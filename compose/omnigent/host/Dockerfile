# omnigent 러너(host) 이미지 — vendor omnigent-host(claude-code/codex/pi/kiro-cli 는
# baked-in)에 opencode 를 추가 (L25). vendor 이미지엔 gh CLI 도 없어서 함께 얹음 —
# 인터랙티브 세션·git-worker 둘 다 git 인증은 credential.helper/credential_proxy 로
# 되지만 gh 바이너리 자체가 없으면 `gh pr create` 등이 전부 실패한다.
# worker-vm 은 ARM64 라 네이티브 빌드할 것 (docs/dev-guide.md "omnigent host 이미지 빌드").
ARG OMNIGENT_HOST_TAG=latest
FROM ghcr.io/omnigent-ai/omnigent-host:${OMNIGENT_HOST_TAG}

RUN npm install -g opencode-ai@~1.17.7

# gh CLI — apt 저장소용 gpg 가 이미지에 없어 .deb 직접 설치로 우회. 버전 고정(재현성).
# 파일 위 주석대로 worker-vm(ARM64) 네이티브 빌드 전제 — arm64 .deb 고정.
ARG GH_CLI_VERSION=2.96.0
RUN curl -fsSL -o /tmp/gh.deb "https://github.com/cli/cli/releases/download/v${GH_CLI_VERSION}/gh_${GH_CLI_VERSION}_linux_arm64.deb" \
  && apt-get update \
  && apt-get install -y /tmp/gh.deb \
  && rm -rf /tmp/gh.deb /var/lib/apt/lists/*
