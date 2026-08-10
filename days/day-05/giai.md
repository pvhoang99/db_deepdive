# Day 05 — Lời giải: `pg_stat_statements` — tối ưu cái đáng tối ưu + ôn tuần

> Bài chữa. Đo thật trên lab `SCALE=1`. Bench script: [bench.sql](bench.sql) — 20 dạng query, 4.225 lượt gọi.

---

## §1. Chuẩn hoá query (normalization)

```
       queryid        |                      query                       | calls
----------------------+--------------------------------------------------+-------
 -4626323535711655346 | SELECT * FROM device WHERE id = $1               |     3
 -1751211165309445537 | SELECT * FROM device WHERE id = $1 AND is_active |     1
```

**4 câu lệnh gộp thành 2 entry.**

Ba câu đầu (`id = 42`, `id = 99`, `id = 12345`) chỉ khác **hằng số** → hằng số bị thay bằng `$1`, băm ra cùng một `queryid` → gộp thành 1 dòng, `calls = 3`.

Câu thứ tư tách riêng vì nó khác **cấu trúc**: có thêm `AND is_active`. Parse tree khác → `queryid` khác.

### Luật gọn

> **Khác hằng số thì gộp. Khác cấu trúc thì tách.**

Điều này quan trọng hơn vẻ ngoài của nó: nhờ nó mà một endpoint gọi 10 triệu lần chỉ chiếm **một dòng** thay vì làm tràn bảng thống kê.

### ⚠️ Hai cái bẫy của normalization

**1. Query build bằng nối chuỗi thì KHÔNG gộp được.** Nếu ORM/code sinh ra:
```sql
SELECT * FROM device WHERE id IN (1,2,3);
SELECT * FROM device WHERE id IN (1,2,3,4);      -- entry KHÁC
SELECT * FROM device WHERE id IN (1,2,3,4,5);    -- entry KHÁC nữa
```
Mỗi độ dài danh sách `IN` là một entry riêng. Một endpoint có thể sinh ra hàng nghìn entry và **làm tràn `pg_stat_statements.max`**, đẩy các entry quan trọng khác ra ngoài.

Cách sửa: dùng `WHERE id = ANY($1)` với mảng — luôn là một entry duy nhất, bất kể độ dài.

*(Từ PG14 có `pg_stat_statements.track` xử lý danh sách hằng số dài hơn, nhưng đừng dựa vào nó — `= ANY($1)` vẫn là cách đúng.)*

**2. Chỉ khác chữ hoa/thường hay khoảng trắng cũng tách entry.** `SELECT` vs `select` là hai `queryid` khác nhau. Đây là lý do nên để ORM sinh SQL nhất quán.

---

## §2 + §3. `total` hay `mean` — ý quan trọng nhất hôm nay

### ⚠️ Bẫy phương pháp phải xử lý trước khi có số liệu đúng

Bản bench đầu tiên em viết theo gợi ý trong đề:

```sql
SELECT count(*) FROM (
  SELECT (SELECT count(*) FROM ts_kv WHERE device_id = 1 + g % 500)
  FROM generate_series(1, 300) g
) s;
```

Kết quả: **`calls = 1`**. Toàn bộ 20 query đều `calls = 1`, hai bảng top 5 giống hệt nhau, và bài học của §3 biến mất sạch.

Vì sao: **`pg_stat_statements` đếm `calls` theo số CÂU LỆNH gửi lên server, không phải số vòng lặp bên trong một câu.** Chạy 300 lần subquery bên trong một statement vẫn chỉ là **một** statement.

Bản đúng dùng `\gexec` để sinh ra 300 câu lệnh thật:
```sql
SELECT format('SELECT count(*) FROM ts_kv WHERE device_id = %s;', 1 + mod(g, 500))
FROM generate_series(1, 300) g \gexec
```

> **Bài học phương pháp: mô phỏng tải API bằng `generate_series` cho ra số liệu sai về `calls`. Muốn đo đúng, phải gửi đúng số câu lệnh mà production gửi.**

### Top 10 theo `total_exec_time` — nơi tài nguyên bị tiêu

