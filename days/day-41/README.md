# Day 41 — TOAST: chuyện gì xảy ra khi một dòng không vừa 8KB

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

> Day 21 bạn nhìn tuple trong page. Nhưng page chỉ có 8KB — vậy `jsonb` 200KB nằm ở đâu? Câu trả lời là **TOAST**, và nó giải thích một loạt hiện tượng bạn từng thấy mà không hiểu: bảng "nhỏ" mà tốn 40GB, `SELECT id` nhanh còn `SELECT *` chậm 50 lần, tỷ lệ HOT tự nhiên tụt.

## Chuẩn bị

```sql
\timing on
\o /days/day-41/output.txt
```

---

## §0. Đoán trước

1. Một dòng có cột `text` 100KB — dòng đó chiếm bao nhiêu byte **trong page của bảng chính**?
2. `SELECT id FROM t` trên bảng có cột 100KB — có phải đọc 100KB đó không?
3. `pg_relation_size('t')` có tính phần TOAST không? Còn `pg_total_relation_size`?
4. `UPDATE t SET counter = counter + 1` (không đụng cột lớn) — có ghi lại 100KB kia không?

---

## §1. Vì sao TOAST tồn tại

### Lý thuyết

Postgres không cho một tuple nằm vắt qua nhiều page. Page = 8KB → tuple tối đa ~8KB. Nhưng `text`/`jsonb`/`bytea` có thể 1GB.

Giải pháp: **TOAST** (The Oversized-Attribute Storage Technique).

Khi tuple vượt **`TOAST_TUPLE_THRESHOLD` ≈ 2KB**, Postgres lần lượt:
1. **Nén** các cột lớn (nếu strategy cho phép),
2. Nếu vẫn > 2KB → **đẩy ra ngoài**: cắt giá trị thành chunk ~1996 byte, lưu vào một **bảng TOAST riêng** (`pg_toast.pg_toast_<oid>`, có index riêng),
3. Trong tuple chính chỉ còn một **con trỏ 18 byte** (`varatt_external`: OID, độ dài, độ dài đã nén).

Bốn strategy cho mỗi cột:

| Strategy | Nén | Đẩy ra ngoài | Dùng cho |
|---|---|---|---|
| `PLAIN` | không | không | kiểu độ dài cố định (`int`, `timestamptz`) |
| `EXTENDED` | **có** | **có** | mặc định của `text`, `jsonb`, `bytea` |
| `EXTERNAL` | không | có | dữ liệu đã nén sẵn (ảnh, gzip) hoặc cần **đọc một phần** nhanh (`substring`) |
| `MAIN` | có | chỉ khi bất khả kháng | giá trị vừa phải, muốn giữ trong bảng chính |

Hệ quả quan trọng nhất, và là lý do bài này nằm ngay trước tuần capstone:
**Đọc cột không-TOAST thì không đụng bảng TOAST.** Đó là vì sao `SELECT id, ts` rẻ hơn `SELECT *` gấp bội trên bảng có jsonb lớn — và vì sao `SELECT *` trong ORM là một cái bẫy có chi phí đo được.

### Làm ngay

```sql
SELECT attname, atttypid::regtype AS kieu,
       CASE attstorage WHEN 'p' THEN 'PLAIN' WHEN 'e' THEN 'EXTERNAL'
                       WHEN 'x' THEN 'EXTENDED' WHEN 'm' THEN 'MAIN' END AS strategy
FROM pg_attribute WHERE attrelid='device'::regclass AND attnum>0 ORDER BY attnum;

SELECT c.relname, t.relname AS toast_table,
       pg_size_pretty(pg_relation_size(c.oid))  AS main,
       pg_size_pretty(pg_relation_size(c.reltoastrelid)) AS toast
FROM pg_class c LEFT JOIN pg_class t ON t.oid=c.reltoastrelid
WHERE c.relname IN ('device','ts_kv','alarm','device_attr');
```

**Ghi vào writeup:** bảng nào có TOAST table? Kích thước phần TOAST so với phần chính là bao nhiêu %?

---

## §2. Nhìn ngưỡng 2KB bằng mắt

### Làm ngay

```sql
CREATE TABLE toast_lab (id int PRIMARY KEY, note text);

INSERT INTO toast_lab SELECT g, repeat('a', 100)    FROM generate_series(1,1000) g;      -- 100B
INSERT INTO toast_lab SELECT 1000+g, repeat('b', 1500) FROM generate_series(1,1000) g;   -- 1.5KB
INSERT INTO toast_lab SELECT 2000+g, repeat('c', 5000) FROM generate_series(1,1000) g;   -- 5KB
INSERT INTO toast_lab SELECT 3000+g, repeat('d', 100000) FROM generate_series(1,1000) g; -- 100KB
VACUUM ANALYZE toast_lab;

SELECT pg_size_pretty(pg_relation_size('toast_lab')) AS main,
       pg_size_pretty(pg_relation_size(reltoastrelid)) AS toast,
       pg_size_pretty(pg_total_relation_size('toast_lab')) AS tong
FROM pg_class WHERE relname='toast_lab';
```

