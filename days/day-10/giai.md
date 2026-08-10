# Day 10 — Lời giải: Cái giá của index — write amplification, bloat, REINDEX + ôn tuần 2

> Bài chữa. Đo thật trên lab `SCALE=1`.

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án |
|---|---|---|
| 1 | Insert 200k dòng vào bảng 5 index chậm hơn bao nhiêu lần? | **9,7 lần** (208 ms → 2.025 ms) |
| 2 | Update ngẫu nhiên 30 % × 5 vòng thì index phình bao nhiêu? | Index trên cột **bị đổi**: **+293 %**. Index trên cột **không đổi**: **+99 %** |
| 3 | `VACUUM` có làm index nhỏ lại không? | **KHÔNG.** 6.104 kB trước và sau. Chỉ `REINDEX` mới co (→ 1.776 kB) |

Câu 3 là điều quan trọng nhất bài này, và cũng là điều bị hiểu sai nhiều nhất.

---

## §1. Mỗi index là một khoản thuế trên đường ghi

Insert **200.000 dòng** vào 4 bảng giống hệt nhau, chỉ khác số index:

| Số index | **thời gian** | chậm hơn | throughput | **WAL sinh ra** | tổng dung lượng |
|---|---|---|---|---|---|
| **0** | **207,8 ms** | 1,00× | 962.000 dòng/s | **17 MB** | 12 MB |
| **1** | **568,7 ms** | **2,74×** | 351.700 dòng/s | **31 MB** | 15 MB |
| **3** | **1.106,3 ms** | **5,32×** | 180.800 dòng/s | **58 MB** | 25 MB |
| **5** | **2.024,7 ms** | **9,74×** | 98.800 dòng/s | **92 MB** | 41 MB |

### Ba điều đọc ra

**1. Index đầu tiên đắt nhất.** Từ 0 → 1 index: chậm **2,74 lần**. Từ 1 → 5 index (thêm 4 cái): chậm thêm 3,56 lần.

Con số này phản trực giác nhưng hợp lý: bảng không index chỉ append vào cuối heap — tuần tự, gần như miễn phí. Index đầu tiên đưa vào **random write** và **ghi WAL cho index**.

Chi phí trung bình mỗi index sau đó: `(2024,7 − 568,7) / 4 = 364 ms/index` ≈ **+64 % so với baseline không index** cho mỗi index thêm vào.

**2. WAL tăng gần tuyến tính: 17 → 31 → 58 → 92 MB.**

```
mỗi index thêm vào  ->  +15 MB WAL cho 200.000 dòng  ->  ~78 byte WAL/dòng/index
```

WAL không chỉ tốn đĩa — nó phải được `fsync` khi commit, sao chép sang replica, và lưu trữ cho PITR. **Với hệ có replica, mỗi index nhân chi phí mạng lên.**

Tỷ lệ đáng nhớ: **5 index làm WAL tăng 5,4 lần** (17 → 92 MB).

**3. Dung lượng: heap 12 MB, 5 index tốn 29 MB — index gấp 2,4 lần dữ liệu.**

### 🔧 Quy đổi sang hệ thật

Với `ts_kv` nhận **50.000 dòng/giây** (hệ IoT quy mô vừa):

| Số index | Throughput đo được | Đáp ứng nổi 50k/s? | WAL mỗi ngày |
|---|---|---|---|
| 0 | 962.000/s | ✅ dư sức | 367 GB |
| 1 | 351.700/s | ✅ | 669 GB |
| 3 | 180.800/s | ✅ | 1,25 TB |
| 5 | 98.800/s | ⚠️ chỉ dư 2× | **1,99 TB** |

Và đây là lab với dữ liệu **nằm gọn trong RAM**. Trên bảng thật 500 GB, index không vừa cache, mỗi lần chèn là một random read từ đĩa — con số throughput sẽ tệ hơn nhiều lần.

> **Với `UPDATE` còn tệ hơn:** trừ khi là HOT update (Day 24), UPDATE tạo dòng ở vị trí vật lý mới → **MỌI index đều phải cập nhật**, kể cả index không chứa cột bị đổi. Đây là lý do quy tắc "cứ thêm index cho chắc" rất tai hại.

