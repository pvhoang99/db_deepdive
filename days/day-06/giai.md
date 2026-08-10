# Day 06 — Lời giải: Bên trong B-tree — index thật sự nằm thế nào trên đĩa

> Bài chữa. Đo thật trên lab `SCALE=1`, dùng `pageinspect` để nhìn thẳng vào byte trên đĩa.

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án | Bẫy |
|---|---|---|---|
| 1 | `idx_tskv_dev` (5M dòng, bigint) cao mấy tầng? | `level = 2` → **3 tầng** (lá + internal + root) | Đa số đoán 4–5 tầng. Fanout lớn hơn ta tưởng nhiều |
| 2 | Index Scan tìm 1 dòng đọc tối thiểu bao nhiêu page? | **4** = root + internal + lá + 1 page heap | Đa số quên page heap, hoặc quên meta page |
| 3 | `idx_dev_name` (50k dòng, text) vs `idx_tskv_dev` (5M, bigint) — cái nào cao hơn? | **`idx_tskv_dev` cao hơn** (level 2 vs level 1) | Bẫy: 100 lần ít dòng hơn thắng cả việc khoá rộng gấp 3 |

Câu 3 đáng dừng lại: `idx_dev_name` có khoá rộng hơn (24 byte vs 8) nhưng vẫn **thấp hơn một tầng**, vì nó chỉ có 50.000 dòng thay vì 5 triệu. Số dòng thắng độ rộng khoá — trừ khi khoá rất rộng (§4).

---

## §1. Cấu trúc cây thật

```
SELECT * FROM bt_metap('idx_tskv_dev');

 magic  | version | root | level | fastroot | fastlevel | allequalimage
--------+---------+------+-------+----------+-----------+---------------
 340322 |       4 |  209 |     2 |      209 |         2 | t
```

| Trường | Giá trị | Nghĩa |
|---|---|---|
| `root` | **209** | page số 209 là gốc — **không phải page 0** (page 0 là meta page) |
| `level` | **2** | chiều cao tính từ lá = 0 → cây có **3 tầng** |
| `fastroot` | 209 | trùng `root` = cây khoẻ. Khác nhau nghĩa là tầng trên đã bị xoá gần hết sau nhiều DELETE |
| `allequalimage` | `t` | **điều kiện để deduplication hoạt động** (§6) |

### Page root

```
 blkno | type | live_items | avg_item_size | free_size | btpo_level
-------+------+------------+---------------+-----------+------------
   209 | r    |         18 |            19 |      7732 |          2
```

Root chỉ có **18 entry** và còn trống **7.732/8.192 byte (94 %)**. Bình thường — root chỉ đầy dần khi cây cao thêm tầng.

### 12 page đầu

```
 blkno | type | live_items | avg_item_size | free_size
-------+------+------------+---------------+-----------
     1 | l    |         10 |           729 |       812
     2 | l    |         10 |           729 |       812
     3 | i    |        204 |            23 |      2452     <- internal
     4 | l    |         10 |           729 |       812
   ... (còn lại đều là 'l')
```

`l` = leaf, `i` = internal, `r` = root. Postgres **trộn lẫn** các loại page trong file, không xếp theo tầng.

### 💡 Con số bất thường phải giải thích: `avg_item_size = 729`

Index trên `bigint` mà mỗi entry **729 byte**? Và mỗi page lá chỉ chứa **10 entry**?

Đó là **deduplication** đang chạy. So với `idx_tskv_ts` (cùng bảng, khoá cũng 8 byte, nhưng giá trị gần như duy nhất):

| | `idx_tskv_dev` (device_id, lặp nhiều) | `idx_tskv_ts` (ts, duy nhất) |
|---|---|---|
| `live_items` mỗi page lá | **10** | **367** |
| `avg_item_size` | **729 byte** | **16 byte** |
| kích thước index | **34 MB** | **107 MB** |

