# Day 09 — Lời giải: Partial index & expression index

> Bài chữa. Đo thật trên lab `SCALE=1`. Bảng `alarm`: 200.000 dòng, **10.078 active (5,04 %)**, 33 MB.

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án | Bẫy |
|---|---|---|---|
| 1 | Partial index nhỏ hơn full bao nhiêu lần? | **11,4 lần** (208 kB vs 2.368 kB) — và **thấp hơn 1 tầng** | Đa số đoán ~20 lần (theo tỷ lệ 5 %). Thực tế ít hơn vì overhead cố định |
| 2 | `end_ts IS NULL AND severity='CRITICAL'` dùng được không? | ✅ **Có** — A∧B kéo theo A | |
| 3 | `status IN ('ACTIVE_UNACK','ACTIVE_ACK')` thì sao? | ❌ **Không** — dù tương đương về dữ liệu | Đây là bài học chính §2 |

---

## §1. Partial index

| Index | size | pages | `level` | Số tầng |
|---|---|---|---|---|
| `alarm(device_id)` đầy đủ | **2.368 kB** | 296 | **2** | 3 |
| `alarm(device_id) WHERE end_ts IS NULL` | **208 kB** | 26 | **1** | 2 |

**Nhỏ hơn 11,4 lần và thấp hơn một tầng.**

Chiều cao giảm là lợi ích ít người để ý: **mỗi lookup tiết kiệm một lần đọc page**. Với index nằm sẵn trong RAM thì không đáng kể, nhưng với index lớn không vừa cache thì đó là một lần I/O ngẫu nhiên bớt đi.

Chú ý tỷ lệ: dữ liệu chỉ 5,04 % nhưng index là 8,8 % (208/2.368). Chênh vì mỗi index vẫn có meta page, root page, và overhead cố định — **partial index không tiết kiệm tuyến tính theo % dòng**.

### Bốn lợi ích, xếp theo tầm quan trọng thực tế

1. **Ghi rẻ hơn** — quan trọng nhất, hay bị bỏ qua. `INSERT` một alarm đã đóng (`end_ts` khác NULL) thì index này **không phải cập nhật gì cả**. Với bảng 95 % dòng nằm ngoài điều kiện, đó là 95 % chi phí ghi biến mất.
2. **Nằm gọn trong cache** — 208 kB thì luôn trong `shared_buffers`, không bao giờ đọc đĩa.
3. **Cây thấp hơn** — bớt một page read mỗi lookup.
4. **VACUUM nhanh hơn** — ít entry để dọn.

Mẫu áp dụng: **bảng lớn nhưng chỉ một phần nhỏ "đang hoạt động"** — job queue, alarm đang mở, đơn chưa xử lý, session còn hạn, soft-deleted rows.

---

## §2. Điều kiện để planner chịu dùng partial index

| # | Query | Index được chọn | buffers | time | Vì sao |
|---|---|---|---|---|---|
| **Q1** | `end_ts IS NULL AND device_id=3` | **`_part`** ✅ | **64** | **0,092 ms** | trùng khớp điều kiện index |
| **Q2** | `+ severity='CRITICAL'` | **`_part`** ✅ | 61 | 0,074 ms | `A ∧ B ⟹ A` — chứng minh được |
| **Q3** | chỉ `device_id=3` | `_full` | **436** | 0,756 ms | không có `end_ts IS NULL` → không thể dùng partial |
| **Q4** | `(end_ts IS NULL OR severity='CRITICAL')` | `_full` | 436 | 0,593 ms | **`A ∨ B` KHÔNG kéo theo `A`** |
| **Q5** | `status IN ('ACTIVE_UNACK','ACTIVE_ACK')` | `_full` | 436 | 0,629 ms | tương đương dữ liệu nhưng **planner không biết** |

**Q1 vs Q3: buffers 64 vs 436 — chênh 6,8 lần.**

### Q5 — câu hỏi quan trọng nhất §2

Phân bố dữ liệu:

```
    status     | count  | số dòng có end_ts IS NULL
---------------+--------+---------------------------
 CLEARED_ACK   | 129954 |  1279      <- !!
 CLEARED_UNACK |  61247 |     0
 ACTIVE_ACK    |   5324 |  5324
 ACTIVE_UNACK  |   3475 |  3475
```

Ở đây có một điều thú vị: `status IN ('ACTIVE_UNACK','ACTIVE_ACK')` cho 8.799 dòng, còn `end_ts IS NULL` cho 10.078 dòng. **Chúng KHÔNG tương đương** — có 1.279 dòng `CLEARED_ACK` mà `end_ts` vẫn NULL (dữ liệu không nhất quán, rất giống production thật).

Nhưng dù có tương đương đi nữa, planner vẫn từ chối. Vì:

> **Bộ chứng minh của planner làm việc trên CÚ PHÁP của biểu thức, không phải trên NGỮ NGHĨA của dữ liệu.** Nó không chạy query để kiểm tra, không biết ràng buộc nghiệp vụ, không suy luận qua các cột khác nhau.

Nó xử lý được:
- ✅ `A AND B ⟹ A` (loại bỏ hạng tử)
- ✅ `x > 100 ⟹ x > 50` (so sánh hằng số **trên cùng cột**)
- ✅ `x = 5 ⟹ x IS NOT NULL`
- ✅ `x IN (1,2) ⟹ x IN (1,2,3)`

Nó **không** xử lý được:
- ❌ `A OR B ⟹ A`
- ❌ quan hệ giữa **hai cột khác nhau** (`status` và `end_ts`)
- ❌ suy luận qua `CHECK` constraint nghiệp vụ
- ❌ giá trị tham số chưa biết (§3)

**Hệ quả thực dụng: điều kiện `WHERE` của partial index phải viết CHÍNH XÁC như trong query.** Không được "tương đương". Và mọi query muốn dùng nó phải lặp lại điều kiện đó — kể cả khi ứng dụng biết chắc nó luôn đúng.

---

## §3. Bẫy tham số — kết quả tinh tế hơn README mô tả

Index: `alarm(device_id) WHERE (details->>'threshold')::int > 50`

### Thử nghiệm 1: hằng số vs tham số

```sql
-- hằng số
EXPLAIN SELECT * FROM alarm WHERE (details->>'threshold')::int > 50 AND device_id = 3;
->  Bitmap Index Scan on idx_alarm_thresh   ✅

-- tham số, chạy 7 lần liên tiếp
PREPARE p2b(int) AS SELECT * FROM alarm WHERE (details->>'threshold')::int > $1 AND device_id = 3;
EXPLAIN EXECUTE p2b(50);   -- lần 1..7
->  Bitmap Index Scan on idx_alarm_thresh   ✅  (CẢ 7 LẦN)
```

**Partial index VẪN được dùng với tham số.** Đây là điểm README nói chưa đủ chính xác.

Lý do: Postgres dùng **custom plan** cho ~5 lần đầu — lúc đó `$1` đã có giá trị thật (50), nên bộ chứng minh làm việc bình thường. Và ở đây nó **giữ custom plan mãi** vì generic plan có cost cao hơn hẳn.

### Thử nghiệm 2: ép generic plan — lúc này mới hỏng

```sql
SET plan_cache_mode = force_generic_plan;
EXPLAIN EXECUTE p2c(50);

Bitmap Heap Scan on alarm  (cost=17.72..2699.30 rows=409)
  Recheck Cond: (device_id = 3)
  Filter: (((details ->> 'threshold'::text))::integer > $1)     <<< rơi xuống Filter
  ->  Bitmap Index Scan on idx_alarm_dev_full                   <<< index KHÁC
```

Cost từ **1.218,86** lên **2.699,30** (đắt gấp 2,2 lần), partial index bị bỏ, điều kiện rơi xuống `Filter`.

### Thử nghiệm 3: bắt tận tay lúc chuyển generic plan

Với index `alarm(device_id) WHERE end_ts IS NULL`:

