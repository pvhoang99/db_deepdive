# Day 14 — Cost model: mấy con số GUC thực sự làm gì

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

```sql
\timing on
\o /days/day-14/output.txt
ANALYZE;
```

---

## §0. Đoán trước

1. Với server SSD, `random_page_cost` nên để bao nhiêu?
2. Nếu hạ `random_page_cost` từ 4.0 xuống 1.1, điểm hoà vốn seq-vs-index dịch theo hướng nào?
3. Bạn có tự tính được cost của một Seq Scan chính xác tới 1% không?

---

## §1. Năm hằng số cost

### Lý thuyết

| GUC | Mặc định | Đơn vị |
|---|---|---|
| `seq_page_cost` | 1.0 | đọc 1 page tuần tự — **mốc quy chiếu** |
| `random_page_cost` | 4.0 | đọc 1 page ngẫu nhiên |
| `cpu_tuple_cost` | 0.01 | xử lý 1 dòng ở executor |
| `cpu_index_tuple_cost` | 0.005 | xử lý 1 entry index |
| `cpu_operator_cost` | 0.0025 | thi hành 1 toán tử/hàm |

Mọi cost trong plan đều là tổ hợp tuyến tính của năm số này.

**`random_page_cost = 4.0` là di sản của ổ đĩa cơ** (seek ~5ms vs đọc tuần tự). Trên NVMe hiện đại tỷ lệ thật gần **1.0–1.2**; trên SSD SATA khoảng 1.5–2.0.

Để nguyên 4.0 trên SSD khiến planner **sợ index quá mức** → chọn seq scan trong những ca index đáng ra thắng. Đây là một trong hai GUC đáng chỉnh nhất khi lên production (cái kia là `effective_cache_size`).

### Làm ngay

```sql
SELECT name, setting, unit, boot_val, source
FROM pg_settings
WHERE name IN ('seq_page_cost','random_page_cost','cpu_tuple_cost',
               'cpu_index_tuple_cost','cpu_operator_cost',
               'effective_cache_size','shared_buffers','work_mem');
```

**Ghi vào writeup:** cột `source` cho biết giá trị đến từ đâu (default / configuration file / command line). Lab đang đặt khác mặc định những gì?

---

## §2. Tự tính cost của Seq Scan

### Lý thuyết

```
cost_seqscan = relpages × seq_page_cost
             + reltuples × cpu_tuple_cost
             + reltuples × cpu_operator_cost × số_điều_kiện
```

Với `SELECT count(*) FROM ts_kv WHERE device_id = 42`:
- 1 điều kiện `WHERE` → 1 toán tử
- Node `Aggregate` phía trên cộng thêm `số_dòng_ra × cpu_operator_cost`

### Làm ngay

```sql
SET max_parallel_workers_per_gather = 0;   -- tắt song song cho dễ tính

SELECT relpages, reltuples,
       relpages * 1.0                    AS phan_io,
       reltuples * 0.01                  AS phan_cpu_tuple,
       reltuples * 0.0025                AS phan_cpu_op,
       relpages * 1.0 + reltuples * 0.01 + reltuples * 0.0025 AS cost_toi_tinh
FROM pg_class WHERE relname = 'ts_kv';

EXPLAIN SELECT count(*) FROM ts_kv WHERE device_id = 42;
```

**Ghi vào writeup:** cost bạn tính vs cost planner in. Lệch bao nhiêu %? Phần lệch đến từ node nào?

Kiểm chứng bằng cách đổi hằng số:
```sql
SET seq_page_cost = 2.0;
EXPLAIN SELECT count(*) FROM ts_kv WHERE device_id = 42;   -- cost tăng đúng relpages × 1.0?
RESET seq_page_cost;
```

---

## §3. Cost của Index Scan — nơi `correlation` chen vào

### Lý thuyết

Công thức phức tạp hơn nhiều, nhưng ý chính:

