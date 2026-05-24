# postgres init

`docker-entrypoint-initdb.d` 마운트. **첫 컨테이너 시작 (= 빈 데이터 디렉토리) 시 1 회만** 실행.

기존 데이터 디렉토리가 있는 상태에서는 무시됨. 운영 중 DB/user 추가는 `psql` 직접 — `docs/runbook.md` 참조.

여기 둘 파일:
- `*.sh` — 셸 스크립트 (실행권한 필요)
- `*.sql` — psql 자동 실행
- `*.sql.gz` — gzip 압축 sql

알파벳 순 실행.
