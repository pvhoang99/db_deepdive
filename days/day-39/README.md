# Day 39 — Logical decoding, replication slot & outbox/CDC

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

> Ngày hôm qua bạn nhìn replica **vật lý** (byte-for-byte). Hôm nay là kênh còn lại: rút **sự kiện logic** (INSERT/UPDATE/DELETE trên bảng nào, giá trị gì) ra khỏi WAL. Đây chính là thứ Debezium/CDC chạy bên dưới — và là đối thủ trực tiếp của outbox pattern mà bạn đang dùng.

## Chuẩn bị

```sql
\timing on
\o /days/day-39/output.txt
SHOW wal_level;   -- phải là 'logical' (docker-compose đã đặt sẵn)
```

Nếu ra `replica`: `make down && make up` để nạp lại cấu hình.

---

## §0. Đoán trước

Viết dự đoán vào `writeup.md` **trước khi chạy gì**:

1. Một replication slot **không ai đọc** trong 3 ngày thì chuyện gì xảy ra với primary?
2. `DELETE FROM device WHERE id=7` — CDC đọc được **cả dòng vừa bị xoá** hay chỉ khoá chính?
3. Outbox (bảng `outbox` + poller) và CDC (logical decoding) — cái nào sinh ra ít WAL hơn cho cùng một sự kiện? Chênh mấy lần?
4. Slot có sống sót qua restart Postgres không? Qua failover sang replica thì sao?

---

## §1. Ba mức `wal_level`

### Lý thuyết

WAL luôn đủ để **crash recovery**. Câu hỏi là nó có đủ để làm thêm việc khác không:

| `wal_level` | WAL chứa gì thêm | Dùng để |
|---|---|---|
| `minimal` | chỉ đủ recover | không replicate được |
| `replica` (mặc định) | đủ để replay trên máy khác | streaming replication, PITR |
| `logical` | + thông tin để **giải mã ra hàng dữ liệu** | logical replication, CDC |

Điểm mấu chốt: WAL ở mức `replica` ghi **"page 42 byte 128 đổi thành X"** — hoàn toàn vật lý, không biết đó là bảng nào, cột nào. Logical decoding cần thêm metadata (quan hệ, replica identity) để dựng lại được "`UPDATE device SET name='x' WHERE id=7`".

Cái giá: WAL to hơn (đặc biệt khi `REPLICA IDENTITY FULL`, xem §3), và đổi `wal_level` **bắt buộc restart**.

### Làm ngay

```sql
SELECT name, setting, context FROM pg_settings
WHERE name IN ('wal_level','max_replication_slots','max_wal_senders');
```

**Ghi vào writeup:** cột `context` của `wal_level` là gì? Điều đó nói gì về việc bật CDC trên production đang chạy?

---

## §2. Slot đầu tiên — nhìn WAL bằng mắt người

### Lý thuyết

**Replication slot** là một cái mốc bền vững trên WAL. Nó nói với Postgres: *"đừng xoá WAL từ vị trí này trở đi, có người còn chưa đọc."*

- **Physical slot** — cho replica vật lý (Day 38).
- **Logical slot** — gắn với một **output plugin** giải mã WAL thành thứ đọc được:
  - `test_decoding` — text, để người đọc/debug
  - `pgoutput` — nhị phân, dùng bởi logical replication và Debezium

Slot **bền vững**: sống qua restart. Đó vừa là tính năng vừa là quả bom (§4).

### Làm ngay

```sql
SELECT * FROM pg_create_logical_replication_slot('lab_slot', 'test_decoding');

SELECT slot_name, plugin, slot_type, active, restart_lsn, confirmed_flush_lsn
FROM pg_replication_slots;
```

Sinh thay đổi rồi đọc lại:

```sql
CREATE TABLE cdc_demo (id int PRIMARY KEY, name text, qty int);
INSERT INTO cdc_demo VALUES (1,'a',10), (2,'b',20);
UPDATE cdc_demo SET qty = 99 WHERE id = 1;
DELETE FROM cdc_demo WHERE id = 2;

-- peek: đọc mà KHÔNG dịch slot đi
SELECT lsn, xid, data FROM pg_logical_slot_peek_changes('lab_slot', NULL, NULL);
```

