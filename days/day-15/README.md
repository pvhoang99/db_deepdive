# Day 15 — Chẩn đoán mù + ôn tuần 3

**Thời lượng:** 60–90 phút · **Cách học:** hôm nay đảo ngược — **chẩn đoán trước, chạy sau**.

## Chuẩn bị

```sql
\timing on
\o /days/day-15/output.txt
ANALYZE;
```

---

## Luật chơi hôm nay

Với mỗi ca dưới đây:

1. **Đọc mô tả và plan xấu. KHÔNG chạy gì cả.**
2. Viết vào `writeup.md`: **chẩn đoán** (gốc bệnh là gì) + **cách sửa** bạn định làm + **dự đoán** cải thiện bao nhiêu.
3. Chỉ khi đã viết xong mới chạy để kiểm chứng.
4. Ghi lại: bạn đúng hay sai, và nếu sai thì vì sao.

Đây là bài kiểm tra thật của tuần 3. Tỷ lệ đúng của bạn cho biết bạn đã thật sự hiểu hay chỉ đang làm theo hướng dẫn.

---

## Ca 1 — "Query này chạy 5 lần đầu nhanh rồi chậm mãi"

### Bối cảnh

Service Java gọi qua JDBC với prepared statement. Endpoint lấy telemetry của một device. Với đa số device thì nhanh, nhưng có vài device rất chậm — và lạ ở chỗ nếu restart service thì lại nhanh được vài phút.

```sql
PREPARE tele(bigint) AS
SELECT ts, dbl_v FROM ts_kv WHERE device_id = $1 ORDER BY ts DESC LIMIT 100;
```

### Chẩn đoán trước (viết vào writeup rồi mới chạy)

### Kiểm chứng

```sql
CREATE INDEX IF NOT EXISTS idx_dev_ts_d ON ts_kv(device_id, ts DESC);
ANALYZE ts_kv;

DEALLOCATE ALL;
PREPARE tele(bigint) AS SELECT ts, dbl_v FROM ts_kv WHERE device_id = $1 ORDER BY ts DESC LIMIT 100;

EXPLAIN (ANALYZE, BUFFERS) EXECUTE tele(49000);   -- lần 1
EXPLAIN (ANALYZE, BUFFERS) EXECUTE tele(49000);   -- 2
EXPLAIN (ANALYZE, BUFFERS) EXECUTE tele(49000);   -- 3
EXPLAIN (ANALYZE, BUFFERS) EXECUTE tele(49000);   -- 4
EXPLAIN (ANALYZE, BUFFERS) EXECUTE tele(49000);   -- 5
EXPLAIN (ANALYZE, BUFFERS) EXECUTE tele(49000);   -- 6
EXPLAIN (ANALYZE, BUFFERS) EXECUTE tele(1);       -- 7 - device nói nhiều nhất
```

**Ghi vào writeup:** chẩn đoán của bạn có đúng không? Cách sửa ở tầng ứng dụng là gì (JDBC `prepareThreshold`, pgx `QueryExecMode`)?

---

## Ca 2 — "Thêm một điều kiện WHERE mà query chậm gấp 50 lần"

### Bối cảnh

Query đang chạy tốt:
```sql
SELECT count(*) FROM ts_kv k JOIN device d ON d.id = k.device_id
WHERE d.region = 'eu-west' AND k.ts >= '2025-07-01';
```

Team thêm một điều kiện tưởng như vô hại (`AND d.country = 'DE'`, mà mọi device eu-west đều là DE nên **không lọc thêm dòng nào**) — và query chậm hẳn đi.

### Chẩn đoán trước

### Kiểm chứng

```sql
DROP STATISTICS IF EXISTS st_dev_geo;
ANALYZE device;

EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ts_kv k JOIN device d ON d.id = k.device_id
WHERE d.region='eu-west' AND k.ts >= '2025-07-01';

EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ts_kv k JOIN device d ON d.id = k.device_id
WHERE d.region='eu-west' AND d.country='DE' AND k.ts >= '2025-07-01';
```

Rồi sửa:
```sql
CREATE STATISTICS st_dev_geo (dependencies, mcv) ON region, country FROM device;
ANALYZE device;
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ts_kv k JOIN device d ON d.id = k.device_id
WHERE d.region='eu-west' AND d.country='DE' AND k.ts >= '2025-07-01';
```

**Ghi vào writeup:** thêm điều kiện làm ước lượng của node `device` đổi từ bao nhiêu xuống bao nhiêu? Kiểu join có đổi không? Sau khi có statistics thì sao?

---

## Ca 3 — "Job ETL nạp xong query ngay thì treo"

### Bối cảnh

Pipeline nạp 500k dòng vào bảng staging rồi join ngay với bảng chính trong cùng transaction. Chạy tay từng bước thì nhanh, chạy tự động thì treo hàng chục phút.

### Chẩn đoán trước

### Kiểm chứng

