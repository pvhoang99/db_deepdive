# Day 06 — Bên trong B-tree: index thật sự nằm thế nào trên đĩa

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

```sql
\timing on
\o /days/day-06/output.txt
CREATE INDEX IF NOT EXISTS idx_tskv_dev ON ts_kv(device_id);
CREATE INDEX IF NOT EXISTS idx_tskv_ts  ON ts_kv(ts);
CREATE INDEX IF NOT EXISTS idx_dev_name ON device(name);
ANALYZE;
```

---

## §0. Đoán trước

1. `idx_tskv_dev` (5M dòng, `bigint`) cao mấy tầng?
2. Một `Index Scan` tìm 1 dòng phải đọc tối thiểu bao nhiêu page?
3. `idx_dev_name` (50k dòng, `text` ~15 ký tự) so với `idx_tskv_dev` — cái nào cao hơn?

---

## §1. B-tree của Postgres là B⁺-tree

### Lý thuyết

> **Dữ liệu chỉ nằm ở tầng lá. Tầng trong chỉ chứa khoá dẫn đường.**

```
                    ┌──────────────┐
   meta page (0) ──>│  root page   │        tầng 2
                    └──┬────┬───┬──┘
              ┌────────┘    │   └────────┐
         ┌────▼───┐    ┌────▼───┐   ┌────▼───┐
         │internal│    │internal│   │internal│   tầng 1
         └──┬──┬──┘    └──┬──┬──┘   └──┬──┬──┘
       ┌────▼┐┌─▼───┐   ...
       │leaf │↔│leaf │↔ ... ↔ leaf              tầng 0 — nối đôi
       └─────┘└─────┘
         └─> TID (block, offset) trỏ vào heap
```

1. **Lá nối đôi.** Range scan `ts BETWEEN a AND b` chỉ cần tìm điểm đầu một lần rồi đi ngang — không trèo cây lại. Đây là lý do range scan trên B-tree rẻ.
2. **Lá chứa TID, không chứa dòng.** TID = `(block, offset)` — địa chỉ vật lý trong heap. Muốn lấy dữ liệu vẫn phải nhảy sang heap (trừ index-only scan).
3. **Mọi lá cùng độ sâu.** Không key nào "may mắn hơn key nào".

### Làm ngay

```sql
SELECT * FROM bt_metap('idx_tskv_dev');
```
Ghi `root` (page số mấy), `level` (chiều cao, **tính từ lá = 0**), `fastroot`.

```sql
-- thống kê page root
SELECT * FROM bt_page_stats('idx_tskv_dev', (SELECT root FROM bt_metap('idx_tskv_dev')));

-- 12 page đầu: cái nào là root(r) / internal(i) / leaf(l)?
SELECT s.blkno, s.type, s.live_items, s.dead_items, s.avg_item_size, s.free_size
FROM generate_series(1, 12) AS g(b), LATERAL bt_page_stats('idx_tskv_dev', g.b) s;
```

**Ghi vào writeup:** cây cao mấy tầng? Page nào là lá, page nào là internal?

---

## §2. Cấu trúc một page index (8 KB)

### Lý thuyết

```
┌─────────────────────────────────────────┐
│ PageHeader (24 byte)                    │
├─────────────────────────────────────────┤
│ ItemId array →→→ (mỗi entry 4 byte)     │  con trỏ, mọc từ trên xuống
├─────────────────────────────────────────┤
│           khoảng trống                  │
├─────────────────────────────────────────┤
│ ←←← index tuples (key + TID)            │  dữ liệu, mọc từ dưới lên
├─────────────────────────────────────────┤
│ Special (16 byte): btpo_prev/next/flags │  riêng của B-tree
└─────────────────────────────────────────┘
```

**High key** — entry đầu của mỗi page (trừ page ngoài cùng bên phải) không trỏ đi đâu; nó ghi *"mọi khoá trong page này đều ≤ giá trị này"*. Dùng để phát hiện page đã bị tách trong lúc bạn đang đi xuống (thuật toán Lehman-Yao — lý do B-tree Postgres đọc rất song song được).

### Làm ngay