Chạy lại đúng câu `peek` đó lần nữa — vẫn ra y hệt. Rồi:

```sql
-- get: đọc VÀ dịch slot đi (consume)
SELECT lsn, xid, data FROM pg_logical_slot_get_changes('lab_slot', NULL, NULL);
SELECT lsn, xid, data FROM pg_logical_slot_get_changes('lab_slot', NULL, NULL);  -- lần 2: rỗng
```

**Ghi vào writeup:**
- Dán đủ output của `peek` cho 4 thao tác trên.
- `BEGIN`/`COMMIT` xuất hiện thế nào? Thứ tự các thay đổi được phát ra là thứ tự **thực hiện** hay thứ tự **commit**? (Gợi ý: mở 2 transaction đan xen bằng `make s1`/`make s2` rồi peek — đây là bài kiểm tra thật, làm đi.)
- `peek` vs `get` khác nhau ở đâu, và vì sao consumer thật **bắt buộc** phải dùng `get` (hoặc gửi feedback LSN)?

---

## §3. `REPLICA IDENTITY` — vì sao DELETE của bạn rỗng ruột

### Lý thuyết

Với `UPDATE`/`DELETE`, WAL cần biết **dòng nào** bị đụng. Mặc định Postgres chỉ ghi **khoá chính** của dòng đó (`REPLICA IDENTITY DEFAULT`).

| Chế độ | WAL ghi gì cho old row | Hệ quả |
|---|---|---|
| `DEFAULT` | chỉ cột PK | CDC không thấy giá trị cũ; bảng **không có PK** thì UPDATE/DELETE **lỗi** khi có publication |
| `USING INDEX i` | cột của unique index `i` | dùng khi PK không phù hợp |
| `FULL` | **toàn bộ dòng cũ** | thấy được before-image; WAL phình to, UPDATE đắt hơn nhiều |
| `NOTHING` | không gì | UPDATE/DELETE không replicate được |

Đây là chỗ đội CDC hay vấp: muốn "before/after image" để dựng event domain → bật `FULL` → WAL tăng vọt → replica lag → sự cố.

### Làm ngay

```sql
-- bảng KHÔNG có primary key
CREATE TABLE cdc_nopk (id int, v text);
INSERT INTO cdc_nopk VALUES (1,'x');
UPDATE cdc_nopk SET v='y';
DELETE FROM cdc_nopk;
SELECT data FROM pg_logical_slot_get_changes('lab_slot', NULL, NULL);
```

Rồi so 3 chế độ trên bảng có PK:

```sql
-- (a) DEFAULT
ALTER TABLE cdc_demo REPLICA IDENTITY DEFAULT;
UPDATE cdc_demo SET name = 'a1', qty = 11 WHERE id = 1;
SELECT data FROM pg_logical_slot_get_changes('lab_slot', NULL, NULL);

-- (b) FULL
ALTER TABLE cdc_demo REPLICA IDENTITY FULL;
UPDATE cdc_demo SET name = 'a2', qty = 12 WHERE id = 1;
SELECT data FROM pg_logical_slot_get_changes('lab_slot', NULL, NULL);
```

Đo cái giá của `FULL` bằng WAL (kỹ thuật của Day 24/37):

```sql
CREATE TABLE ri_def  (id int PRIMARY KEY, a text, b text, c text, pad text);
CREATE TABLE ri_full (id int PRIMARY KEY, a text, b text, c text, pad text);
INSERT INTO ri_def  SELECT g, 'a','b','c', repeat('x',200) FROM generate_series(1,100000) g;
INSERT INTO ri_full SELECT g, 'a','b','c', repeat('x',200) FROM generate_series(1,100000) g;
ALTER TABLE ri_full REPLICA IDENTITY FULL;
VACUUM ANALYZE ri_def, ri_full;
CHECKPOINT;

SELECT pg_stat_statements_reset();
UPDATE ri_def  SET a = 'z';
UPDATE ri_full SET a = 'z';
SELECT substring(query,1,30) AS q, calls,
       pg_size_pretty(wal_bytes::bigint) AS wal, wal_records, wal_fpi,
       round(total_exec_time::numeric,0) AS ms
FROM pg_stat_statements WHERE query LIKE 'UPDATE ri_%' ORDER BY wal_bytes DESC;
```

