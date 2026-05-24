# ops-vm

control plane. 인프라 컨테이너 = caddy + postgres + registry. airflow workload = airflow-stack 의 api-server / scheduler / dag-processor / edge-worker-ops 가 같은 호스트에서 nexus network 공유.

## 셋업

```
ssh ops-vm
git clone <nexus-prime-url>
cd nexus-prime
bash hosts/ops-vm/host-setup.sh
# 로그아웃 후 재로그인 (docker 그룹 적용)

# 인프라 컨테이너
cp compose/_hosts/ops-vm.env.example compose/_hosts/ops-vm.env
$EDITOR compose/_hosts/ops-vm.env
docker compose -f compose/_hosts/ops-vm.yml --env-file compose/_hosts/ops-vm.env up -d
```

## block volume mount (registry data)

OCI Block Volume attach 후 호스트에서:

```
# device 확인 (attach 후 추가된 디스크)
lsblk

# 파일시스템 (한 번만 — 빈 볼륨일 때)
sudo mkfs.ext4 /dev/<device>

# mount point + fstab (UUID 사용, nofail 로 부팅 안전)
sudo mkdir -p /srv/registry
echo "UUID=$(sudo blkid -s UUID -o value /dev/<device>) /srv/registry ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
sudo mount -a
```

## SSH

`ssh/config.example` 참조 — tailnet IP 또는 MagicDNS alias.

## 디스크 (현재)

- 부트: tofu 정의 참조 (`tofu/instances.tf`)
- registry: 별도 block volume → `/srv/registry`
