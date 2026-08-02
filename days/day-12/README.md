# Day 12 — Khi ước lượng sai thì plan nổ

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

```sql
\timing on
\o /days/day-12/output.txt
ANALYZE;
```

---

## §0. Đoán trước

1. Nếu planner ước lượng 10 dòng nhưng thực tế 100.000 dòng, plan hỏng theo cách nào?
2. Sai số ở node **lá** và ở node **gốc** — cái nào nguy hiểm hơn?
3. Prepared statement chạy 10 lần có dùng cùng một plan không?

---

## §1. Sai số lan truyền qua join

### Lý thuyết

Giả sử ba bảng join, mỗi node ước lượng lệch chỉ **2 lần**:

```
lá A: est 100     thật 200      (×2)
lá B: est 100     thật 200      (×2)
join A⋈B: est 100×100×sel = 1.000   thật 200×200×sel = 4.000   (×4)
join ⋈C: est 1.000×...  = 10.000    thật 4.000×...  = 64.000   (×6.4)
```

**Sai số nhân lên, không cộng lại.** Lệch 2 lần ở hai node lá thành lệch 6 lần ở gốc. Với 5 bảng thì lệch trăm lần.

Hệ quả trực tiếp:

> **Luôn tìm node lá đầu tiên (từ dưới lên) có `rows` lệch `actual rows` nhiều lần. Sửa chỗ đó. Đừng phí thời gian với node gốc.**

### Làm ngay

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT t.name, count(*)
FROM ts_kv k
JOIN device d ON d.id = k.device_id
JOIN tenant t ON t.id = d.tenant_id
WHERE d.region = 'eu-west' AND k.ts >= '2025-06-01' AND k.ts < '2025-06-03'
GROUP BY t.name;
```

**Ghi vào writeup — bảng mỗi node một dòng:** node | rows đoán | actual rows | tỷ lệ lệch. Node nào lệch đầu tiên? Tỷ lệ lệch tăng dần lên phía trên thế nào?

---

## §2. Hai kiểu hỏng khi ước lượng sai

### Lý thuyết

**Đánh giá thấp (underestimate)** — planner tưởng ít dòng:
- Chọn **Nested Loop** vì tưởng outer chỉ vài dòng → thực tế loop 500.000 lần → query treo
- Chọn **Index Scan** thay vì Seq Scan → random I/O trên nửa bảng
- Cấp `work_mem` nhỏ cho hash → spill ra đĩa

Đây là kiểu hỏng **nguy hiểm hơn nhiều**: từ 50ms thành 15 phút.

**Đánh giá cao (overestimate)** — planner tưởng nhiều dòng:
- Bỏ index, quét toàn bảng
- Chọn Hash Join với build side to
- Query chậm hơn *một cách tuyến tính*, thường vài lần chứ không phải nghìn lần

Nhớ tính bất đối xứng này: **underestimate giết server, overestimate chỉ làm chậm.**

### Làm ngay

Dựng một ca underestimate rồi xem plan nổ:

```sql
-- điều kiện mà planner ước lượng rất thấp
EXPLAIN (ANALYZE, BUFFERS)
SELECT d.name, k.ts, k.dbl_v
FROM device d JOIN ts_kv k ON k.device_id = d.id
WHERE d.region = 'ap-southeast' AND d.country = 'VN' AND d.type = 'sensor'
  AND k.ts >= '2025-07-01';
```
So `rows` và `actual rows` của node quét `device`. Rồi ép nested loop để thấy kịch bản xấu nhất:
```sql
SET enable_hashjoin=off; SET enable_mergejoin=off;
EXPLAIN (ANALYZE, BUFFERS)
SELECT d.name, k.ts FROM device d JOIN ts_kv k ON k.device_id = d.id
WHERE d.region='ap-southeast' AND d.country='VN' AND d.type='sensor' AND k.ts >= '2025-07-01';
RESET ALL;
```

**Ghi vào writeup:** node `device` lệch mấy lần? Với nested loop, `loops` bằng bao nhiêu và thời gian tăng mấy lần so với hash join?

---

## §3. Sửa bằng statistics target

### Làm ngay

Tìm một cột ước lượng tệ rồi nâng target:

```sql
EXPLAIN SELECT * FROM ts_kv WHERE device_id = 31337;
SELECT count(*) FROM ts_kv WHERE device_id = 31337;

