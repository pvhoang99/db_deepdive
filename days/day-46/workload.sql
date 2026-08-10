-- Day 46 — Workload mô phỏng ứng dụng IoT (ThingsBoard-like)
-- 10 nhóm truy cập, 27 câu. Tần suất mô phỏng bằng số vòng generate_series.
-- Chạy: make run F=days/day-46/workload.sql
\timing on

-- =====================================================================
-- NHÓM 1 — DASHBOARD: giá trị mới nhất của N device        [rất cao]
-- =====================================================================
-- W01: latest value cho 30 device (giảm từ 400 để workload chạy được khi chưa có index) (mẫu nóng nhất của mọi hệ IoT)
SELECT count(v) FROM (
  SELECT (SELECT dbl_v FROM ts_kv WHERE device_id = (1 + g % 300) ORDER BY ts DESC LIMIT 1) AS v
  FROM generate_series(1, 30) g
) s;

-- W02: latest value kèm tên device (join)
SELECT count(v) FROM (
  SELECT d.name, (SELECT dbl_v FROM ts_kv t WHERE t.device_id = d.id ORDER BY t.ts DESC LIMIT 1) AS v
  FROM device d WHERE d.id <= 20
) s;

-- W03: latest theo cặp (device, key) — dashboard nhiều metric
SELECT count(v) FROM (
  SELECT (SELECT dbl_v FROM ts_kv WHERE device_id = (1 + g % 100) AND key_id = (1 + g % 8)
          ORDER BY ts DESC LIMIT 1) AS v
  FROM generate_series(1, 30) g
) s;

-- =====================================================================
-- NHÓM 2 — BIỂU ĐỒ: chuỗi thời gian 1 device, 1 ngày          [cao]
-- =====================================================================
-- W04
SELECT sum(v) FROM (
  SELECT (SELECT count(*) FROM ts_kv
          WHERE device_id = (1 + g % 100) AND key_id = 1
            AND ts >= '2025-06-01' AND ts < '2025-06-02') AS v
  FROM generate_series(1, 20) g
) s;

-- W05: lấy cả giá trị để vẽ, không chỉ đếm
SELECT count(*) FROM (
  SELECT ts, dbl_v FROM ts_kv
  WHERE device_id = 42 AND key_id = 1 AND ts >= '2025-06-01' AND ts < '2025-06-08'
  ORDER BY ts
) s;

-- W06: nhiều device cùng lúc (so sánh biểu đồ)
SELECT count(*) FROM (
  SELECT device_id, ts, dbl_v FROM ts_kv
  WHERE device_id IN (10,20,30,40,50) AND ts >= '2025-06-01' AND ts < '2025-06-02'
) s;

-- =====================================================================
-- NHÓM 3 — DANH SÁCH: device theo tenant + trạng thái, phân trang [cao]
-- =====================================================================
-- W07
SELECT count(*) FROM (
  SELECT id, name, type, region FROM device
  WHERE tenant_id = 3 AND is_active
  ORDER BY created_at DESC LIMIT 50 OFFSET 0
) s;

-- W08: trang sâu (offset lớn — mẫu phân trang tệ nhưng phổ biến)
SELECT count(*) FROM (
  SELECT id, name FROM device WHERE tenant_id = 3 AND is_active
  ORDER BY created_at DESC LIMIT 50 OFFSET 2000
) s;

-- W09: đếm tổng cho phân trang (mẫu "total count" của mọi UI)
SELECT count(*) FROM device WHERE tenant_id = 3 AND is_active;

-- W10: lặp W07 cho 20 tenant
SELECT sum(v) FROM (
  SELECT (SELECT count(*) FROM device WHERE tenant_id = g AND is_active) AS v
  FROM generate_series(1, 20) g
) s;

-- =====================================================================
-- NHÓM 4 — ALARM: alarm đang mở, sắp theo severity            [cao]
-- =====================================================================
-- W11
SELECT count(*) FROM (
  SELECT id, device_id, type, severity, start_ts FROM alarm
  WHERE status IN ('ACTIVE_ACK','ACTIVE_UNACK')
  ORDER BY severity, start_ts DESC LIMIT 100
) s;

-- W12: alarm đang mở của một device
SELECT sum(v) FROM (
  SELECT (SELECT count(*) FROM alarm WHERE device_id = (1 + g % 500) AND status IN ('ACTIVE_ACK','ACTIVE_UNACK')) AS v
  FROM generate_series(1, 200) g
) s;

