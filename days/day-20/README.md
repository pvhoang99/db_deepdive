# Day 20 — Join order, CTE, semi/anti join + ôn tuần 4

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

```sql
\timing on
\o /days/day-20/output.txt
ANALYZE;
```

---

## §0. Đoán trước

Nhu cầu: **"device chưa từng gửi telemetry trong 7 ngày qua"**. Có 4 cách viết (`NOT EXISTS`, `NOT IN`, `LEFT JOIN ... IS NULL`, `EXCEPT`).

1. Cách nào nhanh nhất?
2. Có cách nào cho **kết quả sai** không?

---

## §1. Planner sắp thứ tự join thế nào

### Lý thuyết

Với N bảng, số thứ tự join khả dĩ tăng theo giai thừa. Postgres dùng quy hoạch động để tìm thứ tự rẻ nhất — nhưng chỉ tới một ngưỡng:

| GUC | Mặc định | Nghĩa |
|---|---|---|
| `join_collapse_limit` | 8 | tối đa bao nhiêu bảng được gộp vào một bài toán tối ưu |
| `from_collapse_limit` | 8 | tương tự cho subquery trong FROM |
| `geqo_threshold` | 12 | quá số bảng này thì chuyển sang **GEQO** (thuật toán di truyền) |

Ý nghĩa thực tế:
- **Dưới 8 bảng**: planner thử mọi thứ tự → thứ tự bạn viết trong SQL **không quan trọng**
- **Trên 8 bảng**: planner bắt đầu tôn trọng thứ tự bạn viết → thứ tự viết **có ảnh hưởng**
- **Trên 12 bảng**: GEQO — thuật toán ngẫu nhiên, **có thể ra plan khác nhau giữa các lần chạy**

GEQO là nguồn của hiện tượng khó chịu "cùng query, lúc nhanh lúc chậm". Nếu bạn có query join 15 bảng chạy bất ổn, thử `SET geqo = off` (chấp nhận planning time cao hơn nhiều).

`JOIN` tường minh với `INNER JOIN` vẫn được tự do sắp xếp lại. Nhưng `LEFT JOIN` thì **không** — thứ tự có ý nghĩa ngữ nghĩa, planner bị ràng buộc nhiều hơn.

### Làm ngay

```sql
SHOW join_collapse_limit;
SHOW geqo_threshold;

-- viết hai thứ tự khác nhau cho cùng một join 3 bảng
EXPLAIN SELECT count(*) FROM tenant t JOIN device d ON d.tenant_id=t.id JOIN ts_kv k ON k.device_id=d.id
WHERE t.plan='enterprise' AND k.ts >= '2025-07-01';

EXPLAIN SELECT count(*) FROM ts_kv k JOIN device d ON k.device_id=d.id JOIN tenant t ON d.tenant_id=t.id
WHERE t.plan='enterprise' AND k.ts >= '2025-07-01';
```

Rồi ép planner tôn trọng thứ tự viết:
```sql
SET join_collapse_limit = 1;
EXPLAIN SELECT count(*) FROM tenant t JOIN device d ON d.tenant_id=t.id JOIN ts_kv k ON k.device_id=d.id
WHERE t.plan='enterprise' AND k.ts >= '2025-07-01';
RESET join_collapse_limit;
```

**Ghi vào writeup:** hai cách viết cho plan giống hay khác nhau? Với `join_collapse_limit = 1` thì sao? Kết luận gì về việc "viết bảng nhỏ trước cho nhanh"?

---

## §2. Semi join và anti join

### Lý thuyết

| Viết | Ngữ nghĩa | Node trong plan |
|---|---|---|
| `EXISTS (...)` | có ít nhất một dòng khớp | **Semi Join** |
| `NOT EXISTS (...)` | không có dòng nào khớp | **Anti Join** |
| `IN (subquery)` | thường tương đương EXISTS | Semi Join |
| `NOT IN (subquery)` | **KHÔNG** tương đương NOT EXISTS | thường không tối ưu được |

**Semi Join dừng ngay khi tìm được dòng đầu tiên** — rất rẻ. Đó là lý do `EXISTS` thường nhanh hơn `JOIN` khi bạn chỉ cần kiểm tra sự tồn tại (và `JOIN` còn nhân bản dòng nếu có nhiều dòng khớp).

### Cái bẫy `NOT IN` — phải nhớ đời

```sql
SELECT * FROM device WHERE id NOT IN (SELECT device_id FROM ts_kv);
```

Nếu subquery trả về **dù chỉ một NULL**, toàn bộ kết quả là **rỗng**. Vì `x NOT IN (1, 2, NULL)` được đánh giá là `x<>1 AND x<>2 AND x<>NULL` → `NULL` → không phải TRUE → loại bỏ.

