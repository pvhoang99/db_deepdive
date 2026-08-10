# Day 46 — Lời giải: Capstone 1a — audit lab, dựng hiện trường và chẩn đoán

> Bài chữa. Lab reset sạch (`make nuke && make up && make seed 1`), **không có index nào ngoài primary key**. Workload 27 câu mô phỏng ứng dụng IoT. Hôm nay **chỉ chẩn đoán, không sửa gì**.
>
> Baseline: **44.796 ms** cho một lần chạy workload. **Năm query chiếm 97,4%** tổng thời gian, và cả năm đều là cùng một bệnh: **seq scan 5 triệu dòng để lấy vài dòng**.

---

## §1. Hiện trạng

| Bảng | Tổng | Heap | Index | TOAST | `n_live_tup` |
|---|---|---|---|---|---|
| `ts_kv` | **289 MB** | 289 MB | **0 bytes** | 0 bytes | 4.999.978 |
| `alarm` | 33 MB | 29 MB | 4.408 kB | 0 bytes | 200.000 |
| `device_attr` | 11 MB | 6.296 kB | 4.904 kB | 0 bytes | 99.856 |
| `device` | 11 MB | 9.656 kB | 1.112 kB | 0 bytes | 50.000 |
| `ts_key_dict` | 48 kB | 8 kB | 32 kB | 0 bytes | 8 |
| `tenant` | 32 kB | 8 kB | 16 kB | 0 bytes | 20 |
| **Database** | **351 MB** | | | | |

**Index hiện có: 6 — tất cả đều là primary key hoặc unique constraint.**

| Index | Size |
|---|---|
| `device_attr_pkey` | 4.904 kB |
| `alarm_pkey` | 4.408 kB |
| `device_pkey` | 1.112 kB |
| `tenant_pkey`, `ts_key_dict_pkey`, `ts_key_dict_key_key` | 16 kB × 3 |

Ba điều đọc ra ngay từ bảng này, **trước khi chạy một query nào**:

1. **`ts_kv` — bảng lớn nhất (82% database) — có 0 byte index.** Nó thậm chí không có primary key. Mọi truy cập vào nó đều là seq scan 289 MB.
2. **`alarm` chỉ có index trên `id`** — mà không query nào lọc theo `id`. Index 4,4 MB đó gần như vô dụng cho workload.
3. **TOAST = 0 ở mọi bảng** — nên tuần 9 §41 không áp dụng ở đây. Đây là kết luận âm nhưng cần ghi lại: **loại trừ một giả thuyết cũng là kết quả chẩn đoán.**

Phân bố dữ liệu (thu thập trước, dùng cho chẩn đoán):

| Chỉ số | Giá trị |
|---|---|
| `ts_kv`: dòng / device | **102,2** (5M dòng / ~49k device) |
| `alarm`: `status LIKE 'ACTIVE%'` | **8.070 / 200.000 = 4,0%** |
| `device`: `tenant_id=3 AND is_active` | **1.637 / 50.000 = 3,3%** |

---

## §2. Workload và baseline

[`workload.sql`](workload.sql) — 27 câu, 10 nhóm. Ba lỗi thiết kế tôi vấp và phải sửa:

### 🔧 Bẫy 1: `count(*)` làm Postgres XOÁ HẲN scalar subquery

Bản đầu tiên:
```sql
SELECT count(*) FROM (
  SELECT (SELECT dbl_v FROM ts_kv WHERE device_id = (1 + g % 300) ORDER BY ts DESC LIMIT 1)
  FROM generate_series(1, 400) g
) s;
```
Chạy **0,860 ms**. Toàn bộ workload xong trong 900 ms.

Lý do: `count(*)` chỉ cần **số dòng**, không cần giá trị. Planner nhận ra scalar subquery không ảnh hưởng số dòng nên **loại bỏ hoàn toàn** — 400 lần seq scan 5 triệu dòng biến mất.

Sửa: `count(v)` / `sum(v)` với alias, buộc phải tính giá trị.
```sql
SELECT count(v) FROM (
  SELECT (SELECT dbl_v FROM ts_kv WHERE device_id = (1 + g % 300) ORDER BY ts DESC LIMIT 1) AS v
  FROM generate_series(1, 30) g
) s;
```
Sau khi sửa: **11.769 ms** cho riêng câu này.

