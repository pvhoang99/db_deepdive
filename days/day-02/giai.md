# Day 02 — Lời giải: Giải phẫu một node trong EXPLAIN ANALYZE

> Bài chữa. Đo thật trên lab `SCALE=1`, sau khi Day 01 đã `ANALYZE` toàn DB. `max_parallel_workers_per_gather = 0` để plan sạch, dễ đọc.

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án | Bẫy |
|---|---|---|---|
| 1 | Postgres chọn kiểu join nào? | **Hash Join** (`device` làm build side) | Đa số đoán nested loop vì "có index trên PK". Sai — xem §2 để hiểu vì sao |
| 2 | Node nào tốn nhiều thời gian nhất? | `Seq Scan on ts_kv` — **324 ms / 375 ms tổng = 87 %** | Đa số chỉ vào `HashAggregate` vì nó "trông nặng". Không phải |

Chốt ngay điều quan trọng: node tốn nhiều thời gian nhất **không phải** node nằm trên cùng, cũng **không phải** node có tên nghe kêu nhất. Phải tính. §3 và §6 dạy cách tính.

---

## §1. Đọc trọn một dòng plan

```
->  Seq Scan on public.ts_kv  (cost=0.00..99458.00 rows=2833 width=0)
                              (actual time=0.165..263.767 rows=3731 loops=1)
      Output: device_id, key_id, ts, dbl_v, bool_v, str_v
      Filter: (ts_kv.device_id = 42)
      Rows Removed by Filter: 4996269
      Buffers: shared hit=27435 read=9523
      I/O Timings: shared read=8.517
```

Bóc từng mảnh:

| Thành phần | Giá trị | Nghĩa |
|---|---|---|
| loại node | `Seq Scan on public.ts_kv` | quét tuần tự, không dùng index |
| `cost` startup | **0.00** | trả được dòng đầu ngay — node **streaming** |
| `cost` total | **99458.00** | chi phí ước lượng để chạy hết node |
| `rows` (đoán) | **2.833** | planner ước lượng |
| `actual rows` | **3.731** | sự thật — lệch **+32 %** |
| `width` | **0** | *(xem ghi chú dưới)* |
| `loops` | **1** | node chạy đúng một lần |
| `actual time` first | **0.165 ms** | tới dòng đầu tiên |
| `actual time` last | **263.767 ms** | tới dòng cuối cùng |
| `Rows Removed by Filter` | **4.996.269** | đọc lên rồi vứt |
| `Buffers` | `hit=27435 read=9523` | tổng 36.958 page = **đúng cả bảng** |

### Ba chi tiết hay bị bỏ qua

**`width=0` không có nghĩa là "dòng rỗng".** Đây là `count(*)` — không cột nào cần đưa lên tầng trên, nên độ rộng hữu ích bằng 0. `width` là **byte trung bình mỗi dòng mà node này phải chuyển lên node cha**, không phải kích thước dòng trên đĩa. Nó quan trọng vì planner dùng `width` để ước lượng bộ nhớ cần cho Sort/Hash — `width` sai thì `work_mem` tính sai thì spill bất ngờ.

**`rows=2833` khác con số 3.500 hôm qua.** Cùng câu SQL, cùng dữ liệu. Vì sao? Hôm qua chạy `ANALYZE ts_kv;` riêng lẻ, hôm nay Day 01 kết thúc bằng `ANALYZE;` toàn DB — **hai lần lấy mẫu khác nhau, ra MCV khác nhau chút ít**. `ANALYZE` lấy mẫu ngẫu nhiên 30.000 dòng, không đọc hết bảng.

→ Điều này đáng nhớ: **chạy `ANALYZE` hai lần liên tiếp trên cùng bảng không đổi có thể cho hai ước lượng khác nhau, và do đó hai plan khác nhau.** Đây là một nguồn "query tự nhiên chậm" hoàn toàn hợp lệ mà không ai đổi gì cả.

**`Rows Removed by Filter: 4.996.269`.** Filter vứt đi **99,925 %** số dòng đọc lên. Chỉ số này là kim chỉ nam của cả tuần 2: nó cao = anh đang trả tiền I/O cho dữ liệu không dùng đến.

---

## §2. Bẫy `loops` — chỗ 90 % người đọc plan sai

