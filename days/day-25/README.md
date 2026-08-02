# Day 25 — Freeze, XID wraparound + ôn tuần 5

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

```sql
\timing on
\o /days/day-25/output.txt
```

---

## §0. Đoán trước

1. XID là 32 bit. Với hệ ghi 5.000 transaction/giây, bao lâu thì hết XID?
2. Chuyện gì xảy ra khi sắp hết?
3. Bảng **chỉ đọc**, không bao giờ update — có cần vacuum không?

---

## §1. XID chỉ có 32 bit

### Lý thuyết

Transaction ID là số nguyên **32 bit không dấu** → 4.294.967.296 giá trị. Postgres so sánh XID theo **modulo**: từ góc nhìn của một transaction, 2 tỷ XID phía trước là "tương lai", 2 tỷ phía sau là "quá khứ".

Vấn đề: nếu một tuple có `xmin` cũ hơn 2 tỷ transaction, nó đột nhiên bị coi là **thuộc về tương lai** → **biến mất** khỏi mọi query. Mất dữ liệu âm thầm.

Với hệ ghi 5.000 TPS: `2^31 / 5000 ≈ 429.000 giây ≈ 5 ngày`. Nghĩa là **hệ tải cao có thể chạm ngưỡng trong vòng một tuần** nếu vacuum không chạy.

### Làm ngay

```sql
SELECT txid_current();

-- tự tính
SELECT 2147483648::bigint / 5000 / 3600 AS gio_neu_5000_tps,
       2147483648::bigint / 50000 / 3600 AS gio_neu_50000_tps;
```

**Ghi vào writeup:** với tốc độ ghi thật của hệ bạn (ước lượng TPS), bao lâu thì hết 2 tỷ XID?

---

## §2. Freeze — lời giải

### Lý thuyết

Giải pháp là **freeze**: đánh dấu tuple là "cũ hơn mọi thứ, luôn hiển thị", tách nó khỏi hệ thống XID.

Cơ chế: VACUUM đặt bit `HEAP_XMIN_FROZEN` trong header tuple. Từ đó `xmin` không còn được so sánh nữa.

Các tham số:

| GUC | Mặc định | Nghĩa |
|---|---|---|
| `vacuum_freeze_min_age` | 50 triệu | tuple cũ hơn ngần này XID thì freeze khi gặp |
| `vacuum_freeze_table_age` | 150 triệu | bảng già hơn ngần này → vacuum **quét toàn bộ** (aggressive) |
| `autovacuum_freeze_max_age` | 200 triệu | **bắt buộc** autovacuum chạy, kể cả khi autovacuum đã tắt |
| `vacuum_failsafe_age` | 1,6 tỷ | bỏ qua cost delay, chạy hết tốc lực |

`relfrozenxid` của mỗi bảng = XID cũ nhất chưa được freeze. `age(relfrozenxid)` = khoảng cách tới hiện tại.

**Điểm rất quan trọng:** `autovacuum_freeze_max_age` áp dụng **kể cả với bảng chỉ đọc**. Một bảng archive không bao giờ đổi vẫn cần được vacuum để freeze — nếu không, nó sẽ kéo cả database tới wraparound.

Đây là câu trả lời cho câu hỏi §0.3: **có, bảng chỉ đọc vẫn cần vacuum.**

### Làm ngay

```sql
SELECT name, setting FROM pg_settings WHERE name LIKE '%freeze%' ORDER BY name;

SELECT relname,
       age(relfrozenxid) AS tuoi,
       round(100.0 * age(relfrozenxid) / current_setting('autovacuum_freeze_max_age')::numeric, 2) AS pct_toi_nguong,
       pg_size_pretty(pg_relation_size(oid)) AS size
FROM pg_class WHERE relkind = 'r' AND relnamespace='public'::regnamespace
ORDER BY age(relfrozenxid) DESC;

SELECT datname, age(datfrozenxid),
       round(100.0*age(datfrozenxid)/2000000000, 3) AS pct_toi_2ty
FROM pg_database ORDER BY 2 DESC;
```

