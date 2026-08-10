# Day 21 — Lời giải: MVCC tận mắt — xmin, xmax, ctid

> Bài chữa. Đo thật trên lab `SCALE=1`, dùng `pageinspect` để nhìn thẳng vào byte trên đĩa.

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án |
|---|---|---|
| 1 | `UPDATE` 3 lần thì dòng chiếm bao nhiêu chỗ? | **4 slot** (1 gốc + 3 phiên bản), tức **gấp 4 lần** |
| 2 | `DELETE` xong dòng biến mất khỏi page ngay không? | **KHÔNG.** Nó vẫn nằm nguyên slot, chỉ được gắn `xmax` |
| 3 | `ROLLBACK` có dọn dẹp không? | **KHÔNG.** Bảng phình từ 8 kB lên **512 kB** sau một ROLLBACK |

---

## §1. Mỗi dòng có nhiều phiên bản

```
 ctid  | xmin | xmax | id | v
-------+------+------+----+----
 (0,1) | 1776 |    0 |  1 | v1
 (0,2) | 1776 |    0 |  2 | v2
 (0,3) | 1776 |    0 |  3 | v3
 (0,4) | 1776 |    0 |  4 | v4
 (0,5) | 1776 |    0 |  5 | v5
```

**Cả 5 dòng có `xmin = 1776` giống hệt nhau** — vì chúng được tạo bởi **cùng một transaction** (`INSERT ... generate_series` là một lệnh, một transaction ngầm).

**`xmax = 0` ở mọi dòng** = chưa transaction nào xoá/thay thế chúng → còn sống.

`ctid = (page, slot)` — cả 5 dòng nằm trên page 0, slot 1–5.

### Bốn cột ẩn — có thể `SELECT` trực tiếp

| Cột | Nghĩa |
|---|---|
| `xmin` | ID transaction **tạo** phiên bản này |
| `xmax` | ID transaction **xoá/thay thế** nó (0 = còn sống) |
| `ctid` | địa chỉ vật lý `(page, offset)` — **thay đổi mỗi lần UPDATE** |
| `cmin`/`cmax` | thứ tự lệnh trong cùng transaction |

Chúng là cột thật, chỉ ẩn khỏi `SELECT *`.

### Quy tắc hiển thị (đơn giản hoá)

```
Một tuple hiện hữu với transaction của tôi nếu:
    xmin đã COMMIT  VÀ  xmin ≤ snapshot của tôi
VÀ  (xmax = 0  HOẶC  xmax chưa commit  HOẶC  xmax > snapshot của tôi)
```

**Lợi ích lớn của thiết kế này: đọc không bao giờ chặn ghi, ghi không bao giờ chặn đọc.** Cái giá: dòng chết tích tụ (§2–§4), cần VACUUM dọn (Day 22).

---

## §2. `UPDATE` = DELETE + INSERT

Sau `UPDATE ... WHERE id = 1` lần đầu:
```
 ctid  | xmin | xmax | id |     v
-------+------+------+----+-----------
 (0,6) | 1778 |    0 |  1 | updated-1     <- ctid đổi từ (0,1) sang (0,6)!
 (0,2) | 1776 |    0 |  2 | v2
```

**`ctid` của dòng `id=1` nhảy từ `(0,1)` sang `(0,6)`** — nó là một **tuple mới ở slot mới**, không phải bản cũ được sửa.

### Nhìn xuống tầng page sau 3 lần UPDATE

```
 slot | lp_off | t_xmin | t_xmax | t_ctid | trạng thái
------+--------+--------+--------+--------+------------
    1 |   8160 |   1776 |   1778 | (0,6)  | normal      <- v1        CHẾT (xmax=1778)
    2 |   8128 |   1776 |      0 | (0,2)  | normal      <- v2        sống
    3 |   8096 |   1776 |      0 | (0,3)  | normal      <- v3        sống
    4 |   8064 |   1776 |      0 | (0,4)  | normal      <- v4        sống
    5 |   8032 |   1776 |      0 | (0,5)  | normal      <- v5        sống
    6 |   7992 |   1778 |   1779 | (0,7)  | normal      <- updated-1 CHẾT
    7 |   7952 |   1779 |   1780 | (0,8)  | normal      <- updated-2 CHẾT
    8 |   7912 |   1780 |      0 | (0,8)  | normal      <- updated-3 SỐNG
```

