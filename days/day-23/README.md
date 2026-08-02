# Day 23 — Autovacuum: mặc định là thảm hoạ với bảng lớn

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

```sql
\timing on
\o /days/day-23/output.txt
```

Lab đã bật `log_autovacuum_min_duration = 0` nên mọi lần autovacuum chạy đều vào log. Mở terminal thứ hai:
```bash
docker logs -f pgdd | grep -i vacuum
```

---

## §0. Đoán trước

1. Với bảng `ts_kv` 5 triệu dòng, autovacuum chạy sau bao nhiêu dead tuple (mặc định)?
2. Với bảng 500 triệu dòng thì sao?
3. Con số đó có hợp lý không?

Tính bằng tay trước khi đọc tiếp.

---

## §1. Autovacuum kích hoạt khi nào

### Lý thuyết

Công thức:

```
ngưỡng_vacuum = autovacuum_vacuum_threshold
              + autovacuum_vacuum_scale_factor × reltuples
```

Mặc định: `threshold = 50`, `scale_factor = 0.2` → **20% bảng**.

| Số dòng | Ngưỡng dead tuple |
|---|---|
| 1.000 | 250 |
| 100.000 | 20.050 |
| 5.000.000 | **1.000.050** |
| 500.000.000 | **100.000.050** |

Đây là chỗ mặc định sai một cách nguy hiểm: với bảng 500 triệu dòng, phải tích tụ **100 triệu dead tuple** rồi autovacuum mới đụng tới. Lúc đó bảng đã phình 20%, và lần vacuum ấy sẽ chạy rất lâu, ăn I/O nặng.

Tương tự cho ANALYZE:
```
ngưỡng_analyze = autovacuum_analyze_threshold (50)
               + autovacuum_analyze_scale_factor (0.1) × reltuples
```
→ 10% bảng. Cũng quá muộn với bảng lớn — đây là lý do statistics của bảng lớn hay bị cũ (nhắc lại tuần 3).

**Quy tắc thực chiến:** với bảng trên ~1 triệu dòng, đặt `scale_factor` nhỏ (0.01–0.02) hoặc dùng `threshold` tuyệt đối.

### Làm ngay

```sql
SELECT name, setting FROM pg_settings WHERE name LIKE 'autovacuum%' ORDER BY name;
```

Tự tính ngưỡng cho mọi bảng trong lab:
```sql
SELECT c.relname,
       c.reltuples::bigint AS so_dong,
       (current_setting('autovacuum_vacuum_threshold')::numeric
        + current_setting('autovacuum_vacuum_scale_factor')::numeric * c.reltuples)::bigint AS nguong_vacuum,
       s.n_dead_tup,
       s.last_autovacuum
FROM pg_class c JOIN pg_stat_user_tables s ON s.relid = c.oid
WHERE c.relkind='r' ORDER BY c.reltuples DESC;
```

**Ghi vào writeup:** ngưỡng của `ts_kv` là bao nhiêu? Con số đó bằng bao nhiêu % kích thước bảng tính theo dung lượng?

---

## §2. Autovacuum chạy chậm cỡ nào — cost-based delay

### Lý thuyết

Để không giết I/O của production, autovacuum tự **giới hạn tốc độ**. Nó tích luỹ "điểm chi phí" và ngủ khi vượt ngưỡng:

| GUC | Mặc định | Nghĩa |
|---|---|---|
| `vacuum_cost_page_hit` | 1 | page có trong cache |
| `vacuum_cost_page_miss` | 2 (PG14+) | page phải đọc |
| `vacuum_cost_page_dirty` | 20 | page bị làm bẩn |
| `autovacuum_vacuum_cost_limit` | −1 (dùng `vacuum_cost_limit` = 200) | điểm tích luỹ tối đa trước khi ngủ |
| `autovacuum_vacuum_cost_delay` | 2ms | ngủ bao lâu |

Ước lượng thông lượng tối đa với mặc định:
```
mỗi vòng: 200 điểm ÷ 20 (dirty) = 10 page ghi, rồi ngủ 2ms
→ ~5.000 page/giây ≈ 40 MB/s trong trường hợp xấu nhất
```

Với bảng 500GB bloat nặng, autovacuum có thể cần **nhiều ngày**. Trong lúc đó bảng tiếp tục phình — autovacuum **không bao giờ đuổi kịp**. Đây là kịch bản "vacuum không bao giờ xong" rất hay gặp.

Cách sửa: nâng `autovacuum_vacuum_cost_limit` (ví dụ 2000) và/hoặc giảm delay về 0 trên máy có I/O tốt.

### Làm ngay

