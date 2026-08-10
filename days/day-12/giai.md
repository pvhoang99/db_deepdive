# Day 12 — Lời giải: Khi ước lượng sai thì plan nổ

> Bài chữa. Đo thật trên lab `SCALE=1`, dataset gốc (5.000.000 dòng, `ts` correlation = 1).

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án |
|---|---|---|
| 1 | Ước lượng 10 nhưng thực tế 100.000 thì plan hỏng thế nào? | **Nested Loop với 100.000 vòng lặp** thay vì hash join; hash table thiếu `work_mem` → spill; chọn index scan cho nửa bảng |
| 2 | Sai ở node **lá** hay node **gốc** nguy hiểm hơn? | **Node lá** — sai số **nhân lên** qua từng tầng join, không cộng |
| 3 | Prepared statement chạy 10 lần có cùng một plan không? | **KHÔNG.** 5 lần đầu custom plan, **từ lần 6 chuyển generic** — và ở lab, generic sai **617 lần** |

---

## §1. Sai số lan truyền qua join

| # | Node (từ lá lên) | rows đoán | actual rows | **tỷ lệ lệch** |
|---|---|---|---|---|
| 1 | `Seq Scan on tenant` | 20 | 20 | 1,00 |
| 2 | `Seq Scan on device` (`region='eu-west'`) | **7.257** | **7.276** | **1,003** |
| 3 | `Index Scan on ts_kv` (khoảng 2 ngày) | **109.815** | **111.117** | **1,012** |
| 4 | `Hash Join` (ts_kv ⋈ device) | **15.939** | **15.241** | **0,956** |
| 5 | `Hash Join` (⋈ tenant) | 15.939 | 15.241 | 0,956 |
| 6 | `HashAggregate` | 20 | 20 | 1,00 |

**Query này ước lượng gần như hoàn hảo — sai số dưới 5 % ở mọi node.** `Execution Time: 77,2 ms`.

Đây là kết quả tốt, và nó dạy một điều: **khi thống kê tươi và các cột độc lập, planner rất giỏi.** Vấn đề chỉ xuất hiện khi một trong hai điều kiện đó vỡ — §2 làm vỡ điều kiện thứ hai.

### Cơ chế nhân lên (lý thuyết cần nhớ)

```
lá A:      est 100     thật 200      (×2)
lá B:      est 100     thật 200      (×2)
A ⋈ B:     est 1.000   thật 4.000    (×4)   <- 2 × 2
(A⋈B) ⋈ C: est 10.000  thật 64.000   (×6,4)
```

**Sai số nhân, không cộng.** Lệch 2 lần ở hai lá thành lệch 6,4 lần ở gốc. Với 5 bảng thì thành hàng trăm lần.

> **Luật vận hành: quét plan TỪ LÁ LÊN, tìm node ĐẦU TIÊN lệch > 10 lần. Sửa chỗ đó. Node gốc lệch chỉ là hậu quả.**

---

## §2. Hai kiểu hỏng — dựng ca underestimate

### Dữ liệu bẫy

```
    region    | country |    type    | count
--------------+---------+------------+-------
 ap-southeast | VN      | sensor     | 19267
 ap-southeast | VN      | gateway    |  1910
 ap-southeast | VN      | controller |   226
```

Chú ý: **`region='ap-southeast'` ⟺ `country='VN'`** — hai cột phụ thuộc hàm hoàn toàn (seed cố ý làm vậy).

### Kết quả

```
->  Seq Scan on device d  (cost=0.00..2082.00 rows=8240) (actual rows=19267)
      Filter: ((region = 'ap-southeast') AND (country = 'VN') AND (type = 'sensor'))
```

| Node | rows đoán | actual | lệch |
|---|---|---|---|
| **`Seq Scan on device`** | **8.240** | **19.267** | **thiếu 2,34 lần** |
| `Index Scan on ts_kv` | 1.615.131 | 1.611.191 | 1,00 ✓ |
| `Hash Join` | **266.174** | **637.591** | **thiếu 2,40 lần** |

### Vì sao node `device` sai — giả định độc lập

Planner nhân ba selectivity với nhau, coi ba cột **độc lập**:

```
sel(region='ap-southeast') × sel(country='VN') × sel(type='sensor')
= 0,4287 × 0,4288 × 0,8981
= 0,1651
rows = 0,1651 × 50.000 = 8.255      ≈ 8.240 planner in ✓
```

Nhưng `country='VN'` **không thêm thông tin gì** khi đã có `region='ap-southeast'` — mọi device ap-southeast đều ở VN. Selectivity thật:

```
sel thật = 0,4287 × 1,0 × 0,8981 = 0,385
rows thật = 0,385 × 50.000 = 19.267 ✓
```

**Planner nhân thừa một lần với 0,4288 → sai thiếu đúng 2,33 lần.** Khớp chính xác con số quan sát được.

> **Đây là "giả định độc lập" — lỗi kinh điển nhất của mọi cost-based optimizer. Day 13 dạy cách sửa bằng `CREATE STATISTICS`.**

### Hai kiểu hỏng — đo cả hai

| | Hash Join (planner tự chọn) | Nested Loop (bị ép) |
|---|---|---|
| **Execution Time** | **661,6 ms** | **1.069,1 ms** |
| buffers | 641.280 | **770.932** |
| `loops` của nhánh trong | 1 | **1.611.191** |
| Memoize | — | `Hits: 1.561.192  Misses: 49.999` |

**Nested loop chậm 1,6 lần.** Nghe không đáng sợ — **nhưng chỉ vì `Memoize` cứu.**

Không có Memoize, nhánh trong phải chạy **1.611.191 lần** thay vì 49.999 lần — chậm hơn ~32 lần (Day 02 §2 đã đo cùng cấu trúc này). Và Memoize chỉ hoạt động vì `device` chỉ có 50.000 dòng và cache 4,5 MB vừa `work_mem`.

**Trên bảng thật 50 triệu device, Memoize sẽ overflow, và nested loop sẽ là 1,6 triệu lần random read.**

### Bất đối xứng: underestimate vs overestimate

| | Underestimate (tưởng ít) | Overestimate (tưởng nhiều) |
|---|---|---|
| Chọn sai | **Nested Loop** cho tập lớn | bỏ index, seq scan |
| | Index Scan cho nửa bảng | Hash Join với build side to |
| | `work_mem` thiếu → spill | cấp thừa RAM |
| **Mức thiệt hại** | **50 ms → 15 phút** (phi tuyến) | chậm **vài lần** (tuyến tính) |

> **Nhớ tính bất đối xứng này: underestimate giết server, overestimate chỉ làm chậm.** Khi phải chọn giữa hai loại sai, luôn thiên về ước lượng cao hơn.

---

## §3. Sửa bằng statistics target

| device_id | **thật** | target 100 | target 2000 | Nhận xét |
|---|---|---|---|---|
| **1** (nóng nhất) | **107.947** | **103.114** (−4,5 %) | **108.358** (+0,4 %) | trong MCV cả hai lần, đều tốt |
| **31337** (đuôi) | **30** | **153** (+410 %) | **68** (+127 %) | cải thiện, chưa hết |
| **49999** (đuôi) | **39** | **153** (+292 %) | **68** (+74 %) | cải thiện, chưa hết |

Nâng target: MCV **100 → 2.000**, `n_distinct` **28.704 → 49.849** (thật 50.000, sai còn **0,3 %**).

### Có device nào nâng target vẫn không cứu được — và vì sao

**Có: mọi device thuộc phần đuôi.**

Với target 2000, MCV chứa 2.000 device nóng nhất. Còn **48.000 device đuôi** vẫn phải dùng công thức "chia đều":

```
selectivity = (1 − Σ freq MCV) / (n_distinct − 2.000)
rows = 68     (cho MỌI device ngoài MCV)
```

Nhưng thực tế phần đuôi **cũng lệch**: device 31337 có 30 dòng, device 49999 có 39 dòng, và chắc chắn có device đuôi khác có 200 dòng. **Một con số 68 không thể đúng cho cả 48.000 device.**

