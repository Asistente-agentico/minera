<#
.SYNOPSIS
    Levanta el stack de desarrollo de la UI (MK + MA + M2 + M3 + UI) con la
    configuracion de minera.

.DESCRIPTION
    Lee MASTER_SECRET desde minera/.env y delega en Illari/scripts/dev-ui.ps1,
    apuntando CLIENTE_DIR al repo minera.

    Requiere que el repo Illari este en ../Illari relativo a minera.

.PARAMETER Cmd
    Subcomando: up (default) | down | logs | ps

.PARAMETER UiPort
    Puerto de la UI en el host. Default: 3000

.EXAMPLE
    .\scripts\dev-ui.ps1
    .\scripts\dev-ui.ps1 -Cmd down
    .\scripts\dev-ui.ps1 -Cmd logs
#>

param(
    [string]$Cmd    = "up",
    [string]$UiPort = "3000"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding          = [System.Text.Encoding]::UTF8

$repoRaiz  = Split-Path -Parent $PSScriptRoot
$illariDir = Join-Path (Split-Path -Parent $repoRaiz) "Illari"
$illariScript = Join-Path $illariDir "scripts\dev-ui.ps1"

if (-not (Test-Path $illariScript)) {
    Write-Error "No se encontro Illari/scripts/dev-ui.ps1 en: $illariScript`nVerifica que el repo Illari este en $(Split-Path -Parent $repoRaiz)\Illari"
    exit 1
}

# Leer variables desde minera/.env si no estan en el entorno.
$envFile = Join-Path $repoRaiz ".env"
if (Test-Path $envFile) {
    foreach ($pat in @(
        @{ Name = "MASTER_SECRET";   Var = "MASTER_SECRET"   },
        @{ Name = "ILLARI_IMAGE";    Var = "ILLARI_IMAGE"    },
        @{ Name = "ILLARI_UI_IMAGE"; Var = "ILLARI_UI_IMAGE" }
    )) {
        $varName = $pat.Var
        if (-not (Get-Item "env:$varName" -ErrorAction SilentlyContinue)) {
            $m = Select-String -Path $envFile -Pattern "^\s*(?:export\s+)?$($pat.Name)\s*=\s*(.+)$"
            if ($m) {
                $val = $m.Matches[0].Groups[1].Value.Trim().Trim('"').Trim("'")
                if ($val) { Set-Item "env:$varName" $val }
            }
        }
    }
}
if (-not $env:MASTER_SECRET) {
    Write-Error "MASTER_SECRET no definido. Agregalo a minera/.env o defínelo en `$env:MASTER_SECRET."
    exit 1
}

# ---------------------------------------------------------------------------
# Pre-flight: verificar imágenes locales (solo en subcomando up)
# Se activa si existe minera/imagenes/versiones.yaml.
# ---------------------------------------------------------------------------
$versionesFile = Join-Path $repoRaiz "imagenes\versiones.yaml"
if (($Cmd -eq "up") -and (Test-Path $versionesFile)) {
    $modImagenes = @(
        @{ Mod = "mk"; Var = "ILLARI_MK_IMAGE"; Default = "illari-mk:local" },
        @{ Mod = "ma"; Var = "ILLARI_MA_IMAGE"; Default = "illari-ma:local" },
        @{ Mod = "mv"; Var = "ILLARI_MV_IMAGE"; Default = "illari-mv:local" },
        @{ Mod = "m2"; Var = "ILLARI_M2_IMAGE"; Default = "illari-m2:local" },
        @{ Mod = "m3"; Var = "ILLARI_M3_IMAGE"; Default = "illari-m3:local" },
        @{ Mod = "ui"; Var = "ILLARI_UI_IMAGE"; Default = "illari-ui:local"  }
    )
    $faltantes = @()
    foreach ($m in $modImagenes) {
        $envItem = Get-Item "env:$($m.Var)" -ErrorAction SilentlyContinue
        $imagen  = if ($envItem) { $envItem.Value } else { $m.Default }
        docker image inspect $imagen 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { $faltantes += $m.Mod }
    }
    if ($faltantes.Count -gt 0) {
        Write-Host ""
        Write-Host "ERROR: imágenes faltantes en Docker local:" -ForegroundColor Red
        foreach ($mod in $faltantes) { Write-Host "  illari-${mod}:local" -ForegroundColor Yellow }
        Write-Host ""
        Write-Host "Construye con:"
        Write-Host "  .\scripts\build-imagenes.ps1 -Modulo $($faltantes -join ', ')"
        Write-Host ""
        exit 1
    }
}

& $illariScript -Cmd $Cmd -ClienteDir $repoRaiz -UiPort $UiPort
exit $LASTEXITCODE
