<#
.SYNOPSIS
    Pipeline E2E ingesta: MK + MV + M1 via docker compose, valida con pytest local.

.DESCRIPTION
    Tres fases:
      1. Pre-flight: verifica que las imagenes locales existen.
      2. Limpiar datos/qdrant_mv/ y levantar MK + MV + M1 via docker compose.
         MK sirve las claves KEK a MV. MV cifra y persiste chunks en Qdrant.
         M1 escribe chunks_generados_dev.json (--dev) y envia a MV.
      3. Local: pytest valida chunks_generados_dev.json contra e2e_ingesta.yaml.

.PARAMETER Suite
    Ruta relativa al YAML de suite. Default: tests/e2e_ingesta.yaml

.EXAMPLE
    $env:MASTER_SECRET = "<secreto>"
    .\scripts\run_e2e_ingesta.ps1
    .\scripts\run_e2e_ingesta.ps1 -Suite tests/e2e_ingesta.yaml
#>

param(
    [string]$Suite = "tests/e2e_ingesta.yaml"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding          = [System.Text.Encoding]::UTF8

$composeFile = "docker-compose.ingesta.yml"
$repoRaiz    = Split-Path -Parent $PSScriptRoot
$suiteAbs    = Join-Path $repoRaiz $Suite
$illariTests  = Join-Path (Split-Path -Parent $repoRaiz) "Illari\tests"
$testPipeline = Join-Path $illariTests "e2e_escritura\test_pipeline.py"
$composeAbs   = Join-Path $repoRaiz $composeFile

# -- Leer MASTER_SECRET (env > .env > error) ---------------------------------
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
    Write-Error "MASTER_SECRET no definido. Definelo en `$env:MASTER_SECRET o en el archivo .env."
    exit 1
}

# -- Validaciones previas ----------------------------------------------------
if (-not (Test-Path $suiteAbs)) {
    Write-Error "Suite no encontrada: $suiteAbs"
    exit 1
}
if (-not (Test-Path $composeAbs)) {
    Write-Error "$composeFile no encontrado en $repoRaiz"
    exit 1
}
if (-not (Test-Path $testPipeline)) {
    Write-Error "test_pipeline.py no encontrado en $testPipeline`nVerifica que el repo Illari este en $(Split-Path -Parent $repoRaiz)\Illari"
    exit 1
}

# -- Archivo de resultado ----------------------------------------------------
$ts      = Get-Date -Format "yyyyMMdd-HHmmss"
$outDir  = Join-Path $repoRaiz "tests\results"
$outFile = Join-Path $outDir "e2e_ingesta-$ts.txt"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
New-Item -ItemType File -Force -Path $outFile | Out-Null

# -- Fase 1: pre-flight (verificar imagenes locales) -------------------------
$modRequeridos = @(
    @{ Mod = "mk"; Var = "ILLARI_MK_IMAGE"; Default = "illari-mk:local" },
    @{ Mod = "mv"; Var = "ILLARI_MV_IMAGE"; Default = "illari-mv:local" },
    @{ Mod = "m1"; Var = "ILLARI_M1_IMAGE"; Default = "illari-m1:local" }
)
$faltantes = @()
$imagenesResueltas = @{}
foreach ($m in $modRequeridos) {
    $envItem = Get-Item "env:$($m.Var)" -ErrorAction SilentlyContinue
    $imagen  = if ($envItem) { $envItem.Value } else { $m.Default }
    $imagenesResueltas[$m.Mod] = $imagen
    docker image inspect $imagen 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { $faltantes += $m.Mod }
}

Write-Host ""
Write-Host "=== Illari E2E ingesta -- minera ==="
Write-Host "Suite  : $suiteAbs"
Write-Host "Imagenes:"
foreach ($mod in $modRequeridos) {
    Write-Host "  $($mod.Mod): $($imagenesResueltas[$mod.Mod])"
}
Write-Host "Output : $outFile"
Write-Host ""

