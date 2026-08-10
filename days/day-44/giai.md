# Day 44 — Lời giải: Đổi schema trên bảng 3 triệu dòng mà không chặn ai

> Bài chữa. Đo thật trên `mig2` (3.000.000 dòng, 262 MB) với một **probe** chạy song song — một query điểm rẻ (~0,47 ms) mô phỏng traffic API, lấy mẫu liên tục trong lúc migration chạy.
>
> Kết luận một câu: **cách đúng và cách sai đều mất ~20–27 giây và sinh ~1,2 GB WAL, nhưng cách sai làm một request đứng 1.195 ms còn cách đúng chỉ 28,6 ms — 41,8×.** Và p99 **không** phát hiện được khác biệt đó.

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án đo được | Bẫy |
|---|---|---|---|
| 1 | `UPDATE` 3 triệu dòng — bảng phình bao nhiêu? | **262 MB → 546 MB = +108%** (hơn gấp đôi), 3.000.000 dead tuple. **Cả hai cách đều thế** — backfill theo lô **không** giảm bloat. | Bẫy: nhiều người tưởng chia lô thì bảng ít phình hơn. Không — cùng số dòng bị viết lại. Cái khác là **autovacuum có cơ hội chen vào giữa các lô**, và transaction không giữ `xmin` suốt. |
| 2 | Trong lúc `UPDATE` chạy, `SELECT` có bị chặn không? | **Không** — `UPDATE` lấy `ROW EXCLUSIVE`, `SELECT` lấy `ACCESS SHARE`, hai cái tương thích. Probe vẫn chạy suốt (1.669 mẫu). | Bẫy ngược: cái chặn không phải `UPDATE` mà là **`SET NOT NULL` phía sau nó** — 1.155 ms `ACCESS EXCLUSIVE`. |
| 3 | Thêm cột `NOT NULL` mà p99 không đổi — làm được không? Bao nhiêu bước? | **Được. 5 bước.** p99 probe: baseline **1,45 ms** → cách đúng **1,90 ms**. Bước khoá nặng nhất chỉ **5,25 ms** (`SET NOT NULL` sau khi đã có `CHECK` hợp lệ). | Bẫy đo lường: p99 của **cách sai** cũng chỉ 1,67 ms! Vì chỉ **1 mẫu** bị chặn. Phải nhìn **max**, không nhìn p99 — xem §2. |
| 4 | Đổi tên cột trong lúc app đang chạy — an toàn? | **Không an toàn với rolling deploy**, nhưng transaction đổi tên chỉ mất **10,86 ms**. Vấn đề không phải thời gian mà là **pod cũ vẫn dùng tên cũ**. | Và một bẫy tôi vấp thật: sau khi đổi tên, **trigger đang chạy bị lỗi cached plan** — `type of parameter 15 (bigint) does not match that when preparing the plan (smallint)`. Xem §4. |

---

## §1. Expand / Contract — mẫu duy nhất bạn cần

Vấn đề gốc: **code và schema không deploy cùng lúc**. Trong rolling deploy luôn có khoảnh khắc pod cũ và pod mới chạy song song.

```
1. EXPAND   — thêm cái mới, KHÔNG bỏ cái cũ.   Schema mới tương thích code cũ.
2. MIGRATE  — code mới ghi cả hai, đọc cái cũ.  Backfill dữ liệu cũ theo lô.
3. SWITCH   — code mới đọc cái mới.             Cái cũ vẫn còn (phòng rollback).
4. CONTRACT — sau vài ngày yên ổn, bỏ cái cũ.
```

**Quy tắc bất di bất dịch: mỗi bước phải tương thích ngược với bước trước.** Nếu bước nào không rollback được mà không mất dữ liệu, tách nhỏ thêm.

Đây chính là cách bạn đã làm với event schema trong CQRS — cùng tư duy, áp cho bảng. Điểm chung: **không bao giờ có một khoảnh khắc mà chỉ một phiên bản code chạy được.**

### Ví dụ áp cho một thay đổi thật: tách `meta->>'model'` thành cột (Day 41 §5)

| Pha | SQL | Code đang chạy | Rollback về đâu |
|---|---|---|---|
| **1. EXPAND** | `ALTER TABLE device ADD COLUMN model text;` | Code cũ (chỉ đọc `meta`) — **không biết cột mới tồn tại** | `DROP COLUMN model`, không mất gì |
| **2. MIGRATE** | Deploy code ghi **cả** `meta` lẫn `model`. Backfill lô: `UPDATE device SET model = meta->>'model' WHERE model IS NULL LIMIT n` | Code mới ghi 2 chỗ, **vẫn đọc `meta`** | Rollback code về bản cũ — dữ liệu vẫn đúng vì `meta` vẫn được ghi |
| **3. SWITCH** | `CREATE INDEX CONCURRENTLY ON device(model);` rồi deploy code **đọc** `model` | Code mới đọc `model`, vẫn ghi cả hai | Rollback code — `meta` vẫn đúng |
| **4. CONTRACT** | Sau **7 ngày**: bỏ ghi `meta->>'model'` trong code, rồi tuần sau `UPDATE device SET meta = meta - 'model'` | — | Điểm không quay lại |

