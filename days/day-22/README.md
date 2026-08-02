# Day 22 — Dead tuple & bloat

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

```sql
\timing on
\o /days/day-22/output.txt
```

---

## §0. Đoán trước

1. Update 100% một bảng 5 lần liên tiếp (không vacuum) — bảng phình mấy lần?
2. `VACUUM` có trả dung lượng về cho hệ điều hành không?
3. `DELETE` 90% bảng rồi `VACUUM` — bảng có nhỏ lại không?

---

## §1. Dead tuple sinh ra và tích tụ

### Lý thuyết

Từ Day 21: `UPDATE` và `DELETE` để lại phiên bản cũ. Chúng là **dead tuple**.

Một dead tuple chỉ dọn được khi **không transaction nào còn có thể nhìn thấy nó** — tức là khi mọi snapshot đang mở đều mới hơn `xmax` của nó.

Đây là chỗ nguy hiểm nhất trong vận hành Postgres:

> **Một transaction mở lâu (kể cả chỉ đọc, kể cả `idle in transaction`) chặn VACUUM dọn dead tuple của TOÀN BỘ database.**

Kịch bản kinh điển: một connection từ ứng dụng `BEGIN` rồi quên `COMMIT` (bug retry, debug breakpoint, pool cấu hình sai). Sau vài giờ, bảng nóng phình gấp 10 lần, query chậm dần, đĩa đầy. Sửa bằng cách kill connection đó.

### Làm ngay

```sql
CREATE TABLE t_dead AS SELECT id, name, tenant_id, firmware, created_at FROM device;
ALTER TABLE t_dead SET (autovacuum_enabled = false);   -- tắt để quan sát rõ
VACUUM ANALYZE t_dead;

SELECT n_live_tup, n_dead_tup, pg_size_pretty(pg_relation_size('t_dead')) AS size
FROM pg_stat_user_tables WHERE relname='t_dead';
```

Update 5 vòng, đo sau mỗi vòng:
```sql
UPDATE t_dead SET firmware = firmware;
SELECT n_live_tup, n_dead_tup, pg_size_pretty(pg_relation_size('t_dead')) AS size
FROM pg_stat_user_tables WHERE relname='t_dead';
```
Lặp lệnh trên **5 lần**.

**Ghi vào writeup — bảng 6 dòng (vòng 0..5):** n_live_tup | n_dead_tup | kích thước. Bảng phình mấy lần sau 5 vòng?

---

## §2. Đo bloat chính xác bằng `pgstattuple`

### Lý thuyết

`n_dead_tup` trong `pg_stat_user_tables` là con số **thống kê xấp xỉ**, cập nhật bởi các process khi chúng chạm vào bảng. Nó có thể lệch.

`pgstattuple` **quét thật** và cho số chính xác:

| Trường | Nghĩa |
|---|---|
| `tuple_percent` | % không gian là dòng sống |
| `dead_tuple_percent` | % là dòng chết |
| `free_percent` | % là khoảng trống dùng lại được |

Bảng khoẻ: `dead_tuple_percent` dưới ~10%, `free_percent` dưới ~20%.

Có công thức ước lượng bloat "không cần quét" (dựa trên `pg_stats` và độ rộng cột) rất phổ biến trong monitoring, nhưng nó chỉ là xấp xỉ. Khi cần con số thật thì dùng `pgstattuple` (chấp nhận nó quét toàn bảng).

### Làm ngay

```sql
SELECT * FROM pgstattuple('t_dead');
SELECT * FROM pgstattuple_approx('t_dead');   -- nhanh hơn, xấp xỉ
```

**Ghi vào writeup:** `dead_tuple_percent` và `free_percent`. So `pgstattuple` với `pgstattuple_approx` — lệch bao nhiêu, cái nào chạy nhanh hơn?

---

## §3. `VACUUM` làm gì và **không** làm gì

### Lý thuyết

`VACUUM` thường (không FULL):

✓ Đánh dấu không gian của dead tuple là **dùng lại được** (ghi vào Free Space Map)
✓ Xoá entry tương ứng trong mọi index
✓ Cập nhật visibility map (bật `all-visible` — Day 08)
✓ Cập nhật `relfrozenxid` (freeze — Day 25)
✓ Chạy **song song với truy vấn bình thường**, chỉ chặn DDL

