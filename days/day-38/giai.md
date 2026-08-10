# Day 38 — Lời giải: Replication & replica lag — bug read-your-writes

> Bài chữa. Dựng thật một replica bằng `pg_basebackup` (Postgres 17, cùng network namespace, replica nghe cổng 5433, async, `hot_standby=on`, `max_standby_streaming_delay=30s`).
>
> Kết luận một câu: **không có tải, replica luôn kịp (0/20 lần lỗi). Có tải, replica KHÔNG BAO GIỜ kịp — 30/30 lần đọc ngay sau ghi đều trả về rỗng.** Bug read-your-writes không phải chuyện hiếm gặp; nó là mặc định khi hệ có tải.

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án đo được | Bẫy |
|---|---|---|---|
| 1 | Ghi primary rồi đọc replica ngay — có thấy không? | **Tuỳ tải, và tuỳ theo cách tệ nhất.** Không tải: **0/20** lần lỗi (lag < 4 ms). Có tải: **30/30 lần KHÔNG thấy dữ liệu** (lag 32–42 MB). | Bẫy chết người: **test trên staging nhàn rỗi luôn cho 100% đúng.** Bug chỉ xuất hiện khi có tải — tức đúng lúc production đang bận và bạn ít muốn debug nhất. |
| 2 | Query dài trên replica có ảnh hưởng primary không? | **Có, rất nặng — nếu `hot_standby_feedback = on`.** Một query 25 giây trên replica làm `VACUUM` trên primary **không dọn được 150.000 dead tuple**, bảng `device` phình từ 20 MB lên **42 MB (2,1×)** và **không co lại** sau đó. | Bẫy: người ta bật `hot_standby_feedback` để tránh query bị huỷ, rồi vài tháng sau đi tìm nguyên nhân bloat ở primary mà không nghĩ tới replica. |
| 3 | Với CQRS, bug này biểu hiện thế nào? | Cộng dồn **hai** độ trễ: replication lag (đo được 42 MB ≈ 600 ms) **+** projection lag của read model. Và bạn không sửa được bằng LSN gating đơn thuần — xem §7. | Bẫy: CQRS làm người ta tưởng "eventual consistency là thiết kế, không phải bug", nên bỏ qua. Nhưng user bấm Lưu rồi không thấy dữ liệu vẫn là bug với **họ**. |

---

## §1. Dựng replica và streaming replication

```bash
docker exec pgdd bash -c "echo 'host replication all all trust' >> /var/lib/postgresql/data/pg_hba.conf"
docker volume create pgdata_replica
docker run --rm --network container:pgdd -v pgdata_replica:/data postgres:17 \
  bash -c "rm -rf /data/* && pg_basebackup -h 127.0.0.1 -p 5432 -U postgres -D /data -Fp -Xs -R -P && chmod 700 /data"
docker run -d --name pgrep --network container:pgdd -v pgdata_replica:/var/lib/postgresql/data \
  -e POSTGRES_PASSWORD=postgres postgres:17 -c port=5433 -c hot_standby=on -c max_standby_streaming_delay=30s
```

`pg_basebackup` copy 773 MB. Log replica:
```
LOG:  entering standby mode
LOG:  redo starts at 6/E10000D8
LOG:  consistent recovery state reached at 6/E10001D0
LOG:  database system is ready to accept read-only connections
LOG:  started streaming WAL from primary at 6/E2000000 on timeline 1
```

Ba chi tiết trong log này đáng chú ý:
- **`consistent recovery state reached`** — trước mốc này replica không nhận connection nào cả. Đây là lý do một replica mới dựng "chưa dùng được ngay" dù process đã chạy.
- **`started streaming`** — chuyển từ đọc file WAL sang nhận stream trực tiếp. `-Xs` trong `pg_basebackup` (`--wal-method=stream`) là thứ làm bước này liền mạch không mất WAL.
- **`-R`** tự sinh `standby.signal` và `primary_conninfo` — không cần viết `recovery.conf` tay như trước PG12.

```sql
-- trên primary
SELECT pg_is_in_recovery();   -- false
-- trên replica
SELECT pg_is_in_recovery();   -- true   ← cách phân biệt chuẩn, dùng trong health check
```

`pg_stat_replication` trên primary:

| Cột | Giá trị |
|---|---|
| `application_name` | `walreceiver` |
| `client_addr` | 127.0.0.1 |
| **`state`** | **`streaming`** |
| `sent_lsn` / `write_lsn` / `flush_lsn` / `replay_lsn` | `6/E2000000` (bằng nhau — đang kịp) |
| **`sync_state`** | **`async`** |

**`state = streaming`** là trạng thái tốt. Các trạng thái khác: `startup` (đang khởi động), `catchup` (**đang đuổi theo — replica mới dựng hoặc vừa mất kết nối**), `backup` (đang `pg_basebackup`). Thấy `catchup` kéo dài là dấu hiệu replica không đuổi kịp tốc độ ghi của primary.

**`sync_state = async`** — primary **không chờ** replica khi commit. Đây là mặc định và là lý do có §3 và §6.

### Ba mốc LSN — vì sao phải phân biệt

