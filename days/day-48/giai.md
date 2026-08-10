# Day 48 — Lời giải: Capstone 2 — mang về hệ production thật

> **Nói thẳng trước: tôi không có quyền truy cập hệ production của bạn.** Ngày này yêu cầu audit một hệ thật, và đó là việc chỉ bạn làm được.
>
> Vậy nên tôi làm hai thứ có giá trị thật thay vì viết một báo cáo giả:
>
> 1. **[`audit.sql`](audit.sql)** — bộ kiểm tra hoàn chỉnh, **chỉ đọc, an toàn cho production và cho replica**, đã chạy thật và **0 lỗi**. Chạy một lệnh, ra toàn bộ số liệu cần cho báo cáo.
> 2. **[`report.md`](report.md)** — báo cáo audit đầy đủ theo đúng cấu trúc §7 yêu cầu, **điền bằng số thật đo trên lab** (hệ duy nhất tôi truy cập được), ghi rõ ở đầu là chưa chạy trên production. Nó vừa là mẫu, vừa là bài audit thật của lab.
>
> Output thô: [`audit-output-lab.txt`](audit-output-lab.txt) (375 dòng).

---

## Vì sao làm thế này thay vì viết báo cáo giả

Một báo cáo audit bịa số là thứ tệ nhất có thể giao — nó trông giống việc thật đủ để ai đó tin và hành động theo. Ba lựa chọn tôi cân nhắc:

| Lựa chọn | Đánh giá |
|---|---|
| Viết báo cáo với số bịa cho "hệ production của bạn" | ❌ Nguy hiểm: trông thật, dẫn tới quyết định sai |
| Viết một template trống | ❌ Ít giá trị: bạn vẫn phải tự nghĩ ra query và ngưỡng |
| **Bộ công cụ chạy được + báo cáo thật của lab làm mẫu** | ✅ Bạn chạy một lệnh trên production, thay số vào, có ngay báo cáo |

Cách thứ ba cũng đúng tinh thần của cả 48 ngày: **mọi kết luận phải có số đo đứng sau.**

---

## §1–2. `audit.sql` — bộ kiểm tra

**Nguyên tắc an toàn** (đúng bảng ràng buộc của README):

| Trong file có | Không có |
|---|---|
| `SELECT` trên catalog và view thống kê | `EXPLAIN ANALYZE` bất kỳ dạng nào |
| `SET statement_timeout/lock_timeout/idle_in_transaction_session_timeout` cho **phiên hiện tại** | `ALTER SYSTEM`, đổi GUC hệ thống |
| `format()` **in ra** lệnh đề xuất | DDL, DML |
| | `VACUUM`, `REINDEX`, `CREATE INDEX` |

Chạy được trên **replica read-only**. Đã kiểm chứng: **0 lỗi**.

### Cấu trúc

| Mục | Nội dung | Ngày tham chiếu |
|---|---|---|
| **§1 Hiện trạng** | version, GUC khác mặc định, **GUC quan trọng kể cả đang ở mặc định**, dung lượng DB, 20 bảng lớn nhất, extension, **`stats_reset`** | — |
| **§2.1** | Bloat & vacuum | Day 22–23 |
| **§2.2** | XID age (bảng + database) | Day 25 |
| **§2.3** | Transaction dài / `idle in transaction` | Day 22, 40 |
| **§2.3b** | **Ai đang ghim `xmin horizon` — cả 4 nguồn** | Day 38 §5, 39 §4, 40 §5 |
| **§2.4** | Slot, replication lag 3 tầng, `pg_ls_waldir`, archiver, checkpointer | Day 37–39 |
| **§2.5** | Index không dùng / **INVALID** / **constraint chưa validate** / **trùng lặp** | Day 07, 10, 43 |
| **§2.6** | TOAST | Day 41 |
| **§2.7** | Prepared statement, `generic_plans` vs `custom_plans` | Day 42 |
| **§2.8** | HOT ratio, cache hit, rollback, deadlock, temp | Day 24 |
| **§2.9** | Connection theo state, wait event hiện tại | Day 36, 40 |
| **§3.1–3.6** | Top query theo **tổng / mean / stddev / temp / WAL / buffer-mỗi-dòng** | Day 05 |
| **§5.1–5.2** | **Sinh lệnh `ALTER TABLE` và `DROP INDEX` đề xuất** (chỉ in, không chạy) | Day 23 |

