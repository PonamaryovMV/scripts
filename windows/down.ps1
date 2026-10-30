#Requires -Version 5.1
<#
.SYNOPSIS
  Удаляет kind-кластер стенда (контекст из kubeconfig kind убирает сам).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\windows\down.ps1
  powershell -ExecutionPolicy Bypass -File .\scripts\windows\down.ps1 -CleanupWsl    # + остатки WSL-версии стенда
  powershell -ExecutionPolicy Bypass -File .\scripts\windows\down.ps1 -CleanupHosts  # + убрать имена стенда из hosts (UAC)
#>
[CmdletBinding()]
param(
  [string]$ClusterName = "gitops-stand",
  [switch]$CleanupWsl,
  [switch]$CleanupHosts
)

$ErrorActionPreference = "Continue"
$BinDir = Join-Path (Split-Path -Parent (Resolve-Path (Join-Path $PSScriptRoot "..")).Path) "bin"
$env:PATH = "$BinDir;$env:PATH"

if ((& kind get clusters 2>$null) -contains $ClusterName) {
  Write-Host "==> Удаляю kind-кластер $ClusterName" -ForegroundColor Cyan
  & kind delete cluster --name $ClusterName
} else {
  Write-Host " OK  кластера $ClusterName нет" -ForegroundColor Green
}

if ($CleanupWsl) {
  # registry, сборщик и volume от bash-версии стенда — в Windows-версии не нужны
  & docker rm -f kind-registry "buildx_buildkit_$ClusterName-builder0" *> $null
  & docker volume rm "$ClusterName-registry-data" *> $null
  Write-Host " OK  остатки WSL-версии удалены" -ForegroundColor Green
}

if ($CleanupHosts) {
  $script = Join-Path $PSScriptRoot "hosts.ps1"
  Start-Process powershell -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -Remove"
  Write-Host " OK  имена стенда убраны из hosts" -ForegroundColor Green
}
