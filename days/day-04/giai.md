# Day 04 — Lời giải: Bốn kiểu truy cập bảng, và vì sao "có index mà không dùng"

> Bài chữa. Đo thật trên lab `SCALE=1`. Index có sẵn từ Day 02: `idx_tskv_dev(device_id)`, `idx_tskv_dev_key(device_id, key_id)`. Bài này tạo thêm `idx_tskv_ts(ts)` và `idx_tskv_key(key_id)`.

---

## Chuẩn bị: ba mức selectivity

```
 device_id | count  | % bảng
-----------+--------+--------
      1    | 107947 | 2,159 %   <- CAO
     29    |   4879 | 0,098 %   <- GIỮA
  50000    |     13 | 0,00026 % <- THẤP
```

Phân bố power-law của seed lộ rõ: device #1 nhiều hơn device #50000 **8.300 lần**.

---

## §0. Đáp án phần đoán

| Mức | Planner chọn (`count(*)`) | Planner chọn (`sum(dbl_v)`) |
|---|---|---|
| THẤP (13 dòng) | Index Only Scan | **Bitmap Heap Scan** |
| GIỮA (4.879 dòng) | Index Only Scan | **Bitmap Heap Scan** |
| CAO (107.947 dòng) | Index Only Scan | **Bitmap Heap Scan** |

Câu trả lời cho "ở mức nào seq scan bắt đầu thắng index": **trên cột `device_id` thì KHÔNG BAO GIỜ trong dải này** — kể cả ở 2,16 % bảng, bitmap vẫn nhanh gấp 2 lần seq scan. Còn trên cột `ts` thì điểm lật là **giữa 33 % và 66 %**.

Hai con số hoàn toàn khác nhau trên cùng một bảng. Vì sao — đó là bài học chính hôm nay (§4).

### ⚠️ Bẫy phương pháp phải xử lý trước

Chạy ma trận với `count(*)` cho kết quả **vô nghĩa**: planner luôn chọn `Index Only Scan` ở cả 3 mức, vì `count(*)` không cần cột nào từ heap. Ở mức CAO nó đọc **95 buffer** cho 107.947 dòng — không phải vì index giỏi, mà vì **nó không hề đụng bảng**.

So sánh "4 kiểu truy cập **bảng**" mà chọn một query không đọc bảng thì không so được gì.

→ Toàn bộ §1–§3 dưới đây dùng `SELECT sum(dbl_v)` — `dbl_v` không nằm trong index nào, nên **bắt buộc phải đọc heap**. Đây là điều kiện công bằng.

> **Bài học phương pháp: trước khi benchmark, kiểm tra query của anh có thật sự chạm vào thứ anh muốn đo không.** Rất nhiều benchmark "index nhanh 1000 lần" thực chất đang đo index-only scan.

---

## §1 + §3. Ma trận 3 mức × 4 kiểu scan

Tất cả dùng `SELECT sum(dbl_v) FROM ts_kv WHERE device_id = X`.

### MỨC THẤP — device 50000 (13 dòng, 0,00026 %)

| Kiểu scan | planner chọn? | total cost | actual time | buffers | ghi chú |
|---|---|---|---|---|---|
| **Bitmap Heap Scan** | ✅ | 601,59 | **0,049 ms** | **16** | `Heap Blocks: exact=13` |
| Index Scan | | 631,54 | 0,348 ms | 16 | |
| Seq Scan | | 99.457,81 | **299,620 ms** | **36.958** | `Rows Removed: 4.999.987` |

**Seq scan chậm hơn 6.100 lần.** Đọc 36.958 page để lấy 13 dòng.

Bitmap và Index Scan gần như hoà nhau (16 buffer cả hai) — vì 13 dòng thì chẳng có gì để sắp xếp lại. Bitmap thắng sát nút nhờ dùng được `idx_tskv_dev_key` (index nhỏ hơn ở tầng lá cho lookup này).

### MỨC GIỮA — device 29 (4.879 dòng, 0,098 %)

| Kiểu scan | planner chọn? | total cost | actual time | buffers | ghi chú |
|---|---|---|---|---|---|
| **Bitmap Heap Scan** | ✅ | 11.249,54 | 4,566 ms | 4.589 | `Heap Blocks: exact=4.582` |
| **Index Scan** | | 14.672,68 | **2,632 ms** | **4.589** | ⬅ nhanh hơn 1,7× |
| Seq Scan | | 99.467,01 | 255,003 ms | 36.958 | |

