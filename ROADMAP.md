# Lộ trình 48 ngày — Database cho ra ngô ra khoai (Tier 1)

**Đối tượng:** backend Java/Go 5 năm, mạnh DDD/CQRS/Temporal/outbox, DB đang ở mức "đọc hiểu" chứ chưa "debug được production".
**Mục tiêu cuối:** nhìn `EXPLAIN (ANALYZE, BUFFERS)` là biết vì sao chậm và sửa được — trên chính hệ IoT/telemetry bạn đang chạy.
**Nhịp:** 60–90 phút/ngày × 5 ngày/tuần × ~10 tuần. Ngày 6–7 nghỉ hoặc trả nợ bài.
**Ngoại lệ về thời lượng:** Day 46–48 (capstone) là **90–120 phút mỗi ngày** — nếu ngày thường của bạn chỉ có 60 phút thì để capstone vào cuối tuần.

---

## Cấu trúc mỗi ngày

Mỗi `days/day-XX/README.md` dùng cấu trúc **xen kẽ** — đọc một khái niệm rồi gõ tay kiểm chứng ngay:

```
§0. Đoán trước        <- viết dự đoán vào writeup TRƯỚC khi chạy lệnh nào
§1. Lý thuyết  -> Làm ngay -> Ghi vào writeup
§2. Lý thuyết  -> Làm ngay -> Ghi vào writeup
...
Kết ngày: "bạn đoán sai chỗ nào" + "áp dụng vào hệ thật" + tiêu chí "Đạt khi"
```

Phần mô tả từng ngày ở dưới là **tóm tắt**. Nội dung đầy đủ nằm trong `days/day-XX/README.md`.

## Luật chơi

1. **Mỗi ngày nộp 3 thứ** vào `days/day-XX/`:
   - `lab.sql` — toàn bộ câu lệnh bạn chạy (kể cả cái sai)
   - `output.txt` — output thật, dán nguyên (`\o output.txt` trong psql)
   - `writeup.md` — trả lời câu hỏi của ngày hôm đó, bằng chữ của bạn
2. **Không tra đáp án trước khi đoán.** Mỗi bài đều có bước "đoán trước khi chạy" — viết dự đoán vào writeup rồi mới chạy. Chỗ bạn đoán sai chính là chỗ học được.
3. **Nộp bài:** gõ `/review-bai` (mặc định review ngày mới nhất) hoặc `/review-bai 07`.
4. **Con số, không tính từ.** "Nhanh hơn" là không đủ. "p95 từ 840ms → 12ms, shared read 41k → 388 buffer" mới là đủ.
5. Cứ 5 ngày có 1 ngày ôn — bắt buộc, không được bỏ để chạy tiếp bài mới.

## Dựng lab (làm 1 lần)

```bash
make up
make seed SCALE=1      # 50k device, 5M ts_kv, 200k alarm — mất ~2-4 phút
make psql
```

Cấu hình trong `docker-compose.yml` **cố ý để nhỏ** (`work_mem=4MB`, `shared_buffers=256MB`) để bạn nhìn thấy external sort, hash spill, bitmap scan. Đừng tăng lên cho tới khi bài tập bảo tăng.

Reset sạch khi cần: `make nuke && make up && make seed 1`

---

# TUẦN 1 — Công cụ đo. Không có bước này thì mọi thứ sau là mê tín.

### Day 01 — Dựng lab, `\timing`, plan đầu tiên
**Học:** EXPLAIN vs EXPLAIN ANALYZE (cái sau *thực sự chạy* query), cấu trúc cây plan đọc từ trong ra ngoài, đơn vị `cost` là gì (không phải ms).
**Bài tập:**
1. Dựng lab, seed xong.
2. Chạy `EXPLAIN` (không ANALYZE) cho: `SELECT count(*) FROM ts_kv WHERE device_id = 42;` — ghi lại `rows` planner dự đoán.
3. Chạy lại với `EXPLAIN (ANALYZE, BUFFERS)`. So `rows=` (dự đoán) với `actual rows=`.
4. Chạy `ANALYZE ts_kv;` rồi lặp lại bước 2-3.
**Writeup trả lời:** Trước `ANALYZE`, planner nghĩ bảng có bao nhiêu row? Vì sao nó nghĩ vậy khi bảng vừa được insert 5 triệu dòng? Sau `ANALYZE` sai số còn bao nhiêu %?
**Đạt khi:** giải thích được `reltuples` đến từ đâu và vì sao autovacuum chưa kịp cập nhật.

### Day 02 — Giải phẫu một dòng EXPLAIN ANALYZE
**Học:** `cost=start..total`, `rows`, `width`, `actual time=first..last`, `loops`, và cái bẫy chết người: **`actual time` là thời gian MỘT lần loop, phải nhân với `loops`**.
**Bài tập:** chạy 3 query dưới, với mỗi node trong plan viết ra: node này nhận gì từ con, trả ra bao nhiêu row, tốn bao nhiêu ms *tổng*.
```sql
SELECT d.name, count(*) FROM ts_kv t JOIN device d ON d.id=t.device_id
WHERE t.ts >= '2025-06-01' AND t.ts < '2025-06-02' GROUP BY d.name ORDER BY 2 DESC LIMIT 10;
```
+ 1 query có nested loop với `loops > 1000` (tự tìm cách tạo ra).
**Writeup:** chỉ ra node tốn nhiều thời gian nhất và chứng minh bằng phép nhân `actual time × loops`. Vì sao tổng thời gian các node con lại lớn hơn/nhỏ hơn node cha?
**Đạt khi:** tính tay ra được thời gian thật của node nested-loop inner mà không nhìn dòng cuối.

