# Day 48 — Capstone 2: mang về hệ production thật

**Thời lượng:** 90–120 phút · **Cách học:** hôm nay bạn viết một tài liệu thật để gửi cho team.

---

## Nguyên tắc an toàn — đọc trước khi làm

Bạn làm việc trên **production**. Ràng buộc tuyệt đối:

| Được phép | **Không** được phép |
|---|---|
| `SELECT` từ catalog và view thống kê | `EXPLAIN ANALYZE` trên `INSERT/UPDATE/DELETE` |
| `EXPLAIN` (không `ANALYZE`) | `CREATE INDEX` (không có `CONCURRENTLY`) |
| `EXPLAIN (ANALYZE, BUFFERS)` trên `SELECT` nhẹ | `VACUUM FULL`, `REINDEX` (không CONCURRENTLY) |
| Đọc log | `ALTER SYSTEM`, đổi GUC |
| `pg_stat_statements` | Bất kỳ DDL nào chưa qua review |

Nếu chỉ có quyền read-only thì càng tốt. Nếu chưa có quyền truy cập production, dùng **staging** hoặc bản khôi phục từ backup — ghi rõ trong báo cáo.

Đặt bảo hiểm cho mọi phiên:
```sql
SET statement_timeout = '30s';
SET lock_timeout = '2s';
SET idle_in_transaction_session_timeout = '60s';
```

---

## §1. Thu thập hiện trạng

### Làm ngay

```sql
-- phiên bản và cấu hình
SELECT version();
SELECT name, setting, unit, source FROM pg_settings
WHERE source NOT IN ('default','override') ORDER BY name;

-- kích thước
SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database ORDER BY 2 DESC;

SELECT schemaname, relname,
       pg_size_pretty(pg_total_relation_size(relid)) AS tong,
       pg_size_pretty(pg_relation_size(relid))       AS heap,
       pg_size_pretty(pg_indexes_size(relid))        AS index,
       n_live_tup, n_dead_tup
FROM pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC LIMIT 20;

-- pg_stat_statements đã bật chưa
SELECT * FROM pg_extension WHERE extname = 'pg_stat_statements';
```

Nếu chưa bật `pg_stat_statements`: ghi vào báo cáo như một **khuyến nghị ưu tiên số 1** (cần thêm vào `shared_preload_libraries` và restart), rồi dùng log `log_min_duration_statement` thay thế cho phần còn lại.

**Ghi vào báo cáo:** phiên bản, RAM/core của máy, dung lượng DB, 10 bảng lớn nhất, các GUC khác mặc định.

---

## §2. Sức khoẻ hệ thống — 8 kiểm tra nhanh

### Làm ngay

Chạy đủ 8 nhóm query đã học, ghi lại kết quả:

**1. Bloat và vacuum** (Day 22-23)
```sql
SELECT relname, n_live_tup, n_dead_tup,
       round(n_dead_tup::numeric/nullif(n_live_tup,0),3) AS ty_le_chet,
       last_vacuum, last_autovacuum, last_analyze, last_autoanalyze,
       pg_size_pretty(pg_total_relation_size(relid)) AS size
FROM pg_stat_user_tables
WHERE n_dead_tup > 10000
ORDER BY n_dead_tup DESC LIMIT 20;
```

**2. XID age** (Day 25)
```sql
SELECT c.relname, age(c.relfrozenxid) AS xid_age,
       round(100.0*age(c.relfrozenxid)/current_setting('autovacuum_freeze_max_age')::numeric,1) AS pct
FROM pg_class c WHERE c.relkind='r'
ORDER BY age(c.relfrozenxid) DESC LIMIT 10;
```

**3. Transaction dài / idle in transaction** (Day 22)
```sql
SELECT pid, usename, state, now()-xact_start AS xact_age,
       now()-state_change AS idle_time, left(query,80)
FROM pg_stat_activity
WHERE xact_start IS NOT NULL AND now()-xact_start > interval '1 min'
ORDER BY xact_start;
```

**4. Replication slot và WAL** (Day 37-38)
```sql
SELECT slot_name, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_giu
FROM pg_replication_slots;
SELECT * FROM pg_stat_replication;
SELECT * FROM pg_stat_archiver;
```

**5. Index không dùng / trùng lặp / INVALID** (Day 07, Day 10)
```sql
SELECT s.relname, s.indexrelname, s.idx_scan,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS size,
       i.indisunique, i.indisprimary, i.indisvalid
FROM pg_stat_user_indexes s JOIN pg_index i ON i.indexrelid = s.indexrelid
WHERE s.idx_scan < 50 AND NOT i.indisprimary AND NOT i.indisunique
ORDER BY pg_relation_size(s.indexrelid) DESC LIMIT 20;

SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;
SELECT stats_reset FROM pg_stat_database WHERE datname = current_database();
```