### Mô tả bằng chữ một page sau 3 lần UPDATE cùng một dòng

> Page 0 có **8 slot** cho một bảng chỉ chứa **5 dòng logic**.
>
> Dòng `id=1` chiếm **4 slot** (1, 6, 7, 8) — mỗi lần `UPDATE` thêm một slot mới ở cuối vùng dữ liệu, và slot cũ được gắn `t_xmax` = XID của transaction đã thay thế nó.
>
> Bốn slot đó tạo thành một **chuỗi liên kết**: slot 1 → `t_ctid=(0,6)`, slot 6 → `(0,7)`, slot 7 → `(0,8)`, slot 8 → `(0,8)` (trỏ về chính nó = phiên bản mới nhất). Đây là **update chain** — Postgres đi theo chuỗi này để tìm phiên bản hiện hành.
>
> **Ba slot là rác** (`t_xmax` ≠ 0), chiếm chỗ cho tới khi VACUUM dọn.
>
> `lp_off` giảm dần (8160 → 7912): dữ liệu mọc **từ dưới lên**, còn mảng con trỏ `ItemId` mọc **từ trên xuống** — đúng cấu trúc page ở Day 06 §2.

**Tỷ lệ lãng phí: 3 slot chết / 4 slot của dòng đó = 75 %.** Và nếu bảng có index, mỗi phiên bản mới còn thêm một entry index (§7).

---

## §3. `DELETE` chỉ đánh dấu

Sau `DELETE FROM t_mvcc WHERE id = 5`:

```sql
SELECT ctid, xmin, xmax, * FROM t_mvcc;   -- chỉ còn 4 dòng
```
```
 lp | t_xmin | t_xmax | t_ctid
----+--------+--------+--------
  5 |   1776 |   1781 | (0,5)     <- id=5 VẪN Ở ĐÓ, chỉ thêm t_xmax
```

| | |
|---|---|
| Dòng `id=5` còn trong page không? | **CÒN NGUYÊN**, slot 5 |
| `xmax` của nó | **1781** (XID của transaction đã xoá) |
| Kích thước bảng | **8.192 byte — không giảm một byte nào** |

**`DELETE` không xoá gì cả.** Nó chỉ ghi `xmax` để các snapshot mới không thấy nữa.

> **Hệ quả vận hành: `DELETE FROM t WHERE ...` không bao giờ trả lại dung lượng cho hệ điều hành.** Bảng chỉ nhỏ lại sau `VACUUM FULL` hoặc `pg_repack` — và đó là lý do `DROP PARTITION` mạnh hơn `DELETE` rất nhiều (Day 33).

---

## §4. `ROLLBACK` để lại rác

| | |
|---|---|
| Kích thước **trước** | **8.192 byte (8 kB)** |
| Trong transaction, `count(*)` | **9.905** |
| Sau `ROLLBACK`, `count(*)` | **4** ✓ |
| **Kích thước sau ROLLBACK** | **512 kB** — **phình 64 lần** |

**Chèn 9.901 dòng rồi rollback: dữ liệu biến mất, dung lượng thì không.**

### Vì sao rollback không dọn

Rollback trong Postgres **rất rẻ**: nó chỉ ghi một bit vào commit log (`pg_xact`) rằng transaction đó abort. **Không hoàn tác gì cả.**

Mọi tuple transaction đó đã ghi vẫn nằm trên đĩa với `xmin` = XID đã abort → mọi snapshot đều bỏ qua chúng → chúng là **rác chờ VACUUM**.

