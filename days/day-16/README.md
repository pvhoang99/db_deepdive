# Day 16 — Nested Loop và Memoize

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

```sql
\timing on
\o /days/day-16/output.txt
CREATE INDEX IF NOT EXISTS idx_tskv_dev ON ts_kv(device_id);
ANALYZE;
```

---

## §0. Đoán trước

1. Nested loop hợp lý tới outer bao nhiêu dòng?
2. `Memoize` giúp được bao nhiêu % trong join `ts_kv × device`?
3. Nếu planner ước lượng outer sai 100 lần, nested loop chậm hơn hash join bao nhiêu lần?

---

## §1. Ba thuật toán join — bức tranh tổng thể

### Lý thuyết

| Thuật toán | Cách làm | Chi phí | Tốt khi |
|---|---|---|---|
| **Nested Loop** | với mỗi dòng outer, quét inner | `O(N × chi_phí_quét_inner)` | outer nhỏ **và** inner có index |
| **Hash Join** | build hash từ bảng nhỏ, probe bằng bảng lớn | `O(N + M)`, cần RAM cho hash | cả hai bảng lớn, join bằng `=` |
| **Merge Join** | sắp cả hai rồi đi song song | `O(N log N + M log M)` hoặc `O(N+M)` nếu đã sắp | cả hai đã có sẵn thứ tự |

Ba cái này là toàn bộ kho vũ khí của Postgres. Không có gì khác.

### Làm ngay

```sql
-- ép từng loại cho cùng một join để thấy khác biệt
SET enable_hashjoin=off; SET enable_mergejoin=off;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv k JOIN device d ON d.id=k.device_id WHERE d.type='controller';
RESET ALL;

SET enable_nestloop=off; SET enable_mergejoin=off;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv k JOIN device d ON d.id=k.device_id WHERE d.type='controller';
RESET ALL;

SET enable_nestloop=off; SET enable_hashjoin=off;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv k JOIN device d ON d.id=k.device_id WHERE d.type='controller';
RESET ALL;
```

**Ghi vào writeup — bảng 3 dòng:** thuật toán | time | buffers | temp. Planner tự chọn cái nào?

---

## §2. Nested Loop hoạt động thế nào

### Lý thuyết

```
for mỗi dòng r trong OUTER:
    for mỗi dòng s trong INNER khớp điều kiện:
        trả ra (r, s)
```

Trong plan, node inner có `loops` = số dòng outer.

```
Nested Loop  (actual rows=8234 loops=1)
  ->  Seq Scan on device d  (actual rows=519 loops=1)        ← OUTER, chạy 1 lần
        Filter: (type = 'controller')
  ->  Index Scan on ts_kv k  (actual rows=16 loops=519)      ← INNER, chạy 519 lần
        Index Cond: (device_id = d.id)
```

**Nested loop chỉ đáng khi inner có index.** Không có index thì mỗi vòng lặp là một Seq Scan toàn bảng — 519 lần quét 5 triệu dòng.

Chi phí thật của node inner = `actual time × loops` (nhắc lại Day 02).

### Làm ngay

```sql
SET enable_hashjoin=off; SET enable_mergejoin=off;

-- inner CÓ index
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM device d JOIN ts_kv k ON k.device_id = d.id WHERE d.type='controller';

-- inner KHÔNG index (bỏ tạm)
BEGIN;
DROP INDEX idx_tskv_dev;
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM device d JOIN ts_kv k ON k.device_id = d.id WHERE d.type='controller' LIMIT 1;
ROLLBACK;

RESET ALL;
```

> Cảnh báo: biến thể không index có thể rất lâu. Nếu quá 2 phút thì `Ctrl+C` và ghi lại rằng bạn phải huỷ — đó chính là bài học.

**Ghi vào writeup:** với inner có index, `loops` bao nhiêu, thời gian thật của node inner bao nhiêu? Không có index thì sao?

---

## §3. Ngưỡng: nested loop hợp lý tới đâu

### Làm ngay

Quét nhiều mức kích thước outer:

```sql
SET enable_hashjoin=off; SET enable_mergejoin=off;

-- outer ~519 dòng
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM device d JOIN ts_kv k ON k.device_id=d.id WHERE d.type='controller';
-- outer ~4500 dòng
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM device d JOIN ts_kv k ON k.device_id=d.id WHERE d.type='gateway';
-- outer ~45000 dòng
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM device d JOIN ts_kv k ON k.device_id=d.id WHERE d.type='sensor';
RESET ALL;
```

Rồi chạy lại cả 3 **không ép** (để planner tự chọn) và so.

**Ghi vào writeup — bảng 6 dòng:** outer rows | thuật toán | time | buffers. **Ngưỡng outer rows nào nested loop bắt đầu thua?** Planner có chọn đúng ở cả 3 mức không?

---

## §4. `Materialize` — đệm cho inner

### Lý thuyết

Khi inner **không** có index và phải quét lại nhiều lần, planner chèn `Materialize`: quét inner một lần, lưu kết quả vào bộ đệm (RAM hoặc file tạm), các vòng sau đọc từ đệm.

Đỡ hơn quét lại từ đầu, nhưng vẫn là `O(N × M)` về mặt so sánh — chỉ tiết kiệm I/O chứ không tiết kiệm CPU.

Thấy `Materialize` dưới một Nested Loop với `loops` lớn thường là dấu hiệu **thiếu index trên inner**.

### Làm ngay