### Day 03 — `BUFFERS`: đọc I/O thay vì đọc thời gian
**Học:** page 8KB, `shared hit` (trong shared_buffers) vs `read` (từ OS/đĩa) vs `dirtied`/`written`, `temp read/written` (= spill), `I/O Timings`.
**Bài tập:**
1. Restart container để cache lạnh, chạy 1 query nặng, ghi `shared read`.
2. Chạy **lại y hệt** ngay lập tức, ghi `shared hit`. Giải thích chênh lệch thời gian.
3. Dùng `pg_prewarm('ts_kv')` rồi đo lại.
4. Tính: query đọc bao nhiêu MB? So với `pg_total_relation_size('ts_kv')`.
**Writeup:** vì sao **buffers là thước đo tin cậy hơn ms** khi so sánh 2 plan? Nêu 1 tình huống ms giảm nhưng query thực chất *không* tốt hơn.
**Đạt khi:** bạn ngừng dùng ms làm bằng chứng chính.

### Day 04 — Bốn kiểu truy cập bảng
**Học:** Seq Scan, Index Scan, Index Only Scan, Bitmap Heap Scan (+ `Recheck Cond`, `Heap Blocks: exact/lossy`), và **vì sao có index mà planner vẫn seq scan**.
**Bài tập:** tạo `CREATE INDEX ON ts_kv(device_id);` rồi chạy cùng 1 query với `device_id` lọc ra 1 row / 1.000 row / 500.000 row. Với mỗi mức, ép cả 4 kiểu bằng `SET enable_seqscan=off` / `enable_bitmapscan=off` / `enable_indexscan=off` và ghi lại buffers + time của từng kiểu.
**Writeup:** vẽ bảng 3 mức × 4 kiểu (time, shared hit/read). Tại điểm nào seq scan bắt đầu thắng index scan? Con số selectivity đó là bao nhiêu %? Vì sao bitmap scan nằm giữa?
**Đạt khi:** trả lời được "index có mà không dùng" bằng chi phí random I/O chứ không bằng "planner nó ngu".

### Day 05 — `pg_stat_statements` + ôn tuần
**Học:** đo cả hệ thống thay vì đoán từng query. `total_exec_time` vs `mean_exec_time` vs `calls`, `pg_stat_statements_reset()`.
**Bài tập:** viết `bench.sh` chạy ~20 query hỗn hợp; reset stats, chạy bench, rồi lấy top 5 theo `total_exec_time` và top 5 theo `mean_exec_time`.
**Writeup:** hai bảng top 5 khác nhau ở đâu? **Cái nào nên tối ưu trước và vì sao?** + tổng kết tuần: 3 điều bạn tưởng đúng mà hoá ra sai.
**Đạt khi:** phát biểu được vì sao query 5ms chạy 1 triệu lần nguy hiểm hơn query 2s chạy 10 lần.

---

# TUẦN 2 — Index B-tree: từ "biết đánh index" lên "biết index nằm ở đâu trên đĩa"

### Day 06 — Bên trong B-tree
**Học:** meta page / root / internal / leaf, fanout, độ cao cây, high key, `pageinspect`.
**Bài tập:** trên index `ts_kv(device_id)`: dùng `bt_metap()` xem `level`, `root`; `bt_page_stats()` vài page; `bt_page_items()` đọc entry leaf. Tính fanout thực tế.
**Writeup:** cây cao mấy tầng? Một lần index lookup tốn tối thiểu bao nhiêu page read? Nếu bảng to gấp 100 lần thì cây cao thêm mấy tầng — và điều đó nói gì về khả năng scale của B-tree?

### Day 07 — Composite index & quy tắc leftmost
**Học:** thứ tự cột quyết định tất cả; `Index Cond` vs `Filter` (khác biệt sống còn); equality-first-then-range.
**Bài tập:** tạo cả `(device_id, ts)` và `(ts, device_id)`. Chạy 4 dạng query: `device_id=? AND ts BETWEEN`, chỉ `ts BETWEEN`, chỉ `device_id=?`, `device_id IN (...) AND ts>?`. Ghi index nào được chọn, buffers bao nhiêu.
**Writeup:** với mỗi query chỉ rõ điều kiện nào vào `Index Cond`, cái nào rơi xuống `Filter`, và **`Rows Removed by Filter`** là bao nhiêu. Quy tắc chọn thứ tự cột bạn rút ra là gì?
**Đạt khi:** viết được quy tắc bằng 2 câu và áp dụng đúng cho bảng `alarm`.

### Day 08 — Index-only scan, `INCLUDE`, visibility map
**Học:** vì sao index-only scan vẫn phải đụng heap (`Heap Fetches`), vai trò của visibility map và VACUUM.
**Bài tập:** tạo `(device_id, ts) INCLUDE (dbl_v)`, chạy query chỉ select 3 cột đó → xem `Heap Fetches`. Chạy `VACUUM ts_kv;` rồi đo lại. Sau đó `UPDATE` 10k row rồi đo lần nữa.
**Writeup:** `Heap Fetches` thay đổi thế nào qua 3 lần đo? Giải thích bằng visibility map. Khi nào `INCLUDE` hơn hẳn việc nhét cột vào key?

