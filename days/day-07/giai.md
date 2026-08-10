# Day 07 — Lời giải: Composite index & quy tắc leftmost

> Bài chữa. Đo thật trên lab `SCALE=1`. Bắt đầu bằng việc xoá hết index cũ và tạo đúng 2 index đối xứng: `idx_dev_ts(device_id, ts)` và `idx_ts_dev(ts, device_id)` — **cùng 150 MB, cùng số cột, chỉ khác thứ tự**.

---

## §0. Đáp án phần đoán

Với `WHERE device_id = 42 AND ts >= '2025-06-01' AND ts < '2025-06-02'`:

| Câu hỏi | Đáp án |
|---|---|
| Planner chọn index nào? | **`idx_dev_ts`** — 4 buffer, 0,033 ms |
| Ép dùng `idx_ts_dev` thì sao? | **217 buffer, 2,045 ms — chậm 62 lần** |
| `Rows Removed by Filter` bao nhiêu? | **0** — và đây là bẫy, xem dưới |

### ⚠️ Bẫy quan trọng nhất bài này: `Index Cond` không đảm bảo index đang làm việc

Đề bài (và hầu hết tài liệu) dạy: điều kiện vào `Index Cond` = tốt, rơi xuống `Filter` = xấu. Số đo cho thấy điều đó **chưa đủ**.

```
-- ép idx_ts_dev (thứ tự SAI)
Index Only Scan using idx_ts_dev on ts_kv  (actual time=0.108..2.027 rows=31)
  Index Cond: ((ts >= '2025-06-01') AND (ts < '2025-06-02') AND (device_id = 42))
                                                              ^^^^^^^^^^^^^^^^^
  Buffers: shared hit=217
```

`device_id = 42` **vẫn nằm trong `Index Cond`**, và `Rows Removed by Filter` = 0. Nhìn plan thì "hoàn hảo".

Nhưng buffers tố cáo: **217 vs 4**.

Lý do: Postgres phân biệt hai loại điều kiện trong `Index Cond`:

| Loại | Vai trò | Ở đây |
|---|---|---|
| **boundary qual** | quyết định **bắt đầu và dừng ở đâu** trong cây | `ts BETWEEN ...` |
| **non-boundary qual** | lọc từng entry **trong lúc quét**, không thu hẹp phạm vi | `device_id = 42` |

Cả hai đều in ra dưới nhãn `Index Cond`. Nhưng chỉ boundary qual mới giảm số page phải đọc.

> **Sửa lại luật của Day 02: `Index Cond` tốt hơn `Filter` (đỡ phải lên heap), nhưng chỉ **BUFFERS** mới nói được index có thật sự thu hẹp phạm vi không. Điều kiện lọt vào `Index Cond` mà buffers vẫn cao = đang quét cả nhánh rồi lọc.**

---

## §1. Quy tắc leftmost

| Query | Index được chọn | buffers | time |
|---|---|---|---|
| `WHERE device_id = 42` | **`idx_dev_ts`** | 22 | 0,63 ms |
| `WHERE ts BETWEEN ...` | **`idx_ts_dev`** | 217 | 8,89 ms |

Mỗi query dùng đúng index có cột lọc đứng **đầu**.

### `idx_dev_ts` có dùng được cho query 2 không

**Không hiệu quả.** Bằng chứng — ép bỏ `idx_ts_dev`:

```
-b ép idx_dev_ts cho query chỉ lọc ts
Seq Scan on ts_kv  (actual time=109.060..340.350 rows=55563)
  Filter: ((ts >= '2025-06-01') AND (ts < '2025-06-02'))
  Rows Removed by Filter: 4944437
  Buffers: shared hit=20005 read=16953
Execution Time: 342.885 ms
```

Planner **thà quét toàn bảng (343 ms) còn hơn dùng `idx_dev_ts`**. Chậm hơn 39 lần so với `idx_ts_dev` (8,9 ms).

Giải thích bằng danh bạ: index `(device_id, ts)` sắp theo `device_id` trước. Muốn tìm mọi dòng có `ts` trong một ngày, phải mở **mọi** nhóm `device_id` ra xem — tức quét toàn bộ index. Index 150 MB, bảng 289 MB → quét index không rẻ hơn quét bảng bao nhiêu, mà lại mất thêm bước lên heap.

