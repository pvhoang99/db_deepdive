# Day 08 — Lời giải: Index-only scan, `INCLUDE`, và visibility map

> Bài chữa. Đo thật trên lab `SCALE=1`. Bài này cố ý **tắt autovacuum** và `UPDATE` 1,96 triệu dòng để làm bẩn visibility map — nếu không thì hiện tượng chính không lộ ra.

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án | Bẫy |
|---|---|---|---|
| 1 | Chưa VACUUM thì `Heap Fetches` bao nhiêu? | **Không có `Heap Fetches` — planner còn không thèm chọn index-only scan** | Đa số đoán "bằng số dòng". Thực tế planner thấy VM sạch 0 % nên đổi hẳn sang `Index Scan` thường |
| 2 | Sau `VACUUM` thì sao? | `Heap Fetches: 0`, buffers **6.878 → 24 (giảm 287 lần)** | Đa số đoán "cải thiện chút ít" |
| 3 | `(a,b) INCLUDE (c)` to hơn hay nhỏ hơn `(a,b,c)`? | **To hơn một chút** — 195 MB vs 193 MB | Đa số đoán INCLUDE nhỏ hơn. Sai — xem §4 |

Câu 1 là bài học đắt nhất: khi VM bẩn, **planner không chọn index-only scan cả**. Nó tính cost dựa trên tỷ lệ `all_visible` của bảng, thấy 0 % thì biết index-only sẽ phải fetch heap mọi dòng → chọn plan khác luôn.

---

## §1. Vấn đề: index không biết dòng nào còn sống

Sau khi `UPDATE` 1.955.902 dòng với autovacuum tắt:

```
 all_visible | tong
-------------+-------
           0 | 51414        <- 0% page nào all-visible
```

Query `SELECT device_id, ts, dbl_v FROM ts_kv WHERE device_id = 42` với index `(device_id, ts) INCLUDE (dbl_v)` — index chứa **đủ mọi cột cần**:

```
Index Scan using idx_dev_only on ts_kv  (actual time=7.330..107.425 rows=3731)
  Index Cond: (device_id = 42)
  Buffers: shared hit=478 read=6400 dirtied=3359 written=3558
Execution Time: 107.623 ms
```

**Nó không "only" chút nào** — và thậm chí planner còn không dùng index `idx_dev_ts_inc` mà chọn `idx_dev_only`, vì khi VM bẩn 100 % thì index-only scan chẳng có lợi thế gì mà index lại to hơn.

### Vì sao — điểm khác biệt lớn với MySQL

**Thông tin visibility (`xmin`/`xmax`) chỉ nằm trong heap, KHÔNG nằm trong index.**

Kể cả khi index chứa đủ mọi cột, Postgres vẫn phải quay lại heap hỏi *"phiên bản dòng này có hiển thị với snapshot của tôi không?"*.

Đây là hệ quả trực tiếp của kiến trúc MVCC kiểu Postgres: index trỏ tới **mọi phiên bản** của dòng, kể cả phiên bản chết, và không có cách nào biết cái nào còn sống mà không đọc heap.

MySQL/InnoDB khác hẳn: index phụ trỏ vào clustered index (PK), và visibility xử lý qua undo log — nên "covering index" ở MySQL hoạt động không cần điều kiện gì. **Người từ MySQL sang Postgres hay bất ngờ đúng chỗ này.**

Chú ý thêm `dirtied=3359 written=3558` — query **SELECT** mà làm bẩn 3.359 page và ghi 3.558 page xuống đĩa. Đó là **hint bit**: lần đầu đọc một tuple sau khi transaction ghi nó đã commit, Postgres ghi lại "đã commit rồi" vào tuple header để lần sau khỏi tra `pg_xact`. Nên **`SELECT` đầu tiên sau một đợt ghi lớn luôn đắt bất thường** — và nó sinh I/O ghi thật.

---

## §2. Visibility Map

