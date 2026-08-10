# Day 01 — Lời giải: Postgres làm gì với câu SQL của bạn

> Bài chữa. Số liệu đo thật trên lab `SCALE=1` (Postgres 17, `shared_buffers=256MB`, `work_mem=4MB`, `jit=off`), ngay sau `make seed` khi chưa bảng nào được ANALYZE.
> Seed dùng hàm băm tất định nên anh chạy lại sẽ ra **cùng các con số row**; chỉ `ms` là dao động theo máy.

---

## §0. Đáp án cho phần đoán

| # | Câu hỏi | Đáp án đo được | Chỗ hầu hết mọi người đoán sai |
|---|---|---|---|
| 1 | Planner ước lượng `device_id = 42` ra bao nhiêu? Thực tế? | đoán **17.185** / thật **3.731** | Đa số đoán planner ra ~0 hoặc ra đúng. Thực ra nó ra một số **có vẻ hợp lý** — đó mới là cái nguy hiểm |
| 2 | `pg_class.reltuples` lúc này? | **-1** (và `relpages` = **0**) | Đa số đoán 5.000.000 hoặc 0 |
| 3 | `count(*) FROM ts_kv` mất bao nhiêu ms? | **567 ms** (tắt song song), **~190 ms** (bật song song) | Đa số đoán "nhanh, có gì đâu" — quên rằng `count(*)` trong Postgres **luôn phải đọc hết bảng** |

Điểm số 3 đáng dừng lại: Postgres **không** giữ sẵn số dòng của bảng ở đâu cả (khác MySQL/MyISAM). MVCC bắt buộc mỗi transaction phải tự kiểm tra từng tuple có "nhìn thấy được" với snapshot của mình không. `count(*)` = đọc 289 MB. Đây là lý do dashboard nào cũng có ô "Tổng số bản ghi" và ô đó luôn là ô chậm nhất trang.

---

## §1. Bốn giai đoạn — Planning vs Execution

### Số đo

| Query | Planning | Execution | Cái nào lớn hơn |
|---|---|---|---|
| `count(*) FROM ts_kv WHERE device_id = 42` | 0.203 ms | 171.4 ms | Execution (planning = 0,1 %) |
| `SELECT * FROM tenant WHERE id = 1` | 0.240 ms | 0.212 ms | **Planning** (53 % tổng thời gian) |

### Điều cần rút ra

**Thời gian planning gần như không phụ thuộc lượng dữ liệu.** 0.20 ms cho bảng 5 triệu dòng, 0.24 ms cho bảng 3 dòng — gần y hệt. Cái quyết định planning time là **độ phức tạp câu SQL** (số bảng join, số index ứng viên, số predicate), không phải số dòng.

Hệ quả trực tiếp: planning chỉ thành gánh nặng ở **query siêu nhẹ chạy siêu nhiều** — tức đúng 90 % traffic của một service CRUD.

```
0.24 ms × 1.000.000 lượt/ngày = 240 giây CPU/ngày
                                 chi cho việc không sinh ra một dòng dữ liệu nào
```

### 🔧 Tình huống thực tế

**Bối cảnh.** Service Go dùng `pgx`, endpoint `GET /devices/{id}` chạy `SELECT * FROM device WHERE id = $1`, 3.000 rps. p99 đang 8 ms, sếp muốn xuống 5 ms.

**Chẩn đoán sai thường gặp:** "thêm index đi" — đã có PK rồi, index không giúp gì.

**Chẩn đoán đúng:** query này execution ~0.2 ms, phần còn lại là network + planning + pool. `pgx` mặc định đã bật statement cache (prepared statement), nhưng nếu anh đi qua **PgBouncer transaction mode bản < 1.21** thì prepared statement **không sống qua transaction** → mỗi request đều parse+plan lại. Đó là nơi mất ms.

**Cách kiểm chứng ở production, không cần đoán:**

```sql
-- pg_stat_statements tách bạch plan time và exec time (PG13+)
SELECT query, calls,
       total_plan_time, total_exec_time,
       total_plan_time / NULLIF(total_plan_time + total_exec_time, 0) * 100 AS pct_plan
FROM pg_stat_statements
WHERE calls > 10000
ORDER BY total_plan_time DESC
LIMIT 10;
```

Cột `pct_plan` > 30 % ở một query nóng = anh đang trả tiền cho việc suy nghĩ lặp lại. Cách sửa: bật `max_prepared_statements` trên PgBouncer ≥ 1.21, hoặc chuyển sang session mode, hoặc gộp nhiều lượt lookup thành một `WHERE id = ANY($1)`.

### ⚠️ Cái bẫy đi kèm: generic plan

Prepared statement tiết kiệm planning bằng cách **nhớ sẵn một plan** — nhưng plan đúng lại phụ thuộc vào giá trị tham số:

| `?` truyền vào | Số dòng khớp | Cách đúng |
|---|---|---|
| `device_id = 1` | ~110.000 (đo được ở §4: freq 2,2 %) | Seq scan / bitmap |
| `device_id = 42` | 3.731 | Index scan |
| một device đuôi dài | vài dòng | Index scan |

Postgres thoả hiệp: **5 lần đầu dùng custom plan** (nhìn giá trị thật), từ lần 6 nếu thấy cost generic không tệ hơn thì chuyển sang **generic plan**.

→ Triệu chứng ngoài đời: *"query nhanh vài lần đầu rồi tự nhiên chậm hẳn, restart pod lại nhanh"*. Đây không phải bug ma, là cơ chế này. Day 42 sẽ đo tận tay.

Ép tắt: `SET plan_cache_mode = force_custom_plan;`

---

## §2. Planner biết gì về bảng của bạn

### Số đo (trạng thái chưa ANALYZE)

```
 relname | relpages | reltuples | size_that | pages_that
---------+----------+-----------+-----------+------------
 device  |        0 |        -1 | 9656 kB   |       1207
 ts_kv   |        0 |        -1 | 289 MB    |      36958
 alarm   |        0 |        -1 | 29 MB     |       3705
```

```
 relname | last_analyze | last_autoanalyze | n_live_tup
---------+--------------+------------------+------------
 ts_kv   |    (NULL)    |      (NULL)      |    5000000
```

### Trả lời từng câu

**`reltuples` = -1 nghĩa là gì?**

Từ PG14, `-1` là mã "**chưa từng được đo**", phân biệt hẳn với `0` = "đã đo rồi, bảng thật sự rỗng". Trước PG14 cả hai đều là `0` và planner không tài nào phân biệt được — đó là một lớp bug ước lượng cả thập kỷ.

**`relpages` = 0 nhưng file thật 36.958 page — vì sao một cái đúng, cái kia không?**

| | Nguồn | Cũ được không |
|---|---|---|
| `pg_class.relpages` | catalog, chỉ đổi khi ANALYZE/VACUUM | **Có** — đang là 0 |
| `pg_relation_size()/8192` | hỏi hệ điều hành ngay lúc gọi | Không, luôn đúng |

Chi tiết tinh tế và **quan trọng**: lúc lập kế hoạch, planner **không tin `relpages` trong catalog**. Nó gọi `RelationGetNumberOfBlocks()` hỏi số block thật của file, rồi dùng **tỷ lệ `reltuples/relpages` cũ** để nội suy ra số dòng hiện tại.

→ Rút ra: **kích thước bảng planner luôn nắm đúng. Cái nó mù là mật độ dòng và nội dung bên trong.** Ta sẽ chứng minh bằng số ở §3.

**`last_analyze` / `last_autoanalyze` cả hai NULL:** thống kê chưa từng tồn tại → planner đang bay mù hoàn toàn. Đây là câu SQL **đầu tiên** nên gõ khi gặp query chậm bí ẩn trên production.

**`n_live_tup` = 5.000.000 nhưng `reltuples` = -1?** Hai bộ đếm khác nhau: `n_live_tup` trong `pg_stat_user_tables` được **stats collector cộng dồn theo từng INSERT/UPDATE/DELETE**, còn `reltuples` chỉ do ANALYZE/VACUUM ghi. Planner **chỉ dùng `reltuples`**, không dùng `n_live_tup`. Nên cảnh giác: monitoring của anh nhìn `n_live_tup` thấy đúng, mà planner vẫn đang sai.

### Hằng số cắm cứng khi không có thống kê cột

Trong `src/include/utils/selfuncs.h`:

| Điều kiện | Selectivity | Tên hằng |
|---|---|---|
| `col = ?` | **0,5 %** | `DEFAULT_EQ_SEL` |
| `col > ?` / `col < ?` | 33 % | `DEFAULT_INEQ_SEL` |
| `col BETWEEN a AND b` | 0,5 % | `DEFAULT_RANGE_INEQ_SEL` |
| n_distinct khi mù | 200 | — |

Không liên quan gì tới dữ liệu của anh. Bảng nào, cột nào, giá trị nào cũng y hệt.

### 🔧 Tình huống thực tế

**Bối cảnh.** Job ETL đêm: `TRUNCATE staging; COPY staging FROM ...` (20 triệu dòng); rồi ngay sau đó chạy `INSERT INTO fact SELECT ... FROM staging JOIN dim ...`. Job chạy 40 phút, thỉnh thoảng nhảy lên 6 tiếng, không ai đổi code.

**Nguyên nhân.** `TRUNCATE` reset `reltuples` về 0. `COPY` không cập nhật thống kê. Autovacuum cần ~10 % thay đổi **và** phải đợi hết `autovacuum_naptime` (60 s) — mà job chạy tiếp ngay lập tức. Planner nhìn `staging` tưởng rỗng → chọn **nested loop** với staging làm outer → 20 triệu lần index lookup.