Đây không phải bug của Postgres, mà là ngữ nghĩa ba giá trị của SQL chuẩn. Nhưng nó gây bug production rất âm thầm: query đúng cho tới ngày có một dòng NULL lọt vào.

Hệ quả thứ hai: vì planner phải giữ đúng ngữ nghĩa đó, **`NOT IN` không tối ưu được thành Anti Join** — thường phải quét toàn bộ subquery vào một hash rồi kiểm tra từng dòng.

> **Quy tắc: luôn dùng `NOT EXISTS`, không dùng `NOT IN` với subquery.**

### Làm ngay

```sql
-- bốn cách viết cùng một nhu cầu
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM device d
WHERE NOT EXISTS (SELECT 1 FROM ts_kv k WHERE k.device_id=d.id AND k.ts >= '2025-07-23');

EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM device d
WHERE d.id NOT IN (SELECT k.device_id FROM ts_kv k WHERE k.ts >= '2025-07-23');

EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM device d
LEFT JOIN ts_kv k ON k.device_id=d.id AND k.ts >= '2025-07-23'
WHERE k.device_id IS NULL;

EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM (
  SELECT id FROM device EXCEPT SELECT device_id FROM ts_kv WHERE ts >= '2025-07-23'
) s;
```

Rồi kiểm chứng cái bẫy NULL:
```sql
CREATE TABLE t_null AS SELECT device_id FROM ts_kv LIMIT 1000;
INSERT INTO t_null VALUES (NULL);

SELECT count(*) FROM device WHERE id NOT IN (SELECT device_id FROM t_null);
SELECT count(*) FROM device d WHERE NOT EXISTS (SELECT 1 FROM t_null n WHERE n.device_id = d.id);
DROP TABLE t_null;
```

**Ghi vào writeup — bảng 4 dòng:** cách viết | node join | time | buffers. Cách nào thắng? Và **hai câu lệnh kiểm chứng NULL trả về kết quả gì** — giải thích.

---

## §3. CTE: `MATERIALIZED` vs `NOT MATERIALIZED`

### Lý thuyết

Trước PG12, `WITH` **luôn** là rào chắn tối ưu hoá (optimization fence): CTE được tính xong hoàn toàn rồi mới dùng, điều kiện `WHERE` bên ngoài **không** được đẩy vào trong.

Từ PG12, mặc định là `NOT MATERIALIZED` cho CTE **chỉ dùng một lần và không có side effect** — nó được inline như subquery, điều kiện đẩy vào được.

Bạn điều khiển tường minh:
```sql
WITH x AS MATERIALIZED     (...)   -- ép tính riêng, giữ rào chắn
WITH x AS NOT MATERIALIZED (...)   -- ép inline
```

Khi nào cố tình dùng `MATERIALIZED`:
- CTE dùng **nhiều lần** và tính toán đắt → tính một lần rồi tái sử dụng
- Muốn chặn planner đẩy điều kiện vào (hiếm, thường là để tránh một plan xấu đã biết)
- CTE có `INSERT/UPDATE/DELETE ... RETURNING` (luôn materialized)

### Làm ngay

```sql
EXPLAIN (ANALYZE, BUFFERS)
WITH recent AS (
  SELECT device_id, dbl_v FROM ts_kv WHERE ts >= '2025-07-01'
)
SELECT count(*) FROM recent WHERE device_id = 42;

EXPLAIN (ANALYZE, BUFFERS)
WITH recent AS MATERIALIZED (
  SELECT device_id, dbl_v FROM ts_kv WHERE ts >= '2025-07-01'
)
SELECT count(*) FROM recent WHERE device_id = 42;
```

**Ghi vào writeup:** với `NOT MATERIALIZED` (mặc định), điều kiện `device_id = 42` có được đẩy vào trong CTE không — nhìn `Index Cond`/`Filter` ở node quét `ts_kv`. Chênh lệch buffers mấy lần?

Thử CTE dùng nhiều lần:
```sql
EXPLAIN (ANALYZE, BUFFERS)
WITH agg AS (SELECT device_id, count(*) c FROM ts_kv GROUP BY device_id)
SELECT (SELECT sum(c) FROM agg), (SELECT max(c) FROM agg), (SELECT avg(c) FROM agg);
```
**Ghi vào writeup:** CTE được tính mấy lần? (nhìn số node quét `ts_kv`).

---

## §4. `LATERAL` — join phụ thuộc dòng

### Lý thuyết

`LATERAL` cho phép subquery bên phải **tham chiếu cột của bên trái**:

```sql
SELECT d.name, last.ts, last.dbl_v
FROM device d
CROSS JOIN LATERAL (
  SELECT ts, dbl_v FROM ts_kv k WHERE k.device_id = d.id ORDER BY ts DESC LIMIT 1
) last;
```

