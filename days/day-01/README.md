# Day 01 — Postgres làm gì với câu SQL của bạn

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo. Đừng đọc hết rồi mới làm.

## Chuẩn bị

```bash
make up
make seed SCALE=1     # nếu chưa seed, hoặc muốn reset về trạng thái chưa ANALYZE
make psql
```

```sql
\timing on
\o /days/day-01/output.txt
```

Từ đây output ghi vào file, **không hiện trên màn hình**. Mở terminal thứ hai để xem trực tiếp:
```bash
tail -f days/day-01/output.txt
```

---

## §0. Đoán trước — làm trước tiên, đừng bỏ

Mở `writeup.md`, viết dự đoán **trước khi gõ bất cứ lệnh nào**:

1. `ts_kv` có 5.000.000 dòng, `device_id` phân bố rất lệch. Planner ước lượng `WHERE device_id = 42` ra bao nhiêu dòng? Thực tế bao nhiêu?
2. `pg_class.reltuples` của `ts_kv` lúc này bằng bao nhiêu?
3. `SELECT count(*) FROM ts_kv` mất bao nhiêu ms?

Viết con số cụ thể. Đoán sai không mất điểm — **không đoán mới mất điểm.**

---

## §1. Bốn giai đoạn của một câu query

### Lý thuyết

Khi driver JDBC/pgx gửi một câu SQL, Postgres xử lý qua 4 bước:

```
SQL text
   │
   ▼ ① PARSE        cú pháp -> parse tree. Chưa biết bảng có tồn tại không.
   ▼ ② REWRITE      tra catalog, dán view vào, áp rule -> query tree
   ▼ ③ PLAN         sinh nhiều cách thi hành, ước lượng chi phí, chọn cái rẻ nhất
   ▼ ④ EXECUTE      chạy plan, trả row
```

Bước ③ là nội dung của tuần 1–4. Điều cốt lõi:

> **Planner không biết dữ liệu của bạn. Nó chỉ biết một bản tóm tắt thống kê được lấy mẫu định kỳ.**

Mọi ca "query đột nhiên chậm dù không đổi code" đều bắt nguồn từ câu đó.

### Làm ngay

```sql
-- xem thời gian PLAN so với thời gian EXECUTE
EXPLAIN (ANALYZE) SELECT count(*) FROM ts_kv WHERE device_id = 42;
```

Nhìn hai dòng cuối: `Planning Time` và `Execution Time`.

```sql
-- query đơn giản tới mức planning tốn hơn execution
EXPLAIN (ANALYZE) SELECT * FROM tenant WHERE id = 1;
```

**Ghi vào writeup:** với query nào `Planning Time` lớn hơn `Execution Time`? Điều đó gợi ý gì về chi phí của việc lập kế hoạch cho các query siêu nhẹ chạy hàng triệu lần?

---

## §2. Planner biết gì về bảng của bạn

### Lý thuyết

Hai nguồn, đều trong catalog:

**`pg_class`** — cấp bảng: `relpages` (số page 8KB), `reltuples` (số dòng).
**`pg_statistic`** (xem qua `pg_stats`) — cấp cột: tỷ lệ NULL, số giá trị phân biệt, giá trị phổ biến, histogram. Tuần 3 đào sâu.

Cả hai **không** cập nhật realtime khi bạn INSERT. Chúng được cập nhật bởi:
1. Lệnh `ANALYZE` gõ tay
2. **autovacuum** — tiến trình nền, chỉ chạy khi thay đổi vượt ngưỡng (~10–20% bảng)

Với bảng chưa từng được ANALYZE, `reltuples` mang giá trị đặc biệt **`-1`** — khác hẳn `0` nghĩa là "đã đo, bảng thật sự rỗng". Gặp `-1`, planner ước lượng số dòng từ **kích thước file thật trên đĩa** chia cho độ rộng dòng trung bình.

Còn selectivity của `device_id = 42` thì sao? Không có `pg_statistic` cho cột đó thì planner dùng **hằng số cắm cứng trong source**:

| Điều kiện | Selectivity mặc định |
|---|---|
| `col = ?` | **0.5 %** |
| `col > ?` / `col < ?` | 33 % |
| `col BETWEEN ? AND ?` | 0.5 % |
| số giá trị phân biệt (khi mù tịt) | 200 |

```
rows ước lượng = (số dòng suy từ kích thước file) × 0.005
```

### Làm ngay

```sql
SELECT relname, relpages, reltuples FROM pg_class WHERE relname = 'ts_kv';

SELECT relname, relpages, reltuples,
       pg_size_pretty(pg_relation_size(oid)) AS size_that,
       pg_relation_size(oid)/8192            AS pages_that
FROM pg_class WHERE relname IN ('ts_kv','device','alarm');

SELECT relname, last_analyze, last_autoanalyze, n_live_tup
FROM pg_stat_user_tables WHERE relname = 'ts_kv';
```

