<#
.SYNOPSIS
    Pipeline E2E ingesta: MK+MV+M1 via docker compose, valida con pytest local.

.DESCRIPTION
    Tres fases:
      1. docker compose pull.
      2. Limpiar datos/qdrant_mv/ y levantar MK + MV + M1 via docker compose.
         MK sirve las claves KEK a MV. MV cifra y persiste chunks en Qdrant.
         M1 escribe chunks_generados_dev.json (--dev) y envía a MV.
      3. Local: pytest valida chunks_generados_dev.json contra e2e_ingesta.yaml.

.PARAMETER Suite
    Ruta relativa al YAML de suite. Default: tests/e2e_ingesta.yaml

.PARAMETER Tag
    Tag de imagen del registro. Default: dev-0.7.1 (o $env:ILLARI_TAG si está definido).
    Ignorado si se define -Image o $env:ILLARI_IMAGE.

.PARAMETER Image
    Nombre completo de imagen local (override). P.ej. "asistente-virtual:local".
    Si se define, omite el pull y usa esa imagen directamente.
    También se puede pasar via $env:ILLARI_IMAGE.

.EXAMPLE
    $env:MASTER_SECRET = "<secreto>"
    .\scripts\run_e2e_ingesta.ps1
    .\scripts\run_e2e_ingesta.ps1 -Suite tests/e2e_ingesta.yaml
    .\scripts\run_e2e_ingesta.ps1 -Image asistente-virtual:local
#>

param(
    [string]$Suite = "tests/e2e_ingesta.yaml",
    [string]$Tag   = "",
    [string]$Image = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding          = [System.Text.Encoding]::UTF8

$illariTag   = if ($Tag) { $Tag } elseif ($env:ILLARI_TAG) { $env:ILLARI_TAG } else { "dev-0.7.1" }
$composeFile = "docker-compose.ingesta.yml"

# ILLARI_IMAGE permite usar imagen construida localmente (omite pull).
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

$repoRaiz     = Split-Path -Parent $PSScriptRoot
$suiteAbs     = Join-Path $repoRaiz $Suite
$illariTests  = Join-Path (Split-Path -Parent $repoRaiz) "Illari\tests"
$testPipeline = Join-Path $illariTests "e2e_escritura\test_pipeline.py"
$composeAbs   = Join-Path $repoRaiz $composeFile

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
if (-not (Test-Path $composeAbs)) {
    Write-Error "$composeFile no encontrado en $repoRaiz"
    exit 1
}
if (-not (Test-Path $testPipeline)) {
    Write-Error "test_pipeline.py no encontrado en $testPipeline`nVerifica que el repo Illari esté en $(Split-Path -Parent $repoRaiz)\Illari"
    exit 1
}

# -- Archivo de resultado ---------------------------------------------------
$ts      = Get-Date -Format "yyyyMMdd-HHmmss"
$outDir  = Join-Path $repoRaiz "tests\results"
$outFile = Join-Path $outDir "e2e_ingesta-$ts.txt"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
New-Item -ItemType File -Force -Path $outFile | Out-Null

Write-Host ""
Write-Host "=== Illari E2E ingesta -- minera ==="
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

# -- Fase 2: limpiar BDV y ejecutar pipeline --------------------------------
Write-Host "[2/3] Ejecutando pipeline MK -> MV -> M1 via docker compose..."
Write-Host ""

$qdrantDir = Join-Path $repoRaiz "datos\qdrant_mv"
Write-Host "  Limpiando $qdrantDir..."
if (Test-Path $qdrantDir) {
    Remove-Item -Recurse -Force $qdrantDir
    Write-Host "  Eliminado: $qdrantDir"
} else {
    Write-Host "  datos/qdrant_mv/ no existe, nada que limpiar."
}
Write-Host ""

docker compose -f $composeAbs up --abort-on-container-exit --exit-code-from m1 |
    Tee-Object -FilePath $outFile -Append
$composeExit = $LASTEXITCODE

docker compose -f $composeAbs down --remove-orphans 2>$null | Out-Null

if ($composeExit -ne 0) {
    Write-Host ""
    Write-Host "FAILED pipeline docker compose (exit $composeExit) -- ver: $outFile" -ForegroundColor Red
    exit $composeExit
}

$chunksJson = Join-Path $repoRaiz "datos\chunks_generados_dev.json"
if (-not (Test-Path $chunksJson)) {
    Write-Host ""
    Write-Host "FAILED: chunks_generados_dev.json no fue generado por el pipeline." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "  Pipeline completado. chunks_generados_dev.json generado y chunks en BDV."
Write-Host ""

# -- Fase 3: pytest local ---------------------------------------------------
Write-Host "[3/3] Validando chunks_generados_dev.json con pytest..."
Write-Host ""

$env:ILLARI_E2E_INGESTA = $suiteAbs
$env:ILLARI_E2E_RAIZ      = $repoRaiz

python -m pytest $testPipeline -v -m e2e `
    --rootdir=(Join-Path $illariTests "..") |
    Tee-Object -FilePath $outFile -Append
$pytestExit = $LASTEXITCODE

Write-Host ""
if ($pytestExit -eq 0) {
    Write-Host "PASSED -- resultado guardado en: $outFile" -ForegroundColor Green
} else {
    Write-Host "FAILED (exit $pytestExit) -- resultado guardado en: $outFile" -ForegroundColor Red
}

exit $pytestExit
