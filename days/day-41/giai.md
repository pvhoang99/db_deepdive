# Day 41 — Lời giải: TOAST — chuyện gì xảy ra khi một dòng không vừa 8KB

> Bài chữa. Đo thật trên lab (Postgres 17, `default_toast_compression = pglz`). Day 21 nhìn tuple trong page; hôm nay trả lời câu hỏi còn treo: `jsonb` 200 KB nằm ở đâu.
>
> Kết luận một câu: **lọc theo một field jsonb trên bảng bị TOAST tốn 150.473 buffer và 473 ms, so với 516 buffer và 5,7 ms nếu field đó là cột thật — 292× buffer, 83× thời gian.**

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án đo được | Bẫy |
|---|---|---|---|
| 1 | Dòng có cột `text` 100 KB chiếm bao nhiêu byte trong page chính? | **Tuỳ dữ liệu có nén được không.** `repeat('d', 100000)`: nén còn **1.156 byte** ⇒ **nằm nguyên trong page chính, KHÔNG bị đẩy ra TOAST**. Dữ liệu ngẫu nhiên 9.600 byte: **bị đẩy ra**, page chính chỉ giữ con trỏ 18 byte. | Bẫy lớn: **ngưỡng 2 KB áp lên độ dài SAU NÉN, không phải độ dài gốc.** Một giá trị 100 KB có thể không bao giờ chạm TOAST. |
| 2 | `SELECT id` trên bảng có cột 100 KB — có đọc 100 KB đó không? | **Không.** `SELECT id` → Index Only Scan, **10 buffer**, 0,400 ms. `sum(length(note))` (phải de-TOAST) → **28,5 ms** so với `sum(id)` → **0,43 ms** — **71×**. | Nhưng `EXPLAIN (ANALYZE)` **không** de-TOAST vì nó không gửi dữ liệu về client — nên plan của `SELECT id, note` trông rẻ y hệt. Đo bằng `\timing` với hàm ép đọc giá trị mới thấy. |
| 3 | `pg_relation_size` có tính TOAST không? | **KHÔNG.** `tu`: `pg_relation_size` = **3.536 kB**, TOAST = **313 MB**, `pg_total_relation_size` = 317 MB. **Bảng "3,5 MB" thật ra tốn 317 MB.** | Đây là nguồn báo cáo dung lượng sai phổ biến nhất. Xếp hạng bảng bằng `pg_relation_size` sẽ **giấu mất** đúng những bảng tốn đĩa nhất. |
| 4 | `UPDATE t SET counter = counter+1` (không đụng cột lớn) — có ghi lại phần TOAST không? | **Không** — 6.257.330 byte WAL, 91 ms. Đụng cột TOAST: **279.268.045 byte (266 MB), 4.107 ms** — **44,6× WAL, 45× thời gian**. | Bẫy: người ta tưởng "chỉ thêm 1 ký tự vào cuối chuỗi thì rẻ". Không có UPDATE tại chỗ cho TOAST — **toàn bộ chuỗi chunk được ghi lại từ đầu**. |

---

## §1. Vì sao TOAST tồn tại

Postgres không cho một tuple nằm vắt qua nhiều page. Page = 8 KB ⇒ tuple tối đa ~8 KB. Nhưng `text`/`jsonb`/`bytea` có thể tới 1 GB.

Khi tuple vượt **`TOAST_TUPLE_THRESHOLD` ≈ 2 KB**, Postgres lần lượt:
1. **Nén** các cột lớn (nếu strategy cho phép),
2. Nếu vẫn > 2 KB → **đẩy ra ngoài**: cắt thành chunk ~1.996 byte, lưu vào bảng `pg_toast.pg_toast_<oid>` có index riêng,
3. Trong tuple chính chỉ còn **con trỏ 18 byte** (`varatt_external`).

### Strategy của `device`

| Cột | Kiểu | Strategy |
|---|---|---|
| `id`, `tenant_id`, `is_active`, `created_at` | bigint/int/bool/timestamptz | **`PLAIN`** |
| `uuid` | uuid | **`PLAIN`** |
| `name`, `type`, `region`, `country`, `firmware` | text | `EXTENDED` |
| `meta` | jsonb | `EXTENDED` |

`PLAIN` cho kiểu độ dài cố định — chúng **không bao giờ** bị nén hay đẩy ra ngoài (không có gì để nén, và độ dài đã biết trước).

### Bốn strategy

| Strategy | Nén | Đẩy ra ngoài | Dùng cho |
|---|---|---|---|
| `PLAIN` | không | không | kiểu độ dài cố định |
| **`EXTENDED`** | **có** | **có** | mặc định của `text`, `jsonb`, `bytea` |
| `EXTERNAL` | **không** | có | dữ liệu đã nén sẵn (ảnh, gzip); hoặc cần `substring()` đọc tiền tố nhanh |
| `MAIN` | có | chỉ khi bất khả kháng | giá trị vừa phải, muốn giữ trong bảng chính |