**Cách biết pha trước đã an toàn:** giữa pha 2 và 3, chạy query đối chiếu và chờ nó về 0 trong 24 giờ:
```sql
SELECT count(*) FROM device WHERE model IS DISTINCT FROM (meta->>'model');
```

---

## §2. Thêm cột `NOT NULL` — 5 bước vs 1 bước

Cùng một kết quả cuối: cột `owner_id bigint NOT NULL` trên 3 triệu dòng.

### Cách đúng (5 bước)

| Bước | Lệnh | Thời gian | Lock |
|---|---|---|---|
| 1 | `ADD COLUMN owner_id bigint` (nullable) | **3,36 ms** | `ACCESS EXCL` (3 ms) |
| 2 | backfill theo lô 50.000, nghỉ 20 ms | **26.620 ms** | `ROW EXCL` — không chặn đọc |
| 3 | `ADD CONSTRAINT ck CHECK (owner_id IS NOT NULL) NOT VALID` | **6,49 ms** | `ACCESS EXCL` (6 ms) |
| 4 | `VALIDATE CONSTRAINT ck` | **286,0 ms** | **`SHARE UPDATE EXCL` — không chặn ai** |
| 5 | `ALTER COLUMN owner_id SET NOT NULL` | **5,25 ms** | `ACCESS EXCL` (5 ms) |
| 5b | `DROP CONSTRAINT ck` | 2,95 ms | `ACCESS EXCL` |
| | **Tổng** | **~26,9 s** | **cửa sổ khoá dài nhất: 6,49 ms** |

### Cách sai (1 phát)

| Bước | Lệnh | Thời gian | Lock |
|---|---|---|---|
| 1 | `ADD COLUMN owner_id bigint` | 3,36 ms | `ACCESS EXCL` |
| 2 | `UPDATE mig2_bad SET owner_id = device_id % 100` | **17.921 ms** | `ROW EXCL` |
| 3 | `ALTER COLUMN owner_id SET NOT NULL` | **1.155,25 ms** | **`ACCESS EXCL` suốt 1,16 giây** |
| | **Tổng** | **~19,1 s** | **cửa sổ khoá dài nhất: 1.155 ms** |

### Kết quả trên probe

| | Baseline (không migration) | **Cách đúng** | **Cách sai** |
|---|---|---|---|
| Số mẫu | 729 | 1.824 | 1.669 |
| **max** | **1,78 ms** | **28,57 ms** | **1.195,50 ms** |
| p99 | 1,45 ms | 1,90 ms | **1,67 ms** |
| avg | 0,470 ms | 0,379 ms | 1,125 ms |
| Mẫu > 100 ms | 0 | 0 | **1** |
| Bảng sau | 262 MB | **546 MB** | **546 MB** |
| Dead tuple | 0 | 2.999.936 | 3.000.000 |
| WAL | — | **1.221 MB** | **1.255 MB** |

**Ba điều đọc từ bảng này, và điều thứ hai là quan trọng nhất:**

**a) Cách sai làm một request đứng 1.195,50 ms; cách đúng chỉ 28,57 ms — 41,8×.** Con số 1.195 ms khớp gần như chính xác với thời gian `SET NOT NULL` chạy (1.155 ms) — đó là một probe không may xin `ACCESS SHARE` ngay lúc `ALTER TABLE` đang giữ `ACCESS EXCLUSIVE`.

**b) p99 KHÔNG phát hiện được vấn đề: 1,67 ms (cách sai) vs 1,90 ms (cách đúng) — cách sai còn "tốt hơn".**

Vì chỉ **1 trong 1.669 mẫu** bị chặn = 0,06%, nằm ngoài p99. Nếu bạn đánh giá migration bằng p99, bạn sẽ kết luận cách sai an toàn.

> **Với traffic thật, con số phải nhìn là: cửa sổ khoá × qps = số request bị ảnh hưởng.** Ở 5.000 qps, 1.155 ms khoá = **~5.775 request** treo hơn một giây — quá `connectionTimeout` của HikariCP (Day 36) ⇒ pool cạn ⇒ **lỗi lan sang mọi endpoint khác**, kể cả những endpoint không đụng bảng này.
>
> Đo migration bằng **max** và bằng **cửa sổ khoá**, không bao giờ bằng p99.

**c) Cách đúng CHẬM HƠN: 26,9 s vs 19,1 s (1,4×), và bloat/WAL gần như y hệt** (546 MB, ~1,2 GB WAL cả hai).

