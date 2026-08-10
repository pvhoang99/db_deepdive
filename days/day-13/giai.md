# Day 13 — Lời giải: Cột tương quan & `CREATE STATISTICS`

> Bài chữa. Đo thật trên lab `SCALE=1`. Bảng `device`: 50.000 dòng.

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án |
|---|---|---|
| 1 | Planner ước lượng `region='ap-southeast' AND country='VN'` ra bao nhiêu? | **9.081** |
| 2 | Thực tế bao nhiêu? | **21.403** |
| 3 | Sai bao nhiêu lần? | **thiếu 2,36 lần** |

Và sau khi tạo extended statistics: **21.443 vs 21.403 — sai 0,19 %.**

---

## §1. Giả định độc lập — chỗ planner sai một cách hệ thống

### Số đo

```
 sel_region | sel_country | sel_thật
------------+-------------+----------
    0,42806 |     0,42806 |  0,42806
```

Ba con số **bằng nhau tuyệt đối** — đó là dấu vân tay của **phụ thuộc hàm hoàn toàn**: mọi device `ap-southeast` đều là `VN`, và ngược lại.

### Tự tính tay

```
Planner:  sel(region) × sel(country) × 50.000
        = 0,42806 × 0,42806 × 50.000
        = 0,18324 × 50.000
        = 9.162          ≈ 9.081 planner in ✓ (chênh do làm tròn của MCV)

Sự thật: sel_thật × 50.000
        = 0,42806 × 50.000
        = 21.403 ✓
```

**Planner nhân thừa đúng một lần với 0,42806 → sai thiếu đúng `1/0,42806 = 2,34 lần`.**

### Công thức tổng quát cho phụ thuộc hàm

> **Với `a → b` (a xác định b), sai số của planner bằng đúng `1 / selectivity(b)`.**

| Cặp cột | sel của cột thứ hai | **Sai số** |
|---|---|---|
| `region` / `country` (4 giá trị đều) | 0,43 | **2,3 lần** |
| `city='Đà Lạt'` / `province='Lâm Đồng'` | ~0,015 | **67 lần** |
| `postal_code` / `province` | ~0,001 | **1.000 lần** |
| `model='TH-100'` / `manufacturer='Acme'` | ~0,05 | **20 lần** |

**Cặp cột càng hiếm thì sai số càng khủng khiếp.** Ở lab chỉ 2,3 lần vì cả 4 region đều lớn; trong hệ thật với hàng nghìn `city`, sai số hàng trăm lần là bình thường.

Và như Day 12 đã đo: đây là **underestimate** — kiểu hỏng nguy hiểm, dẫn tới nested loop cho tập lớn.

---

## §2. `CREATE STATISTICS` — kết quả

```sql
CREATE STATISTICS st_dev_geo (dependencies, ndistinct, mcv)
  ON region, country FROM device;
ANALYZE device;
```

| | rows đoán | thật | **sai số** |
|---|---|---|---|
| **trước** | **9.081** | 21.403 | **−57,6 % (2,36 lần)** |
| **sau** | **21.443** | 21.403 | **+0,19 %** |

**Sai số từ 2,36 lần xuống 0,19 % — cải thiện 300 lần.** Bằng một câu DDL, không tạo index, không tốn dung lượng đáng kể.

---

## §3. Nhìn vào bên trong extended statistics

```
  stxname   | stxkeys | stxkind
------------+---------+---------
 st_dev_geo | 6 7     | {d,f,m}
```

`stxkind`: `d` = dependencies, `f` = ndistinct, `m` = mcv. `stxkeys = 6 7` là số thứ tự cột (`region`, `country`).

### Hệ số phụ thuộc

```
stxddependencies : {"6 => 7": 1.000000, "7 => 6": 1.000000}
stxdndistinct    : {"6, 7": 4}
```

**Hệ số 1.000000 theo CẢ HAI chiều** = phụ thuộc hàm hoàn hảo, hai chiều. Biết `region` là biết chắc `country`, và ngược lại.

Cách đọc hệ số:
| Giá trị | Nghĩa |
|---|---|
| **1,0** | biết a là biết chắc b |
| **0,7** | biết a thì đoán đúng b trong 70 % trường hợp |
| **0,0** | hoàn toàn độc lập — không cần statistics |

Planner dùng hệ số này để **nội suy** giữa "nhân hai selectivity" (độc lập) và "lấy selectivity nhỏ hơn" (phụ thuộc hoàn toàn).

