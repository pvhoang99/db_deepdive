# Day 19 — Aggregation: HashAgg, GroupAgg và hash spill

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

```sql
\timing on
\o /days/day-19/output.txt
ANALYZE;
```

---

## §0. Đoán trước

1. `GROUP BY device_id` (50.000 nhóm) với `work_mem = 4MB` — HashAgg hay GroupAgg?
2. `GROUP BY device_id, key_id, date_trunc('hour', ts)` sinh bao nhiêu nhóm?
3. Trước PG13, query nhóm quá nhiều có thể làm gì với server?

---

## §1. Hai cách gom nhóm

### Lý thuyết

**HashAggregate** — dựng hash table `key → trạng thái tích luỹ`, đọc một lượt:
```
for mỗi dòng:
    tra hash[key], cập nhật (count++, sum += x, ...)
```
- Một lượt quét, không cần sắp xếp → nhanh
- Cần RAM tỷ lệ với **số nhóm** (không phải số dòng)
- Kết quả **không có thứ tự**

**GroupAggregate** — yêu cầu dữ liệu đã sắp theo khoá nhóm, rồi gom các dòng liền nhau:
```
for mỗi dòng (đã sắp):
    nếu key đổi -> xuất nhóm trước, bắt đầu nhóm mới
```
- Cần sort trước (trừ khi đã có index)
- RAM chỉ đủ chứa **một nhóm** → không bao giờ nổ
- Kết quả **đã sắp** theo khoá nhóm — miễn phí cho `ORDER BY`

Planner chọn HashAgg khi ước lượng `số nhóm × kích thước trạng thái` vừa `work_mem`.

### Làm ngay

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT key_id, count(*) FROM ts_kv GROUP BY key_id;                -- 8 nhóm
EXPLAIN (ANALYZE, BUFFERS) SELECT device_id, count(*) FROM ts_kv GROUP BY device_id;          -- 50k nhóm
EXPLAIN (ANALYZE, BUFFERS) SELECT device_id, count(*) FROM ts_kv GROUP BY device_id ORDER BY device_id;
```

**Ghi vào writeup:** mỗi query dùng node gì? Query thứ 3 có `ORDER BY` — plan có đổi so với query 2 không, vì sao?

---

## §2. Ép cả hai cách để so

### Làm ngay

```sql
SET enable_hashagg = off;
EXPLAIN (ANALYZE, BUFFERS) SELECT device_id, count(*), avg(dbl_v) FROM ts_kv GROUP BY device_id;
RESET enable_hashagg;

EXPLAIN (ANALYZE, BUFFERS) SELECT device_id, count(*), avg(dbl_v) FROM ts_kv GROUP BY device_id;
```

**Ghi vào writeup — bảng 2 dòng:** phương án | node | time | buffers | temp | Memory/Disk. Planner chọn đúng chưa?

---

## §3. Hash spill (PG13+) — và vì sao trước đó nguy hiểm

### Lý thuyết

**Trước PG13**: nếu planner ước lượng số nhóm sai và HashAgg vượt `work_mem`, Postgres **không có cơ chế tràn** — nó cứ cấp phát tiếp cho tới khi hết RAM. Kết quả: OOM killer giết postmaster, cả database restart. Đây là một trong những cách phổ biến nhất làm sập Postgres.

**Từ PG13**: HashAgg biết tràn ra đĩa, giống hash join. Plan hiện:
```
HashAggregate
  Group Key: device_id
  Planned Partitions: 32  Batches: 33  Memory Usage: 4145kB  Disk Usage: 78912kB
```

- `Planned Partitions` — số phân vùng dự kiến chia
- `Disk Usage` — đã ghi ra đĩa bao nhiêu

An toàn hơn nhiều, nhưng **vẫn chậm**. `Disk Usage > 0` vẫn là cờ đỏ cần xử lý.

### Làm ngay

```sql
SET work_mem = '1MB';
EXPLAIN (ANALYZE, BUFFERS)
SELECT device_id, key_id, date_trunc('hour', ts) AS h, count(*), avg(dbl_v)
FROM ts_kv GROUP BY 1,2,3;

SET work_mem = '16MB';
EXPLAIN (ANALYZE, BUFFERS)
SELECT device_id, key_id, date_trunc('hour', ts) AS h, count(*), avg(dbl_v)
FROM ts_kv GROUP BY 1,2,3;

