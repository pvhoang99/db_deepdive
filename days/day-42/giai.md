# Day 42 — Lời giải: Prepared statement trong đời thật — driver, pool, và kiểu tham số

> Bài chữa. Đo thật trên lab (Postgres 17, `ts_kv` 5M dòng, `device` 50k dòng, collation `en_US.utf8`).
>
> Kết luận một câu: **tiết kiệm được 0,033 ms planning time mỗi lần nhờ generic plan — nhưng một tham số sai kiểu (`numeric` thay vì `bigint`) làm cùng câu query chậm đi 179 lần.** Hai con số này chênh nhau 5.400 lần, và nói rõ đâu là chỗ đáng lo.

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án đo được | Bẫy |
|---|---|---|---|
| 1 | `PreparedStatement` trong Java — mặc định có tạo prepared statement **trên server** không? | **Không, trong 5 lần đầu.** pgjdbc mặc định `prepareThreshold = 5`: 5 lần đầu gửi statement **vô danh**, từ lần 6 mới tạo statement có tên trên server. Lab xác nhận đúng cơ chế: `custom_plans` lên 5 rồi `generic_plans` mới bắt đầu tăng. | Bẫy: "dùng `PreparedStatement` là an toàn **và** nhanh". An toàn SQL injection thì có ngay từ lần 1; tiết kiệm planning thì không. Với query chạy < 5 lần mỗi connection (rất phổ biến khi pool lớn), bạn **không bao giờ** chạm tới generic plan. |
| 2 | 300 connection × 150 statement tốn bao nhiêu RAM, ở đâu? | Đo được **13,3 kB mỗi statement** (200 statement: backend 939 kB → 3.603 kB). ⇒ 300 × 150 × 13,3 kB ≈ **600 MB**, nằm trong **bộ nhớ riêng của từng backend**, không phải shared memory. | Bẫy: RAM này **không** hiện ra ở `shared_buffers` và không giới hạn được bằng GUC nào. Nó chỉ hiện ra ở RSS của process — và Day 36 đã cho thấy `ps` báo RSS sai vì đếm lặp shared memory. |
| 3 | Sau pgbouncer `transaction`, `PREPARE` rồi `EXECUTE` ở request sau? | **`ERROR: 26000: prepared statement "shared_q" does not exist`** — tái hiện được bằng hai session psql. | Bẫy: lỗi này **không xảy ra khi test**, chỉ xảy ra khi có tải đủ để transaction rơi vào server connection khác. Giống hệt bug `SET` mất ngẫu nhiên của Day 36 §6. |
| 4 | `device_id bigint` có index, `WHERE device_id = $1` với `$1` kiểu `numeric` — index có được dùng? | **KHÔNG.** `Filter: ((device_id)::numeric = '42'::numeric)` — Postgres ép **cột** sang numeric ⇒ Seq Scan. **642,6 ms vs 3,6 ms — 179×**, 36.958 buffer vs 3.556. | Bẫy: cùng một câu SQL, viết tay thì nhanh, qua driver thì chậm 179 lần — và `pg_stat_statements` cho thấy hai entry khác nhau nên bạn không dễ nhận ra chúng là cùng một query. |

---

## §1. Ba tầng "prepared" — bạn đang ở tầng nào

| Tầng | Là gì | Ai làm | Tiết kiệm planning? | Chống SQL injection? |
|---|---|---|---|---|
| **1. Client-side** | driver ghép tham số vào chuỗi SQL rồi gửi text | JDBC khi chưa đạt `prepareThreshold`; nhiều ORM | **không** | **có** |
| **2. Extended query protocol** | `Parse`/`Bind`/`Execute` — SQL và tham số đi riêng | pgx mặc định; JDBC sau ngưỡng | **có** | có |
| **3. `PREPARE` SQL tường minh** | bạn gõ tay | — | có | có |