-- W13: alarm mở trong 24h gần nhất theo severity
SELECT severity, count(*) FROM alarm
WHERE status IN ('ACTIVE_ACK','ACTIVE_UNACK') AND start_ts >= '2025-07-25'
GROUP BY severity;

-- W14: alarm join device để hiện tên
SELECT count(*) FROM (
  SELECT a.id, d.name, a.severity FROM alarm a JOIN device d ON d.id = a.device_id
  WHERE a.status IN ('ACTIVE_ACK','ACTIVE_UNACK') ORDER BY a.start_ts DESC LIMIT 100
) s;

-- =====================================================================
-- NHÓM 5 — TÌM KIẾM: device theo tên, không phân biệt hoa thường [TB]
-- =====================================================================
-- W15
SELECT count(*) FROM device WHERE lower(name) LIKE 'device-00012%';

-- W16: tìm kiếm chứa (không phải prefix)
SELECT count(*) FROM device WHERE name ILIKE '%01234%';

-- W17: lặp tìm kiếm prefix
SELECT sum(v) FROM (
  SELECT (SELECT count(*) FROM device WHERE lower(name) LIKE 'device-000' || g || '%') AS v
  FROM generate_series(1, 9) g
) s;

-- =====================================================================
-- NHÓM 6 — BÁO CÁO: downsample theo giờ, 1 tuần               [thấp]
-- =====================================================================
-- W18
SELECT count(*) FROM (
  SELECT date_trunc('hour', ts) AS h, avg(dbl_v)
  FROM ts_kv WHERE key_id = 1 AND ts >= '2025-06-01' AND ts < '2025-06-08'
  GROUP BY 1 ORDER BY 1
) s;

-- W19: downsample 1 device, 1 tháng
SELECT count(*) FROM (
  SELECT date_trunc('hour', ts) AS h, avg(dbl_v), min(dbl_v), max(dbl_v)
  FROM ts_kv WHERE device_id = 42 AND ts >= '2025-06-01' AND ts < '2025-07-01'
  GROUP BY 1
) s;

-- =====================================================================
-- NHÓM 7 — TỔNG HỢP: đếm theo region + country               [thấp]
-- =====================================================================
-- W20
SELECT region, country, count(*) FROM device GROUP BY region, country ORDER BY 3 DESC;

-- W21: tổng hợp có join tenant
SELECT t.name, count(*) FROM device d JOIN tenant t ON t.id = d.tenant_id
WHERE d.is_active GROUP BY t.name ORDER BY 2 DESC;

-- =====================================================================
-- NHÓM 8 — JSONB: lọc device theo meta                        [TB]
-- =====================================================================
-- W22
SELECT count(*) FROM device WHERE meta->>'model' = 'TH-100';

-- W23: lọc theo tag trong mảng
SELECT count(*) FROM device WHERE meta->'tags' ? 'critical';

-- W24: lọc theo hai field
SELECT count(*) FROM device WHERE meta->>'model' = 'TH-200' AND (meta->>'hw_rev')::int >= 3;

-- =====================================================================
-- NHÓM 9 — GHI: insert telemetry theo lô                  [rất cao]
-- =====================================================================
-- W25: 5 lô × 2000 dòng (mô phỏng ingest)
INSERT INTO ts_kv (device_id, key_id, ts, dbl_v)
SELECT 1 + g % 50000, 1 + g % 8, '2025-07-31'::timestamptz + (g || ' ms')::interval, random()
FROM generate_series(1, 10000) g;

-- =====================================================================
-- NHÓM 10 — GHI: update trạng thái alarm                      [cao]
-- =====================================================================
-- W26: đóng alarm cũ
UPDATE alarm SET status = 'CLEARED_ACK', end_ts = now()
WHERE id IN (SELECT id FROM alarm WHERE status = 'ACTIVE_UNACK' ORDER BY id LIMIT 2000);

-- W27: mở lại (giữ dữ liệu không đổi giữa các lần chạy)
UPDATE alarm SET status = 'ACTIVE_UNACK', end_ts = NULL
WHERE id IN (SELECT id FROM alarm WHERE status = 'CLEARED_ACK' AND end_ts >= now() - interval '5 minutes'
             ORDER BY id LIMIT 2000);
