# Day 23 — Lời giải: Autovacuum — mặc định là thảm hoạ với bảng lớn

> Bài chữa. Đo thật trên lab `SCALE=1`, có bật `log_autovacuum_min_duration = 0`.

---

## §0. Đáp án phần đoán — tính bằng tay

```
ngưỡng_vacuum = autovacuum_vacuum_threshold + autovacuum_vacuum_scale_factor × reltuples
              = 50 + 0,2 × reltuples
```

| # | Bảng | Ngưỡng dead tuple |
|---|---|---|
| 1 | `ts_kv` **5.002.424** dòng | **1.000.535** |
| 2 | 500.000.000 dòng | **100.000.050** |
| 3 | Hợp lý không? | **KHÔNG** — xem dưới |

### Vì sao con số đó vô lý

Với `ts_kv`, ngưỡng 1.000.535 dead tuple nghĩa là:

```
bảng 295 MB, phải tích tụ 20% dead tuple = 59 MB rác
rồi autovacuum mới đụng tới
```

Và với bảng 500 triệu dòng (500 GB): phải tích tụ **100 GB rác** trước khi autovacuum chạy lần đầu. Lúc đó:
- Bảng đã phình 20 % — mọi Seq Scan chậm 20 %
- Index-only scan đã chết từ lâu (Day 08: chỉ cần 0,45 % dòng bị sửa là mất 23 % page `all-visible`)
- Lần vacuum ấy phải quét 600 GB, chạy hàng giờ, ăn I/O nặng
- Trong lúc đó bảng tiếp tục phình

**Mặc định 0.2 được chọn từ thời bảng vài trăm nghìn dòng.** Với bảng hàng trăm triệu dòng, nó là một mặc định sai một cách hệ thống.

### Ngưỡng ANALYZE cũng vậy

```
ngưỡng_analyze = 50 + 0,1 × reltuples
```
`ts_kv`: **500.292 dòng** phải thay đổi rồi mới ANALYZE lại.

> **Đây chính là lời giải thích cho hiện tượng ở tuần 3: thống kê của bảng lớn luôn cũ.** Không phải vì ai quên, mà vì ngưỡng mặc định quá cao.

---

## §1. Bảng ngưỡng thật của lab

| relname | số dòng | **ngưỡng vacuum** | **ngưỡng analyze** | n_dead_tup | last_autovacuum |
|---|---|---|---|---|---|
| **`ts_kv`** | 5.002.424 | **1.000.535** | **500.292** | 97.772 | *(chưa bao giờ)* |
| `alarm` | 200.000 | 40.050 | 20.050 | 0 | 03:17:03 |
| `device_attr` | 99.856 | 20.021 | 10.036 | 0 | 03:17:03 |
| `device` | 50.000 | 10.050 | 5.050 | 0 | 03:17:03 |
| `tenant` | 20 | **54** | 52 | 0 | *(chưa)* |

`ts_kv` có **97.772 dead tuple** nhưng ngưỡng là **1.000.535** → autovacuum **chưa bao giờ chạm tới nó** kể từ khi seed.

Chú ý bảng nhỏ `tenant` (20 dòng): ngưỡng 54 — tức phải sửa **270 %** số dòng. Với bảng nhỏ, `threshold = 50` chi phối và mặc định lại quá **thấp** một cách vô hại.

### Ba GUC mới cần biết (PG13+)

```
autovacuum_vacuum_insert_threshold    = 1000
autovacuum_vacuum_insert_scale_factor = 0.2
```

Từ PG13, autovacuum còn kích hoạt theo **số dòng INSERT** (không chỉ dead tuple). Điều này quan trọng cho bảng **append-only** như `ts_kv`: nó không sinh dead tuple nào, nhưng vẫn cần vacuum để:
- Bật bit `all-visible` cho index-only scan (Day 08)
- Freeze tuple cũ, tránh wraparound (Day 25)

Trước PG13, bảng append-only **không bao giờ được autovacuum** cho tới khi chạm ngưỡng freeze — một lỗ hổng lớn.

```
autovacuum_work_mem = -1   (dùng maintenance_work_mem = 128MB)
```

