# Day 45 — Lời giải: Chẩn đoán mù + diễn tập migration (ôn tuần 9)

> Bài chữa. Năm ca chẩn đoán mù, mỗi ca viết chẩn đoán **trước** rồi mới kiểm chứng. Cộng một bài diễn tập migration thật trên `ts_kv` (5.000.000 dòng) với probe đo latency song song.
>
> Kết quả diễn tập: **thêm cột `NOT NULL` + partial index trên bảng 5 triệu dòng, tổng 1,3 giây, cửa sổ khoá dài nhất 4,58 ms, và p99 của probe TRONG lúc migration (2,01 ms) còn THẤP HƠN baseline (2,40 ms).** Đạt cả 4 yêu cầu.
>
> Sản phẩm kèm theo: [`migration.sql`](migration.sql) và [`migration-playbook.md`](migration-playbook.md).

---

## Bảng điểm chẩn đoán

| Ca | Chẩn đoán của tôi | Đúng/Sai | Chỗ nghĩ nhầm |
|---|---|---|---|
| 1 | Transaction dài giữ `ACCESS SHARE`, `ALTER` xếp hàng, mọi query sau đó kẹt theo | ✅ | — |
| 2 | TOAST — `pg_relation_size` không tính TOAST | ✅ | Nhưng đánh giá thấp mức chênh: tôi đoán ~10×, thật là **82×** |
| 3 | Replication slot của Debezium không consume kịp | ✅ | — |
| 4 | Transaction cũ chặn `CONCURRENTLY` | ⚠️ **nửa đúng** | Tôi nghĩ **mọi** transaction cũ đều chặn. Thật ra `READ COMMITTED` idle **không** chặn; chỉ `REPEATABLE READ`+ mới chặn. |
| 5 | pgbouncer transaction mode, prepared statement mất khi đổi server connection | ✅ | — |

**4,5/5.** Ca sai là ca 4, và lý do nghĩ nhầm giống hệt lỗi ở Day 40 §5: tôi gộp "transaction đang mở" với "transaction đang giữ snapshot" làm một. Chúng khác nhau, và mức cô lập là thứ quyết định.

---

## Ca 1 — "Migration chỉ thêm một cột, mà API 500 suốt 8 phút"

### Chẩn đoán (viết trước)

> Câu `ALTER TABLE` không phải thủ phạm — nó chỉ mất vài mili giây khi chạy được. Thủ phạm là **một transaction đang mở giữ `ACCESS SHARE`** trên `device` (nhiều khả năng một job báo cáo, hoặc một session `idle in transaction` do `@Transactional` bọc lời gọi HTTP).
>
> `ALTER TABLE` cần `ACCESS EXCLUSIVE`, phải xếp hàng. Và vì hàng đợi lock là FIFO, **mọi query đến sau nó cũng kẹt** — kể cả `SELECT` vốn hoàn toàn tương thích với transaction đang chạy. Nên không phải một query chậm mà là **mọi** query trên bảng đó đứng im ⇒ pool cạn ⇒ 500 ở mọi endpoint.
>
> "Tự khỏi sau 8 phút" = job kia chạy xong và commit.

### Kiểm chứng (số liệu Day 43 §2)

```
 pid  |        state        | wait_event_type | wait_event | bi_chan_boi |  q
------+---------------------+-----------------+------------+-------------+--------------------------
 3654 | idle in transaction | Client          | ClientRead | {}          | SELECT count(*) FROM ...
 3656 | active              | Lock            | relation   | {3654}      | ALTER TABLE ... ADD COLUMN
 3655 | active              | Lock            | relation   | {3656}      | SELECT count(*) FROM ...
```

| | Chờ |
|---|---|
| `ALTER TABLE` | **8.091,7 ms** (chạy thật chỉ ~11 ms) |
| `SELECT` vô can | **5.099,7 ms** — bị chặn bởi **`ALTER TABLE`**, không phải bởi transaction gốc |

Log Postgres:
```
process 3656 still waiting for AccessExclusiveLock on relation 240001 after 1000.196 ms
process 3655 still waiting for AccessShareLock  on relation 240001 after 1000.134 ms
```

### Sửa hai chỗ

**a) Ở migration** — `lock_timeout` + retry (Day 43 §4). Đo được: `lock_timeout = '2s'` huỷ sau đúng **2.000,7 ms** với `ERROR: 55P03 canceling statement due to lock timeout`, và **rời khỏi hàng đợi** ⇒ traffic được giải phóng ngay.

```sql
SET lock_timeout = '3s';
ALTER TABLE device ADD COLUMN label text;
```

