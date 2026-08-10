# Day 34 — Lời giải: jsonb & GIN

> Bài chữa. Đo thật trên `device` (50.000 dòng, 9.656 kB heap, cột `meta jsonb` trung bình 78 byte). Dữ liệu mẫu:
> ```json
> {"tags": ["outdoor"], "model": "TH-200", "hw_rev": 4}
> ```
> Bốn model phân bố gần đều: TH-200 12.769 · TH-100 12.445 · GW-10 12.410 · PWR-5 12.376.
>
> Kết luận một câu: **GIN index không cứu được query viết bằng `->>`**, và với field cố định thì **cột thật + B-tree thắng GIN 4,7× về tốc độ và 13,8× về kích thước index**.

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án đo được | Bẫy |
|---|---|---|---|
| 1 | GIN trên `device.meta` to bằng bao nhiêu % bảng? | **5,7%** (552 kB / 9.656 kB) khi mới tạo. **Nhưng sau một lệnh `UPDATE` toàn bảng, nó phình lên 4.952 kB = 51%** — gấp 9 lần. Xem §7. | Con số "GIN nhỏ mà" chỉ đúng lúc vừa build. GIN bloat rất nhanh và `VACUUM` thường không co lại. |
| 2 | `jsonb_path_ops` nhỏ hơn `jsonb_ops` bao nhiêu? | **360 kB vs 552 kB = nhỏ hơn 34,8%** (0,65×). README nói "2–3 lần" — **không đúng ở đây**. | Tỉ lệ phụ thuộc hình dạng document. Document của ta chỉ có 3 khoá; càng nhiều khoá lồng nhau thì `path_ops` càng thắng đậm. Cái nó thắng chắc chắn hơn là **số buffer index phải đọc: 6 vs 19 (3,2×)**. |
| 3 | B-tree trên `(meta->>'model')` so với GIN cho query equality — cái nào nhanh hơn? | **B-tree, 3,6 ms vs 8,1 ms — 2,2×.** Và nếu tách hẳn thành cột thật: **1,49 ms — 5,4× nhanh hơn GIN**, index chỉ 360 kB vs 4.952 kB (**13,8×**). | Bẫy ngược: B-tree expression **chỉ** phục vụ đúng biểu thức đó. Query `meta->>'hw_rev'` không dùng được nó. GIN linh hoạt, B-tree nhanh — chọn theo việc bạn có biết trước field hay không. |

---

## §1. `json` vs `jsonb`

```sql
CREATE TABLE t_j (id int, j json, jb jsonb);
INSERT INTO t_j SELECT id, meta::text::json, meta FROM device;
```

| | `json` | `jsonb` |
|---|---|---|
| Tổng `pg_column_size` | **2.840.702 B (2.774 kB)** | **3.910.552 B (3.819 kB)** |
| So sánh | 100% | **+37,7%** |
| `WHERE ->>'model' = 'TH-100'` (lần 1 / lần 2) | 34,7 / 34,1 ms | **9,28 / 8,98 ms** |
| So sánh tốc độ | 1× | **nhanh hơn 3,7×** |

**`jsonb` TO HƠN `json` 37,7%.** Đây là điều ngược trực giác nhất của §1 — nhiều người tưởng "nhị phân thì gọn hơn". Không: `jsonb` lưu thêm **header độ dài cho từng phần tử** và **bảng offset để nhảy thẳng tới khoá** mà không phải parse tuần tự. Đó chính là thứ đánh đổi lấy 3,7× tốc độ đọc field.

Cách nhớ: `json` là **file text đã được validate**; `jsonb` là **cấu trúc dữ liệu đã dựng sẵn trên đĩa**.

Ba khác biệt hành vi phải biết (không chỉ là hiệu năng):

```sql
SELECT '{"b":1,"a":2,"a":3}'::json;    -- {"b":1,"a":2,"a":3}   giữ nguyên hết
SELECT '{"b":1,"a":2,"a":3}'::jsonb;   -- {"a": 3, "b": 1}      sắp lại, bỏ khoá trùng (giữ cái cuối)
```

- **Thứ tự khoá bị sắp lại** (theo độ dài rồi theo bảng chữ cái). Nếu ai đó so sánh chuỗi JSON để phát hiện thay đổi, `jsonb` sẽ phá.
- **Khoá trùng bị loại**, giữ cái cuối cùng.
- **Khoảng trắng bị chuẩn hoá.**

### 🔧 Tình huống thực tế — chữ ký webhook và `jsonb`

Service nhận webhook từ đối tác, mỗi payload kèm HMAC ký trên **chuỗi JSON nguyên văn**. Team lưu payload vào cột `jsonb` cho tiện query, rồi khi cần xác minh lại chữ ký thì `SELECT payload::text` — chữ ký **không bao giờ khớp**, vì `jsonb` đã sắp lại khoá và bỏ khoảng trắng.

Cách đúng: hai cột.
```sql
ALTER TABLE webhook_log ADD COLUMN raw_body text;      -- nguyên văn, dùng để verify chữ ký
ALTER TABLE webhook_log ADD COLUMN payload jsonb;      -- đã parse, dùng để query
```
Trả giá bằng ~2,4× dung lượng, nhưng đó là cái giá của việc audit được. Cùng nguyên tắc áp dụng cho: log request để điều tra sự cố, payload có chữ ký số, và bất cứ thứ gì bạn có thể phải trình cho auditor.

---

## §2. Toán tử — cái nào index được

```sql
CREATE INDEX idx_meta_gin ON device USING gin(meta);   -- jsonb_ops, 552 kB
```

