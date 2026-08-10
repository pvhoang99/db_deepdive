# Day 14 — Lời giải: Cost model — mấy con số GUC thực sự làm gì

> Bài chữa. Đo thật trên lab `SCALE=1`.

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án |
|---|---|---|
| 1 | `random_page_cost` cho SSD? | **1.1 (NVMe)**, 1.5–2.0 (SATA SSD). Mặc định 4.0 là số của **ổ đĩa cơ** |
| 2 | Hạ 4.0 → 1.1 thì điểm hoà vốn dịch hướng nào? | **Về phía index** — index scan rẻ đi, thắng ở selectivity cao hơn |
| 3 | Tính được cost Seq Scan chính xác tới 1 %? | **Chính xác tới 0,005 %** — xem §2 |

---

## §1. Năm hằng số cost

```
         name         | setting | boot_val |    source
----------------------+---------+----------+--------------
 seq_page_cost        | 1       |        1 | default
 random_page_cost     | 4       |        4 | default
 cpu_tuple_cost       | 0.01    |     0.01 | default
 cpu_index_tuple_cost | 0.005   |    0.005 | default
 cpu_operator_cost    | 0.0025  |   0.0025 | default
 effective_cache_size | 131072  |   524288 | command line   <- 1GB (mặc định 4GB)
 shared_buffers       | 32768   |    16384 | command line   <- 256MB (mặc định 128MB)
 work_mem             | 4096    |     4096 | command line   <- 4MB
 max_connections      | 100     |      100 | command line
```

Cột `source` là thứ nên nhìn đầu tiên khi debug: nó cho biết giá trị đến từ **default**, **configuration file**, hay **command line**. Lab đặt khác mặc định 4 thứ, và **`effective_cache_size` đang bị đặt THẤP hơn mặc định** (1 GB vs 4 GB) — cố ý, để planner bảo thủ hơn với index.

Mọi cost trong plan đều là **tổ hợp tuyến tính** của năm hằng số đầu.

---

## §2. Tự tính cost của Seq Scan — khớp tuyệt đối

```
 relpages | reltuples  | phần I/O | phần cpu_tuple | phần cpu_op | cost tôi tính
----------+------------+----------+----------------+-------------+---------------
    37698 | 5.001034e6 |  37698,0 |      50.010,34 |   12.502,59 |   100.210,925
```

```
EXPLAIN SELECT count(*) FROM ts_kv WHERE device_id = 42;
->  Seq Scan on ts_kv  (cost=0.00..100210.93 rows=2334 width=0)
```

| | |
|---|---|
| Tôi tính | **100.210,925** |
| Planner in | **100.210,93** |
| **Lệch** | **0,005 %** (chỉ do làm tròn) |

Công thức:
```
cost = relpages × seq_page_cost
     + reltuples × cpu_tuple_cost
     + reltuples × cpu_operator_cost × số_điều_kiện
     = 37.698 × 1,0 + 5.001.034 × 0,01 + 5.001.034 × 0,0025 × 1
```

### Kiểm chứng từng thành phần

**Bỏ `WHERE` đi:**
```
EXPLAIN SELECT count(*) FROM ts_kv;
->  Seq Scan  (cost=0.00..87708.34)
```
```
100.210,93 − 87.708,34 = 12.502,59 = đúng phần cpu_operator ✓
```

**Đổi `seq_page_cost` từ 1.0 lên 2.0:**
```
cost: 100.210,93 -> 137.908,92
chênh: 37.697,99 = đúng relpages ✓
```

**Cost model hoàn toàn minh bạch và tính tay được.** Đây là điều đáng làm ít nhất một lần — sau đó anh sẽ không bao giờ coi `cost` là con số ma thuật nữa.

Node `Aggregate` phía trên cộng thêm `5.001.034 × 0,0025 / …` — chênh 5,83 giữa 100.216,76 và 100.210,93, đúng bằng `2.334 dòng ra × 0,0025` cho việc gom + `1 × 0,01`.

