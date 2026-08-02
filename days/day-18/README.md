# Day 18 — Merge Join & Sort

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

```sql
\timing on
\o /days/day-18/output.txt
ANALYZE;
```

---

## §0. Đoán trước

1. Sort 5 triệu dòng với `work_mem = 4MB` — `Sort Method` là gì, ghi ra đĩa bao nhiêu MB?
2. Cần `work_mem` bao nhiêu để sort đó vừa RAM?
3. Tạo index đúng thứ tự so với tăng `work_mem` — cái nào thắng?

---

## §1. Ba `Sort Method`

### Lý thuyết

```
Sort Method: quicksort  Memory: 25kB
Sort Method: top-N heapsort  Memory: 28kB
Sort Method: external merge  Disk: 41008kB
```

| Method | Khi nào | Chi phí |
|---|---|---|
| **quicksort** | toàn bộ dữ liệu vừa `work_mem` | rẻ nhất, thuần CPU |
| **top-N heapsort** | có `LIMIT N` nhỏ — chỉ giữ N phần tử tốt nhất | rất rẻ, không cần chứa hết dữ liệu |
| **external merge** | không vừa RAM → ghi các run đã sắp ra đĩa rồi trộn | đắt: ghi + đọc lại toàn bộ |

**`top-N heapsort` là lý do `ORDER BY ... LIMIT 10` rẻ hơn `ORDER BY` không LIMIT rất nhiều** — kể cả trên bảng khổng lồ. Nó chỉ giữ một heap 10 phần tử.

External merge sort làm việc theo hai pha: chia dữ liệu thành các run vừa `work_mem`, sort từng run rồi ghi ra file tạm; sau đó trộn nhiều run lại. Nếu số run quá nhiều so với khả năng trộn một lượt thì phải trộn nhiều vòng — càng đắt.

### Làm ngay

```sql
SHOW work_mem;

EXPLAIN (ANALYZE, BUFFERS) SELECT device_id FROM ts_kv ORDER BY dbl_v;
EXPLAIN (ANALYZE, BUFFERS) SELECT device_id FROM ts_kv ORDER BY dbl_v LIMIT 10;
EXPLAIN (ANALYZE, BUFFERS) SELECT device_id FROM ts_kv ORDER BY dbl_v LIMIT 1000000;
EXPLAIN (ANALYZE, BUFFERS) SELECT id FROM device ORDER BY name;
```

**Ghi vào writeup — bảng 4 dòng:** query | Sort Method | Memory/Disk | temp read/written | time. Với `LIMIT 10` và `LIMIT 1000000`, method có khác nhau không — vì sao?

---

## §2. Quét `work_mem` để tìm điểm lật

### Làm ngay

```sql
SET work_mem = '4MB';   EXPLAIN (ANALYZE, BUFFERS) SELECT device_id FROM ts_kv ORDER BY dbl_v;
SET work_mem = '32MB';  EXPLAIN (ANALYZE, BUFFERS) SELECT device_id FROM ts_kv ORDER BY dbl_v;
SET work_mem = '128MB'; EXPLAIN (ANALYZE, BUFFERS) SELECT device_id FROM ts_kv ORDER BY dbl_v;
SET work_mem = '512MB'; EXPLAIN (ANALYZE, BUFFERS) SELECT device_id FROM ts_kv ORDER BY dbl_v;
RESET work_mem;
```

**Ghi vào writeup:** ở mức nào chuyển từ `external merge` sang `quicksort`? Con số đó có khớp với ước lượng của bạn từ `rows × width` không? Thời gian giảm mấy lần?

---

## §3. Index xoá hẳn node Sort

### Lý thuyết

Index B-tree lưu dữ liệu **đã sắp**. Nếu `ORDER BY` khớp thứ tự index, planner đọc thẳng theo index — **không có node `Sort` nào cả**, và tốn 0 byte `work_mem`.

Đây là giải pháp tốt hơn hẳn việc tăng `work_mem`:
- Không tốn RAM
- Kết hợp `LIMIT` thì dừng ngay sau N dòng — không cần đọc hết bảng
- Ổn định khi dữ liệu lớn lên

Đổi lại: tốn chỗ và làm chậm ghi (Day 10).

### Làm ngay

```sql
-- ba phương án cho cùng một nhu cầu
-- (1) sort trên đĩa
SET work_mem = '4MB';
EXPLAIN (ANALYZE, BUFFERS) SELECT device_id, ts FROM ts_kv ORDER BY dbl_v LIMIT 100;

-- (2) sort trong RAM
SET work_mem = '512MB';
EXPLAIN (ANALYZE, BUFFERS) SELECT device_id, ts FROM ts_kv ORDER BY dbl_v LIMIT 100;
RESET work_mem;

-- (3) index
CREATE INDEX idx_tskv_dbl ON ts_kv(dbl_v);
ANALYZE ts_kv;
EXPLAIN (ANALYZE, BUFFERS) SELECT device_id, ts FROM ts_kv ORDER BY dbl_v LIMIT 100;
```

**Ghi vào writeup — bảng 3 dòng:** phương án | time | buffers | temp | RAM dùng. **Khi nào bạn chọn index thay vì tăng `work_mem`?**

---

## §4. Merge Join hoạt động thế nào

### Lý thuyết

```
sắp cả hai bên theo join key
rồi đi song song hai con trỏ:
    nếu key trái < key phải  -> tiến con trỏ trái
    nếu key trái > key phải  -> tiến con trỏ phải
    nếu bằng nhau            -> ghép (và xử lý nhóm trùng)
```