---

## §2. Cost-based delay — tính thông lượng bằng tay

```
vacuum_cost_page_hit         = 1
vacuum_cost_page_miss        = 2
vacuum_cost_page_dirty       = 20
vacuum_cost_limit            = 200
autovacuum_vacuum_cost_limit = -1     (dùng vacuum_cost_limit = 200)
autovacuum_vacuum_cost_delay = 2 ms
autovacuum_max_workers       = 3
maintenance_work_mem         = 128MB
```

### Thông lượng tối đa lý thuyết

**Trường hợp xấu nhất (mọi page bị làm bẩn):**
```
mỗi vòng: 200 điểm ÷ 20 (dirty) = 10 page, rồi ngủ 2 ms
số vòng/giây = 1000 / 2 = 500
thông lượng  = 10 × 500 = 5.000 page/giây
             = 5.000 × 8 KB = 40 MB/s
```

**Trường hợp tốt (page trong cache, không làm bẩn):**
```
200 ÷ 1 = 200 page mỗi vòng × 500 vòng = 100.000 page/giây = 800 MB/s
```

Thực tế nằm giữa, thường **~40–100 MB/s**.

### Bảng 100 GB bloat 30 % cần bao lâu

```
VACUUM phải quét toàn bộ 100 GB (trừ phần all-visible)
100 GB ÷ 40 MB/s = 2.500 giây ≈ 42 phút
```

Nghe chấp nhận được. Nhưng đó là **một worker, một bảng, không bị chặn**. Thực tế:

| Yếu tố | Ảnh hưởng |
|---|---|
| Chỉ **3 worker** cho toàn database | 10 bảng lớn cần vacuum → xếp hàng |
| Index cũng phải quét | mỗi index thêm một lượt quét đầy đủ |
| `maintenance_work_mem = 128MB` | chỉ chứa ~22 triệu TID → bảng nhiều dead tuple cần **nhiều lượt quét index** |
| Bảng tiếp tục được ghi | dead tuple mới sinh ra trong lúc vacuum chạy |

**Với bảng 500 GB bloat nặng, autovacuum có thể cần nhiều ngày — và không bao giờ đuổi kịp.**

### `maintenance_work_mem` — biến ẩn quan trọng nhất

```
số TID chứa được = maintenance_work_mem ÷ 6 byte
                 = 128 MB ÷ 6 = ~22,4 triệu TID
```

Nếu bảng có nhiều dead tuple hơn con số này, VACUUM phải **quét lại TOÀN BỘ index nhiều lần** (`index scans: 2`, `3`...). Với bảng có 5 index, mỗi lượt là 5 lần quét index đầy đủ.

> **Dòng `index scans: N` trong log là chỉ số quan trọng nhất.** `N > 1` nghĩa là `maintenance_work_mem` không đủ. Nâng nó lên 1–2 GB cho instance có RAM là cách tăng tốc VACUUM rẻ nhất.

Ở lab mọi log đều là `index scans: 0` (bảng không index hoặc không có dead tuple trong index) — trạng thái lý tưởng.

---

## §3. Đọc log autovacuum — từng dòng

```
LOG:  automatic vacuum of table "lab.public.t_av": index scans: 0
	pages: 0 removed, 521 remain, 521 scanned (100.00% of total)
	tuples: 12500 removed, 50000 remain, 0 are dead but not yet removable
	removable cutoff: 1830, which was 0 XIDs old when operation ended
	frozen: 0 pages from table (0.00% of total) had 0 tuples frozen
	index scan not needed: 0 pages from table (0.00% of total) had 0 dead item identifiers removed
	I/O timings: read: 0.000 ms, write: 0.000 ms
	avg read rate: 0.000 MB/s, avg write rate: 0.000 MB/s
	buffer usage: 1070 hits, 0 misses, 0 dirtied
	WAL usage: 939 records, 0 full page images, 78585 bytes
	system usage: CPU: user: 0.01 s, system: 0.00 s, elapsed: 0.03 s
```

