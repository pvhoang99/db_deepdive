# Day 37 — WAL & checkpoint

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

```sql
\timing on
\o /days/day-37/output.txt
```

---

## §0. Đoán trước

1. Insert 500k dòng sinh ra bao nhiêu MB WAL — nhiều hay ít hơn kích thước dữ liệu?
2. Cùng lệnh đó chạy **ngay sau checkpoint** so với **lâu sau checkpoint** — chênh nhau bao nhiêu?
3. `synchronous_commit = off` nhanh hơn bao nhiêu, và đánh đổi cái gì?

---

## §1. WAL là gì

### Lý thuyết

**Write-Ahead Logging**: trước khi sửa bất kỳ page nào trong bộ nhớ, ghi lại **ý định** vào một file log tuần tự. Chỉ khi WAL đã nằm chắc trên đĩa (`fsync`) thì transaction mới được coi là commit.

Vì sao thiết kế này thắng:
- Ghi WAL là **tuần tự** — nhanh hơn nhiều so với ghi ngẫu nhiên vào các page rải rác
- Page dữ liệu (dirty page) có thể ghi xuống đĩa **sau**, theo lô, khi thuận tiện
- Crash recovery: replay WAL từ checkpoint gần nhất

Bạn đã biết khái niệm này từ Kafka và từ Postgres — đây là cùng một ý tưởng: **append-only log là nguồn chân lý, trạng thái là kết quả replay log.**

WAL còn là nền của: replication (streaming WAL sang replica), PITR (point-in-time recovery), logical decoding (CDC).

### Làm ngay

```sql
SELECT pg_current_wal_lsn(), pg_current_wal_insert_lsn();
SHOW wal_level;
SHOW wal_segment_size;

SELECT name, setting, unit FROM pg_settings
WHERE name IN ('wal_level','max_wal_size','min_wal_size','checkpoint_timeout',
               'checkpoint_completion_target','full_page_writes','synchronous_commit',
               'wal_compression','wal_buffers');

SELECT * FROM pg_ls_waldir() ORDER BY name DESC LIMIT 5;
```

**Ghi vào writeup:** `wal_level` là gì (nó ảnh hưởng lượng WAL sinh ra)? Mỗi WAL segment to bao nhiêu?

---

## §2. Đo lượng WAL sinh ra

### Làm ngay

```sql
CREATE TABLE t_wal (LIKE ts_kv);

SELECT pg_current_wal_lsn() AS truoc \gset
INSERT INTO t_wal SELECT * FROM ts_kv LIMIT 500000;
SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), :'truoc')) AS wal_sinh_ra,
       pg_size_pretty(pg_relation_size('t_wal')) AS kich_thuoc_du_lieu;
```

Với index:
```sql
CREATE INDEX ON t_wal(device_id, ts);
CREATE INDEX ON t_wal(ts);
CREATE INDEX ON t_wal(key_id);

SELECT pg_current_wal_lsn() AS truoc \gset
INSERT INTO t_wal SELECT * FROM ts_kv LIMIT 500000;
SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), :'truoc')) AS wal_co_3_index;
```

UPDATE:
```sql
SELECT pg_current_wal_lsn() AS truoc \gset
UPDATE t_wal SET dbl_v = dbl_v + 1 WHERE device_id < 100;
SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), :'truoc')) AS wal_update;
```

**Ghi vào writeup — bảng:** thao tác | WAL sinh ra | dữ liệu thật | **tỷ lệ khuếch đại**. Index làm WAL tăng bao nhiêu %?

---

## §3. `full_page_writes` — nguồn khuếch đại lớn nhất

### Lý thuyết

Vấn đề **torn page**: nếu máy mất điện giữa lúc OS đang ghi một page 8KB (đĩa ghi theo sector 512B hoặc 4KB), page trên đĩa có thể nửa cũ nửa mới. WAL record kiểu "sửa byte thứ 100 của page X" không thể replay lên một page hỏng.

Giải pháp: **lần đầu tiên** một page bị sửa sau mỗi checkpoint, Postgres ghi **toàn bộ page 8KB** vào WAL (gọi là full page image — FPI). Các lần sửa tiếp theo trên page đó chỉ ghi phần thay đổi.

Hệ quả rất quan trọng:

> **Ghi ngay sau checkpoint đắt hơn nhiều so với ghi lâu sau checkpoint** — vì mọi page đụng tới đều phải ghi nguyên 8KB.

Đây là lý do bạn thấy WAL bùng lên theo chu kỳ, và là lý do checkpoint quá thường xuyên rất tốn kém.

`wal_compression = on` (PG15+ hỗ trợ nhiều thuật toán: `pglz`, `lz4`, `zstd`) nén riêng phần FPI — thường giảm WAL 40-70% với chi phí CPU nhỏ. **Rất đáng bật.**

Tắt `full_page_writes` chỉ an toàn nếu hệ thống lưu trữ đảm bảo atomic 8KB write (một số SAN, ZFS với recordsize phù hợp). **Đừng tắt nếu không chắc.**

### Làm ngay

```sql
CHECKPOINT;
SELECT pg_current_wal_lsn() AS truoc \gset
UPDATE t_wal SET dbl_v = dbl_v + 1 WHERE device_id < 200;
SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), :'truoc')) AS ngay_sau_checkpoint;

-- lặp lại NGAY, không checkpoint
SELECT pg_current_wal_lsn() AS truoc \gset
UPDATE t_wal SET dbl_v = dbl_v + 1 WHERE device_id < 200;
SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), :'truoc')) AS lan_hai;
```

Đo FPI qua `pg_stat_statements`:
```sql
SELECT pg_stat_statements_reset();
CHECKPOINT;
UPDATE t_wal SET dbl_v = dbl_v + 1 WHERE device_id < 200;
UPDATE t_wal SET dbl_v = dbl_v + 1 WHERE device_id < 200;
SELECT left(query,40) AS q, calls, wal_records, wal_fpi,
       pg_size_pretty(wal_bytes::bigint) AS wal
FROM pg_stat_statements WHERE query LIKE 'UPDATE t_wal%';
```

Thử `wal_compression`:
```sql
ALTER SYSTEM SET wal_compression = 'lz4';
SELECT pg_reload_conf();
SHOW wal_compression;

CHECKPOINT;
SELECT pg_current_wal_lsn() AS truoc \gset
UPDATE t_wal SET dbl_v = dbl_v + 1 WHERE device_id < 200;
SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), :'truoc')) AS voi_nen;

ALTER SYSTEM SET wal_compression = 'off';
SELECT pg_reload_conf();
```

**Ghi vào writeup:** lần 1 (sau checkpoint) vs lần 2 chênh mấy lần? `wal_fpi` bằng bao nhiêu ở mỗi lần? `wal_compression` giảm được bao nhiêu %?

---

## §4. Checkpoint

### Lý thuyết

Checkpoint đẩy **mọi dirty page** trong shared_buffers xuống đĩa và ghi một điểm mốc vào WAL. Sau đó WAL cũ hơn điểm đó có thể bỏ đi (nếu không có replication slot giữ lại).

Kích hoạt khi:
- Đủ `checkpoint_timeout` (mặc định 5 phút)
- WAL sinh ra vượt `max_wal_size` (mặc định 1GB) → gọi là **checkpoint theo yêu cầu**, cần tránh
- Gọi `CHECKPOINT` thủ công, hoặc shutdown

`checkpoint_completion_target` (mặc định 0.9): trải việc ghi ra trong 90% khoảng thời gian tới checkpoint kế tiếp, thay vì ghi ồ ạt. Giữ ở 0.9.

Đánh đổi:

| | Checkpoint thường xuyên | Checkpoint thưa |
|---|---|---|
| Thời gian recovery sau crash | ngắn | **dài** |
| Lượng WAL (do FPI) | **nhiều** | ít |
| I/O spike | thường xuyên, nhỏ | thưa, lớn |
| Dung lượng WAL cần giữ | ít | nhiều |

Cấu hình production điển hình: `max_wal_size = 8-32GB`, `checkpoint_timeout = 15-30min`. Mục tiêu: checkpoint được kích hoạt bởi **timeout**, không phải bởi `max_wal_size`.

Kiểm tra bằng `pg_stat_checkpointer` (PG17; bản cũ là `pg_stat_bgwriter`): nếu `num_requested` lớn so với `num_timed` thì `max_wal_size` quá nhỏ.

### Làm ngay

