# Day 33 — Lời giải: Vận hành partition — ATTACH, DETACH, retention

> Bài chữa. Đo thật, tiếp nối `ts_p` từ Day 32 (3 partition tháng 05/06/07, 5 triệu dòng, đã bỏ `ts_p_default`). Ngày hôm nay của container là **2026-08-10** — con số này quan trọng ở §4.
>
> Day 32 kết luận "partition không làm query nhanh hơn". Hôm nay là câu trả lời cho "vậy nó để làm gì": **`DROP PARTITION` nhanh hơn `DELETE + VACUUM FULL` 5.083 lần và không sinh một dead tuple nào.**

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án đo được | Bẫy |
|---|---|---|---|
| 1 | `DROP PARTITION` xoá 1,7 triệu dòng mất bao lâu? | **0,836 ms** | Không đọc dòng nào, không ghi WAL per-row, chỉ unlink file + xoá catalog. Nhưng nó vẫn cần `ACCESS EXCLUSIVE` trên bảng cha — ngắn, nhưng nếu có query đang chạy 5 phút thì nó xếp hàng **và chặn mọi query mới phía sau**. |
| 2 | `DELETE` cùng số dòng mất bao lâu? | **1.413,8 ms** cho riêng `DELETE`. Nhưng đó chưa xong việc: + `VACUUM` 303,2 ms + `VACUUM FULL` 2.532,5 ms = **4.249,5 ms** để thật sự trả đĩa. Tỉ lệ **5.083×**. | Con số 1,4 s trông không tệ — bẫy là ở đây. Trên bảng 400 GB thật, `DELETE` 1 tháng dữ liệu mất hàng giờ và sinh WAL bằng đúng lượng dữ liệu xoá. |
| 3 | Sau `DELETE`, kích thước bảng đổi thế nào? | **Không đổi. 289 MB trước, 289 MB sau `DELETE`, 289 MB sau cả `VACUUM`.** Chỉ `VACUUM FULL` mới xuống 189 MB. | Đây là điều gây sốc nhất: `VACUUM` dọn 1.722.141 dead tuple về 0 nhưng **không trả một byte nào cho OS**. Nó chỉ đánh dấu chỗ trống để tái dùng. Ổ đĩa của bạn vẫn đầy. |

---

## §1. Lý do tồn tại thật sự của partitioning

Cùng một việc — xoá 1.722.141 dòng dữ liệu tháng 5 — làm theo hai cách.

### Cách 1: `DROP PARTITION`

```sql
BEGIN;
DROP TABLE ts_p_2025_05;      -- Time: 0.836 ms
SELECT count(*) FROM ts_p;    -- 3.277.859 (đã mất đúng 1.722.141 dòng)
ROLLBACK;
```

### Cách 2: `DELETE` trên bảng phẳng

```sql
CREATE TABLE ts_flat AS SELECT * FROM ts_kv;   -- 289 MB heap / 396 MB total
CREATE INDEX ON ts_flat(ts);
VACUUM ANALYZE ts_flat;
DELETE FROM ts_flat WHERE ts < '2025-06-01';   -- 1.722.141 dòng
```

### Bảng so sánh (đây là bảng để thuyết phục team)

| Cách | Thời gian | Dead tuple sinh ra | Kích thước heap sau | Total (heap+index) | Khoá |
|---|---|---|---|---|---|
| **`DROP TABLE partition`** | **0,836 ms** | **0** | — (file bị unlink) | — | `ACCESS EXCLUSIVE` trên cha, ~1 ms |
| `DELETE` | 1.413,8 ms | **1.722.141** | 289 MB (**không đổi**) | 396 MB | row lock |
| `DELETE` + `VACUUM` | +303,2 ms | dọn về 0 | **289 MB (vẫn không đổi)** | 396 MB | `SHARE UPDATE EXCLUSIVE` |
| `DELETE` + `VACUUM` + `VACUUM FULL` | +2.532,5 ms = **4.249,5 ms** | 0 | **189 MB** | 260 MB | **`ACCESS EXCLUSIVE` suốt 2,5 s** |

**Hai câu có số để thuyết phục team:**

> Xoá 1,7 triệu dòng bằng `DROP PARTITION` mất **0,8 mili giây** và không sinh rác; xoá cùng lượng đó bằng `DELETE` rồi `VACUUM FULL` mất **4,2 giây**, sinh 1,7 triệu dead tuple, và khoá bảng ở `ACCESS EXCLUSIVE` suốt 2,5 giây — chênh **5.083 lần**.
>
> Quan trọng hơn: `DELETE` + `VACUUM` **không trả lại một byte đĩa nào** (289 MB trước và sau), nên nếu retention của ta hiện đang chạy bằng `DELETE`, dung lượng đĩa chỉ tăng chứ không bao giờ giảm.

### Vì sao `VACUUM` không trả đĩa

`VACUUM` đánh dấu space trống trong từng page để tái sử dụng. Nó chỉ **cắt đuôi** file (truncate) khi các page **cuối cùng** trống hoàn toàn. Ở đây dữ liệu bị xoá là tháng 5 — nằm ở *đầu* file (correlation = 1, dữ liệu xếp theo thời gian) — nên phần trống nằm giữa/đầu, không phải cuối. File giữ nguyên kích thước.

Nghịch lý là: **nếu dữ liệu của bạn xếp theo thời gian (mọi bảng telemetry đều thế) thì `DELETE` dữ liệu cũ là trường hợp tệ nhất cho `VACUUM`** — đúng cái ta cần thu hồi lại là cái nó không thu hồi được.

### 🔧 Tình huống thực tế — cron `DELETE` chạy 3 năm

Một hệ IoT có cron mỗi đêm: `DELETE FROM telemetry WHERE ts < now() - interval '90 days'`. Sau 3 năm:
- Đĩa **1,8 TB** trong khi dữ liệu sống chỉ ~400 GB. Bloat 4,5×.
- Job chạy 6–8 tiếng mỗi đêm, chồng lấn giờ cao điểm sáng.
- WAL sinh ~200 GB/đêm → replica lag, `archive_command` không kịp, backup phình.
- `autovacuum` trên bảng đó gần như không bao giờ hoàn thành.
- Muốn thu hồi đĩa phải `VACUUM FULL` — cần **downtime nhiều giờ** và cần *free space bằng kích thước bảng* (mà đĩa đang đầy → không làm được). Bế tắc kinh điển.

Lối thoát duy nhất không downtime là `pg_repack` (viết lại online, cần dung lượng gấp đôi tạm thời) — hoặc migrate sang partition (§7) và không bao giờ rơi lại vào đây.

