<#
.SYNOPSIS
    Ejecuta la suite E2E del cliente minera y guarda el resultado en un archivo.

.DESCRIPTION
    Lee el YAML de la suite indicada, extrae nombre y version, construye el
    nombre del archivo de resultado y lanza pytest dentro de la imagen Docker
    del producto. El resultado queda en tests/results/ del repo minera.

    Modo normal : solo resumen PASS/FAIL por escenario.
    Modo dev (-Dev): imprime chunks recuperados, scores, plantas y texto de
    respuesta para cada escenario. Nombre de archivo incluye sufijo "-dev".

.PARAMETER Suite
    Ruta al archivo YAML de la suite. Por defecto: tests/e2e.yaml

.PARAMETER MasterSecret
    MASTER_SECRET usado al indexar los chunks. Si no se pasa, se lee de la
    variable de entorno MASTER_SECRET.

.PARAMETER Imagen
    Imagen Docker del producto. Por defecto: ghcr.io/asistente-agentico/illari:dev-0.6.2

.PARAMETER Dev
    Activa modo verbose: imprime detalle de chunks y respuestas por escenario.

.EXAMPLE
    .\scripts\run_e2e.ps1
    .\scripts\run_e2e.ps1 -Dev
    .\scripts\run_e2e.ps1 -Suite tests/e2e.yaml -MasterSecret "abc123..." -Dev
#>

param(
    [string]$Suite        = "tests/e2e.yaml",
    [string]$MasterSecret = $env:MASTER_SECRET,
    [string]$Imagen       = "ghcr.io/asistente-agentico/illari:dev-0.6.2",
    [switch]$Dev
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -- Rutas ------------------------------------------------------------------
$repoRaiz = Split-Path -Parent $PSScriptRoot
$suiteAbs = Join-Path $repoRaiz $Suite

if (-not (Test-Path $suiteAbs)) {
    Write-Error "Suite no encontrada: $suiteAbs"
    exit 1
}

if (-not $MasterSecret) {
    Write-Error "MASTER_SECRET no definido. Pasalo con -MasterSecret o como variable de entorno."
    exit 1
}

# -- Leer nombre y version del YAML -----------------------------------------
$suiteName = [IO.Path]::GetFileNameWithoutExtension($suiteAbs)

$versionLine = Get-Content $suiteAbs | Select-String "^\s*version\s*:"
if ($versionLine) {
    $version = ($versionLine.ToString() -replace '^\s*version\s*:\s*["'']?', '') -replace '["'']?\s*$', ''
} else {
    $version = "sin-version"
}

# -- Nombre del archivo de resultado ----------------------------------------
$ts      = Get-Date -Format "yyyyMMdd-HHmmss"
$devSuffix = if ($Dev) { "-dev" } else { "" }
$outName = "$suiteName-v$version$devSuffix-$ts.txt"
$outDir  = Join-Path $repoRaiz "tests\results"
$outFile = Join-Path $outDir $outName

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# -- Rutas dentro del contenedor --------------------------------------------
$raizContenedor    = "/cliente/minera"
$suiteContenedor   = "$raizContenedor/$(($Suite -replace '\\','/'))"
$dominioContenedor = "$raizContenedor/configuracion/dominio.yaml"

# -- Flags pytest y env vars -------------------------------------------------
$pytestFlags = if ($Dev) { "-v -s -m e2e" } else { "-v -m e2e" }
$verboseVal  = if ($Dev) { "1" } else { "0" }

# -- En modo dev: montar tests/ local de Illari para usar version en disco --
# Los dos repos se asumen hermanos: .../Dev/minera  y  .../Dev/Illari
$devMount = @()
if ($Dev) {
    $illariTests = Join-Path (Split-Path -Parent $repoRaiz) "Illari\tests"
    if (Test-Path $illariTests) {
        $devMount = @("-v", "${illariTests}:/app/tests")
        Write-Host "Tests   : $illariTests (montado en /app/tests)"
    } else {
        Write-Host "Tests   : usando tests embebidos en la imagen (Illari no encontrado en $illariTests)"
    }
}

# -- Info previa -------------------------------------------------------------
$modo = if ($Dev) { "dev (verbose)" } else { "normal" }
Write-Host ""
Write-Host "Suite  : $suiteName v$version"
Write-Host "Modo   : $modo"
Write-Host "Imagen : $Imagen"
Write-Host "Output : $outFile"
Write-Host ""

# -- Ejecutar ----------------------------------------------------------------
$cmd = "pip install fastembed -q 2>/dev/null && python -m pytest /app/tests/e2e/ $pytestFlags"

docker run --rm `
    -v "${repoRaiz}:/cliente/minera" `
    @devMount `
    -e "ILLARI_E2E_SUITE=$suiteContenedor" `
    -e "ILLARI_E2E_DOMINIO=$dominioContenedor" `
    -e "MASTER_SECRET=$MasterSecret" `
    -e "ILLARI_E2E_VERBOSE=$verboseVal" `
    -w $raizContenedor `
    --entrypoint sh `
    $Imagen `
    -c $cmd `
    | Tee-Object -FilePath $outFile

$exitCode = $LASTEXITCODE

Write-Host ""
if ($exitCode -eq 0) {
    Write-Host "PASSED - resultado guardado en: $outFile" -ForegroundColor Green
} else {
    Write-Host "FAILED (exit $exitCode) - resultado guardado en: $outFile" -ForegroundColor Red
}

exit $exitCode
