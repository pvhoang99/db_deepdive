# Day 32 — Lời giải: Declarative partitioning & partition pruning

> Bài chữa. Đo thật trên lab `SCALE=1` (`ts_kv` = 5.000.000 dòng, 295 MB, `ts` trải từ 2025-05-01 đến 2025-07-30, correlation = 1). Toàn bộ số liệu dưới đây là output thật của `EXPLAIN (ANALYZE, BUFFERS)`, `max_parallel_workers_per_gather = 0` để plan dễ đọc.
>
> Kết luận một câu của cả ngày: **partition không phải công cụ tăng tốc query — nó là công cụ vận hành.** Ở lab này partition làm query **chậm hơn** trong 3/4 trường hợp. Số đo bên dưới chứng minh điều đó.

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án đo được | Bẫy |
|---|---|---|---|
| 1 | Query 1 ngày trên bảng phân vùng theo tháng — đọc bao nhiêu partition? | **1** (`ts_p_2025_06`). Plan chỉ có đúng 1 node, không có `Append`. | Nhưng nó vẫn đọc **toàn bộ 151 MB** của partition tháng đó nếu không có index — 133 ms. "Prune xuống 1 partition" ≠ "chỉ đọc 1 ngày". |
| 2 | Query với `ts > $1` (tham số) có prune được không? | **Có — nhưng chỉ khi plan là generic.** Với custom plan, tham số đã được thay bằng hằng số ngay lúc plan → prune ở plan-time, không thấy gì đặc biệt. Với `plan_cache_mode = force_generic_plan` mới thấy `Subplans Removed: 3`. | Bẫy lớn: prepared statement ở lab **không tự chuyển sang generic plan** sau 5 lần. Postgres giữ custom plan vì nó rẻ hơn. Xem §3. |
| 3 | Partition có bao giờ làm query **chậm hơn** không? | **Có, và rất thường xuyên.** Q1 (`count 1 ngày`): phẳng 9,2 ms vs phân vùng 110,4 ms (**12×**). Q3 (`1 device toàn thời gian`): phẳng 0,63 ms vs phân vùng 1,34 ms (**2,1×**). Q4 (`group by key_id`): phẳng 968 ms vs phân vùng 1217 ms (**1,26×**). | Nguyên nhân khác nhau ở từng câu — xem §4. |

---

## §1. Partition là gì và không phải là gì

Tạo `ts_p` phân vùng RANGE theo `ts`, 3 partition tháng + 1 default, rồi `INSERT ... SELECT * FROM ts_kv` (5 triệu dòng).

```sql
CREATE TABLE ts_p (
  device_id bigint NOT NULL, key_id smallint NOT NULL, ts timestamptz NOT NULL,
  dbl_v double precision, bool_v boolean, str_v text
) PARTITION BY RANGE (ts);
CREATE TABLE ts_p_2025_05 PARTITION OF ts_p FOR VALUES FROM ('2025-05-01') TO ('2025-06-01');
CREATE TABLE ts_p_2025_06 PARTITION OF ts_p FOR VALUES FROM ('2025-06-01') TO ('2025-07-01');
CREATE TABLE ts_p_2025_07 PARTITION OF ts_p FOR VALUES FROM ('2025-07-01') TO ('2025-08-01');
CREATE TABLE ts_p_default PARTITION OF ts_p DEFAULT;
INSERT INTO ts_p SELECT * FROM ts_kv;
CREATE INDEX ON ts_p (device_id, ts);   -- index này lan xuống mọi partition
```

| Quan hệ | Kích thước (total) | Là partition? | Số dòng |
|---|---|---|---|
| `ts_p` | **0 bytes** | không (là parent) | — |
| `ts_p_2025_05` | 151 MB | có | 1.722.141 |
| `ts_p_2025_06` | 146 MB | có | 1.666.668 |
| `ts_p_2025_07` | 142 MB | có | 1.611.191 |
| `ts_p_default` | 16 kB | có | **0** |

Ba điều đọc thẳng từ bảng này:

1. **Parent `ts_p` chiếm 0 byte.** Nó không phải một cái bảng, nó là một *entry trong catalog* + một danh sách partition. Mọi dòng nằm ở partition con. `pg_relation_size('ts_p')` = 0 luôn — nếu bạn monitor dung lượng bằng `pg_relation_size` trên tên bảng cha thì sau khi partition, dashboard của bạn về 0 và bạn tưởng mất dữ liệu. Phải dùng `pg_total_relation_size` cộng qua `pg_partition_tree()`.
2. **`ts_p_default` trống.** Đúng như thiết kế: mọi dòng đều rơi vào 3 tháng đã khai báo. Nhưng nó tồn tại là một *bảo hiểm*, không phải một *chỗ chứa* — xem cái bẫy ở §6.
3. **`CREATE INDEX ON ts_p (device_id, ts)`** không tạo index trên parent (parent 0 byte). Nó tạo 3 index con `ts_p_2025_05_device_id_ts_idx`, … và một index "ảo" trên parent để gom chúng lại. Bạn thấy tên partition-level index trong mọi plan bên dưới.

### 🔧 Tình huống thực tế — dashboard dung lượng về 0

Team hạ tầng có Grafana panel `pg_relation_size('public.events')` để cảnh báo khi bảng events vượt 500 GB. Đêm migration, DBA đổi `events` thành bảng phân vùng theo tuần. Sáng hôm sau panel hiển thị **0 B** và alert "table shrank 99%" nổ. Không ai mất dữ liệu, chỉ là query monitoring sai. Truy vấn đúng:

```sql
SELECT sum(pg_total_relation_size(relid))
FROM pg_partition_tree('events');   -- gồm cả parent lẫn mọi partition con
```

Cùng loại bug: script backup `pg_dump -t events` — với bảng phân vùng, `-t events` **chỉ dump định nghĩa parent**, không dump dữ liệu con, trừ khi thêm `-t 'events*'`. Đây là cách mất backup thầm lặng.

---

## §2. Partition pruning — lúc plan

Bốn query, cùng một bảng.

| Query | Partition được quét | Buffers | Exec time |
|---|---|---|---|
| `ts >= '2025-06-01' AND ts < '2025-06-02'` (1 ngày) | **1** — chỉ `ts_p_2025_06`, **không có node `Append`** | 12.320 | **133,6 ms** |
| `ts >= '2025-05-25' AND ts < '2025-06-05'` (cross-month) | **2** — `Append` gồm `_05` và `_06` | 25.050 | 340,3 ms |
| `device_id = 42` (không lọc khoá phân vùng) | **4/4** — cả `default` | 3.580 | 6,6 ms |
| 1 ngày, `enable_partition_pruning = off` | **4/4** | 36.960 | **386,8 ms** |

Đọc kỹ ba chỗ:

**a) Prune xuống 1 partition thì `Append` biến mất hoàn toàn.**

```
 Aggregate  (cost=37463.31..37463.32 rows=1) (actual time=133.627..133.628 rows=1 loops=1)
   ->  Seq Scan on ts_p_2025_06 ts_p  (cost=0.00..37320.02 rows=57314) (actual rows=55563 loops=1)
         Filter: ((ts >= '2025-06-01'...) AND (ts < '2025-06-02'...))
         Rows Removed by Filter: 1611105
```

Postgres không giữ `Append` với 1 child — nó nhấc thẳng child lên. Alias vẫn là `ts_p` (tên bạn viết), nhưng relation thật là `ts_p_2025_06`. **Đây là cách nhanh nhất để biết pruning có chạy hay không: nhìn tên bảng trong plan.**

**b) Prune rồi vẫn phải quét full partition.**

`Rows Removed by Filter: 1611105` — đọc 1.666.668 dòng của tháng 6 để lấy về 55.563 dòng của ngày 1/6. Tỉ lệ hữu ích **3,3%**. Pruning cắt được 2 partition (296 MB) nhưng partition còn lại vẫn bị seq scan trọn vẹn. Partition **theo tháng** cho query **theo ngày** = giảm I/O 3× chứ không phải 30×. Muốn hơn thì cần index bên trong partition — §4b.

**c) Tắt pruning cho thấy giá của nó.** 386,8 ms vs 133,6 ms = **2,9×**, và buffers 36.960 vs 12.320 = **3,0×**. Đúng tỉ lệ 3 partition/1 partition. `enable_partition_pruning = off` là công tắc chỉ để làm bài tập; đừng bao giờ set nó trên production.

### Bẫy: query không lọc khoá phân vùng

`WHERE device_id = 42` đọc **cả 4 partition** — nhưng chỉ mất 6,6 ms, vì index `(device_id, ts)` có ở mọi partition, mỗi partition cho một `Bitmap Heap Scan` rẻ. Plan thành 4 node thay vì 1:

```
->  Append (actual rows=3731)
      ->  Bitmap Heap Scan on ts_p_2025_05  (rows=1329)  Heap Blocks: exact=1251
      ->  Bitmap Heap Scan on ts_p_2025_06  (rows=1200)  Heap Blocks: exact=1140
      ->  Bitmap Heap Scan on ts_p_2025_07  (rows=1202)  Heap Blocks: exact=1163
      ->  Seq Scan on ts_p_default          (rows=0)
```

Chú ý `ts_p_default` cũng bị đụng vào (`Seq Scan`, cost 0.00..0.00). Partition default **không bao giờ bị prune** trừ khi điều kiện loại trừ được nó về mặt logic — mà điều kiện trên `device_id` thì không nói gì về `ts`, nên default luôn phải quét. May là nó trống nên miễn phí.

### 🔧 Tình huống thực tế — query lookup theo ID trên bảng phân vùng theo thời gian

API `GET /events/{event_id}` của bạn chạy `SELECT * FROM events WHERE id = $1`. Trước khi partition: một `Index Scan`, 4 buffer, 0,05 ms. Sau khi partition theo tuần và giữ 2 năm (**104 partition**): 104 index scan, ~400 buffer, và planning time nhảy từ 0,05 ms lên 1,5 ms — **planning tốn hơn execution 10 lần**. Với 5.000 rps thì đó là 104 lần index-descend mỗi request.

Cách sửa: bắt caller truyền thêm thời gian (`GET /events/{event_id}?ts=...` → `WHERE id=$1 AND ts >= $2::date AND ts < $2::date + 1`), hoặc encode timestamp vào chính ID (ULID/Snowflake) rồi derive điều kiện `ts` từ ID trong tầng app. Đây là lý do bảng phân vùng theo thời gian **không hợp** với truy cập ngẫu nhiên theo surrogate key.

---

## §3. Execution-time pruning và cái bẫy tham số

Đây là phần README nói "chạy 5 lần rồi lần 6 sẽ ra generic plan". **Ở lab, điều đó không xảy ra.**

```sql
PREPARE q(timestamptz, timestamptz) AS SELECT count(*) FROM ts_p WHERE ts >= $1 AND ts < $2;
EXPLAIN (ANALYZE) EXECUTE q('2025-06-01','2025-06-02');   -- lần 1
EXPLAIN EXECUTE q(...);  -- lần 2..5
EXPLAIN (ANALYZE) EXECUTE q('2025-06-01','2025-06-02');   -- lần 6
```

