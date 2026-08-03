# Day 40 — Wait events: hệ đang **chờ** cái gì — và ôn tuần 8

**Thời lượng:** 60–90 phút · **Cần 2 terminal:** `make s1` và `make s2`.

> Cả 39 ngày qua bạn đo **một query**. Hôm nay đổi câu hỏi: *"cả hệ đang chờ cái gì?"* — câu hỏi đầu tiên phải trả lời khi có sự cố, trước khi mở EXPLAIN của bất kỳ query nào.
>
> `pg_stat_statements` cho biết query nào **tốn thời gian**. Wait event cho biết thời gian đó **trôi vào đâu**: đọc đĩa, chờ lock, chờ WAL fsync, hay chờ chính ứng dụng của bạn.

## Chuẩn bị

```sql
\timing on
\o /days/day-40/output.txt
```

---

## §0. Đoán trước

1. Một backend đang `state = 'active'` — nó chắc chắn đang **dùng CPU**? Đúng hay sai?
2. Trong lab này (shared_buffers 256MB, bảng 5M dòng), wait event chiếm đa số khi chạy seq scan lớn sẽ là gì?
3. Session `idle in transaction` 2 tiếng gây hại gì — kể 3 thứ.
4. Trên hệ thật của bạn, wait event nào bạn đoán là top 1? Ghi ra, cuối ngày kiểm chứng.

---

## §1. `pg_stat_activity` — bảng quan trọng nhất khi có sự cố

### Lý thuyết

Mỗi backend (mỗi connection) là một dòng. Bốn cột quyết định:

| Cột | Đọc thế nào |
|---|---|
| `state` | `active` (đang chạy câu lệnh) / `idle` (rỗi, ngoài transaction) / **`idle in transaction`** (mở transaction rồi bỏ đó — nguy hiểm) / `idle in transaction (aborted)` |
| `wait_event_type` | nhóm: `LWLock`, `Lock`, `IO`, `IPC`, `Timeout`, `Client`, `BufferPin`, `Extension`, `Activity` |
| `wait_event` | tên cụ thể: `DataFileRead`, `WALSync`, `transactionid`, `ClientRead`... |
| `backend_type` | `client backend` / `autovacuum worker` / `checkpointer` / `walwriter` / `background writer` |

**Điểm mấu chốt, và là chỗ 90% người đọc sai:** `state = 'active'` **KHÔNG** có nghĩa là đang dùng CPU. Nó có nghĩa là "đang trong một câu lệnh". Nếu `wait_event IS NOT NULL` thì nó đang **chờ**, không chạy.

Ngược lại: `wait_event IS NULL` **và** `state='active'` → đang thật sự chạy trên CPU.

Hai wait event luôn xuất hiện nhưng **không phải vấn đề**:
- `Client / ClientRead` trên backend `idle` — đang chờ câu lệnh tiếp theo từ ứng dụng. Bình thường.
- `Activity / *Main` (`WalWriterMain`, `CheckpointerMain`...) — process nền đang ngủ. Bình thường. **Luôn lọc bỏ `backend_type != 'client backend'` khi phân tích**, nếu không bảng xếp hạng của bạn sẽ toàn rác.

### Làm ngay

Ở **S1**:
```sql
SELECT pid, backend_type, state, wait_event_type, wait_event,
       now()-state_change AS trong_state, substring(query,1,50) AS q
FROM pg_stat_activity ORDER BY backend_type, pid;
```

**Ghi vào writeup:** lab đang có mấy backend, mỗi loại `backend_type` bao nhiêu cái, và mỗi cái đang chờ gì lúc "không có tải".

---

## §2. Tự dựng một wait event sampler

### Lý thuyết

`pg_stat_activity` là **ảnh chụp tức thời**. Một lần nhìn không nói lên gì. Công cụ thật (pg_wait_sampling, RDS Performance Insights, pgAnalyze) đều làm cùng một việc: **lấy mẫu liên tục rồi đếm tần suất** — hệt như CPU profiler ở Tier 2.

Ta tự viết bản thô: lấy mẫu 20 lần/giây, ghi vào bảng, rồi xếp hạng.

### Làm ngay

Ở **S1**, tạo bộ lấy mẫu:

```sql
CREATE TABLE IF NOT EXISTS wait_samples (
  t timestamptz, pid int, state text, wet text, we text, query text
);
TRUNCATE wait_samples;

CREATE OR REPLACE PROCEDURE sample_waits(seconds int) LANGUAGE plpgsql AS $$
DECLARE deadline timestamptz := clock_timestamp() + make_interval(secs => seconds);
BEGIN
  WHILE clock_timestamp() < deadline LOOP
    INSERT INTO wait_samples
    SELECT clock_timestamp(), pid, state, wait_event_type, wait_event, substring(query,1,60)
    FROM pg_stat_activity
    WHERE backend_type = 'client backend' AND pid <> pg_backend_pid() AND state <> 'idle';
    COMMIT;
    PERFORM pg_sleep(0.05);
  END LOOP;
END $$;
```

Ở **S2**, chuẩn bị một tải nặng I/O (đừng chạy vội):
```sql
SELECT key_id, count(*), avg(dbl_v) FROM ts_kv GROUP BY key_id ORDER BY 2 DESC;
```

Trình tự: gõ lệnh ở **S1** trước, rồi lập tức chạy ở **S2**.
```sql
-- S1
CALL sample_waits(25);
```

Xong thì xếp hạng ở **S1**:
```sql
SELECT coalesce(wet,'(chạy trên CPU)') AS loai, coalesce(we,'-') AS su_kien,
       count(*) AS mau,
       round(100.0*count(*)/sum(count(*)) OVER (), 1) AS pct
FROM wait_samples WHERE state = 'active'
GROUP BY 1,2 ORDER BY mau DESC;
```

**Ghi vào writeup:** bảng xếp hạng. Bao nhiêu % thời gian query đó **thật sự chạy trên CPU** (wait_event NULL), bao nhiêu % là chờ?

---

## §3. Bảng tra: nhóm wait event nào ứng với bệnh gì

### Lý thuyết

| `wait_event_type` | Nghĩa | Ví dụ hay gặp | Hướng xử lý |
|---|---|---|---|
| `IO` | đọc/ghi file | `DataFileRead`, `DataFileWrite`, `WALWrite`, `WALSync` | thiếu RAM/cache, đĩa chậm, checkpoint dồn |
| `Lock` | **lock cấp hàng/bảng** (do SQL của bạn) | `transactionid`, `tuple`, `relation` | tranh chấp business logic → Day 28–30 |
| `LWLock` | lock nội bộ engine | `BufferMapping`, `WALWrite`, `LockManager` | thường là triệu chứng, không phải nguyên nhân |
| `Client` | chờ **ứng dụng** | `ClientRead` | app chậm gửi lệnh, hoặc `idle in transaction` |
| `IPC` | chờ process khác | `ParallelFinish`, `MessageQueueSend` | parallel worker mất cân bằng |
| `Timeout` | ngủ có chủ đích | `VacuumDelay`, `PgSleep` | thường vô hại |
| `BufferPin` | chờ buffer được nhả | `BufferPin` | hiếm; thường do cursor mở lâu |

Quy tắc đọc:
- `Lock` nhiều → **lỗi thiết kế transaction**, không phải thiếu phần cứng. Thêm CPU không cứu được.
- `IO / DataFileRead` nhiều → working set lớn hơn `shared_buffers`, hoặc query đọc thừa (thiếu index — về lại tuần 1–2).
- `Client / ClientRead` trên backend **active** → thủ phạm là ứng dụng, không phải DB. Đây là phát hiện quý nhất mà bảng này cho bạn.
- `LWLock` nhiều → đừng tối ưu LWLock; tìm cái gây ra nó.

### Làm ngay

Xác nhận nhóm `IO` bằng số của Day 03:
```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT key_id, count(*), avg(dbl_v) FROM ts_kv GROUP BY key_id;
```

**Ghi vào writeup:** nối hai nguồn dữ liệu — `shared read` trong plan và tỷ lệ `IO/DataFileRead` trong sampler. Chúng có kể cùng một câu chuyện không?

---

## §4. Ba kịch bản — nhận diện bằng wait event

### Làm ngay — kịch bản 1: tranh chấp lock

