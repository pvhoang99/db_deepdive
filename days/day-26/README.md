# Day 26 — Ba isolation level của Postgres

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

Từ hôm nay cần **hai terminal**:
```bash
make s1
make s2
```

Trong **S1**:
```sql
\timing on
\o /days/day-26/output.txt
DROP TABLE IF EXISTS acct;
CREATE TABLE acct (id int PRIMARY KEY, owner text, balance int);
INSERT INTO acct VALUES (1,'an',1000), (2,'binh',1000), (3,'cuong',1000);
```

> Mẹo ghi bài: `\o` chỉ ghi output của session đó. Với bài 2 session, dễ nhất là copy-paste cả hai terminal vào `output.txt` và đánh dấu rõ `-- S1:` / `-- S2:`.

---

## §0. Đoán trước

1. Trong **Read Committed**, hai câu `SELECT` trong cùng một transaction có thể trả kết quả khác nhau không?
2. Postgres có Read Uncommitted không?
3. Repeatable Read của Postgres có chặn được phantom read không?

---

## §1. Bốn level của chuẩn SQL vs thực tế Postgres

### Lý thuyết

Chuẩn SQL định nghĩa 4 level qua các anomaly bị cấm:

| Level | Dirty read | Non-repeatable read | Phantom read |
|---|---|---|---|
| Read Uncommitted | cho phép | cho phép | cho phép |
| Read Committed | cấm | cho phép | cho phép |
| Repeatable Read | cấm | cấm | cho phép |
| Serializable | cấm | cấm | cấm |

**Postgres thực hiện khác:**

| Bạn khai | Postgres thực sự làm |
|---|---|
| `READ UNCOMMITTED` | → xử lý như **Read Committed** (không có dirty read, do MVCC) |
| `READ COMMITTED` | Read Committed (mặc định) |
| `REPEATABLE READ` | **Snapshot Isolation** — chặn luôn cả phantom read, mạnh hơn chuẩn |
| `SERIALIZABLE` | SSI — chặn thêm cả **write skew** (Day 30) |

Hai điều đáng nhớ:
- **Postgres không có dirty read ở bất kỳ level nào** — MVCC làm nó không thể xảy ra.
- **Repeatable Read của Postgres mạnh hơn chuẩn**: nó chặn phantom read. Nhưng nó **không** chặn write skew — đó là lý do Serializable tồn tại.

### Làm ngay

**S1:**
```sql
BEGIN TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SHOW transaction_isolation;
COMMIT;
```

**Ghi vào writeup:** Postgres báo level nào? Điều đó xác nhận gì?

---

## §2. Snapshot được chụp lúc nào

### Lý thuyết

Đây là khác biệt cốt lõi giữa Read Committed và Repeatable Read:

| Level | Snapshot chụp khi nào |
|---|---|
| **Read Committed** | mỗi **câu lệnh** chụp một snapshot mới |
| **Repeatable Read / Serializable** | chụp **một lần** ở câu lệnh đầu tiên của transaction, giữ tới hết |

Hệ quả cho Read Committed: hai `SELECT` trong cùng transaction **có thể thấy dữ liệu khác nhau** nếu có transaction khác commit ở giữa.

Đây là điều phá vỡ giả định của rất nhiều code business:
```java
var acc = repo.findById(1);          // đọc lần 1: balance = 1000
// ... logic ...
var acc2 = repo.findById(1);         // đọc lần 2: balance = 500 (ai đó vừa rút)
// tính toán dựa trên acc nhưng ghi dựa trên acc2 -> sai
```

### Làm ngay — Read Committed

**S1:**
```sql
BEGIN;   -- mặc định READ COMMITTED
SELECT id, balance FROM acct WHERE id = 1;
```

**S2:**
```sql
UPDATE acct SET balance = 500 WHERE id = 1;
COMMIT;   -- nếu S2 chưa BEGIN thì lệnh trên đã tự commit
```

**S1 (vẫn trong transaction):**
```sql
SELECT id, balance FROM acct WHERE id = 1;    -- thấy 1000 hay 500?
COMMIT;
```

**Ghi vào writeup:** S1 thấy giá trị nào ở lần đọc thứ hai? Đây là anomaly gì?

---

## §3. Repeatable Read

