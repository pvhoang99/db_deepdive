# Day 44 — Đổi schema trên bảng 5 triệu dòng mà không chặn ai

**Thời lượng:** 60–90 phút · **Cần 2 terminal:** `make s1` (migration) và `make s2` (traffic).

> Hôm qua bạn học lệnh nào nguy hiểm. Hôm nay học cách làm **cùng việc đó** mà API không hề biết. Kỹ thuật lõi chỉ có một: **tách một thay đổi nguy hiểm thành nhiều bước, mỗi bước đều an toàn** — và giữa các bước, schema cũ và code cũ vẫn chạy được.

## Chuẩn bị

```sql
\timing on
\o /days/day-44/output.txt

CREATE TABLE mig2 AS SELECT device_id, key_id, ts, dbl_v, str_v FROM ts_kv LIMIT 3000000;
CREATE INDEX ON mig2(device_id, ts);
VACUUM ANALYZE mig2;
SELECT pg_size_pretty(pg_total_relation_size('mig2'));
```

Ở **S2**, chuẩn bị một "ứng dụng" chạy nền để đo tác động lên traffic thật:

```sql
CREATE TABLE probe (t timestamptz, ms numeric);
CREATE OR REPLACE PROCEDURE run_probe(seconds int) LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz; deadline timestamptz := clock_timestamp() + make_interval(secs=>seconds); n int;
BEGIN
  WHILE clock_timestamp() < deadline LOOP
    t0 := clock_timestamp();
    SELECT count(*) INTO n FROM mig2 WHERE device_id = 1 + (extract(epoch from clock_timestamp())::int % 50);
    INSERT INTO probe VALUES (t0, extract(epoch from clock_timestamp()-t0)*1000);
    COMMIT;
    PERFORM pg_sleep(0.05);
  END LOOP;
END $$;
```

Mỗi khi bài bảo "chạy probe", nghĩa là: **S2** gõ `TRUNCATE probe; CALL run_probe(60);` rồi **S1** chạy migration, xong thì xem:
```sql
SELECT count(*) AS mau, round(max(ms),1) AS max_ms,
       round(percentile_cont(0.99) WITHIN GROUP (ORDER BY ms)::numeric,1) AS p99_ms,
       round(avg(ms),1) AS avg_ms
FROM probe;
```

---

## §0. Đoán trước

1. `UPDATE mig2 SET c = 0` trên 3 triệu dòng — bảng phình thêm bao nhiêu %?
2. Trong lúc `UPDATE` đó chạy, `SELECT` trên cùng bảng có bị chặn không?
3. Thêm cột `NOT NULL` cho bảng 3 triệu dòng mà p99 của API **không đổi** — có làm được không? Bao nhiêu bước?
4. Đổi tên cột `str_v` → `text_value` trong lúc app đang chạy — an toàn hay không?

---

## §1. Expand / Contract — mẫu duy nhất bạn cần

### Lý thuyết

Vấn đề gốc: **code và schema không deploy cùng lúc**. Trong lúc rolling deploy, luôn có khoảnh khắc pod cũ và pod mới chạy song song. Nên mọi thay đổi phải qua 4 pha:

```
1. EXPAND   — thêm cái mới, KHÔNG bỏ cái cũ.  Schema mới tương thích code cũ.
2. MIGRATE  — code mới ghi cả hai, đọc cái cũ. Backfill dữ liệu theo lô.
3. SWITCH   — code mới đọc cái mới. Cái cũ vẫn còn đó (phòng rollback).
4. CONTRACT — sau vài ngày yên ổn, bỏ cái cũ.
```

Quy tắc bất di bất dịch: **mỗi bước phải tương thích ngược với bước trước**. Nếu bước nào không rollback được mà không mất dữ liệu, tách nhỏ thêm.

Đây chính là cách bạn đã làm với event schema trong CQRS — cùng một tư duy, áp cho bảng.

### Làm ngay

Ghi vào writeup: lấy **một** thay đổi schema thật bạn từng làm (hoặc sắp làm) và viết nó ra dưới dạng 4 pha, ghi rõ ở mỗi pha *code nào đang chạy* và *rollback về đâu*.

