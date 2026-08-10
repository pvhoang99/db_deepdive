# Day 29 — Lời giải: Deadlock

> Bài chữa. Đo thật bằng **hai và ba session psql song song**, đọc log Postgres.

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án |
|---|---|---|
| 1 | Phát hiện deadlock sau bao lâu? | **~1 giây** (`deadlock_timeout`), đo được **2.003–2.005 ms** từ lúc câu lệnh đầu bị chặn |
| 2 | Chọn nạn nhân theo tiêu chí gì? | **Transaction PHÁT HIỆN ra chu trình** — tức kẻ vừa hết `deadlock_timeout`. Không có ưu tiên "rẻ hơn" |
| 3 | Deadlock chỉ bằng `UPDATE` (không `FOR UPDATE`)? | **CÓ** — §2 tái hiện được |

---

## §1. Cấu hình

```
 deadlock_timeout | 1s
 log_lock_waits   | on
```

**`deadlock_timeout` không phải thời gian chờ tối đa.** Nó là **chu kỳ kiểm tra**: một transaction chờ quá 1 giây sẽ dựng đồ thị chờ và tìm chu trình.

| Đặt quá thấp | Đặt quá cao |
|---|---|
| tốn CPU dựng đồ thị liên tục trên hệ tranh chấp cao | deadlock treo lâu mới được phá |

`log_lock_waits = on` khiến Postgres ghi vào log **mọi** lần chờ lock quá `deadlock_timeout` — kể cả khi **không** phải deadlock. Đây là nguồn thông tin cực giá trị:

```
LOG:  process 2491 still waiting for ShareLock on transaction 1993 after 1000.181 ms
DETAIL:  Process holding the lock: 2492. Wait queue: 2491.
CONTEXT:  while inserting index tuple (0,3) in relation "uq_pkey"
...
LOG:  process 2491 acquired ShareLock on transaction 1993 after 2004.547 ms
```

**Nên bật `log_lock_waits = on` trên production** — nó cho thấy contention **trước khi** nó thành deadlock.

---

## §2. Deadlock 2 session — chỉ bằng `UPDATE`

| Bước | S1 | S2 |
|---|---|---|
| | `UPDATE ... WHERE id = 1` ✅ | |
| | | `UPDATE ... WHERE id = 2` ✅ |
| | `UPDATE ... WHERE id = 2` → **chờ S2** | |
| | | `UPDATE ... WHERE id = 1` → **DEADLOCK** |

```
ERROR:  deadlock detected
DETAIL:  Process 2492 waits for ShareLock on transaction 1990; blocked by process 2491.
         Process 2491 waits for ShareLock on transaction 1991; blocked by process 2492.
HINT:  See server log for query details.
CONTEXT:  while updating tuple (0,1) in relation "acct"
```

**SQLSTATE: `40P01` (deadlock_detected).**

### Đọc từng dòng

| Dòng | Nghĩa |
|---|---|
| `Process 2492 waits for ShareLock on transaction 1990` | S2 chờ **transaction** của S1 kết thúc (đúng cơ chế Day 28 §2 — chờ trên `transactionid`, không phải tuple) |
| `blocked by process 2491` | kẻ chặn là S1 |
| `Process 2491 waits for ... blocked by process 2492` | **và S1 lại chờ S2** → chu trình khép kín |
| `CONTEXT: while updating tuple (0,1)` | tuple cụ thể gây ra |

### Log Postgres cho chi tiết hơn hẳn client

```
ERROR:  deadlock detected
DETAIL:  Process 2492 waits for ShareLock on transaction 1992; blocked by process 2491.
         Process 2491 waits for ShareLock on transaction 1993; blocked by process 2492.
         Process 2492: INSERT INTO uq VALUES ('a',2);          <<< CÂU LỆNH THẬT
         Process 2491: INSERT INTO uq VALUES ('b',2);          <<< CÂU LỆNH THẬT
```

