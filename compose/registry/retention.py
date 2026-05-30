#!/usr/bin/env python3
"""registry:2 태그 retention — repo 별 최신 N 개만 남기고 오래된 매니페스트 삭제.

registry:2 는 retention 정책이 없어 sha 핀 태그가 무한 누적됨. GC 는 참조 안 되는
blob 만 회수하므로, 먼저 오래된 태그의 매니페스트를 지워야 GC 가 공간을 회수함.
삭제 후 `registry garbage-collect -m` 은 registry-gc.sh 가 수행.

stdlib 만 사용 (ops-vm 에 jq 없음). 인증 없음 (registry 는 tailnet 전용).
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request

# 매니페스트 GET 시 제시할 Accept — 이미지 매니페스트와 멀티아치 인덱스 모두.
_MANIFEST_ACCEPT = ", ".join(
    [
        "application/vnd.docker.distribution.manifest.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.index.v1+json",
    ]
)
_INDEX_TYPES = {
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.index.v1+json",
}


def _request(
    method: str, url: str, accept: str | None = None
) -> tuple[int, dict[str, str], bytes]:
    req = urllib.request.Request(url, method=method)
    if accept:
        req.add_header("Accept", accept)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


def _get_json(url: str, accept: str | None = None) -> dict:
    status, _, body = _request("GET", url, accept)
    if status != 200:
        raise RuntimeError(f"GET {url} → {status}")
    return json.loads(body)


def _created_at(base: str, repo: str, tag: str) -> str:
    """태그의 이미지 config 에서 created 타임스탬프 (RFC3339 문자열, 정렬용)."""
    status, headers, body = _request(
        "GET", f"{base}/v2/{repo}/manifests/{tag}", _MANIFEST_ACCEPT
    )
    if status != 200:
        return ""  # 못 읽으면 가장 오래된 것으로 취급 → 우선 삭제 대상
    manifest = json.loads(body)
    # 멀티아치 인덱스면 첫 하위 매니페스트로 한 단계 내려감
    if headers.get("Content-Type") in _INDEX_TYPES:
        children = manifest.get("manifests", [])
        if not children:
            return ""
        child_digest = children[0]["digest"]
        status, _, body = _request(
            "GET", f"{base}/v2/{repo}/manifests/{child_digest}", _MANIFEST_ACCEPT
        )
        if status != 200:
            return ""
        manifest = json.loads(body)
    config_digest = manifest.get("config", {}).get("digest")
    if not config_digest:
        return ""
    config = _get_json(f"{base}/v2/{repo}/blobs/{config_digest}")
    return config.get("created", "")


def _manifest_digest(base: str, repo: str, tag: str) -> str | None:
    """DELETE 에 쓸 매니페스트 digest (Docker-Content-Digest 헤더)."""
    status, headers, _ = _request(
        "GET", f"{base}/v2/{repo}/manifests/{tag}", _MANIFEST_ACCEPT
    )
    if status != 200:
        return None
    return headers.get("Docker-Content-Digest")


def prune_repo(base: str, repo: str, keep: int, dry_run: bool) -> int:
    """repo 의 오래된 태그 매니페스트 삭제. 삭제한 개수 반환."""
    data = _get_json(f"{base}/v2/{repo}/tags/list")
    tags = data.get("tags") or []
    if len(tags) <= keep:
        print(f"  {repo}: {len(tags)} 태그 ≤ keep={keep} — 유지")
        return 0

    # created 내림차순 정렬 → 최신 keep 개 보존, 나머지 삭제
    tags_sorted = sorted(tags, key=lambda t: _created_at(base, repo, t), reverse=True)
    keep_tags, drop_tags = tags_sorted[:keep], tags_sorted[keep:]
    print(f"  {repo}: {len(tags)} 태그 → {len(keep_tags)} 유지, {len(drop_tags)} 삭제")

    # 여러 태그가 같은 digest 를 가리킬 수 있어 digest 단위로 1 회만 DELETE
    deleted: set[str] = set()
    count = 0
    for tag in drop_tags:
        digest = _manifest_digest(base, repo, tag)
        if not digest or digest in deleted:
            continue
        deleted.add(digest)
        if dry_run:
            print(f"    [dry-run] would delete {tag} ({digest[:19]}…)")
            count += 1
            continue
        status, _, _ = _request("DELETE", f"{base}/v2/{repo}/manifests/{digest}")
        if status == 202:
            print(f"    deleted {tag} ({digest[:19]}…)")
            count += 1
        else:
            print(f"    FAILED {tag} → {status}", file=sys.stderr)
    return count


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--registry-url", required=True, help="예: http://10.0.0.1:5000")
    ap.add_argument("--keep", type=int, default=10, help="repo 별 보존 태그 수")
    ap.add_argument("--dry-run", action="store_true", help="삭제 없이 출력만")
    args = ap.parse_args()

    base = args.registry_url.rstrip("/")
    repos = _get_json(f"{base}/v2/_catalog").get("repositories") or []
    print(f"registry {base}: repo {len(repos)} 개, keep={args.keep}, dry_run={args.dry_run}")

    total = 0
    for repo in repos:
        total += prune_repo(base, repo, args.keep, args.dry_run)
    print(f"총 {total} 매니페스트 {'삭제 예정' if args.dry_run else '삭제'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
