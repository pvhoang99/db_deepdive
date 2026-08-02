# Day 27 — Lost update, write skew, phantom: tự tay tái hiện

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

Hai terminal: `./db.sh s1` và `./db.sh s2`.

**S1:**
```sql
\timing on
DROP TABLE IF EXISTS acct, oncall, seats;
CREATE TABLE acct   (id int PRIMARY KEY, balance int);
CREATE TABLE oncall (id int PRIMARY KEY, bac_si text, dang_truc boolean);
CREATE TABLE seats  (id int PRIMARY KEY, phong text, ghe int);

INSERT INTO acct VALUES (1, 1000);
INSERT INTO oncall VALUES (1,'an',true), (2,'binh',true);
```

---

## §0. Đoán trước

Ràng buộc nghiệp vụ: **"luôn phải còn ít nhất 1 bác sĩ trực"**. Hai bác sĩ cùng lúc xin nghỉ, mỗi người kiểm tra "còn người khác trực không?" rồi mới nghỉ.

1. Ở **Read Committed**, ràng buộc có bị vi phạm không?
2. Ở **Repeatable Read**?
3. Ở **Serializable**?

Viết dự đoán rồi mới chạy.

---

## §1. Lost update

### Lý thuyết

Kịch bản kinh điển:
```
S1: đọc balance = 1000
S2: đọc balance = 1000
S1: ghi balance = 1000 - 100 = 900
S2: ghi balance = 1000 - 200 = 800     <- mất luôn thao tác của S1
```

Kết quả đúng phải là 700. Ta được 800 — **một giao dịch bị nuốt mất**.

Nguyên nhân: cả hai đọc rồi tính toán **ở tầng ứng dụng**, không phải trong database.

### Làm ngay — tái hiện

Reset: `UPDATE acct SET balance = 1000;`

**S1:**
```sql
BEGIN;
SELECT balance FROM acct WHERE id = 1;    -- ghi lại con số
```
**S2:**
```sql
BEGIN;
SELECT balance FROM acct WHERE id = 1;
```
**S1:**
```sql
UPDATE acct SET balance = 900 WHERE id = 1;   -- 1000 - 100
COMMIT;
```
**S2:**
```sql
UPDATE acct SET balance = 800 WHERE id = 1;   -- 1000 - 200
COMMIT;
SELECT balance FROM acct WHERE id = 1;
```

**Ghi vào writeup:** balance cuối bằng bao nhiêu? Đúng ra phải bằng bao nhiêu?

### Bốn cách sửa

Thử từng cách, ghi lại kết quả và đánh giá:

**Cách 1 — tính trong SQL (đơn giản nhất, đủ dùng cho phép cộng trừ):**
```sql
-- S1 và S2 cùng chạy:
UPDATE acct SET balance = balance - 100 WHERE id = 1;
```

**Cách 2 — pessimistic lock:**
```sql
BEGIN;
SELECT balance FROM acct WHERE id = 1 FOR UPDATE;   -- khoá dòng
-- tính toán ở app
UPDATE acct SET balance = ... WHERE id = 1;
COMMIT;
```

**Cách 3 — optimistic lock (version column) — đúng mẫu DDD của bạn:**
```sql
ALTER TABLE acct ADD COLUMN version int NOT NULL DEFAULT 0;
-- app đọc (balance, version), rồi:
UPDATE acct SET balance = ..., version = version + 1
WHERE id = 1 AND version = <version_da_doc>;
-- nếu 0 dòng bị update -> có xung đột -> retry
```

**Cách 4 — Repeatable Read + retry:**
```sql
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT balance FROM acct WHERE id = 1;
UPDATE acct SET balance = ... WHERE id = 1;   -- sẽ nhận 40001 nếu xung đột
COMMIT;
```

**Ghi vào writeup — bảng 4 dòng:** cách sửa | có chặn được lost update không | ưu điểm | nhược điểm | dùng khi nào. **Trong DDD/CQRS, bạn chọn cách nào cho aggregate root và vì sao?**

---

## §2. Write skew — anomaly mà Repeatable Read KHÔNG chặn

### Lý thuyết

Đây là phần quan trọng nhất hôm nay.

Write skew xảy ra khi hai transaction:
1. **Đọc** cùng một tập dữ liệu
2. Mỗi cái ra quyết định dựa trên tập đó
3. **Ghi vào các dòng KHÁC NHAU**

