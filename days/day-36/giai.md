# Day 36 — Lời giải: Connection pooling — vì sao 500 connection giết Postgres

> Bài chữa. Đo thật trên máy **8 core / 31 GB RAM**, Postgres 17 trong Docker (`shared_buffers=256MB`, `work_mem=4MB`). pgbench scale 20 (`pgbench_accounts` 299 MB — vừa `shared_buffers`? Không: 299 MB > 256 MB, nhưng phần nóng thì vừa).
>
> Để đo được 200/500 client, tôi **tạm nâng `max_connections` từ 100 lên 600**, chạy đo, rồi trả lại 100. Phần cuối §5 dùng chính con số 100 để cho thấy điều quan trọng nhất của cả ngày.
>
> Kết luận một câu: **đỉnh throughput read-only nằm đúng ở 8 client = số core, và pgbouncer ở lab này làm mọi thứ CHẬM đi 19–28% — nhưng nó là thứ duy nhất giúp 500 client chạy được khi `max_connections=100`.**

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án đo được | Bẫy |
|---|---|---|---|
| 1 | Throughput đạt đỉnh ở bao nhiêu connection? | **Đúng 8 client = đúng số core.** 153.627 tps. Từ 8 lên 16 tps **giảm** 9%. | Nhưng đó là read-only. Với **read-write**, throughput vẫn tăng tới 128 client (3.060 tps) — vì tải bị chặn ở fsync chứ không ở CPU. **Không có một con số "pool size đúng" cho mọi workload.** |
| 2 | Từ 100 lên 500 connection, throughput tăng hay giảm? | **Giảm.** 128 client 106.439 tps → 256 client 82.784 tps (**−22%**), so với đỉnh ở 8 client thì **−46%**. Latency 0,052 ms → 3,092 ms (**59×**). | Điều làm tôi bất ngờ: nó **không sập**, chỉ chậm dần và đều. Không có ngưỡng gãy đột ngột — đó là lý do nhiều hệ chạy pool 200 nhiều năm mà không ai nghi ngờ. |
| 3 | Pool size nên đặt bao nhiêu? | Công thức HikariCP `core×2 + spindles` = **17–20** cho máy này. Đo được: đỉnh ở 8, và từ 8→32 throughput dao động quanh 140–153k (phẳng). **Vùng 8–32 là vùng an toàn; 17–20 nằm giữa — công thức khớp.** | Bẫy: công thức này cho **throughput tối đa**, không phải **latency tối thiểu**. Ở 8 client latency 0,052 ms; ở 32 client là 0,221 ms (4,3×) với cùng throughput. Nếu tối ưu p99 thì pool nhỏ hơn nữa. |

---

## §1. Mỗi connection là một process

### Đo bộ nhớ thật

`ps` cho ra số vô nghĩa: mỗi backend hiện `RSS ≈ 229 MB` vì `shared_buffers` 256 MB được **đếm lặp lại** ở mọi process (nó là shared memory, chỉ tồn tại một lần trong RAM). 128 backend × 229 MB = 29 GB — **sai hoàn toàn**.

Cách đo đúng: so tổng bộ nhớ container trước và sau khi mở connection.

| | Bộ nhớ container | Số connection |
|---|---|---|
| Idle | **314,8 MB** | 6 |
| 200 connection đang chạy | **725,7 MB** | 206 |
| **Chênh** | **410,9 MB / 200 = 2,05 MB mỗi connection** | |
| Sau khi ngắt hết | **314,8 MB** (trả lại đủ) | 6 |

**2,05 MB mỗi connection** — thấp hơn con số "5–10 MB" thường trích dẫn, vì pgbench chỉ chạm 2 bảng và không nạp mấy vào catalog cache.

Xác nhận từ bên trong:
```sql
SELECT pg_size_pretty(sum(total_bytes)) FROM pg_backend_memory_contexts;   -- 1432 kB
SELECT name, pg_size_pretty(total_bytes) FROM pg_backend_memory_contexts ORDER BY total_bytes DESC LIMIT 5;
--  CacheMemoryContext      | 512 kB   ← catalog + plan cache, PHÌNH theo số bảng/query app dùng
--  TopMemoryContext        | 224 kB
--  Timezones               | 102 kB
--  MessageContext          |  64 kB
--  WAL record construction |  49 kB
```

`CacheMemoryContext` là khoản quyết định và nó **không có giới hạn trên**. Một app ORM chạm 300 bảng với 2.000 prepared statement sẽ có `CacheMemoryContext` hàng chục MB *mỗi connection*, và nó **không bao giờ được giải phóng** trong vòng đời connection. Đây là lý do con số thật ở production thường là 5–15 MB, không phải 2 MB.

Ngoại suy: **500 connection ≈ 1 GB ở lab, ≈ 2,5–7,5 GB với app thật.** Đó là RAM lẽ ra dành cho page cache.

### Chi phí ẩn quan trọng hơn bộ nhớ

Bộ nhớ chỉ là khoản dễ thấy. Khoản đắt hơn là: **nhiều thao tác nội bộ của Postgres phải duyệt toàn bộ mảng `PGPROC`** — mỗi lần lấy snapshot MVCC, mỗi lần tìm lock, mỗi lần tính `xmin` nhỏ nhất cho vacuum. Chi phí đó **tuyến tính theo `max_connections`** (không phải theo số connection đang bận!) và diễn ra dưới **spinlock**.

