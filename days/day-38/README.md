# Day 38 — Replication & replica lag: bug read-your-writes

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

Hôm nay dựng thêm một replica bằng Docker.

```sql
\timing on
\o /days/day-38/output.txt
```

---

## §0. Đoán trước

1. Ghi vào primary rồi đọc replica ngay lập tức — có thấy dữ liệu không?
2. Query dài trên replica có ảnh hưởng gì tới primary không?
3. Trong kiến trúc CQRS của bạn, read model đọc từ replica thì bug này biểu hiện thế nào?

---

## §1. Streaming replication

### Lý thuyết

```
PRIMARY                                    REPLICA
  │ ghi WAL                                   │
  ▼                                           │
WAL segment ──[walsender]──> mạng ──[walreceiver]──> WAL cục bộ
                                              │
                                              ▼ startup process replay
                                          page dữ liệu
```

Replica là bản sao **vật lý** — nó replay chính xác từng WAL record, nên giống primary tới từng byte. Khác với logical replication (replay các thay đổi ở mức dòng, cho phép chọn bảng, đổi schema, khác phiên bản).

Ba mốc LSN cần phân biệt trên replica:

| Hàm | Nghĩa |
|---|---|
| `pg_last_wal_receive_lsn()` | đã **nhận** tới đâu |
| `pg_last_wal_replay_lsn()` | đã **áp dụng** tới đâu |
| `pg_last_xact_replay_timestamp()` | thời điểm của transaction cuối đã áp dụng |

Lag = khoảng cách giữa `pg_current_wal_lsn()` trên primary và `pg_last_wal_replay_lsn()` trên replica. Đo bằng **byte** (chính xác) hoặc bằng **giây** (dễ hiểu hơn nhưng gây hiểu nhầm khi hệ nhàn rỗi).

### Làm ngay

Dựng replica:

```bash
cd /home/pham_hoang/learn/database_deepdive

# cho phép replication từ container khác
docker exec pgdd psql -U postgres -c "ALTER SYSTEM SET wal_level='replica';"
docker exec pgdd psql -U postgres -c "ALTER SYSTEM SET max_wal_senders=10;"
docker exec pgdd psql -U postgres -c "ALTER SYSTEM SET hot_standby_feedback=off;"
docker exec pgdd bash -c "echo 'host replication all all trust' >> /var/lib/postgresql/data/pg_hba.conf"
docker restart pgdd && sleep 6

# tạo replica bằng pg_basebackup
docker volume create pgdata_replica
docker run --rm --network container:pgdd -v pgdata_replica:/data postgres:17 \
  bash -c "rm -rf /data/* && pg_basebackup -h 127.0.0.1 -p 5432 -U postgres -D /data -Fp -Xs -R -P && chmod 700 /data"

docker run -d --name pgrep --network container:pgdd \
  -v pgdata_replica:/var/lib/postgresql/data \
  -e POSTGRES_PASSWORD=postgres \
  postgres:17 -c port=5433 -c hot_standby=on -c max_standby_streaming_delay=30s
sleep 6
docker logs pgrep | tail -20
```

Kiểm tra:
```bash
docker exec pgdd psql -U postgres -d lab -c "SELECT pg_is_in_recovery();"
docker exec pgdd psql -h 127.0.0.1 -p 5433 -U postgres -d lab -c "SELECT pg_is_in_recovery();"
docker exec pgdd psql -U postgres -d lab -c "SELECT client_addr, state, sent_lsn, write_lsn, flush_lsn, replay_lsn, sync_state FROM pg_stat_replication;"
```

> Nếu bước dựng replica không chạy được trong môi trường của bạn, ghi rõ trong writeup bạn đã thử gì và lỗi gì, rồi làm phần lý thuyết + §5, §6, §7 (những phần không cần replica thật).

**Ghi vào writeup:** `pg_stat_replication` cho thấy gì? `state` là gì, `sync_state` là gì?

---

## §2. Đo lag

### Làm ngay

Trên **primary**:
```sql
SELECT client_addr, state,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn))   AS lag_gui,
       pg_size_pretty(pg_wal_lsn_diff(sent_lsn, flush_lsn))              AS lag_ghi,
       pg_size_pretty(pg_wal_lsn_diff(flush_lsn, replay_lsn))            AS lag_apdung,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag_tong,
       write_lag, flush_lag, replay_lag
FROM pg_stat_replication;
```

Trên **replica**:
```bash
docker exec pgdd psql -h 127.0.0.1 -p 5433 -U postgres -d lab -c "
SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn(),
       pg_last_xact_replay_timestamp(),
       now() - pg_last_xact_replay_timestamp() AS lag_giay;"
```

Tạo tải nặng để thấy lag:
```bash
docker exec pgdd psql -U postgres -d lab -c "
CREATE TABLE t_rep AS SELECT * FROM ts_kv LIMIT 0;" 
docker exec pgdd psql -U postgres -d lab -c "
INSERT INTO t_rep SELECT * FROM ts_kv;" &
sleep 2
docker exec pgdd psql -U postgres -d lab -c "
SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag FROM pg_stat_replication;"
wait
```

