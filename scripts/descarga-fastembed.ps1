<#
.SYNOPSIS
    Descarga el modelo fastembed a datos/fastembed_cache/ usando Python local.

.DESCRIPTION
    Instala fastembed (si no está) y descarga el modelo
    sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2
    al directorio datos/fastembed_cache/ del host.
    Ese directorio se monta como caché en mv-api durante el E2E ingesta.

.EXAMPLE
    .\scripts\descarga-fastembed.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRaiz = Split-Path -Parent $PSScriptRoot
$cacheDir = Join-Path $repoRaiz "datos\fastembed_cache"

New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null

Write-Host "Cache: $cacheDir"
Write-Host ""

$env:FASTEMBED_CACHE_PATH = $cacheDir

pip install fastembed -q
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

python -c "
from fastembed import TextEmbedding
TextEmbedding('sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2')
print('modelo descargado OK')
"

if ($LASTEXITCODE -ne 0) {
    Write-Host "FAILED (exit $LASTEXITCODE)" -ForegroundColor Red
    exit $LASTEXITCODE
}

Write-Host ""
Write-Host "OK — modelo en $cacheDir" -ForegroundColor Green
