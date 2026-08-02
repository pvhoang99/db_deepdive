# Day 32 — Declarative partitioning & partition pruning

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

```sql
\timing on
\o /days/day-32/output.txt
```

---

## §0. Đoán trước

1. Query 1 ngày trên bảng phân vùng theo tháng — đọc bao nhiêu partition?
2. Query với `ts > $1` (tham số) có prune được không?
3. Partition có bao giờ làm query **chậm hơn** không?

---

## §1. Partition là gì và không phải là gì

### Lý thuyết

Partitioning chia một bảng logic thành nhiều bảng vật lý. Postgres hỗ trợ 3 kiểu:

| Kiểu | Chia theo | Dùng cho |
|---|---|---|
| `RANGE` | khoảng giá trị | **thời gian** (phổ biến nhất), id |
| `LIST` | danh sách giá trị | tenant_id, region, status |
| `HASH` | băm | phân tán đều khi không có khoá tự nhiên |

**Partition không phải là công cụ tăng tốc query.** Đây là hiểu nhầm phổ biến nhất. Với một query lấy dữ liệu 1 ngày, index B-tree trên bảng phẳng thường **nhanh ngang** bảng phân vùng.

Giá trị thật của partition nằm ở **vận hành**:

| Lợi ích | Vì sao |
|---|---|
| **Xoá dữ liệu cũ tức thời** | `DROP PARTITION` = xoá file, không sinh dead tuple. So với `DELETE` mất hàng giờ + bloat |
| **VACUUM/ANALYZE theo từng phần** | mỗi partition nhỏ, vacuum nhanh, không bao giờ tụt hậu |
| **Index nhỏ hơn** | mỗi partition có index riêng, cây thấp hơn |
| **Bulk load nhanh** | nạp vào partition rời rồi `ATTACH` |
| **Tách tầng lưu trữ** | partition cũ đặt lên tablespace chậm/rẻ |

Cái giá:
- Planning time tăng theo số partition
- Unique constraint **phải chứa khoá phân vùng**
- Khoá ngoại trỏ tới bảng phân vùng có hạn chế
- Query không lọc theo khoá phân vùng phải quét **mọi** partition

### Làm ngay

```sql
CREATE TABLE ts_p (
  device_id bigint      NOT NULL,
  key_id    smallint    NOT NULL,
  ts        timestamptz NOT NULL,
  dbl_v     double precision,
  bool_v    boolean,
  str_v     text
) PARTITION BY RANGE (ts);

CREATE TABLE ts_p_2025_05 PARTITION OF ts_p FOR VALUES FROM ('2025-05-01') TO ('2025-06-01');
CREATE TABLE ts_p_2025_06 PARTITION OF ts_p FOR VALUES FROM ('2025-06-01') TO ('2025-07-01');
CREATE TABLE ts_p_2025_07 PARTITION OF ts_p FOR VALUES FROM ('2025-07-01') TO ('2025-08-01');
CREATE TABLE ts_p_default PARTITION OF ts_p DEFAULT;

\timing on
INSERT INTO ts_p SELECT * FROM ts_kv;

-- index tạo trên bảng cha sẽ tự lan xuống mọi partition
CREATE INDEX ON ts_p (device_id, ts);
ANALYZE ts_p;

SELECT c.relname, pg_size_pretty(pg_total_relation_size(c.oid)) AS size,
       (SELECT count(*) FROM pg_inherits WHERE inhrelid = c.oid) AS la_partition
FROM pg_class c WHERE c.relname LIKE 'ts_p%' ORDER BY 1;
```

**Ghi vào writeup:** mỗi partition to bao nhiêu? `ts_p_default` có dòng nào không — nếu có thì vì sao?

---

## §2. Partition pruning — lúc plan

### Lý thuyết

Pruning = loại bỏ partition không cần đọc. Xảy ra ở **hai thời điểm**:

**Plan-time pruning** — khi điều kiện là hằng số. Partition bị loại **không xuất hiện trong plan**.

**Execution-time pruning** (PG11+) — khi điều kiện chỉ biết lúc chạy (tham số, subquery, nested loop). Plan chứa mọi partition nhưng runtime bỏ qua. Nhận ra qua dòng **`Subplans Removed: N`**.

GUC: `enable_partition_pruning` (mặc định on).

### Làm ngay

```sql
-- điều kiện hằng số
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ts_p WHERE ts >= '2025-06-01' AND ts < '2025-06-02';

-- cross-month
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ts_p WHERE ts >= '2025-05-25' AND ts < '2025-06-05';

-- không lọc theo khoá phân vùng
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ts_p WHERE device_id = 42;

-- tắt pruning để so
SET enable_partition_pruning = off;
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ts_p WHERE ts >= '2025-06-01' AND ts < '2025-06-02';
RESET enable_partition_pruning;
```

