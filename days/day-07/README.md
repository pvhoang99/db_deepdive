# Day 07 — Composite index & quy tắc leftmost

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

```sql
\timing on
\o /days/day-07/output.txt
DROP INDEX IF EXISTS idx_tskv_dev, idx_tskv_ts, idx_tskv_key, idx_tskv_dev_key;
CREATE INDEX idx_dev_ts ON ts_kv(device_id, ts);
CREATE INDEX idx_ts_dev ON ts_kv(ts, device_id);
ANALYZE ts_kv;
```

---

## §0. Đoán trước

Với `WHERE device_id = 42 AND ts BETWEEN '2025-06-01' AND '2025-06-02'`:
- Planner chọn index nào?
- Nếu ép dùng index còn lại, `Rows Removed by Filter` khoảng bao nhiêu?

---

## §1. Index nhiều cột được sắp thế nào

### Lý thuyết

Index `(a, b, c)` sắp theo **thứ tự từ điển**: so `a` trước, `a` bằng nhau thì so `b`, rồi `c`.

Giống danh bạ sắp theo `(họ, tên)`:
```
Nguyễn, An      Tìm "họ Nguyễn"  -> nhảy thẳng tới, đọc liên tục. Nhanh.
Nguyễn, Bình
Nguyễn, Cường   Tìm "tên An"     -> phải lật cả cuốn. Index vô dụng.
Trần,   An
Trần,   Bình
```

**Quy tắc leftmost:** index `(a,b,c)` chỉ dùng được cho các tiền tố `(a)`, `(a,b)`, `(a,b,c)`. Không dùng hiệu quả cho `(b)`, `(c)`, `(b,c)`.

> Lưu ý: Postgres **có thể** vẫn quét toàn bộ index cho `WHERE b = ?` (full index scan) nếu index nhỏ hơn bảng nhiều. Nhưng đó là quét toàn bộ, không phải lookup — đừng nhầm là "index đang hoạt động".

### Làm ngay

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv WHERE device_id = 42;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv WHERE ts >= '2025-06-01' AND ts < '2025-06-02';
```

**Ghi vào writeup:** query 1 dùng index nào, query 2 dùng index nào? Với query 2, `idx_dev_ts` có được dùng không — giải thích bằng quy tắc leftmost.

---

## §2. Quy tắc vàng: equality trước, range sau

### Lý thuyết

Xét `WHERE device_id = 42 AND ts BETWEEN '2025-06-01' AND '2025-06-02'`

**Index `(device_id, ts)`** — đúng:
```
device_id=42, ts=06-01 00:00  ┐
device_id=42, ts=06-01 06:00  ├─ mọi dòng cần đều LIỀN NHAU
device_id=42, ts=06-01 18:00  ┘
device_id=42, ts=06-05 ...     ← dừng ở đây
```
Cả hai điều kiện vào `Index Cond`.

**Index `(ts, device_id)`** — sai:
```
ts=06-01 00:00, device_id=7      ← phải đọc
ts=06-01 00:00, device_id=42     ← cần
ts=06-01 00:01, device_id=1893   ← phải đọc
```
Chỉ thu hẹp được theo `ts`; `device_id=42` rơi xuống `Filter`.

**Quy tắc:** đặt cột dùng `=` trước, cột dùng `>`, `<`, `BETWEEN`, `LIKE 'x%'` sau cùng. **Sau cột range đầu tiên, mọi cột phía sau chỉ còn dùng được làm `Filter`.**

Với nhiều cột equality, thứ tự giữa chúng không ảnh hưởng tính đúng đắn — nhưng ảnh hưởng khả năng tái sử dụng cho query khác. Đặt cột **hay xuất hiện nhất** lên trước.

### Làm ngay

Mẹo ép index: **DDL trong Postgres là transactional** — xoá index tạm rồi rollback.

```sql
BEGIN;
DROP INDEX idx_ts_dev;                        -- chỉ mất trong transaction này
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv
  WHERE device_id = 42 AND ts >= '2025-06-01' AND ts < '2025-06-02';
ROLLBACK;                                     -- index quay lại, không phải build lại

BEGIN;
DROP INDEX idx_dev_ts;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv
  WHERE device_id = 42 AND ts >= '2025-06-01' AND ts < '2025-06-02';
ROLLBACK;
```

> Mẹo rất đáng nhớ: bạn thử được "nếu bỏ index này thì sao" **trên cả production** mà không mất gì. Đổi lại `DROP INDEX` giữ `ACCESS EXCLUSIVE` lock tới lúc rollback — chỉ làm khi bảng đang rảnh.

**Ghi vào writeup:** hai index chênh nhau bao nhiêu lần về buffers? Chỉ rõ điều kiện nào vào `Index Cond`, cái nào xuống `Filter` ở mỗi index.

---

## §3. Ma trận 4 query × 2 index — bài chính

### Làm ngay

```sql
-- Q1: equality + range
SELECT count(*) FROM ts_kv WHERE device_id = 42 AND ts >= '2025-06-01' AND ts < '2025-06-02';
-- Q2: chỉ range
SELECT count(*) FROM ts_kv WHERE ts >= '2025-06-01' AND ts < '2025-06-02';
-- Q3: chỉ equality
SELECT count(*) FROM ts_kv WHERE device_id = 42;
-- Q4: IN + range
SELECT count(*) FROM ts_kv WHERE device_id IN (1,7,42) AND ts >= '2025-07-01';
```

Với mỗi query chạy 3 lần: (a) planner tự chọn, (b) ép `idx_dev_ts`, (c) ép `idx_ts_dev` — dùng mẹo `BEGIN; DROP INDEX ...; ROLLBACK;`.

**Ghi vào writeup — bảng 12 dòng:**

| Query | Index | Index Cond | Filter | Rows Removed by Filter | buffers | time |
|---|---|---|---|---|---|---|

Với Q4, chú ý dạng `Index Cond: (device_id = ANY ('{1,7,42}'))` — Postgres thi hành như 3 lần quét rồi gộp.

---

## §4. Kéo điều kiện từ Filter lên Index Cond

### Làm ngay

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ts_kv WHERE device_id = 42 AND key_id = 1 AND ts >= '2025-06-01';
```
Ghi `Rows Removed by Filter`.

