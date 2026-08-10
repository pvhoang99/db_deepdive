# Day 39 — Lời giải: Logical decoding, replication slot & outbox/CDC

> Bài chữa. Đo thật trên lab (Postgres 17, `wal_level = logical`). Hôm qua nhìn replica **vật lý** (byte-for-byte); hôm nay rút **sự kiện logic** ra khỏi WAL — chính là thứ Debezium chạy bên dưới.
>
> Kết luận một câu: **outbox tốn WAL gấp 1,83× so với CDC cho cùng 10.000 sự kiện, và để lại một cái bảng phình 16,3× khi autovacuum không kịp — nhưng CDC đổi lại rủi ro một slot bỏ quên làm database dừng ghi.**

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án đo được | Bẫy |
|---|---|---|---|
| 1 | Slot không ai đọc trong 3 ngày thì sao? | **WAL chất đống vô hạn.** Đo được: 2 slot bỏ quên giữ **1.278 MB** sau 3M dòng INSERT, `pg_wal` từ 1.024 → **1.296 MB**, và `CHECKPOINT` **không** giải phóng được. Tiếp tục thì đầy đĩa ⇒ **Postgres dừng ghi**. | `max_wal_size` **không** cứu được — nó chỉ điều khiển nhịp checkpoint, không cho phép xoá WAL mà slot còn cần. Van duy nhất là `max_slot_wal_keep_size`, mặc định `-1` = vô hạn. |
| 2 | `DELETE` — CDC đọc được cả dòng hay chỉ PK? | **Chỉ PK**, với `REPLICA IDENTITY DEFAULT`: `DELETE: id[integer]:2`. Với `FULL` mới thấy đủ: `DELETE: id:10 name:'A-truoc' qty:1`. Bảng **không có PK**: `DELETE: (no-tuple-data)` — rỗng hoàn toàn. | Bẫy đắt: bật `FULL` để có before-image ⇒ **WAL +32,4%** ở lab (pad 200 byte). Với bảng có cột lớn, tỉ lệ này tăng mạnh — xem §3. |
| 3 | Outbox hay CDC sinh ít WAL hơn? Chênh mấy lần? | **CDC ít hơn 1,83×.** Outbox: 5.692.509 byte (UPDATE + INSERT outbox + DELETE outbox). CDC: 3.116.324 byte (chỉ UPDATE). Thời gian 106 ms vs 77 ms (1,38×). | Bẫy: chênh lệch WAL chỉ 1,83× nghe không nhiều. Cái đắt hơn là **bloat**: sau 5 chu kỳ poller không vacuum, bảng outbox rỗng nhưng chiếm **4.304 kB** so với 264 kB — **16,3×**. |
| 4 | Slot có sống qua restart? Qua failover? | **Sống qua restart** (slot là bền vững — đó vừa là tính năng vừa là quả bom). **KHÔNG sống qua failover** ở PG < 17 — slot không được replicate sang standby, nên promote xong là mất hết slot và CDC phải snapshot lại từ đầu. | PG17 có `failover slots` (`pg_create_logical_replication_slot(..., failover => true)`) nhưng cần `sync_replication_slots = on` và standby cấu hình đúng. Đừng giả định nó tự có. |

---

## §1. Ba mức `wal_level`

```sql
SELECT name, setting, context FROM pg_settings
WHERE name IN ('wal_level','max_replication_slots','max_wal_senders');
```

| name | setting | **context** |
|---|---|---|
| `wal_level` | `logical` | **`postmaster`** |
| `max_replication_slots` | 10 | **`postmaster`** |
| `max_wal_senders` | 10 | **`postmaster`** |

**`context = postmaster` nghĩa là: đổi giá trị này BẮT BUỘC restart Postgres.** Không `pg_reload_conf()`, không `ALTER SYSTEM` rồi reload — phải restart.

Hệ quả thực tế rất lớn: **bật CDC trên một production đang chạy `wal_level = replica` cần một cửa sổ downtime.** Đây là thứ phải lên kế hoạch từ trước, không phải "bật lên xem sao". Và nó áp dụng cho cả `max_replication_slots` — thêm slot thứ 11 khi giới hạn là 10 cũng cần restart.

### Ba mức khác nhau ở đâu

| `wal_level` | WAL chứa gì thêm | Dùng để |
|---|---|---|
| `minimal` | chỉ đủ crash recovery | không replicate được |
| `replica` (mặc định) | đủ để replay trên máy khác | streaming replication, PITR |
| **`logical`** | + metadata để **giải mã ra hàng dữ liệu** | logical replication, CDC |

Điểm mấu chốt: WAL ở mức `replica` ghi **"page 42, offset 128, đổi thành X"** — hoàn toàn vật lý, không biết đó là bảng nào, cột nào. Đó là lý do replica vật lý giống primary tới từng byte nhưng **không thể** cho bạn biết "dòng nào của bảng nào vừa đổi".

`logical` thêm: OID quan hệ, thông tin schema, và **replica identity** (§3) để dựng lại được `UPDATE device SET name='x' WHERE id=7`.

Cái giá: WAL to hơn. Day 37 đã ghi chú điều này — mọi con số WAL của lab đều đo ở `logical`, cao hơn `replica` khoảng 5–15% (và cao hơn nhiều nếu có bảng `REPLICA IDENTITY FULL`).

---

## §2. Slot đầu tiên — nhìn WAL bằng mắt người

```sql
SELECT * FROM pg_create_logical_replication_slot('lab_slot', 'test_decoding');
```

| slot_name | plugin | slot_type | active | restart_lsn | confirmed_flush_lsn |
|---|---|---|---|---|---|
| `lab_slot` | `test_decoding` | `logical` | **`f`** | `8/C3B80CD8` | `8/C3B80D10` |

`active = f` ngay từ đầu: **slot tồn tại độc lập với consumer.** Không có process nào đang đọc, nhưng nó đã bắt đầu giữ WAL. Đây chính là hạt giống của §4.

