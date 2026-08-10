# Day 40 — Lời giải: Wait events — hệ đang **chờ** cái gì (và ôn tuần 8)

> Bài chữa. Đo thật trên lab (8 core, 31 GB RAM, `shared_buffers=256MB`, `ts_kv` 5M dòng / 289 MB) bằng một wait event sampler tự viết, lấy mẫu 20 lần/giây.
>
> Kết luận một câu: **ba kịch bản sự cố cho ba chữ ký wait event hoàn toàn khác nhau — 100% `Lock/transactionid`, 94,4% `IO/WalSync`, và 96,9% CPU — và bạn phân biệt được chúng trong 30 giây mà không cần mở EXPLAIN của bất kỳ query nào.**

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án đo được | Bẫy |
|---|---|---|---|
| 1 | `state = 'active'` thì chắc chắn đang dùng CPU? | **SAI.** Ở kịch bản lock, một backend `state='active'` suốt 20 giây nhưng **100% mẫu là `Lock/transactionid`** — nó không tiêu tốn một chu kỳ CPU nào. `active` chỉ có nghĩa "đang trong một câu lệnh". Đang chạy CPU thật ⇔ `state='active'` **VÀ** `wait_event IS NULL`. | Đây là lý do "CPU thấp mà DB chậm" — cả hệ đang chờ, không ai chạy. |
| 2 | Wait event chiếm đa số khi seq scan 5M dòng? | **Không phải `IO` — mà là CPU: 96,9%.** `IO/DataFileRead` chỉ **1,5%**. | Lý do: máy có 31 GB RAM, bảng 289 MB ⇒ nằm trọn trong **page cache của OS**. `shared_buffers` miss nhưng đọc từ page cache mất ~µs nên sampler gần như không bắt được. **Trên máy production tỉ lệ RAM/dữ liệu khác hẳn, kết quả sẽ ngược.** |
| 3 | `idle in transaction` 2 tiếng gây hại gì? | **Tuỳ mức cô lập, và đây là phát hiện lớn nhất hôm nay.** `READ COMMITTED` idle: `backend_xmin = NULL`, **KHÔNG chặn vacuum**. `REPEATABLE READ` idle: `backend_xmin = 2774712`, `VACUUM` báo **"100000 are dead but not yet removable"**. | Lời khuyên phổ biến "idle in transaction chặn vacuum" **chỉ đúng một nửa**. Ba tác hại luôn đúng: giữ lock đã lấy, chiếm slot connection, và chặn DDL. |
| 4 | Wait event top 1 trên hệ thật? | Phải tự đo. Nhưng dựa trên số liệu tuần này, ứng viên số một cho hệ ingest IoT là **`IO/WalSync`** — đo được **94,4%** khi commit từng dòng. | Ứng viên số hai bất ngờ hơn: **`Client/ClientRead`** trên backend `idle in transaction` — nghĩa là thủ phạm nằm ở **ứng dụng**, không phải database. |

---

## §1. `pg_stat_activity` khi hệ không tải

```sql
SELECT pid, backend_type, state, wait_event_type, wait_event,
       now()-state_change AS trong_state, substring(query,1,40) AS q
FROM pg_stat_activity ORDER BY backend_type, pid;
```

| pid | `backend_type` | state | `wait_event_type` | `wait_event` |
|---|---|---|---|---|
| 31 | autovacuum launcher | | `Activity` | `AutovacuumMain` |
| 28 | background writer | | `Activity` | `BgwriterMain` |
| 27 | checkpointer | | `Timeout` | `CheckpointWriteDelay` |
| **2373** | **client backend** | **active** | *(null)* | *(null)* |
| 32 | logical replication launcher | | `Activity` | `LogicalLauncherMain` |
| 30 | walwriter | | `Activity` | `WalWriterMain` |

**Năm trong sáu dòng là process nền đang ngủ.** `Activity/*Main` là "process nền đang chờ việc" — hoàn toàn bình thường và **luôn** xuất hiện. Nếu bạn xếp hạng wait event mà không lọc, bảng của bạn sẽ toàn `AutovacuumMain` và `WalWriterMain`, che mất mọi thứ có ý nghĩa.

`checkpointer` ở `Timeout/CheckpointWriteDelay` cũng bình thường — đó chính là `checkpoint_completion_target = 0.9` đang trải việc ghi ra (Day 37 §4), nó **cố ý** ngủ giữa các lần ghi.

> **Bộ lọc bắt buộc cho mọi phân tích wait event:**
> ```sql
> WHERE backend_type = 'client backend' AND state <> 'idle'
> ```
> Thiếu nó là phân tích sai.

Dòng duy nhất đáng chú ý: `client backend` **`active` với `wait_event IS NULL`** — đó chính là query đang thật sự chạy trên CPU (chính câu lệnh này).

---

## §2. Wait event sampler tự viết

