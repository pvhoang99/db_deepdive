# Day 35 — Lời giải: Chọn mô hình lưu telemetry + ôn tuần 7

> Bài chữa. Hôm nay là **tài liệu thiết kế có số liệu**, không phải bài lý thuyết. Phương án A và B được dựng và đo thật trên lab (5.000.000 dòng gốc + 1.000.000 dòng ghi thêm). Phương án C (Cassandra) là phân tích — mọi con số về C đều được **đánh dấu rõ là ước lượng**, không phải đo.
>
> Kết luận một câu: **ở quy mô lab, A và B chênh nhau không đáng kể về đọc/ghi, nhưng chênh 193 lần ở chi phí xoá dữ liệu cũ — và đó mới là tiêu chí quyết định.**

---

## §0. Đề bài và dự đoán

| Tiêu chí | Dự đoán | Thực tế đo được | Đúng/Sai |
|---|---|---|---|
| Dung lượng: A hay B nhỏ hơn? | B nhỏ hơn (partition gọn hơn) | **A nhỏ hơn 24,4%** (439 MB vs 546 MB) — vì A dùng BRIN 48 kB thay cho B-tree `(ts)` 108 MB | ❌ |
| Write throughput | B chậm hơn (routing tuple) | **Gần bằng nhau** (~187k vs ~176k dòng/giây), chênh trong dao động đo | ~ |
| Q1 (giá trị mới nhất) | A nhanh hơn (1 index scan) | **A 0,018 ms vs B 0,026 ms** — A nhanh hơn nhưng cả hai đều dưới 0,03 ms | ✅ |
| Q3 (tổng hợp 1 giờ) | A nhanh hơn nhờ BRIN | **B nhanh hơn 3,2×** (0,88 vs 2,80 ms) — BRIN lossy phải recheck 14.608 dòng thừa | ❌ |
| Q4 (downsample 1 tháng) | Ngang nhau | **B nhanh hơn 1,8×** (361 vs 654 ms) — pruning cắt 2/3 dữ liệu phải quét | ❌ |
| Xoá 1 tháng | B nhanh hơn nhiều | **B nhanh hơn 193×** (46 ms vs 8.876 ms) | ✅ |

Ba dự đoán sai — và cả ba đều sai theo cùng một kiểu: **tôi đánh giá thấp việc "quét ít dữ liệu hơn" quan trọng đến mức nào so với "index nhỏ hơn"**.

---

## §1. Dựng hai phương án

```sql
-- A: bảng phẳng + BRIN
CREATE TABLE ts_a (LIKE ts_kv);
INSERT INTO ts_a SELECT * FROM ts_kv;                          -- 4.812 ms
CREATE INDEX ON ts_a USING brin(ts) WITH (pages_per_range=32);  --   334 ms
CREATE INDEX ON ts_a (device_id, ts);                           -- 2.633 ms

-- B: phân vùng theo tháng + B-tree
CREATE TABLE ts_b (LIKE ts_kv) PARTITION BY RANGE (ts);  -- 3 partition tháng
INSERT INTO ts_b SELECT * FROM ts_kv;                           -- 6.271 ms
CREATE INDEX ON ts_b (device_id, ts);                           -- 2.266 ms
CREATE INDEX ON ts_b (ts);                                      -- 1.492 ms
```

| | A: phẳng + BRIN | B: partition + B-tree |
|---|---|---|
| **Heap** | 289 MB | 288 MB (99 + 96 + 93) |
| **Index `(device_id, ts)`** | 150 MB | 150 MB (52 + 50 + 48) |
| **Index trên `ts`** | **48 kB** (BRIN) | **108 MB** (B-tree: 37 + 36 + 35) |
| **Tổng index** | **151 MB** | 258 MB |
| **TỔNG** | **439 MB** | **546 MB** |
| Chênh | 100% | **+24,4%** |
| Thời gian nạp + index | 7,8 s | 10,0 s |

**Toàn bộ chênh lệch 107 MB đến từ một chỗ duy nhất: B-tree trên `ts` (108 MB) vs BRIN trên `ts` (48 kB) — 2.300 lần.**

Heap giống hệt nhau (289 vs 288 MB). Partition **không** làm dữ liệu gọn hơn hay cồng kềnh hơn — nó chỉ chia file. Điều này quan trọng: mọi lợi/hại của partition đều nằm ở *vận hành* và *lượng dữ liệu phải quét*, không ở dung lượng lưu trữ.

Và BRIN nhỏ tới mức nó **miễn phí**: 48 kB trên bảng 289 MB = 0,016%. Đây là kết luận đã đo ở Day 31, hôm nay xác nhận lại trong bối cảnh so sánh kiến trúc.

> **Ghi chú thiết kế:** hai phương án này *không loại trừ nhau*. Có thể dùng partition + BRIN (bỏ B-tree trên `ts`) để có 439 MB **và** khả năng `DROP PARTITION`. §7 sẽ quay lại điểm này.

---

## §2. Write throughput

Nạp 500.000 dòng mới, đo 2 lần cho mỗi phương án, kèm WAL sinh ra (đo bằng hiệu `pg_current_wal_lsn()`).

| Lần | A: thời gian | A: WAL | B: thời gian | B: WAL |
|---|---|---|---|---|
| 1 | 2.639,6 ms → **189.400 dòng/s** | 113 MB | 2.427,5 ms → **205.900 dòng/s** | 116 MB |
| 2 | 2.694,9 ms → **185.500 dòng/s** | 110 MB | 3.409,6 ms → **146.600 dòng/s** | 145 MB |
| **Trung bình** | **~187.000 dòng/s** | ~112 MB | **~176.000 dòng/s** | ~130 MB |

**Kết luận: chênh lệch nằm trong dao động đo.** Partition không làm ghi chậm đi đáng kể — chi phí định tuyến tuple về partition đúng là ~vài chục nano giây, không đo được ở quy mô này. B sinh nhiều WAL hơn ~16% vì nó có **2 B-tree** phải cập nhật thay vì 1 B-tree + 1 BRIN.

### Phát hiện phụ quan trọng hơn cả kết quả chính