**Planner chọn bitmap nhưng index scan nhanh hơn 1,7 lần** — dù cùng đọc y hệt 4.589 buffer.

Vì sao? Bitmap phải làm thêm một bước: dựng bitmap trong RAM rồi sắp xếp (1,2 ms trong tổng 4,5 ms). Chi phí đó chỉ đáng bỏ ra khi nó **tiết kiệm được I/O thật**. Ở đây mọi page đã nằm trong shared_buffers (`hit=4589, read=0`) nên chẳng có I/O nào để tiết kiệm — bước sắp xếp thành lãng phí thuần.

Planner không biết page nào đang trong cache. Nó dùng `random_page_cost = 4.0`, giả định mỗi lần nhảy ngẫu nhiên đắt gấp 4 lần đọc tuần tự. Trong RAM thì tỷ lệ đó là **1,0**, không phải 4,0.

### MỨC CAO — device 1 (107.947 dòng, 2,159 %)

| Kiểu scan | planner chọn? | total cost | actual time | buffers | ghi chú |
|---|---|---|---|---|---|
| **Bitmap Heap Scan** | ✅ | 39.726,54 | 132,527 ms | 35.055 | `Heap Blocks: exact=34.962` |
| **Index Scan** | | 150.306,13 | **97,367 ms** | 35.055 | ⬅ nhanh hơn 1,36× |
| Seq Scan | | 99.721,17 | 266,987 ms | 36.958 | |

**Đây là chỗ thú vị nhất hôm nay.**

Planner tin Index Scan tốn **150.306** cost — đắt hơn Seq Scan (99.721) tận 1,5 lần, nên loại thẳng. Thực tế Index Scan chạy **97 ms**, nhanh hơn Seq Scan (267 ms) **2,7 lần** và nhanh hơn cả lựa chọn của planner (132 ms).

**Planner sai 4 lần theo chiều bảo thủ.** Cost của nó cho Index Scan là 150.306 trong khi lẽ ra phải thấp hơn cả bitmap (39.726).

### Vậy planner chọn sai ở đâu — và vì sao nó vẫn hợp lý

Sai ở **cả 2 mức GIỮA và CAO**, luôn theo cùng một chiều: **đánh giá Index Scan đắt hơn thực tế**.

Thủ phạm là một con số duy nhất:

```
random_page_cost = 4.0     -- mặc định, mô tả ổ ĐĨA CƠ năm 2000
```

Lab chạy trên SSD/NVMe, và hầu hết page đang nằm sẵn trong RAM. Tỷ lệ random/sequential thật ở đây gần **1,0–1,1**, không phải 4,0.

Chú ý điều quan trọng: `Heap Blocks: exact=34.962` trên tổng 36.958 page = **94,6 % số page của bảng**. Lấy 2,16 % số dòng nhưng phải chạm 94,6 % số page — đó là `correlation ≈ 0` (§2). Index gần như không giúp giảm số page phải đọc; nó chỉ giúp **bỏ qua việc kiểm tra 4,89 triệu dòng không khớp**. Chính khoản CPU đó là cái nó thắng.

> **Câu trả lời đúng cho "index có mà planner không dùng": planner ước lượng số dòng khớp lớn hơn điểm hoà vốn CỦA MÔ HÌNH COST NÓ ĐANG DÙNG. Hai chỗ có thể sai — ước lượng số dòng (tuần 3) hoặc chính mô hình cost (`random_page_cost`, `effective_cache_size` — Day 14). Rất hiếm khi câu trả lời là "planner ngu".**

Ở đây ước lượng số dòng rất chính xác (105.499 đoán vs 107.947 thật = lệch 2,3 %). Vấn đề nằm hoàn toàn ở **mô hình cost**, không phải ở thống kê.

---

## §2. `correlation` — con số quyết định tất cả

```
  attname  | n_distinct | correlation
-----------+------------+--------------
 ts        |         -1 | 1,000        <- HOÀN HẢO
 key_id    |          8 | 0,157
 device_id |      28142 | 0,0054       <- gần như ngẫu nhiên
```