```
PRIMARY                                    REPLICA
  │ ghi WAL                                   │
  ▼                                           │
 WAL ──[walsender]──> mạng ──[walreceiver]──> WAL cục bộ
                                              │  ← pg_last_wal_receive_lsn()
                                              ▼ startup process replay
                                          page dữ liệu
                                                 ← pg_last_wal_replay_lsn()
```

`receive_lsn` là "đã nhận", `replay_lsn` là "đã áp dụng". **Query trên replica chỉ thấy dữ liệu tới `replay_lsn`.** Khoảng cách giữa hai cái này chính là `lag_apdung` ở §2 — và nó là phần lớn nhất khi replica bị nghẽn CPU/I/O chứ không phải nghẽn mạng.

---

## §2. Đo lag ba tầng

### Khi không có tải

| Chỉ số | Giá trị |
|---|---|
| `lag_gui` (primary → sent) | **0 byte** |
| `lag_ghi` (sent → flush) | **0 byte** |
| `lag_apdung` (flush → replay) | **0 byte** |
| `write_lag` | 0,428 ms |
| `flush_lag` | 3,39 ms |
| `replay_lag` | **4,085 ms** |

**Lag tổng bằng 0 byte, nhưng `replay_lag` vẫn 4 ms.** Hai chỉ số này đo hai thứ khác nhau: lag byte là *khoảng cách hiện tại*, `*_lag` là *thời gian đã mất để đi hết chặng đó cho record cuối cùng*. Cả hai đều cần: byte cho "còn thiếu bao nhiêu", thời gian cho "chậm bao lâu".

### Khi có tải nặng (INSERT 5.000.000 dòng)

| Thời điểm | `lag_gui` | `lag_ghi` | `lag_apdung` | **`lag_tong`** |
|---|---|---|---|---|
| 1 s | 18 MB | 6.400 kB | 16 MB | **40 MB** |
| 2 s | 15 MB | 12 MB | 1.925 kB | 29 MB |
| 3 s | 3.832 kB | 4.352 kB | 8.192 kB | 16 MB |
| 4 s | 3.832 kB | 4.352 kB | 8.200 kB | 16 MB |
| 5 s | 8.192 byte | 0 byte | 6.529 kB | 6.537 kB |
| 6 s | 0 | 0 | 0 | **0 byte** |

**Lag đỉnh 40 MB**, và **cả ba thành phần đều đáng kể** — không có một thủ phạm duy nhất:

- **`lag_gui` 18 MB** (primary sinh WAL nhanh hơn walsender đọc và gửi) — nghẽn ở **primary/mạng**.
- **`lag_ghi` 6,4–12 MB** (replica nhận nhưng chưa fsync xong) — nghẽn ở **I/O replica**.
- **`lag_apdung` 16 MB** (đã fsync nhưng chưa replay) — nghẽn ở **CPU replay của replica**.

Đây là lý do phải đo **cả ba**: cách sửa khác nhau hoàn toàn.

| Thành phần lớn nhất | Nghĩa là | Sửa bằng |
|---|---|---|
| `lag_gui` | mạng chậm, hoặc walsender không kịp đọc | băng thông, `wal_compression` (Day 37: −27%), giảm WAL sinh ra |
| `lag_ghi` | đĩa replica chậm | đĩa tốt hơn cho replica, hoặc `synchronous_commit` thấp hơn |
| **`lag_apdung`** | **replay là single-process, CPU replica không kịp** | **không sửa được bằng scale ngang** — chỉ có CPU nhanh hơn, hoặc giảm WAL |

Dòng cuối là giới hạn kiến trúc quan trọng nhất của streaming replication: **replay chạy trên MỘT process (`startup`).** Primary có 8 backend ghi song song, replica chỉ có 1 process replay. Nếu primary ghi bằng 4 core thì replica **về nguyên tắc không thể** đuổi kịp lâu dài.

Và nó nối thẳng với Day 37: **ba index làm WAL gấp 3,82× ⇒ replay lag gấp ~3,82×.** Mỗi index thêm vào một bảng ingest cao là thêm gánh nặng cho một process replay duy nhất trên mọi replica.

### Đo bằng giây — và cái bẫy của nó

```sql
SELECT now() - pg_last_xact_replay_timestamp() AS lag_giay;
-- 00:00:29.068218
```

**29 giây** — nhưng lúc đó `lag_byte = 0`, replica hoàn toàn kịp! Vì `pg_last_xact_replay_timestamp()` trả về thời điểm của **transaction cuối cùng đã replay**, và nếu primary im lặng 29 giây thì con số này tăng đều 29 giây dù chẳng có gì trễ cả.

> **Đừng alert chỉ dựa trên lag tính bằng giây.** Nó báo động giả mỗi khi hệ nhàn rỗi. Alert đúng phải kết hợp: `lag_byte > ngưỡng` **VÀ** `lag_giây > ngưỡng`.

---

## §3. Bug read-your-writes

Kịch bản: `INSERT` vào primary (commit xong) → đọc replica **ngay lập tức** → đếm.

| Điều kiện | Kết quả |
|---|---|
| **Không tải nền** | `....................` → **0 / 20 lần lỗi** |
| **Có tải nền** (3 luồng INSERT 5M dòng) | `XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX` → **30 / 30 lần KHÔNG thấy dữ liệu** |

Lag tại thời điểm đo: **32 MB**.

