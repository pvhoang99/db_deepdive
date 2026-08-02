# Day 09 — Partial index & expression index

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

```sql
\timing on
\o /days/day-09/output.txt
ANALYZE alarm; ANALYZE device;

SELECT count(*) FILTER (WHERE end_ts IS NULL) AS active, count(*) AS total,
       round(100.0*count(*) FILTER (WHERE end_ts IS NULL)/count(*), 2) AS pct
FROM alarm;
```

---

## §0. Đoán trước

1. Partial index `WHERE end_ts IS NULL` nhỏ hơn index đầy đủ bao nhiêu lần?
2. Query `WHERE end_ts IS NULL AND severity = 'CRITICAL'` có dùng được nó không?
3. Query `WHERE status IN ('ACTIVE_UNACK','ACTIVE_ACK')` (tương đương về mặt dữ liệu) thì sao?

---

## §1. Partial index

### Lý thuyết

```sql
CREATE INDEX idx_alarm_active ON alarm(device_id) WHERE end_ts IS NULL;
```

Index này **chỉ chứa các dòng thoả `end_ts IS NULL`** — trong lab là ~5% bảng.

Lợi ích không chỉ dung lượng:
- Nhỏ hơn → nằm gọn trong cache → hầu như không đọc đĩa
- Cây thấp hơn → ít page read mỗi lookup
- **Ghi rẻ hơn**: `INSERT` một dòng có `end_ts` khác NULL thì index này không phải cập nhật gì
- VACUUM nhanh hơn

Công cụ mạnh nhất cho mẫu rất phổ biến: **bảng lớn nhưng chỉ một phần nhỏ "đang hoạt động"** — job queue, alarm đang mở, đơn hàng chưa xử lý, session còn hạn, soft-deleted rows.

### Làm ngay

```sql
CREATE INDEX idx_alarm_dev_full ON alarm(device_id);
CREATE INDEX idx_alarm_dev_part ON alarm(device_id) WHERE end_ts IS NULL;
ANALYZE alarm;

SELECT relname, pg_size_pretty(pg_relation_size(oid)) AS size,
       (SELECT level FROM bt_metap(relname)) AS level
FROM pg_class WHERE relname LIKE 'idx_alarm_dev%';
```

**Ghi vào writeup:** partial index nhỏ hơn full index bao nhiêu lần? Cây thấp hơn không?

---

## §2. Điều kiện để planner chịu dùng partial index

### Lý thuyết

Đây là phần dễ vấp nhất.

> Planner chỉ dùng partial index khi nó **chứng minh được** rằng điều kiện `WHERE` của query **kéo theo** (implies) điều kiện của index.

Với index `WHERE end_ts IS NULL`:

| Query | Dùng được? | Vì sao |
|---|---|---|
| `WHERE end_ts IS NULL` | ✓ | trùng khớp |
| `WHERE end_ts IS NULL AND severity='CRITICAL'` | ✓ | A∧B kéo theo A |
| `WHERE end_ts IS NULL OR severity='CRITICAL'` | ✗ | không kéo theo |
| `WHERE status LIKE 'ACTIVE%'` | ✗ | tương đương về dữ liệu, nhưng planner **không biết** |

Bộ chứng minh của Postgres khá hạn chế: xử lý tốt `AND`, so sánh trên cùng cột với hằng số, và `IS NULL`. **Không** suy luận qua ràng buộc nghiệp vụ, qua hàm, hay qua tham số.

### Làm ngay

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM alarm WHERE end_ts IS NULL AND device_id = 3;
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM alarm WHERE end_ts IS NULL AND device_id = 3 AND severity='CRITICAL';
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM alarm WHERE device_id = 3;
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM alarm WHERE (end_ts IS NULL OR severity='CRITICAL') AND device_id = 3;
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM alarm WHERE status IN ('ACTIVE_UNACK','ACTIVE_ACK') AND device_id = 3;
```

**Ghi vào writeup — bảng 5 dòng:** query | index được chọn | buffers | time | **giải thích vì sao dùng/không dùng partial**.

Câu quan trọng: query 5 tương đương về **dữ liệu** với `end_ts IS NULL` nhưng planner vẫn từ chối. Điều này nói gì về giới hạn của bộ chứng minh?

---

## §3. Bẫy tham số — chỗ ORM phá partial index

### Lý thuyết

Với index `WHERE amount > 1000`, query `WHERE amount > $1` **không** dùng được index — lúc lập kế hoạch planner chưa biết `$1` bằng bao nhiêu.

Đây là chỗ ORM/prepared statement hay làm hỏng partial index mà không ai biết.

### Làm ngay

```sql
CREATE INDEX idx_alarm_thresh ON alarm(device_id) WHERE (details->>'threshold')::int > 50;
ANALYZE alarm;

EXPLAIN SELECT * FROM alarm WHERE (details->>'threshold')::int > 50 AND device_id = 3;