✗ **Không** trả dung lượng về cho hệ điều hành (trừ trường hợp các page trống nằm ở **cuối** file)
✗ **Không** gom các dòng lại cho chặt
✗ **Không** làm index nhỏ lại

Kết quả: sau `VACUUM`, file vẫn to nhưng bên trong có chỗ trống để ghi tiếp. Đây là hành vi **đúng và mong muốn** — bảng ở trạng thái ổn định (steady state) sẽ giữ nguyên kích thước, tái sử dụng chỗ trống.

Vấn đề chỉ xảy ra khi bảng phình lên **rồi không bao giờ dùng hết chỗ trống đó nữa** (ví dụ xoá 90% dữ liệu một lần).

### Làm ngay

```sql
SELECT pg_size_pretty(pg_relation_size('t_dead')) AS truoc_vacuum;
VACUUM (VERBOSE) t_dead;
SELECT pg_size_pretty(pg_relation_size('t_dead')) AS sau_vacuum;
SELECT * FROM pgstattuple('t_dead');
SELECT n_live_tup, n_dead_tup FROM pg_stat_user_tables WHERE relname='t_dead';
```

Đọc kỹ output `VERBOSE` — nó cho biết bao nhiêu tuple bị dọn, bao nhiêu page được xử lý.

Rồi kiểm chứng "chỗ trống được tái sử dụng":
```sql
UPDATE t_dead SET firmware = firmware;
SELECT pg_size_pretty(pg_relation_size('t_dead')) AS sau_update_tiep;
```

**Ghi vào writeup:** VACUUM có làm file nhỏ lại không? Sau khi VACUUM rồi update tiếp 1 vòng, bảng có phình thêm không — **vì sao**? Đây là ý quan trọng nhất hôm nay.

---

## §4. `VACUUM FULL` — và vì sao đừng chạy trên production

### Lý thuyết

`VACUUM FULL` **viết lại toàn bộ bảng** sang file mới, chỉ chép dòng sống, rồi đổi tên và xoá file cũ. Index cũng được build lại.

- ✓ Bảng gọn nhất có thể, dung lượng trả về OS
- ✗ Lấy **`ACCESS EXCLUSIVE` lock** — chặn cả `SELECT`, suốt thời gian chạy
- ✗ Cần chỗ trống bằng **kích thước bảng + index** (bản sao tồn tại song song)
- ✗ Với bảng 500GB có thể chạy hàng giờ

Thay thế trên production: **`pg_repack`** (extension). Nó làm việc tương tự nhưng chỉ khoá ngắn ở đầu và cuối, dùng trigger để bắt kịp thay đổi trong lúc chép. Đây là công cụ chuẩn cho việc "de-bloat không downtime".

### Làm ngay

```sql
SELECT pg_size_pretty(pg_total_relation_size('t_dead')) AS truoc;
\timing on
VACUUM FULL t_dead;
SELECT pg_size_pretty(pg_total_relation_size('t_dead')) AS sau;
SELECT * FROM pgstattuple('t_dead');
```

Quan sát lock (cần 2 session):

**S1:**
```sql
BEGIN;
LOCK TABLE t_dead IN ACCESS EXCLUSIVE MODE;   -- mô phỏng VACUUM FULL đang chạy
```
**S2:**
```sql
SELECT count(*) FROM t_dead;    -- bị chặn!
```
**S1:** `ROLLBACK;`

**Ghi vào writeup:** VACUUM FULL lấy lại được bao nhiêu %? Trong lúc chạy, một `SELECT` bình thường có chạy được không? Bạn sẽ dùng gì thay thế trên production?

---

## §5. Kịch bản DELETE hàng loạt

### Lý thuyết

Xoá 90% bảng bằng `DELETE` là ca xấu nhất:
- 90% bảng thành dead tuple → VACUUM đánh dấu free nhưng file không co
- Bạn còn 10% dữ liệu nằm rải rác trong một file to gấp 10
- Mọi Seq Scan vẫn phải đọc toàn bộ file → chậm gấp 10 mãi mãi

Ba cách xử lý đúng, tốt dần:
1. `DELETE` + `VACUUM FULL`/`pg_repack` — có downtime hoặc phức tạp
2. Tạo bảng mới với dữ liệu cần giữ, đổi tên — nhanh hơn nhiều, nhưng phải xử lý FK/index
3. **`PARTITION` rồi `DROP PARTITION`** — tức thời, không sinh dead tuple nào. Đây là lý do tồn tại của partitioning (Day 32-33)

