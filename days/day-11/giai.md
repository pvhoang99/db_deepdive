# Day 11 — Lời giải: Planner nhìn thấy gì — giải phẫu `pg_stats`

> Bài chữa. Đo thật trên lab `SCALE=1` (đã seed lại sạch, `ts` correlation = 1).

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án | Bẫy |
|---|---|---|---|
| 1 | `type='sensor'` (90 %) — chính xác không? | ✅ **Rất chính xác: 44.905 vs 44.957 = sai 0,12 %** | |
| 2 | `device_id = 42` — chính xác không? | ✅ chính xác (trong MCV). Nhưng `device_id = 31337` **sai 5,1 lần** | Bẫy nằm ở **giá trị nào**, không phải cột nào |
| 3 | ANALYZE lấy mẫu bao nhiêu dòng trên bảng 5 triệu? | **30.000 dòng** (`300 × 100`) — **0,6 % bảng** | Đa số đoán "một phần trăm nào đó của bảng" |

Câu 3 đáng nhớ: **số dòng lấy mẫu KHÔNG phụ thuộc kích thước bảng.** Bảng 5 triệu và bảng 5 tỷ đều lấy 30.000 dòng. Đó là lý do `ANALYZE ts_kv` chỉ mất 182 ms (Day 01) — và cũng là lý do `n_distinct` sai nặng trên bảng lớn (§4).

---

## §1. `ANALYZE` làm gì

```
default_statistics_target = 100  ->  30.000 dòng mẫu
```

### `pg_stats` của `ts_kv`

| attname | null_frac | avg_width | **n_distinct** | **correlation** |
|---|---|---|---|---|
| `ts` | 0 | 8 | **−1** | **1,000** |
| `bool_v` | **0,910** | 1 | 2 | 0,906 |
| `str_v` | **0,908** | 4 | 3 | 0,438 |
| `key_id` | 0 | 2 | **8** | 0,150 |
| `dbl_v` | 0,182 | 8 | 33.174 | −0,037 |
| `device_id` | 0 | 8 | **28.704** | **−0,008** |

Đọc bảng này như đọc bản đồ:
- `ts`: `n_distinct = −1` nghĩa **mọi giá trị đều phân biệt** (số âm = tỷ lệ so với số dòng). `correlation = 1` = append-only hoàn hảo.
- `bool_v` và `str_v` **91 % NULL** — cột thưa, index trên chúng gần như vô dụng trừ khi partial.
- `key_id` chỉ 8 giá trị — index đứng một mình vô dụng (đã chứng minh ở Day 04 §6).

### `n_distinct` của `device_id` — sai lệch đầu tiên

```
 ước lượng | thật
-----------+-------
     28704 | 50000
```

**Sai thiếu 42,6 %.** Planner tưởng chỉ có 28.704 device trong khi thật là 50.000.

Đây không phải bug — đó là bản chất của bài toán ước lượng số giá trị phân biệt từ mẫu. Từ 30.000 dòng mẫu (0,6 % bảng), không có cách nào biết chắc có bao nhiêu giá trị hiếm chưa lọt vào mẫu. Postgres dùng ước lượng Haas–Stokes, và nó **luôn nghiêng về đánh giá thấp**.

Hệ quả sẽ thấy ở §4.

---

## §2. MCV — danh sách giá trị phổ biến

```
 attname  |                     mcv                     |          most_common_freqs
----------+---------------------------------------------+---------------------------------------
 type     | {sensor,gateway,controller}                 | {0.8981, 0.09113, 0.010767}
 region   | {ap-southeast,us-east,eu-west,ap-northeast} | {0.4287, 0.28383, 0.14600, 0.14147}
 firmware | {1.0.0,1.2.4,2.0.0-rc1,1.2.3}               | {0.25227, 0.25060, 0.25043, 0.24670}
```

### Tự tính tay rồi so với planner

`reltuples = 50.000`