Vì chúng ghi vào dòng khác nhau nên **không có xung đột ghi** — snapshot isolation không phát hiện được. Nhưng ràng buộc bao trùm cả tập bị vi phạm.

```
Ràng buộc: luôn còn ≥1 bác sĩ trực

S1 (bác sĩ An):   SELECT count(*) FROM oncall WHERE dang_truc  → 2, ok, mình nghỉ được
S2 (bác sĩ Bình): SELECT count(*) FROM oncall WHERE dang_truc  → 2, ok, mình nghỉ được
S1: UPDATE oncall SET dang_truc=false WHERE id=1   (dòng 1)
S2: UPDATE oncall SET dang_truc=false WHERE id=2   (dòng 2)
cả hai COMMIT → 0 bác sĩ trực. Ràng buộc vỡ.
```

Đây là lý do **Serializable tồn tại** — và là lý do optimistic locking trên từng aggregate **không đủ** cho ràng buộc liên-aggregate.

### Làm ngay — Repeatable Read (vẫn hỏng)

Reset: `UPDATE oncall SET dang_truc = true;`

**S1:**
```sql
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT count(*) FROM oncall WHERE dang_truc;      -- bao nhiêu?
```
**S2:**
```sql
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT count(*) FROM oncall WHERE dang_truc;      -- bao nhiêu?
```
**S1:**
```sql
UPDATE oncall SET dang_truc = false WHERE id = 1;
COMMIT;
```
**S2:**
```sql
UPDATE oncall SET dang_truc = false WHERE id = 2;
COMMIT;
SELECT * FROM oncall;                              -- còn ai trực không?
```

**Ghi vào writeup:** cả hai commit thành công? Còn bao nhiêu bác sĩ trực? Ràng buộc có vỡ không?

### Làm ngay — Serializable (được chặn)

Reset: `UPDATE oncall SET dang_truc = true;`

Lặp lại **y hệt** kịch bản trên nhưng đổi `REPEATABLE READ` thành `SERIALIZABLE`.

**Ghi vào writeup:** session nào bị abort, mã lỗi gì, thông báo là gì? Kết quả cuối cùng có đúng ràng buộc không?

---

## §3. Phantom trong write skew

### Lý thuyết

Biến thể của write skew nhưng với `INSERT`: hai transaction cùng đếm rồi cùng chèn.

```
Ràng buộc: mỗi phòng tối đa 10 ghế

S1: SELECT sum(ghe) FROM seats WHERE phong='A'  → 9
S2: SELECT sum(ghe) FROM seats WHERE phong='A'  → 9
S1: INSERT INTO seats VALUES (10,'A',1)
S2: INSERT INTO seats VALUES (11,'A',1)
→ tổng 11 ghế. Vỡ.
```

Snapshot isolation không chặn được vì cả hai chèn dòng mới, không đụng nhau.

### Làm ngay

```sql
TRUNCATE seats;
INSERT INTO seats SELECT g, 'A', 1 FROM generate_series(1,9) g;
```

**S1 (Repeatable Read):**
```sql
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT sum(ghe) FROM seats WHERE phong = 'A';
```
**S2 (Repeatable Read):**
```sql
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT sum(ghe) FROM seats WHERE phong = 'A';
```
**S1:** `INSERT INTO seats VALUES (100,'A',1); COMMIT;`
**S2:** `INSERT INTO seats VALUES (101,'A',1); COMMIT;`
```sql
SELECT sum(ghe) FROM seats WHERE phong='A';
```

Lặp lại với `SERIALIZABLE`.

**Ghi vào writeup:** ở Repeatable Read tổng bằng bao nhiêu? Ở Serializable thì sao?

---

## §4. Sửa write skew mà **không** dùng Serializable

### Lý thuyết

Serializable có cái giá (throughput, retry). Ba cách khác:

**Cách 1 — Materializing conflict:** tạo một dòng đại diện cho "tài nguyên chung" rồi khoá nó.
```sql
CREATE TABLE phong_lock (phong text PRIMARY KEY);
INSERT INTO phong_lock VALUES ('A');
-- mỗi transaction:
SELECT 1 FROM phong_lock WHERE phong='A' FOR UPDATE;   -- tuần tự hoá thủ công
```

**Cách 2 — Advisory lock:** không cần bảng phụ.
```sql
SELECT pg_advisory_xact_lock(hashtext('phong:A'));
```