**Cách sửa (một dòng):**

```sql
TRUNCATE staging;
COPY staging FROM '/data/x.csv';
ANALYZE staging;              -- <<< dòng này
INSERT INTO fact SELECT ...;
```

**Quy tắc mang về:** *mọi pipeline nạp dữ liệu số lượng lớn rồi query ngay trong cùng job đều phải có `ANALYZE` ở giữa.* Không có ngoại lệ. Chi phí: `ANALYZE ts_kv` trên 5 triệu dòng đo được **182 ms** — rẻ hơn nhiều so với một plan sai.

Cũng lưu ý: `ANALYZE` chỉ lấy mẫu (mặc định 300 × `default_statistics_target` = 30.000 dòng), nên nó **không** scale tuyến tính theo kích thước bảng. Bảng 500 triệu dòng cũng ANALYZE trong vài giây.

---

## §3. Ước lượng khi chưa có thống kê — phép tính ngược

### Bài học phụ: cái bẫy `loops` (chạy lần đầu quên tắt song song)

```
Finalize Aggregate  (cost=55877.65..55877.66 rows=1) (actual time=168.047..171.376 rows=1 loops=1)
  ->  Gather  (cost=55877.43..55877.64 rows=2) (actual time=167.947..171.371 rows=3 loops=1)
        Workers Planned: 2   Workers Launched: 2
        ->  Partial Aggregate  (actual time=165.536..165.536 rows=1 loops=3)
              ->  Parallel Seq Scan on ts_kv  (cost=0.00..54859.53 rows=7160) (actual rows=1244 loops=3)
                    Filter: (device_id = 42)
                    Rows Removed by Filter: 1665423
```

**Đọc sai ở đây là đọc sai cả 48 ngày còn lại.** Dưới node `Gather`, mọi `rows` — cả đoán lẫn thật — là **trung bình MỖI worker**, không phải tổng:

| | mỗi worker | × loops | tổng |
|---|---|---|---|
| planner đoán | 7.160 | × 2,7 | ~19.300 |
| thực tế | 1.244 | × 3 | **3.732** ✓ (khớp 3.731) |

> **Luật cho cả chương trình: thấy `loops=N` với N>1 thì mọi `rows` và `actual time` trên node đó phải nhân với N.**

Ba chi tiết đáng nhớ ở plan này:

- `Gather rows=2` (đoán) nhưng `actual rows=3` — vì **process leader cũng nhảy vào quét cùng**, không ngồi chờ. 2 worker + 1 leader = 3.
- Nhưng lúc *tính cost*, leader chỉ được tính đóng góp **0,7** → hệ số chia là **2,7 chứ không phải 3**. Khó chịu nhưng phải nhớ: **actual chia 3, cost chia 2,7.**
- `Gather.cost − Partial Aggregate.cost = 55877.43 − 54877.43 = đúng 1000.0` = `parallel_setup_cost`. Phí dựng worker là **hằng số 1000** — đây chính là lý do Postgres không thèm song song hoá query nhỏ.

Giá của song song, đo được:

| | Execution Time |
|---|---|
| có song song (3 tiến trình) | 171 ms |
| tắt song song | **567 ms** cho full scan / **319 ms** cho query lọc |

Nhanh ~1,9 lần với 3 tiến trình, không phải 3 lần. **Song song không miễn phí.**

### Kết quả chính (đã tắt song song)

```
Aggregate  (cost=79964.64..79964.65 rows=1) (actual time=318.982..318.983 rows=1 loops=1)
  Buffers: shared hit=28058 read=8900 written=2
  ->  Seq Scan on ts_kv  (cost=0.00..79921.68 rows=17185) (actual rows=3731 loops=1)
        Filter: (device_id = 42)
        Rows Removed by Filter: 4996269
```

**Xác nhận quét toàn bảng:** 3.731 khớp + 4.996.269 bị loại = **5.000.000 chẵn tuyệt đối**. Filter vứt đi **99,925 %** số dòng vừa đọc lên — hình dạng của một query đang gào đòi index.

### Bóc tách sai số ra hai tầng

```
rows ước lượng = reltuples (tầng 1: pg_class)  ×  selectivity (tầng 2: pg_statistic)
17.185         = 3.437.000                     ×  0,005
```

Tính ngược: `17.185 ÷ 0,005 = 3.437.000` → **planner đang nghĩ bảng chỉ có 3,44 triệu dòng**, trong khi thật là 5 triệu.

| Tầng | Planner tin | Sự thật | Sai |
|---|---|---|---|
| ① số dòng bảng | 3.437.000 | 5.000.000 | **thiếu 31,3 %** |
| ② selectivity | 0,5 % (hằng số) | 3.731/5tr = **0,0746 %** | **thừa 6,7 lần** |
| **kết quả cuối** | 17.185 | 3.731 | thừa 4,6 lần |

