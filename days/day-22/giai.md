# Day 22 — Lời giải: Dead tuple & bloat

> Bài chữa. Đo thật trên lab `SCALE=1`.

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án |
|---|---|---|
| 1 | Update 100 % bảng 5 lần (không vacuum) — phình mấy lần? | **5,9 lần** (3.744 kB → 22 MB) |
| 2 | `VACUUM` có trả dung lượng về OS không? | **KHÔNG.** 22 MB trước và sau |
| 3 | `DELETE` 87 % rồi `VACUUM` — bảng nhỏ lại không? | **KHÔNG.** Vẫn 58 MB cho 125.848 dòng (bảng tương đương chỉ cần 6 MB) |

---

## §1. Dead tuple sinh ra và tích tụ

| Vòng | `n_live_tup` | `n_dead_tup` | **Kích thước** |
|---|---|---|---|
| 0 | 50.000 | **0** | **3.744 kB** |
| 1 | 50.000 | **0** | 7.480 kB (2,0×) |
| 2 | 50.000 | **0** | 11 MB |
| 3 | 50.000 | **0** | 15 MB |
| 4 | 50.000 | **0** | 18 MB |
| **5** | 50.000 | **0** | **22 MB (5,9×)** |

**Số dòng logic không đổi (50.000). Bảng phình 5,9 lần.**

Chú ý mỗi vòng chỉ thêm ~3,7 MB — đúng bằng kích thước ban đầu. Mỗi `UPDATE` toàn bảng tạo thêm một bản sao đầy đủ.

### ⚠️ `n_dead_tup` báo 0 suốt 5 vòng — bẫy monitoring thứ hai

Ở Day 21 §4 đã thấy `n_dead_tup` mù với ROLLBACK. Hôm nay nó mù với cả **UPDATE đã commit**:

| Nguồn | `dead_tuple_percent` |
|---|---|
| `n_dead_tup` (`pg_stat_user_tables`) | **0** ❌ |
| **`pgstattuple`** (quét thật) | **15,72 %** ✅ |

Lý do: `n_dead_tup` do **stats collector** cập nhật **bất đồng bộ**, và trong cùng một session chạy liên tiếp thì nó chưa kịp làm mới.

> **Hệ quả: `n_dead_tup` là chỉ số TRỄ, không phải chỉ số thời gian thực.** Với dashboard theo dõi 1 phút/lần thì ổn; nhưng đừng dùng nó để đo ngay sau một thao tác lớn.
>
> Và autovacuum **cũng dựa vào `n_dead_tup`** — nên nó cũng kích hoạt trễ (Day 23).

---

## §2. Đo bloat chính xác bằng `pgstattuple`

```
 table_len | tuple_count | tuple_percent | dead_tuple_count | dead_tuple_percent | free_percent
-----------+-------------+---------------+------------------+--------------------+--------------
  22953984 |       50000 |     15,68     |            50101 |       15,72        |    63,03
```

Đọc bảng này:

| Thành phần | % | Nghĩa |
|---|---|---|
| **dòng sống** | **15,68 %** | dữ liệu hữu ích |
| **dòng chết** | **15,72 %** | rác chờ VACUUM |
| **khoảng trống** | **63,03 %** | đã được VACUUM trước đó hoặc chưa dùng |

**Chỉ 15,68 % của 22 MB là dữ liệu thật.** Bảng "khoẻ" nên có `tuple_percent > 70 %`.

### `pgstattuple` vs `pgstattuple_approx`

Ở lab hai hàm cho **kết quả gần như y hệt** (15,7153 vs 15,7152 %) vì `scanned_percent = 100` — bảng quá nhỏ nên `approx` vẫn quét hết.

Trên bảng lớn, `pgstattuple_approx`:
- Bỏ qua các page đã `all-visible` (dùng visibility map)
- Nhanh hơn nhiều, sai số vài %
- **Chỉ dùng được cho heap**, không dùng cho index

> **Quy tắc: `pgstattuple` quét toàn bảng — trên bảng 500 GB nó chạy hàng chục phút và đọc hết vào cache. Dùng `pgstattuple_approx` cho monitoring định kỳ, `pgstattuple` chỉ khi cần con số chính xác.**

