# Day 11 — Planner nhìn thấy gì: giải phẫu `pg_stats`

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

```sql
\timing on
\o /days/day-11/output.txt
ANALYZE;
```

---

## §0. Đoán trước

1. `device.type` có 90% `sensor`. Planner ước lượng `WHERE type='sensor'` chính xác không?
2. `WHERE device_id = 42` (device nói nhiều nhất) — planner ước lượng chính xác không?
3. Postgres lấy mẫu bao nhiêu dòng khi `ANALYZE` một bảng 5 triệu dòng?

---

## §1. `ANALYZE` làm gì

### Lý thuyết

`ANALYZE` **không đọc toàn bộ bảng**. Nó lấy mẫu ngẫu nhiên:

```
số dòng lấy mẫu = 300 × default_statistics_target
```

Mặc định `default_statistics_target = 100` → **30.000 dòng**, bất kể bảng có 1 triệu hay 1 tỷ dòng.

Từ mẫu đó nó tính ra và lưu vào `pg_statistic`:

| Thống kê | Nghĩa |
|---|---|
| `null_frac` | tỷ lệ NULL |
| `avg_width` | độ rộng trung bình (byte) |
| `n_distinct` | số giá trị phân biệt. **Dương** = số tuyệt đối; **âm** = tỷ lệ so với số dòng (−1 = mọi dòng đều khác nhau) |
| `most_common_vals` (MCV) | danh sách giá trị phổ biến nhất, tối đa `statistics_target` phần tử |
| `most_common_freqs` | tần suất tương ứng |
| `histogram_bounds` | biên các khoảng chia đều phần **còn lại** (sau khi trừ MCV) |
| `correlation` | tương quan giữa thứ tự logic và thứ tự vật lý, từ −1 tới 1 |

Hai chi tiết quan trọng:
- **MCV và histogram loại trừ nhau.** Giá trị đã vào MCV thì không xuất hiện trong histogram.
- `n_distinct` từ mẫu là **ước lượng ngoại suy**, và với bảng lớn nó thường **sai nặng theo hướng đánh giá thấp**. Đây là nguồn lỗi phổ biến nhất.

### Làm ngay

```sql
SELECT attname, null_frac, avg_width, n_distinct, correlation
FROM pg_stats WHERE tablename = 'ts_kv' ORDER BY attname;

SELECT attname, null_frac, n_distinct, correlation
FROM pg_stats WHERE tablename = 'device' ORDER BY attname;

SHOW default_statistics_target;
```

**Ghi vào writeup:** `n_distinct` của `ts_kv.device_id` là bao nhiêu? So với `SELECT count(DISTINCT device_id) FROM ts_kv` thật. Lệch bao nhiêu %?

---

## §2. MCV — danh sách giá trị phổ biến

### Lý thuyết

Với cột lệch, MCV cho ước lượng **rất chính xác** — vì tần suất được lưu trực tiếp, không phải suy đoán.

```
selectivity(col = 'x')  =  most_common_freqs[i]   nếu 'x' nằm trong MCV
```

Nếu **không** nằm trong MCV:
```
selectivity = (1 − tổng freq của MCV − null_frac) / (n_distinct − số phần tử MCV)
```
Tức là "chia đều phần còn lại". Đây là chỗ sai số bắt đầu.

### Làm ngay

```sql
SELECT attname,
       most_common_vals::text[]  AS mcv,
       most_common_freqs         AS freqs
FROM pg_stats WHERE tablename='device' AND attname IN ('type','firmware','region');
```

Tự tính tay rồi so:
```sql
-- planner ước lượng bao nhiêu?
EXPLAIN SELECT * FROM device WHERE type = 'sensor';
EXPLAIN SELECT * FROM device WHERE type = 'controller';
-- thật bao nhiêu?
SELECT type, count(*) FROM device GROUP BY 1;
```

**Ghi vào writeup:** với `type='sensor'` và `type='controller'`, tự tính `freq × reltuples` rồi so với `rows=` planner in. Khớp tới mức nào?

---

## §3. Histogram — cho cột không lệch

### Lý thuyết

Histogram chia phần dữ liệu **không nằm trong MCV** thành các khoảng **có số dòng bằng nhau** (equi-depth). Với 100 biên → 99 khoảng, mỗi khoảng ~1% dữ liệu.

Ước lượng `col < x`: đếm số khoảng nằm trọn dưới `x`, cộng phần nội suy tuyến tính trong khoảng chứa `x`.