**Điểm quan trọng nhất: an toàn SQL injection có từ tầng 1, nhưng tiết kiệm planning chỉ có từ tầng 2.** Rất nhiều team tin rằng dùng `PreparedStatement` là đã "prepared trên server" — thường là không.

### Generic plan chuyển ở lần thứ mấy

```sql
PREPARE d1(bigint) AS SELECT count(*) FROM ts_kv WHERE device_id = $1;
```

| Sau bao nhiêu `EXECUTE` | `custom_plans` | `generic_plans` |
|---|---|---|
| 3 | **3** | 0 |
| 5 | **5** | 0 |
| 8 | 5 | **3** |

**Đúng như tài liệu: 5 lần custom, từ lần thứ 6 chuyển generic.** Nhưng đây không phải quy tắc cứng — Postgres so **chi phí trung bình** của custom với chi phí generic, và chỉ chuyển khi generic không đắt hơn. Day 32 §3 đã gặp trường hợp ngược lại: trên bảng phân vùng, custom plan rẻ hơn nhiều nên Postgres **bám custom mãi mãi**, không bao giờ chuyển.

`generic_plans` / `custom_plans` (PG14+) là **bằng chứng**, không phải suy đoán:
```sql
SELECT name, generic_plans, custom_plans,
       round(100.0*generic_plans/nullif(generic_plans+custom_plans,0),1) AS pct_generic
FROM pg_prepared_statements ORDER BY generic_plans DESC;
```

### Cái được và cái mất

| | Planning Time | Estimate | Thực tế |
|---|---|---|---|
| SQL thường, `device_id = 42` | **0,050 ms** | rows=3.167 | 3.731 |
| SQL thường, `device_id = 43` | 0,043 ms | rows=4.333 | 3.783 |
| `EXECUTE d1(42)` — **generic** | **0,017 ms** | **rows=176** | 3.731 |
| `EXECUTE d1(43)` — generic | **0,014 ms** | **rows=176** | 3.783 |

**Được: planning time 0,050 → 0,017 ms — nhanh 2,9×, tiết kiệm 0,033 ms/lần.**

**Mất: estimate từ 3.167 (sát) xuống 176 (sai 21×).** Generic plan không biết giá trị tham số nên dùng ước lượng trung bình `n_distinct`. Ở đây plan không đổi (đều Seq Scan) nên vô hại — nhưng với dữ liệu lệch, sai 21× đủ để chọn nhầm Nested Loop và giết cả query (Day 09, Day 12).

### Con số này có đáng không?

Query chạy **2 triệu lần/ngày**: 2.000.000 × 0,033 ms = **66 giây CPU/ngày**. Trên máy 8 core (691.200 giây CPU/ngày) đó là **0,0095%**.

> **Kết luận thẳng: tiết kiệm planning time của generic plan gần như không đáng kể cho query đơn giản.** Nó chỉ thật sự quan trọng khi:
> - Query có **nhiều bảng join** — planning time có thể lên hàng chục ms (Day 32 §5 đo được 1,7 ms chỉ với 92 partition).
> - Bảng có **rất nhiều partition** — planning tỉ lệ với số partition còn lại sau prune.
> - Tải cực cao (> 50k qps) khiến 0,033 ms × qps trở thành đáng kể.
>
> Với query OLTP đơn giản, **đừng đánh đổi risk của generic plan sai estimate để lấy 0,033 ms.**

---

## §2. Plan cache tốn RAM ở đâu

Plan cache nằm trong **bộ nhớ riêng của từng backend** (process-per-connection, Day 36), **không phải** shared memory. Chi phí nhân với số connection.

Tạo 200 prepared statement (mỗi cái là một join 2 bảng + `GROUP BY`):

| | `used_bytes` | `total_bytes` |
|---|---|---|
| Trước | **939 kB** | 1.319 kB |
| Sau 200 statement | **3.603 kB** | 4.758 kB |
| **Chênh** | **+2.664 kB** | +3.439 kB |
| **Mỗi statement** | **≈ 13,3 kB** | ≈ 17,2 kB |
| Sau `DEALLOCATE ALL` | **1.175 kB** | 1.558 kB |

