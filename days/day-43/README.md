# Day 43 — Lock của DDL: vì sao một `ALTER TABLE` làm sập cả API

**Thời lượng:** 60–90 phút · **Cần 3 terminal:** `make s1`, `make s2`, và một `make s2` nữa.

> Đây là ngày có tỷ lệ "gây sự cố production" cao nhất trong toàn bộ 48 ngày. Không phải vì DDL khó, mà vì nó **im lặng**: câu lệnh chạy 40ms trên staging, chạy 40 phút trên production, và trong 40 phút đó **toàn bộ query trên bảng đó bị chặn** — kể cả `SELECT`.
>
> Bạn viết migration Flyway/Liquibase mỗi tuần. Hôm nay đo xem mỗi câu trong đó thực sự lấy lock gì.

## Chuẩn bị

```sql
\timing on
\o /days/day-43/output.txt
SHOW log_lock_waits;   -- lab đã bật sẵn: mọi lần chờ lock > deadlock_timeout đều vào log
```

---

## §0. Đoán trước

1. `ALTER TABLE t ADD COLUMN c int;` trên bảng 5 triệu dòng — mất bao lâu?
2. `ALTER TABLE t ADD COLUMN c int NOT NULL DEFAULT 0;` — mất bao lâu? Còn `DEFAULT random()`?
3. Một `ALTER TABLE` đang **chờ** lock (chưa chạy được). Lúc này một `SELECT * FROM t WHERE id=1` đơn giản sẽ: chạy bình thường / bị chặn?
4. `ALTER TABLE t ALTER COLUMN x TYPE bigint` trên bảng 20GB — đĩa cần trống bao nhiêu?

---

## §1. Tám mức lock bảng

### Lý thuyết

Day 28 nói về lock **hàng**. DDL dùng lock **bảng**. Có 8 mức; chỉ cần nhớ 4 mức quan trọng và ai xung đột với ai:

| Lock mode | Ai lấy | Chặn |
|---|---|---|
| `ACCESS SHARE` | `SELECT` | chỉ `ACCESS EXCLUSIVE` |
| `ROW EXCLUSIVE` | `INSERT`/`UPDATE`/`DELETE` | `SHARE` trở lên |
| `SHARE UPDATE EXCLUSIVE` | `VACUUM`, `ANALYZE`, `CREATE INDEX CONCURRENTLY`, `ALTER TABLE ... SET (fillfactor)`, `VALIDATE CONSTRAINT` | lẫn nhau; **không** chặn đọc/ghi |
| `SHARE ROW EXCLUSIVE` | `ADD FOREIGN KEY` (trên bảng được tham chiếu) | ghi, nhưng không chặn đọc |
| `ACCESS EXCLUSIVE` | **đa số `ALTER TABLE`**, `DROP`, `TRUNCATE`, `REINDEX`, `VACUUM FULL`, `CLUSTER` | **TẤT CẢ, kể cả `SELECT`** |

Câu duy nhất phải thuộc: **`ACCESS EXCLUSIVE` chặn cả `SELECT`.** Mọi tai nạn migration đều bắt nguồn từ dòng này.

### Làm ngay

```sql
-- dựng bảng thử: 2 triệu dòng, đủ lớn để thấy chênh lệch
CREATE TABLE mig AS SELECT device_id, key_id, ts, dbl_v, str_v FROM ts_kv LIMIT 2000000;
ALTER TABLE mig ADD PRIMARY KEY (device_id, key_id, ts);
VACUUM ANALYZE mig;
SELECT pg_size_pretty(pg_total_relation_size('mig'));
```

Xem lock của một lệnh cụ thể — **S1**:
```sql
BEGIN;
ALTER TABLE mig ADD COLUMN tmp_col int;
SELECT locktype, relation::regclass, mode, granted
FROM pg_locks WHERE pid = pg_backend_pid() AND relation IS NOT NULL;
ROLLBACK;
```

Lặp lại khung `BEGIN; <lệnh>; SELECT ... pg_locks; ROLLBACK;` cho:
`CREATE INDEX ON mig(str_v)`, `ANALYZE mig`, `ALTER TABLE mig SET (fillfactor=80)`, `TRUNCATE`… (đừng commit).

**Ghi vào writeup — bảng:** lệnh | lock mode | có chặn SELECT không.

---

## §2. Cái bẫy thật: hàng đợi lock

### Lý thuyết

Đây là phần mà hầu hết mọi người không biết, và là lý do sự cố lan rộng thay vì chỉ chậm một chỗ.

