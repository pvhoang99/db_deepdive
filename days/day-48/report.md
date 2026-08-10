# Audit Postgres — 2026-08-10

> **Phạm vi:** báo cáo này được chạy trên **hệ lab** (`postgresql://localhost:5433/lab`) — hệ duy nhất tôi có quyền truy cập ở thời điểm viết. Toàn bộ **quy trình, bộ query, ngưỡng và cấu trúc** dùng được nguyên vẹn cho production: chạy [`audit.sql`](audit.sql) (chỉ đọc, an toàn cho production và cho replica) rồi thay số vào các mục dưới đây.
>
> **Chưa chạy trên production.** Mọi số trong báo cáo này là số của lab. Phần "Việc cần làm" ở cuối ghi rõ những gì cần lấy từ production trước khi báo cáo này có giá trị quyết định.
>
> Bộ công cụ: [`audit.sql`](audit.sql) · output thô: [`audit-output-lab.txt`](audit-output-lab.txt) · playbook migration: [`../day-45/migration-playbook.md`](../day-45/migration-playbook.md)

---

## Tóm tắt điều hành

- **Không có vấn đề CRITICAL.** Không có replication slot bỏ quên, không có index INVALID, không có transaction dài, XID age ~0% ngưỡng wraparound.
- **`cache_hit_pct = 82,26%` — thấp hơn ngưỡng khuyến nghị 99%.** Nguyên nhân: `shared_buffers = 256 MB` trên dataset 764 MB. **Đây là phát hiện quan trọng nhất về cấu hình.**
- **`alarm` có tỉ lệ dead tuple 30%** (60.000/200.000) và **autovacuum chưa từng chạy trên nó** (`last_autovacuum = null`) — bảng bị update liên tục nhưng ngưỡng autovacuum mặc định (20%) không đủ nhạy.
- **Query nặng nhất chiếm 25,6% và đọc 10.863 buffer để trả về 1 dòng** — `lower(name) LIKE 'prefix%'`, không dùng được index do collation `en_US.utf8` (cần `text_pattern_ops`).
- **Ba query đọc > 10.000 buffer cho mỗi dòng trả về** — dấu hiệu thiếu index rõ ràng, đã định lượng ở mục Phát hiện.
- **Ingest sinh 121 MB WAL cho 120.000 dòng** với `wal_fpi = 14.993` (≈ 98% WAL là full-page image) — `wal_compression` đang **tắt**, bật `lz4` ước giảm ~27%.
- **Tổng 6 hành động đề xuất**, trong đó **4 hành động không cần restart và rollback tức thì**, ước tính giảm thời gian workload thêm ~40% và giảm WAL ~27%.

---

## 1. Hiện trạng

| Hạng mục | Giá trị |
|---|---|
| Phiên bản | PostgreSQL 17 (Docker `postgres:17`) |
| Phần cứng | **8 core / 31 GB RAM** |
| Dung lượng database | **764 MB** |
| Bảng lớn nhất | `ts_kv` — **5.260.000 dòng**, 686 MB (heap 297 MB + index 389 MB) |
| Bảng thứ hai | `alarm` — 200.000 dòng, 42 MB |
| `pg_stat_statements` | **đã bật** ✅ |
| `stats_reset` | trong phiên audit (mọi số dưới là của 12 lần chạy workload) |

**GUC khác mặc định:**

| GUC | Giá trị | Đánh giá |
|---|---|---|
| `shared_buffers` | **256 MB** | ⚠️ quá nhỏ so với dataset 764 MB (xem Phát hiện W1) |
| `work_mem` | 4 MB | cố ý nhỏ cho mục đích học; production cần đo lại |
| `effective_cache_size` | 1 GB | ⚠️ thấp so với 31 GB RAM |
| `maintenance_work_mem` | 128 MB | OK |
| `max_connections` | 100 | OK cho 8 core (Day 36: đỉnh throughput ở 8, vùng phẳng tới 32) |
| `wal_level` | `logical` | cố ý (cho CDC); sinh WAL nhiều hơn `replica` ~5–15% |
| `wal_compression` | **off** | ⚠️ nên bật `lz4` |
| `max_wal_size` | 1 GB | ⚠️ thấp — `pct_requested = 42,9%` |
| `checkpoint_timeout` | 5 min | ⚠️ thấp |
| `max_slot_wal_keep_size` | **−1 (không giới hạn)** | ⚠️ **thiếu van an toàn** |
| `idle_in_transaction_session_timeout` | **0 (tắt)** | ⚠️ thiếu bảo hiểm |
| `log_min_duration_statement` | 200 ms | ✅ tốt |
| `log_lock_waits` | on | ✅ tốt |
| `track_io_timing` | on | ✅ tốt |