Hai LSN cần phân biệt:
- **`restart_lsn`** — điểm WAL cũ nhất slot còn cần. **Đây là mốc quyết định WAL nào được xoá.**
- **`confirmed_flush_lsn`** — điểm consumer đã xác nhận xử lý xong.

### Decode 4 thao tác

```sql
CREATE TABLE cdc_demo (id int PRIMARY KEY, name text, qty int);
INSERT INTO cdc_demo VALUES (1,'a',10), (2,'b',20);
UPDATE cdc_demo SET qty = 99 WHERE id = 1;
DELETE FROM cdc_demo WHERE id = 2;
SELECT lsn, xid, data FROM pg_logical_slot_peek_changes('lab_slot', NULL, NULL);
```

```
    lsn     |   xid   |                              data
------------+---------+-----------------------------------------------------------------
 8/C3B80D10 | 2768094 | BEGIN 2768094
 8/C3B8E770 | 2768094 | COMMIT 2768094                    ← CREATE TABLE: transaction RỖNG
 8/C3B8E770 | 2768095 | BEGIN 2768095
 8/C3B8E770 | 2768095 | table public.cdc_demo: INSERT: id[integer]:1 name[text]:'a' qty[integer]:10
 8/C3B8E858 | 2768095 | table public.cdc_demo: INSERT: id[integer]:2 name[text]:'b' qty[integer]:20
 8/C3B8E910 | 2768095 | COMMIT 2768095
 8/C3B8E910 | 2768096 | BEGIN 2768096
 8/C3B8E910 | 2768096 | table public.cdc_demo: UPDATE: id[integer]:1 name[text]:'a' qty[integer]:99
 8/C3B8E990 | 2768096 | COMMIT 2768096
 8/C3B8E990 | 2768097 | BEGIN 2768097
 8/C3B8E990 | 2768097 | table public.cdc_demo: DELETE: id[integer]:2
 8/C3B8EA00 | 2768097 | COMMIT 2768097
```

Bốn quan sát:

1. **`BEGIN`/`COMMIT` bao quanh từng transaction** — CDC consumer dùng cặp này để xác định ranh giới nguyên tử. Một sự kiện domain thường phải gom nhiều dòng trong cùng một xid.
2. **`CREATE TABLE` cho ra một transaction RỖNG** (`BEGIN 2768094` / `COMMIT 2768094`, không có gì ở giữa). **DDL không được decode.** Đây là mấu chốt của §5: consumer không bao giờ biết schema vừa đổi.
3. **`UPDATE` chỉ hiện giá trị MỚI** (`qty:99`), không có giá trị cũ. Đây là `REPLICA IDENTITY DEFAULT`.
4. **`DELETE` chỉ hiện `id[integer]:2`** — đúng và chỉ PK. Nếu event domain của bạn cần biết "đơn hàng bị xoá có giá trị bao nhiêu", CDC mặc định **không cho bạn biết**.

### `peek` vs `get`

| | Lần 1 | Lần 2 |
|---|---|---|
| `pg_logical_slot_peek_changes` | 12 bản ghi | **12 bản ghi (y hệt)** |
| `pg_logical_slot_get_changes` | 12 bản ghi | **0 bản ghi** |

`peek` đọc mà **không dịch** `confirmed_flush_lsn`; `get` đọc **và** dịch (consume).

**Consumer thật bắt buộc phải dùng `get`** (hoặc gửi feedback LSN qua giao thức replication). Vì `restart_lsn` chỉ tiến khi consumer xác nhận — nếu bạn chỉ `peek` mãi, slot **giữ WAL vĩnh viễn** dù bạn đang đọc đều đặn. Đây là một cách rất dễ tự bắn vào chân: monitoring dùng `peek` để "xem có gì mới không", và WAL vẫn phình.

Ngược lại, `get` là **phá huỷ**: đọc xong là mất. Nếu consumer crash sau khi `get` nhưng trước khi đẩy sang Kafka, **sự kiện mất vĩnh viễn**. Đây là lý do consumer thật (Debezium) dùng giao thức streaming với feedback riêng biệt — nhận trước, xác nhận sau khi đã ghi bền vững.

### Thứ tự phát ra: commit order, không phải execution order

Hai transaction đan xen: **A bắt đầu trước**, **B bắt đầu sau và commit trước**.

```
S1: BEGIN; INSERT (10,'A-truoc');           -- xid 2768098, bắt đầu TRƯỚC
S2:              BEGIN; INSERT (20,'B-sau'); COMMIT;   -- xid 2768099, commit TRƯỚC
S1: COMMIT;
```

Slot phát ra:
```
 2768099 | BEGIN 2768099
 2768099 | table public.cdc_demo: INSERT: id:20 name:'B-sau'      ← B TRƯỚC
 2768099 | COMMIT 2768099
 2768098 | BEGIN 2768098
 2768098 | table public.cdc_demo: INSERT: id:10 name:'A-truoc'    ← A SAU
 2768098 | COMMIT 2768098
```

**Thứ tự là COMMIT ORDER, không phải execution order.** Và mọi thay đổi của một transaction được gom liền mạch, không đan xen với transaction khác.

Hai hệ quả cho consumer:

- **Tốt:** consumer luôn thấy transaction nguyên vẹn và theo đúng thứ tự chúng trở nên hữu hình — đúng thứ tự mà một client đọc database sẽ thấy. Đây là đảm bảo mạnh và là lý do CDC "đúng theo bản chất".
- **Xấu:** một transaction dài chặn mọi thứ sau nó. Transaction chạy 10 phút rồi commit ⇒ **tất cả thay đổi của nó đổ ra một lượt sau 10 phút**, và slot không tiến được trong suốt thời gian đó. Với CDC, **transaction dài = lag lớn và WAL tích tụ**. (PG14+ có streaming của in-progress transaction — `streaming = on` — giảm nhẹ vấn đề này, nhưng consumer phải xử lý được abort.)

---

## §3. `REPLICA IDENTITY` — vì sao DELETE của bạn rỗng ruột

