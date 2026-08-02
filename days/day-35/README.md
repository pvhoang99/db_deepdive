# Day 35 — Chọn mô hình lưu telemetry + ôn tuần 7

**Thời lượng:** 60–90 phút · **Cách học:** hôm nay là bài **thiết kế có số liệu**, không phải bài đọc lý thuyết.

## Chuẩn bị

```sql
\timing on
\o /days/day-35/output.txt
```

---

## §0. Đề bài

Bạn phải trình bày trước team: **hệ telemetry IoT nên lưu ở đâu.** Ba phương án:

- **A** — Postgres bảng phẳng + BRIN
- **B** — Postgres phân vùng theo tháng + B-tree
- **C** — Cassandra (LSM-tree) — cái bạn đang chạy

Hôm nay bạn **đo** phương án A và B trên lab, rồi phân tích C bằng lý thuyết + kinh nghiệm vận hành thật của bạn.

**Đoán trước:** viết vào writeup dự đoán của bạn cho từng tiêu chí, rồi mới đo.

---

## §1. Dựng hai phương án

### Làm ngay

```sql
-- A: bảng phẳng + BRIN
DROP TABLE IF EXISTS ts_a;
CREATE TABLE ts_a (LIKE ts_kv);
INSERT INTO ts_a SELECT * FROM ts_kv;
CREATE INDEX ON ts_a USING brin(ts) WITH (pages_per_range = 32);
CREATE INDEX ON ts_a (device_id, ts);
VACUUM ANALYZE ts_a;

-- B: phân vùng theo tháng + B-tree
DROP TABLE IF EXISTS ts_b CASCADE;
CREATE TABLE ts_b (LIKE ts_kv) PARTITION BY RANGE (ts);
CREATE TABLE ts_b_05 PARTITION OF ts_b FOR VALUES FROM ('2025-05-01') TO ('2025-06-01');
CREATE TABLE ts_b_06 PARTITION OF ts_b FOR VALUES FROM ('2025-06-01') TO ('2025-07-01');
CREATE TABLE ts_b_07 PARTITION OF ts_b FOR VALUES FROM ('2025-07-01') TO ('2025-08-01');
INSERT INTO ts_b SELECT * FROM ts_kv;
CREATE INDEX ON ts_b (device_id, ts);
CREATE INDEX ON ts_b (ts);
VACUUM ANALYZE ts_b;

SELECT relname, pg_size_pretty(pg_total_relation_size(oid)) AS tong,
       pg_size_pretty(pg_indexes_size(oid))                AS index
FROM pg_class WHERE relname IN ('ts_a','ts_b') OR relname LIKE 'ts_b_%';
```

**Ghi vào writeup:** dung lượng bảng + index của A và B. Chênh bao nhiêu %?

---

## §2. Đo write throughput

### Làm ngay

```sql
\timing on
INSERT INTO ts_a SELECT device_id, key_id, ts + interval '95 days', dbl_v, bool_v, str_v
FROM ts_kv LIMIT 500000;

CREATE TABLE ts_b_08 PARTITION OF ts_b FOR VALUES FROM ('2025-08-01') TO ('2025-09-01');
INSERT INTO ts_b SELECT device_id, key_id, ts + interval '95 days', dbl_v, bool_v, str_v
FROM ts_kv LIMIT 500000;
```

Đo WAL sinh ra:
```sql
SELECT pg_current_wal_lsn();   -- chạy trước và sau mỗi INSERT
```

**Ghi vào writeup:** throughput (dòng/giây) của A và B. Chênh bao nhiêu %? Vì sao?

---

## §3. Đo read — bốn mẫu query của IoT

### Làm ngay

Bốn mẫu query thật sự xuất hiện trong dashboard IoT:

```sql
-- Q1: giá trị mới nhất của một device (mẫu phổ biến nhất)
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM ts_a WHERE device_id=42 ORDER BY ts DESC LIMIT 1;
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM ts_b WHERE device_id=42 ORDER BY ts DESC LIMIT 1;

-- Q2: chuỗi thời gian của một device trong 1 ngày (vẽ biểu đồ)
EXPLAIN (ANALYZE, BUFFERS) SELECT ts, dbl_v FROM ts_a
  WHERE device_id=42 AND key_id=1 AND ts >= '2025-06-01' AND ts < '2025-06-02' ORDER BY ts;
EXPLAIN (ANALYZE, BUFFERS) SELECT ts, dbl_v FROM ts_b
  WHERE device_id=42 AND key_id=1 AND ts >= '2025-06-01' AND ts < '2025-06-02' ORDER BY ts;

-- Q3: tổng hợp toàn hệ trong 1 giờ (dashboard tổng quan)
EXPLAIN (ANALYZE, BUFFERS) SELECT key_id, count(*), avg(dbl_v) FROM ts_a
  WHERE ts >= '2025-06-01' AND ts < '2025-06-01 01:00' GROUP BY 1;
EXPLAIN (ANALYZE, BUFFERS) SELECT key_id, count(*), avg(dbl_v) FROM ts_b
  WHERE ts >= '2025-06-01' AND ts < '2025-06-01 01:00' GROUP BY 1;

-- Q4: downsample 1 tháng theo giờ (báo cáo)
EXPLAIN (ANALYZE, BUFFERS) SELECT date_trunc('hour', ts) h, avg(dbl_v) FROM ts_a
  WHERE key_id=1 AND ts >= '2025-06-01' AND ts < '2025-07-01' GROUP BY 1 ORDER BY 1;
EXPLAIN (ANALYZE, BUFFERS) SELECT date_trunc('hour', ts) h, avg(dbl_v) FROM ts_b
  WHERE key_id=1 AND ts >= '2025-06-01' AND ts < '2025-07-01' GROUP BY 1 ORDER BY 1;
```

**Ghi vào writeup — bảng 8 dòng:** query | phương án | Planning Time | Execution Time | buffers. Chạy mỗi cái 3 lần lấy số ổn định.

---

## §4. Đo chi phí xoá dữ liệu cũ

### Làm ngay

```sql
-- A: DELETE
SELECT pg_size_pretty(pg_total_relation_size('ts_a')) AS truoc;
\timing on
DELETE FROM ts_a WHERE ts < '2025-06-01';
VACUUM ts_a;
SELECT pg_size_pretty(pg_total_relation_size('ts_a')) AS sau,
       n_dead_tup FROM pg_stat_user_tables WHERE relname='ts_a';

-- B: DROP PARTITION
SELECT pg_size_pretty(pg_total_relation_size('ts_b')) AS truoc;
\timing on
DROP TABLE ts_b_05;
SELECT pg_size_pretty(pg_total_relation_size('ts_b')) AS sau;
```

**Ghi vào writeup:** thời gian, dead tuple sinh ra, dung lượng thu hồi. **Chênh lệch bao nhiêu lần?**

---

## §5. Cassandra — phân tích lý thuyết + kinh nghiệm thật

### Lý thuyết

Bạn đang chạy ThingsBoard + Cassandra nên có dữ liệu thật để đối chiếu.

**Mô hình dữ liệu Cassandra cho telemetry (kiểu ThingsBoard):**
```
PRIMARY KEY ((entity_id, key, partition), ts)
```
- Partition key quyết định node nào giữ dữ liệu
- Clustering key (`ts`) sắp xếp trong partition

**LSM-tree** (đối lập B-tree — nhắc lại cuộc trò chuyện trước):
```
Write → commit log + memtable (RAM, sorted)
     → memtable đầy → flush thành SSTable (immutable, trên đĩa)
     → compaction gộp SSTable, bỏ bản cũ + tombstone
```

| Tiêu chí | Cassandra (LSM) | Postgres (B-tree/heap) |
|---|---|---|
| Write throughput | **rất cao**, sequential write | thấp hơn, random write vào index |
| Read một partition | nhanh (nhưng phải hợp nhất nhiều SSTable) | nhanh |
| Query linh hoạt (ad-hoc, join, aggregate) | **rất kém** — chỉ query theo partition key | **mạnh** |
| Xoá dữ liệu cũ | TTL tự động, nhưng sinh **tombstone** | DROP PARTITION |
| Scale ngang | **native**, thêm node là xong | cần sharding thủ công / Citus |
| Vận hành | phức tạp: compaction strategy, repair, gc_grace | đơn giản hơn |
| Transaction, ràng buộc | rất hạn chế (LWT đắt) | đầy đủ |