PREPARE p2(int) AS SELECT * FROM alarm WHERE (details->>'threshold')::int > $1 AND device_id = 3;
EXPLAIN EXECUTE p2(50);
```

Thêm hiện tượng custom plan → generic plan:
```sql
PREPARE p1(bigint) AS SELECT * FROM alarm WHERE end_ts IS NULL AND device_id = $1;
EXPLAIN EXECUTE p1(3);   -- chạy lệnh này 6 lần liên tiếp, xem plan có đổi không
```
(Postgres chuyển từ custom plan sang generic plan sau ~5 lần. Ghi lại hiện tượng — Day 12 sẽ giải thích kỹ.)

**Ghi vào writeup:** hai cách viết cho ra plan khác nhau thế nào? Đây là rủi ro gì khi dùng ORM/prepared statement trong code Java/Go của bạn?

---

## §4. Mẹo ngược: partial index cho cột lệch

### Lý thuyết

Trực giác thường: "cột `status` có 90% là `DONE`, index vô dụng". Đúng — với index thường.

Nhưng:
```sql
CREATE INDEX idx_pending ON job(created_at) WHERE status <> 'DONE';
```
Index này chỉ chứa 10% dòng. Query `WHERE status <> 'DONE' ORDER BY created_at` giờ dùng được index nhỏ xíu.

**Partial index biến "cột lệch" từ nhược điểm thành ưu điểm.** Càng lệch thì càng đáng.

### Làm ngay

`alarm.status` cũng lệch. Kiểm tra phân bố rồi tự dựng partial index cho nhóm hiếm:
```sql
SELECT status, count(*), round(100.0*count(*)/sum(count(*)) OVER (),2) AS pct
FROM alarm GROUP BY 1 ORDER BY 2 DESC;

CREATE INDEX idx_alarm_unack ON alarm(start_ts) WHERE status LIKE 'ACTIVE%';
ANALYZE alarm;
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM alarm WHERE status LIKE 'ACTIVE%' ORDER BY start_ts DESC LIMIT 20;
```

**Ghi vào writeup:** index này bằng bao nhiêu % kích thước bảng? Query đọc bao nhiêu buffer, có node `Sort` không?

---

## §5. Expression index

### Lý thuyết

```sql
CREATE INDEX idx_dev_lower_name ON device (lower(name));
```

Index lưu **kết quả của biểu thức**, không lưu giá trị gốc.

Quy tắc sắt: **query phải chứa biểu thức y hệt.**
```sql
WHERE lower(name) = 'device-0000042'   -- ✓
WHERE name = 'device-0000042'          -- ✗
WHERE upper(name) = 'DEVICE-0000042'   -- ✗
```

Biểu thức phải **IMMUTABLE**. Nên:
- `lower(text)` ✓
- `now()`, `random()` ✗ (VOLATILE)
- `to_char(timestamptz, ...)` ✗ — là STABLE, phụ thuộc timezone của session. Phải ép: `to_char(ts AT TIME ZONE 'UTC', 'YYYY-MM')`

Lỗi cực hay gặp khi làm time-series.

### Làm ngay

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM device WHERE lower(name) = 'device-0000042';

CREATE INDEX idx_dev_lower ON device (lower(name));
ANALYZE device;

EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM device WHERE lower(name) = 'device-0000042';
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM device WHERE name = 'device-0000042';
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM device WHERE upper(name) = 'DEVICE-0000042';
```

Bẫy timezone — **lệnh này sẽ lỗi, đọc kỹ thông báo**:
```sql
CREATE INDEX idx_tskv_month ON ts_kv (to_char(ts, 'YYYY-MM'));
```
Rồi tự sửa cho chạy được.

**Ghi vào writeup:** thông báo lỗi là gì, bạn sửa thế nào, vì sao Postgres từ chối?

---

## §6. Lợi ích ẩn: statistics cho biểu thức

### Lý thuyết

Bình thường planner không biết gì về phân bố của `lower(name)` hay `meta->>'model'` — phải dùng hằng số mặc định 0.5% (Day 01). Nhưng khi bạn tạo expression index, **`ANALYZE` thu thập thống kê cho chính biểu thức đó**.

Nên đôi khi người ta tạo expression index **chỉ để có statistics**. (Từ PG14 có `CREATE STATISTICS ... ON (expression)` làm việc này mà không cần index — Day 13.)

### Làm ngay

```sql
EXPLAIN SELECT * FROM device WHERE meta->>'model' = 'TH-100';   -- ước lượng bao nhiêu?
SELECT count(*) FROM device WHERE meta->>'model' = 'TH-100';    -- thật bao nhiêu?

CREATE INDEX idx_dev_model ON device ((meta->>'model'));
ANALYZE device;

EXPLAIN SELECT * FROM device WHERE meta->>'model' = 'TH-100';   -- giờ ước lượng bao nhiêu?
SELECT attname, n_distinct, most_common_vals FROM pg_stats WHERE tablename = 'idx_dev_model';
```

**Ghi vào writeup:** ước lượng trước/sau khi có expression index. Sai số giảm mấy lần?

---

## §7. Kết hợp partial + expression

### Làm ngay

```sql
CREATE INDEX idx_alarm_crit
  ON alarm ((details->>'threshold')::int)
  WHERE end_ts IS NULL AND severity = 'CRITICAL';
ANALYZE alarm;

SELECT pg_size_pretty(pg_relation_size('idx_alarm_crit')) AS idx,
       pg_size_pretty(pg_relation_size('alarm'))          AS tbl;

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM alarm
WHERE end_ts IS NULL AND severity = 'CRITICAL' AND (details->>'threshold')::int > 80;
```

**Ghi vào writeup:** index bằng bao nhiêu % kích thước bảng? Query đọc bao nhiêu buffer? Đây là kỹ thuật đáng giá nhất của cả tuần 2 — nói rõ vì sao.

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B. Áp dụng vào hệ thật:** liệt kê **3 chỗ** trong hệ ThingsBoard/service của bạn dùng được partial index, kèm ước lượng % dữ liệu mỗi index sẽ chứa. Mẫu hay gặp: soft delete, job chưa xử lý, alarm đang mở, session còn hạn.

### Đạt khi

Bạn nhìn một bảng là biết ngay chỗ nào dùng được partial index, và dự đoán đúng khi nào planner sẽ từ chối dùng nó.

**Xong thì gõ `/review-bai`.**