`correlation` = mức tương quan giữa **thứ tự logic của giá trị** và **thứ tự vật lý trên đĩa**. Từ −1 đến 1.

| | `ts` (corr = 1) | `device_id` (corr = 0,005) |
|---|---|---|
| Ý nghĩa | dữ liệu ghi theo thời gian, append-only | mỗi lần ghi là một device ngẫu nhiên |
| Các dòng khớp nằm ở đâu | **liền kề nhau** trong vài page | **rải khắp** cả bảng |
| Đọc 100.000 dòng cần | ~740 page liên tiếp | **34.962 page rải rác** |
| Index scan giống | đọc tuần tự | nhảy ngẫu nhiên |

`n_distinct = -1` của `ts` nghĩa là "mọi giá trị đều phân biệt" (số âm = tỷ lệ so với số dòng). Hợp lý với timestamp có micro-giây.

**Dự đoán: cột `ts` sẽ có điểm hoà vốn cao hơn nhiều.** §4 kiểm chứng.

---

## §4. Tìm điểm hoà vốn trên `ts`

Bảng trải từ `2025-05-01` đến `2025-07-30` (91 ngày, 5 triệu dòng).

| Khoảng | rows | **% bảng** | Kiểu scan | buffers | actual time |
|---|---|---|---|---|---|
| 1 giờ | 2.305 | 0,046 % | Index Scan | 917 | **0,77 ms** |
| 6 giờ | 13.891 | 0,28 % | Index Scan | 5.345 | 4,01 ms |
| 1 ngày | 55.563 | 1,11 % | Index Scan | 21.403 | 15,95 ms |
| 3 ngày | 166.672 | 3,33 % | Index Scan | 64.487 | 48,96 ms |
| 1 tuần | 388.901 | 7,78 % | Index Scan | 150.593 | 123,04 ms |
| 2 tuần | 777.792 | 15,56 % | Index Scan | 300.102 | 256,11 ms |
| **1 tháng** | **1.666.668** | **33,33 %** | **Index Scan** | 640.599 | 478,23 ms |
| **2 tháng** | **3.277.859** | **65,56 %** | **Seq Scan** ⬅ | **36.958** | 604,58 ms |

### Điểm lật

**Trên `ts`: giữa 33,3 % và 65,6 %.** Postgres giữ index scan tới tận **một phần ba bảng**.

Không có bước bitmap nào cả — nhảy thẳng từ Index Scan sang Seq Scan. Vì với `correlation = 1`, bitmap chẳng có gì để sắp xếp lại: các TID đã ra theo đúng thứ tự page rồi.

### So với `device_id`

| Cột | correlation | Hành vi |
|---|---|---|
| `ts` | **1,0** | Index Scan tới **33 %**, rồi thẳng sang Seq Scan |
| `device_id` | **0,005** | **Bitmap** từ rất sớm, không bao giờ dùng Index Scan thuần |

Cùng một bảng, cùng một máy, cùng mọi GUC. Khác nhau **duy nhất một con số**: correlation.

### Giải thích bằng buffers

| | `ts` 1 tháng (1,67 triệu dòng) | `device_id`=1 (108k dòng) |
|---|---|---|
| dòng lấy được | 1.666.668 | 107.947 |
| **Heap Blocks phải chạm** | ~12.300 page phân biệt | **34.962 page** |
| dòng/page | ~135 (tối đa!) | **3,1** |

Với `ts`, lấy 1,67 triệu dòng chỉ cần chạm ~12.300 page phân biệt vì chúng **nằm liền nhau** — mỗi page đọc lên cho 135 dòng hữu ích, đúng bằng mật độ tối đa của bảng.

Với `device_id`, lấy 108 nghìn dòng phải chạm 34.962 page — mỗi page chỉ cho 3,1 dòng hữu ích. Hiệu suất **43 lần kém hơn**.

> **Đây là toàn bộ lý do BRIN tồn tại (Day 31) và là lý do partition theo thời gian hiệu quả (Day 32). Cả hai đều là cách nói: "hãy xếp những dòng hay đọc cùng nhau vào cùng chỗ trên đĩa".**

### ⚠️ Chi tiết bị bỏ sót: buffers của Index Scan tăng phi tuyến