Hệ quả cụ thể: **đặt `max_connections = 5000` "cho chắc" đã làm chậm hệ thống ngay cả khi chỉ có 10 client.** Đây là một trong ít GUC mà giá trị lớn có hại kể cả khi không dùng tới.

---

## §2. Đường cong throughput

`pgbench -S -M prepared -T 12` (chỉ SELECT, để đo thuần CPU/lock):

| Clients | tps | Latency TB | So với đỉnh |
|---|---|---|---|
| 1 | 33.055 | 0,030 ms | 22% |
| 2 | 57.692 | 0,035 ms | 38% |
| 4 | 91.116 | 0,044 ms | 59% |
| **8** | **153.627** | **0,052 ms** | **100% ← ĐỈNH (= 8 core)** |
| 16 | 139.496 | 0,115 ms | 91% |
| 32 | 145.031 | 0,221 ms | 94% |
| 64 | 139.974 | 0,457 ms | 91% |
| 128 | 106.439 | 1,203 ms | 69% |
| 256 | 82.784 | 3,092 ms | **54%** |

```
tps (nghìn)
160 |            ●8
    |
140 |               ●16  ●32   ●64
120 |
100 |                              ●128
 90 |     ●4
 80 |                                    ●256
 60 |  ●2
 40 | ●1
    +--+--+--+--+---+---+---+----+----+
      1  2  4  8  16  32  64  128  256   clients
```

**Ba đoạn của đường cong, mỗi đoạn một cơ chế:**

1. **1 → 8 client: tăng gần tuyến tính** (33k → 154k = 4,65× cho 8× client). Đây là giai đoạn thêm core = thêm việc. Latency gần như không đổi (0,030 → 0,052 ms).
2. **8 → 64 client: phẳng, dao động 140–153k.** Mọi core đã bận; thêm client không thêm được throughput, chỉ thêm hàng đợi. Latency tăng **8,8×** (0,052 → 0,457 ms) trong khi throughput **giảm nhẹ**. Đây là vùng bạn đang trả latency mà không mua được gì.
3. **64 → 256 client: giảm hẳn.** 140k → 83k (**−41%**). Latency ×6,8. Giờ thì thêm client **lấy đi** throughput.

**Chỉ số cần nhìn không phải throughput mà là tích `throughput × latency`:**

| Clients | tps × latency (≈ số request đang trong hệ) |
|---|---|
| 8 | 153.627 × 0,000052 = **8,0** |
| 32 | 145.031 × 0,000221 = **32,1** |
| 256 | 82.784 × 0,003092 = **256,0** |

Đây chính là **Little's Law** hiện ra chính xác trong dữ liệu: `L = λ × W`. Số request "trong hệ" **luôn bằng số client**, bất kể bạn có bao nhiêu core. Ở 256 client, 8 cái đang chạy và **248 cái đang chờ** — chỉ là chúng chờ trong OS scheduler thay vì trong pool.

### Read-write kể một câu chuyện hoàn toàn khác

`pgbench` mặc định (TPC-B, có ghi):

| Clients | tps | Latency TB |
|---|---|---|
| 8 | 1.165 | 6,87 ms |
| 32 | 2.423 | 13,21 ms |
| 128 | **3.060** | 41,83 ms |

**Throughput vẫn TĂNG tới 128 client** — ngược hẳn với read-only. Lý do: tải ghi bị chặn ở **fsync WAL**, không ở CPU. Trong lúc một backend chờ đĩa xác nhận, core rảnh để phục vụ backend khác. Nhiều client hơn = che lấp được nhiều I/O latency hơn (đây cũng là cơ chế của `commit_delay` và group commit — Day 37).

So sánh trực tiếp: read-only 153.627 tps vs read-write 1.165 tps ở cùng 8 client — **chênh 132 lần**. Đó là giá của việc phải ghi bền vững.

> **Kết luận thiết kế: pool size đúng phụ thuộc tỉ lệ đọc/ghi và mức độ I/O-bound của tải.** Công thức `core×2` là điểm khởi đầu cho tải hỗn hợp, không phải chân lý. Cách đúng là **đo đường cong này trên chính hệ của bạn** — mất 10 phút và cho bạn con số thật thay vì con số đi mượn.

### 🔧 Tình huống thực tế — "tăng pool lên cho nhanh"

Service Java, p99 tăng khi có traffic. Ai đó tăng `maximumPoolSize` từ 20 → 100. Kết quả: p99 **tệ hơn**, và giờ thêm cả timeout ở DB. Team tăng tiếp lên 200. Tệ hơn nữa. Kết luận sai được rút ra: "Postgres không scale, phải chuyển sang X".

Điều thật sự xảy ra, đọc thẳng từ bảng trên: từ 20 → 200 client, throughput giảm ~40% và latency tăng ~27×. Việc tăng pool **chuyển hàng đợi từ chỗ rẻ (pool trong app, chỉ là một `ArrayBlockingQueue`) sang chỗ đắt (OS scheduler + spinlock trong Postgres)**.

Cách chẩn đoán đúng khi p99 tăng: **đừng chạm pool size trước.** Xem `pg_stat_statements` tìm query chậm, xem wait events (Day 40) tìm chỗ tắc thật. Tăng pool là thứ **cuối cùng** nên thử, và thường là nên **giảm**.

---