### MCV nhiều cột — con số đắt giá nhất §3

```
 index |      values       | frequency | base_frequency
-------+-------------------+-----------+----------------
     0 | {ap-southeast,VN} |   0,42887 |        0,18393
     1 | {us-east,US}      |   0,28237 |        0,07973
     2 | {eu-west,DE}      |   0,14613 |        0,02135
     3 | {ap-northeast,JP} |   0,14263 |        0,02034
```

**Chỉ 4 tổ hợp** (thay vì 4 × 4 = 16 mà giả định độc lập dự đoán).

Hai cột cạnh nhau kể toàn bộ câu chuyện:
- `frequency` = tần suất **thật** của tổ hợp
- `base_frequency` = tần suất mà **giả định độc lập** tính ra

| Tổ hợp | frequency / base_frequency | Planner đang sai |
|---|---|---|
| `{ap-southeast,VN}` | 0,42887 / 0,18393 | **2,33 lần** |
| `{us-east,US}` | 0,28237 / 0,07973 | **3,54 lần** |
| `{eu-west,DE}` | 0,14613 / 0,02135 | **6,84 lần** |
| `{ap-northeast,JP}` | 0,14263 / 0,02034 | **7,01 lần** |

> **Cột `base_frequency` là công cụ chẩn đoán tốt nhất Postgres cung cấp.** Tỷ lệ `frequency / base_frequency` cho biết chính xác planner đang sai bao nhiêu lần cho từng tổ hợp cụ thể.

Chú ý điều quan trọng: **tổ hợp càng hiếm thì sai số càng lớn** — `eu-west/DE` (14,6 %) sai 6,84 lần trong khi `ap-southeast/VN` (42,9 %) chỉ sai 2,33 lần. Đây lại là bằng chứng cho công thức `1/sel(b)` ở §1.

---

## §4. `ndistinct` cho nhóm cột — sửa `GROUP BY`

```sql
EXPLAIN SELECT region, country, count(*) FROM device GROUP BY region, country;
```

| | rows đoán | thật |
|---|---|---|
| **không có statistics** | **16** | 4 |
| **có `(ndistinct)`** | **4** | 4 |

Con số **16** đến từ đâu: `n_distinct(region) × n_distinct(country) = 4 × 4 = 16`. Lại là giả định độc lập, lần này cho số **tổ hợp**.

Sai 4 lần ở đây vô hại (16 nhóm hay 4 nhóm đều vừa RAM). Nhưng với cặp cột lớn hơn:

```
GROUP BY city, district      -- 700 × 10.000 = 7.000.000 nhóm đoán
                             -- thật:            ~10.000 nhóm
```

Sai **700 lần** → planner cấp hash table cho 7 triệu nhóm → `work_mem` không đủ → **HashAgg spill ra đĩa** (Day 19), hoặc ngược lại chọn `GroupAggregate` với sort đắt.

---

## §5. Tìm cặp cột đáng tạo statistics

```
       cols       | tích ndistinct | tổ hợp thật | **tỷ lệ**
------------------+----------------+-------------+-----------
 region,country   |             16 |           4 |  **4,00**  <- ĐÁNG TẠO
 type,region      |             12 |          12 |   1,00
 tenant_id,region |             80 |          80 |   1,00
 firmware,type    |             12 |          12 |   1,00
```

**Chỉ `region,country` có tỷ lệ > 1.** Ba cặp còn lại hoàn toàn độc lập — tạo statistics cho chúng là lãng phí (làm `ANALYZE` chậm hơn, không được gì).

### Query phát hiện tự động — mang về production

```sql
-- Tìm cặp cột phụ thuộc: so tích n_distinct riêng lẻ với số tổ hợp thật
-- ⚠️ ĐẮT: mỗi cặp là một lần DISTINCT trên bảng. Chạy trên replica / giờ thấp điểm.
WITH cols AS (
  SELECT attname, n_distinct
  FROM pg_stats
  WHERE tablename = 'device' AND schemaname = 'public'
    AND n_distinct BETWEEN 2 AND 10000          -- bỏ cột unique và cột 1 giá trị
)
SELECT a.attname AS cot_a, b.attname AS cot_b,
       (a.n_distinct * b.n_distinct)::bigint AS tich_neu_doc_lap,
       format('SELECT count(*) FROM (SELECT DISTINCT %I, %I FROM device) s',
              a.attname, b.attname) AS chay_cau_nay
FROM cols a JOIN cols b ON a.attname < b.attname
ORDER BY 3 DESC;
```

