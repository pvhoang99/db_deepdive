# Day 18 — Lời giải: Merge Join & Sort

> Bài chữa. Đo thật trên lab `SCALE=1`.

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án |
|---|---|---|
| 1 | Sort 5 triệu dòng với `work_mem=4MB` — method gì, đĩa bao nhiêu? | **`external merge`, Disk: 120.152 kB (117 MB)** |
| 2 | Cần `work_mem` bao nhiêu để vừa RAM? | **Giữa 128MB và 512MB** — thực tế cần **345.760 kB (338 MB)** |
| 3 | Index vs tăng `work_mem` — cái nào thắng? | **Index, áp đảo: 0,286 ms vs 916 ms = nhanh 3.204 lần** |

Câu 2 đáng dừng lại: sort cần **338 MB** cho dữ liệu chỉ `5.000.000 × 16 byte = 80 MB`. **Overhead 4,2 lần** — mỗi tuple trong bộ đệm sort mang thêm header và con trỏ.

---

## §1. Ba `Sort Method`

| Query | `Sort Method` | Memory / Disk | temp r/w | **time** |
|---|---|---|---|---|
| `ORDER BY dbl_v` (5M dòng) | **external merge** | **Disk: 120.152 kB** | 30.032 / 30.100 | **2.754,9 ms** |
| `ORDER BY dbl_v LIMIT 10` | **top-N heapsort** | **Memory: 25 kB** | **0** | **838,3 ms** |
| `ORDER BY dbl_v LIMIT 1000000` | **external merge** | Disk: 120.136 kB | 18.543 / 30.110 | 2.187,2 ms |
| `device ORDER BY name` (50k dòng) | **quicksort** | Memory: 3.490 kB | 0 | 95,9 ms |

### `LIMIT 10` vs `LIMIT 1000000` — vì sao khác method

| | `LIMIT 10` | `LIMIT 1000000` |
|---|---|---|
| Method | **top-N heapsort** | **external merge** |
| Bộ nhớ | **25 kB** | 117 MB đĩa |
| time | **838,3 ms** | 2.187,2 ms |

`top-N heapsort` giữ một **heap N phần tử**. Với N = 10, heap chỉ 25 kB — nằm trong L1 cache.

Với N = 1.000.000, heap sẽ cần `1.000.000 × 16 byte × overhead ≈ 68 MB` — vượt `work_mem = 4MB`, nên Postgres bỏ chiến lược top-N và quay về external merge sort **toàn bộ 5 triệu dòng**.

> **Ngưỡng: `top-N heapsort` chỉ dùng được khi `N × width × overhead < work_mem`.** Với `work_mem = 4MB` và width 16, N tối đa ≈ **60.000**.
>
> Đây là lý do **pagination sâu (`OFFSET 100000 LIMIT 20`) đắt kinh khủng**: N thực tế là `offset + limit = 100.020`, có thể vượt ngưỡng và biến top-N thành full sort.

Chú ý chi tiết tinh vi ở `LIMIT 1000000`: `temp read=18543 written=30110` — **ghi 30.110 page nhưng chỉ đọc lại 18.543**. Nó dừng sớm khi đủ 1 triệu dòng, không cần trộn hết các run. `LIMIT` vẫn giúp, chỉ không giúp nhiều bằng.

---

## §2. Quét `work_mem` để tìm điểm lật

| `work_mem` | `Sort Method` | Memory / Disk | **temp r/w** | **time** |
|---|---|---|---|---|
| **4MB** | external merge | Disk: 120.152 kB | **30.032 / 30.100** | **2.634,2 ms** |
| **32MB** | external merge | Disk: 120.144 kB | **15.018 / 15.026** | **2.279,5 ms** |
| **128MB** | external merge | Disk: 120.104 kB | 15.013 / 15.015 | 2.409,9 ms |
| **512MB** | **quicksort** | **Memory: 345.760 kB** | **0** | **2.458,9 ms** |

### 💡 Ba điều phản trực giác

**1. Điểm lật ở giữa 128MB và 512MB — cần tận 338 MB cho 80 MB dữ liệu.**

