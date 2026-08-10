# Migration Playbook — Postgres

> Tài liệu vận hành. Mọi con số trong đây được đo trên lab Postgres 17 (8 core, `shared_buffers=256MB`) với bảng 2–5 triệu dòng. Ngoại suy sang production bằng tỉ lệ số dòng, và **đo lại** trước khi tin.

---

## 1. Bảng phân loại DDL

| # | Lệnh | Lock mode | Rewrite? | Quét bảng? | Số đo (2M dòng) | Mức nguy hiểm |
|---|---|---|---|---|---|---|
| 1 | `SELECT` | `ACCESS SHARE` | — | — | — | — |
| 2 | `INSERT`/`UPDATE`/`DELETE` | `ROW EXCLUSIVE` | — | — | — | — |
| 3 | `ADD COLUMN c int` | `ACCESS EXCLUSIVE` | không | không | **2,87 ms** | **an toàn** + `lock_timeout` |
| 4 | `ADD COLUMN c int NOT NULL DEFAULT <hằng>` | `ACCESS EXCLUSIVE` | **không** (PG11+) | không | **3,26 ms** | **an toàn** + `lock_timeout` |
| 5 | `ADD COLUMN c DEFAULT <hàm VOLATILE>` | `ACCESS EXCLUSIVE` | **CÓ** | có | **5.078 ms** | **CẤM giờ cao điểm** |
| 6 | `ALTER COLUMN TYPE` nới rộng (`varchar(50)→varchar(100)`, `→text`) | `ACCESS EXCLUSIVE` | không | không | **2,66 / 2,75 ms** | **an toàn** |
| 7 | `ALTER COLUMN TYPE` đổi thật (`smallint→bigint`) | `ACCESS EXCLUSIVE` | **CÓ** | có | **3.290 ms, WAL 298 MB, +31% kích thước** | **CẤM** — dùng expand/contract |
| 8 | `SET NOT NULL` (trực tiếp) | `ACCESS EXCLUSIVE` | không | **CÓ (full scan)** | **240,9 ms** (2M) / **1.155 ms** (3M) | **cần cẩn thận** |
| 9 | `ADD CHECK` | `ACCESS EXCLUSIVE` | không | **CÓ** | **274,7 ms** | **cần cẩn thận** |
| 10 | `ADD CHECK ... NOT VALID` | `ACCESS EXCLUSIVE` | không | không | **3,08 ms** | **an toàn** |
| 11 | `VALIDATE CONSTRAINT` | **`SHARE UPDATE EXCLUSIVE`** | không | CÓ | **169,6–481,6 ms** | **an toàn** (không chặn đọc/ghi) |
| 12 | `ADD FOREIGN KEY` | `SHARE ROW EXCLUSIVE` + `ACCESS EXCL` | không | **CÓ cả 2 bảng** | ~485 ms | **cần cẩn thận** → dùng `NOT VALID` |
| 13 | `ADD CONSTRAINT ... UNIQUE` | `ACCESS EXCLUSIVE` | không | có (build index) | **785,2 ms** | **cần cẩn thận** |
| 14 | `CREATE UNIQUE INDEX CONCURRENTLY` + `ADD CONSTRAINT ... USING INDEX` | `SHARE UPDATE EXCL` + `ACCESS EXCL` | không | có | 197,9 ms + **3,13 ms khoá** | **an toàn** |
| 15 | `DROP COLUMN` | `ACCESS EXCLUSIVE` | không | không — **và KHÔNG trả đĩa** | 3,04 ms | **an toàn** (đĩa thu hồi bằng `pg_repack`) |
| 16 | `CREATE INDEX` | **`SHARE`** — chặn **GHI** | — | có | 547,3 ms; INSERT bị chặn **216 ms** | **cần cẩn thận** |
| 17 | `CREATE INDEX CONCURRENTLY` | `SHARE UPDATE EXCLUSIVE` | — | **2 lần** | 914,9 ms; INSERT **7,4 ms** | **an toàn** |
| 18 | `RENAME COLUMN` / `RENAME TABLE` | `ACCESS EXCLUSIVE` | không | không | **10,86 ms** (2 cột) | **an toàn về lock**, **nguy hiểm với rolling deploy** |
| 19 | `TRUNCATE` | `ACCESS EXCLUSIVE` | — | — | 0,57 ms | **CẤM** trên bảng đang phục vụ |
| 20 | `VACUUM FULL` / `REINDEX` (không CONCURRENTLY) | `ACCESS EXCLUSIVE` toàn thời gian | **CÓ** | — | phút–giờ | **CẤM** → `pg_repack` / `REINDEX CONCURRENTLY` |
| 21 | `ANALYZE`, `SET (fillfactor=…)`, `SET (autovacuum_*)` | `SHARE UPDATE EXCLUSIVE` | không | (ANALYZE lấy mẫu) | 111,8 / 0,12 ms | **an toàn** |