**Không phải "thỉnh thoảng hỏng" mà là "luôn hỏng khi có tải".** Đây là con số làm tôi bất ngờ nhất hôm nay. Tôi đoán tỉ lệ khoảng 20–50%; thực tế là **100%**.

Lý do đơn giản khi nhìn vào số: lag 32 MB ở tốc độ replay khoảng 50 MB/s nghĩa là replica đang chậm **~600 ms**. Một cặp INSERT-rồi-SELECT qua `psql` mất khoảng 10–20 ms. **10 ms < 600 ms ⇒ không bao giờ kịp.**

Và điều này nói lên bản chất: **read-your-writes không phải xác suất, nó là so sánh hai khoảng thời gian.** Nếu thời gian giữa ghi và đọc nhỏ hơn lag, bạn **luôn** đọc dữ liệu cũ. Trong một web app, thời gian đó là một round-trip HTTP (~50–200 ms) — vẫn thường nhỏ hơn lag lúc hệ bận.

Đây **không** phải bug của Postgres. Đó là hệ quả tất yếu của replication bất đồng bộ, và là chính xác cái ranh giới giữa serializability và linearizability đã nói ở Day 30 §6 — hôm nay nhìn thấy bằng mắt.

### 🔧 Tình huống thực tế — "tôi lưu rồi mà không thấy"

Team thêm read replica để giảm tải, route mọi `SELECT` sang replica ở tầng driver (nghe rất sạch). Trong 3 tuần đầu không có vấn đề gì — traffic thấp.

Rồi có chiến dịch marketing. Trong 2 tiếng cao điểm, support nhận 200 ticket dạng:
- "Tôi tạo đơn xong quay lại danh sách thì không thấy đơn"
- "Đổi mật khẩu rồi đăng nhập lại vẫn báo sai" ← cái này tệ nhất
- "Upload ảnh xong bấm xem báo 404"

Ba triệu chứng, một nguyên nhân. Và **không tái hiện được trên staging** vì staging nhàn rỗi — đúng như số đo: 0/20 khi không tải, 30/30 khi có tải.

Cái làm nó khó chẩn đoán: **log không có lỗi nào.** Query chạy đúng, trả về đúng thứ nó thấy. Chỉ là nó thấy quá khứ.

Cách chẩn đoán nhanh khi nghi ngờ: log `pg_is_in_recovery()` cùng với mỗi query trong request bị báo lỗi. Nếu request "không tìm thấy dữ liệu vừa tạo" luôn đi kèm `pg_is_in_recovery() = true` thì bạn có câu trả lời trong 5 phút.

---

## §4. Sửa bằng LSN gating

```sql
-- 1. sau khi ghi, lấy LSN
INSERT INTO t_ryw(v) VALUES ('...') RETURNING pg_current_wal_insert_lsn();
-- 8/70D6D550

-- 2. trước khi đọc từ replica, kiểm tra
SELECT pg_last_wal_replay_lsn() >= '8/70D6D550'::pg_lsn;
```

Đo thật:

**Không tải:**
```
LSN sau khi ghi: 8/6A2D9078
lan 1 (~0ms): bat kip=t, con thieu=-48 bytes
```
Bắt kịp ngay lần thử đầu (thậm chí replica đã vượt qua — `-48 bytes`).

**Có tải nền:**
```
LSN sau khi ghi: 8/70D6D550
lan 1 (~0ms):   bat kip=f, con thieu=42 MB
lan 2 (~200ms): bat kip=f, con thieu=29 MB
lan 3 (~400ms): bat kip=f, con thieu=24 MB
lan 4 (~600ms): bat kip=t, con thieu=-1098 kB
```

**Cần ~600 ms để bắt kịp.** Và bạn thấy được tiến độ: 42 → 29 → 24 → 0 MB. Con số này chính là thứ để đặt timeout: nếu chờ 600 ms là quá lâu cho request đó, hãy đọc primary luôn thay vì chờ.

### So sánh các cách sửa

| Cách | Chính xác | Chi phí | Khi nào dùng |
|---|---|---|---|
| **LSN gating** | **tuyệt đối** | phải truyền LSN qua tầng ứng dụng | mặc định nên chọn |
| "Sticky primary" N giây sau ghi | phỏng đoán — N sai thì vẫn lỗi | rất dễ làm | khi không sửa được tầng data access |
| `synchronous_commit = remote_apply` | tuyệt đối, không cần code | **mọi ghi chậm thêm 1 RTT + replay**; replica chết ⇒ **primary treo** | chỉ cho vài transaction đặc biệt |
| Luôn đọc primary cho user vừa ghi | tuyệt đối cho user đó | mất lợi ích replica ở đúng lúc bận nhất | fallback đơn giản |

### Pseudo-code cho tầng ứng dụng

**Java / Spring:**

