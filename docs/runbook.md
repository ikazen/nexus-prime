# Runbook

일상 운영 절차. 비정상 진단·해결은 별도 troubleshooting (없음 — 발생 시 추가).

## 호스트 재생성 (worker-vm 디스크 비율 변경 등)

1. `tofu` 에서 boot_volume_size_in_gbs 수정
2. `tofu taint oci_core_instance.worker_vm` (재생성 강제)
3. `tofu apply` — 인스턴스 재생성, public IP 변경 (없으니 무관), Tailscale 재가입 필요
4. ssh + `tailscale up --ssh` 재가입
5. `bash hosts/worker-vm/host-setup.sh`
6. airflow-stack 측 절차 — edge worker 재기동

## ops-vm 부트 디스크 확장

1. `tofu` 에서 `boot_volume_size_in_gbs` 수정 (online resize, in-place)
2. `tofu apply`
3. ops-vm 안: `sudo growpart /dev/sda 1 && sudo resize2fs /dev/sda1`
4. `df -h /` 확인

registry storage 가 부트 안이라 부트 확장이 곧 registry 확장.

## Postgres 신규 DB / user 추가 (공유 DB, L4)

```
ssh ops-vm
docker exec -it postgres psql -U <superuser> -c "CREATE DATABASE <newdb>;"
docker exec -it postgres psql -U <superuser> -c "CREATE USER <newuser> WITH PASSWORD '<pw>';"
docker exec -it postgres psql -U <superuser> -c "GRANT ALL ON DATABASE <newdb> TO <newuser>;"
```

신규 서비스의 `.env` 에 `postgresql://<newuser>:<pw>@postgres:5432/<newdb>`.

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

## 인스턴스 / 메타 손실 시 재배포

1. `tofu apply` (없는 리소스만 재생성)
2. 각 호스트 setup 재실행
3. airflow-stack 측 재셋업 (별도 절차)

백업 없음 (L7). lol-list 데이터는 Supabase 외부라 영향 없음. airflow 메타 DB 는 disposable (Variable / Connection 미사용).
