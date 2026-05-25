#!/usr/bin/env bash
# run_e2e_chat.sh — Levanta MK+MV+MA+M2 via docker compose y valida
#                   consultas RAG con pytest local.
#
# Prerrequisito: datos/qdrant_mv/ debe existir (correr run_e2e_ingesta.sh primero).
#
# Uso:
#   bash scripts/run_e2e_chat.sh
#   bash scripts/run_e2e_chat.sh tests/e2e_chat.yaml
#   bash scripts/run_e2e_chat.sh --llm eco
#   bash scripts/run_e2e_chat.sh --llm gemini
#   bash scripts/run_e2e_chat.sh --llm stub
#
# Variables de entorno:
#   MASTER_SECRET      — secreto de cifrado (obligatorio)
#   ILLARI_MK_IMAGE    — override imagen mk  (default: illari-mk:local)
#   ILLARI_MV_IMAGE    — override imagen mv  (default: illari-mv:local)
#   ILLARI_MA_IMAGE    — override imagen ma  (default: illari-ma:local)
#   ILLARI_M2_IMAGE    — override imagen m2  (default: illari-m2:local)
#   GEMINI_API_KEY     — clave API de Google Gemini (obligatoria si --llm gemini)

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuracion
# ---------------------------------------------------------------------------
COMPOSE_FILE="docker-compose.chat.yml"
REPO_RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
SUITE_REL="tests/e2e_chat.yaml"
LLM_PROVEEDOR="eco"

for arg in "$@"; do
    case "$arg" in
        *.yaml|*.yml) SUITE_REL="$arg" ;;
        --llm) ;;
        *) ;;
    esac
done

ARGS=("$@")
for i in "${!ARGS[@]}"; do
    if [[ "${ARGS[$i]}" == "--llm" ]]; then
        next_idx=$((i + 1))
        if [[ $next_idx -lt ${#ARGS[@]} ]]; then
            LLM_PROVEEDOR="${ARGS[$next_idx]}"
        else
            echo "Error: --llm requiere un valor (eco, stub, gemini)" >&2
            exit 1
        fi
    fi
done

case "$LLM_PROVEEDOR" in
    eco)
        CHAT_YAML="${REPO_RAIZ}/configuracion/chat.eco.yaml"
        M2_PIP_EXTRA=""
        ;;
    stub)
        CHAT_YAML="${REPO_RAIZ}/configuracion/chat.stub.yaml"
        M2_PIP_EXTRA=""
        ;;
    gemini)
        CHAT_YAML="${REPO_RAIZ}/configuracion/chat.gemini.yaml"
        M2_PIP_EXTRA="google-genai"
        ;;
    *)
        echo "Error: --llm debe ser eco, stub o gemini (recibido: '${LLM_PROVEEDOR}')" >&2
        exit 1
        ;;
esac

SUITE_ABS="${REPO_RAIZ}/${SUITE_REL}"

# ---------------------------------------------------------------------------
# Leer secretos del .env (env > .env)
# ---------------------------------------------------------------------------
ENV_FILE="${REPO_RAIZ}/.env"

if [[ -z "${MASTER_SECRET:-}" ]]; then
    if [[ -f "$ENV_FILE" ]]; then
        MASTER_SECRET=$(grep -E '^\s*(export\s+)?MASTER_SECRET\s*=' "$ENV_FILE" \
            | head -1 | sed -E 's/^\s*(export\s+)?MASTER_SECRET\s*=\s*//' | tr -d '"'"'" | xargs)
    fi
fi
if [[ -z "${MASTER_SECRET:-}" ]]; then
    echo "Error: MASTER_SECRET no definido." >&2
    exit 1
fi

if [[ -z "${GEMINI_API_KEY:-}" ]]; then
    if [[ -f "$ENV_FILE" ]]; then
        GEMINI_API_KEY=$(grep -E '^\s*(export\s+)?GEMINI_API_KEY\s*=' "$ENV_FILE" \
            | head -1 | sed -E 's/^\s*(export\s+)?GEMINI_API_KEY\s*=\s*//' | tr -d '"'"'" | xargs || true)
    fi
