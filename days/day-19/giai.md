# Day 19 — Lời giải: Aggregation — HashAgg, GroupAgg và hash spill

> Bài chữa. Đo thật trên lab `SCALE=1`.

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án |
|---|---|---|
| 1 | `GROUP BY device_id` (50k nhóm), `work_mem=4MB` | **HashAggregate**, `Batches: 1`, `Memory Usage: 4881kB` — vừa khít |
| 2 | `GROUP BY device_id, key_id, date_trunc('hour', ts)` sinh bao nhiêu nhóm? | **4.732.627** — gần bằng số dòng (5 triệu). Gom nhóm gần như không giảm gì |
| 3 | Trước PG13, nhóm quá nhiều làm gì với server? | **OOM killer giết postmaster → cả database restart.** HashAgg không có cơ chế tràn |

Câu 2 đáng dừng lại: **4,7 triệu nhóm trên 5 triệu dòng** — trung bình 1,06 dòng mỗi nhóm. Đây là dạng `GROUP BY` tệ nhất có thể: tốn toàn bộ chi phí gom nhóm mà không giảm được dữ liệu.

---

## §1. Hai cách gom nhóm

| Query | Node | Memory | **time** |
|---|---|---|---|
| `GROUP BY key_id` (8 nhóm) | **HashAggregate** | 24 kB | 946,5 ms |
| `GROUP BY device_id` (50k nhóm) | **HashAggregate** | **4.881 kB** | 1.242,2 ms |
| `GROUP BY device_id ORDER BY device_id` | **Sort** → HashAggregate | 3.099 kB + 4.881 kB | 1.243,4 ms |

### Query 3 có `ORDER BY` — plan đổi thế nào

Planner **vẫn dùng HashAggregate**, rồi thêm một node `Sort` **phía trên**:

```
Sort  (Sort Key: device_id, quicksort Memory: 3099kB)
  ->  HashAggregate  (Group Key: device_id, Memory Usage: 4881kB)
        ->  Seq Scan on ts_kv
```

Nó **không** chọn GroupAggregate (vốn cho kết quả đã sắp sẵn, miễn phí cho `ORDER BY`).

Vì sao: sort **50.000 dòng kết quả** (3 MB) rẻ hơn nhiều so với sort **5.000.000 dòng đầu vào** (117 MB — Day 18). Chênh lệch thời gian chỉ **1,2 ms** (1.242,2 → 1.243,4).

> **Quy tắc: gom nhóm trước rồi sắp kết quả, luôn rẻ hơn sắp đầu vào rồi gom — trừ khi đầu vào đã có sẵn thứ tự nhờ index.**

Chú ý `Memory Usage: 4881kB` với `work_mem = 4MB` (4.096 kB) — **vượt giới hạn mà `Batches: 1`**. HashAgg được phép vượt một chút trước khi quyết định chia partition.

---

## §2. Ép cả hai cách

| Phương án | Node | **time** | **buffers** | temp | Memory / Disk |
|---|---|---|---|---|---|
| **HashAgg** *(planner chọn)* | HashAggregate | **1.660,9 ms** | **37.698** | 1.275 / 2.390 | 8.241 kB / **11.536 kB** |
| **GroupAgg** (ép) | GroupAggregate + Index Scan | **5.353,1 ms** | **4.847.513** | 0 | 0 |

**Planner chọn đúng: HashAgg nhanh hơn 3,2 lần và đọc ít hơn 129 lần.**

### Vì sao GroupAgg đắt đến vậy

```
GroupAggregate  (actual time=109.490..5349.123 rows=50000)
  ->  Index Scan using idx_tskv_dev on ts_kv  (actual rows=5000000)
        Buffers: shared hit=4217385 read=630128
```

Planner tránh được node `Sort` bằng cách đọc qua `idx_tskv_dev` (đã sắp theo `device_id`). Nghe hay — nhưng cái giá là **4,85 triệu lượt truy cập buffer** cho index scan trên cột có `correlation ≈ 0` (Day 04, Day 11).

Đổi 11 MB đĩa tạm (HashAgg spill) lấy 4,85 triệu buffer access — **lỗ nặng**.

Chú ý HashAgg **cũng spill** ở đây: `Batches: 5, Disk Usage: 11536kB`. `avg(dbl_v)` cần thêm trạng thái tích luỹ (sum + count) so với `count(*)` thuần, nên 50.000 nhóm không còn vừa 4 MB.