> **Bài học cho mọi benchmark: nếu con số đẹp bất thường, kiểm tra plan trước khi ăn mừng.** Đây là biến thể của cùng lỗi ở Day 41 §3 (`EXPLAIN ANALYZE` không de-TOAST vì không gửi dữ liệu về client) — **query bạn nghĩ mình đang đo không phải query Postgres đang chạy.**

### 🔧 Bẫy 2: giá trị enum sai

Tôi viết `WHERE status = 'ACTIVE'`. Dữ liệu thật:

| status | count |
|---|---|
| `ACTIVE_ACK` | 6.070 |
| `ACTIVE_UNACK` | 4.008 |
| `CLEARED_ACK` | 119.823 |
| `CLEARED_UNACK` | 70.099 |

**Khớp 0 dòng.** Query vẫn "chạy" và vẫn seq scan 200.000 dòng — nhưng nó đo một thứ vô nghĩa. Sửa thành `status IN ('ACTIVE_ACK','ACTIVE_UNACK')` (4,0% số dòng).

### 🔧 Bẫy 3: quy mô

`generate_series(1, 400)` cho W01 nghĩa là **400 × seq scan 5 triệu dòng ≈ 2,3 phút cho một câu**. Giảm xuống 30 vòng để workload chạy được trong ~45 giây và lặp lại được nhiều lần. Ghi rõ trong file để không quên khi ngoại suy.

### Baseline

| Lần chạy | Wall clock | `sum(total_exec_time)` |
|---|---|---|
| **Lần 1 (cache lạnh)** | 44.422 ms | 44.307 ms |
| **Lần 2 (cache nóng)** | 44.915 ms | **44.796 ms** |

**Chênh nhau < 1,2% — gần như không có khác biệt cache lạnh/nóng.**

Điều này bất ngờ so với bài học Day 03 (cache lạnh thường chậm hơn nhiều lần), và lý do rất quan trọng cho phần chẩn đoán: **workload này bị chặn ở CPU chứ không ở I/O.** Dataset 351 MB nằm trọn trong page cache của máy 31 GB; công việc thật là **đánh giá vị từ trên 5 triệu dòng, lặp 30–200 lần**. Cache có nóng hay không không đổi được điều đó.

**Chọn lần 2 (44.796 ms) làm baseline** — vì nó tái lập được ổn định (±1%), và vì trạng thái sau khi hệ đã chạy một lúc mới là trạng thái production thật.

---

## §3. Xếp hạng — chọn mục tiêu

### Top 12 theo `total_exec_time`

| # | Query | calls | total_ms | **pct** | bufs | wal |
|---|---|---|---|---|---|---|
| **1** | **W01** latest value 30 device | 1 | **11.769** | **26,3%** | **1.130.820** | 0 |
| **2** | **W03** latest theo (device,key), 30 lần | 1 | **11.298** | **25,2%** | 1.130.823 | 0 |
| **3** | **W04** chuỗi 1 ngày, 20 device | 1 | **7.686** | **17,2%** | 753.880 | 0 |
| **4** | **W02** latest + join device, 20 device | 1 | **6.944** | **15,5%** | 753.883 | 0 |
| **5** | **W12** alarm mở của 200 device | 1 | **5.901** | **13,2%** | 762.800 | 0 |
| 6 | W17 tìm kiếm prefix × 9 | 1 | 202 | 0,5% | 10.863 | 0 |
| 7 | W18 downsample 1 tuần | 1 | 149 | 0,3% | 37.810 | 0 |
| 8 | W19 downsample 1 device 1 tháng | 1 | 144 | 0,3% | 37.810 | 0 |
| 9 | W06 nhiều device 1 ngày | 1 | 141 | 0,3% | 37.694 | 0 |
| 10 | W05 chuỗi 1 device 1 tuần | 1 | 139 | 0,3% | 37.810 | 0 |
| 11 | W10 đếm device × 20 tenant | 1 | 112 | 0,2% | 24.140 | 0 |
| 12 | W26 UPDATE alarm | 1 | 54 | 0,1% | 26.197 | **608 kB** |

