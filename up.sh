#!/usr/bin/env bash
# Поднимает стенд: registry → kind → секреты → Argo CD (дальше всё синкает Argo CD).
# Повторный запуск безопасен: уже созданное пропускается.
source "$(dirname "$0")/lib/common.sh"

APPS=(hello-api color-web)
INITIAL_VERSION="1.0.0"

check_prereqs() {
  require docker kind kubectl openssl git curl
  docker info >/dev/null 2>&1 || die "Docker недоступен. Запустите Docker Desktop (WSL integration) или сервис docker."
}

# kind в WSL часто падает на нехватке inotify (too many open files)
tune_wsl() {
  is_wsl || return 0

  # Docker Desktop + networkingMode=mirrored: TLS к опубликованным портам из WSL виснет
  # (из Windows при этом всё работает). Проверено на API kind — TLS handshake timeout.
  local winhome
  if winhome="$(windows_home)" && grep -qiE '^\s*networkingMode\s*=\s*mirrored' "${winhome}/.wslconfig" 2>/dev/null \
     && [[ "$(docker info --format '{{.OperatingSystem}}' 2>/dev/null)" == "Docker Desktop" ]]; then
    warn "Docker Desktop + networkingMode=mirrored в .wslconfig: kubectl из WSL не достучится до API kind."
    warn "Уберите networkingMode=mirrored из ${winhome}/.wslconfig и выполните 'wsl --shutdown' (см. README)."
    [[ "${IGNORE_MIRRORED:-false}" == "true" ]] || die "Остановлено. Проигнорировать: IGNORE_MIRRORED=true ./up.sh"
  fi

  local watches instances
  watches=$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0)
  instances=$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo 0)
  if ((watches < 524288 || instances < 512)); then
    log "Поднимаю лимиты inotify (нужен sudo)"
    if sudo sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512 >/dev/null; then
      ok "inotify: watches=524288 instances=512 (до перезапуска WSL; навсегда — см. README)"
    else
      warn "Не удалось поменять inotify-лимиты, kind может работать нестабильно"
    fi
  fi
}

# Кто держит TCP-порт на хосте: контейнер Docker или процесс WSL/Linux
port_owner() {
  local port="$1" c p
  c="$(docker ps --filter "publish=${port}" --format '{{.Names}} ({{.Image}})' | head -1)"
  if [[ -n "$c" ]]; then echo "контейнер ${c}"; return 0; fi
  if command -v ss >/dev/null; then
    p="$(ss -Hltnp "sport = :${port}" 2>/dev/null | head -1)"
    if [[ -n "$p" ]]; then echo "процесс: ${p}"; return 0; fi
  fi
  return 1
}