**Ghi vào writeup:** bảng nào có `age` cao nhất, đang ở bao nhiêu % ngưỡng? Database ở bao nhiêu % của 2 tỷ?

---

## §3. Aggressive vacuum

### Lý thuyết

VACUUM thường **bỏ qua** page đã `all-frozen` trong visibility map — rất nhanh.

Nhưng khi `age(relfrozenxid) > vacuum_freeze_table_age`, VACUUM chuyển sang chế độ **aggressive**: quét **mọi page**, kể cả đã frozen. Với bảng 500GB đó là một lượt đọc toàn bộ.

Đây là nguồn của sự cố kinh điển: *"database đột nhiên chậm hẳn vào 3 giờ sáng, I/O đầy, không ai deploy gì cả"* — đó là aggressive autovacuum khởi động trên bảng lớn.

Cách phòng: freeze **dần dần** thay vì để dồn — hạ `vacuum_freeze_min_age` để tuple được freeze sớm trong các lần vacuum thường.

### Làm ngay

```sql
CREATE TABLE t_frz AS SELECT * FROM device;
VACUUM (VERBOSE, FREEZE) t_frz;
```
Đọc output — nó ghi rõ bao nhiêu tuple được freeze.

```sql
SELECT relname, age(relfrozenxid) FROM pg_class WHERE relname='t_frz';

SELECT count(*) FILTER (WHERE all_frozen) AS frozen_pages,
       count(*) AS total_pages
FROM pg_visibility('t_frz');
```

So với bảng chưa freeze:
```sql
SELECT count(*) FILTER (WHERE all_frozen) AS frozen, count(*) AS total
FROM pg_visibility('ts_kv');
```

**Ghi vào writeup:** sau `VACUUM FREEZE`, bao nhiêu % page là `all_frozen`? `age(relfrozenxid)` bằng bao nhiêu?

---

## §4. Chuyện gì xảy ra khi tới ngưỡng

### Lý thuyết

Postgres cảnh báo và bảo vệ theo bậc:

| `age(datfrozenxid)` | Hành vi |
|---|---|
| > 200 triệu | autovacuum khởi động chế độ chống-wraparound, **không thể tắt** |
| > 1,6 tỷ | failsafe: bỏ qua cost delay, bỏ qua dọn index, chạy hết tốc lực |
| > ~2,1 tỷ − 10 triệu | **WARNING** trong log mỗi lần cấp XID |
| ~2,1 tỷ | **DỪNG NHẬN GHI.** Database chỉ đọc. Phải vào single-user mode để vacuum |

Bậc cuối là sự cố tê liệt hoàn toàn — và cách khắc phục (single-user mode + `VACUUM FULL`) có thể mất **nhiều giờ tới nhiều ngày** với DB lớn.

Các postmortem công khai đáng đọc: **Sentry (2015)**, **Mailchimp (2019)**, **Joyent (2015)**. Cả ba đều là dịch vụ lớn, đều mất nhiều giờ downtime.

Nguyên nhân gốc trong hầu hết các ca đều giống nhau:
1. Một transaction mở rất lâu (hoặc replication slot bị bỏ quên, hoặc prepared transaction treo) chặn vacuum
2. Không ai monitor `age(relfrozenxid)`
3. Phát hiện khi đã quá muộn

### Làm ngay

Kiểm tra ba thứ hay chặn freeze:
```sql
-- 1. transaction dài
SELECT pid, now()-xact_start AS tuoi, state, left(query,60)
FROM pg_stat_activity WHERE xact_start IS NOT NULL ORDER BY xact_start LIMIT 5;

-- 2. replication slot bị bỏ quên (giữ WAL và chặn vacuum)
SELECT slot_name, active, restart_lsn,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_giu_lai
FROM pg_replication_slots;

-- 3. prepared transaction treo (two-phase commit chưa hoàn tất)
SELECT * FROM pg_prepared_xacts;
```