**b) Ở phía job chạy dài** — đây mới là nguyên nhân gốc:
```sql
ALTER ROLE app SET idle_in_transaction_session_timeout = '60s';
ALTER ROLE bao_cao SET statement_timeout = '10min';
```
Và trong code: **không bao giờ mở transaction DB rồi gọi HTTP/Temporal ở giữa** — chữ ký `idle in transaction` + `Client/ClientRead` gần như luôn là cái này (Day 40 §4).

> **Vì sao staging không phát hiện được:** staging không có job báo cáo chạy 8 phút. Migration nguy hiểm hay không **không phụ thuộc vào bản thân câu lệnh**, mà vào cái gì đang chạy cùng lúc.

---

## Ca 2 — "Bảng 200MB nhưng backup 12GB, `SELECT *` chậm gấp 40 lần"

### Chẩn đoán (viết trước)

> Cột `config jsonb` đã bị **TOAST**. Dashboard dùng `pg_relation_size` — hàm này **không tính phần TOAST**. Backup thì tính, nên chênh lệch khổng lồ.
>
> `SELECT id, name` không đụng TOAST (Day 41); `SELECT *` phải de-TOAST cả document cho mỗi dòng.

### Kiểm chứng

Dựng `device_profile` (50.000 dòng, mỗi dòng một jsonb ~7,8 kB):

| Chỉ số | Giá trị |
|---|---|
| **`pg_relation_size` (cái dashboard hiển thị)** | **3.744 kB** |
| **`pg_total_relation_size` (thật)** | **300 MB** |
| TOAST | **293 MB = 97,7%** |
| **Tỉ lệ giấu đi** | **82×** |

| Query | Buffers | Time |
|---|---|---|
| `SELECT id, name FROM device_profile` | **468** | **5,44 ms** |
| `SELECT count(*) WHERE config->>'k' IS NULL` | **225.469** | **828,6 ms** |
| **Chênh** | **482×** | **152×** |

Và đo trực tiếp chi phí de-TOAST khi trả dữ liệu:
```
sum(length(config::text))  →  3.204 ms
sum(id)                    →      3,05 ms      ← 1.050×
```

**Chẩn đoán đúng nhưng tôi đánh giá thấp mức độ: đoán ~10×, thật là 82× ở dung lượng và 1.050× ở thời gian.**

### Sửa ở tầng nào — hai cách

**Cách A: sửa SQL/ORM — cấm `SELECT *`.**
- Ưu: một dòng code, hiệu quả ngay (5,44 ms vs 828,6 ms cho endpoint list).
- Nhược: phải rà mọi chỗ; ORM có thể tự sinh lại; endpoint *chi tiết* vẫn cần `config` nên vẫn chậm.

**Cách B: sửa schema — tách field hay dùng thành cột thật.**
```sql
ALTER TABLE device_profile ADD COLUMN model text;   -- expand/contract (Day 44)
```
- Ưu: giải quyết cả lọc lẫn trả về. Day 41 §5 đo: **124 ms → 0,94 ms (132×)**, và expression index **không** cứu được phần trả về.
- Nhược: cần migration nhiều bước, cần dual-write một thời gian.

**Chọn A trước, B sau.** A mất 30 phút và giải quyết ngay endpoint list (chiếm phần lớn traffic). B mất một sprint và giải quyết triệt để. Nhưng **phải làm A ngay** — vì nó chặn được sự cố đang xảy ra.

Kèm việc thứ ba, làm ngay lập tức và miễn phí: **sửa dashboard** dùng `pg_total_relation_size`. Không có nó, sáu tháng nữa lại có người kết luận sai về bảng khác.

---

## Ca 3 — "Đĩa primary đầy dần từ hôm bật CDC"

### Chẩn đoán (viết trước)

> Debezium tạo một logical replication slot. Slot giữ WAL từ `restart_lsn` cho tới khi consumer xác nhận đã đọc. Nếu Debezium chết, bị scale về 0, hoặc chậm hơn tốc độ sinh WAL, slot giữ WAL **vô hạn**.
>
> `max_wal_size = 4GB` **không** cứu — nó chỉ điều khiển nhịp checkpoint, không cho phép xoá WAL mà slot còn cần. Đó là lý do "checkpoint chạy bình thường" mà đĩa vẫn đầy.

### Kiểm chứng

| Giai đoạn | `pg_wal` | Slot giữ | `wal_status` |
|---|---|---|---|
| Trước | 64 seg / **1.024 MB** | — | — |
| Tạo slot + ghi 600k dòng + 2 `CHECKPOINT` | 64 seg / 1.024 MB | **152 MB** | `reserved`, `safe_wal_size` = **không giới hạn** |
| Sau `pg_drop_replication_slot` + 2 `CHECKPOINT` | 56 seg / **896 MB** | — | — |

