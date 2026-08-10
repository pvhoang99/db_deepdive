# Day 28 — Lời giải: Lock tường minh, `SKIP LOCKED` và hàng đợi trong DB

> Bài chữa. Đo thật bằng **hai đến bốn session psql song song**.

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án |
|---|---|---|
| 1 | 4 worker cùng `SELECT ... FOR UPDATE LIMIT 1` | Cả 4 nhắm **cùng một dòng** → xếp hàng → **tuần tự hoá hoàn toàn**, 4 worker không nhanh hơn 1 |
| 2 | Thêm `SKIP LOCKED`? | Mỗi worker lấy **dòng khác nhau**, không chờ. Đo được: 4 worker × 2.500 job, **0 job trùng** |
| 3 | Chịu được bao nhiêu job/giây? | **~2.534 job/s** với 1 worker và partial index. **701 job/s** nếu thiếu index |

---

## §1. Bốn kiểu row lock

| Thử nghiệm | Kết quả |
|---|---|
| S1 `FOR UPDATE` id=1, S2 `FOR UPDATE NOWAIT` id=1 | **`ERROR: could not obtain lock on row in relation "jobq"`** |
| S2 `FOR SHARE NOWAIT` id=1 | **cùng lỗi** — `FOR SHARE` **bị** `FOR UPDATE` chặn ✅ khớp ma trận |
| S2 `FOR UPDATE NOWAIT` id=**2** | **thành công** — khoá ở cấp **dòng**, không phải bảng |

SQLSTATE của `NOWAIT` là **`55P03` (lock_not_available)**.

### Ma trận xung đột — đã kiểm chứng

| | KEY SHARE | SHARE | NO KEY UPDATE | UPDATE |
|---|---|---|---|---|
| **KEY SHARE** | | | | ✗ |
| **SHARE** | | | ✗ | **✗ (đã đo)** |
| **NO KEY UPDATE** | | ✗ | ✗ | ✗ |
| **UPDATE** | ✗ | ✗ | ✗ | **✗ (đã đo)** |

### ⚠️ Điểm hay bị bỏ qua: khoá ngoại lấy `FOR KEY SHARE` ngầm

Khi `INSERT` vào bảng con có FK, Postgres tự lấy **`FOR KEY SHARE`** trên dòng cha (để đảm bảo cha không bị xoá). Nhìn ma trận: `KEY SHARE` bị chặn bởi `UPDATE`.

```
Transaction A:  SELECT * FROM tenant WHERE id=1 FOR UPDATE;   -- đang sửa tenant
Transaction B:  INSERT INTO device (tenant_id, ...) VALUES (1, ...);   -- BỊ CHẶN
```

**Đây là nguồn contention âm thầm trong hệ có nhiều FK** — một thao tác `UPDATE tenant` chặn mọi `INSERT device` của tenant đó.

Cách giảm: dùng **`FOR NO KEY UPDATE`** thay vì `FOR UPDATE` khi không đụng tới khoá:
```sql
SELECT * FROM tenant WHERE id=1 FOR NO KEY UPDATE;   -- KHÔNG chặn INSERT vào bảng con
```
Và `UPDATE` thường cũng chỉ lấy `FOR NO KEY UPDATE` nếu không sửa cột được tham chiếu — nên vấn đề chủ yếu đến từ `SELECT ... FOR UPDATE` viết tay.

### Ba biến thể chờ

| | Hành vi | SQLSTATE khi thất bại | Dùng khi |
|---|---|---|---|
| mặc định | **chờ vô hạn** | — | tranh chấp hiếm |
| `NOWAIT` | lỗi ngay | **`55P03`** | muốn fail-fast, tự retry ở app |
| **`SKIP LOCKED`** | **bỏ qua dòng bị khoá** | — | **job queue** |

---

## §2. Xem ai đang khoá ai

```
 pid  | state  | bi_chan_boi |                      q
------+--------+-------------+----------------------------------------------
 2378 | active | {2379}      | SELECT id FROM jobq WHERE id = 1 FOR UPDATE;
```

`pg_blocking_pids(pid)` cho biết ngay ai đang chặn — đơn giản hơn nhiều so với tự join `pg_locks`.

### `pg_locks` — và câu hỏi quan trọng