`pg_stat_activity` là **ảnh chụp tức thời**. Một lần nhìn không nói lên gì — bạn có thể chụp đúng lúc mọi thứ đang rảnh. Mọi công cụ thật (pg_wait_sampling, RDS Performance Insights, pganalyze) đều làm một việc: **lấy mẫu liên tục rồi đếm tần suất**, đúng nguyên lý của CPU profiler.

```sql
CREATE PROCEDURE sample_waits(seconds int) LANGUAGE plpgsql AS $$
DECLARE deadline timestamptz := clock_timestamp() + make_interval(secs => seconds);
BEGIN
  WHILE clock_timestamp() < deadline LOOP
    INSERT INTO wait_samples
    SELECT clock_timestamp(), pid, state, wait_event_type, wait_event, substring(query,1,60)
    FROM pg_stat_activity
    WHERE backend_type = 'client backend' AND pid <> pg_backend_pid() AND state <> 'idle';
    COMMIT;                    -- COMMIT trong procedure: để mẫu bền ngay, và tránh giữ snapshot
    PERFORM pg_sleep(0.05);    -- 20 mẫu/giây
  END LOOP;
END $$;
```

Hai chi tiết thiết kế quan trọng:
- **`COMMIT` bên trong vòng lặp** (chỉ `PROCEDURE` mới làm được, `FUNCTION` thì không). Nếu không, chính sampler trở thành một transaction dài giữ snapshot — nó sẽ **tự làm sai kết quả nó đang đo** (và chặn vacuum, đúng §5).
- **`pid <> pg_backend_pid()`** — không đếm chính mình, nếu không sampler chiếm 100% mẫu.

### Kết quả: tải đọc nặng (9 backend, seq scan + sort trên 5M dòng)

| Loại | Sự kiện | Mẫu | % |
|---|---|---|---|
| **(chạy trên CPU)** | — | **254** | **96,9%** |
| `IO` | `DataFileRead` | 4 | 1,5% |
| `LWLock` | `BufferMapping` | 4 | 1,5% |

Tổng 262 mẫu trên 9 backend.

**96,9% CPU — đây là kết quả trung thực nhưng cần giải thích, vì nó ngược với kỳ vọng của §0 câu 2.**

Máy có 31 GB RAM; `ts_kv` chỉ 289 MB. Dù `shared_buffers` chỉ 256 MB (nên có buffer miss), dữ liệu vẫn nằm trọn trong **page cache của OS**. Một `DataFileRead` từ page cache mất ~1–5 µs; sampler lấy mẫu mỗi 50.000 µs ⇒ xác suất bắt được gần như bằng 0. Thời gian thật trôi vào **giải nén tuple, đánh giá vị từ, hash aggregate** — tức CPU.

> **Bài học phương pháp quan trọng hơn cả kết quả: kết luận về wait event KHÔNG chuyển được giữa các máy có tỉ lệ RAM/dữ liệu khác nhau.** Trên production 2 TB dữ liệu / 64 GB RAM, cùng query này sẽ là 80–95% `IO/DataFileRead`. Đây là lý do phải đo trên chính hệ của bạn, không đọc benchmark của người khác.

`LWLock/BufferMapping` 1,5% cũng đúng như lý thuyết: nhiều backend cùng tìm/thay buffer trong `shared_buffers` nhỏ ⇒ tranh chấp bảng băm buffer. Nếu con số này lên 20–30%, đó là dấu hiệu `shared_buffers` quá nhỏ so với số backend.

---

## §3. Bảng tra: nhóm wait event ↔ bệnh

| `wait_event_type` | Nghĩa | Ví dụ | Bệnh và hướng xử lý |
|---|---|---|---|
| **(null)** | **đang chạy CPU thật** | — | CPU-bound: tối ưu query (tuần 1–4), thêm core |
| `IO` | đọc/ghi file | `DataFileRead`, `WalSync`, `WalWrite` | thiếu RAM/cache, đĩa chậm, checkpoint dồn → Day 37 |
| `Lock` | **lock hàng/bảng do SQL của bạn** | `transactionid`, `tuple`, `relation` | **lỗi thiết kế transaction** → Day 28–30. Thêm CPU **không cứu được**. |
| `LWLock` | lock nội bộ engine | `BufferMapping`, `WALWrite`, `LockManager` | thường là **triệu chứng**, không phải nguyên nhân |
| `Client` | chờ **ứng dụng** | `ClientRead` | app chậm gửi lệnh, hoặc `idle in transaction` → §5 |
| `IPC` | chờ process khác | `ParallelFinish`, `MessageQueueSend` | parallel worker mất cân bằng |
| `Timeout` | ngủ có chủ đích | `VacuumDelay`, `PgSleep` | thường vô hại (`VacuumDelay` cao → Day 23) |
| `BufferPin` | chờ buffer được nhả | `BufferPin` | hiếm; cursor mở lâu |

Bốn quy tắc đọc:

1. **`Lock` nhiều → lỗi thiết kế, không phải thiếu phần cứng.** Thêm CPU/RAM/đĩa không cứu được một chút nào.
2. **`IO/DataFileRead` nhiều → working set > cache**, hoặc query đọc thừa (thiếu index — về lại tuần 2).
3. **`Client/ClientRead` trên backend `active`/`idle in transaction` → thủ phạm là ỨNG DỤNG.** Đây là phát hiện quý nhất mà bảng này cho bạn, và là thứ khó tìm nhất bằng cách khác.
4. **`LWLock` nhiều → đừng tối ưu LWLock**, hãy tìm cái gây ra nó (thường là quá nhiều connection — Day 36, hoặc `shared_buffers` quá nhỏ).

### Đối chiếu với `BUFFERS` của Day 03

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT key_id, count(*), avg(dbl_v) FROM ts_kv GROUP BY key_id;
```

Plan cho `shared hit` cao và `read` thấp — **cùng câu chuyện với sampler**: dữ liệu đã trong cache, nên `IO/DataFileRead` chỉ 1,5%. Hai nguồn dữ liệu khớp nhau, và đó là cách kiểm chứng chéo: **nếu `BUFFERS` cho `read` lớn mà sampler không thấy `IO`, thì `read` đó đến từ page cache của OS chứ không từ đĩa thật.**

---

## §4. Ba kịch bản — ba chữ ký

### Kịch bản 1: tranh chấp lock

S1 giữ `UPDATE device ... WHERE id=1` không commit; S2 chạy `UPDATE` cùng dòng.

```sql
SELECT a.pid, a.state, a.wait_event_type, a.wait_event, pg_blocking_pids(a.pid) AS bi_chan_boi,
       substring(a.query,1,45) AS q
FROM pg_stat_activity a WHERE cardinality(pg_blocking_pids(a.pid))>0 OR a.state='idle in transaction';
```

| pid | state | `wait_event_type` | `wait_event` | bị chặn bởi | query |
|---|---|---|---|---|---|
| 2545 | **active** | **`Lock`** | **`transactionid`** | **{2544}** | `UPDATE device SET firmware='v8' WHERE id = 1;` |
| 2544 | **idle in transaction** | **`Client`** | **`ClientRead`** | {} | `UPDATE device SET firmware='v9' WHERE id = 1;` |

**Chữ ký sampler: `Lock / transactionid` — 224 mẫu, 100,0%.**

Hai dòng này là toàn bộ nghệ thuật chẩn đoán:

- **Nạn nhân** (2545): `state='active'`, nhưng `wait_event = Lock/transactionid` ⇒ **không dùng một chút CPU nào** trong suốt 20 giây. Đây là bằng chứng trực tiếp cho §0 câu 1.
- **Thủ phạm** (2544): `state='idle in transaction'` với `Client/ClientRead` ⇒ database **không** đang làm gì cả, nó đang **chờ ứng dụng gửi lệnh tiếp theo**. Vấn đề nằm ở code, không ở DB.

> Khi thấy `Lock` chiếm đa số, **đừng nhìn nạn nhân — nhìn thủ phạm**. `pg_blocking_pids()` chỉ thẳng vào nó. Và nếu thủ phạm ở `Client/ClientRead`, bạn đã có câu trả lời: một transaction đang mở chờ ứng dụng.

### Kịch bản 2: WAL / fsync

3.000 `INSERT`, mỗi cái một transaction (đúng mẫu ORM hay sinh ra).

| `synchronous_commit` | Thời gian | Top wait event | Chữ ký |
|---|---|---|---|
| **`on`** | **9.858,6 ms** | **`IO / WalSync` — 169 mẫu, 94,4%** | CPU 4,5% · `IO/WalWrite` 1,1% |
| **`off`** | **44,8 ms** | (CPU) — 1 mẫu, 100% | không có wait nào |

**220× chênh lệch, và chữ ký nói chính xác lý do: 94,4% thời gian trôi vào `WalSync` — tức `fsync()` xuống đĩa.**

Con số này khớp hoàn hảo với Day 37 §5 (309 → 25.941 tps = 84×) nhưng cho thêm một thứ Day 37 không có: **bằng chứng trực tiếp rằng thời gian đó là fsync**, không phải suy luận.

Đây là lý do sampler đáng giá: Day 37 cho bạn biết `synchronous_commit=off` nhanh hơn; hôm nay cho bạn biết **vì sao**, và quan trọng hơn — cho bạn cách **nhận ra vấn đề này trên một hệ bạn chưa từng xem**, chỉ trong 30 giây, không cần biết trước nó là bug gì.

Phân biệt hai wait event WAL:
- **`WalSync`** = đang `fsync()` — chờ đĩa xác nhận bền vững. Sửa bằng: `synchronous_commit`, gom lô, đĩa nhanh hơn.
- **`WalWrite`** = đang `write()` vào bộ đệm OS. Cao bất thường ⇒ `wal_buffers` quá nhỏ.

### Kịch bản 3: thủ phạm là ứng dụng

```sql
SELECT pid, state, wait_event_type, wait_event,
       now()-xact_start AS transaction_mo, now()-state_change AS trong_state