SET work_mem = '512MB';
EXPLAIN (ANALYZE, BUFFERS)
SELECT device_id, key_id, date_trunc('hour', ts) AS h, count(*), avg(dbl_v)
FROM ts_kv GROUP BY 1,2,3;
RESET work_mem;
```

**Ghi vào writeup — bảng 3 dòng:** work_mem | node | Planned Partitions | Memory Usage | Disk Usage | time.

Đếm số nhóm thật:
```sql
SELECT count(*) FROM (SELECT DISTINCT device_id, key_id, date_trunc('hour', ts) FROM ts_kv) s;
```
So với `rows` planner ước lượng ở node aggregate — lệch mấy lần?

---

## §4. Ước lượng số nhóm — nguồn lỗi

### Lý thuyết

Planner ước lượng số nhóm bằng cách nhân `n_distinct` các cột nhóm (giả định độc lập — nhắc lại Day 13).

Với `GROUP BY device_id, key_id`: `50.000 × 8 = 400.000`. Nhưng nếu mỗi device chỉ gửi 2 loại key thì số nhóm thật chỉ `100.000`.

Sai theo hướng **đánh giá cao** → planner chọn GroupAgg (kèm sort đắt) trong khi HashAgg vừa RAM.
Sai theo hướng **đánh giá thấp** → HashAgg spill.

Sửa bằng `CREATE STATISTICS (ndistinct)` — đúng công cụ của Day 13.

### Làm ngay

```sql
EXPLAIN SELECT device_id, key_id, count(*) FROM ts_kv GROUP BY 1,2;
SELECT count(*) FROM (SELECT DISTINCT device_id, key_id FROM ts_kv) s;

CREATE STATISTICS st_tskv_dk (ndistinct) ON device_id, key_id FROM ts_kv;
ANALYZE ts_kv;

EXPLAIN SELECT device_id, key_id, count(*) FROM ts_kv GROUP BY 1,2;
```

**Ghi vào writeup:** ước lượng số nhóm trước/sau, và số thật. Plan có đổi không?

---

## §5. Parallel Aggregate

### Lý thuyết

Aggregate song song hoá theo mô hình hai pha:

```
Finalize Aggregate          <- leader gộp kết quả từng phần
  -> Gather
       -> Partial Aggregate  <- mỗi worker gom nhóm phần dữ liệu của mình
            -> Parallel Seq Scan
```

Điều kiện: hàm tổng hợp phải có **combine function** — `count`, `sum`, `avg`, `min`, `max` đều có. Một số hàm không có (`array_agg` với thứ tự, `string_agg` có ORDER BY, hàm tự viết chưa khai `COMBINEFUNC`) → **không parallel được**.

Đây là lý do thêm một `string_agg(x ORDER BY y)` vào query có thể làm mất parallel và chậm 4 lần.

### Làm ngay

```sql
SET max_parallel_workers_per_gather = 4;
EXPLAIN (ANALYZE, BUFFERS) SELECT key_id, count(*), avg(dbl_v) FROM ts_kv GROUP BY key_id;
EXPLAIN (ANALYZE, BUFFERS) SELECT key_id, string_agg(DISTINCT str_v, ',') FROM ts_kv GROUP BY key_id;
SET max_parallel_workers_per_gather = 0;
EXPLAIN (ANALYZE, BUFFERS) SELECT key_id, count(*), avg(dbl_v) FROM ts_kv GROUP BY key_id;
RESET max_parallel_workers_per_gather;
```

**Ghi vào writeup:** query nào parallel được, query nào không? Parallel giúp bao nhiêu lần? **Khi nào nó không giúp?**

---

## §6. `FILTER`, `DISTINCT` trong aggregate, và `GROUPING SETS`

### Lý thuyết

```sql
count(*) FILTER (WHERE severity = 'CRITICAL')
```
Rẻ hơn nhiều so với `CASE WHEN` lồng nhau, và **quét bảng một lần** thay vì nhiều subquery.

```sql
count(DISTINCT device_id)
```
Đắt: phải giữ tập giá trị phân biệt trong RAM cho **mỗi nhóm**, và **không parallel được**. Trên dữ liệu lớn nên cân nhắc HyperLogLog (extension `postgresql-hll`) nếu chấp nhận sai số.

```sql
GROUP BY GROUPING SETS ((a), (b), (a,b))
GROUP BY ROLLUP(a, b)
GROUP BY CUBE(a, b)
```
Gom nhiều mức tổng hợp trong **một lượt quét** thay vì `UNION ALL` nhiều query. Rất đáng dùng cho báo cáo.

### Làm ngay

```sql
-- FILTER vs nhiều subquery
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FILTER (WHERE severity='CRITICAL') AS crit,
       count(*) FILTER (WHERE severity='MAJOR')    AS major,
       count(*) FILTER (WHERE end_ts IS NULL)      AS active
