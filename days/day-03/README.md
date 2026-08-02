# Day 03 — `BUFFERS`: đo I/O thay vì đo thời gian

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

```sql
\timing on
\o /days/day-03/output.txt
```

---

## §0. Đoán trước

1. `SELECT count(*) FROM ts_kv` sẽ đọc bao nhiêu buffer?
2. Chạy lần 2 ngay sau đó thì `hit` và `read` đổi thế nào?

---

## §1. Postgres không đọc dòng, nó đọc page

### Lý thuyết

Đơn vị I/O của Postgres là **page = 8 KB**. Heap, index, TOAST đều chia thành page 8KB. Muốn đọc 1 dòng, phải nạp cả page chứa dòng đó.

Hệ quả: **số page đọc, chứ không phải số dòng trả về, quyết định query nhanh hay chậm.** Một query trả 10 dòng nằm rải trên 10 page đắt gấp 10 lần cùng 10 dòng nằm chung 1 page. Đây là nền của `correlation` (Day 04) và BRIN (Day 31).

### Làm ngay

```sql
SELECT pg_size_pretty(pg_relation_size('ts_kv'))       AS heap,
       pg_size_pretty(pg_total_relation_size('ts_kv')) AS total_ke_ca_index,
       pg_relation_size('ts_kv') / 8192                AS pages;
```

**Ghi vào writeup:** bảng `ts_kv` có bao nhiêu page? Trung bình mỗi page chứa bao nhiêu dòng (5 triệu ÷ số page)?

---

## §2. Ba tầng cache

### Lý thuyết

```
   Query
     ▼
shared_buffers      <- cache của Postgres. Mặc định 128MB (lab: 256MB)
     ▼ miss
OS page cache       <- cache của Linux, thường lớn hơn nhiều
     ▼ miss
Đĩa thật
```

Điểm rất dễ hiểu nhầm: **`BUFFERS` chỉ nhìn thấy tầng 1.** Khi EXPLAIN báo `read`, nghĩa là "không có trong shared_buffers" — dữ liệu vẫn có thể đến từ OS page cache trong 0.01ms chứ chưa chắc đụng đĩa. Đó là lý do có khi `read` rất lớn mà query vẫn nhanh.

Vì thế có `effective_cache_size` (mặc định 4GB): lời khai của bạn với planner rằng "tổng cache khoảng chừng này". Nó **không cấp phát** RAM, chỉ dùng để tính cost.

### Làm ngay

```sql
SHOW shared_buffers;
SHOW effective_cache_size;
SELECT count(*) FROM pg_buffercache WHERE relfilenode IS NOT NULL;  -- nếu có extension
```
(Nếu `pg_buffercache` chưa có: `CREATE EXTENSION pg_buffercache;`)

```sql
-- bảng nào đang chiếm shared_buffers nhiều nhất
SELECT c.relname, count(*) AS buffers, pg_size_pretty(count(*)*8192::bigint) AS size
FROM pg_buffercache b JOIN pg_class c ON b.relfilenode = pg_relation_filenode(c.oid)
GROUP BY 1 ORDER BY 2 DESC LIMIT 10;
```

**Ghi vào writeup:** `shared_buffers` bao nhiêu, và hiện đang chứa bảng nào nhiều nhất?

---

## §3. Đọc các con số `BUFFERS`

### Lý thuyết

```
Buffers: shared hit=27921 read=9037 dirtied=12 written=0
         temp read=1523 written=1523
I/O Timings: shared read=7.532
```

| Trường | Nghĩa |
|---|---|
| `shared hit` | page có sẵn trong shared_buffers — **gần như miễn phí** |
| `shared read` | page phải nạp vào (từ OS cache hoặc đĩa) |
| `shared dirtied` | page bị query này làm bẩn |
| `shared written` | page bẩn bị chính query này đẩy xuống đĩa — dấu hiệu shared_buffers chật |
| `local hit/read` | như trên nhưng cho **bảng tạm** |
| `temp read/written` | **spill** — sort/hash thiếu `work_mem`, tràn ra file tạm. Luôn là cờ đỏ |
| `I/O Timings` | thời gian thật tốn cho I/O (cần `track_io_timing=on`, lab đã bật) |

Đổi ra dung lượng: `MB = (hit + read) × 8 ÷ 1024`

