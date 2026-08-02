# Day 30 — SERIALIZABLE (SSI), retry, và đo throughput + ôn tuần 6

**Thời lượng:** 60–90 phút · **Cách học:** đọc một mục → gõ ngay → ghi kết quả → mục tiếp theo.

## Chuẩn bị

```sql
\o /days/day-30/output.txt
DROP TABLE IF EXISTS acct;
CREATE TABLE acct (id int PRIMARY KEY, balance int NOT NULL, version int NOT NULL DEFAULT 0);
INSERT INTO acct SELECT g, 100000, 0 FROM generate_series(1, 100) g;
```

---

## §0. Đoán trước

Cùng một workload tranh chấp, ba cách: (a) `FOR UPDATE`, (b) optimistic version + retry, (c) `SERIALIZABLE` + retry.

1. Cách nào throughput cao nhất khi **ít** tranh chấp?
2. Cách nào cao nhất khi **nhiều** tranh chấp?
3. Tỷ lệ retry của Serializable ở 64 client song song là bao nhiêu?

---

## §1. SSI hoạt động thế nào

### Lý thuyết

Serializable của Postgres dùng **SSI — Serializable Snapshot Isolation**. Nó **không dùng khoá đọc** (khác với two-phase locking của SQL Server/DB2 truyền thống).

Thay vào đó, nó theo dõi **phụ thuộc** giữa các transaction:

- **rw-dependency** (còn gọi là dangerous structure): T1 đọc một thứ mà T2 sau đó ghi đè.

Lý thuyết SSI chứng minh: mọi lịch trình không-serializable đều chứa một transaction có **cả rw-dependency vào lẫn rw-dependency ra** — gọi là "pivot". Postgres phát hiện cấu trúc đó và abort một transaction trong nhóm.

Để theo dõi việc đọc, Postgres dùng **predicate lock** (`SIReadLock`) — đánh dấu vùng dữ liệu đã đọc, ở mức tuple / page / relation tuỳ độ mịn cần thiết. Chúng **không chặn ai cả**, chỉ để phát hiện xung đột.

Hai điều quan trọng:

1. **Predicate lock có thể bị leo thang** (tuple → page → relation) khi vượt `max_pred_locks_per_transaction`. Leo thang làm tăng false positive → nhiều abort không cần thiết. Với transaction đọc nhiều, nên nâng GUC này.
2. **Abort có thể xảy ra lúc COMMIT**, không chỉ lúc chạy câu lệnh. Nên retry phải bọc **toàn bộ** transaction, kể cả commit.

### Làm ngay

```sql
SHOW max_pred_locks_per_transaction;
SHOW max_pred_locks_per_relation;
SHOW max_pred_locks_per_page;
```

Xem predicate lock thật (2 session):

**S1:**
```sql
BEGIN TRANSACTION ISOLATION LEVEL SERIALIZABLE;
SELECT count(*) FROM acct WHERE balance > 50000;
```
**S2:**
```sql
SELECT locktype, relation::regclass, page, tuple, mode, pid
FROM pg_locks WHERE mode = 'SIReadLock';
```

**Ghi vào writeup:** có bao nhiêu `SIReadLock`? Chúng ở mức tuple, page hay relation? **S1:** `COMMIT;`

---

## §2. Predicate lock leo thang

### Làm ngay

**S1:**
```sql
BEGIN TRANSACTION ISOLATION LEVEL SERIALIZABLE;
SELECT count(*) FROM ts_kv WHERE device_id = 1;   -- đọc rất nhiều dòng
```
**S2:**
```sql
SELECT mode, locktype, relation::regclass,
       count(*) FILTER (WHERE tuple IS NOT NULL) AS muc_tuple,
       count(*) FILTER (WHERE tuple IS NULL AND page IS NOT NULL) AS muc_page,
       count(*) FILTER (WHERE page IS NULL) AS muc_relation,
       count(*) AS tong
FROM pg_locks WHERE mode='SIReadLock' GROUP BY 1,2,3;
```
**S1:** `COMMIT;`

**Ghi vào writeup:** lock ở mức nào? So với §1 (đọc ít dòng) — có leo thang không? **Hệ quả: transaction Serializable đọc nhiều dữ liệu sẽ xung đột với nhiều thứ hơn mức cần thiết. Điều đó gợi ý gì về việc thiết kế transaction?**

