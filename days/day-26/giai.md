# Day 26 — Lời giải: Ba isolation level của Postgres

> Bài chữa. Đo thật bằng **hai session psql song song** trên lab `SCALE=1`.

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án |
|---|---|---|
| 1 | Read Committed: hai `SELECT` cùng transaction có thể khác nhau? | **CÓ** — đo được **1000 → 500** |
| 2 | Postgres có Read Uncommitted không? | **Không có dirty read**, nhưng `SHOW` vẫn báo **"read uncommitted"** — xem §1 |
| 3 | Repeatable Read của Postgres chặn phantom không? | **CÓ** — mạnh hơn chuẩn SQL yêu cầu |

---

## §1. Bốn level của chuẩn SQL vs thực tế Postgres

```sql
BEGIN TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SHOW transaction_isolation;
```
```
 transaction_isolation
-----------------------
 read uncommitted          <- KHÔNG phải "read committed"
```

### ⚠️ Đây là chỗ README (và nhiều tài liệu) nói chưa chính xác

Nhiều nguồn viết *"Postgres tự động nâng READ UNCOMMITTED thành READ COMMITTED, và `SHOW` sẽ báo read committed"*.

**Số đo nói: `SHOW` báo đúng cái anh khai — `read uncommitted`.**

Sự thật chính xác hơn: Postgres **chấp nhận** khai báo `READ UNCOMMITTED` và **ghi nhớ** nó, nhưng **hành vi** thì y hệt Read Committed — vì MVCC làm dirty read **không thể xảy ra về mặt kiến trúc**. Không có cơ chế nào để đọc một tuple mà `xmin` chưa commit.

**Hệ quả thực tế:** đừng dùng `SHOW transaction_isolation` để kiểm tra "có dirty read không". Nó chỉ cho biết anh đã **khai** gì. Muốn biết hành vi, phải đo — như §2.

### Bảng so sánh

| Bạn khai | Postgres **hành xử** như | `SHOW` báo |
|---|---|---|
| `READ UNCOMMITTED` | **Read Committed** (không có dirty read) | `read uncommitted` |
| `READ COMMITTED` | Read Committed (mặc định) | `read committed` |
| `REPEATABLE READ` | **Snapshot Isolation** — chặn cả phantom | `repeatable read` |
| `SERIALIZABLE` | **SSI** — chặn cả write skew (Day 30) | `serializable` |

Hai điều đáng nhớ:
- **Postgres không có dirty read ở bất kỳ level nào.**
- **Repeatable Read mạnh hơn chuẩn SQL** — nó chặn phantom read (§4). Nhưng **không** chặn write skew (Day 27).

---

## §2. Read Committed — snapshot chụp mỗi câu lệnh

| Thời điểm | S1 (trong transaction) | S2 |
|---|---|---|
| S1 `BEGIN; SELECT` | **1000** | |
| | | `UPDATE ... = 500` (autocommit) |
| S1 `SELECT` lần 2 | **500** ⚠️ | |

**Hai `SELECT` trong cùng một transaction trả về hai giá trị khác nhau.**

Đây là **non-repeatable read** — anomaly mà chuẩn SQL cho phép ở Read Committed.

### Vì sao — snapshot chụp lúc nào

| Level | Snapshot chụp khi nào |
|---|---|
| **Read Committed** | **mỗi CÂU LỆNH** chụp một snapshot mới |
| Repeatable Read / Serializable | **một lần** ở câu lệnh **đầu tiên**, giữ tới hết transaction |

### 🔧 Điều này phá vỡ giả định nào trong code business

```java
@Transactional                                    // Read Committed mặc định
public void chuyenTien(long from, long to, int amt) {
    Account a = repo.findById(from);              // đọc lần 1: balance = 1000
    if (a.getBalance() < amt) throw new Exception("thiếu tiền");

    // ... gọi service khác, validate, log ... (mất 50ms)

    Account a2 = repo.findById(from);             // đọc lần 2: balance = 50 (ai đó vừa rút)
    repo.update(from, a.getBalance() - amt);      // <- GHI DỰA TRÊN a (1000), không phải a2
}
```