**Ghi vào writeup — bảng:**

| Chế độ | WAL sinh ra | wal_records | thời gian UPDATE | CDC thấy được gì |
|---|---|---|---|---|

Trả lời: `FULL` đắt hơn `DEFAULT` bao nhiêu **lần** ở lab này? Nếu bảng có 40 cột và pad 2KB thì con số đó **tăng hay giảm**, vì sao? Bảng không có PK thì `UPDATE` bị gì?

---

## §4. Quả bom: slot bị bỏ quên

### Lý thuyết

Slot giữ WAL lại **vô thời hạn** cho tới khi consumer xác nhận đã đọc tới đâu. Consumer chết / Debezium bị scale về 0 / môi trường staging bị xoá mà slot còn — WAL chất đống trong `pg_wal` cho tới khi **đầy đĩa và Postgres dừng ghi**.

Đây là một trong những cách phổ biến nhất để giết một Postgres đang chạy CDC. `max_wal_size` **không** cứu bạn — nó chỉ điều khiển nhịp checkpoint, không cho phép xoá WAL mà slot còn cần.

Van an toàn (PG13+): `max_slot_wal_keep_size`. Vượt ngưỡng thì Postgres **hy sinh slot** (`wal_status = 'lost'`) để cứu database. Mất CDC còn hơn mất database — nhưng phải chủ động đặt, mặc định là `-1` (vô hạn).

### Làm ngay

```sql
-- slot lab_slot ở trên đang là "consumer chết". Đo nó giữ bao nhiêu WAL.
SELECT slot_name, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_bi_giu,
       pg_size_pretty(safe_wal_size) AS con_du_dia
FROM pg_replication_slots;
```

Sinh tải ghi rồi đo lại:

```sql
SELECT pg_size_pretty(sum(size)) AS pg_wal_dir FROM pg_ls_waldir();

INSERT INTO ts_kv SELECT device_id, key_id, ts + interval '200 days', dbl_v, bool_v, str_v
FROM ts_kv LIMIT 500000;
CHECKPOINT;

SELECT pg_size_pretty(sum(size)) AS pg_wal_dir_sau FROM pg_ls_waldir();
SELECT slot_name, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_bi_giu
FROM pg_replication_slots;
```

So sánh: tạo thêm 1 slot rồi consume nó ngay, và một slot bỏ quên — chạy `CHECKPOINT` vài lần, xem `pg_ls_waldir()` có co lại không.

Đặt van an toàn và quan sát:

```sql
ALTER SYSTEM SET max_slot_wal_keep_size = '64MB';
SELECT pg_reload_conf();
-- sinh thêm WAL rồi xem wal_status chuyển extended -> unreserved -> lost
SELECT slot_name, wal_status, pg_size_pretty(safe_wal_size) FROM pg_replication_slots;
```

**Ghi vào writeup:**
- `pg_wal` tăng bao nhiêu MB sau 500k row? Sau `CHECKPOINT` nó có giảm không — vì sao **không**?
- 4 giá trị của `wal_status` (`reserved` / `extended` / `unreserved` / `lost`) nghĩa là gì?
- **Query cảnh báo** bạn sẽ đưa lên dashboard: slot nào đang giữ > N GB WAL, hoặc `active = false` quá lâu. Viết ra, chạy được ngay.
- Bạn sẽ đặt `max_slot_wal_keep_size` bao nhiêu cho hệ thật, và **hệ quả khi slot bị `lost`** là gì (Debezium phải làm gì để phục hồi)?

---

## §5. Logical replication thật: publication & subscription

### Lý thuyết