| Query | Dùng GIN? | Buffers | Time | Estimate vs thật |
|---|---|---|---|---|
| `meta @> '{"model":"TH-100"}'` | **✓ Bitmap Index Scan** | 1.226 (index 19) | **8,15 ms** | 12.600 vs 12.445 ✅ |
| `meta->>'model' = 'TH-100'` | **✗ Seq Scan** | 1.207 | 10,65 ms | **250 vs 12.445 — sai 50×** ❌ |
| `meta ? 'hw_rev'` | **✗ Seq Scan** | 1.207 | 12,35 ms | 49.999 vs 50.000 ✅ |
| `meta->'tags' ? 'critical'` | **✗ Seq Scan** | 1.207 | 11,44 ms | **500 vs 14.948 — sai 30×** ❌ |

**Bốn dòng này, ba lý do khác nhau — phải phân biệt được:**

**Dòng 2 — `->>` về nguyên tắc không index được bằng GIN.** GIN lưu các *phần tử* của document (khoá, giá trị). Toán tử `->>` là một *hàm trích xuất*, kết quả của nó không có trong index. Không có cách nào cứu ngoài expression index (§4) hoặc viết lại thành `@>`.

Chú ý thêm estimate `rows=250`: đó là **hằng số mặc định 0,5%** planner dùng khi không biết gì về biểu thức. Sai 50× — trong một query phức tạp hơn, con số này đủ để chọn nhầm Nested Loop và giết cả plan (Day 09).

**Dòng 3 — `?` VỀ NGUYÊN TẮC dùng được `jsonb_ops`, nhưng planner từ chối.** Đây không phải giới hạn kỹ thuật mà là **quyết định đúng**: `hw_rev` có mặt ở **cả 50.000 dòng**, đọc index rồi vẫn phải đọc hết bảng — seq scan rẻ hơn. Estimate 49.999/50.000 chính xác, planner biết rõ nó đang làm gì.

Bài học: **"query không dùng index" chưa chắc là vấn đề.** Kiểm tra estimate trước — nếu estimate đúng mà vẫn seq scan thì planner đúng.

**Dòng 4 — `meta->'tags' ? 'critical'` không dùng được index vì index nằm trên `meta`, còn biểu thức là trên `meta->'tags'`.** Đây là bẫy tinh vi nhất: toán tử `?` *có* trong danh sách hỗ trợ, cột *có* index, nhưng vế trái không phải là cột — nó là một biểu thức khác.

Hai cách sửa, đo được:

```sql
-- cách 1: viết lại bằng @> (mảng jsonb chứa phần tử)
SELECT count(*) FROM device WHERE meta @> '{"tags":["critical"]}';
-- Bitmap Index Scan on idx_meta_path, 9,91 ms, estimate 14.813 vs thật 14.948 ✅

-- cách 2: expression index riêng cho tags
CREATE INDEX ON device USING gin ((meta->'tags'));
```

Cách 1 tốt hơn: không tốn thêm index nào.

### Bảng tra nhanh — toán tử jsonb và GIN

| Toán tử | Nghĩa | `jsonb_ops` | `jsonb_path_ops` |
|---|---|---|---|
| `@>` | chứa | ✓ | **✓ (tốt hơn)** |
| `?` | có khoá này | ✓ | **✗** |
| `?|` `?&` | có khoá nào / mọi khoá | ✓ | **✗** |
| `@?` | jsonpath tồn tại | ✓ | ✓ |
| `@@` | jsonpath vị từ | ✓ | ✓ (nhưng xem §6) |
| `->` `->>` `#>` `#>>` | trích xuất | **✗** | **✗** |
| `=` `<` `>` trên jsonb | so sánh cả document | ✗ (dùng B-tree) | ✗ |

### 🔧 Tình huống thực tế — GIN index chưa từng được dùng

Bảng `event` 200 triệu dòng, cột `payload jsonb`, có GIN index 40 GB. Query nóng nhất của hệ:
```sql
SELECT * FROM event WHERE payload->>'user_id' = $1 AND created_at > $2;
```
Chạy 4 giây, seq scan. Team đã tạo GIN từ 2 năm trước và tin rằng nó đang phục vụ query này. Kiểm tra:

```sql
SELECT indexrelname, idx_scan, pg_size_pretty(pg_relation_size(indexrelid))
FROM pg_stat_user_indexes WHERE relname = 'event';
-- event_payload_gin | idx_scan = 0 | 40 GB
```

**`idx_scan = 0`.** Index 40 GB chưa từng được dùng một lần, nhưng vẫn được cập nhật ở mỗi INSERT (làm ingest chậm ~30%), vẫn nằm trong backup, vẫn phải vacuum.

Sửa: đổi query thành `payload @> jsonb_build_object('user_id', $1)` → dùng được GIN ngay, hoặc tốt hơn là tách `user_id` thành cột thật (§7). Chạy kiểm tra này trên mọi GIN index bạn có — đây là loại index bị bỏ quên nhiều nhất, vì nó "trông có vẻ đang làm việc".

---

## §3. `jsonb_ops` vs `jsonb_path_ops`

```sql
CREATE INDEX idx_meta_path ON device USING gin(meta jsonb_path_ops);
```

| | `jsonb_ops` | `jsonb_path_ops` | Chênh |
|---|---|---|---|
| Kích thước | 552 kB | **360 kB** | nhỏ hơn **34,8%** |
| `@>` 1 khoá — time | 8,343 ms | **7,021 ms** | nhanh hơn 16% |
| `@>` 1 khoá — **buffer index** | 19 | **6** | **3,2×** ít hơn |
| `@>` 2 khoá — time | 4,341 ms | **3,257 ms** | nhanh hơn 25% |
| `@>` 2 khoá — **buffer index** | 40 | **12** | **3,3×** ít hơn |
| `meta ? 'hw_rev'` | ✓ hỗ trợ | **✗ Seq Scan** | — |

**Chỉ số nói lên bản chất là "buffer index", không phải "time".** Ở lab mọi thứ nằm trong shared_buffers nên đọc 19 hay 6 page đều nhanh; trên hệ thật với index không vừa RAM, 3,2× số page đọc là 3,2× I/O ngẫu nhiên.

### Vì sao `path_ops` đọc ít page hơn

