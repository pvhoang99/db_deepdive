# Day 25 — Lời giải: Freeze, XID wraparound + ôn tuần 5

> Bài chữa. Đo thật trên lab `SCALE=1`.

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án |
|---|---|---|
| 1 | XID 32 bit, 5.000 TPS — bao lâu hết? | **4 ngày** tới mốc 2 tỷ. Và chỉ **11 giờ** tới `autovacuum_freeze_max_age` |
| 2 | Chuyện gì khi sắp hết? | Bốn bậc bảo vệ, bậc cuối là **DỪNG NHẬN GHI** — database chỉ đọc |
| 3 | Bảng **chỉ đọc** có cần vacuum không? | **CÓ, bắt buộc.** Nó vẫn kéo cả database tới wraparound |

Câu 3 là câu trả lời phản trực giác nhất tuần 5.

---

## §1. XID chỉ có 32 bit

```
 ngày nếu 1.000 TPS | ngày nếu 5.000 TPS | ngày nếu 50.000 TPS | giờ tới freeze_max @5000tps
--------------------+--------------------+---------------------+-----------------------------
                 24 |                  4 |            0 (~10h) |                          11
```

| Tốc độ ghi | Tới **2 tỷ XID** (ngưỡng chết) | Tới **200 triệu** (`autovacuum_freeze_max_age`) |
|---|---|---|
| 1.000 TPS | 24 ngày | **2,3 ngày** |
| **5.000 TPS** | **4 ngày** | **11 giờ** |
| 50.000 TPS | **~10 giờ** | **1,1 giờ** |

### Con số này nghĩa là gì

**Với hệ IoT ghi 50.000 dòng/giây, nếu vacuum bị chặn hoàn toàn thì database dừng nhận ghi sau ~10 giờ.**

Không phải "vài tháng nữa mới lo". Đây là bài toán trong ngày.

Chú ý: mỗi câu lệnh ghi (không nằm trong transaction tường minh) tiêu **một** XID. Nhưng transaction lớn với nhiều câu lệnh chỉ tiêu **một** XID — nên "TPS" ở đây là số **transaction**, không phải số row.

Cũng lưu ý: `SELECT` thuần **không** tiêu XID (Postgres cấp XID lười — chỉ khi transaction thật sự ghi).

---

## §2. Freeze — lời giải

```
autovacuum_freeze_max_age           = 200.000.000
vacuum_freeze_min_age               =  50.000.000
vacuum_freeze_table_age             = 150.000.000
autovacuum_multixact_freeze_max_age = 400.000.000
```

| GUC | Nghĩa |
|---|---|
| `vacuum_freeze_min_age` (50tr) | tuple cũ hơn ngần này XID thì **freeze khi VACUUM gặp** |
| `vacuum_freeze_table_age` (150tr) | bảng già hơn ngần này → VACUUM chuyển sang **aggressive**, quét mọi page |
| **`autovacuum_freeze_max_age`** (200tr) | **bắt buộc** autovacuum chạy — kể cả khi `autovacuum = off` |
| `vacuum_failsafe_age` (1,6 tỷ) | bỏ qua cost delay, bỏ qua dọn index, chạy hết tốc lực |

### Trạng thái lab

```
   relname   | tuổi | % tới ngưỡng |    size
-------------+------+--------------+------------
 tenant      |  647 |     0,0003 % | 8 kB
 ts_kv       |  629 |     0,0003 % | 295 MB

 datname | age  | % tới 2 tỷ
---------+------+-------------
 lab     | 1168 |   0,00006 %
```

Lab hoàn toàn an toàn — nhưng nó mới chạy vài nghìn transaction.

### 💡 Vì sao bảng chỉ đọc vẫn cần vacuum

`relfrozenxid` của một bảng là **XID cũ nhất chưa được freeze trong bảng đó**. Nó **không tự già đi** khi bảng không đổi — nhưng **XID hiện tại thì cứ tăng**, nên `age(relfrozenxid)` tăng đều theo tốc độ ghi của **toàn database**.

```
Bảng archive 500 GB, đọc-only từ 2 năm trước, relfrozenxid = 1.000.000
Database ghi 5.000 TPS  ->  XID hiện tại tăng 432 triệu/ngày
age(relfrozenxid) của bảng archive tăng 432 triệu/ngày
-> chạm 200 triệu sau ~11 giờ
-> autovacuum BẮT BUỘC quét toàn bộ 500 GB
```