Kiểm chứng phép nhân: `6,7 × 0,687 = 4,60` ✓ khớp đúng tỷ lệ quan sát được.

### 💡 Điểm đắt giá nhất hôm nay

**Hai tầng sai ngược chiều nhau nên triệt tiêu bớt cho nhau.** Tầng 2 sai tận 6,7 lần, nhưng tầng 1 sai thiếu 31 % kéo lại, nên sai số cuối chỉ còn 4,6 lần.

Nghịch lý: **nếu tầng 1 mà đúng 5 triệu thì sai số cuối sẽ TỆ HƠN** (6,7 lần thay vì 4,6).

→ Đừng bao giờ nhìn sai số ở node gốc rồi kết luận. **Phải bóc từng tầng ra** — sai số có thể đang che nhau, và một "cải thiện" ở một tầng có thể làm kết quả cuối xấu đi.

### Vì sao tầng 1 sai 31 %

Tự suy ngược `relpages` từ cost (công thức ở §6):

```
cost = relpages × 1.0 + reltuples × (cpu_tuple_cost 0.01 + cpu_operator_cost 0.0025)
79.921,68 = relpages + 3.437.000 × 0,0125
79.921,68 = relpages + 42.962,5
relpages  ≈ 36.959          ← khớp pages_that = 36.958 thật ✓
```

| | dòng/page |
|---|---|
| planner tin | 3.437.000 ÷ 36.958 = **93** |
| thật | 5.000.000 ÷ 36.958 = **135** |

Planner biết **chắc chắn** số page (đọc kích thước file — luôn đúng), nhưng phải **đoán mỗi page nhét được bao nhiêu dòng** từ kiểu dữ liệu các cột. Nó đoán dòng *béo hơn* thực tế → ra ít dòng hơn 31 %.

Đây là bằng chứng bằng số cho câu ở §2: *planner nắm đúng kích thước, mù về nội dung.*

---

## §4. Cho planner biết sự thật

### Trước / sau `ANALYZE ts_kv` (182 ms)

| | trước | sau |
|---|---|---|
| `reltuples` | **-1** | **5.000.033** (lấy mẫu, lệch 33 dòng = 0,0007 %) |
| `relpages` | **0** | **36.958** |
| `rows` ước lượng ở Seq Scan | **17.185** | **3.500** |
| `actual rows` | 3.731 | 3.731 |
| **sai số** | **+361 %** | **−6,2 %** |

Sai số từ 4,6 lần xuống còn **6 %**. Một lệnh 182 ms.

### Vì sao lần này chính xác đến thế

```
 n_distinct | correlation  |    mcv_5    |                 freq_5                  | so_mcv
------------+--------------+-------------+-----------------------------------------+--------
      28795 | 0.0012320464 | {1,2,3,4,5} | {0.0222, 0.0092, 0.0065, 0.0042, 0.0036}|    100
```

Truy tận nơi giá trị 42:

```
 freq_cua_42 | rows_planner_suy_ra
-------------+---------------------
      0.0007 |                3500
```

**42 nằm trong danh sách 100 giá trị phổ biến nhất (MCV)** với tần suất 0,0007. Planner không phải đoán gì cả — nó tra bảng: `0,0007 × 5.000.033 = 3.500`. Thực tế 3.731. Sai 6 %, và 6 % đó chỉ là sai số lấy mẫu của ANALYZE.

Còn 6 % thừa lại chính là bài của Day 11.

### ⚠️ Cái bẫy nằm ngay đây

`n_distinct = 28.795` nhưng MCV chỉ giữ **100** giá trị. Nghĩa là:

- 100 device nóng nhất → planner tra bảng, **rất chính xác**
- 28.695 device còn lại → planner dùng công thức đồng đều cho phần "đuôi", **kém chính xác**

Phân bố `device_id` trong seed là power-law (cố ý). Device #1 chiếm 2,2 % (~110.000 dòng), device #42 chiếm 0,07 % (3.731 dòng), device đuôi dài có vài dòng. **Cùng một câu SQL `WHERE device_id = $1`, chất lượng ước lượng khác nhau 3 bậc độ lớn tuỳ giá trị.**

Đây chính là gốc rễ của bài generic plan ở §1, và là lý do tồn tại cả tuần 3.

### 🔧 Tình huống thực tế

**Bối cảnh.** Hệ IoT multi-tenant. `WHERE tenant_id = $1` — 5 tenant lớn chiếm 95 % dữ liệu, 3.000 tenant nhỏ chia nhau 5 %.

**Triệu chứng.** API cùng một endpoint: tenant nhỏ trả về trong 20 ms, tenant lớn thỉnh thoảng 40 giây.

