#Requires -Version 5.1
<#
.SYNOPSIS
  Поднимает GitOps-стенд на Windows: kind-кластер + Argo CD.
  Остальное (cert-manager, Argo Rollouts, Kargo, приложения) Argo CD синкает из git сам.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\windows\up.ps1

.NOTES
  Нужен Docker Desktop. kind и kubectl скачиваются в .\bin рядом с папкой scripts.
  GITHUB_TOKEN (fine-grained PAT, Contents: RW на gitops-main) — в scripts\.env или в переменной окружения.
  Повторный запуск безопасен.
#>
[CmdletBinding()]
param(
  [string]$ClusterName = "gitops-stand",
  [string]$KargoPassword = "admin"
)

$ErrorActionPreference = "Continue"   # ошибки нативных команд проверяем по exit code сами
$ProgressPreference    = "SilentlyContinue"
$OutputEncoding        = New-Object System.Text.UTF8Encoding $false

$KindVersion    = "v0.33.0"
$KubectlVersion = "v1.37.2"
$GithubOwner    = "PonamaryovMV"
$KindConfig     = Join-Path $PSScriptRoot "..\config\kind-config.yaml"
$ScriptsDir     = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$StandDir       = Split-Path -Parent $ScriptsDir
$BinDir         = Join-Path $StandDir "bin"
$Context        = "kind-$ClusterName"

# ---------------- вывод ----------------
function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host " OK  $m" -ForegroundColor Green }
function Warn($m) { Write-Host " !   $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host " X   $m" -ForegroundColor Red; exit 1 }

# Простые функции (без param): аргументы вида -n / -o / -f уходят в $args как есть,
# а не разбираются PowerShell как параметры функции.

# Запуск нативной команды; при ненулевом коде — стоп
function Run {
  $exe = $args[0]; $rest = @($args | Select-Object -Skip 1)
  & $exe @rest
  if ($LASTEXITCODE -ne 0) { Fail "$exe $($rest -join ' ') (exit $LASTEXITCODE)" }
}
# Успешна ли нативная команда (вывод скрыт)
function Test-Cmd {
  $exe = $args[0]; $rest = @($args | Select-Object -Skip 1)
  & $exe @rest *> $null
  return ($LASTEXITCODE -eq 0)
}
function Kc { Run kubectl --context $Context @args }
function Wait-Until([string]$What, [int]$TimeoutSec, [scriptblock]$Check) {
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while (-not (& $Check)) {
    if ((Get-Date) -gt $deadline) { Fail "Не дождались: $What" }
    Start-Sleep -Seconds 5
  }
  Ok $What
}

# ---------------- .env ----------------
function Import-DotEnv {
  $file = Join-Path $ScriptsDir ".env"
  if (-not (Test-Path $file)) { return }
  foreach ($line in Get-Content $file) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') {
      $name = $Matches[1]; $value = $Matches[2].Trim('"', "'")
      if ($value -and -not [Environment]::GetEnvironmentVariable($name)) {
        Set-Item -Path "env:$name" -Value $value
      }
    }
  }
}

# ---------------- шаги ----------------
function Test-Docker {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Fail "Docker не найден. Установите Docker Desktop." }
  if (-not (Test-Cmd docker info)) { Fail "Docker Desktop не запущен." }
  Ok "Docker Desktop работает"
}

function Install-Tools {
  New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
  $tools = @{
    "kind.exe"    = "https://github.com/kubernetes-sigs/kind/releases/download/$KindVersion/kind-windows-amd64"
    "kubectl.exe" = "https://dl.k8s.io/release/$KubectlVersion/bin/windows/amd64/kubectl.exe"
  }
  foreach ($name in $tools.Keys) {
    $path = Join-Path $BinDir $name
    if (-not (Test-Path $path)) {
      Step "Скачиваю $name"
      Invoke-WebRequest -UseBasicParsing -Uri $tools[$name] -OutFile $path
    }
  }
  $env:PATH = "$BinDir;$env:PATH"
  Ok "kind $KindVersion, kubectl $KubectlVersion в $BinDir"
}