## §3. Little's Law và hàng đợi

```
L = λ × W        (số request trong hệ = tốc độ đến × thời gian ở trong hệ)
W ≈ S / (1 − ρ)  (thời gian chờ bùng nổ khi utilization ρ → 1)
```

Bảng §2 đã cho thấy `L = số client` chính xác tới chữ số thứ hai. Vế thứ hai giải thích *vì sao* latency bùng nổ:

| ρ (utilization) | W / S (chờ gấp mấy lần thời gian phục vụ) |
|---|---|
| 0,50 | 2× |
| 0,80 | 5× |
| 0,90 | 10× |
| 0,95 | 20× |
| 0,99 | 100× |

**Với 8 core, ρ = 1 khi có 8 request đang chạy.** Mọi client thứ 9 trở đi chỉ làm tăng W. Điều này khớp chính xác với đỉnh đo được ở 8 client.

Nhưng thực tế còn tệ hơn lý thuyết hàng đợi thuần, vì Postgres **không** phải hệ phục vụ có tốc độ phục vụ cố định:

- **Context switch:** 256 process tranh 8 core ⇒ scheduler đổi context liên tục, mỗi lần ~1–3 µs cộng với cache CPU bị đá ra.
- **Cache CPU:** L1/L2 của mỗi core chỉ vài trăm KB. 32 process luân phiên trên một core ⇒ mỗi lần quay lại đều cache-miss.
- **Spinlock:** khi nhiều process tranh cùng một lightweight lock (buffer mapping, procarray), chúng **quay vòng bận** đốt CPU chứ không ngủ. Chi phí tăng **siêu tuyến tính** theo số process tranh.

Ba thứ này cộng lại làm **tốc độ phục vụ S tự nó xấu đi khi ρ tăng** — nên đường cong không phẳng ra mà **đi xuống**.

### Công thức pool size

```
pool_size = (core_count × 2) + effective_spindle_count
          = (8 × 2) + 1..4
          = 17–20
```

Đối chiếu với số đo: đỉnh ở 8, vùng phẳng 8–32. **17–20 nằm giữa vùng phẳng — công thức khớp với thực nghiệm.**

Vì sao `×2` chứ không phải `×1` (bằng số core)? Vì mỗi request có phần **chờ I/O** (đọc page không có trong cache, ghi WAL) trong đó core rảnh. Hệ số 2 là để lấp những khoảng rảnh đó. Với tải hoàn toàn trong RAM (như test read-only ở đây), `×1` mới đúng — và đúng thật, đỉnh ở 8 = 8 core.

**Cách chọn cho hệ của bạn:**
- Tải chủ yếu đọc, dữ liệu vừa RAM → gần `core × 1`
- Tải hỗn hợp, có I/O → `core × 2 + 2`
- Tải ghi nặng, I/O-bound → có thể cao hơn (số đo read-write ở §2 vẫn tăng tới 128) — nhưng khi đó bạn nên tối ưu I/O (Day 37) chứ không phải tăng pool

---

## §4–§5. pgbouncer — đo có/không

pgbouncer 1.25.2, `pool_mode = transaction`, `default_pool_size = 20`, `max_client_conn = 1000`.

### Kết quả với `max_connections = 600` (Postgres chịu được hết)

`pgbench -S -M simple -T 15`:

| Clients | Trực tiếp tps | Trực tiếp lat | pgbouncer tps | pgbouncer lat | pgbouncer |
|---|---|---|---|---|---|
| 16 | **68.932** | 0,232 ms | 49.917 | 0,321 ms | **−27,6%** |
| 64 | **64.918** | 0,986 ms | 43.121 | 1,484 ms | **−33,6%** |
| 200 | **52.281** | 3,825 ms | 41.140 | 4,861 ms | **−21,3%** |
| 500 | **48.724** | 10,262 ms | 39.482 | 12,664 ms | **−19,0%** |

Read-write, 200 client:

| | tps | Latency |
|---|---|---|
| Trực tiếp | **2.678** | 74,68 ms |
| pgbouncer | 2.044 | 97,84 ms | **−23,7%** |

**pgbouncer THUA ở mọi mức đo được.** Đây là kết quả ngược với kỳ vọng và cần giải thích trung thực thay vì giấu đi.

### Vì sao pgbouncer thua ở lab này

1. **Query quá rẻ.** `SELECT ... WHERE aid = $1` mất ~0,02 ms thật sự. Thêm một chặng proxy (parse, forward, đọc lại response) tốn ~0,05–0,1 ms. **Overhead lớn hơn công việc.** Trên hệ thật, query 5–50 ms thì 0,1 ms proxy là 0,2–2% — không đo được.
2. **pgbouncer là một process, một thread.** Nó phải đẩy toàn bộ 50.000 tps qua một event loop trên **một core**, trong khi Postgres dùng cả 8 core. Ở tải này pgbouncer *chính là* nút cổ chai.
3. **Postgres 500 connection ở đây không hề khổ sở.** Tải đọc thuần, dữ liệu nóng trong `shared_buffers`, không có lock contention nào đáng kể. Kịch bản mà pgbouncer sinh ra để cứu — hàng trăm connection idle, catalog cache phình, contention nặng — không xảy ra.