---

## §2. Bloat sinh ra thế nào

Bảng `t_bloat` (50.000 dòng, copy từ `device`), autovacuum **tắt**, 5 vòng `UPDATE ... SET name = name || 'x' WHERE random() < 0.3`:

| Vòng | Bảng | `idx_bloat_name` (**cột bị đổi**) | `idx_bloat_tenant` (**cột không đổi**) |
|---|---|---|---|
| 0 | 9.728 kB | **1.552 kB** | **1.552 kB** |
| 1 | 12 MB | 3.096 kB (+99 %) | 3.088 kB (+99 %) |
| 2 | 13 MB | 3.096 kB | 3.096 kB |
| 3 | 14 MB | 3.584 kB | 3.096 kB |
| 4 | 14 MB | 4.712 kB | 3.096 kB |
| **5** | **15 MB (+58 %)** | **6.104 kB (+293 %)** | **3.096 kB (+99 %)** |

### Hai điều quan trọng

**1. Index trên cột KHÔNG bị đổi vẫn phình +99 %.**

Đây là điều nhiều người bất ngờ. `tenant_id` và `created_at` không hề bị `UPDATE` chạm tới, nhưng index vẫn to gấp đôi.

Lý do: **`UPDATE` = DELETE + INSERT** (Day 21). Dòng mới nằm ở **vị trí vật lý (TID) mới**. Mọi index đều lưu TID → mọi index đều phải thêm entry mới trỏ tới TID mới, kể cả khi giá trị khoá y hệt.

Nó dừng ở +99 % (gấp đôi) rồi ổn định, vì sau vòng 1 các page đã có chỗ trống từ entry chết để tái sử dụng.

**2. Index trên cột BỊ đổi phình gấp 3 và không dừng lại.**

`idx_bloat_name` tiếp tục tăng qua từng vòng: 3.096 → 3.584 → 4.712 → 6.104 kB. Vì `name` thay đổi giá trị mỗi vòng → entry mới nằm ở **vị trí khác trong cây** (thứ tự từ điển đổi) → không tái dùng được chỗ trống, phải cấp page mới liên tục.

> **Luật: đổi giá trị của cột được index đắt hơn nhiều so với đổi cột không được index. Đây là lý do không nên index cột thay đổi thường xuyên (counter, last_seen_at, status đang chạy).**

---

## §3. Đo bloat bằng `pgstattuple`

```
       idx        | index_size | leaf_pages | avg_leaf_density | leaf_fragmentation
------------------+------------+------------+------------------+--------------------
 idx_bloat_name   |    6250496 |        757 |        61.28 %   |       49.27 %
 idx_bloat_tenant |    3170304 |        383 |        79.15 %   |       49.87 %

 dead_tuple_percent | free_percent      <- heap
--------------------+--------------
              24.21 |         9.71
```

| Chỉ số | Nghĩa | Ngưỡng |
|---|---|---|
| `avg_leaf_density` | % không gian page lá thực sự chứa dữ liệu | mới build ~90 %, **dưới 60 % là đáng REINDEX** |
| `leaf_fragmentation` | % page lá không nằm liền kề nhau về vật lý | cao = range scan phải nhảy nhiều |
| `dead_tuple_percent` | % dòng chết trong heap | **> 20 % là autovacuum đang không theo kịp** |

**`idx_bloat_name` tệ hơn: density 61,28 % vs 79,15 %.** Khớp với §2 — index trên cột bị đổi bloat nặng hơn.

`leaf_fragmentation` gần 50 % ở cả hai: page lá bị xáo trộn thứ tự vật lý. Với range scan (`WHERE name BETWEEN ...`) điều này biến đọc tuần tự thành đọc ngẫu nhiên.

---

## §4. VACUUM vs REINDEX vs VACUUM FULL — bảng quan trọng nhất bài