```
 vm_size | pages_all_visible | pages_total
---------+-------------------+-------------
 16 kB   |                 0 |       51414
```

**VM chỉ 16 KB để mô tả 51.414 page (402 MB heap).** Tỷ lệ **1 : 25.000**.

Cơ chế: 2 bit cho mỗi page heap (`all-visible` + `all-frozen`) → 4 page/byte → 51.414 page ÷ 4 = 12.854 byte ≈ 16 KB (làm tròn lên page). ✓

Vì nhỏ như vậy nên **VM luôn nằm trong shared_buffers**. Tra VM là thao tác gần như miễn phí — đó là điều làm index-only scan khả thi.

---

## §3. Bốn trạng thái của `Heap Fetches` — bài chính

| Lần | Trạng thái | Node | `Heap Fetches` | `all_visible` | **buffers** | **time** |
|---|---|---|---|---|---|---|
| **1** | sau UPDATE 1,96M dòng, chưa VACUUM | **Index Scan** | *(không áp dụng)* | **0 / 51.414** | **6.878** | **107,6 ms** |
| **2** | sau `VACUUM ts_kv` | **Index Only Scan** | **0** | **51.414 / 51.414** | **24** | **0,696 ms** |
| **3** | sau UPDATE 22.576 dòng | Index Only Scan | **7.461** | **39.521 / 51.414** | **14.953** | **17,9 ms** |
| **4** | `VACUUM` lại | Index Only Scan | **0** | 51.414 / 51.414 | **73** | **0,577 ms** |

### VACUUM đáng giá bao nhiêu với query này

**Lần 1 → lần 2: buffers 6.878 → 24 = giảm 287 lần. Thời gian 107,6 → 0,696 ms = nhanh 155 lần.**

Không đổi một dòng SQL. Không thêm index. Chỉ chạy `VACUUM`.

### Lần 3 — điều đáng sợ nhất bài này

`UPDATE` **22.576 dòng** (0,45 % bảng) làm:

| | trước UPDATE | sau UPDATE |
|---|---|---|
| `all_visible` | 51.414 (100 %) | **39.521 (76,9 %)** |
| `Heap Fetches` | 0 | **7.461** |
| buffers | 24 | **14.953** (gấp **623 lần**) |
| time | 0,696 ms | 17,9 ms (chậm **26 lần**) |

**Sửa 0,45 % số dòng làm mất 23 % số page all-visible.**

Vì sao lệch tỷ lệ như vậy: 22.576 dòng của `device_id` 40–45 nằm **rải rác** trên 11.893 page khác nhau (correlation ≈ 0 — Day 04). Chỉ cần **một** dòng trong page bị sửa là cả page mất bit `all-visible`.

> **Đây là công thức của tai hoạ: correlation thấp × UPDATE rải rác = mất VM nhanh gấp nhiều lần tỷ lệ dòng bị sửa.**

Chú ý `Heap Fetches: 7.461` cho query chỉ trả **3.731 dòng** — gấp đôi. Vì mỗi dòng có 2 phiên bản (cũ + mới) trong index sau UPDATE, và cả hai đều phải kiểm tra.

---

## §4. `INCLUDE` — cột không nằm trong khoá

### Kích thước — kết quả phản trực giác

| Index | size | pages | level | `avg_item` |
|---|---|---|---|---|
| `(device_id, ts) INCLUDE (dbl_v)` | **195 MB** | 24.968 | 2 | 31 |
| `(device_id, ts, dbl_v)` | **193 MB** | 24.754 | 2 | 31 |

**INCLUDE to hơn 1 %, không nhỏ hơn.** Cả hai cùng chiều cao, cùng `avg_item_size`.

Vì sao: ở **tầng lá**, cả hai lưu y hệt nhau (device_id + ts + dbl_v + TID). Khác biệt chỉ ở tầng internal — nơi bản INCLUDE **không** mang `dbl_v`. Nhưng tầng internal chỉ chiếm ~0,4 % số page (98 trên 24.968), nên tiết kiệm không đáng kể.