**Ghi vào writeup:** lag lớn nhất bạn quan sát được là bao nhiêu byte, bao nhiêu giây? Ba thành phần lag (gửi / ghi / áp dụng) — cái nào lớn nhất?

---

## §3. Bug read-your-writes

### Lý thuyết

Kịch bản mà mọi hệ có read replica đều gặp:

```
1. User bấm "Lưu"        → ghi vào PRIMARY, commit thành công
2. UI chuyển sang trang danh sách → đọc từ REPLICA
3. Replica chưa replay tới đó  → KHÔNG thấy dữ liệu vừa lưu
4. User: "Sao tôi lưu rồi mà không thấy?"
```

Đây **không** phải bug của Postgres. Đây là hệ quả tất yếu của replication bất đồng bộ. Nó là vi phạm **read-your-writes consistency** — chính là điểm khác biệt serializability/linearizability của Day 30 §6, giờ thấy bằng mắt.

Với kiến trúc **CQRS** của bạn, vấn đề này còn nghiêm trọng hơn vì read model *cố tình* tách khỏi write model — bạn có cả replication lag lẫn projection lag cộng dồn.

### Làm ngay

```bash
docker exec pgdd psql -U postgres -d lab -c "
CREATE TABLE IF NOT EXISTS t_ryw (id serial PRIMARY KEY, v text, at timestamptz DEFAULT now());"

# tạo tải nền để có lag
docker exec -d pgdd psql -U postgres -d lab -c "INSERT INTO t_rep SELECT * FROM ts_kv;"
sleep 1

# ghi vào primary rồi đọc replica NGAY
docker exec pgdd bash -c "
psql -U postgres -d lab -tAc \"INSERT INTO t_ryw(v) VALUES ('test-1') RETURNING id\" &&
psql -h 127.0.0.1 -p 5433 -U postgres -d lab -tAc \"SELECT count(*) FROM t_ryw WHERE v='test-1'\"
"
```

Chạy vài lần trong lúc có tải nền.

**Ghi vào writeup:** có lần nào replica trả về `0` không? Bao nhiêu lần trong 10 lần thử?

---

## §4. Sửa bằng LSN gating

### Lý thuyết

Cách đúng và chính xác nhất: **theo dõi LSN**.

```
1. Sau khi commit trên primary:  lsn = SELECT pg_current_wal_insert_lsn()
2. Trả lsn về client (header, cookie, hoặc giữ trong session)
3. Trước khi đọc từ replica:     SELECT pg_last_wal_replay_lsn() >= lsn
4. Nếu chưa tới: đọc primary, hoặc chờ, hoặc thử replica khác
```

Các cách khác, đơn giản hơn nhưng kém chính xác:

| Cách | Ưu | Nhược |
|---|---|---|
| **LSN gating** | chính xác tuyệt đối | cần truyền LSN qua tầng ứng dụng |
| "Sticky primary" sau khi ghi N giây | dễ làm | N là phỏng đoán, có thể sai |
| `synchronous_commit = remote_apply` | mọi ghi đều nhất quán | **rất chậm**, primary chờ replica |
| Chỉ đọc primary cho user vừa ghi | đơn giản | mất lợi ích của replica |

### Làm ngay

```bash
docker exec pgdd bash -c '
LSN=$(psql -U postgres -d lab -tAc "INSERT INTO t_ryw(v) VALUES (\"test-lsn\") RETURNING pg_current_wal_insert_lsn()")
echo "LSN sau khi ghi: $LSN"
for i in 1 2 3 4 5; do
  R=$(psql -h 127.0.0.1 -p 5433 -U postgres -d lab -tAc "SELECT pg_last_wal_replay_lsn() >= \"$LSN\"::pg_lsn")
  echo "lan $i: replica da bat kip = $R"
  sleep 0.2
done'
```

**Ghi vào writeup:** sau bao nhiêu lần thử thì replica bắt kịp? **Viết pseudo-code cho tầng ứng dụng Java/Go của bạn** thực hiện LSN gating — kể cả chỗ lưu LSN và chỗ quyết định đọc primary hay replica.

---

## §5. Query conflict trên replica

### Lý thuyết

Replica phải replay WAL. Nếu WAL nói "xoá page này" nhưng có query trên replica đang đọc page đó → **xung đột**.

Postgres giải quyết bằng cách **huỷ query trên replica**:
```
ERROR:  canceling statement due to conflict with recovery
DETAIL:  User query might have needed to see row versions that must be removed.
```

Điều khiển:

| GUC | Nghĩa | Đánh đổi |
|---|---|---|
| `max_standby_streaming_delay` | cho phép replay **trễ** tối đa bao lâu để query chạy xong | trễ cao → lag cao |
| `hot_standby_feedback = on` | replica báo primary "tôi đang đọc snapshot cũ, đừng vacuum" | **primary tích tụ bloat** |