| Dòng | Nghĩa | Cần chú ý khi |
|---|---|---|
| **`index scans: 0`** | số lượt quét index | **> 1 = `maintenance_work_mem` không đủ** |
| `pages: 0 removed, 521 remain` | không trả page nào về OS | bình thường (Day 22 §3) |
| `521 scanned (100.00%)` | quét toàn bộ | < 100 % = visibility map giúp bỏ qua page sạch |
| **`tuples: 12500 removed`** | dọn được 12.500 dead tuple | |
| **`0 are dead but not yet removable`** | không bị transaction nào chặn | **> 0 = có transaction dài** (Day 22 §6) |
| `removable cutoff: 1830, 0 XIDs old` | XID biên; `0 XIDs old` = rất tươi | `N XIDs old` lớn = có snapshot cũ |
| `frozen: 0 pages` | chưa freeze gì | Day 25 |
| `avg read/write rate` | thông lượng thật | thấp bất thường = bị cost delay bóp |
| **`buffer usage: 1070 hits, 0 misses, 0 dirtied`** | I/O tiêu tốn | `dirtied` cao = tốn WAL và checkpoint |
| **`WAL usage: 939 records, 78585 bytes`** | **VACUUM sinh WAL** | trên bảng lớn là áp lực đáng kể lên replication |
| `elapsed: 0.03 s` | thời gian | dài = xem lại cost_limit |

Và `automatic analyze` chạy ngay sau đó (0,2 giây) — vì `n_mod_since_analyze` cũng vượt ngưỡng.

### Xem autovacuum đang chạy realtime

```sql
SELECT pid, datname, relid::regclass, phase,
       heap_blks_total, heap_blks_scanned, heap_blks_vacuumed,
       index_vacuum_count, max_dead_tuple_bytes, dead_tuple_bytes
FROM pg_stat_progress_vacuum;
```

Cột `phase` cho biết đang ở giai đoạn nào: `scanning heap` → `vacuuming indexes` → `vacuuming heap` → `cleaning up indexes`. Với bảng lớn, `vacuuming indexes` thường chiếm phần lớn thời gian.

---

## §4. Cấu hình per-table

```sql
ALTER TABLE ts_kv SET (autovacuum_vacuum_scale_factor = 0.01,
                       autovacuum_analyze_scale_factor = 0.01,
                       autovacuum_vacuum_cost_limit = 2000);
```

| | Ngưỡng cũ (0.2) | **Ngưỡng mới (0.01)** | Giảm |
|---|---|---|---|
| `ts_kv` (5.002.424 dòng) | **1.000.535** | **50.074** | **20 lần** |

Kiểm tra cấu hình đang áp:
```sql
SELECT relname, reloptions FROM pg_class WHERE reloptions IS NOT NULL;
```
```
 ts_kv | {autovacuum_vacuum_scale_factor=0.01,autovacuum_analyze_scale_factor=0.01,autovacuum_vacuum_cost_limit=2000}
```

### Quy đổi sang tốc độ ghi thật

Hệ IoT nhận **50.000 dòng/giây**, giả sử 10 % là UPDATE (5.000 dead tuple/giây):

| Cấu hình | Ngưỡng | Autovacuum chạy mỗi |
|---|---|---|
| Mặc định (0.2) | 1.000.535 | **200 giây** |
| `scale_factor = 0.01` | 50.074 | **10 giây** |

Với bảng 500 triệu dòng và cùng tốc độ:

| Cấu hình | Ngưỡng | Autovacuum chạy mỗi |
|---|---|---|
| Mặc định (0.2) | 100.000.050 | **5,6 giờ** ⚠️ |
| `scale_factor = 0.005` | 2.500.050 | **8,3 phút** |

**5,6 giờ giữa hai lần vacuum trên bảng ghi nóng = bảng phình 20 % rồi mới được dọn, và mỗi lần dọn phải xử lý 100 triệu dead tuple.**

### Bảng cấu hình theo loại bảng

