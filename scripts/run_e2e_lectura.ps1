<#
.SYNOPSIS
    Pipeline E2E lectura: levanta MK+MV+MA+M2 via docker compose, valida con pytest local.

.DESCRIPTION
    Tres fases:
      1. docker compose pull.
      2. Levantar MK + MV + MA + M2 via docker compose (en background).
         Espera hasta que M2 responda /health en localhost:8000.
      3. Local: pytest valida consultas RAG contra los servicios reales.

    Prerrequisito: datos/qdrant_mv/ debe existir (correr run_e2e_escritura.ps1 primero).

.PARAMETER Suite
    Ruta relativa al YAML de suite. Default: tests/e2e_lectura.yaml

.PARAMETER Tag
    Tag de imagen Docker. Default: dev-0.7.1 (o $env:ILLARI_TAG si está definido)

.EXAMPLE
    $env:MASTER_SECRET = "<secreto>"
    .\scripts\run_e2e_lectura.ps1
    .\scripts\run_e2e_lectura.ps1 -Suite tests/e2e_lectura.yaml
#>

param(
    [string]$Suite = "tests/e2e_lectura.yaml",
    [string]$Tag   = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding          = [System.Text.Encoding]::UTF8

$illariTag   = if ($Tag) { $Tag } elseif ($env:ILLARI_TAG) { $env:ILLARI_TAG } else { "dev-0.7.1" }
$composeFile = "docker-compose.lectura.yml"

$repoRaiz    = Split-Path -Parent $PSScriptRoot
$suiteAbs    = Join-Path $repoRaiz $Suite
$illariTests = Join-Path (Split-Path -Parent $repoRaiz) "Illari\tests"
$composeAbs  = Join-Path $repoRaiz $composeFile

# -- Leer MASTER_SECRET (env > .env > error) --------------------------------
if (-not $env:MASTER_SECRET) {
    $envFile = Join-Path $repoRaiz ".env"
    if (Test-Path $envFile) {
        $m = Select-String -Path $envFile -Pattern '^\s*(?:export\s+)?MASTER_SECRET\s*=\s*(.+)$'
        if ($m) {
            $env:MASTER_SECRET = $m.Matches[0].Groups[1].Value.Trim().Trim('"').Trim("'")
        }
    }
}
if (-not $env:MASTER_SECRET) {
    Write-Error "MASTER_SECRET no definido. Defínelo en `$env:MASTER_SECRET o en el archivo .env."
    exit 1
}

# -- Validaciones previas ---------------------------------------------------
if (-not (Test-Path $suiteAbs)) {
    Write-Error "Suite no encontrada: $suiteAbs"
    exit 1
}
if (-not (Test-Path (Join-Path $repoRaiz "datos\qdrant_mv"))) {
    Write-Error "datos/qdrant_mv/ no encontrado.`nEjecuta run_e2e_escritura.ps1 primero para poblar la BDV."
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
$outFile = Join-Path $outDir "e2e_lectura-$ts.txt"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
New-Item -ItemType File -Force -Path $outFile | Out-Null

Write-Host ""
Write-Host "=== Illari E2E lectura -- minera ==="
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
Write-Host "[2/3] Levantando servicios MK -> MV -> MA + M2..."
Write-Host ""

docker compose -f $composeAbs up -d |
    Tee-Object -FilePath $outFile -Append

# Esperar M2 healthy (máximo 120 segundos)
Write-Host ""
Write-Host "  Esperando M2 en http://localhost:8000/health..."
$m2Ok = $false
for ($i = 1; $i -le 24; $i++) {
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:8000/health" -UseBasicParsing -TimeoutSec 3
        if ($r.StatusCode -eq 200) {
            Write-Host "  M2 listo (intento $i/24)"
            $m2Ok = $true
            break
        }
    } catch { }
    Write-Host "  Intento $i/24 -- esperando 5s..."
    Start-Sleep -Seconds 5
}

if (-not $m2Ok) {
    Write-Host ""
    Write-Host "FAILED: M2 no respondio healthy en 120s." -ForegroundColor Red
    Write-Host "--- Logs de servicios ---"
    docker compose -f $composeAbs logs --tail=30 2>&1 | Write-Host
    docker compose -f $composeAbs down --remove-orphans 2>$null | Out-Null
    exit 1
}
Write-Host ""

# -- Fase 3: pytest local ---------------------------------------------------
Write-Host "[3/3] Ejecutando pytest E2E lectura..."
Write-Host ""

$env:ILLARI_E2E_SUITE   = $suiteAbs
$env:ILLARI_E2E_CLIENTE = $repoRaiz
$env:ILLARI_E2E_M2_URL  = "http://localhost:8000"
$env:ILLARI_E2E_MA_URL  = "http://localhost:8001"

python -m pytest (Join-Path $illariTests "e2e") -v -m e2e `
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