---

## 2. Phát hiện

### 🔴 CRITICAL

**Không có.** Cụ thể, đã kiểm tra và loại trừ:

| Kiểm tra | Kết quả |
|---|---|
| Replication slot bỏ quên | **0 slot** ✅ |
| Index `INVALID` | **0** ✅ |
| Constraint chưa validate | **0** ✅ |
| XID age lớn nhất | **973 = 0,0% ngưỡng wraparound** ✅ |
| Transaction mở > 1 phút | **0** ✅ |
| `archive_command` thất bại | `failed_count = 0` ✅ |
| Deadlock | **0** ✅ |
| Kết nối `idle in transaction` | **0** ✅ |

### 🟠 WARNING

#### W1 — `cache_hit_pct = 82,26%` (ngưỡng: ≥ 99%)

| Chỉ số | Giá trị |
|---|---|
| `cache_hit_pct` | **82,26%** |
| `blk_read_time` | 8.823,95 ms |
| `blk_write_time` | 886,05 ms |
| `shared_buffers` | 256 MB |
| Dataset | **764 MB** |

**Chẩn đoán:** `shared_buffers` bằng 33% dataset. Mỗi lần seq scan `ts_kv` (297 MB heap) là đẩy toàn bộ nội dung cache ra. 8,8 giây `blk_read_time` là thời gian thật chờ đọc.

**Lưu ý quan trọng về chẩn đoán này:** ở lab, phần lớn "read" thực ra đến từ **page cache của OS** (máy có 31 GB RAM, dataset 764 MB) chứ không từ đĩa thật — Day 40 §2 đã đo được wait event chỉ 2,2% `IO/DataFileRead`. Nên `cache_hit_pct` thấp ở đây **ít nghiêm trọng hơn con số gợi ý**. Trên production với dataset ≫ RAM thì nó nghiêm trọng thật.

**Đề xuất:** `shared_buffers = 25% RAM`, `effective_cache_size = 60–75% RAM`. Xem mục 4.

#### W2 — `alarm`: 30% dead tuple, autovacuum chưa từng chạy

| Chỉ số | Giá trị |
|---|---|
| `n_live_tup` | 200.000 |
| `n_dead_tup` | **60.000** |
| `ty_le_chet` | **0,300** |
| `last_autovacuum` | **null — chưa từng chạy** |
| Kích thước | 42 MB (từ 33 MB ban đầu = **+27% bloat**) |

**Chẩn đoán:** workload update 4.000 dòng alarm mỗi vòng. Ngưỡng autovacuum mặc định là `0,2 × n_live_tup + 50 = 40.050` dòng chết — đã vượt (60.000), nhưng `autovacuum_naptime = 60s` và bảng nhỏ nên nó chưa kịp được chọn. Trên production với nhịp update liên tục, đây là bảng sẽ phình dần.

**Đề xuất:** hạ ngưỡng cho riêng bảng này (mục 4.2). Không cần restart, không khoá.

#### W3 — Ba query đọc > 10.000 buffer cho mỗi dòng trả về

| Query | `buf_moi_dong` | mean_ms | % tổng |
|---|---|---|---|
| `date_trunc('hour', ts) ... WHERE key_id=$1 AND ts BETWEEN` (downsample) | **38.508** | 134,6 | 16,6% |
| `count(*) FROM device WHERE tenant_id = g AND is_active` (× 20 tenant) | **24.140** | 115,2 | 14,2% |
| `count(*) FROM device WHERE lower(name) LIKE $1` (× 9) | **10.863** | 207,6 | **25,6%** |

**Chẩn đoán chung:** cả ba đều `Seq Scan`. Chi tiết ở mục 3.

#### W4 — Ingest: 121 MB WAL cho 120.000 dòng, 98% là full-page image

| Chỉ số | Giá trị |
|---|---|
| `wal_bytes` | **121 MB** (12 lần × 10.000 dòng) |
| `wal_records` | 363.849 (**3,03× số dòng** = 1 heap + 2 index) |
| `wal_fpi` | **14.993** → 14.993 × 8 kB = **117 MB = 96,7% toàn bộ WAL** |
| `stddev_ms` | **103,79** so với `mean_ms` 99,92 — **hệ số biến thiên 1,04** |