| # | Query | calls | total_ms | mean_ms | **pct** | buffers |
|---|---|---|---|---|---|---|
| 1 | `GROUP BY device_id, key_id, date_trunc('day',ts)` | 1 | 7.576,0 | 7.575,98 | **45,5 %** | 4.970.025 |
| **2** | **`count(*) FROM alarm WHERE device_id=$1 AND end_ts IS NULL`** | **500** | **5.454,1** | **10,91** | **32,7 %** | **1.945.500** |
| 3 | `NOT EXISTS` anti-join | 1 | 1.173,0 | 1.173,04 | 7,0 % | 3.487.934 |
| 4 | `GROUP BY device_id` + avg | 1 | 622,9 | 622,87 | 3,7 % | 36.961 |
| 5 | `max(ts) FROM ts_kv WHERE device_id=$1` | 400 | 600,8 | 1,50 | 3,6 % | 434.270 |
| 6 | `DISTINCT device_id, key_id` | 1 | 431,1 | 431,06 | 2,6 % | 454.547 |
| 7 | `ORDER BY dbl_v LIMIT 100` | 1 | 274,6 | 274,63 | 1,6 % | 37.074 |
| 8 | `ORDER BY name OFFSET 40000` | 1 | 125,7 | 125,66 | 0,8 % | 1.423 |
| 9 | `count(*) FROM ts_kv` | 1 | 100,0 | 99,97 | 0,6 % | 36.958 |
| 10 | `count(*) FROM ts_kv WHERE device_id=$1` | 300 | 54,0 | 0,18 | 0,3 % | 5.157 |

### Top 10 theo `mean_exec_time` — nơi người dùng phải chờ

| # | Query | calls | mean_ms | pct |
|---|---|---|---|---|
| 1 | `GROUP BY 3 cột` | 1 | 7.575,98 | 45,5 % |
| 2 | `NOT EXISTS` anti-join | 1 | 1.173,04 | 7,0 % |
| 3 | `GROUP BY device_id` | 1 | 622,87 | 3,7 % |
| 4 | `DISTINCT` | 1 | 431,06 | 2,6 % |
| 5 | `ORDER BY dbl_v` | 1 | 274,63 | 1,6 % |
| 6 | `OFFSET 40000` | 1 | 125,66 | 0,8 % |
| 7 | `count(*) FROM ts_kv` | 1 | 99,97 | 0,6 % |
| 8 | `join ts_kv × device` | 1 | 51,39 | 0,3 % |
| 9 | `báo cáo alarm theo tenant` | 1 | 48,19 | 0,3 % |
| 10 | `UPDATE alarm` | 1 | 38,03 | 0,2 % |

### Hai bảng khác nhau ở đâu

**Query alarm badge đứng HẠNG 2 theo total (32,7 % toàn bộ tải) nhưng KHÔNG hề xuất hiện trong top 10 theo mean.**

Mean của nó chỉ **10,9 ms** — hạng ~15, trông hoàn toàn vô hại. Nhưng nó chạy **500 lần**.

Đối xứng ngược lại: `count(*) FROM ts_kv WHERE device_id=$1` có mean **0,18 ms** (nhanh nhất bảng) nhưng vẫn lọt top 10 total nhờ 300 lượt gọi.

```
5.454 ms tổng  =  10,9 ms × 500 lượt
7.576 ms tổng  =  7.576 ms × 1 lượt
```

Hai con số tổng gần bằng nhau. Nhưng **bản chất hoàn toàn khác nhau**.

### 💡 Nếu chỉ được sửa MỘT query, sửa cái nào

Đáp án theo luật "xếp theo total" là query #1 (45,5 %). Nhưng số liệu nói khác — và đây là chỗ đáng học nhất hôm nay:

| | #1 GROUP BY 3 cột | #2 alarm badge |
|---|---|---|
| pct | 45,5 % | 32,7 % |
| calls | **1** | **500** |
| Ai chờ | một job báo cáo | **500 request của người dùng** |
| Sửa được bằng index? | **KHÔNG** (xem dưới) | **CÓ, dễ** |
| Ảnh hưởng p99 API | không | **toàn bộ** |

**Em chọn #2.** Ba lý do, đều bằng số:

1. **#1 không sửa được trong luật chơi.** Nó gom nhóm theo `(device_id, key_id, ngày)` trên toàn bộ 5 triệu dòng → 3.762.968 nhóm. Không index nào tránh được việc phải đọc và gom cả bảng. Bằng chứng: ép sang HashAgg + Seq Scan chỉ còn 4.777 ms (nhanh 1,7 lần) nhưng **spill 253 MB đĩa tạm** — đổi vấn đề này lấy vấn đề khác, và cần đổi GUC (bị cấm).

2. **#2 sửa được bằng một index 208 KB**, kết quả dưới đây.

3. **#2 là traffic người dùng.** 500 người chờ 10,9 ms mỗi người. #1 là một job nền — chậm 7,5 giây không ai biết.

> **Bổ sung cho luật của đề: xếp theo `total` để biết tài nguyên đi đâu, nhưng quyết định sửa cái nào còn phải xét `calls` (ai đang chờ) và tính khả thi.** Query total cao mà `calls=1` là job nền; query total cao với `calls` lớn là p99 của khách hàng.

---

## §4. Sửa kẻ đứng đầu

### Chẩn đoán query alarm badge

```
Aggregate  (actual time=22.301..22.302 rows=1 loops=1)
  Buffers: shared read=3983
  ->  Seq Scan on alarm  (cost=0.00..6670.59 rows=13) (actual time=7.199..22.290 rows=6)
        Filter: ((end_ts IS NULL) AND (device_id = 42))
        Rows Removed by Filter: 199994
        Buffers: shared read=3983
```

Dùng đúng bộ công cụ 4 ngày qua:

| Công cụ | Quan sát |
|---|---|
| Day 02 — `Index Cond` vs `Filter` | **Không có `Index Cond`**. Cả hai điều kiện đều ở `Filter` |
| Day 02 — `Rows Removed by Filter` | **199.994** dòng đọc lên rồi vứt, để lấy **6** dòng. Lãng phí **33.332 lần** |
| Day 03 — buffers | 3.983 page = **toàn bộ bảng `alarm`**, cho mỗi lần gọi |
| Day 04 — selectivity | 6/200.000 = **0,003 %**. Sâu trong vùng index thắng tuyệt đối |

Bảng `alarm` có `alarm_pkey(id)` và `idx_alarm_sev(severity)` — **không có index nào trên `device_id`**.

Phân bố: 200.000 alarm, **10.078 active (5,04 %)**, trải trên 44.011 device.

### Cách sửa — partial index

```sql
CREATE INDEX idx_alarm_dev_active ON alarm(device_id) WHERE end_ts IS NULL;
ANALYZE alarm;
```

`WHERE end_ts IS NULL` là mấu chốt: query **luôn** kèm điều kiện đó, nên index chỉ cần chứa 5,04 % số dòng.

### Kết quả — plan

```
Aggregate  (cost=12.50..12.51 rows=1) (actual time=0.030..0.031 rows=1 loops=1)
  Buffers: shared hit=4 read=2
  ->  Index Only Scan using idx_alarm_dev_active on alarm  (actual time=0.026..0.027 rows=6)
        Index Cond: (device_id = 42)
        Heap Fetches: 0
        Buffers: shared hit=4 read=2
```

| | Trước | Sau | Cải thiện |
|---|---|---|---|
| plan | Seq Scan | **Index Only Scan** | |
| `Rows Removed by Filter` | 199.994 | **0** | |
| buffers (1 lượt) | 3.983 | **6** | **664×** |
| actual time (1 lượt) | 22,3 ms | **0,048 ms** | **465×** |
| kích thước index | — | **208 kB** (bảng 31 MB) | 0,67 % |

### Kết quả — chạy lại toàn bộ bench

| | BEFORE | AFTER |
|---|---|---|
| Vị trí query alarm theo total | **#2** | **rớt khỏi top 10** |
| `pct` của nó | **32,7 %** | **0,03 %** |
| `total_exec_time` | 5.454,1 ms | **3,2 ms** |
| `mean_exec_time` | 10,908 ms | **0,0064 ms** |
| buffers tích luỹ | 1.945.500 | **1.507** |
| **Tổng thời gian cả bench** | **16.669,5 ms** | **11.011,6 ms** |
| Thời gian thực (wall clock) | 17,2 s | **11,4 s** |

**Toàn bộ workload nhanh hơn 34 %. Bằng một index 208 KB.**