| Loại bảng | Cấu hình đề xuất | Lý do |
|---|---|---|
| **Bảng lớn ghi nhiều** (`ts_kv`) | `scale_factor = 0.01`, `cost_limit = 2000` | ngưỡng tuyệt đối hợp lý, vacuum nhanh hơn |
| **Bảng nhỏ update liên tục** (counter, session) | `scale_factor = 0`, `threshold = 1000` | ngưỡng tuyệt đối, không phụ thuộc kích thước |
| **Bảng append-only** (log, event) | mặc định + `insert_scale_factor = 0.05` | không có dead tuple, nhưng cần freeze + VM |
| **Bảng queue** (insert + delete nhanh) | `scale_factor = 0.01`, `cost_delay = 0` | dead tuple sinh cực nhanh |
| **Bảng tra cứu ít đổi** | mặc định | không cần đụng |

---

## §5. Worker và bảng bị bỏ quên

```
autovacuum_max_workers = 3
maintenance_work_mem   = 128MB
```

### RAM tối đa

```
3 worker × 128 MB = 384 MB
```

Nếu nâng `maintenance_work_mem` lên 1 GB: `3 × 1 GB = 3 GB`. Phải trừ vào ngân sách RAM cùng với `shared_buffers` và `work_mem`.

⚠️ **`autovacuum_max_workers` chỉ đổi được khi RESTART.** Còn `maintenance_work_mem` thì reload được.

Có cách tách riêng:
```sql
-- chỉ áp cho autovacuum worker, không ảnh hưởng CREATE INDEX thủ công
ALTER SYSTEM SET autovacuum_work_mem = '1GB';
```

### Bảng lâu nhất chưa được vacuum

```
   relname   |        last_autovacuum        | n_dead_tup |  size
-------------+-------------------------------+------------+---------
 tenant      |            (chưa bao giờ)     |          0 | 8 kB
 ts_key_dict |            (chưa bao giờ)     |          0 | 8 kB
 ts_kv       |            (chưa bao giờ)     |     97.772 | 295 MB
 device      | 2026-08-10 03:17:03           |          0 | 9,4 MB
```

**`ts_kv` — bảng lớn nhất, có 97.772 dead tuple — chưa từng được autovacuum.** Đúng như tính toán §1: ngưỡng 1.000.535 quá cao.

### Ba điều dễ bỏ sót

1. **Bảng `TEMP` không bao giờ được autovacuum** — phải tự `VACUUM` trong session đó.
2. **Một bảng khổng lồ chiếm một worker suốt nhiều giờ** → chỉ còn 2 worker cho phần còn lại → bảng nhỏ bị bỏ đói. Với DB có hàng trăm bảng, cân nhắc `autovacuum_max_workers = 5–8`.
3. **Bảng TOAST có ngưỡng riêng**, thừa hưởng từ bảng chính. Xem trong log: `automatic vacuum of table "lab.pg_toast.pg_toast_NNNNN"`.

---

## §6. Khi autovacuum không đuổi kịp

### Thí nghiệm với `cost_delay = 100ms` — kết quả trung thực

Đặt `autovacuum_vacuum_cost_delay = 100` (chậm gấp 50 lần mặc định) rồi UPDATE 3 vòng toàn bảng:

| | |
|---|---|
| Kích thước sau 3 vòng UPDATE | **11 MB** |
| Sau 75 giây | `n_dead_tup = 0`, `last_autovacuum` đã cập nhật |
| `pg_stat_progress_vacuum` | **rỗng** — vacuum đã xong |

**Autovacuum VẪN đuổi kịp.** Thí nghiệm không tái hiện được kịch bản thất bại.

Vì sao: bảng chỉ **521 page (4 MB)**. Ngay cả với `cost_delay = 100ms`, vacuum một bảng 521 page chỉ mất vài giây.

### Điều kiện để autovacuum thật sự không đuổi kịp

Cần **tất cả**:
```
① Bảng LỚN (hàng trăm GB) — thời gian một lượt vacuum tính bằng giờ
② Tốc độ ghi cao — dead tuple mới sinh nhanh hơn tốc độ dọn
③ Nhiều index — mỗi lượt vacuum phải quét lại toàn bộ index
④ maintenance_work_mem nhỏ -> index scans > 1 -> nhân số lượt quét
⑤ Và/hoặc bị cost_delay bóp
```