**Chốt: nếu bảng của bạn có retention theo thời gian, partition không phải tối ưu hoá — nó là kiến trúc bắt buộc.**

---

## §2. `ATTACH` và `DETACH`

Nạp 499.921 dòng (29 MB) vào bảng rời `ts_p_2025_08` rồi attach.

| Thao tác | Thời gian | Ghi chú |
|---|---|---|
| `ATTACH PARTITION` **không** CHECK | **396,6 ms** | Postgres quét toàn bộ 499.921 dòng dưới `ACCESS EXCLUSIVE` **trên bảng cha** |
| `DETACH PARTITION` | 4,8 ms | không quét gì |
| `ADD CONSTRAINT CHECK (ts >= ... AND ts < ...)` | 41,6 ms | có quét, nhưng **trên bảng rời** — chưa ai đụng vào |
| `ATTACH PARTITION` **có** CHECK | **3,5 ms** | **nhanh hơn 114×** |
| `DETACH ... CONCURRENTLY` trong transaction | **ERROR** | `ALTER TABLE ... DETACH CONCURRENTLY cannot run inside a transaction block` |
| `DETACH ... CONCURRENTLY` ngoài transaction | 6,1 ms | thành công |

**Điểm mấu chốt không phải "nhanh hơn 114×" mà là *cái gì bị khoá*.**

- Không CHECK: 396,6 ms đó là 396,6 ms **`ACCESS EXCLUSIVE` trên `ts_p`** — tức toàn bộ bảng telemetry của bạn đứng im, mọi SELECT/INSERT xếp hàng.
- Có CHECK: 41,6 ms quét diễn ra khi bảng còn **rời, chưa ai biết tới nó**, khoá không ảnh hưởng ai; rồi cửa sổ khoá cha chỉ còn **3,5 ms**.

Tổng thời gian là 45,1 ms vs 396,6 ms (8,8×), nhưng *thời gian gây gián đoạn* là 3,5 ms vs 396,6 ms (**113×**). Với bảng 100 triệu dòng, con số này thành khoảng **80 giây khoá toàn bảng** vs **~4 ms**. Đó là khác biệt giữa một incident và một non-event.

Cách tốt hơn nữa (Day 43 sẽ đào sâu): dùng `NOT VALID` để đẩy cả bước quét ra khỏi `ACCESS EXCLUSIVE`:

```sql
ALTER TABLE staging ADD CONSTRAINT c CHECK (ts >= '2025-08-01' AND ts < '2025-09-01') NOT VALID;
ALTER TABLE staging VALIDATE CONSTRAINT c;   -- chỉ SHARE UPDATE EXCLUSIVE
ALTER TABLE ts_p ATTACH PARTITION staging FOR VALUES FROM ('2025-08-01') TO ('2025-09-01');
```

### `DETACH CONCURRENTLY` — hai điều phải biết

**1. Không chạy được trong transaction block.**

```
ERROR:  ALTER TABLE ... DETACH CONCURRENTLY cannot run inside a transaction block
```

Cùng họ với `CREATE INDEX CONCURRENTLY` và `VACUUM`. Nó chạy hai giai đoạn nội bộ, cần commit giữa chừng. Hệ quả thực tế: **mọi migration tool bọc migration trong transaction (Flyway, Liquibase, golang-migrate mặc định) sẽ fail.** Phải đánh dấu migration là `no-transaction`.

**2. Nó để lại một `CHECK` constraint.**

```sql
SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid='ts_p_2025_08'::regclass;
```
```
        conname        | pg_get_constraintdef
-----------------------+---------------------------------------------------------------
 ts_p_2025_08_ts_check | CHECK (((ts IS NOT NULL) AND (ts >= '2025-08-01 00:00:00+00')
                       |         AND (ts < '2025-09-01 00:00:00+00')))
```

Postgres tự thêm constraint tương đương với biên partition cũ. Hai hệ quả:
- **Attach lại rất nhanh** (đo được 4,6 ms) vì constraint đã chứng minh sẵn — đây là mẹo miễn phí cho quy trình detach → sửa → attach lại.
- Nếu bạn detach để **dùng bảng đó cho việc khác**, constraint này sẽ chặn mọi INSERT ngoài khoảng cũ. Nhớ `DROP CONSTRAINT`.

### 🔧 Tình huống thực tế — mẫu bulk load qua staging

Pipeline nạp dữ liệu lịch sử từ S3 vào bảng phân vùng đang chạy production:

```sql
-- 1. tạo bảng rời, KHÔNG attach — không ai thấy, không khoá gì
CREATE TABLE tele_2025_08_stg (LIKE telemetry INCLUDING DEFAULTS INCLUDING STORAGE);
-- 2. COPY 80 triệu dòng vào, thoải mái, có thể mất 2 tiếng
COPY tele_2025_08_stg FROM PROGRAM 'aws s3 cp s3://... -' WITH (FORMAT csv);
-- 3. tạo index CONCURRENTLY? không cần — bảng chưa ai dùng, CREATE INDEX thường là được
CREATE INDEX ON tele_2025_08_stg (device_id, ts);
-- 4. chứng minh biên trước
ALTER TABLE tele_2025_08_stg ADD CONSTRAINT c CHECK (ts >= '2025-08-01' AND ts < '2025-09-01') NOT VALID;
ALTER TABLE tele_2025_08_stg VALIDATE CONSTRAINT c;
-- 5. cửa sổ khoá: vài mili giây
SET lock_timeout = '3s';
ALTER TABLE telemetry ATTACH PARTITION tele_2025_08_stg
  FOR VALUES FROM ('2025-08-01') TO ('2025-09-01');
ALTER TABLE tele_2025_08_stg DROP CONSTRAINT c;
```

So với `INSERT INTO telemetry SELECT ...` trực tiếp: nạp trực tiếp sinh WAL cho 80 triệu dòng vào bảng đang phục vụ, làm bloat index đang dùng, đẩy autovacuum, và nếu fail giữa chừng thì bạn có dữ liệu nửa vời. Mẫu staging + attach: hỏng thì chỉ cần `DROP TABLE` bảng staging.

**`lock_timeout` ở bước 5 là bắt buộc.** Không có nó, `ATTACH` xếp hàng sau một query dài và — vì nó xin `ACCESS EXCLUSIVE` — **mọi query mới sau nó cũng bị chặn**. Đó là cách một lệnh 4 ms làm sập cả hệ thống. Đặt timeout ngắn và retry.

---

## §3. Index trên bảng phân vùng

Quy trình không-downtime, đo từng bước:

| Bước | Lệnh | Thời gian | `indisvalid` của `idx_p_key` |
|---|---|---|---|
| 1 | `CREATE INDEX idx_p_key ON ONLY ts_p (key_id, ts)` | 4,5 ms | **`f`** (invalid) |
| 2 | `CREATE INDEX CONCURRENTLY idx_p_key_06 ON ts_p_2025_06 ...` | 1.132 ms | `f` |
| 2 | ... `idx_p_key_07` | 1.055 ms | `f` |
| 2 | ... `idx_p_key_05` | 1.131 ms | `f` |
| 2 | ... `idx_p_key_08` | 328 ms | `f` |
| 3 | `ALTER INDEX idx_p_key ATTACH PARTITION idx_p_key_05` | 3,2 ms | `f` |
| 3 | ... `idx_p_key_06` | 2,9 ms | **`f`** (mới 2/4) |
| 3 | ... `idx_p_key_07` | 2,8 ms | `f` |
| 3 | ... `idx_p_key_08` | 2,9 ms | **`t`** ← đổi ở đây |

**`indisvalid` của index cha chuyển `f → t` đúng vào lúc partition cuối cùng được attach.** Postgres đếm: khi mọi partition đều có index con tương ứng đã attach, index cha mới hợp lệ.

**Vì sao quy trình này an toàn hơn `CREATE INDEX` thẳng trên cha:**

| | `CREATE INDEX ON ts_p (...)` | Quy trình `ON ONLY` + `CONCURRENTLY` + `ATTACH` |
|---|---|---|
| Lock | **`ACCESS EXCLUSIVE` trên cha VÀ mọi partition, suốt toàn bộ thời gian build** | mỗi bước chỉ khoá 1 partition, và `CONCURRENTLY` không chặn ghi |
| Thời gian gián đoạn | tổng thời gian build (ở lab: ~3,6 s; thật: hàng giờ) | ~3 ms mỗi lần `ATTACH` |
| Fail giữa chừng | rollback toàn bộ, mất hết công | index con đã xong vẫn giữ; làm tiếp cái còn lại |
| Điều chỉnh nhịp | không | chạy từng partition, giãn ra qua nhiều đêm |

Điều thứ ba là quan trọng nhất trong thực tế: build index trên bảng 2 TB có 24 partition mất 10 tiếng. Làm một phát thì bạn có cửa sổ 10 tiếng để mọi thứ hỏng. Làm từng partition thì mỗi đêm một cái, hỏng thì làm lại đúng cái đó.

**Cảnh báo về `CREATE INDEX CONCURRENTLY`:** nó có thể fail và để lại index `indisvalid = f`. Phải kiểm tra sau mỗi lần:
```sql
SELECT indexrelid::regclass, indisvalid FROM pg_index WHERE NOT indisvalid;
```
Index invalid vẫn tốn chỗ, vẫn được cập nhật khi ghi, nhưng **không bao giờ được dùng để đọc** — tệ nhất mọi thế giới. Thấy thì `DROP INDEX` rồi làm lại.

### 🔧 Tình huống thực tế — index mới trên bảng phân vùng đang chạy

Cần thêm index `(tenant_id, ts)` lên `telemetry` (36 partition tháng, 2 TB). Ai đó chạy `CREATE INDEX ON telemetry (tenant_id, ts);` lúc 22h. Kết quả: `ACCESS EXCLUSIVE` trên toàn bộ 36 partition trong 9 tiếng. Mọi INSERT telemetry chặn. Ingest queue tràn sau 4 phút, message broker bắt đầu drop, mất 9 tiếng dữ liệu cảm biến. Ctrl-C lúc 23h → rollback thêm 40 phút.

Quy trình đúng, chạy rải 36 đêm (hoặc 3–4 partition mỗi đêm):
```sql
CREATE INDEX idx_tenant_ts ON ONLY telemetry (tenant_id, ts);
-- mỗi đêm:
SET statement_timeout = 0;
CREATE INDEX CONCURRENTLY idx_tenant_ts_202506 ON telemetry_2025_06 (tenant_id, ts);
ALTER INDEX idx_tenant_ts ATTACH PARTITION idx_tenant_ts_202506;
-- kiểm tra
SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;
```
Đặt `statement_timeout = 0` cho `CREATE INDEX CONCURRENTLY` — nếu pooler/role của bạn có timeout mặc định, index sẽ bị giết giữa chừng và để lại rác invalid.

---

## §4. Tự động hoá vòng đời partition

Hàm `quan_ly_partition(bảng, số_tháng_tương_lai, số_tháng_giữ)` từ README. Ngày trong container: **2026-08-10**.

### Chạy đúng như README viết (`p_giu_thang = 12`)

```sql
SELECT * FROM quan_ly_partition('ts_p', 2, 12);
```
```
 hanh_dong | ten_partition
-----------+---------------
 TAO       | ts_p_2026_08
 TAO       | ts_p_2026_09
 TAO       | ts_p_2026_10
 XOA       | ts_p_2025_05     ← 1.722.141 dòng
 XOA       | ts_p_2025_06     ← 1.666.668 dòng
 XOA       | ts_p_2025_07     ← 1.611.191 dòng
```

Sau lệnh đó: `SELECT count(*) FROM ts_p` = **499.921** (còn mỗi partition tháng 8). **Vừa mất 5 triệu dòng trong 9,7 mili giây.** (Ở lab tôi bọc trong `BEGIN; ... ROLLBACK;` nên dữ liệu còn nguyên.)

Đây không phải lỗi của hàm — nó làm đúng thứ được bảo. Nhưng nó minh hoạ chính xác vì sao **script retention là loại script nguy hiểm nhất bạn từng chạy trên production**: một tham số sai, một cái đồng hồ server lệch, một `current_date` khác múi giờ, và dữ liệu bốc hơi không có `WHERE` để review, không có undo.

Chạy lại với `p_giu_thang = 24` → chỉ `TAO`, không `XOA`. Chạy lần thứ ba → **0 dòng** (idempotent, an toàn để cron gọi mỗi giờ).

### Điều gì xảy ra nếu nó không chạy một tháng?

Ta không còn `ts_p_default` (đã bỏ cuối Day 32). Thử insert vào tháng chưa có partition:

```sql
INSERT INTO ts_p VALUES (1, 1, '2025-12-15', 1.0, null, null);
```
```
ERROR:  no partition of relation "ts_p" found for row
DETAIL:  Partition key of the failing row contains (ts) = (2025-12-15 00:00:00+00).
```

**Mọi INSERT lỗi. Toàn bộ ingest dừng.** Đây là failure mode kinh điển của partitioning: nó không xuống cấp từ từ, nó chết ngay tại 00:00:00.

