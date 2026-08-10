# Day 31 — Lời giải: BRIN — index nhỏ hơn 3.428 lần cho dữ liệu time-series

> Bài chữa. Đo thật trên lab `SCALE=1` (5.000.000 dòng, 295 MB, `ts` correlation = 1).

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án |
|---|---|---|
| 1 | BRIN trên `ts_kv(ts)` to bao nhiêu? | **32 kB** |
| 2 | Nhỏ hơn B-tree mấy lần? | **3.428 lần** (32 kB vs 107 MB) |
| 3 | Xáo trộn thứ tự vật lý thì chậm mấy lần? | **BRIN bị bỏ hoàn toàn** — planner chuyển sang Seq Scan, chậm **38 lần** |

---

## §1. BRIN vs B-tree — con số

| Đối tượng | Kích thước | Byte |
|---|---|---|
| Bảng `ts_kv` | **295 MB** | 308.822.016 |
| `idx_ts_btree` (B-tree) | **107 MB** | 112.336.896 |
| **`idx_ts_brin`** | **32 kB** | **32.768** |

```
BRIN nhỏ hơn B-tree : 3.428 lần
BRIN bằng            : 0,0106 % kích thước bảng
```

### Cơ chế — vì sao nhỏ đến vậy

**BRIN = Block Range INdex.** Thay vì một entry cho mỗi **dòng**, nó lưu một entry cho mỗi **nhóm page** (mặc định 128 page = 1 MB).

```
5.000.000 dòng = 37.698 page
37.698 ÷ 128   = 295 range
295 range × ~30 byte + metapage ≈ 32 kB ✓
```

Mỗi entry chỉ chứa **min và max** của range đó:
```
Range 0 (page 0-127):    ts ∈ [2025-05-01 00:00, 2025-05-01 00:35]
Range 1 (page 128-255):  ts ∈ [2025-05-01 00:35, 2025-05-01 01:10]
```

Query `WHERE ts BETWEEN a AND b`:
1. Quét **toàn bộ** BRIN (32 kB — gần như miễn phí)
2. Loại mọi range mà `[min,max]` không giao với `[a,b]`
3. Với range còn lại, **quét toàn bộ page** trong range và lọc từng dòng

> **Điểm mấu chốt: BRIN không cho biết dòng nào khớp, chỉ cho biết range nào CÓ THỂ chứa dòng khớp.** Nó là bộ lọc thô — và dòng `Rows Removed by Index Recheck` trong plan chính là cái giá của sự thô đó.

---

## §2. `correlation` là tất cả

```
  attname  |  correlation
-----------+---------------
 ts        |     1,000        <- BRIN hoàn hảo
 bool_v    |     0,906
 str_v     |     0,468
 key_id    |     0,159
 dbl_v     |    -0,057
 device_id |    -0,005        <- BRIN vô dụng
```

**Chỉ `ts` phù hợp với BRIN.** `device_id` (correlation −0,005) sẽ khiến mọi range có `min ≈ 1, max ≈ 50000` → không range nào bị loại → BRIN thoái hoá thành Seq Scan **cộng thêm** chi phí quét index.

Dữ liệu time-series **tự nhiên có correlation = 1**: ghi theo thời gian, Postgres append vào cuối bảng. **Đây chính là lý do BRIN được tạo ra.**

Các cột khác thường có correlation cao: `bigserial` PK, `created_at`, và mọi cột tương quan với thứ tự chèn.

---

## §3. So hiệu năng ba cách

| Phạm vi | Index | **time** | buffers | `Rows Removed by Recheck` | Node |
|---|---|---|---|---|---|
| **1 giờ** (2.305 dòng) | **B-tree** | **0,44 ms** | **10** | — | Index Only Scan |
| | BRIN | 2,40 ms | 137 | **15.008** | Bitmap Heap Scan, `lossy=128` |
| | Seq Scan | **344,0 ms** | 37.698 | — | Seq Scan |
| **1 ngày** (55.563 dòng) | **B-tree** | **8,24 ms** | **156** | — | Index Only Scan |
| | BRIN | 12,34 ms | 515 | **13.700** | `lossy=512` |
| | Seq Scan | 359,5 ms | 37.698 | — | |
| **1 tuần** (388.901 dòng) | **B-tree** | **61,5 ms** | **1.066** | — | Index Only Scan |
| | BRIN | 74,2 ms | 2.947 | **9.352** | `lossy=2944` |
| | Seq Scan | 363,6 ms | 37.698 | — | |