Đối xứng ngược lại (§3, Q3): ép `idx_ts_dev` cho `WHERE device_id = 42` → cũng ra Seq Scan, **275,8 ms**, chậm 470 lần so với 0,586 ms.

> **Quy tắc leftmost, phát biểu bằng số: index `(a, b)` dùng cho `WHERE b = ?` chậm hơn index `(b, a)` từ 39 đến 470 lần — đủ chậm để planner chọn quét toàn bảng thay vì dùng nó.**

---

## §3. Ma trận 4 query × 2 index

| Query | Index | Index Cond | Filter | Rows Removed | **buffers** | **time** |
|---|---|---|---|---|---|---|
| **Q1** `dev=42 AND ts BETWEEN` | `idx_dev_ts` ✅ | `device_id=42 AND ts>=.. AND ts<..` | — | 0 | **4** | **0,033 ms** |
| Q1 | `idx_ts_dev` | `ts>=.. AND ts<.. AND device_id=42` | — | 0 | **217** | 2,045 ms |
| **Q2** chỉ `ts BETWEEN` | `idx_ts_dev` ✅ | `ts>=.. AND ts<..` | — | 0 | **217** | 8,425 ms |
| Q2 | `idx_dev_ts` → **Seq Scan** | — | `ts>=.. AND ts<..` | **4.944.437** | **36.958** | 342,9 ms |
| **Q3** chỉ `dev=42` | `idx_dev_ts` ✅ | `device_id=42` | — | 0 | **19** | **0,586 ms** |
| Q3 | `idx_ts_dev` → **Seq Scan** | — | `device_id=42` | **4.996.269** | **36.958** | 275,8 ms |
| **Q4** `dev IN(1,7,42) AND ts>=` | `idx_dev_ts` ✅ | `device_id = ANY(...) AND ts>=..` | — | 0 | **169** | **6,42 ms** |
| Q4 | `idx_ts_dev` | `ts>=.. AND device_id = ANY(...)` | — | 0 | **6.179** | 118,8 ms |

### Đọc bảng này

**Q1 — chênh 54 lần buffers (4 vs 217).** Thứ tự đúng: cây đi thẳng tới nhánh `device_id=42`, rồi trong nhánh đó đi tới `ts` cần → đọc **4 page**, trả về đúng 31 dòng. Thứ tự sai: phải quét **toàn bộ khoảng một ngày** (55.563 entry, 217 page) rồi lọc còn 31.

**Q4 — chênh 37 lần (169 vs 6.179).** Đây là ví dụ rõ nhất về `ScalarArrayOp`:
```
Index Cond: ((device_id = ANY ('{1,7,42}'::bigint[])) AND (ts >= '2025-07-01'))
```
Postgres thi hành như **3 lần quét riêng** rồi gộp kết quả — mỗi lần đi thẳng tới một `device_id` rồi quét khoảng `ts`. Với thứ tự sai, nó phải quét toàn bộ 1,6 triệu entry của tháng 7 rồi lọc.

**Q2 và Q3 — chênh 39 và 470 lần**, và ở đây planner **từ bỏ index hoàn toàn**. Đây là câu trả lời trực quan nhất cho "có index mà không dùng" (Day 04): index tồn tại, cột tồn tại trong index, nhưng **sai vị trí** thì vô dụng.

### 💡 Mẹo `BEGIN; DROP INDEX; ROLLBACK;`

DDL trong Postgres là transactional, nên có thể thử "nếu bỏ index này thì query nào chết" **mà không mất gì** — rollback trả index về nguyên vẹn, không phải build lại.

Cực kỳ hữu ích trước khi xoá index thật trên production.

**Cái giá:** `DROP INDEX` giữ `ACCESS EXCLUSIVE` lock trên bảng cho tới lúc rollback — mọi query khác bị chặn. Chỉ làm lúc bảng rảnh, và bọc `SET LOCAL lock_timeout = '2s'` để không treo cả hệ thống nếu có transaction dài đang chạy (Day 43 nói kỹ).