**Kiểm tra dựa trên lần đọc 1, ghi dựa trên lần đọc 1, nhưng thực tế đã đổi.** Kết quả: số dư âm.

Ba mẫu code dễ dính:
1. **Đọc → validate → ghi** trong cùng transaction, giữa hai bước có gọi service ngoài
2. **Đọc nhiều bảng để dựng một view nhất quán** — mỗi `SELECT` thấy một thời điểm khác
3. **Vòng lặp `for` xử lý từng dòng** — mỗi vòng là một snapshot mới

Cách sửa (theo thứ tự ưu tiên): `SELECT ... FOR UPDATE` (khoá dòng), optimistic lock bằng version column, hoặc nâng lên Repeatable Read **kèm retry**.

---

## §3. Repeatable Read

| Thời điểm | S1 (`REPEATABLE READ`) | S2 |
|---|---|---|
| S1 `BEGIN; SELECT` | **1000** | |
| | | `UPDATE ... = 500` |
| S1 `SELECT` lần 2 | **1000** ✅ *(vẫn thấy snapshot cũ)* | |
| S1 `COMMIT` | | |
| S1 `SELECT` sau commit | **500** | |

**Snapshot được giữ nguyên suốt transaction.** Non-repeatable read biến mất.

### 💡 Snapshot chụp ở câu lệnh ĐẦU TIÊN, không phải lúc `BEGIN` — kiểm chứng

| Thời điểm | S1 | S2 |
|---|---|---|
| S1 `BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;` | *(chưa chụp snapshot)* | |
| | | `UPDATE ... = 777` (commit) |
| S1 `SELECT` **lần đầu tiên** | **777** ⚠️ | |

**S1 thấy 777** — giá trị S2 vừa ghi **sau** khi S1 đã `BEGIN`.

Vì `BEGIN` chỉ mở transaction, **không** chụp snapshot. Snapshot được chụp ở **câu lệnh đầu tiên thật sự đọc dữ liệu**.

> **Hệ quả thực tế quan trọng:** trong code, `BEGIN` rồi làm việc gì đó vài giây (gọi API, tính toán) rồi mới `SELECT` — snapshot sẽ là thời điểm `SELECT`, không phải `BEGIN`. Nếu cần chụp ngay, dùng:
> ```sql
> BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
> SELECT pg_current_snapshot();   -- hoặc bất kỳ SELECT nào -> chụp snapshot NGAY
> ```

---

## §4. Phantom read

| Level | lần đọc 1 | lần đọc 2 | **Có phantom?** |
|---|---|---|---|
| **Repeatable Read** | **3** | **3** | ❌ **KHÔNG** |
| **Read Committed** | **4** | **5** | ✅ **CÓ** |

*(S2 chèn một dòng mới giữa hai lần đọc trong cả hai trường hợp.)*

### Vì sao Repeatable Read của Postgres chặn được phantom trong khi chuẩn SQL không yêu cầu

Chuẩn SQL định nghĩa các level bằng **danh sách anomaly bị cấm** — nó mô tả *cái gì không được xảy ra*, không mô tả *cách thực hiện*.

Định nghĩa đó ra đời từ mô hình **khoá hai pha (2PL)**:
- 2PL khoá **các dòng đã đọc** → chặn được non-repeatable read
- Nhưng không khoá được **dòng chưa tồn tại** → phantom vẫn lọt (cần predicate lock, rất đắt)

Postgres **không dùng 2PL cho đọc** — nó dùng **Snapshot Isolation**:

```
Mỗi transaction làm việc trên một ảnh chụp tại một thời điểm.
Dòng mới có xmin > snapshot  ->  KHÔNG hiện, bất kể nó thoả điều kiện WHERE gì.
```

Snapshot không phân biệt "dòng đã đọc" với "dòng chưa từng thấy" — **mọi thứ mới hơn snapshot đều vô hình**. Nên phantom bị chặn **miễn phí**, như một hệ quả phụ của kiến trúc.

> **Đây là ví dụ điển hình cho việc: cách thực hiện quyết định đảm bảo thực tế, không phải nhãn dán trên chuẩn.** Repeatable Read của Postgres và của MySQL/InnoDB có cùng tên nhưng khác hành vi.

