# Day 37 — Lời giải: WAL & checkpoint

> Bài chữa. Đo thật trên lab (Postgres 17, 8 core, `shared_buffers=256MB`, `wal_level=logical`). Mọi con số WAL lấy bằng `pg_wal_lsn_diff()` và `pg_stat_statements.wal_fpi`.
>
> Kết luận một câu: **86,3% lượng WAL của một `UPDATE` ngay sau checkpoint là full-page image — cùng lệnh đó chạy lần thứ hai chỉ tốn 1/3 WAL.** Và `synchronous_commit = off` nhanh hơn **84 lần**.

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án đo được | Bẫy |
|---|---|---|---|
| 1 | Insert 500k dòng sinh bao nhiêu WAL — nhiều hay ít hơn dữ liệu? | **Nhiều hơn.** Bảng không index: WAL 42 MB / dữ liệu 29 MB = **1,45×**. Bảng có **3 index: WAL 160 MB = 5,5× dữ liệu**, và INSERT chậm hơn **7,1 lần** (3.145 ms vs 442 ms). | Bẫy: mọi người nghĩ index chỉ tốn đĩa. Nó tốn **WAL**, và WAL đi qua fsync, replication, archive, backup. Mỗi index thêm vào là thêm chi phí ở **năm** chỗ. |
| 2 | Cùng lệnh chạy ngay sau checkpoint vs lâu sau checkpoint chênh bao nhiêu? | **147 MB vs 46 MB — 3,2×.** `wal_fpi`: **16.238 vs 6**. FPI chiếm **86,3%** WAL ở lần đầu, **0,1%** ở lần sau. | Bẫy: tôi tưởng chênh vài chục phần trăm. Thực tế phần lớn WAL của lần đầu **không phải dữ liệu** mà là bản sao nguyên page. |
| 3 | `synchronous_commit = off` nhanh hơn bao nhiêu, đánh đổi gì? | **84× ở 1 client** (309 → 25.941 tps), **68× ở 8 client** (1.388 → 94.065 tps). Đánh đổi: mất tối đa `wal_writer_delay × 3 = 600 ms` transaction cuối khi crash. | Bẫy quan trọng: nó **không** làm hỏng database. Khác hoàn toàn với `fsync=off`. Database vẫn nhất quán, chỉ mất vài trăm ms cuối. Đây là đánh đổi hợp lệ, không phải "cheat". |

---

## §1. WAL là gì

```sql
SHOW wal_level;          -- logical
SHOW wal_segment_size;   -- 16MB
```

| GUC | Giá trị lab | Mặc định PG17 |
|---|---|---|
| `wal_level` | **`logical`** | `replica` |
| `max_wal_size` | 1024 MB | 1 GB |
| `min_wal_size` | 80 MB | 80 MB |
| `checkpoint_timeout` | 300 s | 5 min |
| `checkpoint_completion_target` | 0.9 | 0.9 |
| `full_page_writes` | **on** | on |
| `synchronous_commit` | on | on |
| `wal_compression` | **off** | off |
| `wal_buffers` | 8 MB (1024 × 8 kB) | −1 (tự động) |

**Lưu ý quan trọng cho mọi số đo hôm nay: lab chạy `wal_level = logical`** (để Day 39 làm CDC). Mức này sinh WAL **nhiều hơn `replica`** vì phải ghi thêm thông tin để logical decoding tái tạo được thay đổi ở mức dòng — đáng kể nhất là khi có `REPLICA IDENTITY FULL`. Với `wal_level = replica`, các con số dưới đây sẽ thấp hơn khoảng 5–15%.

WAL hiện tại: **43 segment × 16 MB = 688 MB**.

### Vì sao thiết kế này thắng

Ba lý do, và lý do thứ ba mới là quan trọng nhất về lâu dài:

1. **Ghi tuần tự thay cho ghi ngẫu nhiên.** Sửa 1.000 dòng rải khắp bảng = 1.000 lần ghi ngẫu nhiên; ghi WAL = 1 lần ghi tuần tự. Dirty page được đẩy xuống sau, theo lô.
2. **Crash recovery.** Replay WAL từ checkpoint gần nhất.
3. **WAL là một cái log, và log là thứ có thể replicate.** Đây là nền của streaming replication (Day 38), PITR, và logical decoding/CDC (Day 39).

Ý tưởng này giống hệt Kafka: **append-only log là nguồn chân lý, trạng thái chỉ là kết quả replay log.** Khác biệt là Postgres giữ log ngắn (xoá sau checkpoint) còn Kafka giữ log dài theo retention. Nhưng cơ chế cốt lõi — *ghi ý định trước, áp dụng sau* — là một.

---

## §2. Đo lượng WAL sinh ra

| Thao tác | Số dòng | WAL sinh ra | Dữ liệu thật | Khuếch đại | Thời gian |
|---|---|---|---|---|---|
| `INSERT`, **không index** | 500.000 | **42 MB** (43.766.328 B) | 29 MB (30.277.632 B) | **1,45×** | 442 ms |
| `INSERT`, **3 index** | 500.000 | **160 MB** (167.346.904 B) | — | **5,5×** dữ liệu | **3.145 ms** |
| `UPDATE` | 125.261 | **131 MB** (136.881.192 B) | — | **1.093 byte/dòng** | 1.802 ms |