---

## §3. Hash spill (PG13+)

Query: `GROUP BY device_id, key_id, date_trunc('hour', ts)` → **4.732.627 nhóm thật**.

| `work_mem` | Node | Partitions/Batches | Memory Usage | Disk Usage | temp r/w | **time** |
|---|---|---|---|---|---|---|
| **1MB** | **GroupAggregate** + Incremental Sort | — | 27 kB (avg) | **Peak Disk: 4.312 kB** | 1.733/1.747 | **9.521,8 ms** |
| **16MB** | **GroupAggregate** + Incremental Sort | — | 7.980 kB (avg) | 0 | 0 | **9.688,5 ms** |
| **512MB** | **HashAggregate** | **Batches: 5** | **1.048.625 kB (1 GB!)** | 3.352 kB | 242/594 | **4.963,8 ms** |

### 💡 Ba phát hiện quan trọng

**1. Ở `work_mem` nhỏ, planner KHÔNG chọn HashAgg — nó chọn GroupAgg.**

Đề bài dự kiến thấy `Planned Partitions: 32, Batches: 33`. Thực tế planner tính trước rằng 4,7 triệu nhóm × trạng thái sẽ cần ~1 GB, và với `work_mem = 1MB` thì cần **1.000 partition** — quá đắt. Nó chuyển sang GroupAggregate.

**Đây là hành vi đúng và an toàn:** GroupAgg chỉ cần RAM cho **một nhóm**, không bao giờ nổ.

**2. `Memory Usage: 1.048.625 kB` = 1 GB, với `work_mem = 512MB`.**

HashAgg đã dùng **gấp đôi** `work_mem`. Đây là điều phải biết: **`Memory Usage` của HashAgg có thể vượt `work_mem` đáng kể** vì nó chỉ kiểm tra giới hạn ở các mốc nhất định, và `Batches: 5` cho thấy nó đã cố chia nhưng vẫn giữ nhiều trong RAM.

Với 100 connection cùng chạy query kiểu này: **100 GB**. Đây chính xác là cách OOM một server.

**3. HashAgg (4,96 s) nhanh hơn GroupAgg (9,52 s) gần 2 lần — nhưng phải trả 1 GB RAM.**

Đánh đổi rõ ràng: nhanh gấp đôi, đổi lấy rủi ro OOM.

### Ước lượng số nhóm — lệch bao nhiêu

```
planner ước lượng (node aggregate): rows=5.002.035
số nhóm thật:                       4.732.627
```
Lệch chỉ **5,7 %** — rất chính xác, vì planner dùng `n_distinct` của `ts` (= −1, mọi giá trị phân biệt) và suy ra gần đúng.

### Vì sao trước PG13 điều này giết server

```
PG12 và trước:
  HashAgg vượt work_mem  ->  KHÔNG có cơ chế tràn  ->  cứ malloc tiếp
                         ->  hết RAM  ->  OOM killer giết postmaster
                         ->  TOÀN BỘ database restart, mọi connection đứt
```

Và điều tệ nhất: nó xảy ra khi **ước lượng số nhóm sai**. Planner đoán 10.000 nhóm (vừa `work_mem`), thực tế 10 triệu nhóm → chọn HashAgg → nổ.

Từ PG13, tệ nhất là **chậm**, không phải **chết**. Nhưng `Disk Usage > 0` vẫn là cờ đỏ.

---

## §4. Ước lượng số nhóm — và một kết quả đáng cảnh giác

`GROUP BY device_id, key_id`:

| | rows đoán | **thật** | sai số |
|---|---|---|---|
| **không có statistics** | **224.512** | **395.767** | **−43,3 %** |
| **có `CREATE STATISTICS (ndistinct)`** | **89.904** | 395.767 | **−77,3 %** ⚠️ |

### **`CREATE STATISTICS (ndistinct)` làm ước lượng TỆ ĐI — sai từ 1,76× thành 4,40×.**

Đây là kết quả ngược hoàn toàn với kỳ vọng của Day 13, và nó rất đáng học.

### Vì sao

`ndistinct` cho nhóm cột cũng được ước lượng **từ mẫu 30.000 dòng** (Day 11) — và với **395.767 tổ hợp phân biệt** trên 5 triệu dòng, mẫu 30.000 dòng là quá nhỏ để ước lượng đúng.