Đây là cách viết chuẩn cho bài toán **"top-N mỗi nhóm"** — cực phổ biến trong IoT ("giá trị mới nhất của mỗi device").

Với index `(device_id, ts DESC)`, mỗi lần lặp chỉ đọc **một** entry index → rất rẻ. So với `row_number() OVER (PARTITION BY ...)` phải sắp toàn bộ bảng.

`LEFT JOIN LATERAL ... ON true` giữ lại device không có dữ liệu (giống LEFT JOIN).

### Làm ngay

```sql
CREATE INDEX IF NOT EXISTS idx_dev_ts_desc ON ts_kv(device_id, ts DESC);
ANALYZE ts_kv;

-- cách 1: LATERAL
EXPLAIN (ANALYZE, BUFFERS)
SELECT d.id, last.ts, last.dbl_v
FROM device d
CROSS JOIN LATERAL (SELECT ts, dbl_v FROM ts_kv k WHERE k.device_id=d.id ORDER BY ts DESC LIMIT 1) last
WHERE d.type = 'gateway';

-- cách 2: window function
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM (
  SELECT k.device_id, k.ts, k.dbl_v,
         row_number() OVER (PARTITION BY k.device_id ORDER BY k.ts DESC) rn
  FROM ts_kv k JOIN device d ON d.id=k.device_id WHERE d.type='gateway'
) s WHERE rn = 1;

-- cách 3: DISTINCT ON (đặc sản Postgres)
EXPLAIN (ANALYZE, BUFFERS)
SELECT DISTINCT ON (k.device_id) k.device_id, k.ts, k.dbl_v
FROM ts_kv k JOIN device d ON d.id=k.device_id WHERE d.type='gateway'
ORDER BY k.device_id, k.ts DESC;
```

**Ghi vào writeup — bảng 3 dòng:** cách viết | time | buffers | temp. Cách nào thắng và **hơn bao nhiêu lần**? Vì sao?

---

## §5. Subquery vô hướng và tương quan

### Lý thuyết

```sql
SELECT d.name, (SELECT count(*) FROM ts_kv k WHERE k.device_id = d.id) FROM device d;
```

Subquery tương quan trong SELECT list chạy **một lần cho mỗi dòng** outer — 50.000 lần. Postgres không phải lúc nào cũng viết lại được thành join.

Cách sửa: viết lại thành `LEFT JOIN` với subquery đã gom nhóm.

### Làm ngay

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT d.id, (SELECT count(*) FROM ts_kv k WHERE k.device_id=d.id) AS n
FROM device d WHERE d.type='controller';

EXPLAIN (ANALYZE, BUFFERS)
SELECT d.id, coalesce(a.n, 0) AS n
FROM device d
LEFT JOIN (SELECT device_id, count(*) n FROM ts_kv GROUP BY device_id) a ON a.device_id = d.id
WHERE d.type='controller';
```

**Ghi vào writeup:** hai cách chênh nhau bao nhiêu? Với `type='sensor'` (45.000 device) thì chênh lệch đổi thế nào — thử luôn.

---

## §6. Ôn tuần 4

**Viết vào `writeup.md`:**

**A. Bảng so sánh 3 thuật toán join** — mỗi cái: cơ chế, chi phí, điều kiện dùng được, dấu hiệu trong plan khi nó đang tệ.

**B. Checklist "gặp query chậm, tôi kiểm tra theo thứ tự nào"** — tối đa 8 bước, gộp cả những gì học từ tuần 1–4. Đây là bản nâng cấp của checklist tuần 1.

**C. Ba điều tôi tưởng đúng mà hoá ra sai trong tuần 4.**

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?** Đặc biệt: bạn có biết trước cái bẫy `NOT IN` với NULL không?

**B. Áp dụng vào hệ thật:** grep codebase của bạn tìm `NOT IN (SELECT`. Có bao nhiêu chỗ? Chỗ nào có nguy cơ NULL lọt vào? Và tìm chỗ nào đang dùng window function cho bài toán "top-1 mỗi nhóm" mà nên chuyển sang `LATERAL` hoặc `DISTINCT ON`.

### Đạt khi

Bạn viết được cùng một nhu cầu bằng 4 cách và chọn đúng cách nhanh nhất bằng số liệu, và không bao giờ viết `NOT IN` với subquery nữa.

**Xong thì gõ `/review-bai`.**

---

## Hết tuần 4

Xong phần **đọc và tối ưu query**. Tuần 5 chuyển sang tầng dưới nữa: MVCC, vacuum, bloat — nơi "hiểu sơ sơ" biến thành "sửa được sự cố lúc 2 giờ sáng".