### Ba điều đọc ra

**1. BRIN thua B-tree ở MỌI phạm vi — nhưng chỉ 1,2–5,5 lần.**

| Phạm vi | BRIN chậm hơn B-tree |
|---|---|
| 1 giờ | **5,5 lần** |
| 1 ngày | 1,5 lần |
| 1 tuần | **1,2 lần** |

**Phạm vi càng rộng, khoảng cách càng thu hẹp.** Vì `Rows Removed by Index Recheck` gần như không đổi (~10–15 nghìn) trong khi số dòng thật tăng từ 2.305 lên 388.901 — tỷ lệ lãng phí giảm từ 651 % xuống 2,4 %.

**2. Cả hai đều đè bẹp Seq Scan** — nhanh hơn 5–780 lần.

**3. `Heap Blocks: lossy=N` là dấu hiệu nhận diện BRIN.**

BRIN **luôn** cho bitmap lossy (nhớ page, không nhớ dòng) — đúng cơ chế §1. Nên nó **luôn** phải recheck từng dòng trong page được chọn.

### 💡 Vậy BRIN có đáng không?

Số liệu nói: **BRIN chậm hơn 1,2–5,5 lần, đổi lại nhỏ hơn 3.428 lần.**

| | B-tree | BRIN |
|---|---|---|
| Kích thước | **107 MB** | **32 kB** |
| Query 1 tuần | 61,5 ms | 74,2 ms |
| Thời gian tạo | **1.512 ms** | **269 ms** (nhanh 5,6×) |
| Chi phí INSERT | cao (Day 10: +64 %/index) | **gần bằng 0** |
| Có vừa RAM không (bảng 500 GB) | 180 GB — **không** | **54 MB** — thừa sức |

**Điểm quyết định nằm ở quy mô thật.** Ở lab, B-tree 107 MB nằm gọn trong shared_buffers nên nó thắng. Với bảng 500 GB:
- B-tree ~180 GB → **không vừa RAM** → mỗi lookup là random read đĩa
- BRIN ~54 MB → **luôn trong RAM**

> **BRIN không thắng bằng tốc độ trên bảng nhỏ. Nó thắng bằng việc VẪN HOẠT ĐỘNG khi bảng lớn tới mức B-tree không còn vừa RAM.**

---

## §4. `pages_per_range` — chỉnh độ mịn

Query 1 giờ (2.305 dòng):

| `pages_per_range` | **Kích thước** | buffers | **`Rows Removed by Recheck`** | `Heap Blocks` | **time** |
|---|---|---|---|---|---|
| **16** | **96 kB** | **45** | **2.022** | lossy=32 | **2,54 ms** |
| **128** (mặc định) | 32 kB | 131 | 15.008 | lossy=128 | 3,66 ms |
| **512** | **24 kB** | 514 | **66.952** | lossy=512 | **8,52 ms** |

### Đánh đổi rất rõ

```
ppr 16  -> index to gấp 4x (96kB) nhưng đọc thừa ÍT HƠN 33 LẦN (2.022 vs 66.952)
        -> nhanh hơn 3,4 lần so với ppr 512
```

Chú ý: index nhỏ nhất (24 kB) lại **chậm nhất**. Tiết kiệm 8 kB đổi lấy đọc thừa 65.000 dòng — lỗ nặng.

### Quy tắc chọn

> **Chọn `pages_per_range` sao cho MỘT range ≈ đơn vị truy vấn nhỏ nhất của anh.**

Cách tính cho hệ thật:
```
dòng mỗi page      = kích thước bảng ÷ 8KB ÷ số dòng   (lab: 5.000.000/37.698 = 133)
dòng mỗi range     = 133 × pages_per_range
khoảng thời gian   = dòng mỗi range ÷ tốc độ ghi (dòng/giây)

Lab: 133 × 128 = 17.024 dòng/range
     5.000.000 dòng trải 91 ngày -> 636 dòng/giờ... không, 2.290 dòng/giờ
     -> 1 range ≈ 7,4 giờ dữ liệu
```