`ts_kv` có 5 triệu dòng nhưng chỉ **28.142 device phân biệt** — mỗi device lặp trung bình 178 lần. Thay vì lưu 178 entry `(device_id, TID)`, B-tree gộp thành **một** entry `(device_id, [danh sách 178 TID])` — gọi là **posting list**.

Nên "10 entry mỗi page" thật ra là **10 posting list**, chứa hàng nghìn TID. §6 đo cái giá/lợi của cơ chế này.

---

## §2. Cấu trúc một page index

### Entry trong page lá

```
 itemoffset |   ctid    | itemlen |          data
------------+-----------+---------+-------------------------
          1 | (16,4097) |      24 | 01 00 00 00 00 00 00 00     <- HIGH KEY
          2 | (16,8324) |     808 | 01 00 00 00 00 00 00 00     <- posting list
          3 | (16,8324) |     808 | 01 00 00 00 00 00 00 00
```

**`itemoffset = 1` là high key** — nó không trỏ tới dòng nào. Nó nói *"mọi khoá trong page này đều ≤ giá trị này"*. Dùng cho thuật toán Lehman-Yao: khi một tiến trình đang đi xuống mà page bị tách bởi tiến trình khác, high key cho phép nó phát hiện và đi ngang sang page mới thay vì trèo lại từ đầu.

Đây là lý do **B-tree của Postgres đọc song song rất tốt**: không cần khoá toàn cây khi tách page.

`data = 01 00 00 00 00 00 00 00` là số `1` ở dạng little-endian 8 byte → đây là các entry của `device_id = 1` (device nóng nhất, 107.947 dòng).

### `itemlen` — trả lời câu hỏi của đề

| Loại entry | `itemlen` | Bóc tách |
|---|---|---|
| High key | **24 byte** | 8 (IndexTuple header) + 8 (key bigint) + 6 (TID) + 2 (padding căn 8 byte) |
| Posting list | **808 byte** | 8 (header) + 8 (key) + 6×132 (132 TID) ≈ 808 |

**Với entry thường (không dedup), 24 byte cho một khoá 8 byte — phần dư 16 byte đi đâu:**

```
IndexTupleData header    8 byte   (t_tid 6 byte + t_info 2 byte)
key (bigint)             8 byte
TID                      6 byte   ← nằm trong header ở trên
padding căn 8 byte       2 byte
─────────────────────────────────
                        24 byte   → overhead 200 %
```

Cộng thêm **4 byte ItemId** ở đầu page cho mỗi entry → thực chi **28 byte cho 8 byte dữ liệu**.

> **Bài học: index B-tree luôn tốn ít nhất ~3 lần kích thước khoá.** Đây là lý do index trên `smallint` không tiết kiệm được bao nhiêu so với `bigint` — overhead cố định lấn át.

### Entry trong page internal (root)

```
 itemoffset |    ctid     | itemlen |          data
------------+-------------+---------+-------------------------
          1 | (3,0)       |       8 |                              <- "minus infinity"
          2 | (208,4097)  |      24 | 07 00 00 00 00 00 00 00
          3 | (414,4097)  |      24 | 2d 00 00 00 00 00 00 00      <- 0x2d = 45
          4 | (620,4097)  |      24 | 95 00 00 00 00 00 00 00      <- 0x95 = 149
```

Ở page internal, `ctid` **không trỏ vào heap** — nó trỏ tới **page con** (block 3, 208, 414, 620...).

`itemoffset = 1` có `itemlen = 8` và `data` rỗng: đó là entry "âm vô cực" — mọi khoá nhỏ hơn entry thứ 2 đều đi xuống nhánh này. Chỉ page ngoài cùng bên trái mới có.

Đọc được cấu trúc dẫn đường: `device_id < 7` → page 3; `7 ≤ device_id < 45` → page 208; `45 ≤ device_id < 149` → page 414. Khoảng hẹp dần ở đầu vì device nhỏ có nhiều dòng hơn (power-law).