### Plan đo được (ép nested loop)

```
Nested Loop  (cost=0.30..148612.61 rows=15905) (actual time=211.405..976.576 rows=16018 loops=1)
  ->  Seq Scan on ts_kv t  (actual time=210.273..373.094 rows=1611191 loops=1)
        Filter: (ts >= '2025-07-01')
        Rows Removed by Filter: 3388809
  ->  Memoize  (cost=0.30..0.32 rows=1) (actual time=0.000..0.000 rows=0 loops=1611191)
        Cache Key: t.device_id
        Hits: 1561192  Misses: 49999  Evictions: 0  Memory Usage: 3544kB
        ->  Index Scan using device_pkey on device d
              (actual time=0.002..0.002 rows=0 loops=49999)
              Index Cond: (id = t.device_id)
              Filter: (type = 'controller')
              Rows Removed by Filter: 1
Execution Time: 977.788 ms
```

### Tính tay thời gian thật

| Node | actual time (mỗi loop) | loops | **thời gian thật** |
|---|---|---|---|
| `Seq Scan on ts_kv` | 373,094 ms | 1 | **373 ms** |
| `Memoize` | 0,000 ms | **1.611.191** | *xem dưới* |
| `Index Scan on device` | 0,002 ms | **49.999** | 0,002 × 49.999 = **100 ms** |

Chỗ này có một cái bẫy **trong cái bẫy**: `Memoize` hiện `actual time=0.000` vì mỗi lần tra cache mất **dưới 1 micro-giây** — dưới độ phân giải mà EXPLAIN in ra. Nhân với 0 vẫn ra 0, và ta mất dấu.

Suy ngược từ tổng thay vì tin con số 0:

```
Execution Time         = 977,8 ms
− Seq Scan             = 373,1 ms
− Index Scan (×49.999) = 100,0 ms
────────────────────────────────
= khoảng 500 ms         ← chi phí Memoize + vòng lặp Nested Loop
```

**500 ms — hơn một nửa query — biến mất khỏi mọi con số `actual time` hiển thị.** Nó là chi phí gọi node con 1,6 triệu lần: mỗi lần vài trăm nano-giây cho tra hash và chuyển ngữ cảnh executor, nhân 1,6 triệu.

### Nếu KHÔNG nhân loops thì kết luận sai thế nào

Đọc ngây thơ: *"`Index Scan` chỉ tốn 0,002 ms, không đáng gì. `Seq Scan` 373 ms mới là thủ phạm. Đi tối ưu Seq Scan."*

Kết luận đúng: `Seq Scan` là 373/978 = **38 %**. **62 % còn lại nằm ở phía nested loop** — thứ mà mọi con số hiển thị đều nói là "0,000 ms". Đi tối ưu Seq Scan là tối ưu nhầm chỗ; cách sửa đúng là **bỏ nested loop đi** (chính là điều planner tự làm khi ta không ép nó).

> **Luật: `actual time` × `loops` mới là thời gian thật. Và khi `loops` rất lớn mà `actual time` hiển thị 0.000, hãy suy ngược từ `Execution Time` — đừng tin số 0.**

### 💡 Bonus: Memoize làm gì ở đây

`Hits: 1.561.192  Misses: 49.999` → tỷ lệ hit **96,9 %**.

Không có Memoize, nested loop này phải làm **1.611.191** lần index lookup vào `device`. Có Memoize, chỉ còn **49.999** lần thật (đúng bằng số device phân biệt), 1,56 triệu lần còn lại tra từ hash table 3,5 MB trong RAM.

Nếu không có Memoize (PG13 trở về trước), ước lượng thô: 1.611.191 × 0,002 ms ≈ **3,2 giây** thay vì 100 ms. **Memoize tiết kiệm ~32 lần cho riêng node đó.** Day 16 đo kỹ.

Chú ý `rows=0` trên Index Scan: hầu hết device **không** phải type `controller` (`Rows Removed by Filter: 1`), nên phần lớn lần tra trả về 0 dòng. Đây là hình dạng của một plan tệ — nó lọc ở sai chỗ.

### 🔧 Tình huống thực tế