**Bài học phương pháp: benchmark cho câu trả lời đúng với câu hỏi bạn hỏi, không phải với câu hỏi bạn tưởng bạn đang hỏi.** Benchmark này hỏi "pgbouncer có tăng throughput cho SELECT 0,02 ms không?" — câu trả lời là không, và nó đúng. Nhưng đó không phải lý do người ta dùng pgbouncer.

### Kết quả với `max_connections = 100` — đây mới là lý do thật

Trả `max_connections` về 100 (giá trị thật của lab), chạy lại 500 client:

| | Kết quả |
|---|---|
| **500 client trực tiếp** | `FATAL: sorry, too many clients already` — **pgbench chết ở client thứ 326** |
| **500 client qua pgbouncer** | **38.889 tps, latency 12,86 ms, 0 transaction lỗi**, dùng **21 backend** |

```
SHOW POOLS;
 database | cl_active | cl_waiting | sv_active | sv_idle | pool_mode
----------+-----------+------------+-----------+---------+-------------
 lab      |         0 |          0 |         0 |      20 | transaction
```

Và trong lúc chạy 300 client:
```
 database | cl_active | cl_waiting | sv_active | maxwait_us | pool_mode
----------+-----------+------------+-----------+------------+-------------
 lab      |        55 |        245 |        20 |       6403 | transaction
```

**55 client đang được phục vụ, 245 đang xếp hàng, 20 connection thật tới Postgres, chờ lâu nhất 6,4 ms.**

Đối chiếu bộ nhớ:

| | Backend thật | Bộ nhớ container |
|---|---|---|
| 200 client trực tiếp | 206 | **725,7 MB** |
| 300 client qua pgbouncer | **21** | **370,5 MB** |

**Với 1,5× số client, dùng 1/10 số backend và 51% bộ nhớ.**

### Vậy pgbouncer để làm gì?

| pgbouncer **không** làm | pgbouncer **có** làm |
|---|---|
| Tăng throughput (ở lab: **giảm 19–33%**) | **Cho phép client vượt xa `max_connections`** — 500 client trên `max_connections=100` |
| Giảm latency | **Giới hạn concurrency thật** ⇒ giữ Postgres ở vùng phẳng của đường cong §2 |
| Sửa query chậm | **Tiết kiệm bộ nhớ**: 21 backend thay vì 300 |
| | **Xoá chi phí tạo connection** (~1–5 ms) cho client kết nối ngắn (serverless, PHP, script, cron) |
| | **Hàng đợi tường minh, đo được** (`cl_waiting`, `maxwait`) thay vì hàng đợi ẩn trong OS scheduler |

**Nói gọn: pgbouncer là một cái van, không phải một cái bơm.** Nó không làm nước chảy nhanh hơn — nó ngăn bạn mở vòi quá to.

### 🔧 Tình huống thực tế — khi nào pgbouncer thật sự bắt buộc

| Tình huống | Vì sao cần |
|---|---|
| **Kiến trúc microservice**: 20 service × pool 20 = 400 connection, nhưng chỉ ~30 cái bận cùng lúc | Không service nào chịu giảm pool của mình. pgbouncer gom lại thành 30 connection thật. |
| **Serverless / Lambda**: mỗi invocation một connection, burst 1.000 cái | Postgres chết ngay ở `max_connections`. Đây là lý do RDS Proxy tồn tại. |
| **Temporal worker** (kiến trúc của bạn): mỗi worker một pool, số worker co giãn theo tải | Số connection = f(số pod) — thứ mà autoscaler quyết định, không phải bạn. |
| **Blue-green deploy**: trong 2 phút cả bản cũ và mới cùng chạy | Số connection **gấp đôi** trong cửa sổ deploy. Đây là cách deploy làm sập DB. |
| **Failover**: replica lên làm primary, mọi client kết nối lại cùng lúc | Cơn bão connection ngay lúc hệ thống yếu nhất. |

Bốn tình huống cuối có điểm chung: **số connection bị quyết định bởi thứ bạn không kiểm soát trực tiếp.** Đó là lúc cần một cái van.

**Về hiệu năng của bản thân pgbouncer:** nó single-thread nên trần khoảng 20–50k tps mỗi instance. Vượt ngưỡng đó phải chạy nhiều instance (`so_reuseport`) hoặc dùng pgcat/Odyssey (đa luồng). Ở lab, chính pgbouncer là nút cổ chai — đó là số đo, không phải suy đoán.

---

## §6. Cái gì hỏng ở transaction mode

Đây là phần nguy hiểm nhất, và kết quả đo cho thấy **nó nguy hiểm theo cách tệ hơn tôi tưởng**.

### a) `SET` session-level — hỏng KHÔNG ĐỀU

Với **một** client:
```bash
psql -p 6432 -c "SET work_mem='64MB'" -c "SHOW work_mem"
--  work_mem
-- ----------
--  64MB       ← CHẠY ĐÚNG (!)
```

Chạy đúng, vì chỉ có một client nên nó luôn được cấp lại đúng server connection cũ.

Với **16 client song song**, mỗi client `SET work_mem='99MB'` → `pg_sleep(0.05)` → `SHOW work_mem`:

```
   2  4MB     ← MẤT SET
  14  99MB
```

**2 trong 16 client (12,5%) nhận được `4MB` thay vì `99MB`.**