```sql
SET enable_hashjoin=off; SET enable_mergejoin=off;
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM device d JOIN tenant t ON t.id = d.tenant_id WHERE d.type='controller';
RESET ALL;
```

**Ghi vào writeup:** có node `Materialize` không? Nó nằm ở đâu trong cây, và tiết kiệm được gì?

---

## §5. `Memoize` (PG14+) — cache kết quả inner

### Lý thuyết

Nếu outer có nhiều dòng **trùng giá trị join key**, nested loop sẽ quét inner nhiều lần cho cùng một key — công lặp lại vô ích.

`Memoize` đặt một cache LRU giữa: trước khi quét inner, tra cache theo key.

```
Memoize  (actual rows=16 loops=45000)
  Cache Key: d.id
  Cache Mode: logical
  Hits: 41000  Misses: 4000  Evictions: 0  Overflows: 0  Memory Usage: 1200kB
```

- **`Hits`/`Misses`** — tỷ lệ hit cao = memoize đang cứu bạn
- **`Evictions > 0`** — cache đầy, đang phải vứt bớt; cân nhắc tăng `work_mem`
- **`Overflows`** — một entry quá lớn không vừa cache

Memoize chỉ có ích khi **outer có key lặp lại**. Nếu key là duy nhất (join theo PK) thì mọi lần đều miss, và memoize chỉ thêm phí.

Bật/tắt: `SET enable_memoize = on/off;`

### Làm ngay

Dựng tình huống outer có key lặp lại nhiều — join ngược chiều:

```sql
SET enable_hashjoin=off; SET enable_mergejoin=off;

SET enable_memoize = on;
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ts_kv k JOIN device d ON d.id = k.device_id
WHERE k.ts >= '2025-06-01' AND k.ts < '2025-06-01 02:00';

SET enable_memoize = off;
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ts_kv k JOIN device d ON d.id = k.device_id
WHERE k.ts >= '2025-06-01' AND k.ts < '2025-06-01 02:00';

RESET ALL;
```

**Ghi vào writeup:** `Hits`/`Misses` bằng bao nhiêu, tỷ lệ hit mấy %? Memoize cứu được bao nhiêu % thời gian? `Memory Usage` bao nhiêu?

Thử ép cache nhỏ để thấy eviction:
```sql
SET enable_hashjoin=off; SET enable_mergejoin=off; SET work_mem='64kB';
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ts_kv k JOIN device d ON d.id = k.device_id
WHERE k.ts >= '2025-06-01' AND k.ts < '2025-06-01 02:00';
RESET ALL;
```

**Ghi vào writeup:** `Evictions` bao nhiêu? Tỷ lệ hit tụt xuống bao nhiêu?

---

## §6. Khi nested loop là thảm hoạ

### Lý thuyết

Kịch bản kinh điển giết production:

1. Planner ước lượng outer = 5 dòng (do statistics cũ hoặc cột phụ thuộc — tuần 3)
2. Chọn Nested Loop vì "chỉ 5 vòng thôi mà"
3. Thực tế outer = 500.000 dòng
4. 500.000 lần index lookup, mỗi lần vài ms → **query treo hàng chục phút**

Dấu hiệu nhận ra ngay trong plan: node inner có `loops` lớn hơn `rows` ước lượng của outer **rất nhiều lần**.

### Làm ngay

```sql
-- tạo ước lượng sai rồi ép nested loop
DROP STATISTICS IF EXISTS st_dev_geo;
ANALYZE device;

SET enable_hashjoin=off; SET enable_mergejoin=off;
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM device d JOIN ts_kv k ON k.device_id = d.id
WHERE d.region='ap-southeast' AND d.country='VN' AND d.type='sensor';
RESET ALL;

-- và để planner tự quyết
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM device d JOIN ts_kv k ON k.device_id = d.id
WHERE d.region='ap-southeast' AND d.country='VN' AND d.type='sensor';
```

**Ghi vào writeup:** outer ước lượng bao nhiêu vs thật bao nhiêu? Nested loop chậm hơn plan planner chọn bao nhiêu lần?

---

## §7. LEFT JOIN, semi join, anti join với nested loop

### Lý thuyết

Nested loop phục vụ được mọi kiểu join:
- `LEFT JOIN` — nếu inner không có dòng khớp, vẫn trả outer với NULL
- **Semi join** (`EXISTS`, `IN`) — dừng ngay khi tìm được dòng đầu tiên khớp → rất rẻ
- **Anti join** (`NOT EXISTS`) — chỉ trả outer khi inner **không** có dòng nào

Semi/anti join với nested loop + index thường là plan **tối ưu nhất**, vì nó dừng sớm.

### Làm ngay

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM device d WHERE EXISTS (SELECT 1 FROM ts_kv k WHERE k.device_id = d.id);

EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM device d WHERE NOT EXISTS (SELECT 1 FROM ts_kv k WHERE k.device_id = d.id);
```

**Ghi vào writeup:** node join tên là gì trong plan (không phải "Nested Loop" thường)? Với semi join, `actual rows` của node inner bằng bao nhiêu — vì sao nó nhỏ như vậy?

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B. Áp dụng vào hệ thật:** trong service của bạn có join nào giữa một bảng nhỏ (device/user/config) và một bảng rất lớn (telemetry/event/log) không? Nó đang dùng thuật toán gì, và inner đã có index chưa?

### Đạt khi

Bạn nhận ra ngay một nested loop nguy hiểm chỉ bằng cách so `loops` với `rows` ước lượng của outer, và biết khi nào Memoize sẽ giúp được.

**Xong thì gõ `/review-bai`.**
