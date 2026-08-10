# Rollout plan — audit capstone (Day 47)

> Bốn thay đổi, tất cả đều là `CREATE INDEX CONCURRENTLY`. Không có thay đổi schema, không có backfill, không có DDL nào cần rewrite bảng.
>
> Kích thước lab: `ts_kv` 5M dòng / 289 MB, `alarm` 200k dòng / 29 MB. **Ngoại suy sang production bằng tỉ lệ số dòng và đo lại trên bản sao trước khi chạy thật** (Day 45 §6).

---

## Điều kiện tiên quyết — chạy TRƯỚC mọi thay đổi

```sql
-- 1. Không có transaction nào mở > 60s
--    (CREATE INDEX CONCURRENTLY chờ transaction giữ snapshot; REPEATABLE READ idle sẽ treo nó vô hạn — Day 45 Ca 4)
SELECT pid, state, backend_xmin,
       round(EXTRACT(epoch FROM now()-xact_start)::numeric,1) AS xact_giay, substring(query,1,60)
FROM pg_stat_activity
WHERE backend_type='client backend' AND xact_start < now()-interval '60 seconds'
  AND (backend_xmin IS NOT NULL OR state='active')
ORDER BY xact_start;
-- NGƯỠNG: phải rỗng.

-- 2. Không có index INVALID tồn đọng
SELECT indexrelid::regclass, indrelid::regclass FROM pg_index WHERE NOT indisvalid;
-- NGƯỠNG: phải rỗng.

-- 3. Đĩa còn đủ: cần ≥ 120% kích thước index dự kiến
SELECT pg_size_pretty(pg_total_relation_size('ts_kv')) AS bang,
       pg_size_pretty(pg_database_size(current_database())) AS db;
-- NGƯỠNG: free space ≥ 1,2 × (kích thước index dự kiến).

-- 4. Replica lag < 100 MB  (index build sinh WAL lớn)
SELECT application_name, state,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag
FROM pg_stat_replication;

-- 5. Slot ổn
SELECT slot_name, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS giu
FROM pg_replication_slots;
-- NGƯỠNG: wal_status='reserved'.
```

**Cấu hình session cho mọi bước:**
```sql
SET lock_timeout = '3s';        -- CONCURRENTLY chỉ cần lock nhẹ, nhưng vẫn đặt cho chắc
SET statement_timeout = '0';    -- BẮT BUỘC: index build dài, không được bị giết giữa chừng
```
Migration tool phải đánh dấu **non-transactional** (Flyway `executeInTransaction=false`, Liquibase `runInTransaction="false"`) — `CONCURRENTLY` không chạy được trong transaction block (Day 43 §5).

---

## Bảng triển khai

| # | Thay đổi | Lock lúc chạy | Thời gian ở lab (5M/200k dòng) | Ước tính ở prod | Dung lượng | Rollback | Giờ cao điểm? | Kiểm chứng sau 24h |
|---|---|---|---|---|---|---|---|---|
| **1** | `idx_tskv_dev_key_ts` trên `ts_kv (device_id, key_id, ts DESC)` | `SHARE UPDATE EXCLUSIVE` — **không chặn đọc/ghi** | **4.129 ms** | ~**14 phút** ở 1 tỉ dòng | **195 MB** → ~39 GB ở 1 tỉ dòng | `DROP INDEX CONCURRENTLY` | **Được** (không chặn) — nhưng nên chạy đêm vì tốn I/O và WAL | `idx_scan > 0`; `mean_exec_time` của query latest-by-key giảm |
| **2** | `idx_tskv_dev_ts` trên `ts_kv (device_id, ts DESC)` | `SHARE UPDATE EXCLUSIVE` | **4.047 ms** | ~**14 phút** ở 1 tỉ dòng | **151 MB** → ~30 GB | `DROP INDEX CONCURRENTLY` | Được, nên chạy đêm | `idx_scan > 0`; query latest-by-device giảm |
| **3** | `idx_alarm_open_dev` trên `alarm (device_id) WHERE status IN (...)` | `SHARE UPDATE EXCLUSIVE` | **~150 ms** | ~**5 giây** ở 10M dòng | **176 kB** (chỉ 4% số dòng) | `DROP INDEX CONCURRENTLY` | **Được** | `idx_scan > 0` |
| **4** | `idx_alarm_open_sev_ts` trên `alarm (severity, start_ts DESC) WHERE status IN (...)` | `SHARE UPDATE EXCLUSIVE` | **~150 ms** | ~**5 giây** ở 10M dòng | **272 kB** | `DROP INDEX CONCURRENTLY` | **Được** | `idx_scan > 0`; nếu vẫn = 0 sau 7 ngày ⇒ **xoá** |

