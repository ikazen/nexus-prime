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

## Postgres 신규 DB / user 추가 (공유 DB, L4)

서비스별 절차는 해당 서비스 repo 의 runbook 참조 (예: `airflow-stack:docs/runbook.md`).

일반 명령 패턴:
```
docker exec -it postgres psql -U postgres -c "CREATE DATABASE <db>;"
docker exec -it postgres psql -U postgres -c "CREATE USER <user> WITH PASSWORD '<pw>';"
docker exec -it postgres psql -U postgres -c "GRANT ALL ON DATABASE <db> TO <user>;"
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

**서비스 추가 시:**
- Caddyfile에 `http://<name>.internal { reverse_proxy <container>:<port> }` 추가
- dnsmasq는 `*.internal` 전부를 ops-vm으로 해석하므로 DNS 변경 불필요

## Private Registry 사용

주소: `<OPS_TAILNET_IP>:5000` (tailnet 전용 HTTP — 공인 노출 없음).

주소: `registry.internal` (Caddy 경유, tailnet 전용).

신규 호스트에서 처음 쓸 때 insecure registry 등록 필요 (한 번만):

```bash
# Linux (ops-vm, worker-vm)
echo '{"insecure-registries": ["registry.internal"]}' | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker

# mac-server (colima) — colima VM 내부에서 .internal DNS 미지원, IP:5000 직접 사용
# ~/.colima/default/colima.yaml 에 아래 추가 후 colima restart
# docker:
#   insecure-registries:
#     - <OPS_TAILNET_IP>:5000
```

기본 사용:

```bash
docker tag <image> registry.internal/<name>:<tag>
docker push registry.internal/<name>:<tag>
docker pull registry.internal/<name>:<tag>
```


## Registry GC

`registry:2` 는 자동 GC 안 함. 주기 (월 1 회) 수동:

```
docker exec registry registry garbage-collect /etc/docker/registry/config.yml
```

retention 정책 (예: keep last 10 tags) 은 별도 스크립트 — 필요 시 추가.

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
