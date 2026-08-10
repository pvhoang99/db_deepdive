-- ============================================================================
-- audit.sql — Bộ kiểm tra sức khoẻ Postgres, CHỈ ĐỌC, an toàn cho production
-- ============================================================================
-- Dùng: psql -h <host> -U <user> -d <db> -f audit.sql > audit-$(date +%F).txt
--
-- Mọi câu lệnh trong file này đều là SELECT trên catalog / view thống kê.
-- KHÔNG có DDL, KHÔNG có EXPLAIN ANALYZE, KHÔNG đổi GUC.
-- Chạy được trên replica read-only.
-- ============================================================================

\pset pager off
\timing on
\set ON_ERROR_STOP off

-- Bảo hiểm cho phiên (không ảnh hưởng hệ thống)
SET statement_timeout = '30s';
SET lock_timeout = '2s';
SET idle_in_transaction_session_timeout = '60s';

\echo '################ §1. HIỆN TRẠNG ################'

\echo '--- 1.1 phiên bản ---'
SELECT version();

\echo '--- 1.2 GUC khác mặc định ---'
SELECT name, setting, unit, source, pending_restart
FROM pg_settings WHERE source NOT IN ('default','override') ORDER BY name;

\echo '--- 1.3 GUC quan trọng (kể cả đang ở mặc định) ---'
SELECT name, setting, unit FROM pg_settings WHERE name IN (
  'shared_buffers','effective_cache_size','work_mem','maintenance_work_mem',
  'random_page_cost','seq_page_cost','max_connections','max_wal_size','min_wal_size',
  'checkpoint_timeout','checkpoint_completion_target','wal_compression','wal_level',
  'autovacuum_vacuum_cost_limit','autovacuum_vacuum_cost_delay','autovacuum_naptime',
  'autovacuum_freeze_max_age','max_slot_wal_keep_size','idle_in_transaction_session_timeout',
  'statement_timeout','lock_timeout','log_min_duration_statement','log_lock_waits',
  'default_toast_compression','plan_cache_mode','max_worker_processes',
  'max_parallel_workers_per_gather','jit'
) ORDER BY name;

\echo '--- 1.4 dung lượng database ---'
SELECT datname, pg_size_pretty(pg_database_size(datname)) AS size
FROM pg_database WHERE datistemplate = false ORDER BY pg_database_size(datname) DESC;

\echo '--- 1.5 20 bảng lớn nhất ---'
SELECT schemaname, relname,
       pg_size_pretty(pg_total_relation_size(relid)) AS tong,
       pg_size_pretty(pg_relation_size(relid))       AS heap,
       pg_size_pretty(pg_indexes_size(relid))        AS idx,
       n_live_tup, n_dead_tup
FROM pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC LIMIT 20;

\echo '--- 1.6 extension ---'
SELECT extname, extversion FROM pg_extension ORDER BY 1;

\echo '--- 1.7 stats được reset lần cuối khi nào (mọi số dưới đây tính từ mốc này) ---'
SELECT datname, stats_reset, now()-stats_reset AS tuoi_stats
FROM pg_stat_database WHERE datname = current_database();


\echo ''
\echo '################ §2. SỨC KHOẺ — 8 KIỂM TRA ################'

\echo '--- 2.1 BLOAT & VACUUM (ngưỡng: ty_le_chet > 0.2 = WARNING) ---'
SELECT relname, n_live_tup, n_dead_tup,
       round(n_dead_tup::numeric/nullif(n_live_tup,0),3) AS ty_le_chet,
       last_vacuum, last_autovacuum, last_analyze, last_autoanalyze,
       pg_size_pretty(pg_total_relation_size(relid)) AS size
FROM pg_stat_user_tables
WHERE n_dead_tup > 10000
ORDER BY n_dead_tup DESC LIMIT 20;

\echo '--- 2.2 XID AGE (ngưỡng: pct > 50 = WARNING, > 80 = CRITICAL) ---'
SELECT c.relname, age(c.relfrozenxid) AS xid_age,
       round(100.0*age(c.relfrozenxid)/current_setting('autovacuum_freeze_max_age')::numeric,1) AS pct
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE c.relkind IN ('r','m','t') AND n.nspname NOT IN ('pg_catalog','information_schema')
ORDER BY age(c.relfrozenxid) DESC LIMIT 10;

