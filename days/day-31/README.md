# Day 31 — BRIN: index 1000 lần nhỏ hơn cho dữ liệu time-series

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

```sql
\timing on
\o /days/day-31/output.txt
ANALYZE ts_kv;
```

---

## §0. Đoán trước

1. BRIN index trên `ts_kv(ts)` (5 triệu dòng) to bao nhiêu KB?
2. So với B-tree trên cùng cột thì nhỏ hơn mấy lần?
3. Nếu xáo trộn thứ tự vật lý của bảng, BRIN chậm đi mấy lần?

---

## §1. BRIN — ý tưởng

### Lý thuyết

**BRIN = Block Range INdex.** Thay vì lưu một entry cho mỗi dòng (như B-tree), nó lưu một entry cho mỗi **nhóm page liên tiếp** (mặc định 128 page = 1 MB).

Mỗi entry chỉ chứa **giá trị min và max** trong nhóm đó:

```
Range 0 (page 0-127):    ts ∈ [2025-05-01 00:00, 2025-05-01 00:35]
Range 1 (page 128-255):  ts ∈ [2025-05-01 00:35, 2025-05-01 01:10]
Range 2 (page 256-383):  ts ∈ [2025-05-01 01:10, 2025-05-01 01:45]
...
```

Query `WHERE ts BETWEEN a AND b`:
1. Quét toàn bộ BRIN (rất nhanh — nó tí xíu)
2. Bỏ qua mọi range mà `[min,max]` không giao với `[a,b]`
3. Với range còn lại, **quét toàn bộ page** trong range đó và lọc từng dòng

Điểm mấu chốt: BRIN **không** cho biết dòng nào khớp, chỉ cho biết range nào **có thể** chứa dòng khớp. Nó là bộ lọc thô.

Kích thước: 5 triệu dòng ≈ 37.000 page ≈ 290 range × ~30 byte ≈ **vài chục KB**. So với B-tree ~110 MB. **Nhỏ hơn hàng nghìn lần.**

### Làm ngay

```sql
CREATE INDEX idx_ts_btree ON ts_kv(ts);
CREATE INDEX idx_ts_brin  ON ts_kv USING brin(ts);
ANALYZE ts_kv;

SELECT relname, pg_size_pretty(pg_relation_size(oid)) AS size,
       pg_relation_size(oid) AS bytes
FROM pg_class WHERE relname IN ('idx_ts_btree','idx_ts_brin','ts_kv');
```

**Ghi vào writeup:** BRIN nhỏ hơn B-tree bao nhiêu **lần**? BRIN bằng bao nhiêu % kích thước bảng?

---

## §2. `correlation` là tất cả

### Lý thuyết

BRIN chỉ hiệu quả khi thứ tự **vật lý** trùng thứ tự **giá trị** — tức `correlation` gần 1.

Nếu dữ liệu ngẫu nhiên, mỗi range sẽ có `min ≈ giá trị nhỏ nhất toàn bảng` và `max ≈ giá trị lớn nhất` → **không range nào bị loại** → BRIN thoái hoá thành Seq Scan (còn tệ hơn, vì tốn thêm công quét index).

May mắn là dữ liệu time-series **tự nhiên có correlation = 1**: bạn ghi theo thời gian, Postgres ghi tuần tự vào cuối bảng. Đây là lý do BRIN sinh ra.

Các cột khác cũng có correlation cao: `bigserial` PK, `created_at`, và bất kỳ cột nào tương quan với thứ tự chèn.

### Làm ngay

```sql
SELECT attname, correlation FROM pg_stats
WHERE tablename='ts_kv' ORDER BY abs(correlation) DESC NULLS LAST;
```

**Ghi vào writeup:** cột nào correlation cao? Cột nào BRIN sẽ vô dụng?

---

## §3. So hiệu năng ba cách

### Làm ngay

Với mỗi phạm vi thời gian, chạy 3 biến thể (ép index bằng mẹo `BEGIN; DROP INDEX; ROLLBACK;` của Day 07):

```sql
-- 1 giờ
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv WHERE ts >= '2025-06-01' AND ts < '2025-06-01 01:00';
-- 1 ngày
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv WHERE ts >= '2025-06-01' AND ts < '2025-06-02';
-- 1 tuần
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv WHERE ts >= '2025-06-01' AND ts < '2025-06-08';
```

Ép seq scan / btree / brin:
```sql
BEGIN; DROP INDEX idx_ts_brin;  EXPLAIN (ANALYZE,BUFFERS) <query>; ROLLBACK;   -- btree
BEGIN; DROP INDEX idx_ts_btree; EXPLAIN (ANALYZE,BUFFERS) <query>; ROLLBACK;   -- brin
BEGIN; DROP INDEX idx_ts_btree, idx_ts_brin; EXPLAIN (ANALYZE,BUFFERS) <query>; ROLLBACK;  -- seq
```