```
   locktype    | relation | page | tuple | transactionid |        mode         | granted | pid
---------------+----------+------+-------+---------------+---------------------+---------+------
 transactionid |          |      |       |          1959 | ShareLock           | f       | 2378   <- ĐANG CHỜ
 relation      | jobq     |      |       |               | RowShareLock        | t       | 2378
 tuple         | jobq     |    0 |     1 |               | AccessExclusiveLock | t       | 2378
 relation      | jobq     |      |       |               | RowShareLock        | t       | 2379
```

### Vì sao nó chờ trên `transactionid`, không phải trên `tuple`

Đây là chi tiết thiết kế quan trọng của Postgres:

**Postgres KHÔNG có bảng khoá dòng trong bộ nhớ.** Nếu có, khoá 1 triệu dòng sẽ tốn 1 triệu entry — không khả thi.

Thay vào đó, khoá dòng được **ghi thẳng vào tuple header** (`xmax` = XID của transaction đang khoá). Khi transaction B muốn khoá dòng đó:

```
① B đọc tuple, thấy xmax = 1959 (transaction A đang giữ)
② B lấy tuple lock (AccessExclusiveLock trên tuple) — chỉ để xếp hàng, tránh đói
③ B CHỜ TRÊN transactionid = 1959  <- chờ chính transaction A kết thúc
④ A commit/rollback -> XID 1959 kết thúc -> B được đánh thức
```

Nên `granted = f` xuất hiện ở dòng `locktype = transactionid`, không phải `tuple`.

> **Hệ quả thực dụng: số lượng row lock trong Postgres là KHÔNG GIỚI HẠN** (khác Oracle/SQL Server có lock escalation). Khoá 10 triệu dòng cũng chỉ tốn 1 entry trong `pg_locks`.
>
> Và `max_locks_per_transaction` chỉ giới hạn khoá cấp **bảng/object**, không phải khoá dòng.

Chú ý dòng `tuple ... AccessExclusiveLock granted=t` — đó là khoá tạm để xếp hàng, đảm bảo nhiều waiter được phục vụ theo thứ tự (tránh starvation).

---

## §3. Vì sao `FOR UPDATE` không đủ để làm hàng đợi

| Bước | S1 | S2 |
|---|---|---|
| | `SELECT ... LIMIT 1 FOR UPDATE` → **id = 1** | |
| | | `SELECT ... LIMIT 1 FOR UPDATE` → **TREO** |
| | `COMMIT;` | |
| | | *(được chạy)* → **id = 1** — **cùng job!** |

**S2 chờ hết thời gian S1 xử lý, rồi lấy về đúng job S1 vừa lấy.**

*(Ở lab S1 chỉ `SELECT` chứ không đổi `status`, nên S2 thấy lại id=1. Trong queue thật S1 sẽ đổi `status='RUNNING'` và S2 sẽ đọc lại thấy nó không còn `PENDING` → phải quét tiếp → vẫn tốn công vô ích.)*

### Vì sao 4 worker không nhanh hơn 1 worker

Mọi worker đều dùng `ORDER BY created_at LIMIT 1` → **tất cả nhắm vào cùng một dòng đầu tiên**.

```
Worker 1: khoá dòng #1, xử lý (100ms)
Worker 2,3,4: xếp hàng chờ dòng #1
Worker 1 commit -> Worker 2 được đánh thức, đọc lại, thấy #1 đã RUNNING
                -> phải chạy lại query, nhắm dòng #2
                -> nhưng Worker 3,4 cũng vậy -> lại xếp hàng
```

**Hàng đợi bị tuần tự hoá hoàn toàn.** Thêm worker chỉ thêm thời gian chờ.

---

## §4 + §5. `SKIP LOCKED` — lời giải

### Hai session, hai job khác nhau

| | Kết quả |
|---|---|
| S1 `... FOR UPDATE SKIP LOCKED` | **id = 1** |
| S2 `... FOR UPDATE SKIP LOCKED` | **id = 2** ✅ **không chờ** |

### Bốn worker song song — chứng minh không trùng job

```
 locked_by | count
-----------+-------
 w-2414    |  2500
 w-2415    |  2500
 w-2416    |  2500
 w-2417    |  2500

 tổng RUNNING | id phân biệt
--------------+--------------
        10000 |        10000      <- BẰNG NHAU: không job nào bị xử lý 2 lần
```