**Chẩn đoán.** Tenant lớn nằm trong MCV → planner biết nó có 10 triệu dòng → chọn hash join, đúng. Tenant nhỏ không nằm trong MCV → planner ước lượng theo đuôi → chọn nested loop, cũng đúng. **Vấn đề là prepared statement**: sau 5 lần chạy, plan bị đóng băng theo tenant nào tình cờ chạy trước.

**Hai cách sửa, chọn theo tình huống:**

```sql
-- Cách 1: cho planner nhìn kỹ hơn phần đuôi (giữ được prepared statement)
ALTER TABLE ts_kv ALTER COLUMN tenant_id SET STATISTICS 1000;  -- MCV 100 -> 1000
ANALYZE ts_kv;
```

```
-- Cách 2: ép custom plan cho đúng những câu bị lệch (mất lợi ích plan cache)
SET plan_cache_mode = force_custom_plan;
```

Cách 1 rẻ hơn nhiều và nên thử trước — cái giá là ANALYZE lâu hơn và planning time nhích lên. Đo cả hai, đừng đoán.

---

## §5. `EXPLAIN` vs `EXPLAIN ANALYZE`

### Số đo

```sql
BEGIN;
EXPLAIN ANALYZE DELETE FROM alarm WHERE id < 1000;
SELECT count(*) FROM alarm WHERE id < 1000;   -- >>> 0
ROLLBACK;
SELECT count(*) FROM alarm WHERE id < 1000;   -- >>> 999
```

| Thời điểm | Còn lại |
|---|---|
| sau `EXPLAIN ANALYZE DELETE` (trong transaction) | **0** |
| sau `ROLLBACK` | **999** |

**`EXPLAIN ANALYZE` thực sự chạy câu lệnh.** Với `DELETE`/`UPDATE`/`INSERT` nó xoá/sửa/thêm thật. Không có chế độ "chạy thử".

Chi tiết đáng để ý trong plan: `Bitmap Index Scan rows=53105` (đoán) vs `actual rows=999`. Sai 53 lần — vì `alarm` cũng chưa được ANALYZE. Cùng bệnh §3.

### Quy tắc cho production

1. **`EXPLAIN` trần thì luôn an toàn** — không chạy gì. Dùng thoải mái.
2. **`EXPLAIN ANALYZE` với DML thì bọc transaction bắt buộc:**
   ```sql
   BEGIN; EXPLAIN (ANALYZE, BUFFERS) UPDATE ...; ROLLBACK;
   ```
   Gõ `ROLLBACK` **trước**, rồi mới điền câu lệnh vào giữa — thói quen này cứu anh khi mất tập trung.
3. Ngay cả `SELECT`, `EXPLAIN ANALYZE` vẫn tốn tài nguyên thật. Một `EXPLAIN ANALYZE` trên query 40 giây vẫn ngốn 40 giây I/O của production.
4. Trên bản ghi (primary) đang tải cao, ưu tiên `EXPLAIN (GENERIC_PLAN)` (PG16+) để xem plan của câu có tham số mà không cần chạy:
   ```sql
   EXPLAIN (GENERIC_PLAN) SELECT * FROM ts_kv WHERE device_id = $1;
   ```
5. Bọc `ROLLBACK` **không** cứu được: sequence đã nhảy, WAL đã ghi, lock đã giữ suốt transaction, trigger có side-effect ra ngoài (gọi HTTP, `dblink`) đã bắn.

### 🔧 Tình huống thực tế

Sự cố kinh điển nhất trong nghề: kỹ sư paste `EXPLAIN ANALYZE DELETE FROM orders WHERE created_at < '2023-01-01'` vào psql production để "xem plan thôi mà". Không có `BEGIN`. Autocommit. 4 triệu đơn hàng bay.

Cách phòng ở tầng công cụ, đáng làm ngay hôm nay:

```sql
-- trong ~/.psqlrc, cho connection tới production
\set PROMPT1 '%[%033[1;31m%]PROD%[%033[0m%] %/%R%# '
\set AUTOCOMMIT off
\set ON_ERROR_ROLLBACK interactive
```

`AUTOCOMMIT off` biến mọi câu thành transaction ngầm — không gõ `COMMIT` thì không có gì xảy ra. Prompt đỏ để mắt kịp phanh tay.

---

## §6. `cost` không phải mili-giây

### Bảng số đo

| Query | startup cost | total cost | actual time (ms) | ms ÷ total cost |
|---|---|---|---|---|
| `count(*) FROM ts_kv` | 99458.41 | 99458.42 | 566,8 | **0,0057** |
| `count(*) FROM alarm` | 5696.44 | 5696.45 | 31,3 | **0,0055** |
| `ts_kv ORDER BY dbl_v LIMIT 10` | 195007.25 | 195007.27 | 670,2 | **0,0034** |
| `ts_kv ORDER BY dbl_v` (bỏ LIMIT) | 882559.66 | 895059.74 | 2489,8 | **0,0028** |