```sql
SELECT name, setting, unit FROM pg_settings
WHERE name IN ('vacuum_cost_limit','vacuum_cost_delay','autovacuum_vacuum_cost_limit',
               'autovacuum_vacuum_cost_delay','autovacuum_max_workers','autovacuum_naptime');
```

**Ghi vào writeup:** tự tính thông lượng tối đa lý thuyết của autovacuum với cấu hình hiện tại (MB/s). Với bảng 100GB bloat 30%, nó cần bao lâu?

---

## §3. Quan sát autovacuum chạy thật

### Làm ngay

```sql
CREATE TABLE t_av AS SELECT id, name, tenant_id, firmware FROM device;
ALTER TABLE t_av SET (autovacuum_vacuum_scale_factor = 0.05,
                      autovacuum_vacuum_threshold   = 100,
                      autovacuum_analyze_scale_factor = 0.05);
VACUUM ANALYZE t_av;

-- tạo dead tuple vượt ngưỡng
UPDATE t_av SET firmware = firmware WHERE id % 4 = 0;

SELECT n_dead_tup, last_autovacuum FROM pg_stat_user_tables WHERE relname='t_av';
```

Chờ (autovacuum chạy mỗi `autovacuum_naptime`, mặc định 60s) rồi kiểm tra lại. Xem log ở terminal thứ hai.

Xem autovacuum đang chạy:
```sql
SELECT pid, datname, relid::regclass, phase,
       heap_blks_total, heap_blks_scanned, heap_blks_vacuumed,
       index_vacuum_count, num_dead_tuples
FROM pg_stat_progress_vacuum;
```

**Ghi vào writeup:** dán một dòng log autovacuum và **giải thích từng phần**: bao nhiêu page quét, bao nhiêu tuple dọn, bao nhiêu index pass, tốn bao lâu, đọc/ghi bao nhiêu MB/s.

---

## §4. Cấu hình per-table

### Lý thuyết

Không có một cấu hình đúng cho mọi bảng. Nguyên tắc:

| Loại bảng | Cấu hình đề xuất |
|---|---|
| Bảng lớn, ghi nhiều (`ts_kv`) | `scale_factor = 0.01`, `cost_limit` cao |
| Bảng nhỏ, update liên tục (counter, session) | `scale_factor = 0`, `threshold = 1000` |
| Bảng append-only (log) | mặc định ổn, nhưng cần freeze sớm (Day 25) |
| Bảng tra cứu ít đổi | mặc định |
| Bảng queue (insert + delete nhanh) | `scale_factor = 0.01`, autovacuum **rất** thường xuyên |

Cú pháp:
```sql
ALTER TABLE tbl SET (
  autovacuum_vacuum_scale_factor = 0.01,
  autovacuum_vacuum_threshold = 1000,
  autovacuum_analyze_scale_factor = 0.01,
  autovacuum_vacuum_cost_limit = 2000,
  autovacuum_vacuum_cost_delay = 0
);
```

Xem cấu hình đang áp:
```sql
SELECT relname, reloptions FROM pg_class WHERE reloptions IS NOT NULL;
```

### Làm ngay

```sql
ALTER TABLE ts_kv SET (autovacuum_vacuum_scale_factor = 0.01,
                       autovacuum_analyze_scale_factor = 0.01,
                       autovacuum_vacuum_cost_limit = 2000);

SELECT relname, reloptions FROM pg_class WHERE relname IN ('ts_kv','t_av');

-- ngưỡng mới là bao nhiêu?
SELECT c.relname, c.reltuples::bigint,
       (50 + 0.01 * c.reltuples)::bigint AS nguong_moi,
       (50 + 0.2  * c.reltuples)::bigint AS nguong_cu
FROM pg_class c WHERE c.relname = 'ts_kv';
```

**Ghi vào writeup:** ngưỡng mới vs cũ. Với tốc độ ghi của hệ IoT thật của bạn (bao nhiêu row/giây), autovacuum sẽ chạy mỗi bao lâu ở hai cấu hình?

---

## §5. Autovacuum worker và bảng bị bỏ quên

### Lý thuyết

`autovacuum_max_workers` (mặc định 3) giới hạn số bảng được vacuum **đồng thời**. Nếu có 50 bảng cần vacuum, chúng xếp hàng.

Vấn đề: một bảng khổng lồ chiếm một worker suốt nhiều giờ → chỉ còn 2 worker cho phần còn lại. Với database nhiều bảng, các bảng nhỏ có thể bị bỏ đói.

Cũng lưu ý: `autovacuum_max_workers` chỉ đổi được khi **restart**, và mỗi worker dùng `maintenance_work_mem` riêng — nên tăng cả hai cùng lúc phải tính RAM.

