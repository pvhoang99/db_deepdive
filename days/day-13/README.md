# Day 13 — Cột tương quan & `CREATE STATISTICS`

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

```sql
\timing on
\o /days/day-13/output.txt
ANALYZE device;
```

---

## §0. Đoán trước

Bảng `device` có 50.000 dòng. `region='ap-southeast'` chiếm ~43%, `country='VN'` chiếm ~43% — và **mọi dòng `ap-southeast` đều là `VN`**.

1. Planner ước lượng `WHERE region='ap-southeast' AND country='VN'` ra bao nhiêu dòng?
2. Thực tế bao nhiêu?
3. Sai bao nhiêu lần?

Viết dự đoán rồi mới chạy.

---

## §1. Giả định độc lập — chỗ planner sai một cách hệ thống

### Lý thuyết

Với `WHERE a = x AND b = y`, planner tính:

```
selectivity(a AND b) = selectivity(a) × selectivity(b)
```

Đây là công thức xác suất cho hai biến **độc lập**. Planner giả định mọi cột đều độc lập, vì nó chỉ có thống kê **từng cột riêng lẻ**.

Nhưng dữ liệu thật hiếm khi độc lập:

| Cặp cột | Quan hệ thật |
|---|---|
| `region` / `country` | phụ thuộc hàm hoàn toàn |
| `city` / `district` | phụ thuộc hàm |
| `model` / `manufacturer` | phụ thuộc hàm |
| `status` / `end_ts IS NULL` | tương quan chặt |
| `created_at` / `id` (serial) | tương quan gần tuyến tính |
| `postal_code` / `province` | phụ thuộc hàm |

Với phụ thuộc hàm hoàn toàn, sai số bằng đúng nghịch đảo selectivity của cột thứ hai. Nếu `country='VN'` chiếm 43%, planner **đánh giá thấp 2.3 lần**. Với cặp cột hiếm hơn (ví dụ `city='Đà Lạt' AND province='Lâm Đồng'`), sai số dễ lên tới **trăm lần**.

Và như Day 12 đã chỉ ra: đây là **underestimate** — kiểu hỏng nguy hiểm, dẫn tới nested loop sai.

### Làm ngay

```sql
-- selectivity từng cột
SELECT count(*) FILTER (WHERE region='ap-southeast')::float/count(*) AS sel_region,
       count(*) FILTER (WHERE country='VN')::float/count(*)          AS sel_country,
       count(*) FILTER (WHERE region='ap-southeast' AND country='VN')::float/count(*) AS sel_that
FROM device;

EXPLAIN SELECT * FROM device WHERE region='ap-southeast' AND country='VN';
SELECT count(*) FROM device WHERE region='ap-southeast' AND country='VN';
```

**Ghi vào writeup:** tự nhân `sel_region × sel_country × 50000` — có khớp với `rows=` planner in không? So với số thật, sai mấy lần?

---

## §2. Extended statistics — ba loại

### Lý thuyết

```sql
CREATE STATISTICS ten_stats (kind1, kind2) ON col_a, col_b FROM table;
ANALYZE table;
```

Ba loại (`kind`):

| Loại | Giải quyết | Dùng khi |
|---|---|---|
| **`dependencies`** | phụ thuộc hàm giữa các cột | `WHERE a=? AND b=?` với a→b |
| **`ndistinct`** | số tổ hợp phân biệt của nhóm cột | `GROUP BY a, b` ước lượng sai số nhóm |
| **`mcv`** | danh sách tổ hợp giá trị phổ biến **nhiều cột** | dữ liệu lệch, cần chính xác cho từng tổ hợp cụ thể |

Khác biệt quan trọng giữa `dependencies` và `mcv`:
- `dependencies` lưu một **hệ số** (0..1) cho biết "biết a thì đoán được b tới mức nào". Rất nhỏ gọn, sửa được sai số một cách tổng quát.
- `mcv` lưu **danh sách tổ hợp thật** kèm tần suất. Chính xác hơn nhiều cho các tổ hợp phổ biến, nhưng chỉ giúp cho tổ hợp nằm trong danh sách.

Thực tế nên khai cả `(dependencies, mcv)` cho các cặp cột quan trọng.

Từ PG14, còn dùng được cho **biểu thức**:
```sql
CREATE STATISTICS s ON (lower(name)), tenant_id FROM device;
```

### Làm ngay

```sql
CREATE STATISTICS st_dev_geo (dependencies, ndistinct, mcv)
  ON region, country FROM device;
ANALYZE device;

EXPLAIN SELECT * FROM device WHERE region='ap-southeast' AND country='VN';
SELECT count(*) FROM device WHERE region='ap-southeast' AND country='VN';
```

**Ghi vào writeup:** ước lượng trước/sau. Sai số từ bao nhiêu lần xuống bao nhiêu lần?

---

## §3. Nhìn vào bên trong extended statistics

### Làm ngay

```sql
SELECT stxname, stxkeys, stxkind FROM pg_statistic_ext WHERE stxname='st_dev_geo';

SELECT stxddependencies, stxdndistinct
FROM pg_statistic_ext_data d JOIN pg_statistic_ext e ON e.oid = d.stxoid
WHERE e.stxname = 'st_dev_geo';

-- xem MCV nhiều cột
SELECT * FROM pg_mcv_list_items(
  (SELECT stxdmcv FROM pg_statistic_ext_data d JOIN pg_statistic_ext e ON e.oid=d.stxoid
   WHERE e.stxname='st_dev_geo')
) LIMIT 10;
```

`stxddependencies` trả về dạng `{"1 => 2": 1.000000, "2 => 1": 1.000000}` — số 1.0 nghĩa là phụ thuộc hoàn toàn.