---

## §3. Fanout và chiều cao cây

### Bảng đo được

| Bảng | Số dòng | `level` | **Số tầng** | Kích thước index |
|---|---|---|---|---|
| `t_small` | 1.000 | **1** | 2 | 40 kB |
| `t_med` | 200.000 | **2** | 3 | 4.408 kB |
| `ts_kv(device_id)` | 5.000.000 | **2** | 3 | 34 MB |
| `ts_kv(ts)` | 5.000.000 | **2** | 3 | 107 MB |

**5.000 lần nhiều dòng hơn (1.000 → 5.000.000) mà cây chỉ cao thêm MỘT tầng.**

### Fanout thực tế

| Index | Page internal `live_items` | `avg_item_size` | Dự đoán lý thuyết |
|---|---|---|---|
| `idx_tskv_dev` | **204** | 23 byte | ~340 |
| `idx_tskv_ts` | **285** | 15 byte | ~340 |

Fanout thật (204–285) **thấp hơn dự đoán 340** khoảng 20–40 %. Ba lý do:

1. **Page internal không được lấp đầy 100 %.** `free_size = 2.452` trên 8.192 → chỉ dùng **70 %**. B-tree cố ý chừa chỗ để tránh tách page khi có chèn mới.
2. **Công thức lý thuyết bỏ sót ItemId 4 byte** ở đầu page cho mỗi entry.
3. **`idx_tskv_dev` có `avg_item_size = 23`** — cao hơn 15 của `idx_tskv_ts` vì khoá `device_id` cần thêm thông tin cho posting list.

Kiểm chứng ngược cho `idx_tskv_ts`: `(8192 − 24 − 16) × 0,7 ÷ (15 + 4) = 297` ≈ 285 thật ✓

### Kiểm chứng chiều cao bằng fanout thật

```
fanout ≈ 285
2 tầng: 285 × 367 (entry mỗi lá)     ≈    104.595 dòng
3 tầng: 285 × 285 × 367              ≈ 29.809.575 dòng
```

5 triệu dòng nằm giữa → **3 tầng**. ✓ Khớp `level = 2`.

### Con số đáng nhớ nhất về B-tree

> **Dữ liệu tăng ~285 lần thì cây chỉ cao thêm MỘT tầng.**

| Số dòng | Số tầng (fanout 285) |
|---|---|
| 100.000 | 2 |
| 30.000.000 | 3 |
| 8.000.000.000 | 4 |
| 2.400.000.000.000 | 5 |

**Bảng 8 tỷ dòng chỉ tốn hơn bảng 100.000 dòng đúng 2 lần đọc page.** Và hai page tầng trên gần như luôn nằm sẵn trong `shared_buffers` (root chỉ có 1 page, tầng internal chỉ vài chục page — tổng dưới 1 MB).

### Trả lời câu §0 số 2: một lookup tốn tối thiểu bao nhiêu page

```
① meta page (block 0)      -> gần như LUÔN trong shared_buffers
② root page                 -> gần như LUÔN trong shared_buffers
③ internal page             -> thường trong shared_buffers
④ leaf page                 -> thường phải đọc
⑤ heap page                 -> phải đọc (trừ index-only scan)
```

**5 lượt truy cập buffer, nhưng chỉ ~2 lần I/O thật.** Kiểm chứng bằng số liệu Day 04:

```
device 50000 (13 dòng): Buffers: shared hit=15 read=4   -> chỉ 4 page phải đọc
```

---

## §4. Khoá càng rộng, cây càng tệ

