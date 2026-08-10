# Day 47 — Lời giải: Capstone 1b — sửa, đo lại, và trả giá

> Bài chữa. Bốn thay đổi, mỗi cái đo riêng. Không đổi GUC nào.
>
> **Kết quả: workload từ 44.796 ms xuống 811 ms — nhanh hơn 55,2×.** Cái giá: database +102%, INSERT chậm **14,9×**, WAL **×4,25**.
>
> Và phần quan trọng hơn kết quả: **4/5 dự đoán đúng, 1 sai — và cái sai đúng chỗ tôi đã ghi là "không chắc" ở Day 46.**

Kèm theo: [`rollout.md`](rollout.md).

---

## §1. Nhật ký sửa — từng cái một

| # | Thay đổi | Query ảnh hưởng | time trước → sau | buffers trước → sau | Thời gian tạo | Dung lượng |
|---|---|---|---|---|---|---|
| **1** | `CREATE INDEX CONCURRENTLY idx_tskv_dev_key_ts ON ts_kv (device_id, key_id, ts DESC)` | Q2, Q3 (và **một phần** Q1) | Q2: **346,3 → 0,027 ms**<br>Q3: **395,5 → 0,022 ms**<br>Q1: 340,3 → **4,134 ms** | Q2: 37.473 → **4**<br>Q3: 37.476 → **4**<br>Q1: 37.476 → **3.579** | **4.129 ms** | **195 MB** |
| **2** | `CREATE INDEX CONCURRENTLY idx_tskv_dev_ts ON ts_kv (device_id, ts DESC)` | Q1 | **4,134 → 0,020 ms** | **3.579 → 4** | **4.047 ms** | **151 MB** |
| **3** | `CREATE INDEX CONCURRENTLY idx_alarm_open_dev ON alarm (device_id) WHERE status IN ('ACTIVE_ACK','ACTIVE_UNACK')` | Q4 | **31,5 → 0,035 ms** | 3.887 → **3** | ~150 ms | **176 kB** |
| **4** | `CREATE INDEX CONCURRENTLY idx_alarm_open_sev_ts ON alarm (severity, start_ts DESC) WHERE status IN (...)` | Q5 | **32,6 → 0,078 ms** | 3.893 → **102** | ~150 ms | **272 kB** |

Sau mỗi thay đổi: `VACUUM ANALYZE` bảng tương ứng (cần cho `Index Only Scan` — Day 11), rồi `EXPLAIN (ANALYZE, BUFFERS)` chạy 3 lần lấy số ổn định.

**Tổng: 346 MB index thêm, ~8,5 giây thời gian tạo, không chặn đọc/ghi lần nào** (`SHARE UPDATE EXCLUSIVE`).

---

## §2. Dự đoán vs thực tế — phần chấm điểm thật

| Query | **Dự đoán (Day 46)** | **Thực tế** | Sai lệch | Đánh giá |
|---|---|---|---|---|
| **Q1** latest 1 device | ~0,10 ms, ~5 buf, dùng index 3 cột | **0,020 ms**, 4 buf — **nhưng phải TẠO THÊM index 2 cột** | time đúng 5× | ⚠️ **SAI về cách sửa** |
| **Q2** latest (device,key) | ~0,05 ms, ~5 buf, `Index Scan` | **0,027 ms**, **4 buf**, `Index Scan` | 1,9× | ✅ |
| **Q3** chuỗi 1 ngày | ~0,03 ms, ~4 buf, `Index Only Scan`, `Heap Fetches: 0` | **0,022 ms**, **4 buf**, **`Index Only Scan`, `Heap Fetches: 0`** | 1,4× | ✅ **chính xác cả plan** |
| **Q4** alarm 1 device | ~0,03 ms, ~4 buf, index < 200 kB | **0,035 ms**, **3 buf**, **176 kB** | 1,2× | ✅ **chính xác cả dung lượng** |
| **Q5** alarm sắp severity | ~0,15 ms, ~10 buf, không có node `Sort` | **0,078 ms**, **102 buf**, **không có `Sort`** ✅ | time 1,9× ✅<br>**buffers 10×** ❌ | ⚠️ **nửa đúng** |

