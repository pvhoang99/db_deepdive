# Day 24 — HOT update & fillfactor

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

```sql
\timing on
\o /days/day-24/output.txt
```

---

## §0. Đoán trước

1. `UPDATE` cột **không** được index — có phải cập nhật index không?
2. `fillfactor = 70` làm bảng to hơn 30%. Nó bù lại bằng gì?
3. Update 500k lần lên cột có index vs không index — chênh nhau mấy lần?

---

## §1. Vấn đề: mỗi UPDATE phải sửa MỌI index

### Lý thuyết

Từ Day 21: `UPDATE` tạo tuple mới ở vị trí vật lý mới → `ctid` đổi.

Mà index lưu `ctid`. Nên **mọi index đều phải thêm entry mới trỏ tới ctid mới** — kể cả index trên cột hoàn toàn không bị đổi.

Bảng có 5 index, update một cột không liên quan → 1 tuple mới + 5 entry index mới + WAL cho tất cả. Đắt khủng khiếp với bảng ghi nhiều.

### Làm ngay

```sql
CREATE TABLE t_noidx (id int PRIMARY KEY, hot_col int, idx_col int, pad text);
INSERT INTO t_noidx SELECT g, g, g, repeat('x',100) FROM generate_series(1,200000) g;
CREATE INDEX ON t_noidx(idx_col);
VACUUM ANALYZE t_noidx;

SELECT pg_size_pretty(pg_total_relation_size('t_noidx')) AS truoc;
\timing on
UPDATE t_noidx SET hot_col = hot_col + 1;      -- cột KHÔNG index
SELECT pg_size_pretty(pg_total_relation_size('t_noidx')) AS sau,
       n_tup_upd, n_tup_hot_upd
FROM pg_stat_user_tables WHERE relname='t_noidx';
```

**Ghi vào writeup:** `n_tup_hot_upd` / `n_tup_upd` bằng bao nhiêu? (Đọc tiếp §2 để hiểu con số này.)

---

## §2. HOT — Heap-Only Tuple

### Lý thuyết

Postgres có tối ưu hoá: nếu **cả hai điều kiện** dưới đây đúng, nó không cần đụng index nào cả.

**Điều kiện 1:** UPDATE **không chạm cột nào được index**.
**Điều kiện 2:** tuple mới nằm **trong cùng page** với tuple cũ (page phải còn chỗ).

Khi đó Postgres tạo **HOT chain**: tuple cũ trỏ tới tuple mới bằng con trỏ nội bộ trong page.

```
Page:
  slot 1 → [tuple v1, ctid trỏ tới slot 4]     (dead, redirect)
  slot 4 → [tuple v2]                          (live)

Index vẫn trỏ tới slot 1 → đi theo chain → tới slot 4. Index KHÔNG cần sửa.
```

Lợi ích:
- Không ghi entry index mới → ít WAL hơn nhiều
- Index không bloat
- Dọn rác rẻ hơn: page có thể tự dọn HOT chain (**page pruning**) mà không cần VACUUM đầy đủ

Chỉ số theo dõi: `n_tup_hot_upd / n_tup_upd`. **Càng gần 1 càng tốt.** Dưới 0.5 trên bảng update nhiều là dấu hiệu cần xem lại.

Điều kiện 1 là lý do quan trọng để **không đánh index bừa bãi lên bảng update nhiều** — mỗi index thêm vào làm giảm cơ hội HOT.

### Làm ngay