(Day 39 §4 có bản mạnh hơn: slot giữ **1.278 MB**, `pg_wal` 1.024 → **1.296 MB**, vượt thẳng `max_wal_size`.)

Điểm mấu chốt: **`safe_wal_size` = "không giới hạn"** vì `max_slot_wal_keep_size = -1` (mặc định). Đó là lý do nó tăng mãi.

### Vì sao tăng đĩa KHÔNG phải cách sửa

Vì slot giữ WAL **vô hạn theo thiết kế**. Tăng đĩa từ 500 GB lên 1 TB chỉ đổi ngày sập từ thứ Ba sang thứ Sáu. Đây là **rò rỉ**, không phải thiếu dung lượng.

### Ba hành động trong 15 phút đầu

**1. Xác định slot và mức độ (30 giây):**
```sql
SELECT slot_name, plugin, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS giu,
       coalesce(pg_size_pretty(safe_wal_size),'khong gioi han') AS con_lai
FROM pg_replication_slots ORDER BY 5 DESC;
```

**2. Slot `active = false` ⇒ khởi động lại consumer.** Nếu Debezium đã bị gỡ hẳn:
```sql
SELECT pg_drop_replication_slot('ten_slot');
CHECKPOINT; CHECKPOINT;    -- cần HAI lần mới thấy WAL giảm
```
Chấp nhận: CDC phải re-snapshot khi bật lại.

**3. Slot `active = true` nhưng tụt lại ⇒ consumer chậm hơn tốc độ sinh WAL.** Đặt van an toàn ngay để mua thời gian:
```sql
ALTER SYSTEM SET max_slot_wal_keep_size = '50GB';
SELECT pg_reload_conf();
```
Postgres sẽ **hy sinh slot** (`wal_status = 'lost'`) thay vì để đĩa đầy. **Mất CDC còn hơn mất database.**

### Ngưỡng cảnh báo để không bao giờ tới mức này

```sql
-- page: slot không active và giữ > 5 GB
SELECT slot_name FROM pg_replication_slots
WHERE NOT active AND pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) > 5e9;

-- page: wal_status khác 'reserved'
SELECT slot_name, wal_status FROM pg_replication_slots WHERE wal_status <> 'reserved';

-- warning: pg_wal > 3× max_wal_size
SELECT round(100.0*sum(size)/pg_size_bytes(current_setting('max_wal_size')),1) AS pct
FROM pg_ls_waldir();
```

Cộng với `max_slot_wal_keep_size` đặt sẵn — **đó là thứ biến sự cố này thành một cảnh báo thay vì một cuộc gọi lúc 3 giờ sáng.**

---

## Ca 4 — "`CREATE INDEX CONCURRENTLY` chạy 3 tiếng, không lỗi, không xong"

### Chẩn đoán (viết trước)

> `CONCURRENTLY` phải **chờ mọi transaction đang mở kết thúc** trước khi bước sang pha tiếp theo. Có một transaction cũ đang mở (job ETL, session `idle in transaction`). CPU rảnh vì tiến trình đang **chờ**, không chạy.

### Kiểm chứng — và chỗ tôi nghĩ nhầm

Thử với hai mức cô lập của session đang mở:

| Session cũ ở | `wait_event` của `CONCURRENTLY` | `indisvalid` trong lúc đó | Kết quả |
|---|---|---|---|
| **`READ COMMITTED`** (idle in transaction) | *(null — chạy bình thường)* | — | **XONG BÌNH THƯỜNG** ✅ |
| **`REPEATABLE READ`** (idle in transaction) | **`Lock / virtualxid`** | **`f`** | **TREO** cho tới khi session kia commit |

**Chẩn đoán của tôi chỉ đúng một nửa.** Tôi nghĩ mọi transaction đang mở đều chặn. Thực tế: `READ COMMITTED` **thả snapshot sau mỗi câu lệnh** (đúng như Day 40 §5 đã đo với `backend_xmin = NULL`), nên `CONCURRENTLY` không phải chờ nó.

Chỉ transaction giữ snapshot (`REPEATABLE READ`/`SERIALIZABLE`), hoặc transaction **đang thực sự chạy một câu lệnh dài**, mới chặn.

### Trả lời các câu hỏi của ca

**`wait_event` là `Lock / virtualxid`.** Không phải `relation` — `CONCURRENTLY` không xin lock trên bảng, nó chờ **virtual transaction id** của các transaction có thể chưa thấy index mới. Đây là chữ ký rất đặc trưng: thấy `Lock/virtualxid` trên một `CREATE INDEX CONCURRENTLY` là biết ngay đang chờ transaction cũ.

**CPU rảnh** vì tiến trình ngủ trong lock manager, không làm việc gì.