### Ba con số cần đọc kỹ

**a) Không index đã khuếch đại 1,45×.** WAL record cho mỗi dòng gồm: header (~24 byte), thông tin page/offset, và bản sao dữ liệu dòng. Với dòng ~40 byte thì overhead ~45% là hợp lý.

**b) Ba index làm WAL tăng 3,82× và thời gian tăng 7,1×.**

```
42 MB  → 160 MB   (index chiếm 118 MB = 74% tổng WAL)
442 ms → 3.145 ms
```

Mỗi dòng chèn vào bảng có 3 index sinh **4 WAL record** (1 heap + 3 index), và mỗi lần chèn vào B-tree có thể gây page split → thêm FPI. **Chi phí index không phải là đĩa mà là WAL.**

Đây là con số để mang vào mọi cuộc thảo luận "thêm index này có sao không": trên bảng ingest cao, **mỗi index thêm vào tăng khoảng 25–40% lượng WAL**, và WAL đó phải: fsync xuống đĩa, truyền sang mọi replica, ghi vào archive, nằm trong backup. Một index "chỉ tốn 2 GB đĩa" có thể tăng 30% băng thông replication mỗi ngày mãi mãi.

**c) `UPDATE` tốn 1.093 byte cho mỗi dòng ~40 byte — khuếch đại 27×.**

Vì sao đắt đến thế:
- `UPDATE` trong Postgres = **xoá dòng cũ + chèn dòng mới** (MVCC, Day 21) ⇒ dòng mới có ctid mới ⇒ **mọi index phải cập nhật** (3 index ở đây), trừ khi HOT update áp dụng được — mà `device_id` có index nên nó không áp dụng được cho index đó.
- Cộng thêm **FPI** — đây mới là phần lớn nhất. §3 tách bạch con số này.

---

## §3. `full_page_writes` — nguồn khuếch đại lớn nhất

### Vấn đề torn page

Postgres ghi theo page 8 kB, đĩa ghi theo sector 512 B hoặc 4 kB. Mất điện giữa chừng ⇒ page trên đĩa nửa cũ nửa mới. WAL record kiểu "sửa byte thứ 100 của page X" **không thể replay** lên một page hỏng như thế.

Giải pháp: **lần đầu tiên** một page bị sửa sau mỗi checkpoint, ghi **nguyên cả page 8 kB** vào WAL (full page image — FPI). Các lần sửa sau trên page đó chỉ ghi phần thay đổi.

### Đo trực tiếp

Cùng một `UPDATE` trên 158.048 dòng, chạy ba lần liên tiếp:

| Lần | Điều kiện | `wal_records` | **`wal_fpi`** | WAL | % WAL là FPI |
|---|---|---|---|---|---|
| **1** | ngay sau `CHECKPOINT` | 649.241 | **16.238** | **147 MB** | **86,3%** |
| **2** | không checkpoint | 650.313 | **6** | **46 MB** | 0,1% |
| **3** | không checkpoint | 650.345 | **1** | 47 MB | ~0% |

**Chênh 3,2×, và 86,3% WAL của lần đầu không phải dữ liệu mà là bản sao page.**

Kiểm chứng số học: 16.238 FPI × 8.192 byte = **133 MB**. Tổng WAL lần 1 là 147 MB. Phần "công việc thật" chỉ là 147 − 133 = **14 MB** — và đúng bằng phần dư của lần 2 (46 MB, trong đó phần lớn là WAL của index).

`wal_records` gần như y hệt cả ba lần (649k / 650k / 650k) — **số lượng thay đổi không đổi, chỉ có kích thước mỗi record đổi.** Đây là bằng chứng sạch nhất rằng FPI là toàn bộ khác biệt.

> **Hệ quả vận hành: ghi ngay sau checkpoint đắt hơn 3,2 lần.** Nếu checkpoint chạy mỗi 30 giây (vì `max_wal_size` quá nhỏ), bạn **luôn** ở trong vùng đắt — mọi page đều bị chạm lần đầu sau mỗi checkpoint. Đây là mối liên hệ nhân quả giữa §3 và §4 mà nhiều người bỏ sót.

Điều này cũng giải thích chính xác hiện tượng ở **Day 35 §2**: ghi 500k dòng rải rác tốn **316 MB** WAL còn ghi tập trung chỉ tốn **113 MB** (2,8×). Ghi rải rác chạm hàng nghìn page khác nhau, mỗi page một FPI 8 kB cho một dòng 40 byte. Ghi tập trung chạm ít page, mỗi page bị lấp đầy dần.

### `wal_compression`

```sql
ALTER SYSTEM SET wal_compression = 'lz4';
SELECT pg_reload_conf();
```

| | `wal_compression = off` | `wal_compression = lz4` |
|---|---|---|
| `wal_fpi` | 16.238 | 16.388 (như nhau) |
| **WAL** | **147 MB** | **107 MB** |
| Giảm | — | **−27,2%** |

