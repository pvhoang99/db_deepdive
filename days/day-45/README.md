# Day 45 — Chẩn đoán mù + diễn tập migration — ôn tuần 9

**Thời lượng:** 60–90 phút · **Cách học:** chẩn đoán trước, chạy sau.

## Chuẩn bị

```sql
\timing on
\o /days/day-45/output.txt
ANALYZE;
```

---

## Luật chơi hôm nay

Với mỗi ca: **đọc triệu chứng, KHÔNG chạy gì**, viết chẩn đoán + cách sửa + dự đoán vào `writeup.md`, rồi mới kiểm chứng. Ghi lại đúng/sai.

Năm ca dưới đây đều là sự cố có thật, dạng phổ biến nhất ở hệ chạy Postgres + microservice.

---

## Ca 1 — "Migration chỉ thêm một cột, mà API 500 suốt 8 phút"

### Bối cảnh

10h sáng, deploy. Migration duy nhất:
```sql
ALTER TABLE device ADD COLUMN label text;
```
Trên staging: 12ms. Trên production: toàn bộ endpoint đọc `device` trả 500 trong 8 phút, rồi tự khỏi. Bảng `device` chỉ có 50k dòng. Log Postgres có `process 4412 still waiting for AccessExclusiveLock on relation ...`.

### Chẩn đoán trước

### Kiểm chứng

**S1:**
```sql
BEGIN;
SELECT count(*) FROM device WHERE type='sensor';
-- giữ, không commit (mô phỏng một job báo cáo chạy dài)
```
**S2:**
```sql
\timing on
ALTER TABLE device ADD COLUMN label text;
```
**S3:**
```sql
\timing on
SELECT id, name FROM device WHERE id = 5;
```
```sql
-- chụp hiện trường
SELECT pid, state, wait_event_type, wait_event, pg_blocking_pids(pid),
       now()-xact_start AS mo, substring(query,1,50)
FROM pg_stat_activity WHERE datname=current_database() ORDER BY xact_start;
```
Dọn: `COMMIT` ở S1, rồi `ALTER TABLE device DROP COLUMN label;`

**Ghi vào writeup:** thủ phạm thật là ai — câu `ALTER TABLE`, hay cái gì khác? Sửa **hai** chỗ: một ở migration, một ở phía job đang chạy dài.

---

## Ca 2 — "Bảng 200MB nhưng backup 12GB, và `SELECT *` chậm gấp 40 lần `SELECT id`"

### Bối cảnh

Team báo bảng `device_profile` chỉ 200MB theo dashboard, nhưng `pg_dump` ra 12GB và endpoint list device p99 = 3 giây. Bảng có cột `config jsonb` lưu cấu hình thiết bị.

### Chẩn đoán trước

### Kiểm chứng

```sql
CREATE TABLE device_profile AS
SELECT id, name, (SELECT jsonb_agg(jsonb_build_object('k',h,'v',md5((id*h)::text)))
                  FROM generate_series(1,150) h) AS config
FROM device;
VACUUM ANALYZE device_profile;

-- con số mà dashboard hay hiển thị
SELECT pg_size_pretty(pg_relation_size('device_profile')) AS cai_dashboard_hien;
-- con số thật
SELECT pg_size_pretty(pg_total_relation_size('device_profile')) AS that,
       pg_size_pretty(pg_relation_size(reltoastrelid)) AS toast
FROM pg_class WHERE relname='device_profile';

EXPLAIN (ANALYZE, BUFFERS) SELECT id, name FROM device_profile;
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM device_profile;
```

**Ghi vào writeup:** chênh lệch buffers giữa hai query là bao nhiêu lần? Bạn sẽ sửa ở tầng nào — SQL, ORM, hay schema? Nêu 2 cách và chọn 1, kèm lý do.

---

## Ca 3 — "Đĩa primary đầy dần từ hôm bật CDC, retention không đổi"

### Bối cảnh

Bật Debezium 6 ngày trước. `pg_wal` từ 2GB lên 60GB và vẫn tăng. `max_wal_size = 4GB`. Checkpoint chạy bình thường. Không ai đổi gì khác. Đội hạ tầng đề nghị "tăng đĩa".