---

## §3. `VACUUM` làm gì và **không** làm gì — ý quan trọng nhất hôm nay

### Output `VERBOSE` — đọc từng dòng

```
INFO:  finished vacuuming "lab.public.t_dead": index scans: 0
pages: 0 removed, 2802 remain, 2802 scanned (100.00% of total)
tuples: 50101 removed, 50000 remain, 0 are dead but not yet removable
removable cutoff: 1810, which was 0 XIDs old when operation ended
new relfrozenxid: 1809, which is 8 XIDs ahead of previous value
buffer usage: 5619 hits, 0 misses, 0 dirtied
WAL usage: 5138 records, 0 full page images, 784235 bytes
```

| Dòng | Nghĩa |
|---|---|
| `pages: 0 removed, 2802 remain` | **không trả page nào về OS** |
| `tuples: 50101 removed` | dọn được 50.101 dead tuple |
| `0 are dead but not yet removable` | không có transaction nào chặn (§6 sẽ khác) |
| `removable cutoff: 1810` | XID biên — tuple có `xmax` cũ hơn số này mới được dọn |
| `new relfrozenxid: 1809` | freeze tiến thêm 8 XID (Day 25) |
| `WAL usage: 784235 bytes` | **VACUUM cũng sinh WAL** — 784 kB cho một bảng 22 MB |

### Kết quả

| | Trước VACUUM | **Sau VACUUM** |
|---|---|---|
| Kích thước | **22 MB** | **22 MB** *(không đổi)* |
| `dead_tuple_percent` | 15,72 % | **0** ✅ |
| `free_percent` | 63,03 % | **83,09 %** |

**VACUUM chuyển 15,72 % từ "dòng chết" sang "khoảng trống" — nhưng không trả một byte nào cho hệ điều hành.**

### 💡 Kiểm chứng "chỗ trống được tái sử dụng" — ý đắt giá nhất

Sau VACUUM, chạy tiếp **2 vòng UPDATE toàn bảng**:

| | Kích thước |
|---|---|
| sau VACUUM | **22 MB** |
| + 1 vòng UPDATE | **22 MB** |
| + 1 vòng UPDATE nữa | **22 MB** |

**Bảng KHÔNG phình thêm.** Trước đó mỗi vòng thêm 3,7 MB; giờ 0 MB.

Vì sao: `free_percent = 83,09 %` — có 18,3 MB khoảng trống trong file. `UPDATE` viết dòng mới **vào chỗ trống đó** (qua Free Space Map) thay vì cấp page mới.

> ## **Đây là hành vi ĐÚNG và MONG MUỐN của VACUUM.**
>
> Bảng ở **trạng thái ổn định (steady state)** giữ nguyên kích thước và tái sử dụng chỗ trống mãi mãi. Kích thước ổn định ở mức "đủ chứa dữ liệu sống + đệm cho lượng ghi giữa hai lần vacuum".
>
> **Bloat chỉ là vấn đề khi bảng phình lên rồi KHÔNG BAO GIỜ dùng hết chỗ trống đó nữa** — ví dụ xoá 90 % dữ liệu một lần (§5), hoặc autovacuum tụt hậu quá xa (Day 23).

Điều này đảo ngược trực giác thông thường: **mục tiêu không phải là "bảng nhỏ nhất có thể", mà là "kích thước ổn định".** Một bảng luôn 22 MB với 63 % trống vẫn khoẻ hơn một bảng cứ phình mãi.

---

## §4. `VACUUM FULL`

| | Trước | **Sau** |
|---|---|---|
| Tổng | **22 MB** | **3.752 kB** |
| `dead_tuple_percent` | 0 | 0 |
| `free_percent` | 83,09 % | **0,54 %** |

**Lấy lại 83 %** — về đúng kích thước ban đầu (3.744 kB).

### Cái giá