**Ghi vào writeup:**
- `reltuples` bằng bao nhiêu? `relpages` (planner tin) có khớp `pages_that` (thật trên đĩa) không — vì sao một cái đúng, cái kia không?
- `last_analyze` và `last_autoanalyze` cho biết điều gì?

---

## §3. Ước lượng khi chưa có statistics — kiểm chứng bằng phép tính ngược

### Làm ngay

```sql
-- tắt song song cho dễ đọc (tránh bẫy loops, sẽ học kỹ ở Day 02)
SET max_parallel_workers_per_gather = 0;

EXPLAIN                    SELECT count(*) FROM ts_kv WHERE device_id = 42;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv WHERE device_id = 42;
SELECT count(*) FROM ts_kv WHERE device_id = 42;   -- sự thật
```

Nhìn node **`Seq Scan on ts_kv`** (không phải node `Aggregate` trên cùng — nó luôn trả 1 dòng nên vô nghĩa):

```
->  Seq Scan on ts_kv  (cost=0.00.... rows=21369 width=0) (actual .. rows=108169 loops=1)
                                       ↑ planner ĐOÁN              ↑ SỰ THẬT
      Filter: (device_id = 42)
```

Giờ **tính ngược** để xác nhận cơ chế ở §2:

```
rows ước lượng ÷ 0.005  =  planner nghĩ bảng có bao nhiêu dòng
```

So con số đó với 5.000.000 thật.

**Ghi vào writeup:** phép tính ngược ra bao nhiêu? Lệch với 5 triệu bao nhiêu %? Phần lệch đó đến từ tầng nào trong hai tầng ước lượng (số dòng của bảng, hay selectivity)?

---

## §4. Cho planner biết sự thật

### Làm ngay

```sql
ANALYZE ts_kv;

SELECT relname, relpages, reltuples FROM pg_class WHERE relname = 'ts_kv';
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv WHERE device_id = 42;
```

Sai số bây giờ còn bao nhiêu %? Nếu **vẫn còn lệch nhiều**, đó là câu hỏi hay nhất hôm nay — đào tiếp:

```sql
SELECT n_distinct, null_frac, correlation,
       most_common_vals[1:5]  AS mcv_5,
       most_common_freqs[1:5] AS freq_5
FROM pg_stats WHERE tablename='ts_kv' AND attname='device_id';
```

`42` có nằm trong danh sách giá trị phổ biến nhất không?

```sql
ANALYZE;   -- toàn database, chuẩn bị cho các ngày sau
RESET max_parallel_workers_per_gather;

-- Bật lại autovacuum. Seed cố ý tắt nó để bạn kịp quan sát trạng thái
-- "planner chưa biết gì" ở §2 — nếu để bật, nó tự chạy sau ~30 giây.
ALTER TABLE tenant      RESET (autovacuum_enabled);
ALTER TABLE ts_key_dict RESET (autovacuum_enabled);
ALTER TABLE device      RESET (autovacuum_enabled);
ALTER TABLE device_attr RESET (autovacuum_enabled);
ALTER TABLE ts_kv       RESET (autovacuum_enabled);
ALTER TABLE alarm       RESET (autovacuum_enabled);
```

**Ghi vào writeup:** sai số trước/sau ANALYZE (bằng %). Nếu sau ANALYZE vẫn lệch, nguyên nhân là gì?

> Ý nghĩa ngoài đời: cùng hằng số 0.5% đó, với `device_id=42` (>100k dòng) planner **đánh giá thấp** vài lần; với một device chỉ có 3 dòng nó **đánh giá cao** hàng nghìn lần. Sai hai chiều ngược nhau — đây là lý do job ETL nạp xong query ngay thì plan lởm, và là lý do tuần 3 tồn tại.

---

## §5. `EXPLAIN` vs `EXPLAIN ANALYZE` — cái thứ hai thực sự chạy

### Lý thuyết

| | `EXPLAIN` | `EXPLAIN ANALYZE` |
|---|---|---|
| Có chạy query? | **Không** | **Có** |
| Cho `cost`, `rows` ước lượng | ✓ | ✓ |
| Cho `actual time`, `actual rows` | ✗ | ✓ |
| An toàn trên production? | ✓ | **Không** với DML |

### Làm ngay

```sql
BEGIN;
EXPLAIN ANALYZE DELETE FROM alarm WHERE id < 1000;
SELECT count(*) FROM alarm WHERE id < 1000;   -- còn bao nhiêu?
ROLLBACK;
SELECT count(*) FROM alarm WHERE id < 1000;   -- sau rollback?
```

**Ghi vào writeup:** con số ở hai lần đếm. Viết ra **quy tắc bạn tự đặt** khi dùng EXPLAIN trên production.

---

