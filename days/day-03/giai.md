# Day 03 — Lời giải: `BUFFERS` — đo I/O thay vì đo thời gian

> Bài chữa. Đo thật trên lab `SCALE=1`, sau Day 02 (đã có `idx_tskv_dev` và `idx_tskv_dev_key`).
> Bài này có 2 lần `docker restart pgdd` để tạo cache lạnh — thứ tự chạy quan trọng.

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án | Bẫy |
|---|---|---|---|
| 1 | `count(*) FROM ts_kv` đọc bao nhiêu buffer? | **36.958** (đúng bằng `relpages`) | Đa số đoán "ít thôi, có count mà" |
| 2 | Chạy lần 2 ngay sau thì `hit`/`read` đổi thế nào? | `read` → 0, `hit` → **toàn bộ**. **Tổng `hit+read` không đổi** | Đa số đoán tổng cũng giảm. Không — và đó chính là bài học hôm nay |

Câu 2 là toàn bộ tinh thần của Day 03. Đo được ở §4:

| | hit | read | **tổng** |
|---|---|---|---|
| lạnh | 82.314 | 5.784 | **88.098** |
| nóng lần 2 | 88.098 | 0 | **88.098** |
| nóng lần 3 | 88.098 | 0 | **88.098** |
| nóng lần 4 | 88.098 | 0 | **88.098** |
| sau prewarm | 88.098 | 0 | **88.098** |

**Tổng bất biến tuyệt đối qua 5 lần chạy.** Trong khi `Execution Time` dao động 181 → 213 ms (chênh 18 %) mà chẳng vì lý do gì cả.

> **Đó là lý do buffers đáng tin hơn ms: buffers đo LƯỢNG CÔNG VIỆC, ms đo ĐIỀU KIỆN MÔI TRƯỜNG.**

---

## §1. Postgres không đọc dòng, nó đọc page

```
  heap  | total_kể_cả_index | pages | rows_mỗi_page
--------+-------------------+-------+---------------
 289 MB | 368 MB            | 36958 | 135,3
```

| | |
|---|---|
| `ts_kv` heap | **36.958 page** = 289 MB |
| kể cả 2 index | 368 MB (index chiếm 79 MB = **27 %**) |
| dòng/page | **135,3** |

Kiểm tra chéo: 5.000.000 ÷ 135,3 = 36.955 ≈ 36.958 ✓

Mỗi dòng chiếm 8192 ÷ 135,3 = **60,5 byte** trên đĩa. Cấu trúc dòng: 23 byte tuple header + `device_id` 8 + `key_id` 2 + `ts` 8 + `dbl_v` 8 + `bool_v` 1 + `str_v` (NULL) + padding alignment ≈ 56–60 byte. Khớp.

### Hệ quả cần thấm

**Số page đọc, không phải số dòng trả về, quyết định query nhanh hay chậm.**

Chứng minh bằng chính số liệu Day 02:

| Trường hợp | Dòng trả về | Page phải đọc | dòng/page |
|---|---|---|---|
| `device_id = 7` (correlation ≈ 0) | 14.154 | **11.755** | **1,2** |
| quét tuần tự cả bảng | 5.000.000 | 36.958 | 135,3 |

Cùng một bảng, cùng kích thước dòng. Nhưng lấy 14.154 dòng nằm rải rác tốn 11.755 page — **1,2 dòng cho mỗi 8 KB đọc lên**. Đọc nguyên page 8 KB để lấy ~60 byte hữu ích: hiệu suất **0,7 %**.

Đây là gốc rễ của `correlation` (Day 04), `CLUSTER`, BRIN (Day 31), và partition (Day 32). Toàn bộ nghệ thuật là **xếp các dòng hay đọc cùng nhau vào cùng page**.

---

## §2. Ba tầng cache

```
 shared_buffers       = 256MB   (32.768 buffer × 8 KB)
 effective_cache_size = 1GB
 buffer đang dùng     = 32.768  (ĐẦY 100 %)
```

Bảng nào đang chiếm shared_buffers:

| relname | buffers | size |
|---|---|---|
| **ts_kv** | 31.275 | **244 MB** |
| device | 1.208 | 9,7 MB |
| pg_class | 42 | 336 kB |
| idx_tskv_dev | 37 | 296 kB |
| *(catalog vặt)* | ~200 | ~1,6 MB |

`ts_kv` chiếm **95,4 % toàn bộ shared_buffers**. Nhưng nó cần 36.958 page mà chỉ nhét được 31.275 → **luôn thiếu 5.683 page**, tức mỗi lần quét toàn bảng đều phải đọc lại ít nhất 15 %.

Con số này giải thích chính xác dòng `Buffers: shared hit=82314 read=5784` ở §4 — cái `read=5.784` không phải ngẫu nhiên, nó là **phần bảng không vừa cache**.

### Điểm rất dễ hiểu nhầm: `read` ≠ đọc đĩa

```
   Query
     ▼
① shared_buffers      256 MB  ← BUFFERS chỉ nhìn thấy tầng này
     ▼ miss = "read"
② OS page cache       RAM còn lại của máy (thường vài GB)
     ▼ miss
③ Đĩa thật
```

**`shared read` chỉ có nghĩa "không có trong shared_buffers".** Dữ liệu vẫn có thể đến từ OS page cache trong vài micro-giây.

Bằng chứng đo được ở §4:

| | read | I/O Timings | ms/page |
|---|---|---|---|
| lạnh (ngay sau restart) | 5.784 | 25,686 ms | **0,0044 ms** |

4,4 **micro**-giây cho một page 8 KB. NVMe tốt nhất cũng ~80 µs. Vậy 5.784 page đó **không hề đụng đĩa** — chúng đến từ OS page cache của host, vốn vẫn còn nguyên sau khi restart container (restart giết process Postgres, không xoá cache của Linux).

> **Muốn cache lạnh THẬT phải `echo 3 > /proc/sys/vm/drop_caches` trên host, không phải restart container.** Đây là lỗi benchmark rất phổ biến: người ta restart DB, tưởng đã lạnh, đo ra số đẹp giả.

`effective_cache_size = 1GB` là **lời khai** với planner: "tổng cache khoảng chừng này". Nó **không cấp phát một byte RAM nào**, chỉ dùng để tính cost của index scan (page đọc lại nhiều lần thì rẻ hơn). Đặt quá thấp → planner sợ index. Day 14 đo.

### 🔧 Tình huống thực tế

**Bối cảnh.** Server 64 GB RAM, `shared_buffers = 16GB`. Dashboard báo cache hit ratio **99,2 %** — đẹp. Nhưng p99 của API vẫn 2 giây.

**Vấn đề với cache hit ratio.** Nó là tỷ lệ toàn hệ thống, bị các query nhỏ chạy nhiều lần kéo lên. Một query hiếm nhưng quét 40 GB vẫn cho hit ratio tổng 99 % mà giết p99.

**Đo đúng chỗ — buffers theo từng query, không phải toàn hệ:**

```sql
SELECT
  round(total_exec_time::numeric/1000, 1)                 AS tong_giay,
  calls,
  round((shared_blks_hit + shared_blks_read) * 8.0 / 1024 / NULLIF(calls,0), 1) AS mb_moi_lan,
  round(100.0 * shared_blks_hit / NULLIF(shared_blks_hit + shared_blks_read, 0), 1) AS hit_pct,
  left(query, 80) AS query
FROM pg_stat_statements
WHERE shared_blks_hit + shared_blks_read > 0
ORDER BY (shared_blks_hit + shared_blks_read) DESC
LIMIT 15;
```

Sắp theo **tổng page đọc**, không theo thời gian. Query đứng đầu bảng này là query đang ăn hết shared_buffers của mọi người khác — kể cả khi bản thân nó không chậm.

**Quy tắc đặt `shared_buffers`:** 25 % RAM là điểm khởi đầu, không phải chân lý. Để phần còn lại cho OS page cache — Postgres cố tình dựa vào tầng 2. Đặt `shared_buffers` = 80 % RAM thường **chậm hơn** vì double buffering và checkpoint dồn cục.

---

## §3. Đọc các con số `BUFFERS`