Postgres cấp lock theo **hàng đợi FIFO**. Khi một `ALTER TABLE` (cần `ACCESS EXCLUSIVE`) phải chờ vì có transaction cũ đang giữ `ACCESS SHARE`, thì:

- `ALTER TABLE` **xếp hàng**,
- **mọi câu lệnh đến sau đó cũng phải xếp hàng phía sau nó** — kể cả `SELECT` vốn hoàn toàn tương thích với transaction đang chạy.

Kết quả: một transaction đọc dài 10 phút + một `ALTER TABLE` = **10 phút toàn bộ API 500**. Bản thân `ALTER TABLE` có khi chỉ chạy 5ms khi tới lượt.

```
Đang giữ:  T1 [ACCESS SHARE]  ← SELECT dài 10 phút
Hàng đợi:  T2 [ACCESS EXCLUSIVE]  ← ALTER TABLE, chờ T1
           T3 [ACCESS SHARE]      ← SELECT mới, LẼ RA chạy được, nhưng bị kẹt sau T2
           T4 [ACCESS SHARE]      ← ...
```

### Làm ngay

**S1** — mô phỏng một transaction đọc dài:
```sql
BEGIN;
SELECT count(*) FROM mig WHERE device_id = 1;
-- giữ nguyên, KHÔNG commit
```

**S2** — migration:
```sql
\timing on
ALTER TABLE mig ADD COLUMN queued_col int;    -- sẽ treo
```

**S3** — "traffic bình thường":
```sql
\timing on
SELECT count(*) FROM mig WHERE device_id = 2;   -- quan sát: có chạy không?
```

Ở một session khác (hoặc S1 sau khi mở tab mới), chụp hiện trường:
```sql
SELECT a.pid, a.state, a.wait_event_type, a.wait_event,
       pg_blocking_pids(a.pid) AS bi_chan_boi,
       now()-a.xact_start AS transaction_mo,
       substring(a.query,1,60) AS q
FROM pg_stat_activity a WHERE a.datname=current_database() AND a.pid<>pg_backend_pid()
ORDER BY a.xact_start;
```

Rồi `COMMIT` ở S1 và xem cả hàng đợi giải phóng theo thứ tự nào.

**Ghi vào writeup:**
- S3 có bị chặn không? Nó bị chặn bởi **ai** theo `pg_blocking_pids`?
- Dán dòng log tương ứng (`make logs`, tìm `process ... still waiting for AccessExclusiveLock`).
- Viết 3 câu giải thích cho một đồng nghiệp: *"vì sao thêm một cột lại làm API sập, dù bảng nhỏ."*

---

## §3. Lệnh nào rewrite bảng, lệnh nào chỉ sửa metadata

### Lý thuyết

Rewrite = viết lại **toàn bộ** bảng sang file mới (`relfilenode` đổi), cần **gấp đôi dung lượng đĩa**, giữ `ACCESS EXCLUSIVE` suốt thời gian đó, và sinh WAL bằng cả bảng.

| Lệnh | Rewrite? | Quét bảng? | Ghi chú |
|---|---|---|---|
| `ADD COLUMN c int` | không | không | tức thì |
| `ADD COLUMN c int DEFAULT 0` | **không** (PG11+) | không | default hằng lưu trong catalog |
| `ADD COLUMN c int NOT NULL DEFAULT 0` | không (PG11+) | không | |
| `ADD COLUMN c uuid DEFAULT gen_random_uuid()` | **CÓ** | có | default **volatile** → phải điền thật |
| `DROP COLUMN` | không | không | chỉ đánh dấu; **không** lấy lại đĩa |
| `ALTER COLUMN TYPE int → bigint` | **CÓ** | có | + rebuild mọi index liên quan |
| `ALTER COLUMN TYPE varchar(50) → varchar(100)` | không | không | nới rộng thì miễn phí |
| `ALTER COLUMN TYPE varchar → text` | không | không | |
| `SET NOT NULL` | không | **CÓ** (full scan dưới `ACCESS EXCLUSIVE`) | né được — xem Day 44 |
| `SET DEFAULT` / `DROP DEFAULT` | không | không | |
| `ADD CHECK (...)` | không | **CÓ** | `NOT VALID` để né |
| `ADD FOREIGN KEY` | không | **CÓ** cả 2 bảng | `NOT VALID` để né |
| `ADD PRIMARY KEY` | không | có (build index) | dùng `UNIQUE INDEX CONCURRENTLY` trước |
| `SET (fillfactor=..)` | không | không | lock nhẹ (`SHARE UPDATE EXCLUSIVE`) |

