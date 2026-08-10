# Day 16 — Lời giải: Nested Loop và Memoize

> Bài chữa. Đo thật trên lab `SCALE=1`.

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án |
|---|---|---|
| 1 | Nested loop hợp lý tới outer bao nhiêu dòng? | **~4.500 dòng** ở lab này. Trên 45.000 thì hash join thắng |
| 2 | Memoize giúp bao nhiêu % trong join `ts_kv × device`? | **0 % ở tình huống nhỏ (còn CHẬM hơn 27 %)**; **17 % ở tình huống lớn** — phụ thuộc hoàn toàn vào tỷ lệ key lặp |
| 3 | Outer sai 100 lần thì nested loop chậm hơn hash join bao nhiêu? | Ở lab: **chỉ 1,8 lần** (2.621 vs 1.443 ms) — vì Memoize cứu |

Câu 2 là kết quả bất ngờ nhất và đáng học nhất hôm nay.

---

## §1. Ba thuật toán join — cùng một query

`SELECT count(*) FROM ts_kv k JOIN device d ON d.id=k.device_id WHERE d.type='controller'` → 49.629 dòng.

| Thuật toán | **time** | buffers | temp | Ghi chú |
|---|---|---|---|---|
| **Nested Loop** ✅ *(planner chọn)* | **15,7 ms** | **3.812** | 0 | outer 519 dòng, inner có index |
| Hash Join | **677,3 ms** | 38.905 | 0 | phải quét **toàn bộ** 5 triệu dòng `ts_kv` |
| Merge Join | **590,3 ms** | 105.016 | 0 | phải quét **toàn bộ** index `ts_kv` |

**Nested loop nhanh hơn 43 lần và đọc ít hơn 10 lần.**

### Vì sao chênh lệch khổng lồ như vậy

| | Nested Loop | Hash Join / Merge Join |
|---|---|---|
| Lượng `ts_kv` phải đọc | **chỉ 519 nhánh index** = 49.629 dòng | **toàn bộ 5.000.000 dòng** |
| Tỷ lệ đọc phí | 0 % | **99 %** |

Hash join buộc phải quét **cả bảng lớn** để probe — dù chỉ 1 % số dòng khớp. Nested loop với index đi thẳng tới đúng 519 nhánh cần.

> **Đây là quy tắc quan trọng nhất: khi outer nhỏ VÀ inner có index đúng, nested loop không có đối thủ. Hash join không thể tránh việc quét toàn bộ bảng lớn.**

Chú ý Merge Join đọc **105.016 buffer** — nhiều nhất — vì nó phải đi qua toàn bộ index `idx_tskv_dev` (4,99 triệu entry) để giữ thứ tự.

---

## §2 + §3. Ngưỡng: nested loop hợp lý tới đâu

| outer rows | Ép **Nested Loop** | Planner **tự chọn** | Planner chọn gì |
|---|---|---|---|
| **519** (controller) | **14,8 ms**, 3.812 buf | **14,7 ms**, 3.812 buf | **Nested Loop** ✅ |
| **4.524** (gateway) | **94,9 ms**, 23.948 buf | **91,5 ms**, 23.948 buf | **Nested Loop** ✅ |
| **44.957** (sensor) | **2.620,7 ms**, 187.698 buf | **1.442,9 ms**, 38.905 buf | **Hash Join** ✅ |

**Ngưỡng lật: giữa 4.524 và 44.957 dòng outer.** Planner chọn đúng ở cả 3 mức.

### Quy đổi sang tỷ lệ

| outer | % của `device` (50.000) | Nested loop còn tốt? |
|---|---|---|
| 519 | 1,0 % | ✅ nhanh hơn hash 43× |
| 4.524 | 9,0 % | ✅ vẫn tốt |
| 44.957 | 90 % | ❌ chậm hơn hash 1,8× |

Cách nhớ thực dụng hơn: **nested loop tốt khi số lần lookup vào inner < ~10.000.** Vượt ngưỡng đó, chi phí `loops × (đi cây B-tree + chuyển ngữ cảnh executor)` bắt đầu vượt chi phí quét tuần tự.

### 💡 Quan sát tinh tế: planner ĐẢO thứ tự join khi bị ép