Query nhỏ nhất là **1 giờ** → range 7,4 giờ là **quá thô** → nên hạ xuống `pages_per_range = 16` (≈ 55 phút/range). Đúng như số đo: ppr=16 nhanh nhất cho query 1 giờ.

**Mặc định 128 chỉ hợp khi anh hay query theo ngày trở lên.**

---

## §5. Phá correlation — BRIN sụp đổ

| Bảng | correlation của `ts` | Plan | **time** | buffers |
|---|---|---|---|---|
| `ts_kv` | **1,000** | Bitmap Heap Scan (BRIN) | **10,94 ms** | 518 |
| `ts_shuffled` | **−0,0047** | **Seq Scan** — BRIN bị bỏ | **418,81 ms** | 36.992 |

### **Chậm 38 lần — và planner thậm chí không thèm dùng BRIN.**

Đây là kết quả mạnh hơn dự đoán: BRIN không chỉ "chậm đi", nó **vô dụng tới mức planner tính ra Seq Scan còn rẻ hơn**.

Vì với dữ liệu ngẫu nhiên, mỗi range có `min ≈ giá trị nhỏ nhất toàn bảng`, `max ≈ lớn nhất` → **không range nào bị loại** → BRIN phải quét 100 % bảng **cộng thêm** chi phí quét index.

### `CLUSTER` sửa được

```sql
CREATE INDEX idx_shuf_ts_btree ON ts_shuffled(ts);
CLUSTER ts_shuffled USING idx_shuf_ts_btree;
```

| | Trước CLUSTER | **Sau CLUSTER** |
|---|---|---|
| correlation | −0,0047 | **1,000** ✅ |
| Plan | Seq Scan | **Bitmap Heap Scan (BRIN)** |
| time | 418,81 ms | **11,55 ms** (nhanh **36×**) |
| buffers | 36.992 | **514** |

### ⚠️ Nhưng `CLUSTER` KHÔNG dùng được trên production

| | `CLUSTER` |
|---|---|
| Khoá | **`ACCESS EXCLUSIVE`** — chặn cả `SELECT` |
| Thời gian | viết lại **toàn bộ** bảng + index (bảng 500 GB = hàng giờ) |
| Chỗ trống cần | = kích thước bảng + index |
| Có tự duy trì không | **KHÔNG** — dữ liệu mới chèn vào lại phá correlation ngay |

Điểm cuối quan trọng nhất: `CLUSTER` là thao tác **một lần**, không phải thuộc tính bền vững. Postgres **không** có clustered index như SQL Server/MySQL InnoDB.

**Thay thế trên production:** `pg_repack --order-by` — làm cùng việc mà không khoá.

> **Nhưng nếu đang phải `CLUSTER` định kỳ để giữ BRIN hoạt động, đó là dấu hiệu chọn sai công cụ.** BRIN chỉ nên dùng cho bảng **tự nhiên** có correlation cao (append-only theo thời gian) — không phải bảng cần ép cho có.

---

## §6. BRIN cần bảo trì — chỗ đắt giá nhất bài

Chèn 200.000 dòng mới với `ts` vượt xa max hiện tại:

| | **Trước `brin_summarize_new_values`** | **Sau** |
|---|---|---|
| buffers | **684** | **7** |
| `Rows Removed by Index Recheck` | **91.462** | **0** |
| `Heap Blocks` | **lossy=677** | — |
| **time** | **10,87 ms** | **0,072 ms** |

### **Nhanh hơn 151 lần, buffers ít hơn 98 lần — chỉ bằng một lệnh.**

`brin_summarize_new_values('idx_ts_brin')` trả về **6** — đã tóm tắt 6 range mới.

### Vì sao dữ liệu mới không được index tự động

Khi chèn dòng mới, BRIN **chỉ cập nhật range cuối cùng đang được ghi dở**. Các page hoàn toàn mới nằm trong vùng **"chưa summarize"** — và Postgres phải giả định chúng **có thể** chứa bất kỳ giá trị nào → **luôn phải quét**.

```
Range đã summarize:   [min, max] -> lọc được
Range CHƯA summarize: (không có thông tin) -> LUÔN phải đọc
```