**Câu duy nhất phải thuộc: `ACCESS EXCLUSIVE` chặn cả `SELECT`.**
**Câu thứ hai: một `ACCESS EXCLUSIVE` đang CHỜ cũng chặn mọi thứ đến sau nó** (hàng đợi FIFO) — đo được: `SELECT` vô can chờ **5.099 ms**.

---

## 2. Khuôn migration chuẩn

### 2.1 Khung ngoài (script deploy)

```bash
#!/usr/bin/env bash
set -euo pipefail
for i in 1 2 3 4 5; do
  if psql -v ON_ERROR_STOP=1 -d "$DB" -f migration.sql; then
    echo "OK ở lần thử $i"; exit 0
  fi
  echo "Lần $i thất bại (nhiều khả năng lock timeout), chờ $((i*10))s..."
  sleep $((i*10))
done
echo "Thất bại sau 5 lần — có transaction dài đang chạy. Kiểm tra pg_stat_activity."; exit 1
```

- `ON_ERROR_STOP=1` bắt buộc — không có nó, psql chạy tiếp sau lỗi và bạn có schema nửa vời.
- Backoff tăng dần: nếu có job dài đang chạy, thử lại ngay chỉ tốn công.

### 2.2 Thêm cột `NOT NULL` — 5 bước

```sql
SET lock_timeout = '3s';
ALTER TABLE t ADD COLUMN c bigint;                                  -- ~3 ms

-- backfill theo lô (idempotent, dừng-chạy-tiếp được)
DO $$ DECLARE n int; BEGIN
  LOOP
    UPDATE t SET c = <biểu thức>
    WHERE ctid IN (SELECT ctid FROM t WHERE c IS NULL LIMIT 50000);
    GET DIAGNOSTICS n = ROW_COUNT; EXIT WHEN n = 0;
    COMMIT; PERFORM pg_sleep(0.02);        -- nhịp cho autovacuum + replica
  END LOOP;
END $$;

SET lock_timeout = '3s';
ALTER TABLE t ADD CONSTRAINT ck_c CHECK (c IS NOT NULL) NOT VALID;  -- ~6 ms
ALTER TABLE t VALIDATE CONSTRAINT ck_c;                             -- lâu, SHARE UPDATE EXCL
ALTER TABLE t ALTER COLUMN c SET NOT NULL;                          -- ~5 ms (bỏ qua quét)
ALTER TABLE t DROP CONSTRAINT ck_c;
```

**Đo được: cửa sổ khoá 6,49 ms thay vì 1.155 ms — 178×.**

### 2.3 Thêm constraint — 2 bước

```sql
ALTER TABLE t ADD CONSTRAINT fk FOREIGN KEY (x) REFERENCES u(id) NOT VALID;  -- ~3 ms
ALTER TABLE t VALIDATE CONSTRAINT fk;                                        -- SHARE UPDATE EXCL
```
**`NOT VALID` chặn dữ liệu MỚI sai ngay lập tức** — nó chỉ chưa kiểm tra dữ liệu cũ.

### 2.4 Thêm UNIQUE — 2 bước

```sql
SET statement_timeout = '0';
CREATE UNIQUE INDEX CONCURRENTLY ix ON t (a, b);        -- SHARE UPDATE EXCL
SET lock_timeout = '3s';
ALTER TABLE t ADD CONSTRAINT uq_ab UNIQUE USING INDEX ix;  -- ~3 ms
```
**Cửa sổ khoá 3,13 ms thay vì 785 ms — 251×.**