### Chẩn đoán trước

### Kiểm chứng

```sql
SELECT slot_name, plugin, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS giu_bao_nhieu,
       pg_size_pretty(safe_wal_size) AS con_lai
FROM pg_replication_slots;

SELECT pg_size_pretty(sum(size)) FROM pg_ls_waldir();
```

Tái hiện: tạo slot rồi bỏ đó, ghi 300k dòng, `CHECKPOINT`, đo lại `pg_ls_waldir()` (đúng quy trình Day 39 §4).

**Ghi vào writeup:** vì sao tăng đĩa **không phải** cách sửa? Ba hành động theo thứ tự ưu tiên trong 15 phút đầu của sự cố này là gì? Ngưỡng cảnh báo bạn đặt để nó không bao giờ tới mức này?

---

## Ca 4 — "`CREATE INDEX CONCURRENTLY` chạy 3 tiếng, không lỗi, không xong"

### Bối cảnh

Bảng 8 triệu dòng. Bình thường index kiểu này mất 4 phút. Lệnh không báo lỗi, `pg_stat_activity` cho thấy nó `active`. CPU của server gần như rảnh.

### Chẩn đoán trước

### Kiểm chứng

**S1:**
```sql
BEGIN; SELECT 1 FROM ts_kv LIMIT 1;   -- giữ mãi
```
**S2:**
```sql
CREATE INDEX CONCURRENTLY ix_slow ON alarm(severity);
```
**S3:**
```sql
SELECT pid, state, wait_event_type, wait_event, now()-xact_start AS mo,
       substring(query,1,60) FROM pg_stat_activity WHERE datname=current_database();
```

Dọn: `COMMIT` ở S1, chờ index xong, rồi kiểm tra và `DROP INDEX ix_slow;`

**Ghi vào writeup:** `wait_event` của tiến trình `CONCURRENTLY` là gì? Vì sao CPU rảnh? Nếu bạn hủy nó thì để lại cái gì (Day 43 §5) và bạn phải làm gì tiếp? Viết query kiểm tra "có transaction cũ nào đang chặn CONCURRENTLY không" để chạy **trước** mỗi migration.

---

## Ca 5 — "Thêm pgbouncer xong app lỗi ngẫu nhiên, restart thì hết vài phút"

### Bối cảnh

Đưa pgbouncer (transaction mode) vào giữa. Sau đó ~2% request lỗi:
```
ERROR: prepared statement "S_3" does not exist (SQLSTATE 26000)
```
Lỗi không lặp lại được trên máy dev.

### Chẩn đoán trước

### Kiểm chứng

Tái hiện bằng 2 session (Day 42 §3):
```sql
-- S1
PREPARE s3(bigint) AS SELECT count(*) FROM device WHERE tenant_id=$1;
EXECUTE s3(1);
-- S2
EXECUTE s3(1);
```

**Ghi vào writeup:** vì sao lỗi chỉ xảy ra ~2% chứ không phải 100%? Ba cách sửa (ở app, ở pgbouncer, ở kiến trúc) — mỗi cách mất gì? Bạn chọn cách nào và tại sao?

---

## §6. Diễn tập: một migration hoàn chỉnh, có đồng hồ bấm giờ

### Làm ngay

Đây là bài chính của ngày. Bảng thật, 5 triệu dòng, có traffic chạy nền.

**Yêu cầu:** trên bảng `ts_kv`, thêm cột `quality smallint NOT NULL DEFAULT 0` **và** một index `(device_id, ts) WHERE quality > 0`, sao cho trong suốt quá trình:
- không có lần chờ lock nào > 3 giây,
- p99 của probe không tăng quá 2 lần so với baseline,
- có thể dừng giữa chừng và chạy tiếp,
- mọi bước đều rollback được.