Đây là kết quả trung thực và cần nói rõ: **expand/contract không tiết kiệm tài nguyên, nó chỉ đổi tài nguyên lấy tính khả dụng.** Bạn trả thêm 40% thời gian và không giảm được byte WAL nào, để đổi lấy việc không có request nào chờ quá 30 ms.

Và bloat vẫn phải xử lý sau (Day 41: `VACUUM` dọn dead tuple nhưng không trả đĩa — cần `pg_repack`).

---

## §3. Backfill theo lô — cái giá và cái mua được

Ba cách trên cùng 1.000.000 dòng (bảng 49 MB):

| Cách | Thời gian | So với (a) | Kích thước sau | Dead tuple |
|---|---|---|---|---|
| **(a)** một `UPDATE` | **1.377 ms** | 1× | 105 MB | 1.000.000 |
| **(b)** lô 20.000, không nghỉ | **4.583 ms** | **3,33×** | 105 MB | 999.346 |
| **(c)** lô 20.000, nghỉ 50 ms | **6.636 ms** | **4,82×** | 105 MB | 999.111 |

**Chia lô đắt hơn 3,3×; thêm nghỉ đắt hơn 4,8×. Và kích thước cuối giống hệt nhau.**

Chi phí đến từ đâu: mỗi lô phải chạy lại `SELECT ctid FROM bf2 WHERE owner_id IS NULL LIMIT 20000` — với 50 lô, đó là 50 lần quét tìm dòng chưa xử lý. Cộng thêm 50 lần commit (50 fsync — Day 37).

### Vậy mua được gì bằng 3,3–4,8× thời gian?

| Vấn đề của một `UPDATE` lớn | Học ở | Backfill theo lô giải quyết? |
|---|---|---|
| Bảng phình gần gấp đôi | Day 21–22 | **Không** — đo được: cả ba đều 105 MB |
| Transaction dài ghim `xmin horizon` ⇒ chặn `VACUUM` **toàn database** | Day 40 §5 | **CÓ** — mỗi lô là một transaction ~100 ms |
| Sinh WAL bằng cả bảng trong thời gian ngắn ⇒ replica lag vọt | Day 37–38 | **CÓ** — cùng lượng WAL nhưng trải đều, replica đuổi kịp |
| Giữ row lock trên 3 triệu dòng ⇒ mọi `UPDATE` của app trên đó phải chờ | Day 28 | **CÓ** — mỗi lô chỉ giữ lock 20.000 dòng trong ~100 ms |
| Fail ở phút 40 ⇒ rollback toàn bộ, làm lại từ đầu | — | **CÓ** — dừng và chạy tiếp được |
| Autovacuum không có cơ hội chen vào | Day 23 | **CÓ (với `pg_sleep`)** — đó là thứ (c) mua thêm so với (b) |

**Bốn trong sáu vấn đề được giải quyết, và ba trong số đó là vấn đề ảnh hưởng ra ngoài bảng đang migrate** (chặn vacuum toàn database, replica lag, và khả năng dừng giữa chừng). Đó là lý do đáng trả 3,3×.

`pg_sleep` giữa các lô (cách c) mua thêm đúng một thứ: **nhịp cho autovacuum**. Ở lab autovacuum chưa kịp chạy (`last_autovacuum` = null cho cả ba), nhưng trên bảng production đang có traffic, khoảng nghỉ đó là thứ giữ bảng không phình vô hạn trong lúc backfill kéo dài hàng giờ.

### Ba chi tiết dễ sai

**1. Chọn lô bằng khoá, không bằng `OFFSET`.**
```sql
-- SAI: mỗi lô quét lại từ đầu, O(n²)
UPDATE t SET c = ... WHERE id IN (SELECT id FROM t ORDER BY id OFFSET 2000000 LIMIT 20000);
-- ĐÚNG: điều kiện tự thu hẹp sau mỗi lô
UPDATE t SET c = ... WHERE ctid IN (SELECT ctid FROM t WHERE c IS NULL LIMIT 20000);
-- TỐT NHẤT cho bảng lớn: đi theo PK, có index hỗ trợ
UPDATE t SET c = ... WHERE id > :last_id AND id <= :last_id + 20000;
```
Cách `WHERE c IS NULL LIMIT n` vẫn phải quét tìm — với bảng rất lớn nên tạo **partial index** tạm: `CREATE INDEX CONCURRENTLY ON t(id) WHERE c IS NULL;` rồi drop sau.

**2. Idempotent.** Điều kiện lô phải là `WHERE c IS NULL` (hoặc tương đương) để chạy lại được sau khi dừng. Script backfill **sẽ** bị dừng — do deploy, do OOM, do ai đó Ctrl-C.

