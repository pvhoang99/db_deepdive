# Lời giải — 48 ngày

Mỗi ngày có một file `days/day-XX/giai.md`: bài chữa chi tiết, **mọi con số đều đo thật** trên lab (Postgres 17, 8 core / 31 GB RAM, `SCALE=1`), kèm tình huống thực tế và phần "áp dụng vào hệ thật".

**Cách dùng:** làm bài trong `README.md` trước, viết `writeup.md` của bạn, **rồi mới** mở `giai.md` để đối chiếu. Đọc trước thì mất phần lớn giá trị.

Mỗi `giai.md` có cùng cấu trúc:

| Mục | Nội dung |
|---|---|
| **§0. Đáp án phần đoán** | trả lời từng câu "đoán trước", kèm cái bẫy |
| **§1…§N** | mirror các mục của README, có bảng số đo |
| **🔧 Tình huống thực tế** | sự cố production tương ứng, cách chẩn đoán và sửa |
| **Bảng số liệu chính** | mọi con số của ngày, gom một chỗ |
| **Ba điều dễ hiểu sai** | hiểu nhầm ↔ sự thật đo được |
| **Áp dụng vào hệ thật** | 8 việc cụ thể, có SQL chạy được |
| **Câu hỏi mở sang các ngày sau** | liên kết chéo giữa các ngày |

> **Nguyên tắc:** khi thí nghiệm **không** tái hiện được điều README dự đoán, `giai.md` ghi lại đúng như thế và giải thích vì sao — thay vì sửa số cho khớp. Có khoảng một chục chỗ như vậy (đánh dấu bằng ❌ hoặc "không tái hiện được"), và chúng thường là phần đáng đọc nhất.

---

## Tuần 1–2 — Đọc plan và index (Day 01–10)

| Ngày | Chủ đề | Con số đáng nhớ |
|---|---|---|
| [01](days/day-01/giai.md) | EXPLAIN cơ bản, bẫy `loops` | `reltuples = -1` khi chưa ANALYZE |
| [02](days/day-02/giai.md) | ANALYZE vs plan, self-time vs cumulative | |
| [03](days/day-03/giai.md) | BUFFERS — đo bằng page thay vì ms | shared hit/read phân biệt cache và đĩa |
| [04](days/day-04/giai.md) | Chi phí thật của một query | |
| [05](days/day-05/giai.md) | `pg_stat_statements`, total vs mean | `generate_series` trong một statement cho `calls = 1` — phải `\gexec` |
| [06](days/day-06/giai.md) | B-tree internals qua `pageinspect` | fanout, deduplication, page split |
| [07](days/day-07/giai.md) | Composite index và leftmost rule | thứ tự cột quyết định index dùng được hay không |
| [08](days/day-08/giai.md) | `INCLUDE`, partial, expression index | |
| [09](days/day-09/giai.md) | Estimate sai và hậu quả | |
| [10](days/day-10/giai.md) | Cái giá của index, index thừa/trùng | `indkey::int2[]` là 0-based — query tìm index trùng trong tài liệu trả về 0 dòng |

## Tuần 3 — Statistics và cost model (Day 11–15)

| Ngày | Chủ đề | Con số đáng nhớ |
|---|---|---|
| [11](days/day-11/giai.md) | Visibility map, Index Only Scan, `Heap Fetches` | |
| [12](days/day-12/giai.md) | Plan cache, custom vs generic | `to_char(timestamptz,text)` là STABLE, không IMMUTABLE — gợi ý của README sai |
| [13](days/day-13/giai.md) | `CREATE STATISTICS` cho cột phụ thuộc | |
| [14](days/day-14/giai.md) | Cost model GUC | |
| [15](days/day-15/giai.md) | Chẩn đoán mù 5 ca | **3/5 ca không tái hiện được thảm hoạ** — lab quá nhỏ và index quá tốt |

## Tuần 4 — Join, sort, aggregate (Day 16–20)

| Ngày | Chủ đề | Con số đáng nhớ |
|---|---|---|
| [16](days/day-16/giai.md) | Nested Loop, Memoize, Hash Join, Batches | |
| [17](days/day-17/giai.md) | Sort: quicksort / top-N / external merge | `work_mem` quyết định sống chết |
| [18](days/day-18/giai.md) | HashAggregate vs GroupAggregate, hash spill | |
| [19](days/day-19/giai.md) | Extended statistics, rollup | **`CREATE STATISTICS (ndistinct)` làm estimate TỆ HƠN: 1,76× → 4,40×** |
| [20](days/day-20/giai.md) | Viết lại SQL: `LATERAL`, `DISTINCT ON`, `NOT EXISTS` | |

## Tuần 5 — MVCC và vacuum (Day 21–25)