Tỷ lệ đáng ghi nhớ: index chiếm **0,67 %** kích thước bảng, cắt **32,7 %** tổng tải.

### 🔧 Tình huống thực tế

Đây chính xác là hình dạng của sự cố phổ biến nhất trong hệ IoT/SaaS multi-tenant:

**Bối cảnh.** Badge "số cảnh báo đang mở" hiện trên header mọi trang. Frontend gọi nó mỗi khi đổi trang. 200 người dùng × 40 trang/giờ = **8.000 lượt/giờ**.

**Trước sửa:** 8.000 × 22,3 ms = **178 giây CPU mỗi giờ**, và 8.000 × 31 MB = **248 GB đọc mỗi giờ** — đủ để đẩy mọi thứ khác ra khỏi shared_buffers. Đây mới là thiệt hại thật: nó không chỉ chậm, nó **làm chậm mọi query khác**.

**Sau sửa:** 8.000 × 0,048 ms = 0,4 giây CPU/giờ, 375 MB đọc/giờ.

**Vì sao không ai phát hiện sớm:** APM báo endpoint đó p50 = 25 ms — "nhanh mà". Không ai nhìn `calls × mean`. Chỉ `pg_stat_statements` xếp theo `total_exec_time` mới lộ ra.

---

## §5. Tìm kẻ gây spill

```
                            q                            | calls | temp_blks_written | temp_size
---------------------------------------------------------+-------+-------------------+-----------
 SELECT device_id, count(*), avg(dbl_v) FROM ts_kv GROUP  |     1 |              2609 | 20 MB
 SELECT id, name FROM device ORDER BY name OFFSET $1 LIM  |     1 |               204 | 1632 kB
```

**Kẻ ghi tạm nhiều nhất: `GROUP BY device_id` + `avg(dbl_v)` — 20 MB.**

Nó gom 5 triệu dòng vào ~28.000 nhóm; hash table không vừa `work_mem = 4MB` nên spill.

### Tăng `work_mem` cho session đó thì tiết kiệm được bao nhiêu

Trả lời trung thực: **rất ít, và không đáng làm.**

Query đó tốn 622,9 ms tổng. Ghi + đọc 20 MB đĩa tạm chiếm ước lượng **~40–60 ms** (suy từ Day 03: 312 MB temp tốn ~150 ms → 20 MB tốn ~10 ms ghi + tương tự đọc). Tức **dưới 10 %** thời gian query.

Bài học Day 03 §6 lặp lại y nguyên: **spill hiếm khi là nút thắt chính.** 90 % thời gian là công gom nhóm và tính `avg` thuần tuý.

Còn query #1 (`GROUP BY 3 cột`) thì sao? Nó **không** spill ở plan hiện tại — vì planner chọn `Incremental Sort` + `GroupAggregate`, dùng index có sẵn thứ tự nên chỉ cần bộ nhớ nhỏ. Nhưng cái giá là **4.970.025 lượt truy cập buffer**.

Khi ép sang HashAgg + Seq Scan:
```
HashAggregate  Planned Partitions: 128  Batches: 129  Memory Usage: 9233kB  Disk Usage: 253592kB
Buffers: shared hit=28500 read=8461, temp read=26566 written=57899
Execution Time: 4777.634 ms
```
Nhanh hơn 1,7 lần **nhưng spill 253 MB**. Đây là đánh đổi kinh điển: **ít buffer hơn 134 lần, nhưng đổi lấy 253 MB I/O ghi tạm.**

→ Không có câu trả lời phổ quát. Phải đo cả hai. Day 19 làm bài này tử tế.

---

## §6. Đo cho đúng trên production

```
 pg_stat_statements.max = 10000
 số entry đang dùng     = 28
```

Lab dùng 28/10.000 — thoải mái. Nhưng đây là lab.

### Con số 5000 mặc định có đủ không

Ước lượng cho một service backend thật:

```
số entry ≈ số dạng SQL phân biệt
         = (số endpoint × số query mỗi endpoint)
         + query của migration/job nền
         + query của ORM sinh động (biến thể IN, ORDER BY động, filter tuỳ chọn)
         + query của monitoring/health check
```

Một microservice 40 endpoint, mỗi endpoint 3–5 query → ~150 entry. Nhưng:

- **ORM với filter động** dễ nhân lên 10 lần (mỗi tổ hợp filter = một cấu trúc SQL khác)
- **`IN (...)` nối chuỗi** có thể sinh vô hạn biến thể (bẫy ở §1)
- **Nhiều service dùng chung một DB** → cộng dồn

→ **5000 đủ cho một service sạch sẽ; không đủ cho một hệ nhiều service với ORM sinh SQL động.** Cách kiểm tra:

```sql
-- tỷ lệ lấp đầy — cảnh báo khi > 80%
SELECT count(*) AS dang_dung,
       current_setting('pg_stat_statements.max')::int AS toi_da,
       round(100.0 * count(*) / current_setting('pg_stat_statements.max')::int, 1) AS pct_day
FROM pg_stat_statements;
```

Và quan trọng hơn — kiểm tra đã có entry nào bị đẩy ra chưa:

```sql
-- PG14+: dealloc = số lần entry bị trục xuất. > 0 là đang mất dữ liệu.
SELECT dealloc, stats_reset FROM pg_stat_statements_info;
```

`dealloc > 0` nghĩa là **thống kê của anh đã không còn đầy đủ** — có query đã bị xoá khỏi bảng trước khi anh kịp nhìn.

### Đừng reset bừa trên production

`pg_stat_statements` là số **tích luỹ từ lần reset cuối**. Reset là xoá dữ liệu của cả team.

Cách đúng — **chụp hai lần rồi trừ**:

```sql
-- ảnh chụp 1
CREATE TABLE IF NOT EXISTS pgss_snap AS
  SELECT now() AS chup_luc, * FROM pg_stat_statements;

-- ... chờ 15 phút, chạy tải ...

-- delta: chỉ phần phát sinh trong khoảng đó
SELECT s.query, s.calls - COALESCE(p.calls,0) AS calls_delta,
       round((s.total_exec_time - COALESCE(p.total_exec_time,0))::numeric,1) AS ms_delta
FROM pg_stat_statements s
LEFT JOIN pgss_snap p USING (userid, dbid, queryid)
WHERE s.calls > COALESCE(p.calls,0)
ORDER BY ms_delta DESC LIMIT 20;
```

Đây cũng chính là cách mọi công cụ monitoring (pganalyze, Datadog, PMM) hoạt động.

### Chi phí của `pg_stat_statements`

Thường trích dẫn **~1–3 % overhead**. Đổi lại là khả năng biết query nào đang giết hệ thống. **Luôn đáng bật.** Rủi ro thật không phải overhead mà là:

- cần **restart** để thêm vào `shared_preload_libraries` (không reload được)
- chiếm RAM: `pg_stat_statements.max × ~5 KB`. 10.000 entry ≈ 50 MB.
- `pg_stat_statements.track = all` (lab đang dùng) theo dõi cả câu trong function/procedure — chi tiết hơn nhưng tốn hơn. Production thường để `top`.

---

## §7. Ôn tuần

### A. Ba điều tôi tưởng đúng mà hoá ra sai

**1. "Insert xong thì planner biết bảng có 5 triệu dòng."**

*Sự thật:* `reltuples = -1`, `relpages = 0`. Planner suy ngược từ kích thước file và ra **3.437.000 dòng — sai 31 %**. Cộng thêm selectivity mặc định 0,5 % (hằng số cắm cứng, không liên quan gì tới dữ liệu), ước lượng cuối lệch **4,6 lần**.

*Điều tinh vi hơn:* hai tầng sai **ngược chiều nhau** nên triệt tiêu bớt. Nếu tầng "số dòng bảng" mà đúng thì sai số cuối sẽ **tệ hơn** (6,7 lần thay vì 4,6). → Luôn bóc từng tầng, đừng nhìn con số cuối. *(Day 01 §3)*

**2. "`actual time` là thời gian của node đó, so hai node là biết ai chậm."**

*Sự thật:* sai hai lần. `actual time` là **trung bình mỗi loop**, và nó **đã bao gồm** thời gian mọi node con.

*Bằng chứng:* ở Day 02 §2, node `Memoize` hiển thị `actual time=0.000` với `loops=1.611.191`. Suy ngược từ tổng: nó chiếm **~500/978 ms = 51 % query**. Con số hiển thị là **0**.