Cả 6 lần đều ra **y hệt nhau**:

```
 Aggregate  (cost=37463.31..37463.32 rows=1)
   ->  Seq Scan on ts_p_2025_06 ts_p  (cost=0.00..37320.02 rows=57314)
         Filter: ((ts >= '2025-06-01 00:00:00+00'::timestamptz) AND (ts < '2025-06-02 ...'))
```

Hai dấu hiệu nói đây là **custom plan**, không phải generic:
- Tham số đã bị thay bằng **hằng số cụ thể** trong `Filter`. Generic plan sẽ hiện `$1`, `$2`.
- Estimate `rows=57314` sát thực tế (55.563). Generic plan không biết giá trị nên phải đoán mù.

Postgres chỉ chuyển sang generic plan khi generic **không đắt hơn** trung bình custom. Ở đây custom plan prune còn 1 partition (cost 37.463) trong khi generic phải giữ cả 4 (cost 112.147 — xem ngay dưới), nên planner **cố tình bám custom plan mãi mãi**. Đây là hành vi đúng và tốt, không phải lỗi lab.

Ép generic để nhìn thấy execution-time pruning:

```sql
SET plan_cache_mode = force_generic_plan;
PREPARE q2(timestamptz, timestamptz) AS SELECT count(*) FROM ts_p WHERE ts >= $1 AND ts < $2;
EXPLAIN (ANALYZE) EXECUTE q2('2025-06-01','2025-06-02');
```

```
 Aggregate  (cost=112147.51..112147.52 rows=1) (actual time=152.418..152.419 rows=1 loops=1)
   ->  Append  (cost=0.00..112085.01 rows=25001) (actual rows=55563 loops=1)
         Subplans Removed: 3
         ->  Seq Scan on ts_p_2025_06 ts_p_1  (cost=0.00..37320.02 rows=8333) (actual rows=55563)
 Planning Time: 0.818 ms
 Execution Time: 152.475 ms
```

**Đây là `Subplans Removed: 3`** — thứ cần tìm của cả §3.

| | Custom plan | Generic plan |
|---|---|---|
| Cost hiển thị | 37.463 | **112.147** (giá của cả 4 partition) |
| Estimate rows | 57.314 (sát) | 8.333 (sai 6,7×) |
| Prune ở đâu | plan-time (không dấu vết) | **execution-time** → `Subplans Removed: 3` |
| Planning Time | 0,083–0,107 ms | 0,818 ms |
| Execution Time | 133,2 ms | 152,5 ms |

Generic plan chậm hơn 14% ở đây vì phải khởi tạo 4 subplan rồi vứt 3. Nhưng đổi lại planning chỉ làm 1 lần thay vì mỗi lần execute — với 92 partition thì phép đánh đổi đảo chiều (§5).

### Cái bẫy thật: điều kiện đến từ subquery không prune được gì

```sql
EXPLAIN (ANALYZE) SELECT count(*) FROM ts_p
WHERE ts >= (SELECT min(ts) + interval '30 days' FROM ts_p);
```

```
 Aggregate  (actual time=1598.315..1598.319 rows=1 loops=1)
   InitPlan 1
     ->  Aggregate (actual time=866.129..866.131)
           ->  Append (actual rows=5000000)     -- quét TOÀN BỘ 5 triệu dòng để tính min(ts)
   ->  Append  (cost=0.00..107793.34 rows=1666668) (actual rows=3333389 loops=1)
         ->  Seq Scan on ts_p_2025_05  Filter: (ts >= (InitPlan 1).col1)   rows=55530
         ->  Seq Scan on ts_p_2025_06  Filter: (ts >= (InitPlan 1).col1)   rows=1666668
         ->  Seq Scan on ts_p_2025_07  Filter: (ts >= (InitPlan 1).col1)   rows=1611191
         ->  Seq Scan on ts_p_default  Filter: (ts >= (InitPlan 1).col1)   rows=0
 Execution Time: 1598.352 ms
```

**Không hề có `Subplans Removed`.** Điều kiện đến từ `InitPlan` — về lý thuyết Postgres *có thể* prune ở execution-time khi InitPlan xong, nhưng ở đây kết quả `2025-05-31` nằm trong partition đầu tiên nên **không partition nào bị loại**, và phần lớn 1,6 giây là do InitPlan tự nó quét full bảng (866 ms).

Điểm rút ra: điều kiện càng "động" thì pruning càng yếu. Xếp theo độ mạnh:

| Dạng điều kiện | Prune khi nào | Dấu vết trong plan |
|---|---|---|
| `ts >= '2025-06-01'` (hằng số) | plan-time | tên partition trong plan, mất `Append` |
| `ts >= $1` + custom plan | plan-time (mỗi lần execute) | như trên, nhưng planning lặp lại |
| `ts >= $1` + generic plan | execution-time | `Subplans Removed: N` |
| `ts >= (SELECT ...)` | execution-time, sau InitPlan | `Subplans Removed` nếu có gì để loại |
| `ts >= f(x)` với `f` VOLATILE | **không bao giờ** | quét hết |
| `date_trunc('day', ts) = '...'` | **không bao giờ** | quét hết — điều kiện không ở dạng `ts <op> const` |

Dòng cuối là lỗi hay gặp nhất thật sự trong code production.

### 🔧 Tình huống thực tế — `date_trunc` giết pruning

