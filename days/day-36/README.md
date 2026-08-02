# Day 36 — Connection pooling: vì sao 500 connection giết Postgres

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

```sql
\timing on
\o /days/day-36/output.txt
```

---

## §0. Đoán trước

1. Throughput đạt đỉnh ở bao nhiêu connection trên máy của bạn (bao nhiêu core)?
2. Từ 100 lên 500 connection, throughput tăng hay giảm?
3. Pool size nên đặt bao nhiêu cho service Java/Go của bạn?

---

## §1. Mỗi connection là một process

### Lý thuyết

Postgres dùng mô hình **process-per-connection** (không phải thread). Mỗi connection mới là một `fork()` của postmaster.

Chi phí mỗi connection:

| Khoản | Lượng |
|---|---|
| Bộ nhớ cơ bản (process + catalog cache + plan cache) | ~5–10 MB |
| `work_mem` khi query cần sort/hash | × số node × số worker |
| Một slot trong `PGPROC` array | ảnh hưởng mọi thao tác quét snapshot |
| Chi phí tạo (fork + khởi tạo) | ~1–5 ms |

Chi phí ẩn quan trọng nhất là khoản thứ ba: nhiều thao tác nội bộ của Postgres phải **duyệt danh sách mọi process đang chạy** (lấy snapshot, tìm lock, tính `xmin` nhỏ nhất). Chi phí đó tăng theo số connection và xảy ra dưới **spinlock** — nên với hàng trăm connection, các core dành phần lớn thời gian tranh nhau lock thay vì làm việc thật.

Đây là lý do đường cong throughput có **đỉnh rồi đi xuống**, chứ không phải bão hoà phẳng.

### Làm ngay

```sql
SHOW max_connections;
SELECT count(*) FROM pg_stat_activity;
SELECT state, count(*) FROM pg_stat_activity GROUP BY 1;

-- bộ nhớ mỗi backend (xấp xỉ)
SELECT pid, backend_type,
       pg_size_pretty(
         (SELECT sum(used_bytes) FROM pg_backend_memory_contexts WHERE pid IS NOT DISTINCT FROM NULL)
       ) AS note
FROM pg_stat_activity LIMIT 1;

SELECT * FROM pg_backend_memory_contexts ORDER BY total_bytes DESC LIMIT 5;
```

Xem từ phía OS:
```bash
docker exec pgdd ps -eo pid,rss,cmd | grep postgres | head -20
```

**Ghi vào writeup:** mỗi backend process chiếm bao nhiêu RSS? Với 500 connection thì tổng bao nhiêu?

---

## §2. Đường cong throughput — đo thật

### Làm ngay

```bash
docker exec pgdd pgbench -U postgres -d lab -i -s 20    # khởi tạo dữ liệu pgbench
nproc                                                    # máy có mấy core
```

Chạy ma trận:
```bash
for c in 1 2 4 8 16 32 64 128 256; do
  echo "=== $c clients ==="
  docker exec pgdd pgbench -U postgres -d lab -c $c -j 8 -T 12 -M prepared -S 2>&1 \
    | grep -E 'tps|latency average|initial connection'
done
```

(`-S` = chỉ SELECT, để đo thuần CPU/lock không bị I/O ghi che mất.)

Rồi chạy lại với workload có ghi (bỏ `-S`) ở vài mức: 8, 32, 128.

**Ghi vào writeup — bảng:** clients | tps (read-only) | latency trung bình | tps (read-write).

Vẽ xu hướng: **đỉnh ở đâu? Sau đỉnh throughput giảm bao nhiêu %?**

---

## §3. Little's Law và hàng đợi

### Lý thuyết

```
L = λ × W
số request trong hệ = tốc độ đến × thời gian ở trong hệ
```

Hệ quả cho database: khi số connection đang chạy vượt số core, các request **không** chạy song song — chúng xếp hàng, chỉ là hàng đợi nằm trong OS scheduler thay vì trong pool của bạn.

Và hàng đợi trong OS scheduler **tệ hơn** hàng đợi trong pool:
- Context switch liên tục
- Cache CPU bị đá ra liên tục
- Tranh chấp spinlock trong Postgres tăng theo bình phương