Đây là loại bug tệ nhất có thể có:
- **Không có lỗi.** Query chạy, trả kết quả, không có exception nào để bắt.
- **Chạy đúng khi test.** Dev test một mình → 100% đúng. Staging tải nhẹ → 100% đúng. Production tải nặng → hỏng 10–30%.
- **Hậu quả im lặng.** `SET search_path` mất ⇒ query nhầm schema hoặc lỗi "relation does not exist" ngẫu nhiên. `SET work_mem` mất ⇒ query tràn đĩa ngẫu nhiên. `SET timezone` mất ⇒ **dữ liệu sai lệch múi giờ ở 12% số dòng**.

Cái cuối là thảm hoạ thật sự — dữ liệu sai không thể phát hiện được từ log.

**Cách sửa:**
```sql
BEGIN;
  SET LOCAL work_mem = '64MB';    -- an toàn: gắn với transaction, tự trả về khi COMMIT
  -- query ở đây
COMMIT;
```
Hoặc gắn vĩnh viễn vào role/database (pgbouncer không đụng tới):
```sql
ALTER ROLE bao_cao SET work_mem = '256MB';
ALTER DATABASE lab SET search_path = 'app, public';
```

### b) Advisory lock session-level — RÒ RỈ, và không tự dọn

```bash
psql -p 6432 -c "SELECT pg_advisory_lock(42)" -c "SELECT count(*) FROM pg_locks WHERE locktype='advisory'"
--  con_lock
-- ----------
--         1
```
Client thoát. Kiểm tra **từ một kết nối trực tiếp**:
```sql
SELECT count(*) FROM pg_locks WHERE locktype='advisory';   -- 1  ← VẪN CÒN
SELECT pid, objid, granted FROM pg_locks WHERE locktype='advisory';
--  2746 | 42 | t
```

**Lock vẫn được giữ sau khi client đã ngắt kết nối.** Vì connection thật tới Postgres không hề đóng — nó quay về pool của pgbouncer, mang theo cái lock.

Hậu quả: **mọi lần thử `pg_advisory_lock(42)` sau đó đều treo vĩnh viễn**, trừ khi ngẫu nhiên vớ đúng cái server connection đang giữ lock (lúc đó nó lại thành công vì lock là re-entrant trong cùng session — càng khó debug hơn).

Phải giết thủ công:
```sql
SELECT pg_terminate_backend(pid) FROM pg_locks WHERE locktype='advisory';
```

**Sửa: luôn dùng bản `_xact_`.**
```sql
BEGIN;
  SELECT pg_advisory_xact_lock(42);   -- tự nhả khi COMMIT/ROLLBACK, an toàn 100%
  -- việc cần độc quyền
COMMIT;
```
Đo được: bản `_xact_` giữ lock trong transaction (count = 1) và nhả sạch sau `COMMIT` (count = 0).

**Advisory lock session-level là thứ nguy hiểm nhất trong danh sách này**, vì nó không chỉ hỏng chức năng mà còn **để lại rác vĩnh viễn** trên server connection cho mọi client dùng sau.

### c) Temp table — cũng rò rỉ theo cùng cơ chế

```bash
psql -p 6432 -c "CREATE TEMP TABLE tt(x int)" -c "INSERT INTO tt VALUES (1)"
-- CREATE TABLE / INSERT 0 1   ← chạy được
```

Chạy được, và đó chính là vấn đề: temp table sống trên server connection đó. Client sau vớ phải connection đó sẽ thấy một cái bảng nó không tạo ra. 8 client song song kiểm tra `pg_class`: cả 8 đều thấy **0** temp table — tức nó nằm trên đúng một connection cụ thể, không thể dự đoán connection nào.

Kịch bản hỏng: hai request cùng làm `CREATE TEMP TABLE staging` → request thứ hai vớ đúng connection cũ → `ERROR: relation "staging" already exists`. Hoặc tệ hơn: `CREATE TEMP TABLE IF NOT EXISTS` → nó dùng lại bảng cũ **còn dữ liệu của request trước**.

Sửa: `CREATE TEMP TABLE ... ON COMMIT DROP`, hoặc dùng CTE / bảng thật có `session_id`.

### d) Prepared statement — **đã được sửa** ở pgbouncer hiện đại

```bash
pgbench -p 6432 -M prepared -c 4 -T 5
-- tps = 38725, 0 failed
```

pgbouncer **1.25.2** hỗ trợ prepared statement trong transaction mode (từ 1.21). Đây là tin tốt lớn: lời khuyên cũ "phải đặt `prepareThreshold=0` với JDBC" **không còn đúng** nếu bạn chạy ≥ 1.21.

Nhưng phải **kiểm tra version thật** — rất nhiều hệ đang chạy 1.17/1.18 từ repo distro:
```bash
docker exec pgb pgbouncer --version
psql -p 6432 -U postgres -d pgbouncer -c "SHOW VERSION;"
```
Với < 1.21: JDBC cần `prepareThreshold=0`, pgx cần `QueryExecModeSimpleProtocol` hoặc `statement_cache_capacity=0`.

### Bảng tổng hợp — audit code của bạn theo bảng này

