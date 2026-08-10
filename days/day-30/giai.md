# Day 30 — Lời giải: SERIALIZABLE (SSI), retry, đo throughput + ôn tuần 6

> Bài chữa. Đo thật bằng `pgbench` với 3 chiến lược × 3 mức song song + biến thể tranh chấp cao.
> Script bench: [bench/](bench/)

---

## §0. Đáp án phần đoán

| # | Câu hỏi | Đáp án đo được |
|---|---|---|
| 1 | Throughput cao nhất khi **ít** tranh chấp? | **Optimistic (568 tps)**, sát nút `FOR UPDATE` (550 tps) |
| 2 | Cao nhất khi **nhiều** tranh chấp? | **`FOR UPDATE`, áp đảo**: 847 tps vs optimistic 272 vs serializable **3,6** |
| 3 | Tỷ lệ retry của Serializable ở 64 client? | Bản thân số retry thấp (51) nhưng **tps chỉ 3,6 — sụp đổ hoàn toàn** |

Câu 2 là kết quả bất ngờ nhất và quan trọng nhất bài.

---

## §1. SSI hoạt động thế nào

```
max_pred_locks_per_transaction = 64
max_pred_locks_per_relation    = -2
max_pred_locks_per_page        = 2
```

Serializable của Postgres dùng **SSI — Serializable Snapshot Isolation**, **không dùng khoá đọc** (khác two-phase locking của SQL Server/DB2 truyền thống).

Nó theo dõi **rw-dependency**: T1 đọc một thứ mà T2 sau đó ghi đè. Lý thuyết SSI chứng minh mọi lịch trình không-serializable đều chứa một transaction có **cả rw-dependency vào lẫn ra** — gọi là **pivot**. Postgres phát hiện cấu trúc đó và abort một transaction (đúng thông báo đã thấy ở Day 27: `Canceled on identification as a pivot`).

### Predicate lock thật

```sql
BEGIN TRANSACTION ISOLATION LEVEL SERIALIZABLE;
SELECT count(*) FROM acct WHERE balance > 50000;   -- đọc 100 dòng
```
```
 locktype | relation | page | tuple |    mode    | pid
----------+----------+------+-------+------------+------
 relation | acct     |      |       | SIReadLock | 2576
```

**Chỉ MỘT lock, và nó ở mức `relation`** — không phải 100 lock cấp tuple.

Vì query dùng **Seq Scan** trên toàn bảng → Postgres biết ngay là "đọc cả bảng" → khoá thẳng ở mức relation thay vì tạo 100 lock tuple.

`SIReadLock` **không chặn ai cả** — nó chỉ để phát hiện xung đột. Đây là điểm khác biệt cốt lõi so với khoá đọc truyền thống.

---

## §2. Predicate lock leo thang

```sql
BEGIN TRANSACTION ISOLATION LEVEL SERIALIZABLE;
SELECT count(*) FROM ts_kv WHERE device_id = 1;   -- 107.947 dòng
```
```
    mode    | locktype |   relation   | mức_tuple | mức_page | mức_relation | tổng
------------+----------+--------------+-----------+----------+--------------+------
 SIReadLock | relation | ts_kv        |         0 |        0 |            1 |    1
 SIReadLock | relation | idx_tskv_dev |         0 |        0 |            1 |    1
```

**Đọc 107.947 dòng → chỉ 2 lock, cả hai ở mức `relation`** (một cho bảng, một cho index).

### Leo thang đã xảy ra — và hệ quả rất lớn

`max_pred_locks_per_transaction = 64`. Đọc 107.947 dòng vượt xa ngưỡng đó → Postgres **leo thang** tuple → page → **relation**.

> ## **Hệ quả: transaction Serializable đọc nhiều dữ liệu sẽ khoá NGUYÊN BẢNG về mặt predicate — nó xung đột với MỌI thao tác ghi vào bảng đó, kể cả dòng nó chưa từng chạm tới.**
>
> Đây là **false positive**: abort xảy ra dù thực tế không có xung đột logic nào.