```sql
-- so hai loại UPDATE trên cùng bảng
TRUNCATE t_noidx;
INSERT INTO t_noidx SELECT g, g, g, repeat('x',100) FROM generate_series(1,200000) g;
VACUUM ANALYZE t_noidx;
SELECT pg_stat_reset_single_table_counters('t_noidx'::regclass);

UPDATE t_noidx SET hot_col = hot_col + 1;      -- cột KHÔNG index
SELECT n_tup_upd, n_tup_hot_upd,
       round(n_tup_hot_upd::numeric/nullif(n_tup_upd,0),3) AS ty_le_hot,
       pg_size_pretty(pg_total_relation_size('t_noidx')) AS size
FROM pg_stat_user_tables WHERE relname='t_noidx';

SELECT pg_stat_reset_single_table_counters('t_noidx'::regclass);
UPDATE t_noidx SET idx_col = idx_col + 1;      -- cột CÓ index
SELECT n_tup_upd, n_tup_hot_upd,
       round(n_tup_hot_upd::numeric/nullif(n_tup_upd,0),3) AS ty_le_hot,
       pg_size_pretty(pg_total_relation_size('t_noidx')) AS size
FROM pg_stat_user_tables WHERE relname='t_noidx';
```

**Ghi vào writeup — bảng 2 dòng:** loại update | n_tup_upd | n_tup_hot_upd | tỷ lệ HOT | thời gian | kích thước sau.

---

## §3. Nhìn HOT chain trong page

### Làm ngay

```sql
CREATE TABLE t_hot (id int PRIMARY KEY, v int, pad text);
INSERT INTO t_hot SELECT g, g, repeat('x',50) FROM generate_series(1,10) g;
VACUUM t_hot;

SELECT lp, lp_off, t_xmin, t_xmax, t_ctid,
       CASE lp_flags WHEN 0 THEN 'unused' WHEN 1 THEN 'normal'
                     WHEN 2 THEN 'REDIRECT' WHEN 3 THEN 'dead' END AS flag
FROM heap_page_items(get_raw_page('t_hot', 0));

UPDATE t_hot SET v = v + 1 WHERE id = 1;
UPDATE t_hot SET v = v + 1 WHERE id = 1;
UPDATE t_hot SET v = v + 1 WHERE id = 1;

SELECT lp, t_xmin, t_xmax, t_ctid,
       CASE lp_flags WHEN 0 THEN 'unused' WHEN 1 THEN 'normal'
                     WHEN 2 THEN 'REDIRECT' WHEN 3 THEN 'dead' END AS flag
FROM heap_page_items(get_raw_page('t_hot', 0));
```

Chú ý cột `t_ctid`: với HOT chain, tuple cũ trỏ tới slot của tuple mới **trong cùng page** (page number giống nhau).

Rồi xem page tự dọn:
```sql
SELECT count(*) FROM t_hot;   -- một lần đọc kích hoạt page pruning
SELECT lp, t_ctid,
       CASE lp_flags WHEN 2 THEN 'REDIRECT' WHEN 3 THEN 'dead' WHEN 1 THEN 'normal' ELSE 'unused' END AS flag
FROM heap_page_items(get_raw_page('t_hot', 0));
```

**Ghi vào writeup:** sau 3 lần update, dòng id=1 chiếm mấy slot? Có slot nào thành `REDIRECT` không? Sau khi đọc bảng, page có tự dọn không — **đây là page pruning, khác VACUUM ở chỗ nào?**

---

## §4. `fillfactor` — chừa chỗ cho HOT

### Lý thuyết

Điều kiện 2 của HOT đòi hỏi **page còn chỗ trống**. Nhưng mặc định Postgres lấp đầy page 100% khi INSERT — nên UPDATE đầu tiên đã phải sang page khác, mất HOT ngay.

`fillfactor` bảo Postgres chỉ lấp đầy N% khi INSERT, chừa phần còn lại cho các bản UPDATE sau:

```sql
ALTER TABLE tbl SET (fillfactor = 70);
VACUUM FULL tbl;   -- hoặc REINDEX; fillfactor chỉ áp dụng cho page MỚI
```

Đánh đổi:
- Bảng to hơn `100/fillfactor` lần ngay từ đầu (fillfactor 70 → to hơn ~43%)
- Seq scan đọc nhiều page hơn
- Nhưng: tỷ lệ HOT cao hơn nhiều → ít bloat index, ít WAL, update nhanh hơn