**Năm query đầu = 97,4%.** Phần còn lại (22 câu) cộng lại chỉ 2,6%.

### Wait event (lấy mẫu 20 lần/giây trong lúc chạy workload)

| Loại | Sự kiện | Mẫu | % |
|---|---|---|---|
| **(chạy trên CPU)** | — | **784** | **97,5%** |
| `IO` | `DataFileRead` | 18 | 2,2% |
| `IPC` | `BgworkerShutdown` / `MessageQueueReceive` | 2 | 0,2% |

**97,5% CPU, chỉ 2,2% I/O.**

Đây là kết luận chẩn đoán quan trọng nhất của cả ngày, và nó loại trừ ba giả thuyết cùng lúc:

| Giả thuyết bị loại | Bằng chứng |
|---|---|
| "Đĩa chậm / thiếu RAM" | `IO/DataFileRead` chỉ **2,2%**; cache lạnh và nóng chênh **< 1,2%** |
| "Lock contention" | **0 mẫu** `Lock` — workload chạy tuần tự, không có tranh chấp |
| "Ghi quá tải / WAL" | `wal_bytes` của mọi query đọc = **0**; tổng WAL của cả workload < 1 MB |

**Bệnh là: CPU đang đốt vào việc đánh giá vị từ trên hàng triệu dòng không cần thiết.** Cách chữa duy nhất là **đọc ít dòng hơn** — tức index, không phải phần cứng, không phải GUC.

### Năm query chọn để tối ưu — và tiêu chí chọn

Không chỉ lấy top 5 theo `total_exec_time`. Tiêu chí:

| Tiêu chí | Áp dụng |
|---|---|
| **1. `total_exec_time` cao** | 5 query đầu = 97,4% — không tối ưu chúng thì mọi thứ khác vô nghĩa |
| **2. `buffers` cực cao so với số dòng trả về** | W01 đọc **1.130.820 buffer** để trả về **30 giá trị** ⇒ 37.694 buffer/giá trị. Đây là chỉ số tốt hơn `total_ms` vì nó không phụ thuộc cache. |
| **3. Wait event chỉ vào** | 97,5% CPU ⇒ ưu tiên query đọc thừa nhiều dòng nhất, không phải query chờ I/O |
| **4. Mẫu truy cập lặp lại nhiều lần trên production** | W01/W02/W03 là mẫu "latest value" — chạy **mỗi lần refresh dashboard**, tần suất thật cao gấp hàng trăm lần trong lab |
| **5. Một cách sửa giải quyết nhiều query** | W01, W02, W03, W04 đều lọc theo `device_id` trên `ts_kv` ⇒ **một index có thể sửa cả bốn** |

Tiêu chí 5 là lý do tôi **không** chọn W17 (tìm kiếm prefix, 202 ms) dù nó có mean cao — nó cần một index riêng chỉ phục vụ chính nó.

**Danh sách chọn:**

| Q | Từ | Vì sao chọn |
|---|---|---|
| **Q1** | W01/W02 — latest value 1 device | 41,8% tổng thời gian; mẫu nóng nhất của IoT |
| **Q2** | W03 — latest theo (device, key) | 25,2%; cùng bảng, cần thêm cột lọc |
| **Q3** | W04 — chuỗi thời gian 1 device 1 ngày | 17,2%; mẫu vẽ biểu đồ |
| **Q4** | W12 — alarm đang mở của 1 device | 13,2%; bảng khác, bệnh khác |
| **Q5** | W11 — alarm đang mở sắp theo severity | chỉ 0,03% ở lab **nhưng** là endpoint chính của UI alarm và có `ORDER BY` — chọn theo tiêu chí 4 |

---

## §4. Chẩn đoán

### Query 1 — Latest value của một device (W01, W02)

**SQL:**
```sql
SELECT dbl_v FROM ts_kv WHERE device_id = 42 ORDER BY ts DESC LIMIT 1;
```

