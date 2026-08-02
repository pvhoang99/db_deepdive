# Day 10 — Cái giá của index: write amplification, bloat, REINDEX + ôn tuần

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

```sql
\timing on
\o /days/day-10/output.txt
```

---

## §0. Đoán trước

1. Insert 200k dòng vào bảng có 5 index chậm hơn bảng không index bao nhiêu lần?
2. Update ngẫu nhiên 30% bảng thì index phình lên bao nhiêu %?
3. `VACUUM` có làm index nhỏ lại không?

---

## §1. Mỗi index là một khoản thuế trên đường ghi

### Lý thuyết

Khi `INSERT` một dòng, Postgres phải:
1. Ghi dòng vào heap
2. **Với mỗi index**: tìm đúng page lá, chèn entry, có thể tách page
3. **Với mỗi thứ trên**: ghi WAL record

Nên chi phí ghi tăng gần **tuyến tính** theo số index. Bảng có 5 index thì mỗi INSERT là 6 lần ghi (1 heap + 5 index) cộng WAL cho cả 6.

Với `UPDATE` còn tệ hơn — trừ khi là HOT update (Day 24), mọi index đều phải cập nhật kể cả index không chứa cột bị đổi. Lý do: UPDATE tạo dòng mới ở vị trí vật lý mới → mọi TID trong mọi index đều phải trỏ lại.

Đây là lý do quy tắc "cứ thêm index cho chắc" rất tai hại trên bảng ghi nhiều. Với `ts_kv` nhận 50.000 dòng/giây, thêm một index là thêm 50.000 lần chèn B-tree mỗi giây.

### Làm ngay

```sql
CREATE TABLE t_idx0 (LIKE ts_kv);
CREATE TABLE t_idx1 (LIKE ts_kv);
CREATE TABLE t_idx3 (LIKE ts_kv);
CREATE TABLE t_idx5 (LIKE ts_kv);

CREATE INDEX ON t_idx1(device_id);

CREATE INDEX ON t_idx3(device_id);
CREATE INDEX ON t_idx3(ts);
CREATE INDEX ON t_idx3(key_id, ts);

CREATE INDEX ON t_idx5(device_id);
CREATE INDEX ON t_idx5(ts);
CREATE INDEX ON t_idx5(key_id, ts);
CREATE INDEX ON t_idx5(device_id, key_id, ts);
CREATE INDEX ON t_idx5(dbl_v);

-- đo từng cái, \timing đang bật
INSERT INTO t_idx0 SELECT * FROM ts_kv LIMIT 200000;
INSERT INTO t_idx1 SELECT * FROM ts_kv LIMIT 200000;
INSERT INTO t_idx3 SELECT * FROM ts_kv LIMIT 200000;
INSERT INTO t_idx5 SELECT * FROM ts_kv LIMIT 200000;
```

Đo cả WAL sinh ra:
```sql
SELECT pg_current_wal_lsn();   -- chạy trước và sau mỗi INSERT, lấy hiệu
```

**Ghi vào writeup — bảng 4 dòng:** số index | thời gian INSERT | tổng dung lượng (`pg_total_relation_size`) | throughput (dòng/giây). Vẽ xu hướng: thêm mỗi index làm chậm bao nhiêu %?

---

## §2. Bloat sinh ra thế nào

### Lý thuyết

Postgres không sửa dòng tại chỗ. `UPDATE` = ghi dòng mới + đánh dấu dòng cũ chết. Dòng chết vẫn chiếm chỗ tới khi VACUUM dọn.

Với **index**, chuyện còn dai hơn:
- Entry cũ trong index cũng thành rác
- VACUUM xoá được entry rác, nhưng **không gộp page lại**. Page nửa rỗng vẫn là page nửa rỗng.
- Kết quả: index phình ra và **không tự co lại**

Đây là lý do một index sau vài tháng production có thể to gấp 2-3 lần lúc mới build, dù số dòng không đổi.

### Làm ngay

