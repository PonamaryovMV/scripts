#!/usr/bin/env bash
# Ставит CLI для стенда в ~/.local/bin (без sudo).
# Docker ставится отдельно: Docker Desktop с WSL integration или docker-ce внутри WSL.
source "$(dirname "$0")/lib/common.sh"

KIND_VERSION="v0.33.0"
KUBECTL_VERSION="v1.37.2"
ARGOCD_VERSION="v3.6.0-rc4"
KARGO_VERSION="v1.12.5"

BIN_DIR="${HOME}/.local/bin"
mkdir -p "$BIN_DIR"

case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "Неподдерживаемая архитектура: $(uname -m)" ;;
esac

require curl

fetch() { # url target
  log "Скачиваю $(basename "$2") ← $1"
  curl -fsSL -o "$2.tmp" "$1"
  chmod +x "$2.tmp"
  mv "$2.tmp" "$2"
}

fetch "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-${ARCH}" "$BIN_DIR/kind"
fetch "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"                    "$BIN_DIR/kubectl"
fetch "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-${ARCH}" "$BIN_DIR/argocd"
fetch "https://github.com/akuity/kargo/releases/download/${KARGO_VERSION}/kargo-linux-${ARCH}"     "$BIN_DIR/kargo"

# Скрипты стенда находят ~/.local/bin сами; это нужно, только чтобы звать kubectl/kind руками
if [[ ":$(bash -lc 'echo $PATH' 2>/dev/null):" != *":$BIN_DIR:"* ]]; then
  rc="$HOME/.bashrc"
  [[ "${SHELL:-}" == */zsh ]] && rc="$HOME/.zshrc"
  warn "Для ручного запуска kubectl/kind добавьте в PATH:"
  warn "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ${rc} && source ${rc}"
fi

for bin in openssl git; do
  command -v "$bin" >/dev/null || warn "Не найден ${bin}: sudo apt-get install -y ${bin}"
done

if ! command -v docker >/dev/null; then
  warn "Docker не найден. Варианты для WSL:"
  warn "  1) Docker Desktop → Settings → Resources → WSL integration → включить для этого дистрибутива"
  warn "  2) docker-ce внутри WSL: https://docs.docker.com/engine/install/ubuntu/"
elif ! docker info >/dev/null 2>&1; then
  warn "docker установлен, но демон недоступен (запущен ли Docker Desktop / сервис docker?)"
fi

ok "kind     $("$BIN_DIR/kind" version | awk '{print $2}')"
ok "kubectl  ${KUBECTL_VERSION}"
ok "argocd   ${ARGOCD_VERSION}"
ok "kargo    ${KARGO_VERSION}"