| | Bảng | `idx_bloat_name` | `idx_bloat_tenant` | `dead_tuple_%` | `free_%` | `avg_leaf_density` |
|---|---|---|---|---|---|---|
| **sau 5 vòng UPDATE** | 15 MB | 6.104 kB | 3.096 kB | **24,21** | 9,71 | 61,28 |
| **sau `VACUUM`** | **15 MB** *(y nguyên)* | **6.104 kB** *(y nguyên)* | 3.096 kB | **0** ✅ | **34,42** | **26,13** ⚠️ |
| **sau `REINDEX idx_bloat_name`** | 15 MB | **1.776 kB** ✅ | 3.096 kB | 0 | 34,42 | **89,78** ✅ |
| **sau `VACUUM FULL`** | **9.720 kB** ✅ | 1.776 kB | **1.552 kB** ✅ | 0 | **1,47** | — |

### VACUUM lấy lại được gì

**Lấy lại:** đánh dấu không gian của dòng chết là **tái sử dụng được**. `dead_tuple_percent` **24,21 → 0**, `free_percent` **9,71 → 34,42**.

**KHÔNG lấy lại:** một byte nào cho hệ điều hành. Bảng vẫn **15 MB**, index vẫn **6.104 kB**. Không gian trống nằm **bên trong** file, chờ dữ liệu mới lấp vào.

### 💡 Chi tiết phản trực giác nhất bài: VACUUM làm `avg_leaf_density` TỆ ĐI

```
trước VACUUM: avg_leaf_density = 61,28 %
sau  VACUUM: avg_leaf_density = 26,13 %     <- GIẢM
```

Không phải lỗi. VACUUM **xoá các entry chết ra khỏi page lá** nhưng **không gộp page lại**. Kết quả: cùng số page, ít dữ liệu hơn → mật độ giảm.

Con số 26,13 % nghĩa là: **74 % không gian index là khoảng trống**, nằm rải rác trong 757 page. Mọi lần đọc index vẫn phải đi qua đủ 757 page đó.

> **Đây chính là cơ chế khiến index production phình gấp 2–3 lần sau vài tháng dù số dòng không đổi — và autovacuum chạy đều cũng không cứu được.**

### REINDEX lấy lại được gì

**6.104 kB → 1.776 kB, giảm 71 %.** `avg_leaf_density` **26,13 → 89,78 %**, `leaf_fragmentation` **49,27 → 0**.

REINDEX **build lại index từ đầu**: đọc bảng, sắp xếp, ghi cây mới chặt khít. Đây là cách duy nhất lấy lại không gian index.

Chú ý index mới còn **nhỏ hơn ban đầu** (1.776 vs 1.552 kB ban đầu — hơi to hơn vì `name` đã dài thêm 5 ký tự).

### VACUUM FULL lấy lại được gì

**Tất cả.** Bảng 15 MB → **9.720 kB** (bằng đúng lúc mới tạo). `idx_bloat_tenant` 3.096 → **1.552 kB**. `free_percent` 34,42 → **1,47**.

`VACUUM FULL` viết lại **toàn bộ bảng và mọi index** vào file mới.

### Bảng so sánh — học thuộc

| | `VACUUM` | `VACUUM FULL` | `REINDEX` | `REINDEX CONCURRENTLY` |
|---|---|---|---|---|
| Xoá dòng chết trong heap | ✅ | ✅ | ✗ | ✗ |
| **Trả dung lượng heap về OS** | ✗ | ✅ | ✗ | ✗ |
| Xoá entry rác trong index | ✅ | ✅ | ✅ | ✅ |
| **Gộp page index, trả dung lượng** | ✗ | ✅ | ✅ | ✅ |
| Cập nhật visibility map | ✅ | ✅ | ✗ | ✗ |
| **Khoá** | chỉ chặn DDL | **ACCESS EXCLUSIVE** | **ACCESS EXCLUSIVE** | chỉ chặn DDL |
| Cần chỗ trống thêm | ~0 | **= kích thước bảng** | = kích thước index | = kích thước index |
| Chạy trên production giờ cao điểm | ✅ | ❌ **TUYỆT ĐỐI KHÔNG** | ❌ | ✅ |

**`VACUUM FULL` chặn cả `SELECT`.** Trên bảng 500 GB nó chạy hàng giờ và cần thêm 500 GB đĩa trống. Đây là công cụ của cửa sổ bảo trì, không phải công cụ hằng ngày.

