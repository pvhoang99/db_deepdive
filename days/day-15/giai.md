# Day 15 — Lời giải: Chẩn đoán mù + ôn tuần 3

> Bài chữa. Đo thật trên lab `SCALE=1`.
>
> ⚠️ **Đọc phần này trước:** 3 trong 5 ca **không tái hiện được thảm hoạ** như đề mô tả. Đó không phải lỗi của đề — đó là bài học quan trọng nhất hôm nay, và em ghi đúng như đo được thay vì viết cho khớp kịch bản.

---

## Bảng tổng kết chẩn đoán mù

| Ca | Chẩn đoán trước khi chạy | Thực tế đo được | Đúng/Sai |
|---|---|---|---|
| **1** | Generic plan từ lần 6, device lệch → plan sai | ✅ Plan **có** chuyển generic ở lần 6 — nhưng **không chậm đi** | **Nửa đúng** |
| **2** | Giả định độc lập → underestimate → nested loop nổ | ✅ Ước lượng **có** sụp 6,9 lần — nhưng query **nhanh hơn** | **Nửa đúng** |
| **3** | `reltuples = -1` → planner tưởng bảng rỗng → nested loop | ❌ Planner ước lượng **487.328** (sai 2,5 %), chọn hash join **đúng** | **SAI** |
| **4** | `key_id=1` chiếm quá nhiều % → planner đúng, dev sai | ✅ 27,3 % bảng — planner hoàn toàn đúng | **ĐÚNG** |
| **5** | Bloat → bảng và index phình → buffers tăng | ✅ Bảng phình **8,4×**, index **4,0×**, buffers **4,3×** | **ĐÚNG** |

**Tỷ lệ: 2 đúng hoàn toàn, 2 nửa đúng, 1 sai = 3/5.**

Và cái sai ở Ca 3 là cái đáng học nhất.

---

## Ca 1 — "5 lần đầu nhanh rồi chậm mãi"

### Chẩn đoán (viết trước khi chạy)

Prepared statement chuyển sang **generic plan** từ lần thứ 6 (Day 12 §4). Với dữ liệu lệch power-law, generic plan dùng selectivity trung bình → chọn sai plan cho device nóng.

### Kiểm chứng

| Lần | `Index Cond` in ra | rows đoán | actual | buffers | time |
|---|---|---|---|---|---|
| 1–5 | `device_id = '49000'::bigint` | **154** | 36 | 39 | 0,028–0,095 ms |
| **6** | **`device_id = $1`** | **177** | 36 | 39 | 0,047 ms |
| 7 (`tele(1)`) | `device_id = $1` | 177 | **100** | 45 | 0,116 ms |

**Plan CÓ chuyển generic đúng lần thứ 6** — dấu hiệu rõ ràng: `Index Cond` in `$1` thay vì hằng số.

### Nhưng query KHÔNG chậm đi. Vì sao?

Vì **cả hai plan đều là cùng một plan**: `Index Scan using idx_dev_ts_d` + `Limit 100`.

Index `(device_id, ts DESC)` phục vụ hoàn hảo cho mọi giá trị `device_id`:
- device ít dòng (49000, 36 dòng): quét hết 36 dòng → dừng
- device nhiều dòng (1, 107.947 dòng): `LIMIT 100` dừng sau 100 dòng

**`LIMIT` làm cho chi phí không phụ thuộc vào số dòng khớp.** Nên ước lượng sai (177 vs 100 hay 177 vs 36) chẳng ảnh hưởng gì.

> **Bài học quan trọng: generic plan chỉ gây hại khi ước lượng sai đủ để LẬT sang loại plan khác.** Với query có index hoàn hảo + `LIMIT`, không có plan nào khác để lật sang, nên nó vô hại.

### Điều kiện để bệnh này thật sự bùng

Cần **cả ba**:
1. Dữ liệu lệch mạnh (✅ có ở lab)
2. Prepared statement (✅ có)
3. **Tồn tại ít nhất hai plan khả dĩ có chi phí khác nhau nhiều** (❌ **không** có ở đây)