- `jsonb_ops` lưu **mỗi khoá và mỗi giá trị thành một entry riêng**. `@> '{"model":"TH-100"}'` phải tra 2 entry (`"model"` và `"TH-100"`) rồi **giao hai posting list** — và `"TH-100"` xuất hiện ở khắp nơi (kể cả nếu nó là giá trị của khoá khác), nên có false positive phải recheck.
- `jsonb_path_ops` lưu **một hash của cả (đường dẫn + giá trị)**. `@> '{"model":"TH-100"}'` tra đúng **1 entry**, gần như không false positive.

Khác biệt tăng theo số khoá trong điều kiện: `@>` 2 khoá cho `jsonb_ops` phải giao 4 posting list (40 buffer), `path_ops` chỉ giao 2 hash (12 buffer).

### Giá phải trả

```sql
BEGIN; DROP INDEX idx_meta_gin;
EXPLAIN (ANALYZE) SELECT count(*) FROM device WHERE meta ? 'hw_rev';
-- Seq Scan on device ... 12,29 ms   ← path_ops không hỗ trợ `?`
ROLLBACK;
```

`jsonb_path_ops` **không lưu khoá riêng lẻ**, nên không trả lời được "document này có khoá X không". Nếu code của bạn dùng `?`, `?|`, `?&` thì bắt buộc `jsonb_ops`.

**Quy tắc chọn:**

| Bạn dùng | Chọn |
|---|---|
| Chỉ `@>` (và `@?`) | **`jsonb_path_ops`** — luôn luôn |
| Có `?` / `?|` / `?&` | `jsonb_ops` |
| Cả hai, và bảng đủ lớn để đáng | cả hai index — nhưng hãy tự hỏi có thể viết lại `?` thành `@>` không |

Trong thực tế, hầu hết `?` viết lại được:
```sql
WHERE meta ? 'hw_rev'                  -- cần jsonb_ops
WHERE meta @> '{"hw_rev": 2}'          -- cụ thể hơn, dùng path_ops, và thường là cái bạn thật sự muốn
```

---

## §4. B-tree trên expression — đôi khi thắng cả GIN

```sql
CREATE INDEX idx_meta_model_btree ON device ((meta->>'model'));
```

Bảng 3×3 (đo ngay sau khi tạo, chưa có UPDATE nào làm bloat):

| | `jsonb_ops` GIN | `jsonb_path_ops` GIN | B-tree expression |
|---|---|---|---|
| **Kích thước** | 552 kB | 360 kB | **360 kB** |
| **Tốc độ query equality** | 8,34 ms (`@>`) | 7,02 ms (`@>`) | **3,61 ms** (`->>`) |
| **Buffer index đọc** | 19 | 6 | 12 |
| **Estimate của planner** | 12.434 vs 12.445 ✅ | 12.434 vs 12.445 ✅ | **12.502 vs 12.445** ✅ |
| Trả lời được `?` | ✓ | ✗ | ✗ |
| Trả lời được field khác | ✓ | ✓ | **✗ chỉ `model`** |
| Trả lời được `tags` chứa X | ✓ | ✓ | ✗ |

**Một phát hiện quan trọng: cả ba đều cho estimate chính xác.** Điều này ngược với dòng 2 của §2 (estimate 250 vs 12.445). Lý do: **`ANALYZE` thu thập statistics cho biểu thức đã được index**. Tạo `CREATE INDEX ON device ((meta->>'model'))` không chỉ tăng tốc query — nó còn dạy planner ước lượng đúng cho **mọi** query có biểu thức đó, kể cả những query không dùng chính index đó.

Đây là một trong những lý do mạnh nhất để tạo expression index mà ít người biết: **đôi khi bạn tạo nó chỉ để lấy statistics**. (Nếu chỉ cần statistics mà không cần index, dùng `CREATE STATISTICS ... ON (meta->>'model') FROM device` — Day 19.)

### Quy tắc chọn

```
Query bằng `=` trên MỘT field cố định, biết trước
   → cột thật + B-tree  (§7 — nhanh nhất, nhỏ nhất)
   → nếu không đổi được schema: B-tree expression

Query trên VÀI field cố định
   → vài B-tree expression, hoặc composite nếu luôn đi cùng nhau

Query linh hoạt: người dùng chọn field lúc chạy, tìm trong mảng, filter động
   → GIN
   → chỉ dùng @>  ⇒ jsonb_path_ops
   → có dùng ?    ⇒ jsonb_ops

Query có `<` `>` `BETWEEN` trên field số
   → BẮT BUỘC B-tree expression có ép kiểu: ((meta->>'hw_rev')::int)
   → GIN không làm được so sánh thứ tự (xem §6)
```

Dòng cuối là chỗ nhiều người vấp: GIN hoàn toàn **không phục vụ được bất đẳng thức**. `meta @@ '$.hw_rev > 2'` seq scan (§6, 18,7 ms). Muốn index thì:

```sql
CREATE INDEX ON device (((meta->>'hw_rev')::int));
```
Nhớ hai lớp ngoặc, và nhớ rằng phép ép kiểu này chỉ IMMUTABLE với `int` — với `timestamptz` thì không (Day 12 đã gặp).

---

## §5. Chi phí ghi của GIN và `fastupdate`

Hai bảng giống hệt, chỉ khác `fastupdate`. `gin_pending_list_limit` = 4MB (mặc định).

| | `fastupdate = on` | `fastupdate = off` | Chênh |
|---|---|---|---|
| **INSERT 50.000 dòng** | **247,3 ms** | 1.205,6 ms | **nhanh hơn 4,88×** |
| **Kích thước index sau insert** | **3.264 kB** | 384 kB | **to hơn 8,5×** |
| **Đọc ngay sau ghi** | 12,93 ms — **Seq Scan** | **6,72 ms** — Bitmap Index Scan | chậm hơn 1,9× |
| Sau `VACUUM` | 6,03 ms — Bitmap Index Scan | — | ngang nhau |
| **Kích thước index sau `VACUUM`** | **3.592 kB** | 384 kB | **vẫn to hơn 9,4×** |