SELECT datname, age(datfrozenxid) AS db_xid_age,
       round(100.0*age(datfrozenxid)/current_setting('autovacuum_freeze_max_age')::numeric,1) AS pct
FROM pg_database ORDER BY age(datfrozenxid) DESC LIMIT 5;

\echo '--- 2.3 TRANSACTION DÀI / IDLE IN TRANSACTION (ngưỡng: > 5 phút = WARNING) ---'
SELECT pid, usename, application_name, state,
       now()-xact_start   AS xact_age,
       now()-state_change AS trong_state,
       backend_xmin, age(backend_xmin) AS xmin_age,
       wait_event_type, wait_event,
       left(query,80) AS q
FROM pg_stat_activity
WHERE xact_start IS NOT NULL AND now()-xact_start > interval '1 min'
ORDER BY xact_start;

\echo '--- 2.3b AI ĐANG GHIM xmin horizon (4 nguồn — Day 40 §5) ---'
SELECT 'backend' AS nguon, pid::text AS ten, age(backend_xmin) AS tuoi
FROM pg_stat_activity WHERE backend_xmin IS NOT NULL
UNION ALL
SELECT 'replica(hot_standby_feedback)', application_name, age(backend_xmin)
FROM pg_stat_replication WHERE backend_xmin IS NOT NULL
UNION ALL
SELECT 'slot', slot_name, age(coalesce(catalog_xmin, xmin))
FROM pg_replication_slots WHERE coalesce(catalog_xmin, xmin) IS NOT NULL
UNION ALL
SELECT 'prepared_xact', gid, age(transaction) FROM pg_prepared_xacts
ORDER BY tuoi DESC NULLS LAST;

\echo '--- 2.4 REPLICATION SLOT & WAL (ngưỡng: wal_status <> reserved = CRITICAL) ---'
SELECT slot_name, plugin, slot_type, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_giu,
       coalesce(pg_size_pretty(safe_wal_size),'khong gioi han') AS con_du
FROM pg_replication_slots
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC NULLS LAST;

SELECT application_name, client_addr, state, sync_state,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn))   AS lag_gui,
       pg_size_pretty(pg_wal_lsn_diff(sent_lsn, flush_lsn))              AS lag_ghi,
       pg_size_pretty(pg_wal_lsn_diff(flush_lsn, replay_lsn))            AS lag_apdung,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag_tong,
       write_lag, flush_lag, replay_lag
FROM pg_stat_replication;

SELECT count(*) AS wal_segment, pg_size_pretty(sum(size)) AS pg_wal_size FROM pg_ls_waldir();
SELECT archived_count, failed_count, last_failed_time, last_failed_wal FROM pg_stat_archiver;

SELECT num_timed, num_requested,
       round(100.0*num_requested/nullif(num_timed+num_requested,0),1) AS pct_requested,
       round((write_time/1000.0)::numeric,1) AS write_s, round((sync_time/1000.0)::numeric,1) AS sync_s,
       buffers_written, stats_reset
FROM pg_stat_checkpointer;

\echo '--- 2.5 INDEX: không dùng / INVALID / trùng lặp ---'
SELECT s.relname, s.indexrelname, s.idx_scan,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS size,
       i.indisunique, i.indisprimary, i.indisvalid
FROM pg_stat_user_indexes s JOIN pg_index i ON i.indexrelid = s.indexrelid
WHERE s.idx_scan < 50 AND NOT i.indisprimary AND NOT i.indisunique
ORDER BY pg_relation_size(s.indexrelid) DESC LIMIT 20;

\echo 'index INVALID (phải rỗng):'
SELECT indexrelid::regclass AS idx, indrelid::regclass AS bang, indisready
FROM pg_index WHERE NOT indisvalid;

\echo 'constraint chưa validate (phải là quyết định có chủ đích):'
SELECT conrelid::regclass AS bang, conname, contype FROM pg_constraint WHERE NOT convalidated;

\echo 'index trùng lặp (b là tiền tố của a):'
SELECT a.indrelid::regclass AS bang,
       a.indexrelid::regclass AS index_bao_ham,
       b.indexrelid::regclass AS index_thua,
       pg_size_pretty(pg_relation_size(b.indexrelid)) AS size_thua
