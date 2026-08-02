# Day 05 — `pg_stat_statements`: tối ưu cái đáng tối ưu + ôn tuần

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

```sql
\timing on
\o /days/day-05/output.txt
```

---

## §1. Vấn đề: query nào đáng sửa?

### Lý thuyết

Bốn ngày qua bạn học cách mổ xẻ **một** query. Nhưng trên production câu hỏi đầu tiên không phải "query này chậm ở đâu" mà là **"query nào đáng để tôi bỏ một buổi chiều ra sửa"**. Trả lời sai câu đó thì kỹ năng đọc plan cũng vô ích.

`pg_stat_statements` ghi thống kê tích luỹ của mọi câu lệnh. Phải nạp qua `shared_preload_libraries` (lab đã cấu hình) và cần restart để bật — nên trên production hãy bật từ đầu.

**Chuẩn hoá query (normalization)** là cơ chế cốt lõi:
```sql
SELECT * FROM device WHERE id = 42;
SELECT * FROM device WHERE id = 99;      →   SELECT * FROM device WHERE id = $1
SELECT * FROM device WHERE id = 12345;
```
Hằng số thay bằng placeholder, băm thành `queryid`. Nhờ vậy một endpoint gọi 10 triệu lần chỉ chiếm một dòng.

Khác **hằng số** thì gộp; khác **cấu trúc** thì tách riêng.

### Làm ngay

```sql
SELECT pg_stat_statements_reset();

SELECT * FROM device WHERE id = 42;
SELECT * FROM device WHERE id = 99;
SELECT * FROM device WHERE id = 12345;
SELECT * FROM device WHERE id = 42 AND is_active;

SELECT queryid, query, calls FROM pg_stat_statements
WHERE query LIKE '%FROM device WHERE id%';
```

**Ghi vào writeup:** 4 câu lệnh trên gộp thành mấy entry? Vì sao câu thứ 4 tách riêng?

---

## §2. Các cột đáng quan tâm

### Lý thuyết

| Cột | Nghĩa |
|---|---|
| `calls` | số lần chạy |
| `total_exec_time` | **tổng** thời gian tích luỹ (ms) |
| `mean_exec_time` | trung bình mỗi lần |
| `stddev_exec_time` | độ lệch chuẩn — cao = không ổn định, đáng nghi hơn |
| `shared_blks_hit/read` | buffers tích luỹ |
| `temp_blks_written` | tổng spill — chỉ ra ai thiếu `work_mem` |
| `wal_bytes` | WAL sinh ra — chỉ ra ai gây tải ghi |

Truy vấn nền tảng nên thuộc lòng:

```sql
SELECT substring(query, 1, 70) AS q,
       calls,
       round(total_exec_time::numeric, 1)  AS total_ms,
       round(mean_exec_time::numeric, 2)   AS mean_ms,
       round(stddev_exec_time::numeric, 2) AS stddev_ms,
       round(100 * total_exec_time / sum(total_exec_time) OVER (), 1) AS pct,
       shared_blks_hit + shared_blks_read  AS bufs,
       temp_blks_written                   AS temp_w
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;
```

Cột `pct` là quý nhất: nếu query đứng đầu chiếm 45% tổng thời gian, bạn biết chính xác nên làm gì tiếp.

### Làm ngay

Chạy truy vấn trên ngay bây giờ (dữ liệu tích luỹ từ các bài trước).

**Ghi vào writeup:** query nào đang đứng đầu, chiếm bao nhiêu `pct`?

---

## §3. `total` hay `mean`? — ý quan trọng nhất hôm nay

### Lý thuyết

| Query | calls | mean | total |
|---|---|---|---|
| A: báo cáo cuối tháng | 10 | 2.000 ms | 20 giây |
| B: lấy device theo id | 5.000.000 | 4 ms | **5,6 giờ** |

Xếp theo `mean` thì bạn sửa A. Nhưng A chỉ chiếm 20 giây tải của cả tháng. B mới đang ăn CPU, giữ connection, tạo p99 cho toàn bộ API. **Giảm B từ 4ms xuống 1ms tiết kiệm 4,2 giờ CPU; tối ưu A hoàn hảo tiết kiệm 20 giây.**

- **`total_exec_time` = ưu tiên tối ưu.** Nơi tài nguyên thật sự bị tiêu.
- **`mean_exec_time` = ưu tiên trải nghiệm.** Query 2 giây làm người dùng chờ 2 giây, dù hiếm.
- **`stddev` cao = ưu tiên điều tra.** Lúc nhanh lúc chậm thường là plan không ổn định, khoá, hoặc dữ liệu lệch — nguy hiểm hơn chậm đều.

Đây là tư duy Amdahl áp vào database.

### Làm ngay

Tạo `days/day-05/bench.sql` với ~20 query hỗn hợp, cố ý pha trộn:
- vài query nhanh nhưng gọi **rất nhiều lần**
- vài query chậm nhưng gọi ít
- ít nhất một query gây `temp`
- ít nhất một `UPDATE`/`INSERT` để thấy `wal_bytes`