Lần chạy đầu tiên (trước khi tôi lọc dữ liệu cho công bằng), tôi nạp 500.000 dòng **trải đều khắp 3 tháng** thay vì tập trung một khoảng:

| | Dòng tập trung 1 khoảng | Dòng trải khắp bảng |
|---|---|---|
| Thời gian | 2.640 ms | **4.156 ms** |
| WAL | 113 MB | **316 MB — gấp 2,8×** |

**Cùng số dòng, cùng schema, chỉ khác thứ tự ghi — WAL gấp 2,8 lần.**

Nguyên nhân là **full-page writes**: sau mỗi checkpoint, lần đầu một page bị sửa, Postgres ghi **nguyên cả page 8 kB** vào WAL (để chống torn page). Ghi tuần tự thì mỗi page bị chạm một lần rồi được lấp đầy dần → ít full-page write. Ghi rải rác thì chạm hàng nghìn page khác nhau, mỗi page một full-page write 8 kB cho một dòng 30 byte.

**Đây là lý do kỹ thuật vì sao mọi hệ time-series đều muốn dữ liệu đến theo thứ tự thời gian**, và vì sao backfill dữ liệu lịch sử ra-vào lộn xộn lại tốn kém đến thế. Nó cũng là lý do LSM-tree (Cassandra) có lợi thế ghi: nó *luôn* ghi tuần tự vào cuối, không bao giờ sửa page cũ.

### 🔧 Tình huống thực tế — backfill làm replica lag 4 tiếng

Job backfill dữ liệu lịch sử chạy `INSERT ... SELECT` theo `device_id` (vì đó là cách chia lô tự nhiên trong code). Mỗi lô là một device với 2 năm dữ liệu → ghi rải khắp toàn bộ bảng. WAL từ 40 GB/ngày lên **300 GB/ngày**. Replica lag lên 4 tiếng, `archive_command` không kịp, `pg_wal` đầy đĩa, primary suýt dừng ghi.

Sửa: đổi chiều chia lô — **theo thời gian, không theo device**. Mỗi lô là một ngày, tất cả device. Cùng lượng dữ liệu, WAL về ~50 GB/ngày.

```sql
-- SAI: mỗi lô rải khắp bảng
INSERT INTO telemetry SELECT * FROM staging WHERE device_id = $1;
-- ĐÚNG: mỗi lô tập trung vào cuối bảng / một partition
INSERT INTO telemetry SELECT * FROM staging WHERE ts >= $1 AND ts < $1 + interval '1 day';
```

Phụ trợ: tăng `max_wal_size` để checkpoint thưa hơn → ít full-page write hơn (Day 37 sẽ đo trực tiếp).

---

## §3. Bốn mẫu query của IoT

Mỗi query chạy 3 lần, lấy số lần cuối (cache nóng).

| Query | PA | Plan | Planning | **Execution** | Buffers |
|---|---|---|---|---|---|
| **Q1** giá trị mới nhất của 1 device | A | `Index Scan Backward` trên `(device_id, ts)` + `Limit` | 0,033 ms | **0,018 ms** | **4** |
| | B | `Append` 4 partition + `Limit`, **3 partition `never executed`** | 0,083 ms | 0,026 ms | 4 |
| **Q2** 1 device, 1 key, 1 ngày | A | Bitmap Heap Scan + Sort | 0,059 ms | 0,053 ms | 34 |
| | B | Bitmap Heap Scan (prune còn `ts_b_06`) + Sort | 0,100 ms | **0,045 ms** | **33** |
| **Q3** tổng hợp toàn hệ 1 giờ | A | **BRIN** Bitmap Heap Scan, `Heap Blocks: lossy=126` | 0,062 ms | 2,803 ms | **135** |
| | B | `Index Scan` trên `ts_b_06_ts_idx` + HashAggregate | 0,093 ms | **0,884 ms** | 904 |
| **Q4** downsample 1 tháng theo giờ | A | **Seq Scan toàn bảng 6,9M dòng** + external sort | 0,091 ms | 654,1 ms | 44.350 |
| | B | Seq Scan **chỉ `ts_b_06`** + external sort | 0,151 ms | **360,8 ms** | **12.320** |

### Q1 — cả hai đều xuất sắc, nhưng vì lý do khác nhau

A: một `Index Scan Backward` trên `(device_id, ts)`, đọc 4 page, dừng ngay ở dòng đầu. 0,018 ms.

B thú vị hơn:
```
->  Append (actual rows=1 loops=1)
      ->  Index Scan Backward using ts_b_08_device_id_ts_idx on ts_b_08  (actual rows=1)
      ->  Index Scan Backward using ts_b_07_device_id_ts_idx on ts_b_07  (never executed)
      ->  Index Scan Backward using ts_b_06_device_id_ts_idx on ts_b_06  (never executed)
      ->  Index Scan Backward using ts_b_05_device_id_ts_idx on ts_b_05  (never executed)
```

**`Append` xếp partition theo thứ tự giảm dần của `ts` và dừng ngay khi có đủ 1 dòng.** Ba partition còn lại `never executed`. Đây là một tối ưu rất đẹp (`Ordered Append`, PG12+): nó biết `ts_b_08` chứa dữ liệu mới nhất nên tìm ở đó trước.

Điều kiện để nó hoạt động: `ORDER BY` phải khớp với khoá phân vùng, và **mọi partition phải có index cho phép đọc theo thứ tự đó**. Thiếu index ở một partition thôi là mất tối ưu và phải quét cả 4.

Chi phí duy nhất của B: planning 0,083 ms vs 0,033 ms (2,5×) vì phải xét 4 partition. Với 36 partition, planning là ~0,7 ms — **gấp 27 lần execution**. Đây là lý do Q1 (mẫu query phổ biến nhất của IoT dashboard) là mẫu mà partition **hại nhiều nhất**.

### Q3 — BRIN thua ở đây, và số buffer nói ngược với thời gian

Đây là kết quả bất ngờ nhất:

| | A (BRIN) | B (B-tree) |
|---|---|---|
| Execution | 2,803 ms | **0,884 ms** (nhanh 3,2×) |
| **Buffers** | **135** | 904 (nhiều hơn 6,7×) |
| Dòng thừa phải lọc | `Rows Removed by Index Recheck: 14.608` | 0 |
| Plan | Bitmap Heap Scan, `Heap Blocks: lossy=126` | Index Scan |

**B đọc nhiều page hơn 6,7 lần nhưng vẫn nhanh hơn 3,2 lần.** Lý do: `lossy` — BRIN chỉ biết "khoảng page này *có thể* chứa dữ liệu", nên phải đọc 126 block rồi lọc bỏ 14.608 dòng không thoả. Chi phí là **CPU đánh giá vị từ trên 16.913 dòng**, không phải I/O. B đọc 904 page nhưng mọi dòng đọc lên đều đúng, và 904 page đều nằm trong shared_buffers (`hit=904`, không `read`).

Bài học tổng quát: **`Buffers` là chỉ số tốt khi nghi ngờ I/O, nhưng khi mọi thứ nằm trong RAM thì thứ quyết định là số dòng phải đánh giá.** Đọc cả hai, đừng chỉ đọc một.

**Cảnh báo về kết quả này:** nó đúng ở lab với shared_buffers đủ lớn cho toàn bộ dataset. Trên hệ thật 2 TB với 64 GB RAM, 904 page ngẫu nhiên = 904 lần I/O đĩa và BRIN sẽ thắng ngược lại. **Đừng mang kết luận này lên production mà không đo lại với tỉ lệ cache thật.**

### Q4 — điểm partition thắng rõ nhất về đọc

A phải `Seq Scan` **toàn bộ 6,9 triệu dòng** để lấy 454.095 dòng của tháng 6: `Rows Removed by Filter: 5.545.905`. BRIN không giúp được vì query cũng lọc `key_id=1`, và planner chọn seq scan cho khoảng thời gian rộng (1 tháng = 1/3 bảng — đúng như Day 31 đã đo: BRIN chỉ thắng ở khoảng hẹp).

B chỉ quét `ts_b_06`: `Rows Removed by Filter: 1.212.573`. **Ít hơn 4,6 lần dòng phải đọc, ít hơn 3,6 lần buffer (12.320 vs 44.350), nhanh hơn 1,8 lần.**

Cả hai đều `Sort Method: external merge Disk: 11.568 kB` — tràn ra đĩa vì `work_mem` không đủ. Đây là chỗ có thể cải thiện chung cho cả hai (Day 17):
```sql
SET LOCAL work_mem = '64MB';   -- quicksort trong RAM thay vì external merge
```
Hoặc tốt hơn nữa: index trên `(key_id, ts)` cho phép `Incremental Sort`, hoặc **materialized view rollup theo giờ** — với báo cáo chạy hàng ngày thì rollup là câu trả lời đúng, không phải tối ưu query.

---

## §4. Chi phí xoá dữ liệu cũ — tiêu chí quyết định

Xoá cùng một lượng dữ liệu: tháng 5, 1.722.141 dòng.

### A: `DELETE`

| Bước | Thời gian | Dung lượng sau |
|---|---|---|
| `DELETE FROM ts_a WHERE ts < '2025-06-01'` | **1.811,3 ms** | 616 MB (không đổi) |
| `n_dead_tup` sau `DELETE` | — | **1.722.141** |
| `VACUUM ts_a` | 1.252,0 ms | **616 MB — vẫn không đổi**, dead → 0 |
| `VACUUM FULL ts_a` | **5.812,9 ms** | **376 MB** |
| **Tổng** | **8.876,2 ms** | thu hồi 240 MB |

### B: `DROP PARTITION`

| Bước | Thời gian | Dung lượng |
|---|---|---|
| `DROP TABLE ts_b_05` | **46,0 ms** | thu hồi ngay **188 MB** |

### Kết quả

| | A | B | Chênh |
|---|---|---|---|
| Thời gian | 8.876 ms | **46 ms** | **193×** |
| Dead tuple sinh ra | **1.722.141** | **0** | — |
| Đĩa thu hồi | chỉ sau `VACUUM FULL` | **ngay lập tức** | — |
| Khoá | `ACCESS EXCLUSIVE` 5,8 s (VACUUM FULL) | `ACCESS EXCLUSIVE` ~46 ms | 126× |
| WAL sinh ra | ~lượng dữ liệu xoá | ~0 | — |

**Đây là toàn bộ lý do tồn tại của phương án B.** Ba mục §1–§3 cho thấy A và B chênh nhau vài chục phần trăm, có khi A còn thắng. §4 chênh **193 lần** và tỉ lệ đó **tăng tuyến tính theo kích thước bảng** — trên bảng 400 GB, `DELETE + VACUUM FULL` là hàng giờ downtime, `DROP PARTITION` vẫn là ~50 ms.

Lưu ý về con số 46 ms: ở Day 33 tôi đo `DROP TABLE` partition trong một transaction rồi `ROLLBACK` → 0,836 ms. Hôm nay commit thật → 46 ms, vì nó phải unlink 3 file (heap + 2 index) và fsync thư mục. Cả hai đều đúng; **46 ms là con số thật của production**.

---

## §5. Cassandra — phân tích

> Phần này **không có số đo**. Mọi con số dưới đây là ước lượng dựa trên tài liệu và kinh nghiệm vận hành phổ biến, được đánh dấu **(ước lượng)**. Bạn cần điền số thật từ ThingsBoard của mình vào bảng cuối §5.

### Mô hình dữ liệu ThingsBoard

```
CREATE TABLE ts_kv_cf (
  entity_type text, entity_id uuid, key text, partition bigint,
  ts bigint, bool_v boolean, str_v text, long_v bigint, dbl_v double,
  PRIMARY KEY ((entity_type, entity_id, key, partition), ts)
);
```

- **Partition key** `(entity_type, entity_id, key, partition)` — quyết định node nào giữ dữ liệu. Cột `partition` là timestamp đã làm tròn (mặc định theo tháng, cấu hình bằng `TS_KV_PARTITIONING`).
- **Clustering key** `ts` — sắp xếp trong partition, cho phép range scan theo thời gian.

