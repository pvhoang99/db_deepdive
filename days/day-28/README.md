# Day 28 — Lock tường minh, `SKIP LOCKED` và hàng đợi trong DB

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

Hai terminal: `make s1`, `make s2` (mục §5 cần 4 terminal).

**S1:**
```sql
DROP TABLE IF EXISTS jobq;
CREATE TABLE jobq (
  id bigserial PRIMARY KEY,
  payload text,
  status text NOT NULL DEFAULT 'PENDING',
  locked_by text,
  created_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO jobq (payload) SELECT 'job-'||g FROM generate_series(1, 10000) g;
CREATE INDEX ON jobq (created_at) WHERE status = 'PENDING';
ANALYZE jobq;
```

---

## §0. Đoán trước

1. Bốn worker cùng chạy `SELECT ... FOR UPDATE LIMIT 1` — chuyện gì xảy ra?
2. Thêm `SKIP LOCKED` thì sao?
3. Hàng đợi trong Postgres chịu được bao nhiêu job/giây trước khi vỡ?

---

## §1. Bốn kiểu row lock

### Lý thuyết

| Cú pháp | Chặn | Dùng khi |
|---|---|---|
| `FOR UPDATE` | mọi lock khác trên dòng đó | sắp sửa hoặc xoá dòng |
| `FOR NO KEY UPDATE` | như trên trừ `FOR KEY SHARE` | update nhưng không đụng khoá |
| `FOR SHARE` | các lock ghi | đọc và đảm bảo dòng không đổi |
| `FOR KEY SHARE` | chỉ `FOR UPDATE` | dùng ngầm bởi khoá ngoại |

Ma trận xung đột (X = chặn nhau):

| | KEY SHARE | SHARE | NO KEY UPDATE | UPDATE |
|---|---|---|---|---|
| **KEY SHARE** | | | | X |
| **SHARE** | | | X | X |
| **NO KEY UPDATE** | | X | X | X |
| **UPDATE** | X | X | X | X |

Điểm hay bị bỏ qua: khi bạn `INSERT` vào bảng con có khoá ngoại, Postgres tự lấy `FOR KEY SHARE` trên dòng cha. Nếu chỗ khác đang `FOR UPDATE` dòng cha đó, `INSERT` của bạn bị chặn. Đây là nguồn contention âm thầm trong hệ có nhiều FK.

Ba biến thể chờ:
- mặc định: **chờ vô hạn**
- `NOWAIT`: lỗi ngay nếu không lấy được
- `SKIP LOCKED`: **bỏ qua** dòng đang bị khoá, lấy dòng khác

### Làm ngay

**S1:**
```sql
BEGIN;
SELECT id, payload FROM jobq WHERE id = 1 FOR UPDATE;
```
**S2:** thử lần lượt từng biến thể (mỗi lần `ROLLBACK` trước khi thử cái tiếp):
```sql
BEGIN; SELECT id FROM jobq WHERE id = 1 FOR UPDATE;              -- chờ
-- Ctrl+C rồi:
BEGIN; SELECT id FROM jobq WHERE id = 1 FOR UPDATE NOWAIT;       -- lỗi gì?
ROLLBACK;
BEGIN; SELECT id FROM jobq WHERE id = 1 FOR SHARE;               -- chờ hay không?
ROLLBACK;
BEGIN; SELECT id FROM jobq WHERE id = 2 FOR UPDATE;              -- dòng khác, có chờ không?
ROLLBACK;
```
**S1:** `ROLLBACK;`

**Ghi vào writeup:** `NOWAIT` báo lỗi gì (SQLSTATE)? `FOR SHARE` có bị `FOR UPDATE` chặn không? Khớp với ma trận trên chứ?

---

## §2. Xem ai đang khoá ai

### Lý thuyết

`pg_locks` liệt kê mọi lock. Kết hợp với `pg_stat_activity` để biết ai chờ ai.

Từ PG9.6 có hàm tiện hơn nhiều: **`pg_blocking_pids(pid)`** trả về mảng PID đang chặn PID đó.

### Làm ngay

**S1:**
```sql
BEGIN;
SELECT * FROM jobq WHERE id = 1 FOR UPDATE;
```
**S2:**
```sql
BEGIN;
SELECT * FROM jobq WHERE id = 1 FOR UPDATE;   -- sẽ treo
```
**Terminal thứ 3** (hoặc dùng `make psql`):
```sql
SELECT a.pid, a.state, pg_blocking_pids(a.pid) AS bi_chan_boi,
       now()-a.query_start AS cho_bao_lau, left(a.query,60) AS query
FROM pg_stat_activity a
WHERE a.datname = current_database() AND a.pid <> pg_backend_pid()
ORDER BY a.query_start;

SELECT locktype, relation::regclass, page, tuple, transactionid,
       mode, granted, pid
FROM pg_locks WHERE NOT granted OR relation = 'jobq'::regclass;
```