**Điểm: 3/5 đúng hoàn toàn, 2/5 nửa đúng.** (Tiêu chí "sai số < 2× coi là đúng": về **thời gian** thì 5/5 đều đạt; nhưng hai câu sai về **cơ chế**, mà cơ chế mới là thứ đáng chấm.)

### Sai #1 — Q1: chẩn đoán đúng, cách sửa sai

**Tôi dự đoán:** index `(device_id, key_id, ts DESC)` phục vụ được cả Q1 (chỉ lọc `device_id`) nhờ leftmost rule.

**Thực tế sau khi tạo index 3 cột:**
```
 Limit  (actual time=4.082..4.084 rows=1 loops=1)
   Buffers: shared hit=3579
   ->  Sort  (Sort Key: ts DESC, top-N heapsort)          ← VẪN CÓ SORT
         ->  Bitmap Heap Scan on ts_kv  (actual rows=3742)
               ->  Bitmap Index Scan on idx_tskv_dev_key_ts
                     Index Cond: (device_id = 42)
 Execution Time: 4.134 ms
```

Chỉ nhanh **82×** (340,3 → 4,134 ms), không phải 3.400× như dự đoán.

**Vì sao tôi nghĩ nhầm:** leftmost rule cho phép **LỌC** bằng tiền tố cột — điều đó đúng, index vẫn được dùng. Nhưng nó **không** cho phép **ĐỌC THEO THỨ TỰ** của cột thứ ba khi cột thứ hai không bị ràng buộc.

Index sắp theo `(device_id, key_id, ts DESC)`. Với `device_id = 42`, các entry nằm liền nhau nhưng **sắp theo `key_id` trước, `ts` sau**:
```
(42, 1, t9) (42, 1, t8) ... (42, 2, t9) (42, 2, t8) ... (42, 8, t1)
```
Không có cách nào đọc chúng theo `ts DESC` mà không đọc hết. Nên planner chọn `Bitmap Index Scan` (mất thứ tự) + đọc cả 3.742 dòng + `Sort`.

Tôi đã **gộp hai khả năng khác nhau của index làm một**: *lọc theo tiền tố* và *cung cấp thứ tự*. Cái đầu cần tiền tố; cái sau cần **mọi cột trước cột sắp xếp phải là equality**.

**Sửa:** tạo thêm `idx_tskv_dev_ts ON ts_kv (device_id, ts DESC)` — 151 MB nữa.
```
 Limit  (actual time=0.009..0.009 rows=1 loops=1)
   Buffers: shared hit=4
   ->  Index Scan using idx_tskv_dev_ts on ts_kv        ← KHÔNG CÓ SORT
         Index Cond: (device_id = 42)
 Execution Time: 0.020 ms
```

**0,020 ms — nhanh hơn 17.000×.** Nhưng cái giá là **151 MB không nằm trong kế hoạch ban đầu** (+43% so với dự toán 346 MB tổng).

> **Đây là loại sai lầm đắt nhất trong thực tế: chẩn đoán đúng bệnh, kê đúng loại thuốc, nhưng sai liều — và chỉ phát hiện ra sau khi đã tiêu 195 MB.** Nếu đây là production 1 tỉ dòng, sai lầm này là 39 GB và một đêm build index.

Bài học rút ra thành quy tắc: **`ORDER BY c` chỉ dùng được index khi mọi cột đứng trước `c` trong index đều bị ràng buộc bằng `=`.**

### Sai #2 — Q5: đúng plan, sai buffers 10×

**Dự đoán:** ~10 buffer. **Thực tế: 102 buffer.**

Dự đoán đúng phần quan trọng (không còn node `Sort`, `Index Scan` + `Limit` dừng sau 100 entry). Nhưng tôi quên: `LIMIT 100` lấy 100 dòng, và mỗi dòng cần **một lần chạm heap** để lấy `id, device_id, type, start_ts` — những cột không có trong index.

