# 기존 OCI 리소스 import

이미 OCI Console 로 셋업된 환경을 tofu state 로 흡수하는 절차. 신규 셋업은 `docs/setup.md` 참조.

## 흐름

1. `terraform.tfvars` 작성 (`terraform.tfvars.example` 복사 + secrets 채움)
2. `tofu init`
3. OCI Console 에서 OCID 수집 (아래 표)
4. `tofu import` ~17 회 실행
5. `tofu plan` 결과 검증 — **의도된 drift 만** 표시되어야 함
6. 적용 시점 (실제 VM 내리고 새로 배포할 때) 에 `tofu apply`

## OCID 수집 (Console → OCI 메뉴)

| 리소스 | Console 위치 | OCID 변수 |
|---|---|---|
| VCN | Networking → VCN | `<vcn-ocid>` |
| Internet Gateway | VCN 안 → Internet Gateways | `<ig-ocid>` |
| NAT Gateway | VCN 안 → NAT Gateways | `<nat-ocid>` |
| Service Gateway | VCN 안 → Service Gateways | `<sg-ocid>` |
| Route Table public | VCN 안 → Route Tables | `<public-rt-ocid>` |
| Route Table private | VCN 안 → Route Tables | `<private-rt-ocid>` |
| Subnet public | VCN 안 → Subnets | `<public-subnet-ocid>` |
| Subnet private | VCN 안 → Subnets | `<private-subnet-ocid>` |
| NSG ops | VCN 안 → Network Security Groups | `<ops-nsg-ocid>` |
| NSG worker | VCN 안 → Network Security Groups | `<worker-nsg-ocid>` |
| NSG rule (ops 443 tcp) | ops-nsg 안 → Security Rules | `<rule-id-1>` |
| NSG rule (ops 80 tcp) | ops-nsg 안 → Security Rules | `<rule-id-2>` |
| NSG rule (ops 22 tcp) | ops-nsg 안 → Security Rules | `<rule-id-3>` |
| Instance ops-vm | Compute → Instances | `<ops-vm-ocid>` |
| Instance worker-vm | Compute → Instances | `<worker-vm-ocid>` |
| Reserved Public IP | Networking → Reserved Public IPs | `<reserved-ip-ocid>` |

## import 명령 모음

OCID 채워서 한 줄씩:

```bash
cd nexus-prime/tofu
tofu init

# VCN
tofu import oci_core_vcn.main <vcn-ocid>

# Gateways
tofu import oci_core_internet_gateway.ig <ig-ocid>
tofu import oci_core_nat_gateway.nat <nat-ocid>
tofu import oci_core_service_gateway.sg <sg-ocid>

# Route Tables
tofu import oci_core_route_table.public_rt <public-rt-ocid>
tofu import oci_core_route_table.private_rt <private-rt-ocid>

# Subnets
tofu import oci_core_subnet.public <public-subnet-ocid>
tofu import oci_core_subnet.private <private-subnet-ocid>

# NSGs
tofu import oci_core_network_security_group.ops <ops-nsg-ocid>
tofu import oci_core_network_security_group.worker <worker-nsg-ocid>

# NSG rules — id 형식: networkSecurityGroups/<nsg-ocid>/securityRules/<rule-id>
tofu import oci_core_network_security_group_security_rule.ops_https_tcp "networkSecurityGroups/<ops-nsg-ocid>/securityRules/<rule-id-1>"
tofu import oci_core_network_security_group_security_rule.ops_http      "networkSecurityGroups/<ops-nsg-ocid>/securityRules/<rule-id-2>"
tofu import oci_core_network_security_group_security_rule.ops_ssh       "networkSecurityGroups/<ops-nsg-ocid>/securityRules/<rule-id-3>"

# Instances
tofu import oci_core_instance.ops_vm    <ops-vm-ocid>
tofu import oci_core_instance.worker_vm <worker-vm-ocid>

# Reserved Public IP
tofu import oci_core_public_ip.ops_reserved <reserved-ip-ocid>
```

data source (`data "..."`) 는 import 불필요 — apply 시 자동 fetch.

## plan 검증

```
tofu plan
```

**의도된 drift** (코드 vs 실제 환경):
- `oci_core_instance.ops_vm` ForceNew — boot_volume_size (125→150) + metadata 후행 `\n` 차이
- `oci_core_instance.worker_vm` ForceNew — boot_volume_size (75→50) + metadata 후행 `\n` 차이
- `oci_core_public_ip.ops_reserved` in-place update — 인스턴스 재생성 후 새 VNIC 에 re-attach

`tofu plan` 출력: `2 to add, 1 to change, 2 to destroy` — 정상.

그 외 (VCN / NSG / RT / Subnet 등) **차이 0** 이어야 함. 차이 있으면 코드와 실제 환경 불일치 — 코드 수정 또는 실제 환경 확인.

코드 수정 이력 (import 준비 중 발견):
- IG display_name `main-ig` → `main-igw` (OCI 실제 이름)
- SG display_name `main-sg` → `main-sgw`
- public RT display_name `public-rt` → `Default Route Table for main-vcn`
- Reserved IP display_name `ops-vm-reserved-ip` → `ops-vm-ip`
- `ops_https_udp` (NSG UDP 443) 룰 제거 — 실제 환경에 없음

## 적용 (첫 reinstall, L18)

실제 VM 내리고 새로 배포하기로 결정한 시점에:

1. `airflow-stack` 측 docker compose 정지 (`docker compose down` on ops-vm·worker-vm·mac-server)
2. **첫 적용 = reinstall** — `./reinstall-instances.sh`
   - 코드 default (150/50) ≠ 현 환경 (125/75) 차이가 첫 plan 에 표시. L18 정책상 in-place 안 함 → destroy + create 흐름.
   - 인스턴스만 destroy (VCN/NSG/Reserved IP 유지) → 새로 생성 (capacity retry 자동).
   - 환경변수: `SLEEP_SECONDS=30 MAX_ATTEMPTS=500 ./reinstall-instances.sh`
3. 3 노드 ssh + `sudo tailscale up --ssh` (Tailscale 재가입)
4. `bash hosts/<host>/host-setup.sh` (mac 은 `hosts/mac-server/README.md` 절차)
5. ops-vm 인프라 컨테이너 가동 — `docker compose -f compose/_hosts/ops-vm.yml --env-file compose/_hosts/ops-vm.env up -d`
6. `airflow-stack` 재기동

이후 변경 (boot size·shape·image 등) 도 같은 절차 — `docs/runbook.md` 의 "인스턴스 재설치".

### AD fallback

특정 AD 에서 capacity 안 풀리면 다른 AD 시도:
1. `main.tf` 의 `local.availability_domain = ...availability_domains[0].name` 에서 인덱스 변경 (`[1]` 또는 `[2]`)
2. `tofu plan` 으로 변경 확인 (인스턴스 ForceNew 표시 — AD 변경 = 재생성)
3. `./reinstall-instances.sh` 재실행

## state 백업

`*.tfstate` gitignored. apply 후 password manager 또는 OCI Object Storage Always Free 에 백업 (runbook).