**Ghi vào writeup — bảng 9 dòng:** phạm vi | index | time | shared hit+read | node trong plan.

Chú ý plan BRIN: nó luôn là `Bitmap Heap Scan` với `Bitmap Index Scan on idx_ts_brin`, và có `Rows Removed by Index Recheck` — đó là các dòng nằm trong range được chọn nhưng không thoả điều kiện.

**Ghi vào writeup:** với mỗi phạm vi, BRIN đọc thừa bao nhiêu dòng (`Rows Removed by Index Recheck`)? Ở phạm vi nào BRIN thắng B-tree?

---

## §4. `pages_per_range` — chỉnh độ mịn

### Lý thuyết

```sql
CREATE INDEX ... USING brin(ts) WITH (pages_per_range = 32);
```

| `pages_per_range` | Index | Độ chính xác | Đọc thừa |
|---|---|---|---|
| nhỏ (16-32) | to hơn | mịn hơn | ít |
| mặc định (128) | cân bằng | | |
| lớn (512+) | tí xíu | thô | nhiều |

Quy tắc: chọn sao cho một range xấp xỉ bằng đơn vị truy vấn nhỏ nhất. Nếu bạn hay query theo giờ, chọn `pages_per_range` sao cho một range ≈ một giờ dữ liệu.

### Làm ngay

```sql
CREATE INDEX idx_brin_16  ON ts_kv USING brin(ts) WITH (pages_per_range = 16);
CREATE INDEX idx_brin_128 ON ts_kv USING brin(ts) WITH (pages_per_range = 128);
CREATE INDEX idx_brin_512 ON ts_kv USING brin(ts) WITH (pages_per_range = 512);
ANALYZE ts_kv;

SELECT relname, pg_size_pretty(pg_relation_size(oid)) AS size
FROM pg_class WHERE relname LIKE 'idx_brin_%';
```

Đo query 1 giờ với từng cái (dùng mẹo drop-rollback để cô lập):
```sql
BEGIN;
DROP INDEX idx_ts_btree, idx_ts_brin, idx_brin_128, idx_brin_512;
EXPLAIN (ANALYZE,BUFFERS) SELECT count(*) FROM ts_kv WHERE ts >= '2025-06-01' AND ts < '2025-06-01 01:00';
ROLLBACK;
```
Lặp cho từng biến thể.

**Ghi vào writeup — bảng 3 dòng:** pages_per_range | kích thước index | buffers | Rows Removed by Recheck | time. Cái nào tốt nhất cho query 1 giờ?

---

## §5. Phá correlation — BRIN sụp đổ

### Làm ngay

```sql
CREATE TABLE ts_shuffled AS SELECT * FROM ts_kv ORDER BY random();
CREATE INDEX ON ts_shuffled USING brin(ts);
ANALYZE ts_shuffled;

SELECT tablename, correlation FROM pg_stats
WHERE tablename IN ('ts_kv','ts_shuffled') AND attname = 'ts';

EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv       WHERE ts >= '2025-06-01' AND ts < '2025-06-02';
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_shuffled WHERE ts >= '2025-06-01' AND ts < '2025-06-02';
```

**Ghi vào writeup:** correlation của hai bảng. Cùng query, BRIN trên bảng xáo trộn chậm hơn mấy lần, đọc thừa bao nhiêu dòng? Planner có còn chọn BRIN không?

Khôi phục correlation bằng `CLUSTER`:
```sql
CREATE INDEX idx_shuf_ts_btree ON ts_shuffled(ts);
CLUSTER ts_shuffled USING idx_shuf_ts_btree;
ANALYZE ts_shuffled;
SELECT correlation FROM pg_stats WHERE tablename='ts_shuffled' AND attname='ts';
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_shuffled WHERE ts >= '2025-06-01' AND ts < '2025-06-02';
```

**Ghi vào writeup:** `CLUSTER` sửa được không? Nó khoá gì trong lúc chạy (thử `SELECT` từ session khác)? Có dùng được trên production không?

---

## §6. BRIN cần bảo trì

### Lý thuyết

Khi thêm dữ liệu mới, các range mới **không được cập nhật ngay** — BRIN chỉ tóm tắt tới range cuối cùng đã summarize. Dòng mới nằm trong vùng "chưa summarize" nên **luôn phải quét**.

Hai cách xử lý:

```sql
-- summarize thủ công
SELECT brin_summarize_new_values('idx_ts_brin');

-- hoặc bật tự động (PG10+)
ALTER INDEX idx_ts_brin SET (autosummarize = on);
```

`autosummarize` để autovacuum lo — nên bật cho bảng append-only.