**Chẩn đoán:** hai vấn đề chồng nhau.

1. **FPI chiếm 96,7% WAL.** `device_id` sinh ngẫu nhiên ⇒ entry index rơi rải rác khắp cây B-tree ⇒ mỗi page bị chạm lần đầu sau checkpoint tốn nguyên 8 kB (Day 37 §3). Với `checkpoint_timeout = 5min` và `max_wal_size = 1GB`, checkpoint chạy rất thường xuyên (`pct_requested = 42,9%`) nên hệ **luôn ở vùng đắt**.
2. **`stddev` ≈ `mean`** — thời gian INSERT dao động gấp đôi giữa các lần, đúng chữ ký của "ngay sau checkpoint vs xa checkpoint".

**Đề xuất:** `wal_compression = lz4` (−27%, Day 37 §3), `max_wal_size = 8GB`, `checkpoint_timeout = 30min`. Cả ba **không cần restart**.

#### W5 — Checkpoint quá thường xuyên

```
num_timed = 4, num_requested = 3  →  pct_requested = 42,9%
write_s = 568,5, sync_s = 1,0, buffers_written = 52.930
```

**Ngưỡng:** `pct_requested` nên < 10%. **42,9% nghĩa là gần một nửa checkpoint được kích hoạt bởi `max_wal_size`, không phải bởi `checkpoint_timeout`** — đúng nguyên nhân của W4.

#### W6 — Thiếu ba bảo hiểm vận hành

| GUC | Hiện tại | Rủi ro |
|---|---|---|
| `max_slot_wal_keep_size` | **−1** | Một slot bỏ quên có thể làm **đầy đĩa và dừng toàn bộ ghi** (Day 39 §4). Hiện chưa có slot nào, nhưng lab chạy `wal_level=logical` nên chỉ cần một lần thử CDC là có. |
| `idle_in_transaction_session_timeout` | **0** | Một session `@Transactional` bọc lời gọi HTTP sẽ chặn `ALTER TABLE` và mọi query sau nó (Day 43 §2: `SELECT` vô can chờ 5.099 ms). |
| `statement_timeout` (mức role) | 0 | Query chạy vô hạn |

### 🟢 NOTICE

| # | Phát hiện | Ghi chú |
|---|---|---|
| N1 | `idx_alarm_open_sev_ts` chỉ có **8 lần scan** (520 kB) | Được dùng nhưng ít. Theo dõi 7 ngày; nếu vẫn thấp thì cân nhắc xoá. Chi phí thấp nên chưa gấp. |
| N2 | `device_attr` (11 MB, 99.856 dòng) — index có `idx_scan = 0` | Workload không đụng bảng này. Câu hỏi đúng: *"bảng này còn ai dùng không?"*, không phải *"index này có dùng không?"* |
| N3 | Không có bảng nào dùng TOAST | `pct_toast` rỗng ở mọi bảng — Day 41 không áp dụng cho hệ này |
| N4 | `temp_files = 15`, `temp_bytes = 441 MB` | Có tràn temp nhưng `pg_stat_statements` cho `temp_blks_written = 0` ở mọi query hiện tại ⇒ temp đến từ `CREATE INDEX` (maintenance), không phải từ query. Không cần hành động. |
| N5 | `rollback_pct = 0,13%`, `deadlocks = 0` | ✅ tốt |

---

## 3. Phân tích 3 query nặng nhất

> Chọn 3 thay vì 5 vì sau vòng tối ưu của Day 47, các query còn lại đều dưới 3,5% và không đáng phân tích sâu. **Tiêu chí chọn:** `pct` cao **VÀ** `buf_moi_dong` cao (dấu hiệu thiếu index), ưu tiên query mà một cách sửa giải quyết được nhiều chỗ.

### Query 1 — Tìm kiếm device theo tên (25,6% tổng thời gian)

**SQL:**
```sql
SELECT count(*) FROM device WHERE lower(name) LIKE 'device-000' || g || '%';
```
**Tần suất:** 9 lần/vòng workload · `mean = 207,60 ms` · `bufs = 130.356` · **`buf_moi_dong = 10.863`**

**Chẩn đoán:** hai bệnh chồng nhau, cả hai đều từ Day 42 §4c:
1. **`lower(name)` là biểu thức** ⇒ index thường trên `name` vô dụng.
2. **Collation `en_US.utf8`** ⇒ kể cả có index trên `lower(name)`, `LIKE 'prefix%'` vẫn **không** dùng được, vì thứ tự theo ngôn ngữ không đảm bảo tiền tố nằm liền nhau.