### Cost tự tính vs cost planner in

```sql
SELECT relpages, reltuples, relpages*1.0 + reltuples*0.01 FROM pg_class WHERE relname='ts_kv';
-- 36958 | 5.000033e+06 | 86958.33
```

Cost planner in cho `Seq Scan on ts_kv` (không filter): **86958.33**. Khớp **chính xác đến từng chữ số** — 0 % lệch.

```
cost = relpages × seq_page_cost + reltuples × cpu_tuple_cost
     = 36.958 × 1.0 + 5.000.033 × 0.01
     = 36.958 + 50.000,33
     = 86.958,33 ✓
```

Còn khi **có** `Filter: (device_id = 42)` thì cost là 99458.41, chênh thêm 12.500 — chính là `5.000.033 × 0,0025` (`cpu_operator_cost` cho một phép so sánh trên mỗi dòng). Công thức đầy đủ:

```
cost = relpages×seq_page_cost + reltuples×cpu_tuple_cost + reltuples×cpu_operator_cost×(số phép toán)
```

### Tỷ lệ ms÷cost KHÔNG phải hằng số — hai lý do

Đo được dao động **0,0028 → 0,0057**, chênh **2 lần**. Lý do:

1. **Cost giả định tỷ lệ cache-hit cố định, thực tế thì không.** `seq_page_cost=1.0` mô tả một lần đọc page từ đĩa. Nhưng thực tế `count(*) FROM alarm` đọc `shared hit=3705, read=0` — nằm trọn trong RAM, page cost thật gần 0. Còn `ts_kv` thì `hit=28131 read=8827` — phải chạm đĩa. Cùng cost, khác thời gian thật.

2. **Cost model không mô hình hoá được I/O ghi tạm.** Query `ORDER BY` không LIMIT có `temp read=50249 written=50338` — 400 MB ghi ra đĩa tạm. Cost có tính spill, nhưng bằng một hằng số thô, không phản ánh được tốc độ đĩa thật của máy anh.

Lý do thứ ba nếu muốn thêm: cost bỏ qua hoàn toàn **CPU cache locality, TLB miss, chi phí hàm so sánh theo kiểu dữ liệu** (so `text` với collation ICU đắt gấp nhiều lần so `int`).

> **Kết luận thực dụng: cost chỉ dùng để so sánh các plan CỦA CÙNG MỘT QUERY TRÊN CÙNG MỘT MÁY. So cost giữa hai query khác nhau là vô nghĩa.**

### Cặp có/không `LIMIT 10` — chỗ hay nhất §6

| | có LIMIT 10 | không LIMIT |
|---|---|---|
| `Sort Method` | **top-N heapsort  Memory: 26kB** | **external merge  Disk: 201.016 kB** |
| startup cost | 195.007,25 | 882.559,66 |
| total cost | 195.007,27 | 895.059,74 |
| actual time | 670 ms | **2.490 ms** |
| temp read/written | 0 | **50.249 / 50.338 page** |

Thêm `LIMIT 10` không chỉ "cắt bớt kết quả". Nó làm executor **đổi hẳn thuật toán**: từ *sắp xếp toàn bộ 5 triệu dòng, tràn 200 MB ra đĩa* thành *giữ một heap 10 phần tử, 26 KB trong RAM*.

Nhanh hơn **3,7 lần** và **không đụng đĩa tạm**. Đây là ví dụ hoàn hảo cho luật "con số, không tính từ": nếu chỉ báo "LIMIT nhanh hơn" thì mất hẳn cái hay — cái hay là **`Sort Method` đổi tên**.

Ghi chú về startup vs total: node `Sort` có `startup ≈ total` vì nó là **node chặn** — phải đọc hết đầu vào mới trả được dòng đầu tiên. Còn `Seq Scan` có `startup=0.00` — **streaming**, trả dòng đầu ngay. Đây là lý do `LIMIT` cứu được Seq Scan nhưng không cứu được Sort (trừ khi Sort đổi sang top-N).

### 🔧 Tình huống thực tế

**Bối cảnh.** Endpoint danh sách `GET /alarms?page=1&size=20` dùng `ORDER BY created_at DESC LIMIT 20 OFFSET ?`. Trang 1 nhanh, trang 5.000 chậm 8 giây.

**Chẩn đoán.** `OFFSET 100000` vẫn phải **sinh và vứt bỏ** 100.000 dòng. `LIMIT` không cứu được vì Sort là node chặn, và top-N heapsort với N = offset+limit = 100.020 thì cũng chẳng còn nhỏ.

**Sửa: keyset pagination (seek method)** — thay offset bằng con trỏ:

```sql
-- thay vì
SELECT * FROM alarm ORDER BY created_at DESC, id DESC LIMIT 20 OFFSET 100000;

-- dùng
SELECT * FROM alarm
WHERE (created_at, id) < ($1, $2)      -- giá trị cuối của trang trước
ORDER BY created_at DESC, id DESC
LIMIT 20;
-- + index (created_at DESC, id DESC) -> xoá hẳn node Sort, đọc đúng 20 dòng
```

Thời gian trở thành **hằng số theo số trang**. Cái giá: mất khả năng nhảy thẳng tới trang N — hầu như mọi UI đều chấp nhận được (infinite scroll vốn đã là keyset).

---

## §7. Hai con số row — điều quan trọng nhất hôm nay

Plan chạy **trước** khi `ANALYZE` toàn DB, nên `device` vẫn còn thống kê cũ — đúng tình huống muốn quan sát.

| # | Node (từ lá lên gốc) | rows đoán | actual rows | loops | lệch |
|---|---|---|---|---|---|
| 1 | `Seq Scan on device` | 37.417 | 50.000 | 1 | −25 % |
| 2 | `Hash` (build side) | 37.417 | 50.000 | 1 | −25 % |
| 3 | **`Seq Scan on ts_kv`** (filter theo ngày) | **49.886** | **55.563** | 1 | **+11 %** |
| 4 | `Hash Join` | 49.886 | 55.563 | 1 | +11 % |
| 5 | **`HashAggregate`** | **200** | **25.599** | 1 | **−128 lần** ⚠️ |
| 6 | `Sort` (top-N) | 200 | 10 | 1 | (bị LIMIT cắt) |
| 7 | `Limit` | 10 | 10 | 1 | 0 % |

### Node lệch nhiều nhất và vì sao nó nằm ở đó

**`HashAggregate`: đoán 200, thật 25.599 — lệch 128 lần.**

Con số **200** không phải ngẫu nhiên: đó là `DEFAULT_NUM_DISTINCT`, hằng số planner dùng khi **không biết cột `d.name` có bao nhiêu giá trị phân biệt sau join**. Nó biết `device.name` có ~50.000 giá trị, nhưng sau một hash join thì nó bỏ cuộc và trả về hằng số.

Câu hỏi trong đề — *node lệch nhất nằm gần lá hay gần gốc* — có câu trả lời hai vế:

- **Vế 1:** node lệch nhất (`HashAggregate`) nằm **gần gốc**. Ở đây nó **vô hại**: `Batches: 1, Memory Usage: 2593kB`, mọi thứ vừa RAM, không ai chết.
- **Vế 2:** nhưng nếu cùng sai số đó xảy ra **gần lá**, nó sẽ bị **khuếch đại qua từng tầng join phía trên**.

Minh hoạ bằng chính con số ở đây: `Seq Scan on ts_kv` chỉ lệch 11 %, nhưng nếu nó lệch 128 lần thì planner sẽ tưởng chỉ có ~430 dòng → chọn **nested loop** thay vì hash join → 55.563 lần index lookup vào `device` → query 400 ms thành vài phút.

> **Kỹ năng nền tảng: đọc plan từ dưới lên, tìm node ĐẦU TIÊN mà `rows` và `actual rows` lệch nhau nhiều lần. Đó gần như luôn là gốc bệnh.** Node phía trên lệch chỉ là hậu quả bị kéo theo.

Sai ở lá 10 lần → sau 3 tầng join có thể thành 1.000 lần. Sai ở gốc 128 lần → chỉ tốn thêm chút RAM.

### `SETTINGS` in ra gì

```
Settings: effective_cache_size = '1GB', jit = 'off', max_parallel_workers_per_gather = '0'
Query Identifier: -6251925776040490378
```

Ba GUC lab đang đặt khác mặc định. Luôn bật `SETTINGS` khi dán plan cho người khác xem — không có nó, người đọc không biết anh đang chạy với `work_mem` bao nhiêu và mọi lời khuyên đều thành đoán mò.

`Query Identifier` là ID để nối plan này với dòng tương ứng trong `pg_stat_statements` (Day 05).

---

## Bảng số liệu chính

