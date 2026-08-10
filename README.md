# Postgres Deep Dive — 48 ngày

Chương trình tự học Postgres từ mức "biết dùng SQL" lên mức **debug được production**: nhìn `EXPLAIN (ANALYZE, BUFFERS)` là biết vì sao chậm và sửa được.

Dành cho backend engineer đã vững kiến trúc application (DDD, CQRS, microservice) nhưng chưa đào sâu tầng database.

**Nhịp:** 60–90 phút/ngày × 5 ngày/tuần × ~10 tuần. Ba ngày capstone cuối (46–48) cần 90–120 phút. Không cần kinh nghiệm DBA.

---

## Bắt đầu trong 3 phút

```bash
git clone <repo> && cd database_deepdive
make up
make seed SCALE=1      # 50k device, 5M telemetry, 200k alarm (~18 giây)
cat days/day-01/README.md
```

Yêu cầu: Docker + Docker Compose. Không cần cài Postgres trên máy.

**Kết nối:** `postgresql://postgres:postgres@localhost:5433/lab`

---

## Lời giải

Mỗi ngày có bài chữa chi tiết ở `days/day-XX/giai.md` — mọi con số đo thật trên lab, kèm tình huống thực tế.
Xem mục lục và các con số đáng nhớ ở **[LOI-GIAI.md](LOI-GIAI.md)**.

> Làm bài trước, viết `writeup.md` của bạn, **rồi mới** mở `giai.md` để đối chiếu.

---

## Cách học

Mỗi ngày là một file `days/day-XX/README.md` theo cấu trúc **xen kẽ**:

```
§0. Đoán trước        ← viết dự đoán vào writeup TRƯỚC khi chạy lệnh nào
§1. Lý thuyết  → Làm ngay → Ghi vào writeup
§2. Lý thuyết  → Làm ngay → Ghi vào writeup
...
Kết ngày: áp dụng vào hệ thật + tiêu chí "Đạt khi"
```

Đọc một khái niệm → gõ tay kiểm chứng ngay → ghi số liệu → mục tiếp theo. Không đọc hết rồi mới làm.

### Bốn luật

1. **Đoán trước khi chạy.** Chỗ bạn đoán sai chính là chỗ mô hình tư duy đang lệch — đó là phần giá trị nhất.
2. **Con số, không tính từ.** "Nhanh hơn" không tính. "p95 840ms→12ms, shared read 41k→388 buffer" mới tính.
3. **Nộp 3 file** vào `days/day-XX/`: `lab.sql` (mọi lệnh đã chạy, kể cả sai), `output.txt`, `writeup.md`.
4. **Ngày ôn là bắt buộc.** Day 05/10/15/20/25/30/35/40/45 — không được bỏ để chạy tiếp bài mới.

### Chấm bài

Repo có sẵn skill `/review-bai` cho Claude Code. Gõ `/review-bai` (hoặc `/review-bai 07`) — nó đọc bài, **tự chạy lại kiểm chứng** số liệu bạn ghi, chấm theo rubric 5 tiêu chí (ngưỡng đạt 7/10), chỉ ra chỗ hiểu sai, và ghi kết quả vào `PROGRESS.md`.

Không dùng Claude Code thì tự chấm theo mục "Đạt khi" ở cuối mỗi ngày.

---

## Nội dung

| Tuần | Chủ đề | Ngày |
|---|---|---|
| **1** | **Công cụ đo** — 4 giai đoạn của query, cost model, đọc plan, bẫy `loops`, BUFFERS vs ms, 4 kiểu scan, `pg_stat_statements` | [01](days/day-01/) [02](days/day-02/) [03](days/day-03/) [04](days/day-04/) [05](days/day-05/) |
| **2** | **Index B-tree** — cấu trúc page & fanout, leftmost rule, index-only scan & visibility map, partial/expression index, bloat & REINDEX | [06](days/day-06/) [07](days/day-07/) [08](days/day-08/) [09](days/day-09/) [10](days/day-10/) |
| **3** | **Planner & statistics** — `pg_stats`, MCV & histogram, sai số lan truyền, custom vs generic plan, `CREATE STATISTICS`, cost model | [11](days/day-11/) [12](days/day-12/) [13](days/day-13/) [14](days/day-14/) [15](days/day-15/) |
| **4** | **Join, sort, aggregate** — nested loop & Memoize, hash join & batches, external sort, HashAgg spill, join order & CTE | [16](days/day-16/) [17](days/day-17/) [18](days/day-18/) [19](days/day-19/) [20](days/day-20/) |
| **5** | **MVCC & vacuum** — xmin/xmax tận mắt, dead tuple & bloat, autovacuum tuning, HOT update & fillfactor, XID wraparound | [21](days/day-21/) [22](days/day-22/) [23](days/day-23/) [24](days/day-24/) [25](days/day-25/) |
| **6** | **Isolation & locking** — 3 level, lost update / write skew / phantom, `SKIP LOCKED`, deadlock, SSI & retry | [26](days/day-26/) [27](days/day-27/) [28](days/day-28/) [29](days/day-29/) [30](days/day-30/) |
| **7** | **Time-series & IoT** — BRIN, partitioning & pruning, retention & ATTACH/DETACH, jsonb & GIN, chọn mô hình lưu trữ | [31](days/day-31/) [32](days/day-32/) [33](days/day-33/) [34](days/day-34/) [35](days/day-35/) |
| **8** | **Vận hành** — connection pooling, WAL & checkpoint, replication lag, logical decoding & CDC, wait events | [36](days/day-36/) [37](days/day-37/) [38](days/day-38/) [39](days/day-39/) [40](days/day-40/) |
| **9** | **Đổi schema an toàn** — TOAST, plan cache ở tầng driver, lock của DDL, expand/contract & backfill, diễn tập migration | [41](days/day-41/) [42](days/day-42/) [43](days/day-43/) [44](days/day-44/) [45](days/day-45/) |
| **10** | **Capstone** — audit lab & chẩn đoán, sửa & trả giá, audit production thật | [46](days/day-46/) [47](days/day-47/) [48](days/day-48/) |