FROM pg_index a JOIN pg_index b ON a.indrelid = b.indrelid AND a.indexrelid <> b.indexrelid
WHERE a.indkey::text LIKE b.indkey::text || ' %'
  AND NOT b.indisprimary AND NOT b.indisunique
  AND a.indpred IS NULL AND b.indpred IS NULL
  AND a.indexprs IS NULL AND b.indexprs IS NULL;

\echo '--- 2.6 TOAST (ngưỡng: pct_toast > 50 = xem lại SELECT * — Day 41) ---'
SELECT c.relname,
       pg_size_pretty(pg_relation_size(c.oid))           AS main,
       pg_size_pretty(pg_relation_size(c.reltoastrelid)) AS toast,
       round(100.0*pg_relation_size(c.reltoastrelid)/nullif(pg_total_relation_size(c.oid),0),1) AS pct_toast
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE c.relkind='r' AND n.nspname NOT IN ('pg_catalog','information_schema')
  AND c.reltoastrelid <> 0 AND pg_relation_size(c.reltoastrelid) > 0
ORDER BY pg_relation_size(c.reltoastrelid) DESC LIMIT 10;

\echo '--- 2.7 PREPARED STATEMENT & PLAN CACHE (Day 42) ---'
SELECT count(*) AS so_prepared_trong_session_nay FROM pg_prepared_statements;
SELECT name, generic_plans, custom_plans,
       round(100.0*generic_plans/nullif(generic_plans+custom_plans,0),1) AS pct_generic
FROM pg_prepared_statements ORDER BY generic_plans DESC LIMIT 10;

\echo '--- 2.8 HOT & CACHE HIT (ngưỡng: cache_hit < 99% = WARNING; ty_le_hot < 0.5 = xem lại index/fillfactor) ---'
SELECT relname, n_tup_upd, n_tup_hot_upd,
       round(n_tup_hot_upd::numeric/nullif(n_tup_upd,0),3) AS ty_le_hot,
       (SELECT count(*) FROM pg_index WHERE indrelid=relid) AS so_index,
       (SELECT reloptions FROM pg_class WHERE oid=relid) AS reloptions
FROM pg_stat_user_tables WHERE n_tup_upd > 100000
ORDER BY ty_le_hot NULLS LAST LIMIT 10;

SELECT datname,
       round(100.0*blks_hit/nullif(blks_hit+blks_read,0),2) AS cache_hit_pct,
       xact_commit, xact_rollback,
       round(100.0*xact_rollback/nullif(xact_commit+xact_rollback,0),2) AS rollback_pct,
       deadlocks, temp_files, pg_size_pretty(temp_bytes) AS temp,
       blk_read_time, blk_write_time
FROM pg_stat_database WHERE datname = current_database();

\echo '--- 2.9 CONNECTION (Day 36) ---'
SELECT count(*) FILTER (WHERE state='active')              AS dang_chay,
       count(*) FILTER (WHERE state='idle')                AS idle,
       count(*) FILTER (WHERE state='idle in transaction') AS idle_in_xact,
       count(*)                                            AS tong,
       current_setting('max_connections')                  AS max_conn
FROM pg_stat_activity WHERE backend_type='client backend';

SELECT wait_event_type, wait_event, count(*)
FROM pg_stat_activity WHERE backend_type='client backend' AND state='active'
GROUP BY 1,2 ORDER BY 3 DESC;


\echo ''
\echo '################ §3. TOP QUERY ################'

\echo '--- 3.1 theo TỔNG thời gian (đâu là nơi tiêu tiền) ---'
SELECT substring(regexp_replace(query,E'\\s+',' ','g'),1,110) AS q, calls,
       round((total_exec_time/1000)::numeric,1)  AS total_s,
       round(mean_exec_time::numeric,2)          AS mean_ms,
       round(stddev_exec_time::numeric,2)        AS stddev_ms,
       round((100*total_exec_time/sum(total_exec_time) OVER ())::numeric,1) AS pct,
       rows/nullif(calls,0)                      AS rows_moi_lan,
       shared_blks_hit + shared_blks_read        AS bufs,
       temp_blks_written                         AS temp_w,
       pg_size_pretty(wal_bytes::bigint)         AS wal
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%' AND calls > 10
ORDER BY total_exec_time DESC LIMIT 15;

