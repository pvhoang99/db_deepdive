# Day 43 — Lời giải: Lock của DDL — vì sao một `ALTER TABLE` làm sập cả API

> Bài chữa. Đo thật trên bảng `mig` (2.000.000 dòng, 192 MB), 3 session song song, `log_lock_waits = on`.
>
> Kết luận một câu: **một `SELECT` hoàn toàn vô hại phải chờ 5.099 ms — không phải vì transaction đang chạy, mà vì nó xếp hàng sau một `ALTER TABLE` đang chờ.** Đây là cơ chế biến "một câu DDL chậm" thành "cả API sập".

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án đo được | Bẫy |
|---|---|---|---|
| 1 | `ADD COLUMN c int` trên bảng 2M dòng? | **2,87 ms.** Không rewrite, không quét. | Nhưng nó vẫn cần `ACCESS EXCLUSIVE` — và **thời gian chờ lock** mới là thứ giết bạn, không phải thời gian chạy. Đo được: cùng lệnh đó chờ **8,09 giây** khi có một transaction đang mở. |
| 2 | `ADD COLUMN c int NOT NULL DEFAULT 0`? Còn `DEFAULT random()`? | `NOT NULL DEFAULT 7`: **3,26 ms, không rewrite** (PG11+ lưu default hằng vào catalog). `DEFAULT gen_random_uuid()`: **5.078 ms, REWRITE** (`relfilenode` 240001 → 240016). | Ranh giới là **IMMUTABLE vs VOLATILE**, không phải "có DEFAULT hay không". Một hàm volatile bắt Postgres điền giá trị thật cho từng dòng. |
| 3 | `ALTER TABLE` đang **chờ** lock — một `SELECT` đơn giản có chạy được không? | **BỊ CHẶN.** `pg_blocking_pids` chỉ rõ: `SELECT` bị chặn bởi **chính `ALTER TABLE` đang chờ**, không phải bởi transaction gốc. Chờ **5.099,7 ms**. | **Đây là câu quan trọng nhất của cả ngày.** Hàng đợi lock là FIFO — một yêu cầu `ACCESS EXCLUSIVE` đang xếp hàng sẽ chặn tất cả những gì đến sau nó, kể cả những thứ hoàn toàn tương thích với người đang giữ lock. |
| 4 | `ALTER COLUMN TYPE` trên bảng 20 GB — cần bao nhiêu đĩa trống? | **Ít nhất bằng kích thước bảng mới (~20 GB), tức tổng ~40 GB tạm thời.** Đo trên lab: bảng 192 MB → 252 MB sau khi `smallint → bigint`, và sinh **298 MB WAL**. | Cộng thêm: 298 MB WAL đó đi qua replication (Day 38 — replica lag), archive, backup, và **replication slot** (Day 39 — nếu có slot chậm, WAL này bị giữ lại luôn). |

---

## §1. Tám mức lock — cái nào chặn cái nào

Đo bằng `BEGIN; <lệnh>; SELECT ... FROM pg_locks; ROLLBACK;`:

| Lệnh | Lock lấy trên `mig` | Thời gian | **Chặn `SELECT`?** |
|---|---|---|---|
| `SELECT` | `AccessShareLock` | — | không |
| `INSERT`/`UPDATE`/`DELETE` | `RowExclusiveLock` | — | không |
| `ANALYZE mig` | **`ShareUpdateExclusiveLock`** | 111,8 ms | **không** |
| `ALTER TABLE ... SET (fillfactor=80)` | **`ShareUpdateExclusiveLock`** | 0,12 ms | **không** |
| `VALIDATE CONSTRAINT` | **`ShareUpdateExclusiveLock`** | 169,6 ms | **không** |
| `CREATE INDEX` | **`ShareLock`** | 547,3 ms | không — nhưng **chặn mọi GHI** |
| `ALTER TABLE ADD COLUMN` | **`AccessExclusiveLock`** | 2,87 ms | **CÓ** |
| `ALTER TABLE ... SET NOT NULL` | **`AccessExclusiveLock`** | 240,9 ms | **CÓ** |
| `TRUNCATE` | **`AccessExclusiveLock`** (+ `ShareLock`, + `AccessExclusive` trên index) | 0,57 ms | **CÓ** |

**Câu duy nhất phải thuộc: `ACCESS EXCLUSIVE` chặn cả `SELECT`.** Mọi tai nạn migration đều bắt nguồn từ dòng này.

Chi tiết đáng chú ý ở `ANALYZE`: nó lấy `ShareUpdateExclusiveLock` trên bảng **và** `AccessShareLock` trên index — DDL thường chạm nhiều đối tượng hơn bạn nghĩ. `TRUNCATE` lấy tới ba lock.