> **Giới hạn cơ bản: MCV chỉ mô tả được phần đỉnh. Phần đuôi luôn bị coi là phẳng, dù nó không phẳng.** Nâng target chỉ đẩy ranh giới đỉnh/đuôi ra xa hơn, không xoá được vấn đề.

Nhưng chú ý điều quan trọng: **sai số ở đây là +74 % đến +127 % — tức 2 lần, không phải 100 lần.** Đó là mức planner vẫn chọn đúng loại plan. Nâng target đã chuyển vấn đề từ "nguy hiểm" sang "chấp nhận được".

### Cái giá

`ANALYZE` với target 2000 quét 600.000 dòng thay vì 30.000 (20 lần). `pg_statistic` to hơn 20 lần cho cột đó. Planning time tăng.

Chỉ làm cho **vài cột** thật sự có vấn đề, và luôn `ANALYZE` lại sau khi đổi.

---

## §4. Custom plan vs generic plan — chỗ đắt nhất bài này

`PREPARE q(bigint) AS SELECT count(*) FROM ts_kv WHERE device_id = $1;`

| Lần | `Filter` in ra | rows đoán | actual | Loại plan |
|---|---|---|---|---|
| 1 | `device_id = '1'::bigint` | **108.527** | 107.947 | **custom** ✅ |
| 2–5 | `device_id = '1'::bigint` | 108.527 | — | custom |
| **6** | **`device_id = $1`** | **175** | **107.947** | **generic** ⚠️ |
| 7 (`q(49999)`) | `device_id = $1` | 175 | 39 | generic |

**Đúng lần thứ 6, plan chuyển sang generic.** Dấu hiệu nhận biết: `Filter` in `$1` thay vì hằng số.

### Con số gây sốc

```
lần 1 (custom):  rows=108.527   actual=107.947    sai 0,5 %
lần 6 (generic): rows=175       actual=107.947    sai 617 LẦN
```

**Cùng một câu lệnh, cùng một tham số, cùng dữ liệu. Ước lượng sai đi 617 lần chỉ vì đã chạy đủ 5 lần.**

Generic plan dùng selectivity **trung bình trên mọi giá trị**: `5.000.000 / 28.704 n_distinct ≈ 175`. Nó không biết `$1 = 1` là device nóng nhất chiếm 2,16 % bảng.

### So generic vs custom cho device đuôi

| | rows đoán | actual | Execution Time |
|---|---|---|---|
| **generic** (`q(49999)`) | 175 | 39 | **297,6 ms** |
| **custom** (`q(49999)`) | **153** | 39 | **267,5 ms** |

Ở đây chênh chỉ 11 % — vì `count(*)` trên cột không có index phù hợp thì **cả hai đều seq scan**, plan giống nhau, chỉ khác cost.

> **Điều này quan trọng: generic plan không phải lúc nào cũng gây hại. Nó chỉ nổ khi ước lượng sai đủ nhiều để LẬT sang loại plan khác** — ví dụ có index và ước lượng 175 khiến nó chọn index scan cho 107.947 dòng, hoặc chọn nested loop cho một join.

Ở lab, `ts_kv` hiện không có index đơn trên `device_id` nên cả hai plan trùng nhau. **Trên hệ thật có index, sai 617 lần là đủ để lật plan.**

### 🔧 Rủi ro thật với JDBC / pgx

| Driver | Hành vi mặc định | Cách kiểm soát |
|---|---|---|
| **JDBC (PgJDBC)** | dùng server-side prepare sau **5 lần** (`prepareThreshold=5`) | `prepareThreshold=0` để tắt hẳn, hoặc `-1` để prepare ngay |
| **pgx (Go)** | mặc định `QueryExecModeCacheStatement` — có prepared statement cache | `QueryExecModeExec` hoặc `QueryExecModeSimpleProtocol` để tắt |
| **asyncpg / psycopg3** | có statement cache | `statement_cache_size=0` |
| **PgBouncer transaction mode** | trước 1.21 làm mất prepared statement (vô tình "chữa" bug này) | `max_prepared_statements` |

**Triệu chứng nhận diện:** *"endpoint chạy nhanh sau khi restart pod, rồi vài phút sau chậm hẳn, restart lại nhanh"*. Đó chính là bộ đếm 5 lần được reset khi connection mới.