Số FPI không đổi (vẫn phải ghi từng đó page), nhưng mỗi page được nén. **−27,2%** ở đây thấp hơn con số "40–70%" thường trích dẫn, vì dữ liệu lab là `double precision` ngẫu nhiên — gần như không nén được. Với dữ liệu thật (nhiều NULL, nhiều text lặp, nhiều page chưa đầy) tỉ lệ nén cao hơn nhiều.

**`lz4` gần như luôn đáng bật:** chi phí CPU ~1–3%, đổi lại giảm I/O ghi WAL, giảm băng thông replication, giảm dung lượng archive. Ba khoản, một cái giá.

```sql
-- so sánh nhanh trên chính hệ của bạn (chạy mỗi cái sau CHECKPOINT)
ALTER SYSTEM SET wal_compression = 'off';   -- rồi 'lz4', rồi 'zstd'
```
`zstd` nén tốt hơn `lz4` ~10–20% nhưng tốn CPU gấp 2–3 lần. Với hệ I/O-bound chọn `zstd`, CPU-bound chọn `lz4`.

### Tắt `full_page_writes`?

**Đừng, trừ khi bạn chắc chắn.** An toàn chỉ khi hệ lưu trữ đảm bảo ghi 8 kB nguyên tử: một số SAN, ZFS với `recordsize=8k`, hoặc một số cloud volume có cam kết rõ ràng. "Chúng tôi dùng NVMe nên chắc là ổn" **không phải** một đảm bảo — NVMe cũng có atomic write size riêng và thường là 4 kB.

Rủi ro không phải "chậm hơn" mà là **database hỏng không recover được sau mất điện**. Không đáng đổi lấy 30% WAL.

### 🔧 Tình huống thực tế — WAL bùng theo chu kỳ 5 phút

Grafana cho thấy `pg_wal_bytes` có răng cưa đều đặn đúng chu kỳ 5 phút, đỉnh cao gấp 4 lần đáy. Team nghi có cron job. Không có cron nào cả.

Đó chính là `checkpoint_timeout = 5min` cộng với FPI: ngay sau mỗi checkpoint, mọi page bị chạm lần đầu đều tốn 8 kB WAL; càng xa checkpoint thì càng nhiều page đã "ấm" và WAL càng rẻ.

Sửa: `checkpoint_timeout = 30min` + `max_wal_size = 16GB`. WAL trung bình giảm ~45%, và răng cưa dãn ra chu kỳ 30 phút với biên độ nhỏ hơn nhiều. Bật thêm `wal_compression = lz4` giảm tiếp.

Cái phải chấp nhận: thời gian crash recovery dài hơn (phải replay nhiều WAL hơn). Đo bằng `checkpoint_timeout` — worst case replay ≈ lượng WAL của một chu kỳ checkpoint. Đây là quyết định RTO, phải hỏi nghiệp vụ chứ không tự quyết.

---

## §4. Checkpoint

### Thống kê tích luỹ của lab

```sql
SELECT * FROM pg_stat_checkpointer;
-- num_timed = 380, num_requested = 49
-- write_time = 4.615.989 ms, sync_time = 27.200 ms, buffers_written = 604.993
```

**Tỉ lệ `num_requested / (num_timed + num_requested)` = 49/429 = 11,4%** — chấp nhận được (chuẩn: < 10%, và phần lớn 49 cái này là do tôi gõ `CHECKPOINT` thủ công trong các bài trước).

Chú ý `write_time` (4.616 s) so với `sync_time` (27,2 s) — tỉ lệ **170:1**. Đó là `checkpoint_completion_target = 0.9` đang làm việc: ghi được trải mỏng ra suốt 90% chu kỳ thay vì dồn một lúc, nên phần `sync` cuối cùng rất nhanh. **`sync_time` cao là dấu hiệu I/O đang nghẽn** — ở đây thì không.

### Ép checkpoint theo yêu cầu

`INSERT` 1.000.000 dòng ở hai cấu hình:

| | `max_wal_size = 128MB` | `max_wal_size = 4GB` |
|---|---|---|
| `num_timed` | 0 | 0 |
| **`num_requested`** | **3** | 1 (chính là lệnh `CHECKPOINT` tôi gõ) |
| **`buffers_written`** | **33.168** | **3.135** |
| `write_time` | **5.256 ms** | **46 ms** |
| Thời gian `INSERT` | 6.869 ms | 7.489 ms |

Log Postgres nói thẳng ra vấn đề:
```
LOG:  checkpoint starting: wal
LOG:  checkpoint complete: wrote 11132 buffers (34.0%); ... distance=144044 kB
LOG:  checkpoints are occurring too frequently (3 seconds apart)
LOG:  checkpoint starting: wal
LOG:  checkpoint complete: wrote 13453 buffers (41.1%); ...
LOG:  checkpoints are occurring too frequently (1 second apart)
```

**`buffers_written` chênh 10,6× và `write_time` chênh 114×.**

### Nhưng thời gian INSERT lại KHÔNG khá hơn — vì sao?

6.869 ms (128MB) vs 7.489 ms (4GB). Cấu hình "tốt" lại **chậm hơn 9%**. Đây là kết quả trung thực và cần giải thích thay vì giấu:

1. **Checkpointer ghi ở nền, không chặn INSERT.** Việc nó ghi 33.168 buffer không làm backend phải chờ — nó ăn vào I/O của cả hệ, và ở lab I/O còn dư dả.
2. **Ở quy mô lab, I/O không phải nút cổ chai.** Toàn bộ dataset gần vừa page cache của máy 31 GB.
3. **Chi phí thật của checkpoint dồn dập là FPI** (§3), mà một `INSERT` liên tục vào cuối bảng thì chạm ít page khác nhau ⇒ ít FPI ⇒ khoản đắt nhất không xuất hiện.

**Chỗ nó thật sự đau trên production:**
- **I/O spike:** 33.168 buffer × 8 kB = 265 MB fsync mỗi 1–3 giây. Trên đĩa mạng (EBS/PD) đó là ngốn hết IOPS burst và mọi query khác chậm theo.
- **FPI:** với tải OLTP ngẫu nhiên (không phải append tuần tự như test này), checkpoint mỗi 3 giây ⇒ **luôn** ở vùng đắt của §3 ⇒ WAL gấp 3.
- **Cạnh tranh với backend:** `buffers_written` cao nghĩa là backend cũng phải tự đẩy buffer ra khi cần chỗ (`buffers_backend`), làm query chậm trực tiếp.

**Bài học phương pháp: benchmark trên máy dư I/O sẽ không thấy vấn đề I/O.** Số đo đúng, kết luận suy ra từ nó phải cẩn thận. Chỉ số đáng tin ở đây là `buffers_written` (10,6×) và cảnh báo trong log, không phải wall-clock.

### Cấu hình khuyến nghị

| GUC | Lab | Production |
|---|---|---|
| `max_wal_size` | 1 GB | **8–32 GB** |
| `min_wal_size` | 80 MB | 2–4 GB |
| `checkpoint_timeout` | 5 min | **15–30 min** |
| `checkpoint_completion_target` | 0.9 | 0.9 (giữ nguyên) |

Mục tiêu: **checkpoint được kích hoạt bởi `timeout`, không bởi `max_wal_size`.** Kiểm tra:
```sql
SELECT num_timed, num_requested,
       round(100.0*num_requested/nullif(num_timed+num_requested,0),1) AS pct_requested
FROM pg_stat_checkpointer;
```
`pct_requested` > 10% ⇒ tăng `max_wal_size`. Đây là một trong ít chỗ mà "tăng gấp đôi rồi đo lại" là chiến lược đúng.

Cái phải trả: `max_wal_size` lớn cần **dung lượng đĩa cho `pg_wal`** (tối thiểu `max_wal_size` × 2 + dự phòng), và **thời gian crash recovery dài hơn**.

---

## §5. `synchronous_commit`

Mỗi INSERT là một transaction riêng (qua pgbench), đo 2 lần để chắc chắn:

| | 1 client | 8 client |
|---|---|---|
| `synchronous_commit = on` | **309 tps** / 3,24 ms | **1.388 tps** / 5,77 ms |
| `synchronous_commit = off` | **25.941 tps** / 0,039 ms | **94.065 tps** / 0,085 ms |
| **Chênh** | **84×** | **68×** |

Lặp lại lần hai: 307 / 25.427 và 1.407 / 94.065. **Ổn định.**

Con số 309 tps ở 1 client dịch ra: **3,24 ms cho mỗi commit**, và gần như toàn bộ là **một lần `fsync` xuống đĩa**. Với `off`, commit chỉ ghi vào bộ đệm HĐH và trả về ngay — 0,039 ms, nhanh hơn **83 lần**.

Đây cũng là lời giải cho con số ở **Day 36 §2**: read-only 153.627 tps vs read-write 1.165 tps (132×). Chênh lệch đó gần như hoàn toàn là **fsync**.

### Đánh đổi chính xác là gì

`wal_writer_delay = 200ms` ⇒ worst case mất **3 × 200 ms = 600 ms** transaction cuối cùng khi crash.

Ở 94.065 tps, 600 ms là **~56.000 transaction**. Nghe rất nhiều — nhưng phải hỏi đúng câu: *56.000 điểm dữ liệu cảm biến của 600 ms cuối trước khi server mất điện có giá trị gì?*

**Điều quan trọng nhất phải phân biệt:**

| | `synchronous_commit = off` | `fsync = off` |
|---|---|---|
| Sau crash, database | **nhất quán, hoạt động bình thường** | **có thể hỏng, không recover được** |
| Mất gì | vài trăm ms transaction cuối | **toàn bộ database** |
| Dùng được ở production? | **Có**, cho dữ liệu chấp nhận mất | **Không bao giờ** |

`synchronous_commit = off` là đánh đổi *độ bền của vài trăm ms cuối*. `fsync = off` là đánh đổi *tính toàn vẹn*. Chúng khác loại hoàn toàn, và việc nhầm hai cái này là lý do nhiều người sợ `synchronous_commit = off` một cách vô lý.

### Đặt theo từng transaction — đây mới là cách dùng đúng