Đây là đánh đổi ngược với InnoDB: InnoDB rollback đắt (phải đọc undo log và hoàn tác) nhưng không để lại rác trong bảng chính.

### ⚠️ Chi tiết đáng chú ý: `n_dead_tup = 0`

```
 n_live_tup | n_dead_tup
------------+------------
          0 |          0
```

**Bộ đếm thống kê KHÔNG thấy 9.901 dòng rác đó.**

Vì stats collector chỉ cộng dồn theo **transaction đã commit**. Transaction abort không báo cáo gì.

> **Đây là bẫy monitoring rất nguy hiểm: dashboard theo dõi `n_dead_tup` sẽ KHÔNG phát hiện bloat do rollback.** Bảng phình 64 lần mà mọi chỉ số đều xanh.
>
> Muốn thấy, phải dùng `pgstattuple` (đắt) hoặc so `pg_relation_size` với `n_live_tup × avg_width`.

### 🔧 Tình huống thực tế

**Job insert 10 triệu dòng, gặp lỗi ở dòng 9,9 triệu, rollback. Retry 3 lần rồi mới thành công.**

```
Kết quả: bảng chứa 10 triệu dòng hữu ích + 30 triệu dòng rác
         -> phình gấp 4 lần
         -> n_dead_tup vẫn báo 0
         -> autovacuum KHÔNG kích hoạt (nó dựa vào n_dead_tup)
```

Đây là cách bloat tích tụ âm thầm nhất. Cách phòng:
1. **Chia nhỏ batch** — commit mỗi 10.000–50.000 dòng thay vì một transaction khổng lồ
2. **`VACUUM` thủ công sau mỗi lần job thất bại**
3. Với bảng staging: dùng `TRUNCATE` (trả dung lượng ngay) thay vì `DELETE`

---

## §5. Snapshot — vì sao hai session thấy khác nhau

### Thí nghiệm hai session

| Thời điểm | **S1** (đang mở transaction) | **S2** (session khác) |
|---|---|---|
| S1 `BEGIN`, `INSERT (999, ...)` | `count(*)` = **6** | `count(*)` = **5** |
| S1 chưa `COMMIT` | | `SELECT ... WHERE id=999` → **0 dòng** |
| S1 `COMMIT` | `count(*)` = 6 | `count(*)` = **6** |

### 💡 Nhưng dòng 999 CÓ nằm vật lý trên đĩa

S2 đọc trực tiếp page (bỏ qua tầng visibility):

```sql
SELECT lp, t_xmin, t_xmax, t_ctid FROM heap_page_items(get_raw_page('t_mvcc', 0));
```
```
 lp | t_xmin | t_xmax | t_ctid
----+--------+--------+--------
  1 |   1798 |      0 | (0,1)
  ...
  6 |   1799 |      0 | (0,6)     <- DÒNG 999, xmin=1799 = XID của S1
```

**Slot 6 đã tồn tại, dữ liệu đã ghi ra page, trước khi S1 commit.**

S2 không thấy nó không phải vì nó chưa được ghi, mà vì **snapshot của S2 loại nó ra**: `xmin = 1799` là transaction **đang chạy** tại thời điểm S2 chụp snapshot → không hiện.

> **Đây là toàn bộ cơ chế isolation của Postgres: dữ liệu luôn được ghi ngay, còn "ai thấy gì" là do so sánh `xmin`/`xmax` với snapshot.** Tuần 6 đào sâu.

Điểm quan trọng về hiệu năng: vì dữ liệu chưa commit **vẫn chiếm chỗ trên đĩa**, một transaction dài ghi nhiều sẽ làm bảng phình ngay lập tức, kể cả khi nó sẽ rollback.

---

## §6. Transaction ID và `age`