**Bối cảnh.** Endpoint `GET /orders?status=pending` trả 50 đơn, mỗi đơn kèm tên khách. p99 = 3,2 giây. Dev nhìn plan thấy `Index Scan using customer_pkey ... actual time=0.003..0.004 rows=1 loops=50000` và kết luận "index chạy tốt mà, 0,004 ms".

**Sự thật.** `loops=50000` → 0,004 × 50.000 = **200 ms** chỉ riêng node đó, chưa kể chi phí vòng lặp. Và `loops=50000` cho một endpoint trả 50 dòng là dấu hiệu **N+1 query đã leo vào tận trong plan** — hoặc join thiếu điều kiện lọc, hoặc ORM sinh subquery tương quan.

**Dấu hiệu nhận biết N+1 trong plan, không cần đọc code:**

| Dấu hiệu | Ý nghĩa |
|---|---|
| `loops` >> số dòng kết quả cuối | join/subquery đang chạy trên tập lớn hơn cần thiết |
| `Nested Loop` với outer là bảng lớn | thứ tự join ngược — bảng lọc mạnh phải làm outer |
| `SubPlan` có `loops > 1000` | subquery tương quan, thường sửa được bằng `LATERAL` hoặc rewrite thành join |
| `Memoize` có `Hits` rất cao | plan đang lặp lại chính nó — Memoize đang cứu, nhưng gốc bệnh vẫn còn |

**Query tìm nghi phạm trên production:**

```sql
-- những câu chạy lâu bất thường so với số dòng trả về
SELECT calls, mean_exec_time, rows/NULLIF(calls,0) AS rows_moi_lan, query
FROM pg_stat_statements
WHERE calls > 100 AND mean_exec_time > 100
ORDER BY mean_exec_time DESC LIMIT 20;
```

`rows_moi_lan` nhỏ (chục dòng) mà `mean_exec_time` lớn (hàng trăm ms) = query đang làm rất nhiều việc để trả rất ít kết quả. Gần như luôn là loops.

---

## §3. Thời gian là tích luỹ, không phải riêng lẻ

### Số đo

**Query A — `count(*)`:**
```
Aggregate    (actual time=441.888..441.888 rows=1 loops=1)
  -> Seq Scan (actual time=0.024..255.729 rows=5000000 loops=1)
Execution Time: 441.910 ms
```

**Query B — `sum(dbl_v) WHERE key_id = 1`:**
```
Aggregate    (actual time=413.575..413.576 rows=1 loops=1)
  -> Seq Scan (actual time=0.010..334.474 rows=1362527 loops=1)
        Filter: (key_id = 1)
        Rows Removed by Filter: 3637473
Execution Time: 413.594 ms
```

### Thời gian riêng của node Aggregate

| | Aggregate (tổng) | Seq Scan | **Aggregate riêng** | dòng phải xử lý |
|---|---|---|---|---|
| A: `count(*)` | 441,9 | 255,7 | **186,2 ms** | 5.000.000 |
| B: `sum(dbl_v)` | 413,6 | 334,5 | **79,1 ms** | 1.362.527 |

### Vì sao B tốn ÍT CPU aggregate hơn, không phải nhiều hơn

Đề bài gợi ý "cái thứ hai tốn nhiều CPU hơn" — số đo nói **ngược lại**, và lý do rất đáng học:

- **A** phải cộng dồn qua **5.000.000** dòng.
- **B** có `Filter: key_id = 1` nên chỉ **1.362.527** dòng lọt lên tới Aggregate. Ít hơn 3,7 lần → Aggregate riêng ít hơn 2,4 lần. Hợp lý.

Nhưng chi phí không biến mất, nó **chuyển chỗ**: `Seq Scan` của B tốn 334 ms so với 256 ms của A, **thêm 78 ms**. Đó chính là 5 triệu lần đánh giá `key_id = 1`.

```
5.000.000 dòng × cpu_operator_cost 0,0025 = 12.500 cost đơn vị
   → xuất hiện đúng trong cost: 99458.00 (có filter) vs 86958.00 (không) = chênh 12.500 ✓
```

> **Bài học: `Filter` không làm query nhẹ đi. Nó chuyển công việc từ node trên xuống node scan. Muốn thật sự nhẹ thì điều kiện phải vào `Index Cond` — tức là không đọc lên ngay từ đầu. Đó là §4.**