| Query | Tính tay `freq × reltuples` | Planner in `rows=` | **Thực tế** | Sai số |
|---|---|---|---|---|
| `type = 'sensor'` | 0,8981 × 50.000 = **44.905** | **44.905** | 44.957 | **0,12 %** |
| `type = 'controller'` | 0,010767 × 50.000 = **538,4** | **538** | 519 | **3,7 %** |

**Công thức khớp chính xác đến từng chữ số.** Planner không tính toán gì phức tạp — nó tra bảng và nhân.

### Vì sao MCV cho ước lượng tốt đến vậy

Vì tần suất được **lưu trực tiếp**, không phải suy đoán. Với cột chỉ 3–4 giá trị, cả 3–4 đều lọt MCV → không còn gì phải đoán.

Điểm quan trọng: **cột càng lệch thì MCV càng hữu ích**. `type` lệch 90/9/1 — trực giác nói "lệch thế thì planner sẽ sai", nhưng thực tế **ngược lại**: lệch nặng nghĩa là ít giá trị chi phối, mà ít giá trị thì lọt hết vào MCV.

### Công thức khi KHÔNG nằm trong MCV — chỗ sai số bắt đầu

```
selectivity = (1 − Σ freq của MCV − null_frac) / (n_distinct − số phần tử MCV)
```

Tức **"chia đều phần còn lại"**. Giả định phân bố đều cho phần đuôi — và phần đuôi hầu như không bao giờ đều.

---

## §3. Histogram

```
 số biên | ba biên đầu                                          | ba biên cuối
---------+------------------------------------------------------+----------------------------------
     101 | 2025-05-01 00:18, 2025-05-01 22:12, 2025-05-02 22:08 | 2025-07-28 03:08, 2025-07-29 02:02, 2025-07-30 00:00
```

**101 biên → 100 khoảng, mỗi khoảng chứa ~1 % dữ liệu** (equi-depth: số **dòng** bằng nhau, không phải độ rộng bằng nhau).

Kiểm chứng: hai biên đầu cách nhau ~22 giờ, và 1 % của 5 triệu = 50.000 dòng. Dữ liệu trải 91 ngày → trung bình 0,91 ngày/khoảng. Khớp.

### Ước lượng khoảng 1 tuần

| | |
|---|---|
| Planner ước lượng | **400.763** |
| Thực tế | **388.901** |
| **Sai số** | **+3,05 %** |

Rất tốt. Vì `ts` phân bố khá đều theo thời gian, nên **nội suy tuyến tính trong khoảng** hoạt động đúng.

> **Nhưng đây chính là giả định sẽ vỡ ở §7:** histogram giả định phân bố đều **bên trong mỗi khoảng**. Dữ liệu dồn cục trong một khoảng → ước lượng sai hàng chục lần.

Chi tiết cần nhớ: **MCV và histogram loại trừ nhau.** Giá trị đã vào MCV thì bị **loại khỏi** dữ liệu dùng để dựng histogram. Nên histogram mô tả *phần đuôi*, còn MCV mô tả *phần đỉnh*.

---

## §4. `n_distinct` — nguồn lỗi số một

### Trước khi ghi đè

```
 n_distinct ước lượng : 28.704
 n_distinct thật      : 50.000        (sai thiếu 42,6%)
```

```sql
EXPLAIN SELECT * FROM ts_kv WHERE device_id = 31337;
->  rows=153
SELECT count(*) ...  ->  30
```

**Ước lượng 153, thật 30 — sai thừa 5,1 lần.**

Truy nguyên bằng công thức §2:
```
tổng freq của 100 MCV ≈ 0,138
selectivity = (1 − 0,138 − 0) / (28.704 − 100) = 0,0000301
rows = 0,0000301 × 5.000.000 = 150,7    ≈ 153 ✓
```

`n_distinct` nằm ở **mẫu số**. Nhỏ hơn thật 1,74 lần → selectivity lớn hơn thật 1,74 lần.