**Bằng chứng:** `buf_moi_dong = 10.863` = đúng số page của `device` (1.207 page × 9 lần / 1 dòng kết quả) ⇒ **seq scan toàn bộ, mọi lần**.

**Đề xuất:**
```sql
CREATE INDEX CONCURRENTLY idx_device_lower_name_pat
  ON device (lower(name) text_pattern_ops);
```
**Cải thiện ước tính:** Day 42 §4c đo được cùng loại query: **6,70 ms → 0,078 ms (86×), 1.207 → 6 buffer**. Ước ở đây: **207,6 ms → ~3 ms**, tiết kiệm ~2,4 s mỗi vòng workload.

**Rủi ro:** index ~1,5 MB (50.000 dòng × ~30 byte). Ghi chậm thêm không đáng kể (`device` gần như không update). `CONCURRENTLY` ⇒ không khoá.
**Kiểm chứng:** `idx_scan > 0` sau 24h; `mean_exec_time` của query này trong `pg_stat_statements`.

**Lưu ý ràng buộc:** index này **chỉ** phục vụ `lower(name) LIKE 'x%'`. Query `name ILIKE '%x%'` (W16, 28,8 ms) **không** dùng được nó — `%` ở đầu thì không index nào giúp được. Chỗ đó cần `pg_trgm` + GIN, và **không đề xuất bây giờ** vì nó chỉ chiếm 3,5%.

### Query 2 — Downsample theo giờ (16,6%)

**SQL:**
```sql
SELECT date_trunc('hour', ts) AS h, avg(dbl_v) FROM ts_kv
WHERE key_id = 1 AND ts >= '2025-06-01' AND ts < '2025-06-08' GROUP BY 1;
```
**Tần suất:** 1 lần/vòng · `mean = 134,56 ms` · `bufs = 462.098` · **`buf_moi_dong = 38.508`**

**Chẩn đoán:** lọc theo `key_id` + khoảng `ts`, nhưng **hai index hiện có đều bắt đầu bằng `device_id`** (`idx_tskv_dev_key_ts`, `idx_tskv_dev_ts`). Query này **không lọc `device_id`** ⇒ leftmost rule không áp dụng ⇒ `Seq Scan` 297 MB.

**Đề xuất — hai phương án, chọn theo quy mô:**

| Phương án | Lệnh | Kích thước ước tính | Phù hợp khi |
|---|---|---|---|
| **A. B-tree** | `CREATE INDEX CONCURRENTLY ON ts_kv (key_id, ts);` | **~160 MB** | dataset < 100 GB, cần lọc chính xác |
| **B. BRIN** | `CREATE INDEX CONCURRENTLY ON ts_kv USING brin (ts) WITH (pages_per_range=32);` | **~50 kB** | `correlation(ts) ≈ 1`, khoảng thời gian là bộ lọc chính |

**Khuyến nghị: phương án B trước, đo, chỉ thêm A nếu chưa đủ.** Lý do: Day 31 đo được BRIN trên `ts` là **48 kB vs 108 MB** cho B-tree, và ở đây `ts` có `correlation = 1` (dữ liệu ghi theo thời gian). BRIN sẽ cắt được khoảng 1 tuần / 3 tháng ≈ **92% dữ liệu** với chi phí gần bằng 0, rồi `key_id` lọc tiếp trong bộ nhớ.

**Cải thiện ước tính:** BRIN: **134,6 → ~15 ms** (~9×). B-tree: **→ ~5 ms** (~27×) nhưng tốn 160 MB.
**Rủi ro của BRIN:** nếu backfill dữ liệu lịch sử làm `correlation` tụt (Day 31 đo: `VACUUM FULL` làm correlation 1 → −0,39) thì BRIN thành vô dụng. Phải theo dõi `pg_stats.correlation`.

### Query 3 — Đếm device theo tenant (14,2%)

**SQL:**
```sql
SELECT count(*) FROM device WHERE tenant_id = g AND is_active;   -- lặp 20 tenant
```
**Tần suất:** 20 lần/vòng · `mean = 115,15 ms` · `bufs = 289.680` · **`buf_moi_dong = 24.140`**

**Chẩn đoán:** `Seq Scan` toàn bộ `device` (1.207 page) × 20 lần. `tenant_id` có `n_distinct = 20`, `is_active` có `n_distinct = 2` — chọn lọc **3,3%** (1.637/50.000). Đủ chọn lọc cho index.