**13,3 kB mỗi statement cho một join 2 bảng.** Join 5 bảng với subquery có thể vài trăm kB.

### Ngoại suy

| Kịch bản | Statement/conn | Connection | RAM plan cache |
|---|---|---|---|
| Lab | 200 | 1 | 2,6 MB |
| Service Spring nhỏ | 150 | 50 | **~100 MB** |
| **Microservice, pool lớn** | **150** | **300** | **~600 MB** |
| ORM sinh nhiều query, pool rất lớn | 400 | 300 | **~1,6 GB** |

So với `shared_buffers = 256MB` của lab: **plan cache của 300 connection có thể lớn gấp 2,3 lần toàn bộ shared_buffers.** Đó là RAM lẽ ra dành cho cache dữ liệu.

> **Đây là lý do thứ ba để pool nhỏ** (sau context switch và spinlock của Day 36): pool nhỏ = ít bản sao plan cache.

### `DEALLOCATE ALL` không trả hết RAM

939 kB → 3.603 kB → **1.175 kB** (không về 939). `CacheMemoryContext` giữ lại các khối đã cấp phát để tái dùng, không trả về OS ngay. Trên production, một backend đã từng chạy nhiều query khác nhau sẽ **giữ mức RAM cao đó suốt vòng đời connection**.

Hệ quả thực tế: **`maxLifetime` trong HikariCP (Day 36) không chỉ để tránh connection chết — nó còn là cách duy nhất để reset plan cache.** Connection sống mãi mãi = plan cache phình mãi mãi.

### 🔧 Tình huống thực tế — Postgres "không làm gì" mà ăn 12 GB

`shared_buffers = 8GB`, máy 32 GB, monitoring báo Postgres dùng 20 GB. Không có query nặng nào. Team nghi memory leak.

Không phải leak. 250 connection từ 8 service, mỗi service dùng Hibernate sinh ~300 query khác nhau (do `IN (?, ?, ?)` với số phần tử khác nhau tạo ra statement khác nhau!). 250 × 300 × 15 kB ≈ **1,1 GB**, cộng với catalog cache, work_mem tạm, và các context khác → mỗi backend ~45 MB private.

Hai chỗ sửa:
1. **Giảm pool** từ 250 xuống 60 (Day 36) → RAM giảm 4×.
2. **Sửa `IN (?, ?, ?)`** thành `= ANY(?)` với mảng — một statement thay vì hàng trăm biến thể:
   ```java
   // sinh N statement khác nhau, mỗi cái một plan cache entry
   "SELECT * FROM t WHERE id IN (" + placeholders(n) + ")"
   // chỉ một statement duy nhất
   "SELECT * FROM t WHERE id = ANY(?)"     // setArray
   ```
   Cái thứ hai còn giúp `pg_stat_statements` gom thành một dòng thay vì hàng trăm dòng.

---

## §3. pgbouncer transaction mode phá cái gì

Mô phỏng bằng hai session psql (statement chỉ sống trong connection tạo ra nó):

**S1:**
```sql
PREPARE shared_q(bigint) AS SELECT count(*) FROM ts_kv WHERE device_id=$1;
EXECUTE shared_q(42);          -- 3731
SELECT name FROM pg_prepared_statements;   -- shared_q
```

**S2:**
```sql
SELECT count(*) FROM pg_prepared_statements;   -- 0
EXECUTE shared_q(42);
```
```
ERROR:  26000: prepared statement "shared_q" does not exist
LOCATION:  FetchPreparedStatement, prepare.c:448
```

**SQLSTATE `26000` (`invalid_sql_statement_name`) — đây chính xác là lỗi app của bạn sẽ nhận sau pgbouncer transaction mode.**

