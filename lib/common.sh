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

# Локальный registry. Везде используется одно имя — kind-registry:5000 (docker-сеть kind):
# так его видят containerd, Kargo и BuildKit-сборщик. Порт на хосте (127.0.0.1:5001) —
# только чтобы заглянуть в каталог с WSL/Windows: curl -k https://127.0.0.1:5001/v2/_catalog
: "${REGISTRY_NAME:=kind-registry}"
: "${REGISTRY_HOST_PORT:=5001}"
: "${REGISTRY_INTERNAL:=${REGISTRY_NAME}:5000}"
: "${REGISTRY_IMAGE:=registry:3}"
: "${BUILDER_NAME:=${CLUSTER_NAME}-builder}"

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

# Подключает контейнер к docker-сети kind, если он ещё не в ней.
# Подключение может потеряться при перезапуске Docker Desktop / wsl --shutdown.
ensure_on_kind_network() {
  local c="$1"
  if ! docker network inspect kind -f '{{range .Containers}}{{.Name}} {{end}}' | tr ' ' '\n' | grep -qx "$c"; then
    log "Подключаю ${c} к docker-сети kind"
    docker network connect kind "$c"
  fi
}

# BuildKit-сборщик в docker-сети kind: пушит прямо в kind-registry:5000
# (self-signed сертификат registry → insecure = без проверки TLS).
ensure_builder() {
  if docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
    # сеть kind могла быть пересоздана вместе с кластером — тогда сборщик битый
    if docker buildx inspect --bootstrap "$BUILDER_NAME" >/dev/null 2>&1; then return 0; fi
    docker buildx rm -f "$BUILDER_NAME" >/dev/null 2>&1 || true
  fi
  log "Создаю BuildKit-сборщик ${BUILDER_NAME} в сети kind"
  local cfg
  cfg="$(mktemp)"
  cat > "$cfg" <<EOF
[registry."${REGISTRY_INTERNAL}"]
  insecure = true
EOF
  docker buildx create --name "$BUILDER_NAME" \
    --driver docker-container \
    --driver-opt network=kind \
    --buildkitd-config "$cfg" \
    --bootstrap >/dev/null
  rm -f "$cfg"
}

# Контейнер, в котором работает buildkitd сборщика
builder_container() { echo "buildx_buildkit_${BUILDER_NAME}0"; }

# Проверяет, что сборщик видит registry по имени; иначе печатает диагностику
check_builder_dns() {
  local bc; bc="$(builder_container)"
  ensure_on_kind_network "$REGISTRY_NAME"
  ensure_on_kind_network "$bc"
  # нечем проверить внутри образа — не мешаем, ошибка всплывёт при push
  docker exec "$bc" sh -c 'command -v nslookup' >/dev/null 2>&1 || return 0
  docker exec "$bc" nslookup "$REGISTRY_NAME" >/dev/null 2>&1 && return 0
  warn "Сборщик ${bc} не резолвит ${REGISTRY_NAME}. Состояние сети kind:"
  docker network inspect kind -f '{{range .Containers}}  {{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}' >&2
  warn "Сети сборщика: $(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$bc")"
  warn "Сети registry: $(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$REGISTRY_NAME")"
  die "Пришлите этот вывод — разберёмся"
}

remove_builder() {
  docker buildx rm -f "$BUILDER_NAME" >/dev/null 2>&1 || true
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