Rồi chạy các câu `chay_cau_nay` và so. **Tỷ lệ > 2 là đáng tạo statistics; > 10 là bắt buộc.**

Cách rẻ hơn, không cần quét bảng — **tạo statistics rồi đọc `base_frequency`**:
```sql
CREATE STATISTICS tmp_check (mcv) ON col_a, col_b FROM tbl;
ANALYZE tbl;
SELECT values, round((frequency/NULLIF(base_frequency,0))::numeric, 1) AS planner_sai_may_lan
FROM pg_mcv_list_items((SELECT stxdmcv FROM pg_statistic_ext_data d
  JOIN pg_statistic_ext e ON e.oid=d.stxoid WHERE e.stxname='tmp_check'))
ORDER BY 2 DESC LIMIT 10;
-- nếu mọi tỷ lệ ~1 thì DROP STATISTICS tmp_check;
```

---

## §6. Giới hạn của extended statistics

### Thí nghiệm: có giúp qua join không

Query: `ts_kv ⋈ device` với `region='ap-southeast' AND country='VN' AND key_id=1`.

| | Node `device` | Node `Hash Join` |
|---|---|---|
| **không có `dependencies`/`mcv`** | 9.168 vs 21.403 (**−2,33×**) | 253.985 vs 599.396 (**−2,36×**) |
| **có statistics đầy đủ** | **21.245** vs 21.403 (**−0,7 %**) | **588.560** vs 599.396 (**−1,8 %**) |

### Kết luận chính xác hơn đề bài

Đề bài nói *"không giúp qua join"*. Số đo cho thấy **cần nói chính xác hơn**:

✅ **CÓ giúp node join — gián tiếp.** Sửa node lá (`device`: sai 2,33× → 0,7 %) thì node join cũng đúng theo (2,36× → 1,8 %). Đây chính là cơ chế "sai số lan truyền" của Day 12, nhưng theo chiều tốt.

❌ **KHÔNG giúp cho tương quan giữa cột của HAI BẢNG KHÁC NHAU.** Ví dụ: nếu `device.region` tương quan với `ts_kv.key_id` (device châu Á chỉ gửi key 1–3), extended statistics không mô tả được. Postgres **không có** statistics đa bảng.

### 💡 Phát hiện phụ: `ndistinct` không giúp `WHERE`

Ở §4, statistics chỉ khai `(ndistinct)`. Khi chạy §6 với statistics đó, node `device` **vẫn sai 2,33 lần** (9.168 vs 21.403).

> **`ndistinct` chỉ sửa ước lượng số NHÓM cho `GROUP BY`/`DISTINCT`. Nó KHÔNG sửa selectivity của `WHERE`.** Muốn sửa `WHERE` phải có `dependencies` hoặc `mcv`.

Đây là lỗi rất dễ mắc: tạo statistics rồi tưởng xong, mà khai sai `kind`.

### Bảng giới hạn đầy đủ

| Giới hạn | Chi tiết |
|---|---|
| **Chỉ trong một bảng** | không có statistics đa bảng |
| **Phải khai báo thủ công** | Postgres không tự phát hiện — đây là việc của anh |
| **Tối đa 8 cột** mỗi object | |
| `mcv` chỉ giúp tổ hợp **trong danh sách** | tổ hợp hiếm vẫn quay về giả định độc lập |
| `ndistinct` **không** sửa `WHERE` | chỉ sửa `GROUP BY`/`DISTINCT` |
| Không áp dụng cho tham số `$1` trong **generic plan** | nhắc lại Day 12 §4 |
| Làm `ANALYZE` chậm hơn | nên chỉ tạo cho cặp cột quan trọng |

---

## §7. Áp dụng đầy đủ

| Query | trước | **sau** | thật | sai trước | **sai sau** |
|---|---|---|---|---|---|
| `region='ap-southeast' AND country='VN'` | 9.202 | **21.453** | 21.403 | **−57,0 %** | **+0,23 %** |
| `region='us-east' AND country='US' AND type='sensor'` | 3.608 | **12.792** | 12.716 | **−71,6 %** | **+0,60 %** |
| `GROUP BY region, country` | 16 | **4** | 4 | **4,0×** | **0 %** |
| `tenant_id=1 AND type='sensor'` | 9.092 | 9.123 | 8.992 | +1,1 % | +1,5 % |
| `meta->>'model' = 'TH-100'` *(statistics biểu thức)* | **250** | **12.323** | 12.445 | **−98,0 %** | **−0,98 %** |