Từ lý thuyết hàng đợi: khi utilization ρ tiến tới 1, thời gian chờ tiến tới vô hạn theo `W ≈ 1/(1−ρ)`. Ở ρ = 0.8 thời gian chờ đã gấp 5 lần thời gian phục vụ; ở ρ = 0.95 là 20 lần.

**Kết luận thực hành: giới hạn số connection ĐANG CHẠY, để phần chờ nằm ở pool.** Pool nhỏ + hàng đợi tường minh cho throughput cao hơn và p99 tốt hơn nhiều so với pool lớn.

Công thức pool size phổ biến (từ tài liệu HikariCP):
```
pool_size = (core_count × 2) + effective_spindle_count
```
Với SSD/NVMe, `effective_spindle_count` coi như bằng số kênh I/O song song — thực tế thường lấy `core × 2 + 1..4`.

Với máy 8 core: pool ≈ **17–20**. Con số này làm nhiều người kinh ngạc vì họ đang chạy pool 100.

### Làm ngay

```bash
nproc
```

**Ghi vào writeup:** tính pool size đề xuất cho máy này theo công thức. So với đỉnh throughput bạn đo được ở §2 — có khớp không?

---

## §4. pgbouncer

### Lý thuyết

pgbouncer là connection pooler ngoài, **rất nhẹ** (single process, event-driven). Nó giữ N connection thật tới Postgres và phục vụ M connection từ ứng dụng, với M ≫ N.

Ba chế độ:

| Mode | Connection thật được trả về pool khi | Dùng được |
|---|---|---|
| `session` | client ngắt kết nối | mọi thứ |
| **`transaction`** | mỗi transaction kết thúc | **phổ biến nhất** |
| `statement` | mỗi câu lệnh xong | rất hạn chế |

**Cái gì hỏng ở transaction mode** — phải nhớ:
- `SET` ở mức session (`SET work_mem`, `SET search_path`) — dùng `SET LOCAL` thay thế
- `PREPARE`/`EXECUTE` thủ công — pgbouncer 1.21+ hỗ trợ prepared statement, bản cũ thì không
- Advisory lock **session-level** (`pg_advisory_lock`) — dùng `pg_advisory_xact_lock`
- `LISTEN`/`NOTIFY`
- Temp table
- Cursor `WITH HOLD`

Với JDBC, phải đặt `prepareThreshold=0` hoặc dùng pgbouncer ≥ 1.21. Với pgx, dùng `QueryExecModeSimpleProtocol` hoặc bật hỗ trợ tương ứng.

### Làm ngay

Thêm pgbouncer vào lab:

```bash
cat > /home/pham_hoang/learn/database_deepdive/pgbouncer.ini <<'EOF'
[databases]
lab = host=pgdd port=5432 dbname=lab

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = trust
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 20
admin_users = postgres
stats_users = postgres
ignore_startup_parameters = extra_float_digits
EOF

cat > /home/pham_hoang/learn/database_deepdive/userlist.txt <<'EOF'
"postgres" "postgres"
EOF

docker run -d --name pgb --network container:pgdd \
  -v /home/pham_hoang/learn/database_deepdive/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro \
  -v /home/pham_hoang/learn/database_deepdive/userlist.txt:/etc/pgbouncer/userlist.txt:ro \
  edoburu/pgbouncer:latest

docker logs pgb | tail -20
docker exec pgdd psql -h 127.0.0.1 -p 6432 -U postgres -d lab -c "select 1"
```

> Nếu image không chạy được, dùng cách khác: `docker exec` vào container Postgres và cài pgbouncer, hoặc bỏ qua §4-§5 và ghi rõ trong writeup là bạn đã thử gì.

---

## §5. Đo có/không pgbouncer

### Làm ngay

```bash
# trực tiếp tới Postgres
for c in 16 64 200 500; do
  echo "=== TRUC TIEP $c ==="
  docker exec pgdd pgbench -U postgres -d lab -h 127.0.0.1 -p 5432 \
    -c $c -j 8 -T 12 -S -M simple 2>&1 | grep -E 'tps|latency average|error'
done

# qua pgbouncer
for c in 16 64 200 500; do
  echo "=== PGBOUNCER $c ==="
  docker exec pgdd pgbench -U postgres -d lab -h 127.0.0.1 -p 6432 \
    -c $c -j 8 -T 12 -S -M simple 2>&1 | grep -E 'tps|latency average|error'
done
```