Bản INCLUDE còn to hơn chút vì mỗi tuple cần thêm cờ đánh dấu phần payload.

> **Sửa lại kỳ vọng thông thường: `INCLUDE` KHÔNG làm index nhỏ hơn. Lợi ích của nó nằm ở chỗ khác — xem §5.**

### Truy vấn có lọc trên `dbl_v` — chỗ cột khoá thắng rõ

`SELECT * FROM ts_kv WHERE device_id = 42 AND ts > '2025-06-01' AND dbl_v > 30`

| | `INCLUDE (dbl_v)` | khoá `(…, dbl_v)` |
|---|---|---|
| `Index Cond` | `device_id=42 AND ts>..` | `device_id=42 AND ts>.. AND dbl_v>30` |
| `Filter` | **`dbl_v > 30`** | — |
| **`Rows Removed by Filter`** | **1.744** | **0** |
| **buffers** | **99** | **43** |
| time | 0,484 ms | **0,239 ms** |

**Cột khoá thắng: buffers ít hơn 2,3 lần, nhanh gấp đôi.**

Lý do khớp đúng lý thuyết: cột `INCLUDE` **không dùng để tìm kiếm**. Nó chỉ là hành lý mang theo ở tầng lá. Muốn lọc theo nó thì phải đọc mọi entry lên rồi vứt — đúng 1.744 dòng bị vứt.

### Bảng tổng kết khác biệt

| | Cột khoá | Cột `INCLUDE` |
|---|---|---|
| Có ở tầng lá | ✅ | ✅ |
| Có ở tầng internal | ✅ | ❌ |
| Dùng để **tìm kiếm** (`Index Cond`) | ✅ | ❌ |
| Dùng để **sắp xếp** (xoá node Sort) | ✅ | ❌ |
| Tham gia ràng buộc `UNIQUE` | ✅ | ❌ ← **chỗ không thay thế được** |
| Phải là kiểu có toán tử B-tree | ✅ | ❌ (nhận mọi kiểu, kể cả `point`, `json`) |

---

## §5. `INCLUDE` với `UNIQUE` — nơi nó thật sự không thể thay thế

```sql
CREATE UNIQUE INDEX idx_dev_uuid_inc ON device(uuid) INCLUDE (tenant_id, name);
```

```
Index Only Scan using idx_dev_uuid_inc on device  (actual time=0.027..0.027 rows=1)
  Index Cond: (uuid = (InitPlan 1).col1)
  Heap Fetches: 0
  Buffers: shared hit=11 read=3
Execution Time: 0.040 ms
```

**Index Only Scan, `Heap Fetches: 0`, 14 buffer.**

### Nếu thay bằng `CREATE UNIQUE INDEX ON device(uuid, tenant_id, name)` thì sao

**Ràng buộc duy nhất sẽ SAI HOÀN TOÀN.**

`UNIQUE (uuid, tenant_id, name)` ràng buộc **bộ ba** phải duy nhất, không phải `uuid`. Nghĩa là:

```sql
INSERT INTO device VALUES ('abc-123', tenant_id=1, name='sensor-A');
INSERT INTO device VALUES ('abc-123', tenant_id=2, name='sensor-B');  -- ĐƯỢC CHẤP NHẬN!
```

Hai device khác nhau cùng `uuid`. Toàn bộ mục đích của `uuid` sụp đổ. Và bug này **không lộ ra ngay** — nó âm thầm cho phép dữ liệu bẩn vào cho tới khi có người join theo `uuid` và nhận về nhiều dòng.

> **Đây là lý do `INCLUDE` được thêm vào Postgres 11. Trước đó không có cách nào vừa giữ `UNIQUE` trên một cột vừa có index-only scan cho các cột khác.**

