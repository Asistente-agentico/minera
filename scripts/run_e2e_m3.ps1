<#
.SYNOPSIS
    Pipeline E2E reportes M3: levanta MA+M3 via docker compose, valida con pytest local.

.DESCRIPTION
    Tres fases:
      1. docker compose pull.
      2. Levantar MA + M3 via docker compose (en background).
         Espera hasta que M3 responda /health en localhost:8004.
      3. Local: pytest valida reportes estructurados contra el servicio real.

    Prerrequisito: datos/minera.duckdb presente (dbt seed && dbt run).
    No requiere MASTER_SECRET (M3 no usa MV ni Qdrant).

.PARAMETER Suite
    Ruta relativa al YAML de suite. Default: tests/e2e_m3_reportes.yaml

.PARAMETER Tag
    Tag de imagen Docker. Default: dev-0.7.2 (o $env:ILLARI_TAG si está definido)

.EXAMPLE
    .\scripts\run_e2e_m3.ps1
    .\scripts\run_e2e_m3.ps1 -Suite tests/e2e_m3_reportes.yaml
#>

param(
    [string]$Suite = "tests/e2e_m3_reportes.yaml",
    [string]$Tag   = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding          = [System.Text.Encoding]::UTF8

$illariTag   = if ($Tag) { $Tag } elseif ($env:ILLARI_TAG) { $env:ILLARI_TAG } else { "dev-0.7.2" }
$composeFile = "docker-compose.m3.yml"

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
$outFile = Join-Path $outDir "e2e_m3-$ts.txt"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
New-Item -ItemType File -Force -Path $outFile | Out-Null

Write-Host ""
Write-Host "=== Illari E2E M3 (reportes) -- minera ==="
Write-Host "Suite  : $suiteAbs"
Write-Host "Imagen : ghcr.io/asistente-agentico/illari:$illariTag"
Write-Host "Output : $outFile"
Write-Host ""

$env:ILLARI_TAG = $illariTag

# -- Fase 1: docker compose pull --------------------------------------------
Write-Host "[1/3] Descargando imagen Docker..."
docker compose -f $composeAbs pull
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host ""

# -- Fase 2: levantar servicios en background -------------------------------
Write-Host "[2/3] Levantando servicios MA + M3..."
Write-Host ""

docker compose -f $composeAbs down --remove-orphans 2>$null | Out-Null

docker compose -f $composeAbs up -d |
    Tee-Object -FilePath $outFile -Append

# Esperar M3 healthy (máximo 90 segundos)
Write-Host ""
Write-Host "  Esperando M3 en http://localhost:8004/health..."
$m3Ok = $false
for ($i = 1; $i -le 18; $i++) {
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:8004/health" -UseBasicParsing -TimeoutSec 3
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
    docker compose -f $composeAbs down --remove-orphans 2>$null | Out-Null
    exit 1
}
Write-Host ""

# -- Fase 3: pytest local ---------------------------------------------------
Write-Host "[3/3] Ejecutando pytest E2E M3..."
Write-Host ""

$env:ILLARI_E2E_M3      = $suiteAbs
$env:ILLARI_E2E_CLIENTE = $repoRaiz
$env:ILLARI_E2E_M3_URL  = "http://localhost:8004"
$env:ILLARI_E2E_MA_URL  = "http://localhost:8001"

python -m pytest (Join-Path $illariTests "e2e_m3") -v -m e2e `
    --rootdir=(Join-Path $illariTests "..") |
    Tee-Object -FilePath $outFile -Append
$pytestExit = $LASTEXITCODE

docker compose -f $composeAbs down --remove-orphans 2>$null | Out-Null

Write-Host ""
if ($pytestExit -eq 0) {
    Write-Host "PASSED -- resultado guardado en: $outFile" -ForegroundColor Green
} else {
    Write-Host "FAILED (exit $pytestExit) -- resultado guardado en: $outFile" -ForegroundColor Red
}

exit $pytestExit
