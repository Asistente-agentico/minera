<#
.SYNOPSIS
    Ejecuta el pipeline M1 en Docker y valida la salida con pytest.

.DESCRIPTION
    Tres fases:
      1. Borrar qdrant_data/ (partida limpia).
      2. Docker: ejecutar M1 CLI (dbt → chunker → chunks_generados_dev.json).
         MV no se inicia (mk/ pendiente de integración en imagen).
      3. Local: pytest valida chunks_generados_dev.json contra e2e_escritura.yaml.

    Nota: MASTER_SECRET no es necesario. M1 envía chunks en texto plano a MV;
    el cifrado lo hace MV.

.PARAMETER Suite
    Ruta al archivo YAML de la suite. Por defecto: tests/e2e_escritura.yaml

.PARAMETER Imagen
    Imagen Docker del producto. Por defecto: ghcr.io/asistente-agentico/illari:dev-0.7.0

.EXAMPLE
    .\scripts\run_e2e_escritura.ps1
    .\scripts\run_e2e_escritura.ps1 -Suite tests/e2e_escritura.yaml
#>

param(
    [string]$Suite  = "tests/e2e_escritura.yaml",
    [string]$Imagen = "ghcr.io/asistente-agentico/illari:dev-0.7.0"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -- Rutas ------------------------------------------------------------------
$repoRaiz    = Split-Path -Parent $PSScriptRoot
$suiteAbs    = Join-Path $repoRaiz $Suite
$illariTests = Join-Path (Split-Path -Parent $repoRaiz) "Illari\tests"
$testPipeline = Join-Path $illariTests "e2e_escritura\test_pipeline.py"

# -- Validaciones previas ---------------------------------------------------
if (-not (Test-Path $suiteAbs)) {
    Write-Error "Suite no encontrada: $suiteAbs"
    exit 1
}

$duckdb = Join-Path $repoRaiz "datos\minera.duckdb"
if (-not (Test-Path $duckdb)) {
    Write-Error "datos/minera.duckdb no encontrado. Ejecuta 'dbt seed' y 'dbt run' primero."
    exit 1
}

if (-not (Test-Path $testPipeline)) {
    Write-Error "test_pipeline.py no encontrado en $testPipeline`nVerifica que el repo Illari esté en $(Split-Path -Parent $repoRaiz)\Illari"
    exit 1
}

# -- Nombre del archivo de resultado ----------------------------------------
$ts      = Get-Date -Format "yyyyMMdd-HHmmss"
$outDir  = Join-Path $repoRaiz "tests\results"
$outFile = Join-Path $outDir "e2e_escritura-$ts.txt"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

Write-Host ""
Write-Host "=== Illari E2E escritura — minera ==="
Write-Host "Suite  : $suiteAbs"
Write-Host "Imagen : $Imagen"
Write-Host "Output : $outFile"
Write-Host ""

# -- Fase 1: limpiar qdrant_data/ -------------------------------------------
Write-Host "[1/3] Limpiando qdrant_data/..."
$qdrantDir = Join-Path $repoRaiz "qdrant_data"
if (Test-Path $qdrantDir) {
    Remove-Item -Recurse -Force $qdrantDir
    Write-Host "  Eliminado: $qdrantDir"
} else {
    Write-Host "  qdrant_data/ no existe, nada que limpiar."
}
Write-Host ""

# -- Fase 2: Docker — pipeline M1 -------------------------------------------
Write-Host "[2/3] Ejecutando pipeline M1 en Docker..."
Write-Host "  (MV no iniciado — mk/ no está en la imagen; MV se integra en próxima versión)"
Write-Host ""

$pipelineCmd = @"
pip install fastembed -q 2>/dev/null
export MINERA_DB_PATH=/cliente/minera/datos/minera.duckdb
python -m m1.core.orquestador.cli ejecutar \
    --dev \
    --config /cliente/minera/configuracion \
    --schemas /app/configuracion/schemas \
    --medallon /cliente/minera/modelos \
    --profiles-dir /cliente/minera/modelos \
    --raiz /cliente/minera
"@

New-Item -ItemType File -Force -Path $outFile | Out-Null

docker pull $Imagen

docker run --rm `
    -v "${repoRaiz}:/cliente/minera" `
    -e "MINERA_DB_PATH=/cliente/minera/datos/minera.duckdb" `
    --entrypoint sh `
    $Imagen `
    -c $pipelineCmd `
    | ForEach-Object { $_; $_ | Out-File -FilePath $outFile -Encoding UTF8 -Append }

$dockerExit = $LASTEXITCODE

if ($dockerExit -ne 0) {
    Write-Host ""
    Write-Host "FAILED pipeline Docker (exit $dockerExit) — ver: $outFile" -ForegroundColor Red
    exit $dockerExit
}

$chunksJson = Join-Path $repoRaiz "datos\chunks_generados_dev.json"
if (-not (Test-Path $chunksJson)) {
    Write-Host ""
    Write-Host "FAILED: chunks_generados_dev.json no fue generado por el pipeline." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "  Pipeline completado. chunks_generados_dev.json generado."
Write-Host ""

# -- Fase 3: pytest local ---------------------------------------------------
Write-Host "[3/3] Validando chunks_generados_dev.json con pytest..."
Write-Host ""

$env:ILLARI_E2E_ESCRITURA = $suiteAbs
$env:ILLARI_E2E_RAIZ      = $repoRaiz

python -m pytest $testPipeline -v -m e2e `
    --rootdir=(Join-Path $illariTests "..") `
    | ForEach-Object { $_; $_ | Out-File -FilePath $outFile -Encoding UTF8 -Append }

$pytestExit = $LASTEXITCODE

Write-Host ""
if ($pytestExit -eq 0) {
    Write-Host "PASSED — resultado guardado en: $outFile" -ForegroundColor Green
} else {
    Write-Host "FAILED (exit $pytestExit) — resultado guardado en: $outFile" -ForegroundColor Red
}

exit $pytestExit