### Day 09 — Partial index & expression index
**Học:** index chỉ trên phần dữ liệu bạn thật sự query; điều kiện để planner *chịu* dùng partial index.
**Bài tập:**
1. `alarm` có ~5% row `end_ts IS NULL`. So sánh full index vs `WHERE end_ts IS NULL` về kích thước và tốc độ.
2. Thử query `WHERE end_ts IS NULL AND severity='CRITICAL'` — partial index có được dùng không? Còn `WHERE end_ts IS NULL OR ...`?
3. Expression index: `lower(name)`, và `((meta->>'model'))`.
**Writeup:** partial index tiết kiệm bao nhiêu % dung lượng? Nêu 1 trường hợp bạn viết `WHERE` hơi khác một chút và planner **không** dùng được partial index — vì sao?
**Áp dụng thật:** liệt kê 2 chỗ trong hệ ThingsBoard/service của bạn dùng được partial index.

### Day 10 — Index bloat, REINDEX, và cái giá của index — ôn tuần
**Học:** mỗi index làm chậm write bao nhiêu; bloat sinh ra thế nào; `pgstattuple`, `REINDEX CONCURRENTLY`, `CREATE INDEX CONCURRENTLY`.
**Bài tập:** đo thời gian insert 200k row vào `ts_kv` khi có 0 / 1 / 3 / 5 index. Sau đó update ngẫu nhiên 30% bảng, đo `pgstattuple` trên index trước/sau, rồi `REINDEX` và đo lại.
**Writeup:** biểu đồ (bảng số) write throughput theo số index. Bloat lên bao nhiêu %? Ôn tuần: viết checklist 6 dòng "khi nào tôi thêm index, khi nào tôi từ chối".

---

# TUẦN 3 — Planner & statistics: nơi 90% ca "index có mà không dùng" nằm

### Day 11 — Planner nhìn thấy gì
**Học:** `pg_stats`: `null_frac`, `n_distinct`, `most_common_vals/freqs`, `histogram_bounds`, `correlation`.
**Bài tập:** đọc `pg_stats` cho `device.type` (lệch 90/9/1), `device.tenant_id`, `ts_kv.ts`, `ts_kv.device_id`. Với mỗi cột, **tự tính tay** số row planner sẽ ước lượng cho 1 predicate, rồi so với `EXPLAIN`.
**Writeup:** 4 phép tính tay + sai số so với planner. Vì sao `type='sensor'` ước lượng chính xác còn `device_id=12345` thì không?

### Day 12 — Khi ước lượng sai thì plan nổ
**Học:** sai số ước lượng lan truyền qua join như thế nào; `n_distinct` sai; `default_statistics_target`.
**Bài tập:** dựng 1 query 3 bảng mà planner ước lượng lệch > 100×, xem nó chọn nested loop và chạy rất lâu. Sửa bằng cách tăng `default_statistics_target` cho cột đó + `ANALYZE`, đo lại.
**Writeup:** con số estimate/actual ở từng node trước và sau. Vì sao sai số ở node lá lại nguy hiểm gấp bội ở node gốc?

### Day 13 — Cột tương quan & `CREATE STATISTICS`
**Học:** giả định độc lập của planner và chỗ nó sai; `dependencies`, `ndistinct`, `mcv`.
**Bài tập:** `WHERE region='ap-southeast' AND country='VN'` — hai cột này phụ thuộc hàm (dữ liệu seed cố ý làm vậy). Xem planner ước lượng bao nhiêu vs thực tế. Tạo `CREATE STATISTICS ... (dependencies, mcv) ON region, country FROM device`, `ANALYZE`, đo lại.
**Writeup:** estimate trước/sau. Trong schema công việc thật của bạn, chỉ ra 1 cặp cột tương quan tương tự (gợi ý: `city`/`district`, `status`/`type`, `tenant_id`/`region`).

### Day 14 — Cost model: mấy con số GUC thực sự làm gì
**Học:** `seq_page_cost`, `random_page_cost`, `cpu_tuple_cost`, `effective_cache_size`.
**Bài tập:** lấy query ở Day 04 tại điểm hoà vốn. Đổi `random_page_cost` 4.0 → 1.1 (SSD) và `effective_cache_size` 1GB → 4GB, xem plan lật ở đâu. **Tự tính cost của Seq Scan bằng tay** từ `relpages`/`reltuples` và so với số planner in ra.
**Writeup:** công thức bạn dùng, con số bạn tính, con số planner in. Với server SSD thật của bạn thì `random_page_cost` nên để bao nhiêu và vì sao?

### Day 15 — Ôn tuần: chẩn đoán mù
**Bài tập:** tôi sẽ đưa bạn 3 plan xấu (trong `days/day-15/cases/`); với mỗi cái, chỉ nhìn plan, chẩn đoán nguyên nhân và đề xuất cách sửa **trước khi** chạy. Rồi chạy để kiểm chứng.
**Writeup:** chẩn đoán của bạn vs kết quả thật. Tỷ lệ đúng bao nhiêu / 3.

---

# TUẦN 4 — Join, sort, aggregate: nơi work_mem quyết định sống chết

### Day 16 — Nested Loop
**Học:** khi nào NL là đúng (outer nhỏ + inner có index), `Materialize`, memoization (`Memoize` node ở PG14+).
**Bài tập:** ép nested loop trên join `ts_kv × device` ở 3 mức kích thước outer. Bật/tắt `enable_memoize` và đo. Xem `Cache Hits/Misses` của node Memoize.
**Writeup:** ngưỡng outer rows mà NL còn hợp lý. Memoize cứu được bao nhiêu %?