fi
if [[ "$LLM_PROVEEDOR" == "gemini" ]] && [[ -z "${GEMINI_API_KEY:-}" ]]; then
    echo "Error: --llm gemini requiere GEMINI_API_KEY." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Pre-flight: verificar imagenes locales
# ---------------------------------------------------------------------------
declare -A MOD_IMAGES=(
    [mk]="${ILLARI_MK_IMAGE:-illari-mk:local}"
    [mv]="${ILLARI_MV_IMAGE:-illari-mv:local}"
    [ma]="${ILLARI_MA_IMAGE:-illari-ma:0.1.1}"
    [m2]="${ILLARI_M2_IMAGE:-illari-m2:0.1.1}"
)
FALTANTES=()
for mod in mk mv ma m2; do
    imagen="${MOD_IMAGES[$mod]}"
    if ! docker image inspect "${imagen}" &>/dev/null; then
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
echo "  OK: illari-mk:local, illari-mv:local, illari-ma:local, illari-m2:local"

# ---------------------------------------------------------------------------
# Validar prerequisitos
# ---------------------------------------------------------------------------
if [[ ! -f "$SUITE_ABS" ]]; then
    echo "Error: suite no encontrada: $SUITE_ABS" >&2
    exit 1
fi
if [[ ! -d "${REPO_RAIZ}/datos/qdrant_mv" ]]; then
    echo "Error: datos/qdrant_mv/ no encontrado." >&2
    echo "Ejecuta run_e2e_ingesta.sh primero para poblar la BDV." >&2
    exit 1
fi
if [[ ! -f "${REPO_RAIZ}/${COMPOSE_FILE}" ]]; then
    echo "Error: ${COMPOSE_FILE} no encontrado en ${REPO_RAIZ}" >&2
    exit 1
fi

ILLARI_TESTS="$(dirname "$REPO_RAIZ")/Illari/tests"
TEST_SUITE="${ILLARI_TESTS}/e2e_chat/test_suite.py"
if [[ ! -f "$TEST_SUITE" ]]; then
    echo "Error: test_suite.py no encontrado en ${TEST_SUITE}" >&2
    echo "Verifica que el repo Illari este en $(dirname "$REPO_RAIZ")/Illari" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Info
# ---------------------------------------------------------------------------
TS=$(date +%Y%m%d-%H%M%S)
OUT_DIR="${REPO_RAIZ}/tests/results"
OUT_FILE="${OUT_DIR}/e2e_chat-${TS}.txt"
mkdir -p "$OUT_DIR"

echo ""
echo "=== Illari E2E chat — minera ==="
echo "Suite  : ${SUITE_ABS}"
echo "LLM    : ${LLM_PROVEEDOR} (${CHAT_YAML})"
echo "Imagenes:"
for mod in mk mv ma m2; do echo "  ${mod}: ${MOD_IMAGES[$mod]}"; done
echo "Output : ${OUT_FILE}"
echo ""

# ---------------------------------------------------------------------------
# Fase 2 — Levantar servicios en background
# ---------------------------------------------------------------------------
echo "[2/3] Levantando servicios MK -> MV -> MA + M2..."
echo ""

MASTER_SECRET="${MASTER_SECRET}" \
CHAT_YAML="${CHAT_YAML}" \
M2_PIP_EXTRA="${M2_PIP_EXTRA}" \
GEMINI_API_KEY="${GEMINI_API_KEY:-}" \
docker compose -f "${REPO_RAIZ}/${COMPOSE_FILE}" down --remove-orphans 2>/dev/null || true

MASTER_SECRET="${MASTER_SECRET}" \
CHAT_YAML="${CHAT_YAML}" \
M2_PIP_EXTRA="${M2_PIP_EXTRA}" \
GEMINI_API_KEY="${GEMINI_API_KEY:-}" \
docker compose -f "${REPO_RAIZ}/${COMPOSE_FILE}" up -d \
    | tee -a "${OUT_FILE}"