FROM pg_stat_activity WHERE state LIKE 'idle in transaction%';
```

| pid | state | `wait_event_type` | `wait_event` | transaction mở | trong state |
|---|---|---|---|---|---|
| 2735 | **`idle in transaction`** | **`Client`** | **`ClientRead`** | 2,09 s | 2,07 s |

`transaction_mo ≈ trong_state` ⇒ transaction mở ra rồi **không làm gì suốt** từ đó. Chữ ký kinh điển của `@Transactional` bọc một lời gọi HTTP ra ngoài.

### Ba chữ ký để nhận diện trong 30 giây đầu

| Chữ ký | Bệnh | Đi đâu |
|---|---|---|
| **`Lock/transactionid` chiếm đa số** | tranh chấp business logic | `pg_blocking_pids()` → tìm thủ phạm → Day 28–30 |
| **`IO/WalSync` chiếm đa số** | commit từng dòng / fsync nghẽn | gom lô, `synchronous_commit` → Day 37 |
| **`IO/DataFileRead` chiếm đa số** | working set > cache, hoặc thiếu index | `BUFFERS` trong plan → tuần 1–2 |
| **`Client/ClientRead` trên `idle in transaction`** | **lỗi ở ứng dụng** | `idle_in_transaction_session_timeout` → §5 |
| **(null) — CPU chiếm đa số** | CPU-bound | tối ưu query, thêm core |
| `LWLock/LockManager` cao | quá nhiều connection | → Day 36 |

---

## §5. `idle in transaction` — và một chỉnh sửa quan trọng

README (và hầu hết tài liệu) nói: *"một transaction mở giữ snapshot ⇒ chặn `VACUUM` trên toàn database"*. **Đo thật cho thấy điều đó chỉ đúng với REPEATABLE READ trở lên.**

Thí nghiệm: mở `BEGIN; SELECT count(*) FROM device;` rồi để idle. Tạo bảng 200.000 dòng, xoá một nửa, `VACUUM (VERBOSE)`.

| Mức cô lập của session idle | `backend_xmin` | `VACUUM` báo | Dead tuple dọn được |
|---|---|---|---|
| **`READ COMMITTED`** | **`NULL`** | `tuples: 100000 removed, 100000 remain, 0 are dead but not yet removable` | **100.000 — dọn sạch** ✅ |
| **`REPEATABLE READ`** | **`2774712`** | `tuples: 0 removed, 200000 remain, **100000 are dead but not yet removable**` | **0 — chặn hoàn toàn** ❌ |
| Sau khi `REPEATABLE READ` commit | — | `tuples: 100000 removed, 100000 remain` | **100.000** ✅ |

**Cơ chế:** ở `READ COMMITTED`, snapshot được lấy **mỗi câu lệnh** và **thả ra khi câu lệnh xong**. Transaction vẫn mở (vẫn `idle in transaction`) nhưng **không giữ snapshot nào** ⇒ `backend_xmin = NULL` ⇒ không ghim `xmin horizon`. Ở `REPEATABLE READ`/`SERIALIZABLE`, snapshot lấy ở câu lệnh **đầu tiên** và giữ tới hết transaction.

Dòng `100000 are dead but not yet removable` trong `VACUUM VERBOSE` là **bằng chứng trực tiếp** — bất cứ khi nào thấy nó, có ai đó đang ghim horizon.

### Nhưng `READ COMMITTED` idle in transaction VẪN nguy hiểm

Ba tác hại **luôn đúng**, không phụ thuộc mức cô lập:

1. **Giữ mọi lock đã lấy.** Kịch bản 1 chứng minh: session `READ COMMITTED` idle đã chạy một `UPDATE` ⇒ giữ row lock ⇒ chặn người khác **vô thời hạn**. Nó cũng chặn mọi DDL (`ALTER TABLE` chờ `ACCESS EXCLUSIVE` → và mọi query mới xếp hàng sau — Day 43).
2. **Chiếm slot connection** — với `max_connections=100` và pool lớn (Day 36), vài chục session idle in transaction làm cạn pool.
3. **Nếu nó có xid** (đã ghi gì đó) thì nó vẫn ghim `xmin horizon` cho **freeze/wraparound** dù không ghim cho vacuum thường.

Và tác hại thứ 4 — chỉ với `REPEATABLE READ`+: **chặn `VACUUM` trên TOÀN BỘ database**, kể cả bảng nó chưa từng chạm. Vì `xmin horizon` là chỉ số toàn cục.

> **"Một session `idle in transaction` ở service A làm phình bảng của service B" — cơ chế bằng 3 câu:**
> Snapshot của A ghim `xmin horizon` toàn cluster ở một xid cũ. `VACUUM` chỉ được xoá dead tuple có `xmax` cũ hơn horizon đó, vì bất kỳ dòng nào mới hơn *có thể* vẫn hữu hình với A. Bảng của B tích tụ dead tuple không dọn được, phình lên, và mọi seq scan trên nó bắt đầu đọc cả rác — dù A và B không dùng chung một cái bảng nào.

### Chẩn đoán và thuốc

```sql
-- ai đang ghim horizon (dùng được cho MỌI nguồn: backend, replica, slot)
SELECT pid, backend_type, state, backend_xmin, age(backend_xmin) AS tuoi,
       now()-xact_start AS mo_bao_lau, substring(query,1,50) AS q