100 dòng nằm rải rác ⇒ ~100 heap page + 2 index page = **102 buffer**. Đúng như số học, tôi chỉ không nghĩ tới nó.

**Sửa được không?** Có — `INCLUDE` (Day 08):
```sql
CREATE INDEX ... ON alarm (severity, start_ts DESC) INCLUDE (id, device_id, type)
  WHERE status IN ('ACTIVE_ACK','ACTIVE_UNACK');
```
Sẽ cho `Index Only Scan`, ~3 buffer. **Nhưng tôi KHÔNG làm** — 0,078 ms đã quá đủ, và `INCLUDE` làm index to hơn ~3× (thêm 3 cột vào 8.070 entry). Đây là chỗ dừng đúng lúc: **tối ưu tiếp là tối ưu cho vui, không phải cho hệ thống.**

### Phân loại nguyên nhân sai

| Loại | Có xảy ra không |
|---|---|
| Chẩn đoán sai node gốc bệnh | **Không** — cả 5 query đều đúng node (`Seq Scan`, và estimate đúng nên không phải bệnh statistics) |
| Chẩn đoán đúng nhưng đánh giá sai mức cải thiện | **Có, Q5** — sai 10× về buffers vì quên chi phí chạm heap của `LIMIT n` |
| **Xuất hiện nút thắt mới sau khi sửa nút thắt cũ** | **Có, Q1 — và đây là ca thú vị nhất.** Sau khi index 3 cột loại bỏ `Seq Scan`, nút thắt chuyển sang **`Sort` + `Bitmap Heap Scan` 3.579 buffer**. Đó là nút thắt *mới*, chỉ nhìn thấy được sau khi sửa cái cũ. |

Ca Q1 minh hoạ đúng nguyên tắc của Day 47: **sửa một thứ → đo ngay → mới sang cái tiếp.** Nếu tôi tạo cả 4 index cùng lúc rồi mới đo, tôi sẽ thấy "mọi thứ đều nhanh" và **không bao giờ biết index 3 cột một mình là không đủ cho Q1** — cũng như không biết index 2 cột có thật sự cần hay không.

---

## §3. Đo lại toàn bộ

### Before / After từng query

| Query | time trước | **time sau** | Cải thiện | bufs trước | **bufs sau** | Plan chính trước → sau |
|---|---|---|---|---|---|---|
| **Q1** latest 1 device | 340,3 ms | **0,020 ms** | **17.000×** | 37.476 | **4** | `Seq Scan + Sort + Limit` → **`Index Scan + Limit`** |
| **Q2** latest (device,key) | 346,3 ms | **0,027 ms** | **12.800×** | 37.473 | **4** | `Seq Scan + Sort + Limit` → **`Index Scan + Limit`** |
| **Q3** chuỗi 1 ngày | 395,5 ms | **0,022 ms** | **18.000×** | 37.476 | **4** | `Seq Scan + Aggregate` → **`Index Only Scan` (Heap Fetches: 0)** |
| **Q4** alarm 1 device | 31,5 ms | **0,035 ms** | **900×** | 3.887 | **3** | `Seq Scan` → **`Index Only Scan` (Heap Fetches: 0)** |
| **Q5** alarm sắp severity | 32,6 ms | **0,078 ms** | **418×** | 3.893 | **102** | `Seq Scan + Sort + Limit` → **`Index Scan + Limit`** (không còn `Sort`) |

### Tổng workload

| | Trước | **Sau** | Cải thiện |
|---|---|---|---|
| Wall clock lần 2 | 44.915 ms | **926 ms** | **48,5×** |
| `sum(total_exec_time)` | **44.796 ms** | **811 ms** | **55,2×** |

### Wait event — chân dung hệ đã đổi

| | Trước | Sau |
|---|---|---|
| (CPU) | **97,5%** (784 mẫu) | **100,0%** (15 mẫu) |
| `IO/DataFileRead` | 2,2% (18 mẫu) | 0% |
| **Tổng số mẫu** | **784** | **15** |