Hàm tạo trước 2 tháng (`p_thang_tuong_lai = 2`) nên bạn có **2 tháng ân hạn** — cron phải hỏng liên tục 2 tháng mà không ai để ý thì mới sập. Nhưng "không ai để ý" là chuyện thường xảy ra với cron chạy êm suốt 2 năm.

**Có `DEFAULT` partition thì sao?** INSERT không lỗi nữa, nhưng bạn đổi một sự cố *ồn ào* lấy một sự cố *im lặng*: dữ liệu dồn vào default, không được prune (Day 32 §2 — default không bao giờ prune được), query chậm dần, và tệ nhất là khi bạn phát hiện ra và muốn tạo partition đúng cho tháng đó, Postgres phải **quét toàn bộ default dưới `ACCESS EXCLUSIVE`** để kiểm tra. Default càng phình, cửa sổ khoá càng dài.

Kết luận thực dụng: **có `DEFAULT` partition + alert khi nó khác rỗng.** Nó là chuông báo cháy, không phải phòng chứa đồ.

```sql
-- alert này phải chạy mỗi 15 phút
SELECT count(*) FROM telemetry_default;   -- phải luôn = 0
```

### Chạy nó bằng gì trên production?

| Cách | Ưu | Nhược | Khi nào chọn |
|---|---|---|---|
| **`pg_partman`** | đã được kiểm chứng, xử lý được rất nhiều edge case, có retention + rollup | thêm extension, RDS phải bật thủ công | mặc định — đừng tự viết nếu không có lý do |
| **`pg_cron`** | ở trong DB, không cần hạ tầng ngoài | chạy trên primary; failover thì sao? theo dõi thất bại kém | có sẵn pg_cron rồi |
| **Cron ngoài / k8s CronJob** | dễ log, dễ alert, dễ test | phải quản lý credential, phải chống chạy trùng | team không được cài extension |
| **Temporal workflow** | retry, visibility, alert khi fail — đúng thế mạnh của bạn | nặng cho một việc DDL | **khuyến nghị cho bạn**: bạn đã có Temporal, và cái bạn cần nhất ở đây là *biết khi nó fail* |

Với nền tảng Temporal của bạn, một workflow lịch chạy hàng ngày với activity `ensure_partitions(table, months_ahead)` + `drop_expired(table, retain)` cho bạn đúng thứ cron không có: **retry có backoff, alert khi thất bại N lần, và một trang lịch sử thấy được nó đã chạy những ngày nào**. Bắt buộc: activity phải idempotent (hàm này đã idempotent — đo được lần 2 trả 0 dòng).

### 🔧 Tình huống thực tế — ba cách script retention giết dữ liệu

1. **Múi giờ.** Server chạy UTC, `current_date` là 2026-01-01 lúc 07:00 giờ VN ngày 31/12 → xoá sớm hơn dự tính 1 ngày. Với `p_giu_thang` tính bằng tháng thì lệch 1 ngày = mất cả một partition tháng. **Luôn dùng `timestamptz` và cố định `SET TIME ZONE 'UTC'` trong script.**
2. **Regex khớp nhầm.** `c.relname ~ '\d{4}_\d{2}$'` cũng khớp `ts_p_backup_2025_05`, `ts_p_2025_05_old`. Một bảng backup ai đó đặt tên gần giống sẽ bị `DROP TABLE` im lặng. **Lọc thêm bằng `pg_inherits` (hàm này có làm — tốt) và đối chiếu prefix chính xác.**
3. **Không có phanh.** Hàm gọi `DROP TABLE` thẳng. Phiên bản production nên: (a) mặc định `dry_run = true` chỉ trả về danh sách; (b) từ chối xoá nếu số partition bị xoá > 1 trong một lần chạy; (c) `ALTER TABLE ... DETACH` trước, đợi 7 ngày, rồi mới `DROP` ở lần chạy sau. Bước (c) biến một lỗi vĩnh viễn thành một lỗi có 7 ngày để phát hiện.

```sql
-- phanh tối thiểu nên thêm vào hàm
IF (SELECT count(*) FROM ... ) > 1 THEN
  RAISE EXCEPTION 'Tu choi: se xoa % partition trong mot lan chay', n;
END IF;
```

---

## §5. Retention: xoá vs archive

Rollup dữ liệu tháng 5 xuống mức ngày trước khi xoá partition thô:

```sql
INSERT INTO ts_rollup_daily
SELECT device_id, key_id, ts::date, count(*), avg(dbl_v), min(dbl_v), max(dbl_v)
FROM ts_p_2025_05 GROUP BY 1,2,3;
```

| | Thô (`ts_p_2025_05`) | Rollup ngày |
|---|---|---|
| Số dòng | 1.722.141 | **1.295.870** |
| Kích thước total | 240 MB | **141 MB** |
| Tỉ lệ | 100% | **58,59%** |

**Rollup chỉ tiết kiệm được 41% — gần như vô dụng.** Đây là kết quả *ngược* với kỳ vọng của README (rollup thường xuống 1–5%).

Lý do, đo ra:

```sql
SELECT round(1722141::numeric/1295870, 2) AS mau_moi_nhom,
       count(DISTINCT device_id), count(DISTINCT key_id), count(DISTINCT ts::date)
FROM ts_p_2025_05;
--  mau_moi_nhom | 1.33 | 50000 device | 8 key | 31 ngay
```

**Trung bình chỉ 1,33 mẫu cho mỗi (device, key, ngày).** Dataset lab có 50.000 device × 8 key × 31 ngày = 12,4 triệu tổ hợp có thể, mà chỉ có 1,72 triệu dòng — dữ liệu **thưa**, mỗi device chỉ báo vài lần mỗi tháng. Gom 1,33 dòng thành 1 dòng (và dòng rollup còn *rộng hơn*: thêm `n, avg, min, max`) thì chẳng tiết kiệm gì.

### Công thức đúng

> **Tỉ lệ nén của rollup ≈ (số mẫu mỗi nhóm) × (width dòng thô / width dòng rollup).**

Rollup có ích khi **số mẫu mỗi nhóm lớn**. Với telemetry thật:

| Tần suất lấy mẫu | Mẫu / (device,key,ngày) | Rollup ngày còn lại |
|---|---|---|
| mỗi 10 giây | 8.640 | ~0,03% |
| mỗi 1 phút | 1.440 | ~0,2% |
| mỗi 5 phút | 288 | ~1% |
| mỗi 1 giờ | 24 | ~12% |
| **lab này** | **1,33** | **58,6%** ❌ |

**Vậy trước khi thiết kế rollup, hãy đo chính con số này trên dữ liệu thật của bạn:**

