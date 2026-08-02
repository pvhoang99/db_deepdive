# Day 39 — Capstone phần 1: audit toàn bộ lab

**Thời lượng:** 90 phút · **Cách học:** hôm nay không có lý thuyết mới. Bạn làm việc như đang xử lý sự cố production.

## Bối cảnh

Coi lab này là **production**. Bạn vừa được giao: *"DB chậm, tìm và sửa."*

Ràng buộc — giống hệt đời thật:
- **Không được đổi GUC** (`work_mem`, `shared_buffers`, `random_page_cost`...). Chỉ được đổi **index, schema, SQL**.
- Mọi thay đổi phải chứng minh bằng số **trước/sau**.
- Không được xoá dữ liệu.

---

## §1. Chuẩn bị hiện trường

### Làm ngay

Reset về trạng thái sạch, không index thừa:

```bash
make nuke && make up && make seed 1
```

```sql
\timing on
\o /days/day-39/output.txt
ANALYZE;

-- ghi lại hiện trạng
SELECT relname, pg_size_pretty(pg_total_relation_size(relid)) AS tong,
       pg_size_pretty(pg_indexes_size(relid)) AS index, n_live_tup
FROM pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC;

SELECT indexrelname, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes ORDER BY pg_relation_size(indexrelid) DESC;
```

**Ghi vào writeup:** bảng hiện trạng — dung lượng, số index, tổng.

---

## §2. Workload

### Làm ngay

Tạo `days/day-39/workload.sql` mô phỏng ứng dụng IoT thật. Phải có đủ các mẫu sau (tự viết, tối thiểu 25 câu):

| Nhóm | Mẫu | Tần suất mô phỏng |
|---|---|---|
| Dashboard | giá trị mới nhất của N device | rất cao |
| Biểu đồ | chuỗi thời gian 1 device, 1 ngày | cao |
| Danh sách | device theo tenant + trạng thái, có phân trang | cao |
| Alarm | alarm đang mở, sắp theo severity | cao |
| Tìm kiếm | device theo tên (không phân biệt hoa thường) | trung bình |
| Báo cáo | downsample theo giờ, 1 tuần | thấp |
| Tổng hợp | đếm theo region + country | thấp |
| jsonb | lọc device theo `meta` | trung bình |
| Ghi | insert telemetry theo lô | rất cao |
| Ghi | update trạng thái alarm | cao |

Khung mở đầu:
```sql
-- lặp nhiều lần các query nhẹ để mô phỏng tần suất cao
SELECT count(*) FROM (
  SELECT (SELECT dbl_v FROM ts_kv WHERE device_id = (1 + g % 300) ORDER BY ts DESC LIMIT 1)
  FROM generate_series(1, 400) g
) s;

SELECT count(*) FROM (
  SELECT (SELECT count(*) FROM ts_kv
          WHERE device_id = (1 + g % 100) AND key_id = 1
            AND ts >= '2025-06-01' AND ts < '2025-06-02')
  FROM generate_series(1, 100) g
) s;

-- ... tự viết tiếp cho đủ các nhóm trên
```

Chạy:
```sql
SELECT pg_stat_statements_reset();
```
```bash
time make run days/day-39/workload.sql
```

**Ghi vào writeup:** tổng thời gian chạy workload lần đầu (baseline).

---

## §3. Xếp hạng — chọn mục tiêu

### Làm ngay

```sql
SELECT substring(query, 1, 90) AS q,
       calls,
       round(total_exec_time::numeric, 0)   AS total_ms,
       round(mean_exec_time::numeric, 2)    AS mean_ms,
       round(stddev_exec_time::numeric, 2)  AS stddev,
       round(100 * total_exec_time / sum(total_exec_time) OVER (), 1) AS pct,
       shared_blks_hit + shared_blks_read   AS bufs,
       temp_blks_written                    AS temp_w
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%'
ORDER BY total_exec_time DESC
LIMIT 12;
```

**Ghi vào writeup:** bảng top 12. Chọn **5 query** để tối ưu — và **giải thích tiêu chí chọn** (không chỉ lấy top 5 theo total; cân nhắc cả mean cao và stddev cao).

---

## §4. Chẩn đoán — với mỗi query

### Làm ngay

Với **mỗi** trong 5 query, đi đủ quy trình đã học:

1. `EXPLAIN (ANALYZE, BUFFERS)` — lấy plan thật
2. Quét **từ lá lên gốc**, tìm node đầu tiên `rows` lệch `actual rows` > 10 lần
3. Kiểm tra `pg_stats` của cột lọc: `n_distinct`, MCV, `correlation`, `last_analyze`
4. Tìm dấu hiệu: `Rows Removed by Filter` lớn, `temp` > 0, `Heap Fetches` cao, `Batches` > 1, `lossy` > 0, `loops` lớn
5. Ghi chẩn đoán **trước khi** sửa

**Ghi vào writeup — với mỗi query một mục:**