Cách tự kiểm chứng thay vì học thuộc: so `pg_relation_filenode()` trước và sau.

### Làm ngay

```sql
CREATE OR REPLACE FUNCTION fnode(t text) RETURNS oid LANGUAGE sql AS
$$ SELECT pg_relation_filenode(t::regclass) $$;

SELECT fnode('mig') AS truoc;
\timing on
ALTER TABLE mig ADD COLUMN a int;                              SELECT fnode('mig');
ALTER TABLE mig ADD COLUMN b int NOT NULL DEFAULT 7;           SELECT fnode('mig');
ALTER TABLE mig ADD COLUMN c uuid DEFAULT gen_random_uuid();   SELECT fnode('mig');
```

```sql
-- đổi kiểu: cái rẻ và cái đắt
ALTER TABLE mig ADD COLUMN s1 varchar(50);
SELECT fnode('mig');
ALTER TABLE mig ALTER COLUMN s1 TYPE varchar(100);   SELECT fnode('mig');
ALTER TABLE mig ALTER COLUMN s1 TYPE text;           SELECT fnode('mig');
ALTER TABLE mig ALTER COLUMN key_id TYPE bigint;     SELECT fnode('mig');
```

```sql
-- SET NOT NULL: không rewrite nhưng quét cả bảng
ALTER TABLE mig ALTER COLUMN b SET NOT NULL;      -- đo thời gian
-- DROP COLUMN không trả đĩa
SELECT pg_size_pretty(pg_total_relation_size('mig')) AS truoc_drop;
ALTER TABLE mig DROP COLUMN c;
SELECT pg_size_pretty(pg_total_relation_size('mig')) AS sau_drop;
```

Đo WAL của lệnh rewrite (kỹ thuật Day 37):
```sql
SELECT pg_current_wal_lsn() AS l1 \gset
ALTER TABLE mig ALTER COLUMN device_id TYPE numeric;
SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), :'l1')) AS wal_sinh_ra;
```

**Ghi vào writeup — bảng:** lệnh | thời gian | `relfilenode` đổi? | WAL sinh ra | dung lượng bảng sau. Trả lời câu §0.4: bảng 20GB đổi kiểu cột cần bao nhiêu đĩa trống, và WAL sinh ra bao nhiêu (ảnh hưởng gì tới replica và tới slot của Day 39)?

---

## §4. `lock_timeout` — cái van bạn phải có

### Lý thuyết

Migration **không được phép chờ lock vô hạn**, vì trong lúc chờ nó chặn cả hệ (§2). Mẫu đúng:

```sql
SET lock_timeout = '3s';        -- không lấy được lock trong 3s thì bỏ, thử lại sau
SET statement_timeout = '30s';  -- và bản thân lệnh cũng không được chạy quá lâu
ALTER TABLE ...;
```

Thất bại nhanh + retry tốt hơn nhiều so với "chờ được thì chờ". Thà migration fail 5 lần rồi thành công ở lần 6 lúc 2h sáng, còn hơn chặn API 10 phút giữa giờ cao điểm.

Cảnh báo về `statement_timeout` với DDL dài: nó **hủy cả lệnh đang rewrite**, mọi công đã làm bị rollback. Với lệnh chắc chắn dài, đặt `lock_timeout` nhỏ nhưng `statement_timeout = 0`.

Phân biệt:

| GUC | Đếm cái gì |
|---|---|
| `lock_timeout` | thời gian **chờ lấy** một lock |
| `statement_timeout` | thời gian chạy **cả câu lệnh** |
| `idle_in_transaction_session_timeout` | thời gian transaction rỗi (Day 40) |
| `deadlock_timeout` | sau bao lâu mới đi **tìm** deadlock (mặc định 1s) |

### Làm ngay

**S1:**
```sql
BEGIN; SELECT count(*) FROM mig WHERE device_id=1;   -- giữ ACCESS SHARE
```
**S2:**
```sql
SET lock_timeout = '2s';
\timing on
ALTER TABLE mig ADD COLUMN d int;
```

**Ghi vào writeup:** mã lỗi và SQLSTATE nhận được. So với §2 (không có `lock_timeout`): S3 lần này có bị chặn lâu không? Viết đoạn migration mẫu (pseudo-code hoặc SQL) có retry: thử tối đa 5 lần, `lock_timeout=3s`, backoff giữa các lần.

---

## §5. `CREATE INDEX` vs `CREATE INDEX CONCURRENTLY`