So sánh:

| Trường hợp | Số tổ hợp thật | Mẫu 30.000 dòng có đủ không |
|---|---|---|
| Day 13: `region, country` trên `device` | **4** | ✅ thừa sức → ước lượng **chính xác tuyệt đối** |
| Hôm nay: `device_id, key_id` trên `ts_kv` | **395.767** | ❌ quá nhỏ → **ước lượng còn tệ hơn giả định độc lập** |

> **Luật bổ sung cho Day 13: `CREATE STATISTICS (ndistinct)` chỉ đáng tin khi số tổ hợp phân biệt NHỎ so với kích thước mẫu (30.000 × statistics_target/100).** Với nhóm cột có hàng trăm nghìn tổ hợp, nó có thể làm mọi thứ tệ hơn.

**Cách kiểm chứng trước khi tin:**
```sql
-- ĐO số tổ hợp thật (đắt, chạy trên replica)
SELECT count(*) FROM (SELECT DISTINCT a, b FROM t) s;
-- nếu > ~50.000 -> đừng dùng ndistinct statistics, hoặc phải nâng STATISTICS target
```

Và nếu vẫn cần, nâng target trước:
```sql
ALTER TABLE ts_kv ALTER COLUMN device_id SET STATISTICS 1000;
ANALYZE ts_kv;   -- mẫu 300.000 dòng thay vì 30.000
```

Ở đây plan **không đổi** (vẫn HashAgg với `Planned Partitions`), nên tác hại chỉ là tiềm ẩn. Nhưng trong một join, ước lượng số nhóm sai 4,4 lần sẽ lan lên trên (Day 12).

---

## §5. Parallel Aggregate

| Query | Plan | Workers | **time** | Tăng tốc |
|---|---|---|---|---|
| `count(*), avg(dbl_v)` parallel 4 | **Finalize GroupAggregate** ← Gather Merge ← **Partial HashAggregate** | 4 | **302,8 ms** | **3,60×** |
| cùng query, parallel 0 | HashAggregate | — | **1.089,8 ms** | 1,00× |
| **`string_agg(DISTINCT ...)`** parallel 4 | **GroupAggregate + Sort** *(KHÔNG parallel)* | **0** | **2.686,1 ms** | — |

### Mô hình hai pha

```
Finalize GroupAggregate          <- leader gộp kết quả từng phần
  -> Gather Merge
       -> Sort (mỗi worker, 25 kB)
            -> Partial HashAggregate   <- mỗi worker gom nhóm phần của mình
                 -> Parallel Seq Scan
```

Mỗi worker gom 1 triệu dòng thành 8 nhóm **cục bộ**, rồi leader gộp 40 nhóm cục bộ (5 tiến trình × 8) thành 8 nhóm cuối.

**Hiệu quả cực cao vì lượng dữ liệu chuyển qua `Gather` rất nhỏ** (40 dòng thay vì 5 triệu).

### Khi nào parallel KHÔNG giúp

`string_agg(DISTINCT str_v, ',')` — **không parallel được**, và tệ hơn nữa:

```
GroupAggregate  (actual time=1914.993..2678.034 rows=8)
  ->  Sort  Sort Key: key_id, str_v
        Sort Method: external merge  Disk: 60920kB       <- SPILL 60 MB
        ->  Seq Scan on ts_kv
Execution Time: 2686,1 ms
```

**Chậm hơn 8,9 lần so với query parallel (302,8 ms)**, và spill 60 MB đĩa tạm.

Lý do: `DISTINCT` bên trong aggregate buộc phải **sắp toàn bộ 5 triệu dòng** theo `(key_id, str_v)` để khử trùng lặp. Và hàm này không có **combine function** nên không chia được cho worker.

| Hàm | Parallel được? |
|---|---|
| `count`, `sum`, `avg`, `min`, `max`, `bool_and/or` | ✅ có combine function |
| `count(DISTINCT x)`, `sum(DISTINCT x)` | ❌ |
| `string_agg`, `array_agg` **có `ORDER BY` hoặc `DISTINCT`** | ❌ |
| `string_agg`, `array_agg` **không có ORDER BY** | ✅ (nhưng thứ tự không đảm bảo) |
| hàm tự viết chưa khai `COMBINEFUNC` | ❌ |