Khi ép nested loop ở mức 44.957, planner **không** làm điều ngây thơ (device làm outer, 44.957 vòng lặp). Nó **đảo lại**:

```
Nested Loop  (actual rows=4505494 loops=1)
  ->  Seq Scan on ts_kv k  (actual rows=5000000 loops=1)      <- ts_kv làm OUTER
  ->  Memoize  (actual rows=1 loops=5000000)
        Cache Key: k.device_id
        Hits: 4950000  Misses: 50000  Memory Usage: 5272kB
        ->  Index Scan using device_pkey on device d  (loops=50000)
```

5 triệu vòng lặp — nghe kinh khủng — nhưng `Memoize` biến 5.000.000 lần lookup thành **50.000 lần thật** (hit rate **99,0 %**).

Kết quả: 2.621 ms, chỉ chậm hơn hash join 1,8 lần thay vì hàng chục lần.

> **Bài học: khi ép `enable_nestloop`, planner sẽ tìm cách nested loop ÍT TỆ NHẤT, không phải cách anh nghĩ.** Muốn đo đúng "nested loop ngây thơ" thì phải ép cả thứ tự join.

---

## §4. `Materialize` — không thấy, mà thấy `Memoize`

Query `device ⋈ tenant` (tenant chỉ 20 dòng), ép nested loop:

```
Nested Loop  (actual rows=519 loops=1)
  ->  Seq Scan on device d  (actual rows=519 loops=1)
  ->  Memoize  (actual rows=1 loops=519)
        Cache Key: d.tenant_id
        Hits: 499  Misses: 20  Evictions: 0  Memory Usage: 3kB
        ->  Index Only Scan using tenant_pkey on tenant t  (loops=20)
```

**Không có `Materialize` — Postgres 17 chọn `Memoize` thay thế.**

`tenant` có PK nên inner **có index**, và `d.tenant_id` chỉ có 20 giá trị phân biệt → Memoize phù hợp hơn hẳn.

| | `Materialize` | `Memoize` |
|---|---|---|
| Lưu gì | **toàn bộ** kết quả inner | kết quả **theo từng key** |
| Dùng khi | inner **không có index**, phải quét lại | inner **có index**, outer có **key lặp** |
| Tiết kiệm | I/O (không quét lại) | **cả I/O lẫn CPU** (không tra lại cây) |
| Độ phức tạp | vẫn `O(N × M)` so sánh | `O(số key phân biệt)` lookup |

Ở đây Memoize biến **519 lần** tra `tenant` thành **20 lần** — hit rate 96,1 %, cache chỉ **3 kB**.

Muốn thấy `Materialize` thật thì phải có inner không index được (ví dụ join với subquery, hoặc điều kiện không dùng `=`).

---

## §5. `Memoize` — kết quả phản trực giác

### Thí nghiệm 1: outer nhỏ (4.632 dòng) — Memoize LÀM CHẬM

| | `enable_memoize = on` | `enable_memoize = off` |
|---|---|---|
| `Hits` / `Misses` | **863 / 3.769** | — |
| **tỷ lệ hit** | **18,6 %** | — |
| `Memory Usage` | 413 kB | — |
| buffers | **9.348** | **11.074** |
| **time** | **8,37 ms** | **6,56 ms** |

**Memoize CHẬM HƠN 27 %** dù tiết kiệm được 16 % buffers.

Vì sao: chỉ **18,6 %** hit. 4.632 dòng ts_kv trong 2 giờ trải trên 3.769 device phân biệt — gần như mỗi dòng một device khác nhau. Cache gần như vô dụng, mà vẫn phải trả phí băm key + tra hash + cấp phát 413 kB cho **mọi** dòng.

> **Memoize chỉ có ích khi outer có KEY LẶP LẠI NHIỀU. Tỷ lệ hit dưới ~50 % thì nó là gánh nặng thuần tuý.**

### Thí nghiệm 2: outer lớn (55.563 dòng) — Memoize CỨU

| | với Memoize | không Memoize (`work_mem=64kB`) |
|---|---|---|
| `Hits` / `Misses` | **29.964 / 25.599** | — |
| **tỷ lệ hit** | **53,9 %** | — |
| `Memory Usage` | 2.800 kB | — |
| buffers | **72.602** | **132.530** |
| **time** | **69,7 ms** | **81,0 ms** |