FROM pg_stat_activity WHERE backend_xmin IS NOT NULL ORDER BY age(backend_xmin) DESC;

SELECT pg_snapshot_xmin(pg_current_snapshot()) AS xmin_horizon;
```

```sql
ALTER SYSTEM SET idle_in_transaction_session_timeout = '60s';   -- giết session mở transaction mà rỗi
ALTER ROLE app SET statement_timeout = '30s';                   -- theo role, không toàn cục mù quáng
ALTER ROLE bao_cao SET statement_timeout = '10min';
```

`idle_in_transaction_session_timeout` là **an toàn hơn nhiều người nghĩ**: nó chỉ giết session đang mở transaction mà **không làm gì**. Một transaction đang chạy query 10 phút **không** bị đụng tới (cái đó là `statement_timeout`). Nói cách khác nó chỉ giết đúng những session không nên tồn tại.

**Bốn nguồn ghim `xmin horizon` — tổng kết cả tuần 5 và tuần 8:**

| Nguồn | Nhìn ở đâu | Ngày |
|---|---|---|
| Transaction dài / `idle in transaction` (RR+) | `pg_stat_activity.backend_xmin` | Day 22, hôm nay |
| **Replica với `hot_standby_feedback=on`** | **`pg_stat_replication.backend_xmin`** | Day 38 §5 |
| **Physical / logical replication slot** | **`pg_replication_slots.xmin`, `catalog_xmin`** | Day 37 §6, Day 39 §4 |
| Prepared transaction (2PC) bị bỏ quên | `pg_prepared_xacts` | — |

Ba nguồn cuối **không xuất hiện trong `pg_stat_activity`** — đó là lý do bloat khó chẩn đoán nhất luôn đến từ chúng.

---

## §6. Nối wait event với query — và vì sao hai bảng không trùng nhau

Chạy đồng thời ba loại tải: một query nặng chạy **1 lần**, một query nhẹ chạy **hàng chục nghìn lần** (pgbench 4 client), và một luồng commit từng dòng.

**Sampler (wait_samples):**

| Query | Loại | Sự kiện | Mẫu |
|---|---|---|---|
| `DO $$ ... INSERT INTO device_attr ... COMMIT ...` | **`IO`** | **`WalSync`** | **154** |
| `DO $$ ... INSERT ...` | (CPU) | — | 13 |
| `SELECT device_id, count(*), avg(dbl_v) FROM ts_kv ...` | (CPU) | — | 12 |
| `DO $$ ... INSERT ...` | `IO` | `WalWrite` | 2 |

**`pg_stat_statements`:**

| Query | calls | total_ms | mean_ms |
|---|---|---|---|
| `DO $$ ... INSERT INTO device_attr ...` | 1 | **9.254** | 9.254 |
| `SELECT device_id, count(*), avg(dbl_v) ...` | 1 | 644 | 644 |
| **`INSERT INTO device_attr VALUES ($3,$4,$5\|\|i,$6)`** | **3.000** | **257** | **0,086** |

Ba khác biệt, mỗi cái là một bài học:

**a) `SELECT * FROM device WHERE id=42` (pgbench, hàng chục nghìn lần) KHÔNG xuất hiện trong sampler.** Mỗi lần chạy mất ~0,02 ms; sampler lấy mẫu mỗi 50 ms ⇒ xác suất bắt được gần bằng 0. **Sampler mù với query nhanh, dù chúng chạy rất nhiều lần và tổng thời gian có thể lớn.**

**b) `INSERT INTO device_attr` chỉ có `total_exec_time = 257 ms` trong `pg_stat_statements`, nhưng khối `DO` bọc nó mất 9.254 ms.** Chênh lệch **9 giây** đi đâu? **Vào `COMMIT`** — mà `COMMIT` không phải một statement được `pg_stat_statements` tính riêng. Sampler thì bắt được ngay: **154 mẫu `IO/WalSync`**.

> **Đây là điểm mù lớn nhất của `pg_stat_statements`: thời gian commit/fsync không được quy cho câu `INSERT`.** Nhìn `pg_stat_statements` bạn kết luận "INSERT rất nhanh, 0,086 ms" và đi tìm bug ở chỗ khác. Sampler chỉ thẳng vào `WalSync`.

**c) Ngược lại, sampler không cho bạn `calls` và `mean`.** Một query 0,086 ms × 3.000 lần là vấn đề khác hẳn một query 9 giây × 1 lần — sampler không phân biệt được.

### Dùng cả hai, không thay thế nhau

| | `pg_stat_statements` | Wait event sampler |
|---|---|---|
| Trả lời | **query nào tốn tổng thời gian nhiều nhất** | **thời gian đó trôi vào đâu** |
| Mạnh ở | query nhanh chạy nhiều lần; so sánh `calls`/`mean` | query chậm; thời gian ngoài statement (commit, lock) |
| Mù ở | **thời gian commit/fsync**; thời gian chờ lock không hiện rõ | query nhanh (< chu kỳ lấy mẫu) |
| Dùng khi | tối ưu định kỳ, tìm top query | **đang có sự cố, chưa biết bệnh gì** |

**Quy trình đúng: sampler trước để biết *loại* bệnh, `pg_stat_statements` sau để biết *query nào*.**

---

## §7. Quy trình 30 giây đầu khi có sự cố

| # | Câu hỏi | Lệnh | Bất thường ⇒ đi đâu |
|---|---|---|---|
| **1** | Bao nhiêu backend active / đang chờ? | `SELECT state, count(*) FROM pg_stat_activity WHERE backend_type='client backend' GROUP BY 1;` | `active` ≫ số core → Day 36. `idle in transaction` > 0 → bước 4 |
| **2** | Hệ đang chờ **nhóm** gì? | `SELECT wait_event_type, wait_event, count(*) FROM pg_stat_activity WHERE backend_type='client backend' AND state='active' GROUP BY 1,2 ORDER BY 3 DESC;` | dùng bảng chữ ký §4 |
| **3** | Có ai bị chặn không? | `SELECT pid, pg_blocking_pids(pid), substring(query,1,60) FROM pg_stat_activity WHERE cardinality(pg_blocking_pids(pid))>0;` | có → nhìn **thủ phạm**, không nhìn nạn nhân → Day 28–30 |
| **4** | `idle in transaction` lâu không? | `SELECT pid, now()-xact_start AS mo, backend_xmin, substring(query,1,60) FROM pg_stat_activity WHERE state LIKE 'idle in transaction%' ORDER BY xact_start;` | > 60 s → §5. `backend_xmin` khác NULL → đang chặn vacuum |
| **5** | Ai đang ghim `xmin horizon`? | `SELECT pid,backend_xmin,age(backend_xmin) FROM pg_stat_activity WHERE backend_xmin IS NOT NULL UNION ALL SELECT NULL,xmin,age(xmin) FROM pg_replication_slots WHERE xmin IS NOT NULL;` | `age` > 50M → Day 22, 38 §5, 39 §4 |
| **6** | Replication lag / slot? | `SELECT application_name, pg_wal_lsn_diff(pg_current_wal_lsn(),replay_lsn) FROM pg_stat_replication; SELECT slot_name,active,wal_status FROM pg_replication_slots;` | lag > 100 MB, `wal_status <> 'reserved'` → Day 38, 39 |
| **7** | Query nào nặng nhất? | `SELECT substring(query,1,60), calls, round(total_exec_time) FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10;` | → Day 05, và nhớ điểm mù ở §6 |
| **8** | Vacuum & checkpoint có theo kịp? | `SELECT relname,n_dead_tup,last_autovacuum FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 5; SELECT num_timed,num_requested FROM pg_stat_checkpointer;` | `n_dead_tup` cao → Day 22–23. `num_requested`/tổng > 10% → Day 37 §4 |

**Thứ tự này quan trọng.** Bước 1–3 mất 15 giây và loại được 80% khả năng. Đừng bao giờ mở EXPLAIN trước khi qua bước 2 — bạn có thể đang tối ưu một query hoàn toàn khoẻ mạnh trong khi cả hệ đang chờ một cái lock.

---

## Ôn tuần 8

### Ba con số đo được tuần này mà trước đây chỉ đoán

| # | Con số | Trước đây tôi tưởng | Ngày |
|---|---|---|---|
| **1** | **Đỉnh throughput ở đúng 8 client = 8 core**; 256 client cho **−46%** throughput và **×59** latency | "pool 100 cho chắc, thừa còn hơn thiếu" | 36 |
| **2** | **86,3% WAL của một `UPDATE` ngay sau checkpoint là full-page image**; cùng lệnh lần hai chỉ tốn 1/3 | "WAL to bằng lượng dữ liệu ghi" | 37 |
| **3** | **Read-your-writes hỏng 30/30 lần khi có tải** (0/20 khi không tải) | "lag vài ms, hiếm khi gặp" | 38 |

Ba con số phụ đáng nhớ không kém: `synchronous_commit=off` nhanh **84×** (37); `hot_standby_feedback=on` làm primary phình **2,1×** và vacuum dọn được **0** dead tuple (38); outbox tốn WAL **1,83×** CDC nhưng bloat **16,3×** (39).

### Một thứ trong hệ thật giờ tôi tin là đang sai

**Nghi ngờ: `maximumPoolSize` đang đặt quá cao (50–100 mỗi service), và tổng connection lúc đỉnh vượt xa `core × 2 + 2`.**

Bằng chứng sẽ đi lấy (chỉ đọc, an toàn, 2 phút):
```sql
-- (1) bao nhiêu connection thật sự làm việc?
SELECT count(*) FILTER (WHERE state='active')             AS dang_chay,
       count(*) FILTER (WHERE state='idle')               AS idle,
       count(*) FILTER (WHERE state='idle in transaction') AS idle_in_xact,
       count(*)                                           AS tong