Nhìn cột buffers ở bảng `ts`: 1 tháng đọc **640.599 buffer** = 5 GB, trong khi cả bảng chỉ 289 MB. Seq Scan ở 2 tháng chỉ đọc **36.958**.

Đây lại là hiện tượng "đếm lượt truy cập" của Day 03: Index Scan chạm cùng một page nhiều lần (một lần cho mỗi dòng trong page đó). 1.666.668 dòng ÷ 640.599 lượt ≈ 2,6 dòng mỗi lượt.

Chi phí đó **rẻ** vì page đang trong shared_buffers (`hit=636.652 read=3.947` — 99,4 % hit). Nhưng nó không miễn phí: 478 ms cho 33 % bảng, so với 605 ms cho 66 % bảng bằng seq scan. Ở mức 33 % thì index scan chỉ còn nhanh hơn ~1,3 lần **khi tính trên mỗi dòng** — đúng vùng hoà vốn.

---

## §5. Bitmap lossy

Ép bitmap (`enable_seqscan=off, enable_indexscan=off`) trên `device_id < 100` (626.145 dòng, 12,5 % bảng):

| work_mem | Heap Blocks | Rows Removed by **Index Recheck** | buffers | **actual time** |
|---|---|---|---|---|
| **64kB** | `exact=386 lossy=36.572` | **4.326.827** | 37.493 | **605,5 ms** |
| **1MB** | `exact=12.239 lossy=24.719` | 2.921.983 | 37.493 | 474,3 ms |
| **256MB** | `exact=36.958 lossy=0` | **0** | 37.493 | **241,2 ms** |

**Chậm 2,5 lần chỉ vì thiếu RAM cho bitmap.**

### Cơ chế

Bitmap cần 1 bit cho mỗi **dòng** để nhớ chính xác dòng nào khớp. Bảng 5 triệu dòng → cần ~600 KB chỉ cho bitmap.

Khi `work_mem` không đủ, Postgres **hạ độ phân giải**: thay vì nhớ "dòng thứ 47 của page 1234 khớp", nó chỉ nhớ "page 1234 **có thể** có dòng khớp". Đó là **lossy**.

Hậu quả: đọc page đó lên rồi phải **kiểm lại toàn bộ 135 dòng** trong page. Đó chính là dòng `Rows Removed by Index Recheck: 4.326.827` — hơn 4,3 triệu dòng bị đọc lên rồi vứt, **gần bằng cả bảng**.

```
work_mem 64kB  ->  4.326.827 dòng phải recheck  ->  605 ms
work_mem 256MB ->          0 dòng phải recheck  ->  241 ms
```

Chú ý: **buffers giống hệt nhau (37.493) ở cả 3 mức**. Số page đọc không đổi — cái đổi là **CPU phải kiểm bao nhiêu dòng trong mỗi page**. Đây là ca hiếm mà buffers không kể hết câu chuyện; phải nhìn `Rows Removed by Index Recheck`.

### `lossy` là dấu hiệu nên chỉnh gì

**Đừng vội tăng `work_mem`.** Thứ tự nên xét:

1. **Query đang lấy quá nhiều dòng** — 12,5 % bảng thì bitmap vốn đã ở ranh giới. Thêm điều kiện lọc, hoặc chấp nhận seq scan (ở đây planner tự chọn seq scan khi không bị ép: 322 ms, **nhanh hơn cả bitmap lossy 605 ms**).
2. **Composite index** để lọc chặt hơn ngay ở tầng index (§6).
3. **Chỉ khi hai cách trên không được** mới tăng `work_mem` — và nhớ nó là per node per connection (Day 03 §6).

Một quan sát đắt giá: khi để planner tự do ở `work_mem=64kB`, nó **chọn Seq Scan (322 ms)** thay vì bitmap lossy (605 ms). Planner đã tính đúng — cost model có mô hình hoá lossy. Trường hợp này planner khôn hơn người ép nó.

---

## §6. `BitmapAnd` — kết hợp nhiều index

Query: `device_id = 3 AND key_id = 1` → 7.905 dòng.

| Cách | Node | buffers | **actual time** |
|---|---|---|---|
| 2 index đơn: `(device_id)` + `(key_id)` | **BitmapAnd** | 8.299 | **48,7 ms** |
| composite `(device_id, key_id)` | Bitmap Index Scan | 7.132 | **7,8 ms** |