### Day 17 — Hash Join & work_mem
**Học:** build side vs probe side, `Buckets`, `Batches`, `Memory Usage`, spill ra đĩa khi `Batches > 1`.
**Bài tập:** join lớn với `work_mem` = 1MB / 4MB / 64MB / 256MB. Ghi `Batches`, `Memory Usage`, `temp read/written`, thời gian.
**Writeup:** bảng 4 mức. Vì sao `Batches: 8` đắt hơn `Batches: 1` nhiều hơn tỷ lệ 8×? Planner chọn bảng nào làm build side và dựa vào gì?
**Cảnh báo cần hiểu:** `work_mem` là **per node per connection** — tính thử worst case với 100 connection.

### Day 18 — Merge Join & Sort
**Học:** quicksort in-memory vs external merge sort, `Sort Method:`, `Disk: xxx kB`, khi nào index cứu được sort.
**Bài tập:** `ORDER BY` trên 5M row với work_mem nhỏ → xem `external merge Disk`. Tăng work_mem tới khi thành `quicksort Memory`. Rồi tạo index đúng thứ tự để **xoá hẳn node Sort**.
**Writeup:** 3 phương án (sort đĩa / sort RAM / index) — time + buffers + temp. Khi nào bạn chọn index thay vì tăng work_mem?

### Day 19 — Aggregation
**Học:** HashAggregate vs GroupAggregate, hash spill (PG13+), `Partial`/`Finalize` khi parallel.
**Bài tập:** `GROUP BY device_id` (50k nhóm) và `GROUP BY (device_id, key_id, date_trunc('hour',ts))` (rất nhiều nhóm) với work_mem nhỏ. Quan sát `Planned Partitions` / `Disk Usage` của HashAgg. Bật `max_parallel_workers_per_gather` và xem plan đổi.
**Writeup:** vì sao trước PG13 query kiểu này có thể giết server? Parallel giúp bao nhiêu và **khi nào nó không giúp**?

### Day 20 — Join order, CTE, subquery — ôn tuần
**Học:** `join_collapse_limit`, GEQO, CTE materialized vs not (đổi lớn ở PG12), `LATERAL`, semi/anti join (`EXISTS` vs `IN` vs `LEFT JOIN ... IS NULL`).
**Bài tập:** viết cùng 1 nhu cầu ("device chưa từng gửi telemetry trong 7 ngày qua") bằng 4 cách trên, so plan + thời gian. Thêm 1 query có CTE, chạy với `MATERIALIZED` và `NOT MATERIALIZED`.
**Writeup:** bảng 4 cách. Cách nào thắng và vì sao? Ôn tuần: checklist "gặp query chậm, tôi kiểm tra theo thứ tự nào" (tối đa 8 bước).

---

# TUẦN 5 — MVCC ở mức vận hành: chỗ "hiểu sơ sơ" thành "sửa được sự cố"

### Day 21 — Nhìn tận mắt xmin/xmax
**Học:** tuple header, `xmin`/`xmax`/`ctid`, snapshot, `txid_current()`, vì sao UPDATE = DELETE + INSERT.
**Bài tập:** bảng nhỏ 5 row: `SELECT ctid, xmin, xmax, * FROM t;` trước/sau INSERT, UPDATE, DELETE, ROLLBACK. Dùng `pageinspect` (`heap_page_items`) xem tuple chết còn nằm trong page.
**Writeup:** vẽ lại (bằng chữ) một page sau 3 lần UPDATE cùng 1 row. Row đó chiếm bao nhiêu chỗ trên đĩa?

### Day 22 — Dead tuple & bloat
**Học:** `n_live_tup`/`n_dead_tup`, `pg_stat_user_tables`, `pgstattuple`, vì sao DELETE không trả lại đĩa cho OS.
**Bài tập:** update 100% bảng `device` 5 lần liên tiếp (tắt autovacuum trước). Đo kích thước bảng sau mỗi vòng. Rồi `VACUUM` → đo. Rồi `VACUUM FULL` → đo.
**Writeup:** bảng phình mấy lần? VACUUM lấy lại được gì, VACUUM FULL lấy lại được gì, và **VACUUM FULL khoá gì** — vì sao không được chạy trên production giờ cao điểm?

### Day 23 — Autovacuum
**Học:** `autovacuum_vacuum_scale_factor` + `threshold`, vì sao mặc định 20% là **thảm hoạ với bảng lớn**, `autovacuum_vacuum_cost_delay`, per-table override.
**Bài tập:** tính tay: với `ts_kv` 5M row, mặc định thì autovacuum chạy sau bao nhiêu dead tuple? Đặt lại `ALTER TABLE ts_kv SET (autovacuum_vacuum_scale_factor=0.01)` và quan sát log (`log_autovacuum_min_duration=0` đã bật sẵn).
**Writeup:** con số mặc định vs con số bạn chọn cho bảng 5M / 500M row. Đọc log autovacuum và giải thích từng dòng.

### Day 24 — HOT update & fillfactor
**Học:** HOT chain, điều kiện để update là HOT (không đụng cột được index + còn chỗ trong page), `fillfactor`, `n_tup_hot_upd`.
**Bài tập:** 2 bảng giống hệt, 1 có `fillfactor=70`. Update cột **không** được index 500k lần trên cả hai, so `n_tup_hot_upd/n_tup_upd`, kích thước bảng, kích thước index. Rồi lặp lại nhưng update cột **có** index.
**Writeup:** tỷ lệ HOT ở 4 kịch bản. Quy tắc: khi nào đặt fillfactor < 100? Liên hệ với bảng nào trong hệ của bạn.

