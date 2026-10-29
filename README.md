# scripts — запуск GitOps-стенда

Локальный стенд на kind: **Argo CD 3.6 (RC)** + **Argo Rollouts** + **Kargo** + два тестовых приложения на Python.
Скрипт поднимает кластер и ставит только Argo CD — всё остальное Argo CD синкает из git.

| Репозиторий | Что внутри |
|---|---|
| [`scripts`](https://github.com/PonamaryovMV/scripts) | этот репозиторий: запуск kind + bootstrap Argo CD |
| [`infra`](https://github.com/PonamaryovMV/infra) | Argo CD (управляет сам собой) + ApplicationSet'ы |
| [`gitops-infra`](https://github.com/PonamaryovMV/gitops-infra) | cert-manager, Argo Rollouts, Kargo (Helm + values) |
| [`gitops-main`](https://github.com/PonamaryovMV/gitops-main) | приложения: исходники, CI-сборка в ghcr.io, манифесты dev/stage/prod, Kargo-пайплайны |

```
up.ps1 ─▶ kind ─▶ Argo CD (infra/argocd)
                    ├─ AppSet platform        ─▶ gitops-infra/components/*   (cert-manager, rollouts, kargo)
                    ├─ AppSet workloads       ─▶ gitops-main/apps/*/envs/*   (<app>-dev|stage|prod)
                    └─ AppSet kargo-pipelines ─▶ gitops-main/apps/*/kargo    (Project, Warehouse, Stages)

git tag hello-api/v1.1.0 ─▶ GitHub Actions ─▶ ghcr.io ─▶ Kargo Warehouse ─▶ dev → stage → prod
```

## Версии

| Компонент | Версия |
|---|---|
| kind / Kubernetes | v0.33.0 / v1.37.0 |
| Argo CD | **v3.6.0-rc4** |
| Argo Rollouts | v1.10.1 (chart 2.43.8) + rollout-extension v0.4.1 |
| Kargo | v1.12.5 |
| cert-manager | v1.21.3 |

## Запуск на Windows

Нужен только **Docker Desktop**. kind и kubectl скрипт скачает сам в `..\bin`.

```powershell
cd C:\Users\ponam\stend
git clone https://github.com/PonamaryovMV/scripts.git     # или скачайте zip
copy scripts\.env.example scripts\.env                    # впишите GITHUB_TOKEN
powershell -ExecutionPolicy Bypass -File .\scripts\windows\up.ps1
```

`GITHUB_TOKEN` — fine-grained PAT с правом **Contents: Read and write** только на `gitops-main`.
Нужен Kargo, чтобы коммитить новые теги образов. Без него всё поднимется, но промоушены упадут.

Первый запуск ~5–10 минут. Повторный запуск безопасен. Кластер сразу виден в **Lens** — kind пишет
контекст `kind-gitops-stand` в `%USERPROFILE%\.kube\config`.

| Что | Адрес | Логин |
|---|---|---|
| Argo CD | http://localhost:8080 | `admin` / пароль печатает `up.ps1` |
| Kargo | http://localhost:8081 | `admin` / `admin` |
| hello-api | dev :8101 · stage :8102 · prod :8103 | |
| color-web | dev :8111 · stage :8112 · prod :8113 | |

Остановить: `powershell -ExecutionPolicy Bypass -File .\scripts\windows\down.ps1`
(`-CleanupWsl` — заодно удалить остатки старой WSL-версии: локальный registry и сборщик).

## Запуск из WSL / Linux

Те же шаги в bash: `./install-tools.sh`, `cp .env.example .env`, `./up.sh`, `./down.sh`.
Скрипт дополнительно добавляет контекст в kubeconfig Windows (для Lens).
С Docker Desktop не включайте `networkingMode=mirrored` в `.wslconfig` — TLS к API kind из WSL зависает.

## Новая версия приложения

Образы собирает GitHub Actions в `gitops-main` и пушит в `ghcr.io/ponamaryovmv/<app>`:

```bash
git tag hello-api/v1.1.0 && git push origin hello-api/v1.1.0
```

Сломанная сборка (проверка отката canary) или свой цвет — в `gitops-main`: **Actions → build → Run workflow**.

> После первой сборки сделайте пакеты публичными, иначе кластер не скачает образы:
> GitHub → профиль → **Packages** → `hello-api` / `color-web` → **Package settings → Change visibility → Public**.

Что происходит дальше:

1. Kargo Warehouse (опрос раз в 30с) видит тег `1.1.0` в ghcr → Freight.
2. Стейдж `dev` (auto-promotion) меняет `newTag` в `gitops-main/apps/<app>/envs/dev`, коммитит в `main`, синкает `<app>-dev`.
3. Argo Rollouts катит canary: 50% → пауза 15с → анализ `/health` canary-подов → 100%.
4. Kargo проверяет, что стейдж отдаёт новую версию (`/version`) → Freight verified → `stage`.
5. `prod` — вручную: Kargo UI → Promote.