ALTER TABLE ts_kv ALTER COLUMN device_id SET STATISTICS 2000;
ANALYZE ts_kv;

EXPLAIN SELECT * FROM ts_kv WHERE device_id = 31337;
```

Thử vài `device_id` khác nhau (một cái rất nhiều dòng, một cái rất ít):
```sql
EXPLAIN SELECT * FROM ts_kv WHERE device_id = 1;
EXPLAIN SELECT * FROM ts_kv WHERE device_id = 49999;
```

**Ghi vào writeup:** với 3 device_id, sai số trước/sau khi nâng target. Có device nào nâng target vẫn không cứu được không — vì sao?

```sql
ALTER TABLE ts_kv ALTER COLUMN device_id SET STATISTICS -1;   -- về mặc định
ANALYZE ts_kv;
```

---

## §4. Custom plan vs generic plan

### Lý thuyết

Khi bạn `PREPARE` một câu lệnh có tham số, Postgres có hai lựa chọn:

- **Custom plan** — lập kế hoạch lại mỗi lần, **biết giá trị tham số thật** → ước lượng chính xác, nhưng tốn planning time mỗi lần
- **Generic plan** — lập một lần, dùng mãi, **không biết tham số** → dùng selectivity trung bình

Chiến lược của Postgres: 5 lần đầu dùng custom plan, ghi lại chi phí trung bình. Từ lần 6, nếu generic plan **không đắt hơn** trung bình đó thì chuyển hẳn sang generic.

Đây là nguồn của một class bug rất khó chịu: **query chạy nhanh 5 lần đầu rồi đột nhiên chậm mãi mãi.** Xảy ra khi dữ liệu lệch — generic plan tối ưu cho giá trị "trung bình" nhưng bạn đang truy vấn giá trị lệch.

Điều khiển bằng:
```sql
SET plan_cache_mode = 'force_custom_plan';   -- luôn lập lại, chính xác
SET plan_cache_mode = 'force_generic_plan';  -- luôn dùng chung
SET plan_cache_mode = 'auto';                -- mặc định
```

### Làm ngay

```sql
PREPARE q(bigint) AS SELECT count(*) FROM ts_kv WHERE device_id = $1;

EXPLAIN (ANALYZE) EXECUTE q(1);       -- lần 1
EXPLAIN (ANALYZE) EXECUTE q(1);       -- 2
EXPLAIN (ANALYZE) EXECUTE q(1);       -- 3
EXPLAIN (ANALYZE) EXECUTE q(1);       -- 4
EXPLAIN (ANALYZE) EXECUTE q(1);       -- 5
EXPLAIN (ANALYZE) EXECUTE q(1);       -- 6  <- chú ý plan có đổi không
EXPLAIN (ANALYZE) EXECUTE q(49999);   -- 7  <- device rất ít dòng, plan có phù hợp không?
```

Ép hai chế độ rồi so:
```sql
SET plan_cache_mode = 'force_generic_plan';
EXPLAIN (ANALYZE) EXECUTE q(49999);
SET plan_cache_mode = 'force_custom_plan';
EXPLAIN (ANALYZE) EXECUTE q(49999);
RESET plan_cache_mode;
```

**Ghi vào writeup:** ở lần thứ mấy plan chuyển sang generic (dấu hiệu: `Index Cond: (device_id = $1)` thay vì hằng số)? Với `device_id = 49999`, generic plan chậm hơn custom plan bao nhiêu? **Đây là rủi ro gì với JDBC/pgx trong service của bạn?**

---

## §5. Khi nào planner "cố tình" chấp nhận ước lượng xấu

### Lý thuyết

Một số dạng query mà planner **không thể** ước lượng tốt, và bạn phải biết để tránh:

| Dạng | Vì sao mù | Cách né |
|---|---|---|
| `WHERE f(col) = ?` với hàm tự viết | không có statistics cho hàm | expression index, hoặc `ROWS` trong `CREATE FUNCTION` |
| Hàm trả bảng `SELECT * FROM f()` | mặc định đoán 1000 dòng | `CREATE FUNCTION ... ROWS 50` |
| `WHERE col = (SELECT ...)` | giá trị chưa biết lúc plan | tách thành 2 query |
| CTE `MATERIALIZED` | rào chắn tối ưu hoá | dùng `NOT MATERIALIZED` (Day 20) |
| `WHERE a = ? AND b = ?` phụ thuộc nhau | giả định độc lập | **`CREATE STATISTICS` — Day 13** |
| Tham số trong generic plan | không biết giá trị | `plan_cache_mode` |

### Làm ngay

```sql
CREATE FUNCTION dev_of_tenant(t int) RETURNS SETOF device
LANGUAGE sql STABLE AS $$ SELECT * FROM device WHERE tenant_id = t $$;