### Câu lệnh chính xác

```sql
-- Bước 1 và 2: chạy TÁCH RIÊNG, mỗi cái một đêm, đo giữa hai lần.
--   Lý do: hai index này chồng lấn (index 2 là tiền tố của index 1 về mặt cột dẫn đầu).
--   Nếu sau bước 1 mà query latest-by-device đã đủ nhanh, KHÔNG cần bước 2 — tiết kiệm 30 GB.
SET lock_timeout = '3s'; SET statement_timeout = '0';
CREATE INDEX CONCURRENTLY idx_tskv_dev_key_ts ON ts_kv (device_id, key_id, ts DESC);
-- kiểm tra ngay:
SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;   -- phải rỗng

-- (đêm hôm sau, chỉ khi bước 1 chưa đủ)
SET lock_timeout = '3s'; SET statement_timeout = '0';
CREATE INDEX CONCURRENTLY idx_tskv_dev_ts ON ts_kv (device_id, ts DESC);
SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;

-- Bước 3 và 4: nhỏ, chạy được bất cứ lúc nào
SET lock_timeout = '3s'; SET statement_timeout = '0';
CREATE INDEX CONCURRENTLY idx_alarm_open_dev
  ON alarm (device_id) WHERE status IN ('ACTIVE_ACK','ACTIVE_UNACK');
CREATE INDEX CONCURRENTLY idx_alarm_open_sev_ts
  ON alarm (severity, start_ts DESC) WHERE status IN ('ACTIVE_ACK','ACTIVE_UNACK');
SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;

-- Sau mỗi bước trên ts_kv: cập nhật visibility map để Index Only Scan hoạt động
VACUUM ANALYZE ts_kv;
```

---

## Ràng buộc quan trọng của bước 3–4: partial index chỉ dùng được khi vị từ KHỚP

Index có `WHERE status IN ('ACTIVE_ACK','ACTIVE_UNACK')`. Planner **chỉ** dùng nó khi chứng minh được điều kiện của query nằm trong vị từ đó:

| Query viết thế nào | Dùng được index? |
|---|---|
| `WHERE status IN ('ACTIVE_ACK','ACTIVE_UNACK')` | ✅ khớp chính xác |
| `WHERE status = 'ACTIVE_ACK'` | ✅ hẹp hơn |
| `WHERE status LIKE 'ACTIVE%'` | ❌ **planner không chứng minh được** |
| `WHERE status <> 'CLEARED_ACK'` | ❌ |

**Trước khi triển khai bước 3–4: grep code tìm mọi cách viết điều kiện alarm đang mở và chuẩn hoá về đúng một dạng.** Nếu code dùng `LIKE 'ACTIVE%'`, phải sửa code **trước**, nếu không index vô dụng và bạn chỉ thêm chi phí ghi.

---

## Cái giá — phải nói rõ với team trước khi duyệt

Đo được ở lab (chi tiết trong [`giai.md`](giai.md) §4):

| Chi phí | Số đo |
|---|---|
| Dung lượng | database **351 MB → 708 MB (+102%)**; `ts_kv` index **0 → 346 MB** |
| **Ghi chậm hơn** | INSERT 200k dòng: **134 ms → 1.998 ms = 14,9×** (trạng thái ổn định, không FPI) |
| **WAL nhiều hơn** | **16 MB → 68 MB = 4,25×** cho cùng 200k dòng |
| WAL ngay sau checkpoint | **306 MB** (37.153 FPI = 95% WAL) — Day 37 §3 |
| UPDATE alarm trong workload | 54 ms → **86,9 ms (+61%)** |

**Ba hệ quả dây chuyền phải cân nhắc:**

1. **WAL ×4,25 ⇒ replica lag ×4,25** (Day 38: replay là single-process). Nếu replica hiện đang lag 20 MB lúc cao điểm, sau khi thêm index sẽ là ~85 MB. Kiểm tra ngưỡng alert.
2. **WAL ×4,25 ⇒ archive và backup lớn hơn 4,25×.** Với hệ sinh 50 GB WAL/ngày, đó là **+160 GB/ngày** phí lưu trữ và băng thông.
3. **Ingest chậm 14,9×** — nếu pipeline telemetry đang chạy gần trần, đây là thay đổi có thể làm nghẽn. Biện pháp giảm nhẹ (Day 37 §5): gom lô lớn hơn, hoặc `ALTER ROLE ingest SET synchronous_commit = off`.

