# Day 20 — Lời giải: Join order, CTE, semi/anti join + ôn tuần 4

> Bài chữa. Đo thật trên lab `SCALE=1`.

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án |
|---|---|---|
| 1 | Cách nào nhanh nhất? | **`LEFT JOIN ... IS NULL` (153,3 ms)** và **`NOT EXISTS` (177,0 ms)** — cả hai cho cùng `Hash Right Anti Join` |
| 2 | Có cách nào cho **kết quả sai** không? | **CÓ: `NOT IN`.** Nó trả **0** trong khi đáp án đúng là **49.087** |

Và con số gây sốc nhất bài: **`NOT IN` mất 476.381 ms — chậm hơn `NOT EXISTS` 2.691 lần.**

---

## §1. Planner sắp thứ tự join thế nào

```
join_collapse_limit = 8
geqo_threshold      = 12
```

| Cách viết | Plan | total cost |
|---|---|---|
| `tenant → device → ts_kv` | Nested Loop ← Hash Join(tenant,device) | **20.829,40** |
| `ts_kv → device → tenant` | **Y HỆT** | **20.829,40** |
| `join_collapse_limit = 1`, viết `tenant → device → ts_kv` | **Y HỆT** | 20.829,40 |
| `join_collapse_limit = 1`, viết `ts_kv → device → tenant` | **Hash Join lồng nhau** | **70.116,63** |

### Kết luận về "viết bảng nhỏ trước cho nhanh"

**Với ≤ 8 bảng: hoàn toàn là mê tín.** Hai cách viết cho **plan giống hệt đến từng chữ số cost**. Planner gộp mọi `INNER JOIN` vào một bài toán tối ưu và thử mọi thứ tự.

**Nhưng khi ép `join_collapse_limit = 1`, thứ tự viết trở thành mệnh lệnh** — và viết sai thứ tự làm cost tệ đi **3,37 lần** (20.829 → 70.116).

Điều này cho ta một công cụ: **`join_collapse_limit = 1` là cách ép thứ tự join** khi planner chọn sai và mọi cách sửa thống kê đều thất bại. Dùng như phương án cuối, và chỉ `SET LOCAL` trong đúng transaction đó.

### Ba ngưỡng cần nhớ

| Số bảng | Hành vi |
|---|---|
| **≤ 8** (`join_collapse_limit`) | thử **mọi** thứ tự — thứ tự viết **không quan trọng** |
| **9–11** | planner bắt đầu tôn trọng thứ tự viết — **thứ tự có ảnh hưởng** |
| **≥ 12** (`geqo_threshold`) | **GEQO** — thuật toán di truyền, **ngẫu nhiên** |

GEQO là nguồn của hiện tượng *"cùng query, lúc nhanh lúc chậm, plan khác nhau giữa các lần chạy"*. Với query join 15 bảng chạy bất ổn:
```sql
SET LOCAL geqo = off;   -- chấp nhận planning time cao hơn nhiều, đổi lấy plan ổn định
```

Chú ý: `LEFT JOIN` **không** được tự do sắp xếp lại như `INNER JOIN` — thứ tự có ý nghĩa ngữ nghĩa, nên planner bị ràng buộc hơn nhiều.

---

## §2. Semi join và anti join — bài học đắt nhất tuần 4

### Bốn cách viết, cùng một nhu cầu

| Cách viết | Node join | **time** | buffers | temp |
|---|---|---|---|---|
| **`LEFT JOIN ... IS NULL`** | **Hash Right Anti Join** | **153,3 ms** | 150.405 | 0 |
| **`NOT EXISTS`** | **Hash Right Anti Join** | **177,0 ms** | 150.405 | 0 |
| `EXCEPT` | HashSetOp Except | 224,3 ms | 150.405 | 0 |
| **`NOT IN`** | **SubPlan (không tối ưu được)** | **476.381,8 ms** | 151.473 | **read 9.506.930** |