`pgoutput` + `PUBLICATION`/`SUBSCRIPTION` là logical replication built-in. Khác physical replication (Day 38) ở những điểm sống còn:

| | Physical | Logical |
|---|---|---|
| Đơn vị | byte của page | hàng dữ liệu |
| Phạm vi | **cả cluster** | chọn từng bảng |
| Đích | phải cùng version, read-only | version khác được, **ghi được** |
| DDL | tự động theo | **KHÔNG** theo — phải tự chạy ở cả 2 bên |
| Sequence | theo | **không** theo |
| Dùng để | HA, đọc phân tải | CDC, migration cross-version, tách service |

Dòng "DDL không theo" là cái làm hỏng nhiều lần migration: thêm cột ở publisher, subscriber không biết, replication đứng.

### Làm ngay

```sql
CREATE PUBLICATION pub_demo FOR TABLE cdc_demo;

SELECT * FROM pg_publication_tables;

-- xem WAL dưới dạng pgoutput (nhị phân, đọc bằng số)
SELECT pg_create_logical_replication_slot('pg_slot', 'pgoutput');
INSERT INTO cdc_demo VALUES (3,'c',30);
SELECT count(*), pg_size_pretty(sum(octet_length(data))::bigint)
FROM pg_logical_slot_peek_binary_changes('pg_slot', NULL, NULL,
     'proto_version','1','publication_names','pub_demo');
```

So overhead 2 plugin cho **cùng một thay đổi**:

```sql
SELECT sum(octet_length(data)) AS bytes_test_decoding
FROM pg_logical_slot_peek_changes('lab_slot', NULL, NULL);
```

**Ghi vào writeup:** `pgoutput` nhỏ hơn `test_decoding` bao nhiêu %? Trong 6 dòng của bảng so sánh trên, dòng nào là lý do **hệ của bạn** sẽ chọn logical thay vì physical?

---

## §6. Outbox vs CDC — bạn đang dùng cái nào và có nên đổi không

### Lý thuyết

Bạn đang dùng **outbox**: trong cùng transaction với thay đổi domain, ghi thêm một dòng vào bảng `outbox`; một poller đọc bảng đó và đẩy sang Kafka.

| | Outbox + poller | CDC (logical decoding) |
|---|---|---|
| Sự kiện là gì | **domain event** bạn tự định nghĩa | thay đổi hàng, thô |
| Đảm bảo | atomic với business data (cùng transaction) | atomic theo bản chất (đọc từ WAL) |
| Chi phí ghi | **2 lần ghi** + xoá dòng → bloat + vacuum | 0 (WAL vốn đã có) |
| Độ trễ | = chu kỳ poll (hoặc `LISTEN/NOTIFY`) | ~ms |
| Rủi ro vận hành | bảng outbox phình, vacuum không kịp | **slot bỏ quên giết DB** |
| Coupling schema | không — event là hợp đồng | có — consumer thấy cột thật |
| Thứ tự | theo id/thời gian bạn chọn | theo thứ tự commit |

Không có bên nào thắng tuyệt đối. Nhưng bạn phải **đo được** cái giá thay vì tranh luận cảm tính.

### Làm ngay

Đo chi phí ghi của outbox so với CDC cho **cùng 10.000 sự kiện**:

```sql
CREATE TABLE ob_order (id bigserial PRIMARY KEY, status text, amount numeric);
CREATE TABLE outbox (
  id bigserial PRIMARY KEY, aggregate_id bigint, type text,
  payload jsonb, created_at timestamptz DEFAULT now()
);
INSERT INTO ob_order (status, amount) SELECT 'NEW', g FROM generate_series(1,10000) g;
VACUUM ANALYZE ob_order, outbox;
CHECKPOINT;

SELECT pg_stat_statements_reset();

-- (a) kiểu outbox: update + ghi event
UPDATE ob_order SET status='PAID' WHERE id <= 10000;
INSERT INTO outbox (aggregate_id, type, payload)
SELECT id, 'OrderPaid', jsonb_build_object('id',id,'amount',amount) FROM ob_order WHERE id <= 10000;
-- poller xoá sau khi đẩy
DELETE FROM outbox;

SELECT substring(query,1,40) AS q, calls, pg_size_pretty(wal_bytes::bigint) AS wal,
       round(total_exec_time::numeric,0) AS ms
FROM pg_stat_statements WHERE query ~* '(ob_order|outbox)' ORDER BY wal_bytes DESC;

-- bloat mà outbox để lại
SELECT relname, n_live_tup, n_dead_tup,
       pg_size_pretty(pg_total_relation_size(relid)) AS size
FROM pg_stat_user_tables WHERE relname='outbox';
```