```sql
BEGIN;
SET LOCAL lock_timeout = '2s';
DROP INDEX idx_nghi_ngo;
EXPLAIN (ANALYZE, BUFFERS) <query quan trọng>;
ROLLBACK;
```

---

## §4. Kéo điều kiện từ `Filter` lên `Index Cond`

Query: `device_id = 42 AND key_id = 1 AND ts >= '2025-06-01'` → 667 dòng.

| | index `(device_id, ts)` | index `(device_id, key_id, ts)` |
|---|---|---|
| Node | Bitmap Heap Scan | **Index Only Scan** |
| `Index Cond` | `device_id=42 AND ts>=..` | `device_id=42 AND key_id=1 AND ts>=..` |
| `Filter` | **`key_id = 1`** | — |
| **`Rows Removed by Filter`** | **1.735** | **0** |
| `Heap Blocks` | **exact=2.296** | — |
| **buffers** (`count(*)`) | **2.311** | **11** |
| **time** | 10,23 ms | **0,194 ms** |

**Buffers giảm 210 lần, thời gian giảm 53 lần.**

Bản dùng `sum(dbl_v)` (buộc đọc heap, so sánh công bằng hơn):

| | `(device_id, ts)` | `(device_id, key_id, ts)` |
|---|---|---|
| buffers | 2.308 | **664** |
| `Heap Blocks` | exact=2.296 | exact=658 |
| time | 2,48 ms | **0,79 ms** |

Vẫn **giảm 3,5 lần** ngay cả khi bắt buộc phải lên heap. Vì index lọc chặt hơn → chỉ 667 dòng phải lấy thay vì 2.402.

### Quy tắc chọn thứ tự cột — đúng 2 câu

> **1. Đặt mọi cột dùng `=` (hoặc `IN`) lên trước, cột dùng range (`>`, `<`, `BETWEEN`, `LIKE 'x%'`) đặt cuối cùng.**
>
> **2. Sau cột range đầu tiên, mọi cột phía sau chỉ còn dùng để lọc chứ không thu hẹp phạm vi đọc nữa — nên chỉ có đúng MỘT cột range được hưởng lợi.**

Bổ sung cho trường hợp nhiều cột equality: thứ tự giữa chúng không ảnh hưởng tính đúng, nhưng ảnh hưởng **khả năng tái sử dụng**. Đặt cột hay xuất hiện một mình lên trước — vì `(a,b,c)` phục vụ được `(a)` và `(a,b)` nhưng không phục vụ `(b)`.

Nếu cần `ORDER BY` thì cột sort đi ngay sau các cột equality (§5).

---

## §5. `ORDER BY` và node `Sort`

Query: `SELECT ts, dbl_v FROM ts_kv WHERE device_id = 42 ORDER BY ts DESC LIMIT 10`

| | index `(device_id, ts)` | index `(device_id, ts DESC)` |
|---|---|---|
| Node | **Index Scan Backward** | **Index Scan** |
| node `Sort` | **không có** | **không có** |
| buffers | 13 | 13 |
| time | 0,029 ms | 0,039 ms |

### 💡 Kết quả phản trực giác: index `DESC` KHÔNG giúp gì

Đề bài gợi ý index `(device_id, ts DESC)` sẽ cải thiện. Số đo nói: **không, và tạo nó là lãng phí 150 MB.**

Lý do: **B-tree của Postgres đọc ngược được**. Lá được nối đôi (`btpo_prev`/`btpo_next` — Day 06), nên `ORDER BY ts DESC` chỉ cần đi từ cuối về đầu. Plan hiện đúng node đó: `Index Scan **Backward** using idx_dev_ts`.

Kiểm chứng chiều ngược lại — `ORDER BY ts ASC` trên index `DESC`:
```
Index Scan Backward using idx_dev_ts_desc  (actual time=0.025..0.045 rows=10)
```
Cũng dùng được, cũng không có `Sort`. **Hoàn toàn đối xứng.**

> **Luật: index một cột sort phục vụ được CẢ HAI chiều. Không bao giờ cần tạo hai index chỉ khác `ASC`/`DESC`.**

### Vậy khi nào `DESC` trong index mới có ý nghĩa

**Chỉ khi `ORDER BY` TRỘN CHIỀU trên nhiều cột.**