EXPLAIN SELECT * FROM dev_of_tenant(1);           -- ước lượng bao nhiêu?
SELECT count(*) FROM dev_of_tenant(1);            -- thật bao nhiêu?

CREATE OR REPLACE FUNCTION dev_of_tenant(t int) RETURNS SETOF device
LANGUAGE sql STABLE ROWS 10000 AS $$ SELECT * FROM device WHERE tenant_id = t $$;
EXPLAIN SELECT * FROM dev_of_tenant(1);
```

**Ghi vào writeup:** mặc định planner đoán bao nhiêu dòng cho hàm trả bảng? Sau khi khai `ROWS` thì sao? Trong hệ của bạn có hàm SQL/PLpgSQL nào đang bị đoán sai kiểu này không?

```sql
DROP FUNCTION dev_of_tenant(int);
```

---

## §6. Quy trình chẩn đoán — thứ mang về production

### Lý thuyết

Khi gặp query chậm bất thường, đi theo thứ tự này:

1. `EXPLAIN (ANALYZE, BUFFERS)` — lấy plan thật
2. Quét **từ lá lên gốc**, tìm node đầu tiên có `rows` lệch `actual rows` > 10 lần
3. Node đó quét bảng nào, lọc theo cột nào?
4. Xem `pg_stats` của cột đó: `n_distinct` có hợp lý không, giá trị đang lọc có trong MCV không, `last_analyze` bao lâu rồi
5. Thử theo thứ tự: `ANALYZE` → nâng `STATISTICS` → `CREATE STATISTICS` (Day 13) → viết lại query
6. Cuối cùng mới tính tới đổi index hay đổi GUC

### Làm ngay

Áp dụng quy trình trên cho query này, ghi lại từng bước:

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM ts_kv k JOIN device d ON d.id = k.device_id
WHERE d.type = 'controller' AND d.region = 'eu-west'
  AND k.key_id = 1 AND k.ts >= '2025-06-15';
```

**Ghi vào writeup:** đi hết 6 bước, ghi kết quả từng bước. Bạn dừng ở bước nào và sửa được bao nhiêu?

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B. Áp dụng vào hệ thật:** service của bạn dùng JDBC/pgx với prepared statement. Sau bài hôm nay, bạn kiểm tra gì để chắc chắn không dính bẫy generic plan? (gợi ý: JDBC có `prepareThreshold`, pgx có `QueryExecMode`.)

### Đạt khi

Cho một plan chậm, bạn chỉ đúng node gốc bệnh trong vòng 1 phút bằng cách quét sai số từ lá lên, và giải thích được vì sao underestimate nguy hiểm hơn overestimate.

**Xong thì gõ `/review-bai`.**