Điều kiện 3 xuất hiện khi: có nhiều index để chọn, hoặc query là **join** (nested loop vs hash join), hoặc không có `LIMIT`.

### Cách sửa ở tầng ứng dụng

| Driver | Cấu hình |
|---|---|
| **JDBC** | `prepareThreshold=0` (tắt server-side prepare) hoặc để mặc định 5 |
| **pgx (Go)** | `QueryExecModeExec` thay vì mặc định `QueryExecModeCacheStatement` |
| **Toàn cục** | `ALTER ROLE api_user SET plan_cache_mode = 'force_custom_plan';` |

**Cách kiểm tra query nào thật sự có nguy cơ:**
```sql
SET plan_cache_mode = 'force_generic_plan';
EXPLAIN <query>;
RESET plan_cache_mode;
```
Plan **giống** plan thường → an toàn, giữ prepared statement. Plan **khác hẳn** → có bom hẹn giờ.

---

## Ca 2 — "Thêm một điều kiện WHERE mà query chậm gấp 50 lần"

### Chẩn đoán

Giả định độc lập (Day 13). `region='eu-west'` ⟹ `country='DE'`, nên thêm `AND country='DE'` không lọc thêm dòng nào, nhưng planner nhân thêm một selectivity → **underestimate** → chọn nested loop cho tập lớn.

### Kiểm chứng

| | rows đoán node `device` | actual | Kiểu join | buffers | **time** |
|---|---|---|---|---|---|
| không có `country` | **7.263** | 7.276 | Nested Loop | 38.338 | **89,8 ms** |
| **có `country`** | **1.055** | 7.276 | Nested Loop | 38.338 | **76,7 ms** |
| sau `CREATE STATISTICS` | **7.233** | 7.276 | Nested Loop | 38.338 | **74,1 ms** |

**Ước lượng CÓ sụp 6,9 lần (7.263 → 1.055) đúng như chẩn đoán.**

`CREATE STATISTICS` sửa lại về 7.233 (sai 0,6 %) — cũng đúng như chẩn đoán.

### Nhưng query lại NHANH HƠN 15 %. Vì sao?

Vì **kiểu join không đổi** — cả ba trường hợp đều là `Nested Loop` với `Index Only Scan` ở nhánh trong.

Với 7.276 device (14,5 % của 50.000) và index `(device_id, ts DESC)` hoàn hảo cho nhánh trong, nested loop **vốn dĩ đã là plan tốt nhất**. Underestimate 6,9 lần chỉ làm planner càng **chắc chắn** chọn nested loop — mà nested loop lại đúng.

Chênh lệch 15 % chỉ là cache nóng dần qua 3 lần chạy (đúng bài học Day 03 §5).

> **Bài học: underestimate chỉ nguy hiểm khi nó đẩy planner từ plan ĐÚNG sang plan SAI. Nếu plan đúng vốn đã là nested loop, underestimate không gây hại gì.**

### Điều kiện để bệnh này bùng

Cần: nhánh ngoài phải **đủ lớn** để nested loop trở thành sai lầm, **và** nhánh trong phải **đắt** (không có index, hoặc bảng không vừa cache).

Ví dụ thật: nếu `device` có 5 triệu dòng, `eu-west/DE` khớp 700.000 dòng, planner đoán 100.000 → chọn nested loop → 700.000 lần random read vào bảng 200 GB → **hàng giờ**.

Ở lab, `ts_kv` nằm gọn trong RAM và có index hoàn hảo, nên nested loop 7.276 vòng chỉ tốn 66 ms.

---

## Ca 3 — "Job ETL nạp xong query ngay thì treo" — **CHẨN ĐOÁN SAI**

### Chẩn đoán (sai)

`reltuples = -1` sau `INSERT` → planner tưởng bảng rỗng → chọn nested loop với staging làm outer → 500.000 lần lookup.

### Thực tế

