# Day 17 — Lời giải: Hash Join & `work_mem`

> Bài chữa. Đo thật trên lab `SCALE=1`.

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án |
|---|---|---|
| 1 | `work_mem = 4MB` thì hash join `ts_kv × device` sinh bao nhiêu Batches? | **1** — build side chỉ 2.466 kB, thừa chỗ. Phải hạ xuống 1MB mới có Batches=2 |
| 2 | `Batches = 8` đắt hơn `Batches = 1` bao nhiêu lần? | Ở lab: **chỉ 1,22 lần** (137,9 vs 113,0 ms) — vì build side nhỏ. Xem giải thích |
| 3 | Planner chọn build side dựa vào gì? | **Kích thước byte ước lượng** (`rows × width`) — luôn chọn bên nhỏ hơn |

---

## §1. Hash join hoạt động thế nào

```
Hash Join  (actual rows=5000000 loops=1)
  Hash Cond: (k.device_id = d.id)
  ->  Seq Scan on ts_kv k  (actual rows=5000000)              <- PROBE side
  ->  Hash  (actual rows=50000 loops=1)                        <- BUILD side
        Buckets: 65536  Batches: 1  Memory Usage: 2466kB
        ->  Index Only Scan using device_pkey on device d
Execution Time: 1535,0 ms
```

**Cách đọc: node `Hash` bọc build side. Node còn lại (in trước, ở trên) là probe side.**

| | Build side (`device`) | Probe side (`ts_kv`) |
|---|---|---|
| rows | 50.000 | 5.000.000 |
| `Buckets` | **65.536** | — |
| `Batches` | **1** | — |
| `Memory Usage` | **2.466 kB** | — |

`Buckets = 65.536` là luỹ thừa 2 gần nhất ≥ 50.000 → trung bình **0,76 dòng mỗi bucket**. Đúng thiết kế.

### Join không phải `=` — hash join bất khả thi

```sql
EXPLAIN SELECT count(*) FROM device d JOIN tenant t ON d.tenant_id > t.id;
->  Nested Loop
      ->  Seq Scan on device d
      ->  Memoize (Cache Mode: binary)
            ->  Index Only Scan using tenant_pkey  Index Cond: (id < d.tenant_id)
```

**Planner chọn Nested Loop, không có lựa chọn nào khác.**

Lý do cơ bản: hash table tra được câu hỏi *"có key nào BẰNG x không"*, nhưng không tra được *"có key nào NHỎ HƠN x không"* — băm phá huỷ thứ tự.

| Điều kiện join | Hash Join | Merge Join | Nested Loop |
|---|---|---|---|
| `a = b` | ✅ | ✅ | ✅ |
| `a > b`, `a < b`, `BETWEEN` | ❌ | ✅ (nếu đã sắp) | ✅ |
| `a LIKE b`, hàm tuỳ ý | ❌ | ❌ | ✅ |

Chú ý `Cache Mode: binary` của Memoize ở đây — khác `logical` ở Day 16. Với điều kiện bất đẳng thức, Memoize so sánh key bằng byte thay vì bằng toán tử bằng.

---

## §2. `work_mem` — ba chữ phải thuộc lòng

```
work_mem        = 4MB
max_connections = 100
```

> **`work_mem` là per NODE, per CONNECTION, per WORKER.**

### Worst case của lab

| Kịch bản | Tính | Kết quả |
|---|---|---|
| 1 node, không parallel | 4 MB × 100 | **400 MB** |
| 3 node (2 sort + 1 hash) | 4 MB × 100 × 3 | **1,2 GB** |
| 3 node × parallel 2 worker | 4 MB × 100 × 3 × **(2+1)** | **3,6 GB** |
| 3 node × parallel 4 worker | 4 MB × 100 × 3 × **(4+1)** | **6,0 GB** |

Với `work_mem = 64MB` (giá trị nhiều người đặt "cho thoáng"): **96 GB**. Đủ để OOM mọi server tầm trung.

### `SET LOCAL` — kiểm chứng nó thật sự cục bộ

```sql
BEGIN;
SET LOCAL work_mem = '256MB';
SHOW work_mem;   -->  256MB
COMMIT;
SHOW work_mem;   -->  4MB        <- tự trả về sau COMMIT ✓
```

**`SET LOCAL` là công cụ đúng.** `SET` thường sẽ giữ tới hết session — và với connection pool, session đó được tái sử dụng cho request khác → **rò rỉ cấu hình sang request không liên quan**. Đây là bug rất khó tìm.

---

## §3. Batches — khi hash table không vừa RAM