Và nó xuất hiện đúng theo kiểu tệ nhất: **không xảy ra khi test** (một client, luôn được cấp lại cùng server connection), chỉ xảy ra khi có đủ tải để transaction rơi vào connection khác. Giống hệt bug `SET work_mem` mất 12,5% của Day 36 §6.

### Bảng cái gì vỡ

| Thứ bị vỡ | Vì sao | Cách sống chung |
|---|---|---|
| `PREPARE`/`EXECUTE` SQL tường minh | statement nằm ở connection khác | không dùng; hoặc pgbouncer ≥ 1.21 + `max_prepared_statements > 0` |
| Prepared statement của driver | như trên → **`26000`** | JDBC `prepareThreshold=0`; pgx `QueryExecModeSimpleProtocol`; hoặc bật hỗ trợ ở pgbouncer |
| `SET` cấp session | áp lên connection ngẫu nhiên | `SET LOCAL` / `ALTER ROLE ... SET` |
| Advisory lock cấp session | **rò rỉ vĩnh viễn** (Day 36 §6b) | `pg_advisory_xact_lock` |
| `LISTEN`/`NOTIFY` | mất kênh | connection riêng, không qua pool |
| Temp table, cursor `WITH HOLD` | như trên | tránh |

### Quyết định: tắt prepare hay nâng pgbouncer?

Day 36 §6e đã đo: **pgbouncer 1.25.2 xử lý `-M prepared` bình thường, 38.725 tps, 0 lỗi.** Hỗ trợ có từ **1.21**.

| Lựa chọn | Được | Mất |
|---|---|---|
| **Tắt server-side prepare** (`prepareThreshold=0`) | đơn giản, chắc chắn không lỗi | mất **0,033 ms/query** planning (§1) — với 2M query/ngày là 66 s CPU/ngày, **không đáng kể** |
| **Nâng pgbouncer ≥ 1.21 + `max_prepared_statements=200`** | giữ được generic plan | pgbouncer phải giữ cache riêng, tốn RAM ở pgbouncer; thêm một thứ có thể sai |

**Khuyến nghị cho hệ Java + Go của bạn: nâng pgbouncer lên ≥ 1.21 và bật `max_prepared_statements` — nhưng KHÔNG phải vì planning time.** Lý do thật là: nếu tắt prepare ở app, bạn cũng mất luôn khả năng dùng extended protocol với binary format cho một số kiểu, và bạn phải nhớ cấu hình đó ở **mọi** service mới. Bật ở pgbouncer là một chỗ, áp cho tất cả.

Nếu không nâng được: `prepareThreshold=0` (Java) / `QueryExecModeSimpleProtocol` (Go), và **kiểm tra log tìm SQLSTATE 26000** để chắc chắn không còn sót chỗ nào.

---

## §4. Kiểu tham số sai làm index thành vô dụng

**Quy tắc: ép kiểu ở phía THAM SỐ thì index sống; ép ở phía CỘT thì chết.** Index B-tree gắn với một operator family; nếu Postgres phải áp một hàm/phép ép lên **cột**, giá trị trong index không còn khớp với thứ đang được so sánh.

### §4a — Kiểu số

Index `ix_tskv_dev ON ts_kv(device_id)` (`bigint`).

| Tham số | Plan | `Filter` / `Index Cond` | Buffers | **Execution** |
|---|---|---|---|---|
| `bigint` | Bitmap Index Scan | `Index Cond: (device_id = '42'::bigint)` | 3.553 | 9,21 ms (lạnh) |
| **`int`** | **Bitmap Index Scan** | `Index Cond: (device_id = 42)` | 3.556 | **3,59 ms** |
| **`numeric`** | **Seq Scan** | **`Filter: ((device_id)::numeric = '42'::numeric)`** | **36.958** | **642,55 ms** |
| `text` (ép cột) | Seq Scan | `Filter: ((device_id)::text = '42'::text)` | 36.958 | **657,20 ms** |

**`numeric` chậm hơn `int` 179 lần và đọc nhiều hơn 10,4 lần buffer.**

