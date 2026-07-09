# Runbook

일상 운영 절차. 비정상 진단·해결은 별도 troubleshooting (없음 — 발생 시 추가).

## 인스턴스 재설치 (정공법, L18)

변경 (boot size·shape·image 등) 또는 장애 복구 모두 같은 절차. in-place 변경 안 함.

1. (변경 시) `tofu/variables.tf` 또는 `terraform.tfvars` 에서 값 수정
2. `airflow-stack` 측 `docker compose down` (3 노드 — ops/worker/mac)
3. `cd tofu && ./reinstall-instances.sh`
   - 인스턴스 destroy (VCN/NSG/Reserved IP 유지) → retry-apply (capacity 매번 풀릴 때까지)
4. ssh + `sudo tailscale up --ssh` 재가입 (3 노드)
5. `bash hosts/<host>/host-setup.sh` (mac 은 README 절차)
6. ops-vm `compose/_hosts/ops-vm.yml` 재기동
7. `airflow-stack` 재기동

데이터 손실:
- postgres `airflow` database — airflow-init 의 `db migrate` + `variables import` 가 부활
- registry storage — task image 가 캐시. 첫 task 시 push 다시
- 두 가지 다 L7 (백업 안 함) 와 L18 정합

ops-vm reserved IP 는 유지 (별도 리소스). 인스턴스 재생성 시 새 vnic 에 자동 attach.

## Secrets 관리 (SOPS + age)

암호화본 `*.enc.env` 는 git에 커밋. 평문 `*.env` 는 로컬·ops-vm 에만. age 개인키는 Bitwarden 보관.

**복호화 (수동):**
```bash
ssh ops-vm
cd ~/nexus-prime
sops --input-type dotenv --output-type dotenv -d compose/_hosts/ops-vm.enc.env > compose/_hosts/ops-vm.env
```

배포 시(`deploy-ops-vm.sh`)는 자동으로 위 복호화 단계가 실행됨.

**env 값 변경 후 재암호화:**
```bash
# ops-vm에서
cd ~/nexus-prime
# ops-vm.env 수정 후:
sops --input-type dotenv --output-type dotenv -e compose/_hosts/ops-vm.env > compose/_hosts/ops-vm.enc.env
# 로컬에서 scp로 가져와 커밋
scp ops-vm:~/nexus-prime/compose/_hosts/ops-vm.enc.env compose/_hosts/ops-vm.enc.env
git add compose/_hosts/ops-vm.enc.env && git commit -m "chore: update ops-vm secrets"
```

**새 머신 복구 시 (age 개인키 없는 상태):**
1. Bitwarden에서 age 개인키 복원
2. `mkdir -p ~/.config/sops/age && echo "<private_key>" > ~/.config/sops/age/keys.txt`
3. `chmod 600 ~/.config/sops/age/keys.txt`
4. 이후 복호화 정상 동작

## 신규 서비스 추가 / Registry / MinIO / Postgres DB 발급

개발자용 절차 → `docs/dev-guide.md` 참조.

## MinIO 버킷 anonymous 오픈

버킷을 자격증명 없이 접근 가능하게 설정한다 (tailnet 내부 전용).

```bash
ssh mac-server
~/mc anonymous set public local/<bucket>   # read+write 공개
~/mc anonymous get local/<bucket>           # 확인 → public
```

읽기만 허용하려면 `public` 대신 `download`.

취소:
```bash
~/mc anonymous set none local/<bucket>
```

`mc` alias `local`은 `localhost:9000` (minioadmin)으로 등록되어 있다. 초기화된 경우:
```bash
~/mc alias set local http://localhost:9000 minioadmin <password>
```

## 내부 DNS (dnsmasq)

`*.internal` → ops-vm tailnet IP 로 해석. tailnet 내 어디서든 `registry.internal`, `rover.internal` 등으로 접근 가능.