### Làm ngay

Reset:
```sql
UPDATE acct SET balance = 1000;
```

**S1:**
```sql
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT id, balance FROM acct WHERE id = 1;
```

**S2:**
```sql
UPDATE acct SET balance = 500 WHERE id = 1;
```

**S1:**
```sql
SELECT id, balance FROM acct WHERE id = 1;    -- thấy gì?
COMMIT;
SELECT id, balance FROM acct WHERE id = 1;    -- sau khi commit thì sao?
```

**Ghi vào writeup:** khác gì so với §2? Snapshot của S1 được chụp lúc nào?

> Chú ý tinh tế: snapshot chụp ở **câu lệnh đầu tiên**, không phải lúc `BEGIN`. Kiểm chứng: `BEGIN;` rồi chờ vài giây, để S2 update và commit, **rồi mới** `SELECT` lần đầu — S1 thấy giá trị nào?

---

## §4. Phantom read

### Lý thuyết

Phantom read = chạy cùng một truy vấn có điều kiện phạm vi hai lần, lần thứ hai xuất hiện **dòng mới** do transaction khác chèn vào.

Theo chuẩn SQL, Repeatable Read vẫn cho phép phantom. Nhưng Postgres dùng snapshot isolation nên **chặn được**.

### Làm ngay

**S1:**
```sql
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT count(*) FROM acct WHERE balance >= 500;
```

**S2:**
```sql
INSERT INTO acct VALUES (4, 'dung', 900);
```

**S1:**
```sql
SELECT count(*) FROM acct WHERE balance >= 500;    -- có thấy dòng mới không?
COMMIT;
SELECT count(*) FROM acct WHERE balance >= 500;
```

Lặp lại toàn bộ ở Read Committed để so.

**Ghi vào writeup — bảng 2 dòng:** level | lần đọc 1 | lần đọc 2 | có phantom không. **Vì sao Repeatable Read của Postgres chặn được phantom trong khi chuẩn SQL không yêu cầu?**

---

## §5. Serialization failure — cái giá của Repeatable Read

### Lý thuyết

Snapshot isolation phải đảm bảo: nếu bạn đọc một dòng ở snapshot cũ rồi ghi đè lên nó, mà dòng đó đã bị người khác sửa sau snapshot của bạn, thì ghi đè là **sai**.

Postgres phát hiện và **abort transaction** với mã lỗi `40001 serialization_failure`:
```
ERROR:  could not serialize access due to concurrent update
```

Ở **Read Committed** thì khác: khi gặp dòng đã bị sửa, Postgres **chờ**, rồi đọc lại phiên bản mới nhất và áp `UPDATE` lên đó (gọi là EPQ — EvalPlanQual). Không lỗi, nhưng có thể cho kết quả bất ngờ.

**Hệ quả bắt buộc:** dùng Repeatable Read hoặc Serializable thì **ứng dụng PHẢI có retry loop**. Không có retry thì user gặp lỗi 500.

### Làm ngay

```sql
UPDATE acct SET balance = 1000;   -- reset
```

**S1:**
```sql
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT balance FROM acct WHERE id = 1;
```

**S2:**
```sql
UPDATE acct SET balance = balance - 100 WHERE id = 1;
```

**S1:**
```sql
UPDATE acct SET balance = balance - 100 WHERE id = 1;   -- chuyện gì xảy ra?
```

**Ghi vào writeup:** S1 nhận lỗi gì (mã SQLSTATE)? Rollback rồi làm lại toàn bộ ở Read Committed — kết quả `balance` cuối cùng bằng bao nhiêu ở mỗi level?

---

## §6. Read Committed và cái bẫy EvalPlanQual

### Lý thuyết

Ở Read Committed, khi `UPDATE` gặp dòng đang bị khoá bởi transaction khác:
1. Chờ transaction kia kết thúc
2. Nếu nó commit, **đọc lại phiên bản mới nhất**
3. **Kiểm tra lại điều kiện `WHERE` trên phiên bản mới**
4. Nếu vẫn khớp thì update, nếu không thì bỏ qua dòng đó

Bước 3-4 là chỗ gây bất ngờ: `UPDATE ... WHERE status='PENDING'` có thể **bỏ sót dòng** nếu transaction khác vừa đổi status.

