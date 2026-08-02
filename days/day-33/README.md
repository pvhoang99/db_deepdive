# Day 33 — Vận hành partition: ATTACH, DETACH, retention

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

Cần bảng `ts_p` từ Day 32. Nếu chưa có, tạo lại theo §1 của Day 32.

```sql
\timing on
\o /days/day-33/output.txt
ANALYZE ts_p;
```

---

## §0. Đoán trước

1. `DROP PARTITION` xoá 1,7 triệu dòng mất bao lâu?
2. `DELETE FROM ts_kv WHERE ts < ...` xoá cùng số dòng mất bao lâu?
3. Sau `DELETE`, kích thước bảng đổi thế nào?

---

## §1. Lý do tồn tại thật sự của partitioning

### Lý thuyết

Đây là bài quan trọng nhất của tuần 7 với hệ IoT của bạn.

| Cách xoá dữ liệu cũ | Thời gian | Sinh dead tuple | Khoá | Trả đĩa về OS |
|---|---|---|---|---|
| `DELETE FROM tbl WHERE ts < x` | phút → giờ | **toàn bộ số dòng xoá** | row lock | không |
| `DELETE` + `VACUUM` | thêm nhiều nữa | dọn được | nhẹ | không |
| `DELETE` + `VACUUM FULL` | rất lâu | dọn được | **ACCESS EXCLUSIVE** | có |
| **`DROP TABLE partition`** | **mili giây** | **không** | ACCESS EXCLUSIVE ngắn | **có** |

`DROP PARTITION` chỉ là xoá file — không đọc dòng nào, không ghi WAL cho từng dòng, không sinh rác.

Đây là lý lẽ mạnh nhất, và với hệ IoT giữ dữ liệu 90 ngày thì gần như bắt buộc.

### Làm ngay

Đo hai cách trên cùng lượng dữ liệu:

```sql
SELECT count(*) FROM ts_p_2025_05;
SELECT pg_size_pretty(pg_total_relation_size('ts_p_2025_05'));

-- cách 1: DROP PARTITION
\timing on
BEGIN;
DROP TABLE ts_p_2025_05;
SELECT count(*) FROM ts_p;
ROLLBACK;   -- rollback để giữ dữ liệu cho các bước sau
```

```sql
-- cách 2: DELETE cùng lượng dữ liệu trên bảng phẳng
CREATE TABLE ts_flat AS SELECT * FROM ts_kv;
CREATE INDEX ON ts_flat(ts);
VACUUM ANALYZE ts_flat;
SELECT pg_size_pretty(pg_relation_size('ts_flat')) AS truoc;

\timing on
DELETE FROM ts_flat WHERE ts < '2025-06-01';
SELECT pg_size_pretty(pg_relation_size('ts_flat')) AS sau_delete;

VACUUM ts_flat;
SELECT pg_size_pretty(pg_relation_size('ts_flat')) AS sau_vacuum;
SELECT n_dead_tup FROM pg_stat_user_tables WHERE relname='ts_flat';

\timing on
VACUUM FULL ts_flat;
SELECT pg_size_pretty(pg_relation_size('ts_flat')) AS sau_vacuum_full;
```

**Ghi vào writeup — bảng so sánh:** cách | thời gian | dead tuple sinh ra | kích thước sau | khoá gì.

**Đây là con số bạn sẽ dùng để thuyết phục team.** Phát biểu lý lẽ cho partitioning bằng **2 câu** có số.

```sql
DROP TABLE ts_flat;
```

---

## §2. `ATTACH` và `DETACH`

### Lý thuyết

```sql
-- tách ra khỏi bảng cha, giữ nguyên dữ liệu
ALTER TABLE ts_p DETACH PARTITION ts_p_2025_05;

-- gắn vào
ALTER TABLE ts_p ATTACH PARTITION ts_p_2025_05
  FOR VALUES FROM ('2025-05-01') TO ('2025-06-01');
```

Khi `ATTACH`, Postgres phải **kiểm tra mọi dòng** thoả điều kiện phân vùng — quét toàn bộ bảng, giữ `ACCESS EXCLUSIVE` lock.

**Mẹo quan trọng:** thêm `CHECK` constraint khớp với biên **trước khi** attach. Postgres thấy constraint đã đảm bảo thì bỏ qua bước quét → attach gần như tức thời.