### Bảng không có primary key

```sql
CREATE TABLE cdc_nopk (id int, v text);
INSERT INTO cdc_nopk VALUES (1,'x');
UPDATE cdc_nopk SET v='y';
DELETE FROM cdc_nopk;
```
```
 table public.cdc_nopk: INSERT: id[integer]:1 v[text]:'x'
 table public.cdc_nopk: UPDATE: id[integer]:1 v[text]:'y'
 table public.cdc_nopk: DELETE: (no-tuple-data)              ← RỖNG HOÀN TOÀN
```

`INSERT` và `UPDATE` vẫn cho thấy dòng mới (vì dòng mới nằm sẵn trong WAL). Nhưng **`DELETE` không có gì cả** — consumer biết "có một dòng bị xoá ở bảng này" mà **không biết dòng nào**. Vô dụng.

Tệ hơn, khi bảng đó nằm trong một publication:
```sql
CREATE PUBLICATION pub_nopk FOR TABLE cdc_nopk;
UPDATE cdc_nopk SET v='w';
-- ERROR:  cannot update table "cdc_nopk" because it does not have a replica identity
--         and publishes updates
-- HINT:  To enable updating the table, set REPLICA IDENTITY using ALTER TABLE.
```

**`UPDATE` LỖI HẲN.** Không phải cảnh báo — ứng dụng của bạn bắt đầu ném exception.

> **Đây là cách bật CDC làm sập production:** thêm một bảng không có PK vào publication, và mọi `UPDATE`/`DELETE` trên bảng đó lỗi ngay lập tức. Phải rà **trước**:
> ```sql
> SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
> WHERE c.relkind='r' AND n.nspname='public' AND c.relreplident='d'
>   AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid=c.oid AND i.indisprimary);
> ```

### Bốn chế độ

| Chế độ | WAL ghi gì cho dòng cũ | CDC thấy được |
|---|---|---|
| `DEFAULT` | chỉ cột PK | UPDATE: chỉ giá trị mới. DELETE: chỉ PK. |
| `USING INDEX i` | cột của unique index `i` | như DEFAULT nhưng theo index khác |
| **`FULL`** | **toàn bộ dòng cũ** | **before-image đầy đủ** |
| `NOTHING` | không gì | UPDATE/DELETE **không replicate được** |

Đo trực tiếp:

**`DEFAULT`:**
```
 table public.cdc_demo: UPDATE: id[integer]:1 name[text]:'a1' qty[integer]:11
```

**`FULL`:**
```
 table public.cdc_demo: UPDATE: old-key: id[integer]:1 name[text]:'a1' qty[integer]:11
                                new-tuple: id[integer]:1 name[text]:'a2' qty[integer]:12
```

**`FULL` + `DELETE`:**
```
 table public.cdc_demo: DELETE: id[integer]:10 name[text]:'A-truoc' qty[integer]:1
```

Với `FULL` bạn có **before và after** — đủ để dựng domain event kiểu `OrderStatusChanged(from='a1', to='a2')`. Đó chính là thứ đội CDC muốn.

### Cái giá của `FULL`, đo bằng WAL

Hai bảng giống hệt, 100.000 dòng, cột `pad` = 200 ký tự. `UPDATE` toàn bộ.

| Bảng | `wal_bytes` | WAL | `wal_records` | `wal_fpi` | Thời gian |
|---|---|---|---|---|---|
| `ri_def` (DEFAULT) | 68.567.204 | **65 MB** | 301.366 | 3.306 | 584 ms |
| `ri_full` (FULL) | 90.767.204 | **87 MB** | 301.366 | 3.306 | 568 ms |
| **Chênh** | **+22.200.000** | **+32,4%** | **0** | **0** | ~0 |

Ba điều đọc được:

1. **`wal_records` và `wal_fpi` GIỐNG HỆT NHAU.** Số lượng WAL record không đổi, chỉ **kích thước mỗi record** tăng. Đây là bằng chứng sạch rằng toàn bộ chênh lệch là do ghi thêm dòng cũ.
2. **22.200.000 / 100.000 = đúng 222 byte mỗi dòng.** Bằng đúng kích thước một dòng cũ (`pad` 200 + `a`,`b`,`c` + header tuple). Con số khớp hoàn hảo với lý thuyết.
3. **Thời gian gần như không đổi** (568 vs 584 ms — trong sai số). Ở lab, ghi thêm 22 MB WAL vào page cache không tốn thời gian. **Trên production nó tốn ở chỗ khác:** fsync, băng thông replication, dung lượng archive.

### Nếu bảng có 40 cột và pad 2 KB thì sao?

**Tỉ lệ TĂNG mạnh**, vì phần thêm vào tỉ lệ với **kích thước dòng**, còn phần gốc gần như cố định:

```
WAL_default ≈ (header + cột thay đổi + PK) × N          — gần như không đổi theo width
WAL_full    ≈ WAL_default + (kích thước toàn dòng) × N  — tỉ lệ với width
```

Ở lab: dòng 222 byte ⇒ +32,4%. Với dòng 2 KB, phần thêm là ~2 KB/dòng trong khi phần gốc vẫn ~680 byte/dòng ⇒ **+300% hoặc hơn**.

> **Quy tắc: `REPLICA IDENTITY FULL` càng đắt khi dòng càng rộng — và đúng những bảng rộng mới là bảng người ta muốn before-image.**

### Ba lối thoát thay cho `FULL`

| Cách | Đánh đổi |
|---|---|
| **`REPLICA IDENTITY USING INDEX`** trên một unique index hẹp | Có định danh ổn định mà không ghi cả dòng. Vẫn không có before-image. |
| **Consumer tự giữ state** (Debezium + bảng snapshot ở phía đích) | Không tốn WAL. Consumer phức tạp hơn, và phải bootstrap. |
| **Ghi before-image vào cột riêng** trong cùng transaction (kiểu outbox nhẹ) | Kiểm soát được chính xác cột nào cần. Quay lại 2 lần ghi — nhưng chỉ cho các cột cần thiết, rẻ hơn `FULL` nhiều. |