### Kết quả — và một dị thường rất đáng đào

```
Aggregate  (actual time=185.557..185.558 rows=1 loops=1)
  Buffers: shared hit=88098
  ->  Index Only Scan using idx_tskv_dev_key on ts_kv  (actual rows=1362527 loops=1)
        Index Cond: (key_id = 1)
        Heap Fetches: 0
        Buffers: shared hit=88098
```

Đổi ra dung lượng: `88.098 × 8 ÷ 1024 = **688 MB**`.

So với §1: bảng heap 289 MB, index `idx_tskv_dev_key` 45 MB (5.811 page). **Query đọc 688 MB từ một index 45 MB.**

Con số đó lớn hơn cả bảng, lớn hơn index 15 lần. Nó nói gì?

### Kiểm chứng: ép Seq Scan để so

```
Seq Scan on ts_kv  (actual time=0.016..348.152 rows=1362527)
  Filter: (key_id = 1)
  Rows Removed by Filter: 3637473
  Buffers: shared hit=25373 read=11585      -- tổng 36.958 = 289 MB
Execution Time: 409.552 ms
```

| | Index Only Scan | Seq Scan |
|---|---|---|
| Buffers | **88.098** (688 MB) | **36.958** (289 MB) |
| Execution | **185,6 ms** | 409,6 ms |

Nghịch lý đẹp: index-only scan **đọc gấp 2,4 lần số buffer** nhưng **nhanh hơn 2,2 lần**.

### Vì sao — và cách đọc con số này cho đúng

Hai điều cần tách bạch:

**1. `Buffers` đếm LƯỢT TRUY CẬP buffer, không phải số page phân biệt.** Một page được chạm 10 lần thì cộng 10 vào `shared hit`. Kiểm chứng bằng một phép đo sạch — full index-only scan **không có điều kiện gì**, trên index `idx_tskv_dev` chỉ 4.345 page:

```
Index Only Scan using idx_tskv_dev on ts_kv  (actual rows=5000000)
  Heap Fetches: 0
  Buffers: shared hit=103794 read=5
```

103.794 lượt truy cập trên một index **4.345 page** = mỗi page chạm trung bình **23,9 lần**. Không có qual nào cả. Đây là bằng chứng dứt khoát: **`Buffers` là bộ đếm lượt, không phải bộ đếm page.**

Thêm bằng chứng: đổi `key_id = 1` thành `key_id IN (1,2,3)` → buffers nhảy từ 88.098 lên **208.164** (2,36 lần) trong khi index không hề to ra. Số lượt tăng vì scan chạy nhiều lượt hơn.

**2. Lượt truy cập vào page đã nằm sẵn trong shared_buffers thì rất rẻ** — chỉ là tra hash + tăng pin count, không có syscall, không có I/O. Đó là vì sao 88.098 lượt "hit" nhanh hơn 36.958 lượt trong đó 11.585 phải `read`.

### 💡 Quy tắc đọc buffers cho đúng, sửa lại mẹo trong đề

Đề bài gợi ý: *"nếu số MB query đọc xấp xỉ kích thước bảng thì nó đang quét toàn bảng, dù plan ghi chữ Index Scan"*. Mẹo này **đúng chiều nhưng không đủ** — số đo hôm nay cho thấy buffers có thể **vượt xa** kích thước bảng.

Phát biểu chính xác hơn:

| Cái cần so | Với | Kết luận |
|---|---|---|
| `shared read` (không phải hit) | kích thước object | **read** mới là I/O thật sự tốn kém |
| `hit + read` giữa **hai plan của cùng query** | nhau | plan nào làm ít việc hơn |
| `hit + read` với **số dòng trả về** | — | tỷ lệ càng cao càng lãng phí |

Và luật vàng vẫn giữ nguyên: **so buffers giữa hai plan của CÙNG query. Đừng diễn giải con số tuyệt đối.**

> Chi tiết `Heap Fetches: 0` và cơ chế đếm lượt của index-only scan là nội dung **Day 06** (cấu trúc B-tree, fanout) và **Day 08** (visibility map). Ở đây chỉ cần nhớ: con số buffers lớn bất thường trên index-only scan không tự động nghĩa là plan tệ — phải so `read` và so với plan thay thế.