```
5.000.000 dòng × 16 byte (width) = 80 MB dữ liệu thuần
Sort cần:                          345.760 kB = 338 MB
Overhead:                          4,2 lần
```

Mỗi tuple trong bộ đệm sort mang: header `SortTuple` (~24 byte) + con trỏ + bản thân tuple với `HeapTupleHeader`. **Đừng bao giờ ước lượng `work_mem` cần bằng `rows × width`** — nhân thêm 3–5 lần.

**2. Tăng `work_mem` 128 lần chỉ nhanh hơn 7 %** (2.634 → 2.459 ms), và mức **512MB (không spill) còn CHẬM HƠN mức 32MB (có spill)**.

Lặp lại đúng bài học Day 03 §6. Bóc tách:

| Thành phần | Thời gian |
|---|---|
| Seq Scan đọc 289 MB | ~490 ms (mọi mức đều vậy) |
| **Sắp xếp 5 triệu dòng (CPU thuần)** | **~1.500 ms** — không tránh được |
| Ghi/đọc 117 MB đĩa tạm | ~250 ms ở mức 4MB, ~120 ms ở mức 32MB |
| Cấp phát + chạm 338 MB RAM | ~150 ms ở mức 512MB |

**Spill chỉ chiếm 9 % thời gian.** Còn quicksort 338 MB phải trả giá page fault và cache miss L3 liên tục — ăn hết phần tiết kiệm.

**3. Từ 4MB lên 32MB, `temp` giảm đúng một nửa (30.032 → 15.018) nhưng `Disk` không đổi (120 MB).**

Hai con số này khác nhau:
- **`Disk:`** = kích thước dữ liệu cần sort — **không đổi**, vì dữ liệu vẫn là 5 triệu dòng
- **`temp read/written`** = tổng lưu lượng qua **các lượt merge** — giảm khi `work_mem` lớn hơn vì cần ít lượt trộn hơn

`work_mem` 4MB → mỗi run 4MB → 30 run → cần 2 lượt trộn.
`work_mem` 32MB → mỗi run 32MB → 4 run → 1 lượt trộn.

---

## §3. Index xoá hẳn node Sort — chỗ đắt giá nhất bài

Cùng nhu cầu: `SELECT device_id, ts FROM ts_kv ORDER BY dbl_v LIMIT 100`

| Phương án | Plan | **time** | **buffers** | temp | RAM dùng |
|---|---|---|---|---|---|
| **(1)** `work_mem = 4MB` | Sort (top-N heapsort) | **916,9 ms** | **37.698** | 0 | 36 kB |
| **(2)** `work_mem = 512MB` | Sort (top-N heapsort) | **951,0 ms** | 37.698 | 0 | 36 kB |
| **(3)** **index `(dbl_v)`** | **Index Scan, KHÔNG có Sort** | **0,286 ms** | **102** | **0** | **0** |

### **Index nhanh hơn 3.204 lần và đọc ít hơn 370 lần.**

Và tăng `work_mem` 128 lần **không giúp gì cả** (916,9 → 951,0 ms — còn chậm hơn trong nhiễu đo).

### Vì sao chênh lệch khổng lồ như vậy

| | Sort + LIMIT | Index Scan + LIMIT |
|---|---|---|
| Phải đọc | **toàn bộ 5.000.000 dòng** | **đúng 100 dòng** |
| Node `Sort` là | **node chặn** — phải đọc hết mới trả được dòng đầu | không có |
| `LIMIT` giúp được | chỉ giảm bộ nhớ heap | **dừng ngay sau 100 dòng** |

Node `Sort` **chặn** (blocking): startup cost = total cost. Nó không thể trả dòng đầu tiên trước khi đã xem hết mọi dòng — vì dòng nhỏ nhất có thể nằm ở cuối bảng.

Index đã sắp sẵn → dòng đầu tiên của index **chính là** dòng nhỏ nhất → `LIMIT 100` dừng sau 100 dòng, đọc **102 buffer**.

### Khi nào chọn index thay vì tăng `work_mem`