```sql
SELECT count(*)::numeric / count(DISTINCT (device_id, key_id, ts::date)) AS mau_moi_nhom
FROM telemetry WHERE ts >= now() - interval '7 days';
```

Nếu < 10, rollup ngày không đáng làm. Nếu > 100, nó là thứ đáng giá nhất bạn có thể làm với dữ liệu cũ.

### Ba mức nhiệt độ dữ liệu

| Mức | Cách làm | Chi phí |
|---|---|---|
| **Nóng** (0–7 ngày) | partition thường, index đầy đủ, SSD | cao |
| **Ấm** (7–90 ngày) | rollup xuống phút/giờ, bỏ bớt index, `fillfactor=100` | trung bình |
| **Lạnh** (>90 ngày) | `DETACH` → export Parquet/S3, hoặc `SET TABLESPACE cold` | thấp |

```sql
CREATE TABLESPACE cold LOCATION '/mnt/hdd/pg';
ALTER TABLE ts_p_2025_05 SET TABLESPACE cold;   -- ACCESS EXCLUSIVE + copy toàn bộ file
```

Lưu ý: `SET TABLESPACE` **copy toàn bộ file** dưới `ACCESS EXCLUSIVE`. Với partition 200 GB đó là hàng chục phút khoá. Làm trên partition đã `DETACH` rồi attach lại — cùng mẹo với §2.

### 🔧 Tình huống thực tế — hợp đồng nói 3 năm, đĩa nói 6 tháng

Hợp đồng với khách hàng công nghiệp yêu cầu giữ dữ liệu cảm biến **3 năm** để phục vụ điều tra sự cố. Dữ liệu thô: 2 TB/tháng → 72 TB cho 3 năm. Không khả thi.

Thiết kế theo tầng, đo tần suất lấy mẫu thật (mỗi 5 giây → 17.280 mẫu/device/key/ngày):

| Tầng | Giữ | Độ phân giải | Dung lượng |
|---|---|---|---|
| Thô | 14 ngày | 5 giây | 0,9 TB |
| Rollup phút | 90 ngày | 1 phút | 0,5 TB |
| Rollup giờ | 3 năm | 1 giờ | 0,3 TB |
| **Tổng** | | | **1,7 TB** (vs 72 TB) |

Vẫn đáp ứng đúng hợp đồng vì điều tra sự cố > 14 ngày tuổi chỉ cần xu hướng theo giờ. Điểm phải đàm phán rõ với khách và ghi vào hợp đồng: **"3 năm ở độ phân giải giờ, 14 ngày ở độ phân giải đầy đủ"** — nếu không, bạn sẽ bị hỏi dữ liệu giây của 8 tháng trước vào đúng lúc có kiện tụng.

Rollup phải chạy **trước** khi partition bị xoá, và phải kiểm chứng đã chạy xong trước khi cho phép xoá:
```sql
-- điều kiện chặn trong script retention
IF NOT EXISTS (SELECT 1 FROM ts_rollup_hourly WHERE gio >= '2025-05-01' AND gio < '2025-06-01') THEN
  RAISE EXCEPTION 'Chua rollup thang 2025-05, tu choi DROP partition';
END IF;
```

---

## §6. Sub-partitioning

`ts_p_2025_09` phân vùng tiếp theo `device_id`:

```sql
CREATE TABLE ts_p_2025_09 PARTITION OF ts_p
  FOR VALUES FROM ('2025-09-01') TO ('2025-10-01') PARTITION BY RANGE (device_id);
CREATE TABLE ts_p_2025_09_lo PARTITION OF ts_p_2025_09 FOR VALUES FROM (MINVALUE) TO (25000);
CREATE TABLE ts_p_2025_09_hi PARTITION OF ts_p_2025_09 FOR VALUES FROM (25000) TO (MAXVALUE);
```

| Quan hệ | Số dòng | Kích thước | `relkind` |
|---|---|---|---|
| `ts_p_2025_09` | — | **0 bytes** | `p` (trung gian) |
| `ts_p_2025_09_lo` | 1.322.507 | 203 MB | `r` |
| `ts_p_2025_09_hi` | 344.078 | 52 MB | `r` |

Cây partition sau khi xong:

```
ts_p                        level 0   không phải lá
├── ts_p_2025_05            level 1   lá
├── ts_p_2025_06            level 1   lá
├── ts_p_2025_07            level 1   lá
├── ts_p_2025_08            level 1   lá
├── ts_p_2025_09            level 1   KHÔNG phải lá
│   ├── ts_p_2025_09_lo     level 2   lá
│   └── ts_p_2025_09_hi     level 2   lá
├── ts_p_2026_08/09/10      level 1   lá
```
9 lá, 2 node trung gian.

### Pruning hoạt động ở cả hai tầng

| Query | Partition được quét | Planning | Execution |
|---|---|---|---|
| `ts` trong 09 **AND** `device_id = 42` | **1** — chỉ `ts_p_2025_09_lo` | 0,375 ms | **1,635 ms** |
| Chỉ lọc `ts` (khoảng tháng 9) | 2 — cả `_lo` và `_hi` | 0,152 ms | 275,4 ms |
| Chỉ lọc `device_id = 42` | mọi partition tháng, **nhưng ở tháng 9 chỉ `_lo`** | 0,342 ms | 2,230 ms |

Dòng thứ ba là điều thú vị nhất: `WHERE device_id = 42` không nói gì về `ts`, nên phải chạm mọi partition tháng — **nhưng bên trong tháng 9, Postgres vẫn prune bỏ `_hi`** vì 42 < 25000. Pruning ở mỗi tầng độc lập với tầng khác.

`Planning Time` 0,375 ms cho cây 2 tầng vs 0,298 ms cho `ts_p` 1 tầng ở Day 32 — chênh không đáng kể ở quy mô này. Chi phí thật của sub-partitioning không nằm ở planning của **một** query mà ở **số lượng partition nhân lên**: 12 tháng × 20 tenant = 240 lá, mỗi lá là một file, một dòng `pg_class`, một mục tiêu autovacuum, một bộ index riêng (ở đây mỗi lá đã tự có 3 index).

### Ghi chú: `Heap Fetches: 617421` trong Index Only Scan

Query "chỉ lọc ts" cho `Index Only Scan` nhưng `Heap Fetches` bằng đúng số dòng trả về — tức nó **không hề "only"**, phải chạm heap mọi dòng. Lý do: dữ liệu vừa `INSERT` xong, chưa `VACUUM`, nên visibility map trống. Đây là bài Day 11 quay lại: sau bulk load, **luôn `VACUUM ANALYZE`** — không chỉ để cập nhật statistics mà để bật visibility map cho index-only scan.