| Thứ dùng | Ở transaction mode | Đo được | Thay bằng |
|---|---|---|---|
| `SET work_mem/search_path/timezone` | **hỏng ngẫu nhiên** | **12,5% mất SET với 16 client** | `SET LOCAL` trong transaction, hoặc `ALTER ROLE/DATABASE SET` |
| `pg_advisory_lock()` | **rò rỉ vĩnh viễn** | lock còn sau khi client ngắt | `pg_advisory_xact_lock()` |
| `CREATE TEMP TABLE` | rò rỉ sang request khác | tạo được, tồn tại trên 1 server conn | `ON COMMIT DROP`, hoặc CTE |
| `LISTEN`/`NOTIFY` | **không dùng được** | (không đo — về nguyên tắc không thể) | polling bảng outbox, hoặc `session` mode cho riêng connection đó |
| Cursor `WITH HOLD` | không dùng được | | đọc hết trong 1 transaction |
| `PREPARE`/`EXECUTE` thủ công | hỏng nếu < 1.21 | **OK với 1.25.2** | nâng pgbouncer |
| Transaction dài / idle in transaction | giữ server conn, làm cạn pool | | `idle_in_transaction_session_timeout` |

**Cách audit nhanh trong codebase:**
```bash
grep -rn "pg_advisory_lock\|CREATE TEMP\|LISTEN \|WITH HOLD" --include=*.java --include=*.go .
grep -rn "SET \(work_mem\|search_path\|timezone\|statement_timeout\)" --include=*.java --include=*.go . | grep -v "SET LOCAL"
```

---

## §7. Cấu hình pool cho service thật

### Checklist tham số

| Tham số | Giá trị | Vì sao |
|---|---|---|
| `maximumPoolSize` | **`core × 2 + 2`**, thường 10–25 | Đo được: đỉnh ở `core`, vùng phẳng tới `core × 4`. **Không phải 100.** |
| `minimumIdle` | **bằng `maximumPoolSize`** | Pool co giãn ⇒ tạo connection lúc tải cao ⇒ thêm 1–5 ms đúng lúc tệ nhất |
| `connectionTimeout` | 2–5 s | Fail nhanh > treo. Timeout ở đây = tín hiệu pool quá nhỏ hoặc DB đang khổ |
| `maxLifetime` | 30 phút, **ngắn hơn** timeout của LB/pgbouncer | Tránh connection chết mà pool không biết |
| `idleTimeout` | 10 phút (vô nghĩa nếu `minimumIdle = max`) | |
| `leakDetectionThreshold` | 30–60 s | **Bắt connection rò rỉ** — nguyên nhân "pool exhausted" phổ biến nhất |
| `validationTimeout` | 1–3 s | |

Phía Postgres:
```sql
-- max_connections = tổng pool mọi service + dự phòng admin (~10)
-- ĐỪNG đặt to "cho chắc": chi phí duyệt PGPROC tuyến tính theo max_connections
ALTER SYSTEM SET idle_in_transaction_session_timeout = '5min';
ALTER ROLE app SET statement_timeout = '30s';
ALTER ROLE bao_cao SET statement_timeout = '10min';
ALTER ROLE bao_cao SET work_mem = '256MB';   -- gắn vào role: pgbouncer không đụng tới
```

### Tính cho hệ của bạn

```
[ ] Số service kết nối tới DB:                       ______
[ ] Số instance mỗi service (kể cả lúc autoscale đỉnh): ______
[ ] Pool size mỗi instance:                          ______
[ ] Số Temporal worker × pool của mỗi worker:        ______
[ ] ⇒ TỔNG connection lúc đỉnh:                      ______
[ ] ⇒ Nhân đôi trong cửa sổ blue-green deploy:       ______
[ ] max_connections hiện tại:                        ______
[ ] Số core của máy DB:                              ______
[ ] ⇒ Pool tổng NÊN là (core × 2 + 2):               ______
```

Truy vấn lấy số thật:
```sql
-- connection hiện tại theo ứng dụng
SELECT application_name, state, count(*)
FROM pg_stat_activity GROUP BY 1,2 ORDER BY 3 DESC;

-- bao nhiêu cái thật sự đang làm việc? (đây mới là con số quan trọng)
SELECT count(*) FILTER (WHERE state='active')            AS dang_chay,
       count(*) FILTER (WHERE state='idle')              AS idle,
       count(*) FILTER (WHERE state='idle in transaction') AS idle_in_xact,
       count(*)                                          AS tong
FROM pg_stat_activity WHERE backend_type='client backend';
```

**Nếu `dang_chay` ≪ `tong`** (ví dụ 12 vs 400) thì bạn đang trả tiền bộ nhớ và chi phí PGPROC cho 388 connection không làm gì — chính xác là bài toán pgbouncer sinh ra để giải.

**Nếu `idle_in_xact` > 0 và kéo dài** thì đó là vấn đề nghiêm trọng hơn cả pool size: nó chặn `VACUUM` (Day 23), giữ snapshot, giữ lock. Đặt `idle_in_transaction_session_timeout` ngay.

### Khuyến nghị cho kiến trúc của bạn

Nhiều service + Temporal worker co giãn ⇒ **có pgbouncer, `transaction` mode**, với:

```ini
pool_mode = transaction
default_pool_size = 20              # ≈ core × 2 + 2 của máy DB
max_client_conn = 2000              # thoải mái, mỗi client chỉ tốn ~2 kB ở pgbouncer
reserve_pool_size = 5               # dự phòng khi pool đầy
reserve_pool_timeout = 3
server_idle_timeout = 600
query_wait_timeout = 5              # fail nhanh thay vì xếp hàng vô hạn
```

