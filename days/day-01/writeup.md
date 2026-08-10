# Day 01 — Postgres làm gì với câu SQL của bạn

## §0. Đoán trước khi chạy
<!-- Viết TRƯỚC khi chạy lệnh nào. Sai cũng để nguyên, KHÔNG sửa lại sau. -->

1. Planner ước lượng `WHERE device_id = 42` ra bao nhiêu dòng? → **đoán:**
   Thực tế bao nhiêu dòng? → **đoán:**
2. `pg_class.reltuples` của `ts_kv` lúc này bằng bao nhiêu? → **đoán:**
3. `SELECT count(*) FROM ts_kv` mất bao nhiêu ms? → **đoán:**

---

## §1. Bốn giai đoạn của một câu query

| Query | Planning Time (ms) | Execution Time (ms) | Cái nào lớn hơn? | Tỷ lệ plan/exec |
|---|---|---|---|---|
| `count(*) FROM ts_kv WHERE device_id = 42` | 0.074 | 194.032 | Execution | 0.04 % |
| `SELECT * FROM tenant WHERE id = 1` | 0.041 | 0.023 | **Planning** | 178 % |

**Ghi:** query nào có `Planning Time` > `Execution Time`? Với query siêu nhẹ chạy hàng triệu lần/ngày thì chi phí lập kế hoạch gợi ý điều gì (prepared statement / plan cache)?

> `SELECT * FROM tenant WHERE id = 1` — plan 0.041 ms > exec 0.023 ms, tức **~64 % tổng thời gian là để lập kế hoạch**, chỉ 36 % là làm việc thật. Với `ts_kv` thì ngược lại: plan chỉ chiếm 0.04 %, coi như miễn phí.
>
> Ý nghĩa: chi phí planning gần như **cố định theo độ phức tạp câu SQL**, không theo lượng dữ liệu. Nên nó chỉ đáng lo với query siêu nhẹ chạy tần suất cao (lookup theo PK — đúng kiểu 90 % traffic của một service CRUD). Chạy 1 triệu lần/ngày thì riêng planning đã tốn ~41 s CPU cho việc không tạo ra dữ liệu nào.
>
> → Đó là lý do tồn tại **prepared statement** (`PREPARE`/`EXECUTE`, JDBC `PreparedStatement`, pgx statement cache): parse + plan một lần, tái dùng plan cho các lần sau. Postgres giữ plan trong session, sau 5 lần chạy sẽ cân nhắc chuyển sang **generic plan** (bỏ hẳn bước plan). Hệ quả cần nhớ cho các ngày sau: generic plan không thấy giá trị tham số thật → mất khả năng dùng MCV/histogram, có thể chọn plan tệ hơn. Đánh đổi: tiết kiệm planning ↔ mất độ chính xác selectivity.
>
> Triệu chứng ngoài đời của cái bẫy này: *query nhanh vài lần đầu rồi tự nhiên chậm hẳn, restart app lại nhanh* — đúng lúc nó nhảy sang generic plan. Ép tắt bằng `plan_cache_mode = force_custom_plan`.
>
> Lưu ý về pooler: PgBouncer ở **transaction/statement mode** trước đây làm prepared statement không sống qua transaction → mất lợi ích. Từ PgBouncer 1.21 đã hỗ trợ protocol-level prepared statement qua `max_prepared_statements`, nên chỉ mất nếu dùng bản cũ hoặc chưa bật option đó.

### Diễn giải lại bằng lời của tôi

**Mục tiêu §1 gói trong 1 câu:** SQL phải qua 4 bước `PARSE → REWRITE → PLAN → EXECUTE`, và bước sống chết là **PLAN**.

- PARSE / REWRITE: máy móc, tất định, cùng SQL luôn ra cùng kết quả → không có gì để tune.
- **PLAN: đây là bước *phỏng đoán*.** Postgres tự quyết quét cả bảng hay dùng index, join kiểu gì — mà **không nhìn dữ liệu thật**, chỉ nhìn một bản thống kê cũ. Đoán sai → chọn nhầm cách → 5 ms thành 5 s **dù code không đổi một chữ**.
- EXECUTE: chỉ thi hành cái PLAN đã chọn. Execute chậm là **triệu chứng**, gốc bệnh ở PLAN.

→ Mọi ca "hôm qua nhanh, hôm nay chậm, không ai deploy gì" không phải bug code, mà là **planner đổi ý**.