### Sau khi ghi đè

```sql
ALTER TABLE ts_kv ALTER COLUMN device_id SET (n_distinct = 50000);
ANALYZE ts_kv;
->  rows=87
```

| | rows đoán | thật | sai số |
|---|---|---|---|
| trước ghi đè | **153** | 30 | **+410 %** |
| sau ghi đè | **87** | 30 | **+190 %** |

**Sai số giảm hơn một nửa.** Vẫn còn thừa 2,9 lần — vì `device_id` phân bố power-law nên "chia đều phần đuôi" vẫn sai; device 31337 chỉ có 30 dòng trong khi trung bình đuôi là ~87.

### Vì sao `n_distinct` nguy hiểm

Nó đứng ở mẫu số của mọi ước lượng equality cho giá trị ngoài MCV. Sai 5 lần ở đó → planner tưởng phải lấy nhiều dòng gấp 5 → **bỏ index, chọn seq scan**, hoặc chọn hash join thay vì nested loop. Day 12 đo hậu quả này.

### Cú pháp ghi đè

```sql
-- số dương: giá trị tuyệt đối
ALTER TABLE ts_kv ALTER COLUMN device_id SET (n_distinct = 50000);

-- số âm: TỶ LỆ so với số dòng — dùng khi bảng còn lớn lên
ALTER TABLE ts_kv ALTER COLUMN device_id SET (n_distinct = -0.01);  -- 1% số dòng

-- trả về tự động
ALTER TABLE ts_kv ALTER COLUMN device_id RESET (n_distinct);
```

**Dùng số âm cho bảng đang lớn** — tỷ lệ tự co giãn theo kích thước, không phải sửa lại mỗi quý.

⚠️ Giá trị ghi đè là **cố định vĩnh viễn** cho tới khi ai đó RESET. Nếu dữ liệu đổi bản chất, nó thành nguồn lỗi mới. Ghi vào tài liệu vận hành.

---

## §5. `default_statistics_target` — đánh đổi mẫu lớn hơn

| | target = 100 (mặc định) | target = 1000 |
|---|---|---|
| độ dài MCV | **100** | **1.000** |
| số biên histogram | 101 | **1.001** |
| `n_distinct` ước lượng | 28.704 (thật 50.000, **sai 42,6 %**) | **48.454** (**sai 3,1 %**) |
| `Planning Time` | 0,040–0,057 ms | 0,052–0,095 ms |

### Ước lượng chính xác hơn bao nhiêu

| Giá trị | Thật | target 100 | target 1000 | Cải thiện |
|---|---|---|---|---|
| `device_id = 31337` | **30** | 87 (+190 %) | **76 (+153 %)** | nhẹ |
| `device_id = 777` | **532** | 87 (**−84 %**) | **733 (+38 %)** | **rất lớn** |

Chỗ đắt giá là `device_id = 777`:

- Với target 100, device 777 **không lọt MCV** → ước lượng 87, trong khi thật 532. **Sai thiếu 6,1 lần.**
- Với target 1000, MCV dài 1.000 phần tử → device 777 **lọt vào MCV** → ước lượng 733 vs thật 532. Sai thừa 1,38 lần.

**Sai 6,1 lần → sai 1,38 lần.** Và quan trọng hơn: **sai đổi chiều** (thiếu → thừa). Đánh giá **thiếu** nguy hiểm hơn nhiều — nó khiến planner chọn nested loop cho tập lớn (Day 12).

Cải thiện lớn nhất lại nằm ở `n_distinct`: **sai 42,6 % → 3,1 %**. Đây thường là lợi ích chính của việc nâng statistics target.

### Cái giá

- `ANALYZE` chậm hơn (mẫu 300.000 dòng thay vì 30.000)
- `pg_statistic` to hơn 10 lần cho cột đó
- `Planning Time` **tăng ~40–65 %** (0,040 → 0,052 ms; 0,057 → 0,095 ms) — planner phải quét MCV dài hơn