### Day 25 — Freeze & XID wraparound — ôn tuần
**Học:** 32-bit XID, `age(relfrozenxid)`, `autovacuum_freeze_max_age`, "aggressive vacuum", tình huống database bị dừng ghi để tránh wraparound.
**Bài tập:** đo `age(relfrozenxid)` mọi bảng; viết query cảnh báo (bảng nào gần `autovacuum_freeze_max_age` nhất, % bao nhiêu). Đọc 1 postmortem wraparound công khai (Sentry hoặc Mailchimp) và tóm tắt.
**Writeup:** query monitoring của bạn + ngưỡng cảnh báo bạn sẽ đặt. Ôn tuần: 5 chỉ số MVCC bạn sẽ đưa lên dashboard.

---

# TUẦN 6 — Isolation & locking: tự tay tái hiện mọi anomaly

Từ đây dùng 2 terminal: `make s1` và `make s2`.

### Day 26 — 3 isolation level của Postgres
**Học:** Read Committed (mặc định) / Repeatable Read / Serializable — và **Postgres không có Read Uncommitted thật**. Snapshot lấy lúc nào ở mỗi level.
**Bài tập:** với mỗi level, chạy kịch bản 2 session: S1 đọc → S2 ghi+commit → S1 đọc lại trong cùng transaction. Ghi kết quả.
**Writeup:** bảng 3 level × (non-repeatable read? phantom?). Ở Read Committed, hai câu `SELECT` trong cùng transaction có thể thấy dữ liệu khác nhau — điều đó phá vỡ giả định nào trong code business của bạn?

### Day 27 — Lost update, write skew, phantom
**Học:** ba anomaly kinh điển, cái nào level nào chặn được.
**Bài tập:** tái hiện đủ 3:
1. **Lost update:** hai session cùng `SELECT balance` → `UPDATE balance = x - 100`.
2. **Write skew:** ràng buộc "luôn phải còn ≥1 bác sĩ trực" — hai người cùng xin nghỉ. Chạy ở Repeatable Read (vẫn hỏng!) rồi Serializable (bị abort).
3. **Phantom:** đếm rồi insert.
**Writeup:** với mỗi anomaly: kịch bản, level nào chặn, và **cách sửa ở tầng application** (bạn dùng DDD/CQRS — sửa bằng optimistic lock version column, pessimistic lock, hay serializable + retry?).
**Đạt khi:** giải thích được vì sao Repeatable Read của Postgres chặn được phantom (snapshot isolation) nhưng vẫn không chặn write skew.

### Day 28 — Lock tường minh & hàng đợi
**Học:** `SELECT FOR UPDATE` / `FOR NO KEY UPDATE` / `FOR SHARE`, `NOWAIT`, `SKIP LOCKED`, advisory lock, ma trận xung đột lock bảng.
**Bài tập:** dựng job queue trên bảng `alarm` bằng `FOR UPDATE SKIP LOCKED`, chạy 4 worker song song (4 psql hoặc 1 script Go), chứng minh không worker nào lấy trùng job. So với cách dùng `pg_advisory_xact_lock`.
**Writeup:** vì sao `SKIP LOCKED` là cách đúng để làm queue trong DB? Nó thay thế được Kafka/outbox ở quy mô nào và **vỡ ở đâu**?

### Day 29 — Deadlock
**Học:** deadlock detector, `deadlock_timeout`, `pg_locks`, `pg_blocking_pids()`, lock queue (kẻ đến sau chặn cả kẻ nhẹ hơn).
**Bài tập:** cố tình tạo deadlock 2 session rồi 3 session (vòng tròn). Đọc log Postgres, xác định câu lệnh nào là nạn nhân. Viết query "ai đang chặn ai" từ `pg_locks` + `pg_stat_activity`.
**Writeup:** log deadlock giải thích từng dòng. Quy tắc phòng deadlock bạn sẽ áp vào code Java/Go (gợi ý: thứ tự lock nhất quán, transaction ngắn, tránh lock leo thang). Kèm query monitoring dùng được ngay.

### Day 30 — SERIALIZABLE + retry — ôn tuần
**Học:** SSI (Serializable Snapshot Isolation), predicate lock, `40001 serialization_failure`, chi phí thật.
**Bài tập:** cùng 1 workload tranh chấp, đo throughput 3 cách: (a) `FOR UPDATE`, (b) optimistic version column + retry, (c) `SERIALIZABLE` + retry. Đo throughput và tỷ lệ retry ở 4/16/64 client song song.
**Writeup:** bảng kết quả. Bạn chọn cách nào cho use case nào? Ôn tuần: **linearizability ≠ serializability** — viết 3 câu phân biệt.

---

# TUẦN 7 — Time-series & IoT: đúng bài toán bạn đang chạy

### Day 31 — BRIN cho telemetry
**Học:** BRIN lưu min/max theo block range, phụ thuộc hoàn toàn vào `correlation`, `pages_per_range`, khi nào BRIN vô dụng.
**Bài tập:** so B-tree(ts) vs BRIN(ts) trên `ts_kv`: kích thước index, thời gian query 1 ngày / 1 tuần / 1 giờ. Rồi **phá correlation** (`CLUSTER` theo device_id hoặc update xáo trộn) và đo lại BRIN.
**Writeup:** BRIN nhỏ hơn B-tree bao nhiêu lần? Sau khi phá correlation thì chậm đi bao nhiêu lần? Bảng nào trong hệ bạn dùng được BRIN?