**"Nghĩ" vs "làm":**

| | ts_kv (5 triệu dòng) | tenant (vài dòng) |
|---|---|---|
| Planning ("nghĩ") | 0.074 ms | 0.041 ms ← gần như y hệt |
| Execution ("làm") | 194 ms | 0.023 ms ← lệch ~8000 lần |

Thời gian **nghĩ gần như không đổi**; thời gian **làm** mới nhảy theo lượng dữ liệu. Nên nghĩ chỉ thành gánh nặng ở query bé tí chạy cực nhiều (0.041 ms × 1 triệu lần = 41 s CPU/ngày cho việc không tạo ra dữ liệu nào).

### Cái bẫy generic plan — câu chuyện dễ nhớ

**Tình huống.** Bảng `ts_kv` 5 triệu dòng. App chạy câu:

```sql
SELECT * FROM ts_kv WHERE device_id = ?
```

Mỗi lần chạy, Postgres phải **nghĩ trước khi làm**: "quét cả bảng, hay dùng index?" Việc nghĩ đó tốn 0.04 ms. Việc làm tốn tuỳ tình huống.

**Vấn đề.** Nghĩ đi nghĩ lại cùng một câu hỏi 1 triệu lần/ngày thì phí. Nên Postgres đề nghị: *"để tao nghĩ 1 lần rồi nhớ luôn câu trả lời, lần sau khỏi nghĩ."* Đó là **prepared statement**.

**Cái bẫy.** Ghi nhớ được thì phải nhớ câu trả lời **chung**, không gắn với `?` cụ thể. Mà câu trả lời đúng lại **phụ thuộc vào `?`**:

| `?` truyền vào | Số dòng khớp | Cách làm đúng |
|---|---|---|
| `device_id = 42` | 100.000 dòng | Quét cả bảng (nhiều quá, index vô ích) |
| `device_id = 777` | 3 dòng | Dùng index (nhảy thẳng vào) |

Hai giá trị, hai cách làm **ngược nhau**. Nhưng plan đã nhớ sẵn thì chỉ có **một** cách. Chọn cách nào cũng sai một nửa số trường hợp.

**Vậy Postgres xử sao?** Nó thoả hiệp: 5 lần đầu cứ nghĩ lại tử tế (custom plan — nhìn `?` thật). Từ lần thứ 6, nếu thấy "chắc lần nào cũng na ná nhau" thì nó dùng plan nhớ sẵn (generic plan).

→ Nên mới có hiện tượng: **5 lần đầu nhanh, từ lần 6 chậm. Restart app thì đếm lại từ 0, nhanh trở lại.** Rất giống bug ma, thực ra là cơ chế này. Ép tắt bằng `plan_cache_mode = force_custom_plan`.

**Đánh đổi cuối cùng:** tiết kiệm 0.041 ms planning ↔ rủi ro chọn nhầm plan tốn 200 ms.

**3 ý phải nắm để qua §1:**
1. Kể được 4 bước, và PLAN là bước đoán mò.
2. Query chậm đột ngột thường là lỗi ở PLAN, không phải code.
3. Planning tốn theo **độ phức tạp SQL**, không theo **số dòng**.

---

## §2. Planner biết gì về bảng của bạn

### Kiến thức cần nắm

**Câu hỏi gốc:** planner phải quyết "quét cả bảng hay dùng index" — mà nó **không được phép nhìn dữ liệu thật** (nhìn thì đã bằng chạy query rồi, còn gì để tiết kiệm). Vậy nó dựa vào đâu? → Dựa vào **một bản tóm tắt thống kê lấy mẫu định kỳ**, nằm trong catalog.

**Hai nguồn duy nhất:**

| Nguồn | Cấp | Chứa gì | Trả lời câu hỏi |
|---|---|---|---|
| `pg_class` | **bảng** | `relpages` (số page 8KB), `reltuples` (số dòng) | "Bảng này to cỡ nào?" |
| `pg_statistic` (xem qua **`pg_stats`**) | **cột** | `null_frac`, `n_distinct`, `most_common_vals/freqs`, `histogram_bounds`, `correlation` | "Điều kiện `WHERE` này lọc còn bao nhiêu %?" |

Ánh xạ thẳng vào công thức §3:

```
rows ước lượng  =  reltuples (pg_class)  ×  selectivity (pg_statistic)
                        ↑ tầng 1                ↑ tầng 2
```

→ **Hai tầng sai ở §3 chính là hai nguồn này.** Tầng 1 hỏng vì `pg_class` chưa cập nhật; tầng 2 hỏng vì `pg_statistic` chưa tồn tại.

---

**Điều quan trọng nhất §2: hai bảng này KHÔNG cập nhật realtime.**

Bạn `INSERT` 5 triệu dòng xong, `pg_class` vẫn nói bảng rỗng. Chỉ có **hai** thứ cập nhật chúng:

1. **`ANALYZE`** gõ tay — chạy ngay lập tức.
2. **autovacuum** — tiến trình nền, **chỉ chạy khi thay đổi vượt ngưỡng**:
   ```
   ngưỡng = autovacuum_analyze_threshold (50) + autovacuum_analyze_scale_factor (0.1) × số dòng
          ≈ 10 % bảng + 50 dòng
   ```
   Với bảng 5 triệu dòng: phải thay đổi ~500.000 dòng nó mới thèm chạy. Và chạy xong còn phải chờ chu kỳ (`autovacuum_naptime`, mặc định 60 s).

> **Đây là nguồn gốc của mọi ca "query đột nhiên chậm dù không đổi code".** Dữ liệu đã đổi, thống kê thì chưa.

Lab này **cố ý tắt autovacuum** trong seed (`autovacuum_enabled = false`) để bạn kịp quan sát trạng thái "planner chưa biết gì". Nếu để bật, sau ~30 s nó tự chạy và bạn mất cơ hội thấy.

---

**`reltuples = -1` — giá trị đặc biệt cần phân biệt:**

| Giá trị | Nghĩa |
|---|---|
| **`-1`** | **Chưa từng được đo** (chưa ANALYZE/VACUUM lần nào). Từ PG14. |
| `0` | **Đã đo rồi, bảng thật sự rỗng.** |

Khác nhau hoàn toàn. Gặp `-1`, planner không chịu thua — nó **suy ngược số dòng từ kích thước file thật trên đĩa**:

```
số page thật (đọc từ file, LUÔN ĐÚNG)  ×  số dòng nhét vừa 1 page (PHẢI ĐOÁN theo kiểu dữ liệu cột)
```

Đó chính là chỗ tầng 1 sai 31 % ở §3: nó biết chắc 36.959 page, nhưng đoán mỗi page chứa 93 dòng trong khi thật là 135.

---

**`relpages` vs kích thước file thật — vì sao một cái đúng, cái kia không:**

| | Nguồn | Có bị cũ không? |
|---|---|---|
| `pg_class.relpages` | catalog, chỉ đổi khi ANALYZE/VACUUM | **Có** — chưa ANALYZE thì thường là `0` |
| `pg_relation_size(oid)/8192` | **đo file thật ngay lúc gọi** | Không, luôn đúng |

Điểm tinh tế: **lúc lập kế hoạch, planner KHÔNG tin `relpages` trong catalog** — nó gọi hệ điều hành hỏi số block thật, rồi dùng tỷ lệ `relpages`/`reltuples` cũ để nội suy ra số dòng hiện tại. Nên số page nó dùng luôn tươi; chỉ có **mật độ dòng/page** là đồ cũ.

→ Rút ra: **kích thước bảng planner luôn nắm đúng. Cái nó mù là NỘI DUNG bên trong.**

---

**Khi không có `pg_statistic`, planner dùng hằng số cắm cứng trong source** (`selfuncs.h`):

| Điều kiện | Selectivity mặc định | Tên hằng số |
|---|---|---|
| `col = ?` | **0.5 %** | `DEFAULT_EQ_SEL` |
| `col > ?` / `col < ?` | **33 %** | `DEFAULT_INEQ_SEL` |
| `col BETWEEN ? AND ?` | 0.5 % | `DEFAULT_RANGE_INEQ_SEL` |
| số giá trị phân biệt (khi mù tịt) | 200 | `DEFAULT_NUM_DISTINCT` |

Không liên quan gì tới dữ liệu của bạn. Cột nào, bảng nào, giá trị nào cũng y hệt. Đây là thủ phạm chính của sai số ở §3.

---

**`pg_stat_user_tables` — bảng để chẩn đoán:**

