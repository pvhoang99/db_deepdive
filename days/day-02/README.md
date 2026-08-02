# Day 02 — Giải phẫu một node trong EXPLAIN ANALYZE

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

```sql
\timing on
\o /days/day-02/output.txt
```

---

## §0. Đoán trước

Với query này, viết dự đoán vào `writeup.md`:

```sql
SELECT d.name, count(*)
FROM ts_kv t JOIN device d ON d.id = t.device_id
WHERE t.ts >= '2025-06-01' AND t.ts < '2025-06-02'
GROUP BY d.name ORDER BY 2 DESC LIMIT 10;
```

1. Postgres chọn kiểu join nào?
2. Node nào tốn nhiều thời gian nhất?

---

## §1. Toàn bộ một dòng plan

### Lý thuyết

```
->  Index Scan using idx_dev on ts_kv t  (cost=0.43..8.45 rows=1 width=24)
                                          (actual time=0.012..0.019 rows=3 loops=1247)
      Index Cond: (t.device_id = d.id)
      Filter: (t.dbl_v > 25.0)
      Rows Removed by Filter: 11
      Buffers: shared hit=4988
```

| Phần | Nghĩa |
|---|---|
| `Index Scan using idx_dev` | **loại node** + index nó dùng |
| `cost=0.43..8.45` | startup..total, **ước lượng**, cho **một** lần chạy node |
| `rows=1` | **ước lượng** số dòng trả ra, cho **một** lần chạy |
| `width=24` | byte trung bình mỗi dòng |
| `actual time=0.012..0.019` | ms thật tới dòng đầu .. tới dòng cuối, **trung bình mỗi loop** |
| `rows=3` (trong actual) | số dòng thật, **trung bình mỗi loop** |
| `loops=1247` | node này chạy lại **1247 lần** |
| `Index Cond` | điều kiện đẩy **vào trong** index — chỉ đọc phần cần |
| `Filter` | điều kiện áp **sau khi** đã đọc dòng lên — đọc rồi mới vứt |
| `Rows Removed by Filter` | số dòng đọc lên rồi vứt. Cao = lãng phí |

### Làm ngay

```sql
EXPLAIN (ANALYZE, BUFFERS, VERBOSE) SELECT count(*) FROM ts_kv WHERE device_id = 42;
```

**Ghi vào writeup:** chỉ ra từng thành phần trên node scan: cost start/total, rows đoán, rows thật, width, loops.

---

## §2. Bẫy `loops` — chỗ 90% người đọc plan sai

### Lý thuyết

> `actual time` và `actual rows` là **trung bình cho MỘT loop**, không phải tổng.

Node ở §1:
- Thời gian thật = `0.019 ms × 1247` ≈ **23.7 ms** (không phải 0.019 ms)
- Số dòng thật = `3 × 1247` = **3741** (không phải 3)

Hệ quả: một node trông vô hại với `actual time=0.019` có thể là thủ phạm chính, chỉ vì nó chạy 1.2 triệu lần. **Luôn nhân với loops trước khi kết luận.**

`loops > 1` xảy ra ở node bên **inner** của Nested Loop, trong `SubPlan`, hoặc trong parallel worker.

### Làm ngay

Ép nested loop để tạo `loops` lớn:

```sql
SET enable_hashjoin = off;
SET enable_mergejoin = off;

EXPLAIN (ANALYZE, BUFFERS)
SELECT d.name, t.ts, t.dbl_v
FROM device d JOIN ts_kv t ON t.device_id = d.id
WHERE d.type = 'controller' AND t.ts >= '2025-07-01';

RESET enable_hashjoin; RESET enable_mergejoin;
```

Với node inner: ghi `actual time`, `loops`, rồi **tính tay** tổng thời gian thật. So với `Execution Time` ở cuối plan.

**Ghi vào writeup:** `loops` bằng bao nhiêu, thời gian thật của node inner là bao nhiêu? Nếu **không** nhân loops thì bạn sẽ kết luận sai thế nào?

---

## §3. Thời gian là tích luỹ, không phải riêng lẻ

### Lý thuyết

`actual time` của một node **đã bao gồm** thời gian của mọi node con.

```
Aggregate            actual time=..97.4     <- tổng cả cây
  -> Seq Scan        actual time=..93.9     <- node này + con của nó
```

Thời gian **riêng** của Aggregate = 97.4 − 93.9 = **3.5 ms**.

Khi tìm nút thắt, đừng tìm node có `actual time` lớn nhất (node gốc luôn lớn nhất). Tìm node có **chênh lệch lớn nhất so với tổng thời gian các con**.

Với node có `loops > 1`, phải quy về cùng đơn vị (nhân loops) trước khi trừ.

### Làm ngay

```sql
EXPLAIN (ANALYZE) SELECT count(*) FROM ts_kv;
EXPLAIN (ANALYZE) SELECT sum(dbl_v) FROM ts_kv WHERE key_id = 1;
```

**Ghi vào writeup:** thời gian riêng của node Aggregate trong mỗi trường hợp. Vì sao cái thứ hai tốn nhiều CPU hơn?

---