Cách thứ ba thường là đúng nhất trong thực tế: bạn hiếm khi cần before-image của **cả 40 cột**; bạn cần của 2–3 cột.

---

## §4. Quả bom: slot bị bỏ quên

Hai slot (`lab_slot`, `pg_slot`) không có consumer. Sinh tải ghi rồi đo:

| Giai đoạn | `pg_wal` | `wal_status` | WAL slot giữ |
|---|---|---|---|
| Ban đầu | 64 seg / 1.024 MB | `reserved` | 33 kB |
| Sau 1M dòng + 2 `CHECKPOINT` | 64 seg / 1.024 MB | `reserved` | **446 MB** |
| Sau 2M dòng nữa + 2 `CHECKPOINT` | 81 seg / **1.296 MB** | **`extended`** | **1.278 MB** |

**`CHECKPOINT` chạy 4 lần mà `pg_wal` chỉ tăng, không bao giờ giảm.** Đây là điểm quan trọng nhất của §4: checkpoint đánh dấu "WAL trước điểm này đã an toàn cho crash recovery", nhưng **slot vẫn nói "tôi chưa đọc"**, nên WAL không được xoá. `max_wal_size = 1GB` bị vượt qua thẳng thừng (1.296 MB) — **nó không phải trần cứng, nó chỉ là mục tiêu cho nhịp checkpoint.**

### Bốn giá trị `wal_status`

Đặt van an toàn và quan sát slot chết:

```sql
ALTER SYSTEM SET max_slot_wal_keep_size = '64MB';
SELECT pg_reload_conf();
```

| Bước | `wal_status` | `safe_wal_size` |
|---|---|---|
| Trước khi đặt van | `extended` | (null — không giới hạn) |
| Ngay sau khi đặt van | **`unreserved`** | **−1.208 MB** (âm = đã vượt) |
| Sau 2 `CHECKPOINT` | **`lost`** | (null) |

```
 pg_wal: 1.296 MB → 928 MB     ← Postgres giải phóng WAL sau khi hy sinh slot
```

Đọc slot đã chết:
```sql
SELECT count(*) FROM pg_logical_slot_get_changes('lab_slot', NULL, NULL);
-- ERROR:  can no longer get changes from replication slot "lab_slot"
-- DETAIL:  This slot has been invalidated because it exceeded the maximum reserved size.
```

| `wal_status` | Nghĩa | Hành động |
|---|---|---|
| **`reserved`** | WAL slot cần nằm trong `max_wal_size` | bình thường |
| **`extended`** | Đã vượt `max_wal_size`, vẫn giữ được vì chưa chạm `max_slot_wal_keep_size` | **cảnh báo** — consumer đang tụt lại |
| **`unreserved`** | Vượt `max_slot_wal_keep_size`, WAL sắp bị xoá | **báo động** — slot sắp chết |
| **`lost`** | WAL cần đã bị xoá | **slot hỏng vĩnh viễn**, phải tạo lại + snapshot lại |

`safe_wal_size` là "còn được phép tụt bao nhiêu nữa trước khi chết" — âm nghĩa là đã quá hạn. Đây là chỉ số alert tốt nhất vì nó cho **thời gian phản ứng**, không chỉ báo sau khi hỏng.

### Hệ quả khi slot bị `lost` — với Debezium

Không phải "kết nối lại là xong". Debezium phải:
1. Phát hiện slot không còn (thường bằng exception lúc connect).
2. **Tạo slot mới** — slot mới bắt đầu từ LSN hiện tại, tức **mọi thay đổi giữa lúc chết và lúc tạo lại đã mất vĩnh viễn**.
3. **Chạy snapshot lại** toàn bộ bảng để đồng bộ lại phía đích — trên bảng hàng trăm GB đó là hàng giờ, và snapshot lấy lock/tải nặng lên primary.
4. Consumer phía sau phải chịu được **duplicate** (snapshot phát lại mọi dòng) — tức pipeline phải idempotent.

**Nói cách khác: `max_slot_wal_keep_size` không phải "cấu hình tuỳ chọn", nó là chọn giữa hai kiểu sự cố** — mất CDC (phải re-snapshot) hay mất database (đầy đĩa, dừng ghi). Chọn cái đầu, luôn luôn.

### 🔧 Tình huống thực tế — staging bị xoá, production chết

Team dựng môi trường staging bằng cách clone production, có Debezium đọc CDC. Ba tháng sau staging bị dọn dẹp — namespace k8s bị xoá, Debezium biến mất. **Nhưng slot được tạo trên chính production** (vì staging đọc CDC từ production để có dữ liệu thật).

Không ai nhớ tới cái slot đó. `pg_wal` tăng ~3 GB/ngày. Đĩa 500 GB, dư 200 GB.

Ngày thứ 68: `PANIC: could not write to file "pg_wal/xlogtemp": No space left on device`. **Postgres dừng.** Và cứu chữa lúc đó rất khó: không xoá được WAL (slot còn giữ), không mở rộng đĩa ngay, không start được Postgres để chạy `pg_drop_replication_slot`.

Lối thoát duy nhất trong tình huống đó: dừng Postgres, xoá **thủ công** file trong `pg_wal` (cực kỳ nguy hiểm — sai một file là mất database), hoặc mount thêm đĩa và symlink. Cả hai đều là thao tác lúc 3 giờ sáng dưới áp lực.

Ba biện pháp, theo thứ tự ưu tiên:
1. **`max_slot_wal_keep_size`** — van an toàn tự động, đo được ở trên là nó hoạt động đúng như quảng cáo.
2. **Alert `wal_status <> 'reserved'`** — cho bạn hàng ngày để phản ứng, không phải hàng phút.
3. **Quy trình: slot phải có owner ghi trong tên.** `debezium_orders_prod`, `staging_clone_2025q1` — để 3 tháng sau còn biết ai tạo và hỏi được ai.