### 🔥 `NOT IN` chậm hơn **2.691 lần** — và đó chưa phải điều tệ nhất

```
Seq Scan on device d  (actual time=49637.932..476378.749 rows=1239)
  Filter: (NOT (ANY (id = (SubPlan 1).col1)))
  Rows Removed by Filter: 48761
  Buffers: shared hit=150266 read=1207, temp read=9506930 written=859
  SubPlan 1
    ->  Index Scan using idx_tskv_ts on ts_kv k  (actual rows=388975 loops=1)
Execution Time: 476381,756 ms      <- 7 phút 56 giây
```

**`temp read = 9.506.930 page = 72,5 GB đọc từ đĩa tạm.** Cho một query đáng ra mất 0,15 giây.

Cơ chế: planner **không thể** biến `NOT IN` thành Anti Join (lý do ở dưới), nên nó vật hoá 388.975 dòng subquery vào một bảng tạm, rồi **quét lại bảng tạm đó cho MỖI dòng của `device`** — 50.000 lần × 388.975 dòng.

### 💀 Và `NOT IN` cho KẾT QUẢ SAI

```sql
CREATE TABLE t_null AS SELECT device_id FROM ts_kv LIMIT 1000;
INSERT INTO t_null VALUES (NULL);      -- chỉ MỘT dòng NULL

SELECT count(*) FROM device WHERE id NOT IN (SELECT device_id FROM t_null);
-->  0            ⚠️ SAI

SELECT count(*) FROM device d WHERE NOT EXISTS (SELECT 1 FROM t_null n WHERE n.device_id = d.id);
-->  49.087       ✅ ĐÚNG
```

**Một dòng NULL duy nhất làm toàn bộ kết quả thành rỗng.**

Giải thích bằng logic ba giá trị của SQL chuẩn:
```
x NOT IN (1, 2, NULL)
  ≡  x <> 1  AND  x <> 2  AND  x <> NULL
  ≡  TRUE    AND  TRUE    AND  NULL
  ≡  NULL                        -- không phải TRUE -> dòng bị loại