**6. TOAST và cột lớn** (Day 41)
```sql
SELECT c.relname,
       pg_size_pretty(pg_relation_size(c.oid))           AS main,
       pg_size_pretty(pg_relation_size(c.reltoastrelid)) AS toast,
       round(100.0*pg_relation_size(c.reltoastrelid)/nullif(pg_total_relation_size(c.oid),0),1) AS pct_toast
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE c.relkind='r' AND n.nspname NOT IN ('pg_catalog','information_schema') AND c.reltoastrelid<>0
ORDER BY pg_relation_size(c.reltoastrelid) DESC LIMIT 10;
```

**7. Plan cache và prepared statement** (Day 42)
```sql
SELECT count(*) AS so_prepared FROM pg_prepared_statements;
SELECT name, generic_plans, custom_plans FROM pg_prepared_statements
ORDER BY generic_plans DESC LIMIT 10;
```

**8. Tỷ lệ HOT và cache hit** (Day 24)
```sql
SELECT relname, n_tup_upd, n_tup_hot_upd,
       round(n_tup_hot_upd::numeric/nullif(n_tup_upd,0),3) AS ty_le_hot,
       (SELECT count(*) FROM pg_index WHERE indrelid=relid) AS so_index
FROM pg_stat_user_tables WHERE n_tup_upd > 100000 ORDER BY ty_le_hot NULLS LAST LIMIT 10;

SELECT datname,
       round(100.0*blks_hit/nullif(blks_hit+blks_read,0),2) AS cache_hit_pct,
       xact_commit, xact_rollback,
       round(100.0*xact_rollback/nullif(xact_commit+xact_rollback,0),2) AS rollback_pct,
       deadlocks, temp_files, pg_size_pretty(temp_bytes) AS temp
FROM pg_stat_database WHERE datname = current_database();
```

**Ghi vào báo cáo:** với mỗi nhóm, kết quả + đánh giá OK/WARNING/CRITICAL + hành động đề xuất.

---

## §3. Top query

### Làm ngay

```sql
SELECT substring(query, 1, 120) AS q, calls,
       round(total_exec_time::numeric/1000, 1)  AS total_s,
       round(mean_exec_time::numeric, 2)        AS mean_ms,
       round(stddev_exec_time::numeric, 2)      AS stddev_ms,
       round(100*total_exec_time/sum(total_exec_time) OVER (), 1) AS pct,
       rows/nullif(calls,0)                     AS rows_moi_lan,
       shared_blks_hit + shared_blks_read       AS bufs,
       temp_blks_written                        AS temp_w,
       pg_size_pretty(wal_bytes::bigint)        AS wal
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%' AND calls > 10
ORDER BY total_exec_time DESC LIMIT 15;
```

Ba bảng riêng:
```sql
-- theo mean (ảnh hưởng trải nghiệm)
... ORDER BY mean_exec_time DESC LIMIT 10;
-- theo stddev (không ổn định, đáng nghi)
... ORDER BY stddev_exec_time DESC LIMIT 10;
-- theo temp (thiếu work_mem)
... WHERE temp_blks_written > 0 ORDER BY temp_blks_written DESC LIMIT 10;
```

Chọn **5 query** để phân tích sâu.

**Ghi vào báo cáo:** ba bảng + tiêu chí chọn 5 query.

---

## §4. Phân tích 5 query

### Làm ngay

Với mỗi query: lấy `EXPLAIN` (không `ANALYZE` nếu là DML hoặc nếu query nặng). Với `SELECT` nhẹ, `EXPLAIN (ANALYZE, BUFFERS)` là chấp nhận được — nhưng đặt `statement_timeout` trước.

Kiểm tra statistics của các cột lọc:
```sql
SELECT attname, null_frac, n_distinct, correlation,
       array_length(most_common_vals::text::text[],1) AS mcv_len
FROM pg_stats WHERE tablename = '<bang>' AND attname IN ('<cot>', ...);

SELECT last_analyze, last_autoanalyze FROM pg_stat_user_tables WHERE relname='<bang>';
SELECT relname, reloptions FROM pg_class WHERE relname='<bang>';
```

**Ghi vào báo cáo — mỗi query một mục:**