```java
// 1. Lưu LSN vào ngữ cảnh request sau MỌI thao tác ghi
@Aspect @Component
class LsnTrackingAspect {
  @AfterReturning("@annotation(org.springframework.transaction.annotation.Transactional)")
  void captureLsn(JoinPoint jp) {
    if (!isWriteOperation(jp)) return;
    String lsn = jdbc.queryForObject("SELECT pg_current_wal_insert_lsn()::text", String.class);
    // Lưu vào nơi SỐNG QUA nhiều request: cookie ký, header trả về client,
    // hoặc Redis theo sessionId. KHÔNG dùng ThreadLocal thuần — nó chết cuối request.
    ResponseContext.setHeader("X-PG-LSN", lsn);
    session.setAttribute("lastWriteLsn", maxLsn(session.getAttribute("lastWriteLsn"), lsn));
  }
}

// 2. Chọn datasource khi đọc
class LsnAwareRoutingDataSource extends AbstractRoutingDataSource {
  private static final Duration MAX_WAIT = Duration.ofMillis(300);

  @Override protected Object determineCurrentLookupKey() {
    if (TransactionSynchronizationManager.isCurrentTransactionReadOnly() == false)
      return "primary";                       // ghi → luôn primary

    String need = RequestContext.getLsn();    // từ header X-PG-LSN của client
    if (need == null) return "replica";       // chưa ghi gì → replica thoải mái

    if (replicaCaughtUp(need)) return "replica";
    if (waitForReplica(need, MAX_WAIT)) return "replica";   // chờ tối đa 300ms
    return "primary";                          // quá lâu → đọc primary, KHÔNG trả dữ liệu cũ
  }

  private boolean replicaCaughtUp(String lsn) {
    // cache kết quả 50ms để không query replica mỗi request
    return replicaLsnCache.get() != null
        && compareLsn(replicaLsnCache.get(), lsn) >= 0;
  }
}

// 3. Một luồng nền cập nhật replay LSN của replica mỗi 50ms
@Scheduled(fixedRate = 50)
void pollReplicaLsn() {
  replicaLsnCache.set(replicaJdbc.queryForObject(
      "SELECT pg_last_wal_replay_lsn()::text", String.class));
}
```

**Go / pgx:**

```go
type Router struct {
    primary, replica *pgxpool.Pool
    replicaLSN       atomic.Pointer[pglogrepl.LSN]  // cập nhật nền mỗi 50ms
}

func (r *Router) ReadPool(ctx context.Context) *pgxpool.Pool {
    need, ok := LSNFromContext(ctx)   // lấy từ header/cookie
    if !ok { return r.replica }

    deadline := time.Now().Add(300 * time.Millisecond)
    for time.Now().Before(deadline) {
        if cur := r.replicaLSN.Load(); cur != nil && *cur >= need {
            return r.replica
        }
        time.Sleep(20 * time.Millisecond)
    }
    return r.primary   // fallback: thà chậm còn hơn sai
}

// Sau mỗi ghi:
var lsn pglogrepl.LSN
tx.QueryRow(ctx, "SELECT pg_current_wal_insert_lsn()").Scan(&lsn)
SetLSNHeader(w, lsn)
```

### Bốn chi tiết dễ sai khi tự làm

1. **LSN phải sống qua nhiều request.** ThreadLocal/context chết ở cuối request. Phải đưa vào **cookie đã ký**, **response header mà client gửi lại**, hoặc **Redis theo user/session**. Đây là chỗ hầu hết implementation sai.
2. **Poll replay LSN ở luồng nền, đừng query mỗi request.** Query trước mỗi lần đọc thì bạn vừa thêm một round-trip cho mọi request — mất luôn lợi ích của replica.
3. **Luôn có fallback về primary.** Nếu chờ quá `MAX_WAIT` (300 ms là hợp lý — đo được 600 ms là worst case dưới tải nặng), đọc primary. **Thà chậm hơn là sai.**
4. **Nhiều replica ⇒ phải theo dõi LSN của từng cái**, và chọn cái đã bắt kịp. Chọn nhầm một replica đang tụt lại thì mọi công sức trên vô nghĩa.

**Đơn giản hoá hợp lý cho 90% trường hợp:** nếu tầng data access không cho phép làm cái trên, dùng **sticky primary 2 giây sau ghi** (lưu timestamp trong session). Đo được lag đỉnh ~600 ms nên 2 giây có biên an toàn 3×. Không hoàn hảo, nhưng bắt được gần hết các case thực tế và làm mất 30 phút thay vì 3 ngày.

---

## §5. Query conflict và cái giá của `hot_standby_feedback`

### a) `hot_standby_feedback = off` — query bị huỷ

Đặt `max_standby_streaming_delay = 1s`, chạy một query dài trên replica, rồi `UPDATE` + `VACUUM` mạnh tay trên primary:

```
BEGIN
 count
-------
 50000
(1 row)

ERROR:  canceling statement due to conflict with recovery
DETAIL:  User query might have needed to see row versions that must be removed.
```

```sql
SELECT confl_snapshot FROM pg_stat_database_conflicts WHERE datname='lab';   -- 1
```

**Query bị giết.** Cơ chế: `VACUUM` trên primary xoá dead tuple → WAL nói "dọn page này" → replica replay tới đó → nhưng có query đang giữ snapshot cần chính những dòng đó → replica phải chọn: **hoãn replay** (tăng lag) hoặc **giết query**. `max_standby_streaming_delay` là ngưỡng của lựa chọn đó.

`pg_stat_database_conflicts` tách được 5 loại xung đột — rất hữu ích để chẩn đoán:

| Cột | Nguyên nhân |
|---|---|
| `confl_snapshot` | vacuum xoá dòng query đang cần ← **phổ biến nhất**, chính là cái đo được |
| `confl_lock` | DDL trên primary (`ALTER TABLE`, `DROP`) |
| `confl_bufferpin` | replay cần buffer query đang pin |
| `confl_tablespace` | `DROP TABLESPACE` |
| `confl_deadlock` | deadlock giữa replay và query |