function Test-Ports {
  $ports = @(6550, 8080, 8081, 8101, 8102, 8103, 8111, 8112, 8113)
  $busy = @()
  foreach ($p in $ports) {
    $c = Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) {
      $proc = (Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue).ProcessName
      $busy += "  $p <- $proc (pid $($c.OwningProcess))"
    }
  }
  if ($busy.Count) {
    $busy | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
    Fail "Порты заняты (часто это контейнеры Docker: docker ps). Освободите их и запустите снова."
  }
}

function New-Cluster {
  $exists = (& kind get clusters 2>$null) -contains $ClusterName
  if ($exists) {
    # kind не переживает перезапуск Docker Desktop: остановленную ноду проще пересоздать
    $running = & docker inspect -f "{{.State.Running}}" "$ClusterName-control-plane" 2>$null
    if ($running -ne "true") {
      Warn "Нода кластера $ClusterName остановлена (перезапуск Docker Desktop?) — пересоздаю кластер"
      Run kind delete cluster --name $ClusterName
      $exists = $false
    }
  }
  if ($exists) {
    Ok "kind-кластер $ClusterName уже есть"
    Run kind export kubeconfig --name $ClusterName
  } else {
    Test-Ports
    Step "Создаю kind-кластер $ClusterName"
    Run kind create cluster --name $ClusterName --config $KindConfig --wait 180s
  }
  Wait-Until "API кластера отвечает" 180 { Test-Cmd kubectl --context $Context get --raw /readyz }
  Ok "контекст $Context в $env:USERPROFILE\.kube\config — Lens увидит его сам"
}

function Get-BcryptHash([string]$Password) {
  # htpasswd из официального образа httpd; пустой логин PowerShell 5.1 не передаёт, поэтому admin: и отрезаем
  $line = & docker run --rm httpd:2.4-alpine htpasswd -nbB -C 10 admin $Password
  if ($LASTEXITCODE -ne 0 -or -not $line) { Fail "Не удалось посчитать bcrypt-хэш" }
  return ($line.Trim() -split ':', 2)[1]
}

function Set-Secrets {
  $nsYaml = "apiVersion: v1`nkind: Namespace`nmetadata:`n  name: kargo`n---`napiVersion: v1`nkind: Namespace`nmetadata:`n  name: kargo-shared-resources`n"
  $nsYaml | kubectl --context $Context apply -f - | Out-Null

  # admin Kargo: хэш пароля + ключ подписи токенов (в публичный git не кладём)
  if (-not (Test-Cmd kubectl --context $Context -n kargo get secret kargo-api)) {
    Step "Создаю секрет kargo-api (admin / $KargoPassword)"
    $hash = Get-BcryptHash $KargoPassword
    $key = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 48 | ForEach-Object { [char]$_ })
    $yaml = @"
apiVersion: v1
kind: Secret
metadata:
  name: kargo-api
  namespace: kargo
stringData:
  ADMIN_ACCOUNT_PASSWORD_HASH: '$hash'
  ADMIN_ACCOUNT_TOKEN_SIGNING_KEY: '$key'
"@
    $yaml | kubectl --context $Context apply -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "Не удалось создать секрет kargo-api" }
  }
  Ok "секрет kargo/kargo-api"

  # доступ Kargo на запись в gitops-main
  if ($env:GITHUB_TOKEN) {
    $user = if ($env:GITHUB_USER) { $env:GITHUB_USER } else { $GithubOwner }
    $yaml = @"
apiVersion: v1
kind: Secret
metadata:
  name: github-creds
  namespace: kargo-shared-resources
  labels:
    kargo.akuity.io/cred-type: git
stringData:
  repoURL: 'https://github.com/$GithubOwner/gitops-main.git'
  username: '$user'
  password: '$($env:GITHUB_TOKEN)'
"@
    $yaml | kubectl --context $Context apply -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "Не удалось создать секрет github-creds" }
    if (-not (Test-Cmd kubectl --context $Context -n kargo-shared-resources get secret github-creds)) { Fail "Секрет github-creds не появился" }
    Ok "секрет kargo-shared-resources/github-creds (доступ на запись в gitops-main)"
  } else {
    Warn "GITHUB_TOKEN не задан (scripts\.env) — Kargo не сможет коммитить в gitops-main"
  }
}