**Đề xuất:**
```sql
CREATE INDEX CONCURRENTLY idx_device_tenant_active
  ON device (tenant_id) WHERE is_active;
```
Partial index (Day 08): chỉ ~50% số dòng vào index (device active), và mọi query của UI đều lọc `is_active`.

**Cải thiện ước tính:** `Index Only Scan`, **115,2 ms → ~1,5 ms** (~77×). Index ~350 kB.
**Rủi ro:** như mọi partial index — **vị từ của query phải khớp** (Day 47 §5). Nếu code viết `is_active = true` thì OK; `is_active IS NOT FALSE` thì không.
**Kiểm chứng:** `idx_scan > 0`; plan chuyển sang `Index Only Scan` với `Heap Fetches: 0`.

**Ghi chú:** index này cũng phục vụ được **W07/W08** (danh sách device có phân trang, 1,0% + 0,x%) — một index, ba query.

---

## 4. Đề xuất cấu hình

### 4.1 GUC

| GUC | Hiện tại | **Đề xuất** | Lý do | Restart? |
|---|---|---|---|---|
| `shared_buffers` | 256 MB | **8 GB** (25% của 31 GB) | `cache_hit = 82,26%`; dataset 764 MB sẽ vừa hoàn toàn | **CÓ** |
| `effective_cache_size` | 1 GB | **20 GB** (65% RAM) | Đây chỉ là **gợi ý cho planner**, không cấp phát RAM. Giá trị thấp làm planner đánh giá thấp index scan | không |
| `work_mem` | 4 MB | **32 MB** | Cố ý nhỏ cho lab. Công thức an toàn: `RAM × 25% / max_connections` = 31 GB × 0,25 / 100 ≈ 77 MB; chọn 32 MB có biên | không |
| `maintenance_work_mem` | 128 MB | **1 GB** | Tăng tốc `CREATE INDEX`, `VACUUM` | không |
| `random_page_cost` | 4.0 (mặc định) | **1.1** | Máy dùng SSD/NVMe. 4.0 là giá trị của đĩa quay 1997 và làm planner **né index** | không |
| `max_connections` | 100 | **giữ 100** | Day 36: đỉnh throughput ở 8 client = số core; 100 đã dư | — |
| **`wal_compression`** | **off** | **`lz4`** | W4: FPI = 96,7% WAL. Day 37 đo **−27,2%** | không |
| **`max_wal_size`** | **1 GB** | **8 GB** | W5: `pct_requested = 42,9%` (ngưỡng < 10%) | không |
| **`checkpoint_timeout`** | **5 min** | **30 min** | Giảm tần suất vào "vùng đắt FPI". **Đánh đổi: crash recovery lâu hơn — cần quyết định RTO** | không |
| `checkpoint_completion_target` | 0.9 | giữ 0.9 | Đo được `write_s:sync_s = 568:1` — đang hoạt động tốt | — |
| **`max_slot_wal_keep_size`** | **−1** | **50 GB** (10–20% đĩa WAL) | W6: bảo hiểm chống đầy đĩa. **Thà mất replica hơn sập primary** | không |
| **`idle_in_transaction_session_timeout`** | **0** | **60 s** (mức role app) | W6. Không đụng transaction đang chạy query | không |
| `statement_timeout` | 0 | **30 s** cho role app, **10 min** cho role báo cáo | Đặt theo role, không toàn cục | không |
| `log_min_duration_statement` | 200 ms | giữ | ✅ | — |
| `log_lock_waits` | on | giữ | ✅ | — |
| `log_checkpoints` | off | **on** | Miễn phí; log cho biết `distance=` để chỉnh `max_wal_size` đúng | không |

**Bốn GUC quan trọng nhất và KHÔNG cần restart:** `wal_compression`, `max_wal_size`, `max_slot_wal_keep_size`, `random_page_cost`.

### 4.2 Cấu hình per-table

```sql
-- Sinh tự động bởi audit.sql §5.1:
ALTER TABLE public.ts_kv SET (autovacuum_vacuum_scale_factor = 0.01,
                              autovacuum_analyze_scale_factor = 0.01);

-- Bổ sung cho W2 (alarm: 30% dead, autovacuum chưa chạy):
ALTER TABLE public.alarm SET (autovacuum_vacuum_scale_factor = 0.0,
                              autovacuum_vacuum_threshold = 5000,
                              autovacuum_analyze_scale_factor = 0.02,
                              fillfactor = 85);
```