Chi phí = chi phí sắp xếp + một lượt quét song song `O(N+M)`.

**Merge join thắng khi cả hai bên đã có sẵn thứ tự** — ví dụ cả hai đều được đọc qua index trên join key. Lúc đó không cần sort gì cả và nó là plan rẻ nhất.

Merge join cũng là plan **duy nhất** xử lý tốt join trên bảng cực lớn mà hash table không thể vừa RAM — vì nó không cần giữ gì trong RAM ngoài cửa sổ hiện tại.

Một điểm khác biệt so với hash join: merge join dùng được với `<`, `>` trong một số trường hợp (range join), còn hash join thì không.

### Làm ngay

```sql
SET enable_hashjoin = off; SET enable_nestloop = off;
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ts_kv k JOIN device d ON d.id = k.device_id;
RESET ALL;
```

Xem cấu trúc: có mấy node `Sort` dưới node `Merge Join`?

**Ghi vào writeup:** merge join phải sắp mấy bên? Tổng thời gian sort chiếm bao nhiêu % tổng thời gian query?

---

## §5. Merge join khi đã có sẵn thứ tự

### Làm ngay

```sql
-- cả hai bên đọc qua index -> không cần sort
CREATE INDEX IF NOT EXISTS idx_tskv_dev ON ts_kv(device_id);

SET enable_hashjoin = off; SET enable_nestloop = off; SET enable_seqscan = off;
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ts_kv k JOIN device d ON d.id = k.device_id;
RESET ALL;
```

So với plan planner tự chọn:
```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ts_kv k JOIN device d ON d.id = k.device_id;
```

**Ghi vào writeup:** khi đọc qua index, node `Sort` còn không? Merge join lúc này so với hash join thì thế nào? Planner chọn đúng chưa?

---

## §6. `Incremental Sort` (PG13+)

### Lý thuyết

Nếu dữ liệu **đã sắp theo tiền tố** của `ORDER BY`, Postgres chỉ cần sắp phần còn lại **trong từng nhóm nhỏ** thay vì sắp toàn bộ.

Ví dụ: có index `(device_id)`, cần `ORDER BY device_id, ts`. Dữ liệu đã đúng thứ tự `device_id`; chỉ cần sắp `ts` bên trong mỗi nhóm `device_id`.

```
Incremental Sort
  Sort Key: device_id, ts
  Presorted Key: device_id
  Full-sort Groups: 1240  Sort Method: quicksort  Average Memory: 26kB
```

Lợi ích lớn: mỗi nhóm nhỏ vừa RAM → **không bao giờ spill**, và kết hợp `LIMIT` thì dừng rất sớm.

### Làm ngay

```sql
SET enable_incremental_sort = on;
EXPLAIN (ANALYZE, BUFFERS)
SELECT device_id, ts FROM ts_kv ORDER BY device_id, ts LIMIT 1000;

SET enable_incremental_sort = off;
EXPLAIN (ANALYZE, BUFFERS)
SELECT device_id, ts FROM ts_kv ORDER BY device_id, ts LIMIT 1000;
RESET enable_incremental_sort;
```

**Ghi vào writeup:** có node `Incremental Sort` không? `Full-sort Groups` bao nhiêu, `Average Memory` bao nhiêu? Chênh lệch thời gian giữa bật/tắt là bao nhiêu lần?

---

## §7. Sort ở những chỗ bạn không ngờ

### Lý thuyết

Sort không chỉ đến từ `ORDER BY`. Nó còn ẩn trong:

| Cấu trúc | Vì sao cần sort |
|---|---|
| `GROUP BY` | nếu chọn GroupAggregate thay vì HashAggregate (Day 19) |
| `DISTINCT` | tương tự |
| `UNION` (không `ALL`) | phải khử trùng lặp |
| Merge Join | sắp cả hai bên |
| Window function `OVER (PARTITION BY ... ORDER BY ...)` | sắp theo partition + order |
| `CREATE INDEX` | build cây |

Window function là chỗ hay bị bỏ sót nhất — một query có 3 window function với 3 `PARTITION BY` khác nhau sẽ có 3 node Sort.

### Làm ngay

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT DISTINCT device_id FROM ts_kv;
EXPLAIN (ANALYZE, BUFFERS) SELECT device_id FROM ts_kv UNION SELECT id FROM device;
EXPLAIN (ANALYZE, BUFFERS) SELECT device_id FROM ts_kv UNION ALL SELECT id FROM device;

EXPLAIN (ANALYZE, BUFFERS)
SELECT device_id, ts, dbl_v,
       row_number() OVER (PARTITION BY device_id ORDER BY ts DESC) AS rn,
       avg(dbl_v)   OVER (PARTITION BY key_id ORDER BY ts)         AS ma
FROM ts_kv WHERE ts >= '2025-06-01' AND ts < '2025-06-02';
```

**Ghi vào writeup:** đếm số node `Sort` trong query cuối. `UNION` và `UNION ALL` khác nhau thế nào về plan và thời gian?

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B. Áp dụng vào hệ thật:** tìm trong service của bạn một query có `ORDER BY` trên bảng lớn. Nó đang sort trên đĩa hay trong RAM? Nếu tạo index đúng thứ tự thì tiết kiệm được gì, và trả giá gì?

### Đạt khi

Bạn nhìn `Sort Method: external merge Disk: xxx` là biết ngay ba lựa chọn (index / tăng work_mem / viết lại query) và chọn được đúng cái phù hợp.

**Xong thì gõ `/review-bai`.**