**Đánh đổi có đáng không:** đọc nhanh hơn **55×**, ghi chậm hơn **14,9×**. Với hệ IoT có tỉ lệ đọc:ghi ~10:1 thì đáng rõ ràng. **Với hệ ingest thuần (ghi ≫ đọc) thì phải cân lại** — và đó là câu hỏi cho team, không phải cho DBA.

---

## Ngưỡng dừng

| Điều kiện | Hành động |
|---|---|
| `CREATE INDEX CONCURRENTLY` chạy > 2× thời gian ước tính | Kiểm tra `wait_event`. Nếu là `Lock/virtualxid` ⇒ có transaction cũ chặn ⇒ tìm và xử lý (Day 45 Ca 4). |
| Replica lag > 1 GB trong lúc build | **Dừng** (`pg_cancel_backend`), chờ replica đuổi kịp, `DROP INDEX CONCURRENTLY` cái dở dang, làm lại đêm sau. |
| `pg_wal` > 70% đĩa | Dừng ngay. Kiểm tra replication slot. |
| Ingest latency p99 tăng > 2× sau khi index lên | Đây là chi phí đã lường trước. Nếu vượt SLO ⇒ `DROP INDEX CONCURRENTLY` và thiết kế lại (cân nhắc BRIN thay B-tree — Day 31). |
| Index `indisvalid = false` sau khi build | `DROP INDEX CONCURRENTLY` rồi làm lại. **Không để tồn đọng** — nó tốn chi phí ghi mà không phục vụ đọc. |

---

## Kiểm chứng sau 24h và sau 7 ngày

```sql
-- 1. Mọi index mới đều được dùng?
SELECT indexrelname, idx_scan, idx_tup_read,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE indexrelname LIKE 'idx_tskv%' OR indexrelname LIKE 'idx_alarm_open%'
ORDER BY idx_scan;
-- NGƯỠNG 24h: idx_scan > 0 cho cả bốn.
-- NGƯỠNG 7 ngày: idx_scan = 0 ⇒ DROP INDEX CONCURRENTLY (điểm cộng, không phải điểm trừ).

-- 2. Query đích đã nhanh lên chưa?
SELECT substring(query,1,70), calls, round(mean_exec_time::numeric,3) AS mean_ms
FROM pg_stat_statements
WHERE query ILIKE '%ts_kv%device_id%' OR query ILIKE '%alarm%status%'
ORDER BY total_exec_time DESC LIMIT 10;
-- So với số ghi lại trước khi triển khai.

-- 3. Chi phí ghi có nằm trong dự tính không?
SELECT substring(query,1,50), calls, round(mean_exec_time::numeric,2) AS mean_ms,
       pg_size_pretty((wal_bytes/nullif(calls,0))::bigint) AS wal_moi_lan
FROM pg_stat_statements WHERE query ILIKE 'INSERT%ts_kv%';
-- NGƯỠNG: mean_exec_time không quá 20× so với trước.

-- 4. Bloat và autovacuum có theo kịp không?
SELECT relname, n_live_tup, n_dead_tup, last_autovacuum,
       pg_size_pretty(pg_total_relation_size(relid)) AS size
FROM pg_stat_user_tables WHERE relname IN ('ts_kv','alarm');

-- 5. Replica lag đã ổn định ở mức mới chưa?
SELECT application_name,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag,
       replay_lag
FROM pg_stat_replication;
```

---

## Thứ tự triển khai đề xuất

| Đêm | Việc | Vì sao thứ tự này |
|---|---|---|
| **1** | Bước 3 + 4 (partial index trên `alarm`) | Nhỏ (< 500 kB), nhanh (< 5 giây), rủi ro gần bằng 0. Lấy niềm tin trước. |
| **2** | Bước 1 (`idx_tskv_dev_key_ts`) | Index lớn nhất nhưng phục vụ nhiều query nhất (Q2 + Q3). |
| **—** | **Đo lại 24h** | Xem query latest-by-device đã đủ nhanh chưa. |
| **3** | Bước 2 (`idx_tskv_dev_ts`) — **chỉ khi cần** | Ở lab, không có nó thì Q1 chỉ đạt 4,13 ms thay vì 0,02 ms. Nhưng 4,13 ms có thể đã đủ với SLO của bạn — **tiết kiệm 30 GB nếu đúng thế.** |

**Điểm quyết định quan trọng nhất nằm ở đêm 3.** Đây là chỗ audit tốt khác audit tệ: audit tệ tạo cả hai index vì "cả hai đều nhanh hơn"; audit tốt hỏi *"4,13 ms có đủ không"* trước khi tiêu 30 GB.