| | `VACUUM` | **`VACUUM FULL`** | `pg_repack` |
|---|---|---|---|
| Trả dung lượng về OS | ✗ | ✅ | ✅ |
| **Khoá** | chỉ chặn DDL | **`ACCESS EXCLUSIVE`** — chặn cả `SELECT` | khoá ngắn ở đầu/cuối |
| Chỗ trống cần thêm | ~0 | **= kích thước bảng + index** | = kích thước bảng + index |
| Chạy được lúc cao điểm | ✅ | ❌ **TUYỆT ĐỐI KHÔNG** | ✅ |
| Thời gian trên bảng 500 GB | vài phút | **hàng giờ, khoá suốt** | hàng giờ, không khoá |

`ACCESS EXCLUSIVE` chặn **mọi thứ**, kể cả `SELECT count(*)`. Trên bảng 500 GB đó là hàng giờ downtime.

> **Trên production, dùng `pg_repack` thay cho `VACUUM FULL`.** Nó tạo bảng mới, dùng trigger bắt kịp thay đổi trong lúc chép, rồi đổi tên trong một transaction ngắn. Đây là công cụ chuẩn cho "de-bloat không downtime".
>
> Cài: `CREATE EXTENSION pg_repack;` rồi chạy `pg_repack -t bang_lon -d db` từ shell.

---

## §5. Kịch bản `DELETE` hàng loạt — ca xấu nhất

| | Kích thước | Số dòng | `count(*)` buffers | time |
|---|---|---|---|---|
| Ban đầu (1.000.000 dòng) | **58 MB** | 1.000.000 | 7.424 | 51,1 ms |
| Sau `DELETE` 87,4 % | **58 MB** | 125.848 | — | — |
| **Sau `VACUUM`** | **58 MB** | 125.848 | **7.424** | 16,8 ms |
| **Bảng tương đương** (tạo mới) | **6.144 kB** | 100.000 | ~768 | — |

### **Còn 12,6 % số dòng nhưng file vẫn 58 MB — lãng phí 9,7 lần.**

Và điểm chí mạng: `SELECT count(*)` sau `VACUUM` vẫn đọc **7.424 buffer** — **y hệt lúc bảng còn đầy đủ 1 triệu dòng**.

```
Bảng đầy đủ  (1.000.000 dòng): 7.424 buffer
Sau DELETE 87% + VACUUM (125.848 dòng): 7.424 buffer     <- KHÔNG GIẢM
Bảng tương đương tạo mới:                  ~768 buffer     <- lẽ ra phải thế này
```

**Mọi Seq Scan phải đọc toàn bộ file mãi mãi.** VACUUM đánh dấu 87 % là "trống" nhưng file vẫn phải quét qua.

*(Thời gian giảm từ 51,1 xuống 16,8 ms chỉ vì plan đổi từ parallel sang không-parallel và cache đã nóng — buffers mới là con số thật.)*

### Ba cách xử lý đúng, tốt dần

| Cách | Ưu | Nhược |
|---|---|---|
| **1.** `DELETE` + `VACUUM FULL`/`pg_repack` | lấy lại được | downtime (FULL) hoặc phức tạp (repack); vẫn phải sinh 874.152 dead tuple |
| **2.** `CREATE TABLE moi AS SELECT ... WHERE giu_lai` rồi đổi tên | nhanh hơn nhiều | phải dựng lại index/FK/trigger, cần khoá ngắn để đổi tên |
| **3.** **`PARTITION` + `DROP PARTITION`** | **tức thời, KHÔNG sinh dead tuple nào** | phải thiết kế partition từ đầu |

> **Cách 3 là lý do tồn tại của partitioning.** `DROP PARTITION` chỉ là `unlink()` một file — mili-giây, không WAL đáng kể, không dead tuple, không cần VACUUM. Day 33 đo cụ thể.

---

## §6. Transaction dài — kẻ giết VACUUM

### Thí nghiệm hai session

**S2** mở `BEGIN; SELECT 1;` rồi ngồi im (giữ snapshot).
**S1** chạy `UPDATE` toàn bảng rồi `VACUUM`:

```
INFO:  finished vacuuming "lab.public.t_dead":
tuples: 0 removed, 100000 remain, 50000 are dead but not yet removable
                   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
removable cutoff: 1822, which was 1 XIDs old when operation ended
```

**`0 removed` — VACUUM dọn được ĐÚNG 0 dòng.** `n_dead_tup` sau đó vẫn là **50.000**.

