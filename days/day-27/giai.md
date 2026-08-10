# Day 27 — Lời giải: Lost update, write skew, phantom — tự tay tái hiện

> Bài chữa. Đo thật bằng **hai session psql song song**.

---

## §0. Đáp án phần đoán

Ràng buộc: **"luôn phải còn ít nhất 1 bác sĩ trực"**. Hai bác sĩ cùng xin nghỉ.

| # | Level | Ràng buộc có vỡ không? | Kết quả đo được |
|---|---|---|---|
| 1 | **Read Committed** | ✅ **VỠ** | 0 bác sĩ trực |
| 2 | **Repeatable Read** | ✅ **VỠ** | **0 bác sĩ trực** |
| 3 | **Serializable** | ❌ **KHÔNG vỡ** | **1 bác sĩ trực**, S2 bị abort |

Câu 2 là câu bất ngờ nhất: **Repeatable Read không cứu được**, dù nó chặn được cả non-repeatable read lẫn phantom (Day 26).

---

## §1. Lost update

| Bước | S1 | S2 |
|---|---|---|
| | `BEGIN; SELECT balance` → **1000** | |
| | | `BEGIN; SELECT balance` → **1000** |
| | `UPDATE ... = 900; COMMIT;` | |
| | | `UPDATE ... = 800; COMMIT;` |

```
 kết quả | đúng ra phải là
---------+-----------------
     800 |             700
```

**Thao tác của S1 bị nuốt mất hoàn toàn.** 100 đồng biến mất.

Nguyên nhân: cả hai đọc rồi tính toán **ở tầng ứng dụng**, database chỉ nhận giá trị cuối cùng và không biết gì về ý định.

### Bốn cách sửa — đo thật

| Cách | Kết quả | Chặn được? | Ưu điểm | Nhược điểm | Dùng khi |
|---|---|---|---|---|---|
| **1. Tính trong SQL** `balance = balance - 100` | **700** ✅ | ✅ | Đơn giản nhất, không khoá lâu, không retry | **Chỉ dùng được cho phép toán tương đối** (cộng/trừ). Không kiểm tra được điều kiện phức tạp | Counter, số dư, tồn kho |
| **2. Pessimistic lock** `SELECT ... FOR UPDATE` | **700** ✅ | ✅ | Đọc-tính-ghi tuỳ ý; không cần retry | Khoá dòng suốt transaction → **giảm đồng thời**; nguy cơ deadlock (Day 29) | Tranh chấp cao, logic phức tạp |
| **3. Optimistic lock** (version column) | — | ✅ | **Không khoá gì cả**, đồng thời cao nhất | Phải retry ở tầng app; phải nhớ đưa `version` vào mọi UPDATE | **DDD aggregate root** |
| **4. Repeatable Read + retry** | — | ✅ (bằng lỗi 40001) | Bảo vệ toàn transaction, không chỉ một dòng | Bắt buộc retry; lỗi xảy ra muộn (lúc UPDATE/COMMIT) | Batch job đọc nhiều bảng |

Chi tiết đáng chú ý ở **cách 2**: khi S1 giữ `FOR UPDATE`, S2 bị chặn ở chính câu `SELECT ... FOR UPDATE`. Sau khi S1 commit, S2 đọc lại và thấy **900** (không phải 1000) → `balance - 200` = **700** đúng.

**`SELECT ... FOR UPDATE` ở Read Committed tự động đọc lại phiên bản mới nhất sau khi được cấp khoá** — đây là điểm khác biệt then chốt so với `SELECT` thường.

### 🔧 Trong DDD/CQRS chọn cách nào cho aggregate root

**Optimistic lock (cách 3)** — và đây là lựa chọn đúng:

```sql
UPDATE aggregate
SET ..., version = version + 1
WHERE id = $1 AND version = $2;
-- affected = 0  ->  OptimisticLockException  ->  retry ở tầng application
```

Lý do:
- **Aggregate root vốn đã là đơn vị nhất quán** — mọi invariant nằm trong nó, kiểm tra trong bộ nhớ rồi ghi một lần
- **Không khoá** → chịu được đồng thời cao, không có deadlock
- **Xung đột hiếm** trong thực tế (hai lệnh cùng sửa một aggregate cùng lúc là bất thường) → retry rẻ