```sql
-- index (a ASC, b ASC) phục vụ:
ORDER BY a ASC,  b ASC      -- đi xuôi
ORDER BY a DESC, b DESC     -- đi ngược
-- KHÔNG phục vụ:
ORDER BY a ASC,  b DESC     -- trộn chiều -> phải tạo index (a ASC, b DESC)
```

Ví dụ thật trong hệ IoT: *"danh sách alarm, tenant tăng dần, trong mỗi tenant thì mới nhất trước"*:
```sql
ORDER BY tenant_id ASC, start_ts DESC
-- cần: CREATE INDEX ON alarm (tenant_id ASC, start_ts DESC);
```

Điểm nữa đáng nhớ: `NULLS FIRST/LAST` cũng phải khớp. Mặc định `ASC` là `NULLS LAST`, `DESC` là `NULLS FIRST`. Viết `ORDER BY x DESC NULLS LAST` mà index không khai `NULLS LAST` thì node `Sort` quay lại.

### Vì sao chỉ 13 buffer cho query có `LIMIT 10`

`Index Scan` là node **streaming** (startup cost thấp — Day 01 §6). `LIMIT 10` khiến nó dừng ngay sau 10 dòng: đọc 3 page index (root → internal → lá) + 10 page heap = 13.

Đây là mẫu query quan trọng nhất của hệ IoT (*"N giá trị mới nhất của device X"*), và với index đúng nó **rẻ như tra một dòng**.

---

## §6. `IN`, `OR`, và giới hạn của Postgres

### `OR` — thảm hoạ

```
Seq Scan on ts_kv  (actual time=0.011..352.492 rows=457405)
  Filter: ((device_id = 42) OR (key_id = 6))
  Rows Removed by Filter: 4542595
  Buffers: shared hit=21822 read=15136
Execution Time: 373.130 ms
```

**Quét toàn bảng.** Không dùng index nào, dù `device_id` là cột đầu của 3 index.

Lý do: `OR` giữa **hai cột khác nhau** không thể thu hẹp trên một index composite — một dòng thoả `key_id = 6` có thể có `device_id` bất kỳ. Postgres **có thể** dùng `BitmapOr` với hai index riêng, nhưng ở đây không có index nào trên `key_id` đứng đầu, nên nó bỏ cuộc.

**Cách sửa — viết lại thành `UNION`:**
```sql
SELECT count(*) FROM (
  SELECT ctid FROM ts_kv WHERE device_id = 42
  UNION
  SELECT ctid FROM ts_kv WHERE key_id = 6
) s;
```
Mỗi nhánh dùng được index riêng. Đây là kỹ thuật quan trọng — `OR` trên nhiều cột gần như luôn nên viết lại thành `UNION`, kể cả khi trông xấu hơn.

### `key_id` không phải cột đầu — không có skip scan

```
Bitmap Heap Scan on ts_kv  (actual time=68.522..216.097 rows=146523)
  Filter: (key_id = 6)
  Rows Removed by Filter: 1464668
  Heap Blocks: exact=11910
  ->  Bitmap Index Scan on idx_ts_dev  (actual rows=1611191)
        Index Cond: (ts > '2025-07-01')
Execution Time: 223.096 ms
```

Planner dùng `idx_ts_dev` cho phần `ts > '2025-07-01'` (**1.611.191 entry**), rồi lọc `key_id = 6` bằng `Filter` → **vứt 1.464.668 dòng**, giữ 146.523. Lãng phí **91 %**.

`key_id` chỉ có 8 giá trị phân biệt. Oracle/MySQL 8 có **index skip scan** (loose index scan) — quét index `(a, b)` cho `WHERE b = ?` bằng cách nhảy qua từng giá trị `a`. **Postgres 17 không có.** (PG18 mới thêm.)

Cách sửa trong Postgres 17: tạo index có `key_id` đứng trước, hoặc mô phỏng skip scan bằng recursive CTE (phức tạp, hiếm khi đáng).

---

## §7. Bao nhiêu index là đủ

### Danh sách index trên `ts_kv` sau bài hôm nay