> **Thêm một `string_agg(x ORDER BY y)` vào query đang parallel có thể làm chậm 9 lần.** Đây là dạng regression rất khó tìm vì SQL nhìn có vẻ vô hại.

---

## §6. `FILTER`, `count(DISTINCT)`, `GROUPING SETS`

### `FILTER` vs nhiều subquery

| | `FILTER` | 3 subquery |
|---|---|---|
| Plan | **1 node Aggregate**, 1 lần quét | **3 node Aggregate**, 3 lần quét |
| buffers | **3.705** | **11.115** (3× ) |
| **time** | **43,1 ms** | **56,6 ms** |

**Nhanh hơn 1,31 lần, đọc ít hơn 3 lần.**

Chênh lệch thời gian nhỏ hơn tỷ lệ buffers vì bảng `alarm` chỉ 29 MB, nằm gọn trong cache. **Trên bảng lớn không vừa cache, chênh lệch sẽ đúng bằng 3 lần.**

```sql
-- LUÔN viết thế này
SELECT count(*) FILTER (WHERE severity='CRITICAL') AS crit,
       count(*) FILTER (WHERE severity='MAJOR')    AS major,
       count(*) FILTER (WHERE end_ts IS NULL)      AS active
FROM alarm;
```

`FILTER` cũng rẻ hơn `count(CASE WHEN ... THEN 1 END)` một chút (không phải tạo giá trị NULL trung gian) và **đọc dễ hơn nhiều**.

### `count(DISTINCT)` — đắt hơn nhiều

| | `count(DISTINCT device_id)` | `count(*)` |
|---|---|---|
| Plan | **GroupAggregate + Sort** | **HashAggregate** |
| `Sort Method` | **external merge, Disk: 127.224 kB** | — |
| temp r/w | **31.805 / 31.875** | 0 |
| **time** | **4.365,7 ms** | **925,1 ms** |

**Đắt hơn 4,7 lần và spill 124 MB.**

Vì `count(DISTINCT device_id)` phải giữ **tập giá trị phân biệt cho mỗi nhóm** → Postgres chọn cách sắp toàn bộ theo `(key_id, device_id)` rồi đếm giá trị đổi. Không parallel được.

**Ba cách thay thế trên dữ liệu lớn:**

```sql
-- 1. Nếu chỉ cần ước lượng: HyperLogLog (extension postgresql-hll)
--    sai số ~2%, RAM hằng số, parallel được
SELECT key_id, hll_cardinality(hll_add_agg(hll_hash_bigint(device_id))) FROM ts_kv GROUP BY key_id;

-- 2. Viết lại thành 2 tầng: DISTINCT trước rồi count
SELECT key_id, count(*) FROM (SELECT DISTINCT key_id, device_id FROM ts_kv) s GROUP BY key_id;

-- 3. Nếu số nhóm nhỏ: bảng rollup cập nhật dần
```

### `GROUPING SETS` / `ROLLUP`

```
MixedAggregate  (actual time=24.362..24.366 rows=9 loops=1)
  Group Key: ()
  Batches: 1  Memory Usage: 32kB
  ->  Seq Scan on device
Execution Time: 24,4 ms
```

**Node `MixedAggregate` gom cả 3 mức tổng hợp trong MỘT lượt quét**, chỉ 32 kB, 24,4 ms.

Viết bằng `UNION ALL` sẽ là 3 lần quét bảng. Với bảng lớn, đây là tiết kiệm 3 lần thẳng.

Rất đáng dùng cho báo cáo dạng "tổng theo vùng, theo quốc gia, và tổng chung".

---

## §7. Chiến lược tổng hợp cho time-series

| Chiến lược | Query 1 tuần | Chi phí dựng | Dung lượng | Độ trễ |
|---|---|---|---|---|
| **(1) Tính lúc query** | **177,0 ms** | 0 | 0 | **0** |
| **(2) Materialized view** | **96,5 ms** | 13,3 s tạo + 3,7 s index | **518 MB** | = chu kỳ refresh |
| — `REFRESH CONCURRENTLY` | | **32,6 s** | | |

### 💡 Kết quả khiêm tốn hơn nhiều so với kỳ vọng: MV chỉ nhanh hơn **1,83 lần**

Vì sao MV không thắng đậm:

```
MV có 4.732.627 dòng — gần bằng số dòng gốc (5.000.000)
MV tổng 518 MB (heap 303 MB + index 216 MB)
ts_kv tổng 696 MB
-> MV chỉ nhỏ hơn 25%
```