**Ba cách xử lý, theo thứ tự nên thử:**

```sql
-- 1. Sửa gốc: cho planner mô tả tốt hơn phần đuôi (giữ được lợi ích plan cache)
ALTER TABLE ts_kv ALTER COLUMN device_id SET STATISTICS 2000;
ANALYZE ts_kv;
```

```sql
-- 2. Tắt generic plan cho session/role có query lệch
ALTER ROLE api_user SET plan_cache_mode = 'force_custom_plan';
-- cái giá: mất ~0,03-0,3 ms planning mỗi lần chạy
```

```
-- 3. Tắt prepared statement ở tầng driver (thô nhất, mất cả lợi ích parse cache)
jdbc:postgresql://...?prepareThreshold=0
```

**Cách kiểm tra hệ của anh có dính không — làm ngay hôm nay:**
```sql
SET plan_cache_mode = 'force_generic_plan';
EXPLAIN <query nóng nhất của anh, với tham số>;
RESET plan_cache_mode;
```
Nếu plan khác hẳn plan bình thường → anh đang có một quả bom hẹn giờ ở lần chạy thứ 6.

---

## §5. Khi nào planner "cố tình" chấp nhận ước lượng xấu

### Thí nghiệm hàm trả bảng — và một phát hiện ngoài dự kiến

```sql
CREATE FUNCTION dev_of_tenant(t int) RETURNS SETOF device
LANGUAGE sql STABLE AS $$ SELECT * FROM device WHERE tenant_id = t $$;

EXPLAIN SELECT * FROM dev_of_tenant(1);
->  Seq Scan on device  (cost=0.00..1832.00 rows=10070)
      Filter: (tenant_id = 1)
SELECT count(*) ...  ->  10.025
```

**Ước lượng 10.070 vs thật 10.025 — sai 0,4 %. Không hề đoán 1000 như đề bài dự kiến.**

Và sau khi khai `ROWS 10000`:
```
->  Seq Scan on device  (cost=0.00..1832.00 rows=10070)     <- Y HỆT
```

**`ROWS` không có tác dụng gì.** Vì sao?

### Function inlining — cơ chế cần biết

Nhìn kỹ plan: nó in `Seq Scan on device`, **không** in `Function Scan on dev_of_tenant`. Planner đã **nội tuyến (inline)** thân hàm vào query.

Postgres inline một hàm SQL khi thoả **mọi** điều kiện:
- `LANGUAGE sql` (không phải plpgsql)
- thân hàm là **một câu `SELECT` duy nhất**
- không `VOLATILE` (ở đây `STABLE` ✅)
- không `SECURITY DEFINER`, không `SET` config

Khi inline được, planner nhìn thấy query thật và dùng thống kê thật → ước lượng chính xác, `ROWS` bị bỏ qua hoàn toàn.

### Khi nào `ROWS` mới có tác dụng — và ước lượng mặc định thật sự là gì

`ROWS` chỉ dùng khi hàm **không inline được**:

| Loại hàm | Inline? | Ước lượng mặc định |
|---|---|---|
| `LANGUAGE sql`, 1 câu SELECT, STABLE/IMMUTABLE | ✅ | dùng thống kê thật |
| **`LANGUAGE plpgsql`** | ❌ | **1.000 dòng** |
| `LANGUAGE sql` nhưng VOLATILE | ❌ | 1.000 dòng |
| `LANGUAGE sql` nhiều câu lệnh | ❌ | 1.000 dòng |
| trả về scalar (không SETOF) | ✅/❌ | 1 dòng |

> **Bài học thực dụng: viết hàm bằng `LANGUAGE sql` một câu SELECT bất cứ khi nào có thể — không chỉ nhanh hơn (không có overhead PL), mà còn cho planner nhìn xuyên qua.** Chuyển một hàm PL/pgSQL đơn giản sang SQL có thể sửa được ước lượng sai 1.000 lần mà không đổi gì khác.

Với hàm PL/pgSQL bắt buộc phải giữ, khai `ROWS`:
```sql
CREATE FUNCTION f(...) RETURNS SETOF x LANGUAGE plpgsql ROWS 50 AS $$ ... $$;
```