**3. Có thể quan sát tiến độ:**
```sql
SELECT count(*) FILTER (WHERE owner_id IS NULL) AS con_lai,
       count(*) AS tong,
       round(100.0*count(*) FILTER (WHERE owner_id IS NOT NULL)/count(*),1) AS pct_xong
FROM mig2;
```

---

## §4. Đổi kiểu cột mà không rewrite

Day 43 đo: `smallint → bigint` trên 2M dòng = **3.290 ms `ACCESS EXCLUSIVE` + 298 MB WAL + rewrite**. Trên bảng 500 GB thì không có cửa.

Mẫu expand/contract:

| Bước | Lệnh | Thời gian | Lock |
|---|---|---|---|
| 1 | `ADD COLUMN key_id_new bigint` | 5,10 ms | `ACCESS EXCL` (5 ms) |
| 2 | `CREATE TRIGGER trg_sync BEFORE INSERT OR UPDATE` | 4,65 ms | `ACCESS EXCL` |
| 3 | backfill theo lô | **32.971 ms** | `ROW EXCL` |
| 4 | index/constraint bằng `CONCURRENTLY` | — | `SHARE UPDATE EXCL` |
| 5 | **transaction đổi tên hai cột** | **10,86 ms** | `ACCESS EXCL` (11 ms) |
| 6 | sau vài ngày: `DROP COLUMN key_id_old`, `DROP TRIGGER` | ms | `ACCESS EXCL` |

**Cửa sổ khoá: 10,86 ms thay vì 3.290 ms — 303×.** Và trên bảng 500 GB, cửa sổ đó **vẫn là ~11 ms** (rename là thao tác catalog, không phụ thuộc kích thước bảng), trong khi `ALTER COLUMN TYPE` sẽ là hàng giờ.

```sql
BEGIN;
  SET LOCAL lock_timeout = '3s';
  ALTER TABLE mig2 RENAME COLUMN key_id     TO key_id_old;
  ALTER TABLE mig2 RENAME COLUMN key_id_new TO key_id;
COMMIT;
```

### Chi phí của trigger

INSERT 100.000 dòng, đo 2 lần mỗi bên:

| | Lần 1 | Lần 2 |
|---|---|---|
| Không trigger | **89,98 ms** | **94,41 ms** |
| Có trigger `BEFORE INSERT` | **196,16 ms** | **180,44 ms** |
| **Chênh** | | **~2,0×** |

**Trigger làm INSERT chậm gấp đôi.** Đó là cái giá phải trả suốt pha 2–3 (có thể vài ngày). Với bảng ingest cao, cần cân nhắc:
- Chấp nhận 2× trong vài ngày, hoặc
- Bỏ trigger và để **code ứng dụng ghi cả hai cột** (dual write) — nhanh hơn nhưng phải sửa mọi chỗ ghi, và nếu sót một chỗ thì dữ liệu lệch âm thầm.

Trigger an toàn hơn (bắt được cả ghi từ script/psql thủ công), code nhanh hơn. Với bảng ít đường ghi thì dùng code; bảng nhiều đường ghi hoặc có legacy thì dùng trigger.

### 🔧 Bẫy tôi vấp thật: trigger + rename = cached plan lỗi

Sau khi đổi tên hai cột, INSERT tiếp theo qua trigger cho:

```
ERROR: type of parameter 15 (bigint) does not match that when preparing the plan (smallint)
CONTEXT: PL/pgSQL function sync_key_id() line 2 at assignment
```

**Hàm PL/pgSQL cache plan theo kiểu cột tại thời điểm compile.** Đổi tên cột làm `NEW.key_id` giờ trỏ tới cột `bigint` thay vì `smallint`, nhưng plan cũ vẫn nhớ `smallint`.

Ba cách xử lý, theo thứ tự an toàn:
1. **`DROP TRIGGER` TRƯỚC khi rename**, rồi tạo lại sau (nếu vẫn cần). Đơn giản nhất và đúng nhất — ở pha 5 thì trigger đã hết tác dụng vì hai cột đã đồng bộ.
2. `DISCARD PLANS` trên mọi connection — không làm được với pool.
3. Ép reconnect toàn bộ pool sau migration — thô nhưng chắc.

**Bài học tổng quát: sau mọi DDL đổi kiểu/tên, plan cache của hàm PL/pgSQL và của prepared statement (Day 42) đều có thể lỗi thời.** Postgres invalidate plan khi schema đổi trong phần lớn trường hợp, nhưng PL/pgSQL với biến `NEW.x` là chỗ nó không bắt được. Thêm vào runbook: **rename cột ⇒ kiểm tra trigger và function liên quan.**

### Dòng thời gian deploy (câu hỏi thiết kế của §4)

