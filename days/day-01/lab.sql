-- Day 01 — mọi câu lệnh đã chạy, theo đúng thứ tự, KỂ CẢ câu sai.
-- Câu sai giữ lại và ghi chú -- SAI: vì sao
\timing on
\o /days/day-01/output.txt

-- §1. Bốn giai đoạn của một câu query
EXPLAIN (ANALYZE) SELECT count(*) FROM ts_kv WHERE device_id = 42;
-- Planning 0.074 ms / Execution 194.032 ms
EXPLAIN (ANALYZE) SELECT * FROM tenant WHERE id = 1;
-- Planning 0.041 ms / Execution 0.023 ms  -> planning > execution

-- §3. Ước lượng khi chưa có statistics
-- SAI: chạy lần đầu mà quên tắt song song -> ra Parallel Seq Scan, dính bẫy loops=3
--      (rows dưới Gather là trung bình MỖI worker, không phải tổng)
EXPLAIN (ANALYZE) SELECT count(*) FROM ts_kv WHERE device_id = 42;

SET max_parallel_workers_per_gather = 0;   -- tắt song song cho dễ đọc
EXPLAIN (ANALYZE) SELECT count(*) FROM ts_kv WHERE device_id = 42;
-- Seq Scan: rows=17185 (đoán) vs actual rows=3731  -> đoán thừa 4,6 lần
-- 3731 + 4996269 Rows Removed by Filter = 5.000.000 chẵn -> quét toàn bảng
-- 17185 / 0.005 = 3.437.000 -> planner nghĩ bảng chỉ có 3,4 triệu dòng (thật 5 triệu)

\o