**Plan trước:**
```
 Limit  (cost=100863.92..100863.92 rows=1) (actual time=340.311..340.313 rows=1 loops=1)
   Buffers: shared hit=27552 read=9924
   ->  Sort  (cost=100863.92..100874.06 rows=4056) (actual time=340.310..340.310 rows=1)
         Sort Key: ts DESC
         Sort Method: top-N heapsort  Memory: 25kB
         ->  Seq Scan on ts_kv  (cost=0.00..100843.64 rows=4056) (actual rows=3738 loops=1)
               Filter: (device_id = 42)
               Rows Removed by Filter: 5066262
 Execution Time: 340.344 ms
```

**Node gốc bệnh:** `Seq Scan on ts_kv`. Estimate **4.056** vs thật **3.738** — **lệch chỉ 1,09×, estimate ĐÚNG**.

**Chẩn đoán:** Đây không phải bệnh estimate. Planner biết chính xác nó sẽ lấy về 3.738 dòng, nhưng **không có đường nào khác ngoài seq scan** — `ts_kv` không có index nào. `Rows Removed by Filter: 5.066.262` là toàn bộ vấn đề: đọc 5 triệu dòng, giữ 3.738 (0,074%), rồi sort để lấy **1**.

Đây là lý do wait event cho 97,5% CPU: 5 triệu lần đánh giá `device_id = 42`.

`n_distinct` của `ts_kv.device_id` = **28.415** (dương ⇒ giá trị tuyệt đối), trung bình **102,2 dòng/device**. Chọn lọc **0,002%** — điều kiện lý tưởng cho B-tree.

**Cách sửa dự định:**
```sql
CREATE INDEX CONCURRENTLY idx_tskv_dev_ts ON ts_kv (device_id, ts DESC);
```
Thứ tự `(device_id, ts DESC)` phục vụ được **cả ba việc**: lọc `device_id`, sắp `ts DESC`, và `LIMIT 1` dừng ngay ở entry đầu (Day 07 leftmost + Day 08).

**Dự đoán:**
- Plan: `Seq Scan + Sort + Limit` → **`Index Scan Backward` + `Limit`**, không có node `Sort`.
- Buffers: **37.476 → ~5** (đi xuống cây B-tree ~4 tầng + 1 heap page).
- Time: **340,3 ms → ~0,05 ms** (**~6.800×**).
- W01 (30 lần): 11.769 ms → **~15 ms**.

**Rủi ro:**
- Index trên 5M dòng, khoá `(bigint, timestamptz)` = 16 byte + overhead ⇒ ước **~150–170 MB** (bằng ~55% kích thước bảng).
- Ghi chậm hơn: Day 37 đo ba index làm WAL tăng 3,82× và INSERT chậm 7,1×; một index ước ~25–35% WAL thêm.
- `CREATE INDEX CONCURRENTLY` mất ~2 lần quét, ước **~10–15 giây** cho 5M dòng (Day 43 đo 914,9 ms cho 2M dòng bảng nhỏ hơn), không chặn ghi.

---

### Query 2 — Latest theo (device, key) (W03)

**SQL:**
```sql
SELECT dbl_v FROM ts_kv WHERE device_id = 42 AND key_id = 3 ORDER BY ts DESC LIMIT 1;
```

**Plan trước:**
```
 Limit  (actual time=346.251..346.252 rows=1 loops=1)
   Buffers: shared hit=27554 read=9919
   ->  Sort  (Sort Key: ts DESC, top-N heapsort  Memory: 25kB)
         ->  Seq Scan on ts_kv  (cost=0.00..113517.76 rows=363) (actual rows=334)
               Filter: ((device_id = 42) AND (key_id = 3))
               Rows Removed by Filter: 5069666
 Execution Time: 346.274 ms
```

**Node gốc bệnh:** cùng `Seq Scan`. Estimate **363** vs thật **334** — lệch 1,09×, **đúng**.

**Chẩn đoán:** giống Q1 nhưng chọn lọc còn cao hơn — **0,0066%** (334/5.070.000). `key_id` có `n_distinct = 8`, phân bố đều, nên `device_id AND key_id` chia thêm 8 lần.