```
  pha 1-3         pha 5 (rename)              pha 6
────┬────────────────┬──────────────────────────┬────────►
    │                │                          │
code cũ: đọc key_id  │ code cũ: đọc key_id      │ code cũ: LỖI (không còn key_id_old)
  → cột smallint     │  → giờ là cột bigint ✅   │
                     │                          │
code mới: đọc key_id │ code mới: đọc key_id ✅   │ code mới: OK
```

**Giữa bước 5 và 6, code cũ VẪN CHẠY ĐƯỢC** — vì nó đọc tên `key_id`, và tên đó giờ trỏ tới cột mới có cùng giá trị. Đây là điểm đẹp của mẫu này: **rename giữ nguyên tên mà app dùng**, chỉ đổi cột bên dưới.

Code đọc `key_id_old` thì chỉ chạy được giữa bước 5 và 6 — nhưng không có code nào nên đọc nó; nó chỉ tồn tại để rollback.

**Rollback ở bước 5:** đổi tên ngược lại, cũng 11 ms. Đó là lý do phải giữ `key_id_old` ít nhất vài ngày.

---

## §5. Ràng buộc an toàn: FK và UNIQUE

### Foreign key

| Bước | Thời gian | Lock |
|---|---|---|
| `ADD CONSTRAINT fk FOREIGN KEY (...) REFERENCES ... NOT VALID` | **3,11 ms** | `ACCESS EXCL` (3 ms) |
| `VALIDATE CONSTRAINT fk` | **481,58 ms** | **`SHARE UPDATE EXCL`** |

**Cửa sổ khoá 3,11 ms thay vì ~485 ms — 156×.**

### `NOT VALID` KHÔNG phải "constraint tắt" — đây là điểm nhiều người hiểu nhầm

```sql
ALTER TABLE mig2 ADD CONSTRAINT fk_owner FOREIGN KEY (owner_id) REFERENCES owner(id) NOT VALID;
INSERT INTO mig2(device_id, key_id, ts, owner_id) VALUES (1,1,now(), 999999);
```
```
ERROR:  insert or update on table "mig2" violates foreign key constraint "fk_owner"
DETAIL:  Key (owner_id)=(999999) is not present in table "owner".
```

**Bị chặn ngay lập tức.** Và dữ liệu hợp lệ thì vào bình thường (`INSERT 0 1`).

`NOT VALID` chỉ có nghĩa: **"chưa kiểm tra dữ liệu CŨ"**. Với dữ liệu mới, ràng buộc có hiệu lực đầy đủ ngay từ giây đầu tiên. Nghĩa là bạn có thể để nó ở trạng thái `NOT VALID` **vô thời hạn** nếu dữ liệu cũ không sạch và bạn chưa muốn sửa — vẫn được bảo vệ hoàn toàn cho dữ liệu đi vào từ nay.

Hai giới hạn của `NOT VALID`: (1) planner **không** dùng constraint chưa validate để tối ưu (ví dụ constraint exclusion); (2) `pg_constraint.convalidated = false` — nên đưa vào dashboard để không quên:
```sql
SELECT conrelid::regclass, conname, contype FROM pg_constraint WHERE NOT convalidated;
```

### UNIQUE

| Cách | Thời gian | Cửa sổ `ACCESS EXCLUSIVE` |
|---|---|---|
| `CREATE UNIQUE INDEX CONCURRENTLY` + `ADD CONSTRAINT ... USING INDEX` | 197,85 + **3,13 ms** | **3,13 ms** |
| `ADD CONSTRAINT ... UNIQUE (...)` thường | **785,16 ms** | **785,16 ms** |
| **Chênh cửa sổ khoá** | | **251×** |

```sql
CREATE UNIQUE INDEX CONCURRENTLY ix_uq ON uq(device_id, ts);     -- SHARE UPDATE EXCL, 197,85 ms
ALTER TABLE uq ADD CONSTRAINT uq_dev_ts UNIQUE USING INDEX ix_uq; -- ACCESS EXCL, 3,13 ms
-- pg_constraint: uq_dev_ts | u
```

`USING INDEX` "nhận nuôi" index đã có sẵn thay vì build lại — nên bước cuối chỉ là thao tác catalog. Lưu ý: index bị **đổi tên** thành tên constraint sau khi attach.

### Bảng tổng hợp

| Muốn | Cách sai | Cách đúng | Cửa sổ khoá |
|---|---|---|---|
| Thêm FK | `ADD FOREIGN KEY` (quét **cả hai** bảng) | `NOT VALID` → `VALIDATE` | 485 ms → **3,1 ms** |
| Thêm UNIQUE | `ADD CONSTRAINT ... UNIQUE` | `CREATE UNIQUE INDEX CONCURRENTLY` → `ADD CONSTRAINT ... USING INDEX` | 785 ms → **3,1 ms** |
| Thêm PK | `ADD PRIMARY KEY` | như UNIQUE + `SET NOT NULL` theo mẫu §2 | |
| Thêm CHECK | `ADD CHECK` | `NOT VALID` → `VALIDATE` | 275 ms → **3,1 ms** (Day 43) |
| Thêm NOT NULL | `SET NOT NULL` | `CHECK ... NOT VALID` → `VALIDATE` → `SET NOT NULL` | 1.155 ms → **5,2 ms** |