Báo cáo cuối tháng viết `WHERE date_trunc('month', created_at) = '2025-06-01'`. Trên bảng phẳng nó chỉ mất index; trên bảng phân vùng 24 tháng nó mất **luôn cả pruning**: 24 seq scan thay vì 1. Query từ 200 ms thành 4 giây. Sửa: viết lại thành sargable range.

```sql
-- sai
WHERE date_trunc('month', created_at) = '2025-06-01'
-- đúng: prune được, dùng được index
WHERE created_at >= '2025-06-01' AND created_at < '2025-07-01'
```

Cùng loại: `WHERE created_at::date = '2025-06-01'`, `WHERE to_char(created_at,'YYYY-MM') = '2025-06'`, `WHERE created_at > now() - interval '7 days'` (cái cuối *prune được* vì `now()` là STABLE, nhưng chỉ ở execution-time).

---

## §4. So bảng phẳng vs bảng phân vùng

`ts_kv` (phẳng, 5M dòng) có `idx_dev_ts (device_id, ts)` và `idx_ts_kv_ts (ts)`. `ts_p` ban đầu chỉ có `(device_id, ts)`.

| Query | Phẳng `ts_kv` | Phân vùng `ts_p` | Ai thắng |
|---|---|---|---|
| **Q1** `count(*) WHERE ts` 1 ngày | **9,2 ms** — Index Only Scan `idx_ts_kv_ts`, 156 buffer | 110,4 ms — Seq Scan `ts_p_2025_06`, 12.320 buffer | phẳng **12,0×** |
| **Q2** `device_id=42 AND ts` 1 ngày | 0,048 ms — Index Only Scan, 7 buffer | **0,037 ms** — Index Only Scan trên 1 partition, 4 buffer | phân vùng **1,3×** |
| **Q3** `device_id=42` toàn thời gian | **0,63 ms** — 1 Index Only Scan, 19 buffer | 1,34 ms — `Append` 4 node, 514 buffer | phẳng **2,1×** |
| **Q4** `GROUP BY key_id` toàn bảng | **968 ms** — Seq Scan + HashAggregate | 1217 ms — `Append` + HashAggregate | phẳng **1,26×** |

Giải thích từng dòng, vì mỗi dòng thua/thắng vì lý do khác nhau:

- **Q1 thua 12× không phải lỗi partition — là lỗi thiếu index.** Bảng phẳng có `idx_ts_kv_ts` nên làm được index-only scan trên đúng 155 page. `ts_p` không có index trên `ts` nên phải seq scan 12.320 page của cả tháng 6. Đây là bài học vận hành quan trọng: **partition không thay thế index.** Xem §4b.
- **Q2 thắng 1,3×** — đây là dạng query duy nhất partition thật sự giúp: có cả khoá phân vùng lẫn cột index. Index của 1 partition thấp hơn index của bảng phẳng (cây nhỏ hơn → ít level hơn), nên `Buffers: 4` vs `7`. Nhưng chênh lệch là 0,011 ms — không đáng kể ở quy mô này.
- **Q3 thua 2,1×** — không lọc theo `ts` nên phải chạm mọi partition. 4 index scan thay vì 1, 514 buffer thay vì 19. Càng nhiều partition càng tệ: với 92 partition thì đây là 92 lần descend cây.
- **Q4 thua 1,26×** — quét toàn bộ thì tổng số page bằng nhau, nhưng `Append` thêm overhead per-tuple và mất tính liên tục của readahead. 249 ms cho không.

### §4b. Cho công bằng: thêm index `(ts)` vào `ts_p`

```sql
CREATE INDEX ON ts_p (ts);
```

```
 Aggregate  (cost=1824.29..1824.30 rows=1) (actual time=9.122..9.123 rows=1 loops=1)
   Buffers: shared hit=4 read=151
   ->  Index Only Scan using ts_p_2025_06_ts_idx on ts_p_2025_06 ts_p (actual rows=55563)
 Execution Time: 9.149 ms
```

**9,149 ms vs 9,233 ms của bảng phẳng — hoà.** Cùng số buffer (155 vs 156). Đúng như dự đoán: khi cả hai đều có index thích hợp, partition không cho thêm gì cho *query này*.

**Đây là kết luận trung tâm của cả ngày.** Với 5M dòng và index đúng, partition cho hiệu năng query bằng hoặc kém hơn bảng phẳng. Cái nó cho là ở chỗ khác — vận hành (Day 33).

### 🔧 Tình huống thực tế — "partition đi cho nhanh"

Bảng `orders` 80 triệu dòng, query chậm. Ai đó đề xuất partition theo tháng. Sau 3 ngày migration, kết quả: query theo `order_id` chậm hơn 20× (phải đụng 36 partition), query báo cáo theo tháng nhanh hơn 3×, còn query dashboard "đơn hàng 7 ngày qua" gần như không đổi. Net: hiệu năng tệ hơn.

Câu hỏi phải hỏi **trước** khi partition, theo thứ tự:

1. Bảng có thật sự lớn không? Dưới ~100 GB thì gần như luôn: index đúng > partition.
2. Có **query nào** lọc theo khoá phân vùng trong ≥80% traffic không? Nếu không, partition chỉ nhân số index scan lên.
3. Bạn cần gì từ nó — **query nhanh hơn hay xoá dữ liệu cũ nhanh hơn?** Nếu là vế 2 thì partition đúng là câu trả lời, và bạn nên chấp nhận query chậm hơn một chút.
4. Có unique constraint nào không chứa khoá phân vùng không? Nếu có, bạn đã bị chặn (§6).

---

## §5. Planning time tăng theo số partition

Tạo `ts_many`: cùng dữ liệu, phân vùng **theo ngày** → **92 partition**.