Nhìn vào `Filter` là thấy ngay bệnh: **`(device_id)::numeric`** — dấu ngoặc bọc quanh **cột**, không phải quanh tham số. Postgres chọn ép cột vì không có cast ngầm từ `numeric` xuống `bigint` an toàn (numeric có thể có phần thập phân), nên nó phải nâng cột lên numeric.

Ngược lại, `int` **hoạt động hoàn hảo**: có cast ngầm `int → bigint` an toàn, nên Postgres ép **tham số** lên bigint và index vẫn dùng được.

> **Đây là chỗ ORM hay sai nhất.** Java `BigDecimal` → `numeric`. Nếu entity khai báo `BigDecimal id` cho một cột `bigint`, mọi query theo id của bạn đang seq scan. Go: `int`/`int64` đều map sang `int8` nên an toàn; nhưng `float64` thì không.

Cách phát hiện trong plan: **tìm dấu ngoặc quanh tên cột trong `Filter`.** `(device_id)::numeric` = bệnh. `device_id = '42'::bigint` = khoẻ.

### §4b — Kiểu thời gian

Index `ix_tskv_ts ON ts_kv(ts)` (`timestamptz`).

| Query | Plan | Buffers | **Execution** | So với range |
|---|---|---|---|---|
| `ts >= '2025-06-01' AND ts < '2025-06-02'` | **Index Only Scan** | 21.403 | **17,80 ms** | 1× |
| `ts::date = '2025-06-01'` | **Seq Scan** — `Filter: ((ts)::date = ...)` | 36.958 | **665,72 ms** | **37×** |
| `date_trunc('day', ts) = '2025-06-01'` | Seq Scan — `Filter: (date_trunc('day', ts) = ...)` | 36.958 | **968,56 ms** | **54×** |

Cả ba trả về **cùng 55.563 dòng**. Chỉ khác cách viết.

`date_trunc` còn chậm hơn `::date` (968 vs 665 ms) vì nó là hàm đắt hơn phải gọi 5 triệu lần.

Đây chính là bẫy đã gặp ở **Day 32 §3** (giết partition pruning) — hôm nay thấy nó cũng giết index, trên cùng một cột. **Một cách viết sai, hai hậu quả.**

Chuyển đổi máy móc:
```sql
-- SAI                                    -- ĐÚNG
ts::date = D                           →  ts >= D AND ts < D + 1
date_trunc('month', ts) = M            →  ts >= M AND ts < M + interval '1 month'
EXTRACT(year FROM ts) = 2025           →  ts >= '2025-01-01' AND ts < '2026-01-01'
to_char(ts,'YYYY-MM') = '2025-06'      →  ts >= '2025-06-01' AND ts < '2025-07-01'
```

Nếu **thật sự** không viết lại được, expression index là lối thoát — nhưng nhớ bài học Day 12: `to_char(timestamptz, text)` là **STABLE, không IMMUTABLE**, nên không index được; `date_trunc('day', ts AT TIME ZONE 'UTC')` thì được.

### §4c — `LIKE` và collation

```sql
SELECT datcollate FROM pg_database WHERE datname='lab';   -- en_US.utf8
```

| Index có | Query | Plan | Buffers | **Execution** |
|---|---|---|---|---|
| B-tree thường | `name LIKE 'device-00012%'` | **Seq Scan** | 1.207 | **6,70 ms** |
| **+ `text_pattern_ops`** | cùng query | **Index Only Scan** | **6** | **0,078 ms** |
| B-tree thường | `name = 'device-0001234'` | **Index Only Scan** | 3 | 0,042 ms |

**86× nhanh hơn, 201× ít buffer hơn** chỉ nhờ thêm opclass.

Dòng thứ ba là bằng chứng quan trọng: **B-tree thường vẫn dùng được cho `=`**, chỉ chết với `LIKE 'prefix%'`.