**Tailscale 어드민 콘솔 설정 (최초 1회):**
1. [Tailscale Admin → DNS](https://login.tailscale.com/admin/dns)
2. Nameservers → Add nameserver → Custom
3. Nameserver: `<OPS_TAILNET_IP>`, Restrict to domain: `internal`

**dnsmasq 이미지 재빌드 (registry 소실 시):**
```bash
ssh ops-vm
cd ~/nexus-prime
docker compose -f compose/_hosts/ops-vm.yml --env-file compose/_hosts/ops-vm.env build dnsmasq
docker compose -f compose/_hosts/ops-vm.yml --env-file compose/_hosts/ops-vm.env up -d dnsmasq
```

## Registry GC

자동 — `registry-gc.timer` (매일 04:00) 가 `registry-gc.sh` 실행: repo 별 최신 5 태그만 남기고 (`retention.py`) → `garbage-collect -m` 으로 blob 회수. 설치는 `hosts/ops-vm/README.md`.

상태/수동:
```
systemctl status registry-gc.timer
sudo systemctl start registry-gc.service          # 즉시 1 회
journalctl -u registry-gc.service -n 50           # 로그
```

삭제 전 미리보기 (안전):
```
python3 ~/nexus-prime/compose/registry/retention.py --registry-url http://<ops-tailnet-ip>:5000 --keep 5 --dry-run
```

주의: retention 은 `created` 최신순 N 개를 보존 — **배포에 핀된 sha 태그가 N 밖으로 밀리면 삭제됨.** 빌드 cadence 대비 `keep` (기본 5, `REGISTRY_KEEP` 로 조정) 을 넉넉히. GC 는 push 중 실행 시 race 가능성 있으나 빈도 낮아 허용.

빈 repo 껍데기 제거: 오타 등으로 repo 의 태그를 전부 지우면 (retention 은 최신 N 개를 늘 남기므로 이 경우 아님 — 수동 전체삭제일 때만) catalog 에 빈 항목이 남음. blob 은 GC 가 회수하지만 디렉토리는 수동:
```
docker exec registry wget -qO- http://localhost:5000/v2/_catalog   # 빈 repo 확인
docker exec registry rm -rf /var/lib/registry/docker/registry/v2/repositories/<repo>
```

## Monitoring

**Prometheus 타겟 확인:**
```bash
docker exec prometheus wget -qO- 'http://localhost:9090/api/v1/targets' | \
  python3 -c "import json,sys; [print(t['labels'].get('job'), t['health']) for t in json.load(sys.stdin)['data']['activeTargets']]"
```

**Grafana admin 비밀번호 재설정:**
```bash
docker exec grafana grafana cli admin reset-admin-password '<new-password>'
```

**Grafana 대시보드 재import** (`setup.md` 의 `import_dashboard` 함수 참조).

**worker-vm promtail 재시작:**
```bash
ssh worker-vm sudo systemctl restart promtail
```

## 알려진 benign 이벤트

**ops-vm CPU 스파이크 (매일 06:00~06:15 KST):** `reflexion_rondo_autosubmit` DAG 의 `poll_submissions` 태스크가 이 시간대 실행되며 ~10분간 user-mode CPU 를 포화(2코어 기준 ~98%)시킨다. iowait/swap 없음, 자가 복구, scheduler heartbeat 알람 미발동 — 정상. 인프라 결함 아님, 원인 코드는 `reflexion-rondo`/`airflow-stack` 소관. Grafana 에서 이 그래프 보고 재조사할 필요 없음.

## Adminer 접속

`http://adminer.internal` — Tailscale 연결 필수.

로그인 값 (`compose/_hosts/ops-vm.env` 참조):
- System: PostgreSQL
- Server: postgres
- Username: `POSTGRES_USER`
- Password: `POSTGRES_PASSWORD`
- Database: 비우면 전체 목록, 특정 DB 접속 시 DB명 입력

**ERR_SSL_PROTOCOL_ERROR (Chrome 일반 모드에서만 발생):**

Chrome이 이전 HTTPS 리다이렉트를 캐시한 것. HSTS와 다른 캐시.

해결:
1. F12 → Network 탭 → "Disable cache" 체크 → `http://adminer.internal` 접속
2. 이후 `chrome://settings/clearBrowserData` → "캐시된 이미지 및 파일" 삭제

또는 DevTools Network 탭의 "Disable cache"를 켠 채로 사용해도 됨.

## Caddy LE 인증서 갱신

자동 (Caddy 가 만료 30 일 전 갱신). 검증:

```
docker exec caddy caddy list-certificates
```

수동 강제:

```
docker compose -f compose/_hosts/ops-vm.yml --env-file ... restart caddy
```

## Tailscale 노드 키 갱신 / 재가입

```
sudo tailscale logout
sudo tailscale up --ssh
```

새 노드 추가 시 tailnet admin 콘솔에서 승인.

## DNS 변경

ops-vm public IP 가 바뀌면 (인스턴스 재생성 등) 외부 DNS 의 `airflow.<your-domain>` A 레코드 갱신. reserved IP 라 보통 안 바뀜.

## mac-server 슬립 방지 설정

macOS 업데이트 후 전원 설정이 초기화될 수 있다. 업데이트·재설치 후 반드시 확인.

**현재 설정 확인:**
```bash
pmset -g | grep -E 'sleep|standby|hibernate|disksleep'
# sleep 0, standby 0, hibernatemode 0, disksleep 0 이어야 함
```

**재적용 (초기화된 경우):**
```bash
sudo pmset -a sleep 0 standby 0 hibernatemode 0 disksleep 0
```

**부팅 시 자동 적용 (LaunchDaemon — 최초 1회 설치):**
```bash
sudo cp ~/projects/nexus-prime/hosts/mac-server/launchd/local.pmset-nosleep.plist /Library/LaunchDaemons/
sudo launchctl load /Library/LaunchDaemons/local.pmset-nosleep.plist
```

LaunchDaemon은 root로 부팅 시 실행되므로 OS 업데이트 후에도 자동 재적용된다.

## mac-server 재부팅

재부팅 전 edge-worker를 먼저 내려야 한다. 그냥 재부팅하면 Airflow DB에 `starting` 상태가 잔류해 재시작 루프에 빠짐.

```bash
ssh mac-server
cd ~/projects/airflow-stack   # edge-worker compose 위치
docker compose stop edge-worker
# 이후 재부팅
```

재부팅 후 Colima·MinIO는 LaunchAgent / `restart: unless-stopped` 로 자동 복구. edge-worker도 자동 재시작됨.

**edge-worker가 재시작 루프에 빠진 경우 복구:**
```bash
# ops-vm에서 DB 상태 강제 변경 후 제거
docker exec postgres psql -U airflow -d airflow -c "UPDATE edge_worker SET state='offline' WHERE worker_name='mac-server';"
docker exec ops-vm-api-server-1 airflow edge remove-remote-edge-worker -H mac-server

# mac-server에서 컨테이너 재생성 (PID 파일 초기화)
ssh mac-server "cd ~/projects/airflow-stack && docker compose down edge-worker && docker compose up -d edge-worker"
```

## colima 자원 변경 (mac-server)

```
ssh mac-server
colima stop && colima start --cpu 6 --memory 8
# 설정은 ~/.colima/default/colima.yaml 저장 → LaunchAgent 다음 부팅부터 동일
```

## tofu state 백업

`*.tfstate` 는 gitignored. 변경 후 password manager 또는 OCI Object Storage Always Free 에 백업. 분실 시 import 재실행 가능하지만 시간 소모.

백업 대상: `terraform.tfstate` 와 `terraform.tfstate.backup` 둘 다. `.backup` 은 직전 apply 상태를 보존하므로 롤백 시 유용.

## 인스턴스 / 메타 손실 시 재배포

장애 복구 = "인스턴스 재설치" 와 동일 절차 (L18). 위 섹션 참조.

## omnigent 최초 배포 체크리스트

repo 변경(compose/Caddyfile/env)은 main에 반영 완료. omnigent 는 worker-vm 배치, tailnet 전용 노출(L23) — 아래는 실제 기동까지 남은 외부 단계, 순서대로.

1. **Postgres DB/user 발급** (ops-vm, "Postgres DB 발급" 절차, `docs/dev-guide.md` 참조):
   ```bash
   ssh ops-vm
   docker exec -it postgres psql -U postgres -c "CREATE DATABASE omnigent;"
   docker exec -it postgres psql -U postgres -c "CREATE USER omnigent WITH PASSWORD '<pw>';"
   docker exec -it postgres psql -U postgres -c "GRANT ALL ON DATABASE omnigent TO omnigent;"
   docker exec -it postgres psql -U postgres -d omnigent -c "GRANT ALL ON SCHEMA public TO omnigent;"
   ```
1a. **[git-worker] `omnigent_ro` read-only role 발급** (`docs/dev-guide.md` "Postgres read-only role 발급"
    절차, 대상 DB = reflexion-rondo DB + pot-of-greed DB):
    ```bash
    ssh ops-vm
    docker exec -it postgres psql -U postgres -c "CREATE USER omnigent_ro WITH PASSWORD '<pw>';"
    # rondo, pot-of-greed 각각 반복
    docker exec -it postgres psql -U postgres -c "GRANT CONNECT ON DATABASE <rondo_db> TO omnigent_ro;"
    docker exec -it postgres psql -U postgres -d <rondo_db> -c "GRANT USAGE ON SCHEMA public TO omnigent_ro;"
    docker exec -it postgres psql -U postgres -d <rondo_db> -c "GRANT SELECT ON ALL TABLES IN SCHEMA public TO omnigent_ro;"
    docker exec -it postgres psql -U postgres -d <rondo_db> -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO omnigent_ro;"
    ```
1b. **[git-worker] fine-grained PAT 발급** — `docs/dev-guide.md` "omnigent git-worker 셋업" 참조
    (대상 repo 만 Contents=RW, Pull requests=RW, Metadata=RO, 짧은 만료).
1c. **[host] omnigent-host 이미지 빌드+push** — `docs/dev-guide.md` "omnigent host 이미지 빌드" 참조
    (worker-vm ARM64 네이티브 빌드 권장, `registry.internal:5000/omnigent-host:<tag>`). worker-vm 에
    `insecure-registries` 미등록이면 dev-guide "Private Registry" 절차 선행.
2. **`worker-vm.enc.env` 작성** (`compose/_hosts/worker-vm.env.example` 복사 후 SOPS 암호화):
   `OMNIGENT_PG_PASSWORD`(위 1의 pw), `OPS_TAILNET_IP`, `WORKER_TAILNET_IP`,
   `OMNIGENT_HOST_TAG`(위 1c 태그),
   `OMNIGENT_ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OLLAMA_API_KEY`,
   `OMNIGENT_GH_TOKEN`(위 1b), `OMNIGENT_RONDO_RO_URL`/`OMNIGENT_POG_RO_URL`(위 1a).
   값에 `$`가 있으면 `$$`로 이스케이프.
   tailnet 전용 노출이라 공개 DNS A레코드·NSG 변경 불필요 — dnsmasq 와일드카드가 `agent.internal` 을 자동 해석.
   (accounts 관련 키는 더 이상 없음 — single-user 모드, L25.)
3. **ghcr.io pull 가능 여부 확인**: `ghcr.io/omnigent-ai/omnigent-server`가 private면
   `echo $GHCR_TOKEN | docker login ghcr.io -u <user> --password-stdin` (`read:packages`) 먼저.
4. **배포**: `git push` (이미 완료) → `bash scripts/deploy-worker-vm.sh`
5. **상태 확인**: `docker logs omnigent`로 부팅 로그 확인, `docker logs omnigent-host`로 서버 터널
   등록(runner registered) 로그 확인.
6. **[git-worker] 에이전트 스펙 업로드**: `compose/omnigent/agents/git-worker/` 를 omnigent 서버에
   등록 (서버는 spec 을 업로드 받아 저장하는 방식 — `omnigent/server/README.md` "Accepts agent specs,
   stores them durably". 정확한 업로드 커맨드/API 는 omnigent CLI·admin UI 확인 필요, 미검증. local
   tool 파일(`tools/python/query_*_readonly.py`)이 omnigent-host 러너까지 어떻게 전달되는지도
   미검증 — `docs/decisions.md` L25 배포 전 검증 항목 참조).

**E2E 검증:**
- `docker compose -f compose/_hosts/worker-vm.yml --env-file compose/_hosts/worker-vm.env ps` — `omnigent`,
  `omnigent-host` 둘 다 healthy/running
- tailnet 기기에서 `http://agent.internal` 접속 → single-user 모드라 로그인 화면 없이 바로 진입하는지 확인
- 대화 1건 생성 → `docker restart omnigent` → 재접속 시 대화·설정 유지 (Postgres + `/data` 영속)
- 웹 UI에서 claude-native·codex·opencode 하니스 세션을 각각 실행 → 정상 동작 확인 (opencode 는 커스텀
  이미지 반영 여부 재확인 포인트)
- ollama-cloud provider(`compose/omnigent/host/config.yaml`)로 모델 응답 확인
- worker-vm → ops-vm:5432 tailnet 도달성: `nc -z <OPS_TAILNET_IP> 5432`
- **[git-worker]** git-worker 에이전트에 "repo X clone, 사소한 변경 후 브랜치 push, PR 생성" 지시 →
  GitHub 에 브랜치+PR 생성 확인, 커밋 author = PAT 소유 계정
- **[git-worker]** `OMNIGENT_GH_TOKEN` 을 일부러 비운 상태로 재기동 → push 실패(fail-closed) 확인
- **[git-worker]** 에이전트에게 워크스페이스 밖 경로(`/etc/passwd`, `/data/artifacts` 등) 읽기 시도 지시 → 차단 확인
- **[git-worker]** 에이전트에게 github.com/api.github.com 외 도메인 접근 시도 지시(예: `curl https://example.com`) → 차단 확인
- **[git-worker]** `query_rondo_readonly`/`query_pog_readonly` 로 SELECT 성공, 비-SELECT(INSERT 등) 시도 시 tool 자체 거부 + DB role 도 거부 이중 확인