Kèm bốn việc bắt buộc **trước** khi bật:
1. **Audit code** theo bảng §6 (grep advisory lock, `SET`, temp table, LISTEN).
2. **Kiểm tra version pgbouncer ≥ 1.21** nếu dùng prepared statement.
3. **Giảm pool phía app xuống 5–10** — pool app giờ chỉ là buffer tới pgbouncer, không phải tới Postgres. Quên bước này thì bạn có hai lớp hàng đợi chồng nhau và p99 tệ hơn trước.
4. **Giám sát `SHOW POOLS`**: `cl_waiting` và `maxwait` là hai chỉ số quan trọng nhất. `maxwait` > 1 s liên tục ⇒ `default_pool_size` quá nhỏ hoặc có query chậm đang giữ connection.

Cân nhắc **hai pool riêng**: một cho OLTP (`pool_size=20`, `statement_timeout=30s`), một cho báo cáo/ETL (`pool_size=4`, `statement_timeout=10min`, có thể trỏ sang replica). Query báo cáo 5 phút chiếm connection trong pool chung là cách làm cạn pool nhanh nhất.

---

## Bảng số liệu chính

| Phép đo | Kết quả |
|---|---|
| Máy | 8 core, 31 GB RAM, `shared_buffers=256MB` |
| **Bộ nhớ / connection** | **2,05 MB** (container 314,8 MB idle → 725,7 MB với 200 conn) |
| `pg_backend_memory_contexts` một backend | 1.432 kB, lớn nhất là `CacheMemoryContext` 512 kB |
| RSS theo `ps` | 229 MB/backend — **sai**, vì đếm lặp `shared_buffers` |
| **Đỉnh throughput read-only** | **8 client = 153.627 tps** (= đúng số core) |
| 256 client | 82.784 tps — **−46% so với đỉnh** |
| Latency 8 → 256 client | 0,052 ms → 3,092 ms — **59×** |
| Kiểm chứng Little's Law (`tps × latency`) | 8,0 / 32,1 / 256,0 với 8 / 32 / 256 client — **khớp chính xác** |
| **Read-write (TPC-B)** | 8 cl: 1.165 tps · 32 cl: 2.423 · **128 cl: 3.060 — vẫn tăng** |
| Read-only vs read-write ở 8 client | 153.627 vs 1.165 tps — **132×** |
| Công thức pool `core×2 + spindles` | **17–20** — nằm trong vùng phẳng đo được (8–32) ✅ |
| **pgbouncer vs trực tiếp, 16 cl** | 49.917 vs 68.932 tps — **pgbouncer −27,6%** |
| **pgbouncer vs trực tiếp, 500 cl** | 39.482 vs 48.724 tps — **pgbouncer −19,0%** |
| pgbouncer read-write, 200 cl | 2.044 vs 2.678 tps — **−23,7%** |
| **500 client, `max_connections=100`, trực tiếp** | **`FATAL: sorry, too many clients already`** — chết ở client 326 |
| **500 client, `max_connections=100`, pgbouncer** | **38.889 tps, 0 lỗi, 21 backend** |
| `SHOW POOLS` ở 300 client | `cl_active=55`, **`cl_waiting=245`**, `sv_active=20`, `maxwait_us=6403` |
| Bộ nhớ: 300 cl qua pgbouncer vs 200 cl trực tiếp | **370,5 MB vs 725,7 MB** — 1,5× client, **51% bộ nhớ** |
| **`SET work_mem` qua transaction mode, 16 client** | **2/16 (12,5%) nhận sai giá trị — không báo lỗi** |
| `pg_advisory_lock()` qua transaction mode | **rò rỉ: lock còn sau khi client ngắt**, phải `pg_terminate_backend` |
| `CREATE TEMP TABLE` qua transaction mode | tạo được, sống trên 1 server connection cụ thể |
| `-M prepared` qua pgbouncer 1.25.2 | **38.725 tps, 0 lỗi** — đã hỗ trợ từ 1.21 |

---

## Ba điều dễ hiểu sai