**Nhanh hơn 14 %, buffers ít hơn 45 %.**

### 💡 Phát hiện ngoài dự kiến: `work_mem=64kB` không gây `Evictions` — nó **xoá hẳn Memoize**

Đề bài dự kiến `work_mem` nhỏ sẽ cho thấy `Evictions > 0`. Thực tế: với `work_mem = 64kB`, planner **bỏ hẳn node Memoize** khỏi plan.

Lý do: planner tính trước rằng cache 64 kB chỉ chứa được vài trăm entry trên 25.599 key phân biệt → tỷ lệ hit sẽ quá thấp → không đáng. Nó **tự loại bỏ** thay vì tạo ra một Memoize kém hiệu quả.

Đây là hành vi tốt hơn dự kiến: **planner đã mô hình hoá được chính bài học của §5.**

Muốn thấy `Evictions` thật cần một tình huống hẹp hơn: số key phân biệt vừa đủ để planner tin là đáng, nhưng thực tế phân bố lệch khiến cache tràn.

### Bảng tra Memoize

| Chỉ số | Nghĩa | Ngưỡng hành động |
|---|---|---|
| `Hits` / (`Hits`+`Misses`) | tỷ lệ hit | **< 50 % → cân nhắc `enable_memoize=off`** |
| `Evictions > 0` | cache đầy, phải vứt bớt | tăng `work_mem` cho session đó |
| `Overflows > 0` | một entry quá lớn không vừa | key có quá nhiều dòng khớp — xem lại join |
| `Memory Usage` | RAM thật đang dùng | nhân với số connection để tính worst case |

---

## §6. Khi nested loop là thảm hoạ — và khi nó không

Query có ước lượng sai do giả định độc lập (Day 13): `region + country + type`.

| | rows đoán outer | actual outer | Plan | **time** |
|---|---|---|---|---|
| ép Nested Loop | **8.112** | **19.267** (sai **2,4×**) | Nested Loop | **402,8 ms** |
| planner tự quyết | 8.112 | 19.267 | **Nested Loop** *(cũng chọn NL)* | **384,5 ms** |

**Planner chọn nested loop, và nó đúng.** 19.267 device × ~103 dòng = 1.978.875 dòng kết quả, tốn 98.082 buffer, 385 ms.

Ước lượng sai 2,4 lần **không đủ** để lật plan — đúng như bài học Day 15.

### Vậy khi nào nested loop thật sự là thảm hoạ

Ba điều kiện phải **đồng thời**:

```
① outer thật lớn hơn ước lượng RẤT nhiều (>50×, không phải 2×)
② inner KHÔNG có index, hoặc index không vừa cache
③ Memoize không cứu được (key outer gần như duy nhất)
```

Ở lab, cả ba đều không thoả:
- ① sai chỉ 2,4×
- ② `device` có PK, bảng 9 MB nằm gọn trong RAM
- ③ Memoize hit 99 % ở tình huống lớn nhất

**Trên production thật, hãy hình dung:**

| | Lab | Production |
|---|---|---|
| outer | 19.267 (sai 2,4×) | 5.000.000 (sai 100×) |
| inner | 50.000 dòng, 9 MB, trong RAM | 500 triệu dòng, 200 GB, **không vừa RAM** |
| mỗi lookup | 0,008 ms (cache hit) | **~1 ms** (random read đĩa) |
| **tổng** | **385 ms** | **~83 phút** |

Và hash join cho cùng việc đó sẽ mất vài phút.

### Dấu hiệu nhận ra ngay trong plan

```
->  Nested Loop  (cost=... rows=8112 ...)        <- planner đoán
      ->  ...   (actual rows=19267 loops=1)      <- OUTER thật
      ->  Index Scan ...  (loops=19267)          <- so loops với rows đoán của outer
```

> **Luật: so `loops` của node inner với `rows` ước lượng của node outer. Lệch > 50 lần = nested loop đang chạy sai quy mô nó được thiết kế cho.**

---

## §7. Semi join và anti join