FROM alarm;

EXPLAIN (ANALYZE, BUFFERS)
SELECT (SELECT count(*) FROM alarm WHERE severity='CRITICAL'),
       (SELECT count(*) FROM alarm WHERE severity='MAJOR'),
       (SELECT count(*) FROM alarm WHERE end_ts IS NULL);

-- count(DISTINCT)
EXPLAIN (ANALYZE, BUFFERS) SELECT key_id, count(DISTINCT device_id) FROM ts_kv GROUP BY key_id;
EXPLAIN (ANALYZE, BUFFERS) SELECT key_id, count(*) FROM ts_kv GROUP BY key_id;

-- GROUPING SETS
EXPLAIN (ANALYZE, BUFFERS)
SELECT region, country, count(*) FROM device GROUP BY ROLLUP(region, country);
```

**Ghi vào writeup:** `FILTER` nhanh hơn nhiều subquery mấy lần, buffers chênh mấy lần? `count(DISTINCT)` đắt hơn `count(*)` mấy lần và có parallel được không?

---

## §7. Chiến lược tổng hợp cho time-series

### Lý thuyết

Với hệ IoT, aggregate nặng nhất luôn là dạng "downsample": trung bình theo giờ/ngày cho mỗi device.

Ba chiến lược, đắt dần về vận hành nhưng rẻ dần về query:

1. **Tính lúc query** — đơn giản, luôn đúng, nhưng quét toàn bộ dữ liệu thô mỗi lần
2. **Materialized view + refresh định kỳ** — nhanh, nhưng dữ liệu trễ, và `REFRESH` khoá bảng (trừ `CONCURRENTLY`, cần unique index)
3. **Bảng rollup tự cập nhật** — ghi vào bảng tổng hợp ngay lúc nạp dữ liệu (trigger hoặc ứng dụng). Nhanh nhất, phức tạp nhất

### Làm ngay

```sql
-- (1) tính lúc query
EXPLAIN (ANALYZE, BUFFERS)
SELECT device_id, date_trunc('hour', ts) h, avg(dbl_v)
FROM ts_kv WHERE key_id = 1 AND ts >= '2025-06-01' AND ts < '2025-06-08'
GROUP BY 1,2;

-- (2) materialized view
CREATE MATERIALIZED VIEW mv_hourly AS
SELECT device_id, key_id, date_trunc('hour', ts) AS h, avg(dbl_v) AS avg_v, count(*) AS n
FROM ts_kv GROUP BY 1,2,3;
CREATE UNIQUE INDEX ON mv_hourly(device_id, key_id, h);
ANALYZE mv_hourly;

EXPLAIN (ANALYZE, BUFFERS)
SELECT device_id, h, avg_v FROM mv_hourly
WHERE key_id = 1 AND h >= '2025-06-01' AND h < '2025-06-08';

\timing on
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_hourly;
SELECT pg_size_pretty(pg_total_relation_size('mv_hourly'));
```

**Ghi vào writeup:** query trên MV nhanh hơn tính trực tiếp bao nhiêu lần? MV tốn bao nhiêu dung lượng, `REFRESH` mất bao lâu? **Với hệ của bạn, refresh mỗi bao lâu là hợp lý?**

```sql
DROP MATERIALIZED VIEW mv_hourly;
```

---

## Kết ngày

### Hai câu cuối

**A.** Vì sao trước PG13 query kiểu `GROUP BY` nhiều cột có thể **giết server**? Bạn đang chạy PG mấy, và điều đó đổi cách bạn đánh giá rủi ro thế nào?

**B. Áp dụng vào hệ thật:** trong hệ IoT của bạn, dashboard đang tính trung bình theo giờ kiểu nào? Nếu chuyển sang rollup thì tiết kiệm bao nhiêu, và phải chấp nhận độ trễ bao nhiêu?

### Đạt khi

Bạn phân biệt được HashAgg và GroupAgg qua plan, biết `Disk Usage > 0` phải làm gì, và chọn được chiến lược tổng hợp phù hợp cho workload time-series.

**Xong thì gõ `/review-bai`.**
