#!/usr/bin/env bash
# Helper cho lab. Dùng: ./db.sh <lệnh>
set -euo pipefail
CT=pgdd
DB=lab
U=postgres

case "${1:-help}" in
  up)      docker compose up -d && echo "Chờ Postgres sẵn sàng..." && until docker exec $CT pg_isready -U $U -d $DB >/dev/null 2>&1; do sleep 1; done && echo "OK: psql -h localhost -p 5433 -U postgres lab" ;;
  down)    docker compose down ;;
  nuke)    docker compose down -v ;;   # xoá sạch cả data, dựng lại từ đầu
  psql)    shift; docker exec -it $CT psql -U $U -d $DB "$@" ;;
  # ./db.sh run file.sql  -> chạy 1 file sql trong repo
  run)     docker exec -i $CT psql -U $U -d $DB -v ON_ERROR_STOP=1 < "$2" ;;
  # ./db.sh q "select 1"
  q)       docker exec -i $CT psql -U $U -d $DB -v ON_ERROR_STOP=1 -c "$2" ;;
  seed)    docker exec -i $CT psql -U $U -d $DB -v ON_ERROR_STOP=1 -v scale="${2:-1}" < seed/01_schema.sql
           docker exec -i $CT psql -U $U -d $DB -v ON_ERROR_STOP=1 -v scale="${2:-1}" < seed/02_data.sql ;;
  logs)    docker logs -f $CT ;;
  # ./db.sh day 02  -> tạo thư mục bài ngày mới (777 để psql trong container ghi \o được)
  day)     d="days/day-$(printf %02d $((10#$2)))"; mkdir -p "$d"; chmod 777 "$d"
           [ -f "$d/writeup.md" ] || cp days/_template/writeup.md "$d/writeup.md" 2>/dev/null || true
           [ -f "$d/lab.sql" ]    || cp days/_template/lab.sql    "$d/lab.sql"    2>/dev/null || true
           echo "sẵn sàng: $d" ;;
  # mở 2 session song song cho lab isolation/locking
  s1)      docker exec -it $CT psql -U $U -d $DB -P "prompt1=S1 %/%R%# " ;;
  s2)      docker exec -it $CT psql -U $U -d $DB -P "prompt1=S2 %/%R%# " ;;
  *)       echo "up | down | nuke | seed [scale] | psql | run <file.sql> | q <sql> | s1 | s2 | logs" ;;
esac