**Câu hỏi thiết kế: index của Q1 có đủ không?** `(device_id, ts DESC)` sẽ lọc được `device_id`, nhưng phải quét ~102 entry của device đó và lọc `key_id` ở heap. Với 102 dòng thì rẻ — nhưng nó **mất khả năng dừng sớm ở `LIMIT 1`**, vì entry đầu tiên có thể là `key_id` khác.

**Cách sửa dự định:** mở rộng index của Q1 thành ba cột thay vì tạo index thứ hai:
```sql
CREATE INDEX CONCURRENTLY idx_tskv_dev_key_ts ON ts_kv (device_id, key_id, ts DESC);
```
Index này phục vụ **cả Q1 lẫn Q2** nhờ leftmost rule (Day 07): `WHERE device_id=42` dùng được tiền tố đầu tiên. Chỉ tốn thêm 2 byte/entry cho `key_id`.

**Dự đoán:**
- Q2: buffers **37.473 → ~5**, time **346,3 → ~0,05 ms**.
- Q1 (chỉ có `device_id`): vẫn dùng được index, nhưng phải quét toàn bộ ~102 entry của device rồi sort. Dự đoán **~0,1 ms** — chậm hơn index 2 cột chút ít nhưng vẫn nhanh hơn baseline ~3.400×.
- W03 (30 lần): 11.298 ms → **~15 ms**.
- Index lớn hơn phương án Q1 ~10 MB (thêm 2 byte × 5M).

**Rủi ro:** nếu Q1 (chỉ lọc `device_id`) là mẫu nóng hơn nhiều so với Q2, có thể cần **cả hai** index — nhưng đó là +150 MB nữa. **Quyết định: dùng một index 3 cột, đo lại, chỉ tách nếu Q1 không đạt.** Đây là điểm sẽ kiểm chứng ngày mai.

---

### Query 3 — Chuỗi thời gian 1 device, 1 ngày (W04)

**SQL:**
```sql
SELECT count(*) FROM ts_kv
WHERE device_id = 42 AND key_id = 1 AND ts >= '2025-06-01' AND ts < '2025-06-02';
```

**Plan trước:**
```
 Aggregate  (actual time=395.472..395.473 rows=1 loops=1)
   Buffers: shared hit=27586 read=9887 written=3
   ->  Seq Scan on ts_kv  (cost=0.00..138866.02 rows=14) (actual rows=7 loops=1)
         Filter: ((ts >= ...) AND (ts < ...) AND (device_id = 42) AND (key_id = 1))
         Rows Removed by Filter: 5069993
 Execution Time: 395.494 ms
```

**Node gốc bệnh:** `Seq Scan`. Estimate **14** vs thật **7** — lệch **2×**, chấp nhận được (đây là kết quả của việc nhân ba selectivity độc lập; Day 19 giải thích vì sao nó thường sai nhiều hơn).

**Chẩn đoán:** đọc **5.070.000 dòng để trả về 7**. Tỉ lệ hữu ích **0,00014%** — tệ nhất trong năm query.

Chú ý `written=3`: query **đọc** này phải ghi 3 buffer — đó là dirty page bị đẩy ra để lấy chỗ, hệ quả của việc quét 289 MB qua `shared_buffers` 256 MB. Một dấu hiệu nhỏ nhưng cụ thể của việc seq scan lớn làm ô nhiễm cache.

**Cách sửa dự định:** **cùng index của Q2** — `(device_id, key_id, ts DESC)`. Cả ba cột lọc đều nằm trong index, theo đúng thứ tự leftmost: equality trên hai cột đầu, range trên cột cuối (Day 07 §3).

Và vì query chỉ cần `count(*)`, nó có thể thành **Index Only Scan** sau `VACUUM` (Day 11).

**Dự đoán:**
- Plan: **`Index Only Scan`**, `Heap Fetches: 0` (sau VACUUM).
- Buffers: **37.476 → ~4**.
- Time: **395,5 ms → ~0,03 ms** (**~13.000×**).
- W04 (20 lần): 7.686 ms → **~10 ms**.

**Rủi ro:** không có rủi ro thêm — dùng chung index với Q2.

---

### Query 4 — Alarm đang mở của một device (W12)