**Vì sao collation quyết định điều này:** với collation không phải `C` (như `en_US.utf8`), thứ tự sắp xếp tuân theo quy tắc ngôn ngữ — `'Z'` có thể đứng trước `'a'`, dấu và khoảng trắng được xử lý đặc biệt. Postgres **không thể đảm bảo** rằng mọi chuỗi bắt đầu bằng `'device-00012'` nằm liền nhau trong index sắp theo `en_US.utf8`. Nên nó không dám dùng index.

`text_pattern_ops` sắp xếp theo **thứ tự byte thuần** (như collation `C`), trong đó tiền tố **chắc chắn** nằm liền nhau — thấy rõ trong plan:
```
Index Cond: ((name ~>=~ 'device-00012'::text) AND (name ~<~ 'device-00013'::text))
```
Toán tử `~>=~` / `~<~` là so sánh theo byte, không theo collation.

Ba lựa chọn:
```sql
-- 1. thêm opclass (giữ nguyên collation của cột cho ORDER BY)
CREATE INDEX ON device (name text_pattern_ops);
-- 2. cột dùng collation C (nếu không cần sắp xếp theo ngôn ngữ)
CREATE INDEX ON device (name COLLATE "C");
-- 3. database dùng collation C (chỉ khi tạo mới; nhanh nhất cho mọi so sánh chuỗi)
```

Chú ý cái giá: index `text_pattern_ops` **không** phục vụ được `ORDER BY name` (theo collation của cột). Muốn cả hai thì cần **hai index**.

---

## §5. Quy tắc cấu hình

| Tình huống | Cấu hình |
|---|---|
| Không có pooler, query lặp nhiều, join nhiều bảng | bật server-side prepare (JDBC mặc định, pgx mặc định) |
| Sau pgbouncer `transaction`, pgbouncer **< 1.21** | `prepareThreshold=0` / `QueryExecModeSimpleProtocol` |
| Sau pgbouncer **≥ 1.21** | `max_prepared_statements=200` ở pgbouncer, giữ prepare ở app |
| Dữ liệu lệch nặng, query theo tham số lệch | `ALTER ROLE x SET plan_cache_mode = 'force_custom_plan'` (Day 12) |
| Nhiều partition (> 50), prepared statement chạy hàng nghìn lần | `force_generic_plan` — Day 32 §5: hoà vốn ở ~35 lần execute |
| Nhiều connection, RAM căng | **giảm pool trước**, rồi giảm số statement khác nhau (`IN (?,?,?)` → `= ANY(?)`) |
| SQL nối chuỗi động (khác nhau mỗi lần) | **không** dùng prepare — cache chỉ phình mà không bao giờ hit |

**Và một luật ngắn cho code — đây mới là phần quan trọng của cả ngày:**

| Kiểu cột | Java | Go |
|---|---|---|
| `bigint` | `setLong` / `Long` | `int64` |
| `integer` | `setInt` / `Integer` | `int32` |
| `timestamptz` | `setObject(n, OffsetDateTime)` | `time.Time` |
| `date` | `setObject(n, LocalDate)` | `time.Time` (chỉ phần ngày) |
| `numeric` | `BigDecimal` | `pgtype.Numeric` / `decimal.Decimal` |
| `uuid` | `setObject(n, UUID)` | `uuid.UUID` |
| `text` | `setString` | `string` |

**Không bao giờ dùng `BigDecimal` cho cột `bigint`** — đó là bug 179× của §4a.

---

## Bảng số liệu chính

