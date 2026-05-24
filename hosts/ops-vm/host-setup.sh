#!/usr/bin/env bash
# ops-vm 호스트 부트스트랩 — swap, Docker, unattended-upgrades, nexus network.
# 멱등 (재실행 안전). Ubuntu 22.04 ARM.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# swap 2G — 12GB 인스턴스 OOM 안전판
if ! swapon --show | grep -q .; then
  sudo fallocate -l 2G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
  echo "swap 2G 생성"
else
  echo "swap 이미 있음"
fi

# Docker Engine + Compose plugin — 공식 apt repo
if ! command -v docker >/dev/null 2>&1; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$USER"
  echo "docker 설치 완료 (docker 그룹은 다음 로그인부터)"
else
  echo "docker 이미 있음"
fi

# unattended-upgrades — 보안 업데이트 자동
sudo apt-get install -y -qq unattended-upgrades
printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' \
  | sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null

# nexus docker network — caddy / postgres / registry / airflow 서비스 공유
if ! sudo docker network inspect nexus >/dev/null 2>&1; then
  sudo docker network create nexus
  echo "nexus network 생성"
else
  echo "nexus network 이미 있음"
fi

echo "=== ops-vm host-setup 완료 ==="
echo "block volume mount (registry data) 는 README.md 의 별도 절차 참조"