**Log ghi rõ CÂU LỆNH của từng process** — client chỉ nhận `HINT: See server log for query details`.

> **Không có log Postgres thì không debug được deadlock.** Đây là lý do `log_lock_waits = on` và giữ log là bắt buộc.

### Câu trả lời cho §0.3

**Deadlock xảy ra chỉ với `UPDATE`, không cần `SELECT FOR UPDATE` nào.** Vì `UPDATE` tự lấy khoá dòng, và thứ tự khoá do **thứ tự câu lệnh trong code** quyết định.

Session còn lại (S1) **chạy tiếp bình thường** sau khi S2 bị abort — nó lấy được khoá và hoàn thành. Log xác nhận:
```
LOG:  process 2491 acquired ShareLock on transaction 1993 after 2004.547 ms
```

---

## §3. Deadlock 3 session — vòng tròn dài hơn

```
S1 khoá id=1, chờ id=2
S2 khoá id=2, chờ id=3
S3 khoá id=3, chờ id=1   -> khép vòng
```

```
ERROR:  deadlock detected
DETAIL:  Process 2513 waits for ShareLock on transaction 1996; blocked by process 2514.
         Process 2514 waits for ShareLock on transaction 1997; blocked by process 2515.
         Process 2515 waits for ShareLock on transaction 1998; blocked by process 2513.
         Process 2513: UPDATE acct SET balance=balance+1 WHERE id=1;
         Process 2514: UPDATE acct SET balance=balance+1 WHERE id=2;
         Process 2515: UPDATE acct SET balance=balance+1 WHERE id=3;
```

**Log vẽ ra ĐỦ vòng tròn 3 process** — 2513 → 2514 → 2515 → 2513.

### Ai bị abort

**S3 (pid 2513)** — session **cuối cùng** khép vòng, tức kẻ vừa phát hiện ra chu trình.

Đây là xác nhận cho câu §0.2: Postgres không chọn "transaction rẻ nhất" hay "transaction trẻ nhất". Nó chọn **kẻ đang chạy deadlock detector**, và đó là kẻ vừa hết `deadlock_timeout`.

> **Hệ quả thực dụng: nạn nhân khá ngẫu nhiên.** Không thể thiết kế theo kiểu "transaction quan trọng sẽ thắng". Mọi transaction đều phải có retry.

### Hai cái còn lại giải quyết thế nào

Sau khi S3 rollback, khoá trên id=3 được nhả:
```
LOG:  process 2515 acquired ShareLock on transaction 1998 after 2003.366 ms   <- S2 đi tiếp
LOG:  process 2514 acquired ShareLock on transaction 1997 after 7011.475 ms   <- S1 đi tiếp
```

**Chu trình bị phá bằng cách hy sinh một transaction; hai cái còn lại tự động giải quyết theo dây chuyền.**

Chú ý S1 chờ tổng **7,0 giây** — dài hơn nhiều so với `deadlock_timeout`. Vì nó phải chờ S2 xong, mà S2 lại phải chờ S3 bị abort trước.

---

## §4. Deadlock ẩn — hai ca, một tái hiện được và một KHÔNG

### Ca 1: unique index — CÓ deadlock ✅

```
S1: INSERT ('a',1)          S2: INSERT ('b',1)
S1: INSERT ('b',2) -> chờ   S2: INSERT ('a',2) -> DEADLOCK
```

```
ERROR:  deadlock detected
CONTEXT:  while inserting index tuple (0,4) in relation "uq_pkey"
```

**Không có `UPDATE` nào, không có `FOR UPDATE` nào — chỉ hai `INSERT`.**

Cơ chế: khi `INSERT` một giá trị unique đã tồn tại nhưng **chưa commit**, transaction phải **chờ** transaction kia (nếu nó commit → lỗi trùng khoá; nếu rollback → chèn được). Chờ đó là chờ trên `transactionid` → tạo được chu trình.