### b) `hot_standby_feedback = on` — query sống, primary trả giá

Bật lên rồi lặp lại thí nghiệm:

```sql
-- trên PRIMARY, trong lúc replica đang chạy query 25 giây:
SELECT application_name, backend_xmin, age(backend_xmin) FROM pg_stat_replication;
-- walreceiver | 2768087 | 0        ← replica đã "cắm cờ" xmin lên primary
```

Chạy **3 vòng** `UPDATE device SET firmware = firmware||''` + `VACUUM device`:

| | Kết quả |
|---|---|
| Query trên replica | **KHÔNG bị huỷ** ✅ |
| `n_dead_tup` trên **primary** sau 3 vòng UPDATE+VACUUM | **150.000** ❌ |
| Kích thước `device` | **20 MB → 42 MB (2,1×)** |
| Sau khi query trên replica kết thúc + `VACUUM` lại | `n_dead_tup` = **0**, nhưng kích thước **vẫn 42 MB** |

**Đây là toàn bộ cái giá, đo bằng số:** `VACUUM` chạy 3 lần liên tiếp trên primary mà **không dọn được một dead tuple nào**, vì `backend_xmin` của replica giữ snapshot cũ. Dead tuple tích tụ 150.000 (gấp 3 lần số dòng sống!) và bảng phình gấp đôi.

Và **bloat không tự co lại**: sau khi query kết thúc, `VACUUM` dọn được dead tuple nhưng kích thước vẫn 42 MB — đúng bài học Day 33 §1. Muốn về 20 MB phải `VACUUM FULL` hoặc `pg_repack`.

> `hot_standby_feedback = on` biến **mọi query dài trên replica thành một transaction dài trên primary** (Day 22 §6). Một báo cáo 2 giờ trên replica = 2 giờ primary không vacuum được. Trên bảng ingest cao đó là hàng chục GB bloat.

### Quy tắc chọn

| Loại replica | `hot_standby_feedback` | `max_standby_streaming_delay` |
|---|---|---|
| **HA standby** (chờ failover, không phục vụ đọc) | `off` | `30s` |
| **Replica cho query ngắn** (API đọc, < 5 s) | `on` | `30s` |
| **Replica cho báo cáo/ETL dài** | **`off`** | **`-1`** (vô hạn) hoặc vài giờ |

Dòng cuối là mẫu quan trọng nhất và ít người biết: **`max_standby_streaming_delay = -1` cho phép replay hoãn vô hạn để query chạy xong.** Replica tụt lại (lag tăng) nhưng **không đụng gì tới primary**. Đó gần như luôn là đánh đổi đúng cho một replica chuyên báo cáo — bạn hy sinh độ tươi của **replica đó** thay vì hy sinh sức khoẻ của **primary**.

**Nguyên tắc: đừng bao giờ để một replica báo cáo bật `hot_standby_feedback`.** Nếu bắt buộc phải bật (vì query bị huỷ liên tục), hãy tách nó thành replica riêng và chấp nhận bloat có kiểm soát — đừng để chung với replica phục vụ API.

### 🔧 Tình huống thực tế — bloat ở primary không rõ nguyên nhân

Bảng `orders` trên primary phình từ 80 GB lên 240 GB trong 6 tuần. `autovacuum` chạy liên tục, log cho thấy nó hoàn thành bình thường, nhưng `n_dead_tup` không bao giờ về gần 0. Không có transaction dài nào trong `pg_stat_activity`. Không có replication slot bỏ quên.

Nguyên nhân: 3 tháng trước có người bật `hot_standby_feedback = on` trên replica BI để job Metabase khỏi bị huỷ. Job đó chạy 2–4 tiếng mỗi đêm. **Suốt 2–4 tiếng đó, primary không vacuum được gì.**

Cách chẩn đoán — một query, và nó không nằm trong checklist của ai cả:
```sql
SELECT application_name, client_addr, backend_xmin,
       age(backend_xmin) AS xmin_age
FROM pg_stat_replication WHERE backend_xmin IS NOT NULL;
```
`backend_xmin IS NOT NULL` nghĩa là replica đang giữ xmin trên primary. `age()` lớn = đang giữ lâu.

Sửa: `hot_standby_feedback = off` trên replica BI + `max_standby_streaming_delay = -1`. Job BI vẫn chạy xong, replica tụt lại 30–90 phút mỗi đêm rồi tự đuổi kịp, primary vacuum bình thường trở lại.

**Bài học: `pg_stat_activity` trên primary không thấy transaction dài của replica.** Phải nhìn `pg_stat_replication.backend_xmin`. Đây là điểm mù kinh điển khi chẩn đoán bloat.

---

## §6. Failover và mất dữ liệu

Với replication **bất đồng bộ** (`sync_state = async`, đúng cấu hình lab), khi primary chết đột ngột: các transaction **đã commit trên primary nhưng chưa gửi tới replica sẽ MẤT** khi promote replica.

Đo được: **lag đỉnh 40 MB** dưới tải. Nếu primary chết đúng lúc đó, đó là **40 MB WAL = hàng trăm nghìn dòng đã commit** biến mất. Người dùng đã thấy "Lưu thành công" mà dữ liệu không còn.

