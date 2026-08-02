# Day 21 — MVCC tận mắt: xmin, xmax, ctid

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

```sql
\timing on
\o /days/day-21/output.txt
```

---

## §0. Đoán trước

1. `UPDATE` một dòng làm nó chiếm bao nhiêu chỗ trên đĩa sau 3 lần update?
2. `DELETE` xong thì dòng biến mất khỏi page ngay không?
3. `ROLLBACK` có dọn dẹp dòng đã ghi không?

---

## §1. Mỗi dòng có nhiều phiên bản

### Lý thuyết

Postgres **không sửa dòng tại chỗ**. Mỗi `UPDATE` tạo một **phiên bản mới** của dòng và đánh dấu phiên bản cũ là hết hiệu lực. Đây là MVCC — Multi-Version Concurrency Control.

Mỗi phiên bản dòng (gọi là **tuple**) có header ẩn:

| Cột ẩn | Nghĩa |
|---|---|
| `xmin` | ID transaction **tạo** ra phiên bản này |
| `xmax` | ID transaction **xoá/thay thế** nó (0 nếu còn sống) |
| `ctid` | địa chỉ vật lý `(page, offset)` |
| `cmin`/`cmax` | thứ tự lệnh trong cùng transaction |

Bạn `SELECT` được chúng trực tiếp — chúng là cột thật, chỉ ẩn khỏi `SELECT *`.

Quy tắc hiển thị (đơn giản hoá): một tuple hiện hữu với transaction hiện tại nếu
```
xmin đã commit VÀ xmin ≤ snapshot của tôi
VÀ (xmax = 0 HOẶC xmax chưa commit HOẶC xmax > snapshot của tôi)
```

Lợi ích lớn của thiết kế này: **đọc không bao giờ chặn ghi, ghi không bao giờ chặn đọc.** Cái giá: dòng chết tích tụ, cần VACUUM dọn (Day 22).

### Làm ngay

```sql
CREATE TABLE t_mvcc (id int PRIMARY KEY, v text);
INSERT INTO t_mvcc SELECT g, 'v'||g FROM generate_series(1,5) g;

SELECT ctid, xmin, xmax, * FROM t_mvcc ORDER BY id;
SELECT txid_current();
```

**Ghi vào writeup:** `xmin` của 5 dòng có giống nhau không, vì sao? `xmax` bằng bao nhiêu?

---

## §2. `UPDATE` = DELETE + INSERT

### Làm ngay

```sql
UPDATE t_mvcc SET v = 'updated-1' WHERE id = 1;
SELECT ctid, xmin, xmax, * FROM t_mvcc ORDER BY id;
```

Chú ý `ctid` của dòng id=1 — nó đã đổi. Dòng cũ vẫn nằm đó, chỉ là bạn không thấy.

```sql
UPDATE t_mvcc SET v = 'updated-2' WHERE id = 1;
UPDATE t_mvcc SET v = 'updated-3' WHERE id = 1;
SELECT ctid, xmin, xmax, * FROM t_mvcc WHERE id = 1;
```

Giờ nhìn xuống tầng page — thấy cả các phiên bản chết:

```sql
SELECT lp AS slot, lp_off, t_xmin, t_xmax, t_ctid,
       CASE lp_flags WHEN 0 THEN 'unused' WHEN 1 THEN 'normal'
                     WHEN 2 THEN 'redirect' WHEN 3 THEN 'dead' END AS trang_thai
FROM heap_page_items(get_raw_page('t_mvcc', 0));
```

**Ghi vào writeup:** page 0 có bao nhiêu slot? Dòng `id=1` chiếm mấy slot sau 3 lần update? Mô tả bằng chữ một page sau 3 lần UPDATE cùng một dòng.

---

## §3. `DELETE` chỉ đánh dấu

### Làm ngay

```sql
DELETE FROM t_mvcc WHERE id = 5;
SELECT ctid, xmin, xmax, * FROM t_mvcc ORDER BY id;

SELECT lp, t_xmin, t_xmax, t_ctid FROM heap_page_items(get_raw_page('t_mvcc', 0));
SELECT pg_size_pretty(pg_relation_size('t_mvcc'));
```

**Ghi vào writeup:** dòng id=5 còn trong page không? `xmax` của nó bằng bao nhiêu? Kích thước bảng có giảm không?

---

## §4. `ROLLBACK` để lại rác

### Lý thuyết

Rollback trong Postgres **rất rẻ** — nó chỉ ghi vào commit log rằng transaction đó abort. Không phải hoàn tác gì cả.

Đổi lại: mọi dòng transaction đó đã ghi **vẫn nằm trên đĩa**, chỉ là không ai thấy. Chúng là rác chờ VACUUM.

Hệ quả thực tế đáng nhớ: **một job insert 10 triệu dòng rồi rollback vẫn làm bảng phình 10 triệu dòng.** Retry vài lần là bảng phình gấp mấy lần dù cuối cùng chẳng có dữ liệu nào.

### Làm ngay

```sql
SELECT pg_size_pretty(pg_relation_size('t_mvcc')) AS truoc;

BEGIN;
INSERT INTO t_mvcc SELECT g, 'rollback-'||g FROM generate_series(100, 10000) g;
SELECT count(*) FROM t_mvcc;
ROLLBACK;

SELECT count(*) FROM t_mvcc;
SELECT pg_size_pretty(pg_relation_size('t_mvcc')) AS sau_rollback;
SELECT n_live_tup, n_dead_tup FROM pg_stat_user_tables WHERE relname='t_mvcc';
```

**Ghi vào writeup:** sau ROLLBACK, `count(*)` bằng bao nhiêu nhưng kích thước bảng bằng bao nhiêu? `n_dead_tup` bao nhiêu?