**Một mẫu duy nhất lặp lại năm lần: tách việc QUÉT DỮ LIỆU ra khỏi lock nặng.**

---

## §6. Những thay đổi **không** thể làm an toàn trong một bước

| Thay đổi | Vì sao nguy hiểm với rolling deploy | Cách thay thế |
|---|---|---|
| `RENAME COLUMN` | pod cũ dùng tên cũ → lỗi ngay | expand/contract (§4), hoặc view tương thích |
| `DROP COLUMN` | pod cũ `SELECT *` hoặc INSERT thiếu cột | bỏ khỏi code trước, chờ **1 deploy đầy đủ**, rồi mới drop |
| Thu hẹp kiểu (`text → varchar(20)`) | dữ liệu dài hơn fail | `CHECK (length(x) <= 20) NOT VALID` → sửa dữ liệu → `VALIDATE` → đổi kiểu |
| Thêm `NOT NULL` cho cột code cũ chưa ghi | pod cũ INSERT thiếu → lỗi | thêm `DEFAULT` trước, đợi code mới, rồi `NOT NULL` |
| **Đổi ngữ nghĩa cột** (đơn vị, timezone, enum) | **không phát hiện được bằng lỗi — hỏng dữ liệu âm thầm** | **cột mới, KHÔNG tái sử dụng cột cũ** |

Dòng cuối là dòng đắt nhất. Lỗi schema thì fail nhanh và thấy ngay trong log; lỗi ngữ nghĩa thì phát hiện sau 3 tháng, lúc dữ liệu đã lẫn lộn giữa "giây" và "mili giây", hoặc giữa UTC và giờ địa phương — và **không có cách nào tách chúng ra nữa**.

### View tương thích — lối thoát khi buộc phải đổi tên

```sql
ALTER TABLE mig2 RENAME TO mig2_real;
CREATE VIEW mig2 AS SELECT device_id, key_id, ts, dbl_v, str_v, owner_id FROM mig2_real;
```

Đo:

| Thao tác qua view | Kết quả |
|---|---|
| `SELECT count(*) FROM mig2 WHERE device_id=1` | **OK** — 12,21 ms |
| `INSERT INTO mig2(...) VALUES (...)` | **OK** — `INSERT 0 1` |
| `UPDATE mig2 SET dbl_v = 1 WHERE ...` | **OK** — `UPDATE 7863` |
| `information_schema.tables.is_insertable_into` | **`YES`** |

**View đơn giản trên một bảng là auto-updatable** — đọc, ghi, sửa đều trong suốt với app. Đây là công cụ rất mạnh: bạn đổi cấu trúc bảng thật mà app không biết gì.

Nhưng có ranh giới rõ ràng:

```sql
CREATE VIEW mig2_join AS SELECT m.device_id, m.ts, o.id AS owner
FROM mig2_real m JOIN owner o ON o.id = m.owner_id;
INSERT INTO mig2_join(device_id, ts, owner) VALUES (3, now(), 1);
```
```
ERROR:  cannot insert into view "mig2_join"
DETAIL:  Views that do not select from a single table or view are not automatically updatable.
HINT:  To enable inserting into the view, provide an INSTEAD OF INSERT trigger
       or an unconditional ON INSERT DO INSTEAD rule.
```

**Điều kiện để view auto-updatable:**
- Chỉ **một** bảng/view trong `FROM` — không `JOIN`, không subquery ở `FROM`.
- Không `DISTINCT`, `GROUP BY`, `HAVING`, `LIMIT`, `OFFSET`, `UNION`.
- Không hàm cửa sổ, không aggregate.
- Mọi cột trong danh sách select phải là **tham chiếu cột đơn giản** (biểu thức thì cột đó chỉ đọc được).

**Khi nào cần `INSTEAD OF` trigger:** view có JOIN, hoặc cần map biểu thức (ví dụ view cũ có `celsius` còn bảng mới lưu `kelvin` — phải chuyển đổi hai chiều), hoặc cần ghi vào nhiều bảng.

Cái giá của view tương thích: thêm một lớp gián tiếp mà 6 tháng sau không ai nhớ tại sao có. **Luôn đặt hạn xoá và ghi vào comment:**
```sql
COMMENT ON VIEW mig2 IS 'View tương thích cho migration #1234. XOÁ SAU 2026-10-01.';
```

---

## Bảng số liệu chính

