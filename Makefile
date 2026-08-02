define HELP
Lab Tier 1 — Postgres Deep Dive

  make up                    khởi động Postgres 17 (cổng 5433)
  make seed [SCALE=1]        nạp dữ liệu IoT (50k device, 5M ts_kv, 200k alarm)
  make psql                  vào psql
  make q SQL="select 1"      chạy một câu lệnh
  make run F=file.sql        chạy một file
  make s1 / make s2          hai session song song (bài locking, tuần 6)
  make logs / make status
  make day N=07              tạo thư mục bài
  make down / make nuke      dừng / xoá sạch cả dữ liệu
endef
export HELP

SHELL := /bin/bash
CT    := pgdd
DB    := lab
PGU   := postgres

SCALE ?= 1
SQL   ?=
F     ?=
N     ?=

.PHONY: help up down nuke seed psql q run s1 s2 logs day status

help:
	@echo "$$HELP"

up:
	@docker compose up -d
	@echo "Chờ Postgres sẵn sàng..."
	@until docker exec $(CT) pg_isready -U $(PGU) -d $(DB) >/dev/null 2>&1; do sleep 1; done
	@echo "OK  ->  postgresql://postgres:postgres@localhost:5433/lab"

down:
	@docker compose down

nuke:
	@docker compose down -v
	@echo "đã xoá cả volume dữ liệu"

seed:
	@docker exec -i $(CT) psql -U $(PGU) -d $(DB) -v ON_ERROR_STOP=1 -v scale=$(SCALE) < seed/01_schema.sql
	@docker exec -i $(CT) psql -U $(PGU) -d $(DB) -v ON_ERROR_STOP=1 -v scale=$(SCALE) < seed/02_data.sql

psql:
	@docker exec -it $(CT) psql -U $(PGU) -d $(DB)

q:
	@test -n "$(SQL)" || { echo 'cần SQL="..."'; exit 1; }
	@docker exec -i $(CT) psql -U $(PGU) -d $(DB) -v ON_ERROR_STOP=1 -c "$(SQL)"

run:
	@test -n "$(F)" || { echo "cần F=<file.sql>"; exit 1; }
	@docker exec -i $(CT) psql -U $(PGU) -d $(DB) -v ON_ERROR_STOP=1 < $(F)

s1:
	@docker exec -it $(CT) psql -U $(PGU) -d $(DB) -P "prompt1=S1 %/%R%# "

s2:
	@docker exec -it $(CT) psql -U $(PGU) -d $(DB) -P "prompt1=S2 %/%R%# "

logs:
	@docker logs -f $(CT)

status:
	@docker ps --filter name=$(CT) --format '{{.Names}}  {{.Status}}'

day:
	@test -n "$(N)" || { echo "cần N=<số ngày>"; exit 1; }
	@d=days/day-$$(printf %02d $$((10#$(N)))); mkdir -p $$d; chmod 777 $$d; \
	[ -f $$d/writeup.md ] || cp days/_template/writeup.md $$d/writeup.md; \
	[ -f $$d/lab.sql ]    || cp days/_template/lab.sql    $$d/lab.sql; \
	echo "sẵn sàng: $$d"
