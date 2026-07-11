# omnigent 러너(host) 이미지 — vendor omnigent-host(claude-code/codex/pi/kiro-cli 는
# baked-in)에 opencode 만 추가 (L25). worker-vm 은 ARM64 라 네이티브 빌드할 것
# (docs/dev-guide.md "omnigent host 이미지 빌드").
ARG OMNIGENT_HOST_TAG=latest
FROM ghcr.io/omnigent-ai/omnigent-host:${OMNIGENT_HOST_TAG}

RUN npm install -g opencode-ai@~1.17.7