```
PREPARE p1(bigint) AS SELECT * FROM alarm WHERE end_ts IS NULL AND device_id = $1;

lần 1-5:  Bitmap Index Scan on idx_alarm_dev_part
          Index Cond: (device_id = '3'::bigint)      <- giá trị THẬT
          rows=60

lần 6-7:  Index Scan using idx_alarm_dev_part
          Index Cond: (device_id = $1)               <- THAM SỐ
          rows=1                                     <- ước lượng SỤP
```

**Đúng lần thứ 6, plan đổi.** Và ước lượng từ **60 dòng xuống 1 dòng** — planner mất khả năng dùng thống kê cho giá trị cụ thể, rơi về ước lượng trung bình.

Ở đây partial index vẫn được dùng (vì `end_ts IS NULL` là hằng, không phải tham số), nhưng **ước lượng sai 60 lần** — đủ để chọn sai kiểu join ở query phức tạp hơn.

### 🔧 Rủi ro thật với ORM/prepared statement

| Loại điều kiện trong partial index | An toàn với tham số? |
|---|---|
| `WHERE deleted_at IS NULL` | ✅ **An toàn** — không có tham số |
| `WHERE status = 'ACTIVE'` | ✅ an toàn — hằng số |
| `WHERE amount > 1000` | ⚠️ chỉ an toàn khi query cũng dùng **hằng số 1000** |
| `WHERE created_at > now() - interval '30 days'` | ❌ **KHÔNG TẠO ĐƯỢC** — `now()` là VOLATILE |

**Quy tắc thực dụng: điều kiện của partial index nên là bất biến và không tham số hoá — `IS NULL`, `= 'hằng'`, `<> 'hằng'`.** Đó là lý do `deleted_at IS NULL` là partial index phổ biến nhất thế giới.

Cách kiểm tra trong hệ thật:
```sql
-- xem query nào đang chạy generic plan và mất index
SET plan_cache_mode = force_generic_plan;
EXPLAIN <query của anh>;
RESET plan_cache_mode;
```
Nếu plan khác hẳn plan bình thường → anh có một quả bom hẹn giờ ở lần chạy thứ 6.

---

## §4. Partial index cho cột lệch — mẹo ngược

Phân bố `alarm.status`:

```
 CLEARED_ACK   | 129954 | 64,98 %
 CLEARED_UNACK |  61247 | 30,62 %
 ACTIVE_ACK    |   5324 |  2,66 %
 ACTIVE_UNACK  |   3475 |  1,74 %
```

Index thường trên `status` sẽ vô dụng cho `CLEARED_*` (65 % và 31 % — quá nhiều, planner chọn seq scan). Nhưng nhóm `ACTIVE%` chỉ **4,4 %** — vùng vàng của index.

```sql
CREATE INDEX idx_alarm_unack ON alarm(start_ts) WHERE status LIKE 'ACTIVE%';
```

| | |
|---|---|
| kích thước index | **216 kB** |
| kích thước bảng | 33 MB |
| **tỷ lệ** | **0,65 %** |

```
Limit  (actual time=0.017..0.047 rows=20 loops=1)
  Buffers: shared hit=21 read=3
  ->  Index Scan Backward using idx_alarm_unack on alarm  (actual rows=20)
Execution Time: 0.060 ms
```

**24 buffer, 0,060 ms. Và KHÔNG có node `Sort`.**

Index chứa `start_ts` nên `ORDER BY start_ts DESC` được phục vụ trực tiếp (đọc ngược — Day 07 §5), `LIMIT 20` dừng sau 20 dòng.

> **Partial index biến "cột lệch" từ nhược điểm thành ưu điểm. Càng lệch càng đáng — vì phần hiếm chính là phần anh hay query.**

Đây là mẫu quan trọng nhất cho **job queue**:
```sql
CREATE INDEX ON job (created_at) WHERE status = 'PENDING';
-- 99% job đã DONE -> index chỉ chứa 1%
-- SELECT ... WHERE status='PENDING' ORDER BY created_at FOR UPDATE SKIP LOCKED  (Day 28)
```