**SQL:**
```sql
SELECT count(*) FROM alarm WHERE device_id = 42 AND status IN ('ACTIVE_ACK','ACTIVE_UNACK');
```

**Plan trước:**
```
 Aggregate  (actual time=31.429..31.430 rows=1 loops=1)
   Buffers: shared hit=3887
   ->  Seq Scan on alarm  (cost=0.00..7034.38 rows=6) (actual rows=6 loops=1)
         Filter: ((status = ANY ('{ACTIVE_ACK,ACTIVE_UNACK}')) AND (device_id = 42))
         Rows Removed by Filter: 199994
 Execution Time: 31.461 ms
```

**Node gốc bệnh:** `Seq Scan on alarm`. Estimate **6** vs thật **6** — **chính xác tuyệt đối**.

**Chẩn đoán:** lại là bệnh thiếu index, không phải bệnh statistics. Nhưng có một khác biệt quan trọng so với Q1–Q3:

`alarm` chỉ 200.000 dòng / 29 MB ⇒ mỗi lần chỉ 31 ms. **Vấn đề là nó chạy 200 lần trong workload ⇒ 5.901 ms = 13,2%.** Đây là mẫu bệnh khác: *query rẻ chạy rất nhiều lần*, chứ không phải *query đắt chạy một lần*.

Phân bố: `status LIKE 'ACTIVE%'` = **4,0%** số dòng; `device_id` có `n_distinct = -0,129865` (âm ⇒ tỉ lệ) tức ~26.000 giá trị phân biệt.

**Cách sửa dự định:**
```sql
CREATE INDEX CONCURRENTLY idx_alarm_dev_status
  ON alarm (device_id) WHERE status IN ('ACTIVE_ACK','ACTIVE_UNACK');
```

Chọn **partial index** (Day 08) thay vì index thường trên `(device_id, status)` vì:
- Chỉ 4,0% số dòng vào index ⇒ **~8.070 entry, ước < 200 kB** thay vì ~5 MB.
- Mọi query của UI đều lọc alarm **đang mở** — alarm đã đóng không bao giờ được hỏi theo mẫu này.
- Index nhỏ ⇒ nằm trọn trong cache ⇒ ghi rẻ (chỉ 4% số INSERT chạm tới nó).

**Dự đoán:**
- Plan: **`Index Only Scan`** hoặc `Bitmap Index Scan` trên partial index.
- Buffers: **3.887 → ~4**.
- Time: **31,5 ms → ~0,03 ms** (**~1.000×**).
- W12 (200 lần): 5.901 ms → **~30 ms**.
- Kích thước index: **< 200 kB**.

**Rủi ro:**
- **Partial index chỉ dùng được khi vị từ của query KHỚP với vị từ của index.** Nếu app viết `status = 'ACTIVE_ACK'` (một giá trị) thì planner vẫn dùng được (điều kiện hẹp hơn); nhưng nếu viết `status LIKE 'ACTIVE%'` thì **không** — planner không chứng minh được tương đương. Đây là ràng buộc phải ghi vào tài liệu.
- Khi alarm đổi `status` từ ACTIVE sang CLEARED, entry bị **xoá khỏi index** — làm `UPDATE` alarm đắt hơn một chút. Nhưng W26/W27 chỉ 54 ms nên không đáng kể.

---

### Query 5 — Alarm đang mở, sắp theo severity (W11)

**SQL:**
```sql
SELECT id, device_id, type, severity, start_ts FROM alarm
WHERE status IN ('ACTIVE_ACK','ACTIVE_UNACK')
ORDER BY severity, start_ts DESC LIMIT 100;
```

**Plan trước:**
```
 Limit  (actual time=32.535..32.546 rows=100 loops=1)
   Buffers: shared hit=3893
   ->  Sort  (Sort Key: severity, start_ts DESC; top-N heapsort  Memory: 38kB)
         ->  Seq Scan on alarm  (cost=0.00..6509.81 rows=10561) (actual rows=8070 loops=1)
               Filter: (status = ANY ('{ACTIVE_ACK,ACTIVE_UNACK}'))
               Rows Removed by Filter: 191930
 Execution Time: 32.567 ms
```