---

## §5. `CONCURRENTLY`

### Chi phí thời gian

```
CREATE INDEX             ts_kv(dbl_v) : 1.965 ms
CREATE INDEX CONCURRENTLY ts_kv(dbl_v) : 2.946 ms
```

**Chậm hơn 1,5 lần.** (Tài liệu thường nói 2–3 lần; ở đây bảng nằm gọn trong cache nên chênh ít hơn.)

Lý do chậm: `CONCURRENTLY` quét bảng **hai lượt** — lượt một build index, lượt hai bắt các thay đổi xảy ra trong lúc build. Giữa hai lượt còn phải chờ mọi transaction đang mở kết thúc.

### Không chạy được trong transaction

```
BEGIN;
CREATE INDEX CONCURRENTLY idx_fail ON t_bloat(firmware);
ERROR:  CREATE INDEX CONCURRENTLY cannot run inside a transaction block
```

Vì nó cần **commit giữa chừng** (sau lượt quét thứ nhất) để các transaction khác thấy index đang được build.

**Hệ quả thực tế rất quan trọng:** hầu hết công cụ migration (Flyway, Liquibase, golang-migrate, Rails) **bọc mỗi migration trong một transaction** → `CREATE INDEX CONCURRENTLY` sẽ lỗi. Phải tắt transaction cho migration đó:

| Công cụ | Cách tắt |
|---|---|
| Flyway | đặt tên file có hậu tố, hoặc `flyway.postgresql.transactional.lock=false` |
| Liquibase | `runInTransaction="false"` |
| golang-migrate | file `.sql` không có `BEGIN`, dùng `-x` no-transaction |
| Rails | `disable_ddl_transaction!` |

Day 43 nói kỹ.

### Rủi ro: index INVALID

Nếu `CREATE INDEX CONCURRENTLY` thất bại (deadlock, `lock_timeout`, huỷ giữa chừng), nó để lại index ở trạng thái **INVALID**:

- ❌ planner **không dùng** nó
- ✅ vẫn **tốn dung lượng**
- ✅ vẫn **phải cập nhật khi ghi** — tức là mọi nhược điểm, không lợi ích nào

Query phát hiện — **phải đưa vào monitoring**:
```sql
SELECT indexrelid::regclass AS idx_hong,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_index WHERE NOT indisvalid;
```

Ở lab trả về 0 dòng (không có index hỏng). Trên production thật, đây là thứ hay bị bỏ quên nhất — index INVALID có thể nằm im hàng năm.

Sửa: `DROP INDEX CONCURRENTLY idx_hong;` rồi tạo lại.

---

## §6. Index không ai dùng

```
 tổng index toàn DB : 1.504 MB
 index có idx_scan=0:    58 MB
```

| tbl | idx | idx_scan | size | unique | primary |
|---|---|---|---|---|---|
| device_attr | `device_attr_pkey` | **0** | 4.904 kB | **✅** | **✅** |
| device | `idx_dev_uuid` | 0 | 1.552 kB | f | f |
| alarm | `idx_alarm_thresh` | 0 | 1.392 kB | f | f |
| ts_key_dict | `ts_key_dict_pkey` | **0** | 16 kB | **✅** | **✅** |
| ts_key_dict | `ts_key_dict_key_key` | **0** | 16 kB | **✅** | f |

### Ba điều phải kiểm tra trước khi xoá

**1. Index có phục vụ ràng buộc không.**

`device_attr_pkey` có `idx_scan = 0` nhưng **TUYỆT ĐỐI không được xoá** — nó là PRIMARY KEY. Index unique/PK làm nhiệm vụ **ép ràng buộc**, không chỉ tra cứu. Xoá nó = cho phép dữ liệu trùng vào.

Tương tự `ts_key_dict_key_key` (UNIQUE constraint) và các index phục vụ FOREIGN KEY.

**2. Thống kê tích luỹ từ bao giờ.**

```sql
SELECT stats_reset FROM pg_stat_database WHERE datname = current_database();
```
Lab trả về **NULL** — nghĩa là chưa từng reset, nhưng cũng nghĩa là số liệu chỉ tích luỹ từ lúc DB được tạo (hôm nay). `idx_scan = 0` sau vài giờ **không có ý nghĩa gì**.