```
cost_indexscan ≈ chi_phí_đi_index
               + số_dòng_khớp × cpu_tuple_cost
               + số_PAGE_HEAP_phải_đọc × page_cost
```

Chỗ tinh tế nằm ở `page_cost` và `số page heap`:

- Nếu **`correlation` ≈ 1**: dòng cần nằm liền nhau → số page ≈ `số_dòng ÷ dòng_mỗi_page`, và đọc gần như **tuần tự** → dùng `seq_page_cost`
- Nếu **`correlation` ≈ 0**: dòng rải khắp → số page ≈ `số_dòng` (mỗi dòng một page riêng), và đọc **ngẫu nhiên** → dùng `random_page_cost`

Postgres nội suy giữa hai cực này theo `correlation`. Đây chính là cơ chế toán học đằng sau hiện tượng bạn đo được ở Day 04.

Ngoài ra `effective_cache_size` tham gia: nếu bảng nhỏ hơn cache, Postgres giảm số page nó cho là phải đọc thật (mô hình Mackert-Lohman).

### Làm ngay

```sql
CREATE INDEX IF NOT EXISTS idx_tskv_ts  ON ts_kv(ts);
CREATE INDEX IF NOT EXISTS idx_tskv_dev ON ts_kv(device_id);
ANALYZE ts_kv;

SET enable_seqscan = off; SET enable_bitmapscan = off;
EXPLAIN SELECT count(*) FROM ts_kv WHERE ts >= '2025-06-01' AND ts < '2025-06-02';     -- corr = 1
EXPLAIN SELECT count(*) FROM ts_kv WHERE device_id = 42;                               -- corr ≈ 0
RESET ALL;
```

**Ghi vào writeup:** hai query lấy số dòng tương đương nhau, nhưng cost chênh bao nhiêu lần? Giải thích bằng `correlation`.

---

## §4. Lật plan bằng `random_page_cost`

### Làm ngay

Tìm điểm hoà vốn rồi dịch nó:

```sql
-- tìm khoảng thời gian mà planner đang chọn seq scan
EXPLAIN SELECT count(*) FROM ts_kv WHERE ts >= '2025-06-01' AND ts < '2025-06-20';

-- hạ random_page_cost như server SSD
SET random_page_cost = 1.1;
EXPLAIN SELECT count(*) FROM ts_kv WHERE ts >= '2025-06-01' AND ts < '2025-06-20';
EXPLAIN SELECT count(*) FROM ts_kv WHERE device_id = 42;
RESET random_page_cost;
```

Quét nhiều mức để tìm điểm lật:
```sql
SET random_page_cost = 4.0; EXPLAIN SELECT count(*) FROM ts_kv WHERE device_id = 42;
SET random_page_cost = 2.0; EXPLAIN SELECT count(*) FROM ts_kv WHERE device_id = 42;
SET random_page_cost = 1.5; EXPLAIN SELECT count(*) FROM ts_kv WHERE device_id = 42;
SET random_page_cost = 1.1; EXPLAIN SELECT count(*) FROM ts_kv WHERE device_id = 42;
RESET random_page_cost;
```

**Ghi vào writeup:** ở giá trị nào plan lật? Với mỗi plan, chạy `EXPLAIN ANALYZE` để xem plan nào **thật sự** nhanh hơn — planner đúng hay sai ở mặc định 4.0?

---

## §5. `effective_cache_size` — lời khai với planner

### Lý thuyết

Không cấp phát RAM. Chỉ là con số bạn khai: "tổng cache khả dụng (shared_buffers + OS page cache) khoảng chừng này".

Planner dùng nó để ước lượng: khi index scan đọc lại cùng một page nhiều lần, page đó có còn trong cache không. Khai cao → planner tin index scan rẻ hơn → thiên về index.

Quy tắc đặt trên production: **50–75% RAM của máy**. Đây là GUC an toàn nhất để chỉnh — nó không tiêu tốn gì cả.

### Làm ngay