---

## §5. Expression index

| Query | Plan | buffers | time |
|---|---|---|---|
| `lower(name) = '...'` **trước khi có index** | Seq Scan, `Rows Removed: 49.999` | **1.494** | **19,41 ms** |
| `lower(name) = '...'` **sau khi có index** | **Index Scan** on `idx_dev_lower` | **3** | **0,037 ms** |
| `name = '...'` (không có hàm) | Index Scan on `idx_dev_name` | 3 | 0,042 ms |
| `upper(name) = '...'` (hàm khác) | **Seq Scan**, `Rows Removed: 49.999` | **1.494** | **16,24 ms** |

**Đúng biểu thức: nhanh 525 lần. Sai biểu thức: chậm y như không có index.**

> **Quy tắc sắt: query phải chứa biểu thức Y HỆT như lúc tạo index.** `lower(name)` ≠ `upper(name)` ≠ `name`. Không có suy luận nào cả.

Đây là nguyên nhân số một của "tôi đã tạo index rồi mà nó không dùng" trong code dùng ORM — ORM sinh `WHERE LOWER(email) = LOWER(?)` còn index tạo trên `lower(email)` thì khớp, nhưng `WHERE email ILIKE ?` thì không.

### Bẫy IMMUTABLE — và cách sửa đúng

```sql
CREATE INDEX idx_tskv_month ON ts_kv (to_char(ts, 'YYYY-MM'));
```
```
ERROR:  functions in index expression must be marked IMMUTABLE
```

**Vì sao Postgres từ chối:** index lưu **kết quả đã tính** của biểu thức. Nếu hàm có thể trả kết quả khác cho cùng đầu vào, index sẽ **âm thầm sai** — query trả thiếu dòng mà không báo lỗi gì.

`to_char(timestamptz, text)` là **STABLE**, không phải IMMUTABLE: kết quả phụ thuộc `TimeZone` và `DateStyle` của session. Cùng một `ts`, session ở Hà Nội và session ở UTC cho hai chuỗi khác nhau.

**Cách sửa mà README gợi ý vẫn KHÔNG chạy:**
```sql
CREATE INDEX ON ts_kv (to_char(ts AT TIME ZONE 'UTC', 'YYYY-MM'));
ERROR:  functions in index expression must be marked IMMUTABLE
```

Vì `to_char(timestamp, text)` — kể cả bản không timezone — **cũng là STABLE** (phụ thuộc `lc_time`). Kiểm chứng:

```sql
SELECT proname, pg_get_function_identity_arguments(oid), provolatile FROM pg_proc WHERE proname='to_char';
 to_char | timestamp without time zone, text | s   <- STABLE
 to_char | timestamp with time zone, text    | s   <- STABLE
```

**Cách sửa thật sự chạy được — dùng `date_trunc` thay vì `to_char`:**

```sql
SELECT proname, pg_get_function_identity_arguments(oid), provolatile FROM pg_proc WHERE proname='date_trunc';
 date_trunc | text, timestamp without time zone     | i   <- IMMUTABLE ✅
 date_trunc | text, timestamp with time zone        | s   <- STABLE
 date_trunc | text, timestamp with time zone, text  | i   <- IMMUTABLE ✅ (PG16+)
```

```sql
-- Cách A: ép về timestamp không timezone trước
CREATE INDEX idx_tskv_month ON ts_kv ((date_trunc('month', ts AT TIME ZONE 'UTC')));

-- Cách B (PG16+): dùng bản 3 tham số, khai timezone tường minh
CREATE INDEX idx_tskv_month ON ts_kv ((date_trunc('month', ts, 'UTC')));
```

Cả hai chạy được. Kết quả đo (cách A): index **33 MB**, và query `WHERE date_trunc('month', ts AT TIME ZONE 'UTC') = '2025-06-01'` dùng được nó.

