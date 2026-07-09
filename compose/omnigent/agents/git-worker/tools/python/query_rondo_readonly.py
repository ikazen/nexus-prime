"""reflexion-rondo DB 를 SELECT 전용으로 조회하는 local tool.

omnigent 의 local tool 은 (별도 container_image 를 지정하지 않는 한) os_env
샌드박스 밖, parent 프로세스(omnigent 컨테이너)에서 실행된다. 그래서 이
파일은 `OMNIGENT_RONDO_RO_URL` 을 직접 읽어도 되고, 그 값이 샌드박스 안
에이전트 프로세스로 전달되는 일은 없다 — 에이전트는 이 tool 이 반환하는
결과 행만 본다. os_env.sandbox 의 egress_rules 를 GitHub 용으로 켜면(HTTP(S)
MITM 프록시가 유일한 아웃바운드 경로가 됨) 샌드박스 안에서 Postgres 로 직접
TCP 접속하는 경로는 어차피 없다 — DB 접근을 이 tool 로 분리한 이유.

DB role(`omnigent_ro`) 자체가 read-only 로 발급되어 있어 INSERT/UPDATE/DDL 은
Postgres 가 거부하지만, 방어적으로 SELECT 문 하나만 허용한다(주석·복수
statement 차단) — 권한 자체를 이 코드가 만드는 것은 아니다.

배포 전 확인 필요: omnigent-server 벤더 이미지에 `psycopg` 가 설치돼 있는지.
없으면 커스텀 이미지 레이어로 추가해야 한다 (docs/runbook.md omnigent 배포
체크리스트 참조).
"""

from __future__ import annotations

import os
import re

import psycopg
from omnigent_client.tools import tool
from psycopg.rows import dict_row

_MAX_ROWS = 500
_STATEMENT_TIMEOUT_MS = 10_000
_DSN_ENV = "OMNIGENT_RONDO_RO_URL"

# 선행 공백/한 줄 주석(`--`)만 건너뛰고 SELECT 로 시작하는지 확인.
_SELECT_RE = re.compile(r"\A(?:\s|--[^\n]*\n)*select\b", re.IGNORECASE)


@tool
def query_rondo_readonly(sql: str) -> dict:
    """
    reflexion-rondo Postgres DB 에 SELECT 전용 쿼리를 실행하고 결과 행을 반환한다.

    :param sql: SELECT 문 하나. 세미콜론으로 여러 statement 를 연결할 수 없다.
    :returns: ``{"rows": [...], "truncated": bool}``. 500 행을 넘으면
        ``truncated`` 가 ``True`` 이고 앞 500 행만 반환된다.
    """
    dsn = os.environ.get(_DSN_ENV)
    if not dsn:
        raise ValueError(f"{_DSN_ENV} 가 설정되어 있지 않습니다 — RO DB 접근이 배선되지 않음")

    stripped = sql.strip().rstrip(";")
    if ";" in stripped:
        raise ValueError("세미콜론으로 구분된 다중 statement 는 허용하지 않습니다")
    if not _SELECT_RE.match(sql):
        raise ValueError("SELECT 문만 허용합니다")

    with psycopg.connect(dsn, row_factory=dict_row, autocommit=True) as conn:
        with conn.cursor() as cur:
            cur.execute(f"SET LOCAL statement_timeout = {_STATEMENT_TIMEOUT_MS}")
            cur.execute(stripped)
            rows = cur.fetchmany(_MAX_ROWS + 1)

    truncated = len(rows) > _MAX_ROWS
    return {"rows": rows[:_MAX_ROWS], "truncated": truncated}