```sql
-- luồng ghi telemetry: nhanh, chấp nhận mất 600 ms cuối
BEGIN;
  SET LOCAL synchronous_commit = off;
  INSERT INTO ts_kv SELECT ...;
COMMIT;

-- luồng ghi cấu hình / lệnh điều khiển / thanh toán: an toàn tuyệt đối
BEGIN;
  -- synchronous_commit = on (mặc định)
  UPDATE device SET config = ... WHERE id = ...;
COMMIT;
```

Hoặc gắn theo role — sạch hơn vì không phải sửa từng chỗ trong code:
```sql
CREATE ROLE ingest;
ALTER ROLE ingest SET synchronous_commit = off;   -- worker nạp telemetry dùng role này
ALTER ROLE app    SET synchronous_commit = on;    -- API dùng role này
```

Cách này có một ưu điểm lớn: **quyết định độ bền trở thành một phần của mô hình quyền hạn**, hiển thị được trong catalog, review được trong PR — thay vì nằm rải rác trong code.

### 🔧 Tình huống thực tế — 84× miễn phí cho ingest telemetry

Pipeline nạp telemetry ghi từng dòng một (mỗi message MQTT một INSERT, một transaction). Throughput trần ở ~1.400 tps trên 8 worker — đúng bằng con số đo được ở đây với `synchronous_commit = on`. Team định mua đĩa nhanh hơn.

Ba thay đổi, theo thứ tự hiệu quả:

1. **`SET LOCAL synchronous_commit = off`** cho luồng telemetry → **68×** (1.388 → 94.065 tps). Đổi lại: mất tối đa 600 ms dữ liệu cảm biến khi server mất điện — nghiệp vụ chấp nhận, vì thiết bị vẫn buffer và gửi lại.
2. **Gom lô**: 1.000 dòng một `INSERT ... VALUES (...), (...)` thay vì 1.000 transaction. Một fsync thay vì 1.000. Thường còn hiệu quả hơn cả (1), và **không mất gì cả** — đây nên là thứ thử trước.
3. `COPY` thay `INSERT` cho lô lớn.

Thứ tự đúng để thử: **(2) gom lô trước** — nó miễn phí. Chỉ khi gom lô không đủ (ví dụ vì yêu cầu latency per-message) thì mới dùng (1).

Không nên: mua đĩa nhanh hơn. Nó giải quyết đúng vấn đề nhưng đắt hơn 68× lần thay đổi một dòng config.

---

## §6. WAL bị giữ lại — nguy cơ đầy đĩa

Trạng thái ban đầu: 0 slot, `max_slot_wal_keep_size = -1` (**không giới hạn** — đây là mặc định và là mặc định nguy hiểm), `wal_keep_size = 0`.

Tạo một slot rồi "quên" nó:

```sql
SELECT pg_create_physical_replication_slot('slot_bo_quen', true);  -- true = reserve_wal ngay
-- (slot_bo_quen, 6/9BBFAE68)
```

| Giai đoạn | WAL trên đĩa | `wal_status` | WAL slot giữ |
|---|---|---|---|
| Trước (sau 2 `CHECKPOINT`) | 45 segment / **720 MB** | — | — |
| Tạo slot | — | `reserved` | 0 |
| Sau 2M dòng INSERT + 2 `CHECKPOINT` | 70 segment / **1.120 MB** | **`extended`** | **1.100 MB** |
| **Sau khi `DROP` slot + 2 `CHECKPOINT`** | 16 segment / **256 MB** | — | — |

**Slot không hoạt động giữ lại 1.100 MB WAL. Xoá nó xong, WAL từ 1.120 MB xuống 256 MB — giảm 4,4×.**

Chi tiết quan trọng: cần **hai** lần `CHECKPOINT` để thấy WAL thật sự giảm. Lần đầu chỉ cập nhật điểm mốc redo; lần hai mới xoá/tái dùng được các segment cũ hơn điểm đó.

Cột `wal_status` chuyển `reserved` → **`extended`** — nghĩa là slot đã vượt quá `max_wal_size` và đang giữ WAL vượt ngưỡng bình thường. Các trạng thái:

| `wal_status` | Nghĩa |
|---|---|
| `reserved` | WAL slot cần còn trong `max_wal_size` — bình thường |
| **`extended`** | Đã vượt `max_wal_size`, vẫn giữ được vì `max_slot_wal_keep_size = -1` — **cảnh báo** |
| `unreserved` | Vượt `max_slot_wal_keep_size`, WAL sắp bị xoá — slot sắp chết |
| `lost` | WAL cần đã bị xoá — **slot hỏng vĩnh viễn**, replica phải rebuild |

### Vì sao đây là sự cố kinh điển

1. Một replica bị gỡ (scale down, đổi kiến trúc, thử nghiệm) nhưng **slot không được xoá**.
2. Primary giữ WAL vô hạn (`max_slot_wal_keep_size = -1` là mặc định).
3. `pg_wal` phình dần — không ai để ý vì nó tăng chậm.
4. Đĩa đầy ⇒ **Postgres không ghi được WAL nữa ⇒ dừng nhận mọi ghi.** Không phải chậm — **dừng hẳn**.
5. Cứu chữa lúc đó rất khó: không xoá được WAL (slot còn giữ), không thêm được đĩa ngay.