```

Với `x = 5`: `5<>1` TRUE, `5<>2` TRUE, `5<>NULL` **NULL** → kết quả NULL → loại. **Mọi dòng đều bị loại, bất kể giá trị.**

Đây **không phải bug của Postgres** — đó là ngữ nghĩa SQL chuẩn, và mọi DB đều hành xử như vậy. Nhưng nó gây bug production **cực kỳ âm thầm**: query đúng suốt hai năm, cho tới ngày một dòng NULL lọt vào bảng, và đột nhiên endpoint trả về danh sách rỗng mà **không có lỗi nào**.

Đây cũng chính là lý do planner không tối ưu được `NOT IN` thành Anti Join: nó **buộc phải giữ đúng ngữ nghĩa NULL đó**, và Anti Join không diễn đạt được.

> ## **Quy tắc tuyệt đối: KHÔNG BAO GIỜ dùng `NOT IN` với subquery. Luôn dùng `NOT EXISTS`.**
>
> Sai kết quả **và** chậm 2.691 lần. Không có tình huống nào `NOT IN (subquery)` là lựa chọn đúng.

*(`NOT IN` với danh sách hằng số — `NOT IN (1,2,3)` — thì an toàn, miễn là không có NULL trong danh sách.)*

### Vì sao `LEFT JOIN ... IS NULL` cũng nhanh

Planner **nhận ra** mẫu `LEFT JOIN ... WHERE right.col IS NULL` và biến nó thành **Anti Join** — đúng plan như `NOT EXISTS`.

Nhưng `NOT EXISTS` vẫn nên là lựa chọn mặc định vì:
- **Ý định rõ ràng hơn** khi đọc code
- `LEFT JOIN ... IS NULL` sai nếu cột kiểm tra `IS NULL` có thể **thật sự NULL** trong dữ liệu
- Không phụ thuộc vào việc planner có nhận ra mẫu hay không

---

## §3. CTE: `MATERIALIZED` vs `NOT MATERIALIZED`

| | mặc định (**NOT MATERIALIZED**) | **`AS MATERIALIZED`** |
|---|---|---|
| `Index Cond` | **`device_id = 42 AND ts >= ...`** | `ts >= ...` **chỉ vậy** |
| `Filter` | — | **`device_id = 42`** |
| `Rows Removed by Filter` | 0 | **1.609.989** |
| dòng đọc | **1.202** | **1.611.191** |
| buffers | **12** | **620.935** |
| temp | 0 | **written 4.827** |
| **time** | **0,234 ms** | **806,4 ms** |

### **`MATERIALIZED` chậm hơn 3.446 lần và đọc nhiều hơn 51.745 lần.**

Với mặc định (`NOT MATERIALIZED`), CTE được **inline như subquery** → điều kiện `device_id = 42` được **đẩy vào trong** → gộp với `ts >= ...` thành một `Index Cond` duy nhất → đọc đúng 1.202 dòng.

Với `MATERIALIZED`, CTE là **rào chắn tối ưu hoá**: nó tính xong toàn bộ 1.611.191 dòng, ghi vào bộ đệm, rồi mới lọc `device_id = 42` — vứt 99,93 %.

> **Đây là lý do trước PG12, `WITH` bị coi là "optimization fence" và mọi người khuyên tránh CTE.** Từ PG12 mặc định đã đổi, nhưng nếu ai đó viết `AS MATERIALIZED` (hoặc đang chạy PG ≤ 11), hình phạt vẫn nguyên vẹn.

### CTE dùng nhiều lần — được tính đúng MỘT lần

```
CTE agg
  ->  HashAggregate  (actual time=1258.804..1266.486 rows=50000)   <- tính 1 LẦN
        ->  Seq Scan on ts_kv  (actual rows=5000000)
InitPlan 2  ->  Aggregate  ->  CTE Scan on agg    (1.280,1 ms)
InitPlan 3  ->  Aggregate  ->  CTE Scan on agg_1  (5,9 ms)
InitPlan 4  ->  Aggregate  ->  CTE Scan on agg_2  (6,0 ms)
Execution Time: 1292,4 ms
```

**Chỉ MỘT node `Seq Scan on ts_kv`** — CTE được tính một lần rồi ba `CTE Scan` đọc lại từ bộ đệm (5,9 và 6,0 ms — gần như miễn phí).

Nếu viết bằng subquery lặp ba lần, sẽ là **ba** lần quét 5 triệu dòng ≈ 3.800 ms.

### Khi nào dùng `MATERIALIZED`

| Tình huống | Dùng `MATERIALIZED`? |
|---|---|
| CTE dùng **nhiều lần** và tính toán đắt | ✅ (Postgres thường tự làm khi thấy dùng > 1 lần) |
| CTE dùng **một lần** | ❌ **TUYỆT ĐỐI KHÔNG** — đo được chậm 3.446× |
| Muốn chặn planner đẩy điều kiện vào (tránh plan xấu đã biết) | ⚠️ hiếm, phải có lý do rõ |
| CTE có `INSERT/UPDATE/DELETE ... RETURNING` | (luôn materialized, không chọn được) |

---

## §4. `LATERAL` — bài toán "top-1 mỗi nhóm"

Nhu cầu: **giá trị mới nhất của mỗi gateway** (4.524 device).

| Cách viết | Plan | **time** | buffers | temp |
|---|---|---|---|---|
| **`CROSS JOIN LATERAL`** | Nested Loop + **Limit 1** mỗi lần | **37,1 ms** | **19.303** | **0** |
| `row_number() OVER (...)` | Sort (**external merge 14 MB**) + WindowAgg | **1.048,4 ms** | 38.905 | 1.775/1.781 |
| `DISTINCT ON` | Sort (**external merge 14 MB**) + Unique | **1.046,7 ms** | 38.905 | 1.775/1.781 |

### **`LATERAL` nhanh hơn 28,2 lần và không spill.**

Vì sao:

```
LATERAL:  4.524 lần × (đọc 1 entry index)  =  4.524 lượt lookup
          -> mỗi lượt: Index Scan using idx_dev_ts_desc, LIMIT 1, dừng ngay