### Kiểm chứng trong join

```
Hash Join  (cost=1958.31..13098.74 rows=57727) (actual rows=51440)
  ->  Seq Scan on device  (rows=10070)  (actual rows=10025)
Execution Time: 97,0 ms
```
Ước lượng tốt ở mọi tầng → plan tốt. Nếu hàm không inline được và đoán 1.000 dòng, planner sẽ tưởng nhánh đó nhỏ 10 lần → rất có thể chọn nested loop.

### Bảng tra đầy đủ

| Dạng | Vì sao mù | Cách né |
|---|---|---|
| `WHERE f(col) = ?` hàm tự viết | không có statistics cho hàm | **expression index** (Day 09 §6) hoặc `CREATE STATISTICS ON (expr)` |
| Hàm trả bảng **không inline được** | mặc định **1.000 dòng** | viết lại thành `LANGUAGE sql` 1 câu, hoặc khai `ROWS n` |
| `WHERE col = (SELECT ...)` | giá trị chưa biết lúc plan | tách thành 2 query, truyền kết quả vào |
| CTE `MATERIALIZED` | rào chắn tối ưu hoá | `NOT MATERIALIZED` (Day 20) |
| `WHERE a = ? AND b = ?` phụ thuộc nhau | **giả định độc lập** | **`CREATE STATISTICS` — Day 13** |
| Tham số trong generic plan | không biết giá trị | `plan_cache_mode` (§4) |
| Dữ liệu mới ngoài histogram | nội suy ngoài biên | partition (Day 32), nâng target |

---

## §6. Quy trình chẩn đoán — áp dụng 6 bước

Query mục tiêu:
```sql
SELECT count(*) FROM ts_kv k JOIN device d ON d.id = k.device_id
WHERE d.type='controller' AND d.region='eu-west' AND k.key_id=1 AND k.ts >= '2025-06-15';
```

### Bước 1 — lấy plan thật

```
Aggregate  (actual time=613.224..613.226 rows=1)
  Buffers: shared hit=954151 read=8489
  ->  Hash Join  (cost=... rows=1014) (actual rows=777)
        ->  Index Scan using idx_tskv_ts on ts_kv k  (rows=694198) (actual rows=681359)
              Index Cond: (ts >= '2025-06-15')
              Filter: (key_id = 1)
              Rows Removed by Filter: 1818708
              Buffers: shared hit=952944 read=8489
        ->  Seq Scan on device d  (rows=73) (actual rows=61)
              Filter: ((type='controller') AND (region='eu-west'))
              Rows Removed by Filter: 49939
Execution Time: 613.261 ms
```

### Bước 2 — quét từ lá lên, tìm node đầu tiên lệch > 10 lần

| Node | đoán | actual | lệch |
|---|---|---|---|
| `Seq Scan on device` | 73 | 61 | **1,20** ✓ |
| `Index Scan on ts_kv` | 694.198 | 681.359 | **1,02** ✓ |
| `Hash Join` | 1.014 | 777 | **1,30** ✓ |

**Không có node nào lệch quá 1,3 lần.** Ước lượng hoàn toàn lành mạnh.

### Bước 3–4 — vậy vấn đề ở đâu

Kiểm chứng sự thật từng tầng:
```
device khớp (type=controller AND region=eu-west) : 61
ts_kv khớp (key_id=1 AND ts>='2025-06-15')       : 681.359
```
Khớp với plan. Thống kê tươi (vừa `ANALYZE`).

**Đây là ca mà quy trình 6 bước dừng ở bước 2 với kết luận: "ước lượng đúng, planner không sai".** Và đó là kết luận quan trọng — nó ngăn ta đi tối ưu nhầm chỗ.

### Vấn đề thật: `Rows Removed by Filter` và buffers

```
Index Scan using idx_tskv_ts:
  Index Cond: (ts >= '2025-06-15')      <- chỉ 1 điều kiện vào Index Cond
  Filter: (key_id = 1)                   <- điều kiện thứ 2 rơi xuống Filter
  Rows Removed by Filter: 1.818.708      <- vứt 73% số dòng đọc lên
  Buffers: 952.944 + 8.489 = 961.433     <- 7,5 GB lượt truy cập
```