**Nhóm `SHARE UPDATE EXCLUSIVE` là nhóm an toàn nhất** — nó không chặn đọc lẫn ghi, chỉ chặn lẫn nhau (hai `VACUUM` cùng lúc, hoặc `VACUUM` + `ANALYZE`). Mọi mẹo an toàn ở §3 đều là cách chuyển việc nặng từ `ACCESS EXCLUSIVE` sang nhóm này.

---

## §2. Cái bẫy thật: hàng đợi lock

Ba session:
- **S1**: `BEGIN; SELECT count(*) FROM mig WHERE device_id=1;` rồi để đó (giữ `ACCESS SHARE`).
- **S2**: `ALTER TABLE mig ADD COLUMN queued_col int;`
- **S3**: `SELECT count(*) FROM mig WHERE device_id=2;` — một query đọc hoàn toàn bình thường.

Hiện trường:

```
 pid  |        state        | wait_event_type | wait_event | bi_chan_boi |  q
------+---------------------+-----------------+------------+-------------+------------------------------
 3654 | idle in transaction | Client          | ClientRead | {}          | SELECT ... device_id = 1;
 3656 | active              | Lock            | relation   | {3654}      | ALTER TABLE mig ADD COLUMN
 3655 | active              | Lock            | relation   | {3656}      | SELECT ... device_id = 2;
```

**Dòng thứ ba là toàn bộ bài học: `SELECT` (3655) bị chặn bởi `ALTER TABLE` (3656), KHÔNG phải bởi transaction gốc (3654).**

Log Postgres xác nhận:
```
LOG:  process 3656 still waiting for AccessExclusiveLock on relation 240001 after 1000.196 ms
LOG:  process 3655 still waiting for AccessShareLock  on relation 240001 after 1000.134 ms
LOG:  process 3656 acquired AccessExclusiveLock on relation 240001 after 8091.679 ms
LOG:  process 3655 acquired AccessShareLock  on relation 240001 after 5099.739 ms
```

| Session | Bắt đầu | Xong | **Chờ** |
|---|---|---|---|
| S2 (`ALTER`) | 06:45:19,862 | 06:45:27,966 | **8.091,7 ms** |
| S3 (`SELECT` thường) | 06:45:22,865 | 06:45:27,977 | **5.099,7 ms** |

**`ALTER TABLE` khi tới lượt chỉ chạy ~11 ms. Nhưng nó làm một `SELECT` vô can phải chờ 5,1 giây.**

### Cơ chế

Postgres cấp lock theo **hàng đợi FIFO**, và một yêu cầu đang xếp hàng **chặn mọi yêu cầu đến sau** — kể cả những yêu cầu tương thích với người đang giữ lock:

```
Đang giữ:  T1 [ACCESS SHARE]        ← SELECT dài / idle in transaction
Hàng đợi:  T2 [ACCESS EXCLUSIVE]    ← ALTER TABLE, chờ T1
           T3 [ACCESS SHARE]        ← SELECT mới. Tương thích với T1!
                                       Nhưng KHÔNG được vượt T2 ⇒ kẹt.
           T4, T5, T6...             ← toàn bộ traffic dồn lại
```

Nếu Postgres cho T3 vượt lên, T2 sẽ **chết đói vĩnh viễn** trên một bảng có traffic đọc liên tục. FIFO là lựa chọn đúng — nhưng nó biến "một DDL chờ lâu" thành "toàn bộ bảng đứng im".

### 🔧 Giải thích cho đồng nghiệp bằng 3 câu

> *"Thêm một cột chỉ mất 3 mili giây, nhưng nó cần khoá độc quyền — mà lúc đó có một report đang chạy 10 phút giữ khoá đọc, nên `ALTER TABLE` phải xếp hàng chờ.*
> *Vấn đề là Postgres cấp khoá theo thứ tự đến trước phục vụ trước: mọi query mới đến sau `ALTER TABLE` đều phải xếp hàng phía sau nó, kể cả `SELECT` bình thường vốn chẳng xung đột với ai.*
> *Nên trong 10 phút đó không phải một query chậm, mà là **mọi** query trên bảng đó đứng im — và API trả 500 vì connection pool cạn."*

Đây cũng là lời giải thích cho hiện tượng "deploy migration lúc 2h sáng vẫn sập": không cần traffic cao, chỉ cần **một** transaction mở lâu (một job ETL, một session `idle in transaction` — Day 40 §5) là đủ.

---

## §3. Lệnh nào rewrite bảng, lệnh nào chỉ sửa metadata

Cách kiểm chứng thay vì học thuộc: so `pg_relation_filenode()` trước và sau. **Filenode đổi = bảng đã bị viết lại.**