| Index | Cột | Kiểu | size | pages | `level` | `avg_item` |
|---|---|---|---|---|---|---|
| `idx_tskv_ts` | `ts` (5M) | timestamptz 8 B | **107 MB** | 13.713 | 2 | 16 |
| `idx_tskv_dev` | `device_id` (5M) | bigint 8 B | **34 MB** | 4.345 | 2 | 729* |
| `idx_dev_name` | `name` (50k) | text ~15 ký tự | 1.552 kB | 194 | 1 | 24 |
| `idx_dev_uuid` | `uuid` (50k) | uuid 16 B | **1.552 kB** | 194 | 1 | 24 |
| `device_pkey` | `id` (50k) | bigint 8 B | **1.184 kB** | 148 | 1 | 16 |
| `idx_dev_meta_txt` | `meta::text` (50k) | text dài | 400 kB† | 50 | 1 | 700 |

\* dedup · † xem ghi chú dưới

### `uuid` so với `bigint` — đo trên cùng bảng `device`

```
device_pkey  (bigint) : 1.184 kB, 148 page, avg_item 16 byte
idx_dev_uuid (uuid)   : 1.552 kB, 194 page, avg_item 24 byte
```

**Index trên `uuid` to hơn `bigint` 31 %** (1.552/1.184), số page nhiều hơn 31 %, mỗi entry rộng hơn 50 % (24 vs 16 byte).

Con số 31 % nghe không đáng sợ. Nhưng đó **chưa phải cái giá chính** — cái giá chính nằm ở §5.

### ⚠️ `idx_dev_meta_txt` chỉ 400 kB — bẫy phải giải thích

Index trên `meta::text` (jsonb dài) lại **nhỏ hơn** index trên `name`? Vô lý — cho tới khi nhìn `avg_item = 700`.

Giải thích: khoá quá dài thì B-tree phải **TOAST/nén** giá trị, và nhiều `meta` giống hệt nhau nên dedup gộp lại. Con số 400 kB không phản ánh chi phí thật — chi phí thật nằm ở **CPU giải nén mỗi lần so sánh**, và ở việc index này gần như không dùng được cho query thật.

Với khoá dài, B-tree còn có giới hạn cứng: **key không được vượt ~1/3 page (2.704 byte)**, vượt thì `CREATE INDEX` báo lỗi. Đây là lý do không index được cột text tự do.

> **Quy tắc: cần index cột text dài (URL, path, email) thì index trên `md5(col)` hoặc `left(col, 32)` bằng expression index, hoặc dùng hash index nếu chỉ cần so sánh bằng.**

### Bảng tham chiếu (điều chỉnh theo số đo thật)

| Kiểu khoá | Độ rộng | `avg_item` thật | Fanout ước lượng | Tầng cho 5M dòng |
|---|---|---|---|---|
| `int` | 4 B | ~12 B | ~360 | 3 |
| `bigint` | 8 B | **16 B** | **~285** | 3 |
| `uuid` | 16 B | **24 B** | ~200 | 3 |
| `text` ~60 B | 60 B | ~68 B | ~80 | 4 |
| `text` ~200 B | 200 B | ~208 B | ~28 | 5 |

---

## §5. Page split — cái giá thật của UUID v4

### Số đo

| | `t_seq` (bigserial, tăng dần) | `t_rnd` (uuid v4, ngẫu nhiên) |
|---|---|---|
| số dòng | 500.000 | 500.000 |
| **kích thước index** | **11 MB** (1.374 page) | **19 MB** (2.441 page) |
| **`free_size` trung bình mỗi lá** | **808 byte** (dùng 90 %) | **2.226 byte** (dùng **73 %**) |
| **thời gian INSERT** | **1.191 ms** | **2.273 ms** |

### Ba con số, ba cái giá khác nhau

**1. Index to hơn 73 %** (19 MB vs 11 MB) — dù cùng 500.000 dòng.

Bóc tách: uuid rộng gấp đôi bigint (đóng góp ~50 %), page chỉ đầy 73 % thay vì 90 % (đóng góp thêm ~23 %).

**2. Page chỉ đầy 73 %** — đây là dấu vân tay của page split 50/50.