| Query | Số partition sau prune | Planning Time | Execution Time |
|---|---|---|---|
| `ts_many` 1 ngày (lần 1) | 1/92 | **0,406 ms** | 7,896 ms |
| `ts_many` 1 ngày (lần 2, cache nóng) | 1/92 | **0,046 ms** | 8,054 ms |
| `ts_many` toàn bảng (lần 1) | 92/92 | **1,702 ms** | 767,9 ms |
| `ts_many` toàn bảng (lần 2) | 92/92 | **0,655 ms** | 773,9 ms |
| `ts_many` JOIN `device`, 1 ngày | 1/92 | 0,354 ms | 29,7 ms |
| `ts_many` generic plan, 1 ngày | 1/92, **`Subplans Removed: 91`** | **1,606 ms** | 11,0 ms |
| `ts_p` 1 ngày (4 partition, có index `ts`) | 1/4 | 0,298 ms | 8,825 ms |

Ba quan sát:

**a) Planning time tỉ lệ với số partition *còn lại sau prune*, không phải tổng số partition.** 1/92 → 0,046 ms; 92/92 → 0,655 ms (14×). Postgres prune rất sớm trong quá trình plan, nên nếu query luôn lọc theo khoá phân vùng thì 92 partition gần như miễn phí lúc plan.

**b) Generic plan trả ngược lại: 1,606 ms planning** vì phải build đủ 92 subplan rồi mới loại 91 lúc chạy. Nhưng planning đó chỉ làm **một lần** cho cả vòng đời prepared statement, còn custom plan trả 0,046 ms **mỗi lần execute**. Điểm hoà vốn: 1,606 / 0,046 ≈ **35 lần execute**. Prepared statement chạy hàng nghìn lần → generic thắng đậm. Đó chính là lý do `plan_cache_mode` tồn tại.

**c) Partition theo ngày nhanh hơn theo tháng cho query 1 ngày:** 7,9 ms (`ts_many`, seq scan 1 partition 1 ngày = 900 page) vs 110 ms (`ts_p` không index) hay 8,8 ms (`ts_p` có index `ts`). Chọn granularity đúng bằng đúng việc thêm index — nhưng partition theo ngày trả giá bằng 92 file, 92 dòng catalog, 92 index, 92 lần autovacuum.

### 🔧 Tình huống thực tế — 5.000 partition

Một hệ metrics partition theo **giờ**, giữ 6 tháng → ~4.400 partition. Triệu chứng:
- `planning_time` cho query dashboard (không lọc thời gian chính xác) lên **200–800 ms**, gấp nhiều lần execution.
- `pg_class` phình lên, `\dt` treo psql.
- `autovacuum` không kịp: mỗi worker chỉ xử lý 1 bảng một lúc, 4.400 bảng / 3 worker.
- Backup `pg_dump` chậm gấp 10× vì mỗi partition là một lần lock + một section.

Quy tắc ngón tay cái thực dụng: **giữ tổng số partition dưới ~1.000, lý tưởng dưới ~100.** Chọn granularity sao cho mỗi partition khoảng 10–100 GB. Nếu retention là 2 năm: theo tháng = 24 partition ✅; theo tuần = 104 ✅; theo ngày = 730 ⚠️; theo giờ = 17.520 ❌.

Nếu bắt buộc phải nhiều partition, đảm bảo **mọi** query nóng đều có điều kiện trên khoá phân vùng, và cân nhắc `plan_cache_mode = force_generic_plan` cho các prepared statement chạy nhiều.

---

## §6. Ràng buộc và hạn chế

Đây là phần quyết định bạn *có được phép* partition hay không. Chạy thật, mọi lỗi dưới đây là output nguyên văn.

**1. Unique/PK bắt buộc chứa toàn bộ cột phân vùng.**

```sql
CREATE TABLE t_bad (id bigserial PRIMARY KEY, ts timestamptz NOT NULL) PARTITION BY RANGE (ts);
-- ERROR:  unique constraint on partitioned table must include all partitioning columns
CREATE UNIQUE INDEX ON t_ok (id);
-- ERROR:  unique constraint on partitioned table must include all partitioning columns
```

Không có đường vòng ở tầng Postgres. Lý do: unique index là per-partition, Postgres không có global index, nên nó không thể đảm bảo duy nhất xuyên partition trừ khi khoá phân vùng nằm trong index (khi đó cùng giá trị ⇒ cùng partition).

**2. PK phải thành `(id, ts)` — và điều đó thay đổi ngữ nghĩa.**

```sql
CREATE TABLE t_ok (id bigint, ts timestamptz NOT NULL, PRIMARY KEY (id, ts)) PARTITION BY RANGE (ts);
INSERT INTO t_ok VALUES (1,'2025-06-01'), (1,'2025-07-01');   -- THÀNH CÔNG, 2 dòng
```

`id = 1` giờ tồn tại **hai lần**. PK `(id, ts)` chỉ cấm trùng cặp, không cấm trùng `id`. Nếu app của bạn giả định `id` là duy nhất — mọi `findById`, mọi FK, mọi cache key — thì bạn vừa âm thầm phá vỡ giả định đó. Đây là rủi ro nguy hiểm hơn cả lỗi compile, vì nó không báo lỗi.

**3. FK trỏ tới bảng phân vùng phải trỏ tới toàn bộ khoá.**

```sql
CREATE TABLE t_child (x int, id bigint, ts timestamptz,
                      FOREIGN KEY (id, ts) REFERENCES t_ok(id, ts));   -- OK
```

Nghĩa là **mọi bảng con phải mang thêm cột `ts`** (denormalize). Với `FOREIGN KEY (id) REFERENCES t_ok(id)` thì lỗi ngay vì không có unique index trên `(id)` đơn lẻ.

