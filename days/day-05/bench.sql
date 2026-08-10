-- Day 05 — bench hỗn hợp ~20 dạng query
-- Cố ý pha trộn: nhẹ-gọi-nhiều, nặng-gọi-ít, gây temp, gây WAL.
-- Chạy:  make run F=days/day-05/bench.sql
--
-- LƯU Ý VỀ PHƯƠNG PHÁP:
-- pg_stat_statements đếm `calls` theo SỐ CÂU LỆNH được gửi lên, không phải
-- số vòng lặp bên trong một câu. Nên để mô phỏng "query nhẹ chạy 2000 lần"
-- ta phải gửi 2000 câu lệnh THẬT — dùng \gexec sinh chúng ra.
-- Viết  SELECT ... FROM generate_series(1,2000)  là SAI: nó chỉ ra calls=1.

\set QUIET on
\pset pager off
\timing off
\o /dev/null

-- ============================================================
-- NHÓM A — nhẹ nhưng gọi RẤT NHIỀU LẦN (mô phỏng traffic API)
-- ============================================================

-- A1. lookup device theo PK — 2000 lượt (endpoint nóng nhất của mọi service)
SELECT format('SELECT id, name FROM device WHERE id = %s;', 1 + mod(g, 50000))
FROM generate_series(1, 2000) g \gexec

-- A2. đếm telemetry của 1 device — 300 lượt (widget dashboard)
SELECT format('SELECT count(*) FROM ts_kv WHERE device_id = %s;', 1 + mod(g, 500))
FROM generate_series(1, 300) g \gexec

-- A3. alarm đang active của 1 device — 500 lượt (badge trên header)
SELECT format('SELECT count(*) FROM alarm WHERE device_id = %s AND end_ts IS NULL;', 1 + mod(g, 500))
FROM generate_series(1, 500) g \gexec

-- A4. giá trị mới nhất của 1 device — 400 lượt (realtime panel)
SELECT format('SELECT max(ts) FROM ts_kv WHERE device_id = %s;', 1 + mod(g, 1000))
FROM generate_series(1, 400) g \gexec

-- A5. tra dictionary — 1000 lượt (join phụ, ai cũng gọi)
SELECT format('SELECT key FROM ts_key_dict WHERE key_id = %s;', 1 + mod(g, 8))
FROM generate_series(1, 1000) g \gexec

-- ============================================================
-- NHÓM B — nặng nhưng gọi ÍT (báo cáo, export)
-- ============================================================

-- B1. top device theo lưu lượng
SELECT device_id, count(*), avg(dbl_v) FROM ts_kv GROUP BY device_id ORDER BY 2 DESC LIMIT 20;

-- B2. thống kê theo giờ trong 1 ngày
SELECT date_trunc('hour', ts) AS h, count(*), avg(dbl_v)
FROM ts_kv WHERE ts >= '2025-06-01' AND ts < '2025-06-02'
GROUP BY 1 ORDER BY 1;

-- B3. join ts_kv x device theo ngày
SELECT d.name, count(*) FROM ts_kv t JOIN device d ON d.id = t.device_id
WHERE t.ts >= '2025-06-01' AND t.ts < '2025-06-02'
GROUP BY d.name ORDER BY 2 DESC LIMIT 10;

-- B4. báo cáo alarm theo tenant + severity (alarm -> device -> tenant)
SELECT te.name, a.severity, count(*)
FROM alarm a
JOIN device d  ON d.id  = a.device_id
JOIN tenant te ON te.id = d.tenant_id
GROUP BY 1,2 ORDER BY 3 DESC LIMIT 30;

-- B5. device chưa gửi telemetry trong tháng 7 (anti-join)
SELECT count(*) FROM device d
WHERE NOT EXISTS (SELECT 1 FROM ts_kv t WHERE t.device_id = d.id AND t.ts >= '2025-07-01');

-- ============================================================
-- NHÓM C — cố ý gây temp (spill)
-- ============================================================

-- C1. sort toàn bảng trên cột không index -> external merge
SELECT device_id, ts FROM ts_kv ORDER BY dbl_v LIMIT 100;

-- C2. group by rất nhiều nhóm -> HashAgg / Sort spill
SELECT device_id, key_id, date_trunc('day', ts) AS d, count(*)
FROM ts_kv GROUP BY 1,2,3 ORDER BY 4 DESC LIMIT 50;

-- C3. distinct trên cặp cột lệch
SELECT count(*) FROM (SELECT DISTINCT device_id, key_id FROM ts_kv) s;

-- ============================================================
-- NHÓM D — ghi (sinh WAL)
-- ============================================================

-- D1. update chạm cột CÓ index
UPDATE alarm SET severity = severity WHERE id < 5000;

-- D2. update KHÔNG chạm index (ứng viên HOT — Day 24)
UPDATE device SET meta = meta WHERE id < 3000;

-- D3. insert rồi xoá (giữ dataset nguyên vẹn)
CREATE TEMP TABLE IF NOT EXISTS bench_tmp (LIKE alarm);
INSERT INTO bench_tmp SELECT * FROM alarm WHERE id < 20000;
DELETE FROM bench_tmp;

-- ============================================================
-- NHÓM E — query "vô hại" nhưng hình dạng xấu
-- ============================================================

-- E1. hàm bọc quanh cột -> index vô dụng (Day 09)
SELECT count(*) FROM device WHERE lower(name) = 'device-00042';

-- E2. LIKE tiền tố mở
SELECT count(*) FROM device WHERE name LIKE '%00042';

-- E3. OFFSET sâu
SELECT id, name FROM device ORDER BY name OFFSET 40000 LIMIT 20;

-- E4. count(*) toàn bảng (ô "tổng số bản ghi" trên dashboard)
SELECT count(*) FROM ts_kv;

\o
