# Day 24 — Lời giải: HOT update & fillfactor

> Bài chữa. Đo thật trên lab `SCALE=1`.

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án |
|---|---|---|
| 1 | `UPDATE` cột **không** index — có phải cập nhật index không? | **CÓ, trừ khi là HOT update.** Và HOT cần page còn chỗ — mà `fillfactor = 100` thì không có |
| 2 | `fillfactor = 70` làm bảng to hơn — bù lại bằng gì? | To hơn **39 %** lúc đầu, nhưng sau 5 vòng UPDATE lại **NHỎ HƠN 45 %** (93 MB vs 170 MB) |
| 3 | Update cột có index vs không index — chênh mấy lần? | Ở `fillfactor = 100`: **gần như bằng nhau** (cả hai đều 0 % HOT). Ở `fillfactor = 70`: khác hẳn |

Câu 1 là bài học chính: **`fillfactor` quan trọng hơn "cột có index hay không".**

---

## §1 + §2. HOT — hai điều kiện, và điều kiện 2 mới là điều kiện chặn

Bảng `t_noidx` với `fillfactor` mặc định (100):

| Loại UPDATE | `n_tup_upd` | `n_tup_hot_upd` | **tỷ lệ HOT** | time | Kích thước |
|---|---|---|---|---|---|
| cột **KHÔNG** index (`hot_col`) | 200.000 | **0** | **0,000** | 1.388,5 ms | 37 → **74 MB** |
| cột **CÓ** index (`idx_col`) | 200.000 | **0** | **0,000** | 1.765,1 ms | 74 → **107 MB** |

### **Cả hai đều 0 % HOT — kể cả khi update cột không được index.**

Đây là kết quả quan trọng nhất bài. Điều kiện HOT gồm **hai** vế:

```
① UPDATE không chạm cột nào được index          <- vế này ĐÚNG với hot_col
② Tuple mới nằm TRONG CÙNG PAGE với tuple cũ    <- vế này SAI
```

Vế ② hỏng vì `fillfactor = 100`: `INSERT` lấp đầy page 100 %, không còn chỗ cho phiên bản mới → tuple mới phải sang page khác → mất HOT.

> **Rất nhiều người chỉ nhớ vế ① và tưởng "tránh index cột hay đổi là đủ". Số đo nói: không đủ. Không có `fillfactor` thì HOT gần như không bao giờ xảy ra.**

Chênh lệch giữa hai loại update vẫn có, chỉ nhỏ hơn dự kiến: 1.388 vs 1.765 ms (**1,27 lần**) và kích thước tăng thêm 37 MB vs 33 MB.

---

## §3. HOT chain trong page

Bảng `t_hot` với `fillfactor = 70`, cập nhật `v` (không index) 3 lần trên dòng `id = 1`:

**Trước UPDATE:**
```
 lp | lp_off | t_xmin | t_xmax | t_ctid | flag
----+--------+--------+--------+--------+--------
  1 |   8104 |   1847 |      0 | (0,1)  | normal
  ... slot 2..10
```

**Sau 3 lần UPDATE:**
```
 lp | t_xmin | t_xmax | t_ctid | flag
----+--------+--------+--------+--------
  1 |   1847 |   1848 | (0,11) | normal     <- v0 chết, TRỎ TỚI (0,11)
  ...
 11 |   1848 |   1849 | (0,12) | normal     <- v1 chết, trỏ tới (0,12)
 12 |   1849 |   1850 | (0,13) | normal     <- v2 chết, trỏ tới (0,13)
 13 |   1850 |      0 | (0,13) | normal     <- v3 SỐNG (trỏ về chính nó)
```

### Đây chính là HOT chain

**Mọi `t_ctid` đều có page number = 0** — chuỗi nằm gọn trong **cùng một page**:
```
(0,1) → (0,11) → (0,12) → (0,13)
```

**Index vẫn trỏ tới slot 1.** Khi tra index, Postgres đi theo chuỗi trong page tới slot 13. **Index không cần sửa một byte nào.**

So với Day 21 §2 (fillfactor 100): ở đó `ctid` cũng nhảy trong cùng page nhưng vì page đầy nên các update sau phải sang page khác — và mỗi lần sang page khác là một entry index mới.

### Dòng `id = 1` chiếm mấy slot

**4 slot** (1, 11, 12, 13). Ba slot là rác.

