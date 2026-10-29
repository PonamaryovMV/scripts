#!/usr/bin/env bash
# Удаляет kind-кластер и контекст из kubeconfig Windows.
#   ./down.sh          — удалить кластер
#   ./down.sh --purge  — плюс остатки старой версии стенда (локальный registry, сборщик)
source "$(dirname "$0")/lib/common.sh"
source "${SCRIPTS_DIR}/up.sh"   # windows_kubeconfig_remove

PURGE=false
[[ "${1:-}" == "--purge" ]] && PURGE=true

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "Удаляю kind-кластер ${CLUSTER_NAME}"
  kind delete cluster --name "$CLUSTER_NAME"
fi

if is_wsl && [[ "$WINDOWS_KUBECONFIG" != "off" ]] && winhome="$(windows_home)"; then
  windows_kubeconfig_remove "${winhome}/.kube/config"
  rm -f "${winhome}/.kube/${CLUSTER_NAME}.yaml"
  ok "контекст ${KUBE_CONTEXT} убран из kubeconfig Windows"
fi

if $PURGE; then
  docker rm -f kind-registry "buildx_buildkit_${CLUSTER_NAME}-builder0" >/dev/null 2>&1 || true
  docker volume rm "${CLUSTER_NAME}-registry-data" >/dev/null 2>&1 || true
  rm -rf "$STATE_DIR"
  ok "остатки локального registry удалены"
fi

ok "готово"
