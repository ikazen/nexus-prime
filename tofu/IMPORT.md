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
| NSG rule (ops 443 udp) | ops-nsg 안 → Security Rules | `<rule-id-2>` |
| NSG rule (ops 80 tcp) | ops-nsg 안 → Security Rules | `<rule-id-3>` |
| NSG rule (ops 22 tcp) | ops-nsg 안 → Security Rules | `<rule-id-4>` |
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

# NSG rules — id 형식: <nsg-ocid>/<rule-id>
tofu import oci_core_network_security_group_security_rule.ops_https_tcp <ops-nsg-ocid>/<rule-id-1>
tofu import oci_core_network_security_group_security_rule.ops_https_udp <ops-nsg-ocid>/<rule-id-2>
tofu import oci_core_network_security_group_security_rule.ops_http     <ops-nsg-ocid>/<rule-id-3>
tofu import oci_core_network_security_group_security_rule.ops_ssh      <ops-nsg-ocid>/<rule-id-4>

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
- `oci_core_instance.ops_vm` boot_volume_size_in_gbs: **125 → 150** (확장)
- `oci_core_instance.worker_vm` boot_volume_size_in_gbs: **75 → 50** (축소 = OCI 가 ForceNew → 인스턴스 재생성)

그 외 (VCN / NSG / RT / Subnet / Reserved IP 등) **차이 0** 이어야 함. 차이 있으면 코드와 실제 환경 불일치 — 코드 수정 또는 실제 환경 확인.

## 적용 (`tofu apply`)

실제 VM 내리고 새로 배포하기로 결정한 시점에:

1. `airflow-stack` 측 docker compose 정지 (`docker compose down` on ops-vm·worker-vm·mac-server)
2. `tofu apply` — worker-vm 재생성 + ops-vm 부트 확장
3. `worker-vm` 재셋업 (`hosts/worker-vm/host-setup.sh` + Tailscale 재가입)
4. `airflow-stack` 재기동

## state 백업

`*.tfstate` gitignored. apply 후 password manager 또는 OCI Object Storage Always Free 에 백업 (runbook).
