# Day 08 — Index-only scan, `INCLUDE`, và visibility map

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

```sql
\timing on
\o /days/day-08/output.txt
CREATE EXTENSION IF NOT EXISTS pg_visibility;

-- Làm "bẩn" bảng trước, để visibility map KHÔNG ở trạng thái sạch sẵn.
-- Nếu autovacuum đã chạy từ các bài trước thì §1 sẽ không thấy được hiện tượng.
ALTER TABLE ts_kv SET (autovacuum_enabled = false);
UPDATE ts_kv SET dbl_v = dbl_v WHERE device_id < 3000;
SELECT count(*) FILTER (WHERE all_visible) AS all_visible, count(*) AS tong
FROM pg_visibility('ts_kv');
```

> Con số `all_visible` phải **nhỏ hơn** `tong`. Nếu bằng nhau, chạy lại `UPDATE` với phạm vi rộng hơn.

---

## §0. Đoán trước

1. `ts_kv` vừa insert xong, chưa VACUUM. Query index-only scan sẽ có `Heap Fetches` bằng bao nhiêu?
2. Sau `VACUUM`, con số đó đổi thế nào?
3. Index `(device_id, ts) INCLUDE (dbl_v)` to hơn hay nhỏ hơn `(device_id, ts, dbl_v)`?

---

## §1. Vấn đề: index không biết dòng nào còn sống

### Lý thuyết

Postgres dùng MVCC: một dòng có nhiều phiên bản, phiên bản nào "hiện hữu" phụ thuộc transaction đang hỏi là ai (Day 21).

**Thông tin visibility chỉ nằm trong heap, không nằm trong index.**

Hệ quả: kể cả khi index chứa đủ mọi cột cần, Postgres vẫn phải quay lại heap hỏi *"dòng này còn sống với transaction của tôi không?"*. Nếu vậy thì index-only scan chẳng tiết kiệm gì.

Đây là khác biệt lớn với MySQL/InnoDB — nơi index phụ trỏ vào clustered index và visibility gắn liền. Người từ MySQL sang hay bất ngờ chỗ này.

### Làm ngay

```sql
DROP INDEX IF EXISTS idx_dev_ts_inc;
CREATE INDEX idx_dev_ts_inc ON ts_kv(device_id, ts) INCLUDE (dbl_v);
ANALYZE ts_kv;

EXPLAIN (ANALYZE, BUFFERS)
SELECT device_id, ts, dbl_v FROM ts_kv WHERE device_id = 42;
```

**Ghi vào writeup:** node là gì? `Heap Fetches` bao nhiêu? Buffers bao nhiêu? Nó có thực sự "only" không?

---

## §2. Lời giải: Visibility Map

### Lý thuyết

Mỗi bảng có file phụ `_vm` — **Visibility Map**, chứa **2 bit cho mỗi page heap**:

| Bit | Nghĩa |
|---|---|
| `all-visible` | mọi dòng trong page hiển thị với **mọi** transaction |
| `all-frozen` | mọi dòng đã freeze (liên quan wraparound, Day 25) |

VM cực nhỏ: 5 triệu dòng ≈ 37.000 page ≈ **9 KB** VM. Luôn trong RAM.

Quy trình Index Only Scan:
```
với mỗi entry trong index:
    tra VM cho page chứa TID
    ├── all-visible = true  → dùng luôn dữ liệu trong index. KHÔNG đụng heap.
    └── all-visible = false → phải đọc page heap.  ← Heap Fetches++
```

**Chỉ VACUUM (thủ công hoặc autovacuum) mới đặt bit `all-visible`.**

```
INSERT/UPDATE dòng trong page  →  bit all-visible bị XOÁ
        ↓
VACUUM chạy, page không còn dòng chết và mọi dòng đủ cũ
        ↓
bit all-visible được BẬT  →  index-only scan hoạt động thật
        ↓
lại có UPDATE  →  bit bị xoá lại
```

> **Index-only scan chỉ hiệu quả trên bảng ít bị ghi, hoặc bảng được VACUUM thường xuyên.**