### Điều này gợi ý gì về thiết kế transaction Serializable

**Ba quy tắc rút ra:**

1. **Transaction Serializable phải ĐỌC ÍT.** Mỗi dòng đọc thêm là một cơ hội xung đột. Đọc cả bảng = xung đột với mọi người.
2. **Dùng index để thu hẹp phạm vi đọc.** Index scan trên vài dòng → predicate lock cấp tuple, xung đột hẹp. Seq scan → cấp relation, xung đột toàn bộ.
3. **Nâng `max_pred_locks_per_transaction`** nếu transaction buộc phải đọc nhiều:
```sql
ALTER SYSTEM SET max_pred_locks_per_transaction = 512;   -- cần RESTART
```
Đổi lại: tốn shared memory (`max_pred_locks_per_transaction × max_connections × ~100 byte`).

**Đây chính là lý do Serializable sụp đổ ở §4** — mọi transaction đều đọc rồi ghi vào cùng 20 tài khoản, predicate lock leo thang, ai cũng xung đột với ai.

---

## §3. Ba chiến lược — và bản sửa `cv_optimistic`

### Vấn đề của bản gốc trong đề

```sql
UPDATE acct SET ... WHERE id = a AND version = va;
IF NOT FOUND THEN n := n+1; CONTINUE; END IF;      -- <<< quay lại đầu vòng
UPDATE acct SET ... WHERE id = b AND version = vb;
IF NOT FOUND THEN n := n+1; CONTINUE; END IF;      -- <<< NHƯNG update thứ nhất ĐÃ ÁP DỤNG
```

**Nếu update thứ hai thất bại, update thứ nhất đã ghi rồi.** Vòng lặp `CONTINUE` không hoàn tác được → **tiền bị trừ mà không được cộng** → tổng số dư sai.

### Bản sửa

```sql
CREATE OR REPLACE FUNCTION cv_optimistic(a int, b int, amt int) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE va int; vb int; ba int; bb int; n int := 0;
BEGIN
  LOOP
    SELECT version, balance INTO va, ba FROM acct WHERE id = a;
    SELECT version, balance INTO vb, bb FROM acct WHERE id = b;

    -- ① ghi CẢ HAI trong MỘT câu lệnh -> nguyên tử, không có trạng thái nửa vời
    WITH upd AS (
      UPDATE acct
      SET balance = CASE WHEN id=a THEN ba-amt ELSE bb+amt END,
          version = CASE WHEN id=a THEN va+1   ELSE vb+1   END
      WHERE (id=a AND version=va) OR (id=b AND version=vb)
      RETURNING 1)
    SELECT count(*) INTO STRICT n FROM upd;

    -- ② chỉ thành công khi CẢ HAI dòng khớp version
    IF n = 2 THEN RETURN 0; END IF;

    -- ③ không đủ 2 -> có xung đột -> ném lỗi để rollback
    RAISE EXCEPTION 'retry' USING ERRCODE='40001';
  END LOOP;
END $$;
```

**Ba thay đổi:**
1. **Gộp hai `UPDATE` thành một câu** → nguyên tử, không có trạng thái nửa vời
2. Kiểm `count(*) = 2` → chỉ thành công khi **cả hai** version còn khớp
3. `RAISE EXCEPTION ... ERRCODE='40001'` thay vì `CONTINUE` → transaction rollback thật, pgbench retry

Kết quả: **tổng số dư luôn đúng 10.000.000** ở mọi lần bench (§5).

---

## §4. Đo throughput — bảng chính của bài

Workload: chuyển tiền giữa 2 trong 20 tài khoản, 12 giây, `--max-tries=10`.