**Node này chiếm 561/613 ms = 92 % query.** Nó đọc 2,5 triệu dòng để lấy 681 nghìn, rồi join xuống còn 777.

### Bước 5–6 — cách sửa

Đây **không** phải bài toán thống kê, mà là bài toán **index và thứ tự join** (tuần 2):

```sql
-- Cách 1: đưa key_id vào Index Cond (Day 07)
CREATE INDEX ON ts_kv (key_id, ts);
-- equality trước, range sau -> cả 2 điều kiện vào Index Cond, Rows Removed = 0
```

```sql
-- Cách 2: đảo thứ tự join. Chỉ 61 device khớp — lẽ ra nên bắt đầu từ đó
CREATE INDEX ON device (type, region);
CREATE INDEX ON ts_kv (device_id, key_id, ts);
-- -> nested loop từ 61 device, mỗi cái tra index -> vài trăm buffer thay vì 961.433
```

Cách 2 tốt hơn nhiều: **bắt đầu từ nhánh lọc chặt nhất**. 61 device × ~13 dòng = 777 dòng, thay vì quét 2,5 triệu dòng rồi vứt 99,97 %.

Planner không chọn cách 2 vì **không có index nào cho phép** — nó không thể tra `ts_kv` theo `device_id` mà không quét. Đây là ví dụ hoàn hảo cho việc: *ước lượng đúng vẫn có thể ra plan tệ, nếu không có index đúng.*

### Quy trình rút gọn để mang về

```
① EXPLAIN (ANALYZE, BUFFERS)
② Quét TỪ LÁ LÊN: node đầu tiên lệch > 10× ?
   ├─ CÓ  -> đó là gốc bệnh, sang ③
   └─ KHÔNG -> ước lượng lành mạnh. Đi tìm Rows Removed by Filter
               và node chiếm nhiều thời gian riêng nhất. (Đây là ca ở §6)
③ Node đó quét bảng nào, lọc cột nào?
④ pg_stats của cột đó: n_distinct hợp lý? giá trị có trong MCV? last_analyze bao lâu?
⑤ Thử theo thứ tự: ANALYZE -> SET STATISTICS -> CREATE STATISTICS -> viết lại query
⑥ Cuối cùng mới tính tới đổi index / đổi GUC
```

**Bổ sung quan trọng cho bước ②:** nếu không tìm thấy node nào lệch, đừng ép — hãy chuyển sang chẩn đoán kiểu tuần 2 (index, `Index Cond` vs `Filter`, buffers).

---

## Bảng số liệu chính

| Kịch bản | rows đoán | actual | lệch | time |
|---|---|---|---|---|
| §1 join 3 bảng, mọi node | — | — | **< 1,05×** | 77,2 ms |
| §2 `device` (3 cột phụ thuộc) | **8.240** | **19.267** | **−2,34×** | — |
| §2 Hash Join | 266.174 | 637.591 | −2,40× | **661,6 ms** |
| §2 ép Nested Loop | — | — | — | **1.069,1 ms (1,6×)**, loops=1.611.191 |
| §3 `dev=1` target 100 / 2000 | 103.114 / **108.358** | 107.947 | −4,5 % / **+0,4 %** | — |
| §3 `dev=31337` target 100 / 2000 | 153 / **68** | 30 | +410 % / **+127 %** | — |
| §3 `n_distinct` target 100 / 2000 | 28.704 / **49.849** | 50.000 | −42,6 % / **−0,3 %** | — |
| **§4 custom plan** (lần 1–5) | **108.527** | 107.947 | **+0,5 %** | 282 ms |
| **§4 generic plan** (từ lần 6) | **175** | 107.947 | **−617 lần** | 304 ms |
| §5 hàm SQL inline được | 10.070 | 10.025 | +0,4 % | — |
| §6 mọi node | — | — | **< 1,3×** | 613,3 ms |
| §6 `Rows Removed by Filter` | | **1.818.708** | | 92 % thời gian ở 1 node |

---

## Ba điều dễ hiểu sai