| Lệnh | Thời gian | `relfilenode` | Quét bảng | Lock |
|---|---|---|---|---|
| `ADD COLUMN a int` | **2,87 ms** | 240001 → 240001 | không | `ACCESS EXCL` |
| `ADD COLUMN b int NOT NULL DEFAULT 7` | **3,26 ms** | không đổi | không | `ACCESS EXCL` |
| **`ADD COLUMN c uuid DEFAULT gen_random_uuid()`** | **5.078,4 ms** | **240001 → 240016** | **CÓ** | `ACCESS EXCL` |
| `ADD COLUMN s1 varchar(50)` | 2,92 ms | không đổi | không | |
| `ALTER COLUMN s1 TYPE varchar(100)` | **2,66 ms** | **không đổi** | không | |
| `ALTER COLUMN s1 TYPE text` | **2,75 ms** | **không đổi** | không | |
| **`ALTER COLUMN key_id TYPE bigint`** | **3.289,8 ms** | **240016 → 240024** | **CÓ** | `ACCESS EXCL` |
| `ALTER COLUMN d SET NOT NULL` (cột nullable) | **240,9 ms** | không đổi | **CÓ (full scan)** | **`ACCESS EXCL`** |
| `DROP COLUMN c` | 3,04 ms | không đổi | không | `ACCESS EXCL` |
| `ADD CHECK (...)` | **274,7 ms** | không đổi | **CÓ** | `ACCESS EXCL` |
| **`ADD CHECK (...) NOT VALID`** | **3,08 ms** | không đổi | **không** | `ACCESS EXCL` (nhưng tức thì) |
| **`VALIDATE CONSTRAINT`** | 169,6 ms | không đổi | CÓ | **`SHARE UPDATE EXCL`** ✅ |
| `SET (fillfactor=80)` | 0,12 ms | không đổi | không | `SHARE UPDATE EXCL` |

### Ba ranh giới quan trọng

**a) `DEFAULT` hằng vs `DEFAULT` volatile — 1.550×**

```
ADD COLUMN b int NOT NULL DEFAULT 7             →    3,26 ms, không rewrite
ADD COLUMN c uuid DEFAULT gen_random_uuid()     → 5.078,4 ms, REWRITE
```

PG11+ lưu default **hằng** vào catalog (`pg_attribute.atthasmissing` + `attmissingval`) và trả về giá trị đó cho các dòng cũ mà không đụng vào chúng. Nhưng `gen_random_uuid()` là **VOLATILE** — mỗi dòng một giá trị khác — nên bắt buộc phải điền thật.

Sửa: thêm cột nullable trước, backfill theo lô (Day 44), rồi mới `SET DEFAULT` cho dòng mới.

**b) Nới rộng kiểu thì miễn phí, đổi kiểu thật thì rewrite**

```
varchar(50) → varchar(100)  →  2,66 ms, không rewrite   (chỉ nới ràng buộc độ dài)
varchar     → text          →  2,75 ms, không rewrite   (cùng biểu diễn nhị phân)
smallint    → bigint        →  3.289,8 ms, REWRITE      (biểu diễn khác nhau)
```

Quy tắc: nếu **biểu diễn nhị phân trên đĩa không đổi** và ràng buộc chỉ nới ra, Postgres chỉ sửa catalog. `numeric(10,2) → numeric(12,2)` cũng miễn phí; `numeric(12,2) → numeric(10,2)` thì không (thu hẹp ⇒ phải kiểm tra).

**c) `SET NOT NULL` không rewrite nhưng quét cả bảng dưới `ACCESS EXCLUSIVE`** — 240,9 ms cho 2M dòng, tức ~2 phút cho 1 tỉ dòng. **Hai phút khoá toàn bảng.**

### Mẹo `NOT VALID` — chuyển việc nặng ra khỏi `ACCESS EXCLUSIVE`

| Cách | Thời gian | Lock | Chặn đọc/ghi? |
|---|---|---|---|
| `ADD CHECK (...)` | **274,7 ms** | `ACCESS EXCLUSIVE` | **CÓ, suốt 274,7 ms** |
| `ADD CHECK (...) NOT VALID` | **3,08 ms** | `ACCESS EXCLUSIVE` | có, nhưng chỉ 3 ms |
| + `VALIDATE CONSTRAINT` | 169,6 ms | **`SHARE UPDATE EXCLUSIVE`** | **KHÔNG** ✅ |

**Cửa sổ chặn từ 274,7 ms xuống 3,08 ms — 89×.** Trên bảng 1 tỉ dòng, đó là khác biệt giữa 2 phút khoá và 20 mili giây khoá.