Công thức đúng: `thời gian riêng = (actual time × loops) − Σ(actual time × loops của các con)`. *(Day 02 §2, §3)*

**3. "Query nhanh hơn 25 lần nghĩa là tôi tối ưu tốt."**

*Sự thật:* Day 03 §5 dựng đúng cái bẫy đó. 29,8 ms (lạnh) → 1,16 ms (có index, nóng) = "nhanh 25,7 lần". Nhưng tách ra:
- cache nóng lên: 29,8 → 16,8 ms = **1,8 lần, không đổi một dòng code**
- index thật: 16,8 → 1,16 ms = 14,5 lần

Báo cáo "25,7 lần" **thổi phồng gần gấp đôi**.

*Buffers tố cáo ngay:* dòng 1 và dòng 2 có **cùng 3.705 buffer** — công việc không đổi thì không có cải thiện. Chỉ dòng 3 mới giảm xuống 11.

**Bonus thứ tư — điều bất ngờ nhất tuần:** tăng `work_mem` từ 4 MB lên 512 MB (128 lần) chỉ làm query nhanh **10 %**, và mức 64 MB (**vẫn spill**) lại **nhanh hơn** mức 512 MB (hết spill). Spill chỉ chiếm 5 % thời gian; 95 % là công sắp xếp thuần tuý. *(Day 03 §6)*

---

### B. Checklist chẩn đoán query chậm — 8 bước

Dùng được ngay trên production, theo đúng thứ tự này:

```
① CHỌN MỤC TIÊU  (đừng bỏ qua bước này)
   pg_stat_statements xếp theo total_exec_time.
   Xem cả `calls`: total cao + calls lớn = p99 khách hàng;
                   total cao + calls=1   = job nền, ưu tiên thấp hơn.

② KIỂM TRA THỐNG KÊ CÓ TƯƠI KHÔNG
   SELECT last_analyze, last_autoanalyze, n_live_tup, n_dead_tup
   FROM pg_stat_user_tables WHERE relname = '<bảng>';
   NULL hoặc cũ vài ngày trên bảng ghi nhiều = nghi phạm số 1. -> ANALYZE, đo lại.

③ LẤY PLAN THẬT
   EXPLAIN (ANALYZE, BUFFERS, SETTINGS) ...
   Với DML: BEGIN; ... ROLLBACK;  (gõ ROLLBACK trước!)
   Trên primary tải cao: EXPLAIN (GENERIC_PLAN) để không chạy thật.

④ QUY MỌI NODE VỀ CÙNG ĐƠN VỊ
   Node nào có loops > 1  ->  nhân actual time × loops.
   loops >> số dòng kết quả cuối = N+1 đã leo vào plan.

⑤ TÌM NODE TỐN NHIỀU THỜI GIAN RIÊNG NHẤT
   riêng = (time × loops) − Σ(con).
   Đừng chọn node có actual time lớn nhất — node gốc luôn lớn nhất.

⑥ SO rows VỚI actual rows, TỪ LÁ LÊN
   Node ĐẦU TIÊN lệch nhiều lần = gốc bệnh.
   Ngoại lệ: node bị LIMIT cắt sớm thì lệch là bình thường.

⑦ ĐỌC BUFFERS, KHÔNG ĐỌC ms
   - hit+read ≈ relpages  -> đang quét cả bảng
   - Rows Removed by Filter lớn -> điều kiện đang ở Filter, cần vào Index Cond
   - temp_written > 0 -> spill (nhưng đo xem nó chiếm bao nhiêu % trước khi tăng work_mem)
   - Heap Blocks: lossy > 0 -> bitmap thiếu work_mem
   - I/O Timings nhỏ so với tổng -> đừng đi mua đĩa nhanh hơn

⑧ SỬA, RỒI CHỨNG MINH BẰNG BUFFERS
   Đo nóng, >= 3 lần, lấy trung vị, chỉ đổi MỘT biến.
   Báo cáo: buffers trước/sau + pct trong pg_stat_statements trước/sau.
   ms chỉ để kiểm tra chéo.
```

**Bước 0 ngầm định:** nếu chưa có `pg_stat_statements`, bật nó trước. Không có nó thì bước ① là đoán mò.