**Cân bằng tuyệt đối (2.500 mỗi worker) và không một job nào trùng.**

*(Con số 2.500 đều nhau là do mỗi worker có `EXIT WHEN n >= 2500`; điều đáng chú ý là cả 4 đều **đạt** được 2.500 — nghĩa là không worker nào bị đói.)*

### Mẫu chuẩn — một câu lệnh, atomic

```sql
UPDATE jobq SET status='RUNNING', locked_by = $1
WHERE id = (
  SELECT id FROM jobq
  WHERE status='PENDING'
  ORDER BY created_at
  LIMIT 1
  FOR UPDATE SKIP LOCKED          -- <<< nằm trong subquery
)
RETURNING id, payload;
```

Ba điểm thiết kế:
1. **Một câu lệnh** → atomic, không cần transaction dài giữ khoá
2. `FOR UPDATE SKIP LOCKED` trong **subquery** — khoá dòng được chọn, rồi UPDATE nó
3. `RETURNING` trả về payload luôn → không cần query thứ hai

> **Đây là nền của mọi thư viện job queue trên Postgres**: `pg-boss`, `Que`, `SolidQueue`, `graphile-worker`, `River`, và phần task queue của nhiều hệ workflow.

---

## §6. Advisory lock

| Thử nghiệm | Kết quả |
|---|---|
| S1 `pg_advisory_xact_lock(hashtext('job:daily-report'))` | ✅ được cấp |
| S2 `pg_try_advisory_xact_lock(...)` | **`f`** (false — không lấy được) |
| S1 `COMMIT` | |
| S2 `pg_try_advisory_xact_lock(...)` | **`t`** ✅ |

```
 locktype |   objid    |     mode      | granted | pid
----------+------------+---------------+---------+------
 advisory | 2612336027 | ExclusiveLock | t       | 2379
```

`objid = 2612336027` là `hashtext('job:daily-report')` — **không có gì cho biết nó là job gì**. Đây là nhược điểm lớn nhất của advisory lock khi debug.

### Bảng so sánh các hàm

| Hàm | Phạm vi | Nhả khi | An toàn với pool? |
|---|---|---|---|
| `pg_advisory_lock(key)` | **session** | gọi `pg_advisory_unlock` hoặc đóng session | ❌ **rất dễ rò rỉ** |
| **`pg_advisory_xact_lock(key)`** | **transaction** | **tự nhả khi commit/rollback** | ✅ |
| `pg_try_advisory_lock(key)` | session | không chờ, trả `false` | ❌ |
| **`pg_try_advisory_xact_lock(key)`** | transaction | không chờ, trả `false` | ✅ |

> **Luôn dùng bản `_xact_`.** Với connection pool, bản session-level giữ khoá cả sau khi connection trả về pool → request tiếp theo dùng connection đó vô tình "thừa hưởng" khoá, hoặc tệ hơn là deadlock ngầm.

### ⚠️ Hash collision — rủi ro ít ai nghĩ tới

`hashtext()` trả về `int4` (32 bit). Với hàng nghìn khoá nghiệp vụ, xác suất hai chuỗi khác nhau cho cùng hash là **không nhỏ** (nghịch lý ngày sinh: ~50 % ở 77.000 khoá).

Hậu quả: hai job hoàn toàn không liên quan **loại trừ lẫn nhau** — và không có cách nào phát hiện ngoài việc thấy chúng chờ nhau một cách khó hiểu.

Cách giảm:
```sql
-- dùng 2 tham số int: (namespace, id) -> tách không gian khoá
SELECT pg_advisory_xact_lock(42, tenant_id);   -- 42 = "namespace tenant"
SELECT pg_advisory_xact_lock(43, device_id);   -- 43 = "namespace device"
```
Cách này an toàn hơn nhiều so với băm chuỗi, và đọc log dễ hơn.

### Hai chỗ dùng được advisory lock trong hệ IoT

**1. Leader election cho job định kỳ** — nhiều instance cùng chạy, chỉ một được thực thi:
```sql
BEGIN;
SELECT pg_try_advisory_xact_lock(100, 1) AS toi_la_leader;   -- 100 = namespace "cronjob"
-- nếu true: chạy job. nếu false: bỏ qua, instance khác đang chạy
COMMIT;
```