Một điểm nữa đáng ghi: `sum(dbl_v)` đắt hơn `count(*)` **trên mỗi dòng** (cộng số thực + kiểm NULL vs tăng biến đếm), nhưng ở đây số dòng ít hơn 3,7 lần nên tổng vẫn thấp hơn. Muốn so công bằng thì phải so trên cùng số dòng.

### Cách tìm nút thắt cho đúng

Đừng tìm node có `actual time` lớn nhất — **node gốc luôn lớn nhất**, vì nó bao gồm mọi node con.

```
thời gian riêng của node = actual time × loops  −  Σ (actual time × loops của các node con)
```

Áp dụng cho §6:

| Node | actual time | loops | tổng | trừ con | **riêng** | % |
|---|---|---|---|---|---|---|
| Limit | 374,2 | 1 | 374,2 | −374,2 | **0,0** | 0 % |
| Sort (top-N) | 374,2 | 1 | 374,2 | −370,7 | **3,5** | 1 % |
| HashAggregate | 370,7 | 1 | 370,7 | −352,1 | **18,6** | 5 % |
| Hash Join | 352,1 | 1 | 352,1 | −324,8−13,9 | **13,4** | 4 % |
| Hash (build) | 13,9 | 1 | 13,9 | −5,5 | **8,4** | 2 % |
| Seq Scan device | 5,5 | 1 | 5,5 | — | **5,5** | 1 % |
| **Seq Scan ts_kv** | **324,8** | 1 | 324,8 | — | **324,8** | **87 %** |

**87 % thời gian nằm ở một node duy nhất: `Seq Scan on ts_kv`.** Mọi tối ưu khác đều là làm màu.

---

## §4. `Index Cond` vs `Filter` — khác biệt sống còn

### Bảng kết quả

| # | Query | Index Cond | Filter | Rows Removed | Buffers | time |
|---|---|---|---|---|---|---|
| 0 | `device_id=7` *(chưa có index)* | — | `device_id=7` | **4.985.846** | 36.958 | **256,0 ms** |
| 1 | `device_id=7` | `device_id = 7` | — | 0 | 11.773 | **22,3 ms** |
| 2 | `device_id=7 AND dbl_v>25` | `device_id = 7` | `dbl_v > 25` | **8.758** | 11.770 | 11,4 ms |
| 3 | `device_id=7 AND key_id=1` *(1 index)* | `device_id = 7` | `key_id = 1` | **10.179** | 11.770 | 11,3 ms |
| 4 | `device_id=7 AND key_id=1` *(composite)* | `device_id=7 AND key_id=1` | — | **0** | **3.776** | **3,9 ms** |

### Đọc bảng này

**Bước 0 → 1: có index.** Buffers 36.958 → 11.773 (**giảm 3,1 lần**), thời gian 256 → 22 ms (**giảm 11,5 lần**). Chú ý thời gian giảm nhiều hơn buffers — vì phần lớn 11.773 page kia đọc từ shared_buffers, còn 36.958 page phải chạm đĩa.

**Bước 3 → 4: đưa `key_id` vào index.** Đây là chỗ đắt giá nhất:

| | 1 index `(device_id)` | composite `(device_id, key_id)` |
|---|---|---|
| `Rows Removed by Filter` | **10.179** | **0** |
| `Heap Blocks: exact` | 11.755 | **3.767** |
| Buffers | 11.770 | **3.776** |
| time | 11,3 ms | **3,9 ms** |

**Buffers giảm 3,1 lần, thời gian giảm 2,9 lần** — chỉ vì chuyển một điều kiện từ `Filter` sang `Index Cond`.

Cơ chế: với index chỉ có `device_id`, Postgres phải lấy **cả 14.154 dòng** của device 7 từ heap lên RAM, rồi vứt 10.179 dòng vì `key_id ≠ 1`. Với composite index, nó nhảy thẳng tới đúng 3.975 dòng cần — **10.179 dòng kia không bao giờ rời khỏi đĩa**.

> **Câu để nhớ: `Index Cond` = index thu hẹp phạm vi đọc. `Filter` = đã đọc lên rồi mới vứt. `Rows Removed by Filter` chính là số dòng anh đã trả tiền I/O mà không dùng.**