Hệ quả cần biết: **nội suy tuyến tính giả định phân bố đều trong mỗi khoảng.** Nếu dữ liệu bên trong khoảng cũng lệch, ước lượng sẽ sai.

### Làm ngay

```sql
SELECT histogram_bounds::text::text[] FROM pg_stats
WHERE tablename='ts_kv' AND attname='ts';
```

Tự tính selectivity của một khoảng rồi so:
```sql
EXPLAIN SELECT * FROM ts_kv WHERE ts >= '2025-06-01' AND ts < '2025-06-08';
SELECT count(*) FROM ts_kv WHERE ts >= '2025-06-01' AND ts < '2025-06-08';
```

**Ghi vào writeup:** histogram có bao nhiêu biên? Mỗi khoảng chiếm ~bao nhiêu % dữ liệu? Ước lượng của planner cho khoảng 1 tuần lệch bao nhiêu % so với thật?

---

## §4. `n_distinct` — nguồn lỗi số một

### Lý thuyết

Ước lượng số giá trị phân biệt từ mẫu là bài toán khó nổi tiếng trong thống kê. Postgres dùng một công thức ước lượng, và với bảng lớn + cột nhiều giá trị, nó thường **đánh giá thấp** đáng kể.

Vì sao nguy hiểm: `n_distinct` xuất hiện ở mẫu số của công thức selectivity ở §2. `n_distinct` nhỏ hơn thật 5 lần → selectivity lớn hơn thật 5 lần → planner tưởng phải lấy nhiều dòng → bỏ index, chọn seq scan hoặc hash join sai.

Bạn có thể **ghi đè** giá trị này:
```sql
ALTER TABLE ts_kv ALTER COLUMN device_id SET (n_distinct = 50000);
ANALYZE ts_kv;
```
Giá trị âm nghĩa là tỷ lệ: `-0.5` = "một nửa số dòng là giá trị phân biệt". Dùng số âm khi bảng còn lớn lên, để tỷ lệ tự co giãn.

### Làm ngay

```sql
SELECT n_distinct FROM pg_stats WHERE tablename='ts_kv' AND attname='device_id';
SELECT count(DISTINCT device_id) FROM ts_kv;

EXPLAIN SELECT * FROM ts_kv WHERE device_id = 31337;
SELECT count(*) FROM ts_kv WHERE device_id = 31337;
```

Sửa lại rồi đo lần nữa:
```sql
ALTER TABLE ts_kv ALTER COLUMN device_id SET (n_distinct = 50000);
ANALYZE ts_kv;
EXPLAIN SELECT * FROM ts_kv WHERE device_id = 31337;
```

**Ghi vào writeup:** `n_distinct` ước lượng vs thật. Sau khi ghi đè, ước lượng của planner đổi thế nào? Có tiến gần sự thật hơn không?

---

## §5. `default_statistics_target` — đánh đổi mẫu lớn hơn

### Lý thuyết

Tăng `statistics_target` cho một cột làm:
- MCV dài hơn → nhiều giá trị lệch được ghi nhận chính xác
- Histogram nhiều khoảng hơn → nội suy mịn hơn
- `n_distinct` ước lượng tốt hơn (mẫu lớn hơn)

Đổi lại: `ANALYZE` chậm hơn, `pg_statistic` to hơn, **planning time tăng** (planner phải quét MCV dài hơn).

Chiến lược đúng: **để mặc định 100 cho toàn hệ, chỉ nâng cho vài cột thật sự có vấn đề.**
```sql
ALTER TABLE ts_kv ALTER COLUMN device_id SET STATISTICS 1000;
```

### Làm ngay

```sql
-- đo trước
EXPLAIN (ANALYZE) SELECT * FROM ts_kv WHERE device_id = 31337;
SELECT array_length(most_common_vals::text::text[], 1) AS mcv_len
FROM pg_stats WHERE tablename='ts_kv' AND attname='device_id';

ALTER TABLE ts_kv ALTER COLUMN device_id SET STATISTICS 1000;
\timing on
ANALYZE ts_kv;    -- ghi thời gian

SELECT array_length(most_common_vals::text::text[], 1) AS mcv_len
FROM pg_stats WHERE tablename='ts_kv' AND attname='device_id';
EXPLAIN (ANALYZE) SELECT * FROM ts_kv WHERE device_id = 31337;
```