Bảng append-only như `ts_kv` là ứng viên hoàn hảo. Bảng trạng thái bị `UPDATE` liên tục thì gần như không bao giờ được hưởng.

### Làm ngay

```sql
SELECT pg_size_pretty(pg_relation_size('ts_kv', 'vm')) AS vm_size,
       count(*) FILTER (WHERE all_visible) AS pages_all_visible,
       count(*) AS pages_total
FROM pg_visibility('ts_kv');
```

**Ghi vào writeup:** VM to bao nhiêu? Bao nhiêu page đang `all_visible`?

---

## §3. Ba trạng thái của `Heap Fetches` — bài chính

### Làm ngay

```sql
-- ĐO LẦN 2: sau VACUUM
VACUUM ts_kv;
SELECT count(*) FILTER (WHERE all_visible) AS av, count(*) FROM pg_visibility('ts_kv');
EXPLAIN (ANALYZE, BUFFERS) SELECT device_id, ts, dbl_v FROM ts_kv WHERE device_id = 42;
```

```sql
-- ĐO LẦN 3: sau khi làm bẩn
UPDATE ts_kv SET dbl_v = dbl_v + 0.001 WHERE device_id BETWEEN 40 AND 45;
SELECT count(*) FILTER (WHERE all_visible) AS av, count(*) FROM pg_visibility('ts_kv');
EXPLAIN (ANALYZE, BUFFERS) SELECT device_id, ts, dbl_v FROM ts_kv WHERE device_id = 42;
```

```sql
-- ĐO LẦN 4: VACUUM lại
VACUUM ts_kv;
EXPLAIN (ANALYZE, BUFFERS) SELECT device_id, ts, dbl_v FROM ts_kv WHERE device_id = 42;
```

**Ghi vào writeup — bảng 4 dòng:** trạng thái | node | `Heap Fetches` | pages all_visible | buffers | time.

Rồi: giữa lần 1 và lần 2, buffers chênh mấy lần — nói cách khác **VACUUM đáng giá bao nhiêu với query này**?

---

## §4. `INCLUDE` — cột không nằm trong khoá

### Lý thuyết

```sql
CREATE INDEX idx_a ON ts_kv (device_id, ts, dbl_v);            -- 3 cột khoá
CREATE INDEX idx_b ON ts_kv (device_id, ts) INCLUDE (dbl_v);   -- 2 khoá + 1 payload
```

| | Cột khoá | Cột `INCLUDE` |
|---|---|---|
| Có ở tầng lá | ✓ | ✓ |
| Có ở tầng internal | ✓ | ✗ |
| Dùng để tìm kiếm / sắp xếp | ✓ | ✗ |
| Tham gia `UNIQUE` | ✓ | ✗ |
| Làm giảm fanout tầng trên | ✓ | không |

Vì cột `INCLUDE` không lên tầng trên nên **fanout tầng internal không bị ảnh hưởng** → cây không cao thêm.

Hai chỗ `INCLUDE` thật sự thắng:
1. **Cột payload rộng** — `INCLUDE (details_jsonb)` cho index-only scan mà không phá cấu trúc cây.
2. **Cùng với `UNIQUE`** — chỗ không thay thế được:
```sql
CREATE UNIQUE INDEX ON device (uuid) INCLUDE (tenant_id, name);
```
Vẫn ràng buộc duy nhất trên `uuid`, nhưng `SELECT tenant_id, name FROM device WHERE uuid = ?` thành index-only. Nhét `tenant_id` vào khoá thì ràng buộc `UNIQUE` sai hoàn toàn.

Khi nào **không** dùng `INCLUDE`: nếu bạn cũng cần lọc/sắp theo cột đó, để nó làm cột khoá.

### Làm ngay

```sql
CREATE INDEX idx_key3 ON ts_kv(device_id, ts, dbl_v);

SELECT relname, pg_size_pretty(pg_relation_size(oid)) AS size,
       (SELECT level FROM bt_metap(relname)) AS level
FROM pg_class WHERE relname IN ('idx_key3','idx_dev_ts_inc');
```