### Đọc bảng này

**Query 2 là ca đắt nhất: sai 3,52 lần → 0,6 %.** Ba cột `region + country + type`: statistics sửa cặp `region/country`, còn `type` độc lập nên nhân bình thường. Kết quả gần như hoàn hảo.

**Query 4 (`tenant_id + type`) không cải thiện** — đúng như §5 dự đoán (tỷ lệ 1,00, hai cột độc lập). `CREATE STATISTICS st_dev_tt` là **lãng phí**, nên xoá.

**Query 5 — statistics trên biểu thức (PG14+):**
```sql
CREATE STATISTICS st_dev_model ON (meta->>'model') FROM device;
```
Sai số **250 → 12.323** (thật 12.445): từ **−98 %** xuống **−1 %**.

Con số 250 chính là `DEFAULT_EQ_SEL` 0,5 % × 50.000 của Day 01 — planner hoàn toàn mù về biểu thức.

> **Đây là cách rẻ hơn expression index (Day 09 §6):** cùng sửa được ước lượng, nhưng **không tốn dung lượng index, không làm chậm ghi**. Nếu chỉ cần sửa ước lượng chứ không cần tra cứu, luôn dùng cách này.

---

## Bảng số liệu chính

| Kịch bản | rows đoán | thật | sai số |
|---|---|---|---|
| `region+country` không statistics | **9.081** | 21.403 | **−2,36×** |
| `region+country` có statistics | **21.443** | 21.403 | **+0,19 %** |
| `region+country+type` không statistics | 3.608 | 12.716 | **−3,52×** |
| `region+country+type` có statistics | **12.792** | 12.716 | **+0,60 %** |
| `GROUP BY region,country` không statistics | 16 | 4 | **4,0×** |
| `GROUP BY region,country` có `ndistinct` | **4** | 4 | **0 %** |
| join — node `device` không statistics | 9.168 | 21.403 | −2,33× |
| join — node `device` có statistics | **21.245** | 21.403 | **−0,7 %** |
| join — node `Hash Join` có statistics | **588.560** | 599.396 | **−1,8 %** |
| `meta->>'model'` không statistics | **250** | 12.445 | **−98 %** |
| `meta->>'model'` có statistics biểu thức | **12.323** | 12.445 | **−0,98 %** |

Nội dung statistics:
```
dependencies : {"region => country": 1.000000, "country => region": 1.000000}
ndistinct    : {"region, country": 4}
mcv          : 4 tổ hợp; frequency/base_frequency = 2,33 / 3,54 / 6,84 / 7,01
```

---

## Ba điều dễ hiểu sai

| # | Hiểu nhầm | Sự thật đo được |
|---|---|---|
| 1 | "Tạo `CREATE STATISTICS` là sửa được mọi ước lượng của nhóm cột đó" | Khai `(ndistinct)` **không sửa `WHERE`** — chỉ sửa `GROUP BY`. Node `device` vẫn sai 2,33× |
| 2 | "Extended statistics không giúp qua join" | **Có giúp gián tiếp**: sửa node lá thì node join đúng theo (2,36× → 1,8 %). Cái không giúp được là tương quan giữa **hai bảng** |
| 3 | "Cặp cột nào cũng nên tạo statistics cho chắc" | 3/4 cặp ở lab **hoàn toàn độc lập** (tỷ lệ 1,00) — tạo là lãng phí. Chỉ 1 cặp đáng |

Thêm hai điều đắt giá:
- **Sai số của phụ thuộc hàm = `1 / selectivity(cột thứ hai)`.** Cặp cột càng hiếm, sai số càng khủng: `postal_code/province` có thể sai **1.000 lần**.
- **`frequency / base_frequency` trong `pg_mcv_list_items` là công cụ chẩn đoán tốt nhất** — nó nói thẳng planner đang sai bao nhiêu lần cho từng tổ hợp.

---

## Áp dụng vào hệ thật

### Hai cặp cột trong schema IoT/SaaS điển hình

**Cặp 1: `city` / `district` (hoặc `province` / `city`)**

```sql
CREATE STATISTICS st_addr_geo (dependencies, ndistinct, mcv)
  ON province, city, district FROM address;
ANALYZE address;
```
- Quan hệ: phụ thuộc hàm hoàn toàn (district → city → province)
- **Planner đang sai ước lượng:** với ~700 city trên 63 province, `sel(province) ≈ 0,016` → sai **~63 lần** cho `WHERE province=? AND city=?`
- Ảnh hưởng: mọi màn hình lọc theo địa chỉ, và mọi join bắt đầu từ đó