| Phép đo | Kết quả |
|---|---|
| Generic plan bắt đầu | **sau 5 lần custom, từ lần thứ 6** (`custom_plans=5`, rồi `generic_plans` tăng) |
| **Planning time: SQL thường vs generic** | **0,050 ms vs 0,017 ms — nhanh 2,9×** (tiết kiệm 0,033 ms/lần) |
| Với 2 triệu query/ngày | 66 giây CPU/ngày = **0,0095%** của máy 8 core |
| Estimate: custom vs generic | 3.167 / 4.333 (sát) vs **176 (sai 21×)** |
| **RAM plan cache** | 939 kB → **3.603 kB** cho 200 statement = **13,3 kB/statement** |
| Ngoại suy 300 conn × 150 statement | **~600 MB** (2,3× `shared_buffers` của lab) |
| Sau `DEALLOCATE ALL` | 1.175 kB — **không trả hết về 939 kB** |
| **`EXECUTE` ở connection khác** | **`ERROR: 26000: prepared statement "shared_q" does not exist`** |
| **Tham số `int` (đúng kiểu)** | Bitmap Index Scan, 3.556 buffer, **3,59 ms** |
| **Tham số `numeric`** | **Seq Scan**, `Filter: ((device_id)::numeric = ...)`, 36.958 buffer, **642,55 ms — 179×** |
| Ép kiểu trên cột (`device_id::text`) | Seq Scan, 36.958 buffer, **657,20 ms** |
| `ts >= x AND ts < y` | **Index Only Scan**, 21.403 buffer, **17,80 ms** |
| `ts::date = '2025-06-01'` | Seq Scan, 36.958 buffer, **665,72 ms — 37×** |
| `date_trunc('day', ts) = ...` | Seq Scan, 36.958 buffer, **968,56 ms — 54×** |
| Collation của lab | **`en_US.utf8`** |
| `LIKE 'prefix%'` + B-tree thường | **Seq Scan**, 1.207 buffer, **6,70 ms** |
| `LIKE 'prefix%'` + **`text_pattern_ops`** | **Index Only Scan**, **6 buffer**, **0,078 ms — 86×** |
| `name = '...'` + B-tree thường | Index Only Scan, 3 buffer, 0,042 ms — **`=` vẫn dùng được index** |

---

## Ba điều dễ hiểu sai

| Hiểu nhầm | Sự thật đo được |
|---|---|
| "Dùng `PreparedStatement` là đã prepared trên server, tiết kiệm planning." | pgjdbc mặc định `prepareThreshold=5` — **5 lần đầu không tạo statement trên server**. Với pool lớn, mỗi connection có thể không bao giờ chạy cùng query 5 lần. Và kể cả khi có: tiết kiệm chỉ **0,033 ms/lần** = 0,0095% CPU với 2M query/ngày. **An toàn SQL injection có từ lần 1; tiết kiệm planning thì gần như không có.** |
| "Kiểu tham số chỉ ảnh hưởng chuyện ép kiểu, không ảnh hưởng hiệu năng." | `numeric` thay vì `bigint` cho cùng câu query: **642,55 ms vs 3,59 ms — 179×**, 36.958 buffer vs 3.556. Vì Postgres phải ép **cột** (`(device_id)::numeric`) chứ không ép tham số ⇒ index vô dụng. `int` thì **không sao** (có cast ngầm an toàn). Một dòng khai báo `BigDecimal` trong entity đủ để giết mọi query theo id. |
| "Có index trên `name` là `LIKE 'abc%'` sẽ nhanh." | Với collation `en_US.utf8`: **Seq Scan, 6,70 ms**. Thêm `text_pattern_ops`: **0,078 ms — 86×**. Vì thứ tự theo ngôn ngữ không đảm bảo tiền tố nằm liền nhau trong index. Cùng index đó **vẫn dùng được cho `=`** (0,042 ms) — nên bạn thấy "index đang hoạt động" và không nghi ngờ gì. |

---

## Áp dụng vào hệ thật

1. **Trả lời ba câu này và kiểm tra chúng khớp nhau** — nếu không khớp thì hoặc đang mất planning time, hoặc đang có `26000` ẩn trong log:
   - `prepareThreshold` của service Java đang là bao nhiêu?
   - Có pgbouncer không, chế độ gì?
   - Phiên bản pgbouncer là gì (`SHOW VERSION;` ở database `pgbouncer`)?