Và `datfrozenxid` của cả database = **min** của `relfrozenxid` mọi bảng. **Một bảng bị bỏ quên kéo cả database tới wraparound.**

> **Đây là lý do "bảng archive không cần đụng tới" là suy nghĩ nguy hiểm nhất về vacuum.**

Cách phòng: `VACUUM FREEZE` bảng archive **một lần** sau khi nó ngừng thay đổi. Sau đó `relfrozenxid` được đẩy lên sát hiện tại và bảng đó không còn kéo ai xuống.

---

## §3. Aggressive vacuum và `VACUUM FREEZE`

```
INFO:  aggressively vacuuming "lab.public.t_frz"
       ^^^^^^^^^^^^
pages: 0 removed, 1216 remain, 1216 scanned (100.00% of total)
frozen: 1207 pages from table (99.26% of total) had 50000 tuples frozen
new relfrozenxid: 1900, which is 1 XIDs ahead of previous value
WAL usage: 2415 records, 1 full page images, 261674 bytes
```

| | Trước `VACUUM FREEZE` | **Sau** |
|---|---|---|
| `all_frozen` pages | **0 / 1.216 (0 %)** | **1.207 / 1.216 (99,3 %)** |
| `age(relfrozenxid)` | 1 | **0** |

**99,3 % page thành `all_frozen`** — 9 page còn lại là page chưa đầy hoặc đang được ghi.

So với `ts_kv` (chưa freeze):
```
 frozen | total | pct_frozen
--------+-------+------------
      0 | 37698 |        0.0
```

### Hai chữ quan trọng trong log: `aggressively vacuuming`

VACUUM thường **bỏ qua** page đã `all-visible` trong visibility map — rất nhanh.

**Aggressive vacuum quét MỌI page**, kể cả đã frozen. Nó kích hoạt khi:
- `age(relfrozenxid) > vacuum_freeze_table_age` (150 triệu), hoặc
- gõ tay `VACUUM FREEZE`

Với bảng 500 GB, đó là **một lượt đọc toàn bộ 500 GB**.

> **Đây là nguồn của sự cố kinh điển:** *"database đột nhiên chậm hẳn lúc 3 giờ sáng, I/O đầy, không ai deploy gì cả"* — đó là aggressive autovacuum khởi động trên bảng lớn khi `age` chạm 150 triệu.
>
> Và nó xảy ra **cùng lúc trên nhiều bảng**, vì các bảng thường có `relfrozenxid` gần nhau (cùng được tạo/nạp một đợt).

### Cách phòng — freeze dần thay vì để dồn

```sql
-- Cách 1: hạ vacuum_freeze_min_age để tuple được freeze SỚM trong vacuum thường
ALTER TABLE bang_lon SET (autovacuum_freeze_min_age = 10000000);   -- 10tr thay vì 50tr

-- Cách 2: freeze chủ động cho bảng/partition đã "đóng băng" về nghiệp vụ
VACUUM (FREEZE, VERBOSE) partition_2024_01;

-- Cách 3: giãn autovacuum_freeze_max_age giữa các bảng để chúng không cùng kích hoạt
ALTER TABLE t1 SET (autovacuum_freeze_max_age = 150000000);
ALTER TABLE t2 SET (autovacuum_freeze_max_age = 180000000);
ALTER TABLE t3 SET (autovacuum_freeze_max_age = 210000000);
```

Cách 2 đặc biệt hợp với **partition theo thời gian**: partition tháng trước không bao giờ đổi nữa → `VACUUM FREEZE` nó một lần → nó không bao giờ cần aggressive vacuum nữa (Day 33).

Chi phí: `VACUUM FREEZE` bảng 50.000 dòng sinh **261.674 byte WAL**. Quy đổi cho bảng 500 GB: ~2,6 GB WAL. Đáng, nếu tránh được aggressive vacuum bất ngờ.

---

## §4. Chuyện gì xảy ra khi tới ngưỡng