**Cách 3 — Đưa ràng buộc vào database:** cách bền nhất nếu biểu diễn được.
```sql
-- ví dụ: đảm bảo không đặt trùng khoảng thời gian
CREATE EXTENSION IF NOT EXISTS btree_gist;
ALTER TABLE booking ADD CONSTRAINT no_overlap
  EXCLUDE USING gist (phong WITH =, khoang_tg WITH &&);
```

Cách 3 mạnh nhất — database tự đảm bảo, không phụ thuộc code nào nhớ khoá.

### Làm ngay

```sql
CREATE TABLE phong_lock (phong text PRIMARY KEY);
INSERT INTO phong_lock VALUES ('A');
TRUNCATE seats;
INSERT INTO seats SELECT g,'A',1 FROM generate_series(1,9) g;
```

**S1:**
```sql
BEGIN;
SELECT 1 FROM phong_lock WHERE phong='A' FOR UPDATE;
SELECT sum(ghe) FROM seats WHERE phong='A';
```
**S2:**
```sql
BEGIN;
SELECT 1 FROM phong_lock WHERE phong='A' FOR UPDATE;   -- chuyện gì xảy ra?
```
**S1:** `INSERT INTO seats VALUES (100,'A',1); COMMIT;`
**S2:** (giờ chạy tiếp) `SELECT sum(ghe) FROM seats WHERE phong='A';` — thấy 10, nên **không** chèn nữa. `COMMIT;`

Thử luôn advisory lock:
```sql
-- S1 và S2
BEGIN;
SELECT pg_advisory_xact_lock(hashtext('phong:A'));
...
COMMIT;   -- lock tự nhả khi transaction kết thúc
```

**Ghi vào writeup:** S2 bị chặn ở đâu, chờ bao lâu? So sánh 3 cách (Serializable / materializing conflict / advisory lock): cái nào dễ sai sót nhất, cái nào ảnh hưởng throughput nhất?

---

## §5. Bảng tổng kết — cái gì chặn được cái gì

### Làm ngay

Điền bảng này bằng **kết quả thật bạn vừa đo**, không phải bằng lý thuyết:

| Anomaly | Read Committed | Repeatable Read | Serializable | Sửa ở tầng app bằng |
|---|---|---|---|---|
| Dirty read | | | | |
| Non-repeatable read | | | | |
| Phantom read | | | | |
| **Lost update** | | | | |
| **Write skew** | | | | |

**Ghi vào writeup:** bảng đã điền + một câu giải thích cho mỗi ô "không chặn được".

---

## §6. Ánh xạ về kiến trúc của bạn

### Lý thuyết

Bạn đang dùng DDD + CQRS + Temporal + outbox. Ánh xạ:

| Vấn đề | Công cụ bạn đang dùng | Có đủ không |
|---|---|---|
| Hai lệnh cùng sửa một aggregate | optimistic lock (version) | ✓ đủ |
| Ràng buộc **trong** một aggregate | invariant kiểm trong aggregate + version | ✓ đủ |
| Ràng buộc **qua nhiều** aggregate | ??? | ✗ **đây là write skew** |
| Ràng buộc qua nhiều service | saga / Temporal | ✓ nhưng eventual, có cửa sổ vi phạm |

Ô thứ ba là chỗ đáng suy nghĩ. DDD dạy "một transaction chỉ sửa một aggregate" — nhưng khi ràng buộc bao trùm nhiều aggregate (như "≥1 bác sĩ trực"), bạn phải chọn:
- Gộp lại thành một aggregate lớn hơn (mất tính đồng thời)
- Dùng Serializable (chấp nhận retry)
- Materializing conflict / advisory lock
- Chấp nhận eventual consistency + bù trừ (saga) — chấp nhận có cửa sổ vi phạm

### Làm ngay

Không có SQL. **Ghi vào writeup:** lấy một ràng buộc nghiệp vụ thật trong hệ của bạn bao trùm nhiều aggregate. Phân tích: nó có thể bị write skew không? Hiện tại bạn đang xử lý thế nào? Sau bài hôm nay bạn sẽ đổi gì?

---

## §7. Dọn dẹp

```sql
DROP TABLE acct, oncall, seats, phong_lock, job;
```

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B.** Giải thích bằng 3 câu: **vì sao Repeatable Read của Postgres chặn được phantom read (snapshot isolation) nhưng vẫn không chặn được write skew?**

### Đạt khi

Bạn tái hiện được cả ba anomaly bằng hai session, biết level nào chặn được cái gì bằng thực nghiệm, và chỉ ra được một chỗ trong hệ thật của bạn có nguy cơ write skew.

**Xong thì gõ `/review-bai`.**