### Day 32 — Declarative partitioning
**Học:** RANGE partition theo tháng, partition pruning lúc plan vs lúc execute, `enable_partition_pruning`, constraint exclusion.
**Bài tập:** tạo `ts_kv_p` partition theo tháng, copy dữ liệu sang. So plan+time với bảng phẳng cho: query 1 ngày, query cross-month, query có `ts` trong biến (prepared statement — pruning lúc nào?).
**Writeup:** `Subplans Removed:` bao nhiêu? Vì sao pruning không xảy ra khi điều kiện `ts` đến từ subquery/parameter? Partition có làm query *chậm* đi trong trường hợp nào không?

### Day 33 — Vận hành partition & retention
**Học:** `ATTACH`/`DETACH PARTITION` (+ `CONCURRENTLY`), tạo partition tương lai, index trên partitioned table, giới hạn của unique constraint.
**Bài tập:** viết script (SQL hoặc Go) tự tạo partition tháng tới và `DETACH` + `DROP` partition cũ hơn 90 ngày. Đo thời gian `DROP` partition vs `DELETE FROM ts_kv WHERE ts < ...` (và đo bloat sau DELETE).
**Writeup:** con số 2 cách xoá. Đây là lý lẽ mạnh nhất cho partitioning — phát biểu nó bằng 2 câu.

### Day 34 — jsonb & GIN
**Học:** `jsonb_ops` vs `jsonb_path_ops`, `@>` vs `->>`, vì sao B-tree trên expression đôi khi thắng GIN, kích thước và chi phí ghi của GIN, `fastupdate`/pending list.
**Bài tập:** trên `device.meta`: query `meta @> '{"model":"TH-100"}'`, `meta->>'model' = 'TH-100'`, `meta->'tags' ? 'critical'`. Thử 3 loại index (GIN jsonb_ops, GIN jsonb_path_ops, B-tree expression) — so kích thước, tốc độ đọc, tốc độ ghi.
**Writeup:** bảng 3×3. Quy tắc chọn. Trong hệ bạn, chỗ nào đang dùng jsonb mà nên tách thành cột thật?

### Day 35 — Ôn tuần: chọn mô hình lưu telemetry
**Bài tập:** viết so sánh có số liệu (từ chính lab của bạn) cho 3 lựa chọn lưu telemetry: Postgres bảng phẳng + BRIN, Postgres partition + B-tree, Cassandra (LSM, cái bạn đang chạy). Ghi rõ: write throughput, query 1 ngày, query 1 tháng, chi phí xoá dữ liệu cũ, chi phí vận hành.
**Writeup:** khuyến nghị của bạn cho hệ thật, kèm điều kiện lật ngược ("nếu X vượt Y thì đổi sang Z").

---

# TUẦN 8 — Vận hành: cái tách "biết SQL" khỏi "giữ được production"