Và mẹo tương tự cho `SET NOT NULL` (PG12+):

```sql
ALTER TABLE mig ADD CONSTRAINT ck_d_nn CHECK (d IS NOT NULL) NOT VALID;  -- 5,5 ms
ALTER TABLE mig VALIDATE CONSTRAINT ck_d_nn;                             -- 194,5 ms, SHARE UPDATE EXCL
ALTER TABLE mig ALTER COLUMN d SET NOT NULL;                             -- 3,1 ms  ← không quét lại!
ALTER TABLE mig DROP CONSTRAINT ck_d_nn;                                 -- 3,2 ms
```

**`SET NOT NULL` từ 240,9 ms xuống 3,1 ms** — vì PG12+ nhận ra đã có `CHECK (d IS NOT NULL)` hợp lệ nên bỏ qua bước quét. Cửa sổ `ACCESS EXCLUSIVE` giảm **78×**.

Đây là mẫu quan trọng nhất của Day 43 và sẽ dùng lại cả Day 44.

### `DROP COLUMN` không trả lại đĩa

```
Trước DROP: 252 MB  →  Sau DROP: 252 MB   (filenode không đổi)
```

`DROP COLUMN` chỉ đánh dấu cột là đã xoá trong `pg_attribute` (`attisdropped = true`). Dữ liệu vẫn nằm trong mọi tuple cũ. Chỉ được thu hồi khi bảng bị rewrite (`VACUUM FULL`, `pg_repack`, hoặc một `ALTER COLUMN TYPE`).

Hệ quả ít biết: có giới hạn **1.600 cột kể cả cột đã drop** — thêm/xoá cột lặp đi lặp lại sẽ đụng trần.

### Cái giá của rewrite — trả lời §0.4

`smallint → bigint` trên bảng 192 MB:

| | Kết quả |
|---|---|
| Thời gian | **3.289,8 ms** |
| `relfilenode` | 240016 → **240024** |
| Kích thước bảng | 192 MB → **252 MB** |
| **WAL sinh ra** | **298 MB** |

**Ngoại suy cho bảng 20 GB:**
- **Đĩa:** cần ~20 GB trống cho bản mới ⇒ tổng ~40 GB trong lúc chạy. Chỉ giải phóng bản cũ khi transaction commit.
- **Thời gian:** ~343 giây (5,7 phút) **`ACCESS EXCLUSIVE` — toàn bộ API đứng im**.
- **WAL:** ~31 GB. Hệ quả dây chuyền: replica lag (Day 38 — replay là single-process, 31 GB có thể là hàng chục phút), `archive_command` quá tải, và **nếu có replication slot chậm thì 31 GB đó bị giữ lại trong `pg_wal`** (Day 39 §4 — nguy cơ đầy đĩa).

> **Kết luận: `ALTER COLUMN TYPE` trên bảng lớn là thao tác cấm.** Phải làm bằng expand/contract (Day 44): thêm cột mới, backfill theo lô, đổi đọc/ghi, xoá cột cũ.

---

## §4. `lock_timeout` — cái van bạn phải có

```sql
SET lock_timeout = '2s';
ALTER TABLE mig ADD COLUMN e int;
```
```
Time: 2000.667 ms
ERROR:  55P03: canceling statement due to lock timeout
```

**Bỏ cuộc sau đúng 2,0 giây, và quan trọng hơn: nó rời khỏi hàng đợi** ⇒ mọi `SELECT` đang kẹt phía sau được giải phóng ngay. So với §2 (không có `lock_timeout`): `SELECT` phải chờ 5,1 giây.

### Bốn timeout — phân biệt cho đúng

| GUC | Đếm cái gì | Dùng cho DDL |
|---|---|---|
| **`lock_timeout`** | thời gian **chờ lấy** một lock | **luôn đặt: 2–5 s** |
| `statement_timeout` | thời gian chạy **cả câu lệnh** | **đặt 0 cho DDL dài** (xem cảnh báo) |
| `idle_in_transaction_session_timeout` | transaction rỗi (Day 40) | đặt ở role app |
| `deadlock_timeout` | sau bao lâu mới **đi tìm** deadlock (mặc định 1 s) | cũng là ngưỡng ghi `log_lock_waits` |

**Cảnh báo về `statement_timeout` với DDL dài:** nó huỷ **cả lệnh đang rewrite**, mọi công đã làm bị rollback. Với `ALTER COLUMN TYPE` trên bảng lớn, `statement_timeout = 30s` nghĩa là bạn **không bao giờ** hoàn thành được nó — chỉ tốn 30 giây khoá bảng rồi rollback, lặp mãi.