Window/DISTINCT ON:  quét 5.000.000 dòng -> join -> SORT 444.877 dòng
                     -> spill 14 MB đĩa -> rồi mới lấy dòng đầu mỗi nhóm
```

Window function và `DISTINCT ON` **buộc phải sắp toàn bộ** dữ liệu của tất cả các nhóm trước khi biết dòng nào là "đầu tiên". `LATERAL` + index đi thẳng tới dòng cần cho từng nhóm.

Điều kiện để `LATERAL` thắng: **phải có index `(nhóm, thứ_tự DESC)`** — ở đây là `idx_dev_ts_desc(device_id, ts DESC)`.

Chú ý `DISTINCT ON` và window function cho **plan gần như y hệt** (1.046,7 vs 1.048,4 ms) — cùng `Sort` + cùng spill. `DISTINCT ON` chỉ là cú pháp gọn hơn, không nhanh hơn.

### Khi nào chọn cái nào

| | `LATERAL` | `DISTINCT ON` | window function |
|---|---|---|---|
| top-**1** mỗi nhóm, **có index** | ✅ **28× nhanh hơn** | | |
| top-**N** mỗi nhóm (N > 1) | ✅ (`LIMIT N`) | ❌ | ✅ |
| Không có index phù hợp | ⚠️ thành N lần seq scan — **rất tệ** | ✅ | ✅ |
| Cần nhiều hạng (`rn <= 3`) | ✅ | ❌ | ✅ |
| Số nhóm rất lớn (> 100k) | ⚠️ N lần lookup bắt đầu đắt | ✅ | ✅ |

**Quy tắc:** số nhóm nhỏ/vừa + có index → `LATERAL`. Số nhóm rất lớn hoặc không có index → window function.

---

## §5. Subquery tương quan — kết quả ngược với kỳ vọng

| Số device | Subquery tương quan | `LEFT JOIN` + GROUP BY | Ai thắng |
|---|---|---|---|
| **519** (controller) | **13,7 ms**, 3.812 buf | **1.248,5 ms**, 38.905 buf | **subquery, 91×** |
| **44.957** (sensor) | **537,6 ms**, 227.203 buf | **1.295,0 ms**, 38.905 buf | **subquery, 2,4×** |

### **Subquery tương quan THẮNG ở cả hai mức** — ngược hoàn toàn với lời khuyên thông thường

Đề bài (và hầu hết tài liệu) khuyên viết lại subquery tương quan thành `LEFT JOIN` với subquery đã gom nhóm. Số đo nói ngược lại.

Vì sao:

```
Subquery tương quan:
  SubPlan chạy 519 lần, mỗi lần Index Only Scan  ->  đọc đúng phần cần
  Buffers: 3.812

LEFT JOIN + GROUP BY:
  HashAggregate gom nhóm TOÀN BỘ 5.000.000 dòng thành 50.000 nhóm  (1.234 ms)
  rồi vứt 49.481 nhóm không cần
  Buffers: 38.905