### Vì sao không phải `Index Scan` mà là `Bitmap Heap Scan`

Cả 4 query đều ra Bitmap. Vì `correlation` của `device_id` ≈ 0,0012 (đo ở Day 01) — dữ liệu của device 7 nằm **rải khắp 11.755 page** khác nhau. Index Scan thuần sẽ phải nhảy ngẫu nhiên 14.154 lần. Bitmap Heap Scan gom hết TID lại, **sắp theo thứ tự page**, rồi đọc một lượt tuần tự. Day 04 đo tận tay chuyện này.

Chú ý `Heap Blocks: exact=11755` cho 14.154 dòng — trung bình **1,2 dòng mỗi page**. Đọc nguyên page 8 KB để lấy ~1 dòng: đó là cái giá của correlation thấp.

### Cái giá của index

```
 idx_tskv_dev     | 34 MB   (tạo mất 1,58 s)
 idx_tskv_dev_key | 45 MB   (tạo mất 2,05 s)
```

Bảng gốc 289 MB. Hai index = **79 MB = 27 % kích thước bảng**. Và mỗi INSERT giờ phải cập nhật thêm 2 cây B-tree. Day 10 đo cái giá này bằng số.

### 🔧 Tình huống thực tế

**Bối cảnh.** Bảng `alarm` 200 triệu dòng trên production. Query dashboard:

```sql
SELECT * FROM alarm
WHERE tenant_id = $1 AND severity = 'CRITICAL' AND end_ts IS NULL
ORDER BY start_ts DESC LIMIT 50;
```

Index hiện có: `alarm(tenant_id)`. Plan cho thấy:

```
Index Cond: (tenant_id = 42)
Filter: ((severity = 'CRITICAL') AND (end_ts IS NULL))
Rows Removed by Filter: 1994210
```

**Đọc plan:** đọc 2 triệu dòng từ heap để trả về 50. Tỷ lệ lãng phí **40.000 lần**.

**Sửa — thứ tự cột theo quy tắc equality trước, range sau (Day 07):**

```sql
CREATE INDEX CONCURRENTLY idx_alarm_dash
  ON alarm (tenant_id, severity, start_ts DESC)
  WHERE end_ts IS NULL;                          -- partial: chỉ ~5% bảng
```

Ba việc cùng lúc:
1. `tenant_id`, `severity` vào `Index Cond` → `Rows Removed by Filter` về 0
2. `start_ts DESC` trong index → **xoá hẳn node `Sort`**, `LIMIT 50` dừng sau 50 dòng
3. `WHERE end_ts IS NULL` → index chỉ chứa 5 % dữ liệu, nhỏ hơn ~20 lần, nằm gọn trong RAM

`CONCURRENTLY` để không khoá bảng khi tạo (Day 43 nói kỹ cái giá của nó).

**Nguyên tắc rút ra:** khi thấy `Rows Removed by Filter` lớn, đừng vội thêm index mới — hãy hỏi *điều kiện nào đang ở `Filter` mà lẽ ra phải ở `Index Cond`*, rồi mở rộng index sẵn có. Thêm cột vào index cũ thường tốt hơn tạo index thứ hai (Day 10 giải thích vì sao).

---

## §5. Nhận mặt các node

| Query | Node chính | Nó đang làm gì |
|---|---|---|
| `device_id < 100` | **Bitmap Heap Scan** + Bitmap Index Scan | 626.145 dòng — quá nhiều cho index scan, quá ít cho seq scan. Gom TID rồi đọc heap theo thứ tự page |
| `device ORDER BY name LIMIT 5` | **Limit** → **Sort** (top-N heapsort 26 kB) → Seq Scan | không có index trên `name` nên phải sort, nhưng `LIMIT 5` biến nó thành heap 5 phần tử |
| `device JOIN tenant` | **Hash Join** | `tenant` 20 dòng làm build side (hash 9 kB), `device` 50.000 dòng probe. `Batches: 1` = vừa RAM |
| `ts_kv ORDER BY device_id, ts LIMIT 20` | **Incremental Sort** | node hay nhất hôm nay — xem dưới |
| `WHERE ... AND 1=0` | **Result / One-Time Filter: false** | planner phát hiện điều kiện luôn sai, cắt bỏ toàn bộ cây con |