Khung gợi ý:
```sql
-- nhẹ nhưng lặp nhiều
SELECT count(*) FROM (
  SELECT (SELECT count(*) FROM ts_kv WHERE device_id = (1 + g % 500))
  FROM generate_series(1, 300) g
) s;

-- nặng, 1 lần
SELECT device_id, count(*), avg(dbl_v) FROM ts_kv GROUP BY device_id ORDER BY 2 DESC LIMIT 20;

-- gây temp
SELECT device_id, ts FROM ts_kv ORDER BY dbl_v LIMIT 100;

-- ghi
UPDATE alarm SET severity = severity WHERE id < 5000;

-- ... tự viết thêm cho đủ ~20
```

Chạy:
```sql
SELECT pg_stat_statements_reset();
```
```bash
make run F=days/day-05/bench.sql
```

**Ghi vào writeup:** hai bảng top 5 — một xếp theo `total_exec_time`, một theo `mean_exec_time`. Chúng khác nhau thế nào? Query nào có ở bảng này mà không có ở bảng kia?

**Và câu quan trọng nhất:** nếu chỉ được sửa **một** query, bạn sửa cái nào? Trả lời bằng `pct` và tổng thời gian tiết kiệm được, không bằng cảm tính.

---

## §4. Sửa kẻ đứng đầu

### Làm ngay

Lấy query số 1 theo `total_exec_time`, chạy `EXPLAIN (ANALYZE, BUFFERS)`, chẩn đoán bằng đúng những gì đã học 4 ngày qua, và **sửa nó** — thêm index / viết lại SQL. **Không được đổi GUC.**

Đo lại:
```sql
SELECT pg_stat_statements_reset();
```
```bash
make run F=days/day-05/bench.sql
```

**Ghi vào writeup:** chẩn đoán là gì, sửa thế nào, `pct` giảm từ bao nhiêu xuống bao nhiêu, buffers giảm mấy lần, query đó tụt xuống hạng mấy.

---

## §5. Tìm kẻ gây spill

### Làm ngay

```sql
SELECT substring(query,1,60) AS q, calls, temp_blks_written,
       pg_size_pretty(temp_blks_written * 8192::bigint) AS temp_size
FROM pg_stat_statements WHERE temp_blks_written > 0
ORDER BY temp_blks_written DESC;
```

**Ghi vào writeup:** ai ghi tạm nhiều nhất? Nếu tăng `work_mem` cho riêng session đó thì tiết kiệm được bao nhiêu?

---

## §6. Đo cho đúng trên production

### Lý thuyết

`pg_stat_statements` là số **tích luỹ từ lúc reset**. Trên production đừng reset bừa (mất dữ liệu của người khác). Cách đúng: **chụp hai lần rồi trừ**, hoặc để monitoring làm.

Bẫy khác: `pg_stat_statements.max` (mặc định 5000) giới hạn số entry. Khi tràn, entry ít dùng bị đẩy ra — và bạn mất số liệu. Lab đặt 10000.

### Làm ngay

```sql
SHOW pg_stat_statements.max;
SELECT count(*) FROM pg_stat_statements;
```

**Ghi vào writeup:** đang dùng bao nhiêu / tối đa bao nhiêu entry? Với service của bạn (bao nhiêu endpoint, bao nhiêu query khác nhau), con số 5000 có đủ không?

---

## §7. Ôn tuần

**Viết vào `writeup.md` ba mục:**

**A. Ba điều tôi tưởng đúng mà hoá ra sai trong tuần này.** Mỗi điều: tôi từng nghĩ gì, sự thật là gì, bằng chứng nào trong lab.

**B. Checklist chẩn đoán query chậm** — tối đa 8 bước, theo thứ tự tôi sẽ thực hiện. Phải dùng được ngay trên production.

**C. Năm chỉ số tôi sẽ đưa lên dashboard** cho DB của mình, kèm ngưỡng cảnh báo cụ thể.

---

## Kết ngày

### Hai câu cuối

**A.** Giải thích vì sao query 5ms chạy 1 triệu lần nguy hiểm hơn query 2s chạy 10 lần — bằng con số cụ thể từ bench của bạn.

**B. Áp dụng vào hệ thật:** `pg_stat_statements` đã bật trên DB production của bạn chưa? Nếu chưa, viết kế hoạch bật (cần restart, thêm gì vào config, rủi ro gì).

### Đạt khi

Bạn chọn được query đáng tối ưu nhất bằng số liệu, sửa được nó, và chứng minh cải thiện bằng `pct` trước/sau — không phải bằng "thấy nhanh hơn".

**Xong thì gõ `/review-bai`.**

---

## Hết tuần 1

Bạn giờ có đủ **công cụ đo**. Từ tuần 2 mọi bài đều dựa trên bốn thứ này: đọc plan, nhân loops, đọc buffers, chọn mục tiêu bằng pg_stat_statements. Còn lấn cấn chỗ nào thì quay lại làm cho chắc — tuần 2 sẽ không giải thích lại.