```sql
SHOW effective_cache_size;

SET effective_cache_size = '128MB';
EXPLAIN SELECT count(*) FROM ts_kv WHERE device_id = 42;
SET effective_cache_size = '8GB';
EXPLAIN SELECT count(*) FROM ts_kv WHERE device_id = 42;
RESET effective_cache_size;
```

**Ghi vào writeup:** cost đổi thế nào giữa hai mức? Plan có lật không?

---

## §6. Song song hoá và cost

### Lý thuyết

| GUC | Ý nghĩa |
|---|---|
| `max_parallel_workers_per_gather` | tối đa worker mỗi node Gather (mặc định 2) |
| `min_parallel_table_scan_size` | bảng nhỏ hơn thì không parallel (mặc định 8MB) |
| `parallel_setup_cost` | chi phí khởi tạo worker (mặc định 1000) — cố tình cao để tránh parallel cho query nhỏ |
| `parallel_tuple_cost` | chi phí chuyển 1 dòng từ worker về leader (0.1) |

`parallel_setup_cost = 1000` rất lớn so với các hằng số khác — đó là cách Postgres nói "chỉ parallel khi query đủ nặng".

Cạm bẫy production: **mỗi worker dùng `work_mem` riêng.** Query parallel 4 worker với hash join có thể dùng `5 × work_mem`.

### Làm ngay

```sql
SET max_parallel_workers_per_gather = 0;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv;
SET max_parallel_workers_per_gather = 2;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv;
SET max_parallel_workers_per_gather = 6;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv;
RESET max_parallel_workers_per_gather;
```

**Ghi vào writeup:** `Workers Planned` vs `Workers Launched` — có khớp không, vì sao? Thời gian giảm có tuyến tính theo số worker không? Ở mức nào thì thêm worker hết tác dụng?

---

## §7. Chỉnh GUC cho server thật của bạn

### Lý thuyết — checklist khởi điểm

| GUC | Công thức khởi điểm | Ghi chú |
|---|---|---|
| `shared_buffers` | 25% RAM | trên 8-16GB thì lợi ích giảm dần |
| `effective_cache_size` | 50–75% RAM | chỉ là con số khai báo |
| `random_page_cost` | 1.1 (NVMe), 1.5 (SSD), 4.0 (HDD) | **đo trước khi tin** |
| `work_mem` | RAM ÷ (max_connections × 2–3) | nhớ: per node, per worker |
| `maintenance_work_mem` | 5–10% RAM, tối đa ~2GB | tăng tốc CREATE INDEX/VACUUM |
| `max_parallel_workers_per_gather` | 2–4 | cao hơn chỉ đáng với OLAP |

Cách đo `random_page_cost` thật cho đĩa của bạn: dùng `fio` với random read 8KB và sequential read, lấy tỷ lệ IOPS.

### Làm ngay

```sql
-- tự tính cấu hình đề xuất cho chính máy này
SELECT
  pg_size_pretty((setting::bigint * 8192)) AS shared_buffers_hien_tai
FROM pg_settings WHERE name = 'shared_buffers';

SHOW max_connections;
SHOW work_mem;
```

**Ghi vào writeup:** với `max_connections=100` và `work_mem=4MB` của lab, worst case bộ nhớ cho work_mem là bao nhiêu? Nếu mỗi query có 3 node sort và parallel 2 worker thì sao?

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B. Áp dụng vào hệ thật:** viết ra cấu hình bạn sẽ đề xuất cho DB production của bạn — RAM bao nhiêu, `shared_buffers` bao nhiêu, `effective_cache_size`, `random_page_cost`, `work_mem`, kèm **lý do và cách bạn sẽ kiểm chứng** từng con số.

### Đạt khi

Bạn tính được cost của Seq Scan bằng tay khớp với planner, và giải thích được `random_page_cost` ảnh hưởng tới lựa chọn plan qua cơ chế nào chứ không chỉ "làm index rẻ hơn".

**Xong thì gõ `/review-bai`.**