**Nếu huỷ nó:** để lại index `indisvalid = false` (Day 43 §5 đo được `indisvalid = f`, `indisready = f`, 0 byte). Phải:
```sql
DROP INDEX CONCURRENTLY ix_slow;   -- rồi tạo lại
```
Nguy hiểm hơn nếu nó thất bại ở pha 2 (`indisready = true`): **mọi `INSERT`/`UPDATE` vẫn phải cập nhật index đó** nhưng planner không bao giờ dùng nó để đọc — tệ nhất mọi thế giới.

### Query kiểm tra trước mỗi migration

```sql
-- Transaction nào có thể chặn CONCURRENTLY
SELECT pid, state, backend_xmin,
       round(EXTRACT(epoch FROM now()-xact_start)::numeric,1) AS xact_giay,
       substring(query,1,60) AS q
FROM pg_stat_activity
WHERE backend_type = 'client backend'
  AND xact_start IS NOT NULL
  AND (backend_xmin IS NOT NULL          -- đang giữ snapshot (RR/SERIALIZABLE, hoặc đang chạy)
       OR state = 'active')
  AND xact_start < now() - interval '30 seconds'
ORDER BY xact_start;
-- NGƯỠNG: phải rỗng trước khi chạy CONCURRENTLY.
```

Chú ý điều kiện `backend_xmin IS NOT NULL` — đây là điểm tinh tế học được từ ca này: **nó lọc ra đúng những transaction thực sự chặn**, không báo động giả với `READ COMMITTED` idle.

---

## Ca 5 — "Thêm pgbouncer xong app lỗi ngẫu nhiên ~2%"

### Chẩn đoán (viết trước)

> pgbouncer `transaction` mode: mỗi transaction có thể rơi vào một server connection **khác nhau**. Prepared statement do driver tạo (`S_3`) chỉ tồn tại trên connection đã `Parse` nó. Khi transaction sau rơi vào connection khác ⇒ `26000`.

### Kiểm chứng (Day 42 §3)

```
S1: PREPARE shared_q(bigint) AS ...;  EXECUTE shared_q(42);   → OK
S2: SELECT count(*) FROM pg_prepared_statements;              → 0
S2: EXECUTE shared_q(42);
    ERROR:  26000: prepared statement "shared_q" does not exist
    LOCATION:  FetchPreparedStatement, prepare.c:448
```

### Vì sao chỉ ~2% chứ không phải 100%

Ba yếu tố cộng lại:

1. **pgjdbc chỉ tạo statement trên server từ lần thứ 6** (`prepareThreshold = 5`). Day 42 đo được: `custom_plans` lên 5 rồi `generic_plans` mới tăng. 5 lần đầu dùng statement vô danh, không thể lỗi.
2. **Xác suất rơi vào connection khác không phải 100%.** Với `default_pool_size = 20` và ít client, một client thường được cấp lại đúng connection cũ. Day 36 §6 đo hiện tượng cùng loại với `SET`: **2/16 client (12,5%) mất giá trị** — không phải tất cả.
3. **Chỉ những query chạy đủ nhiều mới chạm ngưỡng 5**, và chỉ những request rơi đúng cửa sổ mới lỗi.

> **Đây chính là kiểu bug tệ nhất: không tái hiện được trên dev (một client ⇒ luôn cùng connection), không tái hiện trên staging (tải thấp), chỉ xuất hiện ở production dưới tải — và "restart thì hết vài phút" vì restart reset pool và mọi statement phải đếm lại từ đầu.**

### Ba cách sửa

| Cách | Làm gì | Mất gì | Đánh giá |
|---|---|---|---|
| **A. Ở app** | JDBC `prepareThreshold=0`; pgx `QueryExecModeSimpleProtocol` | **0,033 ms/query** planning time (Day 42 §1) = 66 s CPU/ngày với 2M query/ngày = **0,0095%** | Sửa được ngay, gần như không mất gì. Nhược: phải nhớ đặt ở **mọi** service mới. |
| **B. Ở pgbouncer** | Nâng lên **≥ 1.21**, đặt `max_prepared_statements = 200` | RAM ở pgbouncer; thêm một thứ có thể sai | Day 36 §6e đo: pgbouncer **1.25.2** chạy `-M prepared` bình thường, 38.725 tps, 0 lỗi. Cấu hình ở một chỗ, áp cho tất cả. |
| **C. Ở kiến trúc** | Bỏ pgbouncer, hoặc chuyển sang `session` mode | Mất toàn bộ lợi ích pooling: Day 36 đo được **500 client chạy trên `max_connections=100` chỉ với 21 backend**, RAM 370 MB vs 725 MB | Chỉ dùng khi thật sự không có pooler cũng được |

