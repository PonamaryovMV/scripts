# scripts — запуск GitOps-стенда

Локальный стенд на kind: **Argo CD 3.6 (RC)** + **Argo Rollouts** + **Kargo** + два тестовых приложения на Python.
Скрипты поднимают кластер и ставят только Argo CD — всё остальное Argo CD синкает из git.

| Репозиторий | Что внутри |
|---|---|
| [`scripts`](https://github.com/PonamaryovMV/scripts) | этот репозиторий: kind, registry, bootstrap |
| [`infra`](https://github.com/PonamaryovMV/infra) | Argo CD (управляет сам собой) + ApplicationSet'ы |
| [`gitops-infra`](https://github.com/PonamaryovMV/gitops-infra) | cert-manager, Argo Rollouts, Kargo (Helm + values) |
| [`gitops-main`](https://github.com/PonamaryovMV/gitops-main) | приложения: исходники, манифесты dev/stage/prod, Kargo-пайплайны |

```
up.sh ─▶ kind + registry ─▶ Argo CD (infra/argocd)
                              ├─ AppSet platform        ─▶ gitops-infra/components/*   (cert-manager, rollouts, kargo)
                              ├─ AppSet workloads       ─▶ gitops-main/apps/*/envs/*   (<app>-dev|stage|prod)
                              └─ AppSet kargo-pipelines ─▶ gitops-main/apps/*/kargo    (Project, Warehouse, Stages)
```

## Версии

| Компонент | Версия |
|---|---|
| kind / Kubernetes | v0.33.0 / v1.37.0 |
| Argo CD | **v3.6.0-rc4** |
| Argo Rollouts | v1.10.1 (chart 2.43.8) + rollout-extension v0.4.1 |
| Kargo | v1.12.5 |
| cert-manager | v1.21.3 |

## Что нужно

- Windows + WSL2 (Ubuntu) **или** просто Linux
- Docker: Docker Desktop с включённой *WSL integration* для дистрибутива **или** docker-ce внутри WSL
- 8+ ГБ RAM для WSL (`%USERPROFILE%\.wslconfig` → `[wsl2] memory=10GB`)
- `openssl`, `git`, `curl` (`sudo apt-get install -y openssl git curl`)

## Быстрый старт

Все четыре репозитория должны лежать рядом. Клонируйте **внутри WSL** (не в `/mnt/c` — там медленно и ломаются права):

```bash
mkdir -p ~/stand && cd ~/stand
git clone https://github.com/PonamaryovMV/scripts.git
cd scripts
./install-tools.sh            # kind, kubectl, argocd, kargo → ~/.local/bin
cp .env.example .env          # впишите GITHUB_TOKEN
./up.sh                       # недостающие репозитории (infra, gitops-*) склонирует сам
```

`GITHUB_TOKEN` — fine-grained PAT с правом **Contents: Read and write** на `gitops-main`.
Без него всё поднимется, но Kargo не сможет закоммитить новый тег — промоушены упадут.

Первый запуск занимает ~5–10 минут (тянутся образы). Повторный `./up.sh` безопасен.

| Что | Адрес | Логин |
|---|---|---|
| Argo CD | http://localhost:8080 | `admin` / пароль печатает `./status.sh` |
| Kargo | http://localhost:8081 | `admin` / `admin` (`KARGO_ADMIN_PASSWORD`) |
| hello-api | dev :8101 · stage :8102 · prod :8103 | |
| color-web | dev :8111 · stage :8112 · prod :8113 | |

## Lens

Кластер виден в Lens сразу после `up.sh`:

- контекст `kind-gitops-stand` добавляется в `%USERPROFILE%\.kube\config` (бэкап рядом: `config.bak-gitops-stand`);
- дополнительно пишется отдельный файл `%USERPROFILE%\.kube\gitops-stand.yaml`.

API слушает `127.0.0.1:6550` — WSL2 пробрасывает этот порт в Windows (Docker Desktop публикует его в Windows напрямую).
Не хотите трогать основной kubeconfig — `WINDOWS_KUBECONFIG_MERGE=false` в `.env` и добавьте отдельный файл в Lens вручную.
`./down.sh` убирает контекст обратно.

## Сценарии

```bash
./build-app.sh hello-api 1.1.0             # новая версия: dev → stage автоматически, prod — кнопкой в Kargo
./build-app.sh color-web 1.1.0             # цвет меняется по минорной версии — смотрите canary на :8111
./build-app.sh hello-api 1.2.0 --broken    # /health = 500 → canary-анализ падает → Rollout откатывается
./status.sh                                # адреса, пароли, Applications, Stages
```

Что происходит при новом теге:

1. Kargo Warehouse (опрос раз в 30с) находит тег `1.1.0` → создаёт Freight.
2. Стейдж `dev` (auto-promotion) клонирует `gitops-main`, меняет `newTag` в `apps/<app>/envs/dev`, коммитит в `main` и синкает `<app>-dev`.
3. Argo Rollouts катит canary: 50% → пауза 15с → анализ `/health` canary-подов → 100%.
4. Kargo проверяет, что стейдж отдаёт новую версию (`/version`) — Freight становится verified и уезжает в `stage`.
5. `prod` — вручную: Kargo UI → Promote.

## Остановка

```bash
./down.sh           # удалить кластер (образы в registry сохраняются)
./down.sh --purge   # + registry, его volume и сертификаты
```

## Устройство registry

Один контейнер `kind-registry` с self-signed TLS:

- с хоста: `docker push 127.0.0.1:5001/<app>:<tag>` (Docker считает 127.0.0.0/8 доверенным и не проверяет сертификат; именно `127.0.0.1`, а не `localhost` — Docker Desktop резолвит `localhost` в `::1`);
- в кластере: `kind-registry:5000/<app>` — containerd настроен с `skip_verify`, Kargo Warehouse — с `insecureSkipTLSVerify`.

TLS нужен из-за Kargo: он ходит в registry по HTTP только для `localhost` и приватных IP, а имя `kind-registry` — ни то, ни другое.

## WSL: частые проблемы

- **`TLS handshake timeout` к `127.0.0.1:6550` из WSL, а из Windows API отвечает** — связка Docker Desktop +
  `networkingMode=mirrored` в `.wslconfig`. Уберите эту строку, `wsl --shutdown`, перезапустите Docker Desktop.
  Если mirrored нужен — ставьте docker-ce внутрь WSL вместо Docker Desktop. `up.sh` сам предупреждает об этой связке.

- **`too many open files` / поды kind падают** — `up.sh` поднимает лимиты inotify до перезагрузки WSL. Навсегда:
  `echo -e "fs.inotify.max_user_watches=524288\nfs.inotify.max_user_instances=512" | sudo tee /etc/sysctl.d/99-kind.conf`
- **`$'\r': command not found`** — репозиторий склонирован из Windows с CRLF. `.gitattributes` форсит LF, но лучше клонировать внутри WSL.
- **Lens не подключается** — проверьте `curl.exe -k https://127.0.0.1:6550/version` из PowerShell. С Docker Desktop порт публикуется в Windows напрямую; с docker-ce в WSL нужен `localhostForwarding=true` (NAT) или mirrored-режим.
- **Argo CD не видит коммит Kargo** — опрос git раз в 30с (`timeout.reconciliation`); Kargo после коммита сам запускает sync.