Mẫu dùng rất phổ biến trong thực tế:
```sql
-- lookup theo khoá nghiệp vụ, trả về vài trường hay dùng, không đụng heap
CREATE UNIQUE INDEX ON users (email) INCLUDE (id, tenant_id, is_active);
CREATE UNIQUE INDEX ON orders (order_no) INCLUDE (status, total_amount);
```

---

## §6. Bảng append-only vs bảng hay update — cái bẫy quan trọng nhất

Index `alarm(device_id, start_ts) INCLUDE (severity)`.

| | sau `VACUUM alarm` | sau `UPDATE alarm SET status = ...` |
|---|---|---|
| `Heap Fetches` | **0** | **2.364** |
| buffers | **10** | **2.380** |
| time | **0,222 ms** | **10,66 ms** |
| `all_visible` | 4.170 / 4.170 | **2 / 4.170** |

**Chậm 48 lần, buffers gấp 238 lần.**

### Điều then chốt: `UPDATE` KHÔNG chạm cột nào trong index

Câu lệnh là `UPDATE alarm SET status = 'CLEARED_ACK'`. Index chứa `device_id`, `start_ts`, `severity` — **không có `status`**.

Index không hề thay đổi. Nhưng index-only scan vẫn chết.

### Vì sao

Visibility map là ở **cấp PAGE**, không phải cấp dòng, và **không quan tâm cột nào bị sửa**:

```
UPDATE bất kỳ dòng nào trong page
      ↓
tạo phiên bản mới của dòng (MVCC: UPDATE = DELETE + INSERT — Day 21)
      ↓
page có tuple chưa chắc chắn hiển thị với mọi transaction
      ↓
bit all-visible của CẢ PAGE bị xoá
      ↓
mọi index-only scan chạm page đó phải fetch heap
```

25.124 dòng bị sửa, rải trên hầu hết 4.170 page → `all_visible` từ 4.170 xuống **2**.

> **Luật: index-only scan không phụ thuộc vào việc anh sửa cột nào. Nó phụ thuộc vào việc bảng có ĐANG được VACUUM kịp hay không.**

Đây cũng là gợi ý cho Day 24: nếu `UPDATE` là **HOT update** (không chạm cột được index + còn chỗ trong page), thiệt hại nhỏ hơn nhiều vì không phải cập nhật index. Nhưng bit `all-visible` **vẫn** bị xoá.

### Bảng nào phù hợp với chiến lược index-only scan

| Loại bảng | Ví dụ | Phù hợp? |
|---|---|---|
| **Append-only** | `ts_kv`, log, event, audit | ✅ **Hoàn hảo** — VM gần như luôn 100 % |
| Chèn nhiều, sửa hiếm | `orders` (sau khi hoàn tất) | ✅ tốt, cần autovacuum hợp lý |
| Sửa liên tục | `device_state`, `session`, counter | ❌ **Gần như không bao giờ được hưởng** |
| Sửa vừa phải | `alarm` (mở → đóng) | ⚠️ cần hạ `autovacuum_vacuum_scale_factor` riêng cho bảng |

---

## §7. Cái giá của index-only scan

```
-- insert 300.000 dòng
t_w1 (KHÔNG index)                          :   298,9 ms
t_w2 (index (device_id,ts) INCLUDE 3 cột)   : 1.000,5 ms
```

| | `t_w1` | `t_w2` | Chênh |
|---|---|---|---|
| **thời gian INSERT** | 298,9 ms | **1.000,5 ms** | **chậm 3,35 lần** |
| heap | 17 MB | 17 MB | — |
| index | 0 | **18 MB** | |
| **tổng dung lượng** | 17 MB | **36 MB** | **gấp 2,1 lần** |

**Index chứa nhiều cột nặng bằng cả bảng.** Vì nó gần như sao chép mọi cột.

Ba cái giá phải trả:

1. **INSERT chậm 3,35 lần.** Và đây mới chỉ là **một** index. Với 5 index thì hình dung được.
2. **Gấp đôi dung lượng** → gấp đôi áp lực lên shared_buffers → đẩy dữ liệu nóng khác ra ngoài.
3. **Mỗi `UPDATE` chạm cột trong index đều phải cập nhật index** và **phá vỡ HOT update** (Day 24) — làm bảng bloat nhanh hơn.

Còn một cái giá ẩn: **bảng `ts_kv` đã phình từ 289 MB lên 402 MB** sau các `UPDATE` của bài này (+39 %), dù `VACUUM` đã chạy. Đó là bloat — Day 22.

> **Kết luận: `INCLUDE` cả 10 cột "cho chắc" là phản tác dụng. Chỉ include cột mà query nóng thật sự cần TRẢ VỀ (không phải lọc), và chỉ trên bảng ít ghi.**

---

## Bảng số liệu chính

| Kịch bản | node | Heap Fetches | all_visible | buffers | time |
|---|---|---|---|---|---|
| VM bẩn 0 %, chưa VACUUM | **Index Scan** | — | 0/51.414 | **6.878** | **107,6 ms** |
| sau VACUUM | **Index Only Scan** | **0** | 51.414/51.414 | **24** | **0,696 ms** |
| sau UPDATE 22.576 dòng (0,45 %) | Index Only Scan | **7.461** | 39.521/51.414 | **14.953** | 17,9 ms |
| VACUUM lại | Index Only Scan | 0 | 51.414/51.414 | 73 | 0,577 ms |
| §4 lọc `dbl_v` — INCLUDE | Index Scan + Filter | — | — | 99 | 0,484 ms |
| §4 lọc `dbl_v` — cột khoá | Index Scan | — | — | **43** | **0,239 ms** |
| §5 UNIQUE + INCLUDE | Index Only Scan | **0** | — | 14 | **0,040 ms** |
| §6 alarm sau VACUUM | Index Only Scan | **0** | 4.170/4.170 | **10** | **0,222 ms** |
| §6 alarm sau UPDATE cột ngoài index | Index Only Scan | **2.364** | **2**/4.170 | **2.380** | **10,66 ms** |
| §7 INSERT 300k không index | — | — | — | — | **298,9 ms** |
| §7 INSERT 300k có index INCLUDE | — | — | — | — | **1.000,5 ms** |

Kích thước index:
```
(device_id, ts) INCLUDE (dbl_v) : 195 MB   level 2
(device_id, ts, dbl_v)          : 193 MB   level 2   <- KHÔNG nhỏ hơn
```

---

## Ba điều dễ hiểu sai

| # | Hiểu nhầm | Sự thật đo được |
|---|---|---|
| 1 | "Index chứa đủ cột thì được index-only scan" | VM bẩn 100 % → planner **không chọn** index-only scan luôn. Buffers 6.878, chậm 155× so với sau VACUUM |
| 2 | "`INCLUDE` làm index nhỏ hơn đưa cột vào khoá" | **195 MB vs 193 MB — INCLUDE TO HƠN.** Lợi ích thật là giữ được `UNIQUE`, không phải dung lượng |
| 3 | "UPDATE cột không nằm trong index thì không ảnh hưởng index đó" | `UPDATE alarm SET status` (cột ngoài index) làm `all_visible` từ 4.170 xuống **2**, query chậm 48× |

Thêm hai điều tinh vi:
- **`SELECT` có thể ghi đĩa.** Lần 1 báo `dirtied=3359 written=3558` — đó là hint bit. `SELECT` đầu tiên sau đợt ghi lớn luôn đắt bất thường.
- **Sửa 0,45 % số dòng làm mất 23 % số page all-visible** — vì correlation thấp nên dòng rải rác, một dòng bẩn giết cả page.

---

## Áp dụng vào hệ thật

**1. Kiểm tra bảng nào đang mất index-only scan:**

