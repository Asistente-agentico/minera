#!/usr/bin/env bash
# build-imagenes.sh — Construye imágenes Docker por módulo.
#
# Lee versiones de minera/imagenes/versiones.yaml y construye imágenes
# individuales para cada módulo backend + UI desde el repo Illari.
#
# Requiere que el repo Illari esté en ../Illari relativo a minera.
#
# Las imágenes se etiquetan como illari-<mod>:<version> e illari-<mod>:local.
# El tag :local es el que usa docker-compose.ui.yml por defecto.
#
# Uso:
#   bash scripts/build-imagenes.sh                     # todos los módulos
#   bash scripts/build-imagenes.sh base ma m2          # módulos específicos
#   bash scripts/build-imagenes.sh --push              # construir + push
#   bash scripts/build-imagenes.sh ma --push           # solo ma + push

set -euo pipefail

REPO_RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
ILLARI_DIR="$(cd "$REPO_RAIZ/../Illari" 2>/dev/null && pwd || true)"
VERSIONES_FILE="$REPO_RAIZ/imagenes/versiones.yaml"

PUSH=false
MODULOS=()

for arg in "$@"; do
    case "$arg" in
        --push) PUSH=true ;;
        *)      MODULOS+=("$arg") ;;
    esac
done

if [[ -z "$ILLARI_DIR" || ! -d "$ILLARI_DIR" ]]; then
    echo "ERROR: No se encontró el repo Illari en $REPO_RAIZ/../Illari" >&2
    exit 1
fi

if [[ ! -f "$VERSIONES_FILE" ]]; then
    echo "ERROR: No se encontró $VERSIONES_FILE" >&2
    exit 1
fi

_get_version() {
    grep -E "^\s+${1}:" "$VERSIONES_FILE" 2>/dev/null | head -1 \
        | sed -E "s/^\s+${1}:\s*//" | tr -d '"' | xargs 2>/dev/null || true
}
_get_registry() {
    grep -E "^registry:" "$VERSIONES_FILE" 2>/dev/null | head -1 \
        | sed -E "s/^registry:\s*//" | tr -d '"' | xargs 2>/dev/null || true
}

REGISTRY="$(_get_registry)"

declare -A DOCKERFILES=(
    [base]="docker/Dockerfile.base"
    [mk]="docker/Dockerfile.mk"
    [ma]="docker/Dockerfile.ma"
    [m2]="docker/Dockerfile.m2"
    [m3]="docker/Dockerfile.m3"
    [m5]="docker/Dockerfile.m5"
    [mv]="docker/Dockerfile.mv"
    [m1]="docker/Dockerfile.m1"
    [ui]="customer_ui/docker/Dockerfile"
)
declare -A CONTEXTOS=(
    [base]="$ILLARI_DIR"
    [mk]="$ILLARI_DIR"
    [ma]="$ILLARI_DIR"
    [m2]="$ILLARI_DIR"
    [m3]="$ILLARI_DIR"
    [m5]="$ILLARI_DIR"
    [mv]="$ILLARI_DIR"
    [m1]="$ILLARI_DIR"
    [ui]="$ILLARI_DIR/customer_ui"
)

MODULOS_BACKEND=(mk ma m2 m3 m5 mv m1)
TODOS=(base mk ma m2 m3 m5 mv m1 ui)

if [[ ${#MODULOS[@]} -eq 0 ]]; then
    MODULOS=("${TODOS[@]}")
fi

# Si hay módulos backend pero no base, agregar base primero
NECESITA_BASE=false
for m in "${MODULOS[@]}"; do
    for b in "${MODULOS_BACKEND[@]}"; do
        [[ "$m" == "$b" ]] && NECESITA_BASE=true && break 2
    done
done

TIENE_BASE=false
for m in "${MODULOS[@]}"; do [[ "$m" == "base" ]] && TIENE_BASE=true && break; done

if [[ "$NECESITA_BASE" == true && "$TIENE_BASE" == false ]]; then
    echo "  (base agregado automáticamente — requerido por módulos backend)"
    MODULOS=(base "${MODULOS[@]}")
fi

# Deduplicar preservando orden. base solo aparece si está en la lista
# pedida o si el bloque NECESITA_BASE arriba lo agregó.
declare -a MODULOS_ORDERED=()
for m in "${MODULOS[@]}"; do
    FOUND=false
    for x in "${MODULOS_ORDERED[@]:-}"; do [[ "$x" == "$m" ]] && FOUND=true && break; done
    $FOUND || MODULOS_ORDERED+=("$m")
done

# Si base está en la lista pero no en posición 0, moverlo al inicio
# (los módulos backend dependen de él, debe construirse primero).
if [[ ${#MODULOS_ORDERED[@]} -gt 1 && "${MODULOS_ORDERED[0]}" != "base" ]]; then
    declare -a SIN_BASE=()
    TIENE_BASE_AHORA=false
    for m in "${MODULOS_ORDERED[@]}"; do
        if [[ "$m" == "base" ]]; then
            TIENE_BASE_AHORA=true
        else
            SIN_BASE+=("$m")
        fi
    done
    if [[ "$TIENE_BASE_AHORA" == true ]]; then
        MODULOS_ORDERED=(base "${SIN_BASE[@]}")
    fi
fi
MODULOS=("${MODULOS_ORDERED[@]}")

echo ""
echo "=== build-imagenes: ${MODULOS[*]} ==="
echo "Illari   : $ILLARI_DIR"
[[ -n "$REGISTRY" ]] && echo "Registry : $REGISTRY"
echo ""

for MOD in "${MODULOS[@]}"; do
    VERSION="$(_get_version "$MOD")"
    if [[ -z "$VERSION" ]]; then
        echo "WARNING: '$MOD' no está en versiones.yaml — omitiendo."
        continue
    fi

    DOCKERFILE="${ILLARI_DIR}/${DOCKERFILES[$MOD]}"
    CONTEXTO="${CONTEXTOS[$MOD]}"
    TAG_LOCAL="illari-${MOD}:local"
    TAG_VERSION="illari-${MOD}:${VERSION}"

    if [[ ! -f "$DOCKERFILE" ]]; then
        echo "ERROR: Dockerfile no encontrado: $DOCKERFILE" >&2
        exit 1
    fi

    echo "[build] $MOD v$VERSION"
    docker build -f "$DOCKERFILE" -t "$TAG_LOCAL" -t "$TAG_VERSION" "$CONTEXTO"

    if [[ "$PUSH" == true && -n "$REGISTRY" ]]; then
        TAG_REGISTRY="${REGISTRY}/illari-${MOD}:${VERSION}"
        docker tag "$TAG_LOCAL" "$TAG_REGISTRY"
        docker push "$TAG_REGISTRY"
        echo "  → pushed $TAG_REGISTRY"
    fi

    echo "  OK: $TAG_LOCAL / $TAG_VERSION"
    echo ""
done

echo "Imágenes disponibles:"
for MOD in "${MODULOS[@]}"; do
    VERSION="$(_get_version "$MOD")"
    [[ -n "$VERSION" ]] && echo "  illari-${MOD}:local  (v${VERSION})"
done
echo ""