```
--- CHƯA analyze ---
 relpages | reltuples
----------+-----------
        0 |        -1          <- đúng như dự đoán

->  Seq Scan on staging s  (cost=0.00..7977.28 rows=487328) (actual rows=500000)
```

**Planner ước lượng 487.328 dòng — sai chỉ 2,5 %.** Và chọn **Hash Join**, hoàn toàn đúng.

| | rows đoán staging | Kiểu join | time |
|---|---|---|---|
| **chưa ANALYZE** | **487.328** | **Hash Join** ✅ | **99,8 ms** |
| sau ANALYZE | 500.000 | Hash Join | 86,8 ms |

Chỉ nhanh hơn **13 %** sau ANALYZE — không phải "nhanh gấp chục lần".

### Vì sao chẩn đoán sai — quay lại Day 01 §2

`reltuples = -1` **không** làm planner tưởng bảng rỗng. Như đã học ở Day 01: **planner không tin `relpages` trong catalog** — nó hỏi hệ điều hành số block thật của file, rồi suy ngược số dòng.

```
file thật: 3.104 page
độ rộng dòng ước tính: ~24 byte  ->  ~157 dòng/page
suy ra: 3.104 × 157 = 487.328 dòng ✓
```

Sai 2,5 % vì đoán đúng độ rộng dòng (`bigint + timestamptz + float8` = 24 byte, rất dễ đoán chính xác).

> **Em đã nhớ đúng hiện tượng (`reltuples = -1`) nhưng quên mất cơ chế bù (suy từ kích thước file). Đây chính là loại lỗi mà "chẩn đoán mù" sinh ra để phát hiện.**

### Vậy khi nào job ETL THẬT SỰ treo

Cơ chế suy từ kích thước file **chỉ đúng khi độ rộng dòng dễ đoán**. Nó vỡ khi:

| Tình huống | Vì sao vỡ |
|---|---|
| **Bảng có cột `text`/`jsonb` độ dài biến thiên** | không đoán được byte/dòng → sai hàng chục lần |
| **`TRUNCATE` rồi `INSERT` trong CÙNG transaction** | file chưa được ghi ra, planner thấy 0 page → **thật sự tưởng rỗng** |
| **Thiếu thống kê CỘT** (không phải thống kê bảng) | `WHERE` trên staging → dùng hằng số 0,5 % (Day 01) |
| **Nhiều bảng staging join nhau** | sai số nhân lên (Day 12 §1) |

Ca thứ hai là ca nguy hiểm nhất và hay gặp nhất trong job ETL thật:
```sql
BEGIN;
TRUNCATE staging;
COPY staging FROM ...;     -- file mới, planner thấy 0 page trong cùng transaction
SELECT ... JOIN staging;   -- <- ĐÂY mới là chỗ nổ
COMMIT;
```

### Sửa job ETL ở đâu

**Vẫn là câu trả lời cũ, và vẫn bắt buộc:**
```sql
BEGIN;
TRUNCATE staging;
COPY staging FROM '/data/x.csv';
ANALYZE staging;              -- <<< một dòng, tốn ~200ms
SELECT ... JOIN staging ...;
COMMIT;
```

Nhưng giờ ta hiểu **vì sao** nó cần: không phải vì `reltuples = -1`, mà vì:
1. thống kê **cột** (MCV, histogram) hoàn toàn không tồn tại — planner dùng hằng số 0,5 %
2. trong cùng transaction sau `TRUNCATE`, cơ chế suy từ file size cũng vỡ
3. với cột độ rộng biến thiên, ước lượng số dòng cũng sai

---

## Ca 4 — "Index có mà không dùng, ép dùng thì chậm hơn" — **ĐÚNG**

### Kiểm chứng

```
 key_id |  count  | pct
--------+---------+------
      1 | 1362527 | 27.3      <- lấy 27,3% bảng
      2 |  908505 | 18.2
      3..8 | ~455.000 mỗi cái | 9.1
```