**Ghi vào writeup — bảng 4 dòng:** query | số partition trong plan | buffers | time. Query nào phải quét mọi partition?

---

## §3. Execution-time pruning và cái bẫy tham số

### Làm ngay

```sql
PREPARE q(timestamptz, timestamptz) AS
  SELECT count(*) FROM ts_p WHERE ts >= $1 AND ts < $2;

EXPLAIN (ANALYZE) EXECUTE q('2025-06-01','2025-06-02');   -- chạy 6 lần
EXPLAIN (ANALYZE) EXECUTE q('2025-06-01','2025-06-02');
EXPLAIN (ANALYZE) EXECUTE q('2025-06-01','2025-06-02');
EXPLAIN (ANALYZE) EXECUTE q('2025-06-01','2025-06-02');
EXPLAIN (ANALYZE) EXECUTE q('2025-06-01','2025-06-02');
EXPLAIN (ANALYZE) EXECUTE q('2025-06-01','2025-06-02');   -- generic plan, tìm "Subplans Removed"
```

Điều kiện từ subquery:
```sql
EXPLAIN (ANALYZE)
SELECT count(*) FROM ts_p WHERE ts >= (SELECT min(ts)+interval '30 days' FROM ts_p);
```

**Ghi vào writeup:** ở lần thứ 6, plan có `Subplans Removed: N` không? Vì sao pruning **không** xảy ra lúc plan mà phải đợi runtime? Buffers có tiết kiệm được không?

---

## §4. So bảng phẳng vs bảng phân vùng

### Làm ngay

```sql
-- bảng phẳng đã có index (device_id, ts) từ tuần 2
CREATE INDEX IF NOT EXISTS idx_dev_ts ON ts_kv(device_id, ts);
ANALYZE ts_kv; ANALYZE ts_p;

-- Q1: 1 ngày
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv WHERE ts >= '2025-06-01' AND ts < '2025-06-02';
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_p  WHERE ts >= '2025-06-01' AND ts < '2025-06-02';

-- Q2: 1 device trong 1 ngày
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv WHERE device_id=42 AND ts >= '2025-06-01' AND ts < '2025-06-02';
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_p  WHERE device_id=42 AND ts >= '2025-06-01' AND ts < '2025-06-02';

-- Q3: 1 device toàn thời gian
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv WHERE device_id=42;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_p  WHERE device_id=42;

-- Q4: aggregate toàn bảng
EXPLAIN (ANALYZE, BUFFERS) SELECT key_id, count(*) FROM ts_kv GROUP BY key_id;
EXPLAIN (ANALYZE, BUFFERS) SELECT key_id, count(*) FROM ts_p  GROUP BY key_id;
```

**Ghi vào writeup — bảng 8 dòng:** query | bảng | Planning Time | Execution Time | buffers.

Câu quan trọng: **query nào partition thắng, query nào phẳng thắng?** Chú ý `Planning Time` — có tăng không?

---

## §5. Planning time tăng theo số partition

### Lý thuyết

Với mỗi partition, planner phải xét xem có prune được không. Với 1000 partition, planning time có thể lên vài chục ms — vấn đề lớn với query OLTP chạy hàng nghìn lần/giây.

Kinh nghiệm: **giữ dưới ~100 partition** cho bảng OLTP. Nếu cần nhiều hơn, cân nhắc phân vùng theo tuần/tháng thay vì ngày, hoặc dùng partition lồng nhau có chọn lọc.

### Làm ngay

Tạo bảng có nhiều partition để đo:
```sql
CREATE TABLE ts_many (ts timestamptz NOT NULL, v int) PARTITION BY RANGE (ts);
DO $$
DECLARE d date := '2025-05-01';
BEGIN
  WHILE d < '2025-08-01' LOOP
    EXECUTE format('CREATE TABLE ts_many_%s PARTITION OF ts_many FOR VALUES FROM (%L) TO (%L)',
                   to_char(d,'YYYYMMDD'), d, d+1);
    d := d + 1;
  END LOOP;
END $$;

SELECT count(*) FROM pg_inherits WHERE inhparent = 'ts_many'::regclass;
ANALYZE ts_many;

EXPLAIN (ANALYZE) SELECT count(*) FROM ts_many WHERE ts >= '2025-06-01' AND ts < '2025-06-02';
EXPLAIN (ANALYZE) SELECT count(*) FROM ts_many;
```

So với bảng 3 partition:
```sql
EXPLAIN (ANALYZE) SELECT count(*) FROM ts_p WHERE ts >= '2025-06-01' AND ts < '2025-06-02';
```