```
### Query N — <mô tả nghiệp vụ nó phục vụ>
**SQL (đã chuẩn hoá):**
**Tần suất:** N lần/ngày, chiếm X% tổng thời gian
**Plan hiện tại:** (phần quan trọng)
**Chẩn đoán:** node nào là gốc bệnh, vì sao
**Bằng chứng:** rows đoán vs thật, buffers, temp, correlation...
**Đề xuất sửa:** (SQL cụ thể, ví dụ `CREATE INDEX CONCURRENTLY ...`)
**Cải thiện ước tính:** X → Y ms, dựa trên cơ sở nào
**Rủi ro:** dung lượng thêm bao nhiêu, ghi chậm thêm bao nhiêu, khoá gì lúc triển khai
**Cách kiểm chứng sau khi triển khai:** query nào, chỉ số nào
```

---

## §5. Đề xuất cấu hình

### Làm ngay

Dựa trên RAM/core thật của máy và các GUC bạn thu thập ở §1:

| GUC | Hiện tại | Đề xuất | Lý do | Cần restart? |
|---|---|---|---|---|
| `shared_buffers` | | | | có |
| `effective_cache_size` | | | | không |
| `work_mem` | | | | không |
| `maintenance_work_mem` | | | | không |
| `random_page_cost` | | | | không |
| `max_connections` | | | | có |
| `wal_compression` | | | | không |
| `max_wal_size` | | | | không |
| `checkpoint_timeout` | | | | không |
| `autovacuum_vacuum_cost_limit` | | | | không |
| `idle_in_transaction_session_timeout` | | | | không |
| `max_slot_wal_keep_size` | | | | không |
| `log_min_duration_statement` | | | | không |
| `log_lock_waits` | | | | không |

Và per-table (Day 23):
```sql
SELECT format('ALTER TABLE %I SET (autovacuum_vacuum_scale_factor = %s, autovacuum_analyze_scale_factor = %s);',
  relname,
  CASE WHEN n_live_tup > 50000000 THEN '0.005'
       WHEN n_live_tup > 5000000  THEN '0.01'
       WHEN n_live_tup > 500000   THEN '0.05' ELSE '0.1' END,
  CASE WHEN n_live_tup > 5000000 THEN '0.01' ELSE '0.05' END)
FROM pg_stat_user_tables WHERE n_live_tup > 500000;
```

**Ghi vào báo cáo:** bảng đã điền + danh sách `ALTER TABLE`.

---

## §6. Kế hoạch triển khai

### Làm ngay

Sắp xếp mọi đề xuất theo **giá trị ÷ rủi ro**:

| # | Hành động | Giá trị kỳ vọng | Rủi ro | Downtime | Rollback | Ưu tiên |
|---|---|---|---|---|---|---|
| 1 | | | | | | |

Nguyên tắc sắp xếp:
- **Ưu tiên cao nhất:** GUC không cần restart, giá trị cao, rollback tức thì (`effective_cache_size`, `random_page_cost`, `log_*`)
- **Tiếp theo:** `CREATE INDEX CONCURRENTLY` cho query nóng — không khoá, rollback bằng `DROP INDEX`
- **Tiếp theo:** `ALTER TABLE ... SET (autovacuum_*)` — không khoá
- **Cuối cùng:** thay đổi schema, partitioning, GUC cần restart — cần cửa sổ bảo trì và kế hoạch riêng

Với mỗi hành động phải có:
- Câu lệnh chính xác sẽ chạy
- Cách kiểm chứng nó có tác dụng (chỉ số nào, ngưỡng nào)
- Cách rollback
- Ai cần được thông báo

---

## §7. Viết báo cáo cuối

### Làm ngay

Tạo `days/day-48/report.md` — viết như tài liệu bạn **thật sự gửi cho tech lead**. Cấu trúc:

```markdown
# Audit Postgres production — <ngày>

## Tóm tắt điều hành
<5-7 gạch đầu dòng. Phát hiện chính, tác động, đề xuất. Người đọc chỉ đọc phần này.>

## Hiện trạng
<phiên bản, phần cứng, dung lượng, workload>

## Phát hiện

### CRITICAL
<vấn đề có thể gây sự cố: xid age cao, slot bỏ quên, transaction dài, đĩa sắp đầy>

### WARNING
<vấn đề hiệu năng: query chậm, bloat, index thiếu/thừa>

### NOTICE
<cải thiện nên làm nhưng không gấp>

## Phân tích 5 query nặng nhất
<từ §4>

## Đề xuất cấu hình
<từ §5>

## Rủi ro vận hành đã phát hiện
<slot bỏ quên (Day 39), transaction dài / idle in transaction (Day 40),
 index INVALID (Day 43), migration nguy hiểm trong repo (Day 43-44)>

## Kế hoạch triển khai
<từ §6, sắp theo ưu tiên — mỗi hành động ghi rõ lock mode và cách chạy an toàn>

## Monitoring còn thiếu
<chỉ số nào chưa có alert: xid age, replication lag, bloat, slot không hoạt động,
 WAL bị slot giữ, idle in transaction, deadlock rate, cache hit, temp files, index INVALID>

## Phụ lục
<query đã dùng, số liệu thô>
```