| | Plan | cost | time |
|---|---|---|---|
| bình thường | Seq Scan | 103.581 | **411,1 ms** |
| `enable_seqscan = off` | **Seq Scan** | **10000103581** | **411,7 ms** |

### 💡 Hai phát hiện đắt giá

**1. `enable_seqscan = off` KHÔNG ép được index — nó vẫn chọn Seq Scan.**

Nhìn cost: `10000103581.45` — có tiền tố `1e10`. Đó là `disable_cost` **10 tỷ** được cộng vào.

> **`enable_*` là PHẠT COST, không phải công tắc.** Nếu không còn cách nào khác, planner vẫn chọn plan bị phạt. Ở đây `ts_kv` không có index nào trên `key_id` đứng đầu, nên seq scan là lựa chọn duy nhất.

Đây là điều Day 04 §3 đã nói, và giờ nhìn thấy tận mắt con số `1e10`.

**2. Planner hoàn toàn đúng.** `key_id = 1` lấy **27,3 %** bảng — vượt xa mọi điểm hoà vốn (Day 04: `device_id` không bao giờ, `ts` là 33 % nhờ correlation = 1). Với `correlation = 0,164`, index scan sẽ phải chạm gần như mọi page bằng random I/O.

### Giải thích cho dev đó bằng hai câu, có số

> **"`key_id = 1` khớp 1.362.527 dòng — **27,3 %** cả bảng, và `correlation` của cột này chỉ 0,16 nên các dòng đó nằm rải khắp 37.698 page. Đọc 27 % số dòng bằng random I/O sẽ chạm gần như toàn bộ page mà đắt gấp 4 lần đọc tuần tự — nên seq scan 411 ms là plan đúng, và cách sửa không phải ép index mà là làm cho query lọc chặt hơn (thêm điều kiện `ts`, dùng index `(key_id, ts)`)."**

Con số để chốt: `EXPLAIN` khi ép `enable_seqscan=off` vẫn ra Seq Scan với cost `1e10` — **Postgres không có lựa chọn nào khác, chứ không phải nó "không chịu" dùng index.**

---

## Ca 5 — "Query chậm dần theo tháng dù dữ liệu không tăng" — **ĐÚNG**

### Kiểm chứng

| Trạng thái | **bảng** | **index** | **buffers** của lookup | time | `dead_tuple_%` |
|---|---|---|---|---|---|
| ban đầu | **3.584 kB** | **1.552 kB** | **3** | 0,033 ms | 0 |
| sau 8 vòng UPDATE | **30 MB (8,4×)** | **6.184 kB (4,0×)** | **13 (4,3×)** | 0,105 ms | **76,04 %** |
| sau `VACUUM` | 30 MB *(y nguyên)* | 6.184 kB *(y nguyên)* | **4** | 0,026 ms | 0 |
| sau `REINDEX` + `VACUUM FULL` | **3.336 kB** | **1.552 kB** | **3** | 0,030 ms | 0 |

**Số dòng không đổi (50.000). Bảng phình 8,4 lần, index phình 4 lần, buffers của một lookup tăng 4,3 lần.**

`dead_tuple_percent = 76,04 %` — ba phần tư bảng là xác chết.

### Ba mức sửa — và mỗi mức lấy lại được gì

| Cách | Lấy lại | Không lấy lại | Khoá |
|---|---|---|---|
| **`VACUUM`** | buffers **13 → 4** (dọn dead tuple, khôi phục visibility map) | **dung lượng** — bảng vẫn 30 MB | không chặn ghi |
| **`REINDEX CONCURRENTLY`** | dung lượng index (6.184 → 1.552 kB) | dung lượng heap | không chặn ghi |
| **`VACUUM FULL`** / `pg_repack` | **tất cả** (30 MB → 3.336 kB) | — | **ACCESS EXCLUSIVE** (chặn cả SELECT) |

Điều đáng chú ý: **`VACUUM` một mình đã đưa buffers từ 13 về 4** — gần bằng trạng thái ban đầu — dù không trả lại một byte dung lượng nào. Vì nó dọn dead tuple ra khỏi trang index và khôi phục `all-visible` (Day 08).