**Chọn A ngay hôm nay (dừng chảy máu), B trong sprint tới (giải pháp bền).**

Không chọn C: Day 36 §5 cho thấy pgbouncer là thứ duy nhất giúp 500 client chạy được khi `max_connections = 100` — bỏ nó đi là đổi một bug 2% lấy một sự cố toàn phần khi traffic tăng.

**Và quan trọng không kém:** rà nốt các thứ cùng nhóm (Day 36 §6, Day 42 §3) — `SET` cấp session (**mất 12,5%**), `pg_advisory_lock` (**rò rỉ vĩnh viễn**), temp table, `LISTEN/NOTIFY`. Chúng là **cùng một bug với năm biểu hiện**, và cái advisory lock nguy hiểm hơn `26000` nhiều vì nó không báo lỗi, chỉ treo.

---

## §6. Diễn tập: migration hoàn chỉnh có đồng hồ bấm giờ

**Yêu cầu:** thêm `quality smallint NOT NULL DEFAULT 0` + index `(device_id, ts) WHERE quality > 0` trên `ts_kv` (**5.000.000 dòng, 289 MB**), sao cho:
1. không có lần chờ lock nào > 3 giây,
2. p99 probe không tăng quá 2× baseline,
3. dừng giữa chừng chạy tiếp được,
4. mọi bước rollback được.

Toàn bộ script: [`migration.sql`](migration.sql) — viết **trước** khi chạy.

### Kết quả từng bước

| Bước | Lệnh | Lock mode | **Thời gian** |
|---|---|---|---|
| 0 | kiểm tra: transaction > 60 s, index INVALID | `ACCESS SHARE` | 2,29 ms |
| **1** | `ADD COLUMN quality smallint DEFAULT 0` | `ACCESS EXCLUSIVE` | **4,58 ms** |
| **2** | backfill theo lô (idempotent) | `ROW EXCLUSIVE` | **373,9 ms** (0 dòng — `DEFAULT` hằng đã lo) |
| **3a** | `ADD CONSTRAINT ck ... NOT VALID` | `ACCESS EXCLUSIVE` | **3,27 ms** |
| **3b** | `VALIDATE CONSTRAINT ck` | **`SHARE UPDATE EXCLUSIVE`** | **381,5 ms** |
| **3c** | `ALTER COLUMN quality SET NOT NULL` | `ACCESS EXCLUSIVE` | **2,86 ms** |
| **3d** | `DROP CONSTRAINT ck` | `ACCESS EXCLUSIVE` | 3,21 ms |
| **4** | `CREATE INDEX CONCURRENTLY ... WHERE quality > 0` | `SHARE UPDATE EXCLUSIVE` | **533,8 ms** |
| 5 | xác nhận: 0 index INVALID, 0 dòng NULL / 5.000.000 | — | 165,6 ms |
| | **TỔNG** | | **~1,3 giây** |
| | **Cửa sổ khoá dài nhất** | | **4,58 ms** |

### Kết quả probe

| | Baseline (không migration) | **Trong lúc migration** |
|---|---|---|
| Số mẫu | 1.050 | 410 |
| avg | 0,928 ms | **0,678 ms** |
| **p99** | **2,40 ms** | **2,01 ms** |
| **max** | **11,40 ms** | **4,33 ms** |
| Mẫu > 3.000 ms | 0 | **0** |

### Đạt cả 4 yêu cầu

| # | Yêu cầu | Kết quả | Đạt? |
|---|---|---|---|
| 1 | Không chờ lock > 3 s | cửa sổ khoá dài nhất **4,58 ms**, 0 mẫu probe > 3 s | ✅ |
| 2 | p99 không tăng quá 2× | **2,01 ms vs 2,40 ms — GIẢM 16%** | ✅ |
| 3 | Dừng giữa chừng chạy tiếp được | backfill có `WHERE quality IS NULL`, commit mỗi lô | ✅ |
| 4 | Mọi bước rollback được | mỗi bước có dòng rollback ghi trong script | ✅ |

### Ba điều học được từ chính bài diễn tập

**a) p99 trong lúc migration THẤP HƠN baseline.** Không phải migration làm hệ nhanh hơn — mà baseline chạy ngay sau `VACUUM ANALYZE` khi cache còn lạnh (max 11,40 ms), còn lúc migration thì cache đã ấm. **Bài học đo lường: baseline phải lấy ở cùng trạng thái cache với lúc đo thật, nếu không nó vô nghĩa.**