---

## §3. Cost của Index Scan — nơi `correlation` chen vào

Hai query, ép cùng dùng Index Scan:

| | `ts` (corr = **1,000**) | `device_id = 1` (corr = **−0,004**) |
|---|---|---|
| số dòng | 55.563 | **107.947** (nhiều gấp 1,94 lần) |
| **cost Index Scan** | **2.163,05** | **153.087,93** |
| **cost mỗi dòng** | **0,039** | **1,418** |

**Cost mỗi dòng chênh 36,4 lần.** Dù `device_id` chỉ lấy nhiều gấp 1,94 lần số dòng, tổng cost đắt hơn **70,8 lần**.

### Cơ chế

```
cost_indexscan ≈ chi_phí_đi_index
               + số_dòng × cpu_tuple_cost
               + số_PAGE_HEAP × page_cost
```

Hai biến bị `correlation` chi phối:

| | corr ≈ 1 | corr ≈ 0 |
|---|---|---|
| **số page heap** | `số_dòng ÷ dòng_mỗi_page` = 55.563/135 ≈ **412** | ≈ `số_dòng` (mỗi dòng một page riêng) = **107.947** |
| **page_cost dùng** | `seq_page_cost = 1,0` (đọc gần tuần tự) | `random_page_cost = 4,0` |

Postgres **nội suy** giữa hai cực này theo `correlation` (hàm `index_pages_fetched()` + mô hình Mackert–Lohman).

Kiểm chứng thô: `107.947 × 4,0 / 3` ≈ 143.929, cộng phần CPU ≈ **153.088** ✓ khớp con số planner in.

> **Đây là cơ chế toán học đằng sau hiện tượng đo được ở Day 04: điểm hoà vốn của `ts` là 33 % bảng còn `device_id` không bao giờ dùng được Index Scan thuần.** Không phải planner "thiên vị", mà là công thức phản ánh đúng vật lý.

---

## §4. Lật plan bằng `random_page_cost`

### ⚠️ Kết quả bất ngờ: plan KHÔNG lật trên `device_id`

Quét `random_page_cost` từ 4.0 xuống 1.1 cho `WHERE device_id = 1`:

| `random_page_cost` | Plan | total cost |
|---|---|---|
| 4.0 | Bitmap Heap Scan | 40.570,51 |
| 2.0 | Bitmap Heap Scan | 40.378,51 |
| 1.5 | Bitmap Heap Scan | 40.330,51 |
| 1.1 | Bitmap Heap Scan | 40.292,11 |

**Plan không đổi, cost chỉ giảm 0,7 %.** Vì sao?

Vì **Bitmap Heap Scan đã tự giải quyết vấn đề random I/O rồi.** Nó gom TID, sắp theo thứ tự page, rồi đọc gần tuần tự — nên `random_page_cost` gần như không tham gia vào cost của nó. Chỉ có `Bitmap Index Scan` (đọc index) chịu ảnh hưởng, và phần đó chỉ chiếm 1.232/40.570 = 3 % tổng cost.

Và đo thật:

| `random_page_cost` | Execution Time | buffers |
|---|---|---|
| 4.0 | **100,6 ms** | 18.988 hit / 16.070 read |
| 1.1 | 103,9 ms | 17.186 hit / 17.869 read |

Không khác nhau (chênh 3 % là nhiễu — Day 03 §4 đo được nhiễu 17 %).

> **Bài học: `random_page_cost` KHÔNG ảnh hưởng tới Bitmap Heap Scan.** Nó chỉ ảnh hưởng tới **Index Scan thuần**. Nếu plan của anh đang là bitmap, chỉnh `random_page_cost` là vô ích.

### Nơi nó thật sự có tác dụng — Index Scan thuần

Ép bỏ bitmap và seq scan, cùng query `device_id = 1`:

| `random_page_cost` | cost Index Scan | Giảm so với 4.0 |
|---|---|---|
| **4.0** | **153.087,93** | — |
| **2.0** | **77.501,14** | **−49,4 %** |
| **1.1** | **43.487,09** | **−71,6 %** |