| Chiến lược | clients | **tps** | latency TB (ms) | retried | failed | `sum(balance)` |
|---|---|---|---|---|---|---|
| **`FOR UPDATE`** | 4 | **549,6** | 7,3 | **0** | **0** | ✅ 10.000.000 |
| **`FOR UPDATE`** | 16 | **811,0** | 19,7 | **0** | **0** | ✅ |
| **`FOR UPDATE`** | **64** | **847,2** | 75,5 | **0** | **0** | ✅ |
| Optimistic | 4 | **568,3** | 7,0 | 1.899 | 0 | ✅ |
| Optimistic | 16 | 371,8 | 41,7 | 2.168 | 145 | ✅ |
| Optimistic | **64** | **271,9** | 214,0 | 2.196 | **440** | ✅ |
| Serializable | 4 | 403,5 | 9,9 | 1.388 | 7 | ✅ |
| Serializable | 16 | 133,5 | 110,7 | 979 | 140 | ✅ |
| **Serializable** | **64** | **3,6** ⚠️ | **16.865** | 51 | 3 | ✅ |

### 🔥 Ba phát hiện

**1. `FOR UPDATE` TĂNG throughput khi thêm client (550 → 811 → 847 tps).**

Ngược hoàn toàn với trực giác "khoá làm chậm". Vì:
- Khoá **tuần tự hoá** truy cập → không có công vô ích
- Không retry → không lãng phí
- Thêm client chỉ làm hàng đợi dài hơn, nhưng **CPU luôn bận việc hữu ích**

**Latency tăng tuyến tính (7,3 → 75,5 ms) nhưng throughput vẫn tăng** — đúng định luật Little.

**2. Optimistic GIẢM throughput khi thêm client (568 → 372 → 272 tps).**

Ở 4 client nó **nhanh nhất** (568 tps) vì không khoá gì cả. Nhưng tranh chấp tăng → retry tăng → công vô ích tăng → throughput giảm. Và **440 transaction thất bại hoàn toàn** ở 64 client (hết 10 lần thử).

**3. Serializable SỤP ĐỔ ở 64 client: 3,6 tps, latency 16,9 GIÂY.**

**Chậm hơn `FOR UPDATE` 235 lần.**

Nguyên nhân chính là §2: predicate lock leo thang lên mức **relation** → mọi transaction xung đột với mọi transaction → gần như mọi thứ bị abort và retry, lặp đi lặp lại.

Chú ý `retried = 51` — **thấp** — vì hầu hết transaction còn chưa kịp chạy xong trong 12 giây.

### Tranh chấp cao (chỉ 3 tài khoản) @ 64 client

| Chiến lược | **tps** | latency TB | retried | failed | sum |
|---|---|---|---|---|---|
| **`FOR UPDATE`** | **524,4** | 122 ms | **0** | **0** | ✅ |
| Optimistic | **2,85** | **19.727 ms** | 75 | 28 | ✅ |
| Serializable | **1,83** | **34.898 ms** | 0 | 0 | ✅ |

### **`FOR UPDATE` nhanh hơn Serializable 286 lần khi tranh chấp cao.**

Và `FOR UPDATE` gần như **không suy giảm** (847 → 524 tps) khi thu hẹp từ 20 xuống 3 tài khoản, trong khi hai cách kia mất 99 %.

> ## **Kết luận đảo ngược trực giác thông thường:**
>
> **Khi tranh chấp cao, pessimistic lock (`FOR UPDATE`) ĂN ĐỨT optimistic và Serializable.**
>
> Optimistic chỉ thắng khi tranh chấp **thấp** (568 vs 550 tps ở 4 client — chênh 3 %).
>
> Lý do: khoá biến tranh chấp thành **hàng đợi có trật tự**; retry biến tranh chấp thành **công vô ích lặp lại**. Càng tranh chấp, khoảng cách càng lớn.

---

## §5. Kiểm tra tính đúng đắn

```
sum(balance) = 10.000.000 ở TẤT CẢ 12 lần bench
```

**Cả ba chiến lược đều giữ đúng tổng số dư** — kể cả optimistic sau khi sửa ở §3.