```
 relname | tuổi | relfrozenxid
---------+------+--------------
 t_mvcc  |    9 |         1775
 device  |  516 |         1268
 ts_kv   |  514 |         1270
 alarm   |  513 |         1271

 autovacuum_freeze_max_age = 200.000.000
```

| | |
|---|---|
| `age(relfrozenxid)` lớn nhất | **516** |
| Ngưỡng `autovacuum_freeze_max_age` | **200.000.000** |
| **Đã dùng** | **0,00026 %** |

Lab hoàn toàn an toàn — nó mới chạy vài nghìn transaction.

XID là số nguyên **32 bit** → chỉ ~4,2 tỷ giá trị rồi quay vòng. Postgres xử lý bằng so sánh modulo: mỗi transaction "nhìn thấy" 2 tỷ XID phía trước là **tương lai**, 2 tỷ phía sau là **quá khứ**.

Nếu `age(relfrozenxid)` vượt 2 tỷ, các dòng cũ đột nhiên trở thành "tương lai" → **dữ liệu biến mất**. Postgres ngăn điều đó bằng cách **dừng nhận ghi** khi đến gần ngưỡng. Day 25 làm bài này.

Cách ước lượng cho hệ thật:
```
tốc độ tiêu XID = số transaction/giây
thời gian tới ngưỡng = 200.000.000 / (transaction mỗi giây × 86400) ngày
```
Với 1.000 tps: `200.000.000 / 86.400.000 = 2,3 ngày` → autovacuum aggressive sẽ chạy mỗi ~2 ngày. Với 10.000 tps: **mỗi 5,5 giờ**.

---

## §7. Chi phí thật của MVCC — số liệu gây sốc nhất bài

```sql
UPDATE t_upd SET c = c;    -- gán giá trị Y HỆT giá trị cũ
```

| | Trước | **Sau** | Tăng |
|---|---|---|---|
| **Tổng** | **31 MB** | **61 MB** | **+97 %** |
| heap | 18 MB | **36 MB** | **+100 %** |
| index | 13 MB | **26 MB** | **+100 %** |
| `n_live_tup` | 200.000 | **400.000** | |
| `n_dead_tup` | 0 | **200.000** | |
| `n_tup_hot_upd` | — | **0** | **0 % HOT** |

### **`SET c = c` — gán giá trị y hệt — vẫn làm bảng và index phình gấp đôi.**

Postgres **không so sánh giá trị cũ với giá trị mới**. Lệnh `UPDATE` chạm tới dòng nào thì dòng đó được viết lại, chấm hết.

Và **cả hai index cũng phình gấp đôi** (13 → 26 MB) — dù `a` và `b` không hề bị đổi. Vì tuple mới có `ctid` mới → mọi index phải thêm entry trỏ tới địa chỉ mới.

### `n_tup_hot_upd = 0` — vì sao không có HOT update nào

Thử lại với `UPDATE t_upd SET c = 'y'` (cột `c` không được index):
```
 n_tup_upd | n_tup_hot_upd | pct_hot
-----------+---------------+---------
    200000 |             1 |     0.0
```

**Chỉ 1 trên 200.000 là HOT update.** Điều kiện HOT là: không đụng cột được index **VÀ còn chỗ trống trong cùng page**. Bảng vừa `INSERT` xong với `fillfactor = 100` → page đầy khít → không còn chỗ → mọi update phải sang page mới.

Day 24 sẽ dùng `fillfactor = 70` để đảo ngược con số này.

### 🔧 Hệ quả cho ORM — điều quan trọng nhất hôm nay

Hầu hết ORM mặc định sinh `UPDATE` **toàn bộ cột**:

```sql
-- Hibernate mặc định, khi bạn chỉ đổi một trường:
UPDATE device SET uuid=?, tenant_id=?, name=?, type=?, region=?, country=?,
                  firmware=?, is_active=?, created_at=?, meta=?
WHERE id=?;
```