> **Gần như LUÔN LUÔN, khi query có `ORDER BY` + `LIMIT` trên bảng lớn và chạy thường xuyên.**

| Tiêu chí | Index | Tăng `work_mem` |
|---|---|---|
| Tốc độ | **3.204×** ở lab | ~1× (không giúp) |
| RAM dùng lúc chạy | **0** | 338 MB × số connection |
| Ổn định khi dữ liệu lớn lên | ✅ (chỉ thêm 1 tầng cây mỗi 285× dữ liệu) | ❌ (tuyến tính) |
| Chi phí | **107 MB đĩa** + INSERT chậm ~64 % (Day 10) | 0 đĩa, nhưng rủi ro OOM |
| Có `LIMIT` không | bắt buộc phải có để hưởng trọn lợi ích | — |

**Chọn tăng `work_mem` thay vì index chỉ khi:**
- query chạy **hiếm** (job báo cáo hằng đêm), và
- bảng bị ghi rất nóng nên không muốn thêm index, và
- không có `LIMIT` (sort toàn bộ để export)

Cái giá của index ở đây: **107 MB cho một cột `double precision`** — bằng 37 % kích thước bảng. Đắt, nhưng đổi lấy 3.204 lần thì rẻ.

---

## §4 + §5. Merge Join

### Merge join khi đã có sẵn thứ tự

```
Merge Join  (actual rows=5000000 loops=1)
  Merge Cond: (k.device_id = d.id)
  ->  Index Only Scan using idx_tskv_dev on ts_kv k  (actual rows=5000000)
  ->  Index Only Scan using device_pkey on device d  (actual rows=50000)
Execution Time: 884,8 ms
```

**KHÔNG có node `Sort` nào.** Cả hai bên đọc qua index → đã có sẵn thứ tự theo join key.

### 💡 Phát hiện quan trọng nhất: planner chọn SAI

| Plan | time | buffers |
|---|---|---|
| **Merge Join** (ép) | **884,8 ms** | 103.939 |
| **Hash Join** (planner tự chọn) | **1.509,0 ms** | 37.837 |

**Merge join nhanh hơn 1,71 lần, nhưng planner chọn hash join.**

Vì sao planner sai: merge join đọc **103.939 buffer** so với 37.837 của hash join — gấp 2,7 lần. Cost model phạt nặng số buffer đó.

Nhưng **103.939 buffer đó đều là `hit`** (nằm trong shared_buffers), trong khi hash join có `read=15.946` phải chạm đĩa. Lại đúng bài học Day 03: **buffer trong cache rẻ hơn buffer phải đọc rất nhiều**, và cost model không phân biệt được.

Đây là cùng một lớp lỗi với Day 04 (`random_page_cost = 4.0` quá bảo thủ) và Day 14 (`effective_cache_size` quá thấp). Nâng `effective_cache_size` lên đúng mức sẽ giúp planner thấy merge join hấp dẫn hơn.

### Khi nào merge join thắng

| Tình huống | Merge Join |
|---|---|
| **Cả hai bên đã sắp sẵn** (đọc qua index trên join key) | ✅ **thắng — đo được 1,71×** |
| Phải sort một bên | ⚠️ thường thua hash join |
| Phải sort **cả hai** bên | ❌ hầu như luôn thua |
| Bảng cực lớn, hash table không thể vừa RAM | ✅ **plan duy nhất khả thi** — không cần giữ gì trong RAM ngoài cửa sổ hiện tại |
| Join theo `<`, `>` (range join) | ✅ dùng được; hash join **không** |
| `ORDER BY` trùng join key | ✅ kết quả ra đã sắp sẵn — xoá luôn node Sort phía trên |

Điểm cuối là lợi ích ẩn ít người khai thác: nếu query có `ORDER BY device_id` **và** join theo `device_id`, merge join cho kết quả đã sắp — tiết kiệm thêm một node Sort.

---

## §6. `Incremental Sort` (PG13+)