### Làm ngay

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv WHERE key_id = 1;
```

**Ghi vào writeup:** query này đọc bao nhiêu MB? So với `pages` ở §1 — khớp không, chênh chỗ nào và vì sao?

> Mẹo kiểm tra chéo: nếu số MB query đọc xấp xỉ kích thước bảng thì nó đang quét toàn bảng, **dù plan có ghi chữ "Index Scan" ở đâu đó**.

---

## §4. Cache lạnh vs cache nóng

### Làm ngay

Thoát psql, restart container để xoá shared_buffers:

```bash
docker restart pgdd && sleep 5
make psql
```
```sql
\timing on
\o /days/day-03/output.txt
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv WHERE key_id = 1;
```
Ghi lần này (lạnh), rồi chạy **lại y hệt 3 lần nữa**.

```sql
CREATE EXTENSION IF NOT EXISTS pg_prewarm;
SELECT pg_prewarm('ts_kv');
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv WHERE key_id = 1;
```

**Ghi vào writeup — bảng 6 dòng:** trạng thái (lạnh / lặp 1,2,3 / prewarm / sau prewarm) × `hit` | `read` | `I/O time` | `exec time`.

Rồi trả lời: giữa lần lạnh và lần nóng, `read` giảm bao nhiêu, ms giảm bao nhiêu? **Tổng `hit+read` có gần như không đổi không** — vì sao đó là ưu điểm của buffers so với ms?

---

## §5. Vì sao buffers đáng tin hơn mili-giây

### Lý thuyết

Thời gian phụ thuộc: cache nóng/lạnh, máy đang tải gì, CPU boost hay throttle, có ai chạy backup không. Cùng một query 3 lần có thể chênh 20 lần.

**Số buffer thì gần như tất định.** Cùng plan trên cùng lượng dữ liệu luôn chạm đúng chừng đó page.

Tình huống kinh điển bị lừa:

> Bạn thêm index, đo lại thấy 800ms → 40ms, kết luận index hiệu quả. Thật ra lần đầu cache lạnh, lần sau cache nóng. Nhìn buffers thấy cả hai đều `shared hit≈36000` — plan không đổi, index chưa từng được dùng.

### Làm ngay — tự dựng đúng cái bẫy đó

```sql
DROP INDEX IF EXISTS idx_alarm_sev;
```
```bash
docker restart pgdd && sleep 5
make psql
```
```sql
\timing on
\o /days/day-03/output.txt
-- lần 1: cache lạnh, KHÔNG index
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM alarm WHERE severity = 'CRITICAL';
-- lần 2: cache nóng, VẪN không index
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM alarm WHERE severity = 'CRITICAL';
-- lần 3: có index, cache nóng
CREATE INDEX idx_alarm_sev ON alarm(severity);
ANALYZE alarm;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM alarm WHERE severity = 'CRITICAL';
```

**Ghi vào writeup:** 3 dòng số liệu. Nếu chỉ nhìn ms, bạn kết luận sai ở chỗ nào? Buffers đã tố cáo điều đó thế nào?

> Nguyên tắc benchmark rút ra: **hoặc đo tất cả khi cache nóng, hoặc tất cả khi lạnh — đừng trộn.** Và chạy mỗi biến thể ít nhất 3 lần.

---

## §6. `temp` — cờ đỏ quan trọng nhất

### Lý thuyết

`temp written > 0` nghĩa là dữ liệu trung gian bị ghi xuống đĩa vì `work_mem` không đủ. Sort, hash join, hash aggregate đều có thể spill. Tuần 4 sẽ đào sâu.

### Làm ngay

```sql
SHOW work_mem;   -- 4MB
EXPLAIN (ANALYZE, BUFFERS) SELECT device_id, ts FROM ts_kv ORDER BY dbl_v;
```
Ghi `temp read/written` và `Sort Method`.

```sql
SET work_mem = '512MB';
EXPLAIN (ANALYZE, BUFFERS) SELECT device_id, ts FROM ts_kv ORDER BY dbl_v;
RESET work_mem;
```

**Ghi vào writeup:** `temp written` bao nhiêu MB, `Sort Method` là gì ở mỗi mức? Thời gian đổi mấy lần? Vì sao `temp` là cờ đỏ đáng chú ý hơn cả `read` cao?

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B. Áp dụng vào hệ thật:** trong service của bạn có query nào bạn từng "tối ưu" chỉ dựa vào ms không? Nếu đo lại bằng buffers thì bạn kiểm tra gì?

### Đạt khi

Bạn phát biểu được vì sao buffers là thước đo chính và ms chỉ là thước đo phụ, kèm ví dụ cụ thể từ chính lab của bạn nơi ms nói dối.

**Xong thì gõ `/review-bai`.**
