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