`fillfactor = 85` cho `alarm`: bảng bị update `status` liên tục; chừa 15% chỗ trống trong page để tăng cơ hội HOT update (Day 24). **Chỉ áp dụng cho dòng mới** — bảng hiện có cần `pg_repack` để hưởng.

---

## 5. Rủi ro vận hành đã phát hiện

| # | Rủi ro | Trạng thái hiện tại | Hành động |
|---|---|---|---|
| R1 | **Slot bỏ quên làm đầy đĩa** (Day 39 §4) | 0 slot, nhưng `max_slot_wal_keep_size = −1` | Đặt van an toàn **trước** khi bật CDC |
| R2 | **`idle in transaction` chặn DDL và vacuum** (Day 40 §5, Day 43 §2) | 0 session hiện tại, nhưng không có timeout | Đặt `idle_in_transaction_session_timeout` |
| R3 | **Index INVALID tồn đọng** (Day 43 §5) | 0 ✅ | Đưa query kiểm tra vào dashboard |
| R4 | **Migration không có `lock_timeout`** (Day 43 §4) | Chưa rà repo migration | Áp [`migration-playbook.md`](../day-45/migration-playbook.md) |
| R5 | **Partial index vô dụng nếu vị từ không khớp** (Day 47 §5) | Hai partial index trên `alarm` dùng `status IN ('ACTIVE_ACK','ACTIVE_UNACK')` | Grep code; nếu có chỗ viết `status LIKE 'ACTIVE%'` thì index vô dụng |
| R6 | **Ingest chậm 14,9× sau khi thêm index** (Day 47 §4) | Đã xảy ra: INSERT 134 ms → 1.998 ms cho 200k dòng | Theo dõi ingest p99; nếu vượt SLO, cân nhắc BRIN/partition thay B-tree |
| R7 | **`wal_level = logical` sinh WAL nhiều hơn** | Đang bật cho mục đích học | Trên production: nếu không dùng CDC thì để `replica` |

---

## 6. Kế hoạch triển khai

Sắp theo **giá trị ÷ rủi ro**.

| # | Hành động | Giá trị kỳ vọng | Rủi ro | Downtime | Rollback | Ưu tiên |
|---|---|---|---|---|---|---|
| **1** | `ALTER SYSTEM SET wal_compression='lz4'; SELECT pg_reload_conf();` | **−27% WAL** ⇒ giảm I/O, replication, archive, backup | CPU +1–3% | **0** | `SET ... = 'off'` | **P0** |
| **2** | `ALTER SYSTEM SET max_slot_wal_keep_size='50GB';` | Bảo hiểm chống **dừng toàn bộ ghi** | Slot vượt ngưỡng bị `lost` ⇒ CDC phải re-snapshot | **0** | `SET ... = '-1'` | **P0** |
| **3** | `ALTER ROLE app SET idle_in_transaction_session_timeout='60s';` | Chặn nguồn số 1 của "ALTER TABLE làm sập API" | Session vi phạm bị giết — **đó là mục đích** | **0** | `RESET` | **P0** |
| **4** | `ALTER SYSTEM SET random_page_cost=1.1; effective_cache_size='20GB';` | Planner chọn index đúng hơn | Có thể đổi plan của một số query | **0** | `RESET` | **P1** |
| **5** | `ALTER TABLE alarm SET (autovacuum_vacuum_threshold=5000, ...);` | Chặn bloat 30% của W2 | Autovacuum chạy thường hơn ⇒ thêm I/O | **0** (`SHARE UPDATE EXCLUSIVE`) | `RESET (...)` | **P1** |
| **6** | 3 index của mục 3 bằng `CREATE INDEX CONCURRENTLY` | **−~56%** thời gian workload còn lại | +~2 MB (nếu chọn BRIN cho Q2); ghi chậm thêm không đáng kể trên `device` | **0** | `DROP INDEX CONCURRENTLY` | **P1** |
| **7** | `max_wal_size='8GB'; checkpoint_timeout='30min';` | Giảm FPI ⇒ giảm WAL thêm; giảm I/O spike | **Crash recovery lâu hơn — cần quyết định RTO với nghiệp vụ** | **0** | `RESET` | **P2** |
| **8** | `shared_buffers='8GB'` | `cache_hit` 82% → ~99% | **Cần restart**; cần cửa sổ bảo trì | **có** | `RESET` + restart | **P3** |