### ⚠️ Không thấy `REDIRECT`, và page pruning chưa xảy ra

Sau `SELECT count(*)`, các slot **vẫn là `normal`**, chưa có slot nào thành `REDIRECT`.

Vì **page pruning chỉ kích hoạt khi page gần đầy** (hoặc khi tuple bị đánh dấu là "pruning có lợi"). Page này mới dùng ~30 % nên Postgres không thấy cần dọn.

Khi pruning xảy ra, slot 1 sẽ thành **`REDIRECT`** trỏ thẳng tới slot 13, và slot 11, 12 thành `unused` — không gian được tái sử dụng **mà không cần VACUUM**.

### Page pruning khác VACUUM ở chỗ nào

| | **Page pruning** | **VACUUM** |
|---|---|---|
| Kích hoạt bởi | bất kỳ thao tác đọc/ghi chạm page (SELECT cũng được) | autovacuum hoặc lệnh thủ công |
| Phạm vi | **một page** | toàn bảng |
| Dọn được gì | chỉ **HOT chain** trong page đó | mọi dead tuple |
| Có đụng index không | **KHÔNG** | có — phải xoá entry tương ứng |
| Chi phí | rất rẻ, đồng bộ | đắt, chạy nền |
| Cập nhật visibility map | không | có |

> **Page pruning là lý do HOT update rẻ hơn nhiều so với update thường: rác được dọn ngay tại chỗ bởi chính câu SELECT tiếp theo, không cần chờ autovacuum và không cần đụng index.**

---

## §4. `fillfactor` — số liệu quyết định

| | **`fillfactor = 100`** | **`fillfactor = 70`** |
|---|---|---|
| **Kích thước ban đầu** | **31 MB** | **43 MB (+39 %)** |
| tỷ lệ HOT sau 5 vòng | **0,000** | **0,722** |
| **Kích thước sau 5 vòng UPDATE** | **170 MB** | **93 MB** |
| **Chênh lệch cuối** | — | **NHỎ HƠN 45 %** |
| time mỗi vòng UPDATE | ~1.250 ms | **~450–500 ms** |
| **Tốc độ UPDATE** | 1,00× | **~2,6× nhanh hơn** |

### 💡 Đây là kết quả đắt giá nhất bài

```
Lúc đầu:      ff70 to hơn ff100  39%   (43 MB vs 31 MB)
Sau 5 vòng:   ff70 NHỎ HƠN ff100 45%   (93 MB vs 170 MB)
```

**Điểm hoà vốn nằm ở đâu đó trong vòng UPDATE thứ nhất hoặc thứ hai.** Chỉ cần bảng bị UPDATE **hơn một lần trên mỗi dòng** là `fillfactor = 70` đã có lãi.

Và tỷ lệ HOT **0,722** nghĩa là 72 % số update **không đụng index nào** — index không bloat, WAL ít hơn, page pruning tự dọn.

### Vì sao ff70 nhanh hơn 2,6 lần

| Chi phí | ff100 | ff70 (khi HOT) |
|---|---|---|
| Tìm page mới có chỗ | phải hỏi Free Space Map | không cần — dùng ngay page hiện tại |
| Ghi entry index mới | **1 lần cho MỖI index** | **0** |
| WAL cho index | có | **không** |
| Dọn rác | cần VACUUM | **page pruning tự làm** |

### Cách áp dụng

```sql
ALTER TABLE tbl SET (fillfactor = 70);
VACUUM FULL tbl;    -- BẮT BUỘC: fillfactor chỉ áp cho page MỚI
```

Không có `VACUUM FULL` (hoặc `pg_repack`), các page cũ vẫn đầy 100 % và cấu hình không có tác dụng gì.

| Khi nào dùng | Giá trị |
|---|---|
| Bảng UPDATE nhiều lần trên cùng dòng (trạng thái, counter, session, cache) | **70–85** |
| Bảng UPDATE vừa phải | 90 |
| **Bảng append-only** (`ts_kv`, log, event) | **giữ 100** — chừa chỗ chỉ tổ lãng phí |

Index cũng có `fillfactor` riêng (mặc định **90** cho B-tree) — chừa chỗ để giảm page split (Day 06 §5).

---

## §5. Ma trận 4 kịch bản

