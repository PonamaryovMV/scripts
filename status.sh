#!/usr/bin/env bash
# Адреса, пароли и состояние стенда.
source "$(dirname "$0")/lib/common.sh"

kc cluster-info >/dev/null 2>&1 || die "Кластер ${CLUSTER_NAME} недоступен (контекст ${KUBE_CONTEXT})"

argocd_pass="$(kc -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"

cat <<EOF

${C_GREEN}Стенд ${CLUSTER_NAME}${C_RESET}  (kubectl context: ${KUBE_CONTEXT})

  Argo CD    http://localhost:8080      admin / ${argocd_pass:-<ещё не создан>}
  Kargo      http://localhost:8081      admin / ${KARGO_ADMIN_PASSWORD}
  Registry   localhost:${REGISTRY_HOST_PORT} (push)  →  ${REGISTRY_INTERNAL} (в кластере)

  hello-api  dev http://localhost:8101   stage http://localhost:8102   prod http://localhost:8103
  color-web  dev http://localhost:8111   stage http://localhost:8112   prod http://localhost:8113

EOF

log "Argo CD Applications"
kc -n argocd get applications.argoproj.io \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision' \
  2>/dev/null | cut -c1-110 || true

if kc get crd stages.kargo.akuity.io >/dev/null 2>&1; then
  echo
  log "Kargo Stages"
  kc get stages.kargo.akuity.io -A \
    -o custom-columns='PROJECT:.metadata.namespace,STAGE:.metadata.name,FREIGHT:.status.freightSummary,HEALTH:.status.health.status' \
    2>/dev/null || true
fi