**Cost giảm gần tuyến tính theo `random_page_cost`** — đúng như công thức §3 dự đoán (phần page heap chiếm ~94 % tổng cost).

Và ca lật thật trên cột có correlation cao:

| | `ts` khoảng 20 ngày (1.118.480 dòng = **22 %** bảng) |
|---|---|
| rpc = 4.0 | Index Scan, cost **43.312,03** |
| rpc = 1.1 | Index Scan, cost **34.240,83** (−21 %) |

Ở đây cost Seq Scan là **87.708** — nên Index Scan thắng ở **cả hai** mức. Nhưng khoảng cách nới rộng từ 2,0 lần lên 2,6 lần, nghĩa là **điểm hoà vốn dịch từ ~33 % lên ~43 % bảng**.

### Kết luận thực dụng

| Tình huống | Chỉnh `random_page_cost` có giúp? |
|---|---|
| Plan đang là **Index Scan** | ✅ **Rất nhiều** — cost giảm tới 71,6 % |
| Plan đang là **Bitmap Heap Scan** | ❌ Gần như không (0,7 %) |
| Plan đang là **Seq Scan** và anh muốn nó dùng index | ✅ có thể lật, nhưng phải là index scan thuần |

---

## §5. `effective_cache_size` — cùng câu chuyện

| `effective_cache_size` | Plan **bitmap** (planner tự chọn) | Plan **Index Scan** (bị ép) |
|---|---|---|
| 128 MB | cost **40.570,51** | cost **283.775,25** |
| 8 GB | cost **40.570,51** *(y hệt)* | cost **153.361,35** |
| **Chênh** | **0 %** | **−46 %** |

Lại đúng cùng kết luận: **`effective_cache_size` chỉ ảnh hưởng Index Scan, không ảnh hưởng Bitmap Heap Scan.**

### Cơ chế

`effective_cache_size` **không cấp phát một byte RAM nào**. Nó là lời khai: *"tổng cache khả dụng (shared_buffers + OS page cache) khoảng chừng này"*.

Planner dùng nó trong mô hình **Mackert–Lohman**: khi Index Scan chạm cùng một page nhiều lần, page thứ hai trở đi có còn trong cache không? Khai cao → tin là còn → tính ít page read hơn → index rẻ hơn.

Tăng 128 MB → 8 GB (64 lần) làm cost Index Scan giảm **46 %**.

> **Đây là GUC an toàn nhất để chỉnh — nó không tiêu tốn gì cả, chỉ đổi cách planner suy nghĩ.** Đặt quá thấp (như lab: 1 GB) khiến planner sợ index quá mức.

Quy tắc: **50–75 % RAM của máy.** Máy 64 GB → `effective_cache_size = '48GB'`.

---

## §6. Song song hoá và cost

| `max_parallel_workers_per_gather` | Workers Planned | **Workers Launched** | **Execution Time** | Tăng tốc |
|---|---|---|---|---|
| **0** | — | — | **480,3 ms** | 1,00× |
| **2** | 2 | **2** | **174,4 ms** | **2,75×** |
| **6** | **4** | **4** | **128,1 ms** | **3,75×** |

### Ba điều đọc ra

**1. Đặt 6 nhưng chỉ dùng 4 worker.** `Workers Planned: 4`, không phải 6.

Vì Postgres giới hạn số worker theo **kích thước bảng**:
```
số worker ≈ log₃(relpages / min_parallel_table_scan_size)
```
Bảng 37.698 page ÷ 1.024 page (8 MB) = 36,8 → `log₃(36,8) ≈ 3,3` → 4 worker. Muốn nhiều hơn phải:
```sql
ALTER TABLE ts_kv SET (parallel_workers = 8);
```