**b) Backfill trả về 0 dòng — và đó là kết quả đúng.** Vì `DEFAULT 0` là **hằng**, PG11+ lưu vào catalog và không dòng cũ nào có `quality IS NULL` (Day 43 §3). Vòng lặp backfill vẫn giữ trong script vì:
- nó là mẫu dùng lại cho trường hợp giá trị phải tính từ dữ liệu,
- nó **xác nhận** giả định "DEFAULT hằng không cần backfill" thay vì tin suông.

373,9 ms đó là chi phí của một lần quét tìm dòng `NULL` — rẻ và đáng.

**c) Toàn bộ migration mất 1,3 giây trên bảng 5 triệu dòng.** So với cách sai trên bảng **3** triệu dòng ở Day 44: **19,1 giây và một request đứng 1.195 ms**. Cách đúng ở đây nhanh hơn *và* an toàn hơn — vì `DEFAULT` hằng tránh được hoàn toàn việc viết lại 5 triệu dòng.

> **Đây là bài học lớn nhất của cả tuần 9: cách rẻ nhất để làm một migration an toàn là làm sao để KHÔNG PHẢI đụng vào dữ liệu cũ.** `DEFAULT` hằng, `NOT VALID`, `CONCURRENTLY`, rename thay vì đổi kiểu — cả bốn đều là biến thể của cùng ý tưởng đó.

---

## §7. Playbook

Sản phẩm chính của tuần 9: **[`migration-playbook.md`](migration-playbook.md)** — gồm đủ 5 mục yêu cầu:

1. **Bảng phân loại DDL** — 21 lệnh × (lock mode, rewrite?, quét?, số đo thật, mức nguy hiểm).
2. **Khuôn migration chuẩn** — script deploy có retry + 5 mẫu SQL (thêm cột NOT NULL, thêm constraint, thêm UNIQUE, đổi kiểu, backfill).
3. **Checklist trước khi chạy** — 8 query chạy được ngay, mỗi cái kèm ngưỡng.
4. **Ngưỡng dừng** — 6 điều kiện + cách huỷ an toàn cho từng loại lệnh.
5. **Danh sách "không bao giờ làm giờ cao điểm"** — 9 lệnh, mỗi lệnh kèm lý do bằng số.

---

## Ôn tuần 9

### Ba con số đo được tuần này mà trước đây chỉ đoán

| # | Con số | Trước đây tôi tưởng | Ngày |
|---|---|---|---|
| **1** | **`pg_relation_size` giấu 82% dung lượng** — bảng "3.744 kB" thật ra 300 MB; và lọc theo một field jsonb tốn **225.469 buffer / 828,6 ms** so với **468 buffer / 5,44 ms** nếu là cột thật | "TOAST là chi tiết lưu trữ, không ảnh hưởng query" | 41, 45 |
| **2** | **Một `SELECT` vô can chờ 5.099 ms** vì xếp hàng sau một `ALTER TABLE` đang chờ — bản thân `ALTER` chỉ chạy 11 ms | "DDL nhanh thì an toàn" | 43 |
| **3** | **Tham số `numeric` thay vì `bigint` làm query chậm 179×** (642,55 vs 3,59 ms) vì Postgres ép **cột** chứ không ép tham số | "kiểu tham số chỉ là chuyện ép kiểu" | 42 |

Ba con số phụ đáng nhớ: `NOT VALID` + `VALIDATE` giảm cửa sổ khoá **89×** (Day 43); expand/contract rename giảm **303×** (Day 44); `UPDATE` đụng cột TOAST tốn **44,6× WAL** (Day 41).

### Một migration đã từng chạy mà giờ nhìn lại thấy nguy hiểm

Mẫu điển hình mà gần như team nào cũng từng chạy:

```sql
ALTER TABLE device ADD COLUMN status text NOT NULL DEFAULT 'active';
UPDATE device SET status = CASE WHEN is_active THEN 'active' ELSE 'disabled' END;
CREATE INDEX idx_device_status ON device(status);
```

Ba chỗ nguy hiểm, giờ nhìn lại thấy rõ:

1. **Không có `lock_timeout`.** Nếu lúc đó có một job báo cáo đang chạy, cả ba câu xếp hàng và **mọi query trên `device` đứng im** (Ca 1: chờ 8 giây trong lab, 8 phút trên production).
2. **`UPDATE` một phát trên toàn bảng.** Bảng phình >2× (Day 44: 262 → 546 MB), transaction dài ghim `xmin horizon` chặn `VACUUM` **toàn database**, WAL vọt lên làm replica lag.
3. **`CREATE INDEX` không `CONCURRENTLY`** — chặn **mọi ghi** suốt thời gian build (Day 43: INSERT bị chặn 216 ms/2M dòng ⇒ ~1 phút cho 500M dòng).