Nếu dữ liệu cũ bị `UPDATE` làm min/max của range rộng ra, range đó mất tác dụng lọc. Sửa bằng `brin_desummarize_range` + summarize lại, hoặc `REINDEX`.

### Làm ngay

```sql
SELECT * FROM brin_metapage_info(get_raw_page('idx_ts_brin', 0));

-- thêm dữ liệu mới
INSERT INTO ts_kv SELECT device_id, key_id, ts + interval '100 days', dbl_v, bool_v, str_v
FROM ts_kv LIMIT 200000;

EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv WHERE ts >= '2025-10-01' AND ts < '2025-10-05';

SELECT brin_summarize_new_values('idx_ts_brin');
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv WHERE ts >= '2025-10-01' AND ts < '2025-10-05';
```

**Ghi vào writeup:** trước và sau `brin_summarize_new_values`, buffers chênh mấy lần? Bạn sẽ bật `autosummarize` hay chạy thủ công theo lịch?

Dọn:
```sql
DELETE FROM ts_kv WHERE ts >= '2025-08-01';
VACUUM ANALYZE ts_kv;
DROP TABLE ts_shuffled;
DROP INDEX IF EXISTS idx_brin_16, idx_brin_128, idx_brin_512;
```

---

## §7. BRIN nhiều cột và các opclass khác

### Lý thuyết

BRIN dùng được với nhiều kiểu dữ liệu qua các **operator class**:

| Opclass | Lưu gì | Dùng cho |
|---|---|---|
| `minmax` (mặc định) | min, max | dữ liệu tăng dần: timestamp, serial |
| `minmax_multi` (PG14+) | **nhiều** khoảng min-max | dữ liệu gần-tăng-dần nhưng có ngoại lệ |
| `bloom` (PG14+) | bloom filter | cột **equality**, không có thứ tự (uuid, hash) |
| `inclusion` | bao đóng | kiểu hình học, inet, range |

`minmax_multi` rất đáng chú ý: nếu bảng của bạn chủ yếu tăng dần nhưng thỉnh thoảng có dữ liệu đến muộn (rất phổ biến với IoT — thiết bị mất mạng rồi gửi bù), `minmax` sẽ bị một giá trị lạc làm hỏng cả range. `minmax_multi` lưu nhiều khoảng nên chịu được.

`bloom` cho phép BRIN hoạt động với cột **không có correlation** — nhưng chỉ cho điều kiện `=`.

### Làm ngay

```sql
-- mô phỏng dữ liệu đến muộn
INSERT INTO ts_kv SELECT device_id, key_id, '2025-05-02'::timestamptz, dbl_v, bool_v, str_v
FROM ts_kv WHERE ts > '2025-07-25' LIMIT 5000;
VACUUM ANALYZE ts_kv;

CREATE INDEX idx_brin_mm  ON ts_kv USING brin(ts);
CREATE INDEX idx_brin_mm4 ON ts_kv USING brin(ts timestamptz_minmax_multi_ops);
ANALYZE ts_kv;

SELECT relname, pg_size_pretty(pg_relation_size(oid)) FROM pg_class
WHERE relname IN ('idx_brin_mm','idx_brin_mm4');
```
Đo query 1 ngày với từng cái (drop-rollback).

Thử `bloom` cho `device_id` (correlation ≈ 0):
```sql
CREATE INDEX idx_brin_bloom ON ts_kv USING brin(device_id int8_bloom_ops);
ANALYZE ts_kv;
SELECT pg_size_pretty(pg_relation_size('idx_brin_bloom'));
BEGIN; DROP INDEX IF EXISTS idx_tskv_dev, idx_dev_ts, idx_dev_key_ts, idx_dev_ts_desc;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv WHERE device_id = 42;
ROLLBACK;
```

**Ghi vào writeup:** `minmax_multi` so với `minmax` khi có dữ liệu đến muộn — kích thước và tốc độ? `bloom` có làm BRIN dùng được cho `device_id` không, so với B-tree thì thế nào?

Dọn:
```sql
DELETE FROM ts_kv WHERE ts = '2025-05-02';
VACUUM ANALYZE ts_kv;
DROP INDEX IF EXISTS idx_brin_mm, idx_brin_mm4, idx_brin_bloom;
```

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B. Áp dụng vào hệ thật:** bảng nào trong hệ ThingsBoard/service của bạn dùng được BRIN? Với mỗi bảng: `correlation` của cột thời gian là bao nhiêu, index B-tree hiện tại to bao nhiêu GB, chuyển sang BRIN tiết kiệm được bao nhiêu, và **mất gì** (query nào sẽ chậm đi)?

### Đạt khi

Bạn giải thích được BRIN bằng cơ chế min/max theo block range, biết khi nào nó vô dụng, và định lượng được lợi ích/tổn thất khi thay B-tree bằng BRIN.

**Xong thì gõ `/review-bai`.**