**2. `Workers Planned` = `Workers Launched` ở cả hai mức** — tốt. Khi chúng **khác nhau** là dấu hiệu cạn tài nguyên:
```
max_worker_processes  = 8     <- tổng background worker toàn instance
max_parallel_workers  = 8     <- trần cho parallel query
```
Trên production tải cao, nhiều query parallel cùng lúc sẽ tranh nhau 8 slot này. `Workers Launched < Workers Planned` = query chạy chậm hơn plan dự tính, **và planner không biết**.

**Đây là chỉ số nên monitor.**

**3. Tăng tốc KHÔNG tuyến tính:**

| Số tiến trình | Tăng tốc lý tưởng | **Thật** | Hiệu suất |
|---|---|---|---|
| 3 (2 worker + leader) | 3,00× | **2,75×** | 92 % |
| 5 (4 worker + leader) | 5,00× | **3,75×** | **75 %** |

Từ 3 lên 5 tiến trình (+67 %) chỉ nhanh thêm 36 %. Nguyên nhân:
- `parallel_setup_cost = 1000` — phí dựng worker là **hằng số**, không chia được
- `parallel_tuple_cost = 0.1` mỗi dòng chuyển từ worker về leader
- Cạnh tranh băng thông I/O và shared_buffers

Chú ý `buffers` gần như y hệt ở cả 3 mức (~37.700) — **song song không làm giảm lượng công việc, chỉ chia nó ra**.

### ⚠️ Cạm bẫy production: `work_mem` × số worker

**Mỗi parallel worker dùng `work_mem` RIÊNG.** Query có hash join, 4 worker:

```
work_mem × (4 worker + 1 leader) × số node cần bộ nhớ
```

Với `work_mem = 64MB`, 4 worker, 2 node hash → **640 MB cho MỘT query**. Nhân với 20 query đồng thời = 12,8 GB.

Công thức worst case thật sự:
```
RAM = work_mem × max_connections × (max_parallel_workers_per_gather + 1) × số_node_trung_bình
```

---

## §7. Chỉnh GUC cho server thật

### Worst case của lab

`max_connections = 100`, `work_mem = 4MB`:

| Kịch bản | Tính | Kết quả |
|---|---|---|
| 1 node sort, không parallel | 4 MB × 100 | **400 MB** |
| 3 node sort, không parallel | 4 MB × 100 × 3 | **1,2 GB** |
| **3 node sort, parallel 2 worker** | 4 MB × 100 × 3 × **(2+1)** | **3,6 GB** |

Từ "400 MB, chả sao" thành **3,6 GB** chỉ vì bật parallel. Và đó mới là `work_mem = 4MB` — con số cố ý nhỏ của lab.

Với `work_mem = 64MB` (giá trị nhiều người đặt "cho thoáng"): **57,6 GB**. Đủ để OOM mọi server tầm trung.

### Checklist khởi điểm

| GUC | Công thức | Ghi chú từ số đo hôm nay |
|---|---|---|
| `shared_buffers` | **25 % RAM** | trên 16 GB lợi ích giảm dần |
| `effective_cache_size` | **50–75 % RAM** | **an toàn nhất** — không tiêu RAM. Đo được: giảm cost Index Scan 46 % |
| `random_page_cost` | **1.1** NVMe / **1.5** SSD / 4.0 HDD | chỉ ảnh hưởng **Index Scan**, không ảnh hưởng bitmap |
| `work_mem` | `(RAM − shared_buffers − 2GB) ÷ (max_connections × 3 × (parallel+1))` | nhớ nhân với parallel |
| `maintenance_work_mem` | 5–10 % RAM, tối đa ~2 GB | tăng tốc CREATE INDEX / VACUUM |
| `max_parallel_workers_per_gather` | **2–4** | hiệu suất tụt còn 75 % ở 4 worker |
| `max_parallel_workers` | = số core | trần toàn instance |

### Cách đo `random_page_cost` thật cho đĩa của anh

