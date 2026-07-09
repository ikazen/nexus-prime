# omnigent 러너(host) 이미지 — vendor omnigent-host + opencode.
#
# vendor 이미지(ghcr.io/omnigent-ai/omnigent-host) 에는 claude-code/codex/pi/kiro-cli
# 는 baked-in 이지만 opencode 는 없다(omnigent 소스 omnigent/onboarding/harness_install.py
# 의 host 이미지 npm 설치 목록에 opencode 부재 확인). 이 레이어는 그 한 가지만 더한다.
#
# 빌드는 worker-vm(ARM64 네이티브)에서 할 것 — base 이미지가 linux/arm64 매니페스트를
# 제공하는지, npm 패키지 네이티브 의존성이 arm64 에서 빌드되는지 확인 안 된 상태
# (docs/runbook.md omnigent 배포 체크리스트 참조).
ARG OMNIGENT_HOST_TAG=latest
FROM ghcr.io/omnigent-ai/omnigent-host:${OMNIGENT_HOST_TAG}

RUN npm install -g opencode-ai@~1.17.7
