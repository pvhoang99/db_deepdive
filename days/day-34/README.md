# Day 34 — jsonb & GIN

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

```sql
\timing on
\o /days/day-34/output.txt
ANALYZE device;
SELECT meta FROM device LIMIT 3;
```

---

## §0. Đoán trước

1. GIN index trên `device.meta` to bằng bao nhiêu % bảng?
2. `jsonb_path_ops` nhỏ hơn `jsonb_ops` bao nhiêu?
3. B-tree trên `(meta->>'model')` so với GIN — cái nào nhanh hơn cho query equality?

---

## §1. `json` vs `jsonb`

### Lý thuyết

| | `json` | `jsonb` |
|---|---|---|
| Lưu | văn bản nguyên vẹn | dạng nhị phân đã phân tích |
| Giữ khoảng trắng, thứ tự khoá, khoá trùng | có | **không** |
| Ghi | nhanh (chỉ validate) | chậm hơn (phải parse) |
| Đọc/truy cập field | chậm (parse lại mỗi lần) | **nhanh** |
| Index được | chỉ expression index | **GIN, GiST, B-tree** |

**Luôn dùng `jsonb`** trừ khi bạn cần giữ nguyên văn bản gốc (ví dụ lưu payload để audit chữ ký).

### Làm ngay

```sql
CREATE TABLE t_j (id int, j json, jb jsonb);
INSERT INTO t_j SELECT id, meta::text::json, meta FROM device;

SELECT pg_size_pretty(sum(pg_column_size(j))::bigint)  AS kich_thuoc_json,
       pg_size_pretty(sum(pg_column_size(jb))::bigint) AS kich_thuoc_jsonb
FROM t_j;

\timing on
SELECT count(*) FROM t_j WHERE j->>'model'  = 'TH-100';
SELECT count(*) FROM t_j WHERE jb->>'model' = 'TH-100';
```

**Ghi vào writeup:** kích thước và tốc độ đọc field của hai kiểu. `jsonb` to hơn hay nhỏ hơn `json`?

---

## §2. Toán tử — cái nào index được

### Lý thuyết

| Toán tử | Nghĩa | GIN index dùng được? |
|---|---|---|
| `@>` | chứa (containment) | **✓** |
| `?` | có khoá này | ✓ (chỉ `jsonb_ops`) |
| `?|` `?&` | có khoá nào / mọi khoá | ✓ (chỉ `jsonb_ops`) |
| `@?` `@@` | jsonpath | ✓ |
| `->` `->>` | lấy field | **✗** (cần expression index) |
| `#>` `#>>` | lấy theo đường dẫn | ✗ |

Đây là điểm mấu chốt: **`meta->>'model' = 'TH-100'` KHÔNG dùng được GIN index.** Phải viết lại thành `meta @> '{"model":"TH-100"}'`, hoặc tạo expression index B-tree.

Rất nhiều người tạo GIN index rồi thắc mắc sao query không nhanh lên — vì query viết bằng `->>`.

### Làm ngay

```sql
CREATE INDEX idx_meta_gin ON device USING gin(meta);
ANALYZE device;

EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM device WHERE meta @> '{"model":"TH-100"}';
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM device WHERE meta->>'model' = 'TH-100';
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM device WHERE meta ? 'hw_rev';
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM device WHERE meta->'tags' ? 'critical';
```

**Ghi vào writeup — bảng 4 dòng:** query | có dùng GIN không | buffers | time. **Query nào không dùng được index dù đã tạo GIN — vì sao?**

---

## §3. `jsonb_ops` vs `jsonb_path_ops`

### Lý thuyết

| | `jsonb_ops` (mặc định) | `jsonb_path_ops` |
|---|---|---|
| Lưu | mọi **khoá** và mọi **giá trị** riêng lẻ | **hash của cả đường dẫn + giá trị** |
| Kích thước | to | **nhỏ hơn ~2-3 lần** |
| Hỗ trợ `@>` | ✓ | ✓ (nhanh hơn) |
| Hỗ trợ `?` `?|` `?&` | ✓ | **✗** |

`jsonb_path_ops` nhanh hơn cho `@>` vì mỗi entry đã mã hoá cả đường dẫn — ít false positive hơn nên ít phải recheck.

**Quy tắc:** nếu chỉ dùng `@>` thì luôn chọn `jsonb_path_ops`.

### Làm ngay

```sql
CREATE INDEX idx_meta_path ON device USING gin(meta jsonb_path_ops);
ANALYZE device;

SELECT relname, pg_size_pretty(pg_relation_size(oid)) AS size
FROM pg_class WHERE relname IN ('idx_meta_gin','idx_meta_path','device');
```