**May mắn ở chỗ:** bảng `device` chỉ 50.000 dòng nên mọi thứ xong trong vài trăm mili giây, và không có job dài nào đang chạy lúc đó. **Cả ba rủi ro đều là rủi ro về thời điểm, không phải về câu lệnh** — chạy đúng lệnh đó trên bảng 50 triệu dòng lúc 10h sáng là một sự cố.

Cách viết lại đúng, dùng đúng những gì học tuần này:
```sql
SET lock_timeout = '3s';
ALTER TABLE device ADD COLUMN status text DEFAULT 'active';          -- ~3 ms, không rewrite
-- backfill theo lô (script riêng, idempotent, có pg_sleep)
ALTER TABLE device ADD CONSTRAINT ck_status CHECK (status IS NOT NULL) NOT VALID;  -- ~3 ms
ALTER TABLE device VALIDATE CONSTRAINT ck_status;                    -- SHARE UPDATE EXCL
ALTER TABLE device ALTER COLUMN status SET NOT NULL;                 -- ~3 ms
ALTER TABLE device DROP CONSTRAINT ck_status;
SET statement_timeout = '0';
CREATE INDEX CONCURRENTLY idx_device_status ON device(status);
```

### Một thứ sẽ dùng ngay trong 2 tuần tới

**`SET lock_timeout` trong mọi migration** — và bảng phân loại DDL dán vào PR template.

Lý do chọn cái này thay vì TOAST hay expand/contract: nó là thứ **rẻ nhất để áp dụng** (một dòng, không đổi kiến trúc, không cần thảo luận) và **chặn được loại sự cố tệ nhất** (Ca 1 — lan ra toàn hệ, không chỉ chậm một chỗ). Ba thứ còn lại của tuần 9 đều cần sprint riêng; cái này làm được chiều nay.

Thứ hai trong danh sách: **rà kiểu tham số của 3 query nặng nhất** (Day 42) — 30 phút, và một chỗ lệch `BigDecimal`/`bigint` là 179×.

---

## Bảng số liệu chính

| Phép đo | Kết quả |
|---|---|
| **Tỉ lệ chẩn đoán đúng** | **4,5 / 5** (Ca 4 nửa đúng) |
| **Ca 1** — `ALTER TABLE` chờ lock | **8.091,7 ms**; `SELECT` vô can chờ **5.099,7 ms** |
| **Ca 2** — `pg_relation_size` vs thật | **3.744 kB vs 300 MB — 82×**; TOAST **97,7%** |
| — buffers: cột nhỏ vs đụng jsonb | **468 vs 225.469 — 482×**; 5,44 vs 828,6 ms — **152×** |
| — `sum(length(config))` vs `sum(id)` | 3.204 ms vs 3,05 ms — **1.050×** |
| **Ca 3** — slot giữ WAL | **152 MB**, `safe_wal_size` = **không giới hạn**; `pg_wal` 1.024 → 896 MB sau khi drop |
| **Ca 4** — `CONCURRENTLY` + session `READ COMMITTED` idle | **XONG BÌNH THƯỜNG** — không bị chặn |
| **Ca 4** — + session `REPEATABLE READ` idle | **TREO**, `wait_event = Lock/virtualxid`, `indisvalid = f` |
| **Ca 5** — statement ở connection khác | `ERROR: 26000: prepared statement "shared_q" does not exist` |
| **§6 diễn tập — tổng thời gian** | **~1,3 giây** trên 5.000.000 dòng |
| — cửa sổ khoá dài nhất | **4,58 ms** (`ADD COLUMN`) |
| — `VALIDATE CONSTRAINT` | 381,5 ms dưới **`SHARE UPDATE EXCLUSIVE`** |
| — `SET NOT NULL` (sau CHECK) | **2,86 ms** |
| — `CREATE INDEX CONCURRENTLY` (partial) | 533,8 ms |
| — **probe baseline** | p99 **2,40 ms**, max **11,40 ms** |
| — **probe trong migration** | p99 **2,01 ms**, max **4,33 ms**, **0 mẫu > 3 s** |
| — kết quả | **đạt 4/4 yêu cầu** |

---

## Ba điều dễ hiểu sai

