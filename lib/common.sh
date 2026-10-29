# shellcheck shell=bash
# Общие функции и настройки для скриптов стенда.
# Подключается через: source "$(dirname "$0")/lib/common.sh"

set -Eeuo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# install-tools.sh ставит CLI сюда — скрипты находят их, даже если PATH шелла не настроен
case ":$PATH:" in
  *":${HOME}/.local/bin:"*) ;;
  *) export PATH="${HOME}/.local/bin:${PATH}" ;;
esac
WORKSPACE_DIR="$(cd "${SCRIPTS_DIR}/.." && pwd)"

# .env (не коммитится) переопределяет значения по умолчанию
if [[ -f "${SCRIPTS_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${SCRIPTS_DIR}/.env"
  set +a
fi

# ---------- параметры стенда ----------
: "${CLUSTER_NAME:=gitops-stand}"
: "${GITHUB_OWNER:=PonamaryovMV}"
: "${GIT_BRANCH:=main}"

: "${INFRA_DIR:=${WORKSPACE_DIR}/infra}"
: "${GITOPS_INFRA_DIR:=${WORKSPACE_DIR}/gitops-infra}"
: "${GITOPS_MAIN_DIR:=${WORKSPACE_DIR}/gitops-main}"

# Локальный registry: снаружи (docker push) — 127.0.0.1:5001 (не localhost: Docker Desktop резолвит его в ::1),
# внутри кластера (containerd, Kargo) — kind-registry:5000.
: "${REGISTRY_NAME:=kind-registry}"
: "${REGISTRY_HOST_PORT:=5001}"
: "${REGISTRY_INTERNAL:=${REGISTRY_NAME}:5000}"
: "${REGISTRY_IMAGE:=registry:3}"

: "${KARGO_ADMIN_PASSWORD:=admin}"
: "${STATE_DIR:=${HOME}/.local/share/${CLUSTER_NAME}}"

# Kubeconfig для Windows (Lens). auto = только если запущено в WSL.
: "${WINDOWS_KUBECONFIG:=auto}"        # auto | off
: "${WINDOWS_KUBECONFIG_MERGE:=true}"   # добавлять контекст в %USERPROFILE%\.kube\config

KUBE_CONTEXT="kind-${CLUSTER_NAME}"

# Если в шелле задан HTTP(S)_PROXY, kubectl/curl пошли бы через него даже на 127.0.0.1
# (симптом: "TLS handshake timeout" к API kind). Локальные адреса — всегда напрямую.
NO_PROXY="${NO_PROXY:-${no_proxy:-}}"
for _h in 127.0.0.1 localhost "$REGISTRY_NAME" .svc .cluster.local; do
  case ",${NO_PROXY}," in
    *",${_h},"*) ;;
    *) NO_PROXY="${NO_PROXY:+${NO_PROXY},}${_h}" ;;
  esac
done
unset _h
export NO_PROXY no_proxy="$NO_PROXY"

# ---------- логирование ----------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BLUE=$'\e[34m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'
else
  C_RESET=''; C_BLUE=''; C_GREEN=''; C_YELLOW=''; C_RED=''
fi
log()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s ✔%s  %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s !%s  %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s ✖%s  %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

trap 'die "Ошибка в строке ${LINENO}: ${BASH_COMMAND}"' ERR

require() {
  local missing=()
  for bin in "$@"; do command -v "$bin" >/dev/null 2>&1 || missing+=("$bin"); done
  if ((${#missing[@]})); then
    die "Не найдены: ${missing[*]}. Запустите ./install-tools.sh (docker ставится отдельно)."
  fi
}

kc() { kubectl --context "$KUBE_CONTEXT" "$@"; }

is_wsl() { grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; }

# Домашняя папка Windows в виде пути WSL (/mnt/c/Users/<user>)
windows_home() {
  local win
  win="$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r' || true)"
  [[ -n "$win" && "$win" != *'%USERPROFILE%'* ]] || return 1
  wslpath -u "$win"
}

# Ждёт, пока команда не завершится успешно (по умолчанию до 10 минут)
wait_for() {
  local desc="$1" timeout="${2:-600}"; shift 2
  local start=$SECONDS
  until "$@" >/dev/null 2>&1; do
    ((SECONDS - start < timeout)) || die "Не дождались: ${desc}"
    sleep 5
  done
  ok "$desc"
}
