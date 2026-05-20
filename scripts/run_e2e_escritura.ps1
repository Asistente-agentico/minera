<#
.SYNOPSIS
    Pipeline E2E escritura: MK+MV+M1 via docker compose, valida con pytest local.

.DESCRIPTION
    Tres fases:
      1. docker compose pull.
      2. Limpiar datos/qdrant_mv/ y levantar MK + MV + M1 via docker compose.
         MK sirve las claves KEK a MV. MV cifra y persiste chunks en Qdrant.
         M1 escribe chunks_generados_dev.json (--dev) y envía a MV.
      3. Local: pytest valida chunks_generados_dev.json contra e2e_escritura.yaml.

.PARAMETER Suite
    Ruta relativa al YAML de suite. Default: tests/e2e_escritura.yaml

.PARAMETER Tag
    Tag de imagen Docker. Default: dev-0.7.1 (o $env:ILLARI_TAG si está definido)

.EXAMPLE
    $env:MASTER_SECRET = "<secreto>"
    .\scripts\run_e2e_escritura.ps1
    .\scripts\run_e2e_escritura.ps1 -Suite tests/e2e_escritura.yaml
#>

param(
    [string]$Suite = "tests/e2e_escritura.yaml",
    [string]$Tag   = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$illariTag   = if ($Tag) { $Tag } elseif ($env:ILLARI_TAG) { $env:ILLARI_TAG } else { "dev-0.7.1" }
$composeFile = "docker-compose.escritura.yml"

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
$outFile = Join-Path $outDir "e2e_escritura-$ts.txt"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
New-Item -ItemType File -Force -Path $outFile | Out-Null

Write-Host ""
Write-Host "=== Illari E2E escritura -- minera ==="
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

$env:ILLARI_E2E_ESCRITURA = $suiteAbs
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