**Node gốc bệnh:** `Seq Scan`. Estimate **10.561** vs thật **8.070** — lệch **1,31×**, chấp nhận được.

**Chẩn đoán:** hai bệnh chồng nhau:
1. Đọc 200.000 dòng để giữ 8.070 (4,0%).
2. **Sort 8.070 dòng để lấy 100** — `top-N heapsort` đã là cách rẻ nhất, nhưng vẫn phải chạm hết 8.070 dòng.

Nếu index cho phép **đọc sẵn theo thứ tự** `(severity, start_ts DESC)` thì `LIMIT 100` dừng sau đúng 100 entry — bỏ được cả hai bệnh.

**Cách sửa dự định:**
```sql
CREATE INDEX CONCURRENTLY idx_alarm_open_sev_ts
  ON alarm (severity, start_ts DESC)
  WHERE status IN ('ACTIVE_ACK','ACTIVE_UNACK');
```

**Dự đoán:**
- Plan: **`Index Scan` + `Limit`, KHÔNG có node `Sort`** — đây là dấu hiệu chính để xác nhận.
- Buffers: **3.893 → ~10** (100 entry + heap page tương ứng).
- Time: **32,6 ms → ~0,15 ms** (**~215×**).
- Kích thước: **< 300 kB** (8.070 entry).

**Rủi ro:**
- `severity` chỉ có **3 giá trị** (`CRITICAL` 9.989 / `MAJOR` 39.908 / `WARNING` 150.103) — cột dẫn đầu có `n_distinct = 3` thường là thiết kế index tệ. **Nhưng ở đây nó đúng**, vì mục đích không phải lọc mà là **cung cấp thứ tự** cho `ORDER BY`.
- Đây là index **thứ hai** trên `alarm` với cùng vị từ partial. Cân nhắc gộp thành một: `(status, severity, start_ts DESC)`? **Không** — vì Q4 lọc theo `device_id`, Q5 sắp theo `severity`; một index không phục vụ tốt cả hai. Hai partial index nhỏ (< 500 kB tổng) rẻ hơn một index thường lớn.
- `severity` là `text` với thứ tự chữ cái: `CRITICAL` < `MAJOR` < `WARNING`. **May mắn trùng đúng thứ tự nghiêm trọng giảm dần** — nhưng đó là trùng hợp, không phải thiết kế. Nếu sau này thêm `severity = 'INFO'` thì nó sẽ nằm giữa `CRITICAL` và `MAJOR`. **Nên chuyển sang enum hoặc cột số** — ghi vào danh sách nợ kỹ thuật, không sửa trong capstone này.

---

## Bảng tổng hợp dự đoán

| Q | Query | Time trước | **Dự đoán sau** | Bufs trước | **Dự đoán sau** | Cách sửa |
|---|---|---|---|---|---|---|
| **Q1** | latest 1 device | 340,3 ms | **~0,10 ms** (3.400×) | 37.476 | **~5** | index (device_id, key_id, ts DESC) |
| **Q2** | latest (device, key) | 346,3 ms | **~0,05 ms** (6.900×) | 37.473 | **~5** | cùng index Q1 |
| **Q3** | chuỗi 1 ngày | 395,5 ms | **~0,03 ms** (13.000×) | 37.476 | **~4** | cùng index Q1 (Index Only Scan) |
| **Q4** | alarm 1 device | 31,5 ms | **~0,03 ms** (1.000×) | 3.887 | **~4** | partial index (device_id) WHERE ACTIVE |
| **Q5** | alarm sắp severity | 32,6 ms | **~0,15 ms** (215×) | 3.893 | **~10** | partial index (severity, start_ts DESC) WHERE ACTIVE |

**Dự đoán tổng workload:**

| | Baseline | **Dự đoán** |
|---|---|---|
| Top 5 query | 43.598 ms (97,4%) | **~70 ms** |
| Tổng workload | **44.796 ms** | **~1.270 ms (~35×)** |
| Kích thước index thêm | 0 | **~180 MB** (chủ yếu index ts_kv) |
| Database | 351 MB | **~530 MB (+51%)** |