### Làm ngay

```sql
CREATE TABLE t_del AS SELECT * FROM ts_kv LIMIT 1000000;
VACUUM ANALYZE t_del;
SELECT pg_size_pretty(pg_relation_size('t_del')) AS ban_dau;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM t_del;

DELETE FROM t_del WHERE device_id > 100;
SELECT count(*) FROM t_del;
SELECT pg_size_pretty(pg_relation_size('t_del')) AS sau_delete;

VACUUM t_del;
SELECT pg_size_pretty(pg_relation_size('t_del')) AS sau_vacuum;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM t_del;
```

**Ghi vào writeup:** còn bao nhiêu % dòng nhưng file vẫn to bao nhiêu? Sau VACUUM, `SELECT count(*)` đọc bao nhiêu buffer — **so với lúc bảng đầy đủ dữ liệu**?

---

## §6. Transaction dài — kẻ giết VACUUM

### Làm ngay — 2 session

**S2:**
```sql
BEGIN;
SELECT 1;                  -- mở snapshot rồi ngồi im
-- ĐỪNG commit
```

**S1:**
```sql
UPDATE t_dead SET firmware = firmware;
VACUUM (VERBOSE) t_dead;
SELECT n_dead_tup FROM pg_stat_user_tables WHERE relname='t_dead';
```

Đọc dòng `VERBOSE` — nó sẽ ghi kiểu `X dead row versions cannot be removed yet, oldest xmin: NNN`.

Tìm thủ phạm:
```sql
SELECT pid, state, now()-xact_start AS xact_age, now()-state_change AS idle_time,
       left(query, 60) AS query
FROM pg_stat_activity
WHERE state <> 'idle' OR state = 'idle in transaction'
ORDER BY xact_start;
```

**S2:** `COMMIT;`

**S1:**
```sql
VACUUM (VERBOSE) t_dead;
SELECT n_dead_tup FROM pg_stat_user_tables WHERE relname='t_dead';
```

**Ghi vào writeup:** VACUUM báo bao nhiêu dòng "cannot be removed yet"? Sau khi S2 commit thì sao? **Viết query monitoring** phát hiện transaction chạy quá 5 phút — thứ bạn sẽ mang về production.

---

## §7. Ngưỡng cảnh báo cho hệ thật

### Lý thuyết

| Chỉ số | Ngưỡng cảnh báo | Nguồn |
|---|---|---|
| `dead_tuple_percent` | > 20% | `pgstattuple` hoặc công thức xấp xỉ |
| `n_dead_tup` / `n_live_tup` | > 0.2 | `pg_stat_user_tables` |
| Transaction dài nhất | > 5 phút | `pg_stat_activity` |
| `idle in transaction` | > 1 phút | `pg_stat_activity` |
| Bảng chưa autovacuum | > 1 ngày (bảng nóng) | `last_autovacuum` |

Postgres còn có `idle_in_transaction_session_timeout` để tự kill — nên bật trên production (ví dụ 5 phút).

### Làm ngay

```sql
SHOW idle_in_transaction_session_timeout;

SELECT relname,
       n_live_tup, n_dead_tup,
       round(n_dead_tup::numeric / nullif(n_live_tup,0), 3) AS ty_le_chet,
       last_vacuum, last_autovacuum, last_analyze,
       pg_size_pretty(pg_relation_size(relid)) AS size
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC;
```

**Ghi vào writeup:** bảng nào tệ nhất trong lab? Viết một query monitoring duy nhất trả về mọi bảng vượt ngưỡng bạn chọn.

### Dọn dẹp

```sql
DROP TABLE t_dead, t_del;
```

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B. Áp dụng vào hệ thật:** chạy query ở §7 trên DB production của bạn. Bảng nào bloat nặng nhất, bao nhiêu GB đang lãng phí? Có transaction nào đang mở quá lâu không? `idle_in_transaction_session_timeout` đã bật chưa?

### Đạt khi

Bạn giải thích chính xác VACUUM lấy lại được gì và không lấy lại được gì, và biết ngay phải tìm ai khi dead tuple không được dọn.

**Xong thì gõ `/review-bai`.**