### Bảng của lab: có TOAST table nhưng RỖNG

| Bảng | TOAST table | main | **TOAST** |
|---|---|---|---|
| `alarm` | `pg_toast_58883` | 29 MB | **0 bytes** |
| `device` | `pg_toast_58864` | 9.656 kB | **0 bytes** |
| `device_attr` | `pg_toast_58871` | 6.752 kB | **0 bytes** |
| `ts_kv` | `pg_toast_58878` | 289 MB | **0 bytes** |

**Cả bốn bảng đều CÓ TOAST table nhưng không dùng byte nào.** Postgres tạo TOAST table cho mọi bảng có ít nhất một cột khả-TOAST (`text`, `jsonb`...), bất kể có dùng hay không. `device.meta` chỉ ~78 byte (Day 34) nên không bao giờ chạm ngưỡng.

Đây là lý do bảng ở lab không tự nhiên thể hiện được TOAST — phải dựng dữ liệu riêng.

---

## §2. Nhìn ngưỡng 2 KB bằng mắt

### `toast_lab` — dữ liệu lặp, nén cực tốt

| id | Độ dài thật | `pg_column_size` | % sau nén | Bị đẩy ra TOAST? |
|---|---|---|---|---|
| 1 | 100 | **101** | 101,0% | không |
| 1001 | 1.500 | **1.504** | **100,27%** | không |
| 2001 | 5.000 | **69** | **1,38%** | không |
| 3001 | **100.000** | **1.156** | **1,16%** | **KHÔNG** |

```
main = 3.096 kB · TOAST = 0 bytes · giá trị bị đẩy ra = 0 · số chunk = 0
```

**Giá trị 100.000 byte — lớn gấp 50 lần ngưỡng — KHÔNG bị đẩy ra TOAST.**

Vì `repeat('d', 100000)` là 100.000 ký tự giống hệt nhau ⇒ pglz nén còn **1.156 byte** ⇒ tuple sau nén vẫn dưới 2 KB ⇒ không cần đẩy ra.

> **Ngưỡng 2 KB áp lên độ dài SAU NÉN, không phải độ dài gốc.** Đây là đáp án cho câu hỏi chính của §2.

Chi tiết tinh tế ở dòng thứ hai: **1.500 byte 'b' lưu thành 1.504 byte (100,27%) — KHÔNG hề được nén**, dù nó nén được y hệt như 5.000 byte 'c' (còn 1,38%). Lý do: Postgres chỉ **thử nén khi tuple vượt ngưỡng**. Tuple 1.500 byte đã vừa page ⇒ không tốn CPU nén làm gì. Tuple 5.000 byte vượt ngưỡng ⇒ nén ⇒ còn 69 byte ⇒ vừa rồi ⇒ khỏi đẩy ra.

Con số 101 và 1.504 (lớn hơn gốc 1–4 byte) là **header varlena** — mọi giá trị độ dài thay đổi đều mang 1 hoặc 4 byte header.

### `toast_rand` — dữ liệu ngẫu nhiên, không nén được

| id | Độ dài thật | `pg_column_size` | % sau nén | Bị đẩy ra? |
|---|---|---|---|---|
| 1 | 1.920 | **1.924** | 100,2% | không |
| 1001 | **9.600** | **9.600** | **100,0%** | **có** |

```
main = 2.000 kB · TOAST = 10.000 kB
giá trị bị đẩy ra = 1.000 · số chunk = 5.000 · trung bình 5,0 chunk/giá trị
```

md5 ngẫu nhiên **hoàn toàn không nén được** (100,0%). Giá trị 9.600 byte vượt ngưỡng ⇒ bị cắt thành chunk.

Kiểm chứng số học: **9.600 / 1.996 = 4,81 ⇒ 5 chunk.** Đo được đúng **5,0 chunk/giá trị**. Lý thuyết và thực nghiệm khớp hoàn hảo.

Và TOAST table (10.000 kB) lớn gấp 5 lần bảng chính (2.000 kB) — bảng chính giờ chỉ chứa `id` + con trỏ.

### Bẫy đo lường: `pg_column_size` không cho biết có bị TOAST hay không

`pg_column_size` trả về **kích thước đã nén của giá trị**, không phải 18 byte con trỏ. Nên nó không phân biệt được "nằm trong page chính" với "nằm ngoài TOAST". Cách duy nhất chắc chắn là đếm thẳng trong bảng TOAST:

```sql
SELECT reltoastrelid::regclass AS tt FROM pg_class WHERE relname='ten_bang' \gset
SELECT count(DISTINCT chunk_id) AS gia_tri_bi_day_ra, count(*) AS so_chunk FROM :tt;
```