**4. Range không được chồng lấn.**

```sql
CREATE TABLE t_ok_2 PARTITION OF t_ok FOR VALUES FROM ('2025-06-01') TO ('2025-12-01');
-- ERROR:  partition "t_ok_2" would overlap partition "t_ok_1"
```

Biên là **`[FROM, TO)`** — cận dưới đóng, cận trên mở. Nên `TO ('2025-07-01')` và `FROM ('2025-07-01')` là hợp lệ và liền mạch.

**5. Không có partition phù hợp và không có default ⇒ INSERT lỗi.**

```sql
INSERT INTO t_ok VALUES (2,'2030-01-01');
-- ERROR:  no partition of relation "t_ok" found for row
```

Đây là **cách production sập lúc nửa đêm**: bạn tạo partition đến hết tháng 12, đến 00:00:01 ngày 1/1 mọi INSERT bắt đầu lỗi. Hai phòng thủ, dùng cả hai:
- Một partition `DEFAULT` để hứng (nhưng nó *không phải* giải pháp — xem dưới).
- Một job tự tạo partition trước ít nhất 2 tháng (`pg_partman`, hoặc một cron 20 dòng).

**Cái bẫy của DEFAULT partition:** khi đã có dòng nằm trong default, việc `CREATE TABLE ... PARTITION OF` cho khoảng thời gian đó bắt buộc phải **quét toàn bộ default partition** dưới `ACCESS EXCLUSIVE` lock để kiểm tra không có dòng nào thuộc range mới. Default càng phình thì thao tác tạo partition càng khoá lâu. Default là chuông báo động, không phải chỗ ở.

### 🔧 Tình huống thực tế — không partition được vì một cột

Bảng `payment` 400 GB, cần partition theo `created_at` để xoá dữ liệu cũ. Nhưng nó có `UNIQUE (idempotency_key)` — cột do client sinh, không liên quan gì tới thời gian, và là thứ chống double-charge. `UNIQUE (idempotency_key, created_at)` **không tương đương**: cùng key ở hai ngày khác nhau sẽ lọt cả hai ⇒ khách bị trừ tiền hai lần.

Các lối thoát thật:
- **Tách bảng khoá riêng**: `payment_idem(idempotency_key PK, payment_id, created_at)` không phân vùng, nhỏ, giữ nguyên tính duy nhất toàn cục; `payment` thì phân vùng thoải mái. Trả giá bằng một lần INSERT nữa trong cùng transaction.
- **Nhét thời gian vào key**: nếu client key luôn kèm ngày (`2025-06-01:abc123`) thì `UNIQUE (idempotency_key, created_at)` đủ an toàn vì cùng key ⇒ cùng ngày ⇒ cùng partition. Cần đổi hợp đồng API.
- **Đưa dedup lên Redis** với TTL bằng cửa sổ idempotency — chấp nhận Redis là single point of truth cho việc đó.

Bài học: **kiểm tra unique constraint là bước 0 của mọi kế hoạch partition**, trước cả khi vẽ sơ đồ.

---

## §7. Partition-wise join và aggregate

`enable_partitionwise_aggregate` mặc định **off**.

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT device_id, count(*) FROM ts_p GROUP BY device_id;
```

| | OFF | ON |
|---|---|---|
| Plan | `HashAggregate` ← `Append` ← 4 Seq Scan | `Finalize HashAggregate` ← `Append` ← 4× (`Partial HashAggregate` ← Seq Scan) |
| Dòng qua `Append` | **5.000.000** | **149.999** |
| Execution Time | 1575,5 ms | **1333,8 ms** |
| Buffers | 36.960 | 36.960 |

**Nhanh hơn 15,3%.** Cơ chế: với ON, mỗi partition tự aggregate trước (`Partial HashAggregate` → 50.000 dòng mỗi partition), rồi `Append` chỉ phải chuyển 150k dòng thay vì 5 triệu, và hash table cuối chỉ merge 150k. Buffers y hệt nhau — I/O không đổi, cái tiết kiệm là **CPU và số tuple đi qua executor**.

Điều kiện để nó chạy: cột GROUP BY phải "tương thích partition", tức mỗi nhóm chỉ nằm trong một partition, HOẶC Postgres chấp nhận partial aggregate rồi finalize (như trên — `device_id` trải khắp mọi partition nên phải finalize).

Nếu GROUP BY **chính là** khoá phân vùng thì còn tốt hơn nữa: không cần `Finalize` chút nào. Nhưng thử với `date_trunc`:

```sql
SET enable_partitionwise_aggregate = on;
EXPLAIN (ANALYZE) SELECT date_trunc('month',ts) m, count(*) FROM ts_p GROUP BY 1;
```

```
 HashAggregate  (cost=405710.06..507272.58 rows=5000001 width=16) (actual rows=3 loops=1)
   ->  Append (actual rows=5000000)
 Execution Time: 1652.884 ms