### Day 36 — Connection pooling
**Học:** process-per-connection của Postgres, chi phí thật mỗi connection, vì sao 500 connection giết server, pgbouncer 3 chế độ (session/transaction/statement) và cái gì hỏng ở transaction mode (prepared statement, advisory lock, `SET`).
**Bài tập:** benchmark `pgbench` với 10 / 50 / 200 / 500 client trực tiếp vs qua pgbouncer (thêm service vào compose). Vẽ bảng throughput + p99.
**Writeup:** đường cong throughput đạt đỉnh ở đâu và vì sao **sau đỉnh thì tăng client làm giảm throughput** (Little's law, queueing). Pool size bạn sẽ đặt cho service Java/Go của bạn = bao nhiêu, theo công thức nào?

### Day 37 — WAL & checkpoint
**Học:** WAL record, `full_page_writes` và vì sao ghi sau checkpoint đắt gấp bội, `max_wal_size`, `checkpoint_completion_target`, `synchronous_commit`, `pg_stat_bgwriter`.
**Bài tập:** đo lượng WAL sinh ra (`pg_current_wal_lsn()` trước/sau) khi insert 500k row với `full_page_writes` on/off, và ngay sau checkpoint vs lâu sau checkpoint. Đo throughput với `synchronous_commit = on/off/local`.
**Writeup:** WAL amplification bạn đo được là bao nhiêu lần? `synchronous_commit=off` đánh đổi cái gì — mất bao nhiêu dữ liệu trong tình huống xấu nhất?

### Day 38 — Replication & replica lag
**Học:** streaming replication, `pg_stat_replication`, `hot_standby_feedback` và cái giá của nó, query conflict / `max_standby_streaming_delay`, read-your-writes vỡ thế nào.
**Bài tập:** thêm 1 replica vào compose. Tạo lag nhân tạo (query dài trên replica + write nặng trên primary). Viết code (Go/Java) ghi vào primary rồi đọc ngay từ replica → chứng minh bug read-your-writes. Sửa bằng LSN gating (`pg_current_wal_insert_lsn` + `pg_last_wal_replay_lsn`).
**Writeup:** đo lag bao nhiêu ms. Trong hệ CQRS của bạn, read model đọc từ replica thì lỗi này biểu hiện thế nào với người dùng, và bạn sẽ chặn ở tầng nào?

### Day 39 — Logical decoding, replication slot & outbox/CDC
**Học:** `wal_level=logical`, output plugin (`test_decoding`, `pgoutput`), `REPLICA IDENTITY` (DEFAULT/FULL/USING INDEX), publication/subscription, và vì sao logical replication **không** mang theo DDL lẫn sequence.
**Bài tập:** tạo slot, đọc thay đổi bằng `pg_logical_slot_peek_changes`; đo WAL của `REPLICA IDENTITY FULL` vs `DEFAULT`; mô phỏng **slot bị bỏ quên** và xem `pg_wal` phình ra không dừng; đặt `max_slot_wal_keep_size` và quan sát `wal_status` chuyển sang `lost`. Cuối cùng: đo chi phí WAL + bloat của **outbox** so với **CDC** cho cùng 10.000 sự kiện.
**Writeup:** vì sao một slot bỏ quên có thể làm database dừng ghi (và vì sao tăng đĩa không phải cách sửa)? Bảng so sánh outbox vs CDC có số. Query cảnh báo slot cho dashboard.
**Đạt khi:** nêu được 2 lý do kỹ thuật cụ thể để giữ outbox (hoặc đổi sang CDC) cho hệ của bạn.

### Day 40 — Wait events: hệ đang **chờ** cái gì — ôn tuần
**Học:** `pg_stat_activity` (`state` vs `wait_event`), 8 nhóm wait event và bệnh tương ứng, vì sao `state='active'` **không** đồng nghĩa với "đang dùng CPU", `idle in transaction` ghim `xmin horizon` và chặn VACUUM toàn database.
**Bài tập:** tự viết một wait event sampler (lấy mẫu 20 lần/giây vào bảng) rồi xếp hạng; dựng 3 kịch bản có chữ ký khác nhau: tranh chấp lock, WAL/fsync, và "thủ phạm là ứng dụng"; chứng minh một session `idle in transaction` chặn VACUUM bằng `VACUUM (VERBOSE)`.
**Writeup:** bảng xếp hạng wait event (bao nhiêu % thật sự chạy trên CPU), 3 chữ ký sự cố, và **quy trình 8 bước cho 30 giây đầu của một sự cố** — mỗi bước một lệnh chạy được.
**Đạt khi:** đọc một bảng wait event và nói được bệnh nằm ở đĩa / lock / ứng dụng.

---

# TUẦN 9 — Đổi schema mà không sập, và những chi phí ẩn

### Day 41 — TOAST: khi một dòng không vừa 8KB
**Học:** ngưỡng ~2KB, chunk 1996 byte, bảng `pg_toast.*`, 4 strategy (`PLAIN`/`EXTENDED`/`EXTERNAL`/`MAIN`), `pglz` vs `lz4`, và vì sao `pg_relation_size` **không** tính TOAST.
**Bài tập:** đo ngưỡng bị đẩy ra ngoài bằng dữ liệu nén được và không nén được; so buffers của `SELECT id` vs `SELECT *`; so `pglz` vs `lz4` trên jsonb; đo WAL của UPDATE có/không đụng cột TOAST và ảnh hưởng tới tỷ lệ HOT.
**Writeup:** `SELECT *` đọc thừa bao nhiêu lần? Vì sao lọc theo một field jsonb phải giải nén cả document? Bảng nào trong hệ bạn có `pct_toast` cao nhất?

### Day 42 — Prepared statement trong đời thật: driver, pool, kiểu tham số
**Học:** ba tầng "prepared" (client-side / protocol extended query / `PREPARE` SQL), `prepareThreshold` của JDBC và `QueryExecMode` của pgx, plan cache nằm trong RAM **từng backend**, pgbouncer transaction mode phá cái gì, và ép kiểu tham số làm index vô dụng.
**Bài tập:** đọc `pg_prepared_statements` (`generic_plans`/`custom_plans`); đo RAM backend tăng bao nhiêu với 200 statement (`pg_backend_memory_contexts`); tái hiện lỗi `26000 prepared statement does not exist`; so plan của `$1 bigint` vs `$1 numeric` vs `col::text = $1`, và `LIKE` với/không `text_pattern_ops`.
**Writeup:** service của bạn đang ở tầng nào, phải đổi cấu hình gì nếu thêm pgbouncer, và chỗ nào trong code đang gửi sai kiểu.
**Nối tiếp:** cơ chế generic vs custom plan đã học ở Day 12 §4 — hôm nay là phần tầng driver.

### Day 43 — Lock của DDL: vì sao một `ALTER TABLE` làm sập cả API
**Học:** 8 mức lock bảng, `ACCESS EXCLUSIVE` chặn cả `SELECT`, **hàng đợi lock** (một ALTER đang chờ chặn mọi câu đến sau), lệnh nào rewrite bảng vs chỉ sửa metadata, `lock_timeout` vs `statement_timeout`, `CREATE INDEX CONCURRENTLY` và index `INVALID`.
**Bài tập:** với mỗi lệnh DDL, xem lock mode thật trong `pg_locks`; dựng lại kịch bản 3 session để thấy `SELECT` bị chặn bởi một `ALTER` đang xếp hàng; so `relfilenode` trước/sau để biết lệnh nào rewrite; đo WAL của lệnh đổi kiểu cột; tạo một index `INVALID` rồi tìm nó.
**Writeup:** bảng phân loại ≥12 lệnh DDL (lock mode, rewrite?, an toàn?) — mỗi dòng có số bạn tự đo. Migration mẫu có `lock_timeout` + retry.
**Đạt khi:** giải thích được cơ chế hàng đợi lock cho một đồng nghiệp bằng 3 câu.

### Day 44 — Đổi schema trên bảng 5 triệu dòng mà không chặn ai
**Học:** expand/contract 4 pha, `CHECK ... NOT VALID` + `VALIDATE CONSTRAINT` để tách việc quét khỏi lock nặng, `SET NOT NULL` bỏ qua quét khi có CHECK hợp lệ (PG12+), backfill theo lô, `CREATE UNIQUE INDEX CONCURRENTLY` + `ADD CONSTRAINT ... USING INDEX`, đổi kiểu cột bằng cột mới + trigger.
**Bài tập:** chạy một "probe" đo p99 nền, rồi thêm cột `NOT NULL` bằng cả cách sai lẫn cách đúng và so p99; so 3 kiểu backfill (một phát / theo lô / theo lô có nghỉ); đổi kiểu cột không rewrite; thêm FK và UNIQUE an toàn.
**Writeup:** kế hoạch 4 pha cho **một** thay đổi schema thật của bạn, kèm lock mode, thời gian ước tính, điểm rollback, và tín hiệu để biết pha trước đã an toàn.
**Đạt khi:** thêm được cột `NOT NULL` vào bảng 3 triệu dòng mà p99 của probe không đổi rõ rệt.

### Day 45 — Chẩn đoán mù + diễn tập migration — ôn tuần
**Bài tập:** 5 ca sự cố (migration làm sập API, bảng "nhỏ" mà backup khổng lồ, đĩa đầy sau khi bật CDC, `CONCURRENTLY` treo 3 tiếng, lỗi `26000` sau khi thêm pgbouncer) — chẩn đoán **trước** khi chạy, rồi kiểm chứng. Sau đó **diễn tập** một migration hoàn chỉnh trên `ts_kv` với 4 yêu cầu đo được.
**Nộp thêm:** `days/day-45/migration-playbook.md` — bảng phân loại DDL, khuôn migration chuẩn, checklist 8 dòng chạy được, ngưỡng dừng, danh sách cấm giờ cao điểm.
**Đạt khi:** đúng ≥3/5 ca và diễn tập đạt ≥3/4 yêu cầu, có số liệu probe chứng minh.

---

# TUẦN 10 — Capstone

### Day 46 — Capstone 1a: audit lab, dựng hiện trường và chẩn đoán *(90–120 phút)*
**Bài tập:** coi lab là "production". Viết workload ≥25 query đủ 10 nhóm, lấy baseline (cache lạnh + cache nóng), xếp hạng bằng `pg_stat_statements` **và** wait event sampler, chọn 5 query. Với mỗi query: chẩn đoán node gốc bệnh + **dự đoán bằng số** mức cải thiện.
**Ràng buộc:** hôm nay **không sửa gì**. Không được đổi GUC ở cả hai ngày.
**Nộp:** `workload.sql` + 5 mục chẩn đoán có dự đoán.

### Day 47 — Capstone 1b: sửa, đo lại, và trả giá *(90–120 phút)*
**Bài tập:** sửa **từng cái một**, đo sau mỗi lần. Đối chiếu **dự đoán vs thực tế** cho cả 5 query. Đo lại toàn bộ workload + wait event. Rồi đo **cái giá**: dung lượng index, tốc độ ghi, WAL, tỷ lệ HOT — và xoá index mình tạo mà không được dùng.
**Nộp:** bảng before/after, bảng dự đoán vs thực tế, và `rollout.md` (kế hoạch triển khai với lock mode + rollback theo Day 43–44).
**Đạt khi:** độ chính xác của dự đoán — không phải mức cải thiện — là thứ bạn giải thích được.

### Day 48 — Capstone 2: mang về hệ thật *(90–120 phút)*
**Bài tập:** trên hệ ThingsBoard/service thật của bạn (chỉ đọc): 8 nhóm kiểm tra sức khoẻ, top query từ `pg_stat_statements`, `EXPLAIN` (không ANALYZE nếu là production ghi), chẩn đoán 5 query.
**Nộp:** `days/day-48/report.md` — báo cáo như gửi cho team: hiện trạng, phát hiện phân loại CRITICAL/WARNING/NOTICE, 5 query, đề xuất cấu hình, rủi ro vận hành (slot, transaction dài, index INVALID, migration nguy hiểm trong repo), kế hoạch triển khai theo ưu tiên, lỗ hổng monitoring.
**Đạt khi:** báo cáo này đủ chất lượng để bạn thật sự gửi cho tech lead.

---

## Sau ngày 48

Bạn sẽ ở mức: nhìn plan biết bệnh, sửa được, **biết cách chứng minh mình sửa đúng**, và đổi được schema trên bảng lớn mà không gây sự cố. Lúc đó mới sang Tier 2 (profiling, pprof/flame graph, tail latency, backpressure) — không phải trước.

Sách tra cứu song song, **không đọc một lèo**:
- *PostgreSQL 14 Internals* — Egor Rogov (PDF free). Tuần 1–5 map gần như 1-1 với sách này.
- CMU 15-445 (Andy Pavlo, YouTube) — xem sau khi làm bài, để thấy cái mình vừa đo.
- *Database Internals* — Alex Petrov, phần B-tree vs LSM (dành cho tuần 7).
- Docs Postgres phần "Performance Tips" và "Explicit Locking" — ngắn, đọc thật.