### Ba query tôi thêm mà README không yêu cầu

**a) §2.3b — bảng hợp nhất 4 nguồn ghim `xmin`:**
```sql
SELECT 'backend', pid::text, age(backend_xmin) FROM pg_stat_activity WHERE backend_xmin IS NOT NULL
UNION ALL SELECT 'replica(hot_standby_feedback)', application_name, age(backend_xmin) FROM pg_stat_replication WHERE backend_xmin IS NOT NULL
UNION ALL SELECT 'slot', slot_name, age(coalesce(catalog_xmin, xmin)) FROM pg_replication_slots WHERE coalesce(catalog_xmin,xmin) IS NOT NULL
UNION ALL SELECT 'prepared_xact', gid, age(transaction) FROM pg_prepared_xacts
ORDER BY 3 DESC NULLS LAST;
```
**Ba trong bốn nguồn KHÔNG hiện trong `pg_stat_activity`** — đó là lý do bloat khó chẩn đoán nhất luôn đến từ chúng (Day 38 §5, Day 39 §4). Đây là query tôi thấy thiếu nhất trong mọi checklist Postgres từng đọc.

**b) §3.6 — buffer đọc trên mỗi dòng trả về:**
```sql
round(((shared_blks_hit+shared_blks_read)::numeric/nullif(rows,0)),1) AS buf_moi_dong
```
Chỉ số này phát hiện query thiếu index **tốt hơn `total_exec_time`**, vì nó không phụ thuộc cache và không phụ thuộc tần suất. Trên lab nó chỉ thẳng vào 3 query đọc **10.863–38.508 buffer để trả về 1 dòng**.

**c) §2.5 — index trùng lặp:**
```sql
WHERE a.indkey::text LIKE b.indkey::text || ' %'
```
Dùng so khớp chuỗi thay vì `indkey[0:n]` — vì `indkey` là `int2vector` **0-based**, và bản trong hầu hết tài liệu (dùng `indkey::int2[]`) trả về 0 dòng. (Đã gặp lỗi này ở Day 10 và sửa từ đó.)

---

## §3–7. Báo cáo — [`report.md`](report.md)

Điền bằng số thật đo trên lab. Tóm tắt phát hiện:

### Không có CRITICAL — và đó cũng là một kết quả

| Kiểm tra | Kết quả |
|---|---|
| Replication slot bỏ quên | 0 ✅ |
| Index `INVALID` | 0 ✅ |
| Constraint chưa validate | 0 ✅ |
| XID age lớn nhất | **973 = 0,0%** ngưỡng ✅ |
| Transaction > 1 phút | 0 ✅ |
| Deadlock / archive fail | 0 / 0 ✅ |

**Loại trừ giả thuyết cũng là kết quả chẩn đoán.** Một audit chỉ liệt kê vấn đề mà không nói rõ đã kiểm tra và loại trừ những gì thì không đáng tin — người đọc không biết bạn đã nhìn tới đâu.

### Sáu WARNING với số liệu

| # | Phát hiện | Số đo |
|---|---|---|
| **W1** | `cache_hit_pct` thấp | **82,26%** (ngưỡng 99%); `blk_read_time` 8.824 ms; `shared_buffers` 256 MB / dataset 764 MB |
| **W2** | `alarm` bloat, autovacuum chưa chạy | **60.000 dead / 200.000 live = 30%**, `last_autovacuum = null`, bảng 33 → **42 MB (+27%)** |
| **W3** | 3 query đọc > 10.000 buffer/dòng | **38.508** / **24.140** / **10.863** buffer mỗi dòng trả về |
| **W4** | Ingest sinh WAL lớn, gần hết là FPI | **121 MB WAL** cho 120k dòng; `wal_fpi = 14.993` × 8 kB = **117 MB = 96,7%**; `stddev/mean = 1,04` |
| **W5** | Checkpoint quá thường xuyên | `num_requested/(timed+requested)` = **42,9%** (ngưỡng < 10%) |
| **W6** | Thiếu 3 bảo hiểm | `max_slot_wal_keep_size = −1`, `idle_in_transaction_session_timeout = 0`, không có `statement_timeout` theo role |

