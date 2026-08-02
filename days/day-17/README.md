# Day 17 — Hash Join & `work_mem`

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

```sql
\timing on
\o /days/day-17/output.txt
ANALYZE;
```

---

## §0. Đoán trước

1. `work_mem = 4MB` thì hash join `ts_kv × device` sinh bao nhiêu `Batches`?
2. `Batches = 8` đắt hơn `Batches = 1` bao nhiêu lần?
3. Planner chọn bảng nào làm build side, dựa vào gì?

---

## §1. Hash join hoạt động thế nào

### Lý thuyết

Hai pha:

```
PHA 1 — BUILD:  đọc toàn bộ bảng NHỎ, dựng hash table trên join key trong RAM
PHA 2 — PROBE:  đọc bảng LỚN từng dòng, băm key, tra hash table, ghép
```

```
Hash Join  (actual rows=5000000 loops=1)
  Hash Cond: (k.device_id = d.id)
  ->  Seq Scan on ts_kv k        ← PROBE side (bảng lớn), luôn ở dưới trước
  ->  Hash  (actual rows=50000 loops=1)
        Buckets: 65536  Batches: 1  Memory Usage: 3552kB
        ->  Seq Scan on device d ← BUILD side (bảng nhỏ)
```

Đọc plan hash join: **node `Hash` bọc build side.** Node còn lại là probe side.

Ưu điểm: mỗi bảng chỉ đọc **một lần** → `O(N + M)`. Không cần index. Không cần sắp xếp.
Nhược điểm: cần RAM chứa hash table, và **chỉ dùng được cho điều kiện `=`** (không dùng được cho `<`, `>`, `BETWEEN`).

### Làm ngay

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ts_kv k JOIN device d ON d.id = k.device_id;
```

**Ghi vào writeup:** bảng nào là build side, bảng nào là probe? `Buckets`, `Batches`, `Memory Usage` bằng bao nhiêu?

Thử join không phải `=`:
```sql
EXPLAIN SELECT count(*) FROM device d JOIN tenant t ON d.tenant_id > t.id;
```
**Ghi vào writeup:** planner chọn gì? Vì sao không thể hash join?

---

## §2. `work_mem` — giới hạn quyết định

### Lý thuyết

`work_mem` là giới hạn RAM cho **một node** cần bộ nhớ (sort, hash join, hash agg, bitmap, memoize).

Ba chữ phải thuộc lòng:

> **`work_mem` là per NODE, per CONNECTION, per WORKER.**

Một query có 3 node sort + 1 hash join, chạy parallel 2 worker, với 100 connection:
```
worst case = 4 node × 3 process × 100 conn × work_mem
```
Với `work_mem = 64MB` → **76 GB**. Đây là cách người ta OOM một server Postgres.

Quy tắc khởi điểm an toàn: `work_mem ≈ RAM ÷ (max_connections × 3)`. Rồi nâng riêng cho session chạy báo cáo:
```sql
SET LOCAL work_mem = '256MB';   -- chỉ trong transaction này
```

### Làm ngay

```sql
SHOW work_mem;
SHOW max_connections;
```

**Ghi vào writeup:** tính worst case bộ nhớ cho cấu hình lab. Rồi tính cho cấu hình production của bạn.

---

## §3. Batches — khi hash table không vừa RAM

### Lý thuyết

Nếu build side lớn hơn `work_mem`, Postgres chia thành nhiều **batch**:

```
Batch 0: giữ trong RAM
Batch 1..N-1: ghi ra FILE TẠM cả build side lẫn probe side
        ↓
Xử lý xong batch 0 → đọc batch 1 từ đĩa vào RAM → probe → batch 2 → ...
```

Chi phí thật của việc chia batch:
1. Build side phải **ghi ra đĩa rồi đọc lại**
2. **Probe side cũng vậy** — đây là phần đắt bị nhiều người quên, vì probe side thường là bảng lớn
3. Băm hai lần (một lần để chia batch, một lần để tra)

Nên `Batches: 8` **đắt hơn nhiều so với tỷ lệ 8×** — vì bảng 5 triệu dòng ở probe side phải đi qua đĩa một vòng.

Số batch luôn là luỹ thừa của 2. Nếu thấy `Batches` tăng giữa chừng (`Original Batches` khác `Batches`), nghĩa là planner ước lượng thiếu và phải chia lại lúc đang chạy — dấu hiệu ước lượng sai.

### Làm ngay

```sql
-- build side lớn: ép device làm probe, ts_kv làm build bằng cách join có lọc
SET work_mem = '1MB';
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ts_kv k JOIN device d ON d.id = k.device_id
WHERE k.ts >= '2025-06-01' AND k.ts < '2025-06-05';

SET work_mem = '4MB';
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ts_kv k JOIN device d ON d.id = k.device_id
WHERE k.ts >= '2025-06-01' AND k.ts < '2025-06-05';

SET work_mem = '64MB';
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ts_kv k JOIN device d ON d.id = k.device_id
WHERE k.ts >= '2025-06-01' AND k.ts < '2025-06-05';