Cơ chế: Postgres **nhận biết** khi chèn tăng dần và tách page theo tỷ lệ **90/10** thay vì 50/50 — vì nó biết chắc mọi khoá sau đó đều lớn hơn, page bên trái sẽ không bao giờ nhận thêm. Kết quả: `free_size = 808` (dùng 90 %).

Với uuid ngẫu nhiên, mọi page đều có thể nhận khoá mới, nên phải tách 50/50 để chừa chỗ. Ngay sau tách, cả hai page chỉ đầy 50 %; qua thời gian ổn định ở ~70 %. Đo được **73 %**. ✓

**3. INSERT chậm 1,9 lần** (2.273 vs 1.191 ms) — cái giá đắt nhất, và ít người nghĩ tới.

Vì sao:
- **Random write:** khoá tăng dần luôn chèn vào page ngoài cùng bên phải — page đó **luôn nóng trong shared_buffers**. Khoá ngẫu nhiên chèn vào page bất kỳ trong 2.441 page → cache miss liên tục.
- **Nhiều page split hơn:** tách 50/50 xảy ra thường xuyên hơn 90/10.
- **WAL nhiều hơn:** mỗi page split ghi full page image vào WAL. Day 37 đo.

Ở quy mô production (bảng 200 triệu dòng, index 40 GB không vừa RAM), chênh lệch này **không phải 1,9 lần mà là 10–50 lần** — vì mỗi lần chèn thành một lần đọc đĩa ngẫu nhiên.

### 🔧 Tình huống thực tế: PK là UUID v4

**Bối cảnh.** Service Java/Spring, `@Id @GeneratedValue UUID id` — mặc định của rất nhiều team. Bảng `event` 300 triệu dòng, index PK 24 GB, server 32 GB RAM.

**Triệu chứng.** Insert throughput giảm dần theo thời gian: tháng đầu 8.000 rows/s, sáu tháng sau 900 rows/s. Không ai đổi code.

**Chẩn đoán.** Index PK không còn vừa RAM. Mỗi INSERT phải đọc một page ngẫu nhiên từ đĩa để chèn vào. Với bigserial thì page đó luôn là page cuối, luôn trong cache — throughput **không giảm theo kích thước bảng**.

**Ước lượng cái giá (áp con số lab lên hệ thật):**

| Hạng mục | bigint | uuid v4 | Chênh |
|---|---|---|---|
| Index PK | ~14 GB | **24 GB** | +73 % |
| Mọi FK trỏ tới nó | ~14 GB mỗi FK | 24 GB mỗi FK | +73 % **nhân số bảng con** |
| Insert throughput | ổn định | **giảm dần** | 1,9× ở lab, tệ hơn nhiều ở quy mô thật |
| `correlation` cho scan theo thời gian | ≈ 1 | **≈ 0** | mất khả năng dùng BRIN (Day 31) |

**UUIDv7 có đáng không — câu trả lời có điều kiện:**

UUIDv7 nhúng timestamp mili-giây ở 48 bit đầu → **sắp tăng dần theo thời gian**. Nó lấy lại:
- ✅ tách page 90/10 → index chặt như bigserial
- ✅ chèn vào page nóng → insert nhanh, không giảm theo thời gian
- ✅ `correlation` ≈ 1 → BRIN dùng được, range scan theo thời gian hiệu quả
- ❌ vẫn rộng 16 byte → index vẫn to hơn bigint ~30 %
- ❌ **lộ thời điểm tạo bản ghi** — cân nhắc nếu là ID công khai

**Khuyến nghị:**

| Tình huống | Chọn |
|---|---|
| ID sinh ở server, một DB | **`bigint` identity** — rẻ nhất mọi mặt |
| Cần sinh ID ở client / merge nhiều nguồn | **UUIDv7**, không bao giờ v4 |
| Đang dùng UUID v4, bảng chưa lớn | Đổi sang v7 ngay — chỉ đổi hàm sinh, không đổi kiểu cột |
| Đang dùng UUID v4, bảng đã 100M+ | Chuyển dần: v7 cho bản ghi mới. Migration kiểu expand/contract → **Day 44** |