So tốc độ (drop-rollback để cô lập):
```sql
BEGIN; DROP INDEX idx_meta_path;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM device WHERE meta @> '{"model":"TH-100"}';
ROLLBACK;

BEGIN; DROP INDEX idx_meta_gin;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM device WHERE meta @> '{"model":"TH-100"}';
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM device WHERE meta ? 'hw_rev';   -- có chạy được không?
ROLLBACK;
```

**Ghi vào writeup:** `jsonb_path_ops` nhỏ hơn bao nhiêu %? Nhanh hơn bao nhiêu cho `@>`? Với `?` thì sao?

---

## §4. B-tree trên expression — đôi khi thắng cả GIN

### Lý thuyết

Nếu bạn **chỉ** query một field cụ thể bằng `=`, B-tree trên expression thường tốt hơn GIN:
- Nhỏ hơn nhiều (chỉ index một field, không phải cả document)
- Lookup nhanh hơn (B-tree lookup vs GIN bitmap + recheck)
- Ghi rẻ hơn
- Có statistics cho biểu thức (Day 09 §6) → planner ước lượng đúng

GIN thắng khi: query linh hoạt, không biết trước sẽ lọc field nào, hoặc cần tìm trong mảng.

### Làm ngay

```sql
CREATE INDEX idx_meta_model_btree ON device ((meta->>'model'));
ANALYZE device;

SELECT relname, pg_size_pretty(pg_relation_size(oid)) AS size
FROM pg_class WHERE relname IN ('idx_meta_gin','idx_meta_path','idx_meta_model_btree');

EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM device WHERE meta->>'model' = 'TH-100';
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM device WHERE meta @> '{"model":"TH-100"}';
```

Và ước lượng của planner:
```sql
EXPLAIN SELECT * FROM device WHERE meta->>'model' = 'TH-100';
EXPLAIN SELECT * FROM device WHERE meta @> '{"model":"TH-100"}';
SELECT count(*) FROM device WHERE meta->>'model' = 'TH-100';
```

**Ghi vào writeup — bảng 3×3:** ba loại index × (kích thước, tốc độ đọc, ước lượng của planner có chính xác không). **Viết quy tắc chọn.**

---

## §5. Chi phí ghi của GIN và `fastupdate`

### Lý thuyết

GIN đắt khi ghi: một document có 20 khoá/giá trị sinh 20 entry index. Để giảm, GIN có **pending list**:

- `fastupdate = on` (mặc định): entry mới ghi vào một danh sách chờ chưa sắp xếp → ghi rất nhanh
- Danh sách được gộp vào cây chính khi vượt `gin_pending_list_limit` (mặc định 4MB) hoặc khi vacuum
- Đổi lại: **đọc phải quét cả pending list tuyến tính** → query chậm dần khi list dài

Với bảng ghi nhiều đọc ít → giữ `fastupdate = on`. Với bảng đọc nhiều cần latency ổn định → tắt đi.

### Làm ngay

```sql
CREATE TABLE t_gin (id serial PRIMARY KEY, doc jsonb);
CREATE INDEX ON t_gin USING gin(doc jsonb_path_ops) WITH (fastupdate = on);

CREATE TABLE t_gin2 (id serial PRIMARY KEY, doc jsonb);
CREATE INDEX ON t_gin2 USING gin(doc jsonb_path_ops) WITH (fastupdate = off);

\timing on
INSERT INTO t_gin  (doc) SELECT meta FROM device;
INSERT INTO t_gin2 (doc) SELECT meta FROM device;

SELECT relname, pg_size_pretty(pg_total_relation_size(oid)) FROM pg_class
WHERE relname IN ('t_gin','t_gin2');

-- đọc ngay sau khi ghi (pending list còn dài)
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM t_gin  WHERE doc @> '{"model":"TH-100"}';
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM t_gin2 WHERE doc @> '{"model":"TH-100"}';

VACUUM t_gin;   -- gộp pending list
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM t_gin WHERE doc @> '{"model":"TH-100"}';
```

**Ghi vào writeup:** insert với `fastupdate=on` nhanh hơn bao nhiêu? Đọc ngay sau đó chậm hơn bao nhiêu? Sau VACUUM thì sao?

---

## §6. jsonpath (SQL/JSON)

### Lý thuyết

Từ PG12, Postgres hỗ trợ jsonpath — ngôn ngữ truy vấn cho jsonb:

```sql
meta @? '$.hw_rev ? (@ > 2)'              -- có tồn tại không (trả boolean)
meta @@ '$.hw_rev > 2'                    -- kiểm tra vị từ
jsonb_path_query(meta, '$.tags[*]')       -- trả về tập giá trị
jsonb_path_exists(meta, '$.model')
```

`@?` và `@@` **dùng được GIN index**, nhưng chỉ khai thác được phần đầu của đường dẫn — với vị từ phức tạp vẫn phải recheck nhiều.

### Làm ngay

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM device WHERE meta @? '$.model ? (@ == "TH-100")';
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM device WHERE meta @@ '$.hw_rev > 2';

SELECT id, jsonb_path_query_array(meta, '$.tags[*]') FROM device LIMIT 5;
SELECT count(*) FROM device WHERE jsonb_path_exists(meta, '$.tags[*] ? (@ == "critical")');
```

**Ghi vào writeup:** `@?` có dùng GIN không? So với `@>` thì thế nào?

---

## §7. Khi nào **không** nên dùng jsonb

### Lý thuyết

jsonb rất tiện, và chính vì tiện nên hay bị lạm dụng. Dấu hiệu nên tách thành cột thật:

| Dấu hiệu | Vì sao |
|---|---|
| Field xuất hiện trong **mọi** dòng | không cần schema linh hoạt |
| Field được lọc/sắp xếp thường xuyên | cột thật + B-tree rẻ hơn nhiều |
| Field cần ràng buộc (NOT NULL, CHECK, FK) | jsonb không làm được |
| Field cần kiểu chặt (số, ngày) | jsonb lưu text, ép kiểu mỗi lần đọc |
| Cần statistics chính xác cho planner | cột thật có `pg_stats` đầy đủ |

**Mô hình lai** thường là đúng nhất: cột thật cho field ổn định và hay query; jsonb cho phần thật sự linh hoạt/hiếm dùng.

Chi phí ẩn: jsonb lớn hơn 2KB bị **TOAST** — nén và lưu ra bảng phụ. Đọc field từ jsonb đã TOAST phải giải nén **cả document**, kể cả khi bạn chỉ cần một field.

### Làm ngay

```sql
-- xem cái nào bị TOAST
SELECT id, pg_column_size(meta) AS bytes FROM device ORDER BY 2 DESC LIMIT 5;
SELECT reltoastrelid::regclass, pg_size_pretty(pg_total_relation_size(reltoastrelid))
FROM pg_class WHERE relname = 'device';

-- so cột thật vs jsonb
ALTER TABLE device ADD COLUMN model_col text;
UPDATE device SET model_col = meta->>'model';
CREATE INDEX idx_model_col ON device(model_col);
ANALYZE device;

EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM device WHERE model_col = 'TH-100';
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM device WHERE meta @> '{"model":"TH-100"}';

SELECT relname, pg_size_pretty(pg_relation_size(oid)) FROM pg_class
WHERE relname IN ('idx_model_col','idx_meta_gin','idx_meta_path');
```

Thử document lớn để thấy TOAST:
```sql
CREATE TABLE t_big (id int, doc jsonb);
INSERT INTO t_big SELECT g, jsonb_build_object('id', g, 'pad', repeat('x', 5000), 'v', g)
FROM generate_series(1, 20000) g;
\timing on
SELECT count(*) FROM t_big WHERE (doc->>'v')::int > 19000;
SELECT pg_size_pretty(pg_total_relation_size('t_big')) AS tong,
       pg_size_pretty(pg_relation_size('t_big'))       AS chinh;
```

**Ghi vào writeup:** cột thật + B-tree so với jsonb + GIN — index nhỏ hơn mấy lần, query nhanh hơn mấy lần? Với `t_big`, bao nhiêu % dung lượng nằm ở TOAST, và query lọc theo field trong document TOAST chậm thế nào?

### Dọn dẹp

```sql
ALTER TABLE device DROP COLUMN model_col;
DROP TABLE t_j, t_gin, t_gin2, t_big;
```

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B. Áp dụng vào hệ thật:** trong hệ ThingsBoard/service của bạn, chỗ nào đang dùng jsonb? Với mỗi chỗ: field nào xuất hiện ở mọi dòng và hay được query — **nên tách thành cột thật**? Query hiện tại viết bằng `->>` hay `@>` — có đang bỏ phí GIN index không?

### Đạt khi

Bạn biết chính xác toán tử nào dùng được GIN, chọn đúng giữa `jsonb_ops`/`jsonb_path_ops`/B-tree expression bằng số liệu, và nhận ra chỗ nào jsonb đang bị lạm dụng.

**Xong thì gõ `/review-bai`.**