**Khi nào dùng:** bảng bị UPDATE nhiều lần trên cùng dòng (bảng trạng thái, counter, session, cache). Giá trị thường dùng 70–90.
**Khi nào KHÔNG dùng:** bảng append-only (`ts_kv`) — chừa chỗ chỉ tổ lãng phí.

Với **index** cũng có `fillfactor` (mặc định 90 cho B-tree) — chừa chỗ để giảm page split.

### Làm ngay

```sql
CREATE TABLE t_ff100 (id int PRIMARY KEY, v int, pad text) WITH (fillfactor = 100);
CREATE TABLE t_ff70  (id int PRIMARY KEY, v int, pad text) WITH (fillfactor = 70);

INSERT INTO t_ff100 SELECT g, g, repeat('x',100) FROM generate_series(1,200000) g;
INSERT INTO t_ff70  SELECT g, g, repeat('x',100) FROM generate_series(1,200000) g;
VACUUM ANALYZE t_ff100; VACUUM ANALYZE t_ff70;

SELECT relname, pg_size_pretty(pg_total_relation_size(oid)) AS size_ban_dau
FROM pg_class WHERE relname IN ('t_ff100','t_ff70');

SELECT pg_stat_reset_single_table_counters('t_ff100'::regclass);
SELECT pg_stat_reset_single_table_counters('t_ff70'::regclass);

\timing on
UPDATE t_ff100 SET v = v + 1;
UPDATE t_ff70  SET v = v + 1;

SELECT relname, n_tup_upd, n_tup_hot_upd,
       round(n_tup_hot_upd::numeric/nullif(n_tup_upd,0),3) AS ty_le_hot
FROM pg_stat_user_tables WHERE relname IN ('t_ff100','t_ff70');

SELECT relname, pg_size_pretty(pg_total_relation_size(oid)) AS size_sau
FROM pg_class WHERE relname IN ('t_ff100','t_ff70');
```

Chạy thêm 4 vòng UPDATE nữa rồi đo lại.

**Ghi vào writeup — bảng:** fillfactor | size ban đầu | tỷ lệ HOT | thời gian UPDATE | size sau 5 vòng. **fillfactor 70 to hơn lúc đầu bao nhiêu %, nhưng sau 5 vòng update thì bên nào to hơn?**

---

## §5. Bốn kịch bản kết hợp

### Làm ngay

Chạy ma trận: {fillfactor 100, 70} × {update cột có index, không index}.

```sql
DROP TABLE IF EXISTS m1, m2, m3, m4;
CREATE TABLE m1 (id int PRIMARY KEY, hot_col int, idx_col int, pad text) WITH (fillfactor=100);
CREATE TABLE m2 (id int PRIMARY KEY, hot_col int, idx_col int, pad text) WITH (fillfactor=70);
CREATE TABLE m3 (id int PRIMARY KEY, hot_col int, idx_col int, pad text) WITH (fillfactor=100);
CREATE TABLE m4 (id int PRIMARY KEY, hot_col int, idx_col int, pad text) WITH (fillfactor=70);

DO $$ BEGIN
  FOR t IN SELECT unnest(ARRAY['m1','m2','m3','m4']) LOOP
    EXECUTE format('INSERT INTO %I SELECT g,g,g,repeat(''x'',100) FROM generate_series(1,200000) g', t);
    EXECUTE format('CREATE INDEX ON %I(idx_col)', t);
    EXECUTE format('VACUUM ANALYZE %I', t);
    EXECUTE format('SELECT pg_stat_reset_single_table_counters(%L::regclass)', t);
  END LOOP;
END $$;

UPDATE m1 SET hot_col = hot_col+1;   -- ff100, không index
UPDATE m2 SET hot_col = hot_col+1;   -- ff70,  không index
UPDATE m3 SET idx_col = idx_col+1;   -- ff100, có index
UPDATE m4 SET idx_col = idx_col+1;   -- ff70,  có index

SELECT relname, n_tup_upd, n_tup_hot_upd,
       round(n_tup_hot_upd::numeric/nullif(n_tup_upd,0),3) AS ty_le_hot,
       pg_size_pretty(pg_total_relation_size(relid)) AS size
FROM pg_stat_user_tables WHERE relname IN ('m1','m2','m3','m4') ORDER BY relname;
```