---

## §4. Cache lạnh vs cache nóng

### Bảng 6 dòng

| Trạng thái | hit | read | **tổng** | I/O time | exec time |
|---|---|---|---|---|---|
| **lạnh** (sau restart) | 82.314 | **5.784** | 88.098 | 25,686 ms | **208,7 ms** |
| nóng lần 2 | 88.098 | 0 | 88.098 | — | 181,5 ms |
| nóng lần 3 | 88.098 | 0 | 88.098 | — | **213,1 ms** |
| nóng lần 4 | 88.098 | 0 | 88.098 | — | 194,0 ms |
| `pg_prewarm('ts_kv')` | — | — | (nạp 36.958 page, 137 ms) | — | — |
| sau prewarm | 88.098 | 0 | 88.098 | — | 185,8 ms |

### Ba điều đọc ra từ bảng này

**1. `read` giảm 5.784 → 0, nhưng ms gần như không giảm (208,7 → 181,5 = chỉ 13 %).**

Vì I/O time chỉ có 25,7 ms trong tổng 208,7 ms = **12 %**. 88 % còn lại là CPU. Xoá sạch I/O cũng chỉ cứu được 12 %.

**Bài học chống lãng phí:** trước khi đi mua đĩa nhanh hơn hay tăng RAM, đọc dòng `I/O Timings`. Nếu nó là 12 % thì đĩa nhanh gấp đôi cũng chỉ cứu 6 %.

**2. Ba lần chạy nóng liên tiếp — hoàn toàn giống nhau về mọi mặt — cho 181,5 / 213,1 / 194,0 ms. Dao động 17 %.**

Không có nguyên nhân nào cả: cùng plan, cùng buffers, cùng dữ liệu, cùng máy. Chỉ là nhiễu OS scheduler, CPU frequency, NUMA.

> **Nếu anh "tối ưu" được một query từ 213 ms xuống 181 ms, anh chưa tối ưu gì cả. Anh vừa đo trúng nhiễu.** Muốn tuyên bố cải thiện, cần biên độ vượt hẳn 17 %, và cần buffers thay đổi.

**3. `pg_prewarm` không giúp gì ở đây (185,8 vs 181,5 ms) — và vì sao.**

`pg_prewarm('ts_kv')` nạp 36.958 page **của heap**. Nhưng plan đang dùng **index-only scan**, `Heap Fetches: 0` — nó không đụng heap một dòng nào. Prewarm sai đối tượng.

Muốn prewarm đúng: `SELECT pg_prewarm('idx_tskv_dev_key');`

Đây là bài học vận hành thật: sau khi failover hoặc restart, script warm-up phải nhắm vào **đúng object mà plan dùng** — thường là index, không phải heap. Prewarm nhầm chỗ vừa tốn thời gian vừa **đẩy dữ liệu hữu ích ra khỏi shared_buffers**.

### 🔧 Tình huống thực tế

**Bối cảnh.** Cluster Postgres HA, failover lúc 2 giờ sáng. Replica lên làm primary. 20 phút sau, mọi API p99 tăng 15 lần rồi từ từ về bình thường.

**Nguyên nhân.** `shared_buffers` của replica lạnh tanh. Mọi query đều `read` thay vì `hit`.

**Cách xử lý, theo thứ tự ưu tiên:**

```sql
-- 1. Bật lưu/khôi phục cache tự động qua restart (PG có sẵn, mặc định BẬT)
SHOW shared_preload_libraries;   -- pg_prewarm nếu muốn autoprewarm
-- postgresql.conf:
--   shared_preload_libraries = 'pg_prewarm'
--   pg_prewarm.autoprewarm = on
--   pg_prewarm.autoprewarm_interval = 300s
-- -> ghi danh sách block đang nóng ra file mỗi 5 phút, nạp lại khi khởi động
```

```sql
-- 2. Warm-up thủ công sau failover: nhắm INDEX của các bảng nóng nhất
SELECT pg_prewarm(indexrelid::regclass::text)
FROM pg_stat_user_indexes
WHERE idx_scan > 100000
ORDER BY idx_scan DESC LIMIT 20;
```