| Index | size | Có thừa không |
|---|---|---|
| `idx_dev_key_ts (device_id, key_id, ts)` | **194 MB** | không — index rộng nhất |
| `idx_dev_ts (device_id, ts)` | 150 MB | **THỪA** — bị `idx_dev_key_ts` bao phủ một phần* |
| `idx_dev_ts_desc (device_id, ts DESC)` | 150 MB | **THỪA HOÀN TOÀN** — §5 chứng minh |
| `idx_ts_dev (ts, device_id)` | 150 MB | **giữ** — index duy nhất phục vụ query chỉ lọc `ts` |
| `idx_dev_only (device_id)` | 34 MB | **THỪA** — là tiền tố của cả 3 index trên |

\* `(device_id, key_id, ts)` **không** thay hoàn toàn được `(device_id, ts)`: query `WHERE device_id=? AND ts BETWEEN ?` chỉ dùng được cột đầu, `ts` rơi xuống non-boundary. Nhưng nó vẫn tốt hơn nhiều so với không có gì — cần đo trước khi xoá.

Tổng: **678 MB index cho một bảng 289 MB** — index gấp **2,3 lần** dữ liệu. Xoá 3 index thừa lấy lại **334 MB (49 %)**.

### ⚠️ Query tìm index thừa trong README bị lỗi — bản sửa

Query trong README:
```sql
AND (b.indkey::int2[])[0:array_length(a.indkey::int2[],1)-1] = a.indkey::int2[]
```
Chạy trên lab này trả về **0 dòng**, dù `idx_dev_only(device_id)` rõ ràng là tiền tố của `idx_dev_ts(device_id, ts)`.

Nguyên nhân: `indkey` là kiểu `int2vector`, cast sang `int2[]` cho ra mảng **0-based** (đo được `array_lower = 0, array_upper = 1`), nên phép cắt lát và so sánh không khớp như mong đợi.

**Bản dùng được (so khớp tiền tố dạng chuỗi):**

```sql
SELECT a.indrelid::regclass                        AS bang,
       a.indexrelid::regclass                      AS idx_thua,
       pg_size_pretty(pg_relation_size(a.indexrelid)) AS size_thua,
       b.indexrelid::regclass                      AS bi_bao_phu_boi,
       s.idx_scan                                  AS luot_dung
FROM pg_index a
JOIN pg_index b
  ON b.indrelid = a.indrelid AND b.indexrelid <> a.indexrelid
LEFT JOIN pg_stat_user_indexes s ON s.indexrelid = a.indexrelid
WHERE b.indnatts > a.indnatts
  AND b.indkey::text LIKE a.indkey::text || ' %'   -- a là TIỀN TỐ của b
  AND NOT a.indisprimary AND NOT a.indisunique     -- đừng đụng PK/unique
  AND a.indpred   IS NULL AND b.indpred   IS NULL  -- bỏ qua partial index
  AND a.indexprs  IS NULL AND b.indexprs  IS NULL  -- bỏ qua expression index
ORDER BY pg_relation_size(a.indexrelid) DESC;
```

Kết quả trên lab:
```
   idx_thua   | size_thua | bi_bao_phu_boi  | cot_thua | cot_phu
--------------+-----------+-----------------+----------+---------
 idx_dev_only | 34 MB     | idx_dev_ts      | 1        | 1 3
 idx_dev_only | 34 MB     | idx_dev_key_ts  | 1        | 1 2 3
 idx_dev_only | 34 MB     | idx_dev_ts_desc | 1        | 1 3
```

Bốn điều kiện loại trừ ở cuối rất quan trọng — thiếu chúng, query sẽ đề nghị xoá PK hoặc partial index, và đó là cách phá production.

### Index chưa từng được dùng

```
   relname   |    indexrelname     | idx_scan | size
-------------+---------------------+----------+---------
 ts_kv       | idx_dev_only        |        0 | 34 MB
 device_attr | device_attr_pkey    |        0 | 4904 kB
 device      | idx_dev_uuid        |        0 | 1552 kB
 device      | idx_dev_name        |        0 | 1552 kB
 device      | idx_dev_meta_txt    |        0 | 400 kB
```

**Ba cảnh báo trước khi tin bảng này:**