| Cột | Cho biết |
|---|---|
| `last_analyze` | lần cuối **có người gõ tay** `ANALYZE` |
| `last_autoanalyze` | lần cuối **autovacuum tự chạy** |
| `n_live_tup` | số dòng ước tính hiện tại (cập nhật liên tục hơn `reltuples`) |

**Cả hai cột `last_*` đều `NULL` = thống kê chưa từng tồn tại → planner đang bay mù.** Đây là câu lệnh đầu tiên nên gõ khi gặp query chậm bí ẩn trên production.

### 3 ý phải nắm để qua §2

1. Planner chỉ biết bảng qua **`pg_class`** (cấp bảng) + **`pg_statistic`** (cấp cột) — không nhìn dữ liệu thật.
2. Hai nguồn đó **cập nhật trễ**, do `ANALYZE` hoặc autovacuum (ngưỡng ~10 % bảng) — không phải realtime theo INSERT.
3. `reltuples = -1` ≠ `0`. Thiếu thống kê cột thì planner rơi về **hằng số 0.5 %** cho `col = ?`.

### Số liệu đo được

| relname | relpages (planner tin) | reltuples | size thật | pages_that (thật) |
|---|---|---|---|---|
| ts_kv | *(suy từ cost §3: **36.959**, chờ kiểm chứng)* | *(dự kiến **-1**)* |  |  |
| device |  |  |  |  |
| alarm |  |  |  |  |

`pg_stat_user_tables` cho `ts_kv`:

| last_analyze | last_autoanalyze | n_live_tup |
|---|---|---|
|  |  |  |

**Ghi:**
- `reltuples` = ? Ý nghĩa của giá trị đó:
- `relpages` có khớp `pages_that` không, vì sao một cái đúng một cái không?
- `last_analyze` / `last_autoanalyze` cho biết điều gì về bảng này?

>

---

## §3. Ước lượng khi chưa có statistics — phép tính ngược

### Lần chạy 1 — QUÊN tắt song song (giữ lại làm bài học)

```
Finalize Aggregate  (cost=55877.65..55877.66 rows=1 width=8) (actual time=172.142..176.150 rows=1 loops=1)
  ->  Gather  (cost=55877.43..55877.64 rows=2 width=8) (actual time=172.058..176.143 rows=3 loops=1)
        Workers Planned: 2
        Workers Launched: 2
        ->  Partial Aggregate  (cost=54877.43..54877.44 rows=1 width=8) (actual time=169.682..169.683 rows=1 loops=3)
              ->  Parallel Seq Scan on ts_kv  (cost=0.00..54859.53 rows=7160 width=0) (actual time=0.074..169.452 rows=1244 loops=3)
                    Filter: (device_id = 42)
                    Rows Removed by Filter: 1665423
Planning Time: 0.048 ms / Execution Time: 176.175 ms
```

-- SAI: quên `SET max_parallel_workers_per_gather = 0` → dính bẫy `loops=3`.

**Bẫy đọc EXPLAIN quan trọng nhất:** dưới node `Gather`, mọi `rows` (cả đoán lẫn thực tế) là **trung bình MỖI worker**, không phải tổng.

| | mỗi worker | tổng |
|---|---|---|
| planner đoán | 7.160 | ~19.300 |
| thực tế | 1.244 | ~3.732 |

> **Quy tắc cho cả 40 ngày: thấy `loops=N` với N > 1 thì mọi `rows` trên node đó phải nhân với N.**

Chi tiết đáng nhớ:
- `Gather rows=2` (đoán) nhưng `actual rows=3` → vì **leader cũng nhảy vào quét cùng**, không ngồi chờ. 3 tiến trình → 3 kết quả con.
- Nhưng khi *tính cost*, leader chỉ được tính đóng góp 0,7 → hệ số chia là **2,7 chứ không phải 3**. Khó chịu: **actual chia 3, cost chia 2,7.**
- Gather − Partial Aggregate = 55877.43 − 54877.43 = **đúng 1000.0** = `parallel_setup_cost`. Phí dựng worker là hằng số 1000 → lý do Postgres không song song hoá query nhỏ.
- Trong Gather: 55877.64 − 55877.43 = 0.21 ≈ 2 dòng × `parallel_tuple_cost` 0.1.
- `Partial Aggregate` có startup = total = 169.68 → **node chặn**: phải đọc hết mới đếm xong. Còn `Seq Scan` startup 0.074 → **streaming**, trả dòng đầu ngay. (Ý §6.)