## §6. `cost` không phải mili-giây

### Lý thuyết

Planner so sánh phương án bằng đơn vị trừu tượng **cost**. Mốc: đọc tuần tự 1 page = **1.0**.

| Tham số | Mặc định | Ý nghĩa |
|---|---|---|
| `seq_page_cost` | 1.0 | đọc 1 page tuần tự |
| `random_page_cost` | 4.0 | đọc 1 page ngẫu nhiên — **đắt gấp 4** |
| `cpu_tuple_cost` | 0.01 | xử lý 1 dòng |
| `cpu_operator_cost` | 0.0025 | tính 1 phép toán |

```
cost Seq Scan = relpages × seq_page_cost + reltuples × cpu_tuple_cost (+ chi phí toán tử)
```

Hai chỗ dễ nhầm:
- **Cost không đổi ra ms được.** Nó chỉ dùng để *so sánh* các plan **của cùng query trên cùng máy**.
- `random_page_cost = 4.0` là mặc định thời **ổ đĩa cơ**. Trên SSD tỷ lệ thật gần 1.1–1.5. Để nguyên 4.0 khiến planner sợ index quá mức.

Trên mỗi node còn có `cost=A..B`: **A = startup** (tới dòng đầu tiên), **B = total** (tới dòng cuối). Node `Sort` phải đọc hết mới trả được dòng đầu → startup cao. Với `LIMIT`, planner ưu tiên startup thấp.

### Làm ngay

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM alarm;
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM ts_kv ORDER BY dbl_v LIMIT 10;
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM ts_kv ORDER BY dbl_v;      -- bỏ LIMIT
```

Tự tính cost của Seq Scan bằng công thức trên rồi so với con số planner in:
```sql
SELECT relpages, reltuples, relpages*1.0 + reltuples*0.01 AS cost_toi_tinh
FROM pg_class WHERE relname='ts_kv';
```

**Ghi vào writeup:**
- Bảng 4 dòng: `startup cost` | `total cost` | `actual time` | tỷ lệ ms÷cost. Tỷ lệ có phải hằng số không — nêu **hai** lý do khiến nó không thể là hằng số.
- Cost bạn tự tính so với cost planner in: lệch bao nhiêu?
- Cặp có/không `LIMIT 10`: startup cost đổi thế nào, plan có đổi kiểu node không?

---

## §7. Hai con số row — điều quan trọng nhất hôm nay

### Lý thuyết

Trên mỗi node có **hai** con số row:

```
(cost=0.00..63002.33 rows=7123 width=0) (actual ... rows=108169 loops=1)
                     ↑ planner ĐOÁN                    ↑ SỰ THẬT
```

> **Kỹ năng nền tảng của mọi việc tune query: so hai con số này ở từng node, tìm node đầu tiên (từ dưới lên) mà chúng lệch nhau nhiều lần. Đó gần như luôn là gốc bệnh** — vì sai số ở node lá bị khuếch đại qua từng tầng join phía trên.

Nếu chỉ nhớ một câu từ hôm nay, nhớ câu đó.

### Làm ngay

```sql
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, SETTINGS)
SELECT d.name, count(*)
FROM ts_kv t JOIN device d ON d.id = t.device_id
WHERE t.ts >= '2025-06-01' AND t.ts < '2025-06-02'
GROUP BY d.name ORDER BY 2 DESC LIMIT 10;
```

Với **mỗi** node, ghi cặp `rows` / `actual rows` và tỷ lệ lệch.

`SETTINGS` ở cuối in ra GUC nào lab đang đặt khác mặc định — đọc lướt cho biết.

**Ghi vào writeup:** node nào lệch nhiều nhất? Nó nằm gần lá hay gần gốc?

---

## Kết ngày

### Nộp bài

| File | Nội dung |
|---|---|
| `lab.sql` | mọi lệnh đã chạy, kể cả sai (ghi chú `-- SAI: vì...`) |
| `output.txt` | đã có nhờ `\o` |
| `writeup.md` | các mục "Ghi vào writeup" ở trên + 2 câu dưới |

Lấy lại lịch sử lệnh:
```bash
docker exec pgdd cat /var/lib/postgresql/.psql_history | tail -80
```

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?** Lúc đầu bạn nghĩ vậy vì hiểu nhầm điều gì?

**B. Áp dụng vào hệ thật:** trong hệ của bạn có job nào nạp dữ liệu lớn rồi query ngay không? Sau bài hôm nay bạn sẽ thêm bước gì vào job đó?

### Đạt khi

Giải thích được `reltuples` từ đâu ra, vì sao ngay sau khi insert 5 triệu dòng planner vẫn chưa biết, ai cập nhật con số đó, và vì sao việc so `rows` với `actual rows` ở từng node là kỹ năng nền tảng.

**Xong thì gõ `/review-bai`.**