> **Đây là nguồn deadlock rất phổ biến và ít ai ngờ**: hai request cùng `INSERT` nhiều bản ghi có unique key theo thứ tự khác nhau.

### Ca 2: khoá ngoại — **KHÔNG** deadlock ❌

```
S1: UPDATE parent SET v=v+1 WHERE id=1;   S2: UPDATE parent SET v=v+1 WHERE id=2;
S1: INSERT INTO child VALUES (10, 2);     S2: INSERT INTO child VALUES (20, 1);
```

**Cả hai `INSERT` đều thành công. Không có deadlock, không có chờ.**

### Giải thích bằng ma trận lock (Day 28 §1) — đây mới là bài học

| Thao tác | Lock lấy trên `parent` |
|---|---|
| `UPDATE parent SET v = v+1` | **`FOR NO KEY UPDATE`** — vì `v` **không** phải cột được tham chiếu bởi FK |
| `INSERT INTO child` | **`FOR KEY SHARE`** trên dòng cha |

Tra ma trận:

| | KEY SHARE | SHARE | NO KEY UPDATE | UPDATE |
|---|---|---|---|---|
| **KEY SHARE** | | | *(trống)* | ✗ |
| **NO KEY UPDATE** | *(trống)* | ✗ | ✗ | ✗ |

**`FOR KEY SHARE` và `FOR NO KEY UPDATE` KHÔNG xung đột nhau.** Nên không có chờ, không có deadlock.

> **Đây chính xác là lý do Postgres 9.3 giới thiệu `FOR NO KEY UPDATE`**: trước đó mọi `UPDATE` đều lấy khoá mạnh nhất và chặn mọi `INSERT` vào bảng con — nguồn contention khổng lồ trong hệ nhiều FK.

**Ca này SẼ deadlock nếu `UPDATE` chạm cột khoá:**
```sql
UPDATE parent SET id = id + 100 WHERE id = 1;   -- đụng khoá -> lấy FOR UPDATE -> xung đột KEY SHARE
```

### Bảng nguồn deadlock ẩn

| Nguồn | Có deadlock? | Ghi chú |
|---|---|---|
| **Unique index** | ✅ **đã đo** | hai `INSERT` cùng giá trị theo thứ tự ngược |
| **Khoá ngoại** | ⚠️ **chỉ khi `UPDATE` đụng cột khoá** | `FOR NO KEY UPDATE` không xung đột `FOR KEY SHARE` |
| `ON CONFLICT` (upsert) | ✅ | cùng cơ chế unique index |
| Trigger | ✅ | trigger sửa bảng khác theo thứ tự khó kiểm soát |
| **Thứ tự trong MỘT câu lệnh** | ✅ | `UPDATE ... WHERE id IN (...)` khoá theo thứ tự **plan** chọn, không phải thứ tự viết |

Nguồn cuối rất đáng chú ý: **cùng một câu `UPDATE ... WHERE id IN (1,2,3)` chạy đồng thời vẫn có thể deadlock** nếu planner chọn thứ tự khác nhau giữa hai lần (ví dụ một lần index scan, một lần bitmap scan → thứ tự TID khác nhau).

Cách phòng: ép thứ tự bằng subquery có `ORDER BY` + `FOR UPDATE`.

---

## §5. Query "ai đang chặn ai"

```
 pid_chờ | state  | chờ_giây |            q_chờ            | pid_chặn |     state_chặn      |           q_chặn
---------+--------+----------+-----------------------------+----------+---------------------+----------------------------
    2537 | active |      2.0 | UPDATE acct SET balance=2.. |     2536 | idle in transaction | UPDATE acct SET balance=1..
```

**Cột `state_chặn = idle in transaction` là thông tin quý nhất** — nó cho biết kẻ chặn **không đang làm gì cả**, chỉ giữ khoá. Đây là dấu hiệu của bug ứng dụng (quên commit, transaction bọc quanh lời gọi HTTP), không phải query chậm.

### `pg_locks` chi tiết