### Lần chạy 2 — đã tắt song song, `loops=1`

```
Aggregate  (cost=79964.64..79964.65 rows=1 width=8) (actual time=345.282..345.283 rows=1 loops=1)
  ->  Seq Scan on ts_kv  (cost=0.00..79921.68 rows=17185 width=0) (actual time=0.056..344.810 rows=3731 loops=1)
        Filter: (device_id = 42)
        Rows Removed by Filter: 4996269
Planning Time: 0.047 ms / Execution Time: 345.307 ms
```

**Xác nhận quét toàn bảng:** `3.731 khớp + 4.996.269 bị loại = 5.000.000` chẵn tuyệt đối. Filter vứt **99,925 %** số dòng đọc lên — hình dạng của query đang gào đòi index (tuần 2).

| | giá trị |
|---|---|
| `rows` (planner đoán) | **17.185** |
| `actual rows` (sự thật) | **3.731** |
| tỷ lệ lệch | **đoán thừa 4,6 lần** |
| `rows` ÷ 0.005 = planner nghĩ bảng có bao nhiêu dòng | **3.437.000** |
| lệch với 5.000.000 thật | **thiếu 31,3 %** |

**Ghi:** phần lệch đến từ tầng nào — ước lượng **số dòng của bảng**, hay **selectivity 0.5%**, hay cả hai? Bằng chứng nào cho thấy vậy?

> Bóc tách được **cả hai tầng đều sai, nhưng ngược chiều nhau**:
>
> | Tầng | Planner tin | Sự thật | Sai |
> |---|---|---|---|
> | ① số dòng bảng | 3.437.000 | 5.000.000 | **thiếu 31 %** |
> | ② selectivity | 0,5 % (hằng số cắm cứng) | 3731/5tr = **0,0746 %** | **thừa 6,7 lần** |
>
> Kiểm chứng: 6,7 × 0,687 ≈ **4,6 lần** — khớp đúng tỷ lệ lệch quan sát được. ✓
>
> **Điểm đắt giá nhất hôm nay:** hai tầng sai ngược chiều nên **triệt tiêu bớt cho nhau**. Tầng 2 sai tới 6,7 lần, nhưng tầng 1 sai thiếu 31 % kéo lại nên kết quả cuối chỉ lệch 4,6 lần. Nếu tầng 1 mà *đúng* 5 triệu thì sai số cuối sẽ **tệ hơn** (6,7 lần).
>
> → Đừng bao giờ nhìn sai số ở node gốc rồi kết luận. **Phải bóc từng tầng ra** — sai số có thể đang che nhau.
>
> Thủ phạm chính vẫn là **tầng 2**: hằng số 0,5 % không liên quan gì tới dữ liệu thật. Với `device_id = 42` (device thưa, 3.731 dòng) nó **đoán thừa**; với một device nóng 100k dòng thì cùng hằng số đó sẽ **đoán thiếu**. Một con số không thể đúng cho mọi giá trị — cùng gốc bệnh với generic plan ở §1.

### Tự suy ngược `relpages` / `reltuples` từ cost

Dùng công thức §6 theo chiều ngược:

```
cost = relpages × 1.0 + reltuples × (cpu_tuple_cost 0.01 + cpu_operator_cost 0.0025)
79.921,68 = relpages + 3.437.014 × 0,0125
79.921,68 = relpages + 42.962,68
relpages ≈ 36.959
```

→ Dự đoán cho §2: `relpages = 36.959`, `reltuples = -1` (chưa ANALYZE). Bảng nặng 36.959 × 8KB = **289 MB**.

**Vì sao tầng 1 sai 31 %:**

| | dòng/page |
|---|---|
| planner tin | 3.437.014 ÷ 36.959 = **93** |
| thật | 5.000.000 ÷ 36.959 = **135** |

Planner biết **chắc chắn** số page (đọc từ kích thước file — luôn đúng), nhưng phải **đoán mỗi page nhét được bao nhiêu dòng** dựa trên kiểu dữ liệu các cột. Nó đoán dòng *béo hơn* thực tế → ra ít dòng hơn thực tế 31 %.

### Bonus: giá của việc song song