---

## §3. `SELECT *` vs `SELECT cột nhỏ`

| Query | Plan | Buffers | Execution |
|---|---|---|---|
| `SELECT id FROM toast_rand` | **Index Only Scan** | **10** | 0,400 ms |
| `SELECT id, note FROM toast_rand` | Seq Scan | 250 | 0,398 ms |
| `SELECT count(*) WHERE octet_length(note) > 1000` | Seq Scan | 250 | 0,455 ms |

**Hai điều bất ngờ ở đây, cả hai đều là bài học về phương pháp đo:**

**a) `EXPLAIN (ANALYZE, BUFFERS)` của `SELECT id, note` KHÔNG đắt hơn — vì nó không de-TOAST.**

`EXPLAIN ANALYZE` chạy query nhưng **vứt bỏ kết quả**, không gửi về client. Việc de-TOAST xảy ra lúc **serialize dữ liệu ra**, nên nó không xảy ra. Plan cho thấy 250 buffer — đó là bảng chính, không có TOAST.

> **Với bảng có cột TOAST, `EXPLAIN ANALYZE` nói dối về chi phí thật.** Muốn đo đúng phải ép đọc giá trị:

```sql
SELECT sum(length(note)) FROM toast_rand;   -- 28,5 ms / 27,2 ms  ← phải de-TOAST hết
SELECT sum(id)           FROM toast_rand;   --  0,43 ms /  0,36 ms
```

**71× chênh lệch** — đây mới là con số thật của `SELECT *` so với `SELECT id`.

(PG16+ có `EXPLAIN (ANALYZE, SERIALIZE)` để tính cả phần này — nếu server của bạn ≥ 16 thì dùng nó.)

**b) `octet_length(note) > 1000` chỉ mất 250 buffer và 0,455 ms — không de-TOAST.**

`octet_length()` đọc được độ dài từ **header varlena** mà không cần nạp nội dung. Cùng nhóm: `length()` trên `text` thì **phải** de-TOAST (vì phải đếm ký tự UTF-8), nhưng `octet_length()` thì không.

Đây là một tối ưu nhỏ nhưng hữu ích: lọc "document có lớn bất thường không" bằng `octet_length` gần như miễn phí.

---

## §4. Nén: `pglz` vs `lz4`

20.000 document jsonb, mỗi cái ~11 KB thô (300 phần tử `readings`), nạp **độc lập** cho từng bảng.

> **Bẫy đã vấp và phải sửa:** lần chạy đầu tôi làm `INSERT INTO cmp_lz4 SELECT * FROM cmp_pglz` — kết quả hai bảng **giống hệt nhau** (1.206 byte/dòng). Vì giá trị đã nén được copy nguyên trạng, không nén lại. **Cùng lý do, `ALTER TABLE ... SET COMPRESSION lz4` KHÔNG nén lại dữ liệu cũ** — chỉ áp dụng cho dữ liệu ghi mới. Muốn đổi hết phải `VACUUM FULL` hoặc rewrite bảng.

| | `pglz` | `lz4` | Chênh |
|---|---|---|---|
| **TOAST** | **104 MB** (109.232.128 B) | **117 MB** (122.880.000 B) | lz4 **+12,5%** |
| Kích thước TB/giá trị | **4.964 B** (44,4% của 11.176 gốc) | 5.751 B (51,5%) | |
| **Thời gian INSERT 20.000 dòng** | **7.216,7 ms** | **2.519,1 ms** | **lz4 nhanh 2,86×** |
| **Đọc + de-TOAST** (`WHERE j->>'model'=...`) | **294,7 / 304,9 ms** | **152,8 / 152,8 ms** | **lz4 nhanh 1,95×** |
| Đọc cột nhỏ (`sum(id)`) | 1,38 ms | 1,29 ms | như nhau |

**Đánh đổi rất rõ: lz4 tốn thêm 12,5% dung lượng, đổi lại ghi nhanh 2,86× và đọc nhanh 1,95×.**

Với dữ liệu jsonb đọc nhiều, đây gần như luôn là đánh đổi đúng — vì chi phí **giải nén** nằm trên đường đọc nóng, còn 12,5% dung lượng là tiền đĩa (rẻ).

Dòng cuối cũng quan trọng: `sum(id)` mất 1,3 ms ở **cả hai** — xác nhận lại §3, đọc cột nhỏ không đụng TOAST nên thuật toán nén không liên quan.

### Chọn thế nào

| Tình huống | Chọn |
|---|---|
| jsonb/text đọc nhiều, latency quan trọng | **`lz4`** |
| Dữ liệu lưu trữ, ít đọc, đĩa đắt | `pglz` (hoặc `zstd` nếu build có) |
| Blob đã nén sẵn (ảnh, gzip, protobuf) | **`EXTERNAL`** — nén lại chỉ tốn CPU vô ích |