| `age(datfrozenxid)` | Hành vi |
|---|---|
| **> 200 triệu** | autovacuum khởi động chế độ chống-wraparound, **không thể tắt**, không thể huỷ (kill nó, nó chạy lại ngay) |
| **> 1,6 tỷ** | **failsafe**: bỏ qua cost delay, **bỏ qua dọn index**, chạy hết tốc lực |
| **> ~2,09 tỷ** | **WARNING** trong log mỗi lần cấp XID |
| **~2,1 tỷ** | **DỪNG NHẬN GHI.** Database chỉ đọc. Phải vào **single-user mode** để VACUUM |

Bậc cuối là tê liệt hoàn toàn. Khắc phục: dừng Postgres, vào single-user mode (`postgres --single`), chạy `VACUUM` — với DB lớn có thể mất **nhiều giờ tới nhiều ngày**, và trong suốt thời gian đó **không có gì hoạt động**.

### Ba thứ hay chặn freeze — kiểm tra trong lab

```sql
-- 1. transaction dài
 pid  |   tuổi   | state  | query
------+----------+--------+-------
 2196 | 00:00:00 | active | (chính query đang chạy)      <- sạch

-- 2. replication slot bị bỏ quên
 slot_name | active | restart_lsn | wal_giu_lai
-----------+--------+-------------+-------------
(0 rows)                                                  <- sạch

-- 3. prepared transaction treo
 transaction | gid | prepared | owner | database
-------------+-----+----------+-------+----------
(0 rows)                                                  <- sạch
```

Lab sạch cả ba. **Trên production, thứ ít người kiểm tra nhất là (2) và (3).**

| Thủ phạm | Vì sao chặn | Dấu hiệu |
|---|---|---|
| **Transaction dài** | giữ snapshot → `removable cutoff` không tiến | `pg_stat_activity.backend_xmin` cũ |
| **Replication slot không active** | giữ `xmin` để replica còn dùng được | `active = false`, `restart_lsn` cũ |
| **Prepared transaction treo** | 2PC chưa `COMMIT PREPARED` — sống mãi qua restart | `pg_prepared_xacts` có dòng |
| `hot_standby_feedback` từ replica | replica báo ngược `xmin` của nó lên primary | Day 38 |

**Prepared transaction là nguy hiểm nhất** vì nó **sống sót qua restart Postgres**. Kill connection không cứu được; phải `ROLLBACK PREPARED 'gid'` thủ công.

> ### ⚠️ Rủi ro cụ thể cho hệ dùng Temporal + outbox
>
> Nếu có bug khiến transaction outbox không commit/rollback (retry lỗi, worker chết giữa chừng, distributed transaction treo), nó sẽ **chặn vacuum toàn database** — và với 50.000 TPS thì chỉ ~10 giờ tới ngưỡng dừng ghi.
>
> Đây là rủi ro thật, không lý thuyết. Alert cho `pg_prepared_xacts` và `xact_start` là **bắt buộc**, không phải "nice to have".

---

## §5. Query monitoring — mang thẳng về production

```
   relname   | xid_age | pct_freeze_max | pct_shutdown |  size   | mức độ
-------------+---------+----------------+--------------+---------+--------
 tenant      |     648 |        0,000 % |    0,00003 % | 32 kB   | OK
 ts_kv       |     630 |        0,000 % |    0,00003 % | 846 MB  | OK
```

### Query đầy đủ

```sql
SELECT
  n.nspname || '.' || c.relname                                   AS bang,
  age(c.relfrozenxid)                                             AS xid_age,
  round(100.0 * age(c.relfrozenxid)
        / current_setting('autovacuum_freeze_max_age')::numeric, 1) AS pct_freeze_max,
  round(100.0 * age(c.relfrozenxid) / 2100000000.0, 2)            AS pct_shutdown,
  pg_size_pretty(pg_total_relation_size(c.oid))                   AS size,
  s.last_autovacuum,
  CASE
    WHEN age(c.relfrozenxid) > 1500000000 THEN 'CRITICAL'
    WHEN age(c.relfrozenxid) > current_setting('autovacuum_freeze_max_age')::numeric        THEN 'WARNING'
    WHEN age(c.relfrozenxid) > current_setting('autovacuum_freeze_max_age')::numeric * 0.75 THEN 'NOTICE'
    ELSE 'OK'
  END AS muc_do
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
WHERE c.relkind IN ('r','m','t')            -- gồm cả TOAST và materialized view
ORDER BY age(c.relfrozenxid) DESC
LIMIT 20;
```

