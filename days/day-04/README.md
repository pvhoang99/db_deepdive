# Day 04 — Bốn kiểu truy cập bảng, và vì sao "có index mà không dùng"

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

```sql
\timing on
\o /days/day-04/output.txt
CREATE INDEX IF NOT EXISTS idx_tskv_dev ON ts_kv(device_id);
ANALYZE ts_kv;
```

Tìm 3 device có số dòng rất khác nhau:
```sql
SELECT device_id, count(*) FROM ts_kv GROUP BY 1 ORDER BY 2 DESC LIMIT 3;   -- mức CAO
SELECT device_id, count(*) FROM ts_kv GROUP BY 1 ORDER BY 2 ASC  LIMIT 3;   -- mức THẤP
SELECT device_id, count(*) FROM ts_kv GROUP BY 1 HAVING count(*) BETWEEN 2000 AND 5000 LIMIT 3;  -- GIỮA
```

---

## §0. Đoán trước

Với 3 device đó: planner chọn kiểu scan nào cho mỗi mức? Ở mức nào seq scan bắt đầu thắng index?

---

## §1. Bốn cách lấy dữ liệu từ một bảng

### Lý thuyết

**Seq Scan** — đọc tuần tự page 0 → page cuối, lọc từng dòng.
- Chi phí ≈ `relpages × seq_page_cost + reltuples × cpu_tuple_cost`
- Tuần tự → OS/đĩa readahead rất hiệu quả; song song hoá tốt
- Không phụ thuộc selectivity: lấy 1 dòng hay 5 triệu đều đọc cả bảng

**Index Scan** — đi từ root xuống lá, lấy TID, rồi **nhảy tới đúng page heap**.
- Chi phí ≈ đi index + `số dòng khớp × random_page_cost`
- Ngẫu nhiên → mỗi dòng có thể là một lần nhảy riêng
- Trả dòng **theo thứ tự index** → xoá được node `Sort` phía trên
- Tốt khi ít dòng; **thảm hoạ** khi nhiều dòng

**Index Only Scan** — như trên nhưng không đụng heap, vì mọi cột cần đều nằm trong index. Chỉ khả thi khi visibility map cho phép (Day 08).

**Bitmap Heap Scan** — giải pháp trung dung, hai pha:
1. `Bitmap Index Scan`: quét index, **không** lấy dòng, chỉ dựng bitmap các page cần đọc
2. `Bitmap Heap Scan`: sắp bitmap theo số page rồi đọc heap **theo thứ tự tăng dần** — biến random I/O thành gần-tuần-tự

```
Bitmap Heap Scan on ts_kv  (actual rows=108169)
  Recheck Cond: (device_id = 42)
  Heap Blocks: exact=9214
  ->  Bitmap Index Scan on idx_tskv_dev  (actual rows=108169)
```

- **`Recheck Cond`** — bitmap chỉ ghi "page này *có* dòng khớp", không ghi dòng nào; nên đọc page lên vẫn phải kiểm lại.
- **`Heap Blocks: exact=N lossy=M`** — bitmap giới hạn bởi `work_mem`. Quá nhiều page thì chuyển sang **lossy**: chỉ nhớ "page này *có thể* khớp" → phải quét toàn bộ page đó. `lossy > 0` = `work_mem` không đủ.

Bitmap còn có siêu năng lực Index Scan không có: **kết hợp nhiều index** bằng `BitmapAnd` / `BitmapOr`.

### Làm ngay

```sql
-- ép ra từng loại để nhận mặt
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv WHERE device_id = <THAP>;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv WHERE device_id = <GIUA>;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv WHERE device_id = <CAO>;
```

**Ghi vào writeup:** ba query này planner chọn kiểu scan nào? Có `Recheck Cond` ở đâu không?

---

## §2. Vì sao có index mà planner vẫn Seq Scan

### Lý thuyết

Câu trả lời gói trong một con số: **selectivity** — tỷ lệ dòng khớp.

Giả sử bảng 10.000 page, 1.000.000 dòng (100 dòng/page):

| Selectivity | Số dòng | Index Scan phải đọc | Seq Scan phải đọc |
|---|---|---|---|
| 0.001% | 10 | ~10 page ngẫu nhiên → cost ≈ 10×4 = **40** | 10.000 page → **10.000** |
| 1% | 10.000 | ~10.000 page ngẫu nhiên → cost ≈ **40.000** | **10.000** |
| 50% | 500.000 | ~10.000 page, mỗi page nhiều lần → **40.000+** | **10.000** |

Chỗ then chốt: khi lấy 10.000 dòng **rải đều** trên 10.000 page, Index Scan phải chạm gần như mọi page — giống hệt Seq Scan — nhưng bằng random I/O đắt gấp 4 lần, cộng chi phí đi index. Nó thua toàn diện.

Điểm hoà vốn thực tế thường **5–20% số dòng**, phụ thuộc:
- `random_page_cost` (SSD đặt 1.1 thì index thắng ở ngưỡng cao hơn nhiều)
- **`correlation`** của cột — nếu thứ tự vật lý trùng thứ tự index (cột `ts` trong bảng append-only), các dòng khớp nằm liền nhau, index scan gần như tuần tự và thắng tới 50%+
- Bảng có nằm sẵn trong cache không

> Câu trả lời đúng cho "index có mà không dùng": **planner ước lượng số dòng khớp lớn hơn điểm hoà vốn.** Từ đó chỉ có hai khả năng — (a) ước lượng đúng, planner cũng đúng, nên chấp nhận; hoặc (b) ước lượng **sai**, và đó là bài của tuần 3. Rất hiếm khi câu trả lời là "planner ngu".