## §4. `Index Cond` vs `Filter` — khác biệt sống còn

### Lý thuyết

Đây là thứ phân biệt "index chạy tốt" với "index có mà vô dụng":

```
Index Scan using idx_device on ts_kv
  Index Cond: (device_id = 42)          <- index nhảy thẳng tới, đọc 108k dòng
  Filter: (dbl_v > 25.0)                <- đọc 108k dòng lên RAM rồi vứt bớt
  Rows Removed by Filter: 61000         <- 61k dòng đọc phí
```

`Index Cond` = index thu hẹp phạm vi đọc. `Filter` = đã đọc lên rồi mới lọc — công vô ích, đo bằng `Rows Removed by Filter`.

**Thấy `Rows Removed by Filter` lớn = có cơ hội tối ưu index.**

### Làm ngay

```sql
CREATE INDEX idx_tskv_dev ON ts_kv(device_id);
ANALYZE ts_kv;

EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM ts_kv WHERE device_id = 7;
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM ts_kv WHERE device_id = 7 AND dbl_v > 25;
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM ts_kv WHERE device_id = 7 AND key_id = 1;
```

Đoán trước: nếu thêm `CREATE INDEX ON ts_kv(device_id, key_id)` thì query thứ 3 đổi thế nào? Tạo rồi kiểm chứng:

```sql
CREATE INDEX idx_tskv_dev_key ON ts_kv(device_id, key_id);
ANALYZE ts_kv;
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM ts_kv WHERE device_id = 7 AND key_id = 1;
```

**Ghi vào writeup:** bảng 4 dòng — query | Index Cond | Filter | Rows Removed by Filter | buffers. Với query thứ 3, `Rows Removed by Filter` từ bao nhiêu xuống bao nhiêu, buffers giảm mấy lần?

---

## §5. Các node hay gặp

### Lý thuyết

| Node | Làm gì | Cảnh báo |
|---|---|---|
| `Seq Scan` | quét tuần tự cả bảng | không phải lúc nào cũng xấu |
| `Index Scan` | qua index rồi lấy dòng từ heap | random I/O, xấu khi nhiều dòng |
| `Bitmap Heap Scan` | gom TID rồi đọc heap theo thứ tự page | ở giữa hai cái trên |
| `Nested Loop` | mỗi dòng outer quét inner một lần | `loops` = số dòng outer |
| `Hash Join` | build hash từ bảng nhỏ, probe bằng bảng lớn | `Batches > 1` = tràn đĩa |
| `Sort` | sắp xếp | xem `Sort Method` |
| `Gather` | gom kết quả parallel worker | thêm chi phí giao tiếp |
| `Materialize` | đệm kết quả con để quét lại | thường dưới Nested Loop |
| `Memoize` (PG14+) | cache kết quả inner theo key | xem `Hits/Misses` |

Hai chỗ dễ nhầm nữa:
- **`rows` bị cắt bởi `LIMIT`** — node dưới có thể dừng sớm, `actual rows` nhỏ hơn số nó *đáng lẽ* trả ra. Đừng vội kết luận planner sai.
- **`never executed`** — plan có nhánh đó nhưng runtime không chạy tới. Không phải lỗi.

### Làm ngay

```sql
-- ép ra nhiều loại node khác nhau để nhận mặt
EXPLAIN (ANALYZE) SELECT * FROM ts_kv WHERE device_id < 100;                  -- bitmap?
EXPLAIN (ANALYZE) SELECT * FROM device ORDER BY name LIMIT 5;                 -- sort + limit
EXPLAIN (ANALYZE) SELECT * FROM device d JOIN tenant t ON t.id=d.tenant_id;   -- hash join
EXPLAIN (ANALYZE) SELECT * FROM ts_kv ORDER BY device_id, ts LIMIT 20;        -- có Sort không?
```

**Ghi vào writeup:** liệt kê các loại node bạn gặp và một câu mô tả mỗi cái đang làm gì trong query đó.

---

## §6. Bài tổng hợp — mổ xẻ toàn bộ cây

### Làm ngay

```sql
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT d.name, count(*)
FROM ts_kv t JOIN device d ON d.id = t.device_id
WHERE t.ts >= '2025-06-01' AND t.ts < '2025-06-02'
GROUP BY d.name ORDER BY 2 DESC LIMIT 10;
```

**Ghi vào writeup — bảng mỗi node một dòng:**

| Node | rows (đoán) | actual rows | loops | rows thật (×loops) | actual time | thời gian riêng |
|---|---|---|---|---|---|---|

Rồi trả lời: node nào tốn nhiều **thời gian riêng** nhất? Có trùng với dự đoán ở §0 không? Bạn chứng minh bằng phép tính nào?

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B. Áp dụng vào hệ thật:** trong service của bạn, có query nào bạn nghi đang có nested loop với `loops` rất lớn không? Dấu hiệu nhận ra là gì?

### Đạt khi

Nhìn một plan lạ, bạn chỉ đúng được node tốn thời gian thật (đã nhân loops, đã trừ thời gian con) mà không cần nhìn dòng `Execution Time`.

**Xong thì gõ `/review-bai`.**