**Dự đoán của tôi ở Day 46 về wait event SAI hoàn toàn.** Tôi đoán "CPU giảm xuống 70–80%, IO tăng tỉ trọng". Thực tế: **CPU lên 100%, IO biến mất.**

Lý do — và nó hiển nhiên khi nhìn lại: index scan đọc **4 buffer** thay vì 37.476. Bốn buffer đó **luôn nằm trong cache**, nên không còn `DataFileRead` nào. I/O không "tăng tỉ trọng", nó **biến mất cùng với công việc**.

Con số đáng chú ý hơn là **số mẫu: 784 → 15**. Sampler lấy mẫu 20 lần/giây; workload chạy 39 giây trước và 0,9 giây sau. **Số mẫu chính là thước đo tổng công việc**, và nó giảm 52× — khớp với 55,2× từ `pg_stat_statements`.

### Top 5 sau khi sửa — đổi hoàn toàn

| # | Query | total_ms | pct | Trước đây xếp |
|---|---|---|---|---|
| 1 | **W10** đếm device × 20 tenant | 203,9 | **25,1%** | #11 (112 ms, 0,2%) |
| 2 | **W18** downsample 1 tuần | 134,1 | 16,5% | #7 (149 ms, 0,3%) |
| 3 | **W17** tìm kiếm prefix × 9 | 115,9 | 14,3% | #6 (202 ms, 0,5%) |
| 4 | **W26 UPDATE alarm** | **86,9** | 10,7% | #12 (54 ms, 0,1%) |
| 5 | **W25 INSERT ts_kv** | **61,8** | 7,6% | không trong top 12 |

**Không một query nào trong top 5 cũ còn ở lại.** Cả năm đã xuống dưới 0,1% — tổng cộng chúng giờ chiếm **~0,03%** thay vì 97,4%.

Thứ tự mới nói ba điều:

1. **W10, W18, W17 gần như không đổi thời gian tuyệt đối** (112→204, 149→134, 202→116 ms) — chúng chỉ "nổi lên" vì các query khác biến mất. Đây là hiện tượng bình thường của mọi audit: **top-N sau khi tối ưu luôn là những thứ trước đó bị che khuất.**
2. **W26 (UPDATE alarm) TĂNG từ 54 → 86,9 ms (+61%)** và W25 (INSERT) xuất hiện với 61,8 ms. **Đây không phải nhiễu — đây là cái giá của index**, hiện ra ngay trong chính bảng xếp hạng.
3. Vòng tối ưu tiếp theo (nếu có) sẽ nhắm vào **W10** (`count(*)` cho phân trang — Day 20 có kỹ thuật) và **W17** (`lower(name) LIKE` — cần expression index + `text_pattern_ops`, Day 42 §4c). Nhưng **204 ms cho 20 lần lặp = 10 ms/lần** — đã đủ tốt, và tối ưu tiếp là tối ưu cho vui.

---

## §4. Cái giá phải trả

### a) Dung lượng

| | Trước | **Sau** | Chênh |
|---|---|---|---|
| `ts_kv` index | **0 bytes** | **346 MB** | +346 MB |
| `ts_kv` tổng | 289 MB | **643 MB** | +122% |
| `alarm` index | 4.408 kB | 5.256 kB | +848 kB |
| **Database** | **351 MB** | **708 MB** | **+102%** |

**Dung lượng database tăng gấp đôi để đổi lấy tốc độ đọc gấp 55 lần.**

### b) Tốc độ ghi và WAL — đo tách bạch FPI

INSERT 200.000 dòng vào bảng **không index** (`t_w`) so với vào `ts_kv` (**2 index**):