Nếu dùng bản gốc trong đề (hai `UPDATE` riêng + `CONTINUE`), tổng sẽ **sai** khi có xung đột ở update thứ hai: tiền bị trừ mà không được cộng.

> **Đây là lý do phải luôn có một invariant kiểm tra được.** Throughput cao mà kết quả sai thì vô nghĩa — và bug loại này chỉ lộ ra khi tải cao.

---

## §6. `linearizability` ≠ `serializability`

### Ba câu phân biệt

> **Serializability nói về TRANSACTION: kết quả cuối cùng phải tương đương với việc chạy các transaction lần lượt theo MỘT thứ tự tuần tự nào đó — nhưng thứ tự đó không cần trùng với thứ tự thời gian thực.**
>
> **Linearizability nói về MỘT THAO TÁC trên một đối tượng: mỗi thao tác phải có vẻ xảy ra tức thời tại một thời điểm nằm giữa lúc gọi và lúc trả về, nên nó TÔN TRỌNG thứ tự thời gian thực — cái gì commit trước thì mọi thao tác bắt đầu sau đó phải thấy.**
>
> **Kết hợp cả hai gọi là strict serializability (one-copy serializability) — đó là thứ Spanner cung cấp, còn Postgres `SERIALIZABLE` trên một node chỉ cho serializability, và qua replica thì không cả linearizable lẫn serializable.**

### Ví dụ cụ thể để nhớ

```
T1 commit lúc 10:00:00
T2 bắt đầu  lúc 10:00:01

Serializability CHO PHÉP thứ tự tương đương là "T2 rồi T1"
   -> T2 có thể KHÔNG THẤY kết quả của T1, dù T1 đã commit trước
Linearizability CẤM điều đó.
```

### 🔧 Nơi khác biệt này gây bất ngờ trong hệ CQRS

```
1. Người dùng bấm "Cập nhật tên thiết bị"
2. Command handler ghi vào PRIMARY, commit thành công, trả 200 OK
3. UI reload, gọi query API
4. Query API đọc từ REPLICA (đúng thiết kế CQRS — tách read/write)
5. Replica chưa nhận được WAL của bước 2  ->  UI hiện TÊN CŨ
6. Người dùng: "Sao lưu không được?" -> bấm lại -> ghi đè lần nữa
```

**Đây là vi phạm linearizability (read-your-writes), không phải vi phạm serializability.** Mỗi transaction đều serializable hoàn hảo; vấn đề là thứ tự **thời gian thực** giữa write ở primary và read ở replica.

Postgres `SERIALIZABLE` **không cứu được** — nó chỉ đảm bảo trong phạm vi một node.

Cách sửa (Day 38): **LSN gating** — sau khi commit, lấy `pg_current_wal_insert_lsn()`, gửi kèm response; lần đọc sau kiểm tra `pg_last_wal_replay_lsn()` của replica đã vượt LSN đó chưa, nếu chưa thì đọc từ primary.

---

## §7. Ôn tuần 6

### A. Bảng quyết định

| Tình huống | **Công cụ** | Vì sao |
|---|---|---|
| **Đếm rồi cộng dồn một số** | `UPDATE x SET n = n + 1` (**tính trong SQL**) | Nguyên tử sẵn, không khoá lâu, không retry. Day 27 §1: cho kết quả đúng 700 |
| **Hai lệnh sửa cùng một aggregate** | **Optimistic lock (version)** | Xung đột hiếm → retry rẻ; không khoá → đồng thời cao. Day 30: nhanh nhất ở tranh chấp thấp (568 tps) |
| **Ràng buộc qua nhiều dòng/bảng** | **Materializing conflict** (`FOR UPDATE` trên dòng đại diện) | Day 30 chứng minh Serializable sụp ở tranh chấp cao (**1,8 tps**). `FOR UPDATE` giữ **524 tps** |
| **Job queue nhiều worker** | **`FOR UPDATE SKIP LOCKED`** | Day 28: 4 worker, **0 job trùng**, cân bằng tuyệt đối |
| **Một job chỉ chạy một instance** | **`pg_try_advisory_xact_lock(ns, id)`** | Không cần bảng phụ, tự nhả khi transaction kết thúc |
| **Báo cáo nhất quán một thời điểm** | **`REPEATABLE READ`** + retry | Snapshot cố định (Day 26 §3); rẻ hơn Serializable vì không có predicate lock |