### Khi nào sub-partition đáng dùng

| Đáng | Không đáng |
|---|---|
| Multi-tenant với vài tenant **rất lớn** cần cô lập (khôi phục riêng, tablespace riêng, xoá riêng theo yêu cầu GDPR) | Chia đều theo hash chỉ để "phân tán" — Postgres không song song hơn nhờ thế |
| Query luôn có **cả hai** khoá trong `WHERE` | Query chỉ có một khoá (nhân đôi số scan không lợi ích) |
| Số lá cuối cùng < ~200 | 12 × 50 tenant = 600 lá |

### 🔧 Tình huống thực tế — GDPR và tenant offboarding

SaaS B2B, dữ liệu telemetry phân vùng theo tháng. Khách hàng lớn rời đi và yêu cầu xoá toàn bộ dữ liệu trong 30 ngày theo GDPR. Với partition chỉ theo tháng: `DELETE FROM telemetry WHERE tenant_id = 42` — 800 triệu dòng rải khắp 36 partition, chạy 14 tiếng, sinh 300 GB WAL, bloat mọi partition, rồi vẫn phải `pg_repack` từng cái.

Với sub-partition `LIST (tenant_id)` cho các tenant lớn: 36 lệnh `DROP TABLE telemetry_2025_XX_t42`, tổng **dưới 1 giây**, không bloat, đĩa trả về ngay. Và có thể chứng minh với auditor rằng dữ liệu đã bị xoá vật lý chứ không chỉ đánh dấu.

Đánh đổi: chỉ sub-partition cho tenant nằm trong top ~10 về dung lượng, phần còn lại dồn vào một partition `DEFAULT` chung. Cần một job định kỳ "promote" tenant vượt ngưỡng thành partition riêng (chính là mẫu `DETACH` → tách dữ liệu → `ATTACH` của §2).

---

## §7. Migrate bảng phẳng sang phân vùng — không downtime

Kế hoạch cho `ts_kv` (5.000.000 dòng, 289 MB heap / 396 MB total), ngoại suy sang bảng thật.

### Số liệu cơ sở đo được hôm nay

| Thao tác | Đo được | Suy ra tốc độ |
|---|---|---|
| `CREATE TABLE AS SELECT * FROM ts_kv` (5M dòng) | 3.488 ms | **1,43 triệu dòng/giây**, ~83 MB/s |
| `INSERT INTO ts_p SELECT ...` (1,67M dòng, có 3 index) | 11.649 ms | **143.000 dòng/giây** ← chậm hơn 10× vì phải maintain index |
| `CREATE INDEX` trên 5M dòng | 1.639 ms | |
| `CREATE INDEX CONCURRENTLY` trên 1,7M dòng | 1.132 ms | ~1,5M dòng/giây |
| `ATTACH` có CHECK | 3,5 ms | |

**Bài học quan trọng cho kế hoạch: copy vào bảng có index chậm hơn 10 lần.** Nên: copy vào partition **chưa có index**, tạo index sau, rồi attach.

### Kế hoạch từng bước

**Giả định bảng thật:** `telemetry`, 400 GB, 3 tỉ dòng, ingest 2.000 dòng/s, retention mong muốn 90 ngày.

| # | Bước | Ước tính | Rollback |
|---|---|---|---|
| 0 | **Kiểm tra chặn:** liệt kê mọi unique/PK không chứa `ts` (Day 32 §6). Nếu có → dừng, giải quyết trước. | 1 ngày | — |
| 1 | `CREATE TABLE telemetry_new (...) PARTITION BY RANGE (ts);` + tạo partition phủ toàn bộ quá khứ + 3 tháng tương lai + `DEFAULT` | phút | `DROP TABLE telemetry_new` |
| 2 | Bật **dual write** ở tầng app: mọi INSERT/UPDATE/DELETE ghi vào cả hai bảng, trong **cùng transaction**. Deploy sau feature flag. | 1 tuần dev | tắt flag |
| 3 | Copy lịch sử theo lô, **mỗi lô một transaction, mỗi lô một ngày**, chạy nền ngoài giờ cao điểm. Copy vào partition **chưa có index**. Ở tốc độ 1,4M dòng/s đo được: 3 tỉ dòng ≈ **36 phút CPU thuần**; thực tế trên đĩa production + throttle ≈ **8–24 giờ**. | 1–2 ngày | `TRUNCATE` partition tương ứng và làm lại lô đó |
| 4 | Tạo index trên từng partition (`CREATE INDEX` thường — partition chưa ai đọc), theo lô | vài giờ | `DROP INDEX` |
| 5 | **Kiểm chứng** (xem dưới) | vài giờ | — |
| 6 | Cut-over: `SET lock_timeout='3s'` + rename trong transaction ngắn | **< 50 ms** | rename ngược lại |
| 7 | Theo dõi 7 ngày với dual write **vẫn bật** (giờ ghi vào `telemetry_old`) | 7 ngày | rename ngược, không mất dữ liệu |
| 8 | Tắt dual write, `DROP TABLE telemetry_old` | phút | không còn — đây là điểm không quay lại |

### Bước 6 chi tiết

```sql
SET lock_timeout = '3s';
BEGIN;
  ALTER TABLE telemetry     RENAME TO telemetry_old;
  ALTER TABLE telemetry_new RENAME TO telemetry;
COMMIT;
```

Rename mất mili giây nhưng cần `ACCESS EXCLUSIVE`. **`lock_timeout` là bắt buộc** vì cùng vấn đề ở §2: nếu xin `ACCESS EXCLUSIVE` mà phải chờ một query dài, mọi query mới xếp hàng phía sau — bạn tự tạo ra downtime bằng chính lệnh chống downtime. Bọc trong vòng retry:

```bash
for i in $(seq 1 30); do
  psql -c "SET lock_timeout='3s'; BEGIN; ALTER TABLE ... ; COMMIT;" && break
  sleep 10
done
```

Cũng phải đổi tên mọi index/constraint/sequence có tên gắn với bảng cũ, nếu không lần migration sau sẽ đụng tên.

### Bước 5: kiểm chứng dữ liệu khớp

Đừng chỉ `count(*)`. Ba tầng, từ rẻ đến chắc:

```sql
-- 1. đếm theo ngày (rẻ, phát hiện lô thiếu)
SELECT ts::date, count(*) FROM telemetry     GROUP BY 1
EXCEPT
SELECT ts::date, count(*) FROM telemetry_new GROUP BY 1;
-- phải trả 0 dòng

-- 2. checksum theo ngày (phát hiện dòng sai giá trị)
SELECT ts::date, sum(hashtext(row(device_id,key_id,ts,dbl_v,bool_v,str_v)::text)::bigint)
FROM telemetry GROUP BY 1
EXCEPT
SELECT ts::date, sum(hashtext(row(device_id,key_id,ts,dbl_v,bool_v,str_v)::text)::bigint)
FROM telemetry_new GROUP BY 1;

-- 3. mẫu ngẫu nhiên đối chiếu từng dòng
SELECT * FROM telemetry TABLESAMPLE SYSTEM (0.01)
EXCEPT SELECT * FROM telemetry_new;
```

Tầng 2 là tầng quan trọng: `sum(hashtext(...))` giao hoán nên không phụ thuộc thứ tự, và bắt được lỗi kiểu "dual write ghi thiếu cột" mà `count(*)` không bao giờ thấy.

**Chạy kiểm chứng ngay trước bước 6, không phải một ngày trước** — dual write có thể đã lệch trong khoảng thời gian đó.

### Vì sao dual write chứ không phải trigger

Trigger (`AFTER INSERT ... EXECUTE FUNCTION copy_to_new()`) đơn giản hơn nhiều và không cần đổi code app. Nhưng:
- Trigger chạy trên **mọi** ghi, kể cả từ script/migration/psql thủ công — điều này là *ưu điểm*.
- Nhưng nó tăng độ trễ ghi (đo được ở lab: insert có index chậm hơn 10×) và mọi lỗi ở bảng đích làm **fail transaction gốc** — tức bảng mới có thể kéo sập bảng đang phục vụ.
- Không tắt được nhanh khi có sự cố (phải `ALTER TABLE ... DISABLE TRIGGER`, cần `ACCESS EXCLUSIVE`).

Với hệ có Temporal như của bạn, lựa chọn thứ ba hay hơn cả hai: **logical replication / CDC** (Day 39). Publication trên bảng cũ, subscription ghi vào bảng mới, không đụng vào đường ghi nóng, và có `pg_stat_subscription` để đo lag chính xác.

### 🔧 Tình huống thực tế — migration hỏng ở bước nào cũng phải sống được

Câu hỏi mà mọi review kế hoạch migration đều nên hỏi: *"nếu mất điện đúng lúc này thì sao?"*

| Hỏng ở | Trạng thái | Hành động |
|---|---|---|
| Bước 3 (copy) | bảng mới thiếu dữ liệu, app vẫn dùng bảng cũ | không ảnh hưởng ai; làm tiếp từ lô cuối cùng thành công |
| Bước 4 (index) | index dở dang, có thể `indisvalid=f` | `DROP INDEX` cái invalid, làm lại |
| Bước 6 giữa 2 lệnh rename | **transaction rollback → không có gì đổi** | thử lại |
| Sau bước 6, phát hiện bảng mới sai | app đang ghi vào bảng mới, bảng cũ có dual write nên vẫn đủ | rename ngược trong 50 ms, mất 0 dòng |
| Sau bước 8 | **không quay lại được** | đây là lý do bước 7 phải đủ 7 ngày và phải có backup |

Điểm nguy hiểm duy nhất là **bước 8**. Đặt nó cách bước 6 ít nhất một tuần, và trước khi `DROP` hãy `ALTER TABLE telemetry_old RENAME TO telemetry_old_delete_me_20260901` — cho bản thân thêm một nhịp để đổi ý.

---

## Bảng số liệu chính

| Phép đo | Kết quả |
|---|---|
| `DROP TABLE ts_p_2025_05` (1.722.141 dòng) | **0,836 ms**, 0 dead tuple |
| `DELETE` cùng số dòng | 1.413,8 ms, **1.722.141 dead tuple** |
| Kích thước heap trước / sau `DELETE` | 289 MB / **289 MB (không đổi)** |
| `VACUUM` sau `DELETE` | 303,2 ms, dead tuple → 0, kích thước **vẫn 289 MB** |
| `VACUUM FULL` | 2.532,5 ms, heap 289 → **189 MB**, total 396 → 260 MB |
| Tổng đường `DELETE` vs `DROP PARTITION` | 4.249,5 ms vs 0,836 ms — **5.083×** |
| `ATTACH` không CHECK (499.921 dòng) | **396,6 ms** `ACCESS EXCLUSIVE` trên cha |
| `ATTACH` có CHECK | **3,5 ms** — **113×** ngắn hơn |
| `ADD CONSTRAINT CHECK` (trên bảng rời) | 41,6 ms — không ảnh hưởng ai |
| `DETACH PARTITION` | 4,8 ms |
| `DETACH CONCURRENTLY` trong transaction | **ERROR: cannot run inside a transaction block** |
| `DETACH CONCURRENTLY` ngoài transaction | 6,1 ms, để lại `CHECK` constraint tự sinh |
| `CREATE INDEX ON ONLY` (cha) | 4,5 ms, `indisvalid = f` |
| `CREATE INDEX CONCURRENTLY` mỗi partition | 328–1.132 ms |
| `indisvalid` của index cha `f → t` | đúng lúc **partition cuối cùng** được `ATTACH` |
| `quan_ly_partition('ts_p', 2, 12)` ngày 2026-08-10 | TẠO 3, **XOÁ 3 partition = 5.000.079 dòng, trong 9,7 ms** |
| Chạy lại lần 2 | 0 dòng — idempotent |
| INSERT vào tháng không có partition (không có DEFAULT) | **ERROR: no partition of relation "ts_p" found for row** |
| Rollup ngày: dòng | 1.722.141 → 1.295.870 |
| Rollup ngày: dung lượng | 240 MB → 141 MB = **58,59%** (gần như vô ích) |
| Số mẫu / (device, key, ngày) ở lab | **1,33** ← đây là lý do rollup vô ích |
| Sub-partition tháng 9 | `_lo` 1.322.507 dòng / 203 MB, `_hi` 344.078 / 52 MB |
| Prune 2 tầng (`ts` + `device_id`) | 1 lá duy nhất, 1,635 ms, planning 0,375 ms |
| Prune chỉ theo `device_id` | mọi tháng, **nhưng trong tháng 9 chỉ `_lo`** |
| Cây partition | 9 lá, 2 node trung gian |
| Tốc độ copy không index | **1,43 triệu dòng/giây** |
| Tốc độ copy có 3 index | **143.000 dòng/giây — chậm 10×** |

---

## Ba điều dễ hiểu sai