Hậu quả đo được:
- Bảng phình **gấp đôi** mỗi vòng update toàn bộ
- **Mọi index** phình gấp đôi, kể cả index trên cột không đổi
- **Phá HOT update** — vì `UPDATE` chạm cột được index (`name`, `type`... đều có index trong hệ thật)
- WAL sinh ra gấp nhiều lần (Day 10: mỗi index = +78 byte WAL/dòng)

**Cách bật dynamic update:**

| ORM | Cấu hình |
|---|---|
| **Hibernate/JPA** | `@DynamicUpdate` trên entity — chỉ sinh SQL cho cột **thật sự đổi** |
| **Spring Data JPA** | dùng `@DynamicUpdate`, hoặc viết `@Modifying @Query` thủ công |
| **GORM (Go)** | `db.Model(&x).Updates(map[string]interface{}{"c": v})` thay vì `db.Save(&x)` |
| **Ecto, ActiveRecord** | mặc định đã chỉ update cột đổi ✅ |

**Ước lượng thiệt hại cho một hệ thật:**
```
Bảng device_state 50.000 dòng, mỗi device báo trạng thái mỗi phút:
  50.000 × 60 × 24 = 72.000.000 UPDATE/ngày

Với @DynamicUpdate (chỉ đổi last_seen, không index):
  -> phần lớn là HOT update (nếu có fillfactor) -> index không đổi

Không có @DynamicUpdate (update cả 10 cột, trong đó có cột được index):
  -> 72 triệu dead tuple/ngày trong heap
  -> 72 triệu entry rác × số index
  -> autovacuum phải dọn liên tục, và nó sẽ tụt hậu
```

---

## Bảng số liệu chính

| Kịch bản | Kết quả |
|---|---|
| 5 dòng INSERT một lệnh | cùng `xmin = 1776`, `xmax = 0` |
| Sau 3 `UPDATE` cùng dòng | page có **8 slot** cho **5 dòng logic**; dòng `id=1` chiếm **4 slot** (3 chết) |
| `DELETE` 1 dòng | dòng **vẫn ở slot 5**, `t_xmax = 1781`, kích thước bảng **không đổi** |
| `ROLLBACK` 9.901 dòng | `count(*)` = 4 ✓ nhưng bảng **8 kB → 512 kB (64×)** |
| — `n_dead_tup` sau rollback | **0** ⚠️ (monitoring không thấy) |
| Snapshot: S1 vs S2 | S1 thấy **6**, S2 thấy **5**, dòng **đã nằm vật lý** ở slot 6 |
| `age(relfrozenxid)` lớn nhất | **516** / ngưỡng 200.000.000 = **0,00026 %** |
| **`UPDATE SET c = c`** (giá trị y hệt) | tổng **31 → 61 MB**, heap **18 → 36 MB**, index **13 → 26 MB** |
| `n_tup_hot_upd` | **0 / 200.000** (fillfactor 100, page đầy) |
| `UPDATE SET c = 'y'` (cột không index) | **1 / 200.000** HOT — vẫn gần 0 |

---

## Ba điều dễ hiểu sai

| # | Hiểu nhầm | Sự thật đo được |
|---|---|---|
| 1 | "`ROLLBACK` thì không có gì được ghi" | Bảng phình **64 lần** sau rollback, và **`n_dead_tup` vẫn báo 0** — monitoring mù hoàn toàn |
| 2 | "`UPDATE SET x = x` (giá trị y hệt) thì Postgres bỏ qua" | Bảng và **mọi index** phình **gấp đôi**. Postgres không so sánh giá trị |
| 3 | "Index không chứa cột bị đổi thì không bị ảnh hưởng" | Cả 2 index phình **13 → 26 MB** dù `a`, `b` không đổi — vì `ctid` mới |

Thêm hai điều:
- **Dữ liệu chưa commit đã nằm vật lý trên đĩa.** Snapshot chỉ quyết định "ai thấy gì", không quyết định "cái gì được ghi".
- **`DELETE` không trả lại một byte nào.** Chỉ `VACUUM FULL` / `pg_repack` / `DROP PARTITION` mới trả.