**Serializable dùng khi nào?** Khi ràng buộc **phức tạp, khó liệt kê hết**, **và** tranh chấp **thấp**. Với tranh chấp cao, dùng materializing conflict.

### B. Checklist review code về tương tranh — 8 câu hỏi

```
① Transaction này có gọi API ngoài / đọc file / chờ I/O không?
   -> CÓ: tách ra ngoài transaction. Day 29 §5: kẻ chặn ở trạng thái 'idle in transaction'.

② Có khoá nhiều dòng không? Nếu có, ID đã được SẮP XẾP chưa?
   -> Day 29 §6: ORDER BY id làm deadlock BẤT KHẢ THI, không chỉ "giảm xác suất".

③ Có mẫu "đọc -> quyết định -> ghi" không?
   -> Đưa điều kiện VÀO câu UPDATE: UPDATE ... WHERE id=? AND balance >= ?
   -> rồi KIỂM TRA affected rows. Day 26 §6: EvalPlanQual bỏ sót dòng âm thầm.

④ Có dùng REPEATABLE READ / SERIALIZABLE không? Nếu có, retry loop ở ĐÂU?
   -> Phải ở tầng ứng dụng (plpgsql chỉ tạo subtransaction, không rollback được).
   -> Bắt CẢ 40001 lẫn 40P01. Có backoff + jitter + giới hạn số lần chưa?

⑤ Transaction retry có IDEMPOTENT không?
   -> Gửi email / gọi API / trừ tiền bên thứ ba phải nằm NGOÀI transaction.

⑥ Ràng buộc nghiệp vụ có bao trùm NHIỀU dòng/aggregate không?
   -> CÓ: đây là write skew (Day 27 §2). Optimistic lock KHÔNG đủ.
   -> Chọn: EXCLUDE constraint > materializing conflict > Serializable.

⑦ Job queue có dùng SKIP LOCKED không? Có partial index không?
   -> Day 28: thiếu SKIP LOCKED = tuần tự hoá hoàn toàn.
   -> Thiếu partial index = chậm 3,6 lần.

⑧ SELECT ... FOR UPDATE trên bảng có khoá ngoại?
   -> Đổi sang FOR NO KEY UPDATE nếu không sửa cột khoá.
   -> Day 29 §4: nó loại bỏ hoàn toàn contention với INSERT vào bảng con.
```

### C. Ba điều tôi tưởng đúng mà hoá ra sai trong tuần 6

**1. "Optimistic lock luôn tốt hơn pessimistic vì không khoá."**

*Sự thật:* ở 64 client tranh chấp cao, `FOR UPDATE` cho **524 tps** còn optimistic chỉ **2,85 tps** — **chậm hơn 184 lần**, latency 19,7 giây, 28 transaction thất bại hoàn toàn.

Optimistic chỉ thắng khi tranh chấp **thấp**, và thắng rất ít (568 vs 550 tps = 3 %).

**2. "Serializable là 'chế độ an toàn', chỉ chậm hơn một chút."**

*Sự thật:* **3,6 tps ở 64 client** — chậm hơn `FOR UPDATE` **235 lần**. Với tranh chấp cao: **1,8 tps**, chậm **286 lần**, latency **34,9 giây**.

Nguyên nhân: predicate lock **leo thang lên mức relation** khi đọc nhiều dòng → mọi transaction xung đột với mọi transaction.