| `work_mem` | `Buckets` | **`Batches`** | `Memory Usage` | **temp read/written** | **time** |
|---|---|---|---|---|---|
| **256kB** | 16.384 | **8** | 384 kB | **744 / 744** | **137,9 ms** |
| **1MB** | 65.536 | **2** | 1.498 kB | **421 / 421** | **129,5 ms** |
| **4MB** | 65.536 | **1** | 2.466 kB | **0 / 0** | **122,4 ms** |
| **64MB** | 65.536 | **1** | 2.466 kB | 0 / 0 | **113,0 ms** |

### ⚠️ `Batches: 8` chỉ đắt hơn `Batches: 1` **1,22 lần** — không phải "hơn 8 lần"

Đề bài dự kiến chênh lệch lớn. Số đo nói khác, và lý do rất đáng học.

### Bóc tách vì sao

Chi phí chia batch gồm **hai phần**, và ở đây chỉ phần nhỏ phát sinh:

| Phần | Ở lab | Trên production |
|---|---|---|
| **Build side ghi/đọc đĩa tạm** | 146 page = **1,2 MB** | có thể hàng GB |
| **Probe side ghi/đọc đĩa tạm** | **598 page = 4,8 MB** | **toàn bộ bảng lớn** |

Tổng temp chỉ **744 page = 6 MB**. Với I/O tạm ~0,003 ms/page (Day 03), đó là ~4 ms — đúng bằng chênh lệch quan sát được (137,9 − 122,4 = 15,5 ms, gồm cả băm hai lần).

**Vì sao probe side rẻ ở đây:** query lọc `ts` xuống chỉ **222.228 dòng** trước khi join. Đó là phần đã được thu hẹp, không phải cả 5 triệu dòng.

### Khi nào `Batches` mới thật sự giết query

Điều kiện: **probe side phải LỚN.**

```
Batches = 8, probe side = 5.000.000 dòng × 8 byte = 40 MB
  -> ghi 40 MB ra đĩa tạm + đọc lại 40 MB
  -> cộng thêm băm 5 triệu dòng lần hai
```

Với bảng thật hàng chục GB ở probe side, `Batches: 32` nghĩa là **toàn bộ bảng đi qua đĩa tạm một vòng** — và đó mới là thảm hoạ.

> **Cách đọc đúng `Batches > 1`: đừng nhìn số batch, hãy nhìn `temp read/written`. Đó mới là chi phí thật.**
>
> Ở lab: `temp 744 page = 6 MB` → vô hại.
> Trên production: `temp 5.000.000 page = 40 GB` → phải sửa ngay.

### Chi tiết đáng để ý: `Buckets` giảm khi `work_mem` nhỏ

```
work_mem 256kB : Buckets 16.384   Batches 8
work_mem 1MB   : Buckets 65.536   Batches 2
```

Postgres đánh đổi: ít bucket hơn (nhiều va chạm hơn) để dành chỗ cho dữ liệu. Với 50.000 dòng trong 16.384 bucket → **3,05 dòng/bucket** → mỗi lần probe phải duyệt trung bình 3 phần tử thay vì 1.

Đây là chi phí thứ hai của `work_mem` thiếu, ít người biết.

---

## §4. Build side — planner chọn thế nào

### Đổi thứ tự viết trong SQL: **không đổi gì cả**

| SQL viết | Build side | time |
|---|---|---|
| `FROM ts_kv k JOIN device d` | **`device`** | 1.480,1 ms |
| `FROM device d JOIN ts_kv k` | **`device`** | 1.518,3 ms |

**Y hệt nhau.** Cùng plan, cùng `Buckets: 65536`, cùng `Memory Usage: 2466kB`.

> **"Viết bảng nhỏ trước cho nhanh" là mê tín.** Planner tự ước lượng `rows × width` của cả hai bên rồi chọn bên nhỏ hơn làm build, hoàn toàn không quan tâm thứ tự anh viết.
>
> (Ngoại lệ: khi số bảng vượt `join_collapse_limit` = 8 — lúc đó thứ tự viết mới có ý nghĩa. Day 20.)

### Khi ước lượng sai kích thước build side

```sql
WHERE d.region='ap-southeast' AND d.country='VN' AND d.type='controller'
```

```
->  Seq Scan on device d  (cost=... rows=96) (actual rows=226)
```

Ước lượng **96** vs thật **226** — sai 2,35 lần (giả định độc lập, Day 13).

Nhưng planner **không chọn hash join** — nó chọn **Nested Loop**:

```
Nested Loop  (actual rows=24758 loops=1)
  ->  Seq Scan on device d  (rows=96) (actual rows=226)
  ->  Index Only Scan using idx_tskv_dev on ts_kv k  (loops=226)
Execution Time: 11,7 ms
```

Với build side ước lượng chỉ 96 dòng, nested loop rẻ hơn hẳn — và đó là lựa chọn **đúng** (11,7 ms).

**Bài học:** ước lượng sai kích thước build side thường không làm hash join tệ đi, mà làm planner **bỏ hash join** chuyển sang nested loop. Nếu ước lượng sai theo hướng ngược (đoán nhỏ mà thật lớn), nested loop sẽ nổ — đúng kịch bản Day 16 §6.

---

## §5. `Buckets` và hash collision

| Join key | `n_distinct` | `Buckets` | `Memory Usage` | **time** |
|---|---|---|---|---|
| `key_id` (**8 giá trị**) | 8 | **1.024** | **9 kB** | **1.084,2 ms** |
| `device_id` (**50.000 giá trị**) | 50.000 | **65.536** | 2.466 kB | **1.457,2 ms** |

### 💡 Kết quả ngược hoàn toàn với lý thuyết trong đề

Đề dự đoán: join theo `key_id` (8 giá trị) sẽ **tệ hơn** vì mọi dòng dồn vào 8 bucket.

Thực tế: join theo `key_id` **NHANH HƠN 26 %**.

### Vì sao — hiểu lại cho đúng

Điểm mấu chốt: **`Buckets` là số bucket cho BUILD side, không phải probe side.**

| | join `key_id` | join `device_id` |
|---|---|---|
| **build side** | `keys_small`: **8 dòng** | `device`: **50.000 dòng** |
| bucket cần | 1.024 (thừa thãi) | 65.536 |
| dòng/bucket | **8/1024 = 0,008** | 50.000/65.536 = 0,76 |
| hash table | **9 kB** — vừa L1 cache CPU | 2.466 kB — tràn L2 |

Build side chỉ có **8 dòng phân biệt** → hash table 9 kB → **nằm gọn trong L1 cache của CPU**. Mỗi lần probe là một lần tra cache siêu nhanh.

Với `device_id`, hash table 2,4 MB vượt L2 cache → mỗi lần probe là một lần cache miss.

### Vậy khi nào "ít giá trị phân biệt" mới là vấn đề

Khi **giá trị lặp nằm ở BUILD side**, không phải probe side:

```sql
-- TỆ: build side có 5 triệu dòng nhưng chỉ 8 key phân biệt
SELECT ... FROM keys_small s JOIN ts_kv k ON k.key_id = s.key_id
-- nếu planner chọn ts_kv làm build -> 5 triệu dòng dồn vào 8 bucket
-- -> mỗi bucket là danh sách 625.000 phần tử -> probe duyệt tuyến tính
```

Postgres tránh điều này bằng cách luôn chọn bên **nhỏ hơn** làm build. Nên trong thực tế nó hiếm khi xảy ra — trừ khi ước lượng sai nặng (§4).

> **Phát biểu lại cho đúng: hash join tệ khi BUILD SIDE có nhiều dòng trùng join key. Probe side trùng key bao nhiêu cũng không sao — thậm chí còn tốt vì hash table nhỏ, vừa cache CPU.**

---

## §6. Parallel Hash Join

| | không parallel | **parallel 4 worker** |
|---|---|---|
| Node | `Hash Join` + `Hash` | **`Parallel Hash Join` + `Parallel Hash`** |
| `Buckets` / `Batches` | 65.536 / 1 | 65.536 / 1 |
| `Memory Usage` | 2.466 kB | **2.528 kB** |
| buffers | 37.837 | 38.075 |
| **Execution Time** | **1.505,8 ms** | **371,1 ms** |
| **Tăng tốc** | 1,00× | **4,06×** |

**Nhanh hơn 4,06 lần với 5 tiến trình — hiệu suất 81 %.** Tốt hơn hẳn parallel seq scan thuần (Day 14: 3,75× với cùng 5 tiến trình).

### Vì sao `Parallel Hash` hiệu quả hơn

```
->  Parallel Hash  (actual rows=10000 loops=5)
      Buckets: 65536  Batches: 1  Memory Usage: 2528kB
      ->  Parallel Index Only Scan using device_pkey  (actual rows=16667 loops=3)
```

**Mỗi worker chỉ build một PHẦN hash table (10.000 dòng), và hash table nằm trong SHARED MEMORY** — dùng chung cho cả 5 tiến trình.

