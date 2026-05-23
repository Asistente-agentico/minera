#!/usr/bin/env bash
# run_e2e_ingesta.sh — Pipeline completo M1→MV→BDV y valida la salida.
#
# Fases:
#   1. Local: preparar_landing.py → CSVs en datos/csv/ desde el xlsx de mediciones.
#   2. docker compose pull (antes de cualquier cambio destructivo).
#   3. Limpiar datos/qdrant_mv/ y levantar MK + MV + M1 via docker compose.
#      M1: cargar_landing.py → dbt seed → dbt snapshot → dbt run → orquestador.
#   4. Local: pytest valida chunks_generados_dev.json contra e2e_ingesta.yaml.
#
# Uso:
#   bash scripts/run_e2e_ingesta.sh
#   bash scripts/run_e2e_ingesta.sh tests/e2e_ingesta.yaml
#
# Variables de entorno:
#   MASTER_SECRET  — secreto de cifrado (obligatorio)
#   ILLARI_TAG     — tag de imagen del registro (default: dev-0.7.3)
#   ILLARI_IMAGE   — nombre completo de imagen (override; p.ej. asistente-virtual:local).
#                    Si se define, omite el pull y usa esa imagen directamente.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------
COMPOSE_FILE="docker-compose.ingesta.yml"

# Si ILLARI_IMAGE no está definida, leer de .env o construir desde ILLARI_TAG.
if [[ -z "${ILLARI_IMAGE:-}" ]]; then
    _ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"
    if [[ -f "$_ENV_FILE" ]]; then
        ILLARI_IMAGE=$(grep -E '^\s*(export\s+)?ILLARI_IMAGE\s*=' "$_ENV_FILE" \
            | head -1 | sed -E 's/^\s*(export\s+)?ILLARI_IMAGE\s*=\s*//' | tr -d '"'"'" | xargs || true)
    fi
fi
if [[ -z "${ILLARI_IMAGE:-}" ]]; then
    ILLARI_IMAGE="ghcr.io/asistente-agentico/illari:${ILLARI_TAG:-dev-0.7.3}"
    _IMAGEN_LOCAL=0
else
    _IMAGEN_LOCAL=1
fi

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
    echo "Pásalo como variable de entorno o agrégalo al archivo .env del repo." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Validar suite, dependencias y compose
# ---------------------------------------------------------------------------
if [[ ! -f "$SUITE_ABS" ]]; then
    echo "Error: suite no encontrada: $SUITE_ABS" >&2
    exit 1
fi

if [[ ! -f "${REPO_RAIZ}/${COMPOSE_FILE}" ]]; then
    echo "Error: ${COMPOSE_FILE} no encontrado en ${REPO_RAIZ}" >&2
    exit 1
fi

# Localizar test_pipeline.py en el repo hermano Illari
ILLARI_TESTS="$(dirname "$REPO_RAIZ")/Illari/tests"
TEST_PIPELINE="${ILLARI_TESTS}/e2e_escritura/test_pipeline.py"
if [[ ! -f "$TEST_PIPELINE" ]]; then
    echo "Error: test_pipeline.py no encontrado en ${TEST_PIPELINE}" >&2
    echo "Verifica que el repo Illari esté en $(dirname "$REPO_RAIZ")/Illari" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Info
# ---------------------------------------------------------------------------
TS=$(date +%Y%m%d-%H%M%S)
OUT_DIR="${REPO_RAIZ}/tests/results"
OUT_FILE="${OUT_DIR}/e2e_ingesta-${TS}.txt"
mkdir -p "$OUT_DIR"

echo ""
echo "=== Illari E2E ingesta — minera ==="
echo "Suite  : ${SUITE_ABS}"
echo "Imagen : ${ILLARI_IMAGE}"
echo "Output : ${OUT_FILE}"
echo ""