```

`LEFT JOIN` phải **gom nhóm cả bảng** dù chỉ cần 519 device. Subquery tương quan chỉ đọc phần liên quan.

### Nhưng xu hướng vẫn đúng — chỉ chưa tới điểm lật

| device | subquery | LEFT JOIN | tỷ lệ |
|---|---|---|---|
| 519 | 13,7 ms | 1.248,5 ms | **91×** |
| 44.957 | 537,6 ms | 1.295,0 ms | **2,4×** |

Subquery scale **tuyến tính theo số device** (13,7 → 537,6 ms khi device tăng 87 lần), còn `LEFT JOIN` gần như **hằng số** (1.248 → 1.295 ms — nó luôn quét cả bảng).

**Điểm lật ước tính: ~110.000 device.** Vượt ngưỡng đó, `LEFT JOIN` mới thắng.

> **Phát biểu lại cho đúng: subquery tương quan thắng khi outer NHỎ và inner có index. Nó chỉ thua khi outer lớn tới mức chi phí `N × lookup` vượt chi phí quét-và-gom-nhóm một lần.**
>
> Đây chính xác là cùng một quy tắc với nested loop vs hash join (Day 16) — vì subquery tương quan **chính là** một nested loop.

**Điều kiện bắt buộc:** inner phải có index. Nếu `ts_kv` không có index trên `device_id`, subquery tương quan sẽ là 519 lần seq scan 5 triệu dòng — thảm hoạ.

---

## §6. Ôn tuần 4

### A. Bảng so sánh 3 thuật toán join

| | **Nested Loop** | **Hash Join** | **Merge Join** |
|---|---|---|---|
| **Cơ chế** | mỗi dòng outer → quét inner | build hash từ bên nhỏ, probe bằng bên lớn | sắp cả hai rồi đi song song 2 con trỏ |
| **Chi phí** | `O(N × chi_phí_lookup)` | `O(N + M)` + RAM cho hash | `O(N log N + M log M)`, hoặc `O(N+M)` nếu đã sắp |
| **Điều kiện dùng** | mọi điều kiện join | **chỉ `=`** | `=` và bất đẳng thức (nếu đã sắp) |
| **Tốt nhất khi** | outer nhỏ (**< ~4.500**) + inner **có index** | cả hai lớn, join bằng `=` | **cả hai đã có sẵn thứ tự** |
| **Số đo (Day 16/17/18)** | outer 519: **15,7 ms** (nhanh hơn hash **43×**) | outer 45k: **1.443 ms** (nhanh hơn NL 1,8×) | đã sắp sẵn: **884,8 ms** (nhanh hơn hash **1,71×**) |
| **Dấu hiệu đang TỆ** | `loops` >> `rows` ước lượng outer (>50×); `Materialize`/`Seq Scan` ở inner | `Batches > 1` **kèm `temp` lớn**; build side ước lượng sai | có node `Sort` bên dưới với `external merge` |
| **Cách chữa** | sửa thống kê; thêm index cho inner; `enable_nestloop=off` tạm | giảm build side (bớt cột, lọc sớm); `SET LOCAL work_mem` | tạo index trên join key cả hai bên |
| **Bất ngờ đo được** | `Memoize` hit < 50 % làm **chậm hơn 27 %** | join key **8 giá trị NHANH HƠN 26 %** (hash 9 kB vừa L1) | planner **bỏ qua** dù nhanh hơn 1,71× |

### B. Checklist "gặp query chậm" — 8 bước, gộp tuần 1–4

```
① CHỌN MỤC TIÊU
   pg_stat_statements ORDER BY total_exec_time.
   Xét cả `calls`: total cao + calls lớn = p99 khách hàng (ưu tiên);
                   total cao + calls=1  = job nền (ưu tiên thấp hơn).

② THỐNG KÊ CÓ TƯƠI KHÔNG
   pg_stat_user_tables: last_analyze, n_mod_since_analyze.
   NULL hoặc > 24h trên bảng ghi nhiều -> ANALYZE, đo lại trước khi làm gì khác.

③ LẤY PLAN, QUY VỀ CÙNG ĐƠN VỊ
   EXPLAIN (ANALYZE, BUFFERS, SETTINGS).
   Mọi node có loops > 1 -> nhân actual_time × loops.
   Tính thời gian RIÊNG = (time × loops) − Σ(các con).