Con số planning time tuyệt đối vẫn rất nhỏ, nhưng nhớ Day 01 §1: với query nhẹ chạy 1 triệu lần/ngày, +0,04 ms là **40 giây CPU/ngày**.

> **Chiến lược đúng: để `default_statistics_target = 100` cho toàn hệ, chỉ nâng cho VÀI cột thật sự có vấn đề** — cột lệch nặng, nhiều giá trị phân biệt, và xuất hiện trong query nóng.

```sql
ALTER TABLE ts_kv ALTER COLUMN device_id SET STATISTICS 1000;
ANALYZE ts_kv;
-- trả về mặc định:
ALTER TABLE ts_kv ALTER COLUMN device_id SET STATISTICS -1;
```

---

## §6. `correlation` — cột quyết định index có đáng không

```
  attname  | correlation
-----------+-------------
 ts        |     1,000      <- append-only, hoàn hảo
 bool_v    |     0,919
 str_v     |     0,402
 key_id    |     0,168
 dbl_v     |    −0,038
 device_id |     0,002      <- gần như ngẫu nhiên
```

### Thí nghiệm phá correlation

```sql
CREATE TABLE ts_shuffled AS SELECT * FROM ts_kv ORDER BY random();
```

| | `ts_kv` | `ts_shuffled` |
|---|---|---|
| **correlation của `ts`** | **1,000** | **−0,0088** |
| Plan được chọn | **Index Only Scan** | **Bitmap Heap Scan** |
| `Heap Blocks` | — | **exact=35.183** |
| **buffers** | **43.078** | **35.489** |
| **actual time** | **34,1 ms** | **180,1 ms** |

**Cùng một query, cùng số dòng (111.117), cùng index. Chậm 5,3 lần.** Khác biệt duy nhất: thứ tự vật lý của dữ liệu.

### Đọc kỹ hai plan

Trên `ts_kv` (corr = 1), planner chọn **Index Only Scan** — nó biết các dòng nằm liền nhau nên đi tuần tự qua index rẻ hơn.

Trên `ts_shuffled` (corr ≈ 0), planner **đổi hẳn chiến lược** sang **Bitmap Heap Scan** — vì các dòng rải rác, phải gom TID rồi sắp theo page mới đọc được hiệu quả. `Heap Blocks: exact=35.183` — chạm **35.183 page phân biệt** để lấy 111.117 dòng = **3,2 dòng/page**, trong khi mật độ tối đa của bảng là 135 dòng/page.

Hiệu suất đọc: **2,3 %**.

> **`correlation` là biến giải thích tại sao ở Day 04 điểm hoà vốn của `ts` là 33 % còn `device_id` thì không bao giờ dùng được Index Scan thuần.** Planner đưa nó thẳng vào công thức cost của Index Scan.

Chú ý điều tinh tế: `ts_kv` đọc **nhiều buffer hơn** (43.078 vs 35.489) nhưng **nhanh hơn 5,3 lần**. Lại là bài học Day 03: buffer trong cache rẻ, buffer phải đọc đĩa mới đắt. `ts_shuffled` có `read=35.489 written=11.727` — chạm đĩa thật.

---

## §7. Bẫy dữ liệu mới — ước lượng ngoài histogram

Thêm 50.000 dòng có `ts` **vượt xa** mọi biên histogram (max cũ 2025-11-17 → max mới 2026-06-06):

| | rows đoán | thật | **sai số** |
|---|---|---|---|
| **trước ANALYZE** | **955** | **50.000** | **thiếu 52 lần** |
| **sau ANALYZE** | **1.481** | 50.000 | **thiếu 34 lần** |

### Điều bất ngờ: `ANALYZE` KHÔNG cứu được

Đa số nghĩ chạy `ANALYZE` là xong. Số đo nói: sai số chỉ giảm từ 52 lần xuống 34 lần — **vẫn thảm hoạ**.