Ba điều đo được, mỗi điều là một bài học riêng:

**1. `fastupdate = on` làm INSERT nhanh gần 5 lần.** Thay vì tìm đúng chỗ trong cây B-tree cho từng entry (mỗi document 3 khoá ⇒ ~3 entry ⇒ 150.000 lần chèn có sắp xếp), nó chỉ append vào một danh sách chờ chưa sắp xếp.

**2. Đọc ngay sau ghi thì planner *từ chối dùng index luôn*.**

```
->  Seq Scan on t_gin  (cost=0.00..1844.89 rows=906) (actual rows=12445)
      Filter: (doc @> '{"model": "TH-100"}'::jsonb)
```

Đây là chi tiết tinh tế nhất của cả ngày: **planner biết pending list dài** (nó tính vào cost của GIN scan) và kết luận seq scan rẻ hơn (cost 1.844 vs cost của index scan cao hơn thế). Nó không "quên" index — nó tính ra rằng quét tuyến tính pending list 2.880 kB tốn hơn quét bảng.

Hệ quả trên production: **query latency của bạn không xấu đi từ từ, nó nhảy bậc.** Chạy êm 5 ms, rồi khi pending list vượt ngưỡng, plan đổi sang seq scan và latency thành 400 ms trong một khoảnh khắc. Rồi autovacuum chạy, pending list được gộp, latency về 5 ms. Bạn có một biểu đồ latency răng cưa mà không đổi gì trong code — dấu hiệu nhận biết cực kỳ đặc trưng của GIN + fastupdate.

**3. `VACUUM` gộp pending list nhưng KHÔNG thu nhỏ index: 3.264 kB → 3.592 kB (to thêm!) so với 384 kB.** Index vẫn phình gấp **9,4 lần** so với bản build sạch. Giống hệt bài học Day 33 §1 về `VACUUM` và heap: dọn được nội dung, không trả được chỗ. Muốn về 384 kB phải `REINDEX`.

### Quyết định `fastupdate`

| Tình huống | Chọn | Lý do |
|---|---|---|
| Ingest nặng, đọc thưa/analytics | `on` (mặc định) | 4,9× throughput ghi |
| Đọc nhiều, cần **latency ổn định** (API đồng bộ, SLO p99) | **`off`** | không có răng cưa, không có nhảy plan |
| `on` nhưng muốn giảm biên độ răng cưa | giảm `gin_pending_list_limit` xuống 512 kB–1 MB | gộp thường xuyên hơn, mỗi lần rẻ hơn |

```sql
ALTER INDEX idx_meta_gin SET (fastupdate = off);
-- hoặc
ALTER INDEX idx_meta_gin SET (gin_pending_list_limit = '512kB');
-- gộp thủ công không cần vacuum toàn bảng:
SELECT gin_clean_pending_list('idx_meta_gin');
```

`gin_clean_pending_list()` là công cụ ít biết nhưng rất hữu ích: gộp pending list mà không phải chạy `VACUUM` cả bảng — chạy được từ cron mỗi vài phút.

### 🔧 Tình huống thực tế — p99 răng cưa không ai giải thích được

Search API trên bảng `product` (jsonb attributes, GIN, `fastupdate=on` mặc định). Grafana cho thấy p99 dao động 8 ms ↔ 600 ms theo chu kỳ ~40 phút. Không tương quan với traffic, không tương quan với deploy. Team nghi network, nghi GC của app, đổi instance type — không đổi.

Nguyên nhân: catalog sync ghi ~50k sản phẩm mỗi 40 phút → pending list phình → planner đổi sang seq scan → p99 nhảy → autovacuum chạy → về bình thường.

Cách chẩn đoán: `pgstatginindex` cho thấy pending list dài.
```sql
CREATE EXTENSION IF NOT EXISTS pgstattuple;
SELECT * FROM pgstatginindex('idx_product_attrs');
-- version | pending_pages | pending_tuples
--       2 |           340 |          52000     ← đây
```
Sửa: `fastupdate = off` (API này đọc nhiều hơn ghi rất nhiều), p99 phẳng ở 9 ms, catalog sync chậm hơn 4× nhưng nó là job nền, không ai quan tâm.

---

## §6. jsonpath (SQL/JSON)

| Query | Dùng GIN? | Buffers | Time |
|---|---|---|---|
| `meta @? '$.model ? (@ == "TH-100")'` | **✓ `idx_meta_path`** | 1.213 (index 6) | **8,47 ms** |
| `meta @> '{"model":"TH-100"}'` | ✓ | 1.213 (index 6) | **7,02 ms** |
| `meta @@ '$.hw_rev > 2'` | **✗ Seq Scan** | 1.207 | **18,69 ms** |
| `jsonb_path_exists(meta, '$.tags[*] ? (@ == "critical")')` | **✗** (là hàm, không phải toán tử) | — | 24,06 ms |
| `meta @> '{"tags":["critical"]}'` | ✓ | 1.214 (index 7) | **9,91 ms** |

**Kết luận thẳng: `@?` dùng được GIN nhưng chậm hơn `@>` tương đương (8,47 vs 7,02 ms), và `@@` với bất đẳng thức thì mất index hoàn toàn.**

Lý do `@@ '$.hw_rev > 2'` không index được: GIN là **inverted index** — nó ánh xạ *giá trị → danh sách dòng*. Nó trả lời được "dòng nào có `hw_rev = 3`" nhưng không có khái niệm thứ tự để trả lời "dòng nào có `hw_rev > 2`". Muốn thế cần cấu trúc có thứ tự = B-tree:

```sql
CREATE INDEX ON device (((meta->>'hw_rev')::int));
SELECT count(*) FROM device WHERE (meta->>'hw_rev')::int > 2;   -- giờ mới index được
```