```
### Query N
**SQL:** ...
**Plan trước:** (dán phần quan trọng)
**Node gốc bệnh:** ... (rows đoán X vs thật Y, lệch Z lần)
**Chẩn đoán:** ...
**Cách sửa dự định:** ...
**Dự đoán cải thiện:** ...
```

---

## §5. Sửa

### Làm ngay

Áp dụng sửa. Các công cụ được phép:

| Công cụ | Học ở |
|---|---|
| Composite index đúng thứ tự | Day 07 |
| `INCLUDE` cho index-only scan | Day 08 |
| Partial index | Day 09 |
| Expression index | Day 09 |
| `ALTER TABLE ... SET STATISTICS` | Day 11 |
| `CREATE STATISTICS` cho cột phụ thuộc | Day 13 |
| Viết lại SQL (`LATERAL`, `DISTINCT ON`, `NOT EXISTS`) | Day 20 |
| `fillfactor` | Day 24 |
| BRIN | Day 31 |
| GIN / `jsonb_path_ops` | Day 34 |
| `VACUUM`/`ANALYZE` đúng lúc | Day 22-23 |

**Nguyên tắc:** sửa **từng cái một**, đo lại sau mỗi lần. Đừng thêm 5 index rồi mới đo — bạn sẽ không biết cái nào có tác dụng.

Sau mỗi lần sửa:
```sql
EXPLAIN (ANALYZE, BUFFERS) <query>;   -- chạy 3 lần, lấy số ổn định
```

---

## §6. Đo lại toàn bộ

### Làm ngay

```sql
SELECT pg_stat_statements_reset();
```
```bash
time make run days/day-39/workload.sql
```
```sql
SELECT substring(query, 1, 90) AS q, calls,
       round(total_exec_time::numeric, 0) AS total_ms,
       round(100 * total_exec_time / sum(total_exec_time) OVER (), 1) AS pct,
       shared_blks_hit + shared_blks_read AS bufs
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%'
ORDER BY total_exec_time DESC LIMIT 12;
```

**Ghi vào writeup — bảng before/after cho cả 5 query:**

| Query | time trước | time sau | buffers trước | buffers sau | pct trước | pct sau | node plan chính trước → sau |
|---|---|---|---|---|---|---|---|

Và tổng: **thời gian chạy toàn bộ workload trước/sau — cải thiện bao nhiêu %?**

---

## §7. Cái giá phải trả

### Lý thuyết

Mọi index đều có giá (Day 10). Một audit tốt phải báo cáo cả chi phí, không chỉ lợi ích.

### Làm ngay

```sql
-- dung lượng index tăng bao nhiêu
SELECT relname, pg_size_pretty(pg_indexes_size(relid)) AS index_size,
       pg_size_pretty(pg_total_relation_size(relid)) AS tong
FROM pg_stat_user_tables ORDER BY pg_indexes_size(relid) DESC;

-- index nào không được dùng trong workload
SELECT indexrelname, idx_scan, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes ORDER BY idx_scan, pg_relation_size(indexrelid) DESC;
```

Đo chi phí ghi:
```sql
CREATE TABLE t_w (LIKE ts_kv);
\timing on
INSERT INTO t_w SELECT * FROM ts_kv LIMIT 200000;   -- không index
DROP TABLE t_w;

\timing on
INSERT INTO ts_kv SELECT device_id, key_id, ts + interval '95 days', dbl_v, bool_v, str_v
FROM ts_kv LIMIT 200000;                             -- với đầy đủ index bạn vừa tạo
DELETE FROM ts_kv WHERE ts > '2025-08-01';
VACUUM ts_kv;
```

**Ghi vào writeup:**
- Tổng dung lượng index trước/sau audit — tăng bao nhiêu GB, bao nhiêu %?
- Có index nào bạn tạo mà `idx_scan = 0` không? Nếu có thì **xoá đi** và ghi lại.
- Insert chậm hơn bao nhiêu % sau khi thêm index?
- **Kết luận: đánh đổi này có đáng không?**

---

## Kết ngày

### Nộp bài

| File | Nội dung |
|---|---|
| `workload.sql` | workload bạn viết |
| `lab.sql` | mọi DDL/DML bạn chạy |
| `output.txt` | output thật |
| `writeup.md` | báo cáo audit đầy đủ theo các mục trên |

### Đạt khi

- Bảng before/after đầy đủ cho cả 5 query, có time + buffers + node plan
- Mỗi chẩn đoán chỉ đúng **node gốc bệnh**, không phải mô tả chung chung
- Tổng thời gian workload giảm rõ rệt và bạn định lượng được
- Bạn báo cáo **cả chi phí** (dung lượng, chậm ghi), không chỉ lợi ích
- Không dùng GUC nào để "gian lận"

**Xong thì gõ `/review-bai`.** Tôi sẽ chạy lại toàn bộ workload để kiểm chứng con số của bạn.

---

Ngày mai: mang đúng quy trình này sang **hệ production thật của bạn**.