```sql
SELECT c.relname,
       s.n_live_tup,
       s.n_dead_tup,
       round(100.0 * s.n_dead_tup / NULLIF(s.n_live_tup + s.n_dead_tup, 0), 1) AS pct_chet,
       s.last_vacuum, s.last_autovacuum
FROM pg_stat_user_tables s
JOIN pg_class c ON c.oid = s.relid
WHERE s.n_dead_tup > 10000
ORDER BY s.n_dead_tup DESC LIMIT 20;
```

Và đo trực tiếp tỷ lệ VM sạch:
```sql
CREATE EXTENSION IF NOT EXISTS pg_visibility;
SELECT round(100.0 * count(*) FILTER (WHERE all_visible) / count(*), 1) AS pct_all_visible
FROM pg_visibility('ts_kv');
```

**Dưới 80 % = index-only scan của bảng đó đang không hoạt động.**

**2. Với bảng cần index-only scan, hạ ngưỡng autovacuum riêng cho nó:**

```sql
-- mặc định 20% của bảng 5M = 1 triệu dead tuple mới chạy — quá muộn
ALTER TABLE ts_kv SET (autovacuum_vacuum_scale_factor = 0.02);   -- 2%
ALTER TABLE alarm SET (autovacuum_vacuum_scale_factor = 0.05);
```

Đây là đánh đổi rõ ràng: VACUUM chạy thường xuyên hơn (tốn I/O nền) đổi lấy query nhanh 48–155 lần. Với bảng đọc nhiều, luôn đáng. Day 23 tính toán kỹ.

**3. Chỉ `INCLUDE` cột được TRẢ VỀ, không phải cột được LỌC.**

```sql
-- Query: SELECT id, name, status FROM orders WHERE tenant_id=? AND created_at>? AND status='OPEN'
-- SAI: status vào INCLUDE -> phải đọc lên rồi vứt
CREATE INDEX ON orders (tenant_id, created_at) INCLUDE (id, name, status);
-- ĐÚNG: status là điều kiện = -> vào khoá, đứng trước cột range
CREATE INDEX ON orders (tenant_id, status, created_at) INCLUDE (id, name);
```

**4. Dùng `UNIQUE ... INCLUDE` cho mọi lookup theo khoá nghiệp vụ:**
```sql
CREATE UNIQUE INDEX ON users (email) INCLUDE (id, tenant_id, is_active);
```
Giữ nguyên ràng buộc, mà `SELECT id, tenant_id FROM users WHERE email = ?` thành index-only. Không có nhược điểm ngoài dung lượng.

**5. Trước khi thêm index INCLUDE nhiều cột, đo chi phí ghi.** §7 cho thấy một index có thể làm INSERT chậm 3,35 lần và gấp đôi dung lượng. Với bảng ghi nóng, lợi ích đọc có thể không bù được.

**6. Đừng bao giờ tắt autovacuum để "cho nhanh".** Bài này tắt nó có chủ đích trong 30 phút và bảng phình 289 → 402 MB (+39 %). Trên production, đó là con đường ngắn nhất tới sự cố.

---

## Câu hỏi mở sang các ngày sau

1. Partial index `WHERE end_ts IS NULL` chỉ chứa 5 % dòng — nó có được index-only scan dễ hơn không? → **Day 09**
2. Bảng phình 289 → 402 MB sau UPDATE dù đã VACUUM. Phần dư đó ở đâu, lấy lại thế nào? → **Day 22**
3. `autovacuum_vacuum_scale_factor` nên đặt bao nhiêu cho bảng 5M / 500M dòng? → **Day 23**
4. Nếu `UPDATE` là HOT update thì có giữ được `all_visible` không? → **Day 24**
5. `Heap Fetches: 7461` cho 3.731 dòng — vì sao gấp đôi? Liên quan gì tới `xmin`/`xmax`? → **Day 21**