Cần **ít nhất một chu kỳ nghiệp vụ đầy đủ** — thường là 1 tháng, để bắt cả job cuối tháng, báo cáo quý, job đối soát.

**3. Có replica không.**

`idx_scan` **không được đồng bộ từ replica về primary**. Index chỉ dùng cho query báo cáo trên replica sẽ hiện `0` trên primary. **Phải cộng số liệu từ mọi node** trước khi kết luận.

Thêm điều thứ tư đáng nhớ: index có thể đang phục vụ **`ORDER BY`** hoặc là index dùng cho `CLUSTER` — những trường hợp `idx_scan` không phản ánh hết giá trị.

---

## §7. Ôn tuần 2

### A. Checklist 6 dòng — khi nào thêm index, khi nào từ chối

Dùng được ngay khi review PR:

```
① THÊM khi: query nóng (top 20 pg_stat_statements theo total_exec_time)
   có `Rows Removed by Filter` > 10× số dòng trả về.
   -> Đo trước, đừng đoán. Không có số liệu = không thêm index.

② THÊM đúng thứ tự: cột `=` trước, cột ORDER BY giữa, MỘT cột range cuối,
   cột chỉ để SELECT vào INCLUDE, điều kiện cố định vào WHERE (partial).

③ THÊM dạng partial nếu query luôn kèm một điều kiện lọc cố định.
   Đo được ở Day 09: 16 kB thay vì 194 MB, nhanh 57×.

④ TỪ CHỐI nếu đã có index khác có cột đó làm TIỀN TỐ.
   `(a,b,c)` đã phục vụ `(a)` và `(a,b)`. Chạy query tìm index thừa (Day 07 §7).

⑤ TỪ CHỐI nếu cột bị UPDATE thường xuyên (counter, last_seen, status đang chạy).
   Đo được hôm nay: index trên cột bị đổi phình +293% sau 5 vòng update.

⑥ TỪ CHỐI nếu bảng là đường ghi nóng và index thứ N+1 không cứu query nào
   trong top 20. Mỗi index = +64% thời gian INSERT và +15MB WAL/200k dòng.
```

Câu hỏi kèm theo cho mọi PR thêm index: *"query nào cần nó, nó đang đứng thứ mấy trong `pg_stat_statements`, và buffers trước/sau là bao nhiêu?"* Không trả lời được = chưa đủ điều kiện merge.

### B. Ba điều tôi tưởng đúng mà hoá ra sai trong tuần 2

**1. "`VACUUM` dọn dẹp thì index sẽ nhỏ lại."**

*Sự thật:* `VACUUM` **không trả một byte nào**. Index 6.104 kB trước và sau. Tệ hơn: `avg_leaf_density` **giảm từ 61,28 % xuống 26,13 %** — VACUUM xoá entry chết nhưng không gộp page, nên mật độ tệ đi.

Chỉ `REINDEX` mới co index (6.104 → 1.776 kB, density 89,78 %). Đây là lý do index production phình gấp 2–3 lần sau vài tháng dù autovacuum chạy đều.

**2. "`INCLUDE` làm index nhỏ hơn đưa cột vào khoá."**

*Sự thật (Day 08):* `(device_id, ts) INCLUDE (dbl_v)` = **195 MB**; `(device_id, ts, dbl_v)` = **193 MB**. INCLUDE **to hơn**. Lợi ích thật của nó là giữ được ràng buộc `UNIQUE` trên tập cột hẹp hơn — không phải dung lượng.

**3. "Điều kiện lọt vào `Index Cond` là index đang làm việc tốt."**

*Sự thật (Day 07):* với index sai thứ tự `(ts, device_id)`, cả hai điều kiện đều nằm trong `Index Cond`, `Rows Removed by Filter = 0` — plan trông hoàn hảo. Nhưng **buffers 217 vs 4**, chậm **62 lần**. Vì `device_id` là *non-boundary qual*: nó lọc từng entry trong lúc quét chứ không thu hẹp phạm vi.

**Chỉ buffers mới nói thật.**