---

## §5. Snapshot — vì sao hai session thấy khác nhau

### Lý thuyết

Khi bắt đầu một câu lệnh (Read Committed) hoặc một transaction (Repeatable Read), Postgres chụp một **snapshot**: danh sách transaction nào đang chạy tại thời điểm đó.

```
snapshot = (xmin_snap, xmax_snap, [danh sách xip đang chạy])
```

Tuple do transaction đang-chạy tạo ra sẽ **không** hiện với snapshot đã chụp trước đó. Đây là toàn bộ cơ chế isolation — tuần 6 sẽ đào sâu.

### Làm ngay — cần 2 terminal

Terminal 1: `./db.sh s1` · Terminal 2: `./db.sh s2`

**S1:**
```sql
BEGIN;
SELECT txid_current();
INSERT INTO t_mvcc VALUES (999, 'chua-commit');
SELECT count(*) FROM t_mvcc;      -- S1 thấy bao nhiêu?
```

**S2 (khi S1 chưa commit):**
```sql
SELECT count(*) FROM t_mvcc;      -- S2 thấy bao nhiêu?
SELECT ctid, xmin, xmax, * FROM t_mvcc WHERE id = 999;   -- có thấy không?
SELECT * FROM pg_stat_activity WHERE state = 'idle in transaction';
```

**S1:**
```sql
COMMIT;
```

**S2:**
```sql
SELECT count(*) FROM t_mvcc;      -- giờ thấy chưa?
```

**Ghi vào writeup:** trước COMMIT, S1 và S2 thấy số dòng khác nhau thế nào? Dòng id=999 có nằm vật lý trên đĩa trước khi commit không (kiểm tra bằng `heap_page_items` từ S2)?

---

## §6. Transaction ID và `age`

### Lý thuyết

XID là số nguyên **32 bit** → chỉ có ~4,2 tỷ giá trị, rồi quay vòng. Postgres xử lý bằng cách so sánh theo modulo: mỗi transaction "nhìn thấy" 2 tỷ XID phía trước là tương lai, 2 tỷ phía sau là quá khứ.

`age(xid)` = số transaction đã trôi qua kể từ XID đó.

Điều này dẫn tới vấn đề **wraparound** — Day 25.

### Làm ngay

```sql
SELECT txid_current();
SELECT relname, age(relfrozenxid) AS tuoi, relfrozenxid
FROM pg_class WHERE relname IN ('t_mvcc','ts_kv','device','alarm');

SELECT datname, age(datfrozenxid) FROM pg_database ORDER BY 2 DESC;
```

**Ghi vào writeup:** `age(relfrozenxid)` của các bảng là bao nhiêu? Ngưỡng nguy hiểm mặc định là 200 triệu — bạn còn cách bao xa?

---

## §7. Chi phí thật của MVCC

### Lý thuyết

Đánh đổi so với các engine sửa-tại-chỗ (Oracle, MySQL/InnoDB dùng undo log):

| | Postgres (MVCC trong heap) | InnoDB (undo log) |
|---|---|---|
| Đọc dữ liệu cũ | miễn phí (đã nằm sẵn trong heap) | phải dựng lại từ undo log |
| Rollback | miễn phí | phải hoàn tác |
| `UPDATE` | tạo dòng mới, **cập nhật mọi index** | sửa tại chỗ, chỉ index bị đổi |
| Dọn rác | VACUUM (nền, có thể tụt hậu) | purge thread |
| Bảng phình | có, phải quản lý | ít hơn |
| `count(*)` | phải quét (không có counter chính xác) | InnoDB cũng vậy |

Điểm quan trọng nhất cho bạn: **`UPDATE` trong Postgres đắt hơn bạn tưởng**, vì nó phải cập nhật mọi index kể cả index không chứa cột bị đổi (trừ HOT update — Day 24).

### Làm ngay

```sql
CREATE TABLE t_upd (id int PRIMARY KEY, a int, b int, c text);
INSERT INTO t_upd SELECT g, g, g, repeat('x',50) FROM generate_series(1,200000) g;
CREATE INDEX ON t_upd(a);
CREATE INDEX ON t_upd(b);
VACUUM ANALYZE t_upd;

SELECT pg_size_pretty(pg_total_relation_size('t_upd')) AS truoc;
\timing on
UPDATE t_upd SET c = c;                     -- không đổi giá trị nhưng vẫn tạo dòng mới
SELECT pg_size_pretty(pg_total_relation_size('t_upd')) AS sau;
SELECT n_live_tup, n_dead_tup, n_tup_upd, n_tup_hot_upd
FROM pg_stat_user_tables WHERE relname='t_upd';
```

**Ghi vào writeup:** `UPDATE ... SET c = c` (giá trị y hệt!) vẫn làm bảng phình bao nhiêu? Điều này nói gì về pattern "cứ update cả row cho tiện" trong ORM?

### Dọn dẹp

```sql
DROP TABLE t_mvcc, t_upd;
```

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B. Áp dụng vào hệ thật:** ORM của bạn (Hibernate/JPA, GORM...) khi save một entity có update **toàn bộ cột** hay chỉ cột đã đổi? Nếu là toàn bộ, ước lượng bạn đang tạo bao nhiêu dòng chết thừa mỗi ngày. Cách bật dynamic update là gì?

### Đạt khi

Bạn nhìn được `xmin`/`xmax`/`ctid` của một dòng và kể lại lịch sử nó đã trải qua, và giải thích được vì sao `ROLLBACK` vẫn làm bảng phình.

**Xong thì gõ `/review-bai`.**