```sql
-- 3. Kiểm tra sau khi warm: bảng nào đang chiếm cache
SELECT c.relname, count(*) AS buffers, pg_size_pretty(count(*)*8192::bigint)
FROM pg_buffercache b JOIN pg_class c ON b.relfilenode = pg_relation_filenode(c.oid)
GROUP BY 1 ORDER BY 2 DESC LIMIT 10;
```

**Điểm dễ bỏ sót:** đừng prewarm hết mọi thứ. `shared_buffers` có hạn; nạp bảng lịch sử 200 GB sẽ đẩy bảng nóng ra ngoài và làm mọi thứ tệ hơn.

---

## §5. Vì sao buffers đáng tin hơn mili-giây

### Ba dòng số liệu — cái bẫy tự dựng

| # | Trạng thái | Plan | hit | read | **tổng buffer** | time |
|---|---|---|---|---|---|---|
| 1 | cache **lạnh**, KHÔNG index | Seq Scan | 0 | **3.705** | 3.705 | **29,8 ms** |
| 2 | cache **nóng**, VẪN không index | Seq Scan | 3.705 | 0 | **3.705** | **16,8 ms** |
| 3 | **có index**, cache nóng | Index Only Scan | 1 | 10 | **11** | **1,16 ms** |

### Nếu chỉ nhìn ms thì kết luận sai ở đâu

Kịch bản của một người chỉ đo ms: chạy lần 1 (29,8 ms), tạo index, chạy lần 3 (1,16 ms), báo cáo **"index giúp nhanh 25,7 lần"**.

Sai ở chỗ: **giữa lần 1 và lần 3 có HAI thay đổi**, không phải một — cache đã nóng lên *và* có index. Tách ra:

| Nguồn cải thiện | Bằng chứng |
|---|---|
| cache nóng lên (dòng 1 → 2) | 29,8 → 16,8 ms = **1,8 lần**, **không đổi một dòng code nào** |
| index thật sự (dòng 2 → 3) | 16,8 → 1,16 ms = **14,5 lần** |

**Báo cáo "25,7 lần" thổi phồng gần gấp đôi.** Trong đó 1,8 lần là quà tặng của cache, sẽ biến mất ngay khi query đó không được chạy trong vài phút.

### Buffers tố cáo điều đó thế nào

Nhìn cột `tổng buffer` là mọi thứ lộ ra ngay:

```
dòng 1:  3.705      ┐
dòng 2:  3.705      ┘ y HỆT NHAU -> KHÔNG có gì thay đổi, chỉ là cache
dòng 3:     11        giảm 337 lần -> ĐÂY mới là index
```

Dòng 1 và 2 có **cùng con số buffer tuyệt đối**. Buffers không quan tâm cache nóng hay lạnh — nó đếm công việc. Công việc không đổi = không có cải thiện thật.

Còn dòng 3: **3.705 → 11 buffer, giảm 337 lần**. Đó là cải thiện thật, và nó sẽ giữ nguyên dù cache nóng hay lạnh, dù máy đang tải hay rảnh.

> **Buffers giảm = cải thiện thật. ms giảm mà buffers không đổi = anh vừa đo lại cái cache.**

Chú ý thêm: index-only scan đọc **11 buffer** để trả 9.989 dòng. `Heap Fetches: 0` — không chạm heap lần nào, vì `count(*)` chỉ cần biết dòng tồn tại và visibility map nói "cả page này đều nhìn thấy được". Day 08 đào sâu.

Phân bố `severity` giải thích vì sao index ăn đứt: `CRITICAL` chỉ **4,99 %** (9.989/200.000). Lọc còn 5 % là vùng index thắng tuyệt đối. Day 04 tìm đúng ngưỡng lật.

### Nguyên tắc benchmark