```sql
-- kiểm tra build có lz4 không
ALTER TABLE t ALTER COLUMN c SET COMPRESSION lz4;   -- lỗi ⇒ build không có
-- đổi mặc định cho dữ liệu mới
ALTER SYSTEM SET default_toast_compression = 'lz4';
-- kiểm tra thuật toán của giá trị cụ thể
SELECT pg_column_compression(j) FROM cmp_lz4 LIMIT 1;   -- 'lz4' / 'pglz' / NULL (không nén)
```

**Với `device.meta` của hệ thật: chọn `lz4`.** Nó là metadata đọc trên gần như mọi request, và 12,5% của một cột metadata là số tuyệt đối rất nhỏ.

---

## §5. TOAST + jsonb — vì sao `meta->>'model'` đắt hơn bạn tưởng

`jsonb` là **một giá trị duy nhất**. Muốn lấy `meta->>'model'` (6 byte), Postgres phải: (1) đọc **toàn bộ** chuỗi chunk TOAST của dòng đó, (2) **giải nén toàn bộ**, (3) rồi mới parse ra field. **Không có "đọc một field"** — TOAST không hiểu jsonb.

Hai bảng: `dev_fat` (meta phình ~4,2 KB) và `dev_thin` (thêm cột thật `model`).

| Bảng | main | **TOAST** | % TOAST |
|---|---|---|---|
| `dev_fat` | 3.784 kB | **195 MB** | **96,9%** |
| `dev_thin` | 4.128 kB | 195 MB | 96,7% |

`meta` trung bình: 4.220 byte gốc → **3.294 byte** sau nén (78% — jsonb có md5 ngẫu nhiên nên nén kém).

### Bảng 4 dòng

| Cách | Index | Plan | **Buffers** | **Execution** |
|---|---|---|---|---|
| `dev_fat WHERE meta->>'model'='TH-100'` | không | Seq Scan | **150.473** | **473,6 ms** |
| `dev_thin WHERE model='TH-100'` | không | Seq Scan | **516** | **5,7 ms** |
| `dev_fat` | expression index | Bitmap Heap Scan | **485** | **2,77 ms** |
| `dev_thin` | B-tree | **Index Only Scan** | **13** | **1,41 ms** |

**Không index: 292× buffer, 83× thời gian.** 150.473 buffer đó **chính là bảng TOAST** — Postgres phải de-TOAST cả 50.000 document 3,3 KB chỉ để đọc 6 ký tự từ mỗi cái.

> Lưu ý so với §3: ở đây `EXPLAIN ANALYZE` **có** đếm buffer TOAST, vì việc de-TOAST xảy ra **trong lúc đánh giá vị từ** (bên trong plan), không phải lúc serialize kết quả. Đây là cách phân biệt: de-TOAST trong `WHERE`/`GROUP BY` **có** hiện trong plan; de-TOAST để trả về client thì **không**.

### Câu hỏi chính: có expression index rồi thì còn de-TOAST không?

**Lọc: KHÔNG.** `dev_fat` với expression index chỉ mất **485 buffer / 2,77 ms** — index đã chứa sẵn giá trị `meta->>'model'`, `Bitmap Heap Scan` chỉ cần đọc heap để kiểm tra visibility (473 block của bảng chính), **không chạm TOAST**. Từ 150.473 xuống 485 buffer — **310×**.

**Lấy giá trị ra: CÓ.**

```sql
SELECT id, meta->>'model' FROM dev_fat WHERE meta->>'model' = 'TH-100';
-- Bitmap Heap Scan, Heap Blocks: exact=473
-- Buffers: shared hit=37820          ← 37.820 buffer!
-- Execution Time: 124,024 ms
```

**Index tìm ra 12.445 dòng chỉ mất 12 buffer, nhưng LẤY giá trị `model` ra tốn thêm 37.808 buffer và 121 ms** — vì phải de-TOAST đủ 12.445 document. So với `SELECT id, model FROM dev_thin`: **0,941 ms**.

> **Kết luận quan trọng nhất của §5: expression index cứu được phần LỌC, nhưng không cứu được phần TRẢ VỀ.** Nếu query của bạn vừa lọc vừa hiển thị field đó (mà API nào cũng thế), bạn vẫn trả giá đầy đủ. **Chỉ tách cột thật mới giải quyết được cả hai** — 124 ms → 0,94 ms, **132×**.

Đây là lập luận định lượng còn thiếu ở Day 34: *"field nào trong jsonb nên tách thành cột thật?"* → **field nào xuất hiện trong `SELECT` hoặc `WHERE` của query nóng, trên bảng có document > 2 KB.**