---

## §2. Thêm cột `NOT NULL` có giá trị mặc định động — 5 bước

### Lý thuyết

Cách sai (một dòng, chặn cả bảng):
```sql
ALTER TABLE mig2 ADD COLUMN status text NOT NULL DEFAULT 'unknown';  -- (an toàn PG11+, nhưng...)
ALTER TABLE mig2 ADD COLUMN owner_id bigint NOT NULL;                -- LỖI: bảng có dữ liệu
UPDATE mig2 SET owner_id = device_id % 100;                          -- 3 triệu dòng, một transaction
ALTER TABLE mig2 ALTER COLUMN owner_id SET NOT NULL;                 -- quét cả bảng dưới ACCESS EXCLUSIVE
```

Cách đúng:
```
1. ADD COLUMN owner_id bigint            -- nullable, tức thì
2. backfill theo lô (§3)                  -- nhiều transaction ngắn
3. ADD CONSTRAINT ck CHECK (owner_id IS NOT NULL) NOT VALID   -- không quét, lock ngắn
4. VALIDATE CONSTRAINT ck                 -- quét bảng dưới SHARE UPDATE EXCLUSIVE (KHÔNG chặn đọc/ghi)
5. ALTER COLUMN owner_id SET NOT NULL     -- PG12+: thấy CHECK hợp lệ nên BỎ QUA việc quét → tức thì
   ALTER TABLE ... DROP CONSTRAINT ck     -- dọn
```

Mấu chốt là bước 3–4: `NOT VALID` tách việc **quét dữ liệu** ra khỏi lock nặng. Việc quét ở bước 4 chạy dưới lock nhẹ và có thể mất nhiều phút mà không ai biết.

### Làm ngay

Chạy probe ở S2 rồi ở S1:

```sql
-- 1
\timing on
ALTER TABLE mig2 ADD COLUMN owner_id bigint;

-- 2 (backfill theo lô — chi tiết ở §3)
DO $$ DECLARE n int; BEGIN
  LOOP
    UPDATE mig2 SET owner_id = device_id % 100
    WHERE ctid IN (SELECT ctid FROM mig2 WHERE owner_id IS NULL LIMIT 50000);
    GET DIAGNOSTICS n = ROW_COUNT;
    EXIT WHEN n = 0;
    COMMIT;
  END LOOP;
END $$;

-- 3
ALTER TABLE mig2 ADD CONSTRAINT ck_owner CHECK (owner_id IS NOT NULL) NOT VALID;
-- 4
ALTER TABLE mig2 VALIDATE CONSTRAINT ck_owner;
-- 5
ALTER TABLE mig2 ALTER COLUMN owner_id SET NOT NULL;
ALTER TABLE mig2 DROP CONSTRAINT ck_owner;
```

Rồi làm lại toàn bộ bằng **cách sai** trên một bản sao để so:
```sql
CREATE TABLE mig2_bad AS SELECT * FROM mig2;   -- (bỏ cột owner_id đi trước nếu muốn công bằng)
ALTER TABLE mig2_bad DROP COLUMN owner_id;
-- chạy probe, rồi:
ALTER TABLE mig2_bad ADD COLUMN owner_id bigint;
UPDATE mig2_bad SET owner_id = device_id % 100;         -- MỘT transaction
ALTER TABLE mig2_bad ALTER COLUMN owner_id SET NOT NULL;
```

**Ghi vào writeup — bảng so sánh:**

| Cách | tổng thời gian | p99 của probe | max của probe | bảng phình bao nhiêu | WAL |
|---|---|---|---|---|---|

Chú ý bước 4 mất bao lâu và **probe có bị ảnh hưởng không** — đó là bằng chứng cho việc `VALIDATE` dùng lock nhẹ.

---

## §3. Backfill theo lô — vì sao một `UPDATE` lớn là thảm hoạ

### Lý thuyết

`UPDATE` 3 triệu dòng trong một transaction gây **năm** vấn đề cùng lúc, mỗi cái bạn đã học riêng:

| Vấn đề | Học ở |
|---|---|
| Mỗi dòng = tuple mới → bảng phình gần gấp đôi | Day 21–22 |
| Transaction dài ghim `xmin horizon` → chặn VACUUM toàn database | Day 40 §5 |
| Sinh WAL bằng cả bảng trong thời gian ngắn → replica lag vọt | Day 37–38 |
| Giữ lock hàng trên 3 triệu dòng → mọi UPDATE của app trên đó phải chờ | Day 28 |
| Nếu fail ở phút thứ 40 → rollback toàn bộ, làm lại từ đầu | — |

Backfill đúng cách: **lô nhỏ, commit sau mỗi lô, có nghỉ, có thể dừng và chạy tiếp**.

Ba chi tiết dễ sai:
1. **Chọn lô bằng khoá, không bằng `OFFSET`** — `OFFSET 2000000` phải quét lại 2 triệu dòng mỗi lô.
2. **Chừa nhịp cho autovacuum** — chạy liên tục 100% thì vacuum không đuổi kịp, bảng vẫn phình.
3. **Idempotent** — điều kiện lô phải là `WHERE col IS NULL` (hoặc tương đương) để chạy lại được sau khi dừng.

### Làm ngay

So ba cách backfill trên cùng dữ liệu:

```sql
-- chuẩn bị 3 bản
CREATE TABLE bf1 AS SELECT device_id, ts, dbl_v, NULL::bigint AS owner_id FROM mig2 LIMIT 1000000;
CREATE TABLE bf2 AS SELECT * FROM bf1;
CREATE TABLE bf3 AS SELECT * FROM bf1;
CREATE INDEX ON bf2(device_id);
CREATE INDEX ON bf3(device_id);
VACUUM ANALYZE bf1, bf2, bf3;
```

```sql
-- (a) một phát
SELECT pg_size_pretty(pg_total_relation_size('bf1')) AS truoc;
\timing on
UPDATE bf1 SET owner_id = device_id % 100;
SELECT pg_size_pretty(pg_total_relation_size('bf1')) AS sau,
       n_dead_tup FROM pg_stat_user_tables WHERE relname='bf1';

-- (b) theo lô, không nghỉ
DO $$ DECLARE n int; BEGIN
  LOOP
    UPDATE bf2 SET owner_id = device_id % 100
    WHERE ctid IN (SELECT ctid FROM bf2 WHERE owner_id IS NULL LIMIT 20000);
    GET DIAGNOSTICS n = ROW_COUNT; EXIT WHEN n=0; COMMIT;
  END LOOP;
END $$;

-- (c) theo lô, có nghỉ 50ms
DO $$ DECLARE n int; BEGIN
  LOOP
    UPDATE bf3 SET owner_id = device_id % 100
    WHERE ctid IN (SELECT ctid FROM bf3 WHERE owner_id IS NULL LIMIT 20000);
    GET DIAGNOSTICS n = ROW_COUNT; EXIT WHEN n=0; COMMIT;
    PERFORM pg_sleep(0.05);
  END LOOP;
END $$;
```

Đo cả ba (chạy probe ở S2 cho mỗi lần):
```sql
SELECT relname, n_live_tup, n_dead_tup,
       pg_size_pretty(pg_total_relation_size(relid)) AS size
FROM pg_stat_user_tables WHERE relname IN ('bf1','bf2','bf3');
```

**Ghi vào writeup — bảng 3 dòng:** cách | tổng thời gian | p99 probe | size sau | dead tuple | có dừng giữa chừng rồi chạy tiếp được không.

**Câu hỏi phải trả lời:** cách (b) và (c) chênh nhau thời gian bao nhiêu %, và bạn **mua được gì** bằng phần chênh đó?

---

## §4. Đổi kiểu cột mà không rewrite

### Lý thuyết

`int → bigint` trên bảng lớn = rewrite + `ACCESS EXCLUSIVE` (Day 43). Trên bảng 500GB thì không có cửa. Mẫu expand/contract:

```
1. ADD COLUMN key_id_new bigint                      -- tức thì
2. CREATE TRIGGER giữ hai cột đồng bộ khi ghi mới    -- từ giờ dữ liệu mới luôn đúng
3. backfill theo lô cho dữ liệu cũ
4. tạo index/constraint tương ứng bằng CONCURRENTLY
5. trong MỘT transaction ngắn: đổi tên hai cột cho nhau
6. sau vài ngày: DROP COLUMN key_id_old, DROP TRIGGER
```