Đây thực chất là **cùng ý tưởng với Day 32–33**: chia dữ liệu theo thời gian để giới hạn lượng phải quét và để xoá theo khối. Chỉ khác là Cassandra làm nó ở tầng phân tán và tự động.

### LSM-tree vs B-tree — bản chất khác biệt

```
Cassandra (LSM):   Write → commit log + memtable (RAM, sorted)
                        → flush thành SSTable (bất biến, ghi TUẦN TỰ)
                        → compaction gộp SSTable, bỏ bản cũ + tombstone
                   Read  → phải hợp nhất N SSTable + memtable

Postgres (B-tree): Write → sửa page tại chỗ (GHI NGẪU NHIÊN vào index)
                        → WAL trước, page sau
                   Read  → một lần đi xuống cây
```

Điều này giải thích trực tiếp kết quả §2: **Postgres tốn 2,8× WAL khi ghi rải rác vì phải full-page-write các page cũ. Cassandra không bao giờ gặp vấn đề đó vì nó không sửa page cũ.** Đổi lại, Cassandra trả giá ở đọc (phải merge nhiều SSTable) và ở compaction (viết lại dữ liệu nhiều lần — write amplification).

### Bốn cạm bẫy vận hành

| Cạm bẫy | Triệu chứng | Phòng |
|---|---|---|
| **Tombstone** | `DELETE`/TTL tạo tombstone, chỉ dọn sau `gc_grace_seconds` (mặc định 10 ngày). Query quét qua > `tombstone_failure_threshold` (100.000) bị **abort**, không phải chậm — lỗi hẳn. | Dùng TTL + **TWCS** để cả SSTable hết hạn cùng lúc và bị **drop nguyên file** (không sinh tombstone). Không bao giờ `DELETE` từng dòng. |
| **Compaction backlog** | Ghi nhanh hơn compaction → SSTable chồng chất → đọc chậm dần, đĩa phình 3–5× dữ liệu thật | Theo dõi `nodetool compactionstats` (pending tasks), `nodetool tablestats` (SSTable count/read). Cấp đủ I/O. |
| **Compaction strategy sai** | `SizeTieredCompactionStrategy` (mặc định) trộn dữ liệu cũ với mới → dữ liệu 6 tháng trước vẫn bị viết lại mỗi lần compaction | **Bắt buộc `TimeWindowCompactionStrategy`** cho time-series, với `compaction_window_size` khớp granularity partition |
| **Wide partition** | Partition > 100 MB gây GC pressure, đọc chậm, node OOM | Cột `partition` trong PK chính là để chống điều này. Tính: `số key × tần suất × độ dài cửa sổ × ~40 byte` phải < 100 MB |

**Cạm bẫy tombstone là quan trọng nhất và ít người biết trước:** nó biến "xoá dữ liệu" — thao tác tưởng như vô hại — thành nguyên nhân downtime số một của Cassandra. Nó là bản đối ngẫu chính xác của bài học §4 hôm nay: Postgres `DELETE` để lại dead tuple làm bảng phình; Cassandra `DELETE` để lại tombstone làm query **fail**. Cả hai hệ đều có một lối thoát chung: **xoá theo khối bất biến** (`DROP PARTITION` / drop SSTable qua TWCS+TTL), không xoá theo dòng.

### Bảng cần bạn điền bằng số thật

```
[ ] Số device đang hoạt động:                    ______
[ ] Điểm dữ liệu/giây (đỉnh và trung bình):      ______ / ______
[ ] Dung lượng Cassandra hiện tại (nodetool status → Load): ______
[ ] Retention thật đang áp dụng:                 ______ ngày
[ ] Compaction strategy đang dùng:               ______   (kiểm tra: DESCRIBE TABLE ts_kv_cf)
[ ] Số node / replication factor:                ______ / ______
[ ] TS_KV_PARTITIONING đang là:                  ______   (MONTHS/DAYS/HOURS)
[ ] Partition lớn nhất (nodetool tablehistograms): ______
[ ] Đã gặp cạm bẫy nào trong 4 cái trên:         ______
```

Ba lệnh để lấy nhanh:
```bash
nodetool status                                    # Load mỗi node
nodetool tablestats thingsboard.ts_kv_cf           # SSTable count, partition size
nodetool tablehistograms thingsboard.ts_kv_cf      # phân bố partition size, latency p50/p95/p99
nodetool compactionstats                           # backlog
```

**Số quan trọng nhất phải lấy là điểm dữ liệu/giây.** Nó là biến quyết định toàn bộ khuyến nghị ở §7.

---

## §6. Bảng so sánh tổng hợp

| Tiêu chí | **A: PG phẳng + BRIN** | **B: PG partition** | **C: Cassandra** |
|---|---|---|---|
| Write throughput | **187.000 dòng/s** (đo, 1 node, batch) | **176.000 dòng/s** (đo) | ~10.000–50.000/s **mỗi node**, scale tuyến tính theo số node *(ước lượng)* |
| WAL / write amplification | 112 MB / 500k dòng (đo). **316 MB nếu ghi rải rác** | 130 MB / 500k dòng (đo) | ghi tuần tự, nhưng compaction viết lại 3–10× *(ước lượng)* |
| Dung lượng cho 5M dòng | **439 MB** (đo) | 546 MB (đo) | ~600–900 MB **×RF** *(ước lượng)* — RF=3 ⇒ ~2 GB |
| **Q1** giá trị mới nhất | **0,018 ms** | 0,026 ms | ~1–5 ms *(ước lượng, gồm network + coordinator)* |
| **Q2** 1 device, 1 ngày | 0,053 ms | **0,045 ms** | ~2–10 ms *(ước lượng)* — đây là mẫu Cassandra làm tốt nhất |
| **Q3** tổng hợp 1 giờ toàn hệ | 2,80 ms | **0,88 ms** | **không làm được** — phải quét mọi partition ⇒ Spark/analytics job |
| **Q4** downsample 1 tháng | 654 ms | **361 ms** | **không làm được** trong DB — cần Spark hoặc rollup ghi sẵn |
| Xoá 1 tháng dữ liệu cũ | **8.876 ms** + `VACUUM FULL` (khoá 5,8 s) | **46 ms** | TTL tự động, **nhưng sinh tombstone** trừ khi dùng TWCS |
| Query ad-hoc / JOIN / aggregate | **đầy đủ SQL** | **đầy đủ SQL** | **rất kém** — chỉ query theo partition key |
| Ràng buộc, transaction | đầy đủ | đầy đủ (trừ unique không chứa khoá phân vùng) | rất hạn chế, LWT đắt |
| Scale ngang | thủ công (Citus / sharding app) | thủ công | **native** |
| **Độ phức tạp vận hành (1–5)** | **1** | **2** (cần job quản lý partition) | **5** (compaction, repair, gc_grace, node replace) |
| Cần thêm hạ tầng | không | không (chỉ cron/Temporal) | cụm ≥3 node, JVM tuning, monitoring riêng |
| Chi phí nhân sự | thấp — mọi backend biết SQL | thấp | **cao** — cần người thật sự hiểu Cassandra |