Nguyên tắc: **`lock_timeout` nhỏ (fail nhanh khi không lấy được lock), `statement_timeout = 0` cho DDL chắc chắn dài.**

### Mẫu migration có retry

```bash
#!/usr/bin/env bash
# Thử tối đa 5 lần, mỗi lần chờ lock tối đa 3s, backoff tăng dần.
for i in 1 2 3 4 5; do
  if psql -v ON_ERROR_STOP=1 -d "$DB" <<'SQL'
      SET lock_timeout = '3s';
      SET statement_timeout = '0';       -- DDL này có thể chạy lâu, đừng giết nó
      BEGIN;
        ALTER TABLE mig ADD COLUMN e int;
        ALTER TABLE mig ADD CONSTRAINT ck_e CHECK (e IS NULL OR e >= 0) NOT VALID;
      COMMIT;
SQL
  then echo "OK ở lần thử $i"; exit 0; fi
  echo "Lần $i thất bại (nhiều khả năng là lock timeout), chờ $((i*10))s..."
  sleep $((i*10))
done
echo "Thất bại sau 5 lần — có transaction dài đang chạy, kiểm tra pg_stat_activity"; exit 1
```

Ba điểm thiết kế:
1. **`ON_ERROR_STOP=1`** — không có nó, psql chạy tiếp các lệnh sau lỗi và bạn có schema nửa vời.
2. **Backoff tăng dần** (10s, 20s, 30s…) — nếu có một job dài đang chạy, thử lại ngay lập tức chỉ tốn công.
3. **Gộp các DDL liên quan vào một transaction** — lấy lock một lần thay vì nhiều lần. Nhưng **không** gộp lệnh `CONCURRENTLY` vào (§5).

Với Flyway: `SET lock_timeout` phải nằm **trong** file migration, hoặc đặt qua `flyway.initSql`. Với Liquibase: dùng `<sql>` với `SET`.

---

## §5. `CREATE INDEX` vs `CREATE INDEX CONCURRENTLY`

| | `CREATE INDEX` | `CREATE INDEX CONCURRENTLY` |
|---|---|---|
| **Thời gian** (2M dòng) | **547,3 ms** | **914,9 ms** (chậm 1,67×) |
| Lock | `ShareLock` | `ShareUpdateExclusiveLock` |
| **INSERT song song** | **bị chặn 216 ms** | **7,4 ms — không bị chặn** |
| Số lần quét bảng | 1 | **2** (+ chờ transaction cũ) |
| Chạy trong transaction | được | **`ERROR: CREATE INDEX CONCURRENTLY cannot run inside a transaction block`** |
| Khi thất bại | không để lại gì | **để lại index `INVALID`** |

### Đo INSERT song song

```
CREATE INDEX thường:      INSERT bắt đầu 06:48:08.519 → xong 06:48:08.735  = 216 ms  ← BỊ CHẶN
CREATE INDEX CONCURRENTLY: INSERT bắt đầu 06:48:10.325 → xong 06:48:10.333  = 7,4 ms ← chạy bình thường
```

**29× khác biệt.** `ShareLock` xung đột với `RowExclusiveLock` của `INSERT`; `ShareUpdateExclusiveLock` thì không.

Lưu ý: `CREATE INDEX` thường **không** chặn `SELECT` (`ShareLock` tương thích với `AccessShareLock`) — nó chỉ chặn ghi. Nhiều người tưởng nó chặn tất cả; không phải.

### Index `INVALID`

Giết `CREATE INDEX CONCURRENTLY` giữa chừng:

```sql
SELECT c.relname, i.indisvalid, i.indisready, pg_size_pretty(pg_relation_size(c.oid))
FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid WHERE NOT i.indisvalid;
--  ix_mig_bad | f | f | 0 bytes
```

`indisvalid = f`, `indisready = f` — index tồn tại trong catalog nhưng **không dùng được để đọc**.

**Vì sao đây là bloat câm:**
- Nếu `indisready = t` (thất bại ở pha 2): **mọi `INSERT`/`UPDATE` vẫn phải cập nhật nó**, tốn WAL và thời gian, nhưng planner không bao giờ dùng nó để đọc. Tệ nhất mọi thế giới.
- Nếu `indisready = f` (thất bại ở pha 1, như trên): không được cập nhật, nhưng vẫn chiếm tên và chỗ trong catalog — và lần chạy migration sau sẽ lỗi `relation already exists`.

Xử lý:
```sql
DROP INDEX CONCURRENTLY ix_mig_bad;   -- rồi tạo lại
```

### Ba hệ quả thực tế

