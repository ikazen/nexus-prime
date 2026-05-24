# Setup

신규 셋업 흐름. 기존 환경은 `tofu import` 만 추가 (`runbook.md` 참조).

## 0. 사전 조건

- OCI 테넌시 + API key (또는 OCI CLI 셋업 완료)
- 사용자 도메인 + 외부 DNS 액세스
- Tailscale 계정
- 로컬: `tofu`, `docker`, `gh` (선택)

```bash
# OpenTofu 설치 (Linux/WSL)
curl -fsSL https://get.opentofu.org/install-opentofu.sh | sudo bash -s -- --install-method deb
```

## 1. tofu apply (OCI 리소스)

```
cd nexus-prime/tofu
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars   # tenancy / compartment / region / SSH 공개키

tofu init
tofu plan
tofu apply
tofu output    # IP / OCID 메모
```

산출물: VCN / 서브넷 2 / NSG 2 / Gateway 3 / 인스턴스 2 (ops-vm·worker-vm) / Reserved IP.

**기존 OCI 환경을 흡수 (import) 하려면** → `tofu/IMPORT.md` 참조.

## 2. DNS

외부 DNS provider 에서 `airflow.<your-domain>` A → `tofu output ops_vm_public_ip`. TTL 60 권장 (초기 셋업 중 변경 잦음).

## 3. Tailscale 가입

각 OCI 노드 + mac:

```
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh
```

mac: `brew install tailscale && open -a Tailscale` 후 로그인.

MagicDNS ON, ACL 단일 사용자 기본값.

## 4. 호스트 부트스트랩

각 노드 ssh 후:

```
git clone <nexus-prime-url>
cd nexus-prime
bash hosts/<host>/host-setup.sh
# 재로그인 (docker 그룹 적용)
```

ops-vm 추가:
- nexus network 는 `host-setup.sh` 가 이미 생성

mac-server 는 macOS 라 host-setup.sh 가 아니라 `hosts/mac-server/README.md` 절차 (brew / colima / LaunchAgent).

## 5. ops-vm 인프라 컨테이너

```
ssh ops-vm
cd nexus-prime
cp compose/_hosts/ops-vm.env.example compose/_hosts/ops-vm.env
$EDITOR compose/_hosts/ops-vm.env   # POSTGRES_*, OPS_TAILNET_IP, AIRFLOW_DOMAIN

docker compose -f compose/_hosts/ops-vm.yml --env-file compose/_hosts/ops-vm.env up -d
```

검증:
- `docker ps` — caddy / postgres / registry 정상
- `https://airflow.<your-domain>` 접속 (Caddy ACME 발급 직후 200 또는 502 — 502 는 airflow api-server 미가동, 정상)
- `docker exec registry ls /var/lib/registry/docker` — registry 정상

## 6. airflow workload

별도 repo. `airflow-stack:docs/setup.md` 참조.

## 7. secrets

`.env` 는 어디서도 git commit 금지. 실제 값은 password manager / secrets vault.

- Postgres password / user — `compose/_hosts/ops-vm.env`
- Airflow Fernet / JWT — airflow-stack 의 `.env`
- Tailscale auth key (재가입 시) — password manager