Thủ phạm lộ diện:
```
 pid  | state  | xact_giây | idle_giây |          q
------+--------+-----------+-----------+----------------------
 2046 | active |         2 |         2 | SELECT pg_sleep(12);
```

### Sau khi S2 `COMMIT`

```
INFO:  finished vacuuming "lab.public.t_dead":
tuples: 50000 removed, 50000 remain, 0 are dead but not yet removable
        ^^^^^^^^^^^^^
```

**Ngay lập tức dọn được toàn bộ 50.000 dòng.** `n_dead_tup` về 0, kích thước 7.480 kB.

### Vì sao — và vì sao đây là sự cố production số một

Một dead tuple chỉ dọn được khi **không snapshot nào còn có thể nhìn thấy nó**. `removable cutoff` = XID cũ nhất trong mọi snapshot đang mở.

S2 giữ một snapshot ở XID 1821 → mọi tuple có `xmax > 1821` **có thể** vẫn cần cho S2 → không dọn được.

> ## **Một transaction mở lâu — KỂ CẢ CHỈ ĐỌC, kể cả `idle in transaction` — chặn VACUUM dọn dead tuple của TOÀN BỘ database.**
>
> Không phải chỉ bảng nó đụng vào. **Toàn bộ database.**

Kịch bản kinh điển:
```
1. Một connection từ app: BEGIN ... rồi quên COMMIT
   (bug retry, breakpoint khi debug, pool cấu hình sai, ORM giữ transaction qua lời gọi HTTP)
2. Sau vài giờ: bảng nóng phình gấp 10 lần
3. Query chậm dần, đĩa đầy, autovacuum chạy liên tục mà không dọn được gì
4. Sửa: kill connection đó -> VACUUM dọn sạch trong vài phút
```

### ⚠️ `idle_in_transaction_session_timeout = 0` — đang TẮT

```
 idle_in_transaction_session_timeout
-------------------------------------
 0
```

**Đây là mặc định của Postgres, và nó là mặc định nguy hiểm.** Không có gì tự kill connection quên commit.

```sql
-- BẬT NGAY trên production
ALTER SYSTEM SET idle_in_transaction_session_timeout = '5min';
SELECT pg_reload_conf();
```

Từ PG17 còn có `transaction_timeout` (giới hạn tổng thời gian transaction, kể cả đang active):
```sql
ALTER SYSTEM SET transaction_timeout = '30min';   -- chặn cả transaction đang chạy
```

### Query monitoring — mang thẳng về production

```sql
-- Transaction chạy quá 5 phút / idle in transaction quá 1 phút
SELECT pid,
       state,
       usename, application_name, client_addr,
       now() - xact_start   AS tuoi_transaction,
       now() - state_change AS thoi_gian_o_trang_thai_nay,
       backend_xmin,
       left(regexp_replace(query, '\s+', ' ', 'g'), 80) AS query
FROM pg_stat_activity
WHERE backend_type = 'client backend'
  AND xact_start IS NOT NULL
  AND (
        (state = 'idle in transaction' AND now() - state_change > interval '1 minute')
     OR (now() - xact_start > interval '5 minutes')
  )
ORDER BY xact_start;
```

Cột `backend_xmin` là chìa khoá: đó chính là XID đang **chặn** VACUUM. So với `removable cutoff` trong log VACUUM để xác nhận đúng thủ phạm.

Kill khi cần:
```sql
SELECT pg_cancel_backend(pid);      -- huỷ query, giữ connection (thử trước)
SELECT pg_terminate_backend(pid);   -- giết hẳn connection
```

Ba nguồn khác cũng chặn VACUUM, đừng quên:
```sql
-- 1. replication slot bị bỏ quên (rất hay gặp)
SELECT slot_name, active, restart_lsn, xmin, catalog_xmin FROM pg_replication_slots;

-- 2. prepared transaction (2PC) bị treo
SELECT gid, prepared, owner FROM pg_prepared_xacts;

-- 3. hot_standby_feedback từ replica (Day 38)
```

---

## §7. Ngưỡng cảnh báo cho hệ thật

Trạng thái lab sau các thí nghiệm:

| relname | n_live_tup | n_dead_tup | tỷ lệ chết | size |
|---|---|---|---|---|
| `t_del` | 0 | **874.152** | — | **58 MB** |
| `t_dead` | 100.000 | 349.898 | **3,499** | 3.744 kB |
| `ts_kv` | 5.002.424 | 97.772 | 0,020 | 295 MB |
| `alarm` | 200.000 | 0 | 0 | 29 MB |

### Query monitoring tổng hợp

```sql
-- Mọi bảng vượt ngưỡng — dùng được ngay trên production
SELECT s.relname,
       pg_size_pretty(pg_relation_size(s.relid))        AS size,
       s.n_live_tup, s.n_dead_tup,
       round(100.0 * s.n_dead_tup
             / NULLIF(s.n_live_tup + s.n_dead_tup, 0), 1) AS pct_chet,
       now() - greatest(s.last_vacuum, s.last_autovacuum) AS lan_vacuum_cuoi,
       CASE
         WHEN s.n_dead_tup > 100000
              AND s.n_dead_tup > 0.2 * GREATEST(s.n_live_tup,1) THEN 'BLOAT — kiểm tra autovacuum'
         WHEN greatest(s.last_vacuum, s.last_autovacuum) IS NULL
              AND s.n_live_tup > 100000                          THEN 'CHƯA TỪNG VACUUM'
         WHEN now() - greatest(s.last_vacuum, s.last_autovacuum)
              > interval '1 day' AND s.n_mod_since_analyze > 0.1 * s.n_live_tup
                                                                 THEN 'VACUUM TỤT HẬU'
       END AS van_de
FROM pg_stat_user_tables s
WHERE pg_relation_size(s.relid) > 100*1024*1024
ORDER BY s.n_dead_tup DESC;
```

### Bảng ngưỡng

| Chỉ số | Cảnh báo | Nguồn | Ghi chú từ số đo |
|---|---|---|---|
| `dead_tuple_percent` | **> 20 %** | `pgstattuple_approx` | đắt — chạy hằng tuần |
| `n_dead_tup / n_live_tup` | **> 0,2** | `pg_stat_user_tables` | rẻ, nhưng **TRỄ** và mù với ROLLBACK |
| **Transaction dài nhất** | **> 5 phút** | `pg_stat_activity` | **quan trọng nhất** — chặn VACUUM toàn DB |
| `idle in transaction` | **> 1 phút** | `pg_stat_activity` | bật `idle_in_transaction_session_timeout` |
| Bảng chưa autovacuum | > 1 ngày (bảng nóng) | `last_autovacuum` | |
| Replication slot không active | bất kỳ | `pg_replication_slots` | chặn VACUUM âm thầm |

---

## Bảng số liệu chính

| Kịch bản | Kết quả |
|---|---|
| 5 vòng UPDATE toàn bảng | 3.744 kB → **22 MB (5,9×)**, `n_dead_tup` báo **0** suốt |
| `pgstattuple` thật | sống **15,68 %**, chết **15,72 %**, trống **63,03 %** |
| **Sau `VACUUM`** | kích thước **22 MB không đổi**; chết 15,72 % → **0**; trống 63,03 % → **83,09 %** |
| **+ 2 vòng UPDATE nữa** | **22 MB — KHÔNG phình thêm** (steady state) |
| `VACUUM` sinh WAL | **784.235 byte** cho bảng 22 MB |
| **`VACUUM FULL`** | 22 MB → **3.752 kB (−83 %)**, trống 0,54 % |
| `DELETE` 87,4 % + `VACUUM` | **58 MB không đổi**, `count(*)` vẫn **7.424 buffer** |
| — bảng tương đương tạo mới | **6.144 kB** → lãng phí **9,7 lần** |
| **VACUUM khi có transaction mở** | `tuples: 0 removed, 50000 are dead but not yet removable` |
| VACUUM sau khi transaction commit | `tuples: 50000 removed` — dọn sạch ngay |
| `idle_in_transaction_session_timeout` | **0 (TẮT)** — mặc định nguy hiểm |

---

## Ba điều dễ hiểu sai