---

## §6. TOAST gặp MVCC — cái giá của UPDATE

Bảng `tu`: 20.000 dòng, cột `big` ~6,4 KB ngẫu nhiên (không nén được). TOAST ban đầu **156 MB**.

| UPDATE | WAL | Thời gian |
|---|---|---|
| `SET counter = counter + 1` (**không** đụng TOAST) | **6.257.330 B (6.111 kB)** | **91 ms** |
| `SET big = big \|\| 'x'` (**có** đụng TOAST) | **279.268.045 B (266 MB)** | **4.107 ms** |
| **Chênh** | **44,6×** | **45,1×** |

**Thêm đúng MỘT ký tự vào cuối chuỗi tốn 266 MB WAL.**

Vì **không có UPDATE tại chỗ cho TOAST**. Giá trị TOAST là bất biến: sửa một byte ⇒ ghi **toàn bộ chuỗi chunk mới** (20.000 × 6,4 KB ≈ 128 MB dữ liệu) + WAL cho chúng + chunk cũ thành dead.

TOAST table: **156 MB → 313 MB** — gấp đôi sau một lệnh.

### HOT gần như bằng 0

```sql
SELECT n_tup_upd, n_tup_hot_upd FROM pg_stat_user_tables WHERE relname='tu';
-- 40000 | 7   →  0,0%
```

**7 HOT update trên 40.000.** So với `tu_small` (dòng 1 byte): cũng **0%** — nên phần này cần nói cho chính xác.

Nguyên nhân **chính** ở cả hai bảng là `fillfactor = 100` (mặc định): sau khi `INSERT` tuần tự, page đầy, không còn chỗ cho phiên bản mới trong cùng page ⇒ mất HOT (điều kiện 2 của Day 24).

Nhưng dòng lớn **làm vấn đề tệ hơn nhiều** ở một khía cạnh khác: bảng chính của `tu` phình từ **1.184 kB → 3.536 kB (3×)** sau hai lệnh UPDATE, vì mỗi tuple mới cần cả một page mới. Với dòng nhỏ, cùng số update chỉ tốn một phần nhỏ.

Cách sửa cho bảng có cột lớn bị update thường xuyên:
```sql
ALTER TABLE tu SET (fillfactor = 70);   -- chừa chỗ cho phiên bản mới trong cùng page
```
Nhưng cách tốt hơn nhiều: **tách cột lớn sang bảng riêng 1-1** — xem §7.

### Bảng TOAST cũng bloat, và `VACUUM` cũng không trả đĩa

```sql
SELECT * FROM pgstattuple('pg_toast.pg_toast_XXXXX');
```

| | Trước `VACUUM` | Sau `VACUUM` |
|---|---|---|
| `table_len` | **327.680.000** (313 MB) | **313 MB — không đổi** |
| `tuple_count` (chunk sống) | 80.000 | 80.000 |
| **`dead_tuple_count`** | **80.000** | **0** |
| `dead_tuple_percent` | **39,94%** | 0% |
| `free_percent` | 19,53% | **59,55%** |

**Đúng 50% chunk là rác** (80.000 sống / 80.000 chết) sau một lệnh UPDATE. `VACUUM` dọn sạch dead tuple nhưng **kích thước vẫn 313 MB** — free space lên 59,55% nhưng không trả về OS. Cùng bài học Day 33 §1 và Day 38 §5, lần này ở bảng TOAST.

**Ai dọn bảng TOAST?** Autovacuum **có** xử lý nó, nhưng nó có **ngưỡng riêng** dựa trên số dòng của **bảng TOAST**, không phải bảng chính. Với `pg_toast` bạn không đặt được `ALTER TABLE ... SET (autovacuum_*)` trực tiếp — phải qua tuỳ chọn `toast.*` trên bảng chính:

```sql
ALTER TABLE tu SET (toast.autovacuum_vacuum_scale_factor = 0.05,
                    toast.autovacuum_vacuum_threshold = 10000);
```

Ít người biết tuỳ chọn này, và đó là lý do bảng TOAST thường là nơi bloat trốn được lâu nhất.

---

## §7. Quy tắc rút ra

### Xếp hạng TOAST toàn database

```sql
SELECT c.relname,
       pg_size_pretty(pg_relation_size(c.oid))           AS main,
       pg_size_pretty(pg_relation_size(c.reltoastrelid)) AS toast,
       round(100.0*pg_relation_size(c.reltoastrelid)/nullif(pg_total_relation_size(c.oid),0),1) AS pct_toast
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE c.relkind='r' AND n.nspname='public' AND c.reltoastrelid<>0
  AND pg_relation_size(c.reltoastrelid) > 0
ORDER BY pg_relation_size(c.reltoastrelid) DESC;
```