**2. Migration lock** — đảm bảo chỉ một pod chạy migration lúc khởi động:
```sql
SELECT pg_advisory_lock(999, 1);   -- session-level ở đây là ĐÚNG (migration không trong transaction)
-- chạy migration
SELECT pg_advisory_unlock(999, 1);
```
*(Đây là ngoại lệ hợp lệ cho bản session-level — Flyway và Liquibase đều dùng cơ chế này.)*

---

## §7. Hàng đợi trong DB vỡ ở đâu — số liệu thật

### Throughput

| Cấu hình | Thời gian 10.000 job | **Throughput** |
|---|---|---|
| **Có partial index** `(created_at) WHERE status='PENDING'` | **3.947 ms** | **2.534 job/s** |
| **Không có index phù hợp** (`ORDER BY id`, seq scan) | **14.261 ms** | **701 job/s** |

### **Partial index làm queue nhanh hơn 3,6 lần** — và đây là điều quan trọng nhất §7

Vì sao: khi job được xử lý dần, số dòng `PENDING` giảm nhưng bảng vẫn to. Không có partial index, mỗi lần lấy job phải **quét qua toàn bộ dòng `DONE`** để tìm dòng `PENDING` tiếp theo.

```sql
-- BẮT BUỘC cho mọi bảng queue
CREATE INDEX ON jobq (created_at) WHERE status = 'PENDING';
```

Đây chính là bài học Day 09 §4 áp dụng vào một ca cụ thể: **partial index biến "cột lệch" thành ưu điểm** — càng nhiều job `DONE` thì index càng nhỏ tương đối.

### Bloat — điểm yếu thật của DB queue

| | 4 worker × 2.500 job | 1 worker × 10.000 job |
|---|---|---|
| `n_tup_upd` | 20.000 | **40.000** |
| **`n_tup_hot_upd`** | **0** | **0** |
| `dead_tuple_percent` | **30,88 %** | **30,98 %** |
| `free_percent` | 31,52 % | 37,24 % |

**Tỷ lệ HOT = 0 %.** Vì `UPDATE ... SET status = 'RUNNING'` **chạm đúng cột nằm trong partial index** → điều kiện ① của HOT (Day 24) bị vi phạm.

Kiểm chứng bằng bảng không có index trên `status`, `fillfactor = 70`:
```
 n_tup_upd | n_tup_hot_upd | pct_hot |  size
-----------+---------------+---------+---------
     10000 |          4986 |  49,9 % | 1872 kB
```

**49,9 % HOT** — nhưng đổi lại throughput tụt xuống 701 job/s vì thiếu index.

> ## 💡 Đây là đánh đổi cốt lõi của job queue trên Postgres
>
> | | Có partial index trên `status` | Không có |
> |---|---|---|
> | Throughput | **2.534 job/s** ✅ | 701 job/s |
> | Tỷ lệ HOT | **0 %** ❌ | 49,9 % |
> | Bloat | **30,9 %** sau 1 vòng | thấp hơn |
>
> **Không thể có cả hai.** Index cần cho tốc độ chính là index phá HOT.

### Cách giảm bloat mà vẫn giữ tốc độ

```sql
-- 1. autovacuum RẤT hung hăng cho bảng queue (Day 23)
ALTER TABLE jobq SET (
  autovacuum_vacuum_scale_factor = 0,
  autovacuum_vacuum_threshold    = 1000,      -- ngưỡng tuyệt đối, rất thấp
  autovacuum_vacuum_cost_delay   = 0,         -- không bóp tốc độ
  fillfactor                     = 70         -- chừa chỗ, dù HOT không dùng được
);

-- 2. XOÁ job đã xong thay vì giữ status='DONE'
DELETE FROM jobq WHERE id = $1;               -- trong cùng transaction xử lý
-- -> bảng chỉ chứa job đang chờ -> nhỏ, index nhỏ, vacuum nhanh

-- 3. Hoặc partition theo thời gian + DROP PARTITION (Day 33)
```

**Cách 2 là mẫu được khuyên dùng nhất**: bảng queue chỉ chứa job **chưa xong**. Job đã xong ghi sang bảng lịch sử (hoặc bỏ). Bảng queue luôn nhỏ → mọi thứ nhanh.

### Điểm mạnh và điểm vỡ