Đây là khác biệt cơ bản với B-tree (cập nhật ngay khi INSERT).

### Hai cách xử lý

```sql
-- Cách 1: bật tự động (PG10+) — KHUYẾN NGHỊ cho bảng append-only
ALTER INDEX idx_ts_brin SET (autosummarize = on);
-- -> autovacuum sẽ summarize, không cần làm gì thêm

-- Cách 2: gọi thủ công theo lịch
SELECT brin_summarize_new_values('idx_ts_brin');
```

**Nên bật `autosummarize = on`** cho bảng append-only. Nhưng lưu ý: nó phụ thuộc autovacuum chạy — nếu autovacuum tụt hậu (Day 23) thì summarize cũng tụt hậu.

Với hệ ghi rất nóng, kết hợp cả hai: bật `autosummarize` **và** chạy `brin_summarize_new_values` theo cron mỗi 5–15 phút.

### Nếu dữ liệu cũ bị `UPDATE`

Range đã summarize có `[min, max]` cố định. Nếu một `UPDATE` đưa giá trị lạc vào range đó, min/max **rộng ra** và range mất tác dụng lọc — vĩnh viễn, cho tới khi:
```sql
SELECT brin_desummarize_range('idx_ts_brin', <block>);
SELECT brin_summarize_range('idx_ts_brin', <block>);
-- hoặc đơn giản: REINDEX INDEX idx_ts_brin;   (chỉ 32 kB, rất nhanh)
```

**`REINDEX` một BRIN 32 kB mất chưa tới một giây** — khác hẳn B-tree 107 MB. Đây là một ưu điểm ẩn của BRIN: bảo trì cực rẻ.

---

## §7. `minmax_multi` và `bloom`

### Mô phỏng dữ liệu đến muộn

Chèn 5.000 dòng có `ts = '2025-05-02'` (rất cũ) vào cuối bảng — mô phỏng thiết bị IoT mất mạng rồi gửi bù.

| Opclass | Kích thước | `Rows Removed by Recheck` | `Heap Blocks` | **time** |
|---|---|---|---|---|
| **`minmax`** (mặc định) | **24 kB** | **31.019** | lossy=640 | 13,16 ms |
| **`minmax_multi`** | **96 kB** | **13.700** | lossy=512 | **10,74 ms** |

### **`minmax_multi` giảm đọc thừa 2,3 lần, nhanh hơn 18 %, đổi lấy index to gấp 4 lần (96 kB).**

Cơ chế: `minmax` lưu **một** khoảng `[min, max]` cho mỗi range. Chỉ cần **một** giá trị lạc (2025-05-02 nằm giữa vùng 2025-07) là khoảng đó phình ra bao trùm 3 tháng → range mất tác dụng lọc hoàn toàn.

`minmax_multi` (PG14+) lưu **nhiều khoảng rời rạc**:
```
minmax:       [2025-05-02, 2025-07-30]        <- một giá trị lạc phá cả range
minmax_multi: [2025-05-02, 2025-05-02], [2025-07-25, 2025-07-30]   <- giữ được độ chính xác
```

> **Với hệ IoT, `minmax_multi` gần như luôn là lựa chọn đúng** — thiết bị mất mạng rồi gửi bù là chuyện xảy ra hằng ngày, và chỉ cần một lô dữ liệu đến muộn là `minmax` mất tác dụng trên cả một vùng lớn.
>
> Cái giá: index to gấp 4 lần — nhưng 96 kB so với B-tree 107 MB thì vẫn **nhỏ hơn 1.114 lần**.

```sql
CREATE INDEX ON ts_kv USING brin(ts timestamptz_minmax_multi_ops);
```

### `bloom` cho `device_id` — KHÔNG hoạt động

```sql
CREATE INDEX idx_brin_bloom ON ts_kv USING brin(device_id int8_bloom_ops);
```
```
 bloom_size
------------
 2328 kB
```

Nhưng query `WHERE device_id = 42`:
```
Seq Scan on ts_kv  (actual time=0.044..277.054 rows=3732)
  Filter: (device_id = 42)
  Rows Removed by Filter: 5001268
Execution Time: 277,499 ms
```

**Planner KHÔNG dùng BRIN bloom — nó chọn Seq Scan.**

### Vì sao — và bài học