# ---------------------------------------------------------------------------
# Fase 0 — Preparar CSVs de landing desde el xlsx de mediciones
# ---------------------------------------------------------------------------
echo "[1/4] Preparando CSVs de landing..."
python3 "${REPO_RAIZ}/scripts/preparar_landing.py" --raiz "${REPO_RAIZ}"
echo ""

# ---------------------------------------------------------------------------
# Fase 1 — Descargar imagen (omite pull si es local o ya existe)
# ---------------------------------------------------------------------------
if [[ $_IMAGEN_LOCAL -eq 1 ]]; then
    echo "[2/4] Imagen local definida (ILLARI_IMAGE) — omitiendo pull."
elif docker image inspect "${ILLARI_IMAGE}" &>/dev/null; then
    echo "[2/4] Imagen ${ILLARI_IMAGE} encontrada localmente — omitiendo pull."
else
    echo "[2/4] Descargando imagen Docker..."
    ILLARI_IMAGE="${ILLARI_IMAGE}" \
    MASTER_SECRET="${MASTER_SECRET}" \
    docker compose -f "${REPO_RAIZ}/${COMPOSE_FILE}" pull
fi
echo ""

# ---------------------------------------------------------------------------
# Fase 2 — Limpiar BDV y ejecutar pipeline MK + MV + M1
# ---------------------------------------------------------------------------
echo "[3/4] Ejecutando pipeline MK → MV → M1 via docker compose..."
echo ""

QDRANT_DIR="${REPO_RAIZ}/datos/qdrant_mv"
echo "  Limpiando ${QDRANT_DIR}..."
if [[ -d "$QDRANT_DIR" ]]; then
    rm -rf "$QDRANT_DIR"
    echo "  Eliminado: ${QDRANT_DIR}"
else
    echo "  datos/qdrant_mv/ no existe, nada que limpiar."
fi

echo "  Pre-creando colección Qdrant (el contenedor MV escribe, no crea)..."
python3 "${REPO_RAIZ}/scripts/preparar_bdv.py" --raiz "${REPO_RAIZ}"
echo ""

# Garantizar estado limpio: si hay contenedores previos (config stale), bajarlos.
ILLARI_IMAGE="${ILLARI_IMAGE}" \
MASTER_SECRET="${MASTER_SECRET}" \
docker compose -f "${REPO_RAIZ}/${COMPOSE_FILE}" down --remove-orphans 2>/dev/null || true

ILLARI_IMAGE="${ILLARI_IMAGE}" \
MASTER_SECRET="${MASTER_SECRET}" \
docker compose -f "${REPO_RAIZ}/${COMPOSE_FILE}" \
    up --abort-on-container-exit --exit-code-from m1 \
    | tee -a "${OUT_FILE}"

COMPOSE_EXIT="${PIPESTATUS[0]}"

# Limpiar red y contenedores detenidos
ILLARI_IMAGE="${ILLARI_IMAGE}" \
MASTER_SECRET="${MASTER_SECRET}" \
docker compose -f "${REPO_RAIZ}/${COMPOSE_FILE}" down --remove-orphans 2>/dev/null || true

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

if [[ ! -d "${REPO_RAIZ}/datos/qdrant_mv" ]] || [[ -z "$(ls -A "${REPO_RAIZ}/datos/qdrant_mv" 2>/dev/null)" ]]; then
    echo ""
    echo "FAILED: datos/qdrant_mv/ vacío o inexistente — MV no indexó los chunks." >&2
    exit 1
fi

echo ""
echo "  Pipeline completado. chunks_generados_dev.json generado y chunks en BDV."
echo ""

# ---------------------------------------------------------------------------
# Fase 3 — Validación local con pytest
# ---------------------------------------------------------------------------
echo "[4/4] Validando chunks con pytest (JSON + BDV)..."
echo ""

ILLARI_E2E_INGESTA="${SUITE_ABS}" \
ILLARI_E2E_RAIZ="${REPO_RAIZ}" \
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