Hai dòng cần đọc kỹ nhất là **Q3/Q4** và **độ phức tạp vận hành** — đó là hai chỗ chênh lệch không phải vài chục phần trăm mà là *khác loại*.

---

## §7. Khuyến nghị

*(Phần này viết như tài liệu gửi tech lead.)*

### A. Khuyến nghị

**Dùng Postgres phân vùng theo thời gian (phương án B), với BRIN thay cho B-tree trên `ts`** — cho tới khi vượt ngưỡng ở mục B.

Cụ thể là **B′ = B + BRIN**, lấy điểm mạnh của cả hai:

```sql
CREATE TABLE telemetry (...) PARTITION BY RANGE (ts);
CREATE INDEX ON telemetry (device_id, ts);          -- cho Q1, Q2 — bắt buộc
CREATE INDEX ON telemetry USING brin (ts)
  WITH (pages_per_range = 32);                       -- thay B-tree(ts): 48 kB thay vì 108 MB
```

Vì sao B′ chứ không phải A hay B thuần:

| | A | B | **B′** |
|---|---|---|---|
| Dung lượng | 439 MB | 546 MB | **~439 MB** |
| Xoá dữ liệu cũ | 8.876 ms | **46 ms** | **46 ms** |
| Q4 (quét theo tháng) | 654 ms | **361 ms** | **361 ms** — pruning làm việc, không cần index `ts` |
| Q3 (1 giờ) | 2,80 ms | **0,88 ms** | ~1–2 ms (BRIN trong 1 partition, khoảng hẹp — điểm mạnh của BRIN) |

Bên trong một partition tháng, dữ liệu đã sắp theo thời gian (correlation ≈ 1) nên BRIN hoạt động tối ưu; và pruning đã cắt sẵn 2/3 dữ liệu trước khi BRIN phải làm gì. **B-tree trên `ts` gần như thừa khi đã có partition theo `ts`** — đây là kết luận thiết kế quan trọng nhất của cả tuần 7.

Kèm theo:
- **Granularity:** tháng nếu retention ≥ 1 năm, tuần nếu retention 90 ngày. Mục tiêu: 10–100 GB/partition, **tổng < 200 partition** (Day 32 §5).
- **Job vòng đời** trên Temporal: `ensure_partitions(ahead=3)` + `drop_expired(retain, dry_run)` (Day 33 §4).
- **`DEFAULT` partition + alert khi nó khác rỗng.**
- **Rollup theo giờ** cho dữ liệu > 14 ngày — nhưng **đo `count(*)/count(DISTINCT nhóm)` trước** (Day 33 §5: ở lab tỉ lệ 1,33 khiến rollup vô dụng; với sampling 5 giây thì tỉ lệ 17.280 và rollup tiết kiệm 99,9%).

### B. Điều kiện lật ngược — cụ thể, đo được

Chuyển khỏi Postgres đơn node khi **bất kỳ** điều nào sau xảy ra:

| # | Ngưỡng | Cách đo | Chuyển sang |
|---|---|---|---|
| 1 | **Ingest > 50.000 điểm/giây** duy trì | `pg_stat_database.tup_inserted` chia theo thời gian | Cassandra, hoặc TimescaleDB phân tán, hoặc sharding theo tenant |
| 2 | **Dữ liệu sống > 5 TB** sau khi đã rollup | `pg_database_size` | như trên |
| 3 | **Không chịu được downtime khi mất 1 node** | yêu cầu nghiệp vụ | Cassandra (multi-master) — PG replica chỉ read-only, failover có gián đoạn |
| 4 | **Ghi phải tiếp tục khi đứt liên kết giữa 2 datacenter** | yêu cầu nghiệp vụ | Cassandra — đây là thứ Postgres về kiến trúc không cho được |
| 5 | **p99 ghi > SLO** dù đã tăng `max_wal_size`, tách WAL sang đĩa riêng, tắt synchronous replica | `pg_stat_statements` + wait events (Day 40) | Cassandra |

Ngưỡng 1 và 2 đo được bằng số. **Ngưỡng 3 và 4 là quyết định nghiệp vụ, không phải kỹ thuật — và chúng thường mới là lý do thật.** Nếu team đang chạy Cassandra vì lý do 4 thì mọi so sánh hiệu năng ở trên đều không liên quan.

Ước lượng: 50.000 điểm/giây × 30 byte = 1,5 MB/s = 130 GB/ngày dữ liệu thô. Ở retention 90 ngày với rollup, đó là ~2–4 TB. Tức **ngưỡng 1 và 2 thường chạm cùng lúc** — đó là điểm gãy tự nhiên.

### C. Phương án lai — khuyến nghị nếu đã có Cassandra

Nếu hệ hiện tại **đã** chạy ThingsBoard + Cassandra, đừng migrate ngược. Kiến trúc lai là đúng nhất:

```
Cassandra:  dữ liệu thô, độ phân giải đầy đủ, retention ngắn–trung (14–90 ngày)
            ← ingest tốc độ cao, TTL + TWCS
            ← phục vụ Q1/Q2 (dashboard theo device) — đúng thế mạnh

Postgres:   metadata (device, tenant, rule, alarm, user)  ← đã ở đó rồi
            + rollup theo giờ/ngày, retention dài (3 năm)
            + mọi query ad-hoc, JOIN, report, BI
            ← đúng thế mạnh: Q3/Q4, SQL, ràng buộc, transaction
```

