"""pot-of-greed DB 를 SELECT 전용으로 조회하는 local tool.

`query_rondo_readonly.py` 와 동일한 설계 — 상세 설명은 그쪽 파일 docstring
참조. 두 파일이 커넥션 로직을 각자 갖는 이유: `tools/python/` 아래 모든
`.py` 파일이 파일명 그대로 tool 로 등록되므로(discover 단계는 `@tool`
데코레이터 유무를 가리지 않음), 공용 헬퍼 모듈을 같은 디렉토리에 두면 그
모듈도 tool 로 등록 시도되어 동작이 불분명해진다 — 작은 중복을 감수하고
파일을 독립적으로 유지한다.
"""

from __future__ import annotations

import os
import re

import psycopg
from omnigent_client.tools import tool
from psycopg.rows import dict_row

_MAX_ROWS = 500
_STATEMENT_TIMEOUT_MS = 10_000
_DSN_ENV = "OMNIGENT_POG_RO_URL"

_SELECT_RE = re.compile(r"\A(?:\s|--[^\n]*\n)*select\b", re.IGNORECASE)


@tool
def query_pog_readonly(sql: str) -> dict:
    """
    pot-of-greed Postgres DB 에 SELECT 전용 쿼리를 실행하고 결과 행을 반환한다.

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