\echo '--- 3.2 theo MEAN (ảnh hưởng trải nghiệm người dùng) ---'
SELECT substring(regexp_replace(query,E'\\s+',' ','g'),1,110) AS q, calls,
       round(mean_exec_time::numeric,2) AS mean_ms,
       round((total_exec_time/1000)::numeric,1) AS total_s
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%' AND calls > 10
ORDER BY mean_exec_time DESC LIMIT 10;

\echo '--- 3.3 theo STDDEV (không ổn định — đáng nghi nhất) ---'
SELECT substring(regexp_replace(query,E'\\s+',' ','g'),1,110) AS q, calls,
       round(mean_exec_time::numeric,2) AS mean_ms,
       round(stddev_exec_time::numeric,2) AS stddev_ms,
       round((stddev_exec_time/nullif(mean_exec_time,0))::numeric,2) AS he_so_bien_thien
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%' AND calls > 10 AND mean_exec_time > 1
ORDER BY stddev_exec_time DESC LIMIT 10;

\echo '--- 3.4 tràn temp (thiếu work_mem — Day 16-17) ---'
SELECT substring(regexp_replace(query,E'\\s+',' ','g'),1,110) AS q, calls,
       temp_blks_written, pg_size_pretty((temp_blks_written*8192)::bigint) AS temp_size,
       round(mean_exec_time::numeric,2) AS mean_ms
FROM pg_stat_statements
WHERE temp_blks_written > 0 ORDER BY temp_blks_written DESC LIMIT 10;

\echo '--- 3.5 sinh WAL nhiều nhất (ảnh hưởng replica & archive — Day 37-38) ---'
SELECT substring(regexp_replace(query,E'\\s+',' ','g'),1,110) AS q, calls,
       pg_size_pretty(wal_bytes::bigint) AS wal, wal_records, wal_fpi
FROM pg_stat_statements WHERE wal_bytes > 0
ORDER BY wal_bytes DESC LIMIT 10;

\echo '--- 3.6 đọc nhiều buffer nhất trên mỗi dòng trả về (dấu hiệu thiếu index) ---'
SELECT substring(regexp_replace(query,E'\\s+',' ','g'),1,110) AS q, calls,
       shared_blks_hit + shared_blks_read AS bufs,
       rows,
       round(((shared_blks_hit+shared_blks_read)::numeric/nullif(rows,0)),1) AS buf_moi_dong
FROM pg_stat_statements
WHERE calls > 10 AND rows > 0
ORDER BY (shared_blks_hit+shared_blks_read)::numeric/nullif(rows,0) DESC LIMIT 10;


\echo ''
\echo '################ §5. SINH LỆNH ĐỀ XUẤT (chỉ IN RA, không chạy) ################'

\echo '--- 5.1 autovacuum per-table theo kích thước (Day 23) ---'
SELECT format('ALTER TABLE %I.%I SET (autovacuum_vacuum_scale_factor = %s, autovacuum_analyze_scale_factor = %s);',
  schemaname, relname,
  CASE WHEN n_live_tup > 50000000 THEN '0.005'
       WHEN n_live_tup > 5000000  THEN '0.01'
       WHEN n_live_tup > 500000   THEN '0.05' ELSE '0.1' END,
  CASE WHEN n_live_tup > 5000000 THEN '0.01' ELSE '0.05' END) AS lenh_de_xuat
FROM pg_stat_user_tables WHERE n_live_tup > 500000 ORDER BY n_live_tup DESC;

\echo '--- 5.2 index không dùng: lệnh xoá (RÀ SOÁT TRƯỚC KHI CHẠY) ---'
SELECT format('DROP INDEX CONCURRENTLY %I.%I;  -- idx_scan=%s, %s',
              schemaname, indexrelname, idx_scan,
              pg_size_pretty(pg_relation_size(indexrelid))) AS lenh_de_xuat
FROM pg_stat_user_indexes s
WHERE idx_scan = 0
  AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indexrelid=s.indexrelid AND (i.indisprimary OR i.indisunique))
ORDER BY pg_relation_size(indexrelid) DESC;

\echo '################ HẾT ################'