| Ưu | Nhược |
|---|---|
| Mỗi hệ làm đúng việc nó giỏi | **Hai hệ phải vận hành, hai bộ backup, hai chỗ để hỏng** |
| Postgres chứa rollup nhỏ (theo Day 33 §5: ~0,2% nếu sampling 1 phút) → dễ dàng giữ 3 năm trên 1 node | Cần pipeline rollup Cassandra → Postgres, và pipeline đó phải **idempotent + có retry** |
| Query BI/report không đụng vào đường ingest | Dữ liệu ở Postgres trễ hơn (eventual) — phải nói rõ với người dùng dashboard |
| Migrate dần được, không big bang | Rủi ro lệch số liệu giữa hai hệ ⇒ cần job đối chiếu |

**Pipeline rollup là chỗ Temporal của bạn phù hợp nhất trong toàn bộ kiến trúc này**: một workflow chạy mỗi giờ, activity đọc Cassandra → tính rollup → upsert vào Postgres, với retry, idempotency key là `(device_id, key, gio)`, và visibility để biết giờ nào chưa chạy. Đây gần như đúng bài toán mẫu của Temporal.

Điều kiện chấp nhận: **định nghĩa rõ Postgres là nguồn sự thật cho *rollup*, Cassandra cho *dữ liệu thô*.** Không bao giờ để hai bên cùng là nguồn sự thật cho cùng một thứ.

### D. Nếu chọn Postgres — TimescaleDB có đáng không?

TimescaleDB về bản chất là: **partition tự động (hypertable) + rollup tự động (continuous aggregate) + nén cột (compression)** — đúng ba thứ bạn vừa tự làm ở Day 32–35.

| Việc | Tự làm (Day 32–33) | TimescaleDB |
|---|---|---|
| Tạo/xoá partition | hàm + Temporal workflow — **~200 dòng code, 2–3 ngày** | `create_hypertable()` + `add_retention_policy()` — **2 dòng** |
| Rollup | materialized view + job refresh + xử lý dữ liệu đến muộn — **1–2 tuần** để làm đúng | `CREATE MATERIALIZED VIEW ... WITH (timescaledb.continuous)` — tự cập nhật tăng dần |
| Nén | không có tương đương | **compression theo cột, thường 10–20×** ← đây là thứ không tự làm được |
| Vận hành | bạn hiểu từng dòng | thêm một extension vào đường quan trọng |

**Đánh giá:** thứ TimescaleDB cho mà bạn **không thể tự làm** là **compression** (10–20× dung lượng) và **continuous aggregate cập nhật tăng dần đúng cách** (xử lý dữ liệu đến muộn là bài toán khó thật sự). Hai thứ đó đáng giá.

Thứ nó cho mà bạn **vừa tự làm được** là partition + retention — tiết kiệm ~2 tuần công.

Chi phí ẩn cần cân nhắc:
- **Managed service:** RDS/Cloud SQL **không** hỗ trợ TimescaleDB. Phải tự vận hành hoặc dùng Timescale Cloud.
- **Licence:** compression và continuous aggregate nằm trong Timescale Community Licence (không phải Apache 2) — cấm cung cấp nó như một dịch vụ DBaaS. Với sản phẩm IoT bán cho khách thì phải đọc kỹ.
- **Nâng cấp:** upgrade major version Postgres phải phối hợp với version TimescaleDB.

**Khuyến nghị:** dùng TimescaleDB nếu (a) tự vận hành Postgres, (b) dung lượng là ràng buộc chính. Dùng partition thuần nếu (a) đang trên managed service, hoặc (b) muốn giữ đường phụ thuộc tối thiểu. **Với việc bạn đã hiểu partition từ trong ra ngoài sau tuần này, quyết định nào cũng an toàn — bạn không còn phụ thuộc vào "phép màu" của extension nữa.** Đó chính là giá trị của việc tự làm trước rồi mới chọn công cụ.

---

## §8. Ôn tuần 7

### A. Cây quyết định chọn index cho time-series

```
Bảng có dữ liệu theo thời gian?
│
├─ KHÔNG → quay lại Day 06–12 (index thường)
│
└─ CÓ
   │
   ├─ [1] CÓ CẦN XOÁ DỮ LIỆU CŨ ĐỊNH KỲ KHÔNG?
   │      │
   │      ├─ CÓ → PARTITION theo thời gian.  ← quyết định TRƯỚC mọi thứ khác
   │      │        (Day 33: DROP 46 ms vs DELETE+VACUUM FULL 8.876 ms = 193×)
   │      │        granularity: retention / ~100, tổng < 200 partition
   │      │
   │      └─ KHÔNG → bảng phẳng, sang [2]
   │
   ├─ [2] INDEX TRÊN CỘT THỜI GIAN:
   │      │
   │      ├─ Dữ liệu ghi theo thứ tự thời gian? (correlation > 0,9)
   │      │  │  kiểm tra: SELECT correlation FROM pg_stats WHERE attname='ts'
   │      │  │
   │      │  ├─ CÓ + đã partition theo ts → KHÔNG CẦN GÌ (pruning đã đủ)
   │      │  │                               hoặc BRIN nếu partition rộng
   │      │  ├─ CÓ + chưa partition       → BRIN (48 kB vs 108 MB = 2.300×)
   │      │  │                               pages_per_range: 32–128
   │      │  └─ KHÔNG (backfill, update)  → B-tree. BRIN sẽ VÔ DỤNG.
   │      │                                 (Day 31: correlation 1 → −0,39 sau VACUUM FULL)
   │      │
   │      └─ Cần ORDER BY ts LIMIT n (giá trị mới nhất)?
   │           → B-tree bắt buộc. BRIN không cho thứ tự.
   │
   ├─ [3] INDEX TRUY CẬP THEO ENTITY:
   │      → B-tree (device_id, ts) — LUÔN LUÔN, thứ tự này không đổi
   │        (Day 07 leftmost: (device_id, ts) phục vụ được cả device_id đơn lẻ,
   │         (ts, device_id) thì không phục vụ được device_id đơn lẻ)
   │      → thêm INCLUDE (dbl_v) nếu muốn index-only scan (Day 08)
   │
   ├─ [4] LỌC MỘT NHÁNH NHỎ THƯỜNG XUYÊN? (alarm chưa xử lý, device lỗi)
   │      → partial index: WHERE trang_thai = 'open'  (Day 08)
   │
   └─ [5] METADATA / THUỘC TÍNH LINH HOẠT (jsonb)?
          ├─ Query bằng = trên field CỐ ĐỊNH  → tách CỘT THẬT + B-tree
          │                                      (Day 34: nhanh 4,7×, index nhỏ 13,8×)
          ├─ Query linh hoạt, chỉ dùng @>      → GIN jsonb_path_ops
          ├─ Có dùng ? ?| ?&                   → GIN jsonb_ops
          └─ Có < > BETWEEN trên field số      → B-tree expression ((meta->>'x')::int)
                                                 GIN KHÔNG làm được bất đẳng thức
```

