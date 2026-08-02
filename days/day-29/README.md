# Day 29 — Deadlock

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

Hai terminal (§3 cần ba): `./db.sh s1`, `./db.sh s2`.

**S1:**
```sql
DROP TABLE IF EXISTS acct;
CREATE TABLE acct (id int PRIMARY KEY, owner text, balance int);
INSERT INTO acct VALUES (1,'an',1000),(2,'binh',1000),(3,'cuong',1000);
```

Mở terminal thứ ba xem log:
```bash
docker logs -f pgdd | grep -iA20 deadlock
```

---

## §0. Đoán trước

1. Postgres phát hiện deadlock sau bao lâu?
2. Nó chọn "nạn nhân" theo tiêu chí gì?
3. Deadlock có thể xảy ra giữa hai transaction chỉ `UPDATE` (không `SELECT FOR UPDATE`) không?

---

## §1. Deadlock là gì

### Lý thuyết

Hai transaction chờ nhau thành vòng tròn:

```
S1: giữ lock trên dòng 1, chờ lock trên dòng 2
S2: giữ lock trên dòng 2, chờ lock trên dòng 1
→ không ai đi tiếp được
```

Postgres không thể ngăn deadlock (bài toán không quyết định được trước), nên nó **phát hiện và phá vỡ**: cứ mỗi `deadlock_timeout` (mặc định **1 giây**), transaction đang chờ sẽ dựng đồ thị chờ và tìm chu trình. Thấy chu trình thì **abort một transaction** với mã `40P01 deadlock_detected`.

Chọn nạn nhân: Postgres chọn transaction **phát hiện ra chu trình** — tức là kẻ đang chờ và vừa hết `deadlock_timeout`. Không có ưu tiên theo "transaction rẻ hơn" như một số DB khác. Thực tế nghĩa là: khá ngẫu nhiên.

**Quan trọng:** `deadlock_timeout` không phải thời gian chờ tối đa. Nó là **chu kỳ kiểm tra**. Đặt quá thấp thì tốn CPU kiểm tra liên tục; quá cao thì deadlock treo lâu mới được phá.

### Làm ngay

```sql
SHOW deadlock_timeout;
SHOW log_lock_waits;
```

**Ghi vào writeup:** hai giá trị này là gì trong lab? `log_lock_waits` làm gì?

---

## §2. Tạo deadlock 2 session

### Làm ngay

**S1:**
```sql
BEGIN;
UPDATE acct SET balance = balance - 100 WHERE id = 1;
```
**S2:**
```sql
BEGIN;
UPDATE acct SET balance = balance - 100 WHERE id = 2;
```
**S1:**
```sql
UPDATE acct SET balance = balance + 100 WHERE id = 2;   -- treo, chờ S2
```
**S2:**
```sql
UPDATE acct SET balance = balance + 100 WHERE id = 1;   -- deadlock!
```

**Ghi vào writeup:**
- Session nào bị abort? Sau bao lâu?
- Mã lỗi và thông báo đầy đủ là gì?
- Session còn lại thì sao — nó chạy tiếp được không?
- **Dán log Postgres và giải thích từng dòng** (nó ghi rõ process nào chờ lock gì của process nào).

Dọn: cả hai `ROLLBACK;`

Trả lời câu §0.3: bạn vừa tạo deadlock **chỉ bằng `UPDATE`**, không có `SELECT FOR UPDATE` nào.

---

## §3. Deadlock 3 session — vòng tròn dài hơn

### Làm ngay

Cần 3 terminal.

**S1:** `BEGIN; UPDATE acct SET balance=balance+1 WHERE id=1;`
**S2:** `BEGIN; UPDATE acct SET balance=balance+1 WHERE id=2;`
**S3:** `BEGIN; UPDATE acct SET balance=balance+1 WHERE id=3;`

**S1:** `UPDATE acct SET balance=balance+1 WHERE id=2;`   (chờ S2)
**S2:** `UPDATE acct SET balance=balance+1 WHERE id=3;`   (chờ S3)
**S3:** `UPDATE acct SET balance=balance+1 WHERE id=1;`   (chờ S1 → chu trình)

**Ghi vào writeup:** ai bị abort? Log có vẽ ra cả vòng tròn 3 process không? Sau khi một transaction bị huỷ, hai cái còn lại giải quyết thế nào?

---

## §4. Deadlock ẩn qua khoá ngoại và index

### Lý thuyết

Deadlock không chỉ đến từ `UPDATE` trực tiếp. Các nguồn âm thầm:

| Nguồn | Cơ chế |
|---|---|
| **Khoá ngoại** | `INSERT` con lấy `FOR KEY SHARE` trên dòng cha |
| **Unique index** | hai `INSERT` cùng giá trị unique — cái sau chờ cái trước |
| **Trigger** | trigger sửa bảng khác theo thứ tự bạn không kiểm soát |
| **`ON CONFLICT`** | upsert cùng lúc trên cùng khoá |
| **Thứ tự trong một câu lệnh** | `UPDATE ... WHERE id IN (...)` khoá các dòng theo thứ tự plan chọn, không phải thứ tự bạn viết |

Nguồn cuối rất đáng chú ý: **cùng một câu `UPDATE ... WHERE id IN (1,2,3)` chạy đồng thời từ hai session vẫn có thể deadlock** nếu planner chọn thứ tự khác nhau (ví dụ một lần dùng index scan, một lần dùng bitmap scan).

Cách phòng: `ORDER BY` trong subquery + `FOR UPDATE` để ép thứ tự khoá.

### Làm ngay

Deadlock qua unique index:
```sql
DROP TABLE IF EXISTS uq;
CREATE TABLE uq (k text PRIMARY KEY, v int);
```
**S1:** `BEGIN; INSERT INTO uq VALUES ('a',1);`
**S2:** `BEGIN; INSERT INTO uq VALUES ('b',1);`
**S1:** `INSERT INTO uq VALUES ('b',2);`   (chờ)
**S2:** `INSERT INTO uq VALUES ('a',2);`   (deadlock)

Deadlock qua khoá ngoại:
```sql
DROP TABLE IF EXISTS child, parent;
CREATE TABLE parent (id int PRIMARY KEY, v int);
CREATE TABLE child  (id int PRIMARY KEY, pid int REFERENCES parent(id));
INSERT INTO parent VALUES (1,1),(2,2);
```
**S1:** `BEGIN; UPDATE parent SET v=v+1 WHERE id=1;`
**S2:** `BEGIN; UPDATE parent SET v=v+1 WHERE id=2;`
**S1:** `INSERT INTO child VALUES (10, 2);`   (cần KEY SHARE trên parent 2)
**S2:** `INSERT INTO child VALUES (20, 1);`

**Ghi vào writeup:** cả hai kịch bản có deadlock không? Kịch bản FK có deadlock không — **giải thích bằng ma trận lock ở Day 28 §1** (`FOR KEY SHARE` có xung đột với `UPDATE` không?).

---

## §5. Query "ai đang chặn ai" — mang về production

### Làm ngay

Tạo một tình huống chờ (không deadlock):

**S1:** `BEGIN; UPDATE acct SET balance=1 WHERE id=1;`
**S2:** `BEGIN; UPDATE acct SET balance=2 WHERE id=1;`   (treo)

**Terminal 3:**
```sql
SELECT
  w.pid            AS pid_cho,
  w.usename, w.state,
  now() - w.query_start        AS cho_bao_lau,
  left(w.query, 60)            AS query_cho,
  b.pid            AS pid_chan,
  b.state          AS state_chan,
  now() - b.xact_start         AS xact_chan_bao_lau,
  left(b.query, 60)            AS query_chan
FROM pg_stat_activity w
JOIN LATERAL unnest(pg_blocking_pids(w.pid)) AS bp(pid) ON true
JOIN pg_stat_activity b ON b.pid = bp.pid
WHERE cardinality(pg_blocking_pids(w.pid)) > 0;
```

Chi tiết hơn từ `pg_locks`:
```sql
SELECT l.pid, l.locktype, l.relation::regclass, l.transactionid,
       l.mode, l.granted, left(a.query,50) AS query
FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid
WHERE l.relation = 'acct'::regclass OR l.locktype = 'transactionid'
ORDER BY l.granted DESC, l.pid;
```

Kill kẻ chặn nếu cần:
```sql
SELECT pg_cancel_backend(<pid>);      -- huỷ query, transaction còn sống
SELECT pg_terminate_backend(<pid>);   -- giết cả connection
```

**Ghi vào writeup:** dán kết quả query "ai chặn ai". Phân biệt `pg_cancel_backend` và `pg_terminate_backend` — khi nào dùng cái nào?

Dọn: `ROLLBACK` cả hai.

---

## §6. Phòng deadlock trong code

### Lý thuyết — bốn quy tắc

**1. Thứ tự khoá nhất quán.** Nếu mọi transaction luôn khoá theo thứ tự tăng dần của khoá chính, không bao giờ có chu trình. Áp dụng: sắp xếp ID trước khi xử lý.
```java
ids.sort();                       // ĐÂY là dòng code chống deadlock
for (var id : ids) update(id);
```
```sql
-- trong SQL:
SELECT * FROM acct WHERE id = ANY($1) ORDER BY id FOR UPDATE;
```