```bash
# random read 8KB
fio --name=rand --rw=randread --bs=8k --size=4G --numjobs=1 \
    --ioengine=libaio --direct=1 --runtime=30 --time_based
# sequential read
fio --name=seq  --rw=read     --bs=8k --size=4G --numjobs=1 \
    --ioengine=libaio --direct=1 --runtime=30 --time_based

# random_page_cost ≈ (IOPS tuần tự) / (IOPS ngẫu nhiên)
```

Trên NVMe hiện đại tỷ lệ này thường **1,0–1,2**. Trên SSD SATA ~1,5–2,0. Trên EBS gp3 ~1,5. Trên HDD ~10–50 (nên 4.0 vốn đã là con số bảo thủ).

### Cấu hình đề xuất — mẫu cho server 64 GB RAM, NVMe, OLTP

```conf
shared_buffers = 16GB                    # 25%
effective_cache_size = 48GB              # 75% — chỉ khai báo
random_page_cost = 1.1                   # NVMe — ĐO bằng fio trước
seq_page_cost = 1.0                      # giữ làm mốc, không đổi
work_mem = 32MB                          # (64-16-2)/(100×3×(2+1)) ≈ 51MB -> lấy 32MB cho an toàn
maintenance_work_mem = 2GB
max_connections = 100                    # dùng pgbouncer thay vì tăng số này (Day 36)
max_parallel_workers_per_gather = 2      # OLTP: 2. OLAP: 4
max_parallel_workers = 16                # = số core
max_worker_processes = 16
```

**Cách kiểm chứng từng con số:**

| GUC | Kiểm chứng |
|---|---|
| `shared_buffers` | `pg_buffercache` — bảng nào chiếm chỗ; tỷ lệ hit của top query |
| `effective_cache_size` | so plan trước/sau trên 10 query nóng nhất; đo bằng `EXPLAIN`, không cần restart |
| `random_page_cost` | `fio` + so plan của các query đang là **Index Scan** (bitmap không đổi) |
| `work_mem` | `log_temp_files = 0` → xem còn spill không; kiểm tra RSS tổng của postgres |
| `max_parallel_workers_per_gather` | so `Workers Planned` vs `Launched` trong log; đo tăng tốc thật |

**Thứ tự triển khai an toàn:** `effective_cache_size` (không rủi ro) → `random_page_cost` (đo trước/sau) → `work_mem` (theo dõi RAM) → `shared_buffers` (cần restart).

---

## Bảng số liệu chính

| Kịch bản | Kết quả |
|---|---|
| **Cost Seq Scan tự tính** | **100.210,925** vs planner **100.210,93** — lệch **0,005 %** |
| Bỏ `WHERE` | −12.502,59 = đúng `reltuples × cpu_operator_cost` ✓ |
| `seq_page_cost` 1→2 | +37.697,99 = đúng `relpages` ✓ |
| Index Scan `ts` (corr=1), 55.563 dòng | cost **2.163** = **0,039/dòng** |
| Index Scan `device_id` (corr≈0), 107.947 dòng | cost **153.088** = **1,418/dòng** (**36,4×**) |
| `random_page_cost` 4.0→1.1 trên **bitmap** | cost 40.570 → 40.292 (**−0,7 %**), plan **không đổi** |
| `random_page_cost` 4.0→1.1 trên **Index Scan** | cost 153.088 → **43.487** (**−71,6 %**) |
| `effective_cache_size` 128MB→8GB trên **bitmap** | **0 %** |
| `effective_cache_size` 128MB→8GB trên **Index Scan** | 283.775 → **153.361** (**−46 %**) |
| Parallel 0 worker | **480,3 ms** |
| Parallel 2 worker (3 tiến trình) | **174,4 ms** (**2,75×**, hiệu suất 92 %) |
| Parallel 4 worker (5 tiến trình) | **128,1 ms** (**3,75×**, hiệu suất **75 %**) |
| Đặt 6 nhưng chỉ được 4 worker | giới hạn bởi `min_parallel_table_scan_size` |

---

## Ba điều dễ hiểu sai