---

## Áp dụng vào hệ thật

**1. Kiểm tra ORM có bật dynamic update chưa — việc đáng làm nhất hôm nay.**

Bật `log_statement = 'mod'` hoặc `log_min_duration_statement = 0` trong vài phút, rồi xem SQL thật:
```
UPDATE device SET uuid=$1, tenant_id=$2, name=$3, ... WHERE id=$10   <- CẢ 10 cột = có vấn đề
UPDATE device SET last_seen=$1 WHERE id=$2                            <- đúng
```

Với Hibernate: thêm `@DynamicUpdate` vào entity bị update nhiều nhất. Đo lại `n_tup_upd` / `n_tup_hot_upd` sau một ngày.

**2. Phát hiện bloat do ROLLBACK — cái mà `n_dead_tup` không thấy:**

```sql
-- so kích thước thật với kích thước "đáng lẽ"
SELECT c.relname,
       pg_size_pretty(pg_relation_size(c.oid)) AS thuc_te,
       pg_size_pretty((s.n_live_tup * (SELECT sum(avg_width) FROM pg_stats
                                       WHERE tablename = c.relname))::bigint) AS uoc_tinh_toi_thieu,
       s.n_live_tup, s.n_dead_tup
FROM pg_stat_user_tables s JOIN pg_class c ON c.oid = s.relid
WHERE pg_relation_size(c.oid) > 100*1024*1024
ORDER BY pg_relation_size(c.oid) DESC;
```
Thực tế >> ước tính mà `n_dead_tup` thấp = **nghi ngờ bloat do rollback hoặc transaction dài**.

**3. Chia nhỏ batch trong job nạp dữ liệu.** Một transaction 10 triệu dòng rollback = 10 triệu dòng rác vô hình. Commit mỗi 10.000–50.000 dòng.

**4. Với bảng staging, dùng `TRUNCATE` thay vì `DELETE`.** `TRUNCATE` trả dung lượng ngay lập tức; `DELETE` không trả gì.

**5. Theo dõi `age(relfrozenxid)` — thêm vào dashboard:**
```sql
SELECT c.relname, age(c.relfrozenxid) AS tuoi,
       round(100.0 * age(c.relfrozenxid) /
             current_setting('autovacuum_freeze_max_age')::bigint, 1) AS pct_nguong
FROM pg_class c
WHERE c.relkind = 'r' AND c.relnamespace = 'public'::regnamespace
ORDER BY age(c.relfrozenxid) DESC LIMIT 20;
```
**Cảnh báo ở 50 %, báo động ở 80 %.** Day 25.

**6. Khi debug một dòng "biến mất bí ẩn", đọc `xmin`/`xmax`:**
```sql
SELECT ctid, xmin, xmax, cmin, cmax, * FROM t WHERE id = ?;
-- xmax ≠ 0 -> đã bị xoá/thay thế bởi transaction xmax
SELECT txid_status(xmax::text::bigint);   -- 'committed' / 'aborted' / 'in progress'
```

---

## Câu hỏi mở sang các ngày sau

1. 3 slot chết trên 8 slot — VACUUM dọn được bao nhiêu, và bao giờ nó chạy? → **Day 22**
2. Autovacuum dựa vào `n_dead_tup` — mà rollback không cập nhật chỉ số đó. Ngưỡng nào là đúng? → **Day 23**
3. `n_tup_hot_upd = 0` vì fillfactor 100. Đặt 70 thì tỷ lệ HOT lên bao nhiêu? → **Day 24**
4. `age(relfrozenxid)` mới 516 — với 10.000 tps thì bao lâu tới 200 triệu? → **Day 25**
5. Snapshot quyết định "ai thấy gì" — hai session cùng UPDATE một dòng thì sao? → **Day 26, Day 27**