**1. Flyway/Liquibase bọc mỗi migration trong transaction ⇒ `CONCURRENTLY` lỗi.**
- Flyway: đặt tên file `V42__add_index.sql` và cấu hình `flyway.executeInTransaction=false`, hoặc dùng callback.
- Liquibase: `<changeSet runInTransaction="false">`.
- golang-migrate: thêm `-- +migrate NoTransaction` (hoặc dùng file `.up.sql` riêng với `x-no-transaction`).

**2. `CONCURRENTLY` phải chờ MỌI transaction đang mở kết thúc** — không chỉ transaction trên bảng đó. Một session `idle in transaction` ở database khác cùng cluster (Day 40 §5) làm nó treo vô hạn. Kiểm tra trước:
```sql
SELECT pid, now()-xact_start AS mo, state, substring(query,1,60)
FROM pg_stat_activity WHERE xact_start < now() - interval '1 minute' ORDER BY xact_start;
```

**3. Đặt `statement_timeout = 0` cho `CONCURRENTLY`.** Nếu role của bạn có `statement_timeout` mặc định, index build trên bảng lớn sẽ bị giết giữa chừng và để lại rác `INVALID`.

### Query cho dashboard

```sql
SELECT n.nspname, c.relname AS index_name, t.relname AS table_name,
       i.indisvalid, i.indisready,
       pg_size_pretty(pg_relation_size(c.oid)) AS size
FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_class t ON t.oid = i.indrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE NOT i.indisvalid;
-- ALERT: có bất kỳ dòng nào → warning ngay
```

---

## §6. Bảng phân loại — dán vào wiki của team

| # | Lệnh | Mức nguy hiểm | Số đo (bảng 2M dòng) | Cách làm an toàn |
|---|---|---|---|---|
| 1 | `ADD COLUMN c int` | **an toàn** + `lock_timeout` | 2,87 ms, không rewrite | `SET lock_timeout='3s'` + retry |
| 2 | `ADD COLUMN c int NOT NULL DEFAULT <hằng>` | **an toàn** + `lock_timeout` | 3,26 ms, không rewrite | như trên. PG11+ mới an toàn — PG10 thì rewrite |
| 3 | `ADD COLUMN c DEFAULT <hàm volatile>` | **CẤM giờ cao điểm** | **5.078 ms, REWRITE** | thêm cột nullable → backfill lô (Day 44) → `SET DEFAULT` |
| 4 | `ALTER COLUMN TYPE` (nới rộng: `varchar(50)→varchar(100)`, `→text`) | **an toàn** | 2,66 / 2,75 ms, không rewrite | `lock_timeout` |
| 5 | `ALTER COLUMN TYPE` (đổi thật: `smallint→bigint`) | **CẤM** | **3.290 ms, REWRITE, 298 MB WAL, +60 MB bảng** | expand/contract (Day 44). Bảng 20 GB ⇒ ~5,7 phút khoá + 31 GB WAL |
| 6 | `SET NOT NULL` | **cần cẩn thận** | **240,9 ms full scan dưới `ACCESS EXCL`** | `CHECK (x IS NOT NULL) NOT VALID` → `VALIDATE` → `SET NOT NULL` ⇒ **3,1 ms (78×)** |
| 7 | `ADD CHECK` | **cần cẩn thận** | 274,7 ms full scan dưới `ACCESS EXCL` | `NOT VALID` (3,08 ms) → `VALIDATE` (`SHARE UPDATE EXCL`) ⇒ **89×** |
| 8 | `ADD FOREIGN KEY` | **cần cẩn thận** | quét **cả hai** bảng | `NOT VALID` → `VALIDATE CONSTRAINT` |
| 9 | `DROP COLUMN` | **an toàn** nhưng không trả đĩa | 3,04 ms, 252 MB → 252 MB | `lock_timeout`; thu hồi đĩa bằng `pg_repack` sau |
| 10 | `CREATE INDEX` | **cần cẩn thận** — chặn **ghi** | 547,3 ms; INSERT bị chặn **216 ms** | dùng `CONCURRENTLY` |
| 11 | `CREATE INDEX CONCURRENTLY` | **an toàn** | 914,9 ms; INSERT **7,4 ms** | `statement_timeout=0`; ngoài transaction; kiểm tra `indisvalid` sau |
| 12 | `TRUNCATE` | **CẤM** trên bảng đang phục vụ | 0,57 ms nhưng `ACCESS EXCLUSIVE` + xoá sạch | `DROP PARTITION` (Day 33) nếu là bảng phân vùng |
| 13 | `ANALYZE` / `SET (fillfactor)` / `VALIDATE CONSTRAINT` | **an toàn** | 111,8 / 0,12 / 169,6 ms, `SHARE UPDATE EXCL` | chạy tự do |
| 14 | `VACUUM FULL` / `REINDEX` (không CONCURRENTLY) | **CẤM** | `ACCESS EXCLUSIVE` toàn thời gian | `pg_repack` / `REINDEX CONCURRENTLY` |