**Ghi vào writeup:** ba query này trả về gì trong lab? **Trên production, cái nào bạn chưa từng kiểm tra?**

> Lưu ý cho bạn: hệ của bạn dùng **Temporal + outbox pattern**. Nếu có bug khiến transaction outbox không commit/rollback, nó sẽ chặn vacuum toàn database. Đây là rủi ro thật, không lý thuyết.

---

## §5. Viết monitoring

### Làm ngay

Viết query cảnh báo hoàn chỉnh — thứ bạn sẽ đưa vào Grafana/alert:

```sql
SELECT
  c.relname,
  age(c.relfrozenxid) AS xid_age,
  round(100.0 * age(c.relfrozenxid)
        / current_setting('autovacuum_freeze_max_age')::numeric, 1) AS pct_freeze_max,
  round(100.0 * age(c.relfrozenxid) / 2100000000.0, 3) AS pct_shutdown,
  pg_size_pretty(pg_total_relation_size(c.oid)) AS size,
  s.last_autovacuum,
  CASE
    WHEN age(c.relfrozenxid) > 1500000000 THEN 'CRITICAL'
    WHEN age(c.relfrozenxid) > current_setting('autovacuum_freeze_max_age')::numeric THEN 'WARNING'
    WHEN age(c.relfrozenxid) > current_setting('autovacuum_freeze_max_age')::numeric * 0.75 THEN 'NOTICE'
    ELSE 'OK'
  END AS muc_do
FROM pg_class c
LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
WHERE c.relkind IN ('r','m','t')
ORDER BY age(c.relfrozenxid) DESC
LIMIT 20;
```

**Ghi vào writeup:** dán kết quả. Ngưỡng cảnh báo bạn sẽ đặt là bao nhiêu, và **bạn sẽ làm gì khi alert kêu?** Viết runbook 5 bước.

---

## §6. Đọc một postmortem thật

### Làm ngay

Đọc một trong ba postmortem sau (tìm trên Google):
- "Sentry postgres transaction id wraparound"
- "Mailchimp postgres wraparound outage"
- "Joyent Manta postgres wraparound"

**Ghi vào writeup:** tóm tắt 5 gạch đầu dòng — nguyên nhân gốc, vì sao không phát hiện sớm, mất bao lâu để khắc phục, họ đổi gì sau đó, và **điều nào áp dụng được cho hệ của bạn**.

```sql
DROP TABLE t_frz;
```

---

## §7. Ôn tuần 5

**Viết vào `writeup.md`:**

**A. Sơ đồ vòng đời một dòng dữ liệu** — từ INSERT → UPDATE → dead tuple → VACUUM → freeze. Vẽ bằng chữ, chỉ rõ ở mỗi bước cái gì đổi (xmin/xmax/ctid/VM bit/kích thước).

**B. Năm chỉ số MVCC lên dashboard**, mỗi cái kèm: query lấy số, ngưỡng cảnh báo, và **hành động khi vượt ngưỡng**.

**C. Ba điều tôi tưởng đúng mà hoá ra sai trong tuần 5.**

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?** Đặc biệt câu 3 — bảng chỉ đọc có cần vacuum không?

**B. Áp dụng vào hệ thật:** chạy query monitoring ở §5 trên production. Bảng nào `age` cao nhất? Bạn có replication slot nào không hoạt động không? Có prepared transaction treo không? Nếu chưa có alert cho `xid_age`, đây là việc bạn làm trong tuần này.

### Đạt khi

Bạn giải thích được wraparound bằng cơ chế (32 bit, so sánh modulo, freeze), có query monitoring dùng được ngay, và biết ba thứ hay chặn vacuum.

**Xong thì gõ `/review-bai`.**

---

## Hết tuần 5

Bạn giờ hiểu tầng lưu trữ và vòng đời dữ liệu. Tuần 6 là phần **tương tranh**: isolation, lock, deadlock — tự tay tái hiện mọi anomaly bằng hai session.