Chú ý: `repeat('a',...)` nén **cực tốt** (dữ liệu lặp). Đó là lý do 100KB chữ 'd' không thành 100KB trên đĩa. Làm lại với dữ liệu **không nén được**:

```sql
CREATE TABLE toast_rand (id int PRIMARY KEY, note text);
INSERT INTO toast_rand
SELECT g, string_agg(md5(random()::text), '') FROM generate_series(1,1000) g,
       generate_series(1,60) h GROUP BY g;     -- ~1.9KB ngẫu nhiên, gần ngưỡng
INSERT INTO toast_rand
SELECT 1000+g, string_agg(md5(random()::text), '') FROM generate_series(1,1000) g,
       generate_series(1,300) h GROUP BY g;    -- ~9.6KB ngẫu nhiên
VACUUM ANALYZE toast_rand;

SELECT pg_size_pretty(pg_relation_size('toast_rand')) AS main,
       pg_size_pretty(pg_relation_size(reltoastrelid)) AS toast
FROM pg_class WHERE relname='toast_rand';
```

Xem giá trị bị nén tới đâu:
```sql
SELECT id, octet_length(note) AS do_dai_that,
       pg_column_size(note)   AS byte_luu_tru,
       round(100.0*pg_column_size(note)/octet_length(note),1) AS pct_sau_nen
FROM toast_rand WHERE id IN (1, 1001);
```

**Bẫy đo lường:** `pg_column_size` trả về **kích thước đã nén của giá trị**, không phải 18 byte con trỏ — nên nó *không* cho biết giá trị có bị đẩy ra ngoài hay không. Muốn biết chắc, đếm thẳng trong bảng TOAST:

```sql
SELECT reltoastrelid::regclass AS toast_tbl FROM pg_class WHERE relname='toast_rand' \gset
SELECT count(DISTINCT chunk_id) AS so_gia_tri_bi_day_ra, count(*) AS so_chunk FROM :toast_tbl;
```

Làm lại phép đếm này cho `toast_lab` (dữ liệu `repeat('a',...)` nén cực tốt).

**Ghi vào writeup — bảng:** kích thước giá trị | `pg_column_size` | % sau nén | có bị đẩy ra TOAST không. Trong `toast_lab`, giá trị 100.000 byte có bị đẩy ra ngoài không — **vì sao không**, dù nó lớn gấp 50 lần ngưỡng? Ngưỡng thực nghiệm áp lên **cái gì**: độ dài gốc hay độ dài sau nén?

Trung bình mỗi giá trị bị đẩy ra chiếm mấy chunk? Đối chiếu với chunk size ~1996 byte.

---

## §3. Cái giá thật: `SELECT *` vs `SELECT cột nhỏ`

### Làm ngay

```sql
VACUUM ANALYZE toast_rand;

EXPLAIN (ANALYZE, BUFFERS) SELECT id FROM toast_rand;
EXPLAIN (ANALYZE, BUFFERS) SELECT id, note FROM toast_rand;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM toast_rand WHERE octet_length(note) > 1000;
```

**Ghi vào writeup — bảng 3 dòng:** query | time | shared hit/read | có đụng TOAST không.

Điểm cần chú ý và **giải thích trong writeup**: `EXPLAIN (ANALYZE, BUFFERS)` **có** đếm buffer của bảng TOAST không? Kiểm chứng bằng cách so `shared read` giữa dòng 1 và dòng 2 — chênh lệch đó chính là phần TOAST.

Đo thêm chi phí de-TOAST khi trả dữ liệu về client:
```sql
\timing on
SELECT sum(length(note)) FROM toast_rand;          -- phải đọc + giải nén toàn bộ
SELECT sum(id) FROM toast_rand;                    -- không đụng
```

---

## §4. Nén: `pglz` vs `lz4`

### Lý thuyết

PG14+ có `default_toast_compression`: `pglz` (mặc định, nén tốt hơn, chậm) hoặc `lz4` (nhanh hơn nhiều, nén kém hơn ~10–20%). Với dữ liệu jsonb đọc nhiều, `lz4` thường thắng rõ vì chi phí **giải nén** nằm trên đường đọc nóng.

Đặt được ở 3 mức: toàn cục (`default_toast_compression`), theo cột (`ALTER TABLE ... ALTER COLUMN ... SET COMPRESSION lz4`), và giá trị cũ **không** được nén lại (chỉ áp dụng cho dữ liệu ghi mới).