# Esperar MV healthy
echo ""
echo "  Esperando mv-api en http://localhost:8002/health..."
MV_OK=0
for i in $(seq 1 24); do
    if python3 -c "
import urllib.request, sys
try:
    r = urllib.request.urlopen('http://localhost:8002/health', timeout=3)
    sys.exit(0 if r.status == 200 else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
        echo "  mv-api listo (intento ${i}/24)"
        MV_OK=1
        break
    fi
    echo "  Intento ${i}/24 — mv-api aun iniciando, esperando 5s..."
    sleep 5
done
if [[ $MV_OK -eq 0 ]]; then
    echo ""
    echo "FAILED: mv-api no respondio healthy en 120s." >&2
    MASTER_SECRET="${MASTER_SECRET}" \
    CHAT_YAML="${CHAT_YAML}" \
    M2_PIP_EXTRA="${M2_PIP_EXTRA}" \
    GEMINI_API_KEY="${GEMINI_API_KEY:-}" \
    docker compose -f "${REPO_RAIZ}/${COMPOSE_FILE}" logs mv-api --tail=30 >&2 || true
    MASTER_SECRET="${MASTER_SECRET}" \
    CHAT_YAML="${CHAT_YAML}" \
    M2_PIP_EXTRA="${M2_PIP_EXTRA}" \
    GEMINI_API_KEY="${GEMINI_API_KEY:-}" \
    docker compose -f "${REPO_RAIZ}/${COMPOSE_FILE}" down --remove-orphans 2>/dev/null || true
    exit 1
fi

# Esperar M2 healthy
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
    echo "FAILED: M2 no respondio healthy en 120s." >&2
    MASTER_SECRET="${MASTER_SECRET}" \
    CHAT_YAML="${CHAT_YAML}" \
    M2_PIP_EXTRA="${M2_PIP_EXTRA}" \
    GEMINI_API_KEY="${GEMINI_API_KEY:-}" \
    docker compose -f "${REPO_RAIZ}/${COMPOSE_FILE}" logs --tail=30 >&2 || true
    MASTER_SECRET="${MASTER_SECRET}" \
    CHAT_YAML="${CHAT_YAML}" \
    M2_PIP_EXTRA="${M2_PIP_EXTRA}" \
    GEMINI_API_KEY="${GEMINI_API_KEY:-}" \
    docker compose -f "${REPO_RAIZ}/${COMPOSE_FILE}" down --remove-orphans 2>/dev/null || true
    exit 1
fi
echo ""

# ---------------------------------------------------------------------------
# Fase 3 — Validacion con pytest local
# ---------------------------------------------------------------------------
echo "[3/3] Ejecutando pytest E2E chat..."
echo ""

ILLARI_E2E_SUITE="${SUITE_ABS}" \
ILLARI_E2E_CLIENTE="${REPO_RAIZ}" \
ILLARI_E2E_M2_URL="http://localhost:8000" \
ILLARI_E2E_MA_URL="http://localhost:8001" \
PYTHONUNBUFFERED=1 \
python3 -m pytest "${TEST_SUITE}" -v -s -m e2e \
    --rootdir="${ILLARI_TESTS}/.." \
    | tee -a "${OUT_FILE}"

PYTEST_EXIT="${PIPESTATUS[0]}"

MASTER_SECRET="${MASTER_SECRET}" \
CHAT_YAML="${CHAT_YAML}" \
M2_PIP_EXTRA="${M2_PIP_EXTRA}" \
GEMINI_API_KEY="${GEMINI_API_KEY:-}" \
docker compose -f "${REPO_RAIZ}/${COMPOSE_FILE}" down --remove-orphans 2>/dev/null || true

echo ""
if [[ $PYTEST_EXIT -eq 0 ]]; then
    echo "PASSED — resultado guardado en: ${OUT_FILE}"
else
    echo "FAILED (exit ${PYTEST_EXIT}) — resultado guardado en: ${OUT_FILE}"
fi

exit "$PYTEST_EXIT"
