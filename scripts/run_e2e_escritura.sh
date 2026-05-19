#!/usr/bin/env bash
# run_e2e_escritura.sh — Ejecuta el pipeline M1 en Docker y valida la salida.
#
# Fases:
#   1. Borrar qdrant_data/ (partida limpia para cuando se integre MV+MK).
#   2. Docker: ejecutar M1 CLI (dbt → chunker → chunks_generados_dev.json).
#      MV no se inicia (mk/ no está en la imagen Docker aún — deuda pendiente).
#      M1 escribe chunks_generados_dev.json (--dev) antes del intento a MV y
#      continúa con degradación silenciosa si MV no responde.
#   3. Local: pytest valida chunks_generados_dev.json contra e2e_escritura.yaml.
#
# Uso:
#   bash scripts/run_e2e_escritura.sh
#   bash scripts/run_e2e_escritura.sh tests/e2e_escritura.yaml
#
# Variables de entorno:
#   ILLARI_TAG  — tag de la imagen Docker (default: dev-0.7.0)
#
# Nota: MASTER_SECRET no es necesario para este script. El orquestador M1
# envía chunks en texto plano a MV; el cifrado lo hace MV (no M1).

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------
IMAGEN_BASE="ghcr.io/asistente-agentico/illari"
IMAGEN="${IMAGEN_BASE}:${ILLARI_TAG:-dev-0.7.0}"

REPO_RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
SUITE_REL="tests/e2e_escritura.yaml"

for arg in "$@"; do
    case "$arg" in
        *.yaml|*.yml) SUITE_REL="$arg" ;;
        *) echo "Argumento desconocido: $arg" >&2; exit 1 ;;
    esac
done

SUITE_ABS="${REPO_RAIZ}/${SUITE_REL}"

# ---------------------------------------------------------------------------
# Validar suite y dependencias
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
OUT_FILE="${OUT_DIR}/e2e_escritura-${TS}.txt"
mkdir -p "$OUT_DIR"

echo ""
echo "=== Illari E2E escritura — minera ==="
echo "Suite  : ${SUITE_ABS}"
echo "Imagen : ${IMAGEN}"
echo "Output : ${OUT_FILE}"
echo ""

# ---------------------------------------------------------------------------
# Fase 1 — Borrar qdrant_data/ (partida limpia)
# ---------------------------------------------------------------------------
echo "[1/3] Limpiando qdrant_data/..."
QDRANT_DIR="${REPO_RAIZ}/qdrant_data"
if [[ -d "$QDRANT_DIR" ]]; then
    rm -rf "$QDRANT_DIR"
    echo "  Eliminado: ${QDRANT_DIR}"
else
    echo "  qdrant_data/ no existe, nada que limpiar."
fi
echo ""

# ---------------------------------------------------------------------------
# Fase 2 — Docker: M1 CLI (dbt + chunker → chunks_generados.json)
# ---------------------------------------------------------------------------
echo "[2/3] Ejecutando pipeline M1 en Docker..."
echo "  Imagen: ${IMAGEN}"
echo "  (MV no iniciado — mk/ no está en la imagen; MV se integra en próxima versión)"
echo ""

PIPELINE_CMD='
pip install fastembed -q 2>/dev/null
export MINERA_DB_PATH=/cliente/minera/datos/minera.duckdb
python -m m1.core.orquestador.cli ejecutar \
    --dev \
    --config /cliente/minera/configuracion \
    --schemas /app/configuracion/schemas \
    --medallon /cliente/minera/modelos \
    --profiles-dir /cliente/minera/modelos \
    --raiz /cliente/minera
'

docker pull "${IMAGEN}"
echo ""

docker run --rm \
    -v "${REPO_RAIZ}:/cliente/minera" \
    -e "MINERA_DB_PATH=/cliente/minera/datos/minera.duckdb" \
    --entrypoint sh \
    "${IMAGEN}" \
    -c "${PIPELINE_CMD}" \
    | tee -a "${OUT_FILE}"

DOCKER_EXIT="${PIPESTATUS[0]}"

if [[ $DOCKER_EXIT -ne 0 ]]; then
    echo ""
    echo "FAILED pipeline Docker (exit ${DOCKER_EXIT}) — ver: ${OUT_FILE}"
    exit "$DOCKER_EXIT"
fi

if [[ ! -f "${REPO_RAIZ}/datos/chunks_generados_dev.json" ]]; then
    echo ""
    echo "FAILED: chunks_generados_dev.json no fue generado por el pipeline." >&2
    exit 1
fi

echo ""
echo "  Pipeline completado. chunks_generados_dev.json generado."
echo ""

# ---------------------------------------------------------------------------
# Fase 3 — Validación local con pytest
# ---------------------------------------------------------------------------
echo "[3/3] Validando chunks_generados_dev.json con pytest..."
echo ""

ILLARI_E2E_ESCRITURA="${SUITE_ABS}" \
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