**2. Transaction ngắn.** Xác suất deadlock tỷ lệ với thời gian giữ lock. Không gọi HTTP, không đọc file, không chờ user trong transaction.

**3. Lấy hết lock cần thiết ngay từ đầu**, thay vì lấy dần.

**4. Luôn có retry.** Deadlock là chuyện **bình thường** trong hệ đồng thời, không phải bug. Bắt `40P01` và thử lại (kèm jitter để tránh retry storm).

Bổ sung cho hệ của bạn: với DDD, một use case thường sửa nhiều aggregate. Nếu thứ tự sửa phụ thuộc dữ liệu đầu vào thì deadlock chỉ là chuyện thời gian. Chuẩn hoá thứ tự ở tầng application layer.

### Làm ngay

Kiểm chứng quy tắc 1:

**Không sắp xếp** — S1 khoá 1→2, S2 khoá 2→1:
```sql
-- S1
BEGIN; SELECT * FROM acct WHERE id=1 FOR UPDATE; SELECT * FROM acct WHERE id=2 FOR UPDATE;
-- S2
BEGIN; SELECT * FROM acct WHERE id=2 FOR UPDATE; SELECT * FROM acct WHERE id=1 FOR UPDATE;
```

**Có sắp xếp** — cả hai đều `ORDER BY id`:
```sql
-- S1 và S2 cùng chạy:
BEGIN; SELECT * FROM acct WHERE id IN (1,2) ORDER BY id FOR UPDATE;
```

**Ghi vào writeup:** trường hợp nào deadlock, trường hợp nào chỉ chờ rồi chạy tiếp? Viết **quy tắc bạn sẽ áp vào code Java/Go** của mình, kèm ví dụ code cụ thể.

---

## §7. Retry loop đúng cách

### Lý thuyết

Retry sai cách còn tệ hơn không retry:
- Retry ngay lập tức → cả hai lại đâm nhau → **retry storm**
- Retry vô hạn → treo mãi
- Retry mà không rollback → lỗi khác

Đúng cách: **exponential backoff + jitter + giới hạn số lần**.

Các mã lỗi cần retry:
| SQLSTATE | Tên | Nguyên nhân |
|---|---|---|
| `40001` | serialization_failure | Repeatable Read / Serializable xung đột |
| `40P01` | deadlock_detected | deadlock |

Cả hai đều **an toàn để retry** — transaction đã rollback hoàn toàn.

### Làm ngay

```sql
CREATE OR REPLACE FUNCTION chuyen_tien(a int, b int, amt int) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE i int := 0; lo int; hi int;
BEGIN
  lo := least(a,b); hi := greatest(a,b);     -- quy tắc 1: thứ tự nhất quán
  LOOP
    BEGIN
      PERFORM * FROM acct WHERE id IN (lo,hi) ORDER BY id FOR UPDATE;
      UPDATE acct SET balance = balance - amt WHERE id = a;
      UPDATE acct SET balance = balance + amt WHERE id = b;
      RETURN 'ok sau ' || i || ' lan thu';
    EXCEPTION
      WHEN deadlock_detected OR serialization_failure THEN
        i := i + 1;
        IF i > 5 THEN RAISE; END IF;
        PERFORM pg_sleep(0.01 * i);          -- backoff (thật thì thêm jitter)
    END;
  END LOOP;
END $$;

SELECT chuyen_tien(1, 2, 50);
SELECT chuyen_tien(2, 1, 30);
SELECT * FROM acct ORDER BY id;
```

**Ghi vào writeup:** hàm này chống deadlock bằng cách nào (chỉ ra dòng code)? Trong Java/Go bạn viết tương đương thế nào — Spring `@Retryable(SQLException)` lọc theo SQLSTATE, hay pgx kiểm `pgErr.Code`?

### Dọn dẹp

```sql
DROP FUNCTION chuyen_tien(int,int,int);
DROP TABLE acct, uq, child, parent;
```

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B. Áp dụng vào hệ thật:** grep log Postgres production tìm `deadlock detected` — có bao nhiêu lần trong tháng qua? Với mỗi ca, hai câu lệnh nào đâm nhau? Code của bạn có sắp xếp thứ tự khoá không, có retry không?

### Đạt khi

Bạn tạo được deadlock 2 và 3 session, đọc được log deadlock và chỉ ra ai chờ ai, có query monitoring dùng ngay được, và viết được retry loop đúng chuẩn.

**Xong thì gõ `/review-bai`.**