1. **Hoặc đo tất cả khi cache nóng, hoặc tất cả khi lạnh. Đừng trộn.** Thực tế nên đo nóng — vì production hầu như luôn nóng.
2. **Chạy mỗi biến thể ít nhất 3 lần, lấy trung vị.** §4 cho thấy nhiễu 17 %.
3. **Báo cáo buffers trước, ms sau.** ms chỉ để kiểm tra chéo.
4. **Chỉ đổi một biến mỗi lần.** Cái bẫy trên sinh ra vì đổi hai biến cùng lúc.
5. **Dán cả `SETTINGS`** khi chia sẻ plan — không có `work_mem` thì mọi lời khuyên là đoán mò.

---

## §6. `temp` — cờ đỏ quan trọng nhất

### Bảng 3 mức `work_mem`

| work_mem | Sort Method | Disk / Memory | temp read/written | shared read | **exec time** |
|---|---|---|---|---|---|
| **4MB** | `external merge` | **Disk: 159.312 kB** | **39.820 / 39.898** | 36.958 | **2.963,6 ms** |
| **64MB** | `external merge` | Disk: 159.248 kB | **19.906 / 19.910** | 36.894 | **2.595,4 ms** |
| **512MB** | `quicksort` | **Memory: 384.823 kB** | **0 / 0** | 36.926 | **2.659,5 ms** |

`temp written` đổi ra dung lượng: `39.898 × 8 ÷ 1024 = **312 MB** ghi ra đĩa tạm` ở mức 4 MB.

### 💡 Kết quả phản trực giác — và nó dạy điều quan trọng nhất §6

Kỳ vọng thông thường: tăng `work_mem` 128 lần (4 MB → 512 MB) thì query phải nhanh hẳn.

Thực tế: **2.963 ms → 2.659 ms. Cải thiện 10 %.** Và mức 64 MB (vẫn spill!) còn **nhanh hơn** mức 512 MB không spill (2.595 vs 2.659 ms).

Bóc tách vì sao:

| Thành phần | Thời gian |
|---|---|
| `Seq Scan` đọc 289 MB | ~500 ms (cả 3 mức đều vậy) |
| sắp xếp 5 triệu dòng | ~2.100 ms (CPU thuần, **không tránh được**) |
| ghi/đọc 312 MB đĩa tạm | ~150 ms (`temp write 99,7 ms + read 51,0 ms`) |

**Chi phí spill chỉ chiếm ~150/2.963 = 5 % query.** 95 % còn lại là công sắp xếp thuần tuý — thứ mà `work_mem` không giúp được gì.

Và ở mức 512 MB, `quicksort` phải cấp phát + chạm 384 MB RAM (page fault, cache miss L3 liên tục), đủ để **ăn hết** phần tiết kiệm từ việc bỏ spill.

Từ 4 MB lên 64 MB thì `temp` giảm đúng một nửa (39.898 → 19.910) — vì số merge pass giảm — nhưng `Disk` vẫn 159 MB. Đó là bằng chứng: `Disk:` là **kích thước dữ liệu cần sort**, còn `temp read/written` là **tổng lưu lượng qua các lượt merge**. Hai con số khác nhau, đừng lẫn.

> **Bài học: `work_mem` không phải nút vặn thần kỳ. Trước khi tăng nó, hãy đo xem spill chiếm bao nhiêu % thời gian thật.** Ở đây là 5 % — nghĩa là cách sửa đúng không phải tăng RAM mà là **xoá hẳn node Sort bằng index** (Day 18).

### Vì sao `temp` vẫn là cờ đỏ đáng chú ý hơn `read` cao

Dù ở lab này spill chỉ tốn 5 %, `temp` vẫn nguy hiểm hơn `read` vì bốn lý do — và lý do thứ ba là lý do thật sự:

| | `shared read` cao | `temp written` cao |
|---|---|---|
| Đối tượng | dữ liệu **thật**, sẽ được dùng lại | dữ liệu **rác**, dùng xong vứt |
| Cache | OS page cache đỡ được | ghi thẳng, không ai cache hộ |
| **Nhân lên theo connection** | không — mọi người **chia sẻ** shared_buffers | **có — `work_mem` là PER NODE PER CONNECTION** |
| Ổ đĩa | đọc | **ghi** — tốn IOPS ghi, mài SSD, cạnh tranh với WAL |

**Vế thứ ba là chỗ giết server thật.** `work_mem = 512MB` với 100 connection, mỗi connection có query 3 node sort:

```
512 MB × 100 connection × 3 node = 150 GB RAM
```

Server 64 GB. Kết cục: OOM killer giết postmaster, **toàn bộ database chết**, không phải một query chậm.

Đây là lý do lab cố ý đặt `work_mem = 4MB`, và là lý do **không bao giờ đặt `work_mem` cao ở cấp global**. Đặt cho đúng session cần:

```sql
-- trong job báo cáo, không phải trong postgresql.conf
SET LOCAL work_mem = '256MB';    -- LOCAL: tự hết hiệu lực khi commit
SELECT ... ORDER BY ...;
```

Hoặc gán theo role:

```sql
ALTER ROLE etl_user SET work_mem = '256MB';   -- chỉ job ETL, không phải API
```

### 🔧 Tình huống thực tế

**Bối cảnh.** Service báo cáo Java, mỗi đêm chạy 20 job song song, mỗi job một query `GROUP BY` lớn. Thỉnh thoảng server OOM. `work_mem` đang là 128 MB global.

**Chẩn đoán, không cần đoán:**

```sql
-- ai đang spill và bao nhiêu
SELECT queryid,
       temp_blks_written * 8 / 1024 AS temp_mb_tong,
       calls,
       round(temp_blks_written * 8.0 / 1024 / NULLIF(calls,0), 1) AS temp_mb_moi_lan,
       left(query, 80)
FROM pg_stat_statements
WHERE temp_blks_written > 0
ORDER BY temp_blks_written DESC LIMIT 20;
```

```sql
-- theo dõi realtime: có ai đang ghi file tạm không
SELECT pid, temp_files, temp_bytes FROM pg_stat_database WHERE datname = current_database();
```

Và bật log để bắt tận tay:
```
log_temp_files = 0      -- log MỌI file tạm, kèm kích thước
```

**Ba cách sửa, xếp theo thứ tự nên thử:**

1. **Xoá node Sort/Hash bằng index** — sửa gốc, không tốn RAM. `ORDER BY x` + index trên `x` = không còn Sort. Day 18.
2. **Giảm `width`** — `SELECT *` kéo cả `str_v` vào sort. Chỉ select cột cần → dữ liệu cần sort nhỏ đi, có thể vừa `work_mem` mà không tăng gì.
3. **`SET LOCAL work_mem`** cho đúng job đó, kèm giới hạn số job song song. Công thức an toàn:
   ```
   work_mem ≤ (RAM khả dụng − shared_buffers − 2GB cho OS) ÷ (max_connections × số node sort trung bình)
   ```
   Với 64 GB, `shared_buffers` 16 GB, 100 connection, 2 node: `(64−16−2)/200 = 230 MB`... và đó là **worst case tuyệt đối**. Thực tế nên chia thêm 4 lần để có biên an toàn → ~56 MB.

---

## Bảng số liệu chính

| Kịch bản | node plan chính | actual time | shared hit/read | temp r/w | ghi chú |
|---|---|---|---|---|---|
| `key_id=1` lạnh | Index Only Scan | 208,7 ms | 82.314 / 5.784 | 0 | I/O chỉ 12 % thời gian |
| `key_id=1` nóng (×3) | Index Only Scan | 181,5 / 213,1 / 194,0 ms | 88.098 / 0 | 0 | **tổng buffer bất biến**, ms nhiễu 17 % |
| `key_id=1` ép Seq Scan | Seq Scan | 409,6 ms | 25.373 / 11.585 | 0 | ít buffer hơn nhưng chậm hơn 2,2× |
| `alarm CRITICAL` lạnh, không index | Seq Scan | 29,8 ms | 0 / 3.705 | 0 | baseline |
| `alarm CRITICAL` nóng, không index | Seq Scan | 16,8 ms | 3.705 / 0 | 0 | **cùng buffer**, nhanh 1,8× — cache thôi |
| `alarm CRITICAL` có index | Index Only Scan | **1,16 ms** | 1 / 10 | 0 | buffer giảm **337×** |
| `ORDER BY dbl_v` work_mem=4MB | Sort external merge | 2.963,6 ms | 3 / 36.958 | **39.820 / 39.898** | Disk 159 MB |
| `ORDER BY dbl_v` work_mem=64MB | Sort external merge | **2.595,4 ms** | 64 / 36.894 | 19.906 / 19.910 | vẫn spill mà nhanh nhất |
| `ORDER BY dbl_v` work_mem=512MB | Sort quicksort | 2.659,5 ms | 32 / 36.926 | **0 / 0** | hết spill, **không nhanh hơn** |