⚠️ **Nhớ `relkind = 't'` (bảng TOAST).** Bảng TOAST có `relfrozenxid` riêng và **cũng kéo `datfrozenxid` xuống**. Nhiều query monitoring bỏ sót nó.

### Ngưỡng cảnh báo

| Ngưỡng | `xid_age` | Mức | Hành động |
|---|---|---|---|
| 50 % của `freeze_max_age` | 100 triệu | **NOTICE** | ghi nhận, xem xu hướng |
| 75 % | 150 triệu | **WARNING** | điều tra ngay — chạy runbook |
| 100 % | 200 triệu | **CRITICAL** | autovacuum chống-wraparound đang chạy |
| 1,6 tỷ | | **PAGE ngay** | failsafe đã kích hoạt |

### Runbook 5 bước khi alert kêu

```
① XÁC ĐỊNH BẢNG NÀO
   Chạy query §5. Ghi lại tên bảng, xid_age, kích thước.

② TÌM CÁI ĐANG CHẶN — làm TRƯỚC mọi thứ khác
   a) SELECT pid, backend_xmin, now()-xact_start, state, query
      FROM pg_stat_activity WHERE backend_xmin IS NOT NULL ORDER BY age(backend_xmin) DESC;
   b) SELECT slot_name, active, age(xmin), age(catalog_xmin) FROM pg_replication_slots;
   c) SELECT gid, prepared, owner FROM pg_prepared_xacts;
   -> Nếu tìm thấy: xử lý NGAY. Mọi bước sau đều vô ích nếu còn cái này.
      pg_terminate_backend(pid) / pg_drop_replication_slot(...) / ROLLBACK PREPARED 'gid'

③ KIỂM TRA AUTOVACUUM CÓ ĐANG CHẠY KHÔNG
   SELECT pid, relid::regclass, phase, heap_blks_scanned, heap_blks_total
   FROM pg_stat_progress_vacuum;
   -> Đang chạy: ước lượng thời gian còn lại = (total-scanned)/tốc độ. Chờ.
   -> KHÔNG chạy: sang ④

④ TĂNG TỐC VACUUM
   ALTER SYSTEM SET autovacuum_vacuum_cost_delay = 0;
   ALTER SYSTEM SET autovacuum_vacuum_cost_limit = 10000;
   ALTER SYSTEM SET autovacuum_work_mem = '2GB';
   SELECT pg_reload_conf();
   -> hoặc chạy tay có ưu tiên:  VACUUM (FREEZE, VERBOSE) bang_bi_alert;

⑤ SAU KHI QUA KHỦNG HOẢNG — sửa gốc
   - Bật alert cho pg_prepared_xacts và replication slot không active
   - idle_in_transaction_session_timeout = '5min'
   - VACUUM FREEZE các bảng/partition đã "đóng băng" nghiệp vụ
   - Giãn autovacuum_freeze_max_age giữa các bảng lớn
   - Nếu chưa partition bảng lớn: đưa vào kế hoạch
```

**Bước ② là bước quan trọng nhất và hay bị bỏ qua nhất.** Trong hầu hết postmortem công khai, đội vận hành mất nhiều giờ tăng tốc vacuum trước khi phát hiện ra có một replication slot bị bỏ quên từ tháng trước.

---

## §6. Postmortem — mẫu chung của các sự cố công khai

Ba sự cố hay được nhắc tới: **Sentry (2015)**, **Joyent Manta (2015)**, **Mailchimp (2019)**.

*(Em không tra cứu được nội dung chi tiết từng bài trong lab này, nên phần dưới là mẫu chung rút ra từ cơ chế đã đo được — anh nên đọc bản gốc để lấy chi tiết cụ thể.)*

**Mẫu chung của mọi ca wraparound:**

- **Nguyên nhân gốc luôn là một thứ CHẶN vacuum**, không phải vacuum chạy chậm: transaction bị bỏ quên, replication slot không dùng, hoặc prepared transaction treo.
- **Không ai monitor `age(relfrozenxid)`.** Dashboard đầy đủ CPU/RAM/disk/QPS nhưng thiếu đúng chỉ số này.
- **Phát hiện khi database đã dừng nhận ghi** — tức bậc cuối cùng, không còn đường lùi.
- **Khắc phục mất nhiều giờ** vì phải vào single-user mode và VACUUM tuần tự, không parallel, không thể phục vụ traffic.
- **Sau đó ai cũng thêm alert cho `xid_age`** — và đó là bài học duy nhất thật sự quan trọng.