| Lần đo | Bảng | Thời gian | WAL | `wal_records` | `wal_fpi` |
|---|---|---|---|---|---|
| **Ngay sau `CHECKPOINT`** | `t_w` (0 index) | 182 ms | 16 MB | 200.000 | 0 |
| | `ts_kv` (2 index) | **2.713 ms** | **306 MB** | 600.463 | **37.153** |
| **Không checkpoint** | `t_w` (0 index) | **134 ms** | **16 MB** | 200.000 | 0 |
| | `ts_kv` (2 index) | **1.998 ms** | **68 MB** | 608.478 | **1.218** |

**Chi phí thật ở trạng thái ổn định (lần 2, không FPI):**

| | 0 index | **2 index** | **Chênh** |
|---|---|---|---|
| Thời gian | 134 ms | **1.998 ms** | **14,9×** |
| WAL | 16 MB | **68 MB** | **4,25×** |
| `wal_records` | 200.000 | **608.478** | **3,04×** |

`wal_records` ×3,04 khớp chính xác lý thuyết: **1 heap record + 2 index record = 3 record mỗi dòng.**

**Và lần đo đầu tiên cho thấy một thứ khác, quan trọng hơn:** ngay sau `CHECKPOINT`, WAL là **306 MB** với **37.153 FPI**. Tính ra: 37.153 × 8.192 = **304 MB = 99% toàn bộ WAL**.

Vì sao index gây ra nhiều FPI đến thế: `device_id` được sinh ngẫu nhiên nên entry mới rơi **rải rác khắp cây B-tree** — chạm 37.153 page khác nhau, mỗi page một full-page image 8 kB cho một entry ~20 byte. Đây đúng là hiện tượng Day 35 §2 (WAL ×2,8 khi ghi rải rác) và Day 37 §3 (FPI = 86,3% WAL), giờ xuất hiện trong một tình huống thật.

> **Hệ quả vận hành: chi phí WAL thật của index dao động giữa 4,25× (ổn định) và 19,1× (ngay sau checkpoint).** Với `checkpoint_timeout = 5min` (mặc định lab), hệ luôn dao động giữa hai mức này. Tăng `checkpoint_timeout` lên 30 phút + bật `wal_compression = lz4` (Day 37 §7) sẽ kéo con số về gần 4,25×.

### c) Tỉ lệ HOT

```sql
SELECT relname, n_tup_upd, n_tup_hot_upd, round(n_tup_hot_upd::numeric/nullif(n_tup_upd,0),3) AS ty_le_hot,
       (SELECT count(*) FROM pg_index WHERE indrelid=relid) AS so_index
FROM pg_stat_user_tables WHERE n_tup_upd > 0;
--  alarm | 22008 | 10 | 0.000 | 3
```

Tỉ lệ HOT của `alarm` = **0,05%** với 3 index.

**Nhưng tôi không có số liệu trước để so** — `pg_stat_user_tables` bị reset khi seed lại, và tôi đã quên chụp lại trước khi tạo index. **Đây là một lỗi phương pháp trong chính bài audit này**, và phải ghi lại.

Điều duy nhất nói được chắc: `UPDATE alarm ... SET status` **luôn** phá HOT trong trường hợp này, vì `status` nằm trong **vị từ của cả hai partial index** — thay đổi nó làm entry phải bị xoá/thêm vào index. Đây là chi phí có thể lường trước bằng lý thuyết (Day 24), và nó khớp với việc W26 tăng 61%.

Nếu muốn cải thiện: `ALTER TABLE alarm SET (fillfactor = 80)` — nhưng cần đo trước/sau đàng hoàng, không đoán.

### d) Index nào không được dùng

```sql
SELECT indexrelname, idx_scan, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes ORDER BY idx_scan;
```

| Index | `idx_scan` | Size | Đánh giá |
|---|---|---|---|
| `device_attr_pkey` | **0** | 4.904 kB | **có sẵn từ trước** — workload không đụng `device_attr` |
| `ts_key_dict_pkey` | **0** | 16 kB | có sẵn từ trước |
| `ts_key_dict_key_key` | **0** | 16 kB | có sẵn từ trước |
| `idx_alarm_open_sev_ts` | 8 | 520 kB | **của tôi** — dùng ít nhưng đúng mục đích (W11 chạy 1 lần/workload) |
| `idx_tskv_dev_key_ts` | **160** | 195 MB | **của tôi** ✅ |
| `idx_tskv_dev_ts` | **170** | 151 MB | **của tôi** ✅ |
| `idx_alarm_open_dev` | **608** | 328 kB | **của tôi** ✅ |