`jsonb_path_exists(...)` là **hàm**, không phải toán tử — planner không có cách nào ánh xạ nó vào operator class của GIN. Chậm nhất bảng (24 ms). Chỉ dùng khi cần kết quả mà toán tử không diễn đạt được.

### Vậy jsonpath để làm gì?

Không phải để tăng tốc — mà để **diễn đạt những thứ `@>` không diễn đạt được**:

```sql
-- lấy giá trị, không phải lọc dòng
SELECT id, jsonb_path_query_array(meta, '$.tags[*]') FROM device LIMIT 5;
--  1 | ["outdoor"]
--  3 | ["indoor", "floor-1"]

-- điều kiện phức hợp trên phần tử mảng — @> không làm được
WHERE meta @? '$.sensors[*] ? (@.type == "temp" && @.value > 80)'

-- đi sâu không biết trước cấu trúc
WHERE meta @? '$.**.serial ? (@ == "X123")'
```

Dòng thứ hai là chỗ jsonpath thật sự không thể thay thế: **"có phần tử nào trong mảng vừa thoả điều kiện A vừa thoả điều kiện B"**. Với `@>` bạn chỉ kiểm tra được containment nguyên vẹn.

### 🔧 Tình huống thực tế — `@>` cho câu trả lời sai trên mảng object

Cảnh báo: `@>` trên mảng object **không ràng buộc các điều kiện phải cùng một phần tử**.

```sql
-- doc = {"sensors": [{"type":"temp","value":20}, {"type":"humid","value":90}]}
SELECT doc @> '{"sensors":[{"type":"temp"},{"value":90}]}';   -- TRUE (!)
```

Trả `true` dù không có sensor nào vừa `type=temp` vừa `value=90` — vì `@>` chỉ đòi mỗi phần tử điều kiện tìm được *một* phần tử khớp, không nhất thiết cùng một cái. Một hệ cảnh báo viết theo kiểu này sẽ báo động giả.

Đúng phải dùng jsonpath:
```sql
WHERE doc @? '$.sensors[*] ? (@.type == "temp" && @.value == 90)'
```
Hoặc `@>` với object nguyên vẹn: `doc @> '{"sensors":[{"type":"temp","value":90}]}'`.

Đây là loại bug im lặng nhất trong toàn bộ jsonb: query chạy, không lỗi, chỉ là sai.

---

## §7. Khi nào **không** nên dùng jsonb

### a) Cột thật thắng áp đảo

```sql
ALTER TABLE device ADD COLUMN model_col text;
UPDATE device SET model_col = meta->>'model';
CREATE INDEX idx_model_col ON device(model_col);
VACUUM ANALYZE device;
```

| Cách | Plan | Buffers | Time | Index size |
|---|---|---|---|---|
| **Cột thật + B-tree** | **Index Only Scan**, `Heap Fetches: 0` | **13** | **1,49 ms** | **360 kB** |
| B-tree expression `->>` | Bitmap Heap Scan | 1.259 | 3,49 ms | 688 kB |
| GIN `jsonb_path_ops` + `@>` | Bitmap Heap Scan | 1.256 | 7,02 ms | 3.848 kB |
| GIN `jsonb_ops` + `@>` | Bitmap Heap Scan | — | — | 4.952 kB |

**Cột thật nhanh hơn GIN 4,7×, đọc ít hơn 97 lần buffer, index nhỏ hơn 13,8 lần.**

Lý do quyết định là **`Index Only Scan` với `Heap Fetches: 0`** — nó không chạm heap một lần nào, chỉ đọc 13 page index. GIN thì bắt buộc phải quay về heap để recheck (`Bitmap Heap Scan`, 1.248 heap block). Đây là điều GIN **về cấu trúc không bao giờ làm được**: GIN là lossy, luôn phải recheck.

### b) GIN vừa bị bloat 9× bởi một lệnh `UPDATE`

So kích thước index trước và sau khi chạy `UPDATE device SET model_col = ...`:

| Index | Trước UPDATE | Sau UPDATE | Phình |
|---|---|---|---|
| `idx_meta_gin` | 552 kB | **4.952 kB** | **9,0×** |
| `idx_meta_path` | 360 kB | **3.848 kB** | **10,7×** |
| `idx_meta_model_btree` | 360 kB | 688 kB | 1,9× |
| `idx_model_col` (mới) | — | 360 kB | — |

**Một lệnh `UPDATE` không hề đụng vào `meta` đã làm cả hai GIN index phình 9–11 lần.** Vì `UPDATE` trong Postgres = xoá + chèn dòng mới (Day 21), và dòng mới có ctid mới ⇒ **mọi index phải thêm entry mới**, kể cả index trên cột không đổi. GIN chịu nặng nhất vì mỗi document sinh nhiều entry.

B-tree chỉ phình 1,9× vì nó có cấu trúc chặt hơn và tái dùng chỗ tốt hơn.

**Hệ quả thực tế:** trên bảng có GIN index, một migration kiểu `ALTER TABLE ADD COLUMN` + `UPDATE` toàn bảng có thể làm index từ 40 GB thành 400 GB. Sau mọi backfill lớn trên bảng có GIN, **luôn `REINDEX CONCURRENTLY`**:

```sql
REINDEX INDEX CONCURRENTLY idx_meta_gin;
```

(Day 43–44 sẽ nói kỹ hơn về mẫu backfill theo lô để tránh chuyện này ngay từ đầu.)

### c) Statistics: cột thật cho planner thứ jsonb không cho được

```sql
SELECT attname, n_distinct, most_common_vals FROM pg_stats WHERE tablename='device';
```

| Cột | `n_distinct` | `most_common_vals` |
|---|---|---|
| `model_col` | **4** | `{TH-200, PWR-5, GW-10, TH-100}` — sạch, dùng được |
| `meta` | **240** | 62 **document nguyên vẹn** — `{"tags":["outdoor"],"model":"TH-100","hw_rev":1}` … |