Query mà **chỉ cột khoá mới phục vụ được**:
```sql
BEGIN; DROP INDEX idx_dev_ts_inc;
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM ts_kv WHERE device_id = 42 AND ts > '2025-06-01' AND dbl_v > 30;
ROLLBACK;

BEGIN; DROP INDEX idx_key3;
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM ts_kv WHERE device_id = 42 AND ts > '2025-06-01' AND dbl_v > 30;
ROLLBACK;
```

**Ghi vào writeup:** kích thước và chiều cao hai index. `Rows Removed by Filter` khác nhau thế nào giữa hai cách?

---

## §5. `INCLUDE` với `UNIQUE`

### Làm ngay

```sql
CREATE UNIQUE INDEX idx_dev_uuid_inc ON device(uuid) INCLUDE (tenant_id, name);
ANALYZE device;

EXPLAIN (ANALYZE, BUFFERS)
SELECT tenant_id, name FROM device WHERE uuid = (SELECT uuid FROM device LIMIT 1);
```

**Ghi vào writeup:** có phải Index Only Scan không? Nếu thay bằng `CREATE UNIQUE INDEX ON device(uuid, tenant_id, name)` thì ràng buộc duy nhất còn đúng không — viết ra vì sao (không cần chạy).

---

## §6. Bảng append-only vs bảng hay update

### Làm ngay

```sql
CREATE INDEX idx_alarm_dev_start ON alarm(device_id, start_ts) INCLUDE (severity);
VACUUM alarm;
EXPLAIN (ANALYZE, BUFFERS) SELECT device_id, start_ts, severity FROM alarm WHERE device_id = 3;

-- UPDATE cột KHÔNG nằm trong index
UPDATE alarm SET status = 'CLEARED_ACK' WHERE device_id BETWEEN 1 AND 100;
EXPLAIN (ANALYZE, BUFFERS) SELECT device_id, start_ts, severity FROM alarm WHERE device_id = 3;
```

**Ghi vào writeup:** `Heap Fetches` đổi ra sao dù `UPDATE` **không chạm cột nào trong index**? Vì sao? (Đây là gợi ý cho Day 24.)

---

## §7. Cái giá của index-only scan

### Lý thuyết

Không miễn phí:
- Index to hơn (chứa thêm dữ liệu) → tốn cache, tốn I/O khi ghi
- Mỗi `UPDATE` chạm cột trong index đều phải cập nhật index, và làm hỏng HOT update (Day 24)

Nên `INCLUDE` cả 10 cột "cho chắc" là phản tác dụng. Chỉ include cột mà query nóng thật sự cần.

### Làm ngay

```sql
-- đo chi phí ghi khi có thêm index
\timing on
CREATE TABLE t_w1 AS SELECT * FROM ts_kv LIMIT 0;
CREATE TABLE t_w2 AS SELECT * FROM ts_kv LIMIT 0;
CREATE INDEX ON t_w2(device_id, ts) INCLUDE (dbl_v, bool_v, str_v);

INSERT INTO t_w1 SELECT * FROM ts_kv LIMIT 300000;
INSERT INTO t_w2 SELECT * FROM ts_kv LIMIT 300000;

SELECT relname, pg_size_pretty(pg_total_relation_size(oid)) FROM pg_class
WHERE relname IN ('t_w1','t_w2');
DROP TABLE t_w1, t_w2;
```

**Ghi vào writeup:** insert vào bảng có index-only-friendly chậm hơn bao nhiêu %? Tổng dung lượng tăng bao nhiêu?

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B. Áp dụng vào hệ thật:** chỉ ra một query nóng trong service của bạn có thể chuyển thành index-only scan. Bảng đó bị ghi nhiều không — nếu có, bạn cần chỉnh gì để giữ được lợi ích?

### Đạt khi

Bạn giải thích được vì sao index-only scan phụ thuộc VACUUM, và biết trước một bảng có phù hợp với chiến lược này hay không chỉ bằng cách nhìn tần suất ghi.

**Xong thì gõ `/review-bai`.**

### Dọn dẹp

```sql
ALTER TABLE ts_kv RESET (autovacuum_enabled);
VACUUM ANALYZE ts_kv;
```