> **Nhưng ở đây có bài học lớn hơn: index đó KHÔNG đáng tạo.** Query lấy 1.666.668 dòng (33 % bảng) — đúng vùng seq scan thắng (Day 04). Đo được 325 ms, chậm hơn cả seq scan. **Index đúng cú pháp không có nghĩa là index đúng việc.**

Cách đúng cho nhu cầu "lọc theo tháng": dùng range trên chính cột `ts` — `WHERE ts >= '2025-06-01' AND ts < '2025-07-01'` — dùng index thường, sargable, không cần expression index gì cả. Và tốt hơn nữa là partition theo tháng (Day 32).

---

## §6. Lợi ích ẩn: statistics cho biểu thức

| | Ước lượng | Thực tế | Sai số |
|---|---|---|---|
| **trước** khi có expression index | **250** | 12.445 | **sai 50 lần** |
| **sau** khi có expression index | **12.272** | 12.445 | **sai 1,4 %** |

**Sai số giảm 36 lần.**

Con số **250** trước đó không ngẫu nhiên: `50.000 dòng × 0,005` = đúng hằng số `DEFAULT_EQ_SEL` của Day 01. Planner hoàn toàn mù về `meta->>'model'`.

Sau khi tạo index, `ANALYZE` thu thập thống kê cho **chính biểu thức**:

```
 attname | n_distinct |      most_common_vals       |          most_common_freqs
---------+------------+-----------------------------+---------------------------------------
 expr    |          4 | {TH-200,PWR-5,GW-10,TH-100} | {0.2550, 0.2516, 0.2480, 0.2454}
```

Planner giờ biết chính xác: 4 model, mỗi model ~25 %. Ước lượng `0,2454 × 50.000 = 12.272`. ✓

### Hệ quả thực dụng

Đôi khi người ta tạo expression index **chỉ để có statistics**, không bao giờ dùng nó để tra cứu. Sai số ước lượng 50 lần ở node lá sẽ bị khuếch đại qua từng tầng join (Day 01 §7, Day 12).

Từ PG14 có cách rẻ hơn — thống kê mà không cần index:
```sql
CREATE STATISTICS st_dev_model ON (meta->>'model') FROM device;
ANALYZE device;
```
Không tốn dung lượng index, không làm chậm ghi. **Nếu chỉ cần sửa ước lượng chứ không cần tra cứu, luôn dùng cách này.** Day 13 đào sâu.

---

## §7. Kết hợp partial + expression — kỹ thuật đáng giá nhất tuần 2

```sql
CREATE INDEX idx_alarm_crit
  ON alarm (((details->>'threshold')::int))
  WHERE end_ts IS NULL AND severity = 'CRITICAL';
```

*(Chú ý cú pháp: biểu thức có cast cần **hai lớp ngoặc** — `(((...)::int))`. README thiếu một lớp và sẽ báo `syntax error`.)*

| | |
|---|---|
| **kích thước index** | **16 kB** |
| kích thước bảng | 33 MB |
| **tỷ lệ** | **0,048 %** |
| `level` | **0** — cây chỉ có **một page lá**, không có root riêng |

Kết quả query:

| | Có `idx_alarm_crit` | Không có (chỉ partial `end_ts IS NULL`) |
|---|---|---|
| `Index Cond` | `threshold > 80` | — |
| `Filter` | — | `severity='CRITICAL' AND threshold > 80` |
| `Rows Removed by Filter` | **0** | **10.002** |
| `Heap Blocks` | exact=**75** | exact=**3.827** |
| **buffers** | **76** | **3.852** |
| **time** | **0,099 ms** | **5,645 ms** |

**Buffers giảm 51 lần, thời gian giảm 57 lần — với một index 16 KB.**

### Vì sao đây là kỹ thuật đáng giá nhất tuần 2

Ba lý do, mỗi lý do đều đo được:

**1. Tỷ lệ lợi ích/chi phí không có gì sánh được.** 16 KB — bằng **hai page** — đổi lấy 57 lần nhanh hơn. So với các cách khác trong tuần:

| Kỹ thuật | Chi phí | Lợi ích đo được |
|---|---|---|
| Composite index (Day 07) | 194 MB | 53× |
| INCLUDE (Day 08) | 195 MB | 155× (nhưng phụ thuộc VACUUM) |
| **Partial + expression** | **16 kB** | **57×** |

**2. Chi phí ghi gần bằng không.** Index chỉ chứa 76 dòng trên 200.000. Nghĩa là **99,96 % số INSERT/UPDATE không phải đụng tới nó**. Với index thường, mọi thao tác ghi đều phải cập nhật.

**3. Nó mã hoá chính xác một câu hỏi nghiệp vụ.** *"Cảnh báo CRITICAL đang mở có ngưỡng vượt 80"* — không phải index tổng quát, mà là index cho **đúng một màn hình**. Đây là cách nghĩ đúng: index phục vụ query, không phục vụ cột.

### Cái giá phải nhớ

Index này **chỉ dùng được cho đúng hình dạng query đó**. Đổi `severity` sang `'MAJOR'` → vô dụng. Bỏ `end_ts IS NULL` → vô dụng. Đó là đánh đổi có ý thức: cực rẻ, cực nhanh, cực hẹp.

Với 5–10 màn hình quan trọng, 5–10 index kiểu này tổng cộng vài trăm KB — rẻ hơn **một** index thường.

---

## Bảng số liệu chính

| Kịch bản | index | buffers | time | ghi chú |
|---|---|---|---|---|
| §1 full index `alarm(device_id)` | 2.368 kB, level 2 | — | — | |
| §1 partial `WHERE end_ts IS NULL` | **208 kB, level 1** | — | — | nhỏ **11,4×**, thấp 1 tầng |
| §2 Q1 `end_ts IS NULL AND dev=3` | `_part` ✅ | **64** | **0,092 ms** | |
| §2 Q3 chỉ `dev=3` | `_full` | 436 | 0,756 ms | chênh **6,8×** |
| §2 Q4 `OR` | `_full` | 436 | 0,593 ms | partial bị từ chối |
| §2 Q5 `status IN (...)` | `_full` | 436 | 0,629 ms | tương đương dữ liệu, vẫn từ chối |
| §3 tham số, custom plan | `_thresh` ✅ | — | cost 1.218 | vẫn dùng được |
| §3 ép generic plan | `_full` + Filter | — | cost **2.699** | mất partial index |
| §3 lần thứ **6** | rows đoán **60 → 1** | — | — | chuyển generic plan |
| §4 partial cột lệch | **216 kB (0,65 %)** | **24** | **0,060 ms** | không có node Sort |
| §5 `lower(name)` không index | Seq Scan | 1.494 | 19,41 ms | |
| §5 `lower(name)` có index | Index Scan | **3** | **0,037 ms** | nhanh **525×** |
| §5 `upper(name)` | Seq Scan | 1.494 | 16,24 ms | sai biểu thức = vô dụng |
| §6 ước lượng trước/sau | 250 → **12.272** (thật 12.445) | — | — | sai số giảm **36×** |
| **§7 partial + expression** | **16 kB (0,048 %), level 0** | **76** | **0,099 ms** | nhanh **57×** |
| §7 không có index đó | | 3.852 | 5,645 ms | Rows Removed 10.002 |

---

## Ba điều dễ hiểu sai

| # | Hiểu nhầm | Sự thật đo được |
|---|---|---|
| 1 | "Điều kiện tương đương về dữ liệu thì planner dùng được partial index" | `status IN ('ACTIVE_*')` vs `end_ts IS NULL` — planner **từ chối**. Bộ chứng minh làm việc trên cú pháp, không trên dữ liệu |
| 2 | "Tham số hoá làm mất partial index" | **Không hẳn.** Custom plan (5 lần đầu) vẫn dùng được. Chỉ **generic plan** mới mất — cost 1.218 → 2.699 |
| 3 | "`ts AT TIME ZONE 'UTC'` là đủ để `to_char` thành IMMUTABLE" | **Sai.** `to_char(timestamp, text)` cũng STABLE (phụ thuộc `lc_time`). Phải dùng `date_trunc` |