```sql
-- (b) kiểu CDC: chỉ update, sự kiện lấy từ WAL
CREATE PUBLICATION pub_order FOR TABLE ob_order;
SELECT pg_create_logical_replication_slot('order_slot','test_decoding');
SELECT pg_stat_statements_reset();
UPDATE ob_order SET status='SHIPPED' WHERE id <= 10000;
SELECT substring(query,1,40) AS q, pg_size_pretty(wal_bytes::bigint) AS wal,
       round(total_exec_time::numeric,0) AS ms
FROM pg_stat_statements WHERE query LIKE 'UPDATE ob_order%';
SELECT count(*) AS su_kien_doc_duoc FROM pg_logical_slot_get_changes('order_slot', NULL, NULL);
```

**Ghi vào writeup — bảng so sánh cho 10.000 sự kiện:**

| Cách | WAL | thời gian | dead tuple để lại | độ trễ | sự kiện là gì |
|---|---|---|---|---|---|

### Dọn dẹp

```sql
SELECT pg_drop_replication_slot('lab_slot');
SELECT pg_drop_replication_slot('pg_slot');
SELECT pg_drop_replication_slot('order_slot');
DROP PUBLICATION pub_demo; DROP PUBLICATION pub_order;
DROP TABLE cdc_demo, cdc_nopk, ri_def, ri_full, ob_order, outbox;
DELETE FROM ts_kv WHERE ts > '2025-12-01';
VACUUM ts_kv;
ALTER SYSTEM RESET max_slot_wal_keep_size;
SELECT pg_reload_conf();
```

**Quan trọng:** đừng bỏ sót `pg_drop_replication_slot` — nếu quên, lab của bạn sẽ giữ WAL mãi và đây đúng là bài học §4.

---

## §7. Giám sát — 5 dòng phải có trên dashboard

### Làm ngay

Viết (và chạy) query cho từng chỉ số:

```sql
-- 1. slot nào không active và giữ bao nhiêu WAL
-- 2. tổng dung lượng pg_wal so với max_wal_size
-- 3. slot có wal_status khác 'reserved'
-- 4. độ trễ logical: confirmed_flush_lsn tụt sau current_wal_lsn bao nhiêu byte
-- 5. (nếu dùng outbox) số dòng tồn đọng + tuổi dòng cũ nhất
```

**Ghi vào writeup:** 5 query + ngưỡng cảnh báo cụ thể (con số, không phải "cao thì báo").

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B. Áp dụng vào hệ thật:**
- Hệ của bạn có slot nào đang tồn tại không? Chạy `pg_replication_slots` trên production và ghi lại (chỉ đọc).
- Bảng outbox hiện tại: bao nhiêu dòng/ngày, WAL sinh ra bao nhiêu, `n_dead_tup` bao nhiêu, autovacuum có theo kịp không (dùng kiến thức Day 22–23)?
- Với **một** aggregate cụ thể trong hệ bạn: nếu đổi sang CDC thì mất gì (event là row thô, không còn là domain event) và được gì? Viết 5 câu, có số.

### Đạt khi

Bạn giải thích được vì sao một slot bị bỏ quên có thể làm database dừng ghi, đo được chi phí WAL của `REPLICA IDENTITY FULL`, và nêu được ít nhất **hai** lý do kỹ thuật cụ thể để giữ outbox thay vì đổi sang CDC (hoặc ngược lại) cho hệ của bạn.

**Xong thì gõ `/review-bai`.**