Bảng tạm (`TEMP`) **không bao giờ** được autovacuum — phải tự `VACUUM`.

### Làm ngay

```sql
SHOW autovacuum_max_workers;
SHOW maintenance_work_mem;

-- ai đang chạy autovacuum ngay lúc này
SELECT pid, now()-xact_start AS chay_duoc, left(query,80) AS query
FROM pg_stat_activity WHERE query LIKE 'autovacuum:%';

-- bảng lâu chưa được vacuum nhất
SELECT relname, last_autovacuum, last_autoanalyze, n_dead_tup,
       pg_size_pretty(pg_relation_size(relid)) AS size
FROM pg_stat_user_tables
ORDER BY last_autovacuum NULLS FIRST LIMIT 10;
```

**Ghi vào writeup:** worker × `maintenance_work_mem` = bao nhiêu RAM tối đa? Bảng nào lâu nhất chưa được vacuum?

---

## §6. Khi autovacuum không đuổi kịp

### Lý thuyết

Dấu hiệu:
- `n_dead_tup` tăng đều dù autovacuum vẫn chạy
- `last_autovacuum` luôn cách đây rất lâu trên bảng nóng
- `pg_stat_progress_vacuum` cho thấy vacuum chạy hàng giờ
- Bảng phình liên tục

Xử lý theo thứ tự:
1. Kiểm tra **transaction dài** đang chặn (Day 22 §6) — đây là nguyên nhân số 1
2. Nâng `autovacuum_vacuum_cost_limit`, giảm `cost_delay` về 0
3. Giảm `scale_factor` cho bảng đó
4. Tăng `maintenance_work_mem` (giúp giảm số lượt quét index)
5. Chạy `VACUUM` thủ công vào giờ thấp điểm
6. Nếu đã bloat nặng: `pg_repack`
7. Xem lại thiết kế: bảng này có nên partition không?

### Làm ngay

Mô phỏng autovacuum không đuổi kịp:
```sql
ALTER TABLE t_av SET (autovacuum_vacuum_cost_delay = 100);   -- cố tình làm chậm
UPDATE t_av SET firmware = firmware;
UPDATE t_av SET firmware = firmware;
UPDATE t_av SET firmware = firmware;

SELECT n_dead_tup, n_live_tup, last_autovacuum,
       pg_size_pretty(pg_relation_size('t_av')) FROM pg_stat_user_tables WHERE relname='t_av';
```
Chờ 1-2 phút, đo lại. Rồi sửa:
```sql
ALTER TABLE t_av SET (autovacuum_vacuum_cost_delay = 0, autovacuum_vacuum_cost_limit = 5000);
VACUUM t_av;
SELECT n_dead_tup, pg_size_pretty(pg_relation_size('t_av')) FROM pg_stat_user_tables WHERE relname='t_av';
```

**Ghi vào writeup:** với `cost_delay = 100ms`, autovacuum có theo kịp không? Sau khi sửa thì sao?

```sql
DROP TABLE t_av;
```

---

## §7. Cấu hình bạn sẽ mang về production

### Làm ngay

Viết script sinh câu lệnh `ALTER TABLE` cho mọi bảng lớn:

```sql
SELECT format(
  'ALTER TABLE %I SET (autovacuum_vacuum_scale_factor = %s, autovacuum_analyze_scale_factor = %s, autovacuum_vacuum_cost_limit = 2000);',
  relname,
  CASE WHEN reltuples > 50000000 THEN '0.005'
       WHEN reltuples > 5000000  THEN '0.01'
       WHEN reltuples > 500000   THEN '0.05'
       ELSE '0.1' END,
  CASE WHEN reltuples > 5000000 THEN '0.01' ELSE '0.05' END
) AS cau_lenh
FROM pg_class WHERE relkind='r' AND reltuples > 100000
  AND relnamespace = 'public'::regnamespace;
```

**Ghi vào writeup:** script sinh ra gì cho lab của bạn? Bạn có đồng ý với các ngưỡng đó không, sửa gì?

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B. Áp dụng vào hệ thật:** chạy query ở §1 và §5 trên DB production. Bảng nào đang dùng ngưỡng mặc định mà không nên? Viết ra bộ `ALTER TABLE` bạn sẽ áp, kèm lý do cho từng bảng.

### Đạt khi

Bạn tính được ngưỡng autovacuum và thông lượng của nó bằng tay, đọc được log autovacuum, và biết chính xác phải chỉnh gì khi nó không đuổi kịp.

**Xong thì gõ `/review-bai`.**