function Install-ArgoCD {
  # Свежий infra/main без git: zip с GitHub во временную папку
  $tmp = Join-Path $env:TEMP "gitops-stand-infra"
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $zip = Join-Path $tmp "infra.zip"
  Step "Скачиваю infra (main)"
  Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$GithubOwner/infra/archive/refs/heads/main.zip" -OutFile $zip
  Expand-Archive -Path $zip -DestinationPath $tmp -Force
  $argocdDir = Join-Path $tmp "infra-main\argocd"

  Step "Ставлю Argo CD"
  # 1-й проход создаёт CRD, CR (ApplicationSet и т.п.) применятся во 2-м
  & kubectl --context $Context apply --server-side --force-conflicts -k $argocdDir *> $null
  Kc wait --for condition=established --timeout=120s crd/applications.argoproj.io crd/applicationsets.argoproj.io crd/appprojects.argoproj.io | Out-Null
  Kc apply --server-side --force-conflicts -k $argocdDir | Out-Null
  Kc -n argocd rollout status deploy/argocd-server --timeout=900s | Out-Null
  Kc -n argocd rollout status deploy/argocd-repo-server --timeout=900s | Out-Null
  Ok "Argo CD запущен — дальше всё синкается из git"
}

function Wait-Platform {
  Step "Жду платформу (cert-manager → Argo Rollouts → Kargo), первый запуск ~3-7 мин"
  Wait-Until "CRD Argo Rollouts" 900 { Test-Cmd kubectl --context $Context get crd analysisruns.argoproj.io }
  Wait-Until "Kargo API"        900 { Test-Cmd kubectl --context $Context -n kargo rollout status deploy/kargo-api --timeout=5s }
  Wait-Until "Kargo controller" 900 { Test-Cmd kubectl --context $Context -n kargo rollout status deploy/kargo-controller --timeout=5s }

  # Kargo включает интеграцию с Rollouts, только если CRD были при старте
  $crdTs = [datetime](& kubectl --context $Context get crd analysisruns.argoproj.io -o "jsonpath={.metadata.creationTimestamp}")
  foreach ($dep in "kargo-api", "kargo-controller") {
    $ts = & kubectl --context $Context -n kargo get deploy $dep -o "jsonpath={.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}"
    if (-not $ts) { $ts = & kubectl --context $Context -n kargo get deploy $dep -o "jsonpath={.metadata.creationTimestamp}" }
    if ([datetime]$ts -lt $crdTs) {
      Step "Перезапускаю $dep (стартовал раньше CRD Rollouts)"
      Kc -n kargo rollout restart deploy $dep | Out-Null
      Kc -n kargo rollout status deploy $dep --timeout=300s | Out-Null
    }
  }
  Ok "платформа готова"
}

function Show-Status {
  $pass = & kubectl --context $Context -n argocd get secret argocd-initial-admin-secret -o "jsonpath={.data.password}" 2>$null
  if ($pass) { $pass = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pass)) } else { $pass = "<ещё не создан>" }
  Write-Host ""
  Write-Host "Стенд $ClusterName  (kubectl context: $Context)" -ForegroundColor Green
  Write-Host ""
  Write-Host "  Argo CD    http://localhost:8080   admin / $pass"
  Write-Host "  Kargo      http://localhost:8081   admin / $KargoPassword"
  Write-Host "  hello-api  dev :8101  stage :8102  prod :8103"
  Write-Host "  color-web  dev :8111  stage :8112  prod :8113"
  Write-Host ""
  & kubectl --context $Context -n argocd get applications.argoproj.io `
    -o "custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status"
}

# ---------------- main ----------------
Import-DotEnv
Test-Docker
Install-Tools
New-Cluster
Set-Secrets
Install-ArgoCD
Wait-Platform
Show-Status
