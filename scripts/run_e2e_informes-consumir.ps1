<#
.SYNOPSIS
    Pipeline E2E reportes M3: levanta MA+M3 via docker compose, valida con pytest local.

.DESCRIPTION
    Tres fases:
      1. docker compose pull.
      2. Levantar MA + M3 via docker compose (en background).
         Espera hasta que M3 responda /health en localhost:8005.
      3. Local: pytest valida reportes estructurados contra el servicio real.

    Prerrequisito: datos/minera.duckdb presente (dbt seed && dbt run).
    No requiere MASTER_SECRET (M3 no usa MV ni Qdrant).

.PARAMETER Suite
    Ruta relativa al YAML de suite. Default: tests/e2e_informes-consumir.yaml

.PARAMETER Tag
    Tag de imagen del registro. Default: dev-0.7.3 (o $env:ILLARI_TAG si está definido).
    Ignorado si se define -Image o $env:ILLARI_IMAGE.

.PARAMETER Image
    Nombre completo de imagen local (override). P.ej. "asistente-virtual:local".
    Si se define, omite el pull y usa esa imagen directamente.
    También se puede pasar via $env:ILLARI_IMAGE.

.EXAMPLE
    .\scripts\run_e2e_informes-consumir.ps1
    .\scripts\run_e2e_informes-consumir.ps1 -Suite tests/e2e_informes-consumir.yaml
    .\scripts\run_e2e_informes-consumir.ps1 -Image asistente-virtual:local
#>

param(
    [string]$Suite = "tests/e2e_informes-consumir.yaml",
    [string]$Tag   = "",
    [string]$Image = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding          = [System.Text.Encoding]::UTF8

$illariTag   = if ($Tag) { $Tag } elseif ($env:ILLARI_TAG) { $env:ILLARI_TAG } else { "dev-0.7.3" }
$composeFile = "docker-compose.informes-consumir.yml"

# ILLARI_IMAGE permite usar imagen construida localmente (omite pull).
$illariImage = ""
$imagenLocal = $false
if ($Image) {
    $illariImage = $Image
    $imagenLocal = $true
} elseif ($env:ILLARI_IMAGE) {
    $illariImage = $env:ILLARI_IMAGE
    $imagenLocal = $true
} else {
    $envFile2 = Join-Path (Split-Path -Parent $PSScriptRoot) ".env"
    if (Test-Path $envFile2) {
        $m2 = Select-String -Path $envFile2 -Pattern '^\s*(?:export\s+)?ILLARI_IMAGE\s*=\s*(.+)$'
        if ($m2) {
            $illariImage = $m2.Matches[0].Groups[1].Value.Trim().Trim('"').Trim("'")
            $imagenLocal = $true
        }
    }
    if (-not $illariImage) {
        $illariImage = "ghcr.io/asistente-agentico/illari:$illariTag"
    }
}

$repoRaiz    = Split-Path -Parent $PSScriptRoot
$suiteAbs    = Join-Path $repoRaiz $Suite
$illariTests = Join-Path (Split-Path -Parent $repoRaiz) "Illari\tests"
$composeAbs  = Join-Path $repoRaiz $composeFile

# -- Validaciones previas ---------------------------------------------------
if (-not (Test-Path $suiteAbs)) {
    Write-Error "Suite no encontrada: $suiteAbs"
    exit 1
}
if (-not (Test-Path (Join-Path $repoRaiz "datos\minera.duckdb"))) {
    Write-Error "datos/minera.duckdb no encontrado.`nEjecuta 'dbt seed' y 'dbt run' en modelos/ primero."
    exit 1
}
if (-not (Test-Path $composeAbs)) {
    Write-Error "$composeFile no encontrado en $repoRaiz"
    exit 1
}
if (-not (Test-Path $illariTests)) {
    Write-Error "tests/ de Illari no encontrado en $illariTests`nVerifica que el repo Illari esté en $(Split-Path -Parent $repoRaiz)\Illari"
    exit 1
}

# -- Archivo de resultado ---------------------------------------------------
$ts      = Get-Date -Format "yyyyMMdd-HHmmss"
$outDir  = Join-Path $repoRaiz "tests\results"
$outFile = Join-Path $outDir "e2e_informes-consumir-$ts.txt"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
New-Item -ItemType File -Force -Path $outFile | Out-Null

Write-Host ""
Write-Host "=== Illari E2E informes-consumir -- minera ==="
Write-Host "Suite  : $suiteAbs"
Write-Host "Imagen : $illariImage"
Write-Host "Output : $outFile"
Write-Host ""

$env:ILLARI_IMAGE = $illariImage

# -- Fase 1: docker compose pull (omite si imagen es local o ya existe) ----
if ($imagenLocal) {
    Write-Host "[1/3] Imagen local definida (ILLARI_IMAGE) -- omitiendo pull."
} else {
    $imageExists = docker image inspect $illariImage 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[1/3] Imagen $illariImage encontrada localmente -- omitiendo pull."
    } else {
        Write-Host "[1/3] Descargando imagen Docker..."
        docker compose -f $composeAbs pull
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
}
Write-Host ""

# -- Fase 2: levantar servicios en background -------------------------------
Write-Host "[2/3] Levantando servicios MA + M3..."
Write-Host ""

try { docker compose -f $composeAbs down --remove-orphans 2>$null | Out-Null } catch { }

docker compose -f $composeAbs up -d |
    Tee-Object -FilePath $outFile -Append

# Esperar M3 healthy (máximo 90 segundos)
Write-Host ""
Write-Host "  Esperando M3 en http://localhost:8005/health..."
$m3Ok = $false
for ($i = 1; $i -le 18; $i++) {
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:8005/health" -UseBasicParsing -TimeoutSec 3
        if ($r.StatusCode -eq 200) {
            Write-Host "  M3 listo (intento $i/18)"
            $m3Ok = $true
            break
        }
    } catch { }
    Write-Host "  Intento $i/18 -- esperando 5s..."
    Start-Sleep -Seconds 5
}