| | `enable_incremental_sort = on` | `= off` |
|---|---|---|
| Node | **Incremental Sort** | Sort (top-N heapsort) |
| Nguồn dữ liệu | **Index Only Scan** (`idx_dev_ts_d`) | **Seq Scan toàn bảng** |
| dòng phải đọc | **107.948** | **5.000.000** |
| `Full-sort Groups` | **1** (27 kB) | — |
| `Pre-sorted Groups` | **1** (127 kB) | — |
| buffers | **430** | **37.698** |
| **time** | **38,7 ms** | **991,7 ms** |

**Nhanh hơn 25,6 lần, đọc ít hơn 88 lần.**

### Cơ chế

Index `idx_dev_ts_d(device_id, ts DESC)` cho dữ liệu **đã sắp theo `device_id`**, nhưng `ts` thì ngược chiều (`DESC` trong index, `ASC` trong `ORDER BY`).

`Incremental Sort` tận dụng phần đã sắp:
```
Sort Key: device_id, ts
Presorted Key: device_id          <- phần này KHÔNG cần sort lại
```

Nó chỉ sort `ts` **bên trong từng nhóm `device_id`** — mỗi nhóm vài trăm dòng, vừa 27–127 kB, **không bao giờ spill**.

Và vì kết quả ra theo đúng thứ tự, `LIMIT 1000` dừng sau khi xử lý **107.948 dòng** (device đầu tiên) thay vì 5 triệu.

> **Incremental Sort là lý do index "gần đúng" vẫn rất có giá trị.** Không cần index khớp hoàn hảo với `ORDER BY` — chỉ cần khớp **tiền tố** là đã tiết kiệm được hàng chục lần.

Hai chỉ số cần đọc:
- **`Full-sort Groups`** — số nhóm phải sort đầy đủ. Nhiều nhóm nhỏ = tốt.
- **`Pre-sorted Groups`** — nhóm đã sắp sẵn, chỉ cần kiểm tra.

---

## §7. Sort ở những chỗ không ngờ

| Query | Plan | Sort? | time |
|---|---|---|---|
| `DISTINCT device_id` | **HashAggregate** | **không** | 1.163,3 ms |
| `UNION` | **Unique** + **Merge Append** | ẩn trong Merge Append | **793,9 ms** |
| `UNION ALL` | **Append** | **không** | **761,4 ms** |
| 2 window function | **2 node Sort** + 2 WindowAgg | **có, 2 node** | 121,8 ms |

### `DISTINCT` — không sort, dùng HashAggregate

Postgres 17 chọn `HashAggregate` cho `DISTINCT`, không phải `Sort + Unique`. Nhanh hơn khi số giá trị phân biệt nhỏ (50.000 trên 5 triệu dòng).

Nếu `work_mem` không đủ cho hash table 50.000 nhóm, nó sẽ quay về `Sort + Unique` — Day 19.

### `UNION` vs `UNION ALL` — chênh lệch nhỏ hơn dự kiến

| | `UNION` | `UNION ALL` |
|---|---|---|
| Node | `Unique` → `Merge Append` | `Append` |
| dòng ra | **50.000** | **5.050.000** |
| buffers | 103.939 | 37.837 |
| time | **793,9 ms** | **761,4 ms** |

Chỉ chậm hơn **4,3 %** — vì planner khôn: nó dùng **`Merge Append`** trên hai `Index Only Scan` đã sắp sẵn, nên khử trùng lặp chỉ cần một lượt quét, **không cần sort**.

Nhưng chú ý buffers: `UNION` đọc **103.939** so với 37.837 — gấp 2,7 lần, vì phải đi qua index thay vì seq scan.

> **Luật vẫn giữ: dùng `UNION ALL` khi anh biết chắc không có trùng lặp.** `UNION` phải khử trùng, và trong trường hợp không có index phù hợp nó sẽ sort — lúc đó chênh lệch là hàng lần chứ không phải 4 %.

### Window function — 2 node Sort cho 2 `PARTITION BY`