`hot_standby_feedback = on` là đánh đổi rất đáng cân nhắc: nó **chặn vacuum trên primary** giống hệt một transaction dài (Day 22 §6). Một query báo cáo chạy 2 giờ trên replica sẽ chặn vacuum trên primary suốt 2 giờ.

Quy tắc: bật `hot_standby_feedback` cho replica phục vụ query ngắn; **tắt** cho replica chạy báo cáo dài, và tăng `max_standby_streaming_delay` thay thế.

### Làm ngay

Tạo xung đột:
```bash
# S_replica: query dài
docker exec -d pgrep psql -U postgres -d lab -c "SELECT pg_sleep(60) FROM ts_kv LIMIT 1;" 2>/dev/null || \
docker exec -d pgdd psql -h 127.0.0.1 -p 5433 -U postgres -d lab -c "BEGIN; SELECT count(*) FROM ts_kv; SELECT pg_sleep(45);"

sleep 2
# primary: vacuum mạnh tay
docker exec pgdd psql -U postgres -d lab -c "
UPDATE device SET firmware = firmware;
VACUUM device;
UPDATE device SET firmware = firmware;
VACUUM device;"

sleep 3
docker logs pgrep 2>&1 | grep -i "conflict\|canceling" | tail -5
```

So sánh với `hot_standby_feedback = on`:
```bash
docker exec pgdd psql -h 127.0.0.1 -p 5433 -U postgres -c "ALTER SYSTEM SET hot_standby_feedback=on; SELECT pg_reload_conf();"
```
Rồi lặp lại, và kiểm tra trên primary:
```sql
SELECT backend_xmin FROM pg_stat_replication;
SELECT n_dead_tup FROM pg_stat_user_tables WHERE relname='device';
```

**Ghi vào writeup:** query trên replica có bị huỷ không, thông báo lỗi là gì? Với `hot_standby_feedback=on`, `backend_xmin` của replica xuất hiện trên primary — điều đó nghĩa là gì với vacuum?

---

## §6. Failover và mất dữ liệu

### Lý thuyết

Với replication **bất đồng bộ**, khi primary chết đột ngột, các transaction đã commit trên primary nhưng chưa gửi tới replica sẽ **mất** khi promote replica.

`synchronous_standby_names` bật chế độ đồng bộ:
```
synchronous_standby_names = 'FIRST 1 (rep1, rep2)'
synchronous_commit = on          -- đợi flush trên replica
```
Không mất dữ liệu, nhưng: mỗi commit phải đi vòng qua mạng, và **nếu replica chết thì primary treo** (trừ khi có ≥2 replica đồng bộ hoặc dùng `ANY`).

Ma trận cần nhớ:

| Cấu hình | RPO (mất bao nhiêu) | Ảnh hưởng latency | Rủi ro |
|---|---|---|---|
| Async | vài trăm ms → vài giây | không | mất dữ liệu khi failover |
| Sync (`remote_write`) | ~0 | +RTT | primary treo nếu replica chết |
| Sync (`remote_apply`) | 0, và đọc replica luôn nhất quán | +RTT +replay | chậm nhất |

### Làm ngay

**Ghi vào writeup:** với hệ của bạn — telemetry IoT và dữ liệu cấu hình/lệnh điều khiển có yêu cầu RPO khác nhau không? Bạn sẽ dùng async hay sync cho mỗi loại? (Gợi ý: kết hợp với `SET LOCAL synchronous_commit` của Day 37.)

---

## §7. Monitoring replication

### Làm ngay

Viết bộ query monitoring hoàn chỉnh:

```sql
-- trên primary
SELECT application_name, client_addr, state, sync_state,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag_byte,
       write_lag, flush_lag, replay_lag,
       backend_xmin,
       age(backend_xmin) AS xmin_age
FROM pg_stat_replication;

-- slot
SELECT slot_name, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_giu
FROM pg_replication_slots;
```

```bash
# trên replica
docker exec pgdd psql -h 127.0.0.1 -p 5433 -U postgres -d lab -c "
SELECT pg_is_in_recovery() AS la_replica,
       pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn(),
       now() - pg_last_xact_replay_timestamp() AS lag_thoi_gian,
       pg_is_wal_replay_paused() AS dang_tam_dung;"
```

**Ghi vào writeup:** ba chỉ số replication bạn sẽ alert, kèm ngưỡng và hành động.

### Dọn dẹp

```bash
docker rm -f pgrep
docker volume rm pgdata_replica
docker exec pgdd psql -U postgres -d lab -c "DROP TABLE IF EXISTS t_rep, t_ryw;"
```

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B. Áp dụng vào hệ thật:** trong kiến trúc CQRS của bạn, read model đọc từ đâu? Lag hiện tại bao nhiêu? Bug read-your-writes biểu hiện thế nào với người dùng (mô tả một luồng cụ thể), và bạn sẽ chặn ở tầng nào — API gateway, service layer, hay UI?

### Đạt khi

Bạn đo được lag ba tầng, tái hiện được bug read-your-writes, viết được LSN gating, và giải thích chính xác cái giá của `hot_standby_feedback`.

**Xong thì gõ `/review-bai`.**