### Lý thuyết

| | `CREATE INDEX` | `CREATE INDEX CONCURRENTLY` |
|---|---|---|
| Lock | `SHARE` — **chặn mọi ghi** | `SHARE UPDATE EXCLUSIVE` — không chặn đọc lẫn ghi |
| Số lần quét bảng | 1 | **2** (+ chờ transaction cũ xong) |
| Thời gian | nhanh hơn | chậm hơn 2–3 lần |
| Chạy trong transaction | được | **KHÔNG** |
| Khi thất bại | không để lại gì | **để lại index `INVALID`** vẫn tốn chỗ và vẫn bị cập nhật khi ghi |

Ba hệ quả thực tế:
1. Flyway/Liquibase mặc định bọc mỗi migration trong transaction → `CONCURRENTLY` **lỗi**. Phải đánh dấu migration đó là non-transactional.
2. `CONCURRENTLY` phải chờ **mọi transaction đang mở** kết thúc — một session `idle in transaction` (Day 40) làm nó treo vô hạn.
3. Index `INVALID` bị bỏ quên là bloat câm: không bao giờ được dùng để đọc, nhưng **mọi INSERT/UPDATE vẫn phải cập nhật nó**.

### Làm ngay

```sql
-- (a) bản thường: đo thời gian và thử ghi song song
\timing on
CREATE INDEX ix_mig_1 ON mig(str_v);
```
Trong lúc nó chạy, ở **S2**: `INSERT INTO mig(device_id,key_id,ts) VALUES (1,1,now());` — quan sát bị chặn.

```sql
-- (b) bản concurrently
DROP INDEX ix_mig_1;
CREATE INDEX CONCURRENTLY ix_mig_2 ON mig(str_v);
```
Lặp lại INSERT ở S2 trong lúc chạy — lần này thế nào?

```sql
-- (c) không chạy được trong transaction
BEGIN;
CREATE INDEX CONCURRENTLY ix_mig_3 ON mig(dbl_v);
ROLLBACK;
```

```sql
-- (d) tạo một index INVALID rồi tìm nó
-- S1: BEGIN; SELECT count(*) FROM mig; (giữ)
-- S2: CREATE INDEX CONCURRENTLY ix_mig_bad ON mig(dbl_v);  -> Ctrl-C giữa chừng
SELECT c.relname, i.indisvalid, i.indisready,
       pg_size_pretty(pg_relation_size(c.oid)) AS size
FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid
WHERE NOT i.indisvalid;
```

**Ghi vào writeup — bảng:** cách tạo | thời gian | INSERT song song có bị chặn | kết quả khi chạy trong transaction. Và: query tìm index `INVALID` (đưa vào dashboard), + cách xử lý khi tìm thấy (`DROP INDEX CONCURRENTLY` rồi tạo lại).

### Dọn dẹp

```sql
DROP INDEX IF EXISTS ix_mig_2, ix_mig_3, ix_mig_bad;
DROP TABLE mig;
DROP FUNCTION fnode(text);
```

---

## §6. Bảng phân loại của riêng bạn

### Làm ngay

Viết vào writeup bảng ba cột — đây là thứ bạn sẽ dán vào wiki của team:

| Lệnh | Mức nguy hiểm | Cách làm an toàn |
|---|---|---|
| ... | an toàn / cần lock_timeout / **cấm giờ cao điểm** | ... |

Tối thiểu 12 dòng, mỗi dòng phải có **số bạn tự đo** làm căn cứ (thời gian, có rewrite hay không).

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?** (câu 3 là câu quan trọng nhất)

**B. Áp dụng vào hệ thật:**
1. Mở **3 migration gần nhất** trong repo của bạn. Với từng câu lệnh DDL: nó lấy lock gì, có rewrite không, mất bao lâu ở kích thước bảng production hiện tại?
2. Migration của bạn có `SET lock_timeout` không? Nếu không — đó là việc phải sửa tuần này.
3. Trên production (chỉ đọc): có index `INVALID` nào không? Có transaction nào mở > 5 phút không (nó sẽ làm mọi `CONCURRENTLY` treo)?

### Đạt khi

Bạn giải thích được cơ chế hàng đợi lock làm một `ALTER TABLE` đang chờ chặn cả `SELECT`, phân loại đúng lệnh nào rewrite bảng, và viết được migration có `lock_timeout` + retry.

**Xong thì gõ `/review-bai`.** Ngày mai: dùng đúng những thứ này để đổi schema trên bảng 5 triệu dòng mà **không** chặn ai.