check_ports() {
  local busy=() port owner ports=()
  [[ "$(docker inspect -f '{{.State.Running}}' "$REGISTRY_NAME" 2>/dev/null || true)" == "true" ]] \
    || ports+=("$REGISTRY_HOST_PORT")
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME" \
    || ports+=(6550 8080 8081 8101 8102 8103 8111 8112 8113)
  for port in "${ports[@]}"; do
    if owner="$(port_owner "$port")"; then busy+=("  ${port} ← ${owner}"); fi
  done
  if ((${#busy[@]})); then
    printf '%s\n' "${busy[@]}" >&2
    die "Порты заняты. Остановите их владельцев (docker rm -f <имя>) или для registry задайте REGISTRY_HOST_PORT в .env"
  fi
}

ensure_repos() {
  local name dir
  for name in infra gitops-infra gitops-main; do
    dir="${WORKSPACE_DIR}/${name}"
    if [[ ! -d "$dir/.git" ]]; then
      log "Клонирую ${name} → ${dir}"
      git clone -q "https://github.com/${GITHUB_OWNER}/${name}.git" "$dir"
    fi
  done
}

ensure_registry() {
  local certs="${STATE_DIR}/certs"
  mkdir -p "$certs"
  if [[ ! -f "$certs/registry.crt" ]]; then
    log "Генерирую self-signed сертификат для registry"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
      -keyout "$certs/registry.key" -out "$certs/registry.crt" \
      -subj "/CN=${REGISTRY_NAME}" \
      -addext "subjectAltName=DNS:${REGISTRY_NAME},DNS:localhost,IP:127.0.0.1" 2>/dev/null
    chmod 644 "$certs/registry.key"
  fi

  if [[ "$(docker inspect -f '{{.State.Running}}' "$REGISTRY_NAME" 2>/dev/null || true)" != "true" ]]; then
    log "Запускаю registry ${REGISTRY_NAME} на 127.0.0.1:${REGISTRY_HOST_PORT}"
    docker rm -f "$REGISTRY_NAME" >/dev/null 2>&1 || true
    # TLS нужен Kargo: он ходит в registry по https (http только для localhost/частных IP),
    # а сертификат не проверяет благодаря insecureSkipTLSVerify в Warehouse.
    docker run -d --restart=always --name "$REGISTRY_NAME" \
      -p "127.0.0.1:${REGISTRY_HOST_PORT}:5000" \
      -v "$certs:/certs:ro" \
      -v "${CLUSTER_NAME}-registry-data:/var/lib/registry" \
      -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/registry.crt \
      -e REGISTRY_HTTP_TLS_KEY=/certs/registry.key \
      -e REGISTRY_STORAGE_DELETE_ENABLED=true \
      "$REGISTRY_IMAGE" >/dev/null
  fi
  ok "registry ${REGISTRY_INTERNAL} (с хоста для просмотра: https://127.0.0.1:${REGISTRY_HOST_PORT})"
}

ensure_cluster() {
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    ok "kind-кластер ${CLUSTER_NAME} уже есть"
  else
    log "Создаю kind-кластер ${CLUSTER_NAME}"
    kind create cluster --name "$CLUSTER_NAME" --config "${SCRIPTS_DIR}/config/kind-config.yaml" --wait 180s
  fi

  # kind говорит Ready раньше, чем API стабильно отвечает снаружи — ждём явно
  wait_for "API кластера отвечает на 127.0.0.1:6550" 180 kc get --raw /readyz

  ensure_on_kind_network "$REGISTRY_NAME"

  # containerd: оба имени registry → https://kind-registry:5000 без проверки сертификата
  local node host dir
  for node in $(kind get nodes --name "$CLUSTER_NAME"); do
    for host in "$REGISTRY_INTERNAL" "127.0.0.1:${REGISTRY_HOST_PORT}" "localhost:${REGISTRY_HOST_PORT}"; do
      dir="/etc/containerd/certs.d/${host}"
      docker exec "$node" mkdir -p "$dir"
      docker exec -i "$node" cp /dev/stdin "$dir/hosts.toml" <<EOF
server = "https://${REGISTRY_INTERNAL}"

[host."https://${REGISTRY_INTERNAL}"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
    done
  done

  kc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "127.0.0.1:${REGISTRY_HOST_PORT}"
    hostFromClusterNetwork: "${REGISTRY_INTERNAL}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
  ok "кластер готов, контекст ${KUBE_CONTEXT}"
}

# Удаляет контекст стенда из kubeconfig Windows (используется и в down.sh)
windows_kubeconfig_remove() {
  local cfg="$1"
  [[ -f "$cfg" ]] || return 0
  KUBECONFIG="$cfg" kubectl config delete-context "$KUBE_CONTEXT" >/dev/null 2>&1 || true
  KUBECONFIG="$cfg" kubectl config delete-cluster "$KUBE_CONTEXT" >/dev/null 2>&1 || true
  KUBECONFIG="$cfg" kubectl config delete-user "$KUBE_CONTEXT" >/dev/null 2>&1 || true
}

export_windows_kubeconfig() {
  [[ "$WINDOWS_KUBECONFIG" == "off" ]] && return 0
  is_wsl || return 0

  local winhome
  winhome="$(windows_home)" || { warn "Не нашёл %USERPROFILE% — kubeconfig для Windows пропущен"; return 0; }
  local dir="${winhome}/.kube"
  local standalone="${dir}/${CLUSTER_NAME}.yaml"
  mkdir -p "$dir"

  # Отдельный файл — всегда (можно добавить в Lens вручную)
  kind get kubeconfig --name "$CLUSTER_NAME" > "$standalone"
  ok "kubeconfig для Windows: ${standalone}"

  [[ "$WINDOWS_KUBECONFIG_MERGE" == "true" ]] || return 0

  # Добавление в %USERPROFILE%\.kube\config — Lens подхватывает его автоматически.
  # Не сливаем файлы целиком (kubectl config view исказил бы Windows-пути вида C:\...),
  # а точечно пишем наши cluster/user/context через kubectl config set-*.
  local cfg="${dir}/config" tmpd server
  tmpd="$(mktemp -d)"
  jp() { KUBECONFIG="$standalone" kubectl config view --raw -o jsonpath="$1"; }
  jp '{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "$tmpd/ca.crt"
  jp '{.users[0].user.client-certificate-data}'          | base64 -d > "$tmpd/client.crt"
  jp '{.users[0].user.client-key-data}'                  | base64 -d > "$tmpd/client.key"
  server="$(jp '{.clusters[0].cluster.server}')"

  [[ -f "$cfg" ]] && cp "$cfg" "${cfg}.bak-${CLUSTER_NAME}"
  windows_kubeconfig_remove "$cfg"
  KUBECONFIG="$cfg" kubectl config set-cluster "$KUBE_CONTEXT" --server="$server" \
    --certificate-authority="$tmpd/ca.crt" --embed-certs=true >/dev/null
  KUBECONFIG="$cfg" kubectl config set-credentials "$KUBE_CONTEXT" \
    --client-certificate="$tmpd/client.crt" --client-key="$tmpd/client.key" --embed-certs=true >/dev/null
  KUBECONFIG="$cfg" kubectl config set-context "$KUBE_CONTEXT" \
    --cluster="$KUBE_CONTEXT" --user="$KUBE_CONTEXT" >/dev/null
  rm -rf "$tmpd"
  ok "контекст ${KUBE_CONTEXT} добавлен в ${cfg} (бэкап: config.bak-${CLUSTER_NAME})"
}

bcrypt_hash() {
  if command -v htpasswd >/dev/null; then
    htpasswd -nbBC 10 "" "$1" | tr -d ':\n'
  else
    docker run --rm httpd:2.4-alpine htpasswd -nbBC 10 "" "$1" | tr -d ':\n'
  fi
}

ensure_secrets() {
  # Admin-аккаунт Kargo. Секрет создаём сами, чтобы хэш пароля не лежал в публичном git.
  kc create namespace kargo --dry-run=client -o yaml | kc apply -f - >/dev/null
  if ! kc -n kargo get secret kargo-api >/dev/null 2>&1; then
    log "Создаю секрет kargo-api (admin / ${KARGO_ADMIN_PASSWORD})"
    kc -n kargo create secret generic kargo-api \
      --from-literal=ADMIN_ACCOUNT_PASSWORD_HASH="$(bcrypt_hash "$KARGO_ADMIN_PASSWORD")" \
      --from-literal=ADMIN_ACCOUNT_TOKEN_SIGNING_KEY="$(openssl rand -base64 48 | tr -d '=+/\n' | cut -c1-48)" >/dev/null
  fi
  ok "секрет kargo/kargo-api"

  # Доступ Kargo на запись в GitHub. Shared-namespace — общий для всех Kargo-проектов.
  kc create namespace kargo-shared-resources --dry-run=client -o yaml | kc apply -f - >/dev/null
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    kc -n kargo-shared-resources create secret generic github-creds \
      --from-literal=repoURL="^https://github\\.com/${GITHUB_OWNER}/.*" \
      --from-literal=repoURLIsRegex=true \
      --from-literal=username="${GITHUB_USER:-$GITHUB_OWNER}" \
      --from-literal=password="$GITHUB_TOKEN" \
      --dry-run=client -o yaml \
      | kc label --local -f - kargo.akuity.io/cred-type=git -o yaml \
      | kc apply -f - >/dev/null
    ok "секрет kargo-shared-resources/github-creds"
  else
    warn "GITHUB_TOKEN не задан в .env — Kargo не сможет пушить в gitops-main (промоушены упадут)"
  fi
}

bootstrap_argocd() {
  log "Ставлю Argo CD из ${INFRA_DIR}/argocd"
  # Первый проход создаёт CRD; CR (ApplicationSet и т.п.) применятся вторым проходом
  kc apply --server-side --force-conflicts -k "${INFRA_DIR}/argocd" >/dev/null 2>&1 || true
  kc wait --for condition=established --timeout=120s \
    crd/applications.argoproj.io crd/applicationsets.argoproj.io crd/appprojects.argoproj.io >/dev/null
  kc apply --server-side --force-conflicts -k "${INFRA_DIR}/argocd" >/dev/null
  kc -n argocd rollout status deploy/argocd-server --timeout=300s >/dev/null
  kc -n argocd rollout status deploy/argocd-repo-server --timeout=300s >/dev/null
  ok "Argo CD запущен, дальше всё синкается из git"
}

wait_platform() {
  log "Жду платформу из gitops-infra (cert-manager → Argo Rollouts → Kargo), первый запуск ~3–7 мин"
  wait_for "CRD Argo Rollouts" 900 kc get crd analysisruns.argoproj.io
  wait_for "Kargo API"         900 kc -n kargo rollout status deploy/kargo-api --timeout=5s
  wait_for "Kargo controller"  900 kc -n kargo rollout status deploy/kargo-controller --timeout=5s

  # Kargo включает интеграцию с Argo Rollouts (верификация стейджей) только если CRD
  # уже были при старте. Порядка между Application нет — при необходимости перезапускаем.
  local crd_ts dep_ts dep
  crd_ts="$(kc get crd analysisruns.argoproj.io -o jsonpath='{.metadata.creationTimestamp}')"
  for dep in kargo-api kargo-controller; do
    # время последнего (пере)запуска: restartedAt, если был rollout restart, иначе создание
    dep_ts="$(kc -n kargo get deploy "$dep" \
      -o jsonpath='{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}')"
    [[ -n "$dep_ts" ]] || dep_ts="$(kc -n kargo get deploy "$dep" -o jsonpath='{.metadata.creationTimestamp}')"
    if (( $(date -d "$dep_ts" +%s) < $(date -d "$crd_ts" +%s) )); then
      log "Перезапускаю ${dep}: стартовал раньше, чем появились CRD Rollouts"
      kc -n kargo rollout restart deploy "$dep" >/dev/null
      kc -n kargo rollout status deploy "$dep" --timeout=300s >/dev/null
    fi
  done
  ok "платформа готова"
}

# Проверка с хоста — только чтобы не пересобирать лишний раз; если порт недоступен, просто соберём заново
image_exists() { # app version
  curl -fsk --max-time 5 "https://127.0.0.1:${REGISTRY_HOST_PORT}/v2/$1/tags/list" 2>/dev/null | grep -q "\"$2\""
}

build_initial_images() {
  local app
  for app in "${APPS[@]}"; do
    if image_exists "$app" "$INITIAL_VERSION"; then
      ok "образ ${app}:${INITIAL_VERSION} уже в registry"
    else
      "${SCRIPTS_DIR}/build-app.sh" "$app" "$INITIAL_VERSION"
    fi
  done
}

main() {
  check_prereqs
  tune_wsl
  check_ports
  ensure_repos
  ensure_registry
  ensure_cluster
  export_windows_kubeconfig
  ensure_secrets
  build_initial_images
  bootstrap_argocd
  wait_platform
  "${SCRIPTS_DIR}/status.sh"
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