| Ngày | Chủ đề | Con số đáng nhớ |
|---|---|---|
| [21](days/day-21/giai.md) | xmin/xmax/ctid, dead tuple | |
| [22](days/day-22/giai.md) | VACUUM vs VACUUM FULL, bloat | `VACUUM` dọn dead tuple nhưng **không trả đĩa** |
| [23](days/day-23/giai.md) | Autovacuum: ngưỡng, cost delay | **`cost_delay=100ms` KHÔNG làm autovacuum tụt lại** trên bảng 521 page |
| [24](days/day-24/giai.md) | HOT update, fillfactor | |
| [25](days/day-25/giai.md) | Freeze, XID wraparound | |

## Tuần 6 — Isolation và lock (Day 26–30)

| Ngày | Chủ đề | Con số đáng nhớ |
|---|---|---|
| [26](days/day-26/giai.md) | Read Committed / Repeatable Read / Serializable | |
| [27](days/day-27/giai.md) | Snapshot, EvalPlanQual, lost update | |
| [28](days/day-28/giai.md) | Ma trận row lock, `NOWAIT`, `SKIP LOCKED` | |
| [29](days/day-29/giai.md) | Deadlock, `pg_blocking_pids` | **Kịch bản deadlock FK KHÔNG deadlock** — `FOR NO KEY UPDATE` và `FOR KEY SHARE` không xung đột |
| [30](days/day-30/giai.md) | SSI, write skew, benchmark 3 chiến lược | |

## Tuần 7 — Time-series và IoT (Day 31–35)

| Ngày | Chủ đề | Con số đáng nhớ |
|---|---|---|
| [31](days/day-31/giai.md) | BRIN cho time-series | **48 kB vs 108 MB (2.300×)**; `bloom` opclass **không** được planner chọn |
| [32](days/day-32/giai.md) | Declarative partitioning & pruning | **Partition KHÔNG làm query nhanh hơn** — bảng phẳng thắng 3/4 |
| [33](days/day-33/giai.md) | ATTACH/DETACH/retention | **`DROP PARTITION` 0,836 ms vs `DELETE`+`VACUUM FULL` 4.249 ms — 5.083×** |
| [34](days/day-34/giai.md) | jsonb & GIN | Cột thật thắng GIN **4,7×**; `UPDATE` toàn bảng làm GIN phình **9–11×** |
| [35](days/day-35/giai.md) | Chọn model lưu telemetry + ôn tuần | Ghi rải rác tốn **2,8× WAL** so với ghi tập trung |

## Tuần 8 — Vận hành (Day 36–40)

| Ngày | Chủ đề | Con số đáng nhớ |
|---|---|---|
| [36](days/day-36/giai.md) | Connection pooling, pgbouncer | Đỉnh ở **8 client = 8 core**; **pgbouncer CHẬM hơn 19–33%** nhưng là thứ duy nhất cho 500 client chạy trên `max_connections=100` |
| [37](days/day-37/giai.md) | WAL & checkpoint | **86,3% WAL sau checkpoint là FPI**; `synchronous_commit=off` nhanh **84×** |
| [38](days/day-38/giai.md) | Replication & replica lag | **Read-your-writes hỏng 30/30 lần khi có tải**; `hot_standby_feedback` làm primary phình **2,1×** |
| [39](days/day-39/giai.md) | Logical decoding, slot, outbox vs CDC | Outbox tốn WAL **1,83×** CDC nhưng bloat **16,3×** |
| [40](days/day-40/giai.md) | Wait events + ôn tuần | **`idle in transaction` ở READ COMMITTED KHÔNG chặn vacuum** — chỉ REPEATABLE READ mới chặn |

## Tuần 9 — Đổi schema an toàn (Day 41–45)

| Ngày | Chủ đề | Con số đáng nhớ |
|---|---|---|
| [41](days/day-41/giai.md) | TOAST | Ngưỡng 2 KB áp lên độ dài **SAU NÉN** — 100 KB chữ 'd' không bị TOAST; TOAST làm query chậm **62×** |
| [42](days/day-42/giai.md) | Prepared statement, driver, kiểu tham số | **Tham số `numeric` thay `bigint`: 179× chậm hơn** |
| [43](days/day-43/giai.md) | Lock của DDL | **`SELECT` vô can chờ 5.099 ms** vì xếp hàng sau `ALTER TABLE` đang chờ |
| [44](days/day-44/giai.md) | Expand/contract, backfill theo lô | Cách đúng **chậm hơn 1,4×** và bloat y hệt — nó chỉ mua tính khả dụng |
| [45](days/day-45/giai.md) | Chẩn đoán mù + diễn tập migration | Migration 5M dòng trong **1,3 giây**, cửa sổ khoá **4,58 ms** · kèm [migration-playbook.md](days/day-45/migration-playbook.md) |