**Cạm bẫy vận hành của Cassandra bạn cần biết** (những thứ sẽ gặp):
- **Tombstone**: DELETE tạo tombstone, chỉ dọn sau `gc_grace_seconds` (mặc định 10 ngày). Query quét qua nhiều tombstone sẽ timeout. Đây là sự cố phổ biến nhất.
- **Compaction backlog**: ghi nhanh hơn khả năng compaction → SSTable chồng chất → đọc chậm dần, đĩa phình gấp mấy lần dữ liệu thật.
- **Compaction strategy sai**: `SizeTiered` (mặc định) tệ cho time-series; phải dùng `TimeWindowCompactionStrategy`.
- **Wide partition**: partition quá lớn (>100MB) gây GC pressure và đọc chậm. Phải chia partition theo thời gian (chính là cột `partition` trong PK của ThingsBoard).

### Làm ngay

Không có SQL. **Ghi vào writeup:** với hệ thật của bạn, điền các số bạn **biết** (hoặc đo được từ ThingsBoard):
- Bao nhiêu device, bao nhiêu điểm dữ liệu/giây
- Dung lượng Cassandra hiện tại, giữ bao lâu
- Compaction strategy đang dùng
- Đã từng gặp sự cố nào trong 4 cạm bẫy trên chưa

---

## §6. Bảng so sánh tổng hợp

### Làm ngay

**Ghi vào writeup — điền bảng này bằng số thật bạn vừa đo (A, B) và ước lượng có căn cứ (C):**

| Tiêu chí | A: PG phẳng + BRIN | B: PG partition | C: Cassandra |
|---|---|---|---|
| Write throughput (dòng/giây) | | | |
| Dung lượng cho 5M dòng | | | |
| Q1 latency (giá trị mới nhất) | | | |
| Q2 latency (1 device, 1 ngày) | | | |
| Q3 latency (tổng hợp 1 giờ) | | | |
| Q4 latency (downsample 1 tháng) | | | |
| Xoá 1 tháng dữ liệu cũ | | | |
| Query ad-hoc / join / aggregate | | | |
| Scale ngang | | | |
| Độ phức tạp vận hành (1-5) | | | |
| Cần thêm hạ tầng gì | | | |

---

## §7. Khuyến nghị

### Làm ngay

**Ghi vào writeup — viết như một tài liệu bạn thật sự gửi cho tech lead:**

**A. Khuyến nghị của tôi:** phương án nào, cho quy mô nào.

**B. Điều kiện lật ngược:** "nếu X vượt Y thì chuyển sang Z". Phải cụ thể, có ngưỡng đo được. Ví dụ: *"nếu điểm dữ liệu vượt 50.000/giây hoặc dung lượng vượt 5TB thì Postgres đơn node không đủ, chuyển sang Cassandra hoặc TimescaleDB phân tán"*.

**C. Phương án lai:** có nên dùng cả hai không — Cassandra cho dữ liệu thô, Postgres cho rollup + metadata + query ad-hoc? Đây là kiến trúc rất phổ biến. Nêu ưu nhược điểm.

**D. Nếu chọn Postgres, cần gì thêm:** TimescaleDB có đáng không (nó cho hypertable, continuous aggregate, compression — về bản chất là partition tự động + rollup tự động + nén cột)? Ước lượng nó tiết kiệm bao nhiêu công so với tự làm những gì bạn học ở Day 32-33.

---

## §8. Ôn tuần 7

**Viết vào `writeup.md`:**

**A. Cây quyết định chọn index cho time-series** — vẽ bằng chữ: khi nào B-tree, khi nào BRIN, khi nào partition, khi nào GIN.

**B. Ba điều tôi tưởng đúng mà hoá ra sai trong tuần 7.**

### Dọn dẹp

```sql
DROP TABLE ts_a;
DROP TABLE ts_b CASCADE;
```

---

## Kết ngày

### Đạt khi

Bạn có bảng so sánh **đầy số thật**, khuyến nghị rõ ràng kèm điều kiện lật ngược đo được, và tài liệu này đủ chất lượng để đưa ra thảo luận với team.

**Xong thì gõ `/review-bai`.**

---

## Hết tuần 7

Tuần 8 là phần cuối: **vận hành** — connection pooling, WAL/checkpoint, replication lag — rồi capstone áp dụng mọi thứ lên hệ thật của bạn.