Và một tác dụng phụ ít biết nhưng độc không kém: **logical slot không hoạt động cũng giữ `xmin`**, làm `VACUUM` không dọn được dead tuple **trên toàn bộ database** (Day 25). Bạn có thể có bảng phình gấp 5 lần mà `VACUUM` chạy suốt vẫn không dọn được gì — và nguyên nhân nằm ở một cái slot bị quên từ 3 tháng trước.

### Query monitoring — dùng ngay hôm nay

```sql
SELECT slot_name, slot_type, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_dang_giu,
       coalesce(pg_size_pretty(safe_wal_size), 'khong gioi han') AS con_du,
       coalesce(age(xmin)::text, '-') AS tuoi_xmin
FROM pg_replication_slots
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC;
```

**Alert khi bất kỳ điều nào:**
- `active = false` **và** `wal_dang_giu > 1 GB` → slot bị bỏ quên
- `wal_status IN ('extended','unreserved','lost')` → nguy hiểm
- `tuoi_xmin > 100.000.000` → đang chặn vacuum/freeze

Kèm hai truy vấn phụ:
```sql
-- tổng WAL trên đĩa
SELECT count(*) AS segment, pg_size_pretty(sum(size)) AS tong FROM pg_ls_waldir();
-- archive có đang fail không (nguyên nhân giữ WAL thứ hai)
SELECT archived_count, failed_count, last_failed_time, last_failed_wal FROM pg_stat_archiver;
```

### Bảo hiểm bắt buộc

```sql
ALTER SYSTEM SET max_slot_wal_keep_size = '50GB';   -- 10–20% dung lượng đĩa pg_wal
```

Khi slot vượt ngưỡng, Postgres **tự vô hiệu hoá nó** (`wal_status = 'lost'`) thay vì để đĩa đầy. Replica đó phải rebuild — nhưng **thà mất một replica còn hơn sập primary**.

Đây là một trong ít GUC mà "đặt là xong, không cần nghĩ thêm" — và nó không được bật mặc định, nên bạn phải chủ động.

---

## §7. Cấu hình cho hệ thật

### Bộ cấu hình đề xuất

```sql
-- === CHECKPOINT: mục tiêu là checkpoint theo timeout, không theo max_wal_size ===
ALTER SYSTEM SET max_wal_size = '16GB';
--   Lý do: lab với 1GB gây 3 checkpoint requested trong một INSERT 1M dòng và
--   log cảnh báo "occurring too frequently (1 second apart)".
--   Chọn: đủ chứa WAL của một chu kỳ checkpoint_timeout ở tải đỉnh.
--   Đo bằng: distance=... trong log checkpoint, nhân với số checkpoint mong muốn.
ALTER SYSTEM SET min_wal_size = '4GB';
--   Lý do: tránh tạo/xoá segment liên tục khi tải dao động.
ALTER SYSTEM SET checkpoint_timeout = '30min';
--   Lý do: FPI làm ghi ngay sau checkpoint đắt 3,2× (đo được). Checkpoint thưa
--   ⇒ ít thời gian ở vùng đắt. Giá: crash recovery lâu hơn — QUYẾT ĐỊNH RTO,
--   phải hỏi nghiệp vụ, không tự quyết.
ALTER SYSTEM SET checkpoint_completion_target = 0.9;
--   Giữ nguyên. Lab cho thấy nó hiệu quả: write_time/sync_time = 170:1.

-- === WAL ===
ALTER SYSTEM SET wal_compression = 'lz4';
--   Lý do: đo được −27,2% WAL trên dữ liệu khó nén nhất (double ngẫu nhiên).
--   Dữ liệu thật thường tốt hơn. Chi phí CPU 1–3%. Giảm I/O + replication + archive.
ALTER SYSTEM SET wal_buffers = -1;
--   Tự động = 1/32 shared_buffers. Ít khi cần chỉnh.
ALTER SYSTEM SET full_page_writes = on;
--   KHÔNG BAO GIỜ TẮT trừ khi storage đảm bảo atomic 8kB write bằng văn bản.

-- === ĐỘ BỀN: theo role, không toàn cục ===
ALTER SYSTEM SET synchronous_commit = 'on';         -- mặc định an toàn
ALTER ROLE ingest_telemetry SET synchronous_commit = 'off';
--   Lý do: đo được 68× throughput. Mất tối đa 600ms dữ liệu cảm biến khi crash —
--   thiết bị vẫn buffer và gửi lại. Với dữ liệu cấu hình/điều khiển: giữ 'on'.

-- === BẢO HIỂM ===
ALTER SYSTEM SET max_slot_wal_keep_size = '50GB';
--   Lý do: slot bỏ quên giữ 1.100MB chỉ sau 2M dòng ở lab. Trên production đó là
--   hàng trăm GB và đĩa đầy = database dừng ghi. Thà mất replica hơn sập primary.
ALTER SYSTEM SET log_checkpoints = on;
--   Miễn phí, và log cho biết chính xác 'distance=' để chỉnh max_wal_size.
```

### Với workload telemetry của bạn — đặt `synchronous_commit` thế nào