```sql
SELECT * FROM pg_stat_checkpointer;
-- nếu lỗi (PG < 17): SELECT * FROM pg_stat_bgwriter;
```

```sql
-- ép checkpoint theo yêu cầu bằng cách đặt max_wal_size nhỏ
ALTER SYSTEM SET max_wal_size = '128MB';
SELECT pg_reload_conf();
SELECT pg_stat_reset_shared('checkpointer');

INSERT INTO t_wal SELECT * FROM ts_kv LIMIT 1000000;
SELECT * FROM pg_stat_checkpointer;

ALTER SYSTEM SET max_wal_size = '2GB';
SELECT pg_reload_conf();
SELECT pg_stat_reset_shared('checkpointer');
INSERT INTO t_wal SELECT * FROM ts_kv LIMIT 1000000;
SELECT * FROM pg_stat_checkpointer;
```

**Ghi vào writeup:** `num_requested` vs `num_timed` ở hai cấu hình. Với `max_wal_size` nhỏ, có bao nhiêu checkpoint theo yêu cầu? Thời gian INSERT chênh bao nhiêu?

Xem log checkpoint:
```bash
docker logs pgdd 2>&1 | grep -i checkpoint | tail -20
```

---

## §5. `synchronous_commit`

### Lý thuyết

| Giá trị | Commit trả về khi | Mất gì nếu crash |
|---|---|---|
| `on` (mặc định) | WAL đã `fsync` xuống đĩa | không mất gì |
| `off` | WAL mới nằm trong bộ đệm HĐH | **các transaction trong `wal_writer_delay × 3`** (~600ms) |
| `local` | fsync trên primary, không đợi replica | không mất trên primary |
| `remote_write` | replica đã nhận và ghi (chưa fsync) | mất nếu cả hai cùng crash |
| `remote_apply` | replica đã **áp dụng** — replica đọc thấy ngay | chậm nhất |

Điểm rất quan trọng: `synchronous_commit = off` **không** làm mất tính toàn vẹn — database vẫn nhất quán sau crash, chỉ là **mất một ít transaction cuối**. Khác hẳn với việc tắt `fsync` (cái đó làm hỏng database).

Nên đây là một đánh đổi hợp lệ cho dữ liệu chấp nhận mất vài trăm ms cuối — **telemetry IoT là ví dụ điển hình**. Bạn đặt được **theo từng transaction**:

```sql
BEGIN;
SET LOCAL synchronous_commit = off;   -- chỉ cho transaction này
INSERT INTO ts_kv ...;
COMMIT;
```

Nghĩa là: ghi telemetry dùng `off` (nhanh), ghi dữ liệu tài chính/cấu hình dùng `on` (an toàn). Rất linh hoạt.

### Làm ngay

```sql
CREATE TABLE t_sync (id serial, v int);

\timing on
SET synchronous_commit = on;
DO $$ BEGIN FOR i IN 1..3000 LOOP INSERT INTO t_sync(v) VALUES (i); END LOOP; END $$;

SET synchronous_commit = off;
DO $$ BEGIN FOR i IN 1..3000 LOOP INSERT INTO t_sync(v) VALUES (i); END LOOP; END $$;

RESET synchronous_commit;
```

> Lưu ý: `DO` block chạy trong **một** transaction nên khác biệt sẽ nhỏ. Để thấy rõ, mỗi INSERT phải là một transaction riêng — dùng pgbench:

```bash
cat > /tmp/ins.sql <<'EOF'
INSERT INTO t_sync(v) VALUES (1);
EOF
docker cp /tmp/ins.sql pgdd:/tmp/ins.sql

docker exec pgdd psql -U postgres -d lab -c "ALTER SYSTEM SET synchronous_commit='on'; SELECT pg_reload_conf();"
docker exec pgdd pgbench -U postgres -d lab -f /tmp/ins.sql -c 8 -T 10 2>&1 | grep tps

docker exec pgdd psql -U postgres -d lab -c "ALTER SYSTEM SET synchronous_commit='off'; SELECT pg_reload_conf();"
docker exec pgdd pgbench -U postgres -d lab -f /tmp/ins.sql -c 8 -T 10 2>&1 | grep tps

docker exec pgdd psql -U postgres -d lab -c "ALTER SYSTEM SET synchronous_commit='on'; SELECT pg_reload_conf();"
```