**Cả bốn index tôi tạo đều được dùng — không có cái nào phải xoá.**

Ba index `idx_scan = 0` đều là primary key có từ trước. Tôi **không xoá** chúng vì: PK là ràng buộc toàn vẹn, không phải chỉ là index. Nhưng ghi lại làm phát hiện: `device_attr` (11 MB, 99.856 dòng) **hoàn toàn không được workload đụng tới** — nếu đây là production, câu hỏi đúng là *"bảng này có còn ai dùng không?"*, không phải *"index này có dùng không?"*.

`idx_alarm_open_sev_ts` chỉ 8 scan. Ở production tôi sẽ **giữ lại và kiểm tra sau 7 ngày** (`rollout.md` có ghi ngưỡng này) — nó chỉ 520 kB và phục vụ một endpoint UI chính.

### e) Kết luận đánh đổi — cho từng thay đổi, không phải cả gói

| # | Thay đổi | Được | Mất | **Đáng?** |
|---|---|---|---|---|
| **1** | `idx_tskv_dev_key_ts` (195 MB) | Q2 **12.800×**, Q3 **18.000×** — hai query chiếm 42,4% workload | 195 MB (+68% bảng); ~1/2 chi phí ghi ×14,9 | **✅ Rất đáng** |
| **2** | `idx_tskv_dev_ts` (151 MB) | Q1 **4,13 ms → 0,020 ms** (206× nữa) — 41,8% workload | 151 MB (+52% bảng); ~1/2 chi phí ghi | **⚠️ Đáng nhưng phải hỏi lại** — xem dưới |
| **3** | `idx_alarm_open_dev` (176 kB) | Q4 **900×**; 13,2% workload | 176 kB = **0,05%** dung lượng; UPDATE alarm chậm | **✅ Rõ ràng đáng** (tỉ lệ lợi ích/chi phí tốt nhất) |
| **4** | `idx_alarm_open_sev_ts` (272 kB) | Q5 **418×** | 272 kB; UPDATE alarm chậm | **✅ Đáng**, nhưng theo dõi `idx_scan` 7 ngày |

**Thay đổi #2 là chỗ cần thảo luận thật sự.** Không có nó, Q1 chạy **4,13 ms** — vẫn nhanh hơn baseline **82 lần**. Có nó, **0,020 ms**. Câu hỏi: **4,13 ms có đủ nhanh không?**

- Nếu SLO của endpoint dashboard là p99 < 50 ms và nó gọi 20 device một lúc: 20 × 4,13 = **82,6 ms — KHÔNG đạt** ⇒ cần index.
- Nếu nó gọi 5 device: 20,7 ms — **đạt** ⇒ **tiết kiệm 151 MB (30 GB ở production 1 tỉ dòng)**.

Ở lab tôi tạo cả hai để đo được con số. **Ở production tôi sẽ triển khai #1 trước, đo 24h, rồi mới quyết định #2** — đúng như `rollout.md` ghi.

**Đánh đổi tổng thể:** đọc nhanh **55,2×**, ghi chậm **14,9×**, dung lượng **+102%**.

Với hệ IoT tỉ lệ đọc:ghi ~10:1 thì đáng rõ ràng. **Với hệ ingest thuần thì phải cân lại** — và ở đó câu trả lời có thể là **BRIN thay B-tree** (Day 31: 48 kB vs 108 MB, ghi rẻ hơn nhiều) hoặc **partition theo thời gian** (Day 32–33), chứ không phải index thường.

---

## Bảng số liệu chính