```
WindowAgg
  ->  Sort  Sort Key: device_id, ts DESC
        Sort Method: external merge  Disk: 2512kB        <- SPILL!
        ->  WindowAgg
              ->  Sort  Sort Key: key_id, ts
                    Sort Method: quicksort  Memory: 3920kB
                    ->  Index Scan using idx_tskv_ts
Execution Time: 121,8 ms
```

**Hai `PARTITION BY` khác nhau → hai node `Sort`.** Và node thứ hai **spill ra đĩa** (`Disk: 2512kB`, `temp read=314 written=315`) dù chỉ 55.563 dòng — vì `work_mem = 4MB` đã bị node sort thứ nhất dùng gần hết (3.920 kB).

> **Đây là chỗ hay bị bỏ sót nhất: mỗi `PARTITION BY` khác nhau là một node Sort, và chúng CHIA NHAU `work_mem` trong cùng một query.**

Query có 3 window function với 3 `PARTITION BY` khác nhau → 3 node Sort → mỗi node vẫn được cấp `work_mem` riêng, nhưng tổng RAM là `3 × work_mem`.

Cách giảm: sắp xếp các window function dùng **cùng** `PARTITION BY ... ORDER BY` cạnh nhau — Postgres sẽ gộp chúng vào **một** node Sort.

---

## Bảng số liệu chính

| Kịch bản | Sort Method | Mem/Disk | temp r/w | buffers | **time** |
|---|---|---|---|---|---|
| `ORDER BY dbl_v` 5M | external merge | **120.152 kB** | 30.032/30.100 | 37.698 | **2.754,9 ms** |
| `+ LIMIT 10` | **top-N heapsort** | **25 kB** | 0 | 37.698 | **838,3 ms** |
| `+ LIMIT 1000000` | external merge | 120.136 kB | 18.543/30.110 | 37.698 | 2.187,2 ms |
| `device ORDER BY name` | quicksort | 3.490 kB | 0 | 1.207 | 95,9 ms |
| work_mem 4MB | external merge | 120.152 kB | **30.032/30.100** | | 2.634,2 ms |
| work_mem 32MB | external merge | 120.144 kB | **15.018/15.026** | | **2.279,5 ms** |
| work_mem 128MB | external merge | 120.104 kB | 15.013/15.015 | | 2.409,9 ms |
| work_mem 512MB | **quicksort** | **345.760 kB** | **0** | | 2.458,9 ms |
| **§3 (1)** sort 4MB + LIMIT 100 | top-N heapsort | 36 kB | 0 | **37.698** | **916,9 ms** |
| **§3 (2)** sort 512MB + LIMIT 100 | top-N heapsort | 36 kB | 0 | 37.698 | 951,0 ms |
| **§3 (3)** index `(dbl_v)` | **KHÔNG có Sort** | — | 0 | **102** | **0,286 ms (3.204×)** |
| §5 Merge Join (ép) | không Sort | — | 0 | 103.939 | **884,8 ms** |
| §5 Hash Join (planner chọn) | — | — | 0 | 37.837 | **1.509,0 ms (chậm 1,71×)** |
| §6 Incremental Sort ON | quicksort 27 kB | — | 0 | **430** | **38,7 ms** |
| §6 Incremental Sort OFF | top-N heapsort 115 kB | — | 0 | 37.698 | **991,7 ms (25,6×)** |
| §7 `UNION` | Unique + Merge Append | — | 0 | 103.939 | 793,9 ms |
| §7 `UNION ALL` | Append | — | 0 | 37.837 | **761,4 ms** |
| §7 2 window function | **2 node Sort**, 1 spill | Disk 2.512 kB | 314/315 | 21.406 | 121,8 ms |

---

## Ba điều dễ hiểu sai

| # | Hiểu nhầm | Sự thật đo được |
|---|---|---|
| 1 | "Tăng `work_mem` là cách sửa sort chậm" | 4MB→512MB (128×) chỉ nhanh **7 %**, và mức 512MB còn **chậm hơn** mức 32MB. Index nhanh hơn **3.204×** |
| 2 | "`work_mem` cần bằng `rows × width`" | Cần **338 MB** cho **80 MB** dữ liệu — overhead **4,2 lần** |
| 3 | "Planner luôn chọn plan nhanh nhất cho join" | Merge join nhanh hơn **1,71×** nhưng planner chọn hash join — cost model không phân biệt được buffer `hit` và `read` |