**S1:** `CALL sample_waits(30);`
**S2:**
```sql
BEGIN; UPDATE device SET firmware='v9' WHERE id = 1;   -- giữ, chưa commit
```
**Terminal thứ 3** (mở thêm `make s2`):
```sql
UPDATE device SET firmware='v8' WHERE id = 1;   -- sẽ treo
```
Sau ~30s: `ROLLBACK` ở cả hai.

```sql
-- S1: xem lại mẫu
SELECT wet, we, count(*) FROM wait_samples WHERE state='active' GROUP BY 1,2 ORDER BY 3 DESC;
```
Và query "ai chặn ai" (đối chiếu với Day 29):
```sql
SELECT a.pid, a.wait_event_type, a.wait_event, pg_blocking_pids(a.pid) AS bi_chan_boi,
       substring(a.query,1,60) AS q
FROM pg_stat_activity a WHERE cardinality(pg_blocking_pids(a.pid)) > 0;
```

### Làm ngay — kịch bản 2: WAL / fsync

**S1:** `TRUNCATE wait_samples; CALL sample_waits(25);`
**S2:**
```sql
SET synchronous_commit = on;
DO $$ BEGIN FOR i IN 1..3000 LOOP
  INSERT INTO device_attr VALUES (1,'server','k'||i,'v'); COMMIT; END LOOP; END $$;
```
Đây là mẫu "commit từng dòng" — đúng cách ORM hay sinh ra.

Lặp lại với `SET synchronous_commit = off;` (nhớ `DELETE FROM device_attr WHERE key LIKE 'k%';` giữa hai lần).

**Ghi vào writeup — bảng:** `synchronous_commit` | thời gian | top 3 wait event | tỷ lệ `WALSync`.

### Làm ngay — kịch bản 3: thủ phạm là ứng dụng

**S2:**
```sql
BEGIN;
SELECT count(*) FROM device;
-- rồi KHÔNG làm gì trong 60 giây (mô phỏng app gọi API bên ngoài giữa transaction)
```
**S1:**
```sql
SELECT pid, state, wait_event_type, wait_event,
       now()-xact_start AS transaction_mo, now()-state_change AS trong_state
FROM pg_stat_activity WHERE state LIKE 'idle in transaction%';
```

**Ghi vào writeup:** ba kịch bản cho ba chữ ký wait event khác hẳn nhau. Ghi lại chữ ký của từng cái — đây là thứ bạn sẽ dùng để chẩn đoán 30 giây đầu của một sự cố thật.

---

## §5. `idle in transaction` — kẻ giết thầm lặng

### Lý thuyết

Một transaction mở (dù không làm gì) giữ lại **snapshot** của nó. Hệ quả dây chuyền, nối thẳng vào tuần 5:

1. `xmin horizon` bị ghim → **VACUUM không thể dọn** dead tuple mới hơn snapshot đó, **trên toàn bộ database**.
2. Bảng phình (Day 22), index phình (Day 10), plan xấu đi.
3. Nếu transaction đã lấy lock (dù chỉ `SELECT ... FOR UPDATE` hay một `UPDATE` nhỏ) → chặn người khác vô thời hạn.
4. Ở Repeatable Read/Serializable còn tệ hơn: snapshot giữ từ câu lệnh đầu.

Nguyên nhân thường gặp trong code kiểu bạn đang viết: `@Transactional` bọc cả một lời gọi HTTP ra ngoài; hoặc mở transaction rồi chờ Temporal/Kafka trả lời.

Thuốc:
```sql
ALTER SYSTEM SET idle_in_transaction_session_timeout = '60s';   -- giết session mở transaction mà rỗi
ALTER SYSTEM SET statement_timeout = '30s';                     -- đặt ở tầng app/role, không phải toàn cục mù quáng
```

### Làm ngay

Với session `idle in transaction` ở §4 vẫn đang mở, ở **S1**:
```sql
SELECT backend_xmin, age(backend_xmin) AS tuoi, state, now()-xact_start AS mo_bao_lau, pid
FROM pg_stat_activity WHERE backend_xmin IS NOT NULL ORDER BY age(backend_xmin) DESC;

-- horizon toàn hệ
SELECT pg_snapshot_xmin(pg_current_snapshot()) AS xmin_horizon;
```