Tệ hơn: điều kiện được kiểm lại nhưng **các dòng khác trong cùng câu lệnh không được đọc lại** — nên câu lệnh có thể thấy một trạng thái hỗn hợp, không tương ứng với bất kỳ thời điểm nào.

### Làm ngay

```sql
DROP TABLE IF EXISTS job;
CREATE TABLE job (id int PRIMARY KEY, status text);
INSERT INTO job VALUES (1,'PENDING'), (2,'PENDING'), (3,'PENDING');
```

**S1:**
```sql
BEGIN;
UPDATE job SET status = 'DONE' WHERE id = 2;
-- chưa commit
```

**S2:**
```sql
BEGIN;
UPDATE job SET status = 'RUNNING' WHERE status = 'PENDING';   -- bị chặn
```

**S1:**
```sql
COMMIT;
```

**S2 (giờ chạy tiếp):**
```sql
SELECT * FROM job ORDER BY id;    -- id=2 có status gì?
COMMIT;
SELECT * FROM job ORDER BY id;
```

**Ghi vào writeup:** S2 update được mấy dòng? `id=2` cuối cùng có status gì? Giải thích bằng EvalPlanQual. **Trong code business của bạn, chỗ nào có mẫu `UPDATE ... WHERE status = ?` như thế này?**

---

## §7. Chọn level nào cho việc gì

### Lý thuyết

| Level | Dùng cho | Ứng dụng phải làm gì |
|---|---|---|
| **Read Committed** | 95% các trường hợp, CRUD thông thường | dùng `SELECT FOR UPDATE` hoặc optimistic lock cho chỗ tranh chấp |
| **Repeatable Read** | báo cáo cần dữ liệu nhất quán một thời điểm; batch job đọc nhiều bảng | **retry loop** cho 40001 |
| **Serializable** | ràng buộc nghiệp vụ phức tạp qua nhiều dòng/bảng (Day 30) | **retry loop**, chấp nhận throughput thấp hơn |

Với kiến trúc DDD/CQRS của bạn: aggregate root thường được bảo vệ bằng **optimistic locking (version column)** ở tầng application, chạy trên Read Committed. Đó là lựa chọn đúng cho hầu hết trường hợp — nhưng phải hiểu nó **không** thay thế được Serializable cho ràng buộc liên-aggregate (Day 27 sẽ cho thấy).

Cấu hình mặc định cho toàn hệ:
```sql
ALTER DATABASE lab SET default_transaction_isolation = 'read committed';
```

### Làm ngay

```sql
SHOW default_transaction_isolation;

-- xem level của các transaction đang chạy
SELECT pid, state, backend_xid, backend_xmin, left(query,50)
FROM pg_stat_activity WHERE backend_xid IS NOT NULL;
```

Viết thử retry loop bằng plpgsql:
```sql
CREATE OR REPLACE FUNCTION rut_tien(p_id int, p_amt int) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE i int := 0;
BEGIN
  LOOP
    BEGIN
      UPDATE acct SET balance = balance - p_amt WHERE id = p_id AND balance >= p_amt;
      IF NOT FOUND THEN RETURN 'khong du so du'; END IF;
      RETURN 'ok sau ' || i || ' lan thu';
    EXCEPTION WHEN serialization_failure THEN
      i := i + 1;
      IF i > 5 THEN RAISE; END IF;
    END;
  END LOOP;
END $$;

SELECT rut_tien(1, 100);
```

**Ghi vào writeup:** retry loop này bắt exception nào? Trong code Java/Go của bạn, bạn bắt lỗi này thế nào (SQLSTATE `40001`)? Spring có `@Retryable`, pgx trả `*pgconn.PgError` với `Code == "40001"`.

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B. Áp dụng vào hệ thật:** service của bạn đang chạy isolation level nào (kiểm tra cấu hình connection pool)? Có chỗ nào dùng Repeatable Read/Serializable mà **không** có retry loop không? Đó là bug chờ nổ.

### Đạt khi

Bạn giải thích được snapshot chụp lúc nào ở mỗi level, tái hiện được non-repeatable read và phantom, và biết vì sao Repeatable Read bắt buộc phải có retry.

**Xong thì gõ `/review-bai`.**