```sql
DROP TABLE IF EXISTS staging;
CREATE TABLE staging (device_id bigint, ts timestamptz, val double precision);

INSERT INTO staging SELECT device_id, ts, dbl_v FROM ts_kv LIMIT 500000;
-- CHƯA analyze, đúng như job thật

EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM staging s JOIN device d ON d.id = s.device_id WHERE d.type='gateway';

ANALYZE staging;

EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM staging s JOIN device d ON d.id = s.device_id WHERE d.type='gateway';
```

**Ghi vào writeup:** trước ANALYZE planner nghĩ `staging` có bao nhiêu dòng? Kiểu join là gì? Sau ANALYZE đổi thế nào, nhanh lên mấy lần? **Bạn sẽ sửa job ETL ở đâu?**

```sql
DROP TABLE staging;
```

---

## Ca 4 — "Index có mà không dùng, nhưng ép dùng thì lại chậm hơn"

### Bối cảnh

Dev phàn nàn Postgres không dùng index. Ép bằng `enable_seqscan=off` thì query còn chậm hơn. Dev kết luận "Postgres dở".

### Chẩn đoán trước

### Kiểm chứng

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv WHERE key_id = 1;

SET enable_seqscan = off;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv WHERE key_id = 1;
RESET enable_seqscan;

SELECT attname, n_distinct, correlation FROM pg_stats
WHERE tablename='ts_kv' AND attname='key_id';
SELECT key_id, count(*), round(100.0*count(*)/sum(count(*)) OVER (),1) AS pct
FROM ts_kv GROUP BY 1 ORDER BY 1;
```

**Ghi vào writeup:** `key_id = 1` chiếm bao nhiêu % bảng? Planner đúng hay sai? Bạn giải thích cho dev đó thế nào bằng **hai câu**, có số?

---

## Ca 5 — "Query chậm dần theo tháng dù dữ liệu không tăng"

### Bối cảnh

Bảng trạng thái bị `UPDATE` rất nhiều nhưng số dòng luôn ổn định ~50.000. Query lookup theo index chậm dần đều qua vài tháng.

### Chẩn đoán trước

### Kiểm chứng

```sql
DROP TABLE IF EXISTS t_state;
CREATE TABLE t_state AS SELECT id, name, tenant_id, firmware FROM device;
CREATE INDEX idx_state_name ON t_state(name);
ALTER TABLE t_state SET (autovacuum_enabled = false);
ANALYZE t_state;

EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM t_state WHERE name = 'device-0000042';
SELECT pg_size_pretty(pg_relation_size('t_state')) tbl,
       pg_size_pretty(pg_relation_size('idx_state_name')) idx;

-- mô phỏng vài tháng update
DO $$ BEGIN FOR i IN 1..8 LOOP UPDATE t_state SET firmware = firmware; END LOOP; END $$;

EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM t_state WHERE name = 'device-0000042';
SELECT pg_size_pretty(pg_relation_size('t_state')) tbl,
       pg_size_pretty(pg_relation_size('idx_state_name')) idx;
SELECT dead_tuple_percent FROM pgstattuple('t_state');
```

**Ghi vào writeup:** bảng và index phình mấy lần? Buffers của query lookup tăng mấy lần? Cách sửa ngắn hạn là gì, cách sửa dài hạn là gì? (Tuần 5 sẽ đào sâu.)

```sql
DROP TABLE t_state;
```

---

## §6. Ôn tuần 3

**Viết vào `writeup.md`:**

**A. Bảng tổng kết chẩn đoán mù:** 5 ca | chẩn đoán của tôi | thực tế | đúng/sai. Tỷ lệ đúng bao nhiêu/5?

**B. Cây quyết định chẩn đoán** — vẽ bằng chữ, dạng:
```
Query chậm
├── rows lệch actual > 10× ở node lá?
│   ├── có → cột lọc là gì?
│   │   ├── một cột, giá trị hiếm → nâng STATISTICS
│   │   ├── hai cột phụ thuộc → CREATE STATISTICS
│   │   ├── bảng vừa nạp dữ liệu → ANALYZE
│   │   └── ...
│   └── không → ...
└── ...
```
Tối đa 12 nhánh. Đây là thứ bạn dán lên tường.

**C. Ba điều tôi tưởng đúng mà hoá ra sai trong tuần 3.**

---

## Kết ngày

### Câu cuối

**Áp dụng vào hệ thật:** trong 5 ca trên, ca nào giống nhất với một sự cố bạn từng gặp (hoặc đang có) ở công ty? Viết lại ca đó bằng bảng/query thật của bạn và nêu cách bạn sẽ xác minh.

### Đạt khi

Bạn chẩn đoán đúng **ít nhất 3/5 ca** trước khi chạy, và cây quyết định của bạn dùng được cho người khác trong team.

**Xong thì gõ `/review-bai`.**

---

## Hết tuần 3

Bạn giờ hiểu vì sao planner sai và sửa được. Tuần 4 chuyển sang **cái xảy ra sau khi plan đã chọn đúng**: join, sort, aggregate — và `work_mem` quyết định sống chết ở đó.