| Bảng | fillfactor | cột update | `n_tup_hot_upd` | **tỷ lệ HOT** | **time** | size ban đầu → sau |
|---|---|---|---|---|---|---|
| **m2** | **70** | **KHÔNG index** | **89.477** | **0,447** ✅ | **1.163,0 ms** | 50 → 81 MB |
| m4 | 70 | CÓ index | 0 | 0,000 | 1.242,6 ms | 50 → 81 MB |
| m1 | 100 | KHÔNG index | 0 | 0,000 | **1.484,1 ms** | 37 → 74 MB |
| m3 | 100 | CÓ index | 0 | 0,000 | 1.414,6 ms | 37 → 74 MB |

### Đọc bảng này

**Chỉ m2 có HOT update.** Nó là kịch bản duy nhất thoả **cả hai** điều kiện:
- ✅ `fillfactor = 70` → page còn chỗ (điều kiện ②)
- ✅ update `hot_col` không được index (điều kiện ①)

**m4 (ff70 nhưng update cột có index): 0 % HOT** — thoả điều kiện ② nhưng vi phạm ①.
**m1 (ff100, cột không index): 0 % HOT** — thoả ① nhưng vi phạm ②.

> **Hai điều kiện là VÀ, không phải HOẶC. Thiếu một cái là mất hết.**

Tỷ lệ HOT của m2 chỉ 0,447 (không phải 0,722 như §4) vì bảng này có thêm cột `idx_col` và một index nữa, làm dòng rộng hơn → ít chỗ trống hơn cho phiên bản mới.

### Kịch bản tốt nhất / tệ nhất

| | Kịch bản | Kết quả |
|---|---|---|
| **Tốt nhất** | **m2**: ff70 + cột không index | HOT 44,7 %, nhanh nhất, WAL ít nhất |
| **Tệ nhất** | **m1**: ff100 + cột không index | chậm nhất (1.484 ms), WAL nhiều nhất (107 MB) |

Điều thú vị: **m1 tệ hơn m3** dù m3 update cột **có** index. Vì với ff100 thì cả hai đều mất HOT, mà m1 lại phải cập nhật index PK... — chênh lệch nằm trong biên nhiễu (1.484 vs 1.415 ms), không nên diễn giải quá.

---

## §6. WAL — thước đo thật của chi phí ghi

| Query | **WAL** | `wal_records` | **`wal_fpi`** | time |
|---|---|---|---|---|
| **m1** ff100, cột không index | **107 MB** | 805.464 | **4.187** | 1.461,4 ms |
| m3 ff100, cột có index | **100 MB** | 805.464 | 3.209 | 1.381,8 ms |
| **m2** ff70, cột không index (HOT) | **91 MB** | **535.941** | 5.814 | 1.151,7 ms |
| **m4** ff70, cột có index | **70 MB** | 715.987 | **0** | 1.187,5 ms |

### Đọc số này cẩn thận — kết quả không đơn giản như kỳ vọng

**`wal_records`: m2 chỉ 535.941 vs m1/m3 805.464 — ít hơn 33 %.**

Đó là dấu vân tay của HOT: 805.464 ≈ 200.000 heap + 200.000 PK index + 200.000 idx_col index + phụ trợ. Với m2, 44,7 % update là HOT → không sinh record index → **giảm đúng ~33 %**.

**Nhưng tổng WAL của m2 (91 MB) không giảm tương ứng** — vì `wal_fpi = 5.814`, cao nhất bảng.

### `wal_fpi` là gì và vì sao nó quan trọng

**FPI = Full Page Image.** Lần đầu một page bị sửa **sau mỗi checkpoint**, Postgres ghi **toàn bộ page 8 KB** vào WAL (không chỉ phần thay đổi).

Lý do: chống **torn page** — nếu máy chết giữa lúc OS đang ghi một page 8 KB, page trên đĩa có thể nửa cũ nửa mới. FPI cho phép khôi phục nguyên vẹn.

```
1 FPI = 8 KB WAL cho MỘT thay đổi vài byte
5.814 FPI × 8 KB = 46 MB      <- một nửa WAL của m2!
```

**m4 có `wal_fpi = 0`** vì nó chạy cuối cùng, các page của nó đã được ghi FPI trong checkpoint trước đó rồi. Đây là lý do WAL của m4 thấp nhất (70 MB) — **không phải vì nó hiệu quả hơn, mà vì thời điểm chạy.**