**Cặp 2: `tenant_id` / `region` (hoặc `tenant_id` / `plan`)**

```sql
CREATE STATISTICS st_dev_tenant (dependencies, ndistinct, mcv)
  ON tenant_id, region FROM device;
ANALYZE device;
```
- Quan hệ: tenant thường triển khai ở **một** vùng → phụ thuộc gần hoàn toàn
- **Planner đang sai:** với 4 region, `sel(region) ≈ 0,25` → sai **~4 lần**
- Ảnh hưởng: query multi-tenant, tức gần như mọi query trong hệ

*(Ở lab này cặp `tenant_id/region` lại độc lập — tỷ lệ 1,00 — nên không đáng tạo. Đây là lý do phải **đo** chứ không đoán.)*

**Cặp 3 đáng xét thêm:** `status` / `end_ts IS NULL`, `device_type` / `protocol`, `order_status` / `payment_status`.

### Quy trình 4 bước — làm được ngay tuần này

```sql
-- ① Tìm ứng viên: cặp cột cùng bảng, mỗi cột 2..10.000 giá trị phân biệt
SELECT attname, n_distinct FROM pg_stats
WHERE tablename='<bảng>' AND n_distinct BETWEEN 2 AND 10000;

-- ② Đo mức phụ thuộc (đắt — chạy trên replica)
SELECT (SELECT count(*) FROM (SELECT DISTINCT a, b FROM t) s) AS to_hop_that;
-- so với n_distinct(a) × n_distinct(b). Tỷ lệ > 2 là đáng.

-- ③ Tạo với ĐỦ ba kind (mỗi kind sửa một loại query khác nhau)
CREATE STATISTICS st_x (dependencies, ndistinct, mcv) ON a, b FROM t;
ANALYZE t;

-- ④ Chứng minh bằng số
EXPLAIN SELECT ... WHERE a=? AND b=?;     -- trước/sau
SELECT values, round((frequency/NULLIF(base_frequency,0))::numeric,1) AS sai_may_lan
FROM pg_mcv_list_items((SELECT stxdmcv FROM pg_statistic_ext_data d
  JOIN pg_statistic_ext e ON e.oid=d.stxoid WHERE e.stxname='st_x'))
ORDER BY 2 DESC LIMIT 5;
```

### Ba lưu ý vận hành

1. **Khai đủ `(dependencies, ndistinct, mcv)`** trừ khi có lý do rõ ràng — mỗi kind sửa một loại query, và chi phí thêm không đáng kể.
2. **Phải `ANALYZE` sau khi tạo.** `CREATE STATISTICS` chỉ khai báo; dữ liệu thống kê chỉ có sau `ANALYZE`.
3. **Đừng tạo hàng loạt.** 3/4 cặp ở lab hoàn toàn độc lập. Mỗi statistics object làm `ANALYZE` chậm hơn và không được gì.

### Bonus rẻ tiền: statistics cho biểu thức

Nếu code có `WHERE lower(email) = ?`, `WHERE (meta->>'model') = ?`, `WHERE date_trunc('day', ts) = ?` — planner đang dùng hằng số 0,5 % và **sai ~98 %**:

```sql
CREATE STATISTICS st_users_email ON (lower(email)) FROM users;
CREATE STATISTICS st_dev_model   ON (meta->>'model') FROM device;
ANALYZE users, device;
```

**Không tốn dung lượng, không làm chậm ghi.** Đo được ở §7: sai số từ 98 % xuống 1 %. Đây có lẽ là thay đổi có tỷ lệ lợi ích/chi phí cao nhất của cả tuần 3.

---

## Câu hỏi mở sang các ngày sau

1. Ước lượng đã đúng — nhưng cost model có đúng không? `random_page_cost` ảnh hưởng plan thế nào? → **Day 14**
2. `GROUP BY` sai số nhóm 700 lần làm HashAgg spill — đo tận tay thế nào? → **Day 19**
3. Extended statistics không áp dụng cho generic plan — kiểm tra hệ mình bằng cách nào? → **Day 42**
4. Tương quan giữa cột của **hai bảng** thì làm sao? → không có cách trực tiếp; phải viết lại query hoặc dùng temp table (**Day 20**)
5. Sau 3 tuần, cho một plan xấu bất kỳ, chẩn đoán trong 1 phút được không? → **Day 15**