**Nhưng nó chỉ bảo vệ MỘT aggregate.** §2 cho thấy chỗ nó thất bại.

---

## §2. Write skew — anomaly mà Repeatable Read KHÔNG chặn

### Repeatable Read — ràng buộc VỠ

| Bước | S1 (bác sĩ An) | S2 (bác sĩ Bình) |
|---|---|---|
| | `SELECT count(*) WHERE dang_truc` → **2** | |
| | | `SELECT count(*) WHERE dang_truc` → **2** |
| | *"còn 2 người, mình nghỉ được"* | *"còn 2 người, mình nghỉ được"* |
| | `UPDATE ... WHERE id=1; COMMIT;` ✅ | |
| | | `UPDATE ... WHERE id=2; COMMIT;` ✅ |

```
 còn bao nhiêu bác sĩ trực
---------------------------
                         0        ⚠️ RÀNG BUỘC VỠ
```

**Cả hai commit thành công. Không có lỗi nào. Bệnh viện không còn bác sĩ trực.**

### Vì sao Repeatable Read không phát hiện được

Snapshot isolation phát hiện xung đột bằng cách kiểm tra: *"dòng tôi sắp ghi có bị ai sửa sau snapshot của tôi không?"*

- S1 ghi dòng `id=1` — không ai đụng
- S2 ghi dòng `id=2` — không ai đụng

**Không có xung đột GHI.** Xung đột nằm ở chỗ khác: mỗi transaction **đọc** một tập dữ liệu rồi **ghi** vào phần khác của tập đó, làm mất hiệu lực giả định của transaction kia.

Đây gọi là **read-write dependency**, và snapshot isolation không theo dõi nó.

### Serializable — được chặn

Cùng kịch bản, đổi `REPEATABLE READ` → `SERIALIZABLE`:

```
S2:  UPDATE oncall SET dang_truc = false WHERE id = 2;
ERROR:  could not serialize access due to read/write dependencies among transactions
DETAIL:  Reason code: Canceled on identification as a pivot, during write.
HINT:  The transaction might succeed if retried.
```

```
 còn bao nhiêu bác sĩ trực (serializable)
------------------------------------------
                                        1        ✅ RÀNG BUỘC GIỮ ĐƯỢC
```

### Đọc kỹ thông báo lỗi

| Phần | Nghĩa |
|---|---|
| `read/write dependencies among transactions` | SSI phát hiện **phụ thuộc đọc-ghi**, không phải xung đột ghi-ghi |
| **`Canceled on identification as a pivot`** | S2 là **pivot** — transaction nằm giữa một chuỗi `T1 → T2 → T3` tạo thành chu trình nguy hiểm |
| `during write` | phát hiện lúc **ghi** (không phải lúc commit — có thể xảy ra ở cả hai) |
| `The transaction might succeed if retried` | **gợi ý rõ ràng: PHẢI có retry loop** |

SSI (Serializable Snapshot Isolation) theo dõi **predicate lock** — nó ghi nhớ "S1 đã đọc tập dòng thoả `dang_truc = true`". Khi S2 ghi vào tập đó, SSI phát hiện chu trình và huỷ một bên.

> ## **Đây là lý do `SERIALIZABLE` tồn tại, và là lý do optimistic locking trên từng aggregate KHÔNG ĐỦ cho ràng buộc liên-aggregate.**
>
> Optimistic lock bảo vệ "aggregate này không bị sửa đồng thời". Write skew là "hai aggregate khác nhau, mỗi cái đúng riêng, nhưng cùng nhau phá ràng buộc bao trùm".

---

## §3. Phantom trong write skew

Ràng buộc: mỗi phòng tối đa 10 ghế. Hiện có 9.

| Level | S1 thấy | S2 thấy | Kết quả | Đúng? |
|---|---|---|---|---|
| **Repeatable Read** | 9 | 9 | **11** ⚠️ | ❌ vượt giới hạn |
| **Serializable** | 9 | 9 | **10** ✅ | ✅ S2 bị abort |