| Luồng | Giá trị | Lý do |
|---|---|---|
| **Ingest telemetry** (MQTT → DB) | **`off`** | 68× throughput. Mất 600 ms dữ liệu cảm biến khi crash là chấp nhận được — thiết bị buffer và gửi lại. |
| **Ghi alarm / sự kiện** | **`on`** | Mất một cảnh báo cháy là mất niềm tin. Volume thấp nên chi phí không đáng kể. |
| **Cấu hình thiết bị, lệnh điều khiển** | **`on`** | Người dùng nhấn "tắt máy bơm" — không được phép mất. |
| **Rollup / ETL nền** | **`off`** | Tính lại được từ dữ liệu thô. |
| **Bảng ghi audit / billing** | **`on`** (hoặc `remote_apply` nếu có sync replica) | Yêu cầu pháp lý. |

**Nhưng thử gom lô trước.** Gom 1.000 dòng vào một transaction cho hiệu quả tương đương và **không mất gì cả**. `synchronous_commit = off` chỉ nên dùng khi ràng buộc latency per-message không cho phép gom lô.

---

## Bảng số liệu chính

| Phép đo | Kết quả |
|---|---|
| `wal_level` của lab | **`logical`** (sinh WAL nhiều hơn `replica` ~5–15%) |
| WAL segment | 16 MB · 43 segment · 688 MB |
| `INSERT` 500k, **không index** | WAL **42 MB** / dữ liệu 29 MB = **1,45×**, 442 ms |
| `INSERT` 500k, **3 index** | WAL **160 MB** = **3,82×** so với không index, **3.145 ms (7,1× chậm hơn)** |
| `UPDATE` 125.261 dòng | WAL **131 MB = 1.093 byte/dòng** (dòng ~40 byte ⇒ **27×**) |
| **`UPDATE` 158k ngay sau `CHECKPOINT`** | **147 MB**, `wal_records` 649.241, **`wal_fpi` 16.238**, **FPI = 86,3% WAL** |
| **Cùng lệnh, lần 2** | **46 MB**, `wal_records` 650.313, **`wal_fpi` 6** — **3,2× ít hơn** |
| Lần 3 | 47 MB, `wal_fpi` 1 |
| Kiểm chứng: 16.238 × 8.192 B | **133 MB** ≈ 147 − 14 MB "công việc thật" ✅ |
| `wal_compression = lz4` (sau checkpoint) | **107 MB vs 147 MB — −27,2%** (số FPI không đổi) |
| `pg_stat_checkpointer` tích luỹ | `num_timed` 380 / `num_requested` 49 = **11,4% requested** |
| `write_time : sync_time` | 4.616 s : 27,2 s = **170:1** (completion_target 0.9 làm việc) |
| `max_wal_size=128MB`, INSERT 1M | `num_requested` **3**, `buffers_written` **33.168**, log: *"checkpoints are occurring too frequently (1 second apart)"* |
| `max_wal_size=4GB`, INSERT 1M | `num_requested` 1, `buffers_written` **3.135** — **ít hơn 10,6×** |
| Thời gian INSERT ở hai cấu hình | 6.869 vs 7.489 ms — **không khá hơn** (lab dư I/O; xem giải thích §4) |
| **`synchronous_commit` on → off, 1 client** | **309 → 25.941 tps = 84×** (3,24 ms → 0,039 ms) |
| **on → off, 8 client** | **1.388 → 94.065 tps = 68×** |
| `wal_writer_delay` | 200 ms ⇒ worst case mất **600 ms** ≈ 56.000 transaction |
| **Slot bỏ quên giữ WAL** | **1.100 MB**, `wal_status` `reserved` → **`extended`** |
| WAL trên đĩa trước / có slot / sau khi xoá | 720 MB → **1.120 MB** → **256 MB** (**4,4×**) |
| `max_slot_wal_keep_size` mặc định | **−1 = không giới hạn** ← mặc định nguy hiểm |

---

## Ba điều dễ hiểu sai

| Hiểu nhầm | Sự thật đo được |
|---|---|
| "WAL to bằng lượng dữ liệu ghi." | Không index: 1,45×. **Ba index: 5,5× dữ liệu và INSERT chậm 7,1 lần.** `UPDATE`: **1.093 byte WAL cho một dòng 40 byte = 27×**. Và WAL đó không chỉ nằm trên đĩa — nó đi qua fsync, replication, archive, backup. **Mỗi index thêm vào tính tiền ở năm chỗ, không phải một.** |
| "Checkpoint chỉ ảnh hưởng thời gian recovery." | Nó là **biến quyết định lượng WAL**. `UPDATE` ngay sau checkpoint tốn **147 MB, trong đó 86,3% là full-page image**; cùng lệnh chạy lần hai tốn **46 MB**. Checkpoint mỗi 3 giây (log: *"occurring too frequently"*) nghĩa là bạn **luôn** ở vùng đắt ⇒ WAL gấp 3 mãi mãi. |
| "`synchronous_commit = off` là ăn gian, có thể hỏng database." | **Không.** Database vẫn **nhất quán hoàn toàn** sau crash — chỉ mất tối đa 600 ms transaction cuối. Khác hoàn toàn với `fsync = off` (cái đó mới làm hỏng database). Đổi lại **84× throughput**, và đặt được **theo từng transaction hoặc từng role** — telemetry dùng `off`, lệnh điều khiển dùng `on`. |