Lab thiếu ① và ②, nên không tái hiện được. **Đây là kết quả trung thực, và nó dạy một điều: đừng ngoại suy từ bảng nhỏ.** Mọi vấn đề autovacuum đều là vấn đề của **quy mô**.

### Dấu hiệu nhận biết trên production

| Dấu hiệu | Query |
|---|---|
| `n_dead_tup` **tăng đều** dù autovacuum vẫn chạy | so 2 snapshot cách 1 giờ |
| `last_autovacuum` luôn cũ trên bảng nóng | `pg_stat_user_tables` |
| Vacuum chạy hàng giờ | `pg_stat_progress_vacuum` |
| `index scans: 2+` trong log | `maintenance_work_mem` không đủ |
| Kích thước bảng tăng liên tục | lịch sử `pg_relation_size` |

### Xử lý theo thứ tự — quan trọng là THỨ TỰ

```
① Kiểm tra TRANSACTION DÀI đang chặn         <- NGUYÊN NHÂN SỐ 1 (Day 22 §6)
   + replication slot không active
   + prepared transaction treo
   Nếu có: sửa cái này TRƯỚC. Mọi chỉnh sửa khác đều vô ích.

② Nâng maintenance_work_mem (hoặc autovacuum_work_mem) lên 1-2GB
   -> giảm `index scans` từ N về 1. Đây là đòn bẩy lớn nhất.

③ Nâng autovacuum_vacuum_cost_limit (2000-5000), giảm cost_delay về 0
   -> tăng thông lượng từ 40 MB/s lên vài trăm MB/s

④ Giảm scale_factor cho bảng đó (0.01 hoặc 0.005)
   -> vacuum thường xuyên hơn, mỗi lần ít việc hơn

⑤ Tăng autovacuum_max_workers (cần RESTART)

⑥ VACUUM thủ công vào giờ thấp điểm để "bắt kịp" một lần

⑦ Nếu đã bloat nặng: pg_repack

⑧ Xem lại thiết kế: bảng này có nên PARTITION không?
   -> vacuum chạy song song trên từng partition, mỗi partition nhỏ hơn
   -> DROP PARTITION thay DELETE = không sinh dead tuple
```

**Bước ① quan trọng nhất và hay bị bỏ qua nhất.** Nếu có transaction dài, vacuum sẽ chạy đủ nhanh nhưng **dọn được 0 dòng** — và mọi việc nâng cost_limit đều vô nghĩa.

---

## §7. Cấu hình mang về production

Script sinh ra cho lab:
```sql
ALTER TABLE alarm SET (autovacuum_vacuum_scale_factor = 0.1,  autovacuum_analyze_scale_factor = 0.05, autovacuum_vacuum_cost_limit = 2000);
ALTER TABLE ts_kv SET (autovacuum_vacuum_scale_factor = 0.01, autovacuum_analyze_scale_factor = 0.01, autovacuum_vacuum_cost_limit = 2000);
```

### Em sửa gì so với script đó

**1. `alarm` không nên để 0.1.** Nó là bảng **trạng thái** (alarm mở → đóng), tức UPDATE nhiều. Ngưỡng 0,1 × 200.000 = 20.000 dead tuple. Với hệ có 10.000 alarm/ngày chuyển trạng thái thì hai ngày mới vacuum một lần — và index-only scan cho badge đếm (Day 05) sẽ chết trong khoảng đó.

```sql
ALTER TABLE alarm SET (autovacuum_vacuum_scale_factor = 0.02,
                       autovacuum_analyze_scale_factor = 0.02);
```

**2. Thêm `autovacuum_vacuum_insert_scale_factor` cho bảng append-only.** `ts_kv` không sinh dead tuple nhưng cần vacuum để bật `all-visible` (Day 08 đo được: buffers giảm **287 lần**):

```sql
ALTER TABLE ts_kv SET (autovacuum_vacuum_insert_scale_factor = 0.05,
                       autovacuum_vacuum_insert_threshold = 100000);
```

**3. Dùng ngưỡng TUYỆT ĐỐI cho bảng rất lớn thay vì tỷ lệ.** Với bảng 500 triệu dòng, `scale_factor = 0.005` vẫn là 2,5 triệu dead tuple:

```sql
-- cách tốt hơn: scale_factor = 0, dùng threshold tuyệt đối
ALTER TABLE bang_500_trieu SET (
  autovacuum_vacuum_scale_factor = 0,
  autovacuum_vacuum_threshold    = 500000,     -- luôn là 500k, không phụ thuộc kích thước
  autovacuum_analyze_scale_factor = 0,
  autovacuum_analyze_threshold   = 200000
);
```

Đây là mẫu được khuyên dùng rộng rãi cho bảng lớn — nó tách ngưỡng khỏi kích thước bảng, nên khi bảng lớn lên gấp 10 lần, tần suất vacuum không đổi.

**4. Cấu hình toàn cục nên đổi cùng lúc:**
```conf
autovacuum_max_workers = 5              # cần RESTART
autovacuum_work_mem = 1GB               # 5 × 1GB = 5GB RAM
autovacuum_vacuum_cost_limit = 2000     # thay vì 200
autovacuum_vacuum_cost_delay = 2ms      # giữ, hoặc 0 nếu I/O tốt
autovacuum_naptime = 30s                # thay vì 60s, kiểm tra thường xuyên hơn
log_autovacuum_min_duration = 0         # log MỌI lần chạy — bắt buộc
```

---

## Bảng số liệu chính

| Kịch bản | Kết quả |
|---|---|
| Ngưỡng vacuum `ts_kv` (mặc định 0.2) | **1.000.535 dead tuple** = **59 MB rác** trước khi chạy |
| Ngưỡng analyze `ts_kv` (mặc định 0.1) | **500.292** dòng thay đổi |
| Ngưỡng bảng 500 triệu dòng | **100.000.050** (~100 GB rác) |
| Sau `scale_factor = 0.01` | **50.074** — giảm **20 lần** |
| `ts_kv` có 97.772 dead tuple | **chưa từng được autovacuum** (dưới ngưỡng) |
| Thông lượng autovacuum (mặc định, xấu nhất) | **~40 MB/s** |
| Bảng 100 GB bloat 30 % | **~42 phút** một lượt (một worker, không bị chặn) |
| `maintenance_work_mem = 128MB` | chứa **~22,4 triệu TID** → vượt là `index scans > 1` |
| RAM autovacuum tối đa | 3 worker × 128 MB = **384 MB** |
| Log autovacuum `t_av` | 521 page, 12.500 tuple dọn, `index scans: 0`, WAL **78.585 byte**, 0,03 s |
| Thí nghiệm `cost_delay = 100ms` | **vẫn đuổi kịp** — bảng 521 page quá nhỏ để tái hiện thất bại |

---

## Ba điều dễ hiểu sai

| # | Hiểu nhầm | Sự thật đo được |
|---|---|---|
| 1 | "Autovacuum bật là đủ, không cần chỉnh" | `ts_kv` có 97.772 dead tuple và **chưa từng được autovacuum** — ngưỡng mặc định là 1.000.535 |
| 2 | "Autovacuum chậm thì nâng `cost_limit`" | Nếu có **transaction dài**, vacuum chạy đủ nhanh nhưng **dọn được 0 dòng**. Kiểm tra bước ① trước |
| 3 | "Bảng append-only không cần vacuum" | Cần — để bật `all-visible` (index-only scan nhanh **287×**) và freeze. PG13+ có `insert_threshold` cho việc này |

Thêm hai điều:
- **`index scans: N` trong log là chỉ số quan trọng nhất.** `N > 1` = `maintenance_work_mem` không đủ, và mỗi lượt là một lần quét lại **toàn bộ** index.
- **Với bảng rất lớn, dùng `scale_factor = 0` + `threshold` tuyệt đối** thay vì tỷ lệ — để tần suất vacuum không đổi khi bảng lớn lên.

---

## Áp dụng vào hệ thật

**1. Chạy query này trên production ngay — nó cho biết bảng nào đang bị bỏ quên:**