**W4 là phát hiện tôi thích nhất** vì nó nối được ba ngày rời rạc thành một câu chuyện: `wal_fpi = 14.993` (Day 37 §3) × `device_id` ngẫu nhiên (Day 35 §2) × `checkpoint` chạy quá thường xuyên (W5) ⇒ **96,7% WAL là bản sao page, không phải dữ liệu**. Và `stddev ≈ mean` là chữ ký đo được của chính hiện tượng đó.

### Ba query phân tích sâu — với cách sửa cụ thể

| Q | Query | mean | buf/dòng | Đề xuất | Ước tính |
|---|---|---|---|---|---|
| **1** | `lower(name) LIKE 'prefix%'` (25,6%) | 207,6 ms | **10.863** | `CREATE INDEX ... (lower(name) text_pattern_ops)` | **→ ~3 ms (~70×)**, dựa trên Day 42 §4c đo được 86× |
| **2** | downsample theo giờ (16,6%) | 134,6 ms | **38.508** | **BRIN trên `ts`** (~50 kB) trước, B-tree `(key_id, ts)` (~160 MB) chỉ khi chưa đủ | → ~15 ms (BRIN) hoặc ~5 ms (B-tree) |
| **3** | `count(*) WHERE tenant_id AND is_active` (14,2%) | 115,2 ms | **24.140** | partial index `(tenant_id) WHERE is_active` (~350 kB) | **→ ~1,5 ms (~77×)**, phục vụ luôn 2 query khác |

Chọn 3 thay vì 5 vì sau vòng tối ưu Day 47, mọi query còn lại đều dưới 3,5% — **phân tích sâu chúng là tối ưu cho vui, không phải cho hệ thống.**

Điểm đáng chú ý ở Q2: **đề xuất BRIN trước B-tree** dù B-tree nhanh hơn. Lý do định lượng: Day 31 đo BRIN **48 kB vs 108 MB** cho cùng cột thời gian với `correlation = 1`. Nếu BRIN đưa 134,6 ms xuống 15 ms thì đã đủ, và tiết kiệm **160 MB**. Đây là kiểu quyết định mà audit tốt khác audit tệ — audit tệ chọn cái nhanh nhất, audit tốt chọn cái đủ nhanh với chi phí thấp nhất.

### Kế hoạch triển khai — 8 hành động theo giá trị ÷ rủi ro

| Ưu tiên | Hành động | Downtime | Rollback |
|---|---|---|---|
| **P0** | `wal_compression='lz4'` (−27% WAL) | 0 | tức thì |
| **P0** | `max_slot_wal_keep_size='50GB'` (chống đầy đĩa) | 0 | tức thì |
| **P0** | `idle_in_transaction_session_timeout='60s'` theo role | 0 | tức thì |
| **P1** | `random_page_cost=1.1`, `effective_cache_size='20GB'` | 0 | tức thì |
| **P1** | autovacuum per-table cho `alarm` + `ts_kv` | 0 | tức thì |
| **P1** | 3 index bằng `CREATE INDEX CONCURRENTLY` | 0 | `DROP INDEX CONCURRENTLY` |
| **P2** | `max_wal_size='8GB'`, `checkpoint_timeout='30min'` | 0 | tức thì (**cần quyết định RTO**) |
| **P3** | `shared_buffers='8GB'` | **cần restart** | restart |

**Ba việc P0 chạy được ngay hôm nay, không downtime, rollback tức thì, và chặn được ba loại sự cố khác nhau.** Đó là tiêu chí sắp xếp đúng: không phải "cái nào lợi nhất" mà là **"cái nào lợi nhiều nhất trên mỗi đơn vị rủi ro"**.

### Monitoring — 15 chỉ số, chỉ ra 3 lỗ hổng lớn nhất

Ba chỉ số **bị bỏ quên nhiều nhất** trong mọi hệ tôi từng thấy, và cả ba đều **báo trước sự cố** thay vì báo sau:

| # | Chỉ số | Vì sao bị bỏ quên |
|---|---|---|
| **1** | **`backend_xmin` của replica và slot** | Không hiện trong `pg_stat_activity`. Là nguyên nhân bloat khó chẩn đoán nhất (Day 38 §5). |
| **2** | **`wal_status` của slot** | Cho cảnh báo ở trạng thái `extended`/`unreserved` **trước khi** đĩa đầy; `pg_wal` size chỉ báo khi đã muộn (Day 39 §4). |
| **3** | **`num_requested / (num_timed + num_requested)`** | Cho biết `max_wal_size` quá nhỏ **trước khi** nó biến thành hoá đơn WAL và replica lag (Day 37 §4). |

Và một lưu ý về ngưỡng, học từ Day 38 §2: **alert replication lag phải AND cả byte lẫn giây.** Lag tính bằng giây một mình sẽ báo động giả mỗi khi hệ nhàn rỗi (đo được: `lag_thoi_gian = 29 giây` trong khi `lag_byte = 0`).

---

## Việc bạn cần làm — 6 bước, mất khoảng 1 giờ

| # | Việc | Lệnh |
|---|---|---|
| **1** | Chạy audit trên production (chỉ đọc, chạy được trên replica) | `psql -h prod -U readonly -d db -f audit.sql > audit-prod-$(date +%F).txt` |
| **2** | Kiểm tra `pg_stat_statements` đã bật chưa | Nếu chưa: **đây là khuyến nghị ưu tiên số 1**. Không có nó thì mọi phân tích query đều mù. |
| **3** | Ghi lại `stats_reset` | Mọi số `pg_stat_*` chỉ có nghĩa tương đối với mốc này. Nếu là 1 giờ trước thì `idx_scan = 0` không nói lên gì. |
| **4** | **Snapshot toàn bộ `pg_stat_*` trước khi đổi bất cứ thứ gì** | `CREATE TABLE audit_snapshot_YYYYMMDD AS SELECT * FROM pg_stat_user_tables;` — Day 47 đã vấp lỗi thiếu số liệu "trước". |
| **5** | Điền số production vào [`report.md`](report.md) | Cấu trúc, ngưỡng, câu lệnh giữ nguyên; chỉ thay số |
| **6** | Chạy 3 việc P0 | Không downtime, rollback tức thì, chặn 3 loại sự cố |

---

## Ba điều dễ hiểu sai (rút ra từ chính ngày hôm nay)

| Hiểu nhầm | Sự thật |
|---|---|
| "Audit là liệt kê vấn đề tìm được." | Một nửa giá trị nằm ở **những gì đã kiểm tra và LOẠI TRỪ**. Báo cáo này nói rõ: 0 slot bỏ quên, 0 index INVALID, XID age 0,0%, 0 transaction dài. Không có phần đó, người đọc không biết bạn đã nhìn tới đâu — và sẽ phải tự kiểm tra lại. |
| "Xếp hạng query theo `total_exec_time` là đủ." | `total_exec_time` bị chi phối bởi **tần suất**, nên nó giấu query chậm-nhưng-hiếm. Cần **năm góc nhìn**: tổng (nơi tiêu tiền), mean (trải nghiệm người dùng), **stddev** (không ổn định — đáng nghi nhất), temp (thiếu `work_mem`), và **buffer-mỗi-dòng** (thiếu index — chỉ số duy nhất không phụ thuộc cache lẫn tần suất). Trên lab, chính `buf_moi_dong` chỉ thẳng vào ba query cần sửa. |
| "Đề xuất cái nhanh nhất là đề xuất tốt nhất." | Q2 nhanh nhất với B-tree `(key_id, ts)` — nhưng **160 MB**. BRIN cho **~50 kB** và có thể đã đủ. Audit tốt hỏi *"đủ nhanh chưa"* trước khi hỏi *"nhanh nhất là gì"*. Cùng logic ở Day 47 §4 với index thứ hai trên `ts_kv`: không có nó thì 4,13 ms, có nó thì 0,020 ms — và **4,13 ms có thể đã đạt SLO**, tiết kiệm 151 MB. |

---

# Hết 48 ngày

## Đã chữa xong toàn bộ