---

## Bảng số liệu chính

| Phép đo | Kết quả |
|---|---|
| Bảng thử | `mig`, 2.000.000 dòng, 192 MB |
| **`ALTER TABLE` chờ lock** | **8.091,7 ms**, khi tới lượt chạy ~11 ms |
| **`SELECT` vô can bị chặn** | **5.099,7 ms** — bởi chính `ALTER TABLE` đang chờ (`pg_blocking_pids = {3656}`) |
| `ADD COLUMN int` | 2,87 ms, không rewrite |
| `ADD COLUMN NOT NULL DEFAULT 7` | **3,26 ms, không rewrite** |
| `ADD COLUMN DEFAULT gen_random_uuid()` | **5.078,4 ms, REWRITE** (`relfilenode` đổi) |
| `varchar(50) → varchar(100)` / `→ text` | 2,66 / 2,75 ms, **không rewrite** |
| **`smallint → bigint`** | **3.289,8 ms, REWRITE, WAL 298 MB**, bảng 192 → 252 MB |
| `SET NOT NULL` (cột nullable) | **240,9 ms full scan** dưới `ACCESS EXCLUSIVE` |
| **Mẹo `CHECK NOT VALID` + `VALIDATE` + `SET NOT NULL`** | 5,5 + 194,5 + **3,1 ms** — cửa sổ khoá giảm **78×** |
| `ADD CHECK` vs `ADD CHECK NOT VALID` | **274,7 ms vs 3,08 ms — 89×** |
| `VALIDATE CONSTRAINT` lock | **`ShareUpdateExclusiveLock`** — không chặn đọc/ghi |
| `DROP COLUMN` | 252 MB → **252 MB**, filenode không đổi |
| `lock_timeout = '2s'` | huỷ sau **2.000,7 ms**, `ERROR: 55P03 canceling statement due to lock timeout` |
| `CREATE INDEX` | **547,3 ms**, INSERT song song **bị chặn 216 ms** |
| `CREATE INDEX CONCURRENTLY` | **914,9 ms (1,67×)**, INSERT song song **7,4 ms (29× nhanh hơn)** |
| `CONCURRENTLY` trong transaction | **`ERROR: cannot run inside a transaction block`** |
| Index sau khi bị huỷ giữa chừng | **`indisvalid = f`, `indisready = f`** |

---

## Ba điều dễ hiểu sai

| Hiểu nhầm | Sự thật đo được |
|---|---|
| "`ALTER TABLE ADD COLUMN` chạy 3 ms nên an toàn." | Nó chạy 3 ms **khi lấy được lock**. Đo được: cùng lệnh đó **chờ 8,09 giây**, và trong lúc chờ nó chặn một `SELECT` vô can **5,10 giây** — vì hàng đợi lock là FIFO, mọi yêu cầu đến sau một `ACCESS EXCLUSIVE` đang chờ đều bị kẹt. **Rủi ro không nằm ở thời gian chạy mà ở thời gian chờ**, và thời gian chờ do transaction dài của người khác quyết định. |
| "Có `DEFAULT` thì phải rewrite bảng." | Ranh giới là **IMMUTABLE vs VOLATILE**, không phải có/không có DEFAULT. `NOT NULL DEFAULT 7`: **3,26 ms, không rewrite** (PG11+ lưu vào catalog). `DEFAULT gen_random_uuid()`: **5.078 ms, REWRITE**. Cùng logic: `varchar(50)→varchar(100)` miễn phí, `smallint→bigint` rewrite — vì biểu diễn nhị phân đổi. |
| "`ADD CHECK` / `SET NOT NULL` chỉ là ràng buộc, chắc là nhanh." | Cả hai **quét toàn bộ bảng dưới `ACCESS EXCLUSIVE`**: 274,7 ms và 240,9 ms cho 2M dòng — tức ~2 phút khoá toàn bảng cho 1 tỉ dòng. Mẹo `NOT VALID` + `VALIDATE` chuyển việc quét sang `SHARE UPDATE EXCLUSIVE` (không chặn ai) và giảm cửa sổ khoá **78–89×**. Đây là mẫu quan trọng nhất của cả tuần 9. |

---

## Áp dụng vào hệ thật

1. **Thêm `SET lock_timeout` vào MỌI migration — tuần này.** Đây là việc có ROI cao nhất trong ngày. Không có nó, một migration 3 ms có thể chặn cả API 10 phút.
   ```sql
   SET lock_timeout = '3s';
   SET statement_timeout = '0';   -- cho DDL dài; đặt số cụ thể cho DDL ngắn
   ```
   Kèm retry với backoff (§4) trong script deploy.