```sql
SELECT c.relname,
       pg_size_pretty(pg_relation_size(c.oid))             AS size,
       c.reltuples::bigint                                 AS so_dong,
       s.n_dead_tup,
       (coalesce((SELECT option_value FROM pg_options_to_table(c.reloptions)
                  WHERE option_name='autovacuum_vacuum_threshold'), current_setting('autovacuum_vacuum_threshold'))::numeric
        + coalesce((SELECT option_value FROM pg_options_to_table(c.reloptions)
                  WHERE option_name='autovacuum_vacuum_scale_factor'), current_setting('autovacuum_vacuum_scale_factor'))::numeric
          * c.reltuples)::bigint                           AS nguong,
       s.last_autovacuum,
       now() - s.last_autovacuum                           AS bao_lau_roi
FROM pg_class c JOIN pg_stat_user_tables s ON s.relid = c.oid
WHERE c.relkind = 'r' AND pg_relation_size(c.oid) > 100*1024*1024
ORDER BY c.reltuples DESC;
```

**Bảng nào có `nguong` > 1 triệu = đang dùng mặc định mà không nên.**

**2. Áp cấu hình cho bảng lớn, kèm lý do:**

```sql
-- ts_kv tương đương: bảng telemetry append-only, 500M dòng
ALTER TABLE ts_kv SET (
  autovacuum_vacuum_scale_factor  = 0,          -- dùng ngưỡng tuyệt đối
  autovacuum_vacuum_threshold     = 500000,     -- vacuum mỗi 500k dead tuple
  autovacuum_analyze_scale_factor = 0,
  autovacuum_analyze_threshold    = 200000,     -- thống kê tươi cho planner (tuần 3)
  autovacuum_vacuum_insert_threshold = 200000,  -- append-only vẫn cần VM + freeze
  autovacuum_vacuum_cost_limit    = 3000        -- I/O tốt, cho chạy nhanh
);

-- alarm: bảng trạng thái, UPDATE nhiều
ALTER TABLE alarm SET (
  autovacuum_vacuum_scale_factor  = 0.02,       -- 2% thay vì 20%
  autovacuum_analyze_scale_factor = 0.02
);

-- device_state / session: bảng nhỏ update liên tục
ALTER TABLE device_state SET (
  autovacuum_vacuum_scale_factor = 0,
  autovacuum_vacuum_threshold    = 5000,        -- ngưỡng tuyệt đối nhỏ
  fillfactor = 70                               -- chuẩn bị cho HOT update (Day 24)
);
```

**3. Bật `log_autovacuum_min_duration = 0` trên production.** Overhead gần bằng 0, và đây là nguồn thông tin duy nhất cho biết vacuum có đuổi kịp không.

Rồi theo dõi hai thứ trong log:
- `index scans: N` — `N > 1` thì nâng `maintenance_work_mem`
- `X are dead but not yet removable` — có transaction dài đang chặn

**4. Nâng `maintenance_work_mem` — đòn bẩy rẻ nhất:**
```sql
ALTER SYSTEM SET autovacuum_work_mem = '1GB';   -- riêng cho autovacuum
SELECT pg_reload_conf();
```
Với `autovacuum_max_workers = 3`, tốn tối đa 3 GB. Đổi lại: `index scans` từ 5 xuống 1 = vacuum nhanh gấp 5 lần trên bảng nhiều index.

**5. Đừng ngoại suy từ bảng nhỏ.** §6 cho thấy autovacuum đuổi kịp thoải mái trên bảng 4 MB ngay cả khi bị bóp 50 lần. Mọi vấn đề autovacuum đều là vấn đề **quy mô** — phải đo trên bảng thật.

---

## Câu hỏi mở sang các ngày sau

1. HOT update giảm được bao nhiêu áp lực lên autovacuum? → **Day 24**
2. `autovacuum_freeze_max_age = 200.000.000` — khi chạm ngưỡng, "aggressive vacuum" khác gì vacuum thường? → **Day 25**
3. Partition giúp vacuum thế nào — mỗi partition một worker riêng? → **Day 32, Day 33**
4. `hot_standby_feedback` từ replica cũng chặn vacuum như transaction dài? → **Day 38**
5. VACUUM sinh WAL (78 kB cho bảng 4 MB) — trên bảng 500 GB thì áp lực lên replication thế nào? → **Day 37, Day 38**