Postgres coi cả document `jsonb` là **một giá trị vô hướng**. MCV của nó là danh sách document, không phải danh sách giá trị field. Nên planner không có cách nào ước lượng `meta->>'model' = 'TH-100'` từ statistics này — đó chính là lý do estimate ở §2 là 250 (hằng số mặc định) thay vì 12.445.

Ba lối thoát, theo thứ tự ưu tiên: **cột thật** > `CREATE STATISTICS ON (meta->>'model')` > expression index.

### d) TOAST — nhưng không phải như bạn nghĩ

Trước hết, `device.meta` **không hề bị TOAST**: max 85 byte, TOAST table 8.192 byte (rỗng). Ngưỡng TOAST là ~2 kB.

README gợi ý demo bằng `repeat('x', 5000)`. Đo thật:

```sql
INSERT INTO t_big SELECT g, jsonb_build_object('id',g,'pad',repeat('x',5000),'v',g) FROM generate_series(1,20000) g;
SELECT pg_column_size(doc), length(doc::text) FROM t_big LIMIT 1;
--  119 | 5028
```

**5.028 byte nén xuống 119 byte — vẫn nằm inline, TOAST chỉ 0,3% (8 kB).** 5.000 chữ 'x' giống hệt nhau thì thuật toán nén (pglz/lz4) xoá sổ. Demo của README **không tái hiện được TOAST**.

Làm lại với payload không nén được (md5 ngẫu nhiên, 5.120 ký tự):

| | `t_big3` (jsonb, TOAST) | `t_big4` (cột thật, cùng dữ liệu) |
|---|---|---|
| Kích thước / dòng | 5.172 byte | — |
| Bảng chính | 1.024 kB | 1.184 kB |
| **TOAST** | **113 MB = 99,1%** | 113 MB |
| Tổng | 114 MB | 114 MB |
| `WHERE (doc->>'v')::int > 19000` | **71.556 buffer, 71,35 ms** | — |
| `WHERE v > 19000` | — | **148 buffer, 1,15 ms** |
| **Chênh** | | **483× buffer, 62× thời gian** |

**Đây là con số đắt giá nhất của cả ngày.** Cùng lượng dữ liệu trên đĩa (114 MB cả hai), nhưng:

- **Cột thật:** `v` là `int` 4 byte nằm inline trong dòng heap. Seq scan chỉ đọc 148 page của bảng chính, phần `pad` khổng lồ nằm trong TOAST **không bao giờ bị chạm tới**.
- **jsonb:** để lấy `doc->>'v'`, Postgres phải **de-TOAST toàn bộ document 5 kB** — nạp và giải nén cả cái `pad` mà bạn không cần. 71.556 buffer.

> **Quy tắc: một field bạn hay lọc mà nằm trong cùng document jsonb với một field lớn → mỗi lần lọc bạn trả tiền cho cả field lớn.**

Sửa bằng cách tách: field nhỏ hay query ra cột thật, phần lớn/hiếm dùng giữ trong jsonb (hoặc cột `text` riêng). Bảng vẫn 114 MB, nhưng query nhanh hơn 62 lần.

Có thể chỉnh chiến lược lưu trữ để ép ra TOAST sớm hơn (Day 41):
```sql
ALTER TABLE t SET (toast_tuple_target = 512);       -- đẩy ra TOAST sớm hơn
ALTER TABLE t ALTER COLUMN doc SET STORAGE EXTERNAL; -- không nén, chỉ lưu ngoài
```
Nhưng nó **không** cứu được vấn đề ở đây: de-TOAST vẫn phải nạp cả document. Chỉ tách cột mới cứu được.

### 🔧 Tình huống thực tế — bảng `order` với `raw_payload`

Bảng `order` có cột `data jsonb` chứa cả: `status` (query mọi lúc), `customer_id` (query mọi lúc), và `raw_gateway_response` (payload 40 kB từ cổng thanh toán, đọc 1 lần/tháng khi có tranh chấp).

Query dashboard `WHERE data->>'status' = 'pending'` phải de-TOAST 40 kB cho **mỗi dòng** chỉ để đọc 7 ký tự. Bảng 2 triệu đơn: 80 GB de-TOAST cho một câu đếm.

Thiết kế lai đúng:
```sql
ALTER TABLE "order"
  ADD COLUMN status text NOT NULL DEFAULT 'pending',   -- cột thật: query mọi lúc, cần CHECK
  ADD COLUMN customer_id bigint REFERENCES customer,   -- cột thật: cần FK
  ADD COLUMN gateway_raw jsonb;                        -- tách riêng: to, hiếm đọc
ALTER TABLE "order" ADD CONSTRAINT ck_status
  CHECK (status IN ('pending','paid','failed','refunded'));
CREATE INDEX ON "order" (status) WHERE status = 'pending';   -- partial, Day 08
```

Chú ý hai thứ jsonb **không bao giờ** cho được: **`CHECK` constraint** trên `status` và **`FOREIGN KEY`** trên `customer_id`. Đó thường là lý do quan trọng hơn cả hiệu năng để tách cột — với jsonb, không gì ngăn ai đó ghi `"status": "PENDING"` hay `"status": null` vào cùng bảng.

### Checklist: field nào nên tách khỏi jsonb

| Dấu hiệu | Vì sao |
|---|---|
| Có mặt ở **mọi** dòng | không cần schema linh hoạt — đó là một cột |
| Xuất hiện trong `WHERE` / `ORDER BY` / `GROUP BY` | cột thật + B-tree rẻ hơn 5–60× |
| Cần `NOT NULL`, `CHECK`, `FOREIGN KEY`, `UNIQUE` | jsonb **không làm được** |
| Cần kiểu chặt (số, ngày, enum) | jsonb lưu text, ép kiểu mỗi lần đọc, ép sai thì lỗi lúc chạy |
| Cần planner ước lượng đúng | cột thật có `pg_stats` đầy đủ |
| Nằm cùng document với field > 2 kB | mỗi lần đọc phải de-TOAST cả document |