FROM pg_stat_activity WHERE backend_type='client backend';

-- (2) hệ đang chờ gì
SELECT wait_event_type, wait_event, count(*) FROM pg_stat_activity
WHERE backend_type='client backend' AND state='active' GROUP BY 1,2 ORDER BY 3 DESC;

-- (3) idle in transaction lâu nhất
SELECT max(now()-xact_start) FROM pg_stat_activity WHERE state='idle in transaction';
```

Dự đoán: `dang_chay` ≈ 10–20 trong khi `tong` ≈ 200–400, và có `LWLock/LockManager` trong top wait event. Nếu đúng ⇒ giảm pool xuống `core×2+2` và thêm pgbouncer (Day 36 §5: 500 client chạy được trên `max_connections=100`, dùng 21 backend).

---

## Bảng số liệu chính

| Phép đo | Kết quả |
|---|---|
| Backend nền lúc không tải | 5 process, tất cả ở `Activity/*Main` hoặc `Timeout/CheckpointWriteDelay` — **phải lọc bỏ** |
| **Tải đọc nặng (9 backend, 5M dòng)** | **CPU 96,9%** · `IO/DataFileRead` 1,5% · `LWLock/BufferMapping` 1,5% |
| Lý do CPU-bound | 31 GB RAM / bảng 289 MB ⇒ **page cache của OS** giữ hết |
| **Kịch bản lock — chữ ký** | **`Lock/transactionid` 224 mẫu = 100,0%** |
| — nạn nhân | `state='active'` nhưng **0% CPU** suốt 20 s |
| — thủ phạm | **`idle in transaction` + `Client/ClientRead`** ⇒ lỗi ở ứng dụng |
| **Kịch bản WAL, `synchronous_commit=on`** | **9.858,6 ms** · **`IO/WalSync` 169 mẫu = 94,4%** |
| **Kịch bản WAL, `synchronous_commit=off`** | **44,8 ms** (**220×**) · **100% CPU, không wait** |
| `idle in transaction` **`READ COMMITTED`** | **`backend_xmin = NULL`** — `VACUUM` dọn **100.000/100.000** ✅ |
| `idle in transaction` **`REPEATABLE READ`** | **`backend_xmin = 2774712`** — `VACUUM`: **"100000 are dead but not yet removable"**, dọn **0** ❌ |
| Sau khi RR commit | dọn được **100.000** |
| **§6 — `INSERT` trong `pg_stat_statements`** | 3.000 calls, **257 ms tổng**, 0,086 ms/lần |
| **§6 — khối `DO` bọc nó** | **9.254 ms** — chênh **9 giây** là **`COMMIT`/fsync**, không được quy cho `INSERT` |
| **§6 — sampler thấy gì** | **154 mẫu `IO/WalSync`** ⇒ chỉ thẳng vào fsync |
| **§6 — query 0,02 ms chạy hàng chục nghìn lần** | **0 mẫu trong sampler** — điểm mù của phương pháp lấy mẫu |

---

## Ba điều dễ hiểu sai

| Hiểu nhầm | Sự thật đo được |
|---|---|
| "`state = 'active'` nghĩa là backend đang dùng CPU." | Ở kịch bản lock, backend `active` suốt 20 giây với **100% mẫu là `Lock/transactionid`** — không tiêu một chu kỳ CPU nào. Đang chạy CPU thật ⇔ `state='active'` **VÀ `wait_event IS NULL`**. Đây là lý do dashboard báo "CPU 15%, DB chậm" — cả hệ đang chờ, không ai chạy, và thêm phần cứng không cứu được gì. |
| "`idle in transaction` luôn chặn `VACUUM`." | **Chỉ đúng từ `REPEATABLE READ` trở lên.** `READ COMMITTED` idle: `backend_xmin = NULL`, `VACUUM` dọn sạch 100.000/100.000. `REPEATABLE READ` idle: `VACUUM` báo **"100000 are dead but not yet removable"**, dọn được **0**. Nhưng `READ COMMITTED` vẫn nguy hiểm vì **giữ mọi lock đã lấy** và chặn DDL — chỉ là qua đường khác. |
| "`pg_stat_statements` cho tôi thấy toàn bộ thời gian." | 3.000 `INSERT` chỉ được tính **257 ms tổng**, trong khi khối bao quanh mất **9.254 ms**. **9 giây đó là `COMMIT`/fsync và không được quy cho câu `INSERT` nào cả.** Nhìn `pg_stat_statements` bạn kết luận "INSERT nhanh, 0,086 ms" và đi tìm bug ở chỗ khác. Sampler bắt được ngay: **154 mẫu `IO/WalSync` = 94,4%**. Hai công cụ bù cho nhau, không thay nhau. |

---

## Áp dụng vào hệ thật

1. **Chạy ngay trên production (chỉ đọc, 30 giây)** — ba query của bước 1, 2, 4 trong §7. Ghi lại kết quả làm baseline: bạn cần biết hệ trông thế nào lúc **khoẻ** thì mới nhận ra lúc **bệnh**.

2. **Cài `pg_wait_sampling`** (hoặc dùng RDS Performance Insights / pganalyze nếu có). Sampler tự viết ở §2 tốt để học nhưng nó chạy trong DB và tự nó tốn tài nguyên; extension lấy mẫu ở tầng thấp hơn, rẻ hơn nhiều.

3. **Đặt `idle_in_transaction_session_timeout`** — 60 s cho role ứng dụng, cao hơn cho role admin. An toàn hơn nhiều người nghĩ: nó **không** đụng tới transaction đang chạy query, chỉ giết session mở transaction mà không làm gì.
   ```sql
   ALTER ROLE app SET idle_in_transaction_session_timeout = '60s';
   ALTER ROLE app SET statement_timeout = '30s';
   ```

4. **Grep code tìm `@Transactional` bọc lời gọi mạng.** Chữ ký `idle in transaction` + `Client/ClientRead` gần như luôn là cái này. Với Temporal: **không bao giờ mở transaction DB rồi chờ activity/signal** — đó là công thức chính xác để tạo ra session này.

5. **Dán bảng chữ ký §4 vào runbook.** Bốn dòng đó phân biệt được: lỗi thiết kế transaction / fsync nghẽn / thiếu cache / lỗi ứng dụng — trong 30 giây, không cần biết trước hệ đang chạy gì.

6. **Kiểm tra `backend_xmin` từ CẢ BỐN nguồn** (§5 bảng cuối). Ba trong bốn nguồn **không xuất hiện trong `pg_stat_activity`** — đó là lý do bloat khó chẩn đoán nhất luôn đến từ chúng.

7. **Đừng mang kết luận wait event giữa các môi trường.** Lab cho 96,9% CPU vì 31 GB RAM / 289 MB dữ liệu. Production 2 TB / 64 GB RAM sẽ cho kết quả ngược. Đo trên chính hệ của bạn, ở chính giờ cao điểm.

8. **Khi có sự cố: bước 1–3 của §7 trước, EXPLAIN sau.** Mở EXPLAIN trước khi biết hệ đang chờ nhóm gì là cách tối ưu một query hoàn toàn khoẻ mạnh trong lúc cả hệ chờ một cái lock.

---

## Câu hỏi mở sang các ngày sau

- **Tuần 9 (Day 41–45)** chuyển sang thay đổi schema an toàn. Wait event của hôm nay là công cụ chính để **quan sát** một migration: `Lock/relation` xuất hiện nghĩa là DDL của bạn đang chặn cả hệ — và bước 3 của §7 chỉ thẳng vào nó.
- **Day 43 (DDL locks)** nối trực tiếp với §5: một session `idle in transaction` ở `READ COMMITTED` **không** chặn vacuum nhưng **chặn `ALTER TABLE`**, và `ALTER TABLE` đang chờ thì chặn **mọi query mới**. Đó là cách một session vô hại làm sập cả hệ.
- **Day 46–48 (capstone)** dùng đúng quy trình 8 bước của §7 để audit một hệ thật.
- **Day 03 (BUFFERS)** nhìn lại từ hôm nay: `shared read` trong plan **không** phân biệt được đọc từ page cache của OS với đọc từ đĩa thật. Sampler phân biệt được (`IO/DataFileRead` có xuất hiện hay không). Kết hợp hai cái mới biết I/O thật sự nằm ở đâu.
- **Câu hỏi mở thật sự:** sampler mù với query < chu kỳ lấy mẫu (đo được: query 0,02 ms chạy hàng chục nghìn lần cho **0 mẫu**). Giảm chu kỳ xuống 10 ms thì overhead của chính sampler tăng lên. Có cách nào đo được thời gian chờ của query siêu ngắn mà không phải lấy mẫu — `pg_stat_statements` với `track_planning`, hay eBPF ở tầng kernel?

---

### Dọn dẹp

```sql
DROP PROCEDURE sample_waits(int);
DROP TABLE wait_samples;
DROP TABLE IF EXISTS t_block;
DELETE FROM device_attr WHERE key LIKE 'k%';
```