Ở Serializable, S2 nhận **cùng một lỗi**:
```
ERROR:  could not serialize access due to read/write dependencies among transactions
DETAIL:  Reason code: Canceled on identification as a pivot, during write.
```

### Điểm đáng chú ý: đây là write skew với `INSERT`, khó hơn nhiều

Với `UPDATE` (§2), ít nhất còn có **dòng tồn tại** để khoá. Với `INSERT`, dòng **chưa tồn tại** — không có gì để khoá.

Đây chính là lý do các cách sửa thủ công (`SELECT ... FOR UPDATE` trên dòng dữ liệu) **không hoạt động** cho ca này. Phải khoá **một đại diện của tập** (§4) hoặc dùng Serializable.

---

## §4. Sửa write skew mà không dùng Serializable

### Cách 1 — Materializing conflict (bảng khoá)

```sql
CREATE TABLE phong_lock (phong text PRIMARY KEY);
INSERT INTO phong_lock VALUES ('A');
-- mỗi transaction:
SELECT 1 FROM phong_lock WHERE phong='A' FOR UPDATE;
```

| Bước | S1 | S2 |
|---|---|---|
| | `SELECT ... FOR UPDATE` ✅ được khoá | |
| | `SELECT sum(ghe)` → **9** | |
| | | `SELECT ... FOR UPDATE` → **BỊ CHẶN** |
| | | `wait_event_type = Lock`, `wait_event = transactionid` |
| | `INSERT`; `COMMIT;` | |
| | | *(được khoá)* `SELECT sum(ghe)` → **10** → **không chèn nữa** |

```
 tổng (materializing conflict)
-------------------------------
                            10        ✅ đúng
```

**Nó "vật hoá" xung đột**: biến một xung đột trừu tượng (trên *tập* dòng) thành xung đột cụ thể (trên *một* dòng có thể khoá được).

### Cách 2 — Advisory lock

```sql
SELECT pg_advisory_xact_lock(hashtext('phong:A'));
```

```
 pid  | wait_event_type | wait_event
------+-----------------+------------
 2347 | Lock            | advisory        <- khác 'transactionid' ở cách 1
```

Kết quả giống hệt: S2 chờ, rồi thấy **10**, không chèn.

`pg_advisory_xact_lock` tự nhả khi transaction kết thúc (commit hoặc rollback) — **an toàn hơn** `pg_advisory_lock` (phải tự `pg_advisory_unlock`, quên là rò rỉ khoá tới hết session).

### Cách 3 — Đưa ràng buộc vào database (mạnh nhất)

```sql
CREATE EXTENSION IF NOT EXISTS btree_gist;
ALTER TABLE booking ADD CONSTRAINT no_overlap
  EXCLUDE USING gist (phong WITH =, khoang_tg WITH &&);
```

Database **tự đảm bảo**, không phụ thuộc code nào nhớ khoá. Nhưng chỉ dùng được khi ràng buộc biểu diễn được bằng `EXCLUDE`/`CHECK`/`UNIQUE` — không phải ràng buộc nào cũng vậy (ví dụ "tổng ≤ 10" thì không).

### So sánh 3 cách — cột quan trọng nhất là "dễ sai sót"

| | **Serializable** | **Materializing conflict** | **Advisory lock** |
|---|---|---|---|
| Dễ sai sót | ✅ **thấp nhất** — database tự phát hiện mọi ràng buộc | ⚠️ cao — **mọi** code path phải nhớ khoá đúng dòng | ⚠️ **cao nhất** — không có gì buộc code phải gọi; hash collision im lặng |
| Ảnh hưởng throughput | ⚠️ **cao nhất** — mọi transaction đều theo dõi predicate lock, retry khi tải cao | trung bình — chỉ tuần tự hoá theo khoá | trung bình — như trên |
| Cần retry loop | **CÓ, bắt buộc** | không | không |
| Phạm vi bảo vệ | **toàn bộ** — mọi ràng buộc, kể cả chưa nghĩ ra | chỉ ràng buộc được khoá tường minh | như trên |
| Debug khi có sự cố | dễ (lỗi 40001 rõ ràng) | dễ (thấy lock chờ) | **khó** — advisory lock không hiện rõ trong `pg_locks` với tên nghiệp vụ |
| Chi phí khi **không** có tranh chấp | có (theo dõi SSI) | **~0** | **~0** |