| # | Hiểu nhầm | Sự thật đo được |
|---|---|---|
| 1 | "VACUUM không làm bảng nhỏ lại = VACUUM vô dụng" | Sau VACUUM, **2 vòng UPDATE nữa không phình thêm một byte**. Đó là **mục tiêu**: kích thước ổn định, không phải kích thước nhỏ nhất |
| 2 | "`n_dead_tup` cho biết bảng có bloat không" | Báo **0** suốt 5 vòng UPDATE trong khi `pgstattuple` báo **15,72 %**. Nó **trễ** và **mù với ROLLBACK** |
| 3 | "Transaction chỉ đọc thì vô hại" | Một `SELECT 1` trong `BEGIN` làm VACUUM dọn được **đúng 0 dòng** trên toàn database |

Thêm hai điều:
- **`DELETE` 87 % rồi `VACUUM` không làm `count(*)` nhanh hơn chút nào** — vẫn 7.424 buffer, y hệt lúc bảng đầy.
- **`VACUUM` cũng sinh WAL** (784 kB cho bảng 22 MB) — trên bảng lớn, VACUUM tạo áp lực WAL đáng kể và ảnh hưởng replication lag.

---

## Áp dụng vào hệ thật

**1. Bật `idle_in_transaction_session_timeout` ngay hôm nay — một dòng, không rủi ro:**
```sql
ALTER SYSTEM SET idle_in_transaction_session_timeout = '5min';
SELECT pg_reload_conf();
```
Đây là biện pháp phòng ngừa rẻ nhất cho sự cố bloat phổ biến nhất. Nếu app có job hợp lệ chạy lâu, đặt riêng cho role đó:
```sql
ALTER ROLE etl_user SET idle_in_transaction_session_timeout = '1h';
```

**2. Đưa query "transaction dài" (§6) lên dashboard, cảnh báo ở 5 phút.** Kèm `backend_xmin` để biết ai đang chặn.

**3. Kiểm tra replication slot bị bỏ quên — thủ phạm âm thầm nhất:**
```sql
SELECT slot_name, active, age(xmin) AS tuoi_xmin,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_giu_lai
FROM pg_replication_slots;
```
`active = false` mà `restart_lsn` cũ = slot đang giữ WAL **và** chặn VACUUM. Xoá nếu không dùng: `SELECT pg_drop_replication_slot('ten_slot');`

**4. Đừng hoảng khi thấy bảng có nhiều `free_percent`.** Kiểm tra kích thước có **ổn định** không:
```sql
-- chạy hằng ngày, ghi vào bảng lịch sử
SELECT now(), relname, pg_relation_size(relid) FROM pg_stat_user_tables;
```
Kích thước ổn định = khoẻ. Kích thước tăng đều = autovacuum tụt hậu (Day 23).

**5. Với retention, dùng partition + `DROP PARTITION`, không dùng `DELETE`.** §5 cho thấy `DELETE` + `VACUUM` để lại file lãng phí 9,7 lần và **không làm query nhanh hơn chút nào**. Day 33.

**6. Cài `pg_repack` trên production** để de-bloat mà không downtime. `VACUUM FULL` chỉ dùng trong cửa sổ bảo trì có kế hoạch.

**7. Với job nạp dữ liệu lớn, chia nhỏ transaction.** Transaction 30 phút vừa giữ dead tuple của toàn DB, vừa để lại rác nếu rollback (Day 21 §4).

---

## Câu hỏi mở sang các ngày sau

1. Autovacuum dựa vào `n_dead_tup` — mà chỉ số đó trễ và mù với ROLLBACK. Ngưỡng mặc định 20 % có hợp lý cho bảng 5 triệu dòng? → **Day 23**
2. `UPDATE` toàn bảng tạo bản sao đầy đủ. HOT update tránh được bao nhiêu? → **Day 24**
3. `new relfrozenxid` tiến 8 XID mỗi lần VACUUM — bao lâu thì tới ngưỡng 200 triệu? → **Day 25**
4. Transaction dài chặn VACUUM — `hot_standby_feedback` từ replica cũng vậy? → **Day 38**
5. `DROP PARTITION` thay `DELETE` — chênh lệch bao nhiêu? → **Day 33**
