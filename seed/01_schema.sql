-- =============================================================
--  Lab schema: mô phỏng IoT telemetry (kiểu ThingsBoard)
--  CỐ Ý KHÔNG TẠO INDEX NÀO NGOÀI PRIMARY KEY.
--  Việc đánh index là bài tập của bạn — đừng thêm index ở đây.
-- =============================================================
\if :{?scale}
\else
  \set scale 1
\endif

DROP TABLE IF EXISTS alarm, ts_kv, device_attr, device, ts_key_dict, tenant CASCADE;

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pageinspect;   -- soi B-tree / heap page
CREATE EXTENSION IF NOT EXISTS pgstattuple;   -- đo bloat
CREATE EXTENSION IF NOT EXISTS pg_prewarm;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS btree_gin;

CREATE TABLE tenant (
  id          int PRIMARY KEY,
  name        text NOT NULL,
  plan        text NOT NULL           -- 'free' | 'pro' | 'enterprise'
);

CREATE TABLE ts_key_dict (
  key_id      smallint PRIMARY KEY,
  key         text NOT NULL UNIQUE
);

CREATE TABLE device (
  id          bigint PRIMARY KEY,
  uuid        uuid NOT NULL,
  tenant_id   int  NOT NULL,
  name        text NOT NULL,
  type        text NOT NULL,          -- lệch nặng: 90% sensor / 9% gateway / 1% controller
  region      text NOT NULL,          -- region và country PHỤ THUỘC HÀM vào nhau
  country     text NOT NULL,          --   -> bài tập CREATE STATISTICS
  firmware    text NOT NULL,
  is_active   boolean NOT NULL,
  created_at  timestamptz NOT NULL,
  meta        jsonb NOT NULL
);

CREATE TABLE device_attr (
  device_id   bigint NOT NULL,
  scope       text   NOT NULL,        -- 'server' | 'shared' | 'client'
  key         text   NOT NULL,
  str_v       text,
  PRIMARY KEY (device_id, scope, key)
);

-- Bảng chính. Append-only, ts gần như tăng dần theo thứ tự vật lý (đúng như telemetry thật)
-- KHÔNG có primary key: bạn sẽ tự quyết định index ở các bài tập.
CREATE TABLE ts_kv (
  device_id   bigint      NOT NULL,
  key_id      smallint    NOT NULL,
  ts          timestamptz NOT NULL,
  dbl_v       double precision,
  bool_v      boolean,
  str_v       text
);

CREATE TABLE alarm (
  id          bigint PRIMARY KEY,
  device_id   bigint NOT NULL,
  type        text   NOT NULL,
  severity    text   NOT NULL,        -- lệch: đa số 'WARNING'
  status      text   NOT NULL,        -- 'ACTIVE_UNACK' | 'ACTIVE_ACK' | 'CLEARED_UNACK' | 'CLEARED_ACK'
  start_ts    timestamptz NOT NULL,
  end_ts      timestamptz,            -- NULL khi alarm còn active -> bài tập partial index
  details     jsonb NOT NULL
);

-- Tắt autovacuum trên các bảng lab.
-- Lý do: Day 01 dạy về `reltuples = -1` (planner chưa biết gì về bảng).
-- Nếu để autovacuum bật, nó chạy sau ~30 giây và bài học biến mất trước khi
-- bạn kịp quan sát. Day 01 §4 sẽ bật lại sau khi bạn đã thấy hiện tượng.
ALTER TABLE tenant      SET (autovacuum_enabled = off);
ALTER TABLE ts_key_dict SET (autovacuum_enabled = off);
ALTER TABLE device      SET (autovacuum_enabled = off);
ALTER TABLE device_attr SET (autovacuum_enabled = off);
ALTER TABLE ts_kv       SET (autovacuum_enabled = off);
ALTER TABLE alarm       SET (autovacuum_enabled = off);

\echo 'schema OK (scale =' :scale ')'