Nhưng Snapshot Isolation **không** chặn được **write skew** — hai transaction đọc cùng dữ liệu rồi ghi vào **hai dòng khác nhau**, mỗi cái đúng riêng lẻ nhưng cùng nhau phá ràng buộc. Đó là lý do `SERIALIZABLE` tồn tại (Day 27, Day 30).

---

## §5. Serialization failure — cái giá của Repeatable Read

Kịch bản: S1 đọc `balance = 1000`, S2 trừ 100 và commit, rồi S1 cũng trừ 100.

| Level | Kết quả của S1 | **`balance` cuối cùng** |
|---|---|---|
| **Repeatable Read** | **`ERROR: could not serialize access due to concurrent update`** | **900** (chỉ S2 thành công) |
| **Read Committed** | `UPDATE 1` — thành công | **800** (cả hai thành công) |

### Hai hành vi hoàn toàn khác nhau

**Repeatable Read:** S1 làm việc trên snapshot cũ (`balance = 1000`). Ghi đè lên một dòng đã bị sửa sau snapshot của mình là **sai về mặt logic** — Postgres phát hiện và **abort** với SQLSTATE **`40001`**.

**Read Committed:** Postgres dùng **EvalPlanQual (EPQ)**: chờ S2 xong, đọc lại phiên bản mới nhất (900), rồi áp `balance - 100` lên **phiên bản mới** → 800. Không lỗi.

### Cái nào "đúng"?

**Cả hai đều đúng — với những định nghĩa khác nhau về "đúng".**

| | Read Committed (800) | Repeatable Read (lỗi 40001) |
|---|---|---|
| Kết quả | cả hai lần rút đều thành công | một lần bị từ chối |
| Phù hợp khi | `balance = balance - x` (phép toán tương đối) | logic đọc-rồi-quyết-định dựa trên giá trị đọc được |
| Nguy hiểm khi | code đã đọc `balance` và quyết định dựa trên nó | không có retry loop → user gặp lỗi 500 |

Ví dụ Read Committed sai:
```java
int bal = readBalance(id);          // 1000
if (bal >= 900) {                   // đúng tại thời điểm đọc
    exec("UPDATE acct SET balance = balance - 900 WHERE id=?", id);
    // S2 vừa rút 200 -> balance thật là 800 -> kết quả -100. Số dư ÂM.
}
```

Sửa bằng cách đưa điều kiện **vào chính câu UPDATE** (như hàm `rut_tien` ở §7):
```sql
UPDATE acct SET balance = balance - 900 WHERE id = ? AND balance >= 900;
-- rồi kiểm tra số dòng bị ảnh hưởng
```

> ## **Luật bắt buộc: dùng Repeatable Read hoặc Serializable thì ứng dụng PHẢI có retry loop cho SQLSTATE 40001.**
>
> Không có retry = user gặp lỗi 500 ngẫu nhiên khi hệ thống tải cao. Và tải càng cao thì lỗi càng nhiều — đúng lúc không muốn nhất.

---

## §6. Read Committed và cái bẫy EvalPlanQual

Bảng `job` có 3 dòng đều `PENDING`.

| Thời điểm | S1 | S2 |
|---|---|---|
| | `BEGIN; UPDATE job SET status='DONE' WHERE id=2;` | |
| | | `BEGIN; UPDATE job SET status='RUNNING' WHERE status='PENDING';` → **BỊ CHẶN** |
| | | *(chờ trên `wait_event_type = Lock`, `wait_event = transactionid`)* |
| | `COMMIT;` | |
| | | **`UPDATE 2`** — chỉ 2 dòng, không phải 3 |

Kết quả cuối:
```
 id | status
----+---------
  1 | RUNNING
  2 | DONE        <- KHÔNG bị S2 đổi thành RUNNING
  3 | RUNNING
```

### **S2 update được 2 dòng, không phải 3. `id=2` giữ nguyên `DONE`.**

### Giải thích bằng EvalPlanQual

Khi `UPDATE` ở Read Committed gặp dòng đang bị khoá bởi transaction khác:

```
① Chờ transaction kia kết thúc                    (đo được: wait_event = transactionid)
② Nếu nó COMMIT: đọc lại phiên bản MỚI NHẤT của dòng đó
③ KIỂM TRA LẠI điều kiện WHERE trên phiên bản mới
④ Vẫn khớp -> update.  Không khớp -> BỎ QUA dòng đó
```

Với `id=2`: phiên bản mới có `status = 'DONE'`, không còn thoả `WHERE status='PENDING'` → **bỏ qua**.

### 💡 Điều tệ hơn ít người biết

Bước ③ chỉ kiểm lại **dòng bị khoá**. Các dòng khác trong cùng câu lệnh **đã được đọc từ snapshot cũ và không được đọc lại**.

Nghĩa là một câu `UPDATE ... WHERE ...` ở Read Committed có thể thấy một **trạng thái hỗn hợp** — không tương ứng với bất kỳ thời điểm nào từng tồn tại trong database.

### 🔧 Mẫu code dễ dính trong hệ thật

```sql
-- Mẫu job queue ngây thơ — RẤT phổ biến
UPDATE job SET status='RUNNING', worker_id=$1
WHERE status='PENDING'
RETURNING id;
```

Hai worker chạy đồng thời:
- Worker A khoá 100 dòng, đang xử lý
- Worker B chờ, rồi nhận về **ít hơn** 100 dòng (những dòng A đã lấy bị bỏ qua)
- Nếu code B giả định "lấy được đúng N dòng" → sai

Các mẫu khác dễ dính:
```sql
UPDATE inventory SET qty = qty - 1 WHERE sku=$1 AND qty > 0;      -- ổn (điều kiện trong UPDATE)
UPDATE orders SET status='SHIPPED' WHERE status='PAID';           -- có thể bỏ sót dòng
UPDATE alarm SET ack_by=$1 WHERE id=$2 AND ack_by IS NULL;        -- ổn
```

**Nguyên tắc: luôn kiểm tra số dòng thật sự bị ảnh hưởng, đừng giả định.**
```java
int affected = jdbc.update("UPDATE job SET status='RUNNING' WHERE status='PENDING' AND id=?", id);
if (affected == 0) { /* ai đó đã lấy job này — xử lý, đừng bỏ qua */ }
```

Cách đúng cho job queue: **`SELECT ... FOR UPDATE SKIP LOCKED`** (Day 28) — nó không chờ, không bỏ sót âm thầm, và mỗi worker lấy được tập rời nhau.

---

## §7. Chọn level nào cho việc gì

```
default_transaction_isolation = read committed
```

### Retry loop bằng plpgsql

```sql
CREATE OR REPLACE FUNCTION rut_tien(p_id int, p_amt int) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE i int := 0;
BEGIN
  LOOP
    BEGIN
      UPDATE acct SET balance = balance - p_amt
      WHERE id = p_id AND balance >= p_amt;         -- điều kiện NẰM TRONG UPDATE
      IF NOT FOUND THEN RETURN 'khong du so du'; END IF;
      RETURN 'ok sau ' || i || ' lan thu';
    EXCEPTION WHEN serialization_failure THEN       -- SQLSTATE 40001
      i := i + 1;
      IF i > 5 THEN RAISE; END IF;
    END;
  END LOOP;
END $$;
```

```
SELECT rut_tien(1, 100);      -->  ok sau 0 lan thu
SELECT rut_tien(1, 999999);   -->  khong du so du
```

Hai điểm thiết kế đáng học từ hàm này:
1. **Điều kiện `balance >= p_amt` nằm trong `UPDATE`**, không phải `SELECT` rồi `IF` — nên nó nguyên tử, không dính bẫy §5.
2. **Giới hạn số lần thử (5)** rồi `RAISE` — không retry vô hạn.

⚠️ **Giới hạn của retry loop trong plpgsql:** khối `BEGIN ... EXCEPTION` tạo **subtransaction**, không phải transaction mới. Nó bắt được `serialization_failure` sinh trong khối đó, nhưng **không rollback được toàn bộ transaction bên ngoài**. Với Serializable, lỗi thường xảy ra lúc `COMMIT` — lúc đó plpgsql không bắt được nữa.