| relname | main | toast | **pct_toast** |
|---|---|---|---|
| `tu` | 3.536 kB | **313 MB** | **97,4%** |
| `dev_fat` | 3.784 kB | 195 MB | 96,9% |
| `dev_thin` | 4.128 kB | 195 MB | 96,7% |
| `cmp_lz4` | 1.024 kB | 117 MB | **98,0%** |
| `cmp_pglz` | 1.024 kB | 104 MB | 97,8% |
| `toast_rand` | 2.000 kB | 10.000 kB | 81,5% |

**Mọi bảng đều 81–98% dung lượng nằm ở TOAST.** Xếp hạng bằng `pg_relation_size` sẽ báo `tu` là "3,5 MB" và **giấu mất 313 MB**.

### Checklist

| Tình huống | Hành động | Bằng chứng đo được |
|---|---|---|
| Query chỉ cần cột nhỏ trên bảng có cột lớn | **cấm `SELECT *`** | `sum(length(note))` vs `sum(id)` — **71×** |
| Field jsonb bị **lọc** trên mọi request | expression index | 150.473 → **485 buffer (310×)** |
| Field jsonb bị **lọc VÀ trả về** | **tách thành cột thật** | 124 ms → **0,94 ms (132×)** |
| Blob đã nén sẵn (ảnh, gzip, protobuf) | `SET STORAGE EXTERNAL` | nén lại chỉ tốn CPU |
| jsonb/text đọc nhiều | `SET COMPRESSION lz4` | đọc nhanh **1,95×**, ghi nhanh **2,86×**, tốn thêm 12,5% đĩa |
| Cột lớn bị UPDATE thường xuyên | **tách sang bảng riêng 1-1** | UPDATE đụng TOAST tốn **44,6× WAL** |
| Bảng "nhỏ" mà tốn đĩa bất thường | `pg_relation_size(reltoastrelid)` | `tu`: 3,5 MB → thật ra 317 MB |
| TOAST bloat | `ALTER TABLE ... SET (toast.autovacuum_*)` | 39,94% dead sau một UPDATE |

### 🔧 Tình huống thực tế — bảng `event` "nhỏ" mà tốn 400 GB

Dashboard dung lượng dựng bằng `pg_relation_size` cho thấy bảng lớn nhất là `orders` (80 GB). Nhưng `df` báo database chiếm 520 GB. 440 GB đi đâu?

```sql
SELECT c.relname, pg_size_pretty(pg_relation_size(c.oid)) AS main,
       pg_size_pretty(pg_relation_size(c.reltoastrelid)) AS toast
FROM pg_class c WHERE c.reltoastrelid <> 0
ORDER BY pg_relation_size(c.reltoastrelid) DESC LIMIT 5;
-- event | 12 GB | 400 GB     ← đây
```

Bảng `event` có cột `payload jsonb` trung bình 40 KB. Ba vấn đề chồng nhau, và cả ba đều có trong số liệu hôm nay:

1. **Query dashboard `SELECT * FROM event WHERE type='X' ORDER BY created_at DESC LIMIT 50`** — de-TOAST 50 document 40 KB để hiển thị 3 field. Sửa: `SELECT id, type, created_at, payload->>'summary'`… nhưng cái cuối vẫn de-TOAST (§5). Sửa đúng: **tách `summary` thành cột thật**.
2. **Job cập nhật `payload` thêm một field mỗi đêm** — mỗi lần là ghi lại toàn bộ 400 GB TOAST + 400 GB dead (§6: 44,6× WAL). Sửa: tách phần hay đổi sang bảng riêng.
3. **TOAST bloat 40%** vì autovacuum dùng ngưỡng mặc định trên bảng TOAST. Sửa: `ALTER TABLE event SET (toast.autovacuum_vacuum_scale_factor = 0.05)`.

Ba thay đổi, không đổi kiến trúc, và không cần downtime nào ngoài một `pg_repack`.

---

## Bảng số liệu chính

