#!/usr/bin/env bash
# Собирает тестовое приложение из gitops-main и пушит в локальный registry.
# Новый semver-тег → Kargo Warehouse видит новый Freight → промоушен по стейджам.
#
#   ./build-app.sh hello-api 1.1.0
#   ./build-app.sh hello-api 1.2.0 --broken        # /health отдаёт 500 → canary откатится
#   ./build-app.sh color-web 1.1.0 --color green
source "$(dirname "$0")/lib/common.sh"

usage() {
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
  echo
  echo "Приложения: $(ls "${GITOPS_MAIN_DIR}/apps" 2>/dev/null | tr '\n' ' ')"
  exit 1
}

[[ $# -ge 2 ]] || usage
APP="$1"; VERSION="$2"; shift 2
BROKEN=false
COLOR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --broken) BROKEN=true ;;
    --color)  COLOR="${2:?--color требует значение}"; shift ;;
    *) usage ;;
  esac
  shift
done

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Версия должна быть semver X.Y.Z (Warehouse выбирает по SemVer)"
SRC="${GITOPS_MAIN_DIR}/apps/${APP}/src"
[[ -f "${SRC}/Dockerfile" ]] || die "Нет ${SRC}/Dockerfile"
require docker

# Цвет по умолчанию зависит от минорной версии — так в браузере видно смену версии
if [[ -z "$COLOR" ]]; then
  palette=(blue green orange purple teal crimson gold)
  minor="$(cut -d. -f2 <<<"$VERSION")"
  COLOR="${palette[minor % ${#palette[@]}]}"
fi

# Сборка и push идут через BuildKit-контейнер в docker-сети kind, а не через `docker push`:
# в Docker Desktop демон живёт в своей VM и не видит порт registry, опубликованный на хосте
# (localhost → ::1 timeout, 127.0.0.1 → connection refused). В сети kind registry доступен
# по тому же имени, что и из кластера, — kind-registry:5000.
docker network inspect kind >/dev/null 2>&1 || die "Нет docker-сети kind — сначала ./up.sh"
ensure_builder
check_builder_dns

IMAGE="${REGISTRY_INTERNAL}/${APP}:${VERSION}"
log "Собираю ${IMAGE} (color=${COLOR}, broken=${BROKEN})"
docker buildx build --builder "$BUILDER_NAME" --push --quiet \
  --provenance=false --sbom=false \
  -t "$IMAGE" \
  --build-arg APP_VERSION="$VERSION" \
  --build-arg APP_COLOR="$COLOR" \
  --build-arg APP_BROKEN="$BROKEN" \
  "$SRC" >/dev/null
ok "${IMAGE} запушен"