**Ghi vào writeup:** dán kết quả. Lock đang chờ có `locktype` gì? (gợi ý: nó chờ trên `transactionid` chứ không phải trên `tuple` — vì sao?)

**S1, S2:** `ROLLBACK;`

---

## §3. Vì sao `FOR UPDATE` không đủ để làm hàng đợi

### Lý thuyết

```sql
BEGIN;
SELECT * FROM jobq WHERE status='PENDING' ORDER BY created_at LIMIT 1 FOR UPDATE;
UPDATE jobq SET status='RUNNING' WHERE id = <id>;
COMMIT;
```

Với 4 worker: cả 4 đều nhắm vào **cùng một dòng đầu tiên**. Worker 1 khoá được, 3 worker còn lại **xếp hàng chờ**. Xong worker 1, worker 2 đọc lại thấy dòng đã `RUNNING`... nhưng nó vẫn phải chờ hết.

Kết quả: **hàng đợi bị tuần tự hoá hoàn toàn** — 4 worker không nhanh hơn 1 worker chút nào.

### Làm ngay

**S1:**
```sql
BEGIN;
SELECT id, payload FROM jobq WHERE status='PENDING' ORDER BY created_at LIMIT 1 FOR UPDATE;
```
**S2:**
```sql
\timing on
BEGIN;
SELECT id, payload FROM jobq WHERE status='PENDING' ORDER BY created_at LIMIT 1 FOR UPDATE;
```
S2 treo. **S1:** `COMMIT;` — S2 mới chạy được.

**Ghi vào writeup:** S2 chờ bao lâu? S2 lấy được job nào — cùng job với S1 hay khác?

---

## §4. `SKIP LOCKED` — lời giải

### Lý thuyết

```sql
SELECT * FROM jobq WHERE status='PENDING' ORDER BY created_at LIMIT 1
FOR UPDATE SKIP LOCKED;
```

Nếu dòng đầu đang bị khoá, **bỏ qua** và lấy dòng tiếp theo. Không chờ, không xung đột.

Đây là tính năng làm Postgres trở thành một job queue dùng được thật (có từ PG9.5). Nó là nền của rất nhiều thư viện: `pg-boss`, `Que`, `SolidQueue`, `graphile-worker`, và cả phần task queue của một số hệ workflow.

Mẫu chuẩn — gộp SELECT và UPDATE thành một câu:
```sql
UPDATE jobq SET status='RUNNING', locked_by = 'worker-1'
WHERE id = (
  SELECT id FROM jobq WHERE status='PENDING'
  ORDER BY created_at LIMIT 1
  FOR UPDATE SKIP LOCKED
)
RETURNING id, payload;
```

Một câu lệnh, atomic, không cần transaction dài.

### Làm ngay

**S1:**
```sql
BEGIN;
SELECT id FROM jobq WHERE status='PENDING' ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED;
```
**S2:**
```sql
BEGIN;
SELECT id FROM jobq WHERE status='PENDING' ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED;
```

**Ghi vào writeup:** S2 có chờ không? Hai session lấy được id giống hay khác nhau?

**S1, S2:** `ROLLBACK;`

---

## §5. Chứng minh không trùng job — 4 worker song song

### Làm ngay

Mở **4 terminal**, mỗi cái chạy:
```bash
docker exec -i pgdd psql -U postgres -d lab -c "
DO \$\$
DECLARE r record; n int := 0;
BEGIN
  LOOP
    UPDATE jobq SET status='RUNNING', locked_by = 'w-'||pg_backend_pid()
    WHERE id = (SELECT id FROM jobq WHERE status='PENDING'
                ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED)
    RETURNING id INTO r;
    EXIT WHEN r IS NULL;
    n := n + 1;
    EXIT WHEN n >= 2500;
  END LOOP;
  RAISE NOTICE 'worker % xu ly % job', pg_backend_pid(), n;
END \$\$;"
```

Chạy cả 4 gần như đồng thời. Rồi kiểm tra:
```sql
SELECT locked_by, count(*) FROM jobq WHERE status='RUNNING' GROUP BY 1 ORDER BY 1;
SELECT count(*) FROM jobq WHERE status='RUNNING';
SELECT count(DISTINCT id) FROM jobq WHERE status='RUNNING';
```

**Ghi vào writeup:** tổng job đã xử lý = tổng của các worker? Có job nào bị xử lý hai lần không (so `count(*)` với `count(DISTINCT id)`)? Mỗi worker lấy được bao nhiêu — có cân bằng không?

---

## §6. Advisory lock — khoá không gắn với dòng nào

### Lý thuyết

Advisory lock là khoá **do ứng dụng tự đặt tên**, Postgres chỉ giữ hộ. Không gắn với bảng hay dòng nào.

| Hàm | Phạm vi | Nhả khi |
|---|---|---|
| `pg_advisory_lock(key)` | session | gọi `pg_advisory_unlock` hoặc đóng session |
| `pg_advisory_xact_lock(key)` | transaction | **tự nhả khi commit/rollback** |
| `pg_try_advisory_lock(key)` | session | không chờ, trả `false` nếu bận |

