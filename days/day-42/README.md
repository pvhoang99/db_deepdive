# Day 42 — Prepared statement trong đời thật: driver, pool, và kiểu tham số

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

> Day 12 §4 đã dạy cơ chế: 5 lần custom plan rồi cân nhắc chuyển sang generic. Hôm nay là phần mà psql **không** cho bạn thấy: prepared statement đi qua JDBC/pgx, qua pgbouncer, và chết ở đâu. Cộng với một lớp bug riêng: **tham số sai kiểu làm index thành vô dụng** — cùng một câu SQL, viết tay thì nhanh, qua driver thì seq scan.

## Chuẩn bị

```sql
\timing on
\o /days/day-42/output.txt
```

Ôn 90 giây: mở lại writeup Day 12 §4, đọc con số bạn đã ghi về generic vs custom plan.

---

## §0. Đoán trước

1. `PreparedStatement` trong Java — mặc định có tạo prepared statement **trên server** không?
2. 300 connection, mỗi cái cache 150 prepared statement — tốn thêm bao nhiêu RAM, ở đâu?
3. Sau pgbouncer ở chế độ `transaction`, `PREPARE` rồi `EXECUTE` ở request sau — chuyện gì xảy ra?
4. Cột `device_id bigint` có index. `WHERE device_id = $1` với `$1` kiểu `numeric` — index có được dùng không?

---

## §1. Ba tầng "prepared" — bạn đang ở tầng nào

### Lý thuyết

Từ "prepared statement" bị dùng cho ba thứ khác nhau:

| Tầng | Là gì | Ai làm | Có tiết kiệm planning không |
|---|---|---|---|
| 1. Client-side | driver ghép tham số vào chuỗi SQL rồi gửi text | JDBC khi `prepareThreshold` chưa đạt; nhiều ORM | **không** |
| 2. Protocol extended query | `Parse` / `Bind` / `Execute` — SQL và tham số đi riêng | pgx mặc định, JDBC sau ngưỡng | **có** (statement vô danh hoặc có tên) |
| 3. `PREPARE` SQL tường minh | câu lệnh SQL `PREPARE`/`EXECUTE` | bạn gõ tay | có |

Điểm quan trọng: **an toàn SQL injection** đến từ tầng 1 trở lên (tham số không bị nối chuỗi), nhưng **tiết kiệm planning time** chỉ đến từ tầng 2–3. Nhiều team tin rằng dùng `PreparedStatement` là đã "prepared" trên server — thường là không.

Mặc định thực tế:
- **JDBC (pgjdbc):** `prepareThreshold = 5` — 5 lần đầu gửi kiểu vô danh, từ lần 6 mới tạo statement có tên trên server. Đặt `prepareThreshold=0` để tắt hẳn.
- **pgx (Go):** mặc định `QueryExecMode` là extended protocol + statement cache. `pgx.QueryExecModeSimpleProtocol` tắt hoàn toàn.
- **Hibernate:** không tự bật; phụ thuộc driver + `hibernate.jdbc.batch_size`.

Nhìn thấy chúng ở đâu:
```sql
SELECT name, statement, generic_plans, custom_plans FROM pg_prepared_statements;
```
Hai cột `generic_plans`/`custom_plans` (PG14+) cho biết **chính xác** statement đó đã dùng plan loại nào bao nhiêu lần — đây là bằng chứng, không phải suy đoán.

### Làm ngay

```sql
PREPARE d1(bigint) AS SELECT count(*) FROM ts_kv WHERE device_id = $1;
EXECUTE d1(42); EXECUTE d1(43); EXECUTE d1(44);
SELECT name, generic_plans, custom_plans FROM pg_prepared_statements;
EXECUTE d1(45); EXECUTE d1(46); EXECUTE d1(47); EXECUTE d1(48);
SELECT name, generic_plans, custom_plans FROM pg_prepared_statements;
```

Đo cái được và cái mất:
```sql
EXPLAIN (ANALYZE) SELECT count(*) FROM ts_kv WHERE device_id = 42;   -- xem "Planning Time"
EXPLAIN (ANALYZE) EXECUTE d1(42);                                     -- so "Planning Time"
```

**Ghi vào writeup:** `generic_plans`/`custom_plans` chuyển ở lần thứ mấy? Planning time tiết kiệm được bao nhiêu ms/lần? Với query chạy 2 triệu lần/ngày thì tổng là bao nhiêu giây CPU/ngày?

---

## §2. Plan cache tốn RAM ở đâu

### Lý thuyết

Plan cache nằm **trong bộ nhớ riêng của từng backend** (process-per-connection, Day 36), không phải shared memory. Nghĩa là chi phí nhân với số connection:

```
RAM plan cache ≈ số connection × số statement khác nhau × kích thước plan
```

Một plan join 5 bảng có thể vài trăm KB. 300 connection × 200 statement là con số hoàn toàn bình thường với một service Spring — và là lý do một Postgres "không làm gì" vẫn ăn nhiều GB RSS.

Đây cũng là một lý do nữa để pool nhỏ (Day 36): pool nhỏ không chỉ giảm context switch, nó còn giảm số bản sao plan cache.