| Phép đo | Kết quả |
|---|---|
| Bảng thử | `mig2`, 3.000.000 dòng, 262 MB |
| **Probe baseline** | 729 mẫu, max **1,78 ms**, p99 1,45 ms, avg 0,470 ms |
| **§2 CÁCH ĐÚNG — tổng** | **~26,9 s**, cửa sổ khoá dài nhất **6,49 ms** |
| — B1 `ADD COLUMN` nullable | 3,36 ms |
| — B2 backfill lô 50k, nghỉ 20 ms | 26.620 ms |
| — B3 `CHECK ... NOT VALID` | **6,49 ms** |
| — B4 `VALIDATE CONSTRAINT` | 286,0 ms, **`SHARE UPDATE EXCL`** |
| — B5 `SET NOT NULL` | **5,25 ms** (đã có CHECK ⇒ bỏ qua quét) |
| — **probe** | max **28,57 ms**, p99 1,90 ms |
| **§2 CÁCH SAI — tổng** | **~19,1 s** (nhanh hơn 1,4×) |
| — `UPDATE` 3M dòng | 17.921 ms |
| — `SET NOT NULL` | **1.155,25 ms `ACCESS EXCLUSIVE`** |
| — **probe** | **max 1.195,50 ms**, p99 **1,67 ms**, 1 mẫu > 100 ms |
| **Chênh max probe** | **41,8×** |
| Bloat / WAL (cả hai cách) | 262 → **546 MB**, ~3.000.000 dead tuple, ~**1,2 GB WAL** |
| **§3 backfill 1M dòng** | (a) một phát **1.377 ms** · (b) lô **4.583 ms (3,33×)** · (c) lô+nghỉ **6.636 ms (4,82×)** |
| — kích thước sau | **105 MB cả ba** — chia lô **không** giảm bloat |
| **§4 transaction đổi tên cột** | **10,86 ms** (so với `ALTER COLUMN TYPE` 3.290 ms ở Day 43 — **303×**) |
| — chi phí trigger lên INSERT 100k | 89,98/94,41 ms → **196,16/180,44 ms ≈ 2,0×** |
| — **bug gặp thật** | sau rename: `ERROR: type of parameter 15 (bigint) does not match that when preparing the plan (smallint)` |
| **§5 FK `NOT VALID`** | **3,11 ms**; `VALIDATE` 481,58 ms (`SHARE UPDATE EXCL`) |
| — `NOT VALID` **vẫn chặn** dữ liệu mới sai | `ERROR: violates foreign key constraint "fk_owner"` ✅ |
| **§5 UNIQUE qua `CONCURRENTLY`** | 197,85 ms + **3,13 ms** khoá |
| **§5 UNIQUE thường** | **785,16 ms** khoá — **251×** |
| **§6 view 1 bảng** | auto-updatable: SELECT/INSERT/UPDATE đều OK, `is_insertable_into = YES` |
| **§6 view có JOIN** | **`ERROR: cannot insert into view ... not automatically updatable`** |

---

## Ba điều dễ hiểu sai

| Hiểu nhầm | Sự thật đo được |
|---|---|
| "Migration an toàn thì nhanh hơn và nhẹ hơn." | **Ngược lại: chậm hơn 1,4×** (26,9 s vs 19,1 s), **bloat y hệt** (546 MB cả hai), **WAL y hệt** (~1,2 GB). Expand/contract **không tiết kiệm tài nguyên** — nó đổi tài nguyên lấy tính khả dụng. Cái duy nhất nó mua: cửa sổ khoá **6,49 ms thay vì 1.155 ms**, và max latency **28,6 ms thay vì 1.195,5 ms**. |
| "Đo migration bằng p99 là đủ." | p99 của **cách sai** là **1,67 ms** — còn *thấp hơn* cách đúng (1,90 ms). Vì chỉ **1 trong 1.669 mẫu** bị chặn = 0,06%, nằm ngoài p99. Nhưng mẫu đó chờ **1,2 giây**. Ở 5.000 qps, cửa sổ 1.155 ms = **~5.775 request** vượt `connectionTimeout` ⇒ pool cạn ⇒ lỗi lan sang mọi endpoint. **Đo bằng max và bằng cửa sổ khoá.** |
| "`NOT VALID` nghĩa là constraint chưa có hiệu lực." | **Sai hoàn toàn.** Đo được: `FOREIGN KEY ... NOT VALID` **chặn ngay** dữ liệu mới sai (`ERROR: violates foreign key constraint`). Nó chỉ có nghĩa "chưa kiểm tra dữ liệu **CŨ**". Nghĩa là bạn có thể để `NOT VALID` **vô thời hạn** khi dữ liệu cũ chưa sạch — vẫn được bảo vệ đầy đủ từ nay. Giới hạn duy nhất: planner không dùng nó để tối ưu. |

---

## Áp dụng vào hệ thật