**Điểm mạnh**
- **Transactional với dữ liệu nghiệp vụ** — enqueue và cập nhật business data trong **cùng một transaction**. Đây chính là **outbox pattern**, và là lý do nó đúng: không có cửa sổ "đã ghi DB nhưng chưa gửi message".
- Không cần hạ tầng thêm — dùng lại backup/replication/monitoring sẵn có
- Truy vấn được: *"còn bao nhiêu job pending, job nào cũ nhất"* chỉ là một câu SQL

**Vỡ ở đâu**

| Giới hạn | Số liệu / mô tả |
|---|---|
| **Throughput** | **~2.500 job/s** với 1 worker ở lab. Nhiều worker tăng được, nhưng WAL và vacuum thành nút thắt quanh **5.000–10.000/s** |
| **Bloat** | **30,9 %** chỉ sau một vòng xử lý. Cần autovacuum hung hăng hoặc DELETE job xong |
| **Long polling** | worker poll liên tục tạo tải nền. Dùng `LISTEN/NOTIFY` để đánh thức thay vì poll |
| **Fan-out** | mỗi message tới nhiều consumer → Kafka hợp hơn hẳn |
| **Replay / lưu trữ lâu** | Kafka giữ log nhiều ngày; DB queue phải tự dọn |
| **Ordering nghiêm ngặt** | `SKIP LOCKED` **phá thứ tự** — job có thể xử lý không theo thứ tự tạo |

### Ngưỡng chuyển sang Kafka

```
Dùng DB queue khi:
  ✓ job gắn chặt với transaction nghiệp vụ (outbox)
  ✓ throughput < ~2.000 job/s
  ✓ một message → một consumer
  ✓ không cần replay

Chuyển sang Kafka khi:
  ✗ throughput > 5.000 job/s ổn định
  ✗ fan-out (một event → nhiều consumer)
  ✗ cần replay / giữ log nhiều ngày
  ✗ cần ordering theo partition key ở quy mô lớn
```

**Outbox pattern là cầu nối đúng**: ghi vào bảng outbox **trong cùng transaction nghiệp vụ**, rồi một process riêng đọc outbox (bằng `SKIP LOCKED`) và đẩy sang Kafka. Được cả tính nguyên tử của DB lẫn khả năng mở rộng của Kafka.

---

## Bảng số liệu chính

| Kịch bản | Kết quả |
|---|---|
| `FOR UPDATE NOWAIT` khi dòng bị khoá | `ERROR: could not obtain lock on row` (**55P03**) |
| `FOR SHARE NOWAIT` khi có `FOR UPDATE` | **cùng lỗi** — khớp ma trận xung đột |
| `FOR UPDATE NOWAIT` trên **dòng khác** | thành công — khoá ở cấp dòng |
| Lock đang chờ trong `pg_locks` | `locktype = **transactionid**`, `ShareLock`, `granted = f` |
| `pg_blocking_pids(2378)` | `{2379}` |
| **`FOR UPDATE` không `SKIP LOCKED`** | S2 **treo**, rồi lấy về **cùng job** |
| **`FOR UPDATE SKIP LOCKED`** | S1 → **id 1**, S2 → **id 2**, không chờ |
| **4 worker × 2.500 job** | `count(*) = count(DISTINCT id) = **10.000`** — **0 job trùng**, cân bằng tuyệt đối |
| `pg_try_advisory_xact_lock` khi bị chiếm | **`f`** → sau khi nhả → **`t`** |
| **Throughput có partial index** | 10.000 job / **3.947 ms** = **2.534 job/s** |
| **Throughput không index phù hợp** | 10.000 job / **14.261 ms** = **701 job/s** (**chậm 3,6×**) |
| Bloat sau 1 vòng | `dead_tuple_percent` **30,9 %**, HOT **0 %** |
| Bảng không index `status` + `fillfactor=70` | HOT **49,9 %**, nhưng throughput chỉ 701/s |

---

## Ba điều dễ hiểu sai