Chi tiết từng ngày: [ROADMAP.md](ROADMAP.md)

---

## Dataset

Mô phỏng hệ IoT telemetry (kiểu ThingsBoard). `make seed 1` tạo:

| Bảng | Dòng | Ghi chú |
|---|---|---|
| `ts_kv` | 5.000.000 | telemetry, append-only, `ts` correlation = 1 |
| `device` | 50.000 | metadata + `meta jsonb` |
| `alarm` | 200.000 | ~5% còn active |
| `device_attr` | ~100.000 | thuộc tính |
| `tenant`, `ts_key_dict` | nhỏ | tra cứu |

Dữ liệu **cố ý cài bẫy** để các bài học lộ ra:

- `device.type` lệch 90/9/1 → MCV và selectivity (Day 11)
- `region` ↔ `country` phụ thuộc hàm hoàn toàn → `CREATE STATISTICS` (Day 13)
- `ts.correlation = 1`, `device_id.correlation ≈ 0` → điểm hoà vốn index (Day 04), BRIN (Day 31)
- `device_id` phân bố power-law → ước lượng sai (Day 12)
- 5% alarm `end_ts IS NULL` → partial index (Day 09)
- `work_mem = 4MB` cố ý nhỏ → thấy được spill, external sort, bitmap lossy

Seed dùng hàm băm tất định thay vì `random()` → **dataset tái lập 100%** giữa các lần seed, nên số liệu before/after so sánh được.

Muốn dữ liệu lớn hơn: `make seed 2` (gấp đôi).

---

## Lệnh hay dùng

```bash
make up
make seed SCALE=[scale]   # nạp dữ liệu (mặc định scale=1)
make psql
make q SQL="select 1"
make run F=file.sql
make s1
make s2
make day N=07         # tạo thư mục bài ngày 7
make logs
make nuke
```

Trong psql, ghi output ra file để nộp bài:
```sql
\timing on
\o /days/day-XX/output.txt
-- ... chạy bài ...
\o
```

---

## Cấu trúc repo

```
├── README.md              file này
├── ROADMAP.md             chi tiết 48 ngày
├── PROGRESS.md            bảng điểm
├── docker-compose.yml     Postgres 17, cấu hình cố ý nhỏ để thấy spill
├── Makefile                mọi lệnh của lab
├── seed/                  schema + sinh dữ liệu
├── days/
│   ├── _template/         mẫu writeup.md và lab.sql
│   └── day-XX/
│       ├── README.md      bài học (lý thuyết xen bài tập)
│       ├── lab.sql        bạn điền
│       ├── writeup.md     bạn điền
│       └── output.txt     sinh ra từ \o
└── .claude/skills/review-bai/    skill chấm bài
```

---

## Học nhóm

Nếu team cùng làm:

- Mỗi người fork hoặc tạo branch riêng `hoc/<tên>`, commit bài mỗi ngày
- Cuối tuần họp 30 phút: mỗi người trình bày **một** thứ mình đoán sai và vì sao
- Phần "Áp dụng vào hệ thật" ở cuối mỗi ngày nên thảo luận chung — đó là chỗ chuyển kiến thức thành hành động
- Day 46-48 (capstone) nên làm chung: một người audit, những người khác review như tech lead

Đừng so tốc độ. Người làm chậm mà ghi đủ số liệu học được nhiều hơn người chạy hết 48 ngày trong 2 tuần.

---

## Tài liệu tra cứu

Đọc song song, **không đọc một lèo**:

- **PostgreSQL 14 Internals** — Egor Rogov (PDF miễn phí). Tuần 1–5 map gần như 1-1.
- **CMU 15-445** — Andy Pavlo (YouTube). Xem *sau* khi làm bài, để thấy cái mình vừa đo.
- **Database Internals** — Alex Petrov. Phần B-tree vs LSM cho tuần 7.
- **Docs Postgres** — mục "Performance Tips", "Explicit Locking", "Routine Vacuuming", "Logical Decoding", "ALTER TABLE" (phần ghi chú về rewrite). Ngắn, đọc thật.
- **Use The Index, Luke** — use-the-index-luke.com. Bổ trợ tuần 2.

---

## Sau 48 ngày

Đây là **Tier 1** của kế hoạch 3 tier:

- **Tier 1 — Database** (chương trình này)
- **Tier 2 — Performance engineering**: pprof / async-profiler, flame graph, Go GMP & GC tuning, JVM G1/ZGC, tail latency p99/p999, backpressure & load shedding
- **Tier 3 — Distributed systems từ nguyên lý**: MIT 6.824 Raft labs, consistency models, Kafka sâu, mini LSM-tree storage engine

Đừng nhảy cóc. Tier 2 chỉ có nghĩa khi bạn đã đọc được plan và đo được I/O.
