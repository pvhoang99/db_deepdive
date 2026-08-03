# Day 47 — Capstone 1b: sửa, đo lại, và trả giá

**Thời lượng:** 90–120 phút · **Điều kiện:** đã xong Day 46 (workload, baseline, 5 chẩn đoán có dự đoán).

> Hôm nay bạn sửa. Nhưng luật quan trọng nhất không phải "sửa cho nhanh" — mà là **mỗi thay đổi phải được đo riêng**, và cuối ngày phải báo cáo **cả cái giá phải trả**. Một audit chỉ báo lợi ích là một audit không đáng tin.

## Chuẩn bị

```sql
\timing on
\o /days/day-47/output.txt
```

Mở lại `days/day-46/writeup.md` — 5 dự đoán của bạn nằm đó. Đừng sửa chúng.

---

## §1. Sửa — từng cái một

### Làm ngay

Công cụ được phép:

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
| Partitioning | Day 32–33 |
| GIN / `jsonb_path_ops` | Day 34 |
| Tách cột ra khỏi jsonb, `SET STORAGE`, bỏ `SELECT *` | Day 41 |
| `VACUUM`/`ANALYZE` đúng lúc | Day 22–23 |

**Vẫn cấm:** đổi GUC.

**Nguyên tắc bắt buộc:** sửa **một** thứ → đo ngay → ghi số → mới sang cái tiếp. Đừng thêm 5 index rồi mới đo; bạn sẽ không biết cái nào có tác dụng, và sẽ giữ lại index vô dụng.

Mọi index tạo bằng `CONCURRENTLY` — vì đây là "production" (Day 43):
```sql
CREATE INDEX CONCURRENTLY ix_... ON ...;
```

Sau mỗi lần sửa:
```sql
EXPLAIN (ANALYZE, BUFFERS) <query>;   -- chạy 3 lần, lấy số ổn định
```

**Ghi vào writeup — bảng nhật ký sửa, mỗi dòng một thay đổi:**

| # | Thay đổi | Query bị ảnh hưởng | time trước → sau | buffers trước → sau | thời gian tạo | dung lượng thêm |
|---|---|---|---|---|---|---|

---

## §2. Dự đoán vs thực tế — phần chấm điểm thật

### Làm ngay

Với mỗi query trong 5 query, điền bảng này:

| Query | Dự đoán (Day 46) | Thực tế | Sai lệch | Bạn nghĩ nhầm ở đâu |
|---|---|---|---|---|

**Ghi vào writeup:** bạn dự đoán đúng mấy trên 5 (sai số dưới 2 lần coi là đúng)? Với những cái sai, phân loại nguyên nhân:
- chẩn đoán sai node gốc bệnh,
- chẩn đoán đúng nhưng đánh giá sai mức cải thiện,
- xuất hiện nút thắt mới sau khi sửa nút thắt cũ (**đây là trường hợp thú vị nhất — mô tả kỹ**).

---

## §3. Đo lại toàn bộ

### Làm ngay

```sql
SELECT pg_stat_statements_reset();
```
```bash
time make run F=days/day-46/workload.sql
```
```sql
SELECT substring(query, 1, 90) AS q, calls,
       round(total_exec_time::numeric, 0) AS total_ms,
       round(100 * total_exec_time / sum(total_exec_time) OVER (), 1) AS pct,
       shared_blks_hit + shared_blks_read AS bufs,
       temp_blks_written AS temp_w
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%'
ORDER BY total_exec_time DESC LIMIT 12;
```

Và lấy lại mẫu wait event (Day 40) để xem **chân dung hệ** đã đổi chưa:
```
S1:  CALL sample_waits(30);
S2:  make run F=days/day-46/workload.sql
```

**Ghi vào writeup:**

| Query | time trước | time sau | buffers trước | buffers sau | pct trước | pct sau | node plan chính trước → sau |
|---|---|---|---|---|---|---|---|

Cộng thêm:
- Tổng thời gian chạy workload trước/sau — cải thiện bao nhiêu %?
- Bảng xếp hạng wait event trước/sau — tỷ lệ `IO` giảm bao nhiêu, có nhóm nào **tăng** không?
- **Top 5 sau khi sửa có còn là top 5 cũ không?** Nếu đổi thì thứ tự mới nói lên điều gì?

---

## §4. Cái giá phải trả

### Lý thuyết

Mọi index đều có giá (Day 10, Day 24). Một audit tốt phải báo cáo cả chi phí. Ba loại chi phí phải đo:

1. **Dung lượng** — index + TOAST + bloat mới sinh ra.
2. **Tốc độ ghi** — mỗi index thêm vào làm chậm INSERT/UPDATE và giảm tỷ lệ HOT.
3. **WAL** — nhiều index → nhiều WAL → replica lag và slot (Day 37–39).

### Làm ngay

```sql
-- dung lượng
SELECT relname, pg_size_pretty(pg_indexes_size(relid)) AS index_size,
       pg_size_pretty(pg_total_relation_size(relid)) AS tong
FROM pg_stat_user_tables ORDER BY pg_indexes_size(relid) DESC;

-- index nào không được dùng trong workload
SELECT indexrelname, idx_scan, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes ORDER BY idx_scan, pg_relation_size(indexrelid) DESC;
```

Đo chi phí ghi và WAL:
```sql
CHECKPOINT;
SELECT pg_stat_statements_reset();

CREATE TABLE t_w (LIKE ts_kv);
INSERT INTO t_w SELECT * FROM ts_kv LIMIT 200000;   -- không index

INSERT INTO ts_kv SELECT device_id, key_id, ts + interval '95 days', dbl_v, bool_v, str_v
FROM ts_kv LIMIT 200000;                             -- với đầy đủ index bạn vừa tạo

SELECT substring(query,1,45) AS q, round(total_exec_time::numeric,0) AS ms,
       pg_size_pretty(wal_bytes::bigint) AS wal, wal_records, wal_fpi
FROM pg_stat_statements WHERE query LIKE 'INSERT%' ORDER BY total_exec_time DESC;

DROP TABLE t_w;
DELETE FROM ts_kv WHERE ts > '2025-08-01';
VACUUM ts_kv;
```

Và tỷ lệ HOT (Day 24):
```sql
SELECT relname, n_tup_upd, n_tup_hot_upd,
       round(n_tup_hot_upd::numeric/nullif(n_tup_upd,0),3) AS ty_le_hot,
       (SELECT count(*) FROM pg_index WHERE indrelid=relid) AS so_index
FROM pg_stat_user_tables WHERE n_tup_upd > 0 ORDER BY ty_le_hot NULLS LAST;
```

**Ghi vào writeup:**
- Tổng dung lượng index trước/sau audit — tăng bao nhiêu GB, bao nhiêu %?
- Có index nào bạn tạo mà `idx_scan = 0` không? Nếu có thì **xoá đi** và ghi lại (đây là điểm cộng, không phải điểm trừ).
- Insert chậm hơn bao nhiêu %? WAL sinh ra nhiều hơn bao nhiêu %?
- Tỷ lệ HOT của bảng bị thêm index có tụt không?
- **Kết luận: đánh đổi này có đáng không** — trả lời bằng số, cho từng thay đổi, không phải cho cả gói.

---

## §5. Triển khai như thật

### Làm ngay

Viết `days/day-47/rollout.md` — coi như bạn phải đưa các thay đổi này lên production thật:

| # | Thay đổi | Lock lúc chạy | Thời gian ước tính ở kích thước prod | Rollback | Chạy được giờ cao điểm? | Cách kiểm chứng sau khi lên |
|---|---|---|---|---|---|---|

Dùng đúng phân loại của Day 43–44. Với mỗi dòng phải có:
- câu lệnh **chính xác** sẽ chạy (có `CONCURRENTLY`, có `lock_timeout`),
- điều kiện tiên quyết cần kiểm tra trước (transaction dài? replica lag? đĩa trống?),
- chỉ số để xác nhận nó có tác dụng sau 24h.

---

## Kết ngày

### Nộp bài

| File | Nội dung |
|---|---|
| `lab.sql` | mọi DDL/DML bạn chạy |
| `output.txt` | output thật |
| `rollout.md` | kế hoạch triển khai |
| `writeup.md` | nhật ký sửa + dự đoán vs thực tế + before/after + cái giá |

### Đạt khi

- Bảng before/after đầy đủ cho cả 5 query, có time + buffers + node plan
- Bảng **dự đoán vs thực tế** đầy đủ, và bạn giải thích được từng chỗ sai
- Tổng thời gian workload giảm rõ rệt và bạn định lượng được
- Bạn báo cáo **cả chi phí** (dung lượng, chậm ghi, WAL, HOT), không chỉ lợi ích
- Bạn đã xoá index mình tạo ra mà không được dùng
- Không dùng GUC nào để "gian lận"

**Xong thì gõ `/review-bai`.** Tôi sẽ chạy lại toàn bộ workload để kiểm chứng con số của bạn.

---

Ngày mai: mang đúng quy trình này sang **hệ production thật của bạn**.