```sql
CREATE TABLE t_bloat AS SELECT * FROM device;
CREATE INDEX idx_bloat_name ON t_bloat(name);
CREATE INDEX idx_bloat_tenant ON t_bloat(tenant_id, created_at);
ALTER TABLE t_bloat SET (autovacuum_enabled = false);   -- tắt để quan sát rõ

SELECT relname, pg_size_pretty(pg_relation_size(oid)) FROM pg_class
WHERE relname IN ('t_bloat','idx_bloat_name','idx_bloat_tenant');
```

Update nhiều vòng, đo sau mỗi vòng:
```sql
UPDATE t_bloat SET name = name || 'x' WHERE random() < 0.3;
SELECT relname, pg_size_pretty(pg_relation_size(oid)) FROM pg_class
WHERE relname IN ('t_bloat','idx_bloat_name','idx_bloat_tenant');
```
Lặp lệnh trên **5 lần**, ghi kích thước sau mỗi lần.

**Ghi vào writeup — bảng 6 dòng (vòng 0..5):** kích thước bảng | idx_bloat_name | idx_bloat_tenant. Index nào phình nhanh hơn, vì sao? (gợi ý: `name` bị đổi, `tenant_id` không.)

---

## §3. Đo bloat bằng `pgstattuple`

### Lý thuyết

| Hàm | Dùng cho | Cho biết |
|---|---|---|
| `pgstattuple('tbl')` | heap | `dead_tuple_percent`, `free_percent` |
| `pgstatindex('idx')` | B-tree | `avg_leaf_density`, `leaf_fragmentation` |
| `pgstattuple_approx('tbl')` | heap lớn | nhanh hơn, không quét toàn bộ |

`avg_leaf_density` là chỉ số quan trọng nhất cho index: index mới build có ~90%; xuống dưới ~60% là đáng REINDEX.

### Làm ngay

```sql
SELECT * FROM pgstatindex('idx_bloat_name');
SELECT * FROM pgstatindex('idx_bloat_tenant');
SELECT dead_tuple_percent, free_percent FROM pgstattuple('t_bloat');
```

**Ghi vào writeup:** `avg_leaf_density` và `leaf_fragmentation` của hai index. Cái nào tệ hơn?

---

## §4. VACUUM vs REINDEX — cái nào lấy lại được gì

### Lý thuyết

| | VACUUM | VACUUM FULL | REINDEX |
|---|---|---|---|
| Xoá dòng chết trong heap | ✓ | ✓ | – |
| Trả dung lượng heap về OS | ✗ | ✓ | – |
| Xoá entry rác trong index | ✓ | ✓ (build lại) | ✓ (build lại) |
| Gộp page index nửa rỗng | ✗ | ✓ | ✓ |
| Khoá | chỉ chặn DDL | **ACCESS EXCLUSIVE** | **ACCESS EXCLUSIVE** |
| Bản CONCURRENTLY | (mặc định không chặn) | không có | `REINDEX CONCURRENTLY` ✓ |

**Điều phải nhớ:** `VACUUM` thường **không** làm index nhỏ lại. Chỉ `REINDEX` mới build lại từ đầu.

`VACUUM FULL` viết lại toàn bộ bảng + index → gọn nhất, nhưng khoá `ACCESS EXCLUSIVE` (chặn cả SELECT) và cần chỗ trống bằng kích thước bảng. **Không chạy trên production giờ cao điểm.**

### Làm ngay

```sql
VACUUM t_bloat;
SELECT relname, pg_size_pretty(pg_relation_size(oid)) FROM pg_class
WHERE relname IN ('t_bloat','idx_bloat_name');
SELECT avg_leaf_density FROM pgstatindex('idx_bloat_name');

REINDEX INDEX idx_bloat_name;
SELECT relname, pg_size_pretty(pg_relation_size(oid)) FROM pg_class WHERE relname='idx_bloat_name';
SELECT avg_leaf_density FROM pgstatindex('idx_bloat_name');

VACUUM FULL t_bloat;
SELECT relname, pg_size_pretty(pg_relation_size(oid)) FROM pg_class
WHERE relname IN ('t_bloat','idx_bloat_name','idx_bloat_tenant');
```