### Ma trận RPO

| Cấu hình | RPO | Latency ghi | Rủi ro |
|---|---|---|---|
| **Async** (lab) | **vài trăm ms → vài giây** (đo: tới 40 MB) | không đổi | mất dữ liệu khi failover |
| Sync `remote_write` | ~0 | +1 RTT | **replica chết ⇒ primary treo** |
| Sync `remote_apply` | 0, và **đọc replica luôn nhất quán** — không cần LSN gating | +1 RTT + thời gian replay | chậm nhất |

```
synchronous_standby_names = 'ANY 1 (rep1, rep2)'   -- cần ≥2 replica, chỉ đợi 1 cái
synchronous_commit = remote_write
```

**Bẫy chết người của sync replication:** với `FIRST 1 (rep1)` và chỉ **một** replica, khi replica đó chết thì **primary treo mọi commit**. Bạn vừa biến một replica từ "tăng độ sẵn sàng" thành "điểm chết đơn". Luôn dùng `ANY 1 (rep1, rep2)` với **ít nhất hai** replica.

### Với hệ của bạn — RPO khác nhau cho từng loại dữ liệu

Kết hợp với `SET LOCAL synchronous_commit` của Day 37:

| Luồng | `synchronous_commit` | RPO | Lý do |
|---|---|---|---|
| **Ingest telemetry** | **`off`** | 600 ms (Day 37) + lag replication | Thiết bị buffer và gửi lại. Mất 600 ms dữ liệu cảm biến không ai chết. Đổi lại **68× throughput**. |
| **Alarm / sự kiện** | `on` (local) | 0 trên primary, mất khi failover | Volume thấp. Chấp nhận mất khi failover nếu có cơ chế phát lại từ nguồn. |
| **Lệnh điều khiển thiết bị** | **`remote_write`** | **0** | Người dùng bấm "tắt máy bơm" và hệ báo thành công — không được phép mất khi failover. Volume rất thấp nên chi phí RTT không đáng kể. |
| **Cấu hình / billing / audit** | **`remote_write`** | **0** | Yêu cầu pháp lý và toàn vẹn. |

**Đây là điểm mạnh lớn nhất của Postgres ở khoản này: `synchronous_commit` đặt được theo từng transaction.** Không phải chọn một mức cho cả database. Telemetry chạy `off` (nhanh nhất), lệnh điều khiển chạy `remote_write` (an toàn nhất), **trong cùng một database, cùng một connection pool**.

```sql
-- gắn theo role cho sạch, thay vì rải trong code
ALTER ROLE ingest_telemetry SET synchronous_commit = 'off';
ALTER ROLE device_control   SET synchronous_commit = 'remote_write';
ALTER ROLE app              SET synchronous_commit = 'on';
```

---

## §7. Monitoring replication

### Bộ query hoàn chỉnh

```sql
-- ===== TRÊN PRIMARY =====
SELECT application_name, client_addr, state, sync_state,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn))   AS lag_gui,
       pg_size_pretty(pg_wal_lsn_diff(sent_lsn, flush_lsn))              AS lag_ghi,
       pg_size_pretty(pg_wal_lsn_diff(flush_lsn, replay_lsn))            AS lag_apdung,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag_tong,
       write_lag, flush_lag, replay_lag,
       backend_xmin, age(backend_xmin) AS xmin_age    -- ← chỉ số bị bỏ quên nhiều nhất
FROM pg_stat_replication;

-- slot (Day 37 §6)
SELECT slot_name, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_giu
FROM pg_replication_slots;

-- ===== TRÊN REPLICA =====
SELECT pg_is_in_recovery()                             AS la_replica,
       pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn(),
       now() - pg_last_xact_replay_timestamp()         AS lag_thoi_gian,
       pg_is_wal_replay_paused()                       AS dang_tam_dung;

SELECT * FROM pg_stat_database_conflicts WHERE datname = current_database();
```

### Ba chỉ số phải alert

| # | Chỉ số | Ngưỡng | Hành động |
|---|---|---|---|
| **1** | `lag_tong` (byte) **VÀ** `lag_thoi_gian` cùng vượt ngưỡng | > 100 MB **và** > 60 s | Đọc `lag_gui`/`lag_ghi`/`lag_apdung` để biết nghẽn ở đâu (bảng §2). Tạm route mọi đọc về primary. **Phải AND hai điều kiện** — lag giây một mình báo động giả khi hệ nhàn rỗi. |
| **2** | `pg_stat_replication` **rỗng** hoặc `state <> 'streaming'` | ngay lập tức | Replica mất kết nối. Nếu có slot, WAL bắt đầu tích tụ trên primary ⇒ nguy cơ đầy đĩa (Day 37 §6). Kiểm tra `wal_status` và `max_slot_wal_keep_size`. |
| **3** | **`backend_xmin IS NOT NULL` VÀ `age(backend_xmin) > 50.000.000`** | > 50M | Replica đang chặn `VACUUM` trên primary. Tìm query dài trên replica; cân nhắc tắt `hot_standby_feedback`. **Đây là chỉ số ít ai theo dõi nhất và là nguyên nhân bloat khó chẩn đoán nhất.** |