> **Bài học đo lường: so WAL giữa các query chạy ở thời điểm khác nhau so với checkpoint là KHÔNG công bằng.** Muốn so đúng, phải `CHECKPOINT;` trước mỗi lần đo, hoặc so `wal_records` thay vì `wal_bytes`.

Day 37 đào sâu FPI và `full_page_writes`.

**So sánh công bằng nhất ở đây là `wal_records`:**
```
m1, m3 (không HOT): 805.464 record
m2     (44,7% HOT): 535.941 record   -> giảm 33%
```

---

## §7. Tỷ lệ HOT toàn database

```
 relname | n_tup_upd | n_tup_hot_upd | ty_le_hot | so_index
---------+-----------+---------------+-----------+----------
 t_ff100 |   1000000 |           174 |     0.000 |        1
 t_noidx |    200000 |             0 |     0.000 |        2
 t_ff70  |   1000000 |        767870 |     0.768 |        1
 t_hot   |         3 |             3 |     1.000 |        1
```

### Có tương quan với số index không

**Ở lab: KHÔNG rõ ràng.** `t_ff100` và `t_ff70` có **cùng 1 index** nhưng tỷ lệ HOT là **0,000 vs 0,768**.

Biến quyết định ở đây là **`fillfactor`**, không phải số index.

Nhưng số index vẫn quan trọng theo cách khác:

| Số index | Ảnh hưởng |
|---|---|
| Nhiều index | càng nhiều cột "cấm đụng" nếu muốn HOT → điều kiện ① khó thoả |
| Nhiều index | dòng index rộng hơn... không, nhưng **mỗi update không-HOT tốn thêm 1 entry/index** |
| Nhiều index | VACUUM chậm hơn (mỗi lượt phải quét mọi index) |

> **Công thức đầy đủ: tỷ lệ HOT = f(fillfactor, cột nào bị update, cột nào được index).** `fillfactor` là điều kiện **cần**; "không đụng cột được index" là điều kiện **đủ**.

---

## Bảng số liệu chính

| Kịch bản | tỷ lệ HOT | time | Kích thước |
|---|---|---|---|
| ff100, cột không index | **0,000** | 1.388,5 ms | 37 → 74 MB |
| ff100, cột có index | 0,000 | 1.765,1 ms | 74 → 107 MB |
| **ff100, 5 vòng UPDATE** | **0,000** | ~1.250 ms/vòng | 31 → **170 MB** |
| **ff70, 5 vòng UPDATE** | **0,722** | **~450–500 ms/vòng (2,6×)** | 43 → **93 MB** |
| — ban đầu ff70 to hơn | | | **+39 %** |
| — sau 5 vòng ff70 nhỏ hơn | | | **−45 %** |
| **m2** ff70 + cột không index | **0,447** ✅ | **1.163,0 ms** | |
| m4 ff70 + cột có index | 0,000 | 1.242,6 ms | |
| m1 ff100 + cột không index | 0,000 | 1.484,1 ms | |
| m3 ff100 + cột có index | 0,000 | 1.414,6 ms | |
| **WAL: m1 (không HOT)** | | | **107 MB, 805.464 record, 4.187 FPI** |
| **WAL: m2 (44,7 % HOT)** | | | **91 MB, 535.941 record (−33 %), 5.814 FPI** |
| HOT chain (`t_hot`) | 1,000 | | 4 slot, `t_ctid` chuỗi trong **cùng page 0** |

---

## Ba điều dễ hiểu sai

| # | Hiểu nhầm | Sự thật đo được |
|---|---|---|
| 1 | "Update cột không được index thì được HOT" | Với `fillfactor = 100`: **0 % HOT**. Cần **cả hai** điều kiện, và điều kiện "page còn chỗ" mới là cái hay thiếu |
| 2 | "`fillfactor = 70` làm bảng to hơn 43 % — không đáng" | To hơn 39 % lúc đầu, **nhỏ hơn 45 % sau 5 vòng UPDATE**, và update nhanh hơn **2,6 lần** |
| 3 | "So `wal_bytes` là cách đo chi phí ghi chính xác" | `wal_fpi` phụ thuộc **thời điểm so với checkpoint**. m4 có `wal_fpi = 0` chỉ vì chạy cuối. So `wal_records` mới công bằng |