```sql
ALTER TABLE staging ADD CONSTRAINT c CHECK (ts >= '2025-08-01' AND ts < '2025-09-01');
ALTER TABLE ts_p ATTACH PARTITION staging FOR VALUES FROM ('2025-08-01') TO ('2025-09-01');
ALTER TABLE staging DROP CONSTRAINT c;   -- không cần nữa
```

Từ PG14 có `DETACH PARTITION ... CONCURRENTLY` — không giữ lock dài.

### Làm ngay

```sql
-- nạp dữ liệu vào bảng rời rồi attach (mẫu bulk load)
CREATE TABLE ts_p_2025_08 (LIKE ts_p INCLUDING DEFAULTS INCLUDING STORAGE);
INSERT INTO ts_p_2025_08
SELECT device_id, key_id, ts + interval '92 days', dbl_v, bool_v, str_v
FROM ts_kv WHERE ts < '2025-05-10';

-- attach KHÔNG có CHECK
\timing on
ALTER TABLE ts_p ATTACH PARTITION ts_p_2025_08 FOR VALUES FROM ('2025-08-01') TO ('2025-09-01');
```
Ghi thời gian. Rồi thử lại có CHECK:
```sql
ALTER TABLE ts_p DETACH PARTITION ts_p_2025_08;
ALTER TABLE ts_p_2025_08 ADD CONSTRAINT c_ts CHECK (ts >= '2025-08-01' AND ts < '2025-09-01');
\timing on
ALTER TABLE ts_p ATTACH PARTITION ts_p_2025_08 FOR VALUES FROM ('2025-08-01') TO ('2025-09-01');
ALTER TABLE ts_p_2025_08 DROP CONSTRAINT c_ts;
```

**Ghi vào writeup:** attach có/không CHECK chênh nhau mấy lần? Điều này quan trọng thế nào với bảng 100 triệu dòng?

Thử `DETACH CONCURRENTLY`:
```sql
ALTER TABLE ts_p DETACH PARTITION ts_p_2025_08 CONCURRENTLY;
ALTER TABLE ts_p ATTACH PARTITION ts_p_2025_08 FOR VALUES FROM ('2025-08-01') TO ('2025-09-01');
```
**Ghi vào writeup:** nó có chạy trong transaction block được không? Thông báo là gì?

---

## §3. Index trên bảng phân vùng

### Lý thuyết

```sql
CREATE INDEX ON ts_p (device_id, ts);
```
Tạo trên bảng cha → Postgres tự tạo index tương ứng trên **mọi** partition, và mọi partition thêm sau. Lock `ACCESS EXCLUSIVE` trên toàn bộ trong lúc build.

Với production, cách không-downtime:
```sql
-- 1. tạo index ON ONLY trên cha (chỉ metadata, invalid)
CREATE INDEX idx_p ON ONLY ts_p (device_id, ts);
-- 2. tạo CONCURRENTLY trên từng partition
CREATE INDEX CONCURRENTLY idx_p_202505 ON ts_p_2025_05 (device_id, ts);
CREATE INDEX CONCURRENTLY idx_p_202506 ON ts_p_2025_06 (device_id, ts);
-- 3. gắn từng cái vào index cha
ALTER INDEX idx_p ATTACH PARTITION idx_p_202505;
ALTER INDEX idx_p ATTACH PARTITION idx_p_202506;
-- khi mọi partition đã attach, idx_p tự thành valid
```

### Làm ngay

```sql
CREATE INDEX idx_p_key ON ONLY ts_p (key_id, ts);
SELECT indexrelid::regclass, indisvalid FROM pg_index WHERE indrelid = 'ts_p'::regclass;

CREATE INDEX CONCURRENTLY idx_p_key_06 ON ts_p_2025_06 (key_id, ts);
CREATE INDEX CONCURRENTLY idx_p_key_07 ON ts_p_2025_07 (key_id, ts);
CREATE INDEX CONCURRENTLY idx_p_key_05 ON ts_p_2025_05 (key_id, ts);

ALTER INDEX idx_p_key ATTACH PARTITION idx_p_key_05;
ALTER INDEX idx_p_key ATTACH PARTITION idx_p_key_06;
SELECT indexrelid::regclass, indisvalid FROM pg_index WHERE indrelid = 'ts_p'::regclass;

ALTER INDEX idx_p_key ATTACH PARTITION idx_p_key_07;
SELECT indexrelid::regclass, indisvalid FROM pg_index WHERE indrelid = 'ts_p'::regclass;
```

