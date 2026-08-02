-- =============================================================
--  Sinh dữ liệu. scale=1 -> 50k device, 5M ts_kv, 200k alarm (~350MB)
--  Chạy: ./db.sh seed 1
--
--  LƯU Ý KỸ THUẬT (đáng biết luôn):
--  Không dùng random() ở đây mà dùng hàm băm tất định rnd(n, salt).
--  Lý do: random() nằm trong subquery KHÔNG tương quan sẽ bị planner
--  tính đúng MỘT lần rồi tái sử dụng cho mọi dòng -> dữ liệu hỏng hết.
--  Băm theo khoá dòng vừa tránh được bẫy đó, vừa cho dataset tái lập
--  100% giữa các lần seed (quan trọng khi so before/after).
-- =============================================================
\if :{?scale}
\else
  \set scale 1
\endif
\timing on

-- rnd(n, salt) -> float8 trong [0,1), tất định theo (n, salt)
CREATE OR REPLACE FUNCTION rnd(n bigint, salt int) RETURNS float8
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$ SELECT abs(hashint8(n * 1000003 + salt)::bigint)::float8 / 2147483648.0 $$;

CREATE OR REPLACE FUNCTION keyid(n bigint) RETURNS smallint
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$ SELECT (ARRAY[1,1,1,2,2,3,4,5,6,7,8])[1 + floor(rnd(n, 11) * 11)::int]::smallint $$;

-- ---------- tenant ----------
INSERT INTO tenant (id, name, plan)
SELECT g, 'tenant-'||g,
       CASE WHEN g <= 2 THEN 'enterprise' WHEN g <= 8 THEN 'pro' ELSE 'free' END
FROM generate_series(1, 20) g;

-- ---------- ts_key_dict ----------
INSERT INTO ts_key_dict (key_id, key) VALUES
  (1,'temperature'), (2,'humidity'), (3,'pressure'), (4,'battery'),
  (5,'rssi'), (6,'door_open'), (7,'status'), (8,'power_w');

-- ---------- device ----------
-- region và country cùng suy ra từ MỘT giá trị rnd(g,5) -> phụ thuộc hàm hoàn hảo.
-- Planner giả định 2 cột độc lập nên sẽ ước lượng sai nặng khi lọc cả hai.
-- Đó là mồi cho bài CREATE STATISTICS (Day 13).
INSERT INTO device (id, uuid, tenant_id, name, type, region, country, firmware, is_active, created_at, meta)
SELECT
  g,
  md5(g::text)::uuid,
  CASE WHEN rnd(g,1) < 0.40 THEN 1 + floor(rnd(g,2)*2)::int      -- tenant 1-2 giữ ~40% device
       ELSE 3 + floor(rnd(g,2)*18)::int END,
  'device-'||lpad(g::text, 7, '0'),
  CASE WHEN rnd(g,3) < 0.90 THEN 'sensor'                   -- lệch 90 / 9 / 1
       WHEN rnd(g,3) < 0.99 THEN 'gateway'
       ELSE 'controller' END,
  CASE WHEN floor(rnd(g,5)*7)::int <= 2 THEN 'ap-southeast'
       WHEN floor(rnd(g,5)*7)::int  = 3 THEN 'ap-northeast'
       WHEN floor(rnd(g,5)*7)::int  = 4 THEN 'eu-west'
       ELSE 'us-east' END,
  CASE WHEN floor(rnd(g,5)*7)::int <= 2 THEN 'VN'
       WHEN floor(rnd(g,5)*7)::int  = 3 THEN 'JP'
       WHEN floor(rnd(g,5)*7)::int  = 4 THEN 'DE'
       ELSE 'US' END,
  (ARRAY['1.0.0','1.2.3','1.2.4','2.0.0-rc1'])[1 + floor(rnd(g,6)*4)::int],
  rnd(g,7) < 0.93,
  timestamptz '2024-01-01' + (rnd(g,8) * interval '600 days'),
  jsonb_build_object(
    'model',  (ARRAY['TH-100','TH-200','GW-10','PWR-5'])[1 + floor(rnd(g,9)*4)::int],
    'hw_rev', floor(rnd(g,10)*5)::int,
    'tags',   CASE WHEN rnd(g,12) < 0.30 THEN jsonb_build_array('critical')
                   WHEN rnd(g,12) < 0.60 THEN jsonb_build_array('indoor', 'floor-'||floor(rnd(g,13)*10)::int)
                   ELSE jsonb_build_array('outdoor') END
  )