---

## §5. Logical replication thật: publication & `pgoutput`

```sql
CREATE PUBLICATION pub_demo FOR TABLE cdc_demo;
SELECT * FROM pg_publication_tables WHERE pubname='pub_demo';
-- pub_demo | public | cdc_demo | {id,name,qty} | (rowfilter null)
```

`pg_publication_tables` cho biết **chính xác cột nào** được publish (`attnames`) và có row filter không — PG15+ cho phép giới hạn cả hai:
```sql
CREATE PUBLICATION p FOR TABLE orders (id, status, amount) WHERE (status <> 'DRAFT');
```
Đây là cách rất hiệu quả để giảm WAL và giảm lộ dữ liệu: **đừng publish cột bạn không cần**, đặc biệt cột lớn và cột nhạy cảm.

### `pgoutput` vs `test_decoding`

Cùng một tập thay đổi (100 INSERT + 100 UPDATE):

| Plugin | Số bản ghi | Tổng byte |
|---|---|---|
| `pgoutput` (nhị phân) | 205 | **7.557** |
| `test_decoding` (text) | 206 | **17.081** |
| **Chênh** | | **`pgoutput` nhỏ hơn 55,8%** |

Hợp lý: `test_decoding` in ra `table public.cdc_demo: INSERT: id[integer]:1 name[text]:'a'` — kèm tên bảng, tên cột, tên kiểu, ở dạng text, cho **mỗi dòng**. `pgoutput` gửi schema **một lần** rồi chỉ gửi giá trị nhị phân.

> **`test_decoding` chỉ để debug.** Nó không phải plugin production — nó tốn 2,26× băng thông và consumer phải parse text. Mọi hệ thật dùng `pgoutput` (logical replication built-in, Debezium ≥ 1.x) hoặc `wal2json` (khi cần JSON và chấp nhận trả giá).

### Physical vs Logical — dòng nào quan trọng với hệ của bạn

| | Physical (Day 38) | Logical (hôm nay) |
|---|---|---|
| Đơn vị | byte của page | hàng dữ liệu |
| Phạm vi | **cả cluster** | **chọn từng bảng, từng cột, từng dòng** |
| Đích | phải cùng version, read-only | version khác được, **ghi được** |
| **DDL** | tự động theo | **KHÔNG theo** |
| Sequence | theo | **không theo** |
| Song song hoá replay | không (1 process) | có (theo bảng/transaction, PG16+) |

**Dòng quan trọng nhất cho hệ của bạn là "chọn từng bảng" + "đích ghi được".** Đó là thứ cho phép: đẩy read model của CQRS sang một database riêng, tách một service ra mà không copy cả cluster, hoặc migrate cross-version.

**Dòng nguy hiểm nhất là "DDL KHÔNG theo".** Đã thấy bằng mắt ở §2: `CREATE TABLE` cho ra một transaction rỗng. Kịch bản hỏng kinh điển:

```
1. Publisher: ALTER TABLE orders ADD COLUMN discount numeric NOT NULL DEFAULT 0;
2. Subscriber: không biết gì, vẫn có schema cũ
3. Publisher: INSERT INTO orders (..., discount) VALUES (..., 5);
4. Subscriber: ERROR — replication ĐỨNG HẲN, WAL bắt đầu tích tụ
5. → quay lại đúng §4
```

Quy trình bắt buộc (chính là expand/contract của Day 44):
- **Thêm cột**: chạy DDL ở **subscriber TRƯỚC**, publisher sau. Cột mới phải nullable hoặc có default.
- **Xoá cột**: publisher trước, subscriber sau.
- **Đổi kiểu**: không làm trực tiếp — thêm cột mới, backfill, chuyển đọc, xoá cột cũ.

---

## §6. Outbox vs CDC — đo bằng số

Cùng **10.000 sự kiện** `OrderPaid` / `OrderShipped` trên bảng `ob_order`.

### (a) Outbox: UPDATE + ghi event + poller xoá

| Câu lệnh | WAL | Thời gian |
|---|---|---|
| `UPDATE ob_order SET status='PAID'` | 2.948.297 B (2.879 kB) | 63 ms |
| `INSERT INTO outbox ... 10.000 dòng` | 2.064.212 B (2.016 kB) | 37 ms |
| `DELETE FROM outbox` (poller đã đẩy xong) | 680.000 B (664 kB) | 6 ms |
| **TỔNG** | **5.692.509 B (5.559 kB)** | **106 ms** |

### (b) CDC: chỉ UPDATE, sự kiện lấy từ WAL

| Câu lệnh | WAL | Thời gian | Sự kiện đọc được |
|---|---|---|---|
| `UPDATE ob_order SET status='SHIPPED'` | **3.116.324 B (3.043 kB)** | **77 ms** | **10.002** (10.000 + BEGIN + COMMIT) |

### Kết quả

| | Outbox | CDC | Chênh |
|---|---|---|---|
| **WAL** | 5.692.509 B | **3.116.324 B** | **1,83×** |
| **Thời gian** | 106 ms | **77 ms** | **1,38×** |
| Số lệnh phải chạy | 3 | **1** | |
| Sự kiện là gì | **domain event tự định nghĩa** | hàng thô (`status: PAID → SHIPPED`) | |
| Độ trễ | chu kỳ poll (thường 100 ms – 5 s) | **~ms** | |

### Và khoản đắt nhất không nằm trong bảng trên: bloat

Mô phỏng 5 chu kỳ poller (INSERT 10.000 → DELETE), `autovacuum_enabled = off`:

| Trạng thái | Số dòng sống | Kích thước bảng |
|---|---|---|
| Sau 1 chu kỳ INSERT+DELETE | 0 | 1.344 kB |
| Sau `VACUUM` | 0 | **264 kB** |
| **Sau 5 chu kỳ, chưa vacuum** | **0** | **4.304 kB** |

**Bảng outbox rỗng hoàn toàn nhưng chiếm 4.304 kB — gấp 16,3 lần kích thước sạch (264 kB).**