### Sửa ngắn hạn và dài hạn

**Ngắn hạn (làm ngay, không downtime):**
```sql
VACUUM (VERBOSE, ANALYZE) t_state;
REINDEX INDEX CONCURRENTLY idx_state_name;
```

**Dài hạn (sửa gốc):**
```sql
-- 1. Hạ ngưỡng autovacuum riêng cho bảng bị UPDATE nhiều
ALTER TABLE t_state SET (autovacuum_vacuum_scale_factor = 0.02);   -- 2% thay vì 20%

-- 2. Chừa chỗ trong page để UPDATE thành HOT (Day 24)
ALTER TABLE t_state SET (fillfactor = 70);

-- 3. Bỏ index trên cột bị UPDATE (Day 10: index trên cột bị đổi phình +293%)
```

Và quan trọng nhất về mặt thiết kế: **tách cột "nóng" (hay đổi) ra bảng riêng.** Nếu chỉ `firmware` bị cập nhật liên tục, để nó cùng bảng với `name`/`tenant_id` khiến toàn bộ dòng bị viết lại mỗi lần.

---

## §6. Ôn tuần 3

### A. Bảng tổng kết — 3/5

Xem bảng ở đầu bài.

**Điều học được từ 2 ca "nửa đúng" và 1 ca sai quan trọng hơn 2 ca đúng:**

> **Chẩn đoán được cơ chế (ước lượng sai ở đâu, vì sao) là chưa đủ. Phải trả lời thêm: sai số đó có đủ để LẬT plan sang loại khác không?** Nếu không, nó vô hại.

Ba ca thất bại đều cùng một lý do: **lab quá nhỏ và index quá tốt** để sai số trở thành thảm hoạ. Trên bảng 500 GB không vừa RAM, cả ba đều sẽ nổ.

### B. Cây quyết định chẩn đoán — dán lên tường

```
QUERY CHẬM
│
├─① Có node nào loops > 1 không?
│   └─ CÓ → nhân actual_time × loops trước khi làm gì khác          (Day 02)
│
├─② Quét TỪ LÁ LÊN: node đầu tiên có rows lệch actual > 10× ?
│   │
│   ├─ CÓ → sai số này có đủ LẬT plan không? (thử force plan khác, đo)
│   │   │
│   │   ├─ KHÔNG lật → BỎ QUA. Đi tiếp sang nhánh ③.       ← ca 1, ca 2
│   │   │
│   │   └─ CÓ lật → cột lọc là gì?
│   │       ├─ 1 cột, giá trị hiếm ngoài MCV → SET STATISTICS 1000   (Day 11)
│   │       ├─ 2+ cột cùng bảng phụ thuộc  → CREATE STATISTICS       (Day 13)
│   │       ├─ biểu thức f(col)            → CREATE STATISTICS ON (expr) (Day 13)
│   │       ├─ bảng vừa nạp / TRUNCATE     → ANALYZE trong job       (Day 15 ca 3)
│   │       ├─ giá trị ngoài histogram     → SET STATISTICS + partition (Day 11 §7)
│   │       ├─ tham số $1, plan có Index Cond: $1 → plan_cache_mode  (Day 12 §4)
│   │       └─ hàm trả bảng không inline   → viết lại LANGUAGE sql   (Day 12 §5)
│   │
│   └─ KHÔNG lệch → ước lượng lành mạnh, sang ③
│
├─③ Rows Removed by Filter > 10 × số dòng trả về?
│   ├─ CÓ → điều kiện đang ở Filter, phải đưa vào Index Cond
│   │       → composite index đúng thứ tự: = trước, ORDER BY giữa, range cuối (Day 07)
│   │       → hoặc partial index nếu điều kiện cố định                (Day 09)
│   └─ KHÔNG → sang ④
│
├─④ buffers ≈ relpages nhưng chỉ trả vài dòng?
│   ├─ selectivity < 5% → thiếu index / index sai thứ tự             (Day 04, 07)
│   └─ selectivity > 25% → planner ĐÚNG, seq scan là hợp lý          ← ca 4
│                          (kiểm chứng: enable_seqscan=off vẫn ra Seq Scan
│                           với cost 1e10 = không có lựa chọn khác)
│
├─⑤ temp_written > 0 ?
│   ├─ đo % thời gian spill chiếm trước khi tăng work_mem            (Day 03 §6)
│   └─ ưu tiên: xoá node Sort bằng index > giảm width > SET LOCAL work_mem
│
├─⑥ Heap Fetches cao / all_visible thấp?
│   └─ VACUUM + hạ autovacuum_vacuum_scale_factor cho bảng đó        (Day 08)
│
└─⑦ Query chậm DẦN theo thời gian, dữ liệu không tăng?
    └─ BLOAT. Đo: pgstattuple.dead_tuple_percent, pgstatindex.avg_leaf_density
        ├─ ngắn hạn: VACUUM (buffers 13→4) + REINDEX CONCURRENTLY
        └─ dài hạn: fillfactor + hạ autovacuum threshold + bỏ index
                    trên cột hay đổi + tách cột nóng ra bảng riêng    ← ca 5
```