④ SAI SỐ ƯỚC LƯỢNG — VÀ NÓ CÓ QUAN TRỌNG KHÔNG
   Quét TỪ LÁ LÊN, tìm node đầu tiên lệch > 10×.
   -> CÓ: sai số này có đủ LẬT plan sang loại khác không? (ép plan khác, đo)
          KHÔNG lật -> bỏ qua, sang ⑤          (bài học Day 15)
          CÓ lật    -> SET STATISTICS / CREATE STATISTICS / ANALYZE / plan_cache_mode
   -> KHÔNG lệch: ước lượng lành mạnh, sang ⑤

⑤ HÌNH DẠNG SQL CÓ SAI KHÔNG          (mới từ tuần 4 — kiểm tra TRƯỚC khi đụng index)
   NOT IN (subquery)        -> đổi NOT EXISTS       (chậm 2.691×, và SAI kết quả)
   CTE AS MATERIALIZED      -> bỏ đi                (chậm 3.446×)
   OR giữa 2 cột            -> viết lại UNION       (Day 07: quét toàn bảng)
   top-1 mỗi nhóm bằng window -> LATERAL + index     (chậm 28×)
   count(CASE WHEN)/subquery lặp -> FILTER          (đọc gấp 3)
   string_agg(DISTINCT/ORDER BY) -> mất parallel     (chậm 8,9×)
   count(DISTINCT)          -> 2 tầng hoặc HLL      (đắt 4,7×)

⑥ INDEX CÓ ĐÚNG KHÔNG
   Rows Removed by Filter > 10× số dòng trả về?
     -> điều kiện đang ở Filter, phải vào Index Cond
     -> composite đúng thứ tự: = trước, ORDER BY giữa, MỘT range cuối
     -> partial index nếu điều kiện cố định
   ORDER BY + LIMIT trên bảng lớn mà vẫn có node Sort?
     -> index đúng thứ tự xoá hẳn Sort  (Day 18: nhanh 3.204×)

⑦ BỘ NHỚ VÀ SPILL
   temp_written > 0 / Batches > 1 / Disk Usage > 0 / Sort Method: external merge
   -> ĐO temp là bao nhiêu MB trước khi tăng work_mem
      < 50 MB  -> bỏ qua (đo được: 6 MB = chỉ +12% thời gian)
      > 500 MB -> thứ tự sửa: xoá node bằng index > giảm width > SET LOCAL work_mem
   Nhớ: work_mem là per NODE × per CONNECTION × per WORKER

⑧ CHỨNG MINH BẰNG BUFFERS
   Đo nóng, >= 3 lần, trung vị, chỉ đổi MỘT biến.
   Báo cáo: buffers trước/sau + pct trong pg_stat_statements trước/sau.
   ms chỉ để kiểm tra chéo.