Vì sao: 50.000 dòng mới **dồn cục** quanh 2026-06-05 (chúng là 50.000 dòng đầu tiên của bảng, `ts` gần nhau, cộng thêm 400 ngày). Sau ANALYZE, histogram có biên cuối vươn tới 2026-06-06, nhưng **khoảng cuối cùng trải rộng nhiều tháng** trong khi dữ liệu chỉ nằm ở một điểm. Nội suy tuyến tính trong khoảng đó → sai 34 lần.

Đây chính là giả định của §3 bị vỡ: **histogram giả định phân bố đều bên trong mỗi khoảng.**

### Vì sao con số đó cực nguy hiểm trong một join

```
Nested Loop  (cost=0.72..889.81 rows=955) (actual rows=50000 loops=1)
  ->  Index Scan using idx_tskv_ts on ts_kv t  (actual rows=50000)
  ->  Index Only Scan using device_pkey on device d  (actual rows=1 loops=50000)
        Buffers: shared hit=99866 read=135
Execution Time: 69.929 ms
```

Planner tưởng nhánh ngoài trả **955 dòng** nên chọn **Nested Loop** — hợp lý với 955 dòng. Thực tế 50.000 dòng → **50.000 lần index lookup**, tốn **99.866 buffer** chỉ riêng nhánh trong.

Ở lab nó "chỉ" 70 ms vì `device` nhỏ và nằm gọn trong RAM. **Trên production, hãy nhân lên:**

| | Lab | Production thật |
|---|---|---|
| nhánh ngoài | 50.000 dòng | 50 triệu dòng |
| bảng trong | 50.000 dòng, 9 MB, trong RAM | 500 triệu dòng, 200 GB, **không vừa RAM** |
| mỗi lookup | 0,001 ms (cache hit) | ~1 ms (random read đĩa) |
| **tổng** | 70 ms | **~14 giờ** |

Và plan đúng (hash join) sẽ chỉ mất vài phút.

> **Đây là hình dạng kinh điển của "job ETL đêm qua chạy 40 phút, đêm nay chạy 6 tiếng, không ai đổi gì".** Dữ liệu mới nằm ngoài histogram → estimate ≈ 0 → nested loop → nổ.

### Cách phòng — bốn lớp

**1. `ANALYZE` ngay sau khi nạp — cần nhưng KHÔNG đủ.** Số đo cho thấy sai số chỉ giảm 52 → 34 lần. Vẫn phải làm, nhưng đừng coi là xong.

**2. Nâng statistics target cho cột thời gian của bảng time-series:**
```sql
ALTER TABLE ts_kv ALTER COLUMN ts SET STATISTICS 1000;
```
1.000 khoảng thay vì 100 → khoảng cuối hẹp hơn 10 lần → nội suy sát hơn.

**3. Partition theo thời gian — cách chữa GỐC (Day 32).** Mỗi partition có thống kê riêng, dữ liệu mới nằm trong partition mới với histogram của chính nó. Đây là lý do thật sự mạnh nhất của partitioning, mạnh hơn cả chuyện `DROP` partition nhanh.

**4. Với job ETL, cân nhắc `SET LOCAL enable_nestloop = off`** trong đúng transaction đó — thô nhưng hiệu quả, và giới hạn phạm vi ảnh hưởng.

### 🎁 Bonus: bắt được `never executed`

Ở lần chạy đầu (chưa có dòng nào thoả), plan hiện:
```
->  Index Only Scan using device_pkey on device d  (never executed)
```
Đây là câu trả lời cho câu hỏi mở của Day 02: `never executed` xuất hiện khi nhánh ngoài trả **0 dòng**, nên nhánh trong của Nested Loop không bao giờ được gọi. **Không phải lỗi.**

---

## §7b. Bảng tra: cột nào sinh ước lượng sai