```sql
-- nhìn entry thật trong một page lá (thay <blk> bằng blkno kiểu 'l' tìm được ở §1)
SELECT itemoffset, ctid, itemlen, left(data, 40) AS data
FROM bt_page_items('idx_tskv_dev', <blk>) LIMIT 15;
```
`ctid` chính là TID trỏ vào heap. Entry `itemoffset = 1` của page không-ngoài-cùng chính là high key.

**Ghi vào writeup:** `itemlen` bằng bao nhiêu byte? Với `bigint` 8 byte thì phần dư đi đâu?

---

## §3. Fanout và chiều cao cây — phép tính đáng nhớ

### Lý thuyết

**Fanout** = số entry vừa trong một page.

Với index trên `bigint`:
```
mỗi entry ≈ 8 (key) + 6 (TID) + 4 (ItemId) + padding ≈ 20-24 byte
fanout    ≈ (8192 − 24 − 16) / 24 ≈ 340 entry/page
```

Chiều cao cho N dòng: `height ≈ log_fanout(N)`

| Số dòng | Chiều cao (fanout 340) |
|---|---|
| 1.000 | 1 tầng |
| 100.000 | 2 tầng |
| 5.000.000 | 3 tầng |
| 100.000.000 | 4 tầng |
| 40.000.000.000 | 5 tầng |

**Con số đáng nhớ nhất về B-tree:** dữ liệu tăng 340 lần thì cây chỉ cao thêm **một** tầng.

Hệ quả: **một index lookup ≈ 3-4 page read**, và page tầng trên gần như luôn nằm sẵn trong `shared_buffers`. Chi phí thật thường chỉ là **1 lần đọc page lá + 1 lần đọc page heap**.

### Làm ngay

```sql
CREATE TABLE t_small AS SELECT g AS id FROM generate_series(1, 1000) g;
CREATE TABLE t_med   AS SELECT g AS id FROM generate_series(1, 200000) g;
CREATE INDEX ON t_small(id);
CREATE INDEX ON t_med(id);

SELECT 't_small' t, * FROM bt_metap('t_small_id_idx')
UNION ALL SELECT 't_med', * FROM bt_metap('t_med_id_idx')
UNION ALL SELECT 'ts_kv', * FROM bt_metap('idx_tskv_dev');
```

**Ghi vào writeup:** bảng — số dòng | level | kích thước index. Khớp với bảng dự đoán ở trên không? **Fanout thực tế** (= `live_items` của một page internal) lệch với 340 bao nhiêu, vì sao?

---

## §4. Khoá càng rộng, cây càng tệ

### Lý thuyết

| Kiểu khoá | Độ rộng | Fanout xấp xỉ | Chiều cao cho 5M dòng |
|---|---|---|---|
| `int` | 4 B | ~450 | 3 |
| `bigint` | 8 B | ~340 | 3 |
| `uuid` | 16 B | ~250 | 3 |
| `text` ~60 B | 60 B | ~90 | 4 |
| `text` ~200 B | 200 B | ~35 | 5 |

Bài học: **index trên cột text dài vừa to vừa cao.** Nếu phải index URL/email/path dài, cân nhắc index trên hash hoặc trên prefix bằng expression index.

Cũng là lý lẽ cho `bigint` vs `uuid` làm PK: uuid rộng gấp đôi, index to gần gấp đôi, và ngẫu nhiên nên phá cả `correlation` (Day 04) lẫn gây page split khắp nơi. Nếu phải dùng uuid, dùng **UUIDv7** (sắp được theo thời gian) thay vì v4.

### Làm ngay

```sql
CREATE INDEX idx_dev_uuid     ON device(uuid);
CREATE INDEX idx_dev_meta_txt ON device((meta::text));

SELECT i.relname,
       pg_size_pretty(pg_relation_size(i.oid)) AS size,
       (SELECT level FROM bt_metap(i.relname)) AS level,
       (SELECT avg_item_size FROM bt_page_stats(i.relname, 1)) AS avg_item
FROM pg_class i JOIN pg_index x ON x.indexrelid = i.oid
WHERE i.relname IN ('idx_tskv_dev','idx_tskv_ts','idx_dev_name','idx_dev_uuid','idx_dev_meta_txt');
```

**Ghi vào writeup:** index nào to nhất trên mỗi dòng dữ liệu? Index trên `uuid` to hơn index trên `bigint` bao nhiêu %?

---

## §5. Page split — nguồn gốc của bloat và random write