| Tuần | Ngày | Chủ đề | Trạng thái |
|---|---|---|---|
| 1–2 | 01–10 | EXPLAIN, pg_stat_statements, B-tree, index | ✅ |
| 3 | 11–15 | Statistics, cost model, chẩn đoán mù | ✅ |
| 4 | 16–20 | Join, sort, aggregate, `work_mem` | ✅ |
| 5 | 21–25 | MVCC, vacuum, bloat, HOT, wraparound | ✅ |
| 6 | 26–30 | Isolation, lock, deadlock, anomaly | ✅ |
| 7 | 31–35 | BRIN, partition, jsonb/GIN, chọn model lưu telemetry | ✅ |
| 8 | 36–40 | Pooling, WAL/checkpoint, replication, CDC, wait events | ✅ |
| 9 | 41–45 | TOAST, plan cache, DDL lock, expand/contract, playbook | ✅ |
| 10 | 46–48 | Capstone: audit → sửa → trả giá → báo cáo | ✅ |

**48/48 ngày có `giai.md` với số đo thật**, chạy trên lab Postgres 17, không có con số nào bịa.

## Mười con số đáng nhớ nhất của cả chương trình

| # | Con số | Ngày |
|---|---|---|
| 1 | **`ALTER TABLE` đang CHỜ làm một `SELECT` vô can chờ 5.099 ms** — bản thân nó chỉ chạy 11 ms | 43 |
| 2 | **86,3% WAL của một `UPDATE` ngay sau checkpoint là full-page image** | 37 |
| 3 | **Read-your-writes hỏng 30/30 lần khi có tải** (0/20 khi không tải) | 38 |
| 4 | **`DROP PARTITION` nhanh hơn `DELETE`+`VACUUM FULL` 5.083 lần**, 0 dead tuple | 33 |
| 5 | **Tham số `numeric` thay vì `bigint` làm query chậm 179×** — vì Postgres ép **cột**, không ép tham số | 42 |
| 6 | **`synchronous_commit = off` nhanh 84×** và **không** làm hỏng database | 37 |
| 7 | **Đỉnh throughput ở đúng 8 client = 8 core**; 256 client cho −46% và latency ×59 | 36 |
| 8 | **Lọc một field jsonb bị TOAST: 150.473 buffer vs 516** nếu là cột thật | 41 |
| 9 | **`hot_standby_feedback=on`: `VACUUM` chạy 3 lần trên primary không dọn được một dead tuple nào** | 38 |
| 10 | **Capstone: workload 44.796 → 811 ms (55,2×)**, cái giá: ghi chậm 14,9×, WAL ×4,25, đĩa +102% | 46–47 |

## Ba bài học phương pháp, quan trọng hơn mọi con số

**1. Con số đẹp bất thường ⇒ kiểm tra plan trước khi ăn mừng.**
Workload đầu tiên chạy 900 ms — vì `count(*)` làm Postgres **xoá hẳn scalar subquery**. Sau khi sửa: 44.796 ms, gấp 50 lần. Cùng loại lỗi: `EXPLAIN ANALYZE` không de-TOAST vì không gửi dữ liệu về client (Day 41 §3).

**2. Đo bằng `max` và cửa sổ khoá, không bằng p99.**
Day 44: p99 của cách sai (1,67 ms) còn *thấp hơn* cách đúng (1,90 ms) — trong khi nó làm một request đứng **1.195 ms**. Ở 5.000 qps đó là ~5.775 request vượt `connectionTimeout` ⇒ pool cạn ⇒ **mọi endpoint lỗi**.

**3. Kết luận không chuyển được giữa các môi trường.**
Lab cho 96,9% CPU vì 31 GB RAM / 289 MB dữ liệu. Production 2 TB / 64 GB RAM sẽ cho kết quả ngược. Mọi benchmark đọc được trên mạng đều mang giả định của máy chạy nó.

## Việc cần làm tuần này — để 48 ngày không thành kiến thức chết

1. **Gửi [`report.md`](report.md) và [`migration-playbook.md`](../day-45/migration-playbook.md) cho tech lead** (sau khi chạy `audit.sql` trên production và thay số).
2. **Chạy 3 việc P0** — không downtime, rollback tức thì.
3. **Thêm 3 alert còn thiếu**: `backend_xmin`, `wal_status`, `pct_requested`.
4. **Thêm `SET lock_timeout` vào mọi migration** — việc rẻ nhất, chặn loại sự cố lan rộng nhất.
5. **Đo lại sau 1 tuần và ghi con số thật.**

> Kiến thức chỉ thành kỹ năng khi nó đổi được một con số trên production.