---

## Ba điều dễ hiểu sai

| # | Hiểu nhầm | Sự thật đo được |
|---|---|---|
| 1 | "`shared read` = đọc đĩa" | `read` chỉ nghĩa "không có trong shared_buffers". Đo được **4,4 µs/page** — đó là OS page cache, không phải đĩa |
| 2 | "ms giảm = tối ưu thành công" | §5: 29,8 → 16,8 ms (1,8 lần) mà **buffers y hệt 3.705**. Chỉ là cache nóng lên |
| 3 | "Tăng `work_mem` là hết spill là nhanh" | §6: tăng 128 lần chỉ nhanh 10 %, và mức 64MB (còn spill) **nhanh hơn** mức 512MB (hết spill) |

Thêm hai điều tinh vi:

- **`Buffers` đếm lượt truy cập, không phải page phân biệt.** Full index scan trên index 4.345 page báo 103.794 buffer. Đừng diễn giải con số tuyệt đối; hãy so giữa hai plan.
- **Restart container KHÔNG cho cache lạnh thật** — OS page cache của host vẫn còn. Muốn lạnh thật phải `drop_caches` trên host.

---

## Áp dụng vào hệ thật

**1. Đổi thứ tự báo cáo khi tối ưu query.** Trước: "từ 800 ms xuống 40 ms". Sau:

```
Trước: Seq Scan, 36.958 buffer (289 MB), temp 0,   840 ms
Sau:   Index Only Scan, 388 buffer (3 MB), temp 0,  12 ms
       -> buffers giảm 95 lần. ms giảm 70 lần (đo nóng, 5 lần, trung vị).
```

Con số buffers là thứ review được; con số ms thì không.

**2. Bật `log_temp_files = 0` trên production.** Mọi spill sẽ vào log kèm kích thước. Đây là cảnh báo sớm rẻ nhất có thể có.

**3. Đừng đặt `work_mem` cao ở global.** Dùng `SET LOCAL` trong job, hoặc `ALTER ROLE ... SET work_mem` cho role báo cáo. Nhớ công thức nhân với `max_connections`.

**4. Script warm-up sau failover phải nhắm vào index, không phải heap** — §4 cho thấy prewarm heap chẳng giúp gì khi plan dùng index-only scan. Hoặc đơn giản hơn: bật `pg_prewarm.autoprewarm = on`.

**5. Thêm panel Grafana "top query theo tổng page đọc"**, tách khỏi panel "top query theo thời gian". Hai bảng này khác nhau, và bảng page mới chỉ ra ai đang ăn hết cache của người khác.

**6. Quy tắc benchmark viết vào wiki của team:** đo nóng, ≥3 lần, lấy trung vị, chỉ đổi một biến, báo cáo buffers trước. Cái bẫy §5 là bẫy mà **ai cũng dính ít nhất một lần**.

---

## Câu hỏi mở sang các ngày sau

1. `device_id=7` lấy 14.154 dòng từ 11.755 page (1,2 dòng/page). Ngưỡng nào thì seq scan thắng index? → **Day 04**
2. Index-only scan báo 88.098 buffer trên index 5.811 page — cơ chế đếm và `Heap Fetches` hoạt động ra sao? → **Day 06, Day 08**
3. `Sort` chiếm 2.100/2.963 ms. Index nào xoá được hẳn node Sort, và cái giá của nó? → **Day 18**
4. `ts_kv` cần 36.958 page nhưng shared_buffers chỉ chứa 31.275 — luôn thiếu 15 %. Partition có giúp không? → **Day 32**
5. `work_mem` per node per connection: đo tận tay worst case với 100 client thế nào? → **Day 17, Day 36**