**3. "Repeatable Read đủ an toàn cho logic nghiệp vụ."**

*Sự thật (Day 27):* write skew vẫn xảy ra — **0 bác sĩ trực**, cả hai transaction commit thành công, **không có lỗi nào**. Và phantom write skew với `INSERT`: tổng **11** ghế trên giới hạn **10**.

**Bonus 4:** `SHOW transaction_isolation` sau khi khai `READ UNCOMMITTED` trả về **`read uncommitted`**, không phải `read committed` như tài liệu hay nói (Day 26 §1).

---

## Bảng số liệu chính

| Kịch bản | tps | latency | retried | failed |
|---|---|---|---|---|
| `FOR UPDATE` @ 4 / 16 / 64 | **549,6 / 811,0 / 847,2** | 7,3 / 19,7 / 75,5 ms | **0** | **0** |
| Optimistic @ 4 / 16 / 64 | **568,3 / 371,8 / 271,9** | 7,0 / 41,7 / 214,0 ms | ~2.000 | 0 / 145 / **440** |
| Serializable @ 4 / 16 / 64 | **403,5 / 133,5 / 3,6** | 9,9 / 110,7 / **16.865 ms** | 1.388 / 979 / 51 | 7 / 140 / 3 |
| **Tranh chấp cao (3 tk) @ 64** | | | | |
| — `FOR UPDATE` | **524,4** | 122 ms | 0 | 0 |
| — Optimistic | **2,85** | **19.727 ms** | 75 | 28 |
| — Serializable | **1,83** | **34.898 ms** | 0 | 0 |
| `sum(balance)` mọi lần bench | **10.000.000** ✅ | | | |
| Predicate lock đọc 100 dòng | **1 lock, mức relation** | | | |
| Predicate lock đọc 107.947 dòng | **2 lock, mức relation** (leo thang) | | | |

---

## B. Ba use case và chiến lược cho hệ thật

**1. Cập nhật trạng thái device (`device_state`) — optimistic lock**
- Mỗi device là một aggregate độc lập, tranh chấp gần như bằng 0 (chỉ device đó ghi vào chính nó)
- Đo được: optimistic nhanh nhất ở tranh chấp thấp
- Kèm `@DynamicUpdate` + `fillfactor = 70` (Day 24) để giữ HOT update

**2. Hạn mức "tối đa N device active mỗi tenant" — materializing conflict**
- Ràng buộc bao trùm nhiều aggregate → **write skew** (Day 27)
- Tranh chấp **trong phạm vi một tenant**, tương đối cao khi tenant lớn kích hoạt hàng loạt
- Serializable sẽ sụp (đo được **1,8 tps**); `FOR UPDATE` trên dòng `tenant` giữ **524 tps**
```sql
BEGIN;
SELECT 1 FROM tenant WHERE id = $1 FOR UPDATE;
SELECT count(*) FROM device WHERE tenant_id = $1 AND is_active;
UPDATE device SET is_active = true WHERE id = $2;
COMMIT;
```

**3. Outbox → Kafka publisher — `FOR UPDATE SKIP LOCKED`**
- Nhiều instance publisher chạy song song
- Day 28: 0 message trùng, cân bằng tuyệt đối, **2.534 msg/s** với partial index
- Kèm partial index `WHERE published_at IS NULL` và autovacuum hung hăng

---

## Ba điều dễ hiểu sai

| # | Hiểu nhầm | Sự thật đo được |
|---|---|---|
| 1 | "Khoá làm giảm throughput" | `FOR UPDATE` **TĂNG** tps khi thêm client (550 → 847). Khoá biến tranh chấp thành hàng đợi có trật tự |
| 2 | "Serializable chỉ chậm hơn một chút" | **3,6 tps** ở 64 client — chậm **235 lần**. Tranh chấp cao: **286 lần** |
| 3 | "Predicate lock ở mức tuple nên chính xác" | Đọc > 64 dòng đã **leo thang lên relation** — xung đột với mọi ghi vào bảng, kể cả dòng chưa chạm |