| # | Hiểu nhầm | Sự thật đo được |
|---|---|---|
| 1 | "Hạ `random_page_cost` là planner sẽ dùng index" | **Không ảnh hưởng Bitmap Heap Scan** (cost đổi 0,7 %). Chỉ ảnh hưởng Index Scan thuần (−71,6 %) |
| 2 | "`effective_cache_size` cấp phát RAM cho cache" | **Không cấp phát một byte nào.** Chỉ là con số khai báo dùng trong công thức cost |
| 3 | "Parallel N worker thì nhanh gấp N lần" | 4 worker chỉ nhanh **3,75 lần** (hiệu suất 75 %). `parallel_setup_cost = 1000` là hằng số không chia được |

Thêm hai điều:
- **Cost model tính tay được chính xác tới 0,005 %.** Làm một lần rồi sẽ không bao giờ coi `cost` là số ma thuật.
- **`work_mem` nhân với `(số worker + 1)`.** Lab với `work_mem=4MB` mà worst case là **3,6 GB**; với 64MB là **57,6 GB**.

---

## Áp dụng vào hệ thật

**1. Chạy ngay để xem hệ đang đặt gì khác mặc định:**
```sql
SELECT name, setting, unit, boot_val, source, sourcefile, sourceline
FROM pg_settings
WHERE source NOT IN ('default','override')
ORDER BY name;
```
Cột `source` + `sourcefile` cho biết ai đặt và ở đâu — cực hữu ích khi có nhiều lớp cấu hình (image, helm chart, ALTER SYSTEM).

**2. Đặt `effective_cache_size` trước tiên — không rủi ro, hiệu quả rõ:**
```sql
ALTER SYSTEM SET effective_cache_size = '48GB';   -- 75% của 64GB
SELECT pg_reload_conf();                          -- không cần restart
```
Đo lại plan của 10 query nóng nhất trước/sau. Ở lab nó giảm cost Index Scan 46 %.

**3. Trước khi hạ `random_page_cost`, kiểm tra plan hiện tại là loại gì:**
```sql
-- nếu plan là Bitmap Heap Scan -> chỉnh rpc vô ích
-- nếu là Seq Scan hoặc Index Scan -> có thể có tác dụng
```
Rồi `fio` để đo tỷ lệ thật, rồi so plan trước/sau trên **toàn bộ** top 20 query — không chỉ query anh đang sửa. Hạ `random_page_cost` ảnh hưởng **mọi** query.

**4. Tính lại `work_mem` worst case của hệ mình:**
```
work_mem × max_connections × 3 (số node) × (max_parallel_workers_per_gather + 1)
```
Nếu con số vượt RAM khả dụng, hạ `work_mem` xuống và dùng `SET LOCAL` cho job cần nhiều.

**5. Monitor `Workers Launched < Workers Planned`.** Đây là dấu hiệu cạn `max_parallel_workers`, và nó khiến query chậm hơn plan mà không ai biết:
```sql
-- bật log để bắt
SET log_min_duration_statement = 1000;
-- rồi tìm trong log các plan có Workers Planned khác Launched
```

**6. Làm một lần bài tính cost bằng tay cho một query của hệ mình.** Nó biến `cost` từ con số ma thuật thành công cụ chẩn đoán.

---

## Câu hỏi mở sang các ngày sau

1. Sau 3 tuần, cho một plan xấu bất kỳ, chẩn đoán trong 1 phút được không? → **Day 15**
2. `work_mem` × số worker × số node — hash join spill thật sự tốn gì? → **Day 17**
3. `parallel_setup_cost = 1000` khiến query nhỏ không parallel. Aggregate parallel giúp bao nhiêu? → **Day 19**
4. `random_page_cost` không ảnh hưởng bitmap — vậy điều gì làm bitmap nhanh hơn? → **Day 31** (BRIN cũng dùng bitmap)
5. `max_connections = 100` nhưng nên đặt bao nhiêu, và vì sao 500 connection giết server? → **Day 36**