### Node đáng chú ý 1: `Incremental Sort`

```
Limit  (actual time=98.548..98.552 rows=20 loops=1)
  ->  Incremental Sort  (cost=13.70..436317.70 rows=4999953) (actual time=98.547..98.549 rows=20)
        Sort Key: device_id, ts
        Presorted Key: device_id                        <<<
        Full-sort Groups: 1  Sort Method: top-N heapsort  Peak Memory: 26kB
        ->  Index Scan using idx_tskv_dev on ts_kv  (actual rows=107948 loops=1)
```

Index `idx_tskv_dev(device_id)` cho ra dữ liệu **đã sắp theo `device_id`** nhưng chưa sắp theo `ts`. Thay vì sort lại cả 5 triệu dòng, `Incremental Sort` (PG13+) chỉ sort **trong từng nhóm `device_id`** — và vì có `LIMIT 20`, nó dừng sau khi đọc 107.948 dòng thay vì 5 triệu.

Con số biết nói: `cost` total là **436.317** (nếu chạy hết) nhưng `actual time` chỉ **98 ms**. Sự chênh lệch khổng lồ này là vì `LIMIT` dừng sớm — **`actual rows=20` không có nghĩa là planner ước lượng sai 250.000 lần**, chỉ có nghĩa là node bị cắt.

> **Bẫy: khi có `LIMIT`, đừng so `rows` (đoán) với `actual rows` để kết luận planner sai.** Node dưới dừng sớm. Đây là một trong hai ngoại lệ của luật "so hai con số row" ở Day 01.

### Node đáng chú ý 2: `One-Time Filter: false`

Em định tạo tình huống `never executed` nhưng planner thông minh hơn dự tính: gặp `AND 1=0` nó **cắt bỏ toàn bộ cây con ngay lúc plan**, chỉ còn `Result` rỗng, chạy 0,008 ms. Cả `EXISTS` subquery cũng bốc hơi.

Đây gọi là **constant folding** — planner đánh giá các biểu thức hằng ngay lúc lập kế hoạch. Ứng dụng thực tế: điều kiện dạng `WHERE (:filter IS NULL OR col = :filter)` trong query động sẽ được rút gọn tuỳ tham số — nhưng **chỉ với custom plan**. Với generic plan (`$1` chưa biết giá trị), planner không rút gọn được và phải giữ cả hai nhánh. Một lý do nữa để hiểu §1 của Day 01.

Muốn thấy `never executed` thật thì cần một nhánh runtime không chạy tới, ví dụ append/partition bị pruning lúc execute (Day 32) hoặc nhánh `EXISTS` dừng sớm.

### Node đáng chú ý 3: `Hash` build side

```
->  Hash  (cost=1.20..1.20 rows=20) (actual time=0.010..0.011 rows=20 loops=1)
      Buckets: 1024  Batches: 1  Memory Usage: 9kB
```

Planner chọn `tenant` (20 dòng) làm build side, `device` (50.000 dòng) làm probe side. **Luôn build từ bảng nhỏ** — hash table phải vừa `work_mem`. `Batches: 1` = không tràn đĩa. Nếu thấy `Batches: 8` thì hash đã spill; Day 17 đo cái giá.

---

## §6. Mổ xẻ toàn cây

### Bảng mỗi node một dòng

| # | Node | rows đoán | actual rows | loops | rows thật | actual time | **thời gian riêng** |
|---|---|---|---|---|---|---|---|
| 1 | `Seq Scan on device` | 50.000 | 50.000 | 1 | 50.000 | 5,454 | **5,5 ms** |
| 2 | `Hash` (build) | 50.000 | 50.000 | 1 | 50.000 | 13,874 | **8,4 ms** |
| 3 | **`Seq Scan on ts_kv`** | 58.423 | 55.563 | 1 | 55.563 | 324,783 | **324,8 ms** ⬅ |
| 4 | `Hash Join` | 58.423 | 55.563 | 1 | 55.563 | 352,137 | **13,4 ms** |
| 5 | `HashAggregate` | 50.000 | 25.599 | 1 | 25.599 | 370,691 | **18,6 ms** |
| 6 | `Sort` (top-N) | 50.000 | 10 | 1 | 10 | 374,211 | **3,5 ms** |
| 7 | `Limit` | 10 | 10 | 1 | 10 | 374,212 | **0,0 ms** |