So với `Parallel Hash Join` của các DB khác (mỗi worker dựng bản sao riêng), cách này tiết kiệm cả RAM lẫn CPU.

### ⚠️ Hệ quả về bộ nhớ — điểm dễ nhầm nhất

> **Với `Parallel Hash`, giới hạn bộ nhớ là `work_mem × (số worker + 1)`, không phải `work_mem`.**

Ở đây: `4MB × 5 = 20MB` cho hash table dùng chung.

Nghe có vẻ nguy hiểm, nhưng thực ra **an toàn hơn**: nó là **một** hash table 20 MB dùng chung, thay vì 5 hash table × 4 MB riêng biệt. Tổng RAM giống nhau, nhưng khả năng tránh batch cao hơn nhiều.

Phân biệt trong plan:
- `Hash` → hash table riêng, giới hạn `work_mem`
- **`Parallel Hash`** → shared, giới hạn `work_mem × (worker+1)`

---

## §7. Chiến lược `work_mem` cho hệ thật

### Bốn bước

```
① Đặt work_mem toàn cục THẤP và an toàn: 4–16MB
   (theo công thức: RAM / (max_connections × 3 × (parallel+1)))

② Tìm query hay spill:
   SELECT substring(query,1,60), calls, temp_blks_written,
          pg_size_pretty(temp_blks_written*8192::bigint) AS temp
   FROM pg_stat_statements WHERE temp_blks_written > 0
   ORDER BY temp_blks_written DESC LIMIT 10;

③ Nâng riêng cho query đó — KHÔNG nâng toàn cục:
   BEGIN; SET LOCAL work_mem = '256MB'; <query>; COMMIT;
   -- hoặc theo role:
   ALTER ROLE report_user SET work_mem = '256MB';

④ Tách connection pool riêng cho worker báo cáo, với role có work_mem cao
```

### Vì sao `SET LOCAL` chứ không phải `SET`

Với connection pool (HikariCP, pgxpool, PgBouncer), một session được **tái sử dụng** cho nhiều request. `SET work_mem = '256MB'` sẽ **dính lại** trên connection đó và áp cho mọi request sau — kể cả API endpoint nhẹ.

Kết quả: 100 connection × 256 MB = **25,6 GB** thay vì 400 MB. Và bug này chỉ lộ ra khi tải cao.

`SET LOCAL` tự huỷ khi `COMMIT`/`ROLLBACK` — kiểm chứng ở §2.

*(Với PgBouncer transaction mode, `SET` thường còn nguy hiểm hơn: connection bị trả về pool giữa chừng, cấu hình đi theo.)*

### Bảng quyết định khi thấy `Batches > 1`

```
Thấy Batches > 1
│
├─ Xem temp read/written là bao nhiêu MB?
│   ├─ < 50 MB  -> BỎ QUA. Chi phí không đáng kể (đo được ở lab: 6MB = +12% thời gian)
│   └─ > 500 MB -> sang bước tiếp
│
├─ Build side có thể nhỏ hơn không?
│   ├─ Ước lượng sai (rows đoán << actual)? -> sửa thống kê (tuần 3)
│   ├─ SELECT * kéo cột thừa vào hash?      -> chỉ select cột cần, giảm width
│   └─ Có thể lọc build side sớm hơn?       -> đẩy WHERE xuống
│
├─ Có thể tránh hash join hoàn toàn không?
│   └─ Index trên join key + outer nhỏ -> nested loop (Day 16, nhanh hơn 43×)
│
└─ Cuối cùng mới: SET LOCAL work_mem cho query đó
```

**Thứ tự này quan trọng.** Tăng `work_mem` là bước **cuối**, không phải bước đầu.

---

## Bảng số liệu chính

| Kịch bản | Buckets | Batches | Memory | temp r/w | **time** |
|---|---|---|---|---|---|
| `ts_kv ⋈ device` toàn bộ | 65.536 | 1 | 2.466 kB | 0 | **1.535,0 ms** |
| join `>` (không phải `=`) | — | — | — | — | **Nested Loop** — hash bất khả thi |
| work_mem **256kB** | **16.384** | **8** | 384 kB | **744/744** | **137,9 ms** |
| work_mem 1MB | 65.536 | **2** | 1.498 kB | 421/421 | 129,5 ms |
| work_mem 4MB | 65.536 | **1** | 2.466 kB | **0** | 122,4 ms |
| work_mem 64MB | 65.536 | 1 | 2.466 kB | 0 | **113,0 ms** |
| **Batches 8 vs 1** | | | | | **chỉ chậm 1,22×** |
| đổi thứ tự SQL | 65.536 | 1 | 2.466 kB | 0 | **build side KHÔNG đổi** |
| join `key_id` (8 giá trị) | **1.024** | 1 | **9 kB** | 0 | **1.084,2 ms** |
| join `device_id` (50k giá trị) | 65.536 | 1 | 2.466 kB | 0 | 1.457,2 ms (**chậm hơn 26 %**) |
| **Parallel Hash Join** 4 worker | 65.536 | 1 | 2.528 kB | 0 | **371,1 ms (4,06×)** |
| `SET LOCAL work_mem` sau COMMIT | | | | | **tự về 4MB** ✓ |