| # | Hiểu nhầm | Sự thật đo được |
|---|---|---|
| 1 | "Prepared statement thì plan ổn định" | **Lần thứ 6 đổi plan**, ước lượng từ sai 0,5 % thành sai **617 lần** |
| 2 | "Khai `ROWS n` cho hàm là sửa được ước lượng" | Hàm SQL đơn giản bị **inline** — `ROWS` bị bỏ qua hoàn toàn. Chỉ có tác dụng với hàm PL/pgSQL |
| 3 | "Plan chậm thì chắc chắn ước lượng sai" | §6: mọi node lệch **< 1,3×**, query vẫn 613 ms. Vấn đề là **thiếu index**, không phải thống kê |

Thêm hai điều:
- **Giả định độc lập sai đúng bằng tích của các selectivity thừa.** Ở §2: nhân thừa 0,4288 → sai đúng 2,33 lần.
- **Generic plan sai 617 lần vẫn có thể vô hại** nếu không có index nào để lật plan sang loại khác. Nó chỉ nổ khi ước lượng sai đủ để đổi *loại* plan.

---

## Áp dụng vào hệ thật

**1. Kiểm tra bẫy generic plan ngay hôm nay — 3 dòng:**
```sql
SET plan_cache_mode = 'force_generic_plan';
EXPLAIN <top 5 query trong pg_stat_statements, với tham số>;
RESET plan_cache_mode;
```
Plan khác hẳn = có bom hẹn giờ.

**2. Cấu hình driver cho đúng:**

| Driver | Đặt gì |
|---|---|
| JDBC | `prepareThreshold=0` cho service có query trên cột lệch; giữ mặc định 5 cho phần còn lại |
| pgx | `QueryExecModeExec` cho query lệch; mặc định cho phần còn lại |
| Toàn cục (nếu không sửa được app) | `ALTER ROLE api_user SET plan_cache_mode = 'force_custom_plan';` |

Cái giá của `force_custom_plan`: mất ~0,03–0,3 ms planning mỗi lần. Với 1 triệu lượt/ngày là 30–300 giây CPU. **Đáng, nếu nó tránh được một plan 15 phút.**

**3. Ưu tiên `LANGUAGE sql` một câu SELECT cho mọi hàm helper.** Chuyển từ PL/pgSQL sang SQL có thể sửa ước lượng sai 1.000 lần miễn phí. Rà soát:
```sql
SELECT p.proname, l.lanname, p.prorows, p.provolatile
FROM pg_proc p JOIN pg_language l ON l.oid = p.prolang
WHERE p.pronamespace = 'public'::regnamespace AND p.proretset
ORDER BY 2, 1;
```
`lanname = 'plpgsql'` + `prorows = 1000` (mặc định) = đang bị đoán sai.

**4. Với mọi cặp cột phụ thuộc nhau, chuẩn bị `CREATE STATISTICS`** (Day 13). Trong hệ IoT/SaaS, các cặp điển hình:
- `region` ↔ `country`
- `city` ↔ `district` ↔ `province`
- `tenant_id` ↔ `region` (tenant thường ở một vùng)
- `status` ↔ `type` (một số status chỉ có ở một số type)

**5. Đưa "sai số ước lượng" vào quy trình review query chậm.** Câu hỏi chuẩn: *"node đầu tiên từ dưới lên lệch bao nhiêu lần?"* Nếu câu trả lời là "dưới 2 lần" thì đừng đụng vào thống kê — đi tìm index.

---

## Câu hỏi mở sang các ngày sau

1. `region` ↔ `country` phụ thuộc hàm làm sai 2,34 lần. `CREATE STATISTICS` sửa được đến đâu? → **Day 13**
2. Sai số làm lật plan — `random_page_cost` và `effective_cache_size` ảnh hưởng ngưỡng lật thế nào? → **Day 14**
3. Nested loop được `Memoize` cứu. Khi nào Memoize không cứu nổi? → **Day 16**
4. §6 cần index `(key_id, ts)` hoặc đảo thứ tự join. `join_collapse_limit` có liên quan gì? → **Day 20**
5. Generic plan sai 617 lần — đo tận tay ở tầng driver Java/Go thế nào? → **Day 42**