| Hiểu nhầm | Sự thật đo được |
|---|---|
| "pgbouncer làm database nhanh hơn." | **Chậm hơn 19–33% ở mọi mức đo.** Nó là một chặng proxy single-thread; với query 0,02 ms thì overhead lớn hơn công việc. pgbouncer là **cái van, không phải cái bơm**: giá trị của nó là 500 client chạy được trên `max_connections=100` (trực tiếp thì `FATAL` ở client 326), và 21 backend thay vì 300. |
| "Pool lớn hơn thì xử lý được nhiều request hơn." | Từ 8 lên 256 client: throughput **−46%**, latency **×59**. `tps × latency` luôn bằng số client (Little's Law) — tăng pool không tạo thêm core, nó chỉ **chuyển hàng đợi từ chỗ rẻ (pool trong app) sang chỗ đắt (OS scheduler + spinlock)**. Ngoại lệ quan trọng: tải **ghi** vẫn tăng tới 128 client vì nó chặn ở fsync chứ không ở CPU — nên phải đo, không đoán. |
| "Transaction mode chỉ hỏng `LISTEN/NOTIFY`, code của tôi không dùng nên an toàn." | `SET work_mem` **mất ngẫu nhiên 12,5%** với 16 client song song — **không có lỗi nào được ném ra**. Test một mình thì 100% đúng. `pg_advisory_lock()` **rò rỉ vĩnh viễn** trên server connection sau khi client ngắt, làm mọi lần xin lock sau đó treo. Đây là loại bug chỉ xuất hiện dưới tải và không để lại dấu vết trong log. |

---

## Áp dụng vào hệ thật

1. **Đo đường cong của chính bạn — 10 phút, cho con số thật thay vì con số đi mượn:**
   ```bash
   pgbench -i -s 50 -U app mydb
   for c in 1 4 8 16 32 64 128; do
     echo -n "clients=$c "
     pgbench -U app -d mydb -c $c -j 8 -T 20 -M prepared 2>&1 | grep '^tps'
   done
   ```
   Chạy cả `-S` (đọc) và mặc định (đọc-ghi). Đỉnh của tải hỗn hợp là pool size của bạn.

2. **Kiểm tra ngay tỉ lệ connection thật sự làm việc:**
   ```sql
   SELECT count(*) FILTER (WHERE state='active')            AS dang_chay,
          count(*) FILTER (WHERE state='idle in transaction') AS idle_in_xact,
          count(*) AS tong
   FROM pg_stat_activity WHERE backend_type='client backend';
   ```
   `dang_chay` ≪ `tong` ⇒ giảm pool hoặc thêm pgbouncer. `idle_in_xact` > 0 kéo dài ⇒ sửa ngay, nó chặn `VACUUM`.

3. **Giảm `maximumPoolSize` về `core × 2 + 2`, và đặt `minimumIdle = maximumPoolSize`.** Đây là thay đổi một dòng config với lợi ích lớn nhất trong danh sách này. Bật `leakDetectionThreshold = 60000` cùng lúc để bắt connection rò rỉ trước khi giảm pool làm lộ ra chúng.

4. **Đừng đặt `max_connections` to "cho chắc".** Chi phí duyệt `PGPROC` tuyến tính theo `max_connections`, kể cả khi connection không được dùng. Đặt = tổng pool + 10.

5. **Audit code trước khi bật transaction mode** — bảng §6, đặc biệt hai dòng đầu:
   ```bash
   grep -rn "pg_advisory_lock(" --include=*.java --include=*.go .   # → pg_advisory_xact_lock
   grep -rn "SET " --include=*.java --include=*.go . | grep -v "SET LOCAL"
   grep -rn "CREATE TEMP\|LISTEN " --include=*.java --include=*.go .
   ```
   Chuyển mọi `SET` phiên bản session sang `SET LOCAL` hoặc `ALTER ROLE ... SET`.

6. **Bật pgbouncer khi (và chỉ khi) số connection do thứ bạn không kiểm soát quyết định**: autoscaling, serverless, blue-green deploy, nhiều microservice. Nếu bạn có 3 service pool cố định 20 thì đừng thêm một thành phần vào đường quan trọng để không được gì.

7. **Nếu bật: giảm pool phía app xuống 5–10**, giám sát `cl_waiting` và `maxwait` từ `SHOW POOLS`, và đặt `query_wait_timeout = 5` để fail nhanh thay vì xếp hàng vô hạn.

8. **Tách pool cho báo cáo/ETL** (`pool_size=4`, `statement_timeout=10min`, lý tưởng là trỏ sang replica). Một query báo cáo 5 phút trong pool chung là cách làm cạn pool nhanh nhất và khó chẩn đoán nhất.

---

## Câu hỏi mở sang các ngày sau

- **Day 37 (WAL & checkpoint)** giải thích con số read-write ở §2: vì sao 1.165 tps thay vì 153.627, và vì sao throughput ghi vẫn tăng tới 128 client. Cũng là chỗ đo trực tiếp full-page write mà Day 35 §2 đã gặp (WAL 2,8× khi ghi rải rác).
- **Day 38 (replication lag)** cho lời giải thật cho §7: tách pool báo cáo sang **replica**, và hiểu cái giá — dữ liệu trễ bao nhiêu, và `hot_standby_feedback` ảnh hưởng vacuum ở primary thế nào.
- **Day 40 (wait events)** là công cụ chẩn đoán còn thiếu của hôm nay: khi throughput giảm ở 256 client, backend đang chờ **cái gì** cụ thể? `pg_stat_activity.wait_event_type = 'LWLock'` sẽ chỉ đúng vào spinlock contention mà §3 mới chỉ mô tả bằng lý thuyết.
- **Day 23 (autovacuum)** nối với `idle_in_transaction` ở §7: một connection idle-in-transaction giữ `xmin` cũ, làm `VACUUM` không dọn được dead tuple **trên toàn bộ database**. Pool lớn làm xác suất có một connection như thế tăng lên.
- **Câu hỏi mở thật sự:** ở §5, pgbouncer chậm hơn 19–33% vì bản thân nó là nút cổ chai single-thread. Ở quy mô nào thì phải chuyển sang pgcat/Odyssey (đa luồng), hay chạy nhiều pgbouncer với `so_reuseport`? Cách đo: theo dõi CPU của process pgbouncer — chạm 100% một core là chạm trần.

---

### Dọn dẹp

```bash
docker rm -f pgb
```
```sql
DROP TABLE pgbench_accounts, pgbench_branches, pgbench_history, pgbench_tellers;
```

> Lưu ý: trong lúc làm bài tôi đã tạm sửa `docker-compose.yml` (`max_connections` 100 → 600) rồi **trả lại 100**. File hiện đã về nguyên trạng.