1. **Dán "5 bước thêm cột NOT NULL" và "3 bước thêm constraint" vào PR template.** Đây là hai mẫu chiếm phần lớn migration thực tế:
   ```sql
   -- Thêm cột NOT NULL
   ALTER TABLE t ADD COLUMN c bigint;                                    -- ~3 ms
   -- backfill theo lô (script riêng, chạy nền, idempotent)
   ALTER TABLE t ADD CONSTRAINT ck_c CHECK (c IS NOT NULL) NOT VALID;    -- ~6 ms
   ALTER TABLE t VALIDATE CONSTRAINT ck_c;                               -- lâu, không chặn ai
   ALTER TABLE t ALTER COLUMN c SET NOT NULL;                            -- ~5 ms
   ALTER TABLE t DROP CONSTRAINT ck_c;
   ```

2. **Viết một script backfill dùng chung** cho cả team, với: chọn lô theo PK, `WHERE col IS NULL` để idempotent, `COMMIT` mỗi lô, `pg_sleep` giữa lô, và log tiến độ. Đây là thứ mọi migration lớn đều cần và mọi người đều viết lại từ đầu.

3. **Đo migration bằng max latency, không bằng p99.** Thêm vào runbook: chạy một probe query rẻ (~1 ms) mỗi 10 ms trong suốt migration, và báo cáo `max(ms)` cùng số mẫu > 100 ms. Nếu max > 100 ms thì có một bước cần tách nhỏ hơn.

4. **Với `ALTER COLUMN TYPE` trên bảng > 10 GB: dùng expand/contract (§4).** Cửa sổ khoá 11 ms thay vì hàng giờ, và **11 ms đó không phụ thuộc kích thước bảng**. Nhớ `DROP TRIGGER` **trước** khi rename để tránh lỗi cached plan.

5. **Chuyển mọi `ADD CONSTRAINT UNIQUE` sang `CREATE UNIQUE INDEX CONCURRENTLY` + `USING INDEX`** — 251× cửa sổ khoá, và index có sẵn để rollback.

6. **Đưa constraint chưa validate vào dashboard:**
   ```sql
   SELECT conrelid::regclass, conname, contype FROM pg_constraint WHERE NOT convalidated;
   ```
   `NOT VALID` là trạng thái hợp lệ để ở lâu, nhưng phải là **quyết định**, không phải quên.

7. **Với thay đổi đổi ngữ nghĩa (đơn vị, timezone, enum): luôn tạo cột MỚI, không tái sử dụng cột cũ.** Đây là loại lỗi duy nhất không có cách sửa sau khi dữ liệu đã lẫn.

8. **View tương thích luôn kèm `COMMENT` có hạn xoá.** Không có nó, 6 tháng sau không ai dám xoá và bạn có một lớp gián tiếp vĩnh viễn.

---

## Câu hỏi mở sang các ngày sau

- **Day 45 (migration rehearsal)** là ngày cuối tuần 9 và trả lời câu hỏi còn thiếu: làm sao **biết trước** một migration mất bao lâu và ảnh hưởng thế nào, mà không phải thử trên production. Số liệu hôm nay (26,9 s cho 3M dòng) là thứ ngoại suy được — nhưng ngoại suy có đúng không?
- **Day 41 (TOAST)** cảnh báo bổ sung cho §3: backfill trên bảng có cột TOAST tốn **44,6× WAL** (Day 41 §6) vì mỗi lần đụng cột TOAST là ghi lại toàn bộ chuỗi chunk. Lô phải nhỏ hơn nhiều, và phải theo dõi replica lag sát hơn.
- **Day 34 §7** nối với §3: `UPDATE` toàn bảng làm **GIN index phình 9–11×**. Sau backfill trên bảng có GIN, **bắt buộc `REINDEX CONCURRENTLY`**.
- **Day 38 §3** cho một góc nhìn khác về §1: giữa pha 2 và 3, nếu read model đọc từ replica thì việc "chờ pha trước an toàn" còn phải cộng thêm replication lag — query đối chiếu phải chạy trên **replica**, không phải primary.
- **Câu hỏi mở thật sự:** §3 cho thấy chia lô đắt hơn 3,3× nhưng bloat y hệt. Có cách backfill nào **không** tạo dead tuple không? Có: viết vào một bảng mới rồi swap (như §4 nhưng ở mức bảng), hoặc dùng `pg_repack` sau. Ranh giới nào để chọn "backfill tại chỗ + repack" thay vì "tạo bảng mới + swap"?

---

### Dọn dẹp

```sql
DROP TABLE IF EXISTS mig2, mig2_bad, bf1, bf2, bf3, uq, uq2, owner, probe,
                     trg_test_on, trg_test_off CASCADE;
DROP PROCEDURE IF EXISTS run_probe(int), run_probe2(int);
DROP FUNCTION IF EXISTS sync_key_id(), sync_ab();
VACUUM;
```