2. **Mở 3 migration gần nhất và phân loại từng câu theo bảng §6.** Với mỗi câu có "rewrite" hoặc "quét bảng", tính lại thời gian ở kích thước bảng production:
   ```
   thời_gian_production ≈ thời_gian_lab × (số_dòng_prod / 2.000.000)
   ```
   `ALTER COLUMN TYPE` trên bảng 500M dòng ≈ **14 phút khoá** và ~75 GB WAL.

3. **Chuyển mọi `ADD CHECK` / `ADD FOREIGN KEY` / `SET NOT NULL` sang mẫu `NOT VALID`:**
   ```sql
   ALTER TABLE t ADD CONSTRAINT c CHECK (...) NOT VALID;   -- ~3 ms, ACCESS EXCL
   ALTER TABLE t VALIDATE CONSTRAINT c;                    -- lâu, nhưng SHARE UPDATE EXCL
   ```
   Với `SET NOT NULL`, thêm bước 3: `ALTER COLUMN x SET NOT NULL` (3,1 ms vì đã có CHECK) rồi `DROP CONSTRAINT`.

4. **Kiểm tra transaction dài TRƯỚC mỗi migration** — nó quyết định bạn chờ 3 ms hay 10 phút:
   ```sql
   SELECT pid, now()-xact_start AS mo, state, substring(query,1,60)
   FROM pg_stat_activity WHERE xact_start < now() - interval '30 seconds'
   ORDER BY xact_start;
   ```
   Có kết quả ⇒ hoãn migration hoặc `pg_terminate_backend` job đó trước.

5. **Đưa query tìm index `INVALID` (§5) vào dashboard.** Nó là bloat câm: tốn chỗ, tốn WAL mỗi lần ghi, và không bao giờ được dùng để đọc.

6. **Cấu hình migration tool cho `CONCURRENTLY`:** Flyway `executeInTransaction=false`, Liquibase `runInTransaction="false"`. Và đặt `statement_timeout=0` cho các migration đó.

7. **Đặt `idle_in_transaction_session_timeout = '60s'`** ở role ứng dụng (Day 40 §5). Nó là nguồn số một của "`ALTER TABLE` chờ mãi không được", và cũng làm `CREATE INDEX CONCURRENTLY` treo vô hạn.

8. **Dán bảng §6 vào wiki và vào PR template.** Mỗi PR có DDL phải trả lời: lệnh này lấy lock gì, có rewrite không, mất bao lâu ở kích thước bảng hiện tại?

---

## Câu hỏi mở sang các ngày sau

- **Day 44 (expand/contract & backfill)** là ngày dùng đúng những thứ hôm nay để đổi schema trên bảng 5 triệu dòng mà **không chặn ai** — cụ thể là thay thế cho dòng 3 và 5 của bảng §6 (`DEFAULT` volatile và `ALTER COLUMN TYPE`).
- **Day 45 (migration rehearsal)** trả lời câu hỏi vận hành: làm sao biết trước một migration mất bao lâu trên production mà không phải thử trên production.
- **Day 40 §5** nối trực tiếp: `idle in transaction` ở `READ COMMITTED` **không** chặn vacuum nhưng **chặn `ALTER TABLE`** — và `ALTER TABLE` đang chờ thì chặn mọi query mới. Đó là cách một session tưởng như vô hại làm sập cả hệ, và nó **không** hiện ra trong bất kỳ chỉ số vacuum nào.
- **Day 39 §4** cảnh báo bổ sung cho §3: 298 MB WAL của một rewrite (31 GB với bảng 20 GB) sẽ bị **giữ lại trong `pg_wal`** nếu có replication slot chậm — migration lớn có thể làm đầy đĩa qua đường này.
- **Câu hỏi mở thật sự:** `VALIDATE CONSTRAINT` chạy dưới `SHARE UPDATE EXCLUSIVE` nên không chặn đọc/ghi — nhưng nó **xung đột với `VACUUM`**. Trên bảng ingest cao mà autovacuum chạy gần như liên tục, `VALIDATE` có thể chờ rất lâu hoặc bị chặn. Cách xử lý: tạm `ALTER TABLE ... SET (autovacuum_enabled = off)` trong lúc validate, hay chấp nhận chờ?

---

### Dọn dẹp

```sql
DROP INDEX IF EXISTS ix_mig_1, ix_mig_2, ix_mig_3, ix_mig_bad;
DROP TABLE mig;
DROP FUNCTION fnode(text);
```