**Nhánh quan trọng nhất là ②: "sai số này có đủ lật plan không?"** — nó ngăn ta phí cả buổi chiều sửa một ước lượng sai vô hại.

### C. Ba điều tôi tưởng đúng mà hoá ra sai trong tuần 3

**1. "Ước lượng sai nhiều lần thì query chắc chắn chậm."**

*Sự thật:* Ca 1 (sai 5 lần), Ca 2 (sai 6,9 lần), Ca 3 (sai 2,5 %) — **cả ba đều không chậm đi**. Sai số chỉ gây hại khi nó **lật plan sang loại khác**. Với query có index hoàn hảo + `LIMIT`, hoặc khi plan đúng vốn dĩ đã là nested loop, sai số vô hại.

**2. "`reltuples = -1` nghĩa là planner tưởng bảng rỗng."**

*Sự thật:* Ca 3 — planner ước lượng **487.328** (sai 2,5 %) cho bảng có `reltuples = -1`. Nó suy ngược từ **kích thước file thật** (3.104 page × ~157 dòng/page). Cái thật sự thiếu là **thống kê CỘT** (MCV, histogram), không phải số dòng.

**3. "`enable_seqscan = off` ép được planner dùng index."**

*Sự thật:* Ca 4 — vẫn ra Seq Scan, với cost `10000103581`. Tiền tố `1e10` là `disable_cost`. Đây là **phạt cost**, không phải công tắc — nếu không có index nào dùng được, planner vẫn chọn cái bị phạt.

**Bonus 4:** `VACUUM` không trả lại một byte dung lượng nào (30 MB trước và sau), nhưng vẫn đưa buffers của một lookup từ **13 xuống 4**. Dọn dead tuple ≠ thu hồi dung lượng, và cái đầu mới là cái ảnh hưởng tốc độ query hằng ngày.

---

## Bảng số liệu chính

| Ca | Chỉ số | Trước | Sau |
|---|---|---|---|
| **1** | plan chuyển generic | lần 1–5: `= '49000'::bigint` | **lần 6: `= $1`** |
| 1 | rows đoán | 154 | 177 (actual 36 / 100) |
| 1 | time | 0,028–0,095 ms | 0,047–0,116 ms — **không chậm đi** |
| **2** | rows đoán node `device` | **7.263** | **1.055** (thêm `country`) → **7.233** (có statistics) |
| 2 | actual | 7.276 | 7.276 |
| 2 | time | 89,8 ms | 76,7 ms → **74,1 ms — nhanh hơn** |
| **3** | `reltuples` | **−1** | 500.000 |
| 3 | rows đoán staging | **487.328** (sai **2,5 %**) | 500.000 |
| 3 | kiểu join | **Hash Join** ✅ | Hash Join |
| 3 | time | 99,8 ms | 86,8 ms (**chỉ nhanh 13 %**) |
| **4** | `key_id=1` chiếm | **27,3 %** bảng | — |
| 4 | `enable_seqscan=off` | **vẫn Seq Scan**, cost **1e10** | — |
| **5** | bảng | 3.584 kB | **30 MB (8,4×)** |
| 5 | index | 1.552 kB | **6.184 kB (4,0×)** |
| 5 | buffers lookup | 3 | **13 (4,3×)** → VACUUM: **4** → VACUUM FULL: **3** |
| 5 | `dead_tuple_percent` | 0 | **76,04 %** |

