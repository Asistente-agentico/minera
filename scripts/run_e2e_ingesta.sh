#!/usr/bin/env bash
# run_e2e_ingesta.sh — Pipeline E2E ingesta: MK + MV + M1 via docker compose.
#
# Tres fases:
#   1. Pre-flight: verifica que las imagenes locales existen.
#   2. Limpiar datos/qdrant_mv/ y levantar MK + MV + M1 via docker compose.
#      MV cifra y persiste chunks en Qdrant. M1 los genera y envia.
#   3. Local: pytest valida chunks_generados_dev.json contra e2e_ingesta.yaml.
#
# Uso:
#   bash scripts/run_e2e_ingesta.sh
#   bash scripts/run_e2e_ingesta.sh tests/e2e_ingesta.yaml
#
# Variables de entorno:
#   MASTER_SECRET      — secreto de cifrado (obligatorio)
#   ILLARI_MK_IMAGE    — override imagen mk  (default: illari-mk:local)
#   ILLARI_MV_IMAGE    — override imagen mv  (default: illari-mv:local)
#   ILLARI_M1_IMAGE    — override imagen m1  (default: illari-m1:local)

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuracion
# ---------------------------------------------------------------------------
COMPOSE_FILE="docker-compose.ingesta.yml"
REPO_RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
SUITE_REL="tests/e2e_ingesta.yaml"

for arg in "$@"; do
    case "$arg" in
        *.yaml|*.yml) SUITE_REL="$arg" ;;
        *) echo "Argumento desconocido: $arg" >&2; exit 1 ;;
    esac
done

SUITE_ABS="${REPO_RAIZ}/${SUITE_REL}"

# ---------------------------------------------------------------------------
# Leer MASTER_SECRET (env > .env > error)
# ---------------------------------------------------------------------------
if [[ -z "${MASTER_SECRET:-}" ]]; then
    ENV_FILE="${REPO_RAIZ}/.env"
    if [[ -f "$ENV_FILE" ]]; then
        MASTER_SECRET=$(grep -E '^\s*(export\s+)?MASTER_SECRET\s*=' "$ENV_FILE" \
            | head -1 | sed -E 's/^\s*(export\s+)?MASTER_SECRET\s*=\s*//' | tr -d '"'"'" | xargs)
    fi
fi
if [[ -z "${MASTER_SECRET:-}" ]]; then
    echo "Error: MASTER_SECRET no definido." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Validar suite y test runner
# ---------------------------------------------------------------------------
if [[ ! -f "$SUITE_ABS" ]]; then
    echo "Error: suite no encontrada: $SUITE_ABS" >&2
    exit 1
fi
if [[ ! -f "${REPO_RAIZ}/${COMPOSE_FILE}" ]]; then
    echo "Error: ${COMPOSE_FILE} no encontrado en ${REPO_RAIZ}" >&2
    exit 1
fi

ILLARI_TESTS="$(dirname "$REPO_RAIZ")/Illari/tests"
TEST_PIPELINE="${ILLARI_TESTS}/e2e_escritura/test_pipeline.py"
if [[ ! -f "$TEST_PIPELINE" ]]; then
    echo "Error: test_pipeline.py no encontrado en ${TEST_PIPELINE}" >&2
    echo "Verifica que el repo Illari este en $(dirname "$REPO_RAIZ")/Illari" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Archivo de resultado
# ---------------------------------------------------------------------------
TS=$(date +%Y%m%d-%H%M%S)
OUT_DIR="${REPO_RAIZ}/tests/results"
OUT_FILE="${OUT_DIR}/e2e_ingesta-${TS}.txt"
mkdir -p "$OUT_DIR"

# ---------------------------------------------------------------------------
# Fase 1 — Pre-flight: verificar imagenes locales
# ---------------------------------------------------------------------------
declare -A MOD_IMAGES=(
    [mk]="${ILLARI_MK_IMAGE:-illari-mk:local}"
    [mv]="${ILLARI_MV_IMAGE:-illari-mv:local}"
    [m1]="${ILLARI_M1_IMAGE:-illari-m1:local}"
)
echo ""
echo "[1/3] Verificando imagenes locales..."
FALTANTES=()
for mod in mk mv m1; do
    if ! docker image inspect "${MOD_IMAGES[$mod]}" &>/dev/null; then
        FALTANTES+=("$mod")
    fi