### Làm ngay

```sql
-- bộ nhớ của backend hiện tại, trước khi prepare
SELECT name, pg_size_pretty(used_bytes) AS used
FROM pg_backend_memory_contexts WHERE name IN ('CacheMemoryContext','CachedPlanSource','TopMemoryContext')
ORDER BY used_bytes DESC;

-- tạo 200 prepared statement khác nhau
DO $$ BEGIN
  FOR i IN 1..200 LOOP
    EXECUTE format('PREPARE p%s(bigint) AS SELECT d.name, count(*) FROM ts_kv t JOIN device d ON d.id=t.device_id
                    WHERE t.device_id = $1 AND t.key_id = %s GROUP BY d.name', i, i % 8 + 1);
  END LOOP;
END $$;
DO $$ BEGIN FOR i IN 1..200 LOOP EXECUTE format('EXECUTE p%s(%s)', i, i); END LOOP; END $$;

SELECT count(*) FROM pg_prepared_statements;
SELECT pg_size_pretty(sum(used_bytes)) AS tong_bo_nho_backend FROM pg_backend_memory_contexts;
SELECT name, pg_size_pretty(used_bytes) AS used FROM pg_backend_memory_contexts
ORDER BY used_bytes DESC LIMIT 8;
```

**Ghi vào writeup:** RAM của backend tăng bao nhiêu MB cho 200 statement? Nhân với `max_connections=100` của lab là bao nhiêu? Nhân với pool thật của bạn là bao nhiêu? So sánh con số đó với `shared_buffers` — bạn có đang dành RAM cho đúng chỗ không?

```sql
DEALLOCATE ALL;
SELECT pg_size_pretty(sum(used_bytes)) FROM pg_backend_memory_contexts;
```

Chú ý: `DEALLOCATE ALL` giải phóng plan nhưng `CacheMemoryContext` thường **không trả RAM lại cho OS** ngay. Ghi lại hiện tượng.

---

## §3. pgbouncer transaction mode phá cái gì

### Lý thuyết

Nối thẳng vào Day 36. Ở chế độ `transaction`, mỗi transaction có thể rơi vào một server connection **khác nhau**. Mọi thứ có **trạng thái sống lâu hơn một transaction** đều vỡ:

| Thứ bị vỡ | Vì sao | Cách sống chung |
|---|---|---|
| `PREPARE`/`EXECUTE` (SQL tường minh) | statement nằm ở connection khác | không dùng; hoặc dùng pgbouncer ≥1.21 với `max_prepared_statements > 0` |
| Prepared statement của driver | như trên → lỗi `26000 prepared statement "S_1" does not exist` | JDBC `prepareThreshold=0`, pgx `QueryExecModeSimpleProtocol`, hoặc bật hỗ trợ ở pgbouncer |
| `SET` ở cấp session | áp lên connection ngẫu nhiên | dùng `SET LOCAL` trong transaction |
| Advisory lock cấp session | nhả ở connection khác | dùng `pg_advisory_xact_lock` (Day 28) |
| `LISTEN/NOTIFY` | mất kênh | tách connection riêng, không qua pool |
| Temp table, cursor `WITH HOLD` | như trên | tránh |

pgbouncer 1.21+ **có** hỗ trợ prepared statement ở protocol level (`max_prepared_statements`) — nó tự Parse lại trên server connection mới. Trước phiên bản đó thì không có cách nào ngoài tắt.

### Làm ngay

Mô phỏng bằng hai session (không cần cài pgbouncer): statement chỉ sống trong connection tạo ra nó.

**S1:**
```sql
PREPARE shared_q(bigint) AS SELECT count(*) FROM ts_kv WHERE device_id=$1;
EXECUTE shared_q(42);
SELECT name FROM pg_prepared_statements;
```
**S2:**
```sql
SELECT name FROM pg_prepared_statements;   -- rỗng
EXECUTE shared_q(42);                      -- lỗi: prepared statement "shared_q" does not exist
```

**Ghi vào writeup:** dán nguyên mã lỗi và SQLSTATE. Đây **chính xác** là lỗi mà app của bạn sẽ nhận khi đứng sau pgbouncer transaction mode. Bạn sẽ chọn cấu hình nào cho service Java và Go của mình — tắt server-side prepare, hay nâng pgbouncer và bật `max_prepared_statements`? Đánh đổi là gì (nhắc lại con số planning time ở §1)?

---

## §4. Kiểu tham số sai làm index thành vô dụng

### Lý thuyết

Index B-tree gắn với một **operator family**. Nếu kiểu tham số không khớp và Postgres phải ép **cột** (chứ không phải ép **tham số**), index không dùng được.

Quy tắc: ép kiểu ở **phía tham số** thì index vẫn sống; ép ở **phía cột** thì chết.

```sql
WHERE device_id = $1::bigint      -- OK, index sống
WHERE device_id::text = $1        -- CHẾT: hàm áp lên cột
```