Bổ sung nên có (mức warning, không page):
- `confl_snapshot` tăng nhanh trên replica → query đang bị huỷ, cần chỉnh `max_standby_streaming_delay`.
- `pg_is_wal_replay_paused() = true` → có người tạm dừng replay và quên bật lại.

### Với kiến trúc CQRS của bạn

Read model đọc từ replica ⇒ **hai độ trễ cộng dồn**:

```
ghi vào write model (primary)
   │
   ├─ replication lag         ← đo được 42 MB ≈ 600 ms dưới tải
   ▼
replica
   │
   ├─ projection lag          ← thời gian projector đọc và cập nhật read model
   ▼
read model
```

**LSN gating của §4 chỉ giải quyết được nửa trên.** Với CQRS, mốc cần chờ không phải "replica đã replay tới LSN X" mà là "**projection đã xử lý xong event Y**".

Cách làm đúng: dùng **version/sequence của chính projection**, không dùng LSN:

```sql
-- read model lưu mốc đã xử lý
CREATE TABLE projection_offset (
  projection text PRIMARY KEY,
  last_event_id bigint NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- API sau khi ghi trả về event_id; client gửi lại ở request đọc
SELECT last_event_id >= $1 FROM projection_offset WHERE projection = 'order_list';
```

Với Temporal, đây là chỗ workflow giúp nhiều: **workflow biết chính xác nó đã phát ra event nào**, nên có thể chờ projection bắt kịp trước khi trả về cho người dùng — mà không cần truyền LSN qua HTTP.

**Chặn ở tầng nào?** Khuyến nghị: **tầng data access / repository**, không phải API gateway và không phải UI.

- **Gateway** không biết request này đọc cái gì ⇒ phải áp dụng cho mọi request ⇒ mất hết lợi ích của replica.
- **UI** (retry/poll khi không thấy dữ liệu) là chữa triệu chứng, và mỗi màn hình phải tự làm lại.
- **Repository** biết chính xác nó đang đọc aggregate nào ⇒ chỉ chờ đúng projection liên quan ⇒ giải quyết một lần cho toàn hệ.

---

## Bảng số liệu chính

| Phép đo | Kết quả |
|---|---|
| `pg_basebackup` | 773 MB, `-Xs -R` |
| `state` / `sync_state` | **`streaming`** / **`async`** |
| **Lag khi không tải** | 0 byte cả ba tầng; `replay_lag` **4,085 ms** |
| **Lag đỉnh khi có tải** (INSERT 5M) | **40 MB** — `lag_gui` 18 MB + `lag_ghi` 6,4 MB + `lag_apdung` 16 MB |
| Thời gian đuổi kịp sau khi tải dừng | ~6 giây |
| `lag_thoi_gian` khi hệ nhàn rỗi | **29 giây** dù `lag_byte = 0` ← **bẫy alert** |
| **Read-your-writes, không tải** | **0 / 20 lần lỗi** |
| **Read-your-writes, có tải** | **30 / 30 lần KHÔNG thấy dữ liệu** (lag 32 MB) |
| **LSN gating, không tải** | bắt kịp ở lần thử **1** (`-48 bytes`) |
| **LSN gating, có tải** | 42 MB → 29 → 24 → bắt kịp ở **~600 ms** |
| Query conflict (`hsf=off`, delay=1s) | **`ERROR: canceling statement due to conflict with recovery`**, `confl_snapshot = 1` |
| `hot_standby_feedback = on`: `backend_xmin` trên primary | **2768087** (replica cắm cờ xmin) |
| **3 vòng `UPDATE` + `VACUUM` trên primary khi replica giữ snapshot** | **`n_dead_tup` = 150.000 — `VACUUM` không dọn được gì** |
| Kích thước `device` | **20 MB → 42 MB (2,1×)** |
| Sau khi query replica xong + `VACUUM` | `n_dead_tup` = 0, **kích thước vẫn 42 MB** (bloat vĩnh viễn) |
| RPO của async khi failover ở lag đỉnh | **~40 MB WAL đã commit bị mất** |

---

## Ba điều dễ hiểu sai

| Hiểu nhầm | Sự thật đo được |
|---|---|
| "Replica lag thường vài ms, bug read-your-writes hiếm gặp." | Không tải: **0/20 lỗi**. Có tải: **30/30 lỗi** — không phải hiếm, mà là **luôn luôn**. Vì đây không phải xác suất mà là so sánh hai khoảng thời gian: round-trip ghi-rồi-đọc (~10–200 ms) vs lag (~600 ms dưới tải). Nhỏ hơn thì **luôn** đọc dữ liệu cũ. Và staging nhàn rỗi sẽ **không bao giờ** tái hiện được. |
| "`hot_standby_feedback = on` chỉ ảnh hưởng replica." | Nó biến mọi query dài trên replica thành transaction dài trên **primary**. Đo được: query 25 giây trên replica ⇒ **`VACUUM` chạy 3 lần trên primary không dọn được một dead tuple nào**, 150.000 dead tuple tích tụ, bảng phình **2,1×** và **không co lại**. Và `pg_stat_activity` trên primary **không thấy gì** — phải nhìn `pg_stat_replication.backend_xmin`. |
| "Đo lag bằng giây là đủ." | Lab cho `lag_thoi_gian = 29 giây` trong khi `lag_byte = 0` — replica kịp hoàn toàn, chỉ là primary im lặng 29 giây. Alert theo giây sẽ báo động giả mỗi đêm. Và ngược lại, lag byte một mình không nói được replay có đang tắc không. **Phải AND cả hai**, và phải tách ba tầng (gửi/ghi/áp dụng) vì cách sửa hoàn toàn khác nhau. |

