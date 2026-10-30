#Requires -Version 5.1
<#
.SYNOPSIS
  Прописывает имена стенда в hosts (127.0.0.1). Нужны права администратора — up.ps1 запускает его через UAC.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\windows\hosts.ps1 -Names argocd,kargo,jenkins
  powershell -ExecutionPolicy Bypass -File .\scripts\windows\hosts.ps1 -Remove
#>
param(
  [string]$Names = "",
  [switch]$Remove
)

$ErrorActionPreference = "Stop"
$hostsFile = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
$begin = "# >>> gitops-stand (scripts/windows/hosts.ps1)"
$end   = "# <<< gitops-stand"

$lines = @(Get-Content $hostsFile -ErrorAction SilentlyContinue)
$out = New-Object System.Collections.Generic.List[string]
$skip = $false
foreach ($l in $lines) {
  if ($l -eq $begin) { $skip = $true; continue }
  if ($l -eq $end)   { $skip = $false; continue }
  if (-not $skip) { $out.Add($l) }
}
while ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -eq "") { $out.RemoveAt($out.Count - 1) }

if (-not $Remove) {
  $list = @($Names -split "[,; ]+" | Where-Object { $_ })
  if ($list.Count -eq 0) { Write-Error "Не переданы имена (-Names)"; exit 1 }
  $out.Add("")
  $out.Add($begin)
  foreach ($n in $list) { $out.Add("127.0.0.1`t$n") }
  $out.Add($end)
}

Set-Content -Path $hostsFile -Value $out -Encoding ASCII
& ipconfig /flushdns *> $null
if ($Remove) { Write-Host "hosts: записи стенда удалены" } else { Write-Host "hosts: добавлено имён — $($list.Count)" }
exit 0