Xem thống kê pgbouncer:
```bash
docker exec pgdd psql -h 127.0.0.1 -p 6432 -U postgres -d pgbouncer -c "SHOW POOLS;"
docker exec pgdd psql -h 127.0.0.1 -p 6432 -U postgres -d pgbouncer -c "SHOW STATS;"
```

**Ghi vào writeup — bảng 8 dòng:** clients | trực tiếp tps | trực tiếp latency | pgbouncer tps | pgbouncer latency.

Ở 500 client, trực tiếp có chạy nổi không? pgbouncer thì sao? `SHOW POOLS` cho thấy bao nhiêu `cl_active`, `sv_active`, `maxwait`?

---

## §6. Kiểm chứng cái hỏng ở transaction mode

### Làm ngay

```bash
# SET session-level qua pgbouncer transaction mode
docker exec pgdd psql -h 127.0.0.1 -p 6432 -U postgres -d lab -c "SET work_mem='64MB'" -c "SHOW work_mem"

# advisory lock session-level
docker exec pgdd psql -h 127.0.0.1 -p 6432 -U postgres -d lab \
  -c "SELECT pg_advisory_lock(42)" -c "SELECT count(*) FROM pg_locks WHERE locktype='advisory'"

# so với bản _xact_
docker exec pgdd psql -h 127.0.0.1 -p 6432 -U postgres -d lab \
  -c "BEGIN; SELECT pg_advisory_xact_lock(42); SELECT count(*) FROM pg_locks WHERE locktype='advisory'; COMMIT;"
```

**Ghi vào writeup:** `SET work_mem` có giữ được qua câu lệnh sau không? Advisory lock session-level hành xử thế nào? **Trong code của bạn có chỗ nào dùng những thứ này không?**

---

## §7. Cấu hình pool cho service thật

### Lý thuyết

Checklist khi cấu hình HikariCP / pgx pool:

| Tham số | Đặt thế nào |
|---|---|
| `maximumPoolSize` | `core × 2 + số kênh I/O`, thường 10–25. **Không phải 100** |
| `minimumIdle` | bằng `maximumPoolSize` (tránh co giãn liên tục) |
| `connectionTimeout` | 2–5 giây — thà fail nhanh còn hơn treo |
| `maxLifetime` | ngắn hơn timeout của DB/LB (ví dụ 30 phút) |
| `idleTimeout` | 10 phút |
| `leakDetectionThreshold` | 30–60 giây — bắt connection bị rò rỉ |
| `validationTimeout` | 1–3 giây |

Và ở phía Postgres:
```
max_connections = (tổng pool size của mọi service) + dự phòng cho admin
idle_in_transaction_session_timeout = '5min'
statement_timeout = tuỳ workload (đặt riêng cho từng role)
```

Nhiều service cùng dùng một DB thì tổng pool size mới là con số quan trọng. Đây là chỗ kiến trúc microservice hay bị bất ngờ: 20 service × pool 20 = 400 connection.

Với kiến trúc của bạn (nhiều service + Temporal worker), rất đáng đặt pgbouncer ở giữa.

### Làm ngay

**Ghi vào writeup:** tính toán cho hệ thật của bạn:
- Bao nhiêu service/instance kết nối tới DB
- Pool size hiện tại của mỗi cái, tổng bao nhiêu
- `max_connections` của DB đang là bao nhiêu
- Máy DB có bao nhiêu core → pool tổng **nên** là bao nhiêu
- Có cần pgbouncer không, chế độ nào, và cái gì trong code sẽ hỏng

### Dọn dẹp

```bash
docker rm -f pgb 2>/dev/null
```

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B.** Giải thích bằng 3 câu **vì sao sau đỉnh, tăng client lại làm giảm throughput** — dùng Little's Law và tranh chấp lock.

### Đạt khi

Bạn có đường cong throughput đo thật, tính được pool size đúng bằng công thức và kiểm chứng bằng số liệu, và biết chính xác cái gì hỏng khi bật pgbouncer transaction mode.

**Xong thì gõ `/review-bai`.**