### 2.5 Đổi kiểu cột — expand/contract 6 bước

```sql
-- 1
ALTER TABLE t ADD COLUMN c_new bigint;
-- 2  (hoặc dual-write ở tầng app — nhanh hơn nhưng phải sửa mọi đường ghi)
CREATE FUNCTION sync_c() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.c_new := NEW.c; RETURN NEW; END $$;
CREATE TRIGGER trg_sync_c BEFORE INSERT OR UPDATE ON t FOR EACH ROW EXECUTE FUNCTION sync_c();
-- 3  backfill theo lô (như 2.2)
-- 4  index/constraint bằng CONCURRENTLY
-- 5  ⚠ DROP TRIGGER TRƯỚC KHI RENAME (nếu không: lỗi cached plan)
DROP TRIGGER trg_sync_c ON t;
BEGIN;
  SET LOCAL lock_timeout = '3s';
  ALTER TABLE t RENAME COLUMN c     TO c_old;
  ALTER TABLE t RENAME COLUMN c_new TO c;
COMMIT;                                        -- đo được: 10,86 ms
-- 6  sau ≥ 7 ngày: DROP COLUMN c_old; DROP FUNCTION sync_c();
```

**Cửa sổ khoá 10,86 ms thay vì 3.290 ms — 303×. Và 10,86 ms KHÔNG phụ thuộc kích thước bảng.**

⚠ Trigger làm `INSERT` chậm **~2×** trong suốt pha 2–3.
⚠ Sau rename, hàm PL/pgSQL dùng `NEW.c` có thể lỗi cached plan: `type of parameter N (bigint) does not match that when preparing the plan (smallint)`.

---

## 3. Checklist trước khi chạy (8 query)

```sql
-- 1. Có transaction nào mở > 60s không?  (chặn ALTER, làm treo CONCURRENTLY ở REPEATABLE READ)
SELECT pid, state, round(EXTRACT(epoch FROM now()-xact_start)::numeric,1) AS xact_giay,
       substring(query,1,60)
FROM pg_stat_activity WHERE xact_start < now()-interval '60 seconds'
  AND backend_type='client backend' ORDER BY xact_start;
-- NGƯỠNG: phải rỗng.

-- 2. Có index INVALID tồn đọng không?
SELECT indexrelid::regclass, indrelid::regclass FROM pg_index WHERE NOT indisvalid;
-- NGƯỠNG: phải rỗng (nếu có: DROP INDEX CONCURRENTLY rồi tạo lại).

-- 3. Có constraint chưa validate không?
SELECT conrelid::regclass, conname FROM pg_constraint WHERE NOT convalidated;
-- NGƯỠNG: mọi dòng phải là quyết định có chủ đích, không phải quên.

-- 4. Replica lag?
SELECT application_name, state,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag
FROM pg_stat_replication;
-- NGƯỠNG: < 100 MB. Migration sinh WAL lớn sẽ làm lag tệ hơn nhiều.

-- 5. Replication slot có ổn không?
SELECT slot_name, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS giu
FROM pg_replication_slots;
-- NGƯỠNG: wal_status = 'reserved' và giu < 5 GB.

-- 6. Đĩa còn đủ cho rewrite không? (nếu migration có rewrite)
SELECT pg_size_pretty(pg_total_relation_size('<bảng>')) AS can_them_it_nhat_bang_nay;
-- NGƯỠNG: free space ≥ 2× kích thước bảng.

-- 7. Autovacuum có đang chạy trên bảng đó không? (xung đột với VALIDATE)
SELECT pid, query FROM pg_stat_activity WHERE query ILIKE '%autovacuum%<bảng>%';

-- 8. Bảng đang bloat sao? (migration sẽ làm tệ hơn ~2×)
SELECT n_live_tup, n_dead_tup, pg_size_pretty(pg_total_relation_size(relid))
FROM pg_stat_user_tables WHERE relname = '<bảng>';
```

---

## 4. Ngưỡng dừng