**Điểm mấu chốt của cả cây: nút [1] quyết định trước, và nó không phải câu hỏi về hiệu năng mà là câu hỏi về vận hành.**

### B. Ba điều tôi tưởng đúng mà hoá ra sai trong tuần 7

**1. "Partition làm query nhanh hơn."**

Sai. Day 32 đo: bảng phẳng thắng 3/4 query (12×, 2,1×, 1,26×), và khi cấp index tương đương thì **hoà** (9,15 vs 9,23 ms). Hôm nay xác nhận lại: A và B chênh nhau vài chục phần trăm ở đọc, có query A còn thắng.

Partition tăng tốc query **chỉ khi** nó cắt bớt lượng dữ liệu phải quét (Q4: 4,6× ít dòng hơn ⇒ 1,8× nhanh hơn). Nếu index đã làm được việc đó thì partition không thêm gì.

**Giá trị thật của partition là 193× ở chỗ xoá dữ liệu.** Nếu bảng của bạn không có retention, đừng partition.

**2. "Rollup luôn tiết kiệm dung lượng lớn."**

Sai. Day 33 đo: rollup theo ngày còn **58,59%** — gần như vô ích. Lý do: chỉ có **1,33 mẫu mỗi (device, key, ngày)** trong dataset lab.

Công thức đúng: *tỉ lệ nén ≈ số mẫu mỗi nhóm*. Sampling 5 giây ⇒ 17.280 mẫu/ngày ⇒ rollup còn 0,03%. Sampling 1 lần/ngày ⇒ rollup **to hơn** dữ liệu gốc (vì dòng rollup có thêm `n, avg, min, max`).

**Phải đo `count(*) / count(DISTINCT nhóm)` trước khi thiết kế rollup.** Tôi suýt thiết kế cả một pipeline rollup dựa trên giả định sai.

**3. "GIN index làm query jsonb nhanh."**

Sai một nửa. Day 34 đo: `meta->>'model' = 'TH-100'` **Seq Scan** dù có GIN — `->>` về nguyên tắc không index được bằng GIN. Và estimate rơi về hằng số mặc định **250 vs thật 12.445 (sai 50×)**.

Tệ hơn: một lệnh `UPDATE` toàn bảng làm GIN phình **9–11×** (552 kB → 4.952 kB), và `VACUUM` không co lại được.

Và cột thật thắng GIN **4,7× tốc độ, 13,8× kích thước index** — với document bị TOAST thì **62× tốc độ, 483× buffer**.

**Điểm chung của cả ba lỗi:** tôi đánh giá công cụ theo *tên gọi và danh tiếng* của nó ("partition = nhanh", "rollup = nén", "GIN = index cho jsonb") thay vì theo *cơ chế* nó hoạt động. Mỗi lần đo xong, lý do đều hiển nhiên. Đó chính là lý do phải đo.

---

## Bảng số liệu chính

| Phép đo | A (phẳng + BRIN) | B (partition + B-tree) |
|---|---|---|
| Heap | 289 MB | 288 MB |
| Index `(device_id, ts)` | 150 MB | 150 MB |
| Index trên `ts` | **48 kB (BRIN)** | **108 MB (B-tree)** — **2.300×** |
| **Tổng** | **439 MB** | **546 MB (+24,4%)** |
| Write throughput (trung bình 2 lần) | **~187.000 dòng/s** | ~176.000 dòng/s |
| WAL / 500k dòng | ~112 MB | ~130 MB |
| **WAL khi ghi rải rác vs tập trung** | **316 MB vs 113 MB — 2,8×** | — |
| Q1 giá trị mới nhất | **0,018 ms**, 4 buffer | 0,026 ms, 4 buffer, `Append` với 3/4 `never executed` |
| Q1 planning | **0,033 ms** | 0,083 ms (2,5×) |
| Q2 1 device 1 ngày | 0,053 ms, 34 buffer | **0,045 ms**, 33 buffer |
| Q3 tổng hợp 1 giờ | 2,803 ms, **135 buffer**, `lossy=126`, recheck bỏ 14.608 dòng | **0,884 ms**, 904 buffer |
| Q4 downsample 1 tháng | 654,1 ms, 44.350 buffer, lọc bỏ **5.545.905** dòng | **360,8 ms**, 12.320 buffer, lọc bỏ 1.212.573 dòng |
| **Xoá 1.722.141 dòng** | `DELETE` 1.811 ms + `VACUUM` 1.252 ms + `VACUUM FULL` 5.813 ms = **8.876 ms** | `DROP TABLE` **46 ms** |
| Dead tuple sinh ra | **1.722.141** | **0** |
| Đĩa sau `DELETE` + `VACUUM` | **616 MB — không đổi** | thu hồi ngay 188 MB |
| **Tỉ lệ** | | **193×** |

---

## Ba điều dễ hiểu sai