`bloom` opclass lưu một bloom filter cho mỗi range, cho phép trả lời *"range này CÓ THỂ chứa giá trị x không"* mà không cần correlation.

Nhưng ở đây: `device_id` có correlation −0,005, và mỗi range 128 page chứa ~17.000 dòng với **hàng nghìn `device_id` phân biệt**. Bloom filter của mỗi range chứa gần như **mọi** device_id → không range nào bị loại → vô dụng.

> **`bloom` chỉ hữu ích khi mỗi block range chứa TƯƠNG ĐỐI ÍT giá trị phân biệt** — ví dụ dữ liệu được gom cụm lỏng lẻo theo cột đó (ghi theo lô của cùng một tenant), hoặc `pages_per_range` rất nhỏ.
>
> Với `device_id` rải hoàn toàn ngẫu nhiên, **không có BRIN nào cứu được — phải dùng B-tree.**

So sánh cuối:
```
device_id = 42:  BRIN bloom -> Seq Scan, 277 ms, 36.995 buffer
                 B-tree     -> 0,63 ms, 22 buffer   (đo được ở Day 07)
                 -> B-tree nhanh hơn 440 lần
```

---

## Bảng số liệu chính

| Kịch bản | Kết quả |
|---|---|
| **BRIN vs B-tree** | **32 kB vs 107 MB = nhỏ hơn 3.428 lần**, bằng **0,0106 %** kích thước bảng |
| Thời gian tạo | BRIN **269 ms** vs B-tree **1.512 ms** (nhanh 5,6×) |
| Query 1 giờ: B-tree / BRIN / Seq | **0,44 / 2,40 / 344,0 ms** |
| Query 1 ngày | **8,24 / 12,34 / 359,5 ms** |
| Query 1 tuần | **61,5 / 74,2 / 363,6 ms** |
| `pages_per_range` 16 / 128 / 512 | **96 / 32 / 24 kB**; recheck **2.022 / 15.008 / 66.952**; **2,54 / 3,66 / 8,52 ms** |
| **Xáo trộn correlation** | corr **−0,005** → **planner bỏ BRIN**, Seq Scan **418,8 ms (chậm 38×)** |
| Sau `CLUSTER` | corr **1,000**, BRIN trở lại, **11,55 ms** (nhanh 36×) |
| **Trước / sau `brin_summarize_new_values`** | **684 → 7 buffer**, recheck **91.462 → 0**, **10,87 → 0,072 ms (151×)** |
| `minmax` vs `minmax_multi` (có dữ liệu đến muộn) | **24 kB / 96 kB**; recheck **31.019 / 13.700**; **13,16 / 10,74 ms** |
| `bloom` cho `device_id` | 2.328 kB — **planner không dùng**, Seq Scan 277,5 ms |

---

## Ba điều dễ hiểu sai

| # | Hiểu nhầm | Sự thật đo được |
|---|---|---|
| 1 | "BRIN nhanh hơn B-tree cho time-series" | **Chậm hơn 1,2–5,5 lần** ở mọi phạm vi. BRIN thắng bằng **kích thước** (3.428×) và **chi phí ghi**, không phải tốc độ đọc |
| 2 | "Tạo BRIN xong là dùng được mãi" | Dữ liệu mới **không được index** cho tới khi summarize — đo được **chậm 151 lần**. Phải bật `autosummarize` |
| 3 | "`pages_per_range` nhỏ hơn thì index to hơn nên chậm hơn" | Ngược lại: ppr=16 (96 kB) **nhanh hơn 3,4 lần** ppr=512 (24 kB). Đọc thừa đắt hơn kích thước index rất nhiều |

Thêm hai điều:
- **`CLUSTER` khôi phục được correlation nhưng khoá `ACCESS EXCLUSIVE` và không tự duy trì** — nếu phải CLUSTER định kỳ, đó là dấu hiệu chọn sai công cụ.
- **`bloom` opclass không cứu được cột correlation ≈ 0** khi mỗi range chứa quá nhiều giá trị phân biệt.

---

## Áp dụng vào hệ thật

**1. Tìm bảng dùng được BRIN — chạy ngay:**