---

## Áp dụng vào hệ thật

1. **Kiểm tra ngay ba thứ này trên production — mất 2 phút:**
   ```sql
   -- (a) checkpoint có quá thường xuyên không?
   SELECT num_timed, num_requested,
          round(100.0*num_requested/nullif(num_timed+num_requested,0),1) AS pct_requested
   FROM pg_stat_checkpointer;                      -- pct_requested > 10% ⇒ tăng max_wal_size

   -- (b) có slot nào bị bỏ quên không?
   SELECT slot_name, active, wal_status,
          pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_giu
   FROM pg_replication_slots WHERE NOT active OR wal_status <> 'reserved';

   -- (c) wal_compression đã bật chưa?
   SHOW wal_compression;
   ```

2. **Bật `wal_compression = 'lz4'` — thay đổi một dòng, giảm ~27% WAL.** Ước lượng lợi ích: lấy `pg_stat_wal.wal_bytes` hoặc dung lượng archive mỗi ngày × 27%. Với hệ sinh 200 GB WAL/ngày đó là **54 GB/ngày** ít đi ở fsync, replication và backup.

3. **Đặt `max_slot_wal_keep_size` ngay hôm nay** (10–20% dung lượng `pg_wal`). Mặc định `-1` nghĩa là một slot bị quên có thể làm đĩa đầy và **dừng toàn bộ ghi**. Đây là bảo hiểm rẻ nhất trong danh sách này.

4. **Tăng `max_wal_size` lên 8–16 GB và `checkpoint_timeout` lên 15–30 phút** — nhưng thảo luận RTO với nghiệp vụ trước, vì nó kéo dài crash recovery. Bật `log_checkpoints = on` và đọc `distance=` trong log để chọn con số đúng.

5. **Với luồng ingest telemetry, thử theo thứ tự:** (a) **gom lô** 500–1.000 dòng một transaction — miễn phí, không mất gì; (b) nếu chưa đủ, `ALTER ROLE ingest SET synchronous_commit = off` — 68×, mất tối đa 600 ms; (c) `COPY` cho lô lớn. **Đừng mua đĩa nhanh hơn trước khi thử ba cái này.**

6. **Rà lại chiến lược index trên bảng ingest cao bằng con số WAL, không phải con số đĩa.** Với mỗi index đang có, hỏi: nó phục vụ query nào, `idx_scan` bằng bao nhiêu (Day 34 §2)? Ba index làm WAL tăng 3,82× — index không dùng tới là khoản chi phí thuần tuý ở năm chỗ.

7. **Chia `synchronous_commit` theo role, không theo lệnh** — nó biến quyết định độ bền thành thứ hiển thị trong catalog và review được trong PR, thay vì rải rác trong code.

8. **Thêm alert cho `pg_stat_archiver.failed_count` và `pg_ls_waldir()` tổng dung lượng.** `archive_command` fail là nguyên nhân giữ WAL phổ biến thứ hai sau slot, và nó im lặng hoàn toàn cho tới lúc đĩa đầy.

---

## Câu hỏi mở sang các ngày sau

- **Day 38 (replication lag)** dùng chính WAL này: replica nhận WAL stream từ primary, nên **mọi con số hôm nay là băng thông replication**. Ba index làm WAL gấp 3,82× ⇒ lag gấp 3,82×. Và `synchronous_commit = remote_write/remote_apply` là hai mức còn lại của bảng §5 mà hôm nay chưa đo được vì lab chưa có replica.
- **Day 39 (logical decoding & CDC)** giải thích vì sao lab chạy `wal_level = logical` và cái giá của nó — cũng là chỗ slot ở §6 trở thành thứ bạn *cố ý* tạo ra, nên monitoring ở §6 chuyển từ "phòng sự cố" thành "vận hành hàng ngày".
- **Day 40 (wait events)** trả lời câu hỏi còn treo ở §4: khi checkpoint dồn dập, backend chờ **cái gì** — `WALWrite`, `WALSync`, `DataFileWrite`, hay `BufferPin`? Đó là cách phân biệt "checkpoint đang hại" với "I/O đang nghẽn vì lý do khác".
- **Day 25 (long transaction & slot)** nối với §6: slot logical không hoạt động giữ `xmin` và chặn `VACUUM` **trên toàn bộ database**. Một cái slot bị quên 3 tháng trước có thể là nguyên nhân bảng phình 5× mà `VACUUM` chạy suốt vẫn không dọn được.
- **Câu hỏi mở thật sự:** ở §4, `max_wal_size` nhỏ làm `buffers_written` gấp 10,6× nhưng thời gian INSERT **không tệ hơn** vì lab dư I/O. Trên máy có I/O bị giới hạn (EBS gp3 3.000 IOPS chẳng hạn), điểm gãy nằm ở đâu? Cách đo: `pg_stat_io` (PG16+) tách được I/O của checkpointer với của backend — đó là chỗ nhìn thấy checkpoint đang lấn át query thật.

---

### Dọn dẹp

```sql
DROP TABLE t_wal, t_sync;
```