### Lý thuyết

Chèn vào page lá đã đầy → Postgres **tách page**: cấp page mới, chuyển ~nửa entry sang, đẩy một khoá lên tầng cha.

Hai kịch bản khác hẳn nhau:

- **Chèn tăng dần** (`ts` append-only, `bigserial`): luôn chèn vào page ngoài cùng bên phải. Postgres nhận ra và tách theo tỷ lệ **90/10** thay vì 50/50 → index chặt, ít lãng phí.
- **Chèn ngẫu nhiên** (`uuid` v4): tách 50/50 khắp nơi → index chỉ đầy ~70%, phình to, mỗi lần chèn là một random write.

### Làm ngay

```sql
CREATE TABLE t_seq (id bigserial PRIMARY KEY, pad text);
CREATE TABLE t_rnd (id uuid PRIMARY KEY, pad text);

INSERT INTO t_seq (pad) SELECT 'x' FROM generate_series(1, 500000);
INSERT INTO t_rnd SELECT gen_random_uuid(), 'x' FROM generate_series(1, 500000);

SELECT relname, pg_size_pretty(pg_relation_size(oid)) AS size
FROM pg_class WHERE relname IN ('t_seq_pkey','t_rnd_pkey');
```
So thêm mức lấp đầy page:
```sql
SELECT 't_seq' AS t, avg(s.free_size)::int AS free_tb
FROM generate_series(1,200) AS g(b), LATERAL bt_page_stats('t_seq_pkey', g.b) s
WHERE s.type = 'l'
UNION ALL
SELECT 't_rnd', avg(s.free_size)::int
FROM generate_series(1,200) AS g(b), LATERAL bt_page_stats('t_rnd_pkey', g.b) s
WHERE s.type = 'l';
```

**Ghi vào writeup:** index nào to hơn, `free_size` trung bình chênh bao nhiêu? Đo cả thời gian của hai lệnh INSERT.

---

## §6. Deduplication (PG13+)

### Lý thuyết

Nếu một khoá lặp lại nhiều lần, B-tree gộp N entry `(key, TID)` thành **một** entry `(key, danh sách TID)`.

Với `ts_kv(device_id)` — một device có hơn 100.000 dòng — cơ chế này tiết kiệm rất nhiều.

### Làm ngay

```sql
CREATE INDEX idx_dedup_on  ON ts_kv(device_id) WITH (deduplicate_items = on);
CREATE INDEX idx_dedup_off ON ts_kv(device_id) WITH (deduplicate_items = off);
CREATE INDEX idx_ts_dedup_on  ON ts_kv(ts) WITH (deduplicate_items = on);
CREATE INDEX idx_ts_dedup_off ON ts_kv(ts) WITH (deduplicate_items = off);

SELECT relname, pg_size_pretty(pg_relation_size(oid)) AS size
FROM pg_class WHERE relname LIKE 'idx_%dedup%' ORDER BY 1;
```

**Ghi vào writeup:** tiết kiệm bao nhiêu % trên `device_id` (lặp nhiều) và trên `ts` (gần như duy nhất)? **Giải thích chênh lệch.**

### Dọn dẹp

```sql
DROP INDEX idx_dedup_on, idx_dedup_off, idx_ts_dedup_on, idx_ts_dedup_off;
DROP TABLE t_small, t_med, t_seq, t_rnd;
```

---

## Kết ngày

### Ba câu cuối

**A.** Nếu bảng to gấp 100 lần (500 triệu dòng), cây cao thêm mấy tầng? **Điều đó nói gì về khả năng scale của B-tree** — và cái gì mới thật sự hết scale khi bảng lớn?

**B. Bạn đoán sai chỗ nào ở §0?**

**C. Áp dụng vào hệ thật:** PK các bảng trong hệ bạn là `bigint` hay `uuid`? Nếu là uuid v4, ước lượng bạn đang trả giá bao nhiêu (dung lượng index + random write + correlation). Đổi sang UUIDv7 có đáng không?

### Đạt khi

Bạn tính được chiều cao cây từ số dòng và độ rộng khoá, và giải thích được vì sao một lookup trên bảng 1 tỷ dòng chỉ đắt hơn bảng 1 triệu dòng đúng một lần đọc page.

**Xong thì gõ `/review-bai`.**