### Làm ngay

```sql
SHOW default_toast_compression;

-- kiểm tra bản build có lz4 không
SELECT 1 FROM pg_settings WHERE name='default_toast_compression';
CREATE TABLE cmp_pglz (id int, j jsonb);
CREATE TABLE cmp_lz4  (id int, j jsonb);
ALTER TABLE cmp_pglz ALTER COLUMN j SET COMPRESSION pglz;
ALTER TABLE cmp_lz4  ALTER COLUMN j SET COMPRESSION lz4;   -- lỗi -> build không có lz4, bỏ qua nhánh này
```

```sql
-- jsonb "thật": lặp lại cấu trúc, giá trị khác nhau -> nén được vừa phải
INSERT INTO cmp_pglz SELECT g, jsonb_build_object(
  'device', md5(g::text), 'model','TH-100', 'tags', to_jsonb(ARRAY['critical','floor-'||(g%9)]),
  'readings', (SELECT jsonb_agg(jsonb_build_object('t',h,'v',random())) FROM generate_series(1,60) h))
FROM generate_series(1,20000) g;
INSERT INTO cmp_lz4 SELECT * FROM cmp_pglz;
VACUUM ANALYZE cmp_pglz, cmp_lz4;

SELECT relname, pg_size_pretty(pg_total_relation_size(oid)) AS tong,
       pg_size_pretty(pg_relation_size(reltoastrelid)) AS toast
FROM pg_class WHERE relname IN ('cmp_pglz','cmp_lz4');

\timing on
SELECT count(*) FROM cmp_pglz WHERE j->>'model' = 'TH-100';
SELECT count(*) FROM cmp_lz4  WHERE j->>'model' = 'TH-100';
```

**Ghi vào writeup — bảng:** thuật toán | dung lượng TOAST | thời gian đọc lọc theo `->>`. Cái nào bạn chọn cho `device.meta` và vì sao? (Nếu build không có lz4 thì ghi rõ, và nêu bạn sẽ kiểm tra thế nào trên server thật.)

---

## §5. TOAST + jsonb: vì sao `meta->>'model'` đắt hơn bạn tưởng

### Lý thuyết

`jsonb` là **một giá trị duy nhất**. Muốn lấy `meta->>'model'` (12 byte), Postgres phải:
1. đọc **toàn bộ** chuỗi chunk TOAST của dòng đó,
2. **giải nén toàn bộ**,
3. rồi mới parse ra field.

Không có "đọc một field" — TOAST không hiểu jsonb. (Ngoại lệ hẹp: strategy `EXTERNAL` cho phép đọc **tiền tố** với `substring()` trên `text`, không áp dụng cho jsonb.)

Đây là lập luận định lượng cho câu hỏi ở Day 34: *"chỗ nào đang dùng jsonb mà nên tách thành cột thật?"* — nếu bạn lọc/sắp xếp theo một field trên mọi request, mỗi request đang trả giá đọc + giải nén cả document.

### Làm ngay

```sql
-- phình meta để nó thật sự bị TOAST
CREATE TABLE dev_fat AS
SELECT id, name, type, meta || jsonb_build_object(
   'history', (SELECT jsonb_agg(jsonb_build_object('t',h,'v',md5((id*h)::text))) FROM generate_series(1,80) h)) AS meta
FROM device;
CREATE TABLE dev_thin AS
SELECT id, name, type, meta->>'model' AS model, meta AS meta FROM dev_fat;
VACUUM ANALYZE dev_fat, dev_thin;

SELECT relname, pg_size_pretty(pg_relation_size(oid)) AS main,
       pg_size_pretty(pg_relation_size(reltoastrelid)) AS toast
FROM pg_class WHERE relname IN ('dev_fat','dev_thin');

EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM dev_fat  WHERE meta->>'model' = 'TH-100';
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM dev_thin WHERE model = 'TH-100';

CREATE INDEX ON dev_thin(model);
CREATE INDEX ON dev_fat ((meta->>'model'));
ANALYZE dev_fat, dev_thin;

EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM dev_fat  WHERE meta->>'model' = 'TH-100';
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM dev_thin WHERE model = 'TH-100';
```

**Ghi vào writeup — bảng 4 dòng:** (cột thật / expression index) × (có index / không) — time + buffers. **Câu hỏi chính:** khi đã có expression index trên `meta->>'model'`, việc lọc còn phải de-TOAST không? Còn khi query cần `SELECT meta->>'model'` (lấy giá trị ra) thì sao?

---

## §6. TOAST gặp MVCC: cái giá của UPDATE

### Lý thuyết

Nối với Day 21 và Day 24:

- UPDATE **không đụng** cột TOAST → tuple mới **dùng lại con trỏ cũ**, phần TOAST không bị ghi lại. Rẻ.
- UPDATE **có đụng** cột TOAST → toàn bộ chuỗi chunk mới được ghi + chunk cũ thành dead → TOAST table cũng bloat và cũng cần VACUUM.
- Dòng lớn (gần 8KB sau khi nén nhưng chưa bị đẩy ra) → **page chứa được rất ít tuple** → UPDATE khó tìm được chỗ trong cùng page → **mất HOT** (điều kiện 2 của Day 24).

### Làm ngay

```sql
CREATE TABLE tu (id int PRIMARY KEY, counter int, big text);
INSERT INTO tu SELECT g, 0, string_agg(md5(random()::text),'')
FROM generate_series(1,20000) g, generate_series(1,200) h GROUP BY g;
VACUUM ANALYZE tu;
SELECT pg_stat_reset_single_table_counters('tu'::regclass);
CHECKPOINT;
SELECT pg_stat_statements_reset();

UPDATE tu SET counter = counter + 1;                      -- không đụng TOAST
UPDATE tu SET big = big || 'x';                           -- đụng TOAST

SELECT substring(query,1,30) AS q, pg_size_pretty(wal_bytes::bigint) AS wal,
       round(total_exec_time::numeric,0) AS ms
FROM pg_stat_statements WHERE query LIKE 'UPDATE tu%' ORDER BY wal_bytes DESC;

SELECT pg_size_pretty(pg_relation_size('tu')) AS main,
       pg_size_pretty(pg_relation_size(reltoastrelid)) AS toast
FROM pg_class WHERE relname='tu';

SELECT n_tup_upd, n_tup_hot_upd FROM pg_stat_user_tables WHERE relname='tu';
SELECT * FROM pgstattuple(( SELECT reltoastrelid::regclass::text FROM pg_class WHERE relname='tu'));
```

**Ghi vào writeup:** hai UPDATE chênh nhau bao nhiêu lần về WAL và thời gian? Tỷ lệ HOT của bảng này so với bảng ở Day 24 (dòng nhỏ) — vì sao khác? Bảng TOAST có bloat không (`pgstattuple`), và ai dọn nó?

### Dọn dẹp

```sql
DROP TABLE toast_lab, toast_rand, cmp_pglz, cmp_lz4, dev_fat, dev_thin, tu;
```

---

## §7. Quy tắc rút ra

### Lý thuyết — checklist

| Tình huống | Hành động |
|---|---|
| Bảng có cột lớn nhưng query thường chỉ cần cột nhỏ | **cấm `SELECT *`**; đo lại buffers để chứng minh |
| Field trong jsonb bị lọc/sắp xếp trên mọi request | tách thành cột thật (hoặc ít nhất expression index) |
| Blob đã nén sẵn (ảnh, gzip, protobuf) | `SET STORAGE EXTERNAL` — nén lại chỉ tốn CPU vô ích |
| Đọc nhiều, nén nặng | `SET COMPRESSION lz4` cho cột đó |
| Cột lớn bị UPDATE thường xuyên | tách sang **bảng riêng** 1-1 — giữ bảng chính gọn để còn HOT |
| Bảng "nhỏ" mà tốn đĩa bất thường | kiểm tra `pg_relation_size(reltoastrelid)` trước khi kết luận |

Bẫy đo lường quan trọng: `pg_relation_size` **không** tính TOAST, `pg_total_relation_size` **có**. Nhiều báo cáo dung lượng sai từ đây.

### Làm ngay

```sql
-- xếp hạng phần TOAST trên toàn database
SELECT c.relname,
       pg_size_pretty(pg_relation_size(c.oid))            AS main,
       pg_size_pretty(pg_relation_size(c.reltoastrelid))  AS toast,
       round(100.0*pg_relation_size(c.reltoastrelid)/nullif(pg_total_relation_size(c.oid),0),1) AS pct_toast
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE c.relkind='r' AND n.nspname='public' AND c.reltoastrelid<>0
ORDER BY pg_relation_size(c.reltoastrelid) DESC;
```

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B. Áp dụng vào hệ thật:** chạy query §7 trên production. Bảng nào có `pct_toast` cao nhất? Với bảng đó:
- Query nào đang `SELECT *` trên nó (dùng `pg_stat_statements`)? Ước lượng số byte đọc thừa mỗi ngày.
- Có field jsonb nào đang bị lọc thường xuyên mà nên tách cột không?
- Cột lớn có bị UPDATE cùng nhịp với cột nhỏ không — có tách bảng được không?

### Đạt khi

Bạn giải thích được ngưỡng 2KB, chứng minh bằng số rằng `SELECT` cột nhỏ không đụng TOAST, và nêu được vì sao lọc theo một field jsonb lại phải giải nén cả document.

**Xong thì gõ `/review-bai`.**