> **Retry loop thật sự phải nằm ở TẦNG ỨNG DỤNG**, nơi có thể rollback và bắt đầu lại cả transaction.

### Cách bắt lỗi 40001 ở tầng ứng dụng

| Ngôn ngữ / thư viện | Cách |
|---|---|
| **Java / Spring** | `@Retryable(retryFor = CannotSerializeTransactionException.class, maxAttempts = 5, backoff = @Backoff(delay = 50, multiplier = 2))` |
| Java thuần JDBC | `catch (SQLException e) { if ("40001".equals(e.getSQLState())) retry; }` |
| **Go / pgx** | `var pgErr *pgconn.PgError; if errors.As(err, &pgErr) && pgErr.Code == "40001" { retry }` |
| Python / psycopg | `except psycopg.errors.SerializationFailure:` |

**Ba nguyên tắc cho retry loop:**
1. **Exponential backoff + jitter** — retry đồng loạt làm tình hình tệ hơn
2. **Giới hạn số lần** (3–5) rồi trả lỗi cho user
3. **Transaction phải idempotent** — retry chạy lại từ đầu, không được gây side effect kép (gửi email, gọi API, trừ tiền hai lần)

### Bảng chọn level

| Level | Dùng cho | Ứng dụng phải làm gì |
|---|---|---|
| **Read Committed** | **95 %** trường hợp, CRUD thông thường | `SELECT FOR UPDATE` hoặc optimistic lock cho chỗ tranh chấp; **luôn kiểm tra số dòng bị ảnh hưởng** |
| **Repeatable Read** | báo cáo cần nhất quán một thời điểm; batch đọc nhiều bảng | **retry loop** cho 40001 |
| **Serializable** | ràng buộc nghiệp vụ phức tạp qua nhiều dòng/bảng | **retry loop**, chấp nhận throughput thấp hơn (Day 30) |

### 🔧 Với kiến trúc DDD/CQRS

Aggregate root thường được bảo vệ bằng **optimistic locking (version column)** ở tầng application, chạy trên Read Committed:

```sql
UPDATE aggregate SET ..., version = version + 1
WHERE id = $1 AND version = $2;
-- affected = 0 -> ai đó đã sửa -> ném OptimisticLockException -> retry ở tầng trên
```

Đây là lựa chọn **đúng** cho hầu hết trường hợp, và nó là một dạng "serializable thủ công" cho **một** aggregate.

**Nhưng nó KHÔNG thay thế được Serializable cho ràng buộc LIÊN-aggregate** — ví dụ "luôn phải còn ít nhất 1 bác sĩ trực" khi hai bác sĩ là hai aggregate khác nhau. Day 27 sẽ chứng minh bằng số.

---

## Bảng số liệu chính

| Kịch bản | Kết quả |
|---|---|
| `SHOW transaction_isolation` sau khai `READ UNCOMMITTED` | **`read uncommitted`** (không phải `read committed`) |
| **Read Committed**: 2 `SELECT` cùng transaction | **1000 → 500** — non-repeatable read |
| **Repeatable Read**: 2 `SELECT` cùng transaction | **1000 → 1000** ✅ |
| Repeatable Read sau `COMMIT` | 500 |
| **Snapshot chụp lúc nào** | `BEGIN` rồi S2 ghi 777 → S1 `SELECT` đầu tiên thấy **777** |
| **Phantom, Repeatable Read** | 3 → **3** ❌ không phantom |
| **Phantom, Read Committed** | 4 → **5** ✅ có phantom |
| **Serialization failure (RR)** | `ERROR: could not serialize access due to concurrent update`, balance cuối **900** |
| Cùng kịch bản ở Read Committed | `UPDATE 1` thành công, balance cuối **800** |
| **EvalPlanQual** | `UPDATE ... WHERE status='PENDING'` → **`UPDATE 2`** (không phải 3), `id=2` giữ `DONE` |
| — trạng thái chờ | `wait_event_type = Lock`, `wait_event = transactionid` |
| `default_transaction_isolation` | `read committed` |