---

## Áp dụng vào hệ thật

1. **Kiểm tra ngay `backend_xmin` — chỉ số bị bỏ quên nhiều nhất, 30 giây:**
   ```sql
   SELECT application_name, client_addr, backend_xmin, age(backend_xmin) AS xmin_age
   FROM pg_stat_replication WHERE backend_xmin IS NOT NULL;
   ```
   Có kết quả với `xmin_age` lớn ⇒ replica đang chặn `VACUUM` ở primary. Đây có thể là lời giải cho bloat mà bạn đang không giải thích được.

2. **Tách replica theo mục đích, cấu hình khác nhau:**
   ```
   replica-api    : hot_standby_feedback=on,  max_standby_streaming_delay=30s
   replica-báocáo : hot_standby_feedback=off, max_standby_streaming_delay=-1
   standby-HA     : hot_standby_feedback=off, không phục vụ đọc
   ```
   Đừng để một replica làm cả ba việc — ba việc đó có ba cấu hình mâu thuẫn nhau.

3. **Tìm bug read-your-writes trong code:** grep mọi chỗ route `SELECT` sang replica. Với mỗi chỗ, hỏi: *"có thao tác ghi nào của cùng user, trong vòng 2 giây trước đó, có thể ảnh hưởng kết quả này không?"* Đặc biệt soi các luồng: tạo-xong-xem-danh-sách, đổi-mật-khẩu-rồi-đăng-nhập, upload-rồi-hiển-thị.

4. **Làm LSN gating ở tầng repository**, với fallback về primary sau 300 ms (đo được worst case 600 ms). Nếu không đủ thời gian, làm **sticky primary 2 giây sau ghi** trước — nó bắt được phần lớn case và làm mất 30 phút.

5. **Đặt alert theo bảng §7, đặc biệt là alert #3** (`backend_xmin`). Alert #1 phải **AND** hai điều kiện byte và giây, nếu không nó sẽ báo động giả mỗi đêm và bị mute.

6. **Phân tầng `synchronous_commit` theo role, không theo database:**
   ```sql
   ALTER ROLE ingest_telemetry SET synchronous_commit = 'off';           -- 68× nhanh hơn
   ALTER ROLE device_control   SET synchronous_commit = 'remote_write';  -- RPO = 0
   ```
   Đây là đòn bẩy lớn nhất trong cả Day 37 + 38 gộp lại.

7. **Nếu dùng sync replication: bắt buộc ≥ 2 replica và `ANY 1 (...)`.** Với `FIRST 1 (rep1)` và một replica, replica chết ⇒ **primary treo mọi commit** — bạn vừa biến công cụ tăng độ sẵn sàng thành điểm chết đơn.

8. **Với CQRS: dùng offset của projection, không dùng LSN.** LSN chỉ giải quyết được replication lag, không giải quyết projection lag. Lưu `projection_offset` và cho API trả về `event_id` để client gửi lại — hoặc để Temporal workflow chờ projection bắt kịp trước khi trả kết quả.

---

## Câu hỏi mở sang các ngày sau

- **Day 39 (logical decoding & CDC)** là lời giải thay thế cho §7: thay vì đọc replica vật lý rồi chờ, dùng logical replication để **đẩy** thay đổi vào read model. Và slot logical sẽ có đúng vấn đề `xmin` của §5 — nhưng lần này bạn *cố ý* tạo ra nó.
- **Day 40 (wait events)** trả lời câu hỏi treo ở §2: khi `lag_apdung` là thành phần lớn nhất, process `startup` trên replica đang chờ **cái gì** — I/O, buffer pin, hay chỉ đơn giản là CPU-bound? Đó là cách biết replay lag có sửa được không.
- **Day 37 (WAL)** nhìn lại từ hôm nay: mọi thứ giảm WAL đều giảm lag theo tỉ lệ 1:1. `wal_compression = lz4` (−27%) giảm 27% băng thông replication; ba index thừa làm WAL gấp 3,82× nên cũng làm lag gấp 3,82×.
- **Day 22–23 (vacuum)** nối trực tiếp với §5: `hot_standby_feedback` là **nguồn thứ ba** chặn vacuum, bên cạnh transaction dài và replication slot — và là nguồn duy nhất **không hiện ra trong `pg_stat_activity` của primary**.
- **Câu hỏi mở thật sự:** replay trên replica là **single-process**. Primary ghi bằng 8 backend song song, replica replay bằng 1. Ở tỉ lệ ghi nào thì replica **về nguyên tắc** không thể đuổi kịp, và khi đó lựa chọn là gì — giảm WAL (bớt index, `wal_compression`), CPU nhanh hơn cho replica, hay chuyển sang logical replication (song song hoá được theo bảng)?

---

### Dọn dẹp

```bash
docker rm -f pgrep
docker volume rm pgdata_replica
```
```sql
DROP TABLE IF EXISTS t_rep, t_ryw;
VACUUM FULL device;   -- thu hồi 22 MB bloat do thí nghiệm hot_standby_feedback ở §5
```