**Dự đoán về wait event sau khi sửa:** tỉ lệ CPU sẽ **giảm** và `IO/DataFileRead` có thể **tăng tỉ lệ tương đối** — vì công việc CPU biến mất gần hết, phần I/O còn lại (đọc index page) chiếm tỉ trọng lớn hơn. Tổng thời gian giảm mạnh nhưng **cơ cấu wait event đảo chiều** — đây là dự đoán khó nhất và là thứ tôi ít chắc nhất.

---

## Ba điều dễ hiểu sai (rút ra từ chính ngày hôm nay)

| Hiểu nhầm | Sự thật đo được |
|---|---|
| "Estimate sai là nguyên nhân query chậm." | **Cả năm query đều có estimate ĐÚNG** (lệch 1,00–2,00×). Planner biết chính xác nó sẽ lấy 3.738 / 334 / 7 / 6 / 8.070 dòng — nó chỉ **không có đường nào khác ngoài seq scan**. Bệnh estimate (Day 09, 19) và bệnh thiếu index là **hai bệnh khác nhau**, và phải phân biệt trước khi động vào `CREATE STATISTICS` hay `ANALYZE`. |
| "Query chậm là do I/O, thêm RAM/đĩa nhanh hơn sẽ đỡ." | Wait event: **97,5% CPU, 2,2% I/O**. Cache lạnh vs nóng chênh **< 1,2%**. Toàn bộ 351 MB nằm trong page cache. Thêm phần cứng **không giải quyết được gì** — CPU đang đốt vào 5 triệu lần đánh giá `device_id = 42`. Cách chữa duy nhất là **đọc ít dòng hơn**. |
| "Benchmark chạy nhanh là tin tốt." | Bản workload đầu tiên chạy **900 ms** — vì `count(*)` làm Postgres **xoá hẳn scalar subquery**. Query tôi nghĩ mình đang đo không phải query Postgres đang chạy. Sau khi sửa: **44.796 ms**, gấp **50 lần**. Cùng loại lỗi với `EXPLAIN ANALYZE` không de-TOAST ở Day 41 §3. **Con số đẹp bất thường ⇒ kiểm tra plan trước khi ăn mừng.** |

---

## Nộp bài

| File | Nội dung |
|---|---|
| [`workload.sql`](workload.sql) | 27 câu, 10 nhóm, đã sửa 3 bẫy |
| [`giai.md`](giai.md) | bài này — hiện trạng, baseline, xếp hạng, 5 chẩn đoán có dự đoán |

**Chưa tạo index nào.** `pg_indexes_size` của `ts_kv` vẫn là 0 byte.

---

## Ngày mai (Day 47) sẽ kiểm chứng

Ba câu hỏi mở để lại cho ngày mai — đây là những chỗ tôi **không chắc**, và độ chính xác của chúng mới là thước đo hiểu tới đâu:

1. **Một index `(device_id, key_id, ts DESC)` có phục vụ tốt cả Q1 (chỉ lọc `device_id`) không?** Hay Q1 cần index riêng `(device_id, ts DESC)`? Nếu cần thì tổng index thêm 150 MB nữa.
2. **Q3 có thành `Index Only Scan` với `Heap Fetches: 0` không?** Nó phụ thuộc visibility map — mà W25 chèn 10.000 dòng mới mỗi lần chạy workload, nên VM có thể không kịp cập nhật (Day 11).
3. **Cơ cấu wait event sau khi sửa sẽ thế nào?** Dự đoán: CPU giảm từ 97,5% xuống ~70–80%, `IO` tăng tỉ trọng. Đây là dự đoán tôi ít tự tin nhất.

Và cái giá phải trả — sẽ đo ngày mai theo đúng tinh thần "sửa và trả giá":
- Index thêm **~180 MB** (+51% database).
- W25 (INSERT 10.000 dòng) sẽ chậm hơn — Day 37 đo ba index làm INSERT chậm **7,1×** và WAL tăng **3,82×**. Với một index lớn trên `ts_kv`, dự đoán INSERT chậm **~2×**.
- `CREATE INDEX CONCURRENTLY` trên 5M dòng: ước **10–15 giây**, không chặn ghi (Day 43).
