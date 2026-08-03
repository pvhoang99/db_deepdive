# Day 46 — Capstone 1a: audit lab — dựng hiện trường và chẩn đoán

**Thời lượng:** 90–120 phút (đây là một buổi, không phải 60 phút) · **Cách học:** hôm nay không có lý thuyết mới. Bạn làm việc như đang xử lý sự cố production.

> Capstone chia làm hai ngày: **hôm nay chẩn đoán, mai sửa**. Ranh giới này cố ý — trong đời thật, phần khó không phải sửa mà là **chỉ đúng chỗ bệnh trước khi động vào**. Hôm nay bạn không được phép sửa gì.

## Bối cảnh

Coi lab này là **production**. Bạn vừa được giao: *"DB chậm, tìm và sửa."*

Ràng buộc — giống hệt đời thật:
- **Không được đổi GUC** (`work_mem`, `shared_buffers`, `random_page_cost`...). Chỉ được đổi **index, schema, SQL** — và chỉ từ ngày mai.
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
\o /days/day-46/output.txt
ANALYZE;

-- ghi lại hiện trạng
SELECT st.relname,
       pg_size_pretty(pg_total_relation_size(st.relid)) AS tong,
       pg_size_pretty(pg_relation_size(st.relid))       AS heap,
       pg_size_pretty(pg_indexes_size(st.relid))        AS index,
       pg_size_pretty(pg_relation_size(c.reltoastrelid)) AS toast,
       st.n_live_tup
FROM pg_stat_user_tables st JOIN pg_class c ON c.oid = st.relid
ORDER BY pg_total_relation_size(st.relid) DESC;

SELECT indexrelname, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes ORDER BY pg_relation_size(indexrelid) DESC;
```

**Ghi vào writeup:** bảng hiện trạng — dung lượng heap / index / TOAST, số index, tổng.

---

## §2. Workload

### Làm ngay

Tạo `days/day-46/workload.sql` mô phỏng ứng dụng IoT thật. Phải có đủ các mẫu sau (tự viết, tối thiểu 25 câu):

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
time make run F=days/day-46/workload.sql
```

**Ghi vào writeup:** chạy **hai lần** và ghi cả hai — lần 1 cache lạnh, lần 2 cache nóng. Con số nào bạn dùng làm baseline để so với ngày mai, và vì sao (nhắc lại Day 03)?

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
       temp_blks_written                    AS temp_w,
       pg_size_pretty(wal_bytes::bigint)    AS wal
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%'
ORDER BY total_exec_time DESC
LIMIT 12;
```

Thêm góc nhìn của Day 40 — chạy workload lần nữa và lấy mẫu wait event song song:

```
S1:  CALL sample_waits(30);            -- procedure của Day 40 §2
S2:  make run F=days/day-46/workload.sql
```

**Ghi vào writeup:**
- bảng top 12 theo `total_exec_time`,
- bảng wait event xếp hạng (hệ đang chờ I/O, lock, hay chạy CPU?),
- **5 query** bạn chọn để tối ưu và **tiêu chí chọn** — không chỉ lấy top 5 theo total; cân nhắc cả mean cao, stddev cao, và cái mà wait event chỉ vào.

---

## §4. Chẩn đoán — với mỗi query

### Làm ngay

Với **mỗi** trong 5 query, đi đủ quy trình đã học:

1. `EXPLAIN (ANALYZE, BUFFERS)` — lấy plan thật
2. Quét **từ lá lên gốc**, tìm node đầu tiên `rows` lệch `actual rows` > 10 lần
3. Kiểm tra `pg_stats` của cột lọc: `n_distinct`, MCV, `correlation`, `last_analyze`
4. Tìm dấu hiệu: `Rows Removed by Filter` lớn, `temp` > 0, `Heap Fetches` cao, `Batches` > 1, `lossy` > 0, `loops` lớn
5. Hai thứ của tuần 9: query có `SELECT *` trên bảng có TOAST không (Day 41)? Nếu chạy qua prepared statement, plan có đổi sau 5 lần không (Day 42)?
6. Ghi chẩn đoán **trước khi** sửa

**Ghi vào writeup — với mỗi query một mục:**

```
### Query N
**SQL:** ...
**Plan trước:** (dán phần quan trọng)
**Node gốc bệnh:** ... (rows đoán X vs thật Y, lệch Z lần)
**Chẩn đoán:** ...
**Cách sửa dự định:** ... (câu lệnh chính xác, có CONCURRENTLY nếu là index)
**Dự đoán cải thiện:** ... (con số: time X→Y ms, buffers A→B)
**Rủi ro của cách sửa:** ... (dung lượng thêm, ghi chậm thêm, lock lúc tạo — Day 43)
```

**Quan trọng:** dự đoán ở đây là bài kiểm tra chính của capstone. Ngày mai bạn sẽ so dự đoán với kết quả thật, và **độ chính xác của dự đoán** mới là thước đo bạn hiểu tới đâu — không phải mức cải thiện.

---

## Kết ngày

### Nộp bài

| File | Nội dung |
|---|---|
| `workload.sql` | workload bạn viết |
| `lab.sql` | mọi lệnh bạn chạy (hôm nay chỉ đọc, không sửa) |
| `output.txt` | output thật |
| `writeup.md` | hiện trạng + baseline + top query + 5 mục chẩn đoán có dự đoán |

### Đạt khi

- Workload đủ 10 nhóm, chạy được, baseline lặp lại được
- Bảng xếp hạng có cả `total`, `mean`, `stddev`, `temp`, `wal`
- Mỗi chẩn đoán chỉ đúng **node gốc bệnh**, không phải mô tả chung chung
- Mỗi query có **dự đoán bằng số** viết ra **trước** khi sửa
- Bạn chưa tạo index nào

**Xong thì gõ `/review-bai`.** Tôi sẽ chấm phần chẩn đoán và giữ lại dự đoán của bạn để đối chiếu ngày mai.