**Ghi vào writeup:** tps chênh mấy lần? Trong tình huống xấu nhất, `off` làm mất bao nhiêu dữ liệu (tính bằng giây và bằng số transaction)?

---

## §6. WAL bị giữ lại — nguy cơ đầy đĩa

### Lý thuyết

WAL cũ bị giữ lại (không xoá được) bởi:

| Nguyên nhân | Kiểm tra |
|---|---|
| **Replication slot không hoạt động** | `pg_replication_slots` — thủ phạm số 1 |
| `wal_keep_size` đặt cao | `SHOW wal_keep_size` |
| `archive_command` thất bại | `pg_stat_archiver.last_failed_time` |
| Checkpoint chưa chạy | bình thường, tự khắc phục |

Replication slot bị bỏ quên là sự cố kinh điển: một replica bị gỡ nhưng slot không xoá → primary giữ WAL vô hạn → **đĩa đầy → database dừng.** Cùng với đó, slot cũ còn **chặn vacuum** (Day 25).

Phòng: đặt `max_slot_wal_keep_size` (PG13+) để Postgres tự vô hiệu hoá slot khi vượt ngưỡng — thà mất replica còn hơn sập primary.

### Làm ngay

```sql
SELECT slot_name, slot_type, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_giu_lai
FROM pg_replication_slots;

SHOW max_slot_wal_keep_size;
SHOW wal_keep_size;
SELECT * FROM pg_stat_archiver;

SELECT pg_size_pretty(sum(size)) AS tong_wal, count(*) AS so_segment FROM pg_ls_waldir();
```

Tạo một slot bỏ quên để thấy hiệu ứng:
```sql
SELECT pg_create_physical_replication_slot('slot_bo_quen');
INSERT INTO t_wal SELECT * FROM ts_kv LIMIT 500000;
CHECKPOINT;
SELECT slot_name, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS giu_lai
FROM pg_replication_slots;
SELECT pg_size_pretty(sum(size)) FROM pg_ls_waldir();

SELECT pg_drop_replication_slot('slot_bo_quen');
CHECKPOINT;
SELECT pg_size_pretty(sum(size)) FROM pg_ls_waldir();
```

**Ghi vào writeup:** slot bỏ quên giữ lại bao nhiêu WAL? Sau khi xoá slot và checkpoint, WAL giảm bao nhiêu? **Viết query monitoring cho slot.**

---

## §7. Cấu hình cho hệ thật

### Lý thuyết — checklist

| GUC | Khởi điểm | Ghi chú |
|---|---|---|
| `max_wal_size` | 8–32 GB | đủ lớn để checkpoint theo timeout |
| `min_wal_size` | 2–4 GB | tránh tạo/xoá segment liên tục |
| `checkpoint_timeout` | 15–30 min | cân với thời gian recovery chấp nhận được |
| `checkpoint_completion_target` | 0.9 | giữ nguyên |
| `wal_compression` | `lz4` hoặc `zstd` | gần như luôn đáng bật |
| `wal_buffers` | −1 (tự động = 1/32 shared_buffers) | ít khi cần chỉnh |
| `synchronous_commit` | `on` toàn cục, `off` cho bảng chịu mất | đặt per-transaction |
| `max_slot_wal_keep_size` | 10–20% dung lượng đĩa WAL | **bảo hiểm chống đầy đĩa** |

### Làm ngay

**Ghi vào writeup:** viết bộ cấu hình WAL bạn đề xuất cho DB production của mình, kèm lý do từng con số. Đặc biệt: với workload telemetry, bạn đặt `synchronous_commit` thế nào cho luồng ghi telemetry so với luồng ghi cấu hình/lệnh điều khiển?

### Dọn dẹp

```sql
DROP TABLE t_wal, t_sync;
```

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B. Áp dụng vào hệ thật:** kiểm tra trên production — `num_requested` checkpoint có cao không, có replication slot nào không hoạt động không, `wal_compression` đã bật chưa? Ước lượng bật `wal_compression` tiết kiệm bao nhiêu I/O mỗi ngày.

### Đạt khi

Bạn đo được WAL amplification và chỉ ra FPI là nguyên nhân, biết chỉnh `max_wal_size` dựa trên `num_requested`, và biết chính xác `synchronous_commit=off` đánh đổi cái gì.

**Xong thì gõ `/review-bai`.**