**Ghi vào writeup:** MCV dài từ bao nhiêu lên bao nhiêu? Thời gian ANALYZE tăng mấy lần? `Planning Time` tăng bao nhiêu? Ước lượng chính xác hơn bao nhiêu?

---

## §6. `correlation` — cột quyết định index có đáng không

### Lý thuyết

`correlation` đo mức trùng khớp giữa thứ tự **logic** (giá trị) và thứ tự **vật lý** (vị trí trên đĩa), từ −1 tới 1.

- **1** — hoàn hảo: `ts` trong bảng append-only. Các dòng liền nhau về giá trị cũng liền nhau trên đĩa → index scan gần như tuần tự → **cực rẻ**
- **~0** — ngẫu nhiên: `device_id`. Dòng cần rải khắp bảng → mỗi dòng một random page

Đây chính là biến giải thích tại sao ở Day 04 điểm hoà vốn của `ts` và `device_id` khác hẳn nhau. Planner đưa `correlation` thẳng vào công thức tính cost của Index Scan.

### Làm ngay

```sql
SELECT attname, correlation FROM pg_stats
WHERE tablename='ts_kv' ORDER BY abs(correlation) DESC;
```

Phá correlation rồi đo lại:
```sql
CREATE TABLE ts_shuffled AS SELECT * FROM ts_kv ORDER BY random();
CREATE INDEX ON ts_shuffled(ts);
CREATE INDEX ON ts_kv(ts);
ANALYZE ts_shuffled; ANALYZE ts_kv;

SELECT 'ts_kv' t, correlation FROM pg_stats WHERE tablename='ts_kv' AND attname='ts'
UNION ALL
SELECT 'shuffled', correlation FROM pg_stats WHERE tablename='ts_shuffled' AND attname='ts';

EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv       WHERE ts >= '2025-06-01' AND ts < '2025-06-03';
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_shuffled WHERE ts >= '2025-06-01' AND ts < '2025-06-03';
```

**Ghi vào writeup:** correlation của hai bảng. Cùng một query, buffers chênh mấy lần? Planner có chọn plan khác không?

```sql
DROP TABLE ts_shuffled;
```

---

## §7. Bảng tra: cột nào sinh ước lượng sai

| Đặc điểm cột | Rủi ro | Dấu hiệu |
|---|---|---|
| Rất nhiều giá trị phân biệt | `n_distinct` bị đánh giá thấp | estimate lớn hơn actual nhiều lần |
| Lệch nặng nhưng giá trị lệch không lọt MCV | selectivity sai cả hai chiều | estimate lệch tuỳ giá trị |
| Giá trị mới hơn mọi histogram bound | estimate ≈ 0 → nested loop sai | bảng time-series vừa nạp dữ liệu mới |
| Correlation gần 0 | index scan đắt hơn planner nghĩ | buffers cao bất ngờ |
| Cột tính từ biểu thức | không có statistics, dùng mặc định 0.5% | Day 09 §6 |
| Hai cột phụ thuộc nhau | giả định độc lập sai | **Day 13** |

### Làm ngay — bẫy dữ liệu mới

```sql
INSERT INTO ts_kv SELECT device_id, key_id, ts + interval '200 days', dbl_v, bool_v, str_v
FROM ts_kv LIMIT 50000;
-- CHƯA analyze
EXPLAIN SELECT count(*) FROM ts_kv WHERE ts > '2026-01-01';
SELECT count(*) FROM ts_kv WHERE ts > '2026-01-01';
ANALYZE ts_kv;
EXPLAIN SELECT count(*) FROM ts_kv WHERE ts > '2026-01-01';
```

**Ghi vào writeup:** trước ANALYZE planner ước lượng bao nhiêu dòng cho khoảng thời gian nằm **ngoài** histogram? Vì sao con số đó cực nguy hiểm khi query này nằm trong một join?

```sql
-- dọn lại để các ngày sau dùng dataset gốc
DELETE FROM ts_kv WHERE ts > '2026-01-01';
VACUUM ANALYZE ts_kv;
```

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B. Áp dụng vào hệ thật:** chạy query ở §1 trên DB của bạn. Chỉ ra 2 cột có `n_distinct` đáng nghi và 1 cột có `correlation` cao. Bạn sẽ nâng `STATISTICS` cho cột nào?

### Đạt khi

Bạn tự tính được ước lượng của planner từ `pg_stats` bằng tay cho cả trường hợp trong MCV lẫn ngoài MCV, và giải thích được sai số bạn thấy.

**Xong thì gõ `/review-bai`.**