---

## Áp dụng vào hệ thật

**1. Đo trước khi chọn chiến lược.** Số liệu ở đây đảo ngược mọi trực giác — đừng tin lời khuyên chung, hãy bench workload thật của mình:
```bash
pgbench -f script.sql -c 64 -j 4 -T 30 -M prepared --max-tries=10
```
Kèm kiểm tra invariant sau mỗi lần chạy.

**2. Nếu đang dùng Serializable, kiểm tra ngay predicate lock có leo thang không:**
```sql
SELECT mode, locktype, relation::regclass,
       count(*) FILTER (WHERE tuple IS NOT NULL) AS muc_tuple,
       count(*) FILTER (WHERE tuple IS NULL AND page IS NOT NULL) AS muc_page,
       count(*) FILTER (WHERE page IS NULL) AS muc_relation
FROM pg_locks WHERE mode='SIReadLock' GROUP BY 1,2,3;
```
`muc_relation > 0` = đang khoá cả bảng → sẽ xung đột với mọi ghi. Thu hẹp phạm vi đọc bằng index, hoặc nâng `max_pred_locks_per_transaction`.

**3. Theo dõi tỷ lệ serialization failure trên production:**
```sql
SELECT datname, xact_commit, xact_rollback,
       round(100.0*xact_rollback/NULLIF(xact_commit+xact_rollback,0),2) AS pct_rollback
FROM pg_stat_database WHERE datname = current_database();
```
Kèm đếm SQLSTATE 40001/40P01 trong log. **Tỷ lệ retry > 5 % = chiến lược đang sai** với mức tranh chấp thực tế.

**4. Với mọi transaction retry, kiểm tra idempotency.** Đây là bug tệ nhất của retry: gửi email 2 lần, gọi API thanh toán 2 lần. Mọi side effect ngoài DB phải nằm **ngoài** transaction.

**5. Luôn có một invariant kiểm tra được** (như `sum(balance)`), và chạy nó sau mỗi lần load test. Throughput cao mà kết quả sai thì vô nghĩa — và bug loại này **chỉ lộ ra khi tải cao**.

---

## Hết tuần 6

| Ngày | Câu hỏi được trả lời | Con số đắt nhất |
|---|---|---|
| 26 | Ba isolation level | snapshot chụp ở **câu lệnh đầu tiên** không phải `BEGIN`; RC vs RR cho **kết quả số khác nhau** (800 vs 900) |
| 27 | Ba anomaly | write skew ở RR: **0 bác sĩ trực**, cả hai commit, **không lỗi** |
| 28 | `SKIP LOCKED` & job queue | 4 worker, **0 job trùng**; partial index nhanh **3,6×** nhưng phá HOT hoàn toàn |
| 29 | Deadlock | `ORDER BY id` làm deadlock **bất khả thi**; khoá ngoại **không** deadlock nhờ `FOR NO KEY UPDATE` |
| 30 | SSI & throughput | **`FOR UPDATE` nhanh hơn Serializable 286×** khi tranh chấp cao |

**Bài học lớn nhất của tuần 6:**

> Isolation level cao hơn **không** phải "an toàn hơn với giá rẻ hơn một chút". Serializable đổi tính đúng đắn lấy throughput theo tỷ lệ có thể lên tới **hàng trăm lần** khi tranh chấp cao.
>
> Cách đúng gần như luôn là: **giữ Read Committed, rồi bảo vệ đúng chỗ cần bảo vệ** bằng công cụ hẹp nhất — điều kiện trong `UPDATE`, optimistic lock cho aggregate, `FOR UPDATE` trên dòng đại diện cho ràng buộc liên-aggregate, `SKIP LOCKED` cho queue.

Tuần 7 quay lại đúng bài toán đang chạy: **time-series và IoT** — BRIN, partitioning, retention, jsonb.