FROM generate_series(1, (50000 * :scale)::int) g;

-- ---------- device_attr ----------
INSERT INTO device_attr (device_id, scope, key, str_v)
SELECT d.id, s.scope, k.key, 'v-'||floor(rnd(d.id, 40)*1000)::int
FROM device d
CROSS JOIN (VALUES ('server'),('shared')) s(scope)
CROSS JOIN (VALUES ('inactivityTimeout'),('location')) k(key)
WHERE rnd(d.id, 41) < 0.5;

-- ---------- ts_kv (bảng chính) ----------
-- ts tăng gần đơn điệu theo thứ tự chèn -> correlation cao -> BRIN rất hiệu quả (Day 31).
-- device_id lệch nặng theo power-law: vài trăm device "nói nhiều" chiếm phần lớn row.
INSERT INTO ts_kv (device_id, key_id, ts, dbl_v, bool_v, str_v)
SELECT
  1 + (power(rnd(g,20), 3) * ((50000 * :scale)::int - 1))::bigint,
  keyid(g),
  timestamptz '2025-05-01'
    + (g::float8 / (5000000 * :scale)) * interval '90 days'
    + (rnd(g,21) * interval '4 minutes'),
  CASE WHEN keyid(g) <= 5 OR keyid(g) = 8
       THEN round((20 + 15*sin(g::float8/50000) + rnd(g,22)*6)::numeric, 3)::float8 END,
  CASE WHEN keyid(g) = 6 THEN rnd(g,23) < 0.05 END,
  CASE WHEN keyid(g) = 7 THEN (ARRAY['OK','OK','OK','DEGRADED','FAULT'])[1+floor(rnd(g,24)*5)::int] END
FROM generate_series(1, (5000000 * :scale)::int) g;

-- ---------- alarm ----------
-- chỉ ~5% alarm còn active (end_ts IS NULL) -> mồi cho partial index (Day 09)
INSERT INTO alarm (id, device_id, type, severity, status, start_ts, end_ts, details)
SELECT
  g,
  1 + (power(rnd(g,30), 3) * ((50000 * :scale)::int - 1))::bigint,
  (ARRAY['HighTemperature','LowBattery','Offline','DoorOpen'])[1 + floor(rnd(g,31)*4)::int],
  CASE WHEN rnd(g,32) < 0.75 THEN 'WARNING'
       WHEN rnd(g,32) < 0.95 THEN 'MAJOR' ELSE 'CRITICAL' END,
  CASE WHEN rnd(g,33) < 0.02 THEN 'ACTIVE_UNACK'
       WHEN rnd(g,33) < 0.05 THEN 'ACTIVE_ACK'
       WHEN rnd(g,33) < 0.40 THEN 'CLEARED_UNACK' ELSE 'CLEARED_ACK' END,
  timestamptz '2025-05-01' + (rnd(g,34) * interval '90 days'),
  CASE WHEN rnd(g,33) >= 0.05
       THEN timestamptz '2025-05-01' + (rnd(g,34) * interval '90 days')
            + (rnd(g,35) * interval '3 days') END,
  jsonb_build_object('threshold', floor(rnd(g,36)*100)::int, 'value', floor(rnd(g,37)*150)::int)
FROM generate_series(1, (200000 * :scale)::int) g;

DROP FUNCTION keyid(bigint);
DROP FUNCTION rnd(bigint, int);

-- ---------- CỐ Ý KHÔNG CHẠY ANALYZE ----------
-- Day 01 bắt đầu bằng việc quan sát planner khi chưa có statistics.
\echo ''
\echo '=== seed xong ==='
SELECT relname,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total,
       c.reltuples::bigint AS reltuples_planner_thinks
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r'
ORDER BY pg_total_relation_size(c.oid) DESC;