### Câu lệnh chính xác cho P0 (chạy được ngay hôm nay)

```sql
-- Mỗi lệnh một transaction riêng (ALTER SYSTEM không chạy trong transaction block)
ALTER SYSTEM SET wal_compression = 'lz4';
ALTER SYSTEM SET max_slot_wal_keep_size = '50GB';
SELECT pg_reload_conf();

ALTER ROLE app SET idle_in_transaction_session_timeout = '60s';
ALTER ROLE app SET statement_timeout = '30s';
ALTER ROLE bao_cao SET statement_timeout = '10min';

-- xác nhận
SELECT name, setting FROM pg_settings
WHERE name IN ('wal_compression','max_slot_wal_keep_size');
SELECT rolname, rolconfig FROM pg_roles WHERE rolconfig IS NOT NULL;
```

**Kiểm chứng sau 24h:**
```sql
-- WAL có giảm không (so với cùng khoảng thời gian hôm trước)
SELECT substring(query,1,50), calls, pg_size_pretty(wal_bytes::bigint), wal_fpi
FROM pg_stat_statements ORDER BY wal_bytes DESC LIMIT 5;
-- Có session nào bị giết vì idle in transaction không (xem log)
```

### Câu lệnh cho P1 — index

```sql
SET lock_timeout = '3s';
SET statement_timeout = '0';

-- Q1: tìm kiếm theo tên
CREATE INDEX CONCURRENTLY idx_device_lower_name_pat ON device (lower(name) text_pattern_ops);

-- Q3: đếm device theo tenant (phục vụ cả W07/W08)
CREATE INDEX CONCURRENTLY idx_device_tenant_active ON device (tenant_id) WHERE is_active;

-- Q2: downsample — thử BRIN trước (rẻ hơn B-tree 3.000×)
CREATE INDEX CONCURRENTLY idx_tskv_ts_brin ON ts_kv USING brin (ts) WITH (pages_per_range = 32);

-- bắt buộc sau khi tạo index trên bảng lớn
VACUUM ANALYZE device;
VACUUM ANALYZE ts_kv;

-- kiểm tra ngay
SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;   -- phải rỗng
```

**Điều kiện tiên quyết (Day 45 checklist):** không có transaction mở > 60 s (nó làm `CONCURRENTLY` treo — Day 45 Ca 4), không có index INVALID tồn đọng, đĩa trống ≥ 1,2× kích thước index dự kiến.