`Execution Time: 374,8 ms`. Tổng thời gian riêng: 5,5+8,4+324,8+13,4+18,6+3,5+0,0 = **374,2 ms** ✓ khớp.

### Node tốn nhiều thời gian riêng nhất

**`Seq Scan on ts_kv`: 324,8 ms = 87 % toàn query.**

Chứng minh không cần nhìn `Execution Time`: node này có `actual time=103.946..324.783` và **không có node con nào**. Toàn bộ 324,8 ms là của chính nó. Không node nào khác vượt quá 19 ms.

Vì sao nó tốn thế:
```
Filter: (t.ts >= '2025-06-01' AND t.ts < '2025-06-02')
Rows Removed by Filter: 4.944.437
Buffers: shared hit=31303 read=5655        -- 36.958 page = cả bảng
```

Đọc **toàn bộ 289 MB** để lấy ra 55.563 dòng (1,1 %). Đây là cùng hình dạng bệnh với §4 bước 0 — điều kiện đang ở `Filter` chứ không phải `Index Cond`. Cách chữa: index trên `ts` (Day 07), hoặc BRIN vì `ts` có correlation = 1 (Day 31), hoặc partition theo tháng (Day 32).

Chú ý `actual time` bắt đầu ở **103,9 ms** chứ không phải 0. Đây là dấu hiệu Hash Join đã chạy xong build side trước rồi mới bắt đầu probe.

### So với dự đoán §0

| | Đoán | Thật | Nhận xét |
|---|---|---|---|
| kiểu join | nested loop (vì có PK) | **Hash Join** | có index PK **không** đảm bảo nested loop. Với 55.563 dòng outer, hash join rẻ hơn nhiều — §2 đo được nested loop mất 978 ms cho cùng loại việc |
| node nặng nhất | HashAggregate | **Seq Scan ts_kv** (87 %) | node "nghe kêu" không phải node tốn tiền |

### Điểm lệch đáng chú ý

`HashAggregate`: đoán 50.000, thật 25.599 — lệch 2 lần. Hôm qua (khi `device` chưa ANALYZE) nó đoán **200**, lệch 128 lần. `ANALYZE` đã kéo từ 128 lần xuống 2 lần.

Lệch 2 lần còn lại là vì planner đoán "50.000 device thì có 50.000 tên phân biệt", nhưng chỉ 25.599 device có dữ liệu trong ngày 2025-06-01. Planner không có cách nào biết điều đó — nó không mô hình hoá được tương quan giữa `d.name` và điều kiện lọc trên `t.ts`. Day 13 xử lý lớp vấn đề này.

Ở đây lệch 2 lần vô hại (`Batches: 1`, 3,3 MB, vừa RAM). Nhưng nếu là 200 lần và HashAgg phải spill thì đã khác — Day 19.

---

## Bảng số liệu chính

| Kịch bản | node plan chính | actual time | shared hit/read | ghi chú |
|---|---|---|---|---|
| `count(*) device_id=42` | Seq Scan | 264,2 ms | 27.435 / 9.523 | Rows Removed 4.996.269 |
| nested loop ép (§2) | Nested Loop + Memoize | **977,8 ms** | 176.910 / 10.045 | loops=1.611.191, Memoize hit 96,9 % |
| `count(*)` toàn bảng | Aggregate | 441,9 ms | — | Aggregate riêng 186 ms |
| `sum(dbl_v) key_id=1` | Aggregate + Filter | 413,6 ms | — | Aggregate riêng 79 ms |
| `device_id=7` không index | Seq Scan | 256,0 ms | 36.958 | baseline |
| `device_id=7` có index | Bitmap Heap Scan | **22,3 ms** | 11.773 | nhanh 11,5× |
| `device_id=7 AND key_id=1` 1 index | Bitmap + Filter | 11,3 ms | 11.770 | Rows Removed 10.179 |
| `device_id=7 AND key_id=1` composite | Bitmap, Cond đủ 2 cột | **3,9 ms** | **3.776** | Rows Removed **0** |
| `ORDER BY device_id, ts LIMIT 20` | **Incremental Sort** | 98,6 ms | 8.342 / 26.723 | Presorted Key: device_id |
| join tổng hợp (§6) | Hash Join → HashAgg | 374,8 ms | 32.510 / 5.655 | Seq Scan chiếm 87 % |