PG18 có `uuidv7()` sẵn. PG17 trở xuống thì dùng hàm tự viết hoặc thư viện phía app.

---

## §6. Deduplication

| Index | Cột | `deduplicate_items` | size | pages | Tiết kiệm |
|---|---|---|---|---|---|
| `idx_dedup_on` | `device_id` | **on** | **34 MB** | 4.345 | **−68 %** |
| `idx_dedup_off` | `device_id` | off | **107 MB** | 13.732 | — |
| `idx_ts_dedup_on` | `ts` | on | 107 MB | 13.713 | **0 %** |
| `idx_ts_dedup_off` | `ts` | off | 107 MB | 13.713 | — |

### Giải thích chênh lệch

| | `device_id` | `ts` |
|---|---|---|
| `n_distinct` | **28.142** | **5.000.000** (mọi giá trị duy nhất) |
| lặp trung bình | **178 lần** | **1 lần** |
| Gộp được không | ✅ 178 entry → 1 posting list | ❌ không có gì để gộp |
| Tiết kiệm | **68 %** (107 → 34 MB) | **0 %** |

Phép tính khớp: entry thường 16 byte × 178 = 2.848 byte cho một device. Posting list: 8 (header) + 8 (key) + 6×178 (TID) = 1.084 byte. Tỷ lệ 1.084/2.848 = **38 %** → tiết kiệm 62 %. Đo được 68 % (thêm phần tiết kiệm ItemId 4 byte mỗi entry). ✓

> **Luật: deduplication chỉ giúp khi khoá LẶP NHIỀU. Trên cột duy nhất (PK, timestamp) nó không làm gì cả — nhưng cũng không hại.**

### Điều kiện để dedup hoạt động: `allequalimage = t`

Ở §1 ta thấy `allequalimage = t`. Nó nghĩa là *"với kiểu dữ liệu này, hai giá trị bằng nhau thì biểu diễn nhị phân cũng giống hệt nhau"*.

Không phải kiểu nào cũng vậy:

| Kiểu | `allequalimage` | Vì sao |
|---|---|---|
| `int`, `bigint`, `uuid`, `timestamptz` | ✅ | so sánh nhị phân trực tiếp |
| `text` với collation C | ✅ | |
| **`text` với collation ICU/locale** | ❌ | `'a'` và `'A'` có thể "bằng nhau" theo collation nhưng khác byte |
| **`numeric`** | ❌ | `1.0` và `1.00` bằng nhau nhưng khác biểu diễn |

→ **Index trên `numeric` hoặc `text` có collation không dedup được.** Nếu có cột lặp nhiều kiểu `numeric`, đổi sang `bigint` (nhân 100 nếu cần 2 chữ số thập phân) tiết kiệm được rất nhiều.

Cái giá của dedup: một chút CPU khi chèn (phải kiểm tra có gộp được không) và khi tách posting list. Thực tế **luôn nên bật** — nó là mặc định từ PG13.

---

## Bảng số liệu chính

