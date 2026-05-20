#!/usr/bin/env bash
# run_e2e_lectura.sh — Levanta MK+MV+MA+M2 via docker compose y valida
#                      consultas RAG con pytest local.
#
# Prerrequisito: datos/qdrant_mv/ debe existir (correr run_e2e_escritura.sh primero).
#
# Uso:
#   bash scripts/run_e2e_lectura.sh
#   bash scripts/run_e2e_lectura.sh tests/e2e_lectura.yaml
#
# Variables de entorno:
#   MASTER_SECRET  — secreto de cifrado (obligatorio)
#   ILLARI_TAG     — tag de imagen Docker (default: dev-0.7.1)

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------
IMAGEN_BASE="ghcr.io/asistente-agentico/illari"
IMAGEN="${IMAGEN_BASE}:${ILLARI_TAG:-dev-0.7.1}"
COMPOSE_FILE="docker-compose.lectura.yml"

REPO_RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
SUITE_REL="tests/e2e_lectura.yaml"

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
# Validar prerequisitos
# ---------------------------------------------------------------------------
if [[ ! -f "$SUITE_ABS" ]]; then
    echo "Error: suite no encontrada: $SUITE_ABS" >&2
    exit 1
fi

if [[ ! -d "${REPO_RAIZ}/datos/qdrant_mv" ]]; then
    echo "Error: datos/qdrant_mv/ no encontrado." >&2
    echo "Ejecuta run_e2e_escritura.sh primero para poblar la BDV." >&2
    exit 1
fi

if [[ ! -f "${REPO_RAIZ}/${COMPOSE_FILE}" ]]; then
    echo "Error: ${COMPOSE_FILE} no encontrado en ${REPO_RAIZ}" >&2
    exit 1
fi

ILLARI_TESTS="$(dirname "$REPO_RAIZ")/Illari/tests"
if [[ ! -d "$ILLARI_TESTS" ]]; then
    echo "Error: tests/ de Illari no encontrado en ${ILLARI_TESTS}" >&2
    echo "Verifica que el repo Illari esté en $(dirname "$REPO_RAIZ")/Illari" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Info
# ---------------------------------------------------------------------------
TS=$(date +%Y%m%d-%H%M%S)
OUT_DIR="${REPO_RAIZ}/tests/results"
OUT_FILE="${OUT_DIR}/e2e_lectura-${TS}.txt"
mkdir -p "$OUT_DIR"

echo ""
echo "=== Illari E2E lectura — minera ==="
echo "Suite  : ${SUITE_ABS}"
echo "Imagen : ${IMAGEN}"
echo "Output : ${OUT_FILE}"
echo ""

# ---------------------------------------------------------------------------
# Fase 1 — Descargar imagen
# ---------------------------------------------------------------------------
echo "[1/3] Descargando imagen Docker..."
ILLARI_TAG="${ILLARI_TAG:-dev-0.7.1}" \
MASTER_SECRET="${MASTER_SECRET}" \
docker compose -f "${REPO_RAIZ}/${COMPOSE_FILE}" pull
echo ""

# ---------------------------------------------------------------------------
# Fase 2 — Levantar servicios en background
# ---------------------------------------------------------------------------
echo "[2/3] Levantando servicios MK → MV → MA + M2..."
echo ""

ILLARI_TAG="${ILLARI_TAG:-dev-0.7.1}" \
MASTER_SECRET="${MASTER_SECRET}" \
docker compose -f "${REPO_RAIZ}/${COMPOSE_FILE}" up -d \
    | tee -a "${OUT_FILE}"

# Esperar M2 healthy (máximo 120 segundos, implica que MA y MV también estén listos)
echo ""
echo "  Esperando M2 en http://localhost:8000/health..."
M2_OK=0
for i in $(seq 1 24); do
    if python3 -c "
import urllib.request, sys
try:
    r = urllib.request.urlopen('http://localhost:8000/health', timeout=3)
    sys.exit(0 if r.status == 200 else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
        echo "  M2 listo (intento ${i}/24)"
        M2_OK=1
        break
    fi
    echo "  Intento ${i}/24 — esperando 5s..."
    sleep 5
done

if [[ $M2_OK -eq 0 ]]; then
    echo ""
    echo "FAILED: M2 no respondió healthy en 120s." >&2
    echo "--- Logs de servicios ---" >&2
    ILLARI_TAG="${ILLARI_TAG:-dev-0.7.1}" \
    MASTER_SECRET="${MASTER_SECRET}" \
    docker compose -f "${REPO_RAIZ}/${COMPOSE_FILE}" logs --tail=30 >&2 || true
    ILLARI_TAG="${ILLARI_TAG:-dev-0.7.1}" \
    MASTER_SECRET="${MASTER_SECRET}" \
    docker compose -f "${REPO_RAIZ}/${COMPOSE_FILE}" down --remove-orphans 2>/dev/null || true
    exit 1
fi
echo ""

# ---------------------------------------------------------------------------
# Fase 3 — Validación con pytest local
# ---------------------------------------------------------------------------
echo "[3/3] Ejecutando pytest E2E lectura..."
echo ""

ILLARI_E2E_SUITE="${SUITE_ABS}" \
ILLARI_E2E_CLIENTE="${REPO_RAIZ}" \
ILLARI_E2E_M2_URL="http://localhost:8000" \
ILLARI_E2E_MA_URL="http://localhost:8001" \
python3 -m pytest "${ILLARI_TESTS}/e2e/" -v -m e2e \
    --rootdir="${ILLARI_TESTS}/.." \
    | tee -a "${OUT_FILE}"

PYTEST_EXIT="${PIPESTATUS[0]}"

# Detener servicios
ILLARI_TAG="${ILLARI_TAG:-dev-0.7.1}" \
MASTER_SECRET="${MASTER_SECRET}" \
docker compose -f "${REPO_RAIZ}/${COMPOSE_FILE}" down --remove-orphans 2>/dev/null || true

echo ""
if [[ $PYTEST_EXIT -eq 0 ]]; then
    echo "PASSED — resultado guardado en: ${OUT_FILE}"
else
    echo "FAILED (exit ${PYTEST_EXIT}) — resultado guardado en: ${OUT_FILE}"
fi

exit "$PYTEST_EXIT"