**Điều áp dụng được ngay cho hệ IoT + Temporal/outbox:**
1. Alert `xid_age > 100 triệu` — làm trong tuần này
2. Alert `pg_prepared_xacts` có bất kỳ dòng nào tồn tại > 5 phút
3. Alert replication slot `active = false`
4. `idle_in_transaction_session_timeout = '5min'`

---

## §7. Ôn tuần 5

### A. Vòng đời một dòng dữ liệu

```
① INSERT
   xmin = XID hiện tại (vd 1776), xmax = 0, ctid = (0,1)
   -> tuple ghi vào page, dữ liệu nằm trên đĩa NGAY (kể cả chưa commit — Day 21 §5)
   -> kích thước bảng: +1 tuple
   -> VM bit all-visible: TẮT (page vừa bị ghi)

② COMMIT
   -> chỉ ghi 1 bit vào pg_xact. KHÔNG đụng tuple.
   -> SELECT đầu tiên sau đó ghi "hint bit" vào tuple  -> làm bẩn page, sinh I/O ghi (Day 08 §1)

③ UPDATE
   tuple cũ: xmax = XID mới (1778), t_ctid trỏ tới tuple mới
   tuple mới: xmin = 1778, xmax = 0, ctid = SLOT MỚI
   -> nếu HOT (fillfactor còn chỗ + không đụng cột index):
        chuỗi nằm TRONG CÙNG PAGE, index KHÔNG đổi
   -> nếu KHÔNG HOT:
        tuple mới sang page khác, MỌI index thêm entry mới
        kích thước bảng VÀ mọi index: +1 (Day 21 §7: gấp đôi sau 1 vòng)
   -> VM bit all-visible: TẮT

④ DELETE
   xmax = XID xoá. Tuple VẪN NGUYÊN trên page (Day 21 §3)
   -> kích thước bảng: KHÔNG đổi

⑤ DEAD TUPLE
   Tuple cũ chỉ dọn được khi mọi snapshot đang mở đều mới hơn xmax của nó
   -> transaction dài (kể cả chỉ đọc) chặn bước này TRÊN TOÀN DATABASE (Day 22 §6)
   -> n_dead_tup tăng... nhưng TRỄ, và MÙ với ROLLBACK (Day 21 §4, Day 22 §1)

⑥ PAGE PRUNING  (chỉ với HOT chain)
   Bất kỳ SELECT nào chạm page gần đầy -> dọn HOT chain tại chỗ
   -> slot đầu thành REDIRECT, slot giữa thành unused
   -> KHÔNG đụng index, KHÔNG cần VACUUM (Day 24 §3)

⑦ VACUUM
   -> xoá dead tuple khỏi heap + entry tương ứng trong MỌI index
   -> ghi không gian trống vào Free Space Map
   -> BẬT VM bit all-visible  -> index-only scan hoạt động (Day 08: nhanh 287x)
   -> đẩy relfrozenxid lên
   -> KHÔNG trả dung lượng cho OS. Kích thước giữ nguyên. (Day 22 §3)
   -> chỗ trống được TÁI SỬ DỤNG -> bảng vào steady state, không phình thêm

⑧ FREEZE  (khi tuple cũ hơn vacuum_freeze_min_age = 50tr XID)
   -> đặt bit HEAP_XMIN_FROZEN, xmin không còn được so sánh nữa
   -> BẬT VM bit all-frozen  -> vacuum sau bỏ qua page này
   -> đẩy relfrozenxid  -> tránh wraparound

⑨ VACUUM FULL / pg_repack  (chỉ khi bloat đã tích tụ và không dùng hết)
   -> viết lại toàn bộ sang file mới, trả dung lượng cho OS
   -> VACUUM FULL khoá ACCESS EXCLUSIVE (chặn cả SELECT)
```

### B. Năm chỉ số MVCC lên dashboard