| Phép đo | Trước | Sau |
|---|---|---|
| **Tổng workload** (`sum(total_exec_time)`) | **44.796 ms** | **811 ms — 55,2×** |
| Wall clock | 44.915 ms | **926 ms** |
| Q1 latest 1 device | 340,3 ms / 37.476 buf | **0,020 ms / 4 buf — 17.000×** |
| Q2 latest (device,key) | 346,3 ms / 37.473 buf | **0,027 ms / 4 buf — 12.800×** |
| Q3 chuỗi 1 ngày | 395,5 ms / 37.476 buf | **0,022 ms / 4 buf — 18.000×** (Index Only Scan, Heap Fetches 0) |
| Q4 alarm 1 device | 31,5 ms / 3.887 buf | **0,035 ms / 3 buf — 900×** |
| Q5 alarm sắp severity | 32,6 ms / 3.893 buf | **0,078 ms / 102 buf — 418×** |
| Top 5 chiếm | **97,4%** | **~0,03%** |
| **Wait event** | CPU 97,5% / IO 2,2%, **784 mẫu** | CPU 100% / IO 0%, **15 mẫu** |
| **Database** | 351 MB | **708 MB (+102%)** |
| `ts_kv` index | 0 bytes | **346 MB** |
| **INSERT 200k (ổn định)** | 134 ms / 16 MB WAL | **1.998 ms / 68 MB — 14,9× & 4,25×** |
| INSERT 200k (sau checkpoint) | 182 ms / 16 MB | **2.713 ms / 306 MB — 37.153 FPI = 99% WAL** |
| `wal_records` mỗi 200k dòng | 200.000 | **608.478 (3,04× = 1 heap + 2 index)** |
| W26 UPDATE alarm trong workload | 54 ms | **86,9 ms (+61%)** |
| Thời gian tạo 4 index | — | **~8,5 giây**, không chặn đọc/ghi |
| Index tôi tạo mà không dùng | — | **0** |
| **Dự đoán đúng** | — | **3/5 hoàn toàn, 2/5 nửa đúng** |

---

## Ba điều dễ hiểu sai (rút ra từ chính ngày hôm nay)

| Hiểu nhầm | Sự thật đo được |
|---|---|
| "Leftmost rule nghĩa là index `(a,b,c)` phục vụ được mọi query lọc theo `a`." | Nó phục vụ được **LỌC**, nhưng không phục vụ được **THỨ TỰ**. `WHERE a=42 ORDER BY c DESC LIMIT 1` trên index `(a,b,c)` cho **`Bitmap Index Scan` + `Sort`, 3.579 buffer, 4,13 ms** — vì với `b` không ràng buộc, các entry của `a=42` sắp theo `b` trước rồi mới `c`. Cần index riêng `(a,c)`: **4 buffer, 0,020 ms**. **Quy tắc: `ORDER BY c` chỉ dùng được index khi mọi cột trước `c` đều bị ràng buộc bằng `=`.** |
| "Sửa xong thì tỉ trọng I/O sẽ tăng vì công việc CPU biến mất." | **Sai hoàn toàn.** I/O **biến mất cùng với công việc**: từ 2,2% xuống **0%**, và tổng số mẫu wait event từ **784 xuống 15**. Index scan đọc 4 buffer — bốn buffer đó luôn trong cache. Tôi đã nghĩ về wait event như một cái bánh có tỉ lệ cố định; thực tế cả cái bánh nhỏ đi 52 lần. |
| "Chi phí WAL của index là một con số." | Nó dao động giữa **4,25× (ổn định) và 19,1× (ngay sau checkpoint)**. Ngay sau `CHECKPOINT`, **37.153 FPI = 99% toàn bộ 306 MB WAL** — vì `device_id` ngẫu nhiên làm entry rơi rải rác khắp cây B-tree, mỗi page bị chạm lần đầu tốn 8 kB. Báo cáo "index làm WAL tăng 4×" là **đúng nhưng chưa đủ**; con số thật phụ thuộc `checkpoint_timeout` và `wal_compression`. |

---

## §5. Triển khai như thật