**Ghi vào writeup:** `indisvalid` của index cha đổi lúc nào? Vì sao quy trình này an toàn hơn `CREATE INDEX` thẳng trên cha?

---

## §4. Tự động hoá: tạo partition tương lai + xoá cũ

### Làm ngay

Viết hàm quản lý vòng đời:

```sql
CREATE OR REPLACE FUNCTION quan_ly_partition(
  p_bang text,
  p_thang_tuong_lai int DEFAULT 2,
  p_giu_thang int DEFAULT 3
) RETURNS TABLE(hanh_dong text, ten_partition text)
LANGUAGE plpgsql AS $$
DECLARE
  m date; ten text; cutoff date; r record;
BEGIN
  -- tạo partition cho các tháng tới
  FOR i IN 0..p_thang_tuong_lai LOOP
    m := date_trunc('month', current_date)::date + (i || ' month')::interval;
    ten := format('%s_%s', p_bang, to_char(m, 'YYYY_MM'));
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = ten) THEN
      EXECUTE format('CREATE TABLE %I PARTITION OF %I FOR VALUES FROM (%L) TO (%L)',
                     ten, p_bang, m, m + interval '1 month');
      hanh_dong := 'TAO'; ten_partition := ten; RETURN NEXT;
    END IF;
  END LOOP;

  -- xoá partition cũ hơn ngưỡng giữ
  cutoff := (date_trunc('month', current_date) - (p_giu_thang || ' month')::interval)::date;
  FOR r IN
    SELECT c.relname FROM pg_inherits i
    JOIN pg_class c ON c.oid = i.inhrelid
    WHERE i.inhparent = p_bang::regclass
      AND c.relname ~ '\d{4}_\d{2}$'
      AND to_date(right(c.relname, 7), 'YYYY_MM') < cutoff
  LOOP
    EXECUTE format('DROP TABLE %I', r.relname);
    hanh_dong := 'XOA'; ten_partition := r.relname; RETURN NEXT;
  END LOOP;
END $$;

SELECT * FROM quan_ly_partition('ts_p', 2, 12);
SELECT relname FROM pg_class c JOIN pg_inherits i ON i.inhrelid = c.oid
WHERE i.inhparent = 'ts_p'::regclass ORDER BY 1;
```

**Ghi vào writeup:** hàm tạo ra những partition nào? Bạn sẽ chạy nó bằng gì trên production — `pg_cron`, Temporal workflow, hay cron ngoài? **Điều gì xảy ra nếu nó không chạy một tháng?** (Gợi ý: nghĩ về partition DEFAULT.)

---

## §5. Retention: xoá vs archive

### Lý thuyết

Không phải lúc nào cũng xoá. Ba mức xử lý dữ liệu cũ:

| Mức | Cách làm | Chi phí |
|---|---|---|
| **Nóng** (0-7 ngày) | partition thường, index đầy đủ, SSD | cao |
| **Ấm** (7-90 ngày) | partition đã downsample, ít index hơn | trung bình |
| **Lạnh** (>90 ngày) | `DETACH` rồi export ra Parquet/S3, hoặc chuyển tablespace chậm | thấp |

Tablespace riêng cho dữ liệu cũ:
```sql
CREATE TABLESPACE cold LOCATION '/mnt/hdd/pg';
ALTER TABLE ts_p_2025_05 SET TABLESPACE cold;
```

Trước khi xoá, thường phải rollup (Day 19): giữ trung bình theo giờ/ngày vĩnh viễn, xoá dữ liệu thô.

### Làm ngay

```sql
-- rollup trước khi xoá partition
CREATE TABLE ts_rollup_daily (
  device_id bigint, key_id smallint, ngay date,
  n bigint, avg_v double precision, min_v double precision, max_v double precision,
  PRIMARY KEY (device_id, key_id, ngay)
);

INSERT INTO ts_rollup_daily
SELECT device_id, key_id, ts::date, count(*), avg(dbl_v), min(dbl_v), max(dbl_v)
FROM ts_p_2025_05 GROUP BY 1,2,3;

SELECT pg_size_pretty(pg_total_relation_size('ts_p_2025_05')) AS tho,
       pg_size_pretty(pg_total_relation_size('ts_rollup_daily')) AS rollup,
       round(100.0 * pg_total_relation_size('ts_rollup_daily')
             / pg_total_relation_size('ts_p_2025_05'), 2) AS pct;
```