---

## §3. Ba chiến lược — cài đặt

### Làm ngay

Viết 3 hàm, mỗi hàm chuyển tiền giữa hai tài khoản ngẫu nhiên:

```sql
-- (a) pessimistic: FOR UPDATE
CREATE OR REPLACE FUNCTION cv_lock(a int, b int, amt int) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE lo int := least(a,b); hi int := greatest(a,b);
BEGIN
  PERFORM * FROM acct WHERE id IN (lo,hi) ORDER BY id FOR UPDATE;
  UPDATE acct SET balance = balance - amt WHERE id = a;
  UPDATE acct SET balance = balance + amt WHERE id = b;
  RETURN 0;   -- 0 lần retry
END $$;

-- (b) optimistic: version column + retry
CREATE OR REPLACE FUNCTION cv_optimistic(a int, b int, amt int) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE va int; vb int; ba int; bb int; n int := 0;
BEGIN
  LOOP
    SELECT version, balance INTO va, ba FROM acct WHERE id = a;
    SELECT version, balance INTO vb, bb FROM acct WHERE id = b;
    UPDATE acct SET balance = ba - amt, version = va + 1 WHERE id = a AND version = va;
    IF NOT FOUND THEN n := n+1; CONTINUE; END IF;
    UPDATE acct SET balance = bb + amt, version = vb + 1 WHERE id = b AND version = vb;
    IF NOT FOUND THEN n := n+1; CONTINUE; END IF;
    RETURN n;
  END LOOP;
END $$;

-- (c) serializable: dựa vào SSI, retry ở ngoài (xem §4)
CREATE OR REPLACE FUNCTION cv_plain(a int, b int, amt int) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE ba int; bb int;
BEGIN
  SELECT balance INTO ba FROM acct WHERE id = a;
  SELECT balance INTO bb FROM acct WHERE id = b;
  UPDATE acct SET balance = ba - amt WHERE id = a;
  UPDATE acct SET balance = bb + amt WHERE id = b;
  RETURN 0;
END $$;
```

> Chú ý: `cv_optimistic` như viết ở trên **không** an toàn hoàn toàn (nếu update thứ hai fail thì update thứ nhất đã áp dụng). Trong thực tế nó phải nằm trong transaction để rollback được. Đây là bài tập: **sửa lại cho đúng** và ghi vào writeup bạn đã sửa gì.

---

## §4. Đo throughput bằng `pgbench`

### Lý thuyết

`pgbench` có sẵn trong image Postgres. Nó tự động retry lỗi serialization/deadlock từ PG13 (báo trong output là `number of transactions retried`).

Cú pháp cần dùng:
```
pgbench -f script.sql -c <clients> -j <threads> -T <giây> -M prepared --max-tries=10
```

### Làm ngay

Tạo 3 script bench:

```bash
mkdir -p days/day-30/bench

cat > days/day-30/bench/lock.sql <<'EOF'
\set a random(1, 20)
\set b random(1, 20)
BEGIN;
SELECT cv_lock(:a, :b, 10) WHERE :a <> :b;
COMMIT;
EOF

cat > days/day-30/bench/optimistic.sql <<'EOF'
\set a random(1, 20)
\set b random(1, 20)
BEGIN;
SELECT cv_optimistic(:a, :b, 10) WHERE :a <> :b;
COMMIT;
EOF

cat > days/day-30/bench/serializable.sql <<'EOF'
\set a random(1, 20)
\set b random(1, 20)
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT cv_plain(:a, :b, 10) WHERE :a <> :b;
COMMIT;
EOF

docker cp days/day-30/bench pgdd:/tmp/bench
```

Chạy ma trận 3 chiến lược × 4 mức song song:

```bash
for f in lock optimistic serializable; do
  for c in 4 16 64; do
    echo "=== $f @ $c clients ==="
    docker exec pgdd pgbench -U postgres -d lab -f /tmp/bench/$f.sql \
      -c $c -j 4 -T 15 -M prepared --max-tries=10 2>&1 | \
      grep -E 'tps|latency|retried|failed'
  done
done
```

**Ghi vào writeup — bảng 9 dòng:** chiến lược | clients | tps | latency trung bình | số transaction retried | số failed.

Rồi thu hẹp phạm vi tranh chấp để tăng contention (`random(1, 3)` thay vì `random(1, 20)`) và chạy lại mức 64 client.