| Điều kiện | Hành động |
|---|---|
| Có bất kỳ chờ lock nào > **3 giây** | `lock_timeout` tự huỷ. Đọc `pg_blocking_pids`, xử lý thủ phạm, thử lại. |
| max latency của probe > **500 ms** | Dừng bước hiện tại. Có bước nào đang giữ `ACCESS EXCLUSIVE` lâu hơn dự tính. |
| Replica lag > **1 GB** và đang tăng | **Tạm dừng backfill** (không cần rollback — backfill idempotent), chờ replica đuổi kịp. |
| `pg_wal` > **70% đĩa** | Dừng ngay. Kiểm tra slot (mục 3.5). |
| `n_dead_tup` của bảng > **2× n_live_tup** | Tạm dừng backfill, chạy `VACUUM` thủ công, rồi tiếp. |
| Kết nối tới DB lỗi / pool cạn | Dừng. Đây là dấu hiệu migration đang chặn cả hệ. |

**Cách huỷ an toàn:**
- Backfill: `Ctrl-C` bất cứ lúc nào — lô đang chạy rollback, các lô trước đã commit. Chạy lại tiếp từ chỗ dở.
- `CREATE INDEX CONCURRENTLY`: `pg_cancel_backend(pid)` — **để lại index `INVALID`**, phải `DROP INDEX CONCURRENTLY` rồi làm lại.
- `ALTER TABLE` đang rewrite: `pg_cancel_backend(pid)` — rollback sạch, nhưng mất toàn bộ công đã làm.
- **Không dùng `pg_terminate_backend`** trừ khi `pg_cancel_backend` không ăn thua.

---

## 5. Không bao giờ làm trong giờ cao điểm

| Lệnh | Vì sao — bằng số |
|---|---|
| `ALTER COLUMN TYPE` (đổi thật) | **3.290 ms `ACCESS EXCLUSIVE`** cho 2M dòng ⇒ ~**14 phút** cho 500M dòng. Cộng 298 MB WAL/2M dòng ⇒ ~**75 GB** cho 500M ⇒ replica lag hàng chục phút. |
| `ADD COLUMN ... DEFAULT <volatile>` | **5.078 ms** cho 2M dòng, rewrite toàn bảng, cần **2× đĩa**. |
| `SET NOT NULL` trực tiếp | **1.155 ms `ACCESS EXCLUSIVE`** cho 3M dòng. Ở 5.000 qps = **~5.775 request** treo > 1 s ⇒ vượt `connectionTimeout` ⇒ **pool cạn ⇒ mọi endpoint lỗi**, kể cả endpoint không đụng bảng này. |
| `ADD CHECK` / `ADD FOREIGN KEY` trực tiếp | **274,7 / 485 ms** quét dưới `ACCESS EXCLUSIVE`. Có `NOT VALID` thì còn **3 ms** — không có lý do nào để làm trực tiếp. |
| `ADD CONSTRAINT ... UNIQUE` trực tiếp | **785,2 ms** khoá; qua `CONCURRENTLY` còn **3,13 ms** (**251×**). |
| `CREATE INDEX` (không CONCURRENTLY) | chặn **mọi ghi** 547 ms/2M dòng; INSERT song song bị chặn **216 ms**. |
| `VACUUM FULL` / `REINDEX` | `ACCESS EXCLUSIVE` toàn thời gian, cần 2× đĩa. |
| `TRUNCATE` | `ACCESS EXCLUSIVE`, và không rollback được dữ liệu. |
| **Bất kỳ DDL nào không có `lock_timeout`** | Một `ALTER` chờ lock chặn **mọi query đến sau** — đo được `SELECT` vô can chờ **5.099 ms**. |

---

## 6. Ba luật ngắn

1. **Mọi migration đều có `SET lock_timeout`.** Không có ngoại lệ. `statement_timeout = 0` cho DDL chắc chắn dài.
2. **Tách việc quét dữ liệu ra khỏi lock nặng.** `NOT VALID` + `VALIDATE`, `CONCURRENTLY` + `USING INDEX`, backfill theo lô — cùng một mẫu, năm ứng dụng.
3. **Đo bằng `max` latency và cửa sổ khoá, không bằng p99.** p99 của cách sai (1,67 ms) còn *thấp hơn* cách đúng (1,90 ms) trong khi nó làm một request đứng **1,2 giây**.