---

## Ba điều dễ hiểu sai

| # | Hiểu nhầm | Sự thật đo được |
|---|---|---|
| 1 | "`SHOW transaction_isolation` sau `READ UNCOMMITTED` trả về `read committed`" | Trả về **`read uncommitted`**. Nó cho biết anh **khai** gì, không phải hành vi thật |
| 2 | "Repeatable Read chụp snapshot lúc `BEGIN`" | Chụp ở **câu lệnh đầu tiên**. `BEGIN` rồi chờ → thấy dữ liệu mới hơn |
| 3 | "`UPDATE ... WHERE status='PENDING'` cập nhật mọi dòng thoả điều kiện" | Ở Read Committed, EvalPlanQual có thể **bỏ sót dòng âm thầm** — `UPDATE 2` thay vì 3 |

Thêm hai điều:
- **Read Committed và Repeatable Read cho KẾT QUẢ SỐ KHÁC NHAU** cho cùng kịch bản (800 vs 900) — không chỉ khác về lỗi.
- **Retry loop trong plpgsql không đủ** — subtransaction không rollback được transaction ngoài. Phải retry ở tầng ứng dụng.

---

## Áp dụng vào hệ thật

**1. Kiểm tra isolation level thật của service:**
```sql
-- xem cấu hình mặc định
SHOW default_transaction_isolation;
SELECT rolname, rolconfig FROM pg_roles WHERE rolconfig IS NOT NULL;
SELECT datname, datconfig FROM pg_database WHERE datconfig IS NOT NULL;

-- xem transaction đang chạy ở level nào (cần bật log)
SET log_statement = 'all';   -- vài phút, rồi tìm "SET TRANSACTION ISOLATION"
```

Với Spring: `@Transactional(isolation = Isolation.REPEATABLE_READ)`. Với pgx: `pgx.TxOptions{IsoLevel: pgx.RepeatableRead}`.

**2. Tìm chỗ dùng Repeatable Read/Serializable mà KHÔNG có retry — đó là bug chờ nổ:**
```bash
grep -rn "REPEATABLE_READ\|SERIALIZABLE\|RepeatableRead\|Serializable" --include=*.java --include=*.go .
```
Mỗi chỗ tìm được phải có retry loop cho SQLSTATE `40001`. Không có = user sẽ gặp lỗi 500 khi tải cao.

**3. Rà soát mẫu `UPDATE ... WHERE <trạng thái>` — bẫy EvalPlanQual:**
```bash
grep -rniE "UPDATE .* SET .* WHERE .*status" --include=*.sql --include=*.java --include=*.go .
```
Mỗi chỗ: code có kiểm tra số dòng bị ảnh hưởng không? Nếu giả định "update hết" thì đó là bug tiềm ẩn.

Với job queue, chuyển sang `FOR UPDATE SKIP LOCKED` (Day 28).

**4. Rà soát mẫu "đọc → quyết định → ghi" trong cùng transaction.**
Đưa điều kiện vào chính câu `UPDATE`:
```sql
-- thay vì: SELECT balance; if (balance >= amt) UPDATE ...
UPDATE acct SET balance = balance - $2 WHERE id = $1 AND balance >= $2;
-- rồi kiểm tra affected rows
```

**5. Đưa vào quy ước team:** *"Read Committed là mặc định. Nâng level chỉ khi có lý do viết ra được, và luôn kèm retry loop."*

---

## Câu hỏi mở sang các ngày sau

1. Repeatable Read chặn phantom nhưng không chặn **write skew** — tái hiện thế nào? → **Day 27**
2. Job queue đúng cách: `FOR UPDATE SKIP LOCKED` vs advisory lock? → **Day 28**
3. Hai transaction chờ nhau vòng tròn — deadlock detector hoạt động ra sao? → **Day 29**
4. `SERIALIZABLE` (SSI) tốn bao nhiêu throughput so với `FOR UPDATE` và optimistic lock? → **Day 30**
5. `wait_event = transactionid` — còn những loại chờ nào và đọc `pg_locks` thế nào? → **Day 29**