Bước 5 lấy `ACCESS EXCLUSIVE` nhưng chỉ vài **mili**giây — chấp nhận được nếu có `lock_timeout` (Day 43 §4).

### Làm ngay

```sql
ALTER TABLE mig2 ADD COLUMN key_id_new bigint;

CREATE OR REPLACE FUNCTION sync_key_id() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.key_id_new := NEW.key_id; RETURN NEW; END $$;
CREATE TRIGGER trg_sync_key_id BEFORE INSERT OR UPDATE ON mig2
FOR EACH ROW EXECUTE FUNCTION sync_key_id();

-- backfill
DO $$ DECLARE n int; BEGIN
  LOOP
    UPDATE mig2 SET key_id_new = key_id
    WHERE ctid IN (SELECT ctid FROM mig2 WHERE key_id_new IS NULL LIMIT 50000);
    GET DIAGNOSTICS n = ROW_COUNT; EXIT WHEN n=0; COMMIT; PERFORM pg_sleep(0.02);
  END LOOP;
END $$;

-- đổi tên trong transaction ngắn
BEGIN;
SET LOCAL lock_timeout = '3s';
ALTER TABLE mig2 RENAME COLUMN key_id     TO key_id_old;
ALTER TABLE mig2 RENAME COLUMN key_id_new TO key_id;
COMMIT;
```

**Ghi vào writeup:** thời gian của transaction đổi tên (đo bằng `\timing`). So với thời gian `ALTER COLUMN TYPE` bạn đo ở Day 43 §3. Trigger làm INSERT chậm đi bao nhiêu % (đo bằng `INSERT ... SELECT` 100k dòng có/không trigger)?

**Câu hỏi thiết kế:** giữa bước 5 và bước 6, code cũ (đang đọc `key_id`) có chạy được không? Còn code đọc `key_id_old`? Vẽ ra dòng thời gian deploy.

---

## §5. Ràng buộc an toàn: FK và UNIQUE

### Lý thuyết

| Muốn | Cách sai | Cách đúng |
|---|---|---|
| Thêm FK | `ADD FOREIGN KEY ...` → quét **cả hai** bảng, khoá ghi | `ADD FOREIGN KEY ... NOT VALID` rồi `VALIDATE CONSTRAINT` |
| Thêm UNIQUE | `ADD CONSTRAINT ... UNIQUE` → build index dưới lock nặng | `CREATE UNIQUE INDEX CONCURRENTLY` rồi `ADD CONSTRAINT ... UNIQUE USING INDEX` |
| Thêm PK | `ADD PRIMARY KEY` | như trên + `SET NOT NULL` theo mẫu §2 |
| Thêm CHECK | `ADD CHECK` | `ADD CHECK ... NOT VALID` rồi `VALIDATE` |

`NOT VALID` nghĩa là: **áp dụng cho dữ liệu mới ngay lập tức**, chỉ chưa kiểm tra dữ liệu cũ. Đây là điểm nhiều người hiểu nhầm — nó không phải "constraint tắt".

### Làm ngay

```sql
-- FK
CREATE TABLE owner (id bigint PRIMARY KEY);
INSERT INTO owner SELECT DISTINCT owner_id FROM mig2 WHERE owner_id IS NOT NULL;

\timing on
ALTER TABLE mig2 ADD CONSTRAINT fk_owner FOREIGN KEY (owner_id) REFERENCES owner(id) NOT VALID;
ALTER TABLE mig2 VALIDATE CONSTRAINT fk_owner;

-- chứng minh NOT VALID vẫn chặn dữ liệu mới sai
ALTER TABLE mig2 DROP CONSTRAINT fk_owner;
ALTER TABLE mig2 ADD CONSTRAINT fk_owner FOREIGN KEY (owner_id) REFERENCES owner(id) NOT VALID;
INSERT INTO mig2(device_id, key_id, ts, owner_id) VALUES (1,1,now(), 999999);   -- lỗi hay không?
```