**Gom nhóm theo `(device_id, key_id, giờ)` gần như không giảm dữ liệu** — 1,06 dòng mỗi nhóm. MV chỉ là một bản sao được sắp xếp khác đi.

Query trên MV còn phải `Bitmap Heap Scan` **25.251 page** vì lọc theo `key_id` mà index `(key_id, h)` có correlation kém trên MV.

### Khi nào MV mới thật sự đáng

**Chỉ khi tỷ lệ nén cao.** Kiểm tra trước bằng một câu:

```sql
SELECT count(*) AS so_dong_goc,
       count(DISTINCT (device_id, key_id, date_trunc('hour', ts))) AS so_nhom,
       round(count(*)::numeric / count(DISTINCT (device_id, key_id, date_trunc('hour', ts))), 1) AS ty_le_nen
FROM ts_kv;
```

| Tỷ lệ nén | Kết luận |
|---|---|
| **< 5×** | ❌ MV không đáng (lab: **1,06×**) |
| 10–50× | ⚠️ đáng cân nhắc |
| **> 100×** | ✅ MV/rollup thắng lớn |

Ở lab, muốn tỷ lệ nén tốt phải gom theo **ngày** thay vì **giờ**, hoặc bỏ `device_id` khỏi khoá nhóm.

### `REFRESH CONCURRENTLY` mất 32,6 giây

**Gấp 2,5 lần thời gian tạo mới (13,3 s).** Vì `CONCURRENTLY` phải:
1. Build MV mới vào bảng tạm
2. So sánh với bản cũ (cần unique index)
3. Áp `INSERT`/`UPDATE`/`DELETE` chênh lệch

Đổi lại: **không khoá bảng** — đọc vẫn chạy suốt quá trình. `REFRESH` thường (không `CONCURRENTLY`) nhanh hơn nhưng giữ `ACCESS EXCLUSIVE` lock, chặn cả `SELECT`.

**Refresh mỗi bao lâu là hợp lý:**

```
chu kỳ refresh >= 10 × thời gian refresh
```
Ở đây: 32,6 s × 10 = **~5,5 phút tối thiểu**. Thực tế nên 15–60 phút, và chỉ khi dashboard chấp nhận độ trễ đó.

### Ba chiến lược, so đầy đủ

| | (1) Tính lúc query | (2) Materialized view | (3) Bảng rollup tự cập nhật |
|---|---|---|---|
| Query | 177 ms | 96,5 ms | **~1 ms** (đọc trực tiếp) |
| Độ trễ dữ liệu | **0** | 15–60 phút | **~0** |
| Dung lượng thêm | 0 | 518 MB | tuỳ mức gom |
| Phức tạp vận hành | **thấp nhất** | trung bình (cron refresh, theo dõi lỗi) | **cao nhất** (trigger/app, xử lý idempotent, backfill) |
| Rủi ro | không | refresh chồng lấn, MV cũ | sai lệch giữa rollup và dữ liệu thô |

**Với hệ IoT thật, (3) thường là câu trả lời** — vì dữ liệu đến theo luồng, và việc `UPSERT` vào bảng `hourly_rollup` ngay lúc nạp rẻ hơn nhiều so với quét lại. Nhưng phải xử lý: dữ liệu đến trễ, backfill, và cách đối soát rollup với dữ liệu thô.

---

## Bảng số liệu chính