| Đối tượng | size | pages | level | avg_item | fanout thật | ghi chú |
|---|---|---|---|---|---|---|
| `idx_tskv_dev` (5M, bigint, lặp) | 34 MB | 4.345 | 2 | 729 | 204 | dedup: 10 posting list/lá |
| `idx_tskv_ts` (5M, timestamptz) | 107 MB | 13.713 | 2 | 16 | 285 | 367 entry/lá |
| `t_small` (1k) | 40 kB | 5 | **1** | — | — | 2 tầng |
| `t_med` (200k) | 4.408 kB | 551 | 2 | — | — | 3 tầng |
| `device_pkey` (50k, bigint) | 1.184 kB | 148 | 1 | 16 | — | |
| `idx_dev_uuid` (50k, uuid) | 1.552 kB | 194 | 1 | 24 | — | **to hơn 31 %** |
| `t_seq_pkey` (500k, tăng dần) | **11 MB** | 1.374 | — | — | — | free 808 B (đầy 90 %), insert **1.191 ms** |
| `t_rnd_pkey` (500k, uuid v4) | **19 MB** | 2.441 | — | — | — | free 2.226 B (đầy 73 %), insert **2.273 ms** |
| dedup on (device_id) | **34 MB** | 4.345 | 2 | — | — | **−68 %** |
| dedup off (device_id) | 107 MB | 13.732 | 2 | — | — | |
| dedup on/off (ts) | 107 MB | 13.713 | 2 | — | — | **0 %** |

---

## A. Bảng to gấp 100 lần thì sao

**500 triệu dòng: cây cao thêm ĐÚNG MỘT TẦNG** (3 → 4).

```
fanout 285:  285³ × 367 ≈ 8,5 tỷ dòng vẫn chỉ 4 tầng
```

Nói cách khác: 5 triệu → 500 triệu (100 lần) thêm 1 tầng; 500 triệu → 8 tỷ (16 lần nữa) **không thêm tầng nào**.

### Điều đó nói gì về khả năng scale của B-tree

**Về mặt số lần đọc page, B-tree scale gần như hoàn hảo** — chi phí tăng theo `log₂₈₅(N)`, tức gần như hằng số trong mọi kích thước thực tế. Một lookup trên bảng 8 tỷ dòng chỉ đắt hơn bảng 100.000 dòng **đúng 2 lần đọc page**.

### Nhưng cái gì mới thật sự hết scale — ba thứ, không thứ nào là chiều cao cây

**1. Index không còn vừa RAM.** Đây là điểm gãy thật.

```
5 triệu dòng   -> index 34–107 MB   -> vừa shared_buffers 256 MB    -> mọi lookup là hit
500 triệu dòng -> index 3,4–10 GB   -> KHÔNG vừa                    -> mỗi lookup là 1-2 random read đĩa
```

Chi phí không nhảy vì cây cao thêm tầng, mà vì **tầng lá rơi ra khỏi cache**. Từ 0,01 ms nhảy lên 0,1–1 ms — chậm 10–100 lần, trong khi số page đọc chỉ tăng 33 %.

**2. Chi phí GHI, không phải chi phí đọc.** §5 đã đo: insert vào index ngẫu nhiên chậm 1,9 lần ngay ở 500.000 dòng, và tỷ lệ này **xấu đi theo kích thước**. Với 5 index trên một bảng lớn, mỗi INSERT là 5 lần random write + 5 lần ghi WAL.

**3. VACUUM và bloat.** Index 10 GB cần vacuum lâu hơn, bloat tích luỹ nhiều hơn, `REINDEX` mất hàng giờ. Day 10 đo.

> **Kết luận: đừng lo cây cao. Lo index có vừa RAM không, và lo chi phí ghi.** Đó là lý do tuần 7 (partition, BRIN) tồn tại — không phải để làm cây thấp hơn, mà để **giảm lượng index phải giữ nóng**.

---

## Ba điều dễ hiểu sai

| # | Hiểu nhầm | Sự thật đo được |
|---|---|---|
| 1 | "Bảng lớn thì index lookup chậm hẳn vì cây cao" | 1.000 → 5.000.000 dòng chỉ thêm **1 tầng**. Cái chậm là index rơi khỏi RAM, không phải chiều cao |
| 2 | "UUID v4 chỉ tốn thêm dung lượng" | Dung lượng +73 %, nhưng **insert chậm 1,9×** và page chỉ đầy 73 % thay vì 90 %. Cái giá chính là ghi, không phải đọc |
| 3 | "Index trên bigint tốn 8 byte mỗi dòng" | Thật ra **28 byte** (24 itemlen + 4 ItemId). Overhead 250 % |

