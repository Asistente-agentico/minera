<#
.SYNOPSIS
    Construye imágenes Docker por módulo para el stack de desarrollo.

.DESCRIPTION
    Lee versiones de minera/imagenes/versiones.yaml y construye imágenes
    individuales para cada módulo backend + UI desde el repo Illari.

    Requiere que el repo Illari esté en ../Illari relativo a minera.

    Las imágenes se etiquetan como illari-<mod>:<version> e illari-<mod>:local.
    El tag :local es el que usa docker-compose.ui.yml por defecto.

.PARAMETER Modulo
    Módulo(s) a construir. Default: todos (base, mk, ma, m2, m3, ui).
    Nota: si se incluye algún módulo que depende de base (mk, ma, m2, m3),
    base se construye automáticamente primero.

.PARAMETER Push
    Si se especifica, hace push al registry definido en versiones.yaml.

.EXAMPLE
    .\scripts\build-imagenes.ps1
    .\scripts\build-imagenes.ps1 -Modulo ma
    .\scripts\build-imagenes.ps1 -Modulo base, ma, m2
    .\scripts\build-imagenes.ps1 -Push
#>

param(
    [string[]]$Modulo = @(),
    [switch]$Push
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding          = [System.Text.Encoding]::UTF8

$repoRaiz      = Split-Path -Parent $PSScriptRoot
$illariDir     = Join-Path (Split-Path -Parent $repoRaiz) "Illari"
$versionesFile = Join-Path $repoRaiz "imagenes\versiones.yaml"

if (-not (Test-Path $illariDir)) {
    Write-Error "No se encontró el repo Illari en: $illariDir`nVerifica que ../Illari exista."
    exit 1
}
if (-not (Test-Path $versionesFile)) {
    Write-Error "No se encontró: $versionesFile"
    exit 1
}

# Parser YAML mínimo para versiones.yaml
function Read-VersionesYaml($path) {
    $cfg = @{ registry = ""; modulos = @{} }
    $inModulos = $false
    foreach ($line in Get-Content $path -Encoding UTF8) {
        if ($line -match '^\s*#' -or $line.Trim() -eq '') { continue }
        if ($line -match '^registry:\s*"?([^"#]*)"?\s*$') {
            $cfg.registry = $Matches[1].Trim()
            continue
        }
        if ($line -match '^modulos:') { $inModulos = $true; continue }
        if ($inModulos -and $line -match '^\s+(\w+):\s*"?([^"#\s]+)"?') {
            $cfg.modulos[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }
    return $cfg
}

$cfg      = Read-VersionesYaml $versionesFile
$registry = $cfg.registry
$versiones = $cfg.modulos

$modulosBackend = @("mk", "ma", "m2", "m3", "m5", "mv", "m1")
$todosMod       = @("base") + $modulosBackend + @("ui")

if ($Modulo.Count -eq 0) {
    $Modulo = $todosMod
}

# Si algún módulo backend está en la lista pero base no, agregar base primero
$necesitaBase = (@($Modulo | Where-Object { $modulosBackend -contains $_ })).Count -gt 0
if ($necesitaBase -and ($Modulo -notcontains "base")) {
    Write-Host "  (base agregado automaticamente - requerido por modulos backend)"
    $Modulo = @("base") + $Modulo
}
# base siempre primero
$Modulo = @("base") + ($Modulo | Where-Object { $_ -ne "base" })
$Modulo = $Modulo | Select-Object -Unique

$dockerfiles = @{
    base = "docker\Dockerfile.base"
    mk   = "docker\Dockerfile.mk"
    ma   = "docker\Dockerfile.ma"
    m2   = "docker\Dockerfile.m2"
    m3   = "docker\Dockerfile.m3"
    m5   = "docker\Dockerfile.m5"
    mv   = "docker\Dockerfile.mv"
    m1   = "docker\Dockerfile.m1"
    ui   = "customer_ui\docker\Dockerfile"
}
$contextos = @{
    base = $illariDir
    mk   = $illariDir
    mv   = $illariDir
    m1   = $illariDir
    ma   = $illariDir
    m2   = $illariDir
    m3   = $illariDir
    m5   = $illariDir
    ui   = (Join-Path $illariDir "customer_ui")
}

Write-Host ""
Write-Host "=== build-imagenes: $($Modulo -join ', ') ==="
Write-Host "Illari   : $illariDir"
if ($registry) { Write-Host "Registry : $registry" }
Write-Host ""

foreach ($mod in $Modulo) {
    if (-not $versiones.ContainsKey($mod)) {
        Write-Warning "Modulo '$mod' no esta en versiones.yaml - omitiendo."
        continue
    }
    $version    = $versiones[$mod]
    $dockerfile = Join-Path $illariDir $dockerfiles[$mod]
    $contexto   = $contextos[$mod]
    $tagLocal   = "illari-${mod}:local"
    $tagVersion = "illari-${mod}:${version}"

    if (-not (Test-Path $dockerfile)) {
        Write-Error "Dockerfile no encontrado: $dockerfile"
        exit 1
    }

    Write-Host "[build] $mod v$version"
    docker build -f $dockerfile -t $tagLocal -t $tagVersion $contexto
    if ($LASTEXITCODE -ne 0) { Write-Error "Build de '$mod' fallido."; exit $LASTEXITCODE }

    if ($Push -and $registry) {
        $tagRegistry = "${registry}/illari-${mod}:${version}"
        docker tag $tagLocal $tagRegistry
        docker push $tagRegistry
        if ($LASTEXITCODE -ne 0) { Write-Error "Push de '$mod' fallido."; exit $LASTEXITCODE }
        Write-Host "  pushed $tagRegistry"
    }

    Write-Host "  OK: $tagLocal / $tagVersion"
    Write-Host ""
}

Write-Host "Imágenes disponibles:"
foreach ($mod in $Modulo) {
    if ($versiones.ContainsKey($mod)) {
        Write-Host "  illari-${mod}:local  (v$($versiones[$mod]))"
    }
}
Write-Host ""