```
 pid  |   locktype    | relation | transactionid |       mode       | granted
------+---------------+----------+---------------+------------------+---------
 2536 | relation      | acct     |               | RowExclusiveLock | t
 2536 | transactionid |          |          1999 | ExclusiveLock    | t       <- S1 giữ XID của mình
 2537 | relation      | acct     |               | RowExclusiveLock | t
 2537 | transactionid |          |          2000 | ExclusiveLock    | t
 2537 | tuple         | acct     |               | ExclusiveLock    | t       <- khoá xếp hàng
 2537 | transactionid |          |          1999 | ShareLock        | f       <- ĐANG CHỜ XID của S1
```

Dòng cuối (`granted = f`) là **cái duy nhất đáng quan tâm**: S2 chờ `ShareLock` trên `transactionid 1999` — chính XID của S1.

Mỗi transaction tự giữ `ExclusiveLock` trên XID của chính nó suốt vòng đời. Ai muốn chờ nó thì xin `ShareLock` trên XID đó — và chỉ được cấp khi transaction kết thúc. **Đó là toàn bộ cơ chế "chờ transaction khác" của Postgres.**

### `pg_cancel_backend` vs `pg_terminate_backend`

| | `pg_cancel_backend(pid)` | `pg_terminate_backend(pid)` |
|---|---|---|
| Tác dụng | **huỷ query đang chạy** | **giết cả connection** |
| Transaction | vẫn sống (ở trạng thái aborted, chờ ROLLBACK) | rollback ngay |
| Connection | vẫn còn | đóng |
| Với `idle in transaction` | **KHÔNG có tác dụng** — không có query để huỷ | ✅ hiệu quả |
| Rủi ro | thấp — app nhận lỗi query, xử lý được | app nhận lỗi connection, có thể không xử lý tốt |

**Quy tắc: thử `pg_cancel_backend` trước; nếu `state = 'idle in transaction'` thì phải dùng `pg_terminate_backend`** (không có query nào để cancel).

```sql
-- an toàn: cancel trước, terminate sau 5 giây nếu chưa hết
SELECT pg_cancel_backend(pid) FROM pg_stat_activity
WHERE state = 'active' AND now() - query_start > interval '5 min';

SELECT pg_terminate_backend(pid) FROM pg_stat_activity
WHERE state = 'idle in transaction' AND now() - state_change > interval '5 min';
```

---

## §6. Phòng deadlock — quy tắc thứ tự khoá, chứng minh bằng số

### Không sắp xếp — DEADLOCK

```
S1: FOR UPDATE id=1  ->  FOR UPDATE id=2
S2: FOR UPDATE id=2  ->  FOR UPDATE id=1
```
```
ERROR:  deadlock detected
CONTEXT:  while locking tuple (0,1) in relation "acct"
```

### Có sắp xếp — CHỈ CHỜ, không deadlock

```sql
-- cả S1 và S2 cùng chạy:
BEGIN; SELECT id FROM acct WHERE id IN (1,2) ORDER BY id FOR UPDATE;
```
```
 số session đang chờ
---------------------
                   1        <- chỉ CHỜ, không lỗi
```
Cả hai đều commit thành công.

### **Đây là bằng chứng cho quy tắc quan trọng nhất về deadlock**

> **Nếu MỌI transaction luôn khoá tài nguyên theo cùng một thứ tự (ví dụ tăng dần theo khoá chính), chu trình chờ KHÔNG THỂ hình thành — deadlock trở nên bất khả thi về mặt toán học.**

Chứng minh: chu trình cần ít nhất một cặp `A chờ B` và `B chờ A`. Nếu mọi transaction khoá theo thứ tự tăng dần, thì A chờ B nghĩa là A đang ở khoá nhỏ hơn khoá B đang giữ — nên B không bao giờ có thể chờ A.

### Bốn quy tắc, xếp theo hiệu quả