| Phép đo | Kết quả |
|---|---|
| Bảng lab có TOAST table | `device`, `ts_kv`, `alarm`, `device_attr` — **cả 4 đều 0 bytes** |
| `repeat('d', 100000)` | nén còn **1.156 byte (1,16%)** — **KHÔNG bị đẩy ra TOAST** |
| `repeat('b', 1500)` | **1.504 byte (100,27%)** — **không hề được nén** (dưới ngưỡng nên không thử nén) |
| md5 ngẫu nhiên 9.600 byte | **9.600 byte (100,0%)** — bị đẩy ra, **5,0 chunk/giá trị** (9.600/1.996 = 4,81 ✅) |
| `toast_rand`: main / TOAST | 2.000 kB / **10.000 kB (5×)** |
| `SELECT id` (Index Only Scan) | **10 buffer**, 0,400 ms |
| `sum(length(note))` vs `sum(id)` | **28,5 ms vs 0,43 ms — 71×** |
| `octet_length(note) > 1000` | 250 buffer, 0,455 ms — **không de-TOAST** (đọc header varlena) |
| `EXPLAIN ANALYZE` của `SELECT id, note` | **không de-TOAST** — plan trông rẻ y hệt `SELECT id` |
| **pglz vs lz4 — TOAST** | 104 MB vs **117 MB** — lz4 **+12,5%** |
| — kích thước TB/giá trị | 4.964 B (44,4%) vs 5.751 B (51,5%) |
| — **INSERT 20.000 dòng** | 7.216,7 ms vs **2.519,1 ms — lz4 nhanh 2,86×** |
| — **đọc + de-TOAST** | 294,7 ms vs **152,8 ms — lz4 nhanh 1,95×** |
| `dev_fat`: main / TOAST | 3.784 kB / **195 MB (96,9%)** |
| **Lọc `meta->>'model'`, không index** | **150.473 buffer, 473,6 ms** |
| **Lọc `model` (cột thật), không index** | **516 buffer, 5,7 ms** — **292× buffer, 83× thời gian** |
| Lọc `meta->>'model'`, **có expression index** | **485 buffer, 2,77 ms** — **310× ít buffer hơn** |
| Lọc `model`, có B-tree | **13 buffer, 1,41 ms** (Index Only Scan) |
| **`SELECT id, meta->>'model'`** (lấy giá trị ra) | **37.820 buffer, 124,0 ms** ← index không cứu được |
| `SELECT id, model` từ `dev_thin` | **0,941 ms — 132×** |
| **UPDATE không đụng TOAST** | 6.257.330 B WAL, **91 ms** |
| **UPDATE đụng TOAST** (thêm 1 ký tự) | **279.268.045 B (266 MB), 4.107 ms — 44,6× WAL, 45× thời gian** |
| TOAST table sau UPDATE | **156 MB → 313 MB** |
| `n_tup_hot_upd / n_tup_upd` | **7 / 40.000 = 0,0%** |
| `pgstattuple` TOAST trước VACUUM | 80.000 sống / **80.000 chết = 39,94%** |
| Sau `VACUUM` | dead 0, free **59,55%**, **kích thước vẫn 313 MB** |
| `pg_relation_size('tu')` vs `pg_total_relation_size` | **3.536 kB vs 317 MB** |

---

## Ba điều dễ hiểu sai

| Hiểu nhầm | Sự thật đo được |
|---|---|
| "Giá trị lớn hơn 2 KB thì bị đẩy ra TOAST." | **Ngưỡng áp lên độ dài SAU NÉN.** `repeat('d', 100000)` — 100 KB, gấp 50 lần ngưỡng — nén còn **1.156 byte** và **nằm nguyên trong page chính**, TOAST table 0 byte. Ngược lại, 9.600 byte md5 ngẫu nhiên không nén được thì bị cắt thành đúng 5 chunk. Và giá trị **dưới** ngưỡng thì không hề được thử nén (1.500 byte 'b' lưu thành 1.504 byte). |
| "Có expression index trên `meta->>'model'` là đủ, không phải tách cột." | Đủ cho **lọc**: 150.473 → **485 buffer (310×)**. **Không đủ cho trả về**: `SELECT id, meta->>'model'` vẫn tốn **37.820 buffer / 124 ms** vì phải de-TOAST đủ 12.445 document. Cột thật: **0,94 ms — 132×**. Mà API nào cũng vừa lọc vừa hiển thị. |
| "`EXPLAIN (ANALYZE, BUFFERS)` cho tôi thấy chi phí thật." | Với bảng có TOAST thì **không**. De-TOAST để **trả về client** xảy ra lúc serialize, sau khi plan kết thúc ⇒ `EXPLAIN ANALYZE` của `SELECT id, note` trông rẻ y hệt `SELECT id`. Chỉ de-TOAST **trong `WHERE`/`GROUP BY`** mới hiện trong plan (150.473 buffer ở §5). Đo đúng phải dùng `\timing` với hàm ép đọc giá trị, hoặc `EXPLAIN (ANALYZE, SERIALIZE)` trên PG16+. |

---

## Áp dụng vào hệ thật

1. **Chạy query xếp hạng §7 trên production ngay** — và so tổng với `pg_database_size()`. Nếu dashboard dung lượng của bạn dùng `pg_relation_size`, nó đang giấu mất phần lớn nhất.
   ```sql
   SELECT c.relname, pg_size_pretty(pg_relation_size(c.oid)) AS main,
          pg_size_pretty(pg_relation_size(c.reltoastrelid)) AS toast,
          round(100.0*pg_relation_size(c.reltoastrelid)/nullif(pg_total_relation_size(c.oid),0),1) AS pct
   FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE c.relkind='r' AND n.nspname NOT IN ('pg_catalog','information_schema')
     AND c.reltoastrelid<>0 AND pg_relation_size(c.reltoastrelid)>0
   ORDER BY 3 DESC LIMIT 10;
   ```