**Ghi vào writeup — bảng 4 dòng.** Kịch bản nào tốt nhất, tệ nhất? Chênh lệch bao nhiêu lần?

---

## §6. WAL — thước đo thật của chi phí ghi

### Lý thuyết

Cách chính xác nhất để so chi phí ghi là đo **lượng WAL sinh ra** — nó bao gồm cả heap lẫn index lẫn full-page write.

```sql
SELECT pg_current_wal_lsn();   -- trước và sau, lấy hiệu
SELECT pg_wal_lsn_diff(lsn2, lsn1);
```

Hoặc dùng `pg_stat_statements.wal_bytes` (đã có trong lab).

### Làm ngay

```sql
SELECT pg_stat_statements_reset();

UPDATE m1 SET hot_col = hot_col+1;
UPDATE m3 SET idx_col = idx_col+1;

SELECT substring(query,1,40) AS q, calls,
       pg_size_pretty(wal_bytes::bigint) AS wal,
       wal_records, wal_fpi
FROM pg_stat_statements WHERE query LIKE 'UPDATE m%' ORDER BY wal_bytes DESC;
```

**Ghi vào writeup:** update cột có index sinh WAL nhiều hơn bao nhiêu lần? `wal_fpi` (full page image) là gì và vì sao nó cao?

### Dọn dẹp

```sql
DROP TABLE t_noidx, t_hot, t_ff100, t_ff70, m1, m2, m3, m4;
```

---

## §7. Quy tắc rút ra

### Lý thuyết — checklist

| Tình huống | Hành động |
|---|---|
| Bảng update nhiều trên cùng dòng | `fillfactor = 70..85` |
| Bảng append-only | giữ `fillfactor = 100` |
| Cột bị update thường xuyên | **đừng đánh index lên nó** nếu tránh được |
| Tỷ lệ HOT < 0.5 trên bảng nóng | xem lại index nào đang phá HOT |
| ORM update toàn bộ cột | bật dynamic update — nếu không thì mọi update đều phá HOT |

Điểm cuối quan trọng với bạn: Hibernate mặc định `UPDATE` **mọi cột** trong entity. Chỉ cần entity có một cột được index là **mọi update đều mất HOT**. Bật `@DynamicUpdate` (hoặc dùng projection) sửa được.

### Làm ngay

```sql
-- kiểm tra tỷ lệ HOT toàn database
SELECT relname, n_tup_upd, n_tup_hot_upd,
       round(n_tup_hot_upd::numeric / nullif(n_tup_upd,0), 3) AS ty_le_hot,
       (SELECT count(*) FROM pg_index WHERE indrelid = relid) AS so_index
FROM pg_stat_user_tables WHERE n_tup_upd > 0
ORDER BY ty_le_hot NULLS LAST;
```

**Ghi vào writeup:** bảng nào tỷ lệ HOT thấp nhất? Có tương quan với số index không?

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B. Áp dụng vào hệ thật:** chạy query ở §7 trên DB production. Bảng nào tỷ lệ HOT thấp? Với mỗi bảng đó: cột nào đang bị update thường xuyên, cột đó có index không, `fillfactor` nên đặt bao nhiêu? Và kiểm tra ORM của bạn có đang update toàn bộ cột không.

### Đạt khi

Bạn giải thích được hai điều kiện của HOT update, đo được tỷ lệ HOT, và biết chính xác khi nào đặt `fillfactor` thấp thì có lợi.

**Xong thì gõ `/review-bai`.**