**1. Thứ tự khoá nhất quán** — quy tắc mạnh nhất, loại bỏ hoàn toàn deadlock

```java
// Java — ĐÂY là dòng code chống deadlock
List<Long> ids = new ArrayList<>(requestIds);
Collections.sort(ids);                          // <<<
for (Long id : ids) { update(id); }
```
```go
// Go
sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
for _, id := range ids { update(id) }
```
```sql
-- SQL: ép thứ tự khoá ngay trong một câu
SELECT * FROM acct WHERE id = ANY($1) ORDER BY id FOR UPDATE;
```

**2. Transaction ngắn.** Xác suất deadlock tỷ lệ với **thời gian giữ khoá**. Không gọi HTTP, không đọc file, không chờ user trong transaction.

Đo được ở §5: kẻ chặn ở trạng thái **`idle in transaction`** — nó không làm gì cả mà vẫn giữ khoá.

**3. Lấy hết khoá cần thiết ngay từ đầu**, thay vì lấy dần khi cần.

**4. Luôn có retry.** Deadlock là chuyện **bình thường** trong hệ đồng thời, không phải bug.

### 🔧 Với kiến trúc DDD

Một use case thường sửa **nhiều aggregate**. Nếu thứ tự sửa phụ thuộc dữ liệu đầu vào (ví dụ "chuyển tiền từ A sang B" với A, B tuỳ request) thì deadlock **chỉ là chuyện thời gian**.

**Chuẩn hoá thứ tự ở tầng application layer:**
```java
// trong Application Service, TRƯỚC khi gọi domain
var sorted = aggregateIds.stream().sorted().toList();
sorted.forEach(id -> repo.lockAndLoad(id));   // khoá hết theo thứ tự
// rồi mới gọi domain logic
```

Đây là một trong ít chỗ mà **hạ tầng phải rò rỉ vào application layer** — và nó xứng đáng.

---

## §7. Retry loop đúng cách

```sql
CREATE OR REPLACE FUNCTION chuyen_tien(a int, b int, amt int) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE i int := 0; lo int; hi int;
BEGIN
  lo := least(a,b); hi := greatest(a,b);              -- ① THỨ TỰ NHẤT QUÁN
  LOOP
    BEGIN
      PERFORM * FROM acct WHERE id IN (lo,hi) ORDER BY id FOR UPDATE;   -- ② khoá hết ngay
      UPDATE acct SET balance = balance - amt WHERE id = a;
      UPDATE acct SET balance = balance + amt WHERE id = b;
      RETURN 'ok sau ' || i || ' lan thu';
    EXCEPTION WHEN deadlock_detected OR serialization_failure THEN      -- ③ bắt CẢ HAI mã
      i := i + 1;
      IF i > 5 THEN RAISE; END IF;                                      -- ④ giới hạn
      PERFORM pg_sleep(0.01 * i);                                       -- ⑤ backoff
    END;
  END LOOP;
END $$;
```

```
SELECT chuyen_tien(1, 2, 50);   -->  ok sau 0 lan thu
SELECT chuyen_tien(2, 1, 30);   -->  ok sau 0 lan thu

 id | owner | balance
----+-------+---------
  1 | an    |     980      (1000 - 50 + 30)
  2 | binh  |    1020      (1000 + 50 - 30)
```

### Hàm này chống deadlock bằng cách nào

**Dòng `lo := least(a,b); hi := greatest(a,b);`** — dù gọi `chuyen_tien(1,2,...)` hay `chuyen_tien(2,1,...)`, khoá luôn được lấy theo thứ tự **1 trước, 2 sau**. Chu trình không thể hình thành.

`ORDER BY id` trong `PERFORM` là lớp bảo vệ thứ hai (phòng khi planner đổi thứ tự).

**`0 lan thu` ở cả hai lời gọi** — không cần retry lần nào, vì thứ tự khoá đã đúng.

### Hai mã lỗi cần retry