### Khuyến nghị theo tình huống

| Tình huống | Chọn |
|---|---|
| Ràng buộc phức tạp, khó liệt kê hết, tranh chấp thấp | **Serializable + retry** |
| Ràng buộc rõ ràng, tranh chấp cao, throughput quan trọng | **Materializing conflict** |
| Cần khoá theo khoá nghiệp vụ không có bảng tương ứng | **Advisory lock** |
| Ràng buộc biểu diễn được bằng constraint | **`EXCLUDE`/`UNIQUE`/`CHECK`** — luôn ưu tiên |

**Advisory lock nguy hiểm nhất về mặt bảo trì**: một dev mới thêm một code path quên gọi lock → ràng buộc vỡ âm thầm, và không có gì trong schema nhắc nhở. Materializing conflict ít nhất còn có một bảng để thấy.

---

## §5. Bảng tổng kết — điền bằng kết quả ĐO ĐƯỢC

| Anomaly | Read Committed | Repeatable Read | Serializable | Sửa ở tầng app bằng |
|---|---|---|---|---|
| **Dirty read** | ✅ chặn | ✅ chặn | ✅ chặn | — (MVCC làm nó bất khả thi) |
| **Non-repeatable read** | ❌ **1000 → 500** | ✅ **1000 → 1000** | ✅ chặn | `FOR UPDATE`, hoặc nâng level |
| **Phantom read** | ❌ **4 → 5** | ✅ **3 → 3** | ✅ chặn | nâng level |
| **Lost update** | ❌ **800** (đúng: 700) | ✅ lỗi **40001** | ✅ lỗi 40001 | tính trong SQL / `FOR UPDATE` / **optimistic lock** |
| **Write skew** | ❌ **0 bác sĩ trực** | ❌ **0 bác sĩ trực** | ✅ **1 bác sĩ**, S2 abort | materializing conflict / advisory lock / `EXCLUDE` |
| **Phantom write skew** (INSERT) | ❌ | ❌ **tổng 11 / giới hạn 10** | ✅ **10**, S2 abort | như trên |

### Giải thích cho mỗi ô "không chặn được"

- **Non-repeatable read ở RC:** mỗi câu lệnh chụp snapshot mới → thấy dữ liệu đã commit sau đó.
- **Phantom ở RC:** cùng lý do — snapshot mới thấy cả dòng mới chèn.
- **Lost update ở RC:** hai `UPDATE` với giá trị tuyệt đối, cái sau ghi đè cái trước; database không biết chúng dựa trên cùng một lần đọc.
- **Write skew ở RR:** snapshot isolation chỉ kiểm tra xung đột **ghi-ghi** trên cùng dòng. Hai transaction ghi **hai dòng khác nhau** → không có xung đột để phát hiện.
- **Phantom write skew ở RR:** tệ hơn — dòng còn **chưa tồn tại** lúc đọc, nên không có gì để so sánh.

---

## §6. Ánh xạ về kiến trúc DDD + CQRS + Temporal + outbox

| Vấn đề | Công cụ đang dùng | Có đủ không |
|---|---|---|
| Hai lệnh cùng sửa **một** aggregate | optimistic lock (version) | ✅ **đủ** |
| Ràng buộc **trong** một aggregate | invariant kiểm trong aggregate + version | ✅ **đủ** |
| **Ràng buộc qua NHIỀU aggregate** | ??? | ❌ **đây là write skew** |
| Ràng buộc qua nhiều service | saga / Temporal | ⚠️ eventual — **có cửa sổ vi phạm** |

### Ô thứ ba — bốn lựa chọn, mỗi cái một cái giá

DDD dạy *"một transaction chỉ sửa một aggregate"*. Nhưng khi ràng buộc bao trùm nhiều aggregate, phải chọn:

| Lựa chọn | Cái giá |
|---|---|
| **Gộp thành một aggregate lớn hơn** | mất tính đồng thời — mọi thao tác trên bất kỳ phần nào đều tranh chấp nhau |
| **Serializable + retry** | throughput thấp hơn, phải xử lý 40001 ở mọi nơi |
| **Materializing conflict / advisory lock** | phải nhớ khoá ở **mọi** code path — dễ sai khi codebase lớn |
| **Eventual consistency + bù trừ (saga/Temporal)** | **chấp nhận có cửa sổ vi phạm** — phải phát hiện và bù trừ |

**Không có lựa chọn nào miễn phí.** Điều quan trọng là **chọn có ý thức**, không phải mặc định vào lựa chọn thứ tư vì "DDD bảo thế".

### Ví dụ trong hệ IoT — ràng buộc liên-aggregate thật

```
Ràng buộc: "mỗi tenant tối đa N device active theo gói cước"

Aggregate: Device (mỗi device một aggregate)
Ràng buộc bao trùm: TẤT CẢ device của một tenant

-> Hai request cùng lúc kích hoạt device thứ N và N+1:
   cả hai đọc count = N-1, cả hai thấy "còn chỗ", cả hai ghi vào
   HAI DÒNG KHÁC NHAU  ->  WRITE SKEW  ->  vượt hạn mức
```

**Cách xử lý được khuyến nghị cho ca này: materializing conflict trên `tenant`**, vì:
- Ràng buộc rõ ràng, dễ liệt kê
- Tranh chấp trong phạm vi một tenant (không phải toàn hệ) → throughput vẫn tốt
- Chỉ một code path (kích hoạt device) cần nhớ khoá

```sql
BEGIN;
SELECT 1 FROM tenant WHERE id = $1 FOR UPDATE;      -- khoá tenant
SELECT count(*) FROM device WHERE tenant_id=$1 AND is_active;
-- kiểm tra hạn mức
UPDATE device SET is_active = true WHERE id = $2;
COMMIT;
```

Các ràng buộc liên-aggregate khác dễ gặp: *"tổng dung lượng lưu trữ của tenant"*, *"số alarm CRITICAL đang mở"*, *"một device chỉ thuộc một gateway"*.

---

## Bảng số liệu chính

| Kịch bản | Kết quả |
|---|---|
| **Lost update** (RC, ghi giá trị tuyệt đối) | **800** — đúng ra phải **700** |
| Cách 1: `balance = balance - 100` | **700** ✅ |
| Cách 2: `SELECT ... FOR UPDATE` | **700** ✅ (S2 đọc lại thấy 900, không phải 1000) |
| **Write skew, Repeatable Read** | **0 bác sĩ trực** ⚠️ cả hai commit thành công |
| **Write skew, Serializable** | **1 bác sĩ**, S2 nhận `40001 — Canceled on identification as a pivot` |
| **Phantom write skew, RR** | tổng **11** / giới hạn **10** ⚠️ |
| **Phantom write skew, Serializable** | tổng **10** ✅, S2 abort |
| **Materializing conflict** | tổng **10** ✅, S2 chờ ở `wait_event = transactionid` |
| **Advisory lock** | tổng **10** ✅, S2 chờ ở `wait_event = advisory` |

---

## B. Vì sao Repeatable Read chặn phantom read nhưng không chặn write skew — 3 câu

> **Repeatable Read của Postgres dùng snapshot isolation: mọi thứ có `xmin` mới hơn snapshot đều vô hình, nên dòng do transaction khác chèn vào không bao giờ hiện ra — phantom read bị chặn miễn phí, như một hệ quả phụ của kiến trúc.**
>
> **Nhưng snapshot chỉ kiểm soát cái transaction ĐỌC, không kiểm soát mối quan hệ giữa cái nó đọc và cái transaction khác GHI: khi hai transaction đọc cùng một tập rồi mỗi cái ghi vào một dòng khác nhau trong tập đó, không có xung đột ghi-ghi nào để snapshot isolation phát hiện.**
>
> **Serializable (SSI) bổ sung đúng phần thiếu đó — nó theo dõi read-write dependency bằng predicate lock, phát hiện chu trình phụ thuộc và huỷ transaction "pivot", nên chặn được write skew với cái giá là phải retry.**

---

## Ba điều dễ hiểu sai