---

## Ba điều dễ hiểu sai

| # | Hiểu nhầm | Sự thật |
|---|---|---|
| 1 | "`actual time=0.002` thì node đó không đáng lo" | Nhân `loops`. Ở §2, node "0,000 ms" chiếm ~500/978 ms = **51 %** query |
| 2 | "Node có `actual time` lớn nhất là thủ phạm" | Node gốc **luôn** lớn nhất vì thời gian tích luỹ. Phải trừ thời gian các con |
| 3 | "Thêm điều kiện `WHERE` thì query nhẹ đi" | `Filter` **chuyển** việc xuống node scan, không xoá việc. Chỉ `Index Cond` mới thật sự giảm I/O |

Thêm một điều tinh vi: **hai lần `ANALYZE` liên tiếp trên cùng bảng có thể cho hai ước lượng khác nhau** (2.833 hôm nay vs 3.500 hôm qua) vì ANALYZE lấy mẫu. Đây là nguồn "query tự nhiên đổi plan" hoàn toàn hợp lệ.

---

## Áp dụng vào hệ thật

**1. Quy trình đọc plan — 4 bước, làm đúng thứ tự này:**

```
① Tìm mọi node có loops > 1        -> nhân actual time × loops
② Tính thời gian riêng             -> node − Σ(các con)
③ Xếp hạng theo thời gian riêng    -> tối ưu từ trên xuống
④ Với node nặng nhất, xem Rows Removed by Filter
   -> lớn = cơ hội đưa điều kiện vào Index Cond
```

**2. Chỉ số cảnh báo đưa lên dashboard:** tỷ lệ `Rows Removed by Filter ÷ actual rows`. Trên 10 lần = có việc để làm. Ở §4 bước 0 tỷ lệ này là **352 lần**.

**3. Query tìm nghi phạm loops trên production:**

```sql
SELECT calls,
       round(mean_exec_time::numeric, 1) AS ms_tb,
       round((rows::numeric / NULLIF(calls,0)), 1) AS rows_moi_lan,
       round(total_exec_time::numeric / 1000, 1) AS tong_giay,
       left(query, 90) AS query
FROM pg_stat_statements
WHERE calls > 100
ORDER BY total_exec_time DESC LIMIT 20;
```

Cột `rows_moi_lan` nhỏ + `ms_tb` lớn = làm nhiều để trả ít. Gần như luôn là nested loop với loops lớn.

**4. Với ORM (Hibernate/JPA, GORM):** N+1 cổ điển thì APM bắt được (nhiều query nhỏ). Nhưng N+1 **đã leo vào trong một plan duy nhất** thì APM chỉ thấy *một* câu SQL chậm — chỉ `loops` trong EXPLAIN mới lộ ra. Đây là loại bug tốn nhiều thời gian nhất để tìm nếu không biết đọc `loops`.

**5. Khi thấy `Rows Removed by Filter` lớn, ưu tiên mở rộng index sẵn có thay vì tạo index mới.** Ở §4, thêm một cột vào index cho buffers giảm 3,1 lần. Tạo index thứ hai thì đổi lại 45 MB đĩa + chậm mọi INSERT.

---

## Câu hỏi mở sang các ngày sau

1. Vì sao `device_id=7` ra Bitmap Heap Scan chứ không Index Scan, và ở ngưỡng nào thì đổi? → **Day 04**
2. `Heap Blocks: exact=11755` cho 14.154 dòng — 1,2 dòng/page. Correlation ảnh hưởng thế nào? → **Day 04, Day 31**
3. Composite `(device_id, key_id)` thắng. Nếu đảo thành `(key_id, device_id)` thì sao? → **Day 07**
4. `Memoize` hit 96,9 %. Khi nào nó không giúp được, và cache của nó tốn RAM ở đâu? → **Day 16**
5. `Seq Scan on ts_kv` lọc theo `ts` chiếm 87 % query. BRIN hay partition sẽ giải quyết thế nào? → **Day 31, Day 32**