| SQLSTATE | Tên | Nguyên nhân | An toàn retry? |
|---|---|---|---|
| **`40001`** | `serialization_failure` | Repeatable Read / Serializable xung đột | ✅ transaction đã rollback hoàn toàn |
| **`40P01`** | `deadlock_detected` | deadlock | ✅ như trên |

### Tương đương ở tầng ứng dụng

```java
// Spring — lọc theo exception type
@Retryable(
    retryFor = {CannotSerializeTransactionException.class,   // 40001
                DeadlockLoserDataAccessException.class},      // 40P01
    maxAttempts = 5,
    backoff = @Backoff(delay = 50, multiplier = 2, random = true))   // random = JITTER
@Transactional
public void chuyenTien(long from, long to, int amt) { ... }
```

```go
// Go / pgx
for i := 0; i < 5; i++ {
    err := doTx(ctx)
    var pgErr *pgconn.PgError
    if errors.As(err, &pgErr) && (pgErr.Code == "40001" || pgErr.Code == "40P01") {
        jitter := time.Duration(rand.Int63n(int64(time.Millisecond * 50)))
        time.Sleep(time.Duration(1<<i)*10*time.Millisecond + jitter)
        continue
    }
    return err
}
```

### ⚠️ Ba lỗi retry thường gặp

| Lỗi | Hậu quả |
|---|---|
| Retry **ngay lập tức** không backoff | hai transaction lại đâm nhau đúng lúc → **retry storm** |
| Retry **không jitter** | mọi client retry cùng thời điểm → đồng bộ hoá xung đột |
| **Retry vô hạn** | treo mãi khi có bug logic |
| Retry mà **transaction không idempotent** | side effect kép (gửi email 2 lần, trừ tiền 2 lần) |

Điểm cuối quan trọng nhất: **transaction được retry phải chạy lại được từ đầu mà không gây tác dụng phụ.** Mọi lời gọi API bên ngoài phải nằm **ngoài** transaction.

> ⚠️ **Giới hạn của retry trong plpgsql** (nhắc lại Day 26 §7): khối `BEGIN ... EXCEPTION` tạo **subtransaction**, không rollback được transaction ngoài. Với Serializable, lỗi thường xảy ra lúc `COMMIT` — plpgsql không bắt được. **Retry thật sự phải ở tầng ứng dụng.**

---

## Bảng số liệu chính

| Kịch bản | Kết quả |
|---|---|
| `deadlock_timeout` / `log_lock_waits` | **1s** / **on** |
| **Deadlock 2 session (chỉ `UPDATE`)** | ✅ tái hiện, S2 bị abort sau **~2.005 ms** |
| Mã lỗi | **`40P01`** — `deadlock detected`, `CONTEXT: while updating tuple (0,1)` |
| Session còn lại | **chạy tiếp bình thường** (`acquired ShareLock after 2004.547 ms`) |
| **Deadlock 3 session** | ✅ log vẽ **đủ vòng tròn** 2513 → 2514 → 2515 → 2513 |
| — nạn nhân | **kẻ khép vòng** (2513), không phải "rẻ nhất" |
| — S1 chờ tổng | **7.011 ms** (chờ dây chuyền) |
| **Deadlock qua unique index** | ✅ chỉ bằng hai `INSERT`, `CONTEXT: while inserting index tuple` |
| **Deadlock qua khoá ngoại** | ❌ **KHÔNG** — `FOR KEY SHARE` và `FOR NO KEY UPDATE` không xung đột |
| §5 `pg_locks` khi chờ | dòng `granted = f` là `transactionid ShareLock` |
| §5 kẻ chặn | `state = **idle in transaction**` |
| **§6a không sắp xếp** | ❌ **DEADLOCK** |
| **§6b có `ORDER BY id`** | ✅ **chỉ chờ**, cả hai commit thành công |
| §7 retry loop | `ok sau **0** lan thu` — thứ tự đúng nên không cần retry |

---

## Ba điều dễ hiểu sai