| Hiểu nhầm | Sự thật đo được |
|---|---|
| "`VACUUM` sau `DELETE` là đủ, đĩa sẽ được thu hồi." | 289 MB trước `DELETE`, 289 MB sau `DELETE`, **289 MB sau `VACUUM`**. `VACUUM` dọn 1,7 triệu dead tuple về 0 nhưng chỉ trả đĩa khi các page **cuối file** trống. Dữ liệu telemetry xếp theo thời gian ⇒ chỗ trống luôn ở đầu ⇒ không bao giờ truncate được. Chỉ `VACUUM FULL` (289 → 189 MB) hoặc `pg_repack` mới thu hồi, và cả hai đều đắt. |
| "`ATTACH PARTITION` là thao tác metadata, nhanh." | **396,6 ms cho 500 nghìn dòng**, và đó là `ACCESS EXCLUSIVE` **trên bảng cha** — toàn bộ bảng telemetry đứng im. Postgres phải chứng minh mọi dòng thuộc biên. Thêm `CHECK` trước ⇒ 3,5 ms. Với 100 triệu dòng, khác biệt là ~80 giây khoá vs ~4 ms. |
| "Rollup luôn tiết kiệm dung lượng lớn." | Ở lab: **58,59%** — gần như không tiết kiệm gì, vì chỉ có **1,33 mẫu mỗi (device, key, ngày)**. Rollup nén theo tỉ lệ số mẫu mỗi nhóm, không theo số dòng tổng. Đo `count(*) / count(DISTINCT nhóm)` trước khi thiết kế; dưới 10 thì đừng làm. |

---

## Áp dụng vào hệ thật

1. **Thay cron `DELETE` bằng `DROP PARTITION` — đây là việc đáng giá nhất của cả tuần 7.** Đo trước để có con số cho team:
   ```sql
   -- bloat hiện tại của bảng telemetry
   SELECT relname, n_live_tup, n_dead_tup,
          pg_size_pretty(pg_total_relation_size(relid)) AS tren_dia,
          round(100.0*n_dead_tup/nullif(n_live_tup+n_dead_tup,0), 1) AS pct_chet
   FROM pg_stat_user_tables WHERE relname = 'telemetry';
   ```
   Nếu `pct_chet` > 20% thì bạn đang trả tiền đĩa cho rác, và mỗi query seq scan đang đọc rác đó.

2. **Mọi `ATTACH` đều phải có `CHECK ... NOT VALID` + `VALIDATE` trước.** Biến thành checklist bắt buộc trong PR template. Cùng với `SET lock_timeout` — không có lệnh DDL nào trên bảng lớn được phép chạy mà không có `lock_timeout`.

3. **Thêm index bằng quy trình 3 bước, không bao giờ `CREATE INDEX` thẳng lên cha:**
   ```sql
   CREATE INDEX idx ON ONLY telemetry (cols);
   -- từng partition, rải nhiều đêm:
   SET statement_timeout = 0;
   CREATE INDEX CONCURRENTLY idx_202506 ON telemetry_2025_06 (cols);
   ALTER INDEX idx ATTACH PARTITION idx_202506;
   -- kiểm tra sau mỗi lần:
   SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;
   ```

4. **Job quản lý partition chạy trên Temporal**, không phải cron:
   - Activity `ensure_partitions(table, months_ahead=3)` — idempotent, chạy hàng ngày.
   - Activity `drop_expired(table, retain_months, dry_run)` — mặc định `dry_run=true`, chỉ chạy thật khi có approval hoặc khi đã `DETACH` trước 7 ngày.
   - Alert khi workflow fail **2 lần liên tiếp**, không phải khi partition hết.
   - Đây là chỗ Temporal thắng cron rõ nhất: bạn *thấy* được nó đã chạy những ngày nào.

5. **Có `DEFAULT` partition + alert khi nó khác rỗng.** Chạy mỗi 15 phút:
   ```sql
   SELECT count(*) FROM telemetry_default;   -- > 0 = page ngay
   ```
   Nó là chuông báo cháy. Đừng để nó thành phòng chứa đồ — default không prune được và làm việc tạo partition bù trở nên đắt.

6. **Đo số mẫu mỗi nhóm trước khi thiết kế rollup:**
   ```sql
   SELECT count(*)::numeric / count(DISTINCT (device_id, key_id, ts::date))
   FROM telemetry WHERE ts >= now() - interval '7 days';
   ```
   < 10 → rollup ngày không đáng. > 100 → đó là đòn bẩy lớn nhất bạn có. Và **chặn cứng** việc `DROP` partition nếu rollup của khoảng đó chưa tồn tại.

7. **Chỉ sub-partition khi có lý do vận hành cụ thể** (offboarding tenant, GDPR, tablespace riêng), không bao giờ vì "chia nhỏ cho nhanh". Giữ tổng số lá < ~200.

8. **Kế hoạch migrate phải trả lời "mất điện ở bước này thì sao?" cho từng bước**, và điểm không-quay-lại (`DROP` bảng cũ) phải cách cut-over ít nhất 7 ngày. Kiểm chứng bằng checksum theo ngày, không phải `count(*)`.

---

## Câu hỏi mở sang các ngày sau

- **Day 34–35** khép lại tuần 7: với dữ liệu telemetry, chọn model lưu trữ nào (EAV như `ts_kv`, jsonb, hay cột rộng) — và §5 hôm nay đã cho một manh mối: **cấu trúc dữ liệu quyết định rollup có ích hay không**, không phải ngược lại.
- **Day 39 (logical decoding & CDC)** cho lựa chọn thứ ba ở §7 thay cho dual write và trigger: replicate bảng cũ sang bảng mới mà không đụng đường ghi nóng.
- **Day 43 (DDL locks)** là phần tiếp thẳng của §2: `NOT VALID` + `VALIDATE CONSTRAINT`, ma trận lock của từng dạng `ALTER TABLE`, và vì sao `lock_timeout` + retry là bắt buộc chứ không phải khuyến nghị.
- **Day 44–45 (expand/contract, migration rehearsal)** là §7 làm cho ra tấm ra món: diễn tập migration trên bản sao production, đo thật, rồi mới làm.
- **Day 23 (autovacuum)** nhìn lại từ hôm nay: với 9 partition thì autovacuum phải theo dõi 9 bảng thay vì 1, mỗi bảng có ngưỡng riêng — partition nhỏ đạt ngưỡng nhanh hơn nên được vacuum thường xuyên hơn. Đó là một lợi ích *ẩn* của partition mà ít ai nhắc: **autovacuum trên 9 bảng 200 MB dễ hơn nhiều so với trên 1 bảng 1,8 GB.**

---

### Dọn dẹp

```sql
DROP TABLE ts_p CASCADE;
DROP FUNCTION quan_ly_partition(text,int,int);
```