**Composite nhanh hơn 6,2 lần.**

### Plan `BitmapAnd`

```
->  BitmapAnd  (actual time=39.966..39.968 rows=0 loops=1)
      ->  Bitmap Index Scan on idx_tskv_dev   (actual time=1.983..1.983 rows=28522)
            Index Cond: (device_id = 3)
      ->  Bitmap Index Scan on idx_tskv_key   (actual time=37.011..37.011 rows=1362527)  <<<
            Index Cond: (key_id = 1)
```

Đây là chỗ đau: để lấy ra 7.905 dòng, nó phải **quét 1.362.527 entry** từ `idx_tskv_key` trước — mất 37 ms trong tổng 48,7 ms (**76 % thời gian**).

`key_id` chỉ có **8 giá trị phân biệt** (`n_distinct = 8`), nên `key_id = 1` khớp 27 % bảng. Index trên một cột 8 giá trị gần như vô dụng khi đứng một mình.

Với composite `(device_id, key_id)`, cây B-tree đi thẳng tới nhánh `device_id=3` rồi trong đó tới `key_id=1` — đọc đúng **9 page index** thay vì 1.176.

### Khi nào BitmapAnd đáng dùng

| Tình huống | Chọn |
|---|---|
| Bộ điều kiện **cố định**, biết trước | **Composite index** — luôn thắng |
| Nhiều tổ hợp điều kiện tuỳ ý (query builder, filter động) | 2–3 index đơn + để BitmapAnd lo |
| Điều kiện `OR` giữa các cột | `BitmapOr` — composite không giúp được |

Chi phí đĩa cũng phải tính:

```
 idx_tskv_dev     |  34 MB
 idx_tskv_key     |  33 MB
 idx_tskv_dev_key |  45 MB
 idx_tskv_ts      | 107 MB   <- đắt nhất, vì timestamp 8 byte + mọi giá trị phân biệt
```

Hai index đơn = 67 MB và **chậm hơn 6 lần**. Một composite = 45 MB. Composite thắng cả về dung lượng lẫn tốc độ ở đây.

> **Quy tắc: nếu bộ điều kiện là cố định và hay dùng, luôn ưu tiên composite index. BitmapAnd là phương án cho trường hợp anh KHÔNG BIẾT TRƯỚC tổ hợp nào sẽ được dùng.**

Chú ý `idx_tskv_ts` nặng **107 MB** — hơn gấp đôi các index khác, và bằng 37 % bảng. Đây là lý do BRIN hấp dẫn cho cột thời gian: Day 31 sẽ cho thấy BRIN làm cùng việc với **~50 KB**.

---

## §7. Bảng tra nhanh — đã kiểm chứng bằng số

| Triệu chứng trong plan | Nghĩa | Số liệu từ lab |
|---|---|---|
| `Seq Scan` + `Rows Removed by Filter` rất lớn | thiếu index hoặc selectivity quá thấp để index có ích | device 50000: bỏ 4.999.987 dòng, 300 ms |
| `Index Scan` mà buffers ≫ số page bảng | đang chạm lại page nhiều lần — kiểm tra correlation | `ts` 1 tháng: 640.599 buffer / bảng 36.958 page |
| `Heap Blocks: lossy=N` lớn | `work_mem` không đủ cho bitmap | 64kB: lossy=36.572, recheck 4,3 triệu dòng, chậm 2,5× |
| `Rows Removed by Index Recheck` > 0 | hệ quả trực tiếp của lossy | 0 khi work_mem đủ |
| `Heap Blocks: exact` ≈ số page bảng | index không giảm được I/O, chỉ giảm CPU | device 1: exact=34.962 / 36.958 = 94,6 % |
| `Recheck Cond` xuất hiện | bình thường với bitmap, **không phải lỗi** | có ở mọi bitmap scan |
| `BitmapAnd` | đang kết hợp nhiều index — cân nhắc composite | 48,7 ms vs 7,8 ms composite |
| `Index Only Scan` + `Heap Fetches: 0` | không đụng bảng — **cẩn thận khi benchmark** | device 1: 95 buffer cho 108k dòng |

---

## Bảng số liệu chính