**Ghi vào writeup — bảng:** sau UPDATE | sau VACUUM | sau REINDEX | sau VACUUM FULL, cho cả bảng và 2 index. **VACUUM lấy lại được gì, REINDEX lấy lại được gì?**

---

## §5. `CONCURRENTLY` — làm được trên production

### Lý thuyết

```sql
CREATE INDEX CONCURRENTLY idx_x ON tbl(col);
REINDEX INDEX CONCURRENTLY idx_x;
```

Không chặn ghi. Đổi lại:
- Chậm hơn ~2-3 lần (quét bảng hai lượt)
- **Không chạy được trong transaction block**
- Nếu thất bại (deadlock, huỷ giữa chừng) sẽ để lại index **INVALID** — vẫn tốn chỗ, vẫn phải cập nhật khi ghi, nhưng planner không dùng. Phải tự phát hiện và `DROP`.

Query phát hiện index hỏng — **nên đưa vào monitoring**:
```sql
SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;
```

### Làm ngay

```sql
CREATE INDEX CONCURRENTLY idx_bloat_created ON t_bloat(created_at);
SELECT indexrelid::regclass, indisvalid FROM pg_index
WHERE indrelid = 't_bloat'::regclass;

-- thử chạy trong transaction -> sẽ lỗi, đọc thông báo
BEGIN;
CREATE INDEX CONCURRENTLY idx_fail ON t_bloat(firmware);
ROLLBACK;
```

**Ghi vào writeup:** thông báo lỗi khi chạy trong transaction là gì? Query tìm index INVALID trả về gì?

---

## §6. Index không ai dùng

### Lý thuyết

Index chưa từng được scan là thuần thuế: tốn ghi, tốn chỗ, tốn VACUUM, không đem lại gì. Trên production thật, tỷ lệ index vô dụng thường 20–40%.

Cảnh báo trước khi xoá: `idx_scan = 0` có thể chỉ vì stats mới reset, hoặc index phục vụ ràng buộc `UNIQUE`/khoá ngoại, hoặc chỉ dùng vào cuối tháng.

### Làm ngay

```sql
SELECT s.relname AS tbl, s.indexrelname AS idx, s.idx_scan,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS size,
       i.indisunique, i.indisprimary
FROM pg_stat_user_indexes s JOIN pg_index i ON i.indexrelid = s.indexrelid
ORDER BY s.idx_scan, pg_relation_size(s.indexrelid) DESC;

SELECT stats_reset FROM pg_stat_database WHERE datname = current_database();
```

**Ghi vào writeup:** có index nào `idx_scan = 0` không? Trước khi xoá, bạn kiểm tra thêm 3 điều gì?

### Dọn dẹp

```sql
DROP TABLE t_idx0, t_idx1, t_idx3, t_idx5, t_bloat;
```

---

## §7. Ôn tuần 2

**Viết vào `writeup.md`:**

**A. Checklist 6 dòng: "khi nào tôi thêm index, khi nào tôi từ chối".** Phải cụ thể, dùng được ngay khi review PR của đồng nghiệp.

**B. Ba điều tôi tưởng đúng mà hoá ra sai trong tuần 2.** Mỗi điều kèm bằng chứng số từ lab.

**C. Query monitoring index** — viết một query duy nhất trả về: index bloat cao, index không ai dùng, index INVALID. Đây là thứ bạn sẽ mang về production.

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B. Áp dụng vào hệ thật:** chạy query ở §6 trên DB production của bạn (chỉ đọc). Có bao nhiêu index không ai dùng, tổng bao nhiêu GB? Bảng `ts_kv` tương đương của bạn đang có mấy index — có cái nào bạn sẽ bỏ không?

### Đạt khi

Bạn định lượng được cái giá của một index (chậm ghi bao nhiêu %, tốn bao nhiêu GB), và biết chính xác VACUUM lấy lại được gì còn REINDEX lấy lại được gì.

**Xong thì gõ `/review-bai`.**

---

## Hết tuần 2

Bạn giờ hiểu index từ cấu trúc page tới cái giá phải trả. Tuần 3 trả lời câu còn treo lại từ Day 04: **khi nào planner ước lượng sai, và vì sao.**