### Làm ngay

```sql
SELECT attname, n_distinct, correlation FROM pg_stats
WHERE tablename='ts_kv' AND attname IN ('ts','device_id','key_id');
```

**Ghi vào writeup:** `correlation` của `ts` và của `device_id` là bao nhiêu? Dự đoán: cột nào sẽ có điểm hoà vốn cao hơn?

---

## §3. Ma trận 3 mức × 4 kiểu scan — bài chính hôm nay

### Lý thuyết: `enable_*` là phạt cost, không phải công tắc

```sql
SET enable_seqscan = off;
```
Không **cấm** seq scan — nó cộng một khoản phạt khổng lồ (`disable_cost` = 10 tỷ) vào cost node đó. Nếu không còn cách nào khác, planner vẫn chọn, và bạn thấy cost có tiền tố `1e10`.

Công dụng thật: **ép planner cho xem plan thay thế để so số liệu** — kiểm chứng thay vì tranh cãi suông.

**Không bao giờ đặt các GUC này trong `postgresql.conf` production.**

### Làm ngay

Với **mỗi** device trong 3 mức, chạy 4 biến thể:

```sql
-- (a) planner tự chọn
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv WHERE device_id = <X>;

-- (b) ép seq scan
SET enable_indexscan=off; SET enable_bitmapscan=off; SET enable_indexonlyscan=off;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv WHERE device_id = <X>;
RESET ALL;

-- (c) ép index scan
SET enable_seqscan=off; SET enable_bitmapscan=off;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv WHERE device_id = <X>;
RESET ALL;

-- (d) ép bitmap scan
SET enable_seqscan=off; SET enable_indexscan=off; SET enable_indexonlyscan=off;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv WHERE device_id = <X>;
RESET ALL;
```

**Ghi vào writeup — bảng 12 dòng:**

| device_id | rows | % bảng | kiểu scan | planner chọn? | total cost | actual time | shared hit+read |
|---|---|---|---|---|---|---|---|

Rồi: ở mức selectivity nào planner chọn **sai** (biến thể bị ép lại nhanh hơn cái nó tự chọn)? Nếu không có, nói rõ vậy.

---

## §4. Tìm điểm hoà vốn

### Làm ngay

Dùng `ts` để quét liên tục nhiều mức selectivity:

```sql
CREATE INDEX idx_tskv_ts ON ts_kv(ts);
ANALYZE ts_kv;

-- đổi khoảng: 1 giờ, 6 giờ, 1 ngày, 3 ngày, 1 tuần, 2 tuần, 1 tháng
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ts_kv WHERE ts >= '2025-06-01' AND ts < '2025-06-01 01:00';
```

**Ghi vào writeup:** ở khoảng nào planner lật từ index → bitmap, và bitmap → seq scan? Tính **% số dòng** tại mỗi điểm lật.

Rồi so với điểm lật của `device_id` ở §3: **khác nhau không, vì sao?** (dùng `correlation` đã đo ở §2 để giải thích).

---

## §5. Bitmap lossy

### Làm ngay

```sql
SET work_mem = '64kB';
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv WHERE device_id < 100;
SET work_mem = '256MB';
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv WHERE device_id < 100;
RESET work_mem;
```

**Ghi vào writeup:** `Heap Blocks: exact= lossy=` ở mỗi mức, thời gian chênh mấy lần. `lossy` là dấu hiệu nên chỉnh cái gì?

---

## §6. BitmapAnd — kết hợp nhiều index

### Làm ngay

```sql
CREATE INDEX idx_tskv_key ON ts_kv(key_id);
ANALYZE ts_kv;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv WHERE device_id = 3 AND key_id = 1;
```

Nếu planner không dùng cả hai, ép nó:
```sql
SET enable_indexscan = off;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv WHERE device_id = 3 AND key_id = 1;
RESET enable_indexscan;
```

**Ghi vào writeup:** có node `BitmapAnd` không? So với việc dùng một composite index `(device_id, key_id)` thì cái nào tốt hơn — tạo thử rồi đo.

---

## §7. Bảng tra nhanh — học thuộc

| Triệu chứng trong plan | Nghĩa là gì |
|---|---|
| `Seq Scan` + `Rows Removed by Filter` rất lớn | thiếu index, hoặc selectivity quá thấp để index có ích |
| `Index Scan` mà `shared read` ≈ số page cả bảng | index scan đang tệ hơn seq scan |
| `Heap Blocks: lossy=N` lớn | `work_mem` không đủ cho bitmap |
| `Heap Fetches` cao trong Index Only Scan | cần VACUUM (Day 08) |
| `Recheck Cond` xuất hiện | bình thường với bitmap, không phải lỗi |
| `BitmapAnd` | planner đang kết hợp nhiều index |

---

## Kết ngày

### Ba câu cuối

**A.** Trả lời câu kinh điển "có index mà Postgres không dùng" bằng **chi phí I/O**, trong 4–5 câu, có dẫn số từ lab của bạn.

**B. Bạn đoán sai chỗ nào ở §0?**

**C. Áp dụng vào hệ thật:** kể một cột trong DB của bạn có `correlation` cao (gợi ý: cột thời gian trong bảng append-only) và một cột gần 0. Điều đó thay đổi chiến lược đánh index thế nào?

### Đạt khi

Bạn giải thích được "index có mà không dùng" bằng chi phí random I/O và selectivity, có số liệu từ chính lab, và biết dùng `enable_*` để kiểm chứng thay vì đoán.

**Xong thì gõ `/review-bai`.**