**Ai cần được thông báo:** team backend (P1 #6 có thể đổi plan của query đang dùng), team hạ tầng (P3 #8 cần restart).

---

## 7. Monitoring còn thiếu

| # | Chỉ số | Query | Ngưỡng | Mức |
|---|---|---|---|---|
| 1 | **XID age** | `SELECT max(age(relfrozenxid)) FROM pg_class WHERE relkind='r'` | > 50% `autovacuum_freeze_max_age` = warning; > 80% = **page** | 🔴 |
| 2 | **Slot không active / `wal_status`** | `SELECT slot_name FROM pg_replication_slots WHERE NOT active OR wal_status<>'reserved'` | có dòng = **page** | 🔴 |
| 3 | **WAL bị slot giữ** | `pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)` | > 5 GB = page | 🔴 |
| 4 | **`pg_wal` so với đĩa** | `sum(size) FROM pg_ls_waldir()` | > 70% đĩa = **page** | 🔴 |
| 5 | **Replication lag** (byte **VÀ** giây) | `pg_stat_replication` | > 100 MB **VÀ** > 60 s = page. **Phải AND** — lag giây một mình báo động giả khi hệ nhàn rỗi (Day 38 §2) | 🔴 |
| 6 | **`backend_xmin` của replica/slot** | `pg_stat_replication.backend_xmin`, `pg_replication_slots.catalog_xmin` | `age > 50M` = warning. **Chỉ số bị bỏ quên nhiều nhất** — nguyên nhân bloat khó chẩn đoán nhất (Day 38 §5) | 🟠 |
| 7 | **`idle in transaction` lâu nhất** | `max(now()-xact_start) WHERE state='idle in transaction'` | > 5 phút = page | 🟠 |
| 8 | **Bloat** | `n_dead_tup / n_live_tup` | > 0,2 = warning | 🟠 |
| 9 | **Index INVALID** | `SELECT * FROM pg_index WHERE NOT indisvalid` | có dòng = warning | 🟠 |
| 10 | **`num_requested / (num_timed + num_requested)`** | `pg_stat_checkpointer` | > 10% = warning (`max_wal_size` quá nhỏ) | 🟠 |
| 11 | **`cache_hit_pct`** | `pg_stat_database` | < 99% = warning | 🟠 |
| 12 | **`temp_files` / `temp_bytes`** | `pg_stat_database` | tăng nhanh = `work_mem` quá nhỏ | 🟡 |
| 13 | **Deadlock rate** | `pg_stat_database.deadlocks` | > 0/giờ = warning | 🟡 |
| 14 | **Constraint chưa validate** | `pg_constraint WHERE NOT convalidated` | có dòng = kiểm tra là chủ đích hay quên | 🟡 |
| 15 | **Wait event top 3** | lấy mẫu `pg_stat_activity` 10–20 lần/giây | dùng để chẩn đoán, không alert (Day 40) | 🟡 |

**Ba chỉ số bị bỏ quên nhiều nhất và nên thêm trước tiên: #6 (`backend_xmin`), #2 (`wal_status`), #10 (`pct_requested`).** Cả ba đều báo trước sự cố thay vì báo sau.

Công cụ: [`audit.sql`](audit.sql) chạy được như một cron hàng tuần, output diff với tuần trước.

---

## 8. Việc cần làm trước khi báo cáo này có giá trị quyết định

Báo cáo này chạy trên lab. Để dùng cho production cần:

| # | Việc | Cách làm |
|---|---|---|
| 1 | **Chạy `audit.sql` trên production** | `psql -h prod -U readonly -d db -f audit.sql > audit-prod-$(date +%F).txt`. An toàn: chỉ đọc, chạy được trên replica. |
| 2 | **Xác nhận `pg_stat_statements` đã bật** | Nếu chưa: đây là **khuyến nghị ưu tiên số 1**, cần `shared_preload_libraries` + restart. Không có nó thì mọi phân tích query đều mù. |
| 3 | **Ghi lại `stats_reset`** | Mọi số của `pg_stat_*` chỉ có nghĩa tương đối với mốc này. Nếu nó là 3 tháng trước thì `idx_scan = 0` mới đáng tin. |
| 4 | **Snapshot toàn bộ `pg_stat_*` TRƯỚC khi thay đổi bất cứ thứ gì** | Day 47 đã vấp lỗi này: không có số liệu HOT "trước" nên không so được. |
| 5 | **Lấy RAM/core thật của máy DB** | Mọi đề xuất `shared_buffers`/`work_mem` phụ thuộc con số này. |
| 6 | **Đối chiếu tỉ lệ đọc:ghi thật** | Quyết định "index có đáng không" phụ thuộc tỉ lệ này (Day 47 §4: đọc nhanh 55×, ghi chậm 14,9×). |

---

## Phụ lục

- **Bộ query đã dùng:** [`audit.sql`](audit.sql) — 9 nhóm kiểm tra, chỉ đọc, có ngưỡng cho từng nhóm, chạy được trên replica.
- **Output thô:** [`audit-output-lab.txt`](audit-output-lab.txt)
- **Playbook migration:** [`../day-45/migration-playbook.md`](../day-45/migration-playbook.md) — 21 lệnh DDL phân loại, khuôn migration, checklist 8 query, ngưỡng dừng.
- **Quy trình 30 giây đầu khi có sự cố:** [`../day-40/giai.md`](../day-40/giai.md) §7 — 8 bước, mỗi bước một query.
- **Số liệu tham chiếu** (đo trên chính lab này, dùng để ước tính):

| Phép đo | Kết quả | Nguồn |
|---|---|---|
| Index cho query latest-value | **17.000×** (340,3 ms → 0,020 ms) | Day 47 §3 |
| Cái giá: INSERT chậm | **14,9×** (134 → 1.998 ms/200k dòng) | Day 47 §4 |
| Cái giá: WAL | **4,25×** ổn định, **19,1×** ngay sau checkpoint | Day 47 §4 |
| `wal_compression = lz4` | **−27,2%** WAL | Day 37 §3 |
| `text_pattern_ops` cho `LIKE 'x%'` | **86×** (6,70 → 0,078 ms) | Day 42 §4c |
| BRIN vs B-tree trên cột thời gian | **48 kB vs 108 MB** (2.300×) | Day 31 |
| `NOT VALID` + `VALIDATE` | cửa sổ khoá **−89×** | Day 43 §3 |
| `ALTER TABLE` chờ lock chặn `SELECT` vô can | **5.099 ms** | Day 43 §2 |