| # | Chỉ số | Query | Ngưỡng | **Hành động khi vượt** |
|---|---|---|---|---|
| **1** | **`age(relfrozenxid)` lớn nhất** | §5 (nhớ `relkind='t'`) | **NOTICE 100tr / WARN 150tr / CRIT 200tr** | Chạy runbook §5. **Bước ② trước tiên** |
| **2** | **Transaction dài nhất + `backend_xmin`** | `pg_stat_activity` | **> 5 phút** | `pg_cancel_backend` → `pg_terminate_backend`. Bật `idle_in_transaction_session_timeout` |
| **3** | **Replication slot không active + prepared xact** | `pg_replication_slots`, `pg_prepared_xacts` | **bất kỳ dòng nào tồn tại > 5 phút** | `pg_drop_replication_slot` / `ROLLBACK PREPARED`. **Ít ai monitor cái này nhất** |
| **4** | **Tỷ lệ `n_dead_tup / n_live_tup`** + `last_autovacuum` | `pg_stat_user_tables` | **> 0,2** hoặc `last_autovacuum` > 1 ngày trên bảng nóng | Hạ `autovacuum_vacuum_scale_factor`, nâng `autovacuum_work_mem`. Nhớ chỉ số này **TRỄ và mù với ROLLBACK** |
| **5** | **Tỷ lệ HOT: `n_tup_hot_upd / n_tup_upd`** | `pg_stat_user_tables` | **< 0,5** trên bảng có `n_tup_upd` lớn | Đặt `fillfactor = 70` + `VACUUM FULL`; bỏ index trên cột hay đổi; bật `@DynamicUpdate` ở ORM |

Hai chỉ số phụ đáng thêm: **kích thước bảng theo thời gian** (tăng đều = autovacuum tụt hậu) và **`pg_stat_progress_vacuum`** (vacuum chạy quá lâu).

### C. Ba điều tôi tưởng đúng mà hoá ra sai trong tuần 5

**1. "`VACUUM` không làm bảng nhỏ lại nên nó vô dụng, phải `VACUUM FULL`."**

*Sự thật (Day 22 §3):* sau `VACUUM`, chạy tiếp **2 vòng UPDATE toàn bảng mà bảng KHÔNG phình thêm một byte** (22 MB trước và sau). Trước đó mỗi vòng thêm 3,7 MB.

**Mục tiêu không phải bảng nhỏ nhất, mà là kích thước ỔN ĐỊNH.** `VACUUM FULL` chỉ cần khi bảng đã phình rồi sẽ không bao giờ dùng hết chỗ trống (ví dụ xoá 90 % dữ liệu).

**2. "Update cột không được index thì được HOT."**

*Sự thật (Day 24 §2):* với `fillfactor = 100` (mặc định), tỷ lệ HOT là **0,000** — kể cả khi update cột hoàn toàn không được index.

HOT cần **cả hai** điều kiện, và điều kiện "page còn chỗ" mới là cái hay thiếu. `fillfactor = 70` đưa tỷ lệ HOT lên **0,722**, update nhanh **2,6 lần**, và bảng sau 5 vòng **nhỏ hơn 45 %**.

**3. "Bảng chỉ đọc không cần vacuum."**

*Sự thật (§2 hôm nay):* `relfrozenxid` không tự già đi, nhưng **XID hiện tại thì cứ tăng** theo tốc độ ghi của **toàn database**. Bảng archive 500 GB không đổi từ 2 năm trước vẫn chạm `autovacuum_freeze_max_age` sau ~11 giờ (@5.000 TPS) và bị **aggressive vacuum quét toàn bộ 500 GB**.

Và `datfrozenxid` = **min** của mọi bảng → **một bảng bị bỏ quên kéo cả database tới wraparound**.

**Bonus 4:** `n_dead_tup` **mù hoàn toàn với ROLLBACK** (Day 21 §4: bảng phình 64 lần, `n_dead_tup` báo 0) và **trễ với UPDATE** (Day 22 §1: báo 0 suốt 5 vòng trong khi `pgstattuple` báo 15,72 %). Monitoring dựa vào nó sẽ mù đúng lúc cần nhất.

---

## Bảng số liệu chính

| Kịch bản | Kết quả |
|---|---|
| 2 tỷ XID @ 1.000 / 5.000 / 50.000 TPS | **24 ngày / 4 ngày / ~10 giờ** |
| 200 triệu XID @ 5.000 TPS | **11 giờ** |
| `age(relfrozenxid)` lab | **629–648** = **0,0003 %** ngưỡng |
| `age(datfrozenxid)` lab | 1.168 = **0,00006 %** của 2 tỷ |
| `VACUUM FREEZE` bảng 50.000 dòng | `all_frozen`: **0 % → 99,3 %**; `age`: 1 → **0** |
| — log ghi | `aggressively vacuuming`, `1207 pages (99.26%) had 50000 tuples frozen` |
| — WAL sinh ra | **261.674 byte** cho bảng 9,7 MB |
| `ts_kv` (chưa freeze) | `all_frozen` = **0 / 37.698 page (0 %)** |
| Ba thứ chặn freeze trong lab | **cả ba đều sạch** (0 transaction dài, 0 slot, 0 prepared xact) |