**Luôn ưu tiên bản `_xact_`** — bản session-level rất dễ rò rỉ khi dùng với connection pool (connection trả về pool mà lock vẫn giữ → deadlock ngầm cho request sau).

Dùng cho: leader election, đảm bảo một job chỉ chạy một instance, tuần tự hoá theo khoá nghiệp vụ (materializing conflict — Day 27 §4), migration lock.

Key là `bigint` hoặc hai `int`. Thường băm từ chuỗi: `hashtext('job:daily-report')`.

### Làm ngay

**S1:**
```sql
BEGIN;
SELECT pg_advisory_xact_lock(hashtext('job:daily-report'));
SELECT 'S1 dang chay job';
```
**S2:**
```sql
BEGIN;
SELECT pg_try_advisory_xact_lock(hashtext('job:daily-report'));   -- true hay false?
SELECT pg_advisory_xact_lock(hashtext('job:daily-report'));       -- treo
```
**S1:** `COMMIT;` — S2 chạy tiếp.

Xem advisory lock đang giữ:
```sql
SELECT locktype, objid, mode, granted, pid FROM pg_locks WHERE locktype = 'advisory';
```

**S2:** `COMMIT;`

**Ghi vào writeup:** `pg_try_advisory_xact_lock` trả về gì khi bị chiếm? Nêu **hai chỗ** trong hệ của bạn dùng được advisory lock.

---

## §7. Hàng đợi trong DB vỡ ở đâu

### Lý thuyết

`SKIP LOCKED` làm job queue trong Postgres rất khả thi — nhưng có giới hạn:

**Điểm mạnh**
- Transactional với dữ liệu nghiệp vụ — enqueue và cập nhật business data trong **cùng một transaction**. Đây chính là outbox pattern, và là lý do nó đúng.
- Không cần hạ tầng thêm, dùng lại backup/replication/monitoring sẵn có
- Truy vấn được: "còn bao nhiêu job pending" chỉ là một câu SQL

**Vỡ ở đâu**
- **Bloat**: mỗi job là insert + vài update + delete → dead tuple rất nhiều. Cần autovacuum rất hung hăng (Day 23) hoặc partition theo thời gian
- **Throughput**: khoảng vài nghìn job/giây là hợp lý. Trên 10k/s thì WAL và vacuum thành nút thắt
- **Long polling**: worker poll liên tục tạo tải nền. Dùng `LISTEN/NOTIFY` để giảm
- **Fan-out**: mỗi message tới nhiều consumer thì Kafka hợp hơn
- **Lưu trữ lâu**: Kafka giữ được log nhiều ngày, DB queue thì bạn phải tự dọn

**Quy tắc chọn:** dùng DB queue khi job gắn chặt với transaction nghiệp vụ và throughput dưới vài nghìn/giây. Dùng Kafka khi cần fan-out, replay, hoặc throughput cao. **Outbox pattern là cầu nối đúng** — ghi vào DB trong transaction, một process đọc outbox rồi đẩy sang Kafka.

### Làm ngay

Đo bloat của bảng queue sau khi xử lý:
```sql
SELECT n_live_tup, n_dead_tup, n_tup_upd, n_tup_hot_upd,
       pg_size_pretty(pg_total_relation_size('jobq')) AS size
FROM pg_stat_user_tables WHERE relname='jobq';

SELECT dead_tuple_percent, free_percent FROM pgstattuple('jobq');
```

Đo throughput:
```sql
-- reset rồi đo thời gian xử lý 10000 job bằng 1 worker
UPDATE jobq SET status='PENDING', locked_by=NULL;
VACUUM ANALYZE jobq;
\timing on
DO $$ DECLARE r record; n int := 0;
BEGIN
  LOOP
    UPDATE jobq SET status='DONE' WHERE id = (
      SELECT id FROM jobq WHERE status='PENDING' ORDER BY created_at LIMIT 1
      FOR UPDATE SKIP LOCKED) RETURNING id INTO r;
    EXIT WHEN r IS NULL; n := n+1;
  END LOOP;
  RAISE NOTICE 'xu ly % job', n;
END $$;
```

**Ghi vào writeup:** throughput bao nhiêu job/giây với 1 worker? Bảng bloat bao nhiêu %? Với số liệu này, ngưỡng nào bạn sẽ chuyển sang Kafka?

```sql
DROP TABLE jobq;
```

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B. Áp dụng vào hệ thật:** outbox pattern của bạn đang đọc bảng outbox thế nào — có dùng `SKIP LOCKED` không? Nếu nhiều instance cùng chạy, chúng có tranh nhau không? Bảng outbox có được autovacuum đủ hung hăng không (kiểm tra `reloptions`)?

### Đạt khi

Bạn giải thích được vì sao `SKIP LOCKED` là cách đúng để làm queue trong DB, đo được throughput thật, và biết ngưỡng nào nó vỡ.

**Xong thì gõ `/review-bai`.**