---

### C. Năm chỉ số lên dashboard + ngưỡng cảnh báo

| # | Chỉ số | Query | Ngưỡng cảnh báo | Vì sao |
|---|---|---|---|---|
| **1** | **Top query theo `total_exec_time` (delta 5 phút)** | delta 2 snapshot, xem §6 | query đứng đầu chiếm **> 25 %** tổng | Chỉ ra ngay nên sửa gì. Ở lab, query #2 chiếm 32,7 % và không ai để ý vì mean chỉ 10,9 ms |
| **2** | **Thống kê cũ** | `now() - greatest(last_analyze, last_autoanalyze)` | **> 24 giờ** trên bảng có `n_mod_since_analyze > 10 %` | Nguồn gốc của mọi "query đột nhiên chậm dù không đổi code" (Day 01) |
| **3** | **`temp_bytes` sinh ra mỗi phút** | `pg_stat_database.temp_bytes` (delta) | **> 1 GB/phút**, hoặc bất kỳ query nào `temp_blks_written > 100k` | Spill vừa chậm vừa cạnh tranh IOPS ghi với WAL. Bật kèm `log_temp_files = 0` |
| **4** | **Tỷ lệ lấp đầy `pg_stat_statements` + `dealloc`** | `pg_stat_statements_info.dealloc` | `dealloc > 0`, hoặc entry **> 80 %** của `max` | `dealloc > 0` = thống kê đã không còn đầy đủ, mọi kết luận từ chỉ số #1 đều không tin được |
| **5** | **`stddev_exec_time / mean_exec_time`** của top 20 query | `pg_stat_statements` | tỷ lệ **> 2** trên query có `calls > 1000` | Lúc nhanh lúc chậm nguy hiểm hơn chậm đều — thường là plan không ổn định (generic plan), lock chờ, hoặc dữ liệu lệch. Đây là chỉ số ít người theo dõi nhất mà lại báo sớm nhất |

Ba chỉ số phụ đáng thêm nếu có chỗ: `shared_blks_read` mỗi giây (ai đang ăn cache của người khác), số connection đang `active` vs `idle in transaction`, và `n_dead_tup` của top 5 bảng (chuẩn bị cho tuần 5).

---

## Hai câu cuối

### A. Vì sao query 5 ms chạy 1 triệu lần nguy hiểm hơn query 2 s chạy 10 lần

Bằng số từ chính bench này:

```
Query alarm badge:  10,9 ms × 500 lượt  =  5.454 ms  =  32,7 % tổng tải
Query GROUP BY:      7.576 ms × 1 lượt  =  7.576 ms  =  45,5 % tổng tải
```

Hai con số tổng cùng bậc độ lớn. Nhưng khác nhau ở **ba điểm quyết định**:

**1. Ai đang chờ.** Query nặng chạy 1 lần: một job nền chờ. Query nhẹ chạy 500 lần: **500 request của người dùng** chờ. Nhân lên quy mô thật (8.000 lượt/giờ) thì đó là toàn bộ p99 của API.

**2. Thiệt hại lan sang người khác.** Query alarm đọc **1.945.500 buffer** tích luỹ = 15 GB. Nó liên tục đẩy dữ liệu nóng của mọi query khác ra khỏi `shared_buffers`. Query GROUP BY chạy một lần thì làm bẩn cache một lần rồi thôi.

**3. Chi phí giữ connection.** 500 lượt × 10,9 ms = 5,5 giây connection bị chiếm. Với pool 20 connection và tải cao, đó là nguồn gốc của "connection pool exhausted" — lỗi mà log ứng dụng báo, còn DB thì trông vẫn "khoẻ".

**Và điểm cuối cùng, thực dụng nhất:** query nhẹ-gọi-nhiều **dễ sửa hơn nhiều**. Ở đây: một index 208 KB cắt 32,7 % tổng tải. Query nặng chạy 1 lần thì phải viết lại logic, đổi schema, hoặc chấp nhận.

Đo được ở đây: **sửa cái chạy nhiều lần → toàn bộ workload nhanh hơn 34 %.**

### B. Kế hoạch bật `pg_stat_statements` trên production

