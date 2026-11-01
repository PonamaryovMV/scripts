# scripts — запуск GitOps-стенда (Windows)

Стенд на kind: **Argo CD 3.6 (RC)**, **Kargo**, **Jenkins**, **Argo Rollouts**, **Traefik** и ФП `qa/at` из трёх сервисов.
`up.ps1` поднимает кластер и ставит Argo CD — всё остальное Argo CD синкает из git.

| Репозиторий | Что внутри |
|---|---|
| [scripts](https://github.com/PonamaryovMV/scripts) | `windows/up.ps1`, `down.ps1`, `hosts.ps1`, конфиг kind |
| [infra](https://github.com/PonamaryovMV/infra) | Argo CD (управляет сам собой) + ApplicationSet'ы |
| [gitops-infra](https://github.com/PonamaryovMV/gitops-infra) | Traefik, cert-manager, Argo Rollouts, Kargo, Jenkins + общий чарт `main` |
| [gitops-main](https://github.com/PonamaryovMV/gitops-main) | ФП `qa/at`: dev, test, uat; ветка ФП `qa-at`; Kargo-проект |
| [gitops-prod](https://github.com/PonamaryovMV/gitops-prod) | ФП `qa/at`: prod; файл срочных исключений |
| [jenkins](https://github.com/PonamaryovMV/jenkins) | BuildRelease, ExcludeService, DAST |

## Запуск

Нужен **Docker Desktop**. kind и kubectl скрипт скачает сам в `..\bin`.

```powershell
cd C:\Users\ponam\stend
git -C scripts pull
# scripts\.env:  GITHUB_TOKEN=ghp_...   (classic PAT, scope repo)
powershell -ExecutionPolicy Bypass -File .\scripts\windows\up.ps1
```

- Скрипт один раз попросит **права администратора (UAC)** — чтобы прописать имена в `hosts`.
- Нужен свободный **порт 80** на 127.0.0.1. Если кластер был создан старой схемой портов, скрипт пересоздаст его сам.
- Первый запуск ~10 минут (образы платформы и Jenkins с плагинами).

| Что | Адрес | Логин |
|---|---|---|
| Argo CD | http://argocd | `admin` / `123` |
| Kargo | http://kargo | `admin` / `123` |
| Jenkins | http://jenkins | `admin` / `123` |
| Сервисы ФП | http://qa-at-&lt;mgmt\|core\|api&gt;-&lt;dev\|test\|uat\|prod&gt; | — |

Если адреса не открываются, а в системе включён прокси — добавьте эти имена в исключения прокси.

## Сценарий

1. **Jenkins → qa-at/BuildRelease**: `TASK-2`, `VERSION=release-2-102`, все сервисы. SCA и SAST → Quality Gate → один коммит в ветку `qa-at`.
2. **Kargo → проект qa-at**: появился Freight. Promote в `dev` → `test` → `uat`.
3. На `uat` Kargo запускает **Jenkins qa-at/DAST** и ждёт статус. После успеха Freight можно продвинуть в `prod`.
4. Откройте http://qa-at-mgmt-uat — версия и цвет релиза.
5. Исключение сервиса — **qa-at/ExcludeService** (`planned` / `urgent` / `clear`), см. README репозитория jenkins.

Как всё устроено (репозитории, Argo CD, Kargo, Jenkins, флоу релиза, исключения) — [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Остановка

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\down.ps1                 # удалить кластер
powershell -ExecutionPolicy Bypass -File .\scripts\windows\down.ps1 -CleanupHosts   # + убрать имена из hosts
```