```sql
SELECT s.tablename, s.attname, s.correlation,
       pg_size_pretty(pg_relation_size(c.oid)) AS size_bang,
       (SELECT pg_size_pretty(sum(pg_relation_size(i.indexrelid)))
        FROM pg_index i JOIN pg_attribute a
          ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
        WHERE i.indrelid = c.oid AND a.attname = s.attname) AS size_btree_hien_tai
FROM pg_stats s JOIN pg_class c ON c.relname = s.tablename
WHERE s.schemaname = 'public'
  AND abs(s.correlation) > 0.95
  AND pg_relation_size(c.oid) > 1024*1024*1024      -- bảng > 1GB
ORDER BY pg_relation_size(c.oid) DESC;
```

Trong hệ IoT/ThingsBoard điển hình, ứng viên là: `ts_kv.ts`, `alarm.start_ts`, `audit_log.created_at`, `event.ts` — **mọi cột thời gian của bảng append-only**.

**2. Ước lượng lợi ích và tổn thất cho từng bảng:**

| | Được | Mất |
|---|---|---|
| **Dung lượng** | B-tree 180 GB → BRIN 54 MB (bảng 500 GB) | — |
| **Chi phí INSERT** | giảm ~64 % cho index đó (Day 10) | — |
| **Query range rộng** (ngày/tuần/tháng) | tương đương | chậm ~1,2× |
| **Query range hẹp** (giờ) | | chậm ~5,5× — chỉnh `pages_per_range` để bù |
| **Query điểm** (`WHERE ts = x`) | ❌ | **BRIN gần như vô dụng** — vẫn quét cả range |
| **`ORDER BY ts LIMIT N`** | ❌ | **BRIN không cho thứ tự** — phải sort. B-tree xoá được node Sort (Day 18) |

**Hai dòng cuối là "mất gì" quan trọng nhất.** Nếu hệ có query kiểu *"100 giá trị mới nhất của device X"* thì **vẫn cần B-tree** — BRIN không thay thế được.

**Chiến lược thường dùng: giữ cả hai.**
```sql
-- BRIN cho query theo khoảng thời gian rộng (báo cáo, export)
CREATE INDEX ON ts_kv USING brin(ts timestamptz_minmax_multi_ops)
  WITH (pages_per_range = 32, autosummarize = on);

-- B-tree composite cho query điểm + ORDER BY (dashboard realtime)
CREATE INDEX ON ts_kv (device_id, ts DESC);
```
BRIN tốn thêm ~100 MB trên bảng 500 GB — coi như miễn phí.

**3. LUÔN bật `autosummarize`:**
```sql
ALTER INDEX idx_ts_brin SET (autosummarize = on);
```
Đo được: không summarize thì **chậm 151 lần** trên dữ liệu mới — tức chính phần dữ liệu được query nhiều nhất.

Kèm cron dự phòng nếu autovacuum hay tụt hậu:
```sql
SELECT brin_summarize_new_values('idx_ts_brin');   -- mỗi 10 phút
```

**4. Dùng `minmax_multi` thay `minmax` cho hệ IoT.** Dữ liệu đến muộn là chuyện hằng ngày, và `minmax` mất tác dụng chỉ vì một lô gửi bù. Giá: to gấp 4 lần — vẫn nhỏ hơn B-tree hơn 1.000 lần.

**5. Chỉnh `pages_per_range` theo đơn vị query nhỏ nhất**, đừng để mặc định 128 nếu hay query theo giờ. Công thức ở §4.

**6. Đừng dùng BRIN cho cột correlation thấp** (`device_id`, `tenant_id`, `uuid`). Kể cả `bloom` opclass cũng không cứu được — đo được planner bỏ hẳn nó.

---

## Câu hỏi mở sang các ngày sau

1. BRIN giải quyết index; nhưng xoá dữ liệu cũ thì sao? → **Day 32, Day 33** (partition + `DROP PARTITION`)
2. Partition có làm correlation tốt hơn nữa không (mỗi partition tự nhiên đã hẹp)? → **Day 32**
3. Với partition, có cần BRIN nữa không — partition pruning đã lọc rồi? → **Day 32 §*
4. `device.meta` là jsonb — index nào cho nó? → **Day 34**
5. So sánh tổng thể: Postgres + BRIN vs Postgres + partition vs Cassandra? → **Day 35**