**Bonus 4:** index-only scan không phụ thuộc vào việc anh sửa cột nào — `UPDATE alarm SET status` (cột **ngoài** index) làm `all_visible` từ 4.170 xuống **2**, query chậm **48 lần** (Day 08 §6).

### C. Query monitoring index — mang thẳng về production

```sql
-- MỘT query trả về cả 3 vấn đề: bloat cao, không ai dùng, INVALID
-- Cần: CREATE EXTENSION pgstattuple;
WITH idx AS (
  SELECT s.schemaname, s.relname AS tbl, s.indexrelname AS idx,
         s.indexrelid, s.idx_scan,
         pg_relation_size(s.indexrelid) AS bytes,
         i.indisvalid, i.indisprimary, i.indisunique
  FROM pg_stat_user_indexes s
  JOIN pg_index i ON i.indexrelid = s.indexrelid
)
SELECT tbl, idx,
       pg_size_pretty(bytes) AS size,
       idx_scan,
       CASE
         WHEN NOT indisvalid                              THEN 'INVALID — drop & tạo lại'
         WHEN idx_scan = 0 AND NOT indisprimary
                          AND NOT indisunique
                          AND bytes > 10*1024*1024        THEN 'KHÔNG DÙNG — xem xét xoá'
         WHEN bytes > 100*1024*1024
              AND (pgstatindex(idx::regclass)).avg_leaf_density < 60
                                                          THEN 'BLOAT — REINDEX CONCURRENTLY'
       END AS van_de,
       CASE WHEN bytes > 100*1024*1024
            THEN round((pgstatindex(idx::regclass)).avg_leaf_density::numeric, 1) END AS density
FROM idx
WHERE NOT indisvalid
   OR (idx_scan = 0 AND NOT indisprimary AND NOT indisunique AND bytes > 10*1024*1024)
   OR (bytes > 100*1024*1024 AND (pgstatindex(idx::regclass)).avg_leaf_density < 60)
ORDER BY bytes DESC;
```

⚠️ **`pgstatindex` quét toàn bộ index** — đắt. Nên query này chỉ tính density cho index > 100 MB, và **chỉ chạy vào giờ thấp điểm** (hoặc trên replica). Với DB lớn, tách thành job hằng tuần ghi kết quả vào bảng thay vì chạy trực tiếp.

Kèm theo, ba dòng cảnh báo rẻ tiền nên chạy liên tục:
```sql
-- 1. Index INVALID (rẻ, chạy mỗi phút được)
SELECT count(*) FROM pg_index WHERE NOT indisvalid;

-- 2. Bảng có dead tuple cao (autovacuum không theo kịp)
SELECT relname, n_dead_tup, round(100.0*n_dead_tup/NULLIF(n_live_tup+n_dead_tup,0),1) AS pct
FROM pg_stat_user_tables WHERE n_dead_tup > 100000 ORDER BY n_dead_tup DESC;

-- 3. Tổng dung lượng index chưa từng dùng
SELECT pg_size_pretty(sum(pg_relation_size(indexrelid))) FROM pg_stat_user_indexes
WHERE idx_scan = 0;
```

---

## Bảng số liệu chính

| Kịch bản | Kết quả |
|---|---|
| INSERT 200k, 0 index | **207,8 ms**, WAL 17 MB |
| INSERT 200k, 1 index | 568,7 ms (**2,74×**), WAL 31 MB |
| INSERT 200k, 3 index | 1.106,3 ms (5,32×), WAL 58 MB |
| INSERT 200k, 5 index | **2.024,7 ms (9,74×)**, WAL **92 MB (5,4×)** |
| Bloat sau 5 vòng UPDATE 30 % — bảng | 9.728 kB → **15 MB (+58 %)** |
| — index trên cột **bị đổi** | 1.552 → **6.104 kB (+293 %)** |
| — index trên cột **không đổi** | 1.552 → **3.096 kB (+99 %)** |
| `pgstatindex` sau bloat | density **61,28 %**, frag **49,27 %** |
| Sau `VACUUM` | size **y nguyên**, dead_tup 24,21→**0**, density **61,28→26,13 %** |
| Sau `REINDEX` | 6.104 → **1.776 kB (−71 %)**, density **89,78 %**, frag **0** |
| Sau `VACUUM FULL` | bảng 15 MB → **9.720 kB**, idx_tenant 3.096 → **1.552 kB** |
| `CREATE INDEX` thường | 1.965 ms |
| `CREATE INDEX CONCURRENTLY` | **2.946 ms (1,5×)** |
| Tổng index toàn DB | 1.504 MB (58 MB chưa từng dùng) |

