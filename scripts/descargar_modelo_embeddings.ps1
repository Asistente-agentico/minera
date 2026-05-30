<#
.SYNOPSIS
    Pre-descarga el modelo de embeddings al cache del host.

.DESCRIPTION
    El cache fastembed se monta como volumen :ro en los containers de
    desarrollo (chat.yml / ui.yml) y como :rw en ingesta.yml. Los
    containers exigen que el modelo correcto ya esté en el cache (ver
    lifespan de MV en `mv/api/main.py`). Esta corrida one-shot lo
    pre-descarga al directorio `datos/fastembed_cache/` del host.

    Idempotente: si el modelo ya está, no hace nada.

    Ejecutar una vez por máquina (o cuando se cambie el modelo).

.PARAMETER ClienteDir
    Raíz del repo cliente (default: directorio padre del script).

.EXAMPLE
    .\scripts\descargar_modelo_embeddings.ps1
#>

param(
    [string]$ClienteDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding          = [System.Text.Encoding]::UTF8

if (-not $ClienteDir) {
    $ClienteDir = Split-Path -Parent $PSScriptRoot
}
$cacheDir = Join-Path $ClienteDir "datos\fastembed_cache"

Write-Host ""
Write-Host "=== Descarga del modelo de embeddings ==="
Write-Host "Cache : $cacheDir"
Write-Host ""

New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null

# Usar la misma definición de modelo que MV
# (mv/core/embeddings/fastembed.py:MODELO_DEFAULT).
$modelo = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"

# Verificación rápida: ¿ya está en el cache?
$yaExiste = Get-ChildItem $cacheDir -Recurse -Directory -Filter "models--sentence-transformers--*" `
            -ErrorAction SilentlyContinue | Select-Object -First 1
if ($yaExiste) {
    Write-Host "OK: modelo ya presente en $($yaExiste.FullName)" -ForegroundColor Green
    Write-Host "    No se descarga nada."
    exit 0
}

# Setear el cache para que fastembed escriba ahí
$env:HF_HOME = $cacheDir

Write-Host "Descargando $modelo (~117 MB la primera vez)..." -ForegroundColor Yellow

# PowerShell trata mensajes a stderr de comandos nativos como errores cuando
# $ErrorActionPreference = "Stop". fastembed emite UserWarnings legítimos.
# Bajamos la pref localmente y dependemos de $LASTEXITCODE para fallar.
$prevErrAction = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    python -c @"
import sys
try:
    from fastembed import TextEmbedding
except ImportError:
    sys.stderr.write('fastembed no instalado. Ejecuta: pip install fastembed\n')
    sys.exit(2)
modelo = '$modelo'
print(f'Cargando {modelo}...', flush=True)
TextEmbedding(model_name=modelo)
print('OK', flush=True)
"@ 2>&1
} finally {
    $ErrorActionPreference = $prevErrAction
}
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "FAILED: la descarga fallo (exit $LASTEXITCODE)." -ForegroundColor Red
    exit $LASTEXITCODE
}

Write-Host ""
Write-Host "Modelo descargado al cache." -ForegroundColor Green
Write-Host "Ahora podes levantar el stack:" -ForegroundColor Green
Write-Host "  .\scripts\dev-ui.ps1 up         (UI completa)"
Write-Host "  .\scripts\run_e2e_chat.ps1      (E2E chat)"
Write-Host "  .\scripts\run_e2e_ingesta.ps1   (E2E ingesta)"