| # | Hiểu nhầm | Sự thật đo được |
|---|---|---|
| 1 | "Khoá ngoại luôn gây deadlock khi UPDATE cha + INSERT con" | **KHÔNG deadlock** — `UPDATE` không đụng cột khoá chỉ lấy `FOR NO KEY UPDATE`, không xung đột `FOR KEY SHARE` |
| 2 | "Deadlock cần `SELECT FOR UPDATE`" | Tái hiện được chỉ bằng **hai `UPDATE`**, và cả bằng **hai `INSERT`** vào unique index |
| 3 | "Postgres chọn nạn nhân là transaction rẻ nhất" | Chọn **kẻ phát hiện chu trình** — khá ngẫu nhiên. Mọi transaction đều phải có retry |

Thêm hai điều:
- **`pg_cancel_backend` vô dụng với `idle in transaction`** — không có query để huỷ. Phải `pg_terminate_backend`.
- **Sắp xếp ID trước khi khoá làm deadlock bất khả thi về mặt toán học** — không phải "giảm xác suất", mà là **loại bỏ hoàn toàn**.

---

## Áp dụng vào hệ thật

**1. Grep log production tìm deadlock — làm ngay:**
```bash
grep -c "deadlock detected" postgresql-*.log
grep -A6 "deadlock detected" postgresql-*.log | grep "^\s*Process [0-9]*:" | sort | uniq -c | sort -rn
```
Dòng cuối cho biết **cặp câu lệnh nào hay đâm nhau nhất** — đó là chỗ cần sắp xếp thứ tự khoá.

**2. Bật `log_lock_waits = on`** nếu chưa. Nó cho thấy contention **trước khi** thành deadlock:
```sql
ALTER SYSTEM SET log_lock_waits = on;
ALTER SYSTEM SET deadlock_timeout = '1s';    -- giữ mặc định
SELECT pg_reload_conf();
```

**3. Rà soát code: mọi chỗ khoá nhiều dòng phải sắp xếp trước.**
```bash
# tìm vòng lặp update nhiều id
grep -rn "for.*ids.*update\|forEach.*update" --include=*.java --include=*.go .
```
Mỗi chỗ: có `sort()` trước không?

**4. Đưa query "ai chặn ai" (§5) lên dashboard**, alert khi có session chờ > 30 giây:
```sql
SELECT w.pid, w.state, now()-w.query_start AS cho,
       pg_blocking_pids(w.pid) AS bi_chan_boi,
       b.state AS state_chan, left(b.query,60) AS q_chan
FROM pg_stat_activity w
LEFT JOIN LATERAL unnest(pg_blocking_pids(w.pid)) bp(pid) ON true
LEFT JOIN pg_stat_activity b ON b.pid = bp.pid
WHERE cardinality(pg_blocking_pids(w.pid)) > 0
  AND now() - w.query_start > interval '30 seconds';
```

**5. Kiểm tra retry loop có jitter và giới hạn.** Retry không jitter tạo retry storm — tệ hơn không retry.

**6. Với FK, dùng `FOR NO KEY UPDATE` thay `FOR UPDATE`** ở những chỗ không sửa khoá. Đo được: nó **loại bỏ hoàn toàn** contention giữa `UPDATE` cha và `INSERT` con.

---

## Câu hỏi mở sang các ngày sau

1. `SERIALIZABLE` sinh `40001` thường xuyên hơn deadlock — throughput thật ở 4/16/64 client? → **Day 30**
2. Deadlock, `FOR UPDATE`, optimistic lock — cái nào chịu tải tốt nhất? → **Day 30**
3. `idle in transaction` giữ khoá — nó cũng chặn VACUUM (Day 22). Cùng một cách phòng? → **Day 22 §6**
4. Lock của DDL (`ALTER TABLE`) khác lock của DML thế nào? → **Day 43**
5. Deadlock trên bảng partition — lock lan tới partition nào? → **Day 32, Day 43**