---

## Áp dụng vào hệ thật

**Ca giống nhất với sự cố thật: Ca 5 (bloat) và Ca 3 (ETL).**

### Ca 5 áp vào hệ IoT

Bảng `device_state` / `device_credentials` / `session` — số dòng ổn định, `UPDATE` liên tục (last_seen, firmware, token).

**Cách xác minh trên production (chỉ đọc):**
```sql
CREATE EXTENSION IF NOT EXISTS pgstattuple;

-- bảng nào bloat nặng nhất
SELECT c.relname,
       pg_size_pretty(pg_relation_size(c.oid)) AS size,
       s.n_live_tup, s.n_dead_tup,
       round(100.0*s.n_dead_tup/NULLIF(s.n_live_tup+s.n_dead_tup,0),1) AS pct_chet,
       s.last_autovacuum
FROM pg_stat_user_tables s JOIN pg_class c ON c.oid = s.relid
WHERE s.n_dead_tup > 10000
ORDER BY s.n_dead_tup DESC LIMIT 20;

-- xác nhận bằng pgstattuple (ĐẮT — chạy trên replica)
SELECT * FROM pgstattuple('device_state');
SELECT * FROM pgstatindex('idx_device_state_xxx');
```

**Ngưỡng hành động:** `dead_tuple_percent > 20 %` hoặc `avg_leaf_density < 60 %`.

### Ca 3 áp vào job ETL

**Cách xác minh:** thêm log vào job, in ra plan thật:
```sql
-- trong job, trước bước join
EXPLAIN (FORMAT JSON) SELECT ... JOIN staging ...;
-- ghi vào log, so plan giữa lần chạy nhanh và lần chạy chậm
```

Và **fix bắt buộc, một dòng:**
```sql
ANALYZE staging;   -- ngay sau COPY/INSERT, trước mọi câu SELECT
```

Chi phí ~200 ms trên 5 triệu dòng (đo được ở Day 01). Không có lý do gì để bỏ qua.

---

## Hết tuần 3

| Ngày | Câu hỏi được trả lời | Con số đắt nhất |
|---|---|---|
| 11 | Planner nhìn thấy gì | MCV sai **0,12 %**, `n_distinct` sai **42,6 %**, correlation làm chênh **5,3×** |
| 12 | Sai số lan truyền thế nào | generic plan sai **617 lần**, giả định độc lập sai **2,34×** |
| 13 | Sửa tương quan cột | `CREATE STATISTICS`: **2,36× → 0,19 %** |
| 14 | Cost model làm gì | tính tay khớp **0,005 %**; `random_page_cost` giảm cost Index Scan **71,6 %** nhưng bitmap **0,7 %** |
| 15 | Chẩn đoán mù | **3/5** — và 3 ca thất bại dạy nhiều hơn 2 ca thành công |

**Bài học lớn nhất của tuần 3:**

> Biết planner sai ở đâu là **một nửa** công việc. Nửa còn lại là biết sai số đó **có quan trọng không** — và câu trả lời phụ thuộc vào việc có tồn tại một plan thay thế đủ khác biệt hay không.

Tuần 4 chuyển sang **cái xảy ra sau khi plan đã chọn đúng**: join, sort, aggregate — và `work_mem` quyết định sống chết ở đó.