Chuẩn bị probe (dùng lại của Day 44):
```sql
CREATE TABLE probe (t timestamptz, ms numeric);
CREATE OR REPLACE PROCEDURE run_probe(seconds int) LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz; deadline timestamptz := clock_timestamp()+make_interval(secs=>seconds); n int;
BEGIN
  WHILE clock_timestamp() < deadline LOOP
    t0 := clock_timestamp();
    SELECT count(*) INTO n FROM ts_kv WHERE device_id = 1+(extract(epoch from clock_timestamp())::int % 50);
    INSERT INTO probe VALUES (t0, extract(epoch from clock_timestamp()-t0)*1000);
    COMMIT; PERFORM pg_sleep(0.05);
  END LOOP;
END $$;
```

Trình tự:
1. **S2:** `TRUNCATE probe; CALL run_probe(90);` — lấy baseline p99 khi **không** migration.
2. Viết toàn bộ migration của bạn vào `days/day-45/migration.sql` **trước khi chạy**, có `lock_timeout`, có backfill theo lô, có kiểm tra trước mỗi bước.
3. **S2:** chạy probe lại. **S1:** chạy migration, bấm giờ từng bước.
4. Đo và so.

```sql
-- mẫu đo sau mỗi lần
SELECT count(*) mau, round(avg(ms),1) avg_ms,
       round(percentile_cont(0.99) WITHIN GROUP (ORDER BY ms)::numeric,1) p99_ms,
       round(max(ms),1) max_ms FROM probe;
```

**Ghi vào writeup:**

| Bước | Lệnh | Lock mode | Thời gian | p99 probe trong lúc chạy |
|---|---|---|---|---|

Cộng: baseline p99, p99 lúc migration, tỷ lệ tăng. **Bạn có đạt cả 4 yêu cầu không?** Nếu không đạt cái nào, ghi rõ vì sao.

### Dọn dẹp

```sql
ALTER TABLE ts_kv DROP COLUMN IF EXISTS quality;
DROP INDEX IF EXISTS <index bạn tạo>;
DROP TABLE IF EXISTS device_profile, probe;
DROP PROCEDURE IF EXISTS run_probe(int);
SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots;  -- nếu Ca 3 còn sót
VACUUM ts_kv;
```

---

## §7. Playbook — sản phẩm của tuần 9

### Làm ngay

Viết `days/day-45/migration-playbook.md`. Đây là tài liệu bạn thật sự dán vào wiki của team, không phải bài tập hình thức. Bắt buộc có:

1. **Bảng phân loại DDL** — ít nhất 12 lệnh × (lock mode, có rewrite/scan không, an toàn hay không), kèm số bạn tự đo.
2. **Khuôn migration chuẩn** — đoạn SQL/pseudo-code có `lock_timeout`, retry, backfill theo lô, kiểm tra trước-sau.
3. **Checklist trước khi chạy** — tối đa 8 dòng, mỗi dòng là một câu query chạy được (ví dụ: "có transaction nào mở > 1 phút không", "có index INVALID nào không", "replica lag bao nhiêu", "slot có ổn không").
4. **Ngưỡng dừng** — điều kiện nào thì hủy migration giữa chừng, và hủy bằng cách nào cho an toàn.
5. **Danh sách "không bao giờ làm trong giờ cao điểm"** — kèm lý do bằng số.

### Ôn tuần 9

Trả lời ngắn trong writeup:

- Ba con số bạn đo được tuần này mà trước đây chỉ đoán.
- Một migration **đã từng chạy** trong hệ của bạn mà giờ nhìn lại thấy nguy hiểm — nguy hiểm ở đâu, may mắn ở chỗ nào.
- Một thứ trong tuần 9 (TOAST / plan cache / DDL lock / expand-contract) mà bạn sẽ dùng ngay trong 2 tuần tới.

---

## Kết ngày

### Đạt khi

- Tỷ lệ chẩn đoán đúng ≥ 3/5 ca, và với ca sai bạn chỉ ra được **vì sao mình nghĩ nhầm**.
- Bài diễn tập §6 đạt ít nhất 3/4 yêu cầu, có số liệu probe chứng minh.
- `migration-playbook.md` đủ 5 mục và mọi query trong checklist đều chạy được.

**Xong thì gõ `/review-bai`.** Ba ngày còn lại là capstone.