Đây là bản chất của outbox: nó là một cái **hàng đợi được cài đặt bằng bảng heap MVCC**, tức mọi dòng đi qua đều để lại một dead tuple. Ở tốc độ cao, autovacuum phải chạy **liên tục** trên bảng đó chỉ để giữ nó không phình. Và mỗi lần autovacuum chạy là thêm I/O, thêm WAL.

Cấu hình bắt buộc nếu dùng outbox ở tốc độ cao (Day 23):
```sql
ALTER TABLE outbox SET (
  autovacuum_vacuum_scale_factor = 0.0,
  autovacuum_vacuum_threshold = 1000,      -- vacuum sau mỗi 1.000 dòng chết, không đợi %
  autovacuum_vacuum_cost_delay = 0,        -- không throttle
  fillfactor = 70
);
```

### Bảng so sánh đầy đủ

| Tiêu chí | **Outbox + poller** | **CDC (logical decoding)** |
|---|---|---|
| WAL cho 10.000 sự kiện | 5.692.509 B | **3.116.324 B (1,83× ít hơn)** |
| Thời gian ghi | 106 ms | **77 ms** |
| Dead tuple để lại | **10.000/chu kỳ**, bloat 16,3× nếu vacuum không kịp | **0** |
| Độ trễ | chu kỳ poll | **~ms** |
| Sự kiện là gì | **domain event** (`OrderPaid` + payload bạn thiết kế) | hàng thô + before/after |
| Đảm bảo atomic | cùng transaction với business data | theo bản chất (đọc từ WAL) |
| Coupling schema | **không** — event là hợp đồng ổn định | **có** — consumer thấy cột thật, đổi cột là breaking change |
| Thứ tự | theo `id` bạn chọn | commit order |
| Rủi ro vận hành lớn nhất | bảng phình, autovacuum không kịp | **slot bỏ quên giết DB** (§4) |
| Cần gì thêm | không — chỉ SQL | `wal_level=logical` (**cần restart**), Debezium/Kafka Connect, giám sát slot |
| DDL | không ảnh hưởng | **phải phối hợp thủ công** (§5) |
| Nợ vận hành | nằm trong DB, team backend hiểu được | thêm một hệ phân tán để chạy và debug |

### Kết luận trung thực

**1,83× WAL không đủ để đổi kiến trúc.** Nếu bạn đang chạy outbox và nó hoạt động, con số này không phải lý do để migrate. Ba lý do *thật sự* đủ mạnh:

**Chọn CDC khi:**
- Cần độ trễ **~ms** (poller không đáp ứng được), hoặc
- Cần capture thay đổi từ code bạn **không sửa được** (legacy, third-party ghi thẳng vào DB), hoặc
- Volume đủ lớn để bloat của outbox trở thành vấn đề vận hành thật (đo: `n_dead_tup` của bảng outbox có bao giờ về gần 0 không).

**Giữ outbox khi:**
- **Event là hợp đồng, không phải row.** Đây là lý do mạnh nhất và mang tính kiến trúc: `OrderPaid{orderId, amount, paidAt}` ổn định qua mọi lần refactor bảng `orders`. Với CDC, đổi tên cột = breaking change cho mọi consumer. Với DDD/CQRS, đây gần như là lý do quyết định.
- **Không muốn thêm một hệ phân tán vào đường quan trọng.** Debezium + Kafka Connect + slot monitoring là ba thứ nữa phải vận hành, và §4 cho thấy chúng có thể giết database.
- **Một domain event ≠ một row change.** "Đơn hàng được thanh toán" có thể chạm 3 bảng; CDC phát ra 3 sự kiện thô mà consumer phải tự ghép lại. Outbox phát ra đúng một sự kiện.

**Với hệ của bạn (DDD/CQRS + Temporal): giữ outbox.** Điểm mạnh nhất của kiến trúc bạn đang có là event là **domain concept**, và đó chính là thứ CDC lấy đi. Nhưng hãy áp dụng ba việc từ hôm nay:
1. Cấu hình autovacuum riêng cho bảng outbox (ở trên) — bloat 16,3× là số đo thật.
2. Thay `DELETE` bằng **partition theo giờ + `DROP PARTITION`** (Day 33: 46 ms vs 8.876 ms, 0 dead tuple). **Đây là cải tiến lớn nhất có thể làm cho outbox mà không đổi kiến trúc.**
3. `LISTEN/NOTIFY` hoặc trigger để đánh thức poller thay vì poll theo chu kỳ — giảm độ trễ về gần CDC mà không cần CDC.

---

## §7. Giám sát — 5 dòng phải có trên dashboard

```sql
-- ===== 1. Slot không active và đang giữ WAL =====
SELECT slot_name, plugin, slot_type, active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_giu,
       now() - COALESCE(active_since, '-infinity') AS khong_active_bao_lau
FROM pg_replication_slots
WHERE NOT active
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC;
-- ALERT: NOT active VÀ wal_giu > 5 GB  → page
--        NOT active > 1 giờ            → warning

-- ===== 2. Tổng pg_wal so với max_wal_size =====
SELECT pg_size_pretty(sum(size)) AS pg_wal,
       current_setting('max_wal_size') AS max_wal_size,
       round(100.0 * sum(size) / (pg_size_bytes(current_setting('max_wal_size'))), 1) AS pct
FROM pg_ls_waldir();
-- ALERT: pct > 300%  → warning (có thứ gì đang giữ WAL)
--        pct > 500%  → page

-- ===== 3. Slot có wal_status khác 'reserved' =====
SELECT slot_name, wal_status, pg_size_pretty(safe_wal_size) AS con_du_truoc_khi_chet
FROM pg_replication_slots WHERE wal_status <> 'reserved';
-- ALERT: 'extended'   → warning
--        'unreserved' → page (slot sắp chết)
--        'lost'       → page (CDC đã hỏng, phải re-snapshot)

-- ===== 4. Độ trễ logical: consumer tụt sau bao nhiêu =====
SELECT slot_name,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS tre_byte,
       pg_size_pretty(pg_wal_lsn_diff(confirmed_flush_lsn, restart_lsn))          AS chua_xac_nhan
FROM pg_replication_slots WHERE slot_type = 'logical';
-- ALERT: tre_byte > 1 GB  → warning (consumer không theo kịp)
--        tăng đều 10 phút liên tiếp → page

-- ===== 5. (outbox) tồn đọng + tuổi dòng cũ nhất =====
SELECT count(*) AS ton_dong,
       now() - min(created_at) AS tuoi_dong_cu_nhat,
       (SELECT n_dead_tup FROM pg_stat_user_tables WHERE relname='outbox') AS dead_tup,
       pg_size_pretty(pg_total_relation_size('outbox')) AS size
FROM outbox;
-- ALERT: tuoi_dong_cu_nhat > 60 s   → page (poller chết)
--        ton_dong > 100.000         → warning
--        dead_tup > 500.000         → warning (autovacuum không kịp — xem §6)
```