done
if [[ ${#FALTANTES[@]} -gt 0 ]]; then
    echo ""
    echo "ERROR: imagenes faltantes en Docker local:" >&2
    for mod in "${FALTANTES[@]}"; do echo "  illari-${mod}:local" >&2; done
    echo ""
    echo "Construye con:"
    echo "  bash scripts/build-imagenes.sh ${FALTANTES[*]}"
    exit 1
fi
echo "  OK: illari-mk:local, illari-mv:local, illari-m1:local"
echo ""

echo ""
echo "=== Illari E2E ingesta — minera ==="
echo "Suite  : ${SUITE_ABS}"
echo "Imagenes:"
for mod in mk mv m1; do echo "  ${mod}: ${MOD_IMAGES[$mod]}"; done
echo "Output : ${OUT_FILE}"
echo ""

# ---------------------------------------------------------------------------
# Fase 2 — Limpiar BDV y ejecutar pipeline
# ---------------------------------------------------------------------------
echo "[2/3] Ejecutando pipeline MK -> MV -> M1 via docker compose..."
echo ""

QDRANT_DIR="${REPO_RAIZ}/datos/qdrant_mv"
echo "  Limpiando ${QDRANT_DIR} y volumen Docker..."
if [[ -d "$QDRANT_DIR" ]]; then
    rm -rf "$QDRANT_DIR"
    echo "  Eliminado: ${QDRANT_DIR}"
else
    echo "  datos/qdrant_mv/ no existe, nada que limpiar."
fi
MASTER_SECRET="${MASTER_SECRET}" \
docker compose -f "${REPO_RAIZ}/${COMPOSE_FILE}" down --volumes --remove-orphans 2>/dev/null || true
echo ""

MASTER_SECRET="${MASTER_SECRET}" \
docker compose -f "${REPO_RAIZ}/${COMPOSE_FILE}" up -d mk qdrant-init mv \
    2>&1 | tee -a "${OUT_FILE}"

echo "  Esperando que MV esté healthy..."
for _i in $(seq 1 24); do
    sleep 5
    _MV_ID=$(docker compose -f "${REPO_RAIZ}/${COMPOSE_FILE}" ps -q mv 2>/dev/null)
    _STATUS=$(docker inspect "${_MV_ID}" --format '{{.State.Health.Status}}' 2>/dev/null || echo "unknown")
    if [ "${_STATUS}" = "healthy" ]; then echo "  MV healthy (intento ${_i}/24)"; break; fi
    if [ "${_i}" -eq 24 ]; then
        echo "ERROR: MV no llegó a healthy en 120s" >&2
        docker compose -f "${REPO_RAIZ}/${COMPOSE_FILE}" logs mv --tail=30 >&2
        docker compose -f "${REPO_RAIZ}/${COMPOSE_FILE}" down --volumes --remove-orphans --timeout 5 2>/dev/null || true
        exit 1
    fi
done
echo ""

MASTER_SECRET="${MASTER_SECRET}" \
docker compose -f "${REPO_RAIZ}/${COMPOSE_FILE}" \
    run --rm --no-deps -T m1 \
    | tee -a "${OUT_FILE}"
COMPOSE_EXIT="${PIPESTATUS[0]}"

# Copiar BDV Qdrant del volumen Docker al host via Alpine
echo "  Copiando BDV Qdrant del volumen Docker al host..."
mkdir -p "$QDRANT_DIR"
docker run --rm -v "minera_qdrant_mv:/source:ro" -v "${QDRANT_DIR}:/dest" \
    alpine sh -c "cp -r /source/. /dest/ && chown -R $(id -u):$(id -g) /dest" || \
    echo "  ADVERTENCIA: copia de BDV Qdrant fallo."

MASTER_SECRET="${MASTER_SECRET}" \
docker compose -f "${REPO_RAIZ}/${COMPOSE_FILE}" down --volumes --remove-orphans 2>/dev/null || true

if [[ $COMPOSE_EXIT -ne 0 ]]; then
    echo ""
    echo "FAILED pipeline docker compose (exit ${COMPOSE_EXIT}) — ver: ${OUT_FILE}"
    exit "$COMPOSE_EXIT"
fi

if [[ ! -f "${REPO_RAIZ}/datos/chunks_generados_dev.json" ]]; then
    echo ""
    echo "FAILED: chunks_generados_dev.json no fue generado por el pipeline." >&2
    exit 1
fi

echo ""
echo "  Pipeline completado. chunks_generados_dev.json generado y chunks en BDV."
echo ""

# ---------------------------------------------------------------------------
# Fase 3 — Validacion local con pytest
# ---------------------------------------------------------------------------
echo "[3/3] Validando chunks_generados_dev.json con pytest..."
echo ""

ILLARI_E2E_ESCRITURA="${SUITE_ABS}" \
ILLARI_E2E_RAIZ="${REPO_RAIZ}" \
PYTHONUNBUFFERED=1 \
python3 -m pytest "${TEST_PIPELINE}" -v -m e2e \
    --rootdir="${ILLARI_TESTS}/.." \
    | tee -a "${OUT_FILE}"
PYTEST_EXIT="${PIPESTATUS[0]}"

echo ""
if [[ $PYTEST_EXIT -eq 0 ]]; then
    echo "PASSED — resultado guardado en: ${OUT_FILE}"
else
    echo "FAILED (exit ${PYTEST_EXIT}) — resultado guardado en: ${OUT_FILE}"
fi

exit "$PYTEST_EXIT"