1. **`device_attr_pkey` có `idx_scan = 0` nhưng TUYỆT ĐỐI không được xoá.** Index unique/PK làm nhiệm vụ **ràng buộc**, không chỉ tra cứu. Luôn lọc `NOT indisprimary AND NOT indisunique`.
2. **`idx_scan` tích luỹ từ lần `pg_stat_reset()` cuối.** Số 0 sau 1 ngày chạy không có nghĩa gì. Cần **ít nhất một chu kỳ nghiệp vụ đầy đủ** — thường là 1 tháng, để bắt cả job cuối tháng.
3. **`idx_scan` không đếm ở replica.** Index chỉ dùng cho query báo cáo trên replica sẽ hiện 0 trên primary. Phải cộng số liệu từ mọi node.

**Quy trình xoá index an toàn:**
```sql
-- 1. Thử: query nào chết nếu bỏ nó?  (rollback -> không mất gì)
BEGIN; SET LOCAL lock_timeout='2s'; DROP INDEX idx_nghi_ngo;
EXPLAIN (ANALYZE, BUFFERS) <các query quan trọng>;
ROLLBACK;

-- 2. Vô hiệu hoá mềm thay vì xoá ngay — planner ngừng dùng, nhưng index vẫn được cập nhật
UPDATE pg_index SET indisvalid = false WHERE indexrelid = 'idx_nghi_ngo'::regclass;
-- ... theo dõi 1 tuần ...
-- 3. Nếu ổn: DROP INDEX CONCURRENTLY idx_nghi_ngo;
-- Nếu không: UPDATE pg_index SET indisvalid = true ...  (khôi phục tức thì, không build lại)
```

Bước 2 là mẹo đáng giá nhất: **rollback trong 1 giây thay vì build lại index 20 phút.** (Sửa `pg_index` trực tiếp cần superuser và có rủi ro — dùng cẩn thận, và luôn trong transaction.)

---

## Bảng số liệu chính

| Kịch bản | Index | Index Cond | Rows Removed | buffers | time |
|---|---|---|---|---|---|
| Q1 `dev=42 AND ts BETWEEN` | `(device_id, ts)` ✅ | cả 2 cột | 0 | **4** | **0,033 ms** |
| Q1 | `(ts, device_id)` | cả 2 cột*(non-boundary)* | 0 | **217** | 2,045 ms |
| Q2 chỉ `ts` | `(ts, device_id)` ✅ | `ts` | 0 | 217 | 8,4 ms |
| Q2 | ép `(device_id, ts)` → **Seq Scan** | — | **4.944.437** | 36.958 | **342,9 ms** |
| Q3 chỉ `device_id` | `(device_id, ts)` ✅ | `device_id` | 0 | **19** | **0,586 ms** |
| Q3 | ép `(ts, device_id)` → **Seq Scan** | — | **4.996.269** | 36.958 | **275,8 ms** |
| Q4 `IN + range` | `(device_id, ts)` ✅ | `= ANY(...) AND ts>=` | 0 | **169** | 6,42 ms |
| Q4 | `(ts, device_id)` | | 0 | 6.179 | 118,8 ms |
| §4 `dev+key+ts` với `(dev,ts)` | | | **1.735** | 2.311 | 10,23 ms |
| §4 với `(dev,key,ts)` | | cả 3 cột | **0** | **11** | **0,194 ms** |
| §5 `ORDER BY ts DESC LIMIT 10` | `(dev, ts)` → Backward | | 0 | 13 | 0,029 ms |
| §5 với index `ts DESC` | `(dev, ts DESC)` | | 0 | 13 | 0,039 ms — **không hơn** |
| §6 `OR` hai cột | **Seq Scan** | — | 4.542.595 | 36.958 | **373,1 ms** |
| §6 `key_id` không đứng đầu | `(ts, device_id)` + Filter | `ts` | **1.464.668** | 18.087 | 223,1 ms |

---

## Ba điều dễ hiểu sai