---

## Kết ngày

### Đạt khi

Báo cáo này đủ chất lượng để bạn **thật sự gửi cho tech lead** mà không cần sửa gì. Cụ thể:

- Phần tóm tắt đọc được trong 2 phút và nêu đúng vấn đề quan trọng nhất
- Mọi phát hiện có **số liệu**, không có câu nào kiểu "có vẻ chậm"
- Mọi đề xuất có **câu lệnh cụ thể**, ước tính cải thiện, rủi ro, và cách rollback
- Có phân biệt rõ CRITICAL / WARNING / NOTICE
- Phần monitoring chỉ ra được lỗ hổng quan sát, không chỉ liệt kê vấn đề hiện có

**Xong thì gõ `/review-bai`.** Tôi sẽ đọc báo cáo với con mắt của một tech lead khó tính: chỗ nào thiếu số, chỗ nào kết luận vội, chỗ nào rủi ro chưa được nêu.

---

# Hết 48 ngày

## Bạn đã đi từ đâu tới đâu

**Ngày 1:** "hiểu sơ sơ cách đánh index, 3 loại join, MVCC"

**Ngày 48:** nhìn `EXPLAIN (ANALYZE, BUFFERS)` biết bệnh, sửa được, chứng minh được bằng số, đổi được schema trên bảng lớn mà không chặn ai, và viết được báo cáo audit cho production.

Cụ thể bạn đã có:
- Đọc plan tới mức nhân `loops`, trừ thời gian con, tìm node gốc bệnh
- Đo bằng buffers thay vì ms
- Chọn index đúng thứ tự cột, biết cái giá của từng index
- Chẩn đoán ước lượng sai từ `pg_stats` và sửa bằng statistics
- Hiểu `work_mem` quyết định sống chết ở join/sort/aggregate
- Vòng đời MVCC, vacuum, bloat, wraparound — và monitoring cho chúng
- Tái hiện được mọi anomaly tương tranh và biết công cụ nào chặn cái gì
- Chiến lược lưu time-series có số liệu so sánh
- Vận hành: pooling, WAL, replication, logical decoding/CDC, và các bẫy của chúng
- Đọc wait event để biết hệ đang chờ đĩa, chờ lock, hay chờ chính ứng dụng
- TOAST và cái giá thật của `SELECT *` trên bảng có cột lớn
- Prepared statement qua driver/pooler và bẫy ép kiểu tham số
- Đổi schema trên bảng lớn theo expand/contract mà p99 không đổi

## Tiếp theo — Tier 2

Giờ mới nên sang **performance engineering**:
- `pprof` (Go: CPU, heap, goroutine, block, mutex), async-profiler / JFR (Java), đọc flame graph
- Runtime internals: Go scheduler (GMP), escape analysis, `GOGC`/`GOMEMLIMIT`; JVM G1 vs ZGC
- Tail latency: p99/p999, Little's law (bạn đã gặp ở Day 36), coordinated omission
- Backpressure: bounded queue, load shedding, adaptive concurrency, retry storm

Sách: *Systems Performance* — Brendan Gregg (tra cứu dần, không đọc một lèo).

Rồi Tier 3 — distributed systems từ nguyên lý: MIT 6.824 Raft labs bằng Go, Kafka sâu, và **lúc đó** mini LSM-tree mới có nghĩa (nhiều thứ bạn học ở tuần 5-7 sẽ khớp vào).

## Việc cần làm ngay tuần này

Đừng để 48 ngày này thành kiến thức chết:

1. Gửi báo cáo Day 48 và `migration-playbook.md` (Day 45) cho team
2. Triển khai 2-3 hành động ưu tiên cao nhất
3. Thêm các alert còn thiếu vào monitoring
4. Đo lại sau 1 tuần và ghi con số thật

Kiến thức chỉ thành kỹ năng khi nó đổi được một con số trên production.