## Tuần 10 — Capstone (Day 46–48)

| Ngày | Chủ đề | Kết quả |
|---|---|---|
| [46](days/day-46/giai.md) | Audit lab: dựng hiện trường, chẩn đoán | Baseline **44.796 ms**, 5 query chiếm **97,4%**, 5 dự đoán viết trước khi sửa · [workload.sql](days/day-46/workload.sql) |
| [47](days/day-47/giai.md) | Sửa, đo lại, trả giá | **44.796 → 811 ms (55,2×)**; cái giá: ghi chậm **14,9×**, WAL **×4,25**, đĩa **+102%**. Dự đoán đúng 3/5 · [rollout.md](days/day-47/rollout.md) |
| [48](days/day-48/giai.md) | Audit production | Bộ [audit.sql](days/day-48/audit.sql) chỉ-đọc chạy được trên replica + [report.md](days/day-48/report.md) |

---

## Sản phẩm mang đi dùng được ngay

| File | Dùng để làm gì |
|---|---|
| **[days/day-48/audit.sql](days/day-48/audit.sql)** | Kiểm tra sức khoẻ Postgres — chỉ đọc, an toàn cho production và replica. Một lệnh ra toàn bộ số liệu. |
| **[days/day-45/migration-playbook.md](days/day-45/migration-playbook.md)** | 21 lệnh DDL phân loại (lock, rewrite, số đo), khuôn migration có retry, checklist 8 query, ngưỡng dừng |
| **[days/day-48/report.md](days/day-48/report.md)** | Mẫu báo cáo audit — cấu trúc, ngưỡng, câu lệnh; thay số production vào là xong |
| **[days/day-40/giai.md](days/day-40/giai.md) §7** | Quy trình 30 giây đầu khi có sự cố — 8 bước, mỗi bước một query |
| **[days/day-46/workload.sql](days/day-46/workload.sql)** | Workload IoT 27 câu để benchmark trước/sau khi tối ưu |

---

## Mười con số đáng nhớ nhất

| # | Con số | Ngày |
|---|---|---|
| 1 | **`ALTER TABLE` đang CHỜ làm một `SELECT` vô can chờ 5.099 ms** — bản thân nó chỉ chạy 11 ms | 43 |
| 2 | **86,3% WAL của một `UPDATE` ngay sau checkpoint là full-page image** | 37 |
| 3 | **Read-your-writes hỏng 30/30 lần khi có tải** (0/20 khi không tải) | 38 |
| 4 | **`DROP PARTITION` nhanh hơn `DELETE`+`VACUUM FULL` 5.083 lần**, 0 dead tuple | 33 |
| 5 | **Tham số `numeric` thay vì `bigint` làm query chậm 179×** | 42 |
| 6 | **`synchronous_commit = off` nhanh 84×** và **không** làm hỏng database | 37 |
| 7 | **Đỉnh throughput ở đúng 8 client = 8 core**; 256 client cho −46% và latency ×59 | 36 |
| 8 | **Lọc một field jsonb bị TOAST: 150.473 buffer vs 516** nếu là cột thật | 41 |
| 9 | **`hot_standby_feedback=on`: `VACUUM` chạy 3 lần trên primary không dọn được dead tuple nào** | 38 |
| 10 | **Capstone: 44.796 → 811 ms (55,2×)**; cái giá: ghi chậm 14,9×, WAL ×4,25, đĩa +102% | 46–47 |

---

## Ba bài học phương pháp

**1. Con số đẹp bất thường ⇒ kiểm tra plan trước khi ăn mừng.**
Workload capstone đầu tiên chạy 900 ms — vì `count(*)` làm Postgres xoá hẳn scalar subquery. Sau khi sửa: 44.796 ms, gấp 50 lần. Cùng loại lỗi: `EXPLAIN ANALYZE` không de-TOAST vì không gửi dữ liệu về client (Day 41 §3).

**2. Đo bằng `max` và cửa sổ khoá, không bằng p99.**
Day 44: p99 của cách sai (1,67 ms) còn *thấp hơn* cách đúng (1,90 ms) — trong khi nó làm một request đứng **1.195 ms**. Ở 5.000 qps đó là ~5.775 request vượt `connectionTimeout` ⇒ pool cạn ⇒ mọi endpoint lỗi.

**3. Kết luận không chuyển được giữa các môi trường.**
Lab cho 96,9% CPU vì 31 GB RAM / 289 MB dữ liệu. Production 2 TB / 64 GB RAM sẽ cho kết quả ngược. Mọi benchmark đọc được trên mạng đều mang giả định của máy chạy nó.
