-- Day 45 §6 — Diễn tập migration: thêm cột quality + partial index trên ts_kv (5M dòng)
-- Yêu cầu: không có lần chờ lock > 3s, p99 probe không tăng quá 2×,
--          dừng giữa chừng chạy tiếp được, mọi bước rollback được.
--
-- CHẠY NGOÀI TRANSACTION (có CREATE INDEX CONCURRENTLY).

\timing on

-- ============ BƯỚC 0: kiểm tra trước ============
-- Không chạy tiếp nếu có transaction mở > 60s (nó sẽ chặn ALTER và làm treo CONCURRENTLY)
SELECT pid, state, round(EXTRACT(epoch FROM now()-xact_start)::numeric,1) AS xact_giay,
       substring(query,1,60) AS q
FROM pg_stat_activity
WHERE xact_start < now() - interval '60 seconds' AND backend_type='client backend'
ORDER BY xact_start;
-- Không được có index INVALID tồn đọng
SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;

-- ============ BƯỚC 1 (EXPAND): thêm cột, có DEFAULT hằng ============
-- DEFAULT hằng ⇒ KHÔNG rewrite (PG11+). Lock ACCESS EXCLUSIVE ~ms.
SET lock_timeout = '3s';
ALTER TABLE ts_kv ADD COLUMN quality smallint DEFAULT 0;
-- Rollback: ALTER TABLE ts_kv DROP COLUMN quality;

-- ============ BƯỚC 2 (MIGRATE): backfill theo lô ============
-- Idempotent (WHERE quality IS NULL), commit mỗi lô, có nghỉ cho autovacuum.
-- Ở đây DEFAULT đã lo cho dòng cũ nên chỉ còn dòng NULL do ghi trước bước 1 — vẫn giữ
-- vòng lặp để mẫu này dùng lại được cho trường hợp không có DEFAULT.
SET lock_timeout = '3s';
DO $$
DECLARE n int; tong bigint := 0;
BEGIN
  LOOP
    UPDATE ts_kv SET quality = 0
    WHERE ctid IN (SELECT ctid FROM ts_kv WHERE quality IS NULL LIMIT 50000);
    GET DIAGNOSTICS n = ROW_COUNT;
    EXIT WHEN n = 0;
    tong := tong + n;
    COMMIT;
    PERFORM pg_sleep(0.02);          -- nhịp cho autovacuum và replica
  END LOOP;
  RAISE NOTICE 'backfill xong: % dòng', tong;
END $$;

-- ============ BƯỚC 3: NOT NULL bằng CHECK NOT VALID ============
SET lock_timeout = '3s';
ALTER TABLE ts_kv ADD CONSTRAINT ck_quality_nn CHECK (quality IS NOT NULL) NOT VALID;  -- ~ms
-- Rollback: ALTER TABLE ts_kv DROP CONSTRAINT ck_quality_nn;

-- Quét bảng dưới SHARE UPDATE EXCLUSIVE — KHÔNG chặn đọc/ghi.
SET lock_timeout = '3s';
ALTER TABLE ts_kv VALIDATE CONSTRAINT ck_quality_nn;

SET lock_timeout = '3s';
ALTER TABLE ts_kv ALTER COLUMN quality SET NOT NULL;   -- ~ms vì đã có CHECK hợp lệ
ALTER TABLE ts_kv DROP CONSTRAINT ck_quality_nn;

-- ============ BƯỚC 4: partial index bằng CONCURRENTLY ============
-- KHÔNG nằm trong transaction. statement_timeout=0 để không bị giết giữa chừng.
SET lock_timeout = '3s';
SET statement_timeout = '0';
CREATE INDEX CONCURRENTLY ix_tskv_quality ON ts_kv (device_id, ts) WHERE quality > 0;

-- ============ BƯỚC 5: xác nhận ============
SELECT indexrelid::regclass AS idx, indisvalid FROM pg_index WHERE NOT indisvalid;   -- phải rỗng
SELECT count(*) FILTER (WHERE quality IS NULL) AS con_null, count(*) AS tong FROM ts_kv;