| Kịch bản | node plan chính | actual time | shared hit/read | temp r/w | ghi chú |
|---|---|---|---|---|---|
| `count(*) device_id=42` trước ANALYZE | Seq Scan | 319,0 ms | 28.058 / 8.900 | — | rows 17.185 vs 3.731 (+361 %) |
| `count(*) device_id=42` sau ANALYZE | Seq Scan | 313,6 ms | 28.150 / 8.808 | — | rows 3.500 vs 3.731 (−6 %) |
| `count(*) ts_kv` full | Seq Scan | 566,8 ms | 28.131 / 8.827 | — | cost tự tính khớp 100 % |
| `count(*) alarm` | Seq Scan | 31,3 ms | 3.705 / 0 | — | nằm trọn trong shared_buffers |
| `ORDER BY dbl_v LIMIT 10` | top-N heapsort 26 kB | 670,2 ms | 28.163 / 8.795 | 0 | không đụng đĩa |
| `ORDER BY dbl_v` không LIMIT | external merge 201 MB | **2.489,8 ms** | 28.195 / 8.763 | **50.249 / 50.338** | chậm 3,7× |
| join `ts_kv × device` 1 ngày | Hash Join → HashAgg | 438,7 ms | 27.594 / 10.574 | 0 | HashAgg lệch 128× |

Quan sát xuyên suốt: **`shared hit + read ≈ 36.958` ở mọi query đụng `ts_kv`** — đúng bằng `relpages`. Mọi query hôm nay đều đọc toàn bộ 289 MB. Đó là cả nội dung của tuần 2.

---

## Ba điều dễ hiểu sai

| # | Hiểu nhầm phổ biến | Sự thật |
|---|---|---|
| 1 | "Insert xong thì planner biết bảng có 5 triệu dòng" | `reltuples = -1`. Planner suy ngược từ kích thước file và **sai 31 %**. Chỉ ANALYZE hoặc autovacuum mới sửa |
| 2 | "`cost` cao thì chạy lâu, tỷ lệ thuận" | ms÷cost dao động 2 lần trong chính 4 query hôm nay. Cost chỉ so sánh **plan của cùng query trên cùng máy** |
| 3 | "`actual rows` là tổng số dòng node đó trả về" | Sai khi `loops > 1`. Dưới `Gather` là **trung bình mỗi worker**. Phải nhân với `loops` |

Thêm một điều tinh vi hơn: **sai số ở hai tầng có thể triệt tiêu nhau** (§3). Sửa đúng một tầng có thể làm kết quả cuối tệ đi. Luôn bóc tầng, đừng nhìn con số cuối.

---

## Áp dụng vào hệ thật

**1. Thêm `ANALYZE` vào mọi pipeline nạp dữ liệu lớn.**
Bất kỳ job nào `COPY`/`INSERT ... SELECT` khối lượng lớn rồi query ngay trong cùng job. Chi phí 182 ms trên 5 triệu dòng. Áp dụng ngay: job ETL đêm, job migration, job backfill.

**2. Câu SQL đầu tiên khi gặp "query chậm bí ẩn":**

```sql
SELECT relname, n_live_tup, n_dead_tup,
       last_analyze, last_autoanalyze,
       now() - greatest(last_analyze, last_autoanalyze) AS thong_ke_cu_bao_lau
FROM pg_stat_user_tables
WHERE relname IN ('ts_kv','device','alarm')
ORDER BY thong_ke_cu_bao_lau DESC NULLS FIRST;
```

`NULL` hoặc "cũ hơn vài ngày" trên bảng ghi nhiều = nghi phạm số một. Đưa query này thành một panel trên Grafana.

**3. Bảng nào bị ghi nhiều thì hạ ngưỡng autoanalyze riêng cho nó:**

```sql
-- mặc định 10% của 5 triệu = 500.000 dòng mới chịu chạy — quá muộn
ALTER TABLE ts_kv SET (autovacuum_analyze_scale_factor = 0.01);   -- 50.000 dòng
```

Day 23 đào sâu chuyện này.

**4. Đưa `\set AUTOCOMMIT off` vào `~/.psqlrc` cho profile production.** Một dòng, phòng được sự cố ở §5.

**5. Với cột lệch nặng (`tenant_id`, `device_id`, `status`), tăng statistics target:**

```sql
ALTER TABLE ts_kv ALTER COLUMN device_id SET STATISTICS 1000;
ANALYZE ts_kv;
```

MCV từ 100 lên 1.000 giá trị → phần đuôi được mô tả tốt hơn nhiều. Đo lại trước/sau, đừng làm mù.

---

## Câu hỏi mở sang các ngày sau

1. `Seq Scan` đọc trọn 36.958 page cho ra 3.731 dòng. Index cần rẻ tới mức nào mới thắng? → **Day 04**
2. MCV chỉ giữ 100 giá trị / 28.795 phân biệt. Phần đuôi được ước lượng bằng công thức nào? → **Day 11**
3. `ORDER BY` tràn 201 MB đĩa tạm với `work_mem=4MB`. Tăng work_mem lên bao nhiêu thì hết tràn, và cái giá khi 100 connection cùng làm vậy? → **Day 18**
4. `HashAggregate` đoán 200 vs thật 25.599 — có cách nào dạy planner con số đúng không? → **Day 13** (`CREATE STATISTICS`)
5. Generic plan chuyển sau lần thứ 5 — đo tận tay thế nào? → **Day 42**