```

**Thay đổi lớn nhất so với checklist tuần 1: thêm bước ⑤.** Tuần 4 cho thấy **hình dạng SQL** có thể gây thiệt hại lớn hơn mọi vấn đề index/thống kê cộng lại — `NOT IN` chậm 2.691 lần, CTE `MATERIALIZED` chậm 3.446 lần. Kiểm tra nó **trước** khi đi sửa index.

### C. Ba điều tôi tưởng đúng mà hoá ra sai trong tuần 4

**1. "`NOT IN` và `NOT EXISTS` tương đương, chỉ khác cú pháp."**

*Sự thật:* `NOT IN` chậm **2.691 lần** (476.381 ms vs 177 ms), đọc **72,5 GB đĩa tạm**, và **cho kết quả SAI** khi subquery có NULL (trả 0 thay vì 49.087). Không có tình huống nào nó là lựa chọn đúng.

**2. "Viết bảng nhỏ trước trong JOIN thì nhanh hơn."**

*Sự thật:* với ≤ 8 bảng, hai cách viết cho plan **giống hệt đến từng chữ số cost** (20.829,40). Planner gộp mọi `INNER JOIN` và thử mọi thứ tự. Chỉ khi `join_collapse_limit = 1` thứ tự mới có ý nghĩa — và lúc đó viết sai làm cost tệ **3,37 lần**.

**3. "Subquery tương quan luôn chậm, phải viết lại thành JOIN."**

*Sự thật:* subquery tương quan **thắng ở cả hai mức đo** — 91× với 519 device, 2,4× với 44.957 device. Vì `LEFT JOIN + GROUP BY` phải gom nhóm **toàn bộ** 5 triệu dòng dù chỉ cần vài trăm device. Điểm lật ước tính ~110.000 device.

**Bonus 4:** `Memoize` với tỷ lệ hit 18,6 % làm query **chậm hơn 27 %** — nó không miễn phí (Day 16).

---

## Bảng số liệu chính

| Kịch bản | Plan | **time** | buffers | temp |
|---|---|---|---|---|
| §1 hai thứ tự viết (≤8 bảng) | **y hệt nhau** | — | — | cost **20.829,40** cả hai |
| §1 `join_collapse_limit=1`, thứ tự xấu | Hash Join lồng | — | — | cost **70.116,63 (3,37×)** |
| **§2 `LEFT JOIN IS NULL`** | Hash Right Anti Join | **153,3 ms** | 150.405 | 0 |
| **§2 `NOT EXISTS`** | Hash Right Anti Join | **177,0 ms** | 150.405 | 0 |
| §2 `EXCEPT` | HashSetOp Except | 224,3 ms | 150.405 | 0 |
| **§2 `NOT IN`** | **SubPlan** | **476.381,8 ms (2.691×)** | 151.473 | **read 9.506.930 (72,5 GB)** |
| **§2 bẫy NULL:** `NOT IN` → **0** ; `NOT EXISTS` → **49.087** | | | | |
| §3 CTE mặc định | Index Only Scan, cond đầy đủ | **0,234 ms** | **12** | 0 |
| §3 CTE `MATERIALIZED` | CTE Scan + Filter | **806,4 ms (3.446×)** | 620.935 | written 4.827 |
| §3 CTE dùng 3 lần | **1 HashAggregate** + 3 CTE Scan | 1.292,4 ms | 37.698 | tính đúng **1 lần** |
| **§4 `LATERAL`** | Nested Loop + Limit 1 | **37,1 ms** | **19.303** | **0** |
| §4 window function | Sort external merge 14 MB | 1.048,4 ms | 38.905 | 1.775/1.781 |
| §4 `DISTINCT ON` | Sort external merge 14 MB | 1.046,7 ms | 38.905 | 1.775/1.781 |
| §5 subquery, 519 device | SubPlan × 519 | **13,7 ms** | **3.812** | 0 |
| §5 LEFT JOIN, 519 device | HashAgg toàn bảng | 1.248,5 ms (**91×**) | 38.905 | 0 |
| §5 subquery, 44.957 device | SubPlan × 44.957 | **537,6 ms** | 227.203 | 0 |
| §5 LEFT JOIN, 44.957 device | HashAgg toàn bảng | 1.295,0 ms (**2,4×**) | 38.905 | 0 |

---

## Áp dụng vào hệ thật

**1. Grep codebase tìm `NOT IN (SELECT` — làm ngay hôm nay.**

```bash
grep -rn --include=*.java --include=*.go --include=*.sql --include=*.xml \
  -iE 'NOT[[:space:]]+IN[[:space:]]*\([[:space:]]*SELECT' .
```

Mỗi chỗ tìm được là **hai** rủi ro: chậm 2.691 lần **và** trả kết quả sai âm thầm khi có NULL. Đổi hết sang `NOT EXISTS` — chuyển đổi cơ học, không đổi ngữ nghĩa (trừ trường hợp anh **đang dựa vào** hành vi NULL, điều gần như chắc chắn là bug).

Kiểm tra chỗ nào có nguy cơ NULL:
```sql
SELECT attrelid::regclass AS bang, attname AS cot
FROM pg_attribute
WHERE NOT attnotnull AND attnum > 0 AND NOT attisdropped
  AND attrelid IN ('ts_kv'::regclass, 'device'::regclass, 'alarm'::regclass);
```
Cột **không** có `NOT NULL` = có nguy cơ.

**2. Grep tìm `AS MATERIALIZED`** — nếu CTE chỉ dùng một lần, xoá từ khoá đó. Đo được chậm 3.446 lần.

**3. Tìm chỗ dùng window function cho "top-1 mỗi nhóm" và chuyển sang `LATERAL`:**

```sql
-- mẫu IoT: giá trị mới nhất của mỗi device
SELECT d.id, d.name, last.ts, last.dbl_v
FROM device d
LEFT JOIN LATERAL (
  SELECT ts, dbl_v FROM ts_kv k
  WHERE k.device_id = d.id
  ORDER BY ts DESC LIMIT 1
) last ON true
WHERE d.tenant_id = $1;

-- BẮT BUỘC có index:
CREATE INDEX CONCURRENTLY ON ts_kv (device_id, ts DESC);
```
Đo được **28,2 lần** nhanh hơn, và không spill.

`LEFT JOIN LATERAL ... ON true` giữ lại device chưa có dữ liệu (khác `CROSS JOIN LATERAL` sẽ loại chúng).

**4. Với query join > 8 bảng, kiểm tra tính ổn định của plan:**
```sql
SHOW join_collapse_limit;   -- 8
SHOW geqo_threshold;        -- 12
```
Query join ≥ 12 bảng chạy bất ổn → thử `SET LOCAL geqo = off` và đo. Nếu ổn định hơn, cân nhắc nâng `geqo_threshold`.

Query join 9–11 bảng → **thứ tự viết có ảnh hưởng**; viết bảng lọc chặt nhất trước.

**5. Đừng vội viết lại subquery tương quan thành JOIN.** Đo trước — ở lab nó thắng 91 lần. Chỉ viết lại khi outer thật lớn (> ~100.000 dòng) **và** inner có index.

---

## Hết tuần 4

| Ngày | Câu hỏi được trả lời | Con số đắt nhất |
|---|---|---|
| 16 | Nested loop & Memoize | NL nhanh hơn hash **43×** khi outer nhỏ; Memoize hit 18,6 % làm **chậm 27 %** |
| 17 | Hash join & work_mem | `Batches 8` chỉ đắt **1,22×** — chi phí thật là `temp`, không phải số batch |
| 18 | Merge join & sort | index xoá node Sort: **3.204×**; `work_mem` cần **338 MB cho 80 MB** dữ liệu |
| 19 | Aggregation | `CREATE STATISTICS(ndistinct)` làm ước lượng **tệ đi**; HashAgg dùng **1 GB** với `work_mem=512MB` |
| 20 | Join order, CTE, semi/anti | **`NOT IN` chậm 2.691× và SAI kết quả**; CTE `MATERIALIZED` chậm **3.446×**; `LATERAL` nhanh **28×** |

**Bài học lớn nhất của tuần 4:**

> Ba tuần đầu dạy cách **sửa những gì planner làm sai**. Tuần 4 cho thấy thiệt hại lớn nhất thường đến từ **cách viết SQL** — `NOT IN`, `MATERIALIZED`, window function cho top-1 — và chúng gây chậm hàng nghìn lần, vượt xa mọi vấn đề index hay thống kê.
>
> **Kiểm tra hình dạng SQL trước khi đụng vào index.**

Tuần 5 chuyển sang tầng dưới nữa: MVCC, vacuum, bloat — nơi "hiểu sơ sơ" biến thành "sửa được sự cố lúc 2 giờ sáng".