Write-Host "[1/3] Verificando imagenes locales..."
if ($faltantes.Count -gt 0) {
    Write-Host ""
    Write-Host "ERROR: imagenes faltantes en Docker local:" -ForegroundColor Red
    foreach ($mod in $faltantes) { Write-Host "  illari-${mod}:local" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "Construye con:"
    Write-Host "  .\scripts\build-imagenes.ps1 -Modulo $($faltantes -join ', ')"
    Write-Host ""
    exit 1
}
Write-Host "  OK: illari-mk:local, illari-mv:local, illari-m1:local"
Write-Host ""

# -- Fase 2: limpiar BDV y ejecutar pipeline ---------------------------------
Write-Host "[2/3] Ejecutando pipeline MK -> MV -> M1 via docker compose..."
Write-Host ""

$qdrantDir = Join-Path $repoRaiz "datos\qdrant_mv"

# Snapshot pre-pipeline ANTES del wipe: captura conteos de tablas del
# medallon y chunk_ids de la BDV de la corrida anterior. Permite al
# reporte final distinguir "nuevos" vs "reemplazos" y mostrar deltas.
$preSnapshot = Join-Path $outDir "snapshot-pre-$ts.json"
Write-Host "  Capturando snapshot pre-pipeline en $preSnapshot..."
python (Join-Path $repoRaiz "scripts\reportar_ingesta.py") snapshot `
    --raiz $repoRaiz --salida $preSnapshot
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ADVERTENCIA: snapshot pre fallo (exit $LASTEXITCODE); reporte mostrara antes=0." -ForegroundColor Yellow
}

Write-Host "  Limpiando $qdrantDir y volumen Docker..."
if (Test-Path $qdrantDir) {
    Remove-Item -Recurse -Force $qdrantDir
    Write-Host "  Eliminado: $qdrantDir"
} else {
    Write-Host "  datos/qdrant_mv/ no existe, nada que limpiar."
}
try { docker compose -f $composeAbs down --volumes --remove-orphans 2>$null | Out-Null } catch { }
Write-Host ""

# Levantar mk + qdrant-init + mv en background. Usar `up -d` (no
# `--abort-on-container-exit`) porque qdrant-init es un init container
# que termina con exit 0 inmediatamente; `--abort-on-container-exit` lo
# interpreta como senal para matar todo (incluyendo mk con SIGKILL 137).
# m1 se ejecuta despues como oneshot via `compose run`, paralelo a .sh.
docker compose -f $composeAbs up -d mk qdrant-init mv |
    Tee-Object -FilePath $outFile -Append
if ($LASTEXITCODE -ne 0) {
    Write-Host "FAILED: docker compose up -d mk qdrant-init mv exit $LASTEXITCODE" -ForegroundColor Red
    try { docker compose -f $composeAbs down --volumes --remove-orphans 2>$null | Out-Null } catch { }
    exit $LASTEXITCODE
}

Write-Host "  Esperando que MV este healthy..."
$mvOk = $false
for ($i = 1; $i -le 24; $i++) {
    Start-Sleep -Seconds 5
    $mvId = docker compose -f $composeAbs ps -q mv 2>$null
    if ($mvId) {
        $status = docker inspect $mvId --format '{{.State.Health.Status}}' 2>$null
        if ($status -eq "healthy") {
            Write-Host "  MV healthy (intento $i/24)"
            $mvOk = $true
            break
        }
    }
}
if (-not $mvOk) {
    Write-Host "FAILED: MV no llego a healthy en 120s" -ForegroundColor Red
    docker compose -f $composeAbs logs mv --tail=30 | Tee-Object -FilePath $outFile -Append
    try { docker compose -f $composeAbs down --volumes --remove-orphans 2>$null | Out-Null } catch { }
    exit 1
}
Write-Host ""

# Ejecutar m1 como oneshot. `run --rm --no-deps -T` no toca los servicios
# en background; el exit code de m1 es el del comando.
docker compose -f $composeAbs run --rm --no-deps -T m1 |
    Tee-Object -FilePath $outFile -Append
$composeExit = $LASTEXITCODE

# Copia Qdrant del volumen nombrado al host via contenedor temporal Alpine.
# docker cp desde contenedor parado no accede volumenes nombrados (solo capas de imagen).
# El volumen minera_qdrant_mv sigue existiendo hasta que se llame down --volumes.
Write-Host "  Copiando BDV Qdrant del volumen Docker al host..."
New-Item -ItemType Directory -Force -Path $qdrantDir | Out-Null
docker run --rm -v "minera_qdrant_mv:/source:ro" -v "${qdrantDir}:/dest" alpine sh -c "cp -r /source/. /dest/"
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ADVERTENCIA: copia de BDV Qdrant fallo (exit $LASTEXITCODE)." -ForegroundColor Yellow
}

try { docker compose -f $composeAbs down --volumes --remove-orphans 2>$null | Out-Null } catch { }

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

# Reporte de metricas: tablas del medallon (antes/ahora/delta), chunks
# por regla y cambios en la BDV (nuevos/reemplazos/finales). Sale a stdout
# y a $outFile via Tee-Object.
$env:PYTHONUNBUFFERED = "1"
python (Join-Path $repoRaiz "scripts\reportar_ingesta.py") reporte `
    --raiz $repoRaiz --pre $preSnapshot |
    Tee-Object -FilePath $outFile -Append

# -- Fase 3: pytest local ----------------------------------------------------
Write-Host "[3/3] Validando chunks_generados_dev.json con pytest..."
Write-Host ""

$env:ILLARI_E2E_ESCRITURA = $suiteAbs
$env:ILLARI_E2E_RAIZ      = $repoRaiz
$env:PYTHONUNBUFFERED     = "1"

# `Split-Path -Parent` resuelve a Illari/ sin componentes `..`. Si se pasa
# `--rootdir=Illari\tests\..` (sin resolver), pytest 9.x trata el path
# explicito de forma distinta y termina coleccionando todo el repo en lugar
# de solo el archivo dado.
$illariRaiz = Split-Path -Parent $illariTests
python -m pytest $testPipeline -v -m e2e `
    --rootdir=$illariRaiz |
    Tee-Object -FilePath $outFile -Append
$pytestExit = $LASTEXITCODE

Write-Host ""
if ($pytestExit -eq 0) {
    Write-Host "PASSED -- resultado guardado en: $outFile" -ForegroundColor Green
} else {
    Write-Host "FAILED (exit $pytestExit) -- resultado guardado en: $outFile" -ForegroundColor Red
}

exit $pytestExit