Giữ trong jsonb khi: field thật sự thưa (chỉ vài % dòng có), tập field thay đổi theo khách hàng/phiên bản, hoặc bạn chỉ lưu để hiển thị/audit chứ không lọc.

---

## Bảng số liệu chính

| Phép đo | Kết quả |
|---|---|
| `json` vs `jsonb` — dung lượng | 2.774 kB vs **3.819 kB — `jsonb` to hơn 37,7%** |
| `json` vs `jsonb` — đọc field `->>` | 34,7 ms vs **9,28 ms — `jsonb` nhanh 3,7×** |
| GIN `jsonb_ops` mới build | 552 kB = **5,7%** kích thước bảng |
| `meta @> '{"model":...}'` | GIN, 1.226 buffer, **8,15 ms** |
| `meta->>'model' = ...` (chưa có expression index) | **Seq Scan**, 10,65 ms, estimate **250 vs 12.445 (sai 50×)** |
| `meta ? 'hw_rev'` | Seq Scan — **planner đúng**, 50.000/50.000 dòng khớp |
| `meta->'tags' ? 'critical'` | Seq Scan — index trên `meta`, biểu thức trên `meta->'tags'` |
| `jsonb_path_ops` vs `jsonb_ops` — kích thước | 360 kB vs 552 kB — **nhỏ hơn 34,8%** |
| `@>` 1 khoá — buffer index | **6 vs 19 — ít hơn 3,2×** |
| `@>` 2 khoá — buffer index | **12 vs 40 — ít hơn 3,3×** |
| `?` với chỉ `jsonb_path_ops` | **Seq Scan — không hỗ trợ** |
| B-tree expression `(meta->>'model')` | 360 kB, **3,61 ms** — nhanh hơn GIN 2,2× |
| Expression index → statistics | estimate **12.502 vs 12.445 ✅** (thay vì 250) |
| GIN `fastupdate=on` vs `off` — INSERT 50k | **247 ms vs 1.206 ms — nhanh 4,88×** |
| — kích thước index sau insert | **3.264 kB vs 384 kB — to 8,5×** |
| — đọc ngay sau ghi | **Seq Scan 12,93 ms** vs Index Scan 6,72 ms |
| — sau `VACUUM` | 6,03 ms, nhưng index **3.592 kB — vẫn to 9,4×** |
| `@?` jsonpath | ✓ GIN, 8,47 ms — chậm hơn `@>` (7,02 ms) |
| `@@ '$.hw_rev > 2'` | **✗ Seq Scan, 18,69 ms** — GIN không làm bất đẳng thức |
| `jsonb_path_exists(...)` | ✗ (là hàm), 24,06 ms — chậm nhất |
| **Cột thật + B-tree** | **Index Only Scan, 13 buffer, 1,49 ms, index 360 kB** |
| So với GIN `@>` | **nhanh 4,7×, buffer ít 97×, index nhỏ 13,8×** |
| GIN bloat sau 1 lệnh `UPDATE` toàn bảng | `jsonb_ops` **552 → 4.952 kB (9,0×)**, `path_ops` **360 → 3.848 kB (10,7×)** |
| B-tree bloat cùng lệnh đó | 360 → 688 kB (1,9×) |
| `pg_stats` cho `model_col` | `n_distinct = 4`, MCV sạch |
| `pg_stats` cho `meta` | `n_distinct = 240`, MCV là **document nguyên vẹn** — vô dụng cho planner |
| `repeat('x',5000)` trong jsonb | **5.028 → 119 byte sau nén, KHÔNG bị TOAST** |
| Payload ngẫu nhiên 5 kB | **TOAST = 99,1%** (113 MB / 114 MB) |
| `WHERE (doc->>'v')::int > 19000` (có TOAST) | **71.556 buffer, 71,35 ms** |
| Cùng dữ liệu, cột thật `WHERE v > 19000` | **148 buffer, 1,15 ms — 483× buffer, 62× thời gian** |

---

## Ba điều dễ hiểu sai

| Hiểu nhầm | Sự thật đo được |
|---|---|
| "Tạo GIN index rồi thì query jsonb sẽ nhanh." | `meta->>'model' = 'TH-100'` **Seq Scan** dù có GIN — `->>` về nguyên tắc không index được bằng GIN. Và estimate rơi về hằng số mặc định **250 vs thật 12.445 (sai 50×)**, đủ để giết plan của một query phức tạp. Phải viết `meta @> '{"model":"TH-100"}'` hoặc tạo expression index. Kiểm tra ngay hôm nay: `SELECT indexrelname, idx_scan FROM pg_stat_user_indexes` — GIN có `idx_scan = 0` là chuyện rất thường. |
| "`jsonb` nhỏ gọn hơn `json` vì nó là nhị phân." | **`jsonb` to hơn 37,7%** (3.819 kB vs 2.774 kB). Nó lưu thêm header độ dài và bảng offset cho từng khoá — đó chính là thứ đổi lấy **3,7× tốc độ đọc field** và khả năng index. Bạn trả dung lượng để mua tốc độ đọc, không phải ngược lại. |
| "jsonb chỉ chậm hơn cột thật một chút, tiện hơn nhiều." | Với document nhỏ: chậm hơn **4,7×**, index to hơn **13,8×**. Với document có field lớn bị TOAST: **chậm hơn 62 lần, đọc nhiều hơn 483 lần buffer** — vì lọc một field `int` phải de-TOAST cả document 5 kB. Cộng thêm: không có `CHECK`, không có `FOREIGN KEY`, planner ước lượng mù, và một lệnh `UPDATE` làm GIN phình **9×**. |

---

## Áp dụng vào hệ thật