---

## Ba điều dễ hiểu sai (tóm tắt)

| # | Hiểu nhầm | Sự thật |
|---|---|---|
| 1 | "Wraparound là vấn đề của DB chạy nhiều năm" | @50.000 TPS: **~10 giờ** tới ngưỡng dừng ghi nếu vacuum bị chặn |
| 2 | "Bảng chỉ đọc an toàn" | Nó kéo `datfrozenxid` của **cả database** xuống, và bị aggressive vacuum quét toàn bộ |
| 3 | "Autovacuum tắt thì không có gì chạy" | `autovacuum_freeze_max_age` **bắt buộc** autovacuum chạy kể cả khi `autovacuum = off` |

---

## Áp dụng vào hệ thật — 4 việc làm trong tuần này

**1. Thêm alert `xid_age` — việc quan trọng nhất của cả tuần 5.**
Dùng query §5, ngưỡng NOTICE 100 triệu. Nhớ `relkind IN ('r','m','t')` để không bỏ sót bảng TOAST.

**2. Thêm alert cho ba thứ chặn vacuum:**
```sql
-- chạy mỗi phút, alert nếu trả về > 0 dòng
SELECT 'prepared_xact' AS loai, gid AS chi_tiet FROM pg_prepared_xacts
  WHERE prepared < now() - interval '5 min'
UNION ALL
SELECT 'slot_khong_active', slot_name FROM pg_replication_slots WHERE NOT active
UNION ALL
SELECT 'transaction_dai', pid::text FROM pg_stat_activity
  WHERE backend_type='client backend' AND xact_start < now() - interval '5 min';
```

**3. Bật `idle_in_transaction_session_timeout = '5min'`** (Day 22) — một dòng, phòng được nguyên nhân số một.

**4. `VACUUM FREEZE` các bảng/partition đã "đóng băng" nghiệp vụ.**
Với hệ IoT, mọi partition của tháng trước. Làm một lần, tránh được aggressive vacuum bất ngờ mãi mãi:
```sql
VACUUM (FREEZE, ANALYZE) ts_kv_2025_07;
```

---

## Hết tuần 5

| Ngày | Câu hỏi được trả lời | Con số đắt nhất |
|---|---|---|
| 21 | MVCC hoạt động thế nào | `UPDATE SET c=c` làm bảng **và mọi index** phình **gấp đôi**; ROLLBACK phình **64×** mà `n_dead_tup` báo 0 |
| 22 | Bloat và VACUUM | VACUUM không trả byte nào **nhưng** 2 vòng UPDATE sau đó không phình thêm — **steady state**; transaction chỉ đọc làm VACUUM dọn **0 dòng** |
| 23 | Autovacuum | ngưỡng mặc định = **1.000.535 dead tuple** cho `ts_kv` → **chưa từng chạy**; `index scans > 1` là chỉ số then chốt |
| 24 | HOT & fillfactor | `fillfactor=70`: HOT **0,722**, update nhanh **2,6×**, bảng nhỏ hơn **45 %** sau 5 vòng |
| 25 | Freeze & wraparound | @50.000 TPS chỉ **~10 giờ** tới ngưỡng dừng ghi; `VACUUM FREEZE` đưa `all_frozen` 0 → **99,3 %** |

**Bài học lớn nhất của tuần 5:**

> Mọi vấn đề MVCC đều quy về **một** câu hỏi: *"có gì đang chặn vacuum không?"*
>
> Bloat, autovacuum tụt hậu, wraparound — cả ba đều có cùng nguyên nhân gốc phổ biến nhất: **một transaction / replication slot / prepared transaction bị bỏ quên**. Tăng tốc vacuum trước khi kiểm tra điều này là lãng phí thời gian.

Tuần 6 là phần **tương tranh**: isolation, lock, deadlock — tự tay tái hiện mọi anomaly bằng hai session.