Xem [`rollout.md`](rollout.md) — gồm:
- điều kiện tiên quyết (5 query kiểm tra trước),
- bảng 4 thay đổi × (lock, thời gian ở lab, ước tính prod, dung lượng, rollback, giờ cao điểm, cách kiểm chứng),
- câu lệnh chính xác có `lock_timeout` + `statement_timeout = 0`,
- ràng buộc quan trọng của partial index (vị từ phải khớp),
- bảng chi phí để team duyệt,
- ngưỡng dừng,
- thứ tự triển khai 3 đêm với **điểm quyết định ở đêm 3**.

---

## Nộp bài

| File | Nội dung |
|---|---|
| [`giai.md`](giai.md) | nhật ký sửa + dự đoán vs thực tế + before/after + cái giá |
| [`rollout.md`](rollout.md) | kế hoạch triển khai production |
| [`../day-46/workload.sql`](../day-46/workload.sql) | workload dùng chung cho cả hai ngày |

**Tự chấm theo tiêu chí "Đạt khi":**

| Tiêu chí | Đạt? |
|---|---|
| Bảng before/after đủ 5 query, có time + buffers + node plan | ✅ |
| Bảng dự đoán vs thực tế, giải thích từng chỗ sai | ✅ — 3/5 đúng, 2 chỗ sai đã phân tích cơ chế |
| Tổng workload giảm rõ rệt, định lượng được | ✅ **55,2×** |
| Báo cáo cả chi phí (dung lượng, ghi, WAL, HOT) | ✅ — **trừ HOT: thiếu số liệu "trước"**, đã ghi rõ là lỗi phương pháp |
| Đã xoá index tạo ra mà không dùng | ✅ — không có cái nào (cả 4 đều `idx_scan > 0`) |
| Không dùng GUC để gian lận | ✅ |

**Một chỗ chưa đạt: không có số liệu HOT trước khi sửa.** Lỗi phương pháp: tôi quên chụp `pg_stat_user_tables` trước khi tạo index. Với một audit thật, **snapshot toàn bộ `pg_stat_*` trước khi động vào bất cứ thứ gì** phải là bước 0.

---

## Câu hỏi mở sang Day 48

- **Ngày mai mang đúng quy trình này sang hệ production thật.** Ba thứ khác biệt lớn nhất so với lab: (a) không được `pg_stat_statements_reset()` tuỳ tiện, (b) không chạy được workload tổng hợp — phải đọc từ traffic thật, (c) không có "trước/sau" sạch vì hệ luôn thay đổi.
- **Câu hỏi kỹ thuật còn để ngỏ:** ở production 1 tỉ dòng, hai index của `ts_kv` là **~69 GB**. Ở quy mô đó, câu trả lời đúng có thể **không phải index** mà là **partition theo thời gian + BRIN** (Day 31–33): BRIN 48 kB thay cho B-tree 108 MB, và `DROP PARTITION` thay cho retention bằng `DELETE`. Đánh đổi: BRIN không phục vụ `ORDER BY ts DESC LIMIT 1` — mẫu nóng nhất của IoT. **Có thể cần cả hai: partition + B-tree `(device_id, ts DESC)` cục bộ trong mỗi partition** (nhỏ hơn nhiều vì mỗi partition chỉ chứa 1 tháng).
- **Một điều tôi vẫn chưa đo:** ảnh hưởng của 346 MB index lên **cache hit ratio** của các query khác. `shared_buffers` chỉ 256 MB; index mới lớn hơn cả shared_buffers. Ở lab dataset vừa page cache OS nên không thấy; ở production nó có thể đẩy dữ liệu nóng khác ra khỏi cache. Cách đo: `pg_buffercache` trước/sau.

---

### Dọn dẹp (giữ index cho Day 48)

```sql
DROP TABLE IF EXISTS wait_samples;
DROP PROCEDURE IF EXISTS sample_waits(int);
DELETE FROM ts_kv WHERE ts > '2025-08-01';
VACUUM ANALYZE ts_kv;
```
