<#
.SYNOPSIS
    Pipeline E2E chat: levanta MK + MV + MA + M2 via docker compose, valida con pytest local.

.DESCRIPTION
    Tres fases:
      1. Pre-flight: verifica que las imagenes locales existen.
      2. Levantar MK + MV + MA + M2 via docker compose (en background).
         Espera hasta que MV y M2 respondan /health.
      3. Local: pytest valida consultas RAG contra los servicios reales.

    Prerrequisito: datos/qdrant_mv/ debe existir (correr run_e2e_ingesta.ps1 primero).

.PARAMETER Suite
    Ruta relativa al YAML de suite. Default: tests/e2e_chat.yaml

.EXAMPLE
    $env:MASTER_SECRET = "<secreto>"
    .\scripts\run_e2e_chat.ps1
    .\scripts\run_e2e_chat.ps1 -Suite tests/e2e_chat.yaml
#>

param(
    [string]$Suite = "tests/e2e_chat.yaml"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding          = [System.Text.Encoding]::UTF8

$composeFile = "docker-compose.chat.yml"
$repoRaiz    = Split-Path -Parent $PSScriptRoot
$suiteAbs    = Join-Path $repoRaiz $Suite
$illariTests = Join-Path (Split-Path -Parent $repoRaiz) "Illari\tests"
$testSuite   = Join-Path $illariTests "e2e_chat\test_suite.py"
$composeAbs  = Join-Path $repoRaiz $composeFile

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
if (-not (Test-Path (Join-Path $repoRaiz "datos\qdrant_mv"))) {
    Write-Error "datos/qdrant_mv/ no encontrado.`nEjecuta run_e2e_ingesta.ps1 primero para poblar la BDV."
    exit 1
}
if (-not (Test-Path $composeAbs)) {
    Write-Error "$composeFile no encontrado en $repoRaiz"
    exit 1
}
if (-not (Test-Path $testSuite)) {
    Write-Error "test_suite.py no encontrado en $testSuite`nVerifica que el repo Illari este en $(Split-Path -Parent $repoRaiz)\Illari"
    exit 1
}

# -- Archivo de resultado ----------------------------------------------------
$ts      = Get-Date -Format "yyyyMMdd-HHmmss"
$outDir  = Join-Path $repoRaiz "tests\results"
$outFile = Join-Path $outDir "e2e_chat-$ts.txt"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
New-Item -ItemType File -Force -Path $outFile | Out-Null

# -- Fase 1: pre-flight (verificar imagenes locales) -------------------------
$modRequeridos = @(
    @{ Mod = "mk"; Var = "ILLARI_MK_IMAGE"; Default = "illari-mk:local" },
    @{ Mod = "mv"; Var = "ILLARI_MV_IMAGE"; Default = "illari-mv:local" },
    @{ Mod = "ma"; Var = "ILLARI_MA_IMAGE"; Default = "illari-ma:0.1.1" },
    @{ Mod = "m2"; Var = "ILLARI_M2_IMAGE"; Default = "illari-m2:0.1.1" }
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
Write-Host "=== Illari E2E chat -- minera ==="
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
Write-Host "  OK: illari-mk:local, illari-mv:local, illari-ma:local, illari-m2:local"
Write-Host ""

# -- Fase 2: levantar servicios en background --------------------------------
Write-Host "[2/3] Levantando servicios MK -> MV -> MA + M2..."
Write-Host ""

try { docker compose -f $composeAbs down --remove-orphans 2>$null | Out-Null } catch { }

docker compose -f $composeAbs up -d |
    Tee-Object -FilePath $outFile -Append

# Esperar MV healthy (modelo fastembed desde cache)
Write-Host ""
Write-Host "  Esperando mv-api en http://localhost:8002/health..."
$mvOk = $false
for ($i = 1; $i -le 24; $i++) {
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:8002/health" -UseBasicParsing -TimeoutSec 3
        if ($r.StatusCode -eq 200) {
            Write-Host "  mv-api listo (intento $i/24)"
            $mvOk = $true
            break
        }
    } catch { }
    Write-Host "  Intento $i/24 -- esperando 5s..."
    Start-Sleep -Seconds 5
}
if (-not $mvOk) {
    Write-Host ""
    Write-Host "FAILED: mv-api no respondio healthy en 120s." -ForegroundColor Red
    docker compose -f $composeAbs logs mv-api --tail=30 2>&1 | Write-Host
    try { docker compose -f $composeAbs down --remove-orphans 2>$null | Out-Null } catch { }
    exit 1
}

# Esperar M2 healthy
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
    docker compose -f $composeAbs logs --tail=30 2>&1 | Write-Host
    try { docker compose -f $composeAbs down --remove-orphans 2>$null | Out-Null } catch { }
    exit 1
}
Write-Host ""

# -- Fase 3: pytest local ----------------------------------------------------
Write-Host "[3/3] Ejecutando pytest E2E chat..."
Write-Host ""

$env:ILLARI_E2E_SUITE   = $suiteAbs
$env:ILLARI_E2E_CLIENTE = $repoRaiz
$env:ILLARI_E2E_M2_URL  = "http://localhost:8000"
$env:ILLARI_E2E_MA_URL  = "http://localhost:8001"

python -m pytest $testSuite -v -s -m e2e `
    --rootdir=(Join-Path $illariTests "..") |
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