Thêm hai điều tinh vi:
- **Deduplication có thể làm `avg_item_size` lên 729 byte** và khiến page lá chỉ chứa 10 "entry" — đọc số này mà không biết dedup sẽ kết luận sai hoàn toàn.
- **`numeric` và `text` có collation không dedup được** (`allequalimage = f`) — có thể là lý do index của anh to hơn dự kiến 3 lần.

---

## Áp dụng vào hệ thật

**1. Kiểm tra PK của mọi bảng lớn:**

```sql
SELECT c.relname AS bang,
       a.attname AS cot_pk,
       t.typname AS kieu,
       pg_size_pretty(pg_relation_size(i.indexrelid)) AS size_pk,
       pg_size_pretty(pg_relation_size(c.oid)) AS size_bang
FROM pg_index i
JOIN pg_class c   ON c.oid = i.indrelid
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = i.indkey[0]
JOIN pg_type t    ON t.oid = a.atttypid
WHERE i.indisprimary AND c.relkind = 'r'
ORDER BY pg_relation_size(c.oid) DESC LIMIT 20;
```

`typname = 'uuid'` trên bảng lớn = đang trả giá. Ước lượng bằng bảng §5.

**2. Tìm index không dedup được (thường là thủ phạm index to bất thường):**

```sql
SELECT i.relname, pg_size_pretty(pg_relation_size(i.oid)) AS size,
       (SELECT allequalimage FROM bt_metap(i.relname)) AS dedup_duoc
FROM pg_class i JOIN pg_index x ON x.indexrelid = i.oid
WHERE i.relkind = 'i' AND x.indisvalid
  AND pg_relation_size(i.oid) > 100*1024*1024
ORDER BY pg_relation_size(i.oid) DESC;
```

`dedup_duoc = f` trên index của cột lặp nhiều = có thể tiết kiệm 60 %+ bằng cách đổi kiểu cột.

**3. Theo dõi "index có còn vừa RAM không" — chỉ số quan trọng nhất bài này:**

```sql
SELECT pg_size_pretty(sum(pg_relation_size(indexrelid))) AS tong_index,
       current_setting('shared_buffers') AS shared_buffers
FROM pg_stat_user_indexes WHERE idx_scan > 0;
```

Tổng index **đang được dùng** vượt `shared_buffers` = bắt đầu vào vùng nguy hiểm. Theo dõi tỷ lệ này theo tháng — nó là chỉ báo sớm cho ngày throughput sụp.

**4. Đừng index cột text dài.** Dùng expression index:
```sql
CREATE INDEX ON docs (md5(url));            -- tra cứu bằng
-- query:  WHERE md5(url) = md5($1)
CREATE INDEX ON docs (left(path, 32));      -- tra cứu tiền tố
```

**5. Nếu đang dùng UUID v4 và bảng còn nhỏ: đổi sang UUIDv7 ngay hôm nay.** Chỉ đổi hàm sinh ở tầng app, không đổi kiểu cột, không migration. Chi phí gần bằng 0, lợi ích tích luỹ theo thời gian.

---

## Câu hỏi mở sang các ngày sau

1. Index `(device_id, key_id)` composite — thứ tự cột ảnh hưởng fanout và dedup thế nào? → **Day 07**
2. Posting list của dedup có ảnh hưởng index-only scan và `Heap Fetches` không? → **Day 08**
3. Partial index `WHERE end_ts IS NULL` (Day 05) chỉ 208 kB — cây nó cao mấy tầng? → **Day 09**
4. Page split để lại chỗ trống. Sau nhiều UPDATE thì bloat lên bao nhiêu, `REINDEX` lấy lại được gì? → **Day 10**
5. `idx_tskv_ts` nặng 107 MB cho một cột `correlation = 1`. BRIN làm cùng việc với bao nhiêu KB? → **Day 31**