Chứng minh nó chặn VACUUM:
```sql
-- S1
CREATE TABLE t_block AS SELECT g AS id, repeat('x',100) AS pad FROM generate_series(1,200000) g;
DELETE FROM t_block WHERE id % 2 = 0;
VACUUM (VERBOSE) t_block;
SELECT n_dead_tup FROM pg_stat_user_tables WHERE relname='t_block';
```
Chú ý dòng `VERBOSE`: `dead row versions cannot be removed yet, oldest xmin: ...`.

Rồi `COMMIT` ở S2, `VACUUM (VERBOSE) t_block;` lại và so.

**Ghi vào writeup:** `n_dead_tup` trước/sau khi commit session kia. Dán dòng `oldest xmin` của VACUUM. **Một session idle in transaction ở service A có thể làm phình bảng của service B trên cùng cluster — giải thích cơ chế bằng 3 câu.**

---

## §6. Nối wait event với query

### Làm ngay

```sql
SELECT substring(query,1,60) AS q, wet, we, count(*) AS mau
FROM wait_samples WHERE state='active' AND query IS NOT NULL
GROUP BY 1,2,3 ORDER BY mau DESC LIMIT 15;
```

**Ghi vào writeup:** query nào chờ nhiều nhất, chờ **cái gì**? So với bảng top `pg_stat_statements` (Day 05) — hai bảng có chỉ vào cùng một query không? Nếu **không**, giải thích tại sao (gợi ý: một query chạy 1 lần 10 giây và một query chạy 10.000 lần mỗi lần 1ms xuất hiện khác nhau trong sampler thế nào).

### Dọn dẹp

```sql
DROP PROCEDURE sample_waits(int);
DROP TABLE wait_samples, t_block;
DELETE FROM device_attr WHERE key LIKE 'k%';
```

---

## §7. Ôn tuần 8 — quy trình 30 giây đầu

### Làm ngay

Viết vào writeup **quy trình chẩn đoán của riêng bạn**, tối đa 8 bước, mỗi bước một lệnh chạy được. Khung gợi ý — bạn phải điền lệnh thật và ngưỡng thật:

| # | Câu hỏi | Lệnh | Nếu bất thường thì đi đâu |
|---|---|---|---|
| 1 | Có bao nhiêu backend active / chờ? | | |
| 2 | Hệ đang chờ nhóm gì? | | |
| 3 | Có ai bị chặn không? | | |
| 4 | Có `idle in transaction` lâu không? | | Day 40 §5 |
| 5 | Replication lag / slot? | | Day 38, Day 39 |
| 6 | Query nào nặng nhất? | | Day 05 |
| 7 | Vacuum có theo kịp không? | | Day 22–23 |
| 8 | Checkpoint có dồn không? | | Day 37 |

Rồi tổng kết tuần 8 (Day 36–40):

- **3 con số** bạn đo được tuần này mà trước đây bạn chỉ đoán.
- **1 thứ trong hệ thật của bạn** giờ bạn tin là đang sai, và bằng chứng bạn sẽ đi lấy.

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?** (đặc biệt câu 1 và câu 4)

**B. Áp dụng vào hệ thật:** chạy trên production (chỉ đọc, an toàn):
```sql
SELECT state, wait_event_type, wait_event, count(*)
FROM pg_stat_activity WHERE backend_type='client backend'
GROUP BY 1,2,3 ORDER BY 4 DESC;

SELECT count(*) FILTER (WHERE state='idle in transaction') AS iit,
       max(now()-xact_start) FILTER (WHERE state='idle in transaction') AS iit_lau_nhat
FROM pg_stat_activity;
```
Có session `idle in transaction` nào không? Lâu nhất bao nhiêu? Truy ngược ra đoạn code nào mở nó. Bạn sẽ đặt `idle_in_transaction_session_timeout` bao nhiêu và ở tầng nào (toàn cục / theo role / theo connection của app)?

### Đạt khi

Bạn phân biệt được `active` với "đang dùng CPU", đọc một bảng wait event và nói được bệnh nằm ở đĩa / lock / ứng dụng, và giải thích được đường dây từ `idle in transaction` tới bloat toàn database.

**Xong thì gõ `/review-bai`.**