2. **Với bảng `pct_toast` cao nhất, tìm query đang `SELECT *`:**
   ```sql
   SELECT calls, round(total_exec_time) AS ms, substring(query,1,80)
   FROM pg_stat_statements WHERE query ILIKE '%select%*%from%ten_bang%'
   ORDER BY total_exec_time DESC;
   ```
   Ước lượng byte đọc thừa/ngày = `calls × số dòng trả về × kích thước TB của cột lớn`.

3. **Tách field jsonb bị lọc VÀ trả về thành cột thật** (không dừng ở expression index — §5 cho thấy index chỉ cứu được nửa vấn đề). Dùng expand/contract của Day 44: thêm cột → backfill theo lô → chuyển đọc → xoá.

4. **Đổi `default_toast_compression = 'lz4'`** nếu build có. Đọc nhanh 1,95×, ghi nhanh 2,86×, tốn thêm 12,5% đĩa. **Lưu ý: chỉ áp dụng cho dữ liệu mới** — muốn đổi hết phải rewrite bảng (`VACUUM FULL` / `pg_repack`).

5. **Tách cột lớn bị UPDATE thường xuyên sang bảng riêng 1-1.** UPDATE đụng TOAST tốn **44,6× WAL** — mà WAL đó đi qua fsync (Day 37), replication (Day 38), archive, backup. Đây là một trong những đòn bẩy lớn nhất trong cả tuần 9.

6. **Đặt autovacuum riêng cho bảng TOAST** — tuỳ chọn ít người biết:
   ```sql
   ALTER TABLE ten_bang SET (toast.autovacuum_vacuum_scale_factor = 0.05,
                             toast.autovacuum_vacuum_threshold = 10000);
   ```
   Đo được 39,94% chunk là rác chỉ sau **một** lệnh UPDATE.

7. **`SET STORAGE EXTERNAL` cho blob đã nén sẵn** (ảnh, gzip, protobuf, video thumbnail). Nén lại chỉ tốn CPU cả lúc ghi lẫn lúc đọc, không giảm được byte nào.

8. **Bỏ `EXPLAIN ANALYZE` làm thước đo duy nhất cho bảng có cột lớn.** Dùng `\timing` với query thật, hoặc `EXPLAIN (ANALYZE, SERIALIZE)` trên PG16+, hoặc đo ở tầng ứng dụng.

---

## Câu hỏi mở sang các ngày sau

- **Day 42 (plan cache ở tầng driver)** tiếp tục chủ đề "chi phí ẩn ngoài EXPLAIN": Day 32 §3 đã thấy custom vs generic plan; Day 42 nhìn từ phía JDBC/pgx, nơi quyết định đó được đưa ra mà bạn không biết.
- **Day 43 (DDL locks)** trả lời câu hỏi vận hành của §7: `ALTER TABLE ... SET COMPRESSION`, `SET STORAGE`, tách cột — cái nào cần rewrite bảng (và do đó cần `ACCESS EXCLUSIVE` hàng giờ), cái nào chỉ là metadata?
- **Day 44 (expand/contract & backfill)** là quy trình để làm được khuyến nghị số 3 và 5 mà không downtime — và §6 hôm nay cho biết chính xác cái giá của backfill trên cột TOAST: **44,6× WAL**, phải chia lô rất nhỏ.
- **Day 34 (jsonb & GIN)** khép lại từ hôm nay: câu hỏi "field nào nên tách thành cột thật" giờ có tiêu chí định lượng — **field xuất hiện trong `SELECT` hoặc `WHERE` của query nóng, trên bảng có document > 2 KB**, vì mỗi lần chạm là de-TOAST cả document.
- **Câu hỏi mở thật sự:** `toast_tuple_target` (mặc định 2.048) chỉnh được theo bảng — đặt nhỏ hơn thì nhiều giá trị bị đẩy ra ngoài hơn, bảng chính gọn hơn, `SELECT` cột nhỏ nhanh hơn; đặt lớn hơn thì ngược lại. Với bảng có cột jsonb ~3 KB và query 90% chỉ đọc cột nhỏ, giảm `toast_tuple_target` xuống 512 có đáng không? Cách đo: so `pg_relation_size` bảng chính và thời gian `SELECT id` trước/sau.

---

### Dọn dẹp

```sql
DROP TABLE toast_lab, toast_rand, cmp_pglz, cmp_lz4, dev_fat, dev_thin, tu, tu_small;
```