2. **Grep log tìm SQLSTATE `26000`** ngay hôm nay. Nó xuất hiện lẻ tẻ dưới tải và thường bị retry che mất — nhưng mỗi lần là một request chậm hơn hoặc lỗi.

3. **Rà kiểu tham số của 3 query nặng nhất** — đây là việc có ROI cao nhất trong ngày:
   ```sql
   SELECT calls, round(mean_exec_time::numeric,2) AS tb_ms, substring(query,1,90)
   FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10;
   ```
   Với mỗi cái, chạy `EXPLAIN` và **tìm dấu ngoặc quanh tên cột trong `Filter`**: `(cot)::kieu` = bệnh 179×. Đối chiếu với khai báo kiểu trong entity/struct.

4. **Grep code tìm cách viết giết index trên cột thời gian:**
   ```bash
   grep -rn "::date\|date_trunc\|EXTRACT(\|to_char(" --include=*.java --include=*.go --include=*.sql . \
     | grep -iE "where|and |or "
   ```
   Mỗi chỗ là 37–54×, và trên bảng phân vùng còn giết luôn pruning (Day 32 §3).

5. **Với mọi `LIKE 'prefix%'`, kiểm tra opclass:**
   ```sql
   SELECT datcollate FROM pg_database WHERE datname = current_database();
   -- khác 'C' ⇒ mọi index phục vụ LIKE prefix phải có text_pattern_ops
   CREATE INDEX CONCURRENTLY ix_name_pat ON t (name text_pattern_ops);
   ```

6. **Đổi `IN (?, ?, ?)` thành `= ANY(?)`** với mảng. Một statement thay vì hàng trăm biến thể ⇒ plan cache nhỏ hơn nhiều, và `pg_stat_statements` gom thành một dòng thay vì hàng trăm dòng rác.

7. **Đặt `maxLifetime` (30 phút)** — nó là cách duy nhất reset plan cache của một backend. Connection sống mãi = plan cache phình mãi.

8. **Nếu nâng pgbouncer ≥ 1.21: bật `max_prepared_statements=200`** và giữ prepare ở app. Không phải vì 0,033 ms, mà vì cấu hình ở một chỗ áp cho mọi service, thay vì phải nhớ đặt `prepareThreshold=0` ở mỗi service mới.

---

## Câu hỏi mở sang các ngày sau

- **Day 43 (DDL locks)** là ngày tiếp theo của tuần 9 và nối trực tiếp: `CREATE INDEX ... text_pattern_ops` ở §4c cần lock gì, và làm sao thêm nó trên bảng 200 GB đang chạy mà không khoá?
- **Day 44 (expand/contract)** cho quy trình sửa lỗi kiểu ở §4a mà không downtime: đổi cột `numeric` thành `bigint` (hoặc sửa entity) trên hệ đang chạy.
- **Day 12 §4** khép lại từ hôm nay: `plan_cache_mode` đặt theo role hay theo statement, và bảng quyết định giờ có ba nguồn số liệu — Day 12 (cơ chế), Day 32 §5 (điểm hoà vốn ~35 execute với 92 partition), Day 42 (0,033 ms/lần cho query đơn giản).
- **Day 36 §6** nhìn lại: `26000` của hôm nay và `SET` mất 12,5% của Day 36 là **cùng một bug với hai biểu hiện** — trạng thái sống lâu hơn một transaction sau pgbouncer transaction mode. Còn thứ gì khác trong code của bạn thuộc nhóm này?
- **Câu hỏi mở thật sự:** generic plan tiết kiệm 0,033 ms nhưng cho estimate sai 21×. Có cách nào lấy cả hai — planning nhanh **và** estimate đúng? PG12+ có cơ chế "generic plan với partial pruning"; và `plan_cache_mode` đặt được per-statement. Ranh giới nào để quyết định?

---

### Dọn dẹp

```sql
DEALLOCATE ALL;
DROP INDEX IF EXISTS ix_tskv_dev, ix_tskv_ts, ix_dev_name, ix_dev_name_pat;
```