| Kịch bản | node plan chính | actual time | buffers | ghi chú |
|---|---|---|---|---|
| device 50000 (0,0003 %) tự chọn | Bitmap Heap Scan | **0,049 ms** | 16 | exact=13 |
| device 50000 ép Seq | Seq Scan | 299,6 ms | 36.958 | chậm **6.100×** |
| device 29 (0,098 %) tự chọn | Bitmap Heap Scan | 4,57 ms | 4.589 | |
| device 29 ép Index Scan | Index Scan | **2,63 ms** | 4.589 | planner chọn thua 1,7× |
| device 1 (2,16 %) tự chọn | Bitmap Heap Scan | 132,5 ms | 35.055 | exact=34.962 (94,6 % bảng) |
| device 1 ép Index Scan | Index Scan | **97,4 ms** | 35.055 | planner chọn thua 1,36× |
| device 1 ép Seq | Seq Scan | 267,0 ms | 36.958 | |
| `ts` 1 tháng (33,3 %) | **Index Scan** | 478,2 ms | 640.599 | vẫn dùng index ở 1/3 bảng |
| `ts` 2 tháng (65,6 %) | **Seq Scan** | 604,6 ms | 36.958 | điểm lật |
| `device_id<100` work_mem 64kB | Bitmap **lossy=36.572** | **605,5 ms** | 37.493 | recheck 4,33 triệu dòng |
| `device_id<100` work_mem 256MB | Bitmap exact=36.958 | **241,2 ms** | 37.493 | nhanh **2,5×** |
| `dev=3 AND key=1` 2 index đơn | **BitmapAnd** | 48,7 ms | 8.299 | quét 1,36 triệu entry key_id |
| `dev=3 AND key=1` composite | Bitmap Index Scan | **7,8 ms** | 7.132 | nhanh **6,2×** |

---

## A. "Có index mà Postgres không dùng" — trả lời bằng chi phí I/O

Postgres không dùng index khi nó ước lượng **số dòng khớp vượt điểm hoà vốn**, và điểm hoà vốn được quyết định bởi một câu hỏi duy nhất: *lấy N dòng đó phải chạm bao nhiêu page phân biệt?*

Ở lab này, lấy 107.947 dòng qua `device_id` (2,16 % bảng) phải chạm **34.962 page** — tức **94,6 % số page của cả bảng** — vì `correlation` của `device_id` chỉ **0,005**, các dòng nằm rải rác. Đọc 94,6 % bảng bằng random I/O (planner định giá gấp 4 lần tuần tự) thì đắt hơn đọc 100 % bảng tuần tự. Planner tính Index Scan = **150.306** cost so với Seq Scan = **99.721** và loại nó.

Ngược lại, trên cột `ts` với `correlation = 1`, lấy **33,3 %** số dòng vẫn dùng index — vì các dòng nằm liền kề, mỗi page đọc lên cho 135 dòng hữu ích thay vì 3,1.

Nên câu trả lời không bao giờ là "planner ngu", mà là một trong ba: **(a)** ước lượng số dòng sai (tuần 3), **(b)** mô hình cost lệch với phần cứng thật — `random_page_cost = 4.0` là số của ổ đĩa cơ, trên SSD nên là 1,1 (Day 14), hoặc **(c)** planner đúng, index thật sự không giúp được. Ở lab này là **(b)**: ước lượng chỉ lệch 2,3 % nhưng planner vẫn chọn thua tối ưu 1,36 lần.

---

## Ba điều dễ hiểu sai

| # | Hiểu nhầm | Sự thật đo được |
|---|---|---|
| 1 | "Selectivity dưới 5 % thì index luôn thắng" | Điểm lật phụ thuộc **correlation**, không phải selectivity. `ts` dùng index tới **33 %**; `device_id` không bao giờ dùng Index Scan thuần |
| 2 | "Planner luôn chọn plan nhanh nhất" | Ở **cả 2 mức** GIỮA và CAO, plan bị ép lại nhanh hơn (1,7× và 1,36×). Cost model bảo thủ với random I/O |
| 3 | "Bitmap luôn nằm giữa index scan và seq scan về tốc độ" | Bitmap **lossy** (605 ms) chậm hơn cả Seq Scan (322 ms). Thiếu `work_mem` thì bitmap là lựa chọn tệ nhất |