Thêm hai điều:
- **Page pruning dọn HOT chain mà không cần VACUUM và không đụng index** — đó là lợi ích lớn nhất của HOT, lớn hơn cả việc tiết kiệm entry index.
- **`fillfactor` chỉ áp cho page MỚI.** Không có `VACUUM FULL`/`pg_repack` sau khi `ALTER TABLE` thì cấu hình vô tác dụng.

---

## Áp dụng vào hệ thật

**1. Chạy query này trên production — tìm bảng có tỷ lệ HOT thấp:**

```sql
SELECT s.relname,
       s.n_tup_upd, s.n_tup_hot_upd,
       round(100.0 * s.n_tup_hot_upd / NULLIF(s.n_tup_upd,0), 1) AS pct_hot,
       (SELECT count(*) FROM pg_index WHERE indrelid = s.relid)  AS so_index,
       coalesce((SELECT option_value FROM pg_options_to_table(c.reloptions)
                 WHERE option_name = 'fillfactor'), '100')       AS fillfactor,
       pg_size_pretty(pg_relation_size(s.relid))                 AS size
FROM pg_stat_user_tables s JOIN pg_class c ON c.oid = s.relid
WHERE s.n_tup_upd > 100000
ORDER BY pct_hot NULLS FIRST;
```

**`pct_hot < 50` trên bảng có `n_tup_upd` lớn = cơ hội cải thiện rõ ràng.**

**2. Với mỗi bảng đó, trả lời 3 câu rồi hành động:**

```
① fillfactor đang là bao nhiêu?  -> nếu 100 và bảng bị update nhiều: đặt 70-85
② Cột nào bị update thường xuyên? -> xem log_statement='mod' hoặc code
③ Cột đó có index không?          -> nếu có: cân nhắc bỏ index đó
```

Ví dụ cho hệ IoT:
```sql
-- device_state: cập nhật last_seen mỗi phút
ALTER TABLE device_state SET (fillfactor = 70);
VACUUM FULL device_state;    -- hoặc pg_repack trên production
-- và BỎ index trên last_seen nếu có — nó phá HOT của mọi update
```

**3. Bảng append-only thì GIỮ `fillfactor = 100`.** `ts_kv`, log, event — chừa chỗ chỉ tổ lãng phí 30 % dung lượng mà không bao giờ dùng tới.

**4. Kiểm tra ORM — điểm chí mạng.**

Hibernate mặc định `UPDATE` **mọi cột** của entity. Chỉ cần entity có **một** cột được index là **mọi update đều mất HOT**, dù logic nghiệp vụ chỉ đổi `last_seen`.

```java
@Entity
@DynamicUpdate          // <- chỉ sinh SQL cho cột THẬT SỰ đổi
public class DeviceState { ... }
```

Kiểm chứng: bật `log_statement = 'mod'` vài phút, xem SQL thật.

**5. Sau khi áp `fillfactor`, đo lại sau một ngày:**
```sql
SELECT relname, round(100.0*n_tup_hot_upd/NULLIF(n_tup_upd,0),1) AS pct_hot
FROM pg_stat_user_tables WHERE relname = 'device_state';
```
Mục tiêu: **> 70 %**. Nếu vẫn thấp, kiểm tra lại điều kiện ① (có index nào trên cột đang bị update không).

**6. Lợi ích dây chuyền:** HOT cao → index không bloat → VACUUM nhanh hơn → autovacuum đuổi kịp (Day 23) → index-only scan hoạt động (Day 08). Đây là một trong ít thay đổi cải thiện **mọi** tầng cùng lúc.

---

## Câu hỏi mở sang các ngày sau

1. `wal_fpi` phụ thuộc checkpoint — `full_page_writes` và `max_wal_size` ảnh hưởng thế nào? → **Day 37**
2. HOT giảm 33 % WAL record — với replica, điều đó giảm lag bao nhiêu? → **Day 38**
3. `age(relfrozenxid)` và freeze — HOT có ảnh hưởng tới nó không? → **Day 25**
4. `fillfactor` cho index (mặc định 90) — đặt bao nhiêu cho index bị insert ngẫu nhiên? → **Day 06 §5**, và Day 43 khi rebuild
5. Bảng trạng thái nên tách khỏi bảng chính không? → **Day 41** (TOAST), **Day 44** (expand/contract)