| # | Hiểu nhầm | Sự thật đo được |
|---|---|---|
| 1 | "Lock dòng nằm trong `pg_locks` với `locktype = tuple`" | Nó chờ trên **`transactionid`**. Khoá dòng ghi trong tuple header → **không giới hạn số lượng**, không có lock escalation |
| 2 | "`FOR UPDATE` + `LIMIT 1` là đủ cho job queue" | 4 worker **tuần tự hoá hoàn toàn**, và S2 lấy về **cùng job** sau khi chờ |
| 3 | "Partial index trên queue chỉ giúp chút ít" | **Nhanh hơn 3,6 lần** (2.534 vs 701 job/s) — nhưng nó cũng **phá HOT hoàn toàn** (0 % vs 49,9 %) |

Thêm hai điều:
- **Khoá ngoại lấy `FOR KEY SHARE` ngầm** — `SELECT ... FOR UPDATE` trên bảng cha chặn `INSERT` vào bảng con. Dùng `FOR NO KEY UPDATE` để tránh.
- **`hashtext()` là 32 bit** — hash collision khiến hai job không liên quan loại trừ nhau. Dùng `pg_advisory_xact_lock(namespace, id)` hai tham số thay vì băm chuỗi.

---

## Áp dụng vào hệ thật

**1. Kiểm tra outbox có dùng `SKIP LOCKED` không — việc đầu tiên:**

```sql
-- nếu nhiều instance cùng chạy mà KHÔNG có SKIP LOCKED, chúng đang tuần tự hoá
-- kiểm tra bằng cách xem có ai chờ lock không
SELECT pid, pg_blocking_pids(pid), now()-query_start AS cho, left(query,80)
FROM pg_stat_activity
WHERE cardinality(pg_blocking_pids(pid)) > 0;
```

Mẫu đúng cho outbox:
```sql
UPDATE outbox SET published_at = now(), locked_by = $1
WHERE id IN (
  SELECT id FROM outbox
  WHERE published_at IS NULL
  ORDER BY created_at
  LIMIT 100                       -- batch, không phải 1
  FOR UPDATE SKIP LOCKED
)
RETURNING id, topic, payload;
```
Lấy **batch 100** thay vì 1 — giảm số round-trip, tăng throughput đáng kể.

**2. Bảng outbox/queue BẮT BUỘC có partial index:**
```sql
CREATE INDEX CONCURRENTLY ON outbox (created_at) WHERE published_at IS NULL;
```
Đo được **3,6 lần** nhanh hơn. Không có nó, throughput tụt dần khi bảng lớn lên.

**3. Cấu hình autovacuum riêng cho bảng queue:**
```sql
ALTER TABLE outbox SET (
  autovacuum_vacuum_scale_factor = 0,
  autovacuum_vacuum_threshold    = 1000,
  autovacuum_vacuum_cost_delay   = 0,
  fillfactor                     = 70
);
```
Kiểm tra hiện trạng:
```sql
SELECT relname, reloptions FROM pg_class WHERE relname = 'outbox';
```
`reloptions IS NULL` = đang dùng mặc định 20 % → với bảng queue đó là quá muộn.

**4. XOÁ bản ghi outbox đã publish thay vì giữ cờ.** Bảng queue nên chỉ chứa việc **chưa làm**. Đo được bloat 30,9 % chỉ sau một vòng — với queue chạy liên tục thì nó tích tụ mãi.

```sql
-- job dọn định kỳ
DELETE FROM outbox WHERE published_at < now() - interval '1 hour';
-- hoặc tốt hơn: partition theo giờ + DROP PARTITION (Day 33)
```

**5. Dùng `pg_advisory_xact_lock(namespace, id)` hai tham số** thay vì `hashtext(chuỗi)` — tránh hash collision và dễ debug hơn.

**6. Thay `SELECT ... FOR UPDATE` bằng `FOR NO KEY UPDATE`** ở những chỗ không đụng khoá — tránh chặn `INSERT` vào bảng con.

---

## Câu hỏi mở sang các ngày sau

1. Hai transaction lấy khoá theo thứ tự ngược nhau → deadlock. Detector phát hiện thế nào? → **Day 29**
2. `SKIP LOCKED` vs `SERIALIZABLE` vs optimistic lock — throughput thật ở 4/16/64 client? → **Day 30**
3. Bảng queue bloat 30,9 % — partition theo giờ có giải quyết được không? → **Day 33**
4. Outbox đẩy sang Kafka — logical decoding có thay được không? → **Day 39**
5. `LISTEN/NOTIFY` để giảm polling — nó hoạt động thế nào qua PgBouncer? → **Day 36**