```

**Không partitionwise, và estimate sai kinh hoàng: `rows=5000001` cho kết quả thật `rows=3`.** Planner không biết `date_trunc('month', ts)` có đúng 3 giá trị (nó không có statistics trên biểu thức), và cũng không nhận ra biểu thức này *hằng số trên mỗi partition tháng*. Kết quả là chậm nhất trong cả ba (1653 ms).

Sửa được bằng extended statistics trên biểu thức (Day 19):
```sql
CREATE STATISTICS ts_p_month (ndistinct) ON date_trunc('month', ts) FROM ts_p;
```
— nhưng nó chỉ sửa estimate, không làm partitionwise chạy.

### Vì sao mặc định off?

`enable_partitionwise_aggregate` và `enable_partitionwise_join` tốn **bộ nhớ và thời gian plan tỉ lệ với số partition**: planner phải cân nhắc đường đi riêng cho từng partition. Với 92 partition và một join 3 bảng, planning có thể nhảy lên hàng trăm ms. Bật khi: ít partition (<50), query analytics chạy lâu, và bạn đã đo thấy lợi. Bật per-session/per-query, không nhất thiết toàn cục:

```sql
SET LOCAL enable_partitionwise_aggregate = on;
```

### 🔧 Tình huống thực tế — partitionwise join cứu ETL

Job ETL đêm join `events` (phân vùng theo ngày) với `event_details` (cũng phân vùng theo ngày, **cùng biên**) trên `(event_id, ts)`. Không có partitionwise join: một Hash Join khổng lồ, build side 200 GB → spill ra đĩa 40 batch, 6 tiếng. Bật `enable_partitionwise_join = on`: 30 join nhỏ, mỗi cái build side ~6 GB vừa `work_mem`, chạy 45 phút.

Điều kiện bắt buộc: **hai bảng phải phân vùng theo cùng kiểu, cùng số partition, cùng biên**, và điều kiện join phải chứa khoá phân vùng. Lệch một biên là mất sạch tối ưu này — nên khi thiết kế hai bảng có quan hệ, hãy partition chúng *giống hệt nhau ngay từ đầu*.

---

## Bảng số liệu chính

| Phép đo | Kết quả |
|---|---|
| `pg_relation_size('ts_p')` (parent) | **0 bytes** |
| Tổng 3 partition | 439 MB (151 + 146 + 142) |
| Query 1 ngày, prune 1/4 partition | 133,6 ms, 12.320 buffer, **không có `Append`** |
| Cùng query, `enable_partition_pruning=off` | 386,8 ms, 36.960 buffer — **2,9×** |
| Query cross-month, prune 2/4 | 340,3 ms, 25.050 buffer |
| Query `device_id=42` (không lọc khoá) | 4/4 partition, 6,6 ms |
| Prepared statement, 6 lần | **luôn custom plan**, không tự chuyển generic |
| `force_generic_plan` | **`Subplans Removed: 3`**, planning 0,818 ms vs 0,083 ms |
| Điều kiện từ subquery | **không prune gì**, 1598 ms |
| Q1 phẳng vs phân vùng (ts_p chưa có index `ts`) | 9,2 ms vs 110,4 ms — **phẳng thắng 12×** |
| Q1 sau khi `CREATE INDEX ON ts_p (ts)` | 9,15 ms vs 9,23 ms — **hoà** |
| Q3 `device_id=42` phẳng vs phân vùng | 0,63 ms / 19 buf vs 1,34 ms / 514 buf — **phẳng thắng 2,1×** |
| Q4 `GROUP BY key_id` | 968 ms vs 1217 ms — **phẳng thắng 1,26×** |
| Planning time, 92 partition, prune còn 1 | 0,046 ms (warm) |
| Planning time, 92 partition, không prune | 0,655 ms — **14×** |
| Generic plan trên 92 partition | **`Subplans Removed: 91`**, planning 1,606 ms |
| Điểm hoà vốn generic vs custom (92 partition) | ~**35 lần execute** |
| `enable_partitionwise_aggregate` OFF → ON | 1575 ms → **1334 ms** (−15,3%), tuple qua `Append` 5.000.000 → **149.999** |
| GROUP BY `date_trunc('month',ts)` | không partitionwise, estimate **5.000.001 vs thật 3**, 1653 ms |

---

## Ba điều dễ hiểu sai

| Hiểu nhầm | Sự thật đo được |
|---|---|
| "Partition làm query nhanh hơn." | Ở lab, phẳng thắng 3/4 query (12×, 2,1×, 1,26×). Sau khi cấp index tương đương thì **hoà**. Partition không tạo ra tốc độ — nó chỉ thay đổi *cách* dữ liệu được tổ chức. Tốc độ đến từ index và từ việc **xoá bớt dữ liệu** (mà partition làm cho việc xoá trở nên rẻ — đó mới là giá trị thật). |
| "Prepared statement sẽ chuyển sang generic plan sau 5 lần, nên phải lo pruning." | Chạy 6 lần: **vẫn là custom plan cả 6**. Postgres so chi phí và thấy custom (37k) rẻ hơn generic (112k) nên bám custom mãi. Muốn thấy `Subplans Removed` phải `SET plan_cache_mode = force_generic_plan`. Và trong trường hợp này custom plan là *lựa chọn đúng* — generic chậm hơn 14%. |
| "Prune xuống 1 partition nghĩa là chỉ đọc phần dữ liệu cần." | `Rows Removed by Filter: 1.611.105` — đọc 1,67 triệu dòng của cả tháng để lấy 55.563 dòng của 1 ngày, **hữu ích 3,3%**. Pruning chỉ cắt ở mức partition. Bên trong partition vẫn cần index như mọi bảng thường. |

---

## Áp dụng vào hệ thật

1. **Trước khi partition, chạy checklist chặn 4 câu** (thứ tự này, dừng ở câu đầu tiên trả lời "không"):
   ```sql
   -- (a) bảng đủ lớn chưa?
   SELECT pg_size_pretty(pg_total_relation_size('events'));   -- < 100 GB thì đi tối ưu index trước

   -- (b) có unique/PK nào KHÔNG chứa cột định phân vùng không? -> đây là rào cản cứng
   SELECT i.indexrelid::regclass, pg_get_indexdef(i.indexrelid)
   FROM pg_index i WHERE i.indrelid = 'events'::regclass AND (i.indisunique OR i.indisprimary);

   -- (c) bao nhiêu % traffic lọc theo cột định phân vùng?
   SELECT calls, mean_exec_time, left(query,100) FROM pg_stat_statements
   WHERE query ILIKE '%events%' ORDER BY calls DESC LIMIT 20;
   ```
   (d) Bạn cần gì — **query nhanh hơn hay retention rẻ hơn?** Nếu là vế 1, quay lại Day 06–12.

2. **Chọn granularity theo dung lượng, không theo trực giác.** Nhắm 10–100 GB/partition và **tổng < 1.000 partition**. Công thức: `granularity = retention / 100`. Retention 2 năm → tháng. Retention 90 ngày → tuần.

3. **Luôn tạo partition trước ít nhất 2 chu kỳ.** Dùng `pg_partman` hoặc cron. Có `DEFAULT` partition nhưng **alert khi nó có dòng đầu tiên** — nó là chuông báo, và để nó phình lên sẽ khoá `ACCESS EXCLUSIVE` khi bạn tạo partition bù:
   ```sql
   SELECT count(*) FROM events_default;   -- phải luôn = 0
   ```

4. **Giữ nguyên chiến lược index.** Partition không thay index (§4b chứng minh: thiếu index `ts` → chậm 12×). Tạo index trên bảng cha để nó lan xuống mọi partition mới:
   ```sql
   CREATE INDEX ON events (ts);
   CREATE INDEX ON events (device_id, ts);
   ```
   Lưu ý: `CREATE INDEX` trên parent khoá cả cây. Trên bảng lớn dùng `CREATE INDEX ... ON ONLY events` (chỉ tạo entry cha, không hợp lệ), rồi `CREATE INDEX CONCURRENTLY` trên từng partition, rồi `ALTER INDEX ... ATTACH PARTITION` — Day 33/43.

5. **Rà mọi query nóng tìm điều kiện giết pruning** trước ngày cut-over. Grep code tìm: `date_trunc(...) =`, `::date =`, `to_char(...) =`, `EXTRACT(... FROM ts) =` trên cột phân vùng. Viết lại thành `>= x AND < y`.

6. **Với prepared statement chạy hàng nghìn lần trên >50 partition, cân nhắc generic plan:**
   ```sql
   SET plan_cache_mode = force_generic_plan;   -- hoặc set per-role
   ```
   Đo trước: điểm hoà vốn ở lab là ~35 lần execute. Kiểm tra `Subplans Removed` xuất hiện — nếu không thấy, generic plan đang quét hết partition và bạn vừa làm mọi thứ tệ đi.

7. **Bật partitionwise cho ETL/analytics, không cho OLTP:**
   ```sql
   BEGIN;
   SET LOCAL enable_partitionwise_aggregate = on;
   SET LOCAL enable_partitionwise_join = on;
   -- query nặng ở đây
   COMMIT;
   ```
   Và nếu có hai bảng thường join nhau, **partition chúng cùng khoá, cùng biên** ngay từ ngày đầu — không thể sửa lại rẻ về sau.

8. **Sửa monitoring và backup trước khi migration**, không phải sau: `pg_total_relation_size` → `sum() FROM pg_partition_tree()`; `pg_dump -t events` → `-t 'events*'`.

---

## Câu hỏi mở sang các ngày sau

- **Day 33** dùng chính `ts_p` này: `DETACH`/`ATTACH`/`DROP PARTITION` — chỗ partition *thật sự* trả tiền. So `DROP TABLE ts_p_2025_05` (tức thời, không sinh dead tuple) với `DELETE FROM ts_kv WHERE ts < '2025-06-01'` (1,7 triệu dead tuple, bloat, autovacuum, không trả lại đĩa). Đó là câu trả lời cho "vậy partition để làm gì".
- **Day 34–35** hỏi ngược lại: với dữ liệu telemetry, model lưu trữ nào đúng — EAV như `ts_kv`, jsonb, hay cột rộng? Và partition ăn khớp thế nào với từng model.
- **Day 43 (DDL locks)** trả lời phần còn thiếu ở §6: làm sao `ATTACH PARTITION` mà không khoá bảng — `ADD CONSTRAINT ... NOT VALID` + `VALIDATE CONSTRAINT` để Postgres bỏ qua bước scan.
- **Day 19** đã gặp lại ở §7: `GROUP BY date_trunc('month', ts)` estimate 5.000.001 vs thật 3. Extended statistics trên biểu thức sửa được estimate — nhưng ở đây estimate sai *không* làm plan sai, vì `HashAggregate` vẫn là lựa chọn đúng. Câu hỏi hay: khi nào estimate sai 1,6 triệu lần mà vẫn vô hại?
- **Day 41 (TOAST)**: `ts_p` có cột `str_v text`. Mỗi partition có TOAST table riêng. Với 92 partition đó là 92 TOAST table + 92 TOAST index — phần chi phí catalog mà không ai đếm.

---

### Dọn dẹp (giữ `ts_p` cho Day 33)

```sql
DROP TABLE ts_many;
DROP TABLE ts_p_default;
DELETE FROM ts_p WHERE ts > '2025-08-01';
```

> Lưu ý: `DROP TABLE ts_p_default` bỏ luôn lưới an toàn. Từ giờ INSERT ngoài khoảng 2025-05 → 2025-08 sẽ báo `no partition of relation "ts_p" found for row`. Đúng ý đồ của Day 33 — bạn sẽ phải tự tạo partition mới.