| Query | Node join | `actual rows` inner | loops | time |
|---|---|---|---|---|
| `EXISTS` | **`Nested Loop Semi Join`** | **1** | 50.000 | 80,2 ms |
| `NOT EXISTS` | **`Nested Loop Anti Join`** | **1** | 50.000 | 74,9 ms |

### Vì sao `actual rows` của inner chỉ bằng 1

**Semi join dừng ngay khi tìm được dòng ĐẦU TIÊN khớp.** Nó không cần biết có bao nhiêu dòng khớp — chỉ cần biết "có hay không".

Với `device_id = 42` có 3.731 dòng trong `ts_kv`, semi join chỉ đọc **1** rồi dừng. Tiết kiệm 3.730 dòng cho mỗi device.

Anti join cũng vậy: đọc được 1 dòng là biết ngay device đó **không** thoả `NOT EXISTS` → loại luôn.

Kết quả: `NOT EXISTS` trả về **0 dòng** (mọi device đều có telemetry) và chạy 74,9 ms — nhanh hơn cả `EXISTS`.

### Điểm cần nhớ

> **Semi/anti join + nested loop + index là plan tối ưu nhất cho câu hỏi "có tồn tại không", vì nó dừng sớm.**

Sai lầm thường gặp: viết `SELECT count(*) ... WHERE id IN (SELECT ...)` rồi so với 0, hoặc dùng `LEFT JOIN ... WHERE x IS NULL`. Cả hai đều **không** dừng sớm được trong nhiều trường hợp. Day 20 so 4 cách này bằng số.

Chi tiết đáng ghi: cả hai plan tốn **150.000 buffer** cho 50.000 lookup = **3 buffer mỗi lookup** — đúng bằng chiều cao cây B-tree (Day 06: root + internal + lá). Cost model hoạt động chính xác như lý thuyết.

---

## Bảng số liệu chính

| Kịch bản | Plan | time | buffers |
|---|---|---|---|
| join `type='controller'` — Nested Loop ✅ | NL + Index Only Scan | **15,7 ms** | **3.812** |
| — Hash Join | Hash Join | **677,3 ms (43×)** | 38.905 |
| — Merge Join | Merge Join | 590,3 ms | **105.016** |
| outer 519 | NL ✅ | 14,7 ms | 3.812 |
| outer 4.524 | NL ✅ | 91,5 ms | 23.948 |
| outer 44.957 | **Hash Join** ✅ | **1.442,9 ms** | 38.905 |
| outer 44.957 ép NL | NL + Memoize (hit **99,0 %**) | 2.620,7 ms (1,8×) | 187.698 |
| `device ⋈ tenant` | NL + **Memoize** (hit 96,1 %, 3 kB) | 4,8 ms | 1.247 |
| Memoize outer nhỏ, hit **18,6 %** | | **8,37 ms** | 9.348 |
| — tắt Memoize | | **6,56 ms (nhanh hơn 27 %)** | 11.074 |
| Memoize outer lớn, hit **53,9 %** | | **69,7 ms** | 72.602 |
| — không Memoize | | 81,0 ms | 132.530 |
| ước lượng sai 2,4× | NL (planner chọn) ✅ | 384,5 ms | 98.082 |
| `EXISTS` | **Nested Loop Semi Join** | 80,2 ms | 150.140 |
| `NOT EXISTS` | **Nested Loop Anti Join** | 74,9 ms | 150.140 |

---

## Ba điều dễ hiểu sai

| # | Hiểu nhầm | Sự thật đo được |
|---|---|---|
| 1 | "Memoize luôn giúp nested loop nhanh hơn" | Hit **18,6 %** → **chậm hơn 27 %**. Nó chỉ giúp khi key outer lặp nhiều (hit > 50 %) |
| 2 | "`loops` lớn là plan tệ" | outer 44.957 ép NL cho `loops = 5.000.000` mà chỉ chậm 1,8× — Memoize biến thành 50.000 lookup thật |
| 3 | "Hash join an toàn hơn nested loop" | Với outer 519 dòng + inner có index, hash join **chậm hơn 43 lần** vì phải quét toàn bộ 5 triệu dòng |

Thêm hai điều:
- **Ép `enable_nestloop=off` không cho anh thấy "nested loop ngây thơ"** — planner sẽ đảo thứ tự join để tìm cách nested loop ít tệ nhất.
- **`work_mem` quá nhỏ không gây `Evictions` — nó làm planner bỏ hẳn Memoize.** Planner đã mô hình hoá được chính bài học này.