| Đặc điểm cột | Rủi ro | Dấu hiệu | Số đo hôm nay |
|---|---|---|---|
| Rất nhiều giá trị phân biệt | `n_distinct` bị đánh giá thấp | estimate > actual nhiều lần | 28.704 vs 50.000 (**−42,6 %**) |
| Giá trị lệch không lọt MCV | selectivity sai **cả hai chiều** | lệch tuỳ giá trị truyền vào | `dev=777`: **−84 %**; `dev=31337`: **+190 %** |
| **Giá trị mới ngoài histogram** | estimate ≈ 0 → **nested loop nổ** | bảng time-series vừa nạp | **sai thiếu 52 lần**, ANALYZE chỉ giảm còn 34 lần |
| `correlation` gần 0 | index scan đắt hơn planner nghĩ | buffers cao bất ngờ | **chậm 5,3 lần** |
| Cột tính từ biểu thức | không có statistics → 0,5 % | (Day 09 §6) | sai **50 lần** |
| Hai cột phụ thuộc nhau | giả định độc lập sai | **Day 13** | |

---

## Bảng số liệu chính

| Kịch bản | Ước lượng | Thực tế | Sai số |
|---|---|---|---|
| `type='sensor'` (trong MCV) | 44.905 | 44.957 | **0,12 %** |
| `type='controller'` (trong MCV) | 538 | 519 | 3,7 % |
| `ts` khoảng 1 tuần (histogram) | 400.763 | 388.901 | 3,05 % |
| `device_id=31337` target 100 | 153 → 87* | 30 | +410 % → +190 % |
| `device_id=777` target 100 | **87** | **532** | **−84 %** |
| `device_id=777` target 1000 | **733** | 532 | +38 % |
| `n_distinct` target 100 | 28.704 | 50.000 | **−42,6 %** |
| `n_distinct` target 1000 | 48.454 | 50.000 | **−3,1 %** |
| `ts > mốc mới` trước ANALYZE | **955** | **50.000** | **−98,1 % (52×)** |
| `ts > mốc mới` sau ANALYZE | 1.481 | 50.000 | **−97,0 % (34×)** |

\* sau khi ghi đè `n_distinct = 50000`

| correlation | Plan | buffers | time |
|---|---|---|---|
| `ts_kv` corr = **1,000** | Index Only Scan | 43.078 | **34,1 ms** |
| `ts_shuffled` corr = **−0,009** | Bitmap Heap Scan, 35.183 block | 35.489 | **180,1 ms (5,3×)** |

---

## Ba điều dễ hiểu sai

| # | Hiểu nhầm | Sự thật đo được |
|---|---|---|
| 1 | "Cột lệch nặng thì planner ước lượng sai" | **Ngược lại.** `type` lệch 90/9/1 → sai **0,12 %**, vì cả 3 giá trị lọt MCV. Nguy hiểm là cột **nhiều giá trị phân biệt**, không phải cột lệch |
| 2 | "ANALYZE xong là ước lượng đúng" | Dữ liệu dồn cục ngoài histogram: sai **52 lần** → ANALYZE → vẫn sai **34 lần** |
| 3 | "ANALYZE quét cả bảng" | Lấy mẫu **30.000 dòng**, không phụ thuộc kích thước bảng. Đó là lý do `n_distinct` sai 42,6 % |

Thêm hai điều tinh vi:
- **`n_distinct` luôn nghiêng về đánh giá THẤP** — bản chất của ước lượng từ mẫu, không phải bug.
- **Sai thiếu nguy hiểm hơn sai thừa.** `dev=777` sai thiếu 6,1 lần → planner tưởng ít dòng → chọn nested loop. Sai thừa chỉ khiến plan bảo thủ hơn.

---

## Áp dụng vào hệ thật

**1. Query rà soát `n_distinct` đáng nghi — chạy ngay:**