| Kịch bản | Node | Memory / Disk | temp r/w | buffers | **time** |
|---|---|---|---|---|---|
| `GROUP BY key_id` (8 nhóm) | HashAgg | 24 kB | 0 | 37.698 | 946,5 ms |
| `GROUP BY device_id` (50k) | HashAgg | 4.881 kB | 0 | 37.698 | 1.242,2 ms |
| `+ ORDER BY device_id` | **Sort trên HashAgg** | +3.099 kB | 0 | 37.698 | 1.243,4 ms |
| `+ avg()` HashAgg | HashAgg **Batches 5** | 8.241 kB / **11.536 kB** | 1.275/2.390 | 37.698 | **1.660,9 ms** |
| `+ avg()` ép GroupAgg | GroupAgg + Index Scan | 0 | 0 | **4.847.513** | **5.353,1 ms (3,2×)** |
| 3 cột, work_mem 1MB | **GroupAgg** + Incr Sort | Peak Disk 4.312 kB | 1.733/1.747 | 4.847.513 | **9.521,8 ms** |
| 3 cột, work_mem 16MB | GroupAgg + Incr Sort | 7.980 kB | 0 | 4.847.513 | 9.688,5 ms |
| 3 cột, work_mem 512MB | **HashAgg** Batches 5 | **1.048.625 kB (1 GB)** | 242/594 | 37.698 | **4.963,8 ms** |
| §4 số nhóm không stats | đoán **224.512** | thật **395.767** | | | sai 1,76× |
| §4 có `ndistinct` stats | đoán **89.904** | thật 395.767 | | | **sai 4,40× — TỆ HƠN** |
| §5 parallel 4 worker | Finalize/Partial HashAgg | 24 kB | 0 | 37.730 | **302,8 ms (3,60×)** |
| §5 `string_agg(DISTINCT)` | GroupAgg + Sort, **không parallel** | Disk 60.920 kB | 15.224/15.284 | 37.701 | **2.686,1 ms** |
| §6 `FILTER` (1 lượt quét) | 1 Aggregate | — | 0 | **3.705** | **43,1 ms** |
| §6 3 subquery | 3 Aggregate | — | 0 | **11.115** | 56,6 ms |
| §6 `count(DISTINCT)` | GroupAgg + Sort | Disk **127.224 kB** | 31.805/31.875 | 37.698 | **4.365,7 ms** |
| §6 `count(*)` | HashAgg | 24 kB | 0 | 37.698 | **925,1 ms (4,7×)** |
| §6 `ROLLUP` | **MixedAggregate** (1 lượt) | 32 kB | 0 | 1.207 | 24,4 ms |
| §7 tính lúc query | HashAgg Batches 5 | Disk 3.464 kB | 291/641 | 150.593 | **177,0 ms** |
| §7 materialized view | Bitmap Heap Scan | — | 0 | 25.254 | **96,5 ms (1,83×)** |
| §7 MV: **518 MB** (heap 303 + idx 216), tạo **13,3 s**, `REFRESH CONCURRENTLY` **32,6 s** | | | | | |

---

## Ba điều dễ hiểu sai

| # | Hiểu nhầm | Sự thật đo được |
|---|---|---|
| 1 | "`CREATE STATISTICS (ndistinct)` luôn cải thiện ước lượng số nhóm" | Làm **tệ đi**: sai 1,76× → **4,40×**. Vì 395.767 tổ hợp quá nhiều cho mẫu 30.000 dòng |
| 2 | "`Memory Usage` của HashAgg không vượt `work_mem`" | Đo được **1.048.625 kB với `work_mem = 512MB`** — gấp đôi. Với 100 connection = 100 GB |
| 3 | "Materialized view luôn nhanh hơn nhiều" | Chỉ **1,83×** — vì tỷ lệ nén chỉ **1,06×**. MV chỉ đáng khi nén > 10× |

Thêm hai điều:
- **Thêm `string_agg(DISTINCT ...)` làm mất parallel và chậm 8,9 lần.** Regression rất khó tìm vì SQL nhìn vô hại.
- **`ORDER BY` sau `GROUP BY` không làm planner chọn GroupAgg.** Sắp 50.000 dòng kết quả rẻ hơn sắp 5 triệu dòng đầu vào.

---

## A. Vì sao trước PG13 `GROUP BY` có thể giết server

**Trước PG13, `HashAggregate` không có cơ chế tràn ra đĩa.** Nếu planner ước lượng số nhóm vừa `work_mem` mà thực tế lớn hơn nhiều, HashAgg cứ tiếp tục cấp phát cho tới khi hết RAM → **OOM killer giết postmaster → toàn bộ database restart**, mọi connection đứt, transaction đang chạy mất.

Và điều kiện để nó xảy ra rất dễ đạt: chỉ cần **ước lượng số nhóm sai** — mà §4 vừa chứng minh ước lượng số nhóm có thể sai **4,4 lần** ngay cả khi đã thêm statistics.

**Lab đang chạy PostgreSQL 17.10**, nên tệ nhất là **chậm** (spill), không phải **chết**. Điều đó đổi cách đánh giá rủi ro:

| | PG ≤ 12 | **PG ≥ 13** |
|---|---|---|
| HashAgg vượt `work_mem` | **OOM, database restart** | spill ra đĩa, chậm |
| `work_mem` cao có rủi ro gì | **thảm hoạ** | chậm + tốn RAM |
| Ưu tiên phòng ngừa | rất cao — phải giới hạn `work_mem` gắt | vừa phải |

**Nhưng đừng chủ quan:** §3 đo được `Memory Usage = 1 GB` với `work_mem = 512MB`. HashAgg vẫn có thể dùng gấp đôi giới hạn. Với 100 connection, đó vẫn là con đường tới OOM — chỉ chậm hơn.

---

## Áp dụng vào hệ thật

**1. Tìm mọi query có `Disk Usage > 0` ở node aggregate:**
```sql
SELECT substring(regexp_replace(query,'\s+',' ','g'),1,70) AS q, calls,
       pg_size_pretty((temp_blks_written*8192/NULLIF(calls,0))::bigint) AS temp_moi_lan
FROM pg_stat_statements WHERE temp_blks_written > 0
ORDER BY temp_blks_written DESC LIMIT 15;
```
Kèm `log_temp_files = 0` để bắt tận tay.

**2. Thay mọi `count(CASE WHEN ...)` và subquery lặp bằng `FILTER`.** Đo được đọc ít hơn **3 lần**. Đây là refactor rẻ nhất, không rủi ro.

**3. Rà soát `count(DISTINCT)` trong query nóng.** Đắt **4,7 lần** và không parallel được. Nếu chấp nhận sai số ~2 %, dùng HyperLogLog (`postgresql-hll`). Nếu không, viết lại thành hai tầng.

**4. Cảnh giác với `string_agg`/`array_agg` có `ORDER BY` hoặc `DISTINCT`** — chúng vô hiệu hoá parallel. Kiểm tra:
```sql
-- so plan có và không có
EXPLAIN SELECT k, count(*) FROM t GROUP BY k;                    -- có Gather?
EXPLAIN SELECT k, count(*), string_agg(x, ',' ORDER BY y) FROM t GROUP BY k;  -- mất Gather?
```

**5. Trước khi làm materialized view, ĐO tỷ lệ nén:**
```sql
SELECT count(*)::numeric / count(DISTINCT (cot1, cot2, date_trunc('hour', ts))) AS ty_le_nen
FROM bang_lon;
```
**Dưới 5× thì đừng làm** — ở lab tỷ lệ 1,06× và MV chỉ nhanh hơn 1,83 lần trong khi tốn 518 MB và 32,6 s mỗi lần refresh.

Nếu nén thấp, gom thô hơn (theo ngày thay vì giờ) hoặc bỏ bớt cột khỏi khoá nhóm.

**6. Với hệ IoT, cân nhắc bảng rollup cập nhật dần thay vì MV:**
```sql
-- lúc nạp telemetry, đồng thời UPSERT vào rollup
INSERT INTO hourly_rollup (device_id, key_id, h, sum_v, n)
VALUES ($1, $2, date_trunc('hour', $3), $4, 1)
ON CONFLICT (device_id, key_id, h)
DO UPDATE SET sum_v = hourly_rollup.sum_v + EXCLUDED.sum_v,
              n     = hourly_rollup.n + 1;
```
Query thành ~1 ms, độ trễ ~0. Cái giá: phải xử lý dữ liệu đến trễ, backfill, và đối soát định kỳ với dữ liệu thô.

**7. Luôn chạy PG ≥ 13.** Nếu còn PG 12 hoặc cũ hơn, đây là một trong những lý do mạnh nhất để nâng cấp.

---

## Câu hỏi mở sang các ngày sau

1. Thứ tự join và CTE — `MATERIALIZED` có phải rào chắn tối ưu hoá không? → **Day 20**
2. Bảng rollup cập nhật dần cần `ON CONFLICT` — nó khoá thế nào khi nhiều worker cùng ghi? → **Day 28**
3. MV tốn 518 MB và refresh 32,6 s. Partition có thay được không? → **Day 32, Day 33**
4. `GROUP BY device_id, key_id, hour` gom 4,7 triệu nhóm gần như không nén — mô hình lưu trữ nào phù hợp hơn? → **Day 35**
5. HashAgg dùng 1 GB với `work_mem = 512MB` — làm sao giới hạn thật sự? → **Day 36** (pooling, giới hạn theo role)