| # | Hiểu nhầm | Sự thật đo được |
|---|---|---|
| 1 | "Điều kiện vào `Index Cond` là index đang làm việc tốt" | Q1 với index sai thứ tự: cả 2 cột đều trong `Index Cond`, `Rows Removed = 0`, **vẫn chậm 62 lần**. Chỉ buffers mới tố cáo |
| 2 | "Cần index `DESC` riêng cho `ORDER BY ... DESC`" | B-tree đọc ngược được. Index `ASC` và `DESC` cho **cùng buffers, cùng plan**. Chỉ cần khi trộn chiều nhiều cột |
| 3 | "Index có chứa cột là dùng được cho cột đó" | `idx_dev_ts` **có** cột `ts`, nhưng query chỉ lọc `ts` thì planner chọn **Seq Scan** — chậm hơn 39 lần |

Thêm hai điều thực dụng:
- **`OR` giữa hai cột giết mọi index.** Viết lại thành `UNION`.
- **Postgres 17 không có index skip scan.** `WHERE b=?` trên index `(a,b)` luôn tệ, kể cả khi `a` chỉ có 8 giá trị.

---

## Áp dụng vào hệ thật

**1. Công thức viết index cho một query — làm theo đúng thứ tự:**

```
① Mọi cột dùng = hoặc IN          -> đặt trước, cột hay dùng một mình lên đầu
② Cột trong ORDER BY              -> đặt tiếp (khai đúng ASC/DESC nếu TRỘN chiều)
③ MỘT cột range (>, <, BETWEEN)   -> đặt cuối
④ Cột chỉ để SELECT, không lọc    -> INCLUDE (Day 08)
⑤ Điều kiện luôn cố định          -> WHERE của partial index (Day 09)
```

Ví dụ áp cho hệ IoT:
```sql
-- "50 alarm CRITICAL đang mở của tenant X, mới nhất trước"
SELECT * FROM alarm
WHERE tenant_id = $1 AND severity = 'CRITICAL' AND end_ts IS NULL
ORDER BY start_ts DESC LIMIT 50;

CREATE INDEX CONCURRENTLY idx_alarm_dash
  ON alarm (tenant_id, severity, start_ts DESC)   -- ①① ②
  WHERE end_ts IS NULL;                            -- ⑤
```

```sql
-- "telemetry của device X, key Y, trong khoảng thời gian"
SELECT ts, dbl_v FROM ts_kv
WHERE device_id = $1 AND key_id = $2 AND ts >= $3 AND ts < $4;

CREATE INDEX ON ts_kv (device_id, key_id, ts);     -- ①① ③
```

**2. Chạy query tìm index thừa (bản sửa ở §7) trên production ngay hôm nay.** Ở lab nó tìm ra 334 MB (49 % tổng index) có thể xoá. Trên bảng thật tỷ lệ thường tương tự.

**3. Trước khi xoá bất kỳ index nào, dùng `BEGIN; DROP INDEX; ROLLBACK;`** để xem query nào chết. Miễn phí, và là cách duy nhất chắc chắn.

**4. Rà soát các query có `OR` giữa hai cột khác nhau.** Đây là dạng bị bỏ sót nhiều nhất — nó không báo lỗi, chỉ âm thầm quét toàn bảng. Tìm bằng:
```sql
SELECT calls, round(mean_exec_time::numeric,1) AS ms, left(query,100)
FROM pg_stat_statements
WHERE query ~* '\yOR\y' AND query !~* 'ORDER'
ORDER BY total_exec_time DESC LIMIT 20;
```

**5. Đừng tạo index `DESC` trùng lặp.** Nếu codebase có cặp index chỉ khác `ASC`/`DESC`, xoá một cái — tiết kiệm 50 % dung lượng nhóm đó mà không mất gì.

---

## Câu hỏi mở sang các ngày sau

1. `Index Only Scan` xuất hiện khắp bài này với `Heap Fetches: 0`. Khi nào nó hỏng và `Heap Fetches` nhảy vọt? → **Day 08**
2. `INCLUDE (dbl_v)` khác gì với đưa `dbl_v` vào key? → **Day 08**
3. 678 MB index cho bảng 289 MB. Mỗi index làm chậm INSERT bao nhiêu? → **Day 10**
4. `idx_ts_dev` nặng 150 MB cho cột `correlation = 1`. BRIN thay được không? → **Day 31**
5. `OR` phải viết lại thành `UNION` — còn `EXISTS` / `IN` / `LEFT JOIN IS NULL` thì sao? → **Day 20**