| # | Hiểu nhầm | Sự thật đo được |
|---|---|---|
| 1 | "Repeatable Read đủ an toàn cho logic nghiệp vụ" | Write skew vẫn xảy ra: **0 bác sĩ trực**, cả hai commit thành công, **không có lỗi nào** |
| 2 | "Optimistic lock (version) chặn được mọi race condition" | Nó chỉ bảo vệ **một** aggregate. Hai aggregate khác nhau → không có version nào xung đột |
| 3 | "`SELECT ... FOR UPDATE` ở Read Committed vẫn đọc snapshot cũ" | Nó **đọc lại phiên bản mới nhất** sau khi được cấp khoá — đo được S2 thấy **900**, không phải 1000 |

Thêm hai điều:
- **Write skew với `INSERT` khó hơn với `UPDATE`** — không có dòng nào tồn tại để khoá, nên phải khoá một **đại diện của tập**.
- **Advisory lock là cách dễ sai sót nhất về lâu dài** — không có gì trong schema buộc code phải gọi nó.

---

## Áp dụng vào hệ thật

**1. Liệt kê mọi ràng buộc nghiệp vụ bao trùm NHIỀU dòng/aggregate.** Đây là danh sách các chỗ có nguy cơ write skew. Mẫu điển hình:
- "tối đa N phần tử" (hạn mức gói cước, số ghế, số slot)
- "luôn còn ít nhất 1" (bác sĩ trực, admin, replica)
- "tổng không vượt X" (dung lượng, ngân sách, tồn kho)
- "không trùng khoảng thời gian" (đặt lịch, ca trực)

**2. Với mỗi ràng buộc, chọn công cụ có ý thức:**
```
Biểu diễn được bằng EXCLUDE/UNIQUE/CHECK?  -> dùng constraint (mạnh nhất)
Tranh chấp trong phạm vi hẹp (1 tenant)?   -> materializing conflict (FOR UPDATE trên tenant)
Ràng buộc phức tạp, khó liệt kê hết?       -> SERIALIZABLE + retry
Chấp nhận eventual + bù trừ?               -> saga, NHƯNG phải có cơ chế phát hiện vi phạm
```

**3. Nếu chọn Serializable, kiểm tra retry loop tồn tại ở MỌI nơi:**
```bash
grep -rn "SERIALIZABLE\|Serializable" --include=*.java --include=*.go . | \
  # mỗi kết quả phải đi kèm retry cho SQLSTATE 40001
```

**4. Viết test tương tranh cho những chỗ đó.** Đây là loại bug **không** xuất hiện trong unit test và **không** xuất hiện khi tải thấp:
```java
// chạy 2 thread đồng thời, kiểm tra invariant sau khi cả hai xong
CountDownLatch latch = new CountDownLatch(1);
// ... hai thread cùng đợi latch rồi cùng chạy
assertThat(countActiveDoctors()).isGreaterThanOrEqualTo(1);
```

**5. Thêm kiểm tra bù trừ định kỳ** cho ràng buộc đang dùng eventual consistency:
```sql
-- job chạy mỗi 5 phút, alert nếu có kết quả
SELECT tenant_id, count(*) AS so_device_active, t.gioi_han
FROM device d JOIN tenant t ON t.id = d.tenant_id
WHERE d.is_active GROUP BY 1, 3 HAVING count(*) > t.gioi_han;
```
Không thay thế được việc chặn từ đầu, nhưng ít nhất phát hiện được.

---

## Câu hỏi mở sang các ngày sau

1. `FOR UPDATE` chặn S2 — còn `FOR UPDATE SKIP LOCKED` và `NOWAIT` thì sao? → **Day 28**
2. Hai transaction cùng dùng `FOR UPDATE` theo thứ tự ngược nhau → deadlock. Detector hoạt động thế nào? → **Day 29**
3. Serializable tốn bao nhiêu throughput so với `FOR UPDATE` và optimistic lock ở 4/16/64 client? → **Day 30**
4. Advisory lock dùng `hashtext` — hash collision gây hậu quả gì? → **Day 28**
5. Predicate lock của SSI tốn bao nhiêu bộ nhớ, và `max_pred_locks_per_transaction` là gì? → **Day 30**