| | Execution Time |
|---|---|
| có song song (3 tiến trình) | 176 ms |
| tắt song song | **345 ms** |

Nhanh gấp **1,96 lần** với 3 tiến trình — không phải gấp 3, vì mất phí dựng worker (1000 cost) + phí gom kết quả. **Song song không miễn phí.**

---

## §4. Cho planner biết sự thật (ANALYZE)

| | trước ANALYZE | sau ANALYZE |
|---|---|---|
| `reltuples` |  |  |
| `relpages` |  |  |
| `rows` ước lượng ở Seq Scan |  |  |
| `actual rows` |  |  |
| sai số (%) |  |  |

`pg_stats` cho `ts_kv.device_id`:

| n_distinct | null_frac | correlation | mcv_5 | freq_5 |
|---|---|---|---|---|
|  |  |  |  |  |

- `42` có nằm trong `most_common_vals` không?

**Ghi:** sai số trước/sau ANALYZE. Nếu sau ANALYZE vẫn lệch → nguyên nhân là gì?

>

---

## §5. `EXPLAIN` vs `EXPLAIN ANALYZE`

| Thời điểm | `count(*) FROM alarm WHERE id < 1000` |
|---|---|
| sau `EXPLAIN ANALYZE DELETE` (trong transaction) |  |
| sau `ROLLBACK` |  |

**Ghi:** quy tắc **tôi tự đặt** khi dùng EXPLAIN trên production:

>

---

## §6. `cost` không phải mili-giây

| Query | startup cost | total cost | actual time (ms) | ms ÷ total cost |
|---|---|---|---|---|
| `count(*) FROM ts_kv` |  |  |  |  |
| `count(*) FROM alarm` |  |  |  |  |
| `ts_kv ORDER BY dbl_v LIMIT 10` |  |  |  |  |
| `ts_kv ORDER BY dbl_v` (bỏ LIMIT) |  |  |  |  |

- Cost tôi tự tính (`relpages*1.0 + reltuples*0.01`) = ; cost planner in = ; lệch = %. Phần lệch đến từ đâu?
- Tỷ lệ ms÷cost có phải hằng số không? **Hai** lý do nó không thể là hằng số:
  1.
  2.
- Cặp có/không `LIMIT 10`: startup cost đổi thế nào? Kiểu node có đổi không (ví dụ `Sort` → `Top-N heapsort` / Index Scan)?

>

---

## §7. Hai con số row — quan trọng nhất hôm nay

Query join `ts_kv × device` theo ngày `2025-06-01`:

| # | Node (từ lá lên gốc) | rows (đoán) | actual rows | loops | tỷ lệ lệch |
|---|---|---|---|---|---|
| 1 |  |  |  |  |  |
| 2 |  |  |  |  |  |
| 3 |  |  |  |  |  |
| 4 |  |  |  |  |  |
| 5 |  |  |  |  |  |

- Node lệch nhiều nhất:
- Nó nằm gần **lá** hay gần **gốc**? Vì sao vị trí đó lại quan trọng?
- `SETTINGS` in ra GUC nào khác mặc định:

>

---

## Bảng số liệu chính

| Kịch bản | node plan chính | actual time | shared hit/read | temp r/w | ghi chú |
|---|---|---|---|---|---|
| count(*) ts_kv WHERE device_id=42 (trước ANALYZE) |  |  |  |  |  |
| count(*) ts_kv WHERE device_id=42 (sau ANALYZE) |  |  |  |  |  |
| count(*) ts_kv (full) |  |  |  |  |  |
| ORDER BY dbl_v LIMIT 10 |  |  |  |  |  |
| ORDER BY dbl_v (không LIMIT) |  |  |  |  |  |
| join ts_kv × device 1 ngày |  |  |  |  |  |

---

## Tôi đoán sai chỗ nào
<!-- Phần quan trọng nhất. Đối chiếu từng dòng §0. Sai vì hiểu nhầm cái gì? -->

| # | Tôi đoán | Thực tế | Tôi đã hiểu nhầm điều gì |
|---|---|---|---|
| 1 |  |  |  |
| 2 |  |  |  |
| 3 |  |  |  |

## Áp dụng vào hệ thật của tôi
<!-- Job nào nạp dữ liệu lớn rồi query ngay? Sau bài này sẽ thêm bước gì vào job đó? -->

>

## Câu hỏi còn treo

1.