Thêm một điều về phương pháp: **`count(*)` không phải query để benchmark cách truy cập bảng** — nó cho index-only scan, không chạm heap. Phải dùng cột không nằm trong index.

---

## Áp dụng vào hệ thật

**1. Đo `correlation` trước khi quyết định chiến lược index:**

```sql
SELECT tablename, attname, n_distinct, correlation,
       CASE
         WHEN abs(correlation) > 0.9 THEN 'BRIN được / index scan tới ~30% bảng'
         WHEN abs(correlation) < 0.1 THEN 'chỉ bitmap; cân nhắc CLUSTER hoặc composite'
         ELSE 'trung bình'
       END AS goi_y
FROM pg_stats
WHERE schemaname = 'public' AND n_distinct <> 0
ORDER BY abs(correlation) DESC;
```

Trong hệ IoT/ThingsBoard điển hình:

| Cột | correlation dự kiến | Chiến lược |
|---|---|---|
| `ts_kv.ts`, `alarm.start_ts`, `*.created_at` | **≈ 1** (append-only) | **BRIN** — nhỏ hơn B-tree ~2.000 lần (Day 31). Hoặc partition theo tháng |
| `device_id`, `tenant_id`, `user_id` | **≈ 0** | B-tree composite, luôn đặt cột này **đứng đầu** |
| `status`, `severity` (ít giá trị) | không quan trọng | **Partial index** thay vì index thường (Day 09) |

**2. Xét `random_page_cost` — thay đổi 1 dòng, tác động toàn hệ:**

```sql
-- Mặc định 4.0 là số của ổ đĩa cơ. Trên SSD/NVMe:
ALTER SYSTEM SET random_page_cost = 1.1;
ALTER SYSTEM SET effective_cache_size = '<~75% RAM>';
SELECT pg_reload_conf();
```

Đây là thay đổi có **tỷ lệ lợi ích/rủi ro cao nhất** trong cả tuần. Ở lab, nó sẽ khiến planner chọn Index Scan ở mức CAO — nhanh hơn 1,36 lần mà không tạo thêm index nào.

Nhưng **phải đo trước/sau**, không đổi mù: hạ `random_page_cost` làm planner ưa index hơn ở *mọi* query, kể cả những chỗ nó đang đúng. Day 14 làm bài này tử tế.

**3. Bật `log_temp_files` và theo dõi bitmap lossy.** Lossy không vào log, nhưng nó luôn đi kèm query nặng — tìm trong `pg_stat_statements` các câu có `shared_blks_read` cao mà `rows` thấp.

**4. Khi có bộ điều kiện cố định, dùng composite thay vì nhiều index đơn.** Đo được 6,2 lần nhanh hơn và tốn ít đĩa hơn. Ngoại lệ: query builder / filter động — lúc đó BitmapAnd mới là đúng.

**5. Dùng `enable_*` để kiểm chứng, không phải để sửa.**

```sql
SET enable_seqscan = off;   -- xem plan thay thế, so số liệu
EXPLAIN (ANALYZE, BUFFERS) ...;
RESET ALL;
```

**Không bao giờ đặt các GUC này trong `postgresql.conf` production.** Chúng cộng `disable_cost` = 10 tỷ, không phải cấm — plan sẽ méo mó theo cách khó lường ở query phức tạp.

---

## Câu hỏi mở sang các ngày sau

1. Cây B-tree của `idx_tskv_ts` (107 MB) cao mấy tầng, một lần lookup tốn tối thiểu bao nhiêu page? → **Day 06**
2. Composite thắng BitmapAnd 6,2 lần. Nếu đảo thứ tự thành `(key_id, device_id)` thì sao? → **Day 07**
3. `Index Only Scan` với `Heap Fetches: 0` — điều kiện nào để đạt được, và khi nào nó hỏng? → **Day 08**
4. Planner sai vì `random_page_cost = 4.0`. Đổi xuống 1.1 thì plan lật ở đâu, tính tay cost thế nào? → **Day 14**
5. `ts` có correlation = 1 và index B-tree nặng 107 MB. BRIN làm cùng việc với bao nhiêu KB? → **Day 31**
6. Điểm hoà vốn 33 % trên `ts` — partition theo tháng có xoá được câu hỏi này không? → **Day 32**