if (-not $m3Ok) {
    Write-Host ""
    Write-Host "FAILED: M3 no respondio healthy en 90s." -ForegroundColor Red
    Write-Host "--- Logs de servicios ---"
    docker compose -f $composeAbs logs --tail=30 2>&1 | Write-Host
    try { docker compose -f $composeAbs down --remove-orphans 2>$null | Out-Null } catch { }
    exit 1
}
Write-Host ""

# -- Fase 3: pytest local ---------------------------------------------------
Write-Host "[3/3] Ejecutando pytest E2E informes-consumir..."
Write-Host ""

$env:ILLARI_E2E_M3      = $suiteAbs
$env:ILLARI_E2E_CLIENTE = $repoRaiz
$env:ILLARI_E2E_M3_URL  = "http://localhost:8005"
$env:ILLARI_E2E_MA_URL  = "http://localhost:8001"
$env:PYTHONUNBUFFERED   = "1"

# Path resuelto sin `..` (pytest 9.x cambia comportamiento con paths
# `Illari\tests\..`; ver fix en run_e2e_ingesta.ps1).
$illariRaiz = Split-Path -Parent $illariTests
python -m pytest (Join-Path $illariTests "e2e_m3\test_reportes.py") -v -m e2e `
    --rootdir=$illariRaiz |
    Tee-Object -FilePath $outFile -Append
$pytestExit = $LASTEXITCODE

try { docker compose -f $composeAbs down --remove-orphans 2>$null | Out-Null } catch { }

Write-Host ""
if ($pytestExit -eq 0) {
    Write-Host "PASSED -- resultado guardado en: $outFile" -ForegroundColor Green
} else {
    Write-Host "FAILED (exit $pytestExit) -- resultado guardado en: $outFile" -ForegroundColor Red
}

exit $pytestExit