**Ghi vào writeup:** rollup chiếm bao nhiêu % dữ liệu thô? Với tỷ lệ này, bạn giữ rollup được bao lâu trong cùng dung lượng?

---

## §6. Sub-partitioning và LIST partition

### Lý thuyết

Partition lồng nhau: theo tháng, rồi trong mỗi tháng chia theo tenant.

```sql
CREATE TABLE ts_p_2025_09 PARTITION OF ts_p
  FOR VALUES FROM ('2025-09-01') TO ('2025-10-01')
  PARTITION BY LIST (device_id);
```

Rất mạnh cho multi-tenant: mỗi tenant lớn có partition riêng, có thể xoá/khôi phục/di chuyển độc lập.

Cái giá: số partition nhân lên (12 tháng × 20 tenant = 240) → planning time tăng mạnh. Chỉ dùng khi thật sự cần cô lập theo tenant.

### Làm ngay

```sql
CREATE TABLE ts_p_2025_09 PARTITION OF ts_p
  FOR VALUES FROM ('2025-09-01') TO ('2025-10-01')
  PARTITION BY RANGE (device_id);

CREATE TABLE ts_p_2025_09_lo PARTITION OF ts_p_2025_09 FOR VALUES FROM (MINVALUE) TO (25000);
CREATE TABLE ts_p_2025_09_hi PARTITION OF ts_p_2025_09 FOR VALUES FROM (25000) TO (MAXVALUE);

INSERT INTO ts_p SELECT device_id, key_id, ts + interval '123 days', dbl_v, bool_v, str_v
FROM ts_kv LIMIT 100000;
ANALYZE ts_p;

EXPLAIN (ANALYZE) SELECT count(*) FROM ts_p
WHERE ts >= '2025-09-01' AND ts < '2025-09-15' AND device_id = 42;
```

**Ghi vào writeup:** plan prune tới mức nào — chỉ một sub-partition? `Planning Time` so với bảng chỉ 1 tầng?

---

## §7. Migrate bảng phẳng sang phân vùng — không downtime

### Lý thuyết

Quy trình chuẩn cho production:

1. Tạo bảng phân vùng mới `tbl_new` với cùng schema
2. Tạo partition cho toàn bộ phạm vi dữ liệu hiện có + tương lai
3. Copy dữ liệu theo lô (theo khoảng thời gian, mỗi lô một transaction) — chạy nền, nhiều giờ
4. Ứng dụng **ghi kép** (dual write) vào cả hai bảng, hoặc dùng trigger
5. Khi đã bắt kịp: transaction ngắn `ALTER TABLE tbl RENAME TO tbl_old; ALTER TABLE tbl_new RENAME TO tbl;`
6. Theo dõi vài ngày rồi mới `DROP tbl_old`

Bước 5 chỉ mất mili giây nhưng cần `ACCESS EXCLUSIVE` — đặt `lock_timeout` ngắn và retry để không xếp hàng sau một query dài.

```sql
SET lock_timeout = '3s';
BEGIN;
ALTER TABLE ts_kv RENAME TO ts_kv_old;
ALTER TABLE ts_p RENAME TO ts_kv;
COMMIT;
```

### Làm ngay

Viết kế hoạch migrate cho bảng telemetry thật của bạn.

**Ghi vào writeup:** kế hoạch từng bước, kèm: bao nhiêu dữ liệu, copy mất bao lâu (ước tính từ tốc độ đo ở §1), rollback thế nào nếu hỏng ở mỗi bước, và cách bạn kiểm chứng dữ liệu khớp trước khi đổi tên.

### Dọn dẹp

```sql
DROP TABLE ts_p CASCADE;
DROP TABLE ts_rollup_daily;
DROP FUNCTION quan_ly_partition(text,int,int);
```

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B. Áp dụng vào hệ thật:** hiện tại bạn xoá telemetry cũ bằng cách nào, mất bao lâu, gây bloat bao nhiêu? Với số liệu ở §1, partition tiết kiệm được bao nhiêu thời gian và bao nhiêu GB mỗi tháng?

### Đạt khi

Bạn có con số thật so sánh `DROP PARTITION` với `DELETE`, viết được hàm quản lý vòng đời partition, và có kế hoạch migrate không-downtime cho bảng thật.

**Xong thì gõ `/review-bai`.**