```sql
SELECT s.tablename, s.attname, s.n_distinct, c.reltuples::bigint AS so_dong,
       CASE
         WHEN s.n_distinct > 0 AND s.n_distinct > c.reltuples * 0.1
           THEN 'nhiều giá trị phân biệt — dễ bị đánh giá thấp'
         WHEN s.n_distinct BETWEEN 1 AND 20
           THEN 'ít giá trị — index đơn vô dụng, xét partial'
       END AS canh_bao
FROM pg_stats s JOIN pg_class c ON c.relname = s.tablename
WHERE s.schemaname = 'public' AND c.reltuples > 1000000
ORDER BY c.reltuples DESC;
```

Cách kiểm chứng thủ công cho cột nghi ngờ (đắt, chạy trên replica):
```sql
SELECT (SELECT n_distinct FROM pg_stats WHERE tablename='ts_kv' AND attname='device_id') AS uoc,
       (SELECT count(DISTINCT device_id) FROM ts_kv) AS that;
```
**Lệch trên 30 % là đáng xử lý.**

**2. Nâng statistics target cho đúng 3 loại cột — không nâng bừa:**

```sql
-- (a) cột lệch nặng dùng trong WHERE của query nóng
ALTER TABLE ts_kv ALTER COLUMN device_id SET STATISTICS 1000;
ALTER TABLE ts_kv ALTER COLUMN tenant_id SET STATISTICS 1000;

-- (b) cột thời gian của bảng time-series (chống bẫy §7)
ALTER TABLE ts_kv ALTER COLUMN ts SET STATISTICS 1000;

-- (c) cột join có n_distinct sai nặng
ANALYZE ts_kv;   -- bắt buộc, không tự áp dụng
```

Đo trước/sau bằng chính query nóng, đừng làm mù. Ở lab, sai số của `device_id=777` giảm từ 6,1 lần xuống 1,38 lần.

**3. Cột có `correlation` cao là ứng viên BRIN — đo ngay:**
```sql
SELECT tablename, attname, correlation
FROM pg_stats
WHERE schemaname='public' AND abs(correlation) > 0.9
ORDER BY abs(correlation) DESC;
```
Trong hệ IoT: `ts_kv.ts`, `alarm.start_ts`, `*.created_at` — mọi cột thời gian của bảng append-only. Day 31 cho thấy BRIN thay được B-tree 107 MB bằng vài chục KB.

Ngược lại, cột có `correlation` gần 0 mà đang có B-tree lớn → cân nhắc `CLUSTER` định kỳ hoặc partition.

**4. Với bảng time-series, đừng dừng ở `ANALYZE` — partition theo tháng.** §7 chứng minh `ANALYZE` chỉ giảm sai số từ 52 lần xuống 34 lần. Partition là cách chữa gốc (Day 32).

**5. Thêm một panel monitoring: "bảng nào có thống kê cũ hơn 24 giờ mà đã thay đổi > 10 %":**
```sql
SELECT relname, n_mod_since_analyze, n_live_tup,
       round(100.0*n_mod_since_analyze/NULLIF(n_live_tup,0),1) AS pct_doi,
       now() - greatest(last_analyze, last_autoanalyze) AS thong_ke_cu
FROM pg_stat_user_tables
WHERE n_mod_since_analyze > 0.1 * n_live_tup
ORDER BY n_mod_since_analyze DESC;
```

---

## Câu hỏi mở sang các ngày sau

1. Sai số 5,1 lần ở node lá — qua 3 tầng join thì thành bao nhiêu? → **Day 12**
2. `region` và `country` phụ thuộc hàm hoàn toàn. Planner nhân hai selectivity với nhau — sai bao nhiêu? → **Day 13**
3. `correlation` đi vào công thức cost của Index Scan như thế nào? Tự tính tay được không? → **Day 14**
4. Dữ liệu ngoài histogram làm nested loop nổ — partition chữa được đến đâu? → **Day 32**
5. `n_distinct` ghi đè bằng tay là cố định vĩnh viễn — có cách nào tự động hơn? → **Day 13** (`CREATE STATISTICS`)
