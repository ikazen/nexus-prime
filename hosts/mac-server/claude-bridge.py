#!/usr/bin/env python3
"""mac-server 호스트에서 claude CLI 를 실행하는 로컬 HTTP 브리지.

Airflow edge worker 는 컨테이너 안에서 돈다 (mac-server 도 Colima VM 안 컨테이너).
claude 는 macOS 호스트 사용자 세션에 인증돼 있어 컨테이너에서 직접 실행 불가 —
이 브리지가 그 경계를 넘는 유일한 통로. tailnet IP 에만 바인드 + Bearer 토큰 이중 방어.

의존성 없음 (stdlib 만). launchd LaunchAgent 로 상주 (local.claude-bridge.plist).
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer

_BIND = os.environ["CLAUDE_BRIDGE_BIND"]  # "<MAC_TAILNET_IP>:<port>" 형식
_TOKEN = os.environ["CLAUDE_BRIDGE_TOKEN"]
_CLAUDE_BIN = os.environ.get("CLAUDE_BIN") or shutil.which("claude") or "claude"
_TIMEOUT_SEC = 120


class Handler(BaseHTTPRequestHandler):
    def _reject(self, code: int, msg: str) -> None:
        body = json.dumps({"ok": False, "error": msg}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:
        if self.path != "/ping":
            self._reject(404, "not found")
            return

        if self.headers.get("Authorization") != f"Bearer {_TOKEN}":
            self._reject(401, "unauthorized")
            return

        length = int(self.headers.get("Content-Length", 0))
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            self._reject(400, "invalid json")
            return

        msg = payload.get("msg", "")
        try:
            result = subprocess.run(
                [_CLAUDE_BIN, "-p", msg],
                capture_output=True,
                text=True,
                timeout=_TIMEOUT_SEC,
            )
            ok = result.returncode == 0
            body = json.dumps({
                "ok": ok,
                "returncode": result.returncode,
                "stdout": result.stdout,
                "stderr": result.stderr,
            }).encode()
        except subprocess.TimeoutExpired:
            body = json.dumps({"ok": False, "error": f"timeout after {_TIMEOUT_SEC}s"}).encode()
            ok = False

        self.send_response(200 if ok else 502)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args) -> None:
        print(f"[claude-bridge] {self.address_string()} - {fmt % args}")


def main() -> None:
    host, port = _BIND.rsplit(":", 1)
    server = HTTPServer((host, int(port)), Handler)
    print(f"[claude-bridge] listening on {_BIND}, claude_bin={_CLAUDE_BIN}")
    server.serve_forever()


if __name__ == "__main__":
    main()