| Hiểu nhầm | Sự thật đo được |
|---|---|
| "Chọn giữa bảng phẳng và partition là chọn theo hiệu năng query." | Bốn query đại diện cho toàn bộ tải IoT chênh nhau 1,2–3,2× theo cả hai chiều — không đủ để quyết định gì. **Chi phí xoá dữ liệu chênh 193×**, và tỉ lệ đó tăng tuyến tính theo kích thước bảng. Câu hỏi đúng không phải "query nào nhanh hơn" mà **"tôi có phải xoá dữ liệu cũ không"**. |
| "Đã partition theo `ts` thì vẫn nên có B-tree trên `ts`." | B-tree trên `ts` tốn **108 MB** trong khi BRIN tốn **48 kB** — và bên trong một partition tháng, dữ liệu đã sắp theo thời gian nên BRIN đủ dùng. Pruning đã cắt sẵn 2/3 dữ liệu trước khi index phải làm gì. **B′ = partition + BRIN cho dung lượng của A và tốc độ xoá của B.** |
| "Ghi 500k dòng thì tốn WAL bằng nhau, bất kể ghi thế nào." | **113 MB nếu ghi tập trung một khoảng, 316 MB nếu ghi rải rác — 2,8×.** Nguyên nhân là full-page writes: page nào bị chạm lần đầu sau checkpoint đều bị ghi nguyên 8 kB vào WAL. Đây là lý do backfill phải chia lô **theo thời gian**, không theo `device_id`. |

---

## Áp dụng vào hệ thật

1. **Lấy con số quyết định trước tiên: điểm dữ liệu/giây và dung lượng sống.**
   ```sql
   -- Postgres
   SELECT tup_inserted FROM pg_stat_database WHERE datname = current_database();
   -- chạy 2 lần cách 60 giây, lấy hiệu chia 60
   ```
   ```bash
   nodetool tablestats thingsboard.ts_kv_cf | grep -E 'Local write count|Space used'
   ```
   Dưới 50.000/giây và dưới 5 TB ⇒ Postgres đủ, và mọi thứ còn lại là chi tiết.

2. **Nếu bảng có retention: partition. Nếu không: đừng.** Đây là câu hỏi duy nhất cần trả lời để quyết định. Kiểm tra nhanh xem hiện đang trả bao nhiêu tiền cho việc không partition:
   ```sql
   SELECT relname, n_live_tup, n_dead_tup,
          round(100.0*n_dead_tup/nullif(n_live_tup+n_dead_tup,0),1) AS pct_chet,
          pg_size_pretty(pg_total_relation_size(relid)) AS tren_dia
   FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 10;
   ```

3. **Dùng B′: partition + BRIN, bỏ B-tree trên cột thời gian.** Kiểm tra điều kiện trước (BRIN cần correlation cao):
   ```sql
   SELECT attname, correlation FROM pg_stats
   WHERE tablename='telemetry' AND attname='ts';   -- cần > 0,9
   ```
   Nếu correlation thấp vì backfill/update thì BRIN vô dụng — giữ B-tree.

4. **Sửa mọi job backfill để chia lô theo thời gian, không theo entity.** Tiết kiệm 2,8× WAL, và đó là WAL đi qua replication, archive, backup. Đây là thay đổi một dòng code cho lợi ích lớn nhất trong danh sách này.

5. **Đo tỉ lệ mẫu trước khi xây rollup:**
   ```sql
   SELECT count(*)::numeric / count(DISTINCT (device_id, key_id, ts::date)) AS mau_moi_nhom
   FROM telemetry WHERE ts >= now() - interval '7 days';
   ```
   < 10 ⇒ đừng làm. > 100 ⇒ đó là đòn bẩy lớn nhất bạn có.

6. **Nếu đã có Cassandra: đừng migrate ngược, làm kiến trúc lai.** Cassandra giữ thô + phục vụ dashboard theo device; Postgres giữ metadata + rollup + mọi query ad-hoc/BI. Pipeline rollup chạy trên Temporal với idempotency key `(device_id, key, gio)`.

7. **Kiểm tra ngay compaction strategy của Cassandra:**
   ```
   DESCRIBE TABLE thingsboard.ts_kv_cf;
   ```
   Nếu thấy `SizeTieredCompactionStrategy` trên bảng time-series ⇒ đổi sang `TimeWindowCompactionStrategy` ngay. Đây là lỗi cấu hình phổ biến nhất và đắt nhất của ThingsBoard mặc định.

8. **Ghi lại "điều kiện lật ngược" thành tài liệu có ngưỡng số**, và gắn alert vào các ngưỡng đó. Quyết định kiến trúc mà không có điều kiện lật ngược thì không phải quyết định — nó là niềm tin.

---

## Hết tuần 7 — nhìn lại

| Ngày | Câu hỏi trung tâm | Câu trả lời đo được |
|---|---|---|
| **31** | BRIN có thay được B-tree cho time-series? | Có, khi correlation cao: **48 kB vs 108 MB (2.300×)**. Nhưng `VACUUM FULL` phá correlation (1 → −0,39) và BRIN thành vô dụng. |
| **32** | Partition có làm query nhanh hơn? | **Không.** Bảng phẳng thắng 3/4; hoà khi index tương đương. `Subplans Removed` chỉ xuất hiện với generic plan. |
| **33** | Vậy partition để làm gì? | **`DROP` 46 ms vs `DELETE`+`VACUUM FULL` 8.876 ms — 193×**, và 0 dead tuple. Đó là toàn bộ lý do. |
| **34** | GIN có cứu được query jsonb? | Chỉ khi viết bằng `@>`. Cột thật thắng GIN **4,7×**, và **62×** nếu document bị TOAST. |
| **35** | Chọn mô hình nào? | Postgres partition + BRIN, cho tới 50k điểm/s hoặc 5 TB. Kiến trúc lai nếu đã có Cassandra. |

**Sang tuần 8: vận hành** — connection pooling (Day 36), WAL & checkpoint (Day 37 — sẽ đo trực tiếp hiện tượng full-page write ở §2 hôm nay), replication lag (Day 38), logical decoding & CDC (Day 39 — công cụ cho pipeline rollup ở §7C), wait events (Day 40).

---

### Dọn dẹp

```sql
DROP TABLE ts_a;
DROP TABLE ts_b CASCADE;
```
