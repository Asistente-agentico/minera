#!/usr/bin/env bash
# run_e2e_informes-consumir.sh — Levanta MA+M3 via docker compose y valida reportes con pytest local.
#
# Prerrequisito: datos/minera.duckdb presente (dbt seed && dbt run).
# No requiere MASTER_SECRET (M3 no usa MV ni Qdrant).
#
# Uso:
#   bash scripts/run_e2e_informes-consumir.sh
#   bash scripts/run_e2e_informes-consumir.sh tests/e2e_informes-consumir.yaml
#
# Variables de entorno:
#   ILLARI_TAG    — tag de imagen del registro (default: dev-0.7.3)
#   ILLARI_IMAGE  — nombre completo de imagen (override; p.ej. asistente-virtual:local).
#                   Si se define, omite el pull y usa esa imagen directamente.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------
COMPOSE_FILE="docker-compose.informes-consumir.yml"

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
SUITE_REL="tests/e2e_informes-consumir.yaml"

for arg in "$@"; do
    case "$arg" in
        *.yaml|*.yml) SUITE_REL="$arg" ;;
        *) ;;
    esac
done

SUITE_ABS="${REPO_RAIZ}/${SUITE_REL}"

# ---------------------------------------------------------------------------
# Validar prerequisitos
# ---------------------------------------------------------------------------
if [[ ! -f "$SUITE_ABS" ]]; then
    echo "Error: suite no encontrada: $SUITE_ABS" >&2
    exit 1
fi

if [[ ! -f "${REPO_RAIZ}/datos/minera.duckdb" ]]; then
    echo "Error: datos/minera.duckdb no encontrado." >&2
    echo "Ejecuta 'dbt seed' y 'dbt run' en modelos/ antes de correr esta suite." >&2
    exit 1
fi

if [[ ! -f "${REPO_RAIZ}/${COMPOSE_FILE}" ]]; then
    echo "Error: ${COMPOSE_FILE} no encontrado en ${REPO_RAIZ}" >&2
    exit 1
fi

ILLARI_TESTS="$(dirname "$REPO_RAIZ")/Illari/tests"
TEST_DIR="${ILLARI_TESTS}/e2e_m3"
if [[ ! -d "$TEST_DIR" ]]; then
    echo "Error: tests/e2e_m3/ no encontrado en ${TEST_DIR}" >&2
    echo "Verifica que el repo Illari esté en $(dirname "$REPO_RAIZ")/Illari" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Info
# ---------------------------------------------------------------------------
TS=$(date +%Y%m%d-%H%M%S)
OUT_DIR="${REPO_RAIZ}/tests/results"
OUT_FILE="${OUT_DIR}/e2e_informes-consumir-${TS}.txt"
mkdir -p "$OUT_DIR"

echo ""
echo "=== Illari E2E informes-consumir — minera ==="
echo "Suite  : ${SUITE_ABS}"
echo "Imagen : ${ILLARI_IMAGE}"
echo "Output : ${OUT_FILE}"
echo ""

# ---------------------------------------------------------------------------
# Fase 1 — Descargar imagen (omite pull si es local o ya existe)
# ---------------------------------------------------------------------------
if [[ $_IMAGEN_LOCAL -eq 1 ]]; then
    echo "[1/3] Imagen local definida (ILLARI_IMAGE) — omitiendo pull."
elif docker image inspect "${ILLARI_IMAGE}" &>/dev/null; then
    echo "[1/3] Imagen ${ILLARI_IMAGE} encontrada localmente — omitiendo pull."
else
    echo "[1/3] Descargando imagen Docker..."
    ILLARI_IMAGE="${ILLARI_IMAGE}" \
    docker compose -f "${REPO_RAIZ}/${COMPOSE_FILE}" pull
fi
echo ""

# ---------------------------------------------------------------------------
# Fase 2 — Levantar servicios en background
# ---------------------------------------------------------------------------
echo "[2/3] Levantando servicios MA + M3..."
echo ""

ILLARI_IMAGE="${ILLARI_IMAGE}" \
docker compose -f "${REPO_RAIZ}/${COMPOSE_FILE}" down --remove-orphans 2>/dev/null || true

ILLARI_IMAGE="${ILLARI_IMAGE}" \
docker compose -f "${REPO_RAIZ}/${COMPOSE_FILE}" up -d \
    | tee -a "${OUT_FILE}"

# Esperar M3 healthy (máximo 90 segundos)
echo ""
echo "  Esperando M3 en http://localhost:8005/health..."
M3_OK=0
for i in $(seq 1 18); do
    if python3 -c "
import urllib.request, sys
try:
    r = urllib.request.urlopen('http://localhost:8005/health', timeout=3)
    sys.exit(0 if r.status == 200 else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
        echo "  M3 listo (intento ${i}/18)"
        M3_OK=1
        break
    fi
    echo "  Intento ${i}/18 — esperando 5s..."
    sleep 5
done

if [[ $M3_OK -eq 0 ]]; then
    echo ""
    echo "FAILED: M3 no respondió healthy en 90s." >&2
    echo "--- Logs de servicios ---" >&2
    ILLARI_IMAGE="${ILLARI_IMAGE}" \
    docker compose -f "${REPO_RAIZ}/${COMPOSE_FILE}" logs --tail=30 >&2 || true
    ILLARI_IMAGE="${ILLARI_IMAGE}" \
    docker compose -f "${REPO_RAIZ}/${COMPOSE_FILE}" down --remove-orphans 2>/dev/null || true
    exit 1
fi
echo ""

# ---------------------------------------------------------------------------
# Fase 3 — Validación con pytest local
# ---------------------------------------------------------------------------
echo "[3/3] Ejecutando pytest E2E informes-consumir..."
echo ""

ILLARI_E2E_INFORMES_CONSUMIR="${SUITE_ABS}" \
ILLARI_E2E_CLIENTE="${REPO_RAIZ}" \
ILLARI_E2E_M3_URL="http://localhost:8005" \
ILLARI_E2E_MA_URL="http://localhost:8001" \
python3 -m pytest "${TEST_DIR}" -v -m e2e \
    --rootdir="${ILLARI_TESTS}/.." \
    | tee -a "${OUT_FILE}"

PYTEST_EXIT="${PIPESTATUS[0]}"

ILLARI_IMAGE="${ILLARI_IMAGE}" \
docker compose -f "${REPO_RAIZ}/${COMPOSE_FILE}" down --remove-orphans 2>/dev/null || true

echo ""
if [[ $PYTEST_EXIT -eq 0 ]]; then
    echo "PASSED — resultado guardado en: ${OUT_FILE}"
else
    echo "FAILED (exit ${PYTEST_EXIT}) — resultado guardado en: ${OUT_FILE}"
fi

exit "$PYTEST_EXIT"