---

## Áp dụng vào hệ thật

**1. Join bảng nhỏ × bảng lớn — mẫu phổ biến nhất trong hệ IoT:**

```sql
-- device (50k) ⋈ ts_kv (5M) : ĐÚNG cách
SELECT ... FROM device d JOIN ts_kv k ON k.device_id = d.id
WHERE d.tenant_id = $1 AND k.ts >= $2;
```

Điều kiện để nested loop thắng:
- ✅ lọc `device` xuống dưới ~10.000 dòng trước khi join
- ✅ **`ts_kv` phải có index bắt đầu bằng `device_id`** — nếu thiếu, nested loop thành thảm hoạ
- ✅ index tốt nhất: `(device_id, ts)` — cả join key lẫn điều kiện lọc (Day 07)

**Kiểm tra hệ mình:**
```sql
-- bảng lớn nào đang thiếu index trên FK?
SELECT c.conrelid::regclass AS bang, a.attname AS cot_fk
FROM pg_constraint c
JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
WHERE c.contype = 'f'
  AND NOT EXISTS (
    SELECT 1 FROM pg_index i
    WHERE i.indrelid = c.conrelid AND i.indkey[0] = c.conkey[1]
  );
```
**Thiếu index trên cột FK = mọi join qua nó đều buộc phải hash join hoặc nested loop thảm hoạ.**

**2. Đưa vào quy trình review plan — 3 câu hỏi:**

```
① Node inner có loops bao nhiêu? So với rows ƯỚC LƯỢNG của outer.
   Lệch > 50× -> nested loop đang chạy sai quy mô.

② Có Memoize không? Tỷ lệ hit bao nhiêu?
   < 50%  -> Memoize đang là gánh nặng, thử enable_memoize=off
   > 90%  -> Memoize đang cứu, đừng đụng vào
   Evictions > 0 -> tăng work_mem cho session đó

③ Inner có index không? Nếu thấy Seq Scan hoặc Materialize dưới
   Nested Loop với loops lớn -> THIẾU INDEX, sửa ngay.
```

**3. Với `EXISTS`/`NOT EXISTS`, ưu tiên viết đúng dạng đó** thay vì `IN` hay `LEFT JOIN ... IS NULL`. Semi/anti join dừng sớm — đo được `actual rows = 1` cho inner thay vì hàng nghìn.

**4. Cảnh giác với plan có `Memoize` + `Memory Usage` lớn.** Nó dùng `work_mem`, và nhân với số connection:
```
Memory Usage × max_connections = RAM worst case
5.272 kB × 100 = 527 MB   (chỉ cho một node Memoize)
```

**5. Khi debug query chậm bất thường, thử ép cả 3 thuật toán** để biết plan hiện tại tệ hơn phương án tốt nhất bao nhiêu:
```sql
SET enable_hashjoin=off; SET enable_mergejoin=off;  EXPLAIN (ANALYZE,BUFFERS) ...;
SET enable_nestloop=off; SET enable_mergejoin=off;  EXPLAIN (ANALYZE,BUFFERS) ...;
SET enable_nestloop=off; SET enable_hashjoin=off;   EXPLAIN (ANALYZE,BUFFERS) ...;
RESET ALL;
```
Mất 3 phút, và cho biết ngay có đáng đi sửa thống kê/index hay không.

---

## Câu hỏi mở sang các ngày sau

1. Hash join phải quét toàn bộ bảng lớn. `work_mem` ảnh hưởng nó thế nào, `Batches > 1` tốn bao nhiêu? → **Day 17**
2. Merge join tốn 105.016 buffer vì phải giữ thứ tự. Khi nào nó thắng? → **Day 18**
3. Memoize dùng `work_mem` — nó cạnh tranh với hash join và sort trong cùng query thế nào? → **Day 17, Day 19**
4. `EXISTS` vs `IN` vs `LEFT JOIN IS NULL` vs `NOT EXISTS` — cái nào thắng? → **Day 20**
5. Thứ tự join do ai quyết định, và `join_collapse_limit` là gì? → **Day 20**