**Chỉ số quan trọng nhất và ít ai theo dõi nhất là #3 (`wal_status`)** — vì nó cho bạn cảnh báo *trước* khi hỏng, còn #2 chỉ báo khi đĩa đã gần đầy.

Bổ sung liên quan tới Day 38 — **logical slot cũng giữ `xmin` và chặn `VACUUM` trên toàn database**:
```sql
SELECT slot_name, xmin, catalog_xmin, age(catalog_xmin) AS tuoi
FROM pg_replication_slots WHERE catalog_xmin IS NOT NULL;
-- ALERT: age > 50.000.000 → warning
```

---

## Bảng số liệu chính

| Phép đo | Kết quả |
|---|---|
| `wal_level` context | **`postmaster`** — bật CDC cần **restart** |
| `peek` × 2 lần | 12 / **12 bản ghi** (không consume) |
| `get` × 2 lần | 12 / **0 bản ghi** (consume) |
| `CREATE TABLE` trong slot | **transaction RỖNG** — DDL không được decode |
| **Thứ tự phát ra** | **commit order** — xid 2768099 (bắt đầu sau) ra **trước** xid 2768098 |
| Bảng không PK — `DELETE` | **`(no-tuple-data)`** — rỗng hoàn toàn |
| Bảng không PK + publication — `UPDATE` | **`ERROR: cannot update table ... does not have a replica identity`** |
| `REPLICA IDENTITY DEFAULT` — `UPDATE` | chỉ giá trị mới |
| `REPLICA IDENTITY FULL` — `UPDATE` | **`old-key: ... new-tuple: ...`** (before + after) |
| **WAL: `DEFAULT` vs `FULL`** (100k dòng, pad 200B) | 68.567.204 vs **90.767.204 B = +32,4%** |
| — chênh trên mỗi dòng | **222 byte** (= đúng kích thước dòng cũ) |
| — `wal_records` / `wal_fpi` | **giống hệt** (301.366 / 3.306) — chỉ record to hơn |
| **`pgoutput` vs `test_decoding`** | 7.557 vs 17.081 byte — **`pgoutput` nhỏ hơn 55,8%** |
| Slot bỏ quên sau 1M dòng | giữ **446 MB** |
| Slot bỏ quên sau 3M dòng | giữ **1.278 MB**, `pg_wal` **1.024 → 1.296 MB** |
| `CHECKPOINT` × 4 | **không giải phóng được byte nào** |
| `max_slot_wal_keep_size='64MB'` | `extended` → **`unreserved`** (`safe_wal_size = −1.208 MB`) → **`lost`** |
| `pg_wal` sau khi slot bị `lost` | **1.296 → 928 MB** |
| Đọc slot `lost` | **`ERROR: can no longer get changes ... invalidated because it exceeded the maximum reserved size`** |
| **Outbox, 10.000 sự kiện** | UPDATE 2.948.297 + INSERT 2.064.212 + DELETE 680.000 = **5.692.509 B**, 106 ms |
| **CDC, 10.000 sự kiện** | **3.116.324 B**, 77 ms, **10.002 sự kiện đọc được** |
| **Chênh** | **WAL 1,83× · thời gian 1,38×** |
| **Bloat outbox** sau 5 chu kỳ, 0 dòng sống | **4.304 kB** vs 264 kB sạch — **16,3×** |

---

## Ba điều dễ hiểu sai

| Hiểu nhầm | Sự thật đo được |
|---|---|
| "`max_wal_size` giới hạn dung lượng `pg_wal`." | `max_wal_size = 1GB` nhưng `pg_wal` đạt **1.296 MB** và `CHECKPOINT` chạy 4 lần **không giải phóng được byte nào** — vì slot giữ. `max_wal_size` chỉ là **mục tiêu cho nhịp checkpoint**, không phải trần cứng. Van duy nhất là `max_slot_wal_keep_size`, và **mặc định của nó là `-1` = vô hạn**. |
| "CDC cho tôi thấy dòng trước và sau khi đổi." | Mặc định (`REPLICA IDENTITY DEFAULT`) **chỉ thấy giá trị mới**; `DELETE` chỉ thấy PK; bảng **không có PK** thì `DELETE` là `(no-tuple-data)` — và `UPDATE` **lỗi hẳn** khi bảng nằm trong publication. Muốn before-image phải `REPLICA IDENTITY FULL`, giá là **+32,4% WAL** ở lab (dòng 222 byte) và **tăng theo độ rộng dòng** — với dòng 2 KB có thể là +300%. |
| "Outbox tốn gấp nhiều lần CDC nên phải đổi sang CDC." | Chỉ **1,83× WAL** và **1,38× thời gian** — không đủ để đổi kiến trúc. Khoản đắt thật là **bloat 16,3×** (bảng rỗng chiếm 4.304 kB thay vì 264 kB), và cái đó sửa được bằng autovacuum tuning + partition theo giờ + `DROP PARTITION` (Day 33: 46 ms, 0 dead tuple). Đổi lại, CDC mang về một rủi ro **giết database** mà outbox không có. Lý do đúng để chọn CDC là **độ trễ** và **không sửa được code nguồn**, không phải WAL. |