Tạo index đúng thứ tự (equality trước, range sau):
```sql
CREATE INDEX idx_dev_key_ts ON ts_kv(device_id, key_id, ts);
ANALYZE ts_kv;
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ts_kv WHERE device_id = 42 AND key_id = 1 AND ts >= '2025-06-01';
```

**Ghi vào writeup:** `Rows Removed by Filter` từ bao nhiêu xuống bao nhiêu, buffers giảm mấy lần? Viết **quy tắc chọn thứ tự cột bằng đúng 2 câu.**

---

## §5. `ORDER BY` và node Sort

### Lý thuyết

Index trả dòng **theo đúng thứ tự đã sắp**. Nếu `ORDER BY` khớp, node `Sort` biến mất hoàn toàn.

Index `(device_id, ts)` phục vụ được `ORDER BY device_id, ts` và `ORDER BY device_id DESC, ts DESC` (đi ngược được).

Nhưng **không** phục vụ `ORDER BY device_id ASC, ts DESC` — trộn chiều. Muốn vậy phải khai lúc tạo:
```sql
CREATE INDEX ON ts_kv (device_id ASC, ts DESC);
```

Cực hữu ích cho mẫu "lấy N bản ghi mới nhất của device X" — query phổ biến nhất trong hệ IoT.

### Làm ngay

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT ts, dbl_v FROM ts_kv WHERE device_id = 42 ORDER BY ts DESC LIMIT 10;

CREATE INDEX idx_dev_ts_desc ON ts_kv(device_id, ts DESC);
ANALYZE ts_kv;

EXPLAIN (ANALYZE, BUFFERS)
SELECT ts, dbl_v FROM ts_kv WHERE device_id = 42 ORDER BY ts DESC LIMIT 10;
EXPLAIN (ANALYZE, BUFFERS)
SELECT ts, dbl_v FROM ts_kv WHERE device_id = 42 ORDER BY ts ASC LIMIT 10;
```

**Ghi vào writeup:** node `Sort` còn không sau khi có index? Buffers từ bao nhiêu xuống bao nhiêu? Index `DESC` có phục vụ được `ORDER BY ASC` không — vì sao?

---

## §6. `IN`, `OR`, và giới hạn của Postgres

### Lý thuyết

- `WHERE device_id IN (1,2,3) AND ts > ?` — dùng được index `(device_id, ts)`, thi hành như 3 lần quét rồi gộp.
- `WHERE a = 1 OR b = 2` — **không** dùng được index composite. Planner dùng `BitmapOr` với hai index riêng, hoặc seq scan.
- Postgres **không có index skip scan** (loose index scan) như Oracle/MySQL 8. Nên `WHERE b = ?` trên index `(a,b)` với `a` ít giá trị phân biệt vẫn không tối ưu tự động.

### Làm ngay

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv WHERE device_id = 42 OR key_id = 6;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv WHERE key_id = 6 AND ts > '2025-07-01';
```

**Ghi vào writeup:** query `OR` được thi hành thế nào? Query thứ hai (`key_id` không phải cột đầu của index nào) planner làm gì?

---

## §7. Bao nhiêu index là đủ — tìm index thừa

### Lý thuyết

Mỗi index thêm vào: làm chậm ghi (Day 10 sẽ đo), chiếm dung lượng và cache, thêm việc cho VACUUM.

**Một composite index đặt đúng thứ tự thường thay được 2-3 index đơn.** Index `(a,b,c)` phục vụ `(a)`, `(a,b)`, `(a,b,c)` — nên nếu đã có nó thì index riêng trên `(a)` là **thừa**.

### Làm ngay

```sql
CREATE INDEX idx_dev_only ON ts_kv(device_id);
```
Chạy lại Q1 và Q3 ở §3 — planner có bao giờ chọn `idx_dev_only` thay `idx_dev_ts` không, trong trường hợp nào?

Tìm index thừa trong toàn database:
```sql
SELECT a.indrelid::regclass AS tbl,
       a.indexrelid::regclass AS idx_thua,
       b.indexrelid::regclass AS bi_bao_phu_boi
FROM pg_index a JOIN pg_index b
  ON b.indrelid = a.indrelid AND b.indexrelid <> a.indexrelid
WHERE array_length(b.indkey::int2[],1) > array_length(a.indkey::int2[],1)
  AND (b.indkey::int2[])[0:array_length(a.indkey::int2[],1)-1] = a.indkey::int2[];
```

Và index chưa từng được dùng:
```sql
SELECT relname, idx_scan, pg_size_pretty(pg_relation_size(indexrelid))
FROM pg_stat_user_indexes WHERE idx_scan = 0 ORDER BY pg_relation_size(indexrelid) DESC;
```

**Ghi vào writeup:** có index nào thừa không? Bạn sẽ xoá cái nào?

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B. Áp dụng vào hệ thật:** lấy 3 query hay chạy nhất trong service của bạn, viết index composite đúng thứ tự cho từng cái, và chỉ ra index đơn nào hiện có đang thừa.

### Đạt khi

Cho một query bất kỳ, bạn viết được ngay thứ tự cột đúng, và giải thích bằng "equality trước, range sau, sau range thì hết tác dụng".

**Xong thì gõ `/review-bai`.**