**Ghi vào writeup:** `Planning Time` với 92 partition vs 4 partition? Với query không prune được thì sao?

---

## §6. Ràng buộc và hạn chế

### Lý thuyết

**Unique/PK phải chứa khoá phân vùng:**
```sql
-- LỖI: không có ts trong khoá
ALTER TABLE ts_p ADD PRIMARY KEY (device_id, key_id);
-- OK
ALTER TABLE ts_p ADD PRIMARY KEY (device_id, key_id, ts);
```
Lý do: Postgres không có index toàn cục qua các partition, nên không thể đảm bảo duy nhất xuyên partition.

Đây là hạn chế **quan trọng nhất** cần cân nhắc trước khi partition. Nếu bảng của bạn có unique constraint không chứa cột thời gian, bạn phải thiết kế lại.

**Khoá ngoại:** bảng phân vùng **được** trỏ tới bảng thường; và từ PG12 bảng thường cũng trỏ được tới bảng phân vùng.

**Partition DEFAULT:** hứng dòng không khớp partition nào. Có nó thì insert không lỗi, nhưng khi `ATTACH` partition mới Postgres phải **quét toàn bộ** DEFAULT để kiểm tra — rất chậm. Cân nhắc không dùng DEFAULT và tạo partition trước.

### Làm ngay

```sql
-- thử tạo PK sai
ALTER TABLE ts_p ADD PRIMARY KEY (device_id, key_id);
```
Đọc kỹ thông báo lỗi.

```sql
ALTER TABLE ts_p ADD PRIMARY KEY (device_id, key_id, ts);
SELECT indexrelid::regclass, indisprimary FROM pg_index
WHERE indrelid IN (SELECT inhrelid FROM pg_inherits WHERE inhparent='ts_p'::regclass);
```

Thử insert ngoài phạm vi:
```sql
INSERT INTO ts_p VALUES (1, 1, '2030-01-01', 1, null, null);
SELECT count(*) FROM ts_p_default;

-- bỏ DEFAULT rồi thử lại
ALTER TABLE ts_p DETACH PARTITION ts_p_default;
INSERT INTO ts_p VALUES (1, 1, '2031-01-01', 1, null, null);
```

**Ghi vào writeup:** thông báo lỗi khi tạo PK thiếu khoá phân vùng là gì, giải thích lý do. Khi không có DEFAULT, insert ngoài phạm vi báo lỗi gì? **Trong hệ của bạn, bảng nào có unique constraint sẽ cản trở việc partition?**

---

## §7. Partition-wise join và aggregate

### Lý thuyết

Nếu hai bảng phân vùng **theo cùng khoá và cùng biên**, planner có thể join từng cặp partition riêng rồi gộp — thay vì gộp hết rồi join. Tiết kiệm rất nhiều RAM và cho phép song song hoá tốt hơn.

Mặc định **tắt** (vì tốn planning time):
```sql
SET enable_partitionwise_join = on;
SET enable_partitionwise_aggregate = on;
```

Với `partitionwise_aggregate`, mỗi partition được aggregate riêng rồi gộp — rất hợp với time-series.

### Làm ngay

```sql
SET enable_partitionwise_aggregate = off;
EXPLAIN (ANALYZE, BUFFERS)
SELECT date_trunc('day', ts) d, count(*) FROM ts_p GROUP BY 1 ORDER BY 1;

SET enable_partitionwise_aggregate = on;
EXPLAIN (ANALYZE, BUFFERS)
SELECT date_trunc('day', ts) d, count(*) FROM ts_p GROUP BY 1 ORDER BY 1;
RESET enable_partitionwise_aggregate;
```

**Ghi vào writeup:** plan đổi thế nào? Thời gian và `Planning Time` đổi bao nhiêu? Khi nào bạn bật GUC này?

### Dọn dẹp (giữ `ts_p` cho Day 33)

```sql
DROP TABLE ts_many;
DROP TABLE ts_p_default;
DELETE FROM ts_p WHERE ts > '2025-08-01';
```

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?** Đặc biệt câu 3 — partition có làm query chậm hơn không?

**B. Áp dụng vào hệ thật:** bảng telemetry của bạn có bao nhiêu dữ liệu, giữ bao lâu? Nếu partition theo tháng thì bao nhiêu partition? Có unique constraint nào cản không? **Lợi ích lớn nhất bạn kỳ vọng là gì — query nhanh hơn hay vận hành dễ hơn?**

### Đạt khi

Bạn giải thích được partition **không** phải công cụ tăng tốc query mà là công cụ vận hành, đọc được `Subplans Removed`, và biết ràng buộc unique-key là rào cản chính khi áp dụng.

**Xong thì gõ `/review-bai`.**