```sql
-- UNIQUE bằng CONCURRENTLY
CREATE TABLE uq AS SELECT DISTINCT device_id, ts FROM mig2 LIMIT 500000;
CREATE UNIQUE INDEX CONCURRENTLY ix_uq ON uq(device_id, ts);
\timing on
ALTER TABLE uq ADD CONSTRAINT uq_dev_ts UNIQUE USING INDEX ix_uq;
SELECT conname, contype FROM pg_constraint WHERE conrelid='uq'::regclass;
```

**Ghi vào writeup:** thời gian và lock mode của từng bước (dùng `pg_locks` như Day 43 §1). `NOT VALID` có chặn được INSERT sai không — kết quả thật là gì? `ADD CONSTRAINT ... USING INDEX` mất bao lâu so với `ADD CONSTRAINT ... UNIQUE` thường?

---

## §6. Những thay đổi **không** thể làm an toàn trong một bước

### Lý thuyết

| Thay đổi | Vì sao nguy hiểm với rolling deploy | Cách thay thế |
|---|---|---|
| `RENAME COLUMN` | pod cũ vẫn dùng tên cũ → lỗi ngay | expand/contract (§4) hoặc view tương thích |
| `DROP COLUMN` | pod cũ `SELECT *` hoặc INSERT thiếu cột | bỏ khỏi code trước, chờ 1 deploy, rồi mới drop |
| Thu hẹp kiểu (`text → varchar(20)`) | dữ liệu dài hơn sẽ fail | thêm CHECK NOT VALID trước, sửa dữ liệu, rồi đổi |
| Thêm `NOT NULL` cho cột code cũ chưa ghi | pod cũ INSERT thiếu → lỗi | thêm DEFAULT trước, đợi code mới, rồi NOT NULL |
| Đổi ngữ nghĩa cột (đơn vị, timezone) | không phát hiện được bằng lỗi — **hỏng dữ liệu âm thầm** | cột mới, không tái sử dụng cột cũ |

Dòng cuối là dòng đắt nhất: lỗi schema thì fail nhanh và thấy ngay; lỗi ngữ nghĩa thì phát hiện sau 3 tháng, lúc dữ liệu đã lẫn lộn.

### Làm ngay

Chứng minh bằng view tương thích — cách cứu khi buộc phải đổi tên:
```sql
ALTER TABLE mig2 RENAME TO mig2_real;
CREATE VIEW mig2 AS SELECT device_id, key_id AS key_id, ts, dbl_v, str_v, owner_id FROM mig2_real;
SELECT count(*) FROM mig2 WHERE device_id = 1;
INSERT INTO mig2(device_id, key_id, ts) VALUES (1,1,now());   -- view có ghi được không?
```

**Ghi vào writeup:** view đơn giản có tự động ghi được không (auto-updatable view)? Điều kiện là gì? Khi nào bạn cần `INSTEAD OF` trigger?

### Dọn dẹp

```sql
DROP VIEW mig2; ALTER TABLE mig2_real RENAME TO mig2;
DROP TABLE mig2, mig2_bad, bf1, bf2, bf3, uq, owner, probe CASCADE;
DROP PROCEDURE IF EXISTS run_probe(int);
DROP FUNCTION IF EXISTS sync_key_id();
VACUUM;
```

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B. Áp dụng vào hệ thật:** chọn **một** thay đổi schema bạn đang cần làm trên hệ thật. Viết ra:
- kế hoạch 4 pha expand/contract, mỗi pha là những câu SQL cụ thể,
- lock mode và thời gian ước lượng của từng câu (dựa trên kích thước bảng thật),
- điểm rollback của từng pha,
- và **cách bạn biết pha trước đã an toàn** trước khi sang pha sau (metric nào, chờ bao lâu).

### Đạt khi

Bạn thêm được một cột `NOT NULL` vào bảng 3 triệu dòng với p99 của probe **không đổi rõ rệt**, và giải thích được vì sao `NOT VALID` + `VALIDATE` lại rẻ hơn làm một phát — bằng lock mode, không bằng cảm giác.

**Xong thì gõ `/review-bai`.**