| Hiểu nhầm | Sự thật đo được |
|---|---|
| "Mọi transaction đang mở đều chặn `CREATE INDEX CONCURRENTLY`." | **Chỉ transaction giữ snapshot mới chặn.** `READ COMMITTED` idle-in-transaction: `CONCURRENTLY` **xong bình thường**. `REPEATABLE READ` idle: **treo**, `wait_event = Lock/virtualxid`, `indisvalid = f`. Query kiểm tra trước migration phải lọc `backend_xmin IS NOT NULL`, nếu không nó báo động giả với mọi session idle. |
| "Migration an toàn thì phức tạp và chậm hơn." | Bài diễn tập: **1,3 giây trên 5 triệu dòng**, cửa sổ khoá **4,58 ms**, p99 **giảm** so với baseline. So với cách sai trên bảng nhỏ hơn (3 triệu dòng, Day 44): **19,1 giây** và một request đứng **1.195 ms**. Cách đúng nhanh hơn *và* an toàn hơn — vì `DEFAULT` hằng tránh được hoàn toàn việc đụng vào dữ liệu cũ. |
| "Tăng đĩa là cách xử lý `pg_wal` phình." | Slot giữ WAL **vô hạn theo thiết kế** (`max_slot_wal_keep_size = -1` mặc định, `safe_wal_size` = "không giới hạn"). Tăng đĩa chỉ đổi ngày sập. Đây là **rò rỉ**, không phải thiếu dung lượng — và `max_wal_size` không cứu được vì nó chỉ điều khiển nhịp checkpoint, không cho phép xoá WAL mà slot còn cần. |

---

## Áp dụng vào hệ thật

1. **Chạy checklist 8 query của playbook trên production hôm nay** — chỉ đọc, 2 phút. Đặc biệt query 1 (transaction > 60 s) và query 2 (index INVALID): cả hai đều có thể đang tồn tại mà không ai biết.

2. **Thêm `SET lock_timeout = '3s'` vào mọi migration + retry với backoff.** Việc rẻ nhất và chặn được sự cố lan rộng nhất (Ca 1).

3. **Sửa dashboard dung lượng: `pg_relation_size` → `pg_total_relation_size`.** Ca 2 đo được nó giấu **82%**. Một dòng SQL, và nó thay đổi cách team ưu tiên công việc tối ưu.

4. **Đặt `max_slot_wal_keep_size = '50GB'` (10–20% đĩa `pg_wal`) ngay.** Mặc định `-1` nghĩa là một slot bị quên có thể **dừng toàn bộ ghi**.

5. **Đặt `idle_in_transaction_session_timeout = '60s'` ở role app.** Nó là nguyên nhân gốc của Ca 1 và Ca 4, và không đụng tới transaction đang thực sự chạy query.

6. **Sửa lỗi pgbouncer `26000` ngay bằng cách A (app), rồi cách B (nâng pgbouncer ≥ 1.21) trong sprint tới.** Và rà nốt bốn thứ cùng nhóm: `SET` cấp session, `pg_advisory_lock`, temp table, `LISTEN/NOTIFY`.

7. **Dán [`migration-playbook.md`](migration-playbook.md) vào wiki** và thêm 3 câu vào PR template cho mọi PR có DDL: *lệnh này lấy lock gì? có rewrite không? mất bao lâu ở kích thước bảng hiện tại?*

8. **Diễn tập trước khi chạy thật:** khôi phục một bản sao production, chạy migration với probe, ghi lại `max` latency và cửa sổ khoá. Nếu `max` > 100 ms thì có bước cần tách nhỏ hơn.

---

## Câu hỏi mở sang tuần 10

- **Day 46–48 (capstone)** dùng đúng quy trình chẩn đoán của ngày hôm nay, nhưng trên một hệ chưa biết trước bệnh gì: audit → chẩn đoán → sửa → đo lại → và trả giá cho những gì mình sửa.
- **Day 40 §7** là bộ khung 8 bước cho 30 giây đầu của sự cố; playbook hôm nay là bộ khung cho **thay đổi có kế hoạch**. Hai thứ này nên nằm cạnh nhau trong wiki.
- **Câu hỏi mở thật sự:** bài diễn tập §6 chạy 1,3 giây vì `DEFAULT` hằng tránh được việc đụng dữ liệu cũ. Nhưng nếu giá trị `quality` phải **tính từ dữ liệu** (ví dụ `quality = CASE WHEN dbl_v IS NULL THEN 0 ELSE 1 END`) thì backfill 5 triệu dòng là bắt buộc — và Day 44 đo được nó tốn ~27 giây, bloat **2×**, WAL **1,2 GB**. Ở kích thước nào thì "backfill tại chỗ + `pg_repack`" thua "tạo bảng mới + swap"? Đó là bài toán còn để ngỏ, và câu trả lời phụ thuộc vào đĩa trống nhiều hơn là vào thời gian.

---

### Dọn dẹp

```sql
ALTER TABLE ts_kv DROP COLUMN IF EXISTS quality;
DROP INDEX IF EXISTS ix_tskv_quality, ix_tskv_dev_probe, ix_slow;
DROP TABLE IF EXISTS device_profile, probe, wal_t;
DROP PROCEDURE IF EXISTS run_probe(int);
SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots;
VACUUM ts_kv;
```