SET work_mem = '256MB';
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ts_kv k JOIN device d ON d.id = k.device_id
WHERE k.ts >= '2025-06-01' AND k.ts < '2025-06-05';
RESET work_mem;
```

**Ghi vào writeup — bảng 4 dòng:** work_mem | Batches | Memory Usage | temp read/written | time.

Rồi: **vì sao `Batches: 8` đắt hơn `Batches: 1` nhiều hơn tỷ lệ 8×?**

---

## §4. Build side — planner chọn thế nào

### Lý thuyết

Planner ước lượng **kích thước byte** của mỗi bên (`rows × width`) rồi chọn bên **nhỏ hơn** làm build.

Điều này có nghĩa: nếu ước lượng sai, planner có thể chọn nhầm bên → hash table khổng lồ → nhiều batch → chậm.

Bạn không ép được build side trực tiếp. Cách gián tiếp: sửa ước lượng (tuần 3), hoặc viết lại query.

### Làm ngay

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv k JOIN device d ON d.id=k.device_id;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM device d JOIN ts_kv k ON d.id=k.device_id;
```

**Ghi vào writeup:** đổi thứ tự viết trong SQL có làm đổi build side không? Điều đó nói gì về việc "viết bảng nhỏ trước cho nhanh"?

Ép một tình huống chọn sai:
```sql
-- lọc device rất chặt nhưng statistics kém -> ước lượng sai kích thước build side
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ts_kv k JOIN device d ON d.id = k.device_id
WHERE d.region='ap-southeast' AND d.country='VN' AND d.type='controller';
```
**Ghi vào writeup:** `Hash` node ước lượng bao nhiêu rows vs thật? `Memory Usage` có khớp dự đoán không?

---

## §5. Hash collision và `Buckets`

### Lý thuyết

`Buckets` là số ngăn trong hash table. Postgres chọn sao cho trung bình mỗi bucket ~1 dòng.

Nếu join key có **nhiều giá trị trùng** (ví dụ join theo `key_id` chỉ có 8 giá trị), mọi dòng dồn vào 8 bucket → mỗi bucket thành một danh sách dài → probe phải duyệt tuyến tính. Hash join thoái hoá về gần `O(N × M)`.

Đây là lý do **hash join tệ khi join key có ít giá trị phân biệt**.

### Làm ngay

```sql
CREATE TABLE keys_small AS SELECT DISTINCT key_id FROM ts_kv;
ANALYZE keys_small;

EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ts_kv k JOIN keys_small s ON s.key_id = k.key_id;

EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ts_kv k JOIN device d ON d.id = k.device_id;
```

**Ghi vào writeup:** so `Buckets` và thời gian giữa join theo `key_id` (8 giá trị) và theo `device_id` (50.000 giá trị). Cùng số dòng probe, vì sao khác nhau?

```sql
DROP TABLE keys_small;
```

---

## §6. Parallel Hash Join

### Lý thuyết

Từ PG11, hash table có thể **dùng chung** giữa các worker (`Parallel Hash`). Mỗi worker góp phần build, rồi tất cả cùng probe.

Quan trọng: với `Parallel Hash`, giới hạn bộ nhớ là `work_mem × số_worker` chứ không phải `work_mem` — vì hash table nằm trong shared memory. Plan sẽ ghi `Parallel Hash` thay vì `Hash`.

### Làm ngay

```sql
SET max_parallel_workers_per_gather = 0;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv k JOIN device d ON d.id=k.device_id;

SET max_parallel_workers_per_gather = 4;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv k JOIN device d ON d.id=k.device_id;
RESET max_parallel_workers_per_gather;
```

**Ghi vào writeup:** node là `Hash` hay `Parallel Hash`? Thời gian giảm bao nhiêu? `Memory Usage` đổi thế nào?

---

## §7. Chiến lược `work_mem` cho hệ thật

### Lý thuyết

Không có một giá trị đúng cho mọi query. Chiến lược tốt:

1. Đặt `work_mem` toàn cục **thấp** và an toàn (4–16MB)
2. Tìm query hay spill bằng `pg_stat_statements.temp_blks_written` (Day 05)
3. Với các query đó, nâng riêng bằng `SET LOCAL work_mem` trong transaction, hoặc đặt theo role:
```sql
ALTER ROLE report_user SET work_mem = '256MB';
```
4. Với worker chạy báo cáo, tách hẳn ra một connection pool riêng có `work_mem` cao

**Không bao giờ** nâng `work_mem` toàn cục lên vài trăm MB để "cho chắc".

### Làm ngay

```sql
SELECT substring(query,1,60) AS q, calls, temp_blks_written,
       pg_size_pretty(temp_blks_written*8192::bigint) AS temp
FROM pg_stat_statements WHERE temp_blks_written > 0
ORDER BY temp_blks_written DESC LIMIT 10;
```

Thử `SET LOCAL`:
```sql
BEGIN;
SET LOCAL work_mem = '256MB';
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM ts_kv k JOIN device d ON d.id=k.device_id
WHERE k.ts >= '2025-06-01' AND k.ts < '2025-06-05';
COMMIT;
SHOW work_mem;   -- đã về mặc định chưa?
```

**Ghi vào writeup:** query nào spill nhiều nhất? Nếu nâng `work_mem` cho riêng nó thì tiết kiệm bao nhiêu?

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B. Áp dụng vào hệ thật:** tính worst case bộ nhớ `work_mem` cho DB production của bạn (max_connections × work_mem × số node ước lượng). Con số đó so với RAM của máy thế nào? Bạn sẽ đổi gì?

### Đạt khi

Bạn nhìn `Batches > 1` là biết ngay phải làm gì, và giải thích được vì sao `work_mem` là per-node-per-worker chứ không phải per-query.

**Xong thì gõ `/review-bai`.**