---

## Ba điều dễ hiểu sai

| # | Hiểu nhầm | Sự thật đo được |
|---|---|---|
| 1 | "VACUUM làm index nhỏ lại" | Size **y nguyên**. `avg_leaf_density` còn **giảm** 61,28 → 26,13 %. Chỉ REINDEX mới co |
| 2 | "UPDATE cột không được index thì index không bị ảnh hưởng" | Index trên cột **không đổi** vẫn phình **+99 %** — vì UPDATE tạo TID mới, mọi index phải trỏ lại |
| 3 | "Thêm một index thì chậm đi vài phần trăm" | Index **đầu tiên** làm INSERT chậm **2,74 lần**. 5 index → **9,74 lần** và WAL **5,4 lần** |

---

## Áp dụng vào hệ thật

**1. Đặt lịch `REINDEX CONCURRENTLY` cho index bloat — đây là việc chưa ai trong team làm:**

```sql
-- chạy hằng tuần vào giờ thấp điểm, cho index > 1GB có density < 60%
REINDEX INDEX CONCURRENTLY idx_xxx;
```
Đo được: lấy lại **71 %** dung lượng. Trên index 20 GB đó là 14 GB, và index gọn hơn = vừa cache hơn = query nhanh hơn.

**2. Kiểm tra index INVALID ngay hôm nay.** Một dòng SQL, và index INVALID có thể đã nằm im hàng năm trên hệ của anh:
```sql
SELECT indexrelid::regclass, pg_size_pretty(pg_relation_size(indexrelid))
FROM pg_index WHERE NOT indisvalid;
```

**3. Với bảng ghi nóng (`ts_kv` tương đương), đếm lại số index và tính chi phí:**
```
mỗi index thêm vào ≈ +64% thời gian INSERT, +78 byte WAL/dòng
```
Nếu bảng nhận 50k dòng/s và có 5 index, anh đang trả **2 TB WAL/ngày** cho việc đó.

**4. Không index cột thay đổi thường xuyên.** `last_seen_at`, `login_count`, `updated_at` — nếu bắt buộc phải index, cân nhắc tách sang bảng riêng để không kéo bloat cho bảng chính.

**5. Với `CREATE INDEX CONCURRENTLY` trên production, luôn kèm `lock_timeout` và kiểm tra kết quả:**
```sql
SET lock_timeout = '5s';
CREATE INDEX CONCURRENTLY idx_x ON tbl(col);
-- rồi kiểm tra ngay:
SELECT indisvalid FROM pg_index WHERE indexrelid = 'idx_x'::regclass;
```

**6. `VACUUM FULL` chỉ dùng trong cửa sổ bảo trì.** Cần chỗ trống bằng kích thước bảng và khoá `ACCESS EXCLUSIVE` (chặn cả SELECT). Với bảng lớn, dùng `pg_repack` — nó làm cùng việc mà không khoá.

---

## Hết tuần 2

| Ngày | Câu hỏi được trả lời | Con số đắt nhất |
|---|---|---|
| 06 | B-tree nằm thế nào trên đĩa | fanout **285**, 5M dòng chỉ **3 tầng**, dedup **−68 %** |
| 07 | Thứ tự cột quyết định gì | sai thứ tự chậm tới **470×** |
| 08 | Index-only scan phụ thuộc gì | VACUUM làm buffers giảm **287×** |
| 09 | Partial + expression index | index **16 kB** nhanh hơn **57×** |
| 10 | Cái giá phải trả | 5 index = INSERT chậm **9,74×**, WAL **5,4×** |

Tuần 3 trả lời câu còn treo từ Day 04: **khi nào planner ước lượng sai, và vì sao.**