Thêm hai điều:
- **Partial index tiết kiệm ít hơn tỷ lệ % dòng** (5 % dòng → 8,8 % kích thước) vì overhead cố định.
- **Index đúng cú pháp ≠ index đúng việc.** `idx_tskv_month` tạo được, dùng được, và **chậm hơn seq scan** vì lấy 33 % bảng.

---

## Áp dụng vào hệ thật — 3 chỗ dùng partial index

**1. Soft delete — phổ biến nhất, dùng được ở gần như mọi bảng**
```sql
CREATE INDEX CONCURRENTLY ON device (tenant_id, name) WHERE deleted_at IS NULL;
```
- % dữ liệu: **90–99 %** ban đầu, giảm dần theo thời gian
- Lợi ích thật không phải kích thước mà là **planner có thống kê đúng cho phần còn sống**
- ⚠️ Bắt buộc: **mọi query phải viết `AND deleted_at IS NULL`** — nếu ORM thêm điều kiện này tự động thì hoàn hảo

**2. Alarm/job đang mở — mẫu của lab, mang thẳng sang được**
```sql
CREATE INDEX CONCURRENTLY ON alarm (device_id, start_ts DESC) WHERE end_ts IS NULL;
CREATE INDEX CONCURRENTLY ON outbox (created_at)              WHERE published_at IS NULL;
```
- % dữ liệu: **1–5 %**
- Lợi ích: đo được **6,8× buffers**, và index nằm trọn trong RAM
- Với outbox/job queue, kết hợp `FOR UPDATE SKIP LOCKED` (Day 28)

**3. Trạng thái hiếm cần cảnh báo**
```sql
CREATE INDEX CONCURRENTLY ON device (tenant_id, updated_at)
  WHERE is_active = false;                        -- device offline: ~2%
CREATE INDEX CONCURRENTLY ON payment (created_at)
  WHERE status = 'FAILED';                        -- ~0.5%
```
- % dữ liệu: **0,5–5 %**
- Đây là chỗ "cột lệch thành ưu điểm" của §4

### Bốn quy tắc mang về

1. **Điều kiện partial index phải là hằng, không tham số hoá.** `IS NULL`, `= 'hằng'`, `<> 'hằng'`. Tránh `> $1`, tuyệt đối tránh `now()`.
2. **Mọi query phải lặp lại điều kiện đó nguyên văn** — kể cả khi biết chắc nó luôn đúng.
3. **Kiểm tra bằng `SET plan_cache_mode = force_generic_plan`** trước khi tin partial index sẽ được dùng trong code có prepared statement.
4. **Luôn `CREATE INDEX CONCURRENTLY`** trên production (Day 43 nói cái giá của nó).

Và một mẹo chẩn đoán:
```sql
-- tìm partial index đang không được dùng — thường là do query viết sai điều kiện
SELECT indexrelname, idx_scan, pg_get_indexdef(indexrelid)
FROM pg_stat_user_indexes s JOIN pg_index i USING (indexrelid)
WHERE i.indpred IS NOT NULL AND s.idx_scan < 100
ORDER BY pg_relation_size(indexrelid) DESC;
```

---

## Câu hỏi mở sang các ngày sau

1. Bảng `alarm` giờ có 5 index (9,7 MB cho bảng 33 MB). Mỗi index làm chậm INSERT bao nhiêu? → **Day 10**
2. Ước lượng sai 50 lần ở §6 — nếu nó nằm ở node lá của một join 3 bảng thì hậu quả thế nào? → **Day 12**
3. `CREATE STATISTICS ON (expression)` thay được expression index để sửa ước lượng — cách dùng? → **Day 13**
4. Lần thứ 6 chuyển generic plan, ước lượng sụp từ 60 xuống 1. Đo tận tay và phòng thế nào? → **Day 42**
5. Partial index cho job queue + `FOR UPDATE SKIP LOCKED` — dựng queue trong DB đúng cách? → **Day 28**