**Ghi vào writeup:** khi contention tăng, chiến lược nào tụt nhanh nhất?

---

## §5. Kiểm tra tính đúng đắn

### Lý thuyết

Throughput cao mà kết quả sai thì vô nghĩa. Tổng số dư phải **luôn** không đổi (mọi giao dịch đều là chuyển tiền).

### Làm ngay

```sql
SELECT sum(balance) FROM acct;   -- phải bằng 100 × 100000 = 10.000.000
```

Chạy sau mỗi lần bench.

**Ghi vào writeup:** chiến lược nào giữ đúng tổng, chiến lược nào không? Nếu `cv_optimistic` sai tổng, **giải thích vì sao** và bạn đã sửa thế nào ở §3.

---

## §6. `linearizability` ≠ `serializability`

### Lý thuyết

Hai khái niệm này rất hay bị nhầm, kể cả trong tài liệu.

| | Serializability | Linearizability |
|---|---|---|
| Về cái gì | **transaction** (nhiều thao tác) | **một thao tác** trên một đối tượng |
| Đảm bảo gì | kết quả tương đương với **một thứ tự tuần tự nào đó** | mỗi thao tác có vẻ xảy ra tức thời tại một thời điểm giữa lúc gọi và lúc trả về |
| Có ràng buộc thời gian thực không | **Không** — thứ tự tuần tự đó có thể khác thứ tự thời gian thực | **Có** — tôn trọng thứ tự thời gian thực |
| Thuộc phạm trù | lý thuyết database | lý thuyết hệ phân tán |

Kết hợp cả hai gọi là **strict serializability** (hay one-copy serializability) — đây mới là thứ Spanner cung cấp.

Postgres `SERIALIZABLE` trên một node là serializable **nhưng không linearizable qua replica**: bạn commit ở primary rồi đọc replica có thể không thấy dữ liệu vừa ghi (Day 38).

Ví dụ cụ thể để nhớ: T1 commit lúc 10:00:00, T2 bắt đầu lúc 10:00:01. Serializability cho phép thứ tự tương đương là "T2 rồi T1" — nghĩa là T2 có thể **không thấy** kết quả của T1. Linearizability thì cấm điều đó.

### Làm ngay

Không SQL. **Ghi vào writeup:** phân biệt hai khái niệm bằng **3 câu** của bạn, kèm một ví dụ từ hệ CQRS của bạn nơi sự khác biệt này gây ra hành vi bất ngờ cho người dùng.

---

## §7. Ôn tuần 6

**Viết vào `writeup.md`:**

**A. Bảng quyết định:** với mỗi tình huống, chọn công cụ nào.

| Tình huống | Công cụ | Vì sao |
|---|---|---|
| Đếm rồi cộng dồn một số | | |
| Hai lệnh sửa cùng một aggregate | | |
| Ràng buộc qua nhiều dòng/bảng | | |
| Job queue nhiều worker | | |
| Đảm bảo một job chỉ chạy một instance | | |
| Báo cáo cần nhất quán một thời điểm | | |

**B. Checklist review code về tương tranh** — 8 câu hỏi bạn sẽ hỏi khi review PR của đồng nghiệp.

**C. Ba điều tôi tưởng đúng mà hoá ra sai trong tuần 6.**

### Dọn dẹp

```sql
DROP FUNCTION cv_lock(int,int,int), cv_optimistic(int,int,int), cv_plain(int,int,int);
DROP TABLE acct;
```

---

## Kết ngày

### Hai câu cuối

**A. Bạn đoán sai chỗ nào ở §0?**

**B. Áp dụng vào hệ thật:** với số liệu bench bạn vừa đo, chiến lược nào phù hợp cho use case nào trong hệ của bạn? Kể tên **ba** use case cụ thể và chiến lược cho từng cái.

### Đạt khi

Bạn có bảng số liệu thật so sánh ba chiến lược ở nhiều mức song song, chọn được đúng cái cho từng use case, và phân biệt rõ serializability với linearizability.

**Xong thì gõ `/review-bai`.**

---

## Hết tuần 6

Xong phần tương tranh. Tuần 7 quay lại đúng bài toán bạn đang chạy: **time-series và IoT** — BRIN, partitioning, retention, jsonb.