Thêm hai điều:
- **`LIMIT N` chỉ cho `top-N heapsort` khi `N × width × overhead < work_mem`.** Với `work_mem=4MB`, N tối đa ~60.000 — nên pagination sâu vẫn đắt.
- **Mỗi `PARTITION BY` khác nhau là một node Sort**, và chúng chia nhau `work_mem` trong cùng query — đo được một node spill dù chỉ 55.563 dòng.

---

## Áp dụng vào hệ thật

**1. Tìm mọi query đang sort trên đĩa:**

```sql
SELECT substring(regexp_replace(query,'\s+',' ','g'),1,70) AS q,
       calls,
       pg_size_pretty(temp_blks_written*8192::bigint) AS temp_tong,
       pg_size_pretty((temp_blks_written*8192/NULLIF(calls,0))::bigint) AS temp_moi_lan
FROM pg_stat_statements WHERE temp_blks_written > 0
ORDER BY temp_blks_written DESC LIMIT 20;
```

Và bật `log_temp_files = 0` để bắt tận tay.

**2. Với mỗi query có `ORDER BY` + `LIMIT` trên bảng lớn, ưu tiên index — không tăng `work_mem`:**

```sql
-- "50 alarm mới nhất của tenant X"
SELECT * FROM alarm WHERE tenant_id=$1 ORDER BY start_ts DESC LIMIT 50;
CREATE INDEX CONCURRENTLY ON alarm (tenant_id, start_ts DESC);
-- -> xoá node Sort, LIMIT dừng sau 50 dòng
```

**Kiểm chứng đã thành công:** plan **không còn node `Sort`**, và `buffers` giảm xuống hàng chục (thay vì bằng `relpages`).

**3. Thay `OFFSET` sâu bằng keyset pagination.** `OFFSET 100000 LIMIT 20` có N thực tế = 100.020 — vượt ngưỡng top-N heapsort:

```sql
-- thay vì OFFSET
SELECT * FROM alarm WHERE (start_ts, id) < ($1, $2)
ORDER BY start_ts DESC, id DESC LIMIT 20;
```
Thời gian thành **hằng số theo số trang**.

**4. Rà soát query có nhiều window function.** Gộp các window dùng cùng `PARTITION BY ... ORDER BY` để Postgres chỉ tạo một node Sort:

```sql
-- 2 node Sort:
row_number() OVER (PARTITION BY device_id ORDER BY ts DESC),
avg(x)       OVER (PARTITION BY key_id    ORDER BY ts)

-- 1 node Sort:
row_number() OVER w,
avg(x)       OVER w
WINDOW w AS (PARTITION BY device_id ORDER BY ts DESC)
```

**5. Dùng `UNION ALL` khi biết chắc không trùng.** Ở lab chênh chỉ 4 % (nhờ có index phù hợp), nhưng khi không có index thì `UNION` phải sort toàn bộ.

**6. Nếu thấy merge join bị planner bỏ qua mà anh nghi nó nhanh hơn:** kiểm tra `effective_cache_size`. Đặt quá thấp khiến planner phạt oan các plan đọc nhiều buffer `hit`. Đo bằng `SET enable_hashjoin=off` rồi so — mất 30 giây.

---

## Câu hỏi mở sang các ngày sau

1. `DISTINCT` dùng HashAggregate — khi nào nó spill và `Planned Partitions` là gì? → **Day 19**
2. `GROUP BY` chọn HashAgg hay GroupAgg (có Sort) dựa vào gì? → **Day 19**
3. Thứ tự join do ai quyết, và CTE có phải rào chắn không? → **Day 20**
4. Index `(dbl_v)` nặng 107 MB cho một cột. Có cách nào rẻ hơn cho cột thời gian? → **Day 31** (BRIN)
5. Sort ẩn trong `CREATE INDEX` — `maintenance_work_mem` ảnh hưởng thế nào? → **Day 43**