**Ghi vào writeup:** hệ số phụ thuộc giữa `region` và `country` bằng bao nhiêu, theo cả hai chiều? Danh sách MCV nhiều cột có bao nhiêu tổ hợp, tổ hợp phổ biến nhất là gì?

---

## §4. `ndistinct` cho nhóm cột — sửa `GROUP BY`

### Lý thuyết

Với `GROUP BY a, b`, planner cần biết số **tổ hợp phân biệt**. Nó lại giả định độc lập: `ndistinct(a) × ndistinct(b)`.

Với `region` (4 giá trị) × `country` (4 giá trị) → đoán 16 nhóm. Thật ra chỉ có **4**.

Ước lượng số nhóm sai làm hỏng:
- Chọn HashAggregate với hash table quá lớn/nhỏ → spill (Day 19)
- Ước lượng sai số dòng ra khỏi node aggregate → sai lan lên trên

### Làm ngay

```sql
DROP STATISTICS st_dev_geo;
ANALYZE device;
EXPLAIN SELECT region, country, count(*) FROM device GROUP BY region, country;
SELECT count(*) FROM (SELECT DISTINCT region, country FROM device) s;

CREATE STATISTICS st_dev_geo (ndistinct) ON region, country FROM device;
ANALYZE device;
EXPLAIN SELECT region, country, count(*) FROM device GROUP BY region, country;
```

**Ghi vào writeup:** số nhóm planner ước lượng trước/sau, và số thật.

---

## §5. Tìm cặp cột đáng tạo statistics

### Lý thuyết

Cách phát hiện: so `n_distinct` của nhóm cột thật với tích các `n_distinct` riêng lẻ. Chênh lệch càng lớn thì phụ thuộc càng chặt.

### Làm ngay

```sql
-- so số tổ hợp thật với tích ndistinct riêng lẻ, cho vài cặp cột của device
WITH pairs AS (
  SELECT 'type,region'   AS cols, count(*) AS combo FROM (SELECT DISTINCT type, region FROM device) s
  UNION ALL SELECT 'region,country', count(*) FROM (SELECT DISTINCT region, country FROM device) s
  UNION ALL SELECT 'tenant_id,region', count(*) FROM (SELECT DISTINCT tenant_id, region FROM device) s
  UNION ALL SELECT 'firmware,type', count(*) FROM (SELECT DISTINCT firmware, type FROM device) s
)
SELECT * FROM pairs;

SELECT attname, n_distinct FROM pg_stats WHERE tablename='device'
  AND attname IN ('type','region','country','tenant_id','firmware');
```

**Ghi vào writeup:** với mỗi cặp, tính `tích ndistinct riêng lẻ ÷ số tổ hợp thật`. Cặp nào tỷ lệ cao nhất — đó là cặp đáng tạo statistics nhất.

---

## §6. Giới hạn của extended statistics

### Lý thuyết

Phải biết trước khi ỷ lại:

- **Chỉ trong một bảng.** Không giúp cho tương quan giữa hai bảng đã join.
- **Phải khai báo thủ công.** Postgres không tự phát hiện. Đây là công việc của bạn.
- **Tối đa 8 cột** mỗi statistics object.
- `mcv` chỉ giúp cho tổ hợp **nằm trong danh sách**; tổ hợp hiếm vẫn quay về giả định độc lập.
- Chỉ áp dụng cho điều kiện dạng `=` với hằng số và một số dạng bất đẳng thức — **không** áp dụng cho tham số `$1` trong generic plan (nhắc lại Day 12 §4).
- Làm `ANALYZE` chậm hơn.

Nên chiến lược đúng: **tạo cho vài cặp cột quan trọng nhất, không tạo hàng loạt.**

### Làm ngay

Kiểm chứng giới hạn "không giúp qua join":
```sql
EXPLAIN (ANALYZE)
SELECT count(*) FROM ts_kv k JOIN device d ON d.id = k.device_id
WHERE d.region='ap-southeast' AND d.country='VN' AND k.key_id = 1;
```
So `rows` với `actual rows` ở node join. Extended statistics có sửa được node này không?

**Ghi vào writeup:** statistics giúp được node nào, không giúp được node nào?

---

## §7. Áp dụng đầy đủ

### Làm ngay

```sql
DROP STATISTICS IF EXISTS st_dev_geo;
CREATE STATISTICS st_dev_geo (dependencies, ndistinct, mcv) ON region, country FROM device;
CREATE STATISTICS st_dev_tt  (dependencies, ndistinct) ON tenant_id, type FROM device;
ANALYZE device;

-- đo lại toàn bộ các query bị ảnh hưởng
EXPLAIN (ANALYZE) SELECT count(*) FROM device WHERE region='ap-southeast' AND country='VN';
EXPLAIN (ANALYZE) SELECT count(*) FROM device WHERE region='us-east' AND country='US' AND type='sensor';
EXPLAIN (ANALYZE) SELECT region, country, count(*) FROM device GROUP BY 1,2;
```

**Ghi vào writeup — bảng:** query | rows đoán trước | rows đoán sau | rows thật | sai số trước/sau.

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B. Áp dụng vào hệ thật:** chỉ ra **2 cặp cột** trong schema công việc thật của bạn có phụ thuộc hàm hoặc tương quan chặt. Với mỗi cặp, viết câu `CREATE STATISTICS` và ước lượng planner đang sai mấy lần. Gợi ý mẫu hay gặp: `city/district`, `status/type`, `tenant_id/region`, `device_type/protocol`.

### Đạt khi

Bạn phát hiện được cặp cột phụ thuộc chỉ bằng cách so `n_distinct`, viết đúng `CREATE STATISTICS`, và chứng minh sai số giảm bằng số.

**Xong thì gõ `/review-bai`.**