**Cần gì:**
```
# postgresql.conf
shared_preload_libraries = 'pg_stat_statements'   # <- CẦN RESTART, không reload được
pg_stat_statements.max = 10000                    # mặc định 5000, dễ tràn với ORM động
pg_stat_statements.track = top                    # 'all' chi tiết hơn nhưng tốn hơn
pg_stat_statements.track_utility = off            # bỏ qua DDL, đỡ nhiễu
pg_stat_statements.save = on                      # giữ số liệu qua restart
track_io_timing = on                              # để có I/O Timings (kiểm tra overhead trước)
```
```sql
CREATE EXTENSION pg_stat_statements;   -- sau khi restart
```

**Rủi ro và cách giảm:**

| Rủi ro | Mức | Cách xử lý |
|---|---|---|
| Cần restart | **cao** — downtime | Gộp vào cửa sổ bảo trì gần nhất. Nếu có replica: đổi trên replica → failover → đổi trên primary cũ |
| Overhead 1–3 % | thấp | Chấp nhận được. Nếu lo, đặt `track = top` thay vì `all` |
| RAM ~50 MB cho 10.000 entry | thấp | Trừ vào tính toán `shared_buffers` |
| `track_io_timing` có thể đắt trên VM có clock chậm | **trung bình** | Chạy `pg_test_timing` trước. Nếu > 100 ns/lượt thì để `off` |
| Lộ dữ liệu nhạy cảm qua text query | thấp | Hằng số đã bị chuẩn hoá thành `$1`. Nhưng bảng/cột thì lộ — hạn quyền `pg_read_all_stats` |

**Ba việc làm ngay sau khi bật:**
1. Dựng job chụp snapshot 5 phút/lần (§6) — đừng bao giờ reset thủ công
2. Cảnh báo `dealloc > 0`
3. Chạy checklist §7B bước ① lần đầu — gần như chắc chắn sẽ tìm ra một query kiểu "alarm badge"

---

## Bảng số liệu chính

| Kịch bản | calls | total_ms | mean_ms | pct | buffers |
|---|---|---|---|---|---|
| **BEFORE** — GROUP BY 3 cột | 1 | 7.576,0 | 7.576,0 | 45,5 % | 4.970.025 |
| **BEFORE** — alarm badge | 500 | **5.454,1** | 10,908 | **32,7 %** | **1.945.500** |
| **AFTER** — alarm badge | 500 | **3,2** | **0,0064** | **0,03 %** | **1.507** |
| Tổng bench BEFORE | 4.225 | **16.669,5** | — | 100 % | — |
| Tổng bench AFTER | 4.225 | **11.011,6** | — | 100 % | — |
| **Cải thiện toàn workload** | | **−34 %** | | | |
| Index thêm vào | | | | | **208 kB** (0,67 % bảng) |

---

## Hết tuần 1 — bốn công cụ đã có

| Công cụ | Câu hỏi nó trả lời | Bài |
|---|---|---|
| `pg_stat_statements` | **Sửa cái nào?** | Day 05 |
| Đọc plan + nhân `loops` | Chậm ở node nào? | Day 02 |
| `BUFFERS` | Thật sự cải thiện hay chỉ là cache? | Day 03 |
| `rows` vs `actual rows` + `enable_*` | Vì sao planner chọn thế? | Day 01, 04 |

Từ tuần 2 mọi bài đều dựa trên bốn thứ này và sẽ không giải thích lại.

## Câu hỏi mở sang các ngày sau

1. Index `idx_alarm_dev_active` chỉ 208 KB cho 10.078 dòng — cây B-tree nó cao mấy tầng? → **Day 06**
2. Partial index thắng lớn ở §4. Viết `WHERE` hơi khác một chút thì planner còn dùng được không? → **Day 09**
3. Query #1 gom 3,76 triệu nhóm: `Incremental Sort` (4,97 triệu buffer) vs `HashAgg` (spill 253 MB) — chọn cái nào? → **Day 19**
4. `NOT EXISTS` anti-join tốn 3,49 triệu buffer. `EXISTS` / `IN` / `LEFT JOIN IS NULL` có khác không? → **Day 20**
5. `UPDATE alarm` sinh 2,8 MB WAL cho 5.000 dòng — vì sao nhiều thế? → **Day 24, Day 37**