---

## Áp dụng vào hệ thật

1. **Chạy ngay trên production (chỉ đọc, 10 giây):**
   ```sql
   SELECT slot_name, plugin, slot_type, active, wal_status,
          pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_giu,
          pg_size_pretty(safe_wal_size) AS con_du
   FROM pg_replication_slots;
   ```
   Có slot nào `active = false`? `wal_status <> 'reserved'`? Đó là quả bom đang đếm ngược.

2. **Đặt `max_slot_wal_keep_size` hôm nay** (10–20% dung lượng `pg_wal`). Đo được ở §4 là nó hoạt động đúng: hy sinh slot, giải phóng WAL, database sống. Chấp nhận trước rằng slot bị `lost` ⇒ Debezium phải re-snapshot — và đảm bảo pipeline của bạn **idempotent** để chịu được duplicate từ snapshot.

3. **Rà bảng không có PK trước khi đụng vào CDC:**
   ```sql
   SELECT n.nspname, c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE c.relkind='r' AND n.nspname NOT IN ('pg_catalog','information_schema')
     AND c.relreplident='d'
     AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid=c.oid AND i.indisprimary);
   ```
   Thêm bảng như thế vào publication ⇒ **`UPDATE` lỗi ngay lập tức**. Đây là cách bật CDC làm sập production.

4. **Đừng bật `REPLICA IDENTITY FULL` toàn cục.** Bật đúng bảng cần before-image, và ưu tiên hai lối thoát rẻ hơn: `USING INDEX` trên unique index hẹp, hoặc ghi before-image của **vài cột cần thiết** vào outbox. Đo trước bằng `pg_stat_statements.wal_bytes` như §3.

5. **Giữ outbox, nhưng sửa ba thứ:**
   ```sql
   -- (a) autovacuum riêng — bloat đo được 16,3×
   ALTER TABLE outbox SET (autovacuum_vacuum_scale_factor = 0.0,
                           autovacuum_vacuum_threshold = 1000,
                           autovacuum_vacuum_cost_delay = 0, fillfactor = 70);
   ```
   (b) **Partition outbox theo giờ và `DROP PARTITION` thay cho `DELETE`** — Day 33 đo được 46 ms vs 8.876 ms, 0 dead tuple. Đây là cải tiến lớn nhất có thể làm mà không đổi kiến trúc.
   (c) `LISTEN/NOTIFY` đánh thức poller thay vì poll theo chu kỳ — độ trễ về gần CDC mà không cần CDC.

6. **Nếu vẫn muốn CDC: dùng `pgoutput`, không dùng `test_decoding`** (nhỏ hơn 55,8%), và **publish có chọn lọc**:
   ```sql
   CREATE PUBLICATION p FOR TABLE orders (id, status, amount) WHERE (status <> 'DRAFT');
   ```
   Đừng publish cột lớn và cột nhạy cảm bạn không cần.

7. **Đặt quy trình DDL cho logical replication** (§5): thêm cột ⇒ subscriber **trước**; xoá cột ⇒ publisher trước; đổi kiểu ⇒ expand/contract (Day 44). Đây là nguyên nhân số một làm logical replication đứng, và khi nó đứng thì bạn quay lại đúng §4.

8. **Đặt tên slot có owner:** `debezium_orders_prod`, `staging_clone_2025q1`. Ba tháng sau bạn sẽ cần biết ai tạo nó và hỏi được ai trước khi xoá.

---

## Câu hỏi mở sang các ngày sau

- **Day 40 (wait events)** khép lại tuần 8: khi slot làm `pg_wal` phình và checkpoint dồn dập, backend chờ **cái gì** — `WALWrite`, `WALSync`, hay `LogicalDecoding`? Đó là cách phân biệt "CDC đang tốn tài nguyên" với "I/O nghẽn vì lý do khác".
- **Day 33 (partition)** áp thẳng vào §6: partition bảng `outbox` theo giờ + `DROP PARTITION` biến khoản bloat 16,3× thành 0. Đây là bài tập đáng làm ngay trong tuần này.
- **Day 44 (expand/contract)** là lời giải cho vấn đề DDL của §5 — cùng một quy trình dùng cho logical replication, cho blue-green deploy, và cho migration không downtime. Ba bài toán, một mẫu.
- **Day 22–25 (vacuum)** nối với §7: **logical slot giữ `catalog_xmin`** và chặn `VACUUM` trên toàn database, giống hệt `hot_standby_feedback` của Day 38 §5. Đây là nguồn thứ tư chặn vacuum, sau transaction dài, physical slot, và replica feedback — và cũng là nguồn khó nhìn ra nhất.
- **Câu hỏi mở thật sự:** logical decoding phát ra theo **commit order**, nên một transaction 10 phút chặn toàn bộ stream 10 phút. PG14+ có `streaming = on` (phát ra thay đổi của transaction *đang chạy*) — nhưng consumer phải xử lý được trường hợp transaction đó `ROLLBACK`. Đánh đổi đó có đáng không, và Debezium xử lý nó thế nào?

---

### Dọn dẹp

```sql
SELECT pg_drop_replication_slot('order_slot');
DROP PUBLICATION pub_demo; DROP PUBLICATION pub_order;
DROP TABLE cdc_demo, cdc_nopk, ri_def, ri_full, ob_order, outbox;
DELETE FROM ts_kv WHERE ts > '2025-12-01';
VACUUM ts_kv;
ALTER SYSTEM RESET max_slot_wal_keep_size;
SELECT pg_reload_conf();
```

> **Quan trọng:** đừng bỏ sót `pg_drop_replication_slot`. Quên là lab của bạn giữ WAL mãi — và đó đúng là bài học §4. Kiểm tra lại bằng `SELECT * FROM pg_replication_slots;` phải trả về 0 dòng.