1. **Trước tiên, tìm GIN index chưa từng được dùng** — 5 phút, có thể tiết kiệm hàng chục GB:
   ```sql
   SELECT s.relname, s.indexrelname, s.idx_scan,
          pg_size_pretty(pg_relation_size(s.indexrelid)) AS size
   FROM pg_stat_user_indexes s
   JOIN pg_index i ON i.indexrelid = s.indexrelid
   JOIN pg_class c ON c.oid = i.indexrelid
   JOIN pg_am am ON am.oid = c.relam
   WHERE am.amname = 'gin'
   ORDER BY s.idx_scan, pg_relation_size(s.indexrelid) DESC;
   ```
   `idx_scan = 0` + kích thước lớn = bạn đang trả tiền ghi, tiền đĩa, tiền backup cho không.

2. **Grep code tìm `->>` trên cột jsonb đã có GIN.** Mỗi chỗ có 3 lựa chọn, theo thứ tự:
   ```sql
   -- (a) tốt nhất: tách cột thật (nếu field có ở mọi dòng và hay query)
   -- (b) viết lại thành @>  — không cần index mới
   WHERE meta @> jsonb_build_object('model', $1)
   -- (c) expression index — khi không đổi được query
   CREATE INDEX CONCURRENTLY ON device ((meta->>'model'));
   ```
   Với ThingsBoard, `device.additional_info` và `device_attributes` là chỗ đầu tiên nên soi.

3. **Đổi mọi GIN `@>`-only sang `jsonb_path_ops`:**
   ```sql
   CREATE INDEX CONCURRENTLY idx_new ON t USING gin (col jsonb_path_ops);
   DROP INDEX CONCURRENTLY idx_old;
   ```
   Nhỏ hơn ~35%, đọc ít hơn ~3× số page index. Điều kiện: code không dùng `?` `?|` `?&` — grep để chắc.

4. **Quyết định `fastupdate` theo hình dạng tải, đừng để mặc định:**
   ```sql
   CREATE EXTENSION IF NOT EXISTS pgstattuple;
   SELECT * FROM pgstatginindex('idx_ten_index');   -- pending_pages lớn = đang răng cưa
   ```
   API đồng bộ có SLO p99 → `fastupdate = off`. Ingest nặng → giữ `on` nhưng thêm cron `SELECT gin_clean_pending_list('idx')` mỗi 5 phút.

5. **`REINDEX CONCURRENTLY` mọi GIN sau backfill lớn.** Một `UPDATE` toàn bảng làm GIN phình 9–11×. Thêm bước này vào runbook migration, ngay sau bước backfill:
   ```sql
   REINDEX INDEX CONCURRENTLY idx_meta_gin;
   ```

6. **Kiểm tra field lớn nằm chung document với field hay lọc** — đây là chỗ mất 62× hiệu năng:
   ```sql
   SELECT avg(pg_column_size(payload))::int AS trung_binh,
          max(pg_column_size(payload)) AS lon_nhat,
          count(*) FILTER (WHERE pg_column_size(payload) > 2000) AS so_dong_bi_toast
   FROM your_table;
   ```
   Có dòng bị TOAST + có query lọc theo field nhỏ trong đó ⇒ tách ngay.

7. **Áp checklist "nên tách thành cột thật" cho từng cột jsonb đang có.** Ưu tiên các field cần `CHECK`/`FK` — đó là rủi ro dữ liệu bẩn, không chỉ là hiệu năng. Với jsonb, không gì ngăn `"status": "PENDING"` và `"status": "pending"` cùng tồn tại.

8. **Cẩn thận với `@>` trên mảng object.** `doc @> '{"a":[{"x":1},{"y":2}]}'` **không** yêu cầu cùng một phần tử thoả cả hai. Nếu logic của bạn cần thế, dùng jsonpath `$.a[*] ? (@.x == 1 && @.y == 2)`. Đây là bug im lặng — query chạy đúng cú pháp, chỉ là trả sai kết quả.

---

## Câu hỏi mở sang các ngày sau

- **Day 35** khép lại tuần 7 bằng đúng câu hỏi hôm nay đặt ra: với telemetry, chọn EAV (`ts_kv` — mỗi metric một dòng), jsonb (mỗi mẫu một document), hay cột rộng? Số liệu §7 hôm nay (cột thật thắng 62×) là một phiếu bầu rất mạnh, nhưng cột rộng lại kém linh hoạt nhất. Câu trả lời gần như chắc chắn là **lai**.
- **Day 41 (TOAST)** đào sâu phần §7d: `toast_tuple_target`, `STORAGE EXTERNAL/EXTENDED`, `lz4` vs `pglz`, và vì sao chỉnh chiến lược lưu trữ **không** cứu được vấn đề de-TOAST-để-đọc-một-field.
- **Day 43–44** trả lời phần bloat ở §7b: mẫu backfill theo lô để `UPDATE` toàn bảng không làm GIN phình 9×, và `REINDEX CONCURRENTLY` khi nào an toàn.
- **Day 19** quay lại ở §4: `CREATE STATISTICS ON (meta->>'model') FROM device` cho planner ước lượng đúng mà không phải trả tiền cho một index. Khi nào chọn nó thay expression index?
- **Day 23 (autovacuum)** nhìn từ §5: GIN với `fastupdate=on` phụ thuộc vào autovacuum để gộp pending list. Nếu autovacuum bị tụt lại trên bảng đó (Day 23 §4), latency query GIN nhảy bậc — một liên kết nhân quả không hiển nhiên chút nào giữa hai bài.

---

### Dọn dẹp

```sql
ALTER TABLE device DROP COLUMN model_col;
DROP INDEX idx_meta_gin, idx_meta_path, idx_meta_model_btree;
DROP TABLE t_j, t_gin, t_gin2, t_big, t_big2, t_big3, t_big4;
REINDEX TABLE device;   -- thu hồi bloat từ lệnh UPDATE ở §7
VACUUM ANALYZE device;
```