Ba nguồn gây ra chuyện này trong code thật:
1. Driver gửi sai kiểu (Java `Long` vs `Integer` vs `BigDecimal`; Go `int` vs `int64`; ORM map `numeric`).
2. Cột `timestamptz` mà tham số là `text`/`date` — hoặc ngược lại, có ép ngầm nhưng đổi ngữ nghĩa timezone.
3. `LIKE 'abc%'` trên collation không phải `C` — B-tree thường **không** dùng được nếu thiếu `text_pattern_ops`.

### Làm ngay — kiểu số

```sql
CREATE INDEX IF NOT EXISTS ix_tskv_dev ON ts_kv(device_id);
ANALYZE ts_kv;

PREPARE ok_bigint(bigint)  AS SELECT count(*) FROM ts_kv WHERE device_id = $1;
PREPARE bad_numeric(numeric) AS SELECT count(*) FROM ts_kv WHERE device_id = $1;
PREPARE bad_text(text)     AS SELECT count(*) FROM ts_kv WHERE device_id::text = $1;

EXPLAIN (ANALYZE, BUFFERS) EXECUTE ok_bigint(42);
EXPLAIN (ANALYZE, BUFFERS) EXECUTE bad_numeric(42);
EXPLAIN (ANALYZE, BUFFERS) EXECUTE bad_text('42');
```

### Làm ngay — kiểu thời gian

```sql
CREATE INDEX IF NOT EXISTS ix_tskv_ts ON ts_kv(ts);
ANALYZE ts_kv;

EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv
WHERE ts >= '2025-06-01' AND ts < '2025-06-02';

EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv
WHERE ts::date = '2025-06-01';            -- hàm áp lên cột

EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv
WHERE date_trunc('day', ts) = '2025-06-01';
```

### Làm ngay — LIKE và collation

```sql
SHOW lc_collate;
CREATE INDEX ix_dev_name ON device(name);
ANALYZE device;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM device WHERE name LIKE 'dev-1234%';

CREATE INDEX ix_dev_name_pat ON device(name text_pattern_ops);
ANALYZE device;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM device WHERE name LIKE 'dev-1234%';
```

**Ghi vào writeup — bảng:**

| Query | Plan node | time | shared hit/read | index có được dùng |
|---|---|---|---|---|

Với mỗi ca **chết**, viết một câu: *thứ gì đã áp lên cột và vì sao điều đó phá index*. Và ca `LIKE`: vì sao collation quyết định được điều này?

---

## §5. Quy tắc cấu hình

### Lý thuyết — checklist

| Tình huống | Cấu hình |
|---|---|
| Không có pooler ở giữa, query lặp lại nhiều | bật server-side prepare (JDBC mặc định, pgx mặc định) |
| Sau pgbouncer `transaction`, pgbouncer < 1.21 | `prepareThreshold=0` / `QueryExecModeSimpleProtocol` |
| Sau pgbouncer ≥ 1.21 | `max_prepared_statements=200` ở pgbouncer, giữ prepare ở app |
| Dữ liệu lệch nặng, query theo tham số lệch | `plan_cache_mode=force_custom_plan` cho **role/statement đó** (Day 12) |
| Nhiều connection, nhiều statement, RAM căng | giảm pool trước, rồi giảm số statement khác nhau |
| Query sinh động (SQL nối chuỗi khác nhau mỗi lần) | không dùng prepare — cache chỉ phình |

Và một luật ngắn cho code: **tham số phải đúng kiểu của cột**. Trong Java: `setLong` cho `bigint`, `setObject(..., OffsetDateTime)` cho `timestamptz`. Trong Go: `int64`, `time.Time`.

### Làm ngay

```sql
-- statement nào đang dùng generic plan trong lab của bạn
SELECT name, generic_plans, custom_plans,
       round(100.0*generic_plans/nullif(generic_plans+custom_plans,0),1) AS pct_generic
FROM pg_prepared_statements ORDER BY generic_plans DESC LIMIT 10;
```

### Dọn dẹp

```sql
DEALLOCATE ALL;
DROP INDEX IF EXISTS ix_tskv_dev, ix_tskv_ts, ix_dev_name, ix_dev_name_pat;
```

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B. Áp dụng vào hệ thật:**
1. Service Java của bạn: `prepareThreshold` đang là bao nhiêu? Có pgbouncer ở giữa không, chế độ gì, phiên bản nào? Ba câu trả lời này phải khớp nhau — nếu không thì hoặc đang mất planning time, hoặc đang có lỗi `26000` ẩn trong log.
2. Chạy trên production (chỉ đọc):
```sql
SELECT count(*) FROM pg_prepared_statements;
SELECT usename, count(*), pg_size_pretty(sum(0)::bigint) FROM pg_stat_activity GROUP BY 1;
```
3. Lấy 3 query nặng nhất từ `pg_stat_statements` — với mỗi cái, kiểm tra kiểu của tham số trong code có khớp kiểu cột không. Ghi lại chỗ lệch (nếu có) và ước lượng thiệt hại.

### Đạt khi

Bạn nói được service của mình đang ở tầng nào trong 3 tầng "prepared", biết cấu hình nào phải đổi nếu thêm pgbouncer, và chứng minh được bằng plan rằng ép kiểu sai phía làm index vô dụng.

**Xong thì gõ `/review-bai`.**