---

## Ba điều dễ hiểu sai

| # | Hiểu nhầm | Sự thật đo được |
|---|---|---|
| 1 | "`Batches: 8` đắt hơn `Batches: 1` khoảng 8 lần" | Chỉ **1,22 lần** ở lab. Chi phí thật nằm ở **`temp read/written`**, không ở số batch |
| 2 | "Viết bảng nhỏ trước cho hash join nhanh hơn" | Đổi thứ tự SQL cho **plan y hệt**. Planner tự chọn build side theo `rows × width` |
| 3 | "Join key ít giá trị phân biệt làm hash join tệ" | Ngược lại: 8 giá trị → hash table **9 kB vừa L1 cache** → **nhanh hơn 26 %**. Chỉ tệ khi giá trị trùng ở **build side** |

Thêm hai điều:
- **`work_mem` thiếu còn làm giảm `Buckets`** (16.384 thay vì 65.536) → nhiều va chạm hơn → probe chậm hơn. Chi phí thứ hai ít người biết.
- **`Parallel Hash` dùng shared memory** — giới hạn là `work_mem × (worker+1)`, và đó là **ưu điểm**, không phải rủi ro.

---

## Áp dụng vào hệ thật

**1. Tính worst case `work_mem` cho DB production:**

```
worst_case = work_mem × max_connections × số_node_TB × (max_parallel_workers_per_gather + 1)
```

Ví dụ hệ 64 GB RAM, `shared_buffers = 16GB`:
```
work_mem an toàn = (64 − 16 − 2) GB / (100 × 3 × 3) = 51 MB
-> lấy 16-32MB cho biên an toàn
```

Nếu con số hiện tại vượt RAM khả dụng → hạ ngay, và dùng `SET LOCAL` cho job cần nhiều.

**2. Tìm query spill và đo xem có đáng sửa không:**

```sql
SELECT substring(regexp_replace(query,'\s+',' ','g'),1,70) AS q,
       calls,
       pg_size_pretty(temp_blks_written*8192::bigint) AS temp_tong,
       pg_size_pretty((temp_blks_written*8192/NULLIF(calls,0))::bigint) AS temp_moi_lan,
       round(total_exec_time::numeric/1000,1) AS tong_giay
FROM pg_stat_statements WHERE temp_blks_written > 0
ORDER BY temp_blks_written DESC LIMIT 10;
```

**Ngưỡng: `temp_moi_lan > 500 MB` mới đáng nâng `work_mem`.** Dưới đó, chi phí spill thường dưới 15 % thời gian query (đo được ở lab và ở Day 03 §6).

**3. Bật `log_temp_files = 0`** để mọi spill vào log kèm kích thước — cảnh báo sớm rẻ nhất.

**4. Với join bảng nhỏ × bảng lớn, ưu tiên nested loop + index thay vì hash join.** Day 16 đo được nhanh hơn **43 lần**. Hash join buộc phải quét toàn bộ bảng lớn.

**5. Bật parallel cho query báo cáo:** Parallel Hash Join cho **4,06×** với 4 worker — hiệu suất 81 %, tốt hơn hẳn parallel scan thuần. Nhưng nhớ nhân `work_mem` với `(worker+1)`.

**6. Đừng bao giờ `SET work_mem` (không có `LOCAL`) trong code đi qua connection pool.** Cấu hình sẽ dính lại trên connection và áp cho request khác.

---

## Câu hỏi mở sang các ngày sau

1. `Sort` cũng dùng `work_mem` — spill của nó khác spill của hash join thế nào? → **Day 18**
2. `HashAggregate` spill (PG13+) — `Planned Partitions` là gì? → **Day 19**
3. Một query có hash join + 2 sort + memoize thì `work_mem` chia thế nào? → **Day 19**
4. Merge join tốn 105.016 buffer (Day 16). Khi nào nó thắng hash join? → **Day 18**
5. `join_collapse_limit` và thứ tự join — khi nào thứ tự viết SQL mới có ý nghĩa? → **Day 20**
