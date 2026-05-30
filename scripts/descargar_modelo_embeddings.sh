#!/usr/bin/env bash
# descargar_modelo_embeddings.sh — Pre-descarga el modelo de embeddings al
# cache del host (datos/fastembed_cache/). Los containers exigen que el
# modelo correcto ya esté presente; este script lo prepara una vez por
# máquina (idempotente).
#
# Uso:
#   bash scripts/descargar_modelo_embeddings.sh

set -euo pipefail

REPO_RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
CACHE_DIR="${REPO_RAIZ}/datos/fastembed_cache"
MODELO="sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"

echo ""
echo "=== Descarga del modelo de embeddings ==="
echo "Cache : ${CACHE_DIR}"
echo ""

mkdir -p "${CACHE_DIR}"

# Verificación rápida: ¿ya está?
if find "${CACHE_DIR}" -type d -name "models--sentence-transformers--*" 2>/dev/null | grep -q .; then
    yaPath=$(find "${CACHE_DIR}" -type d -name "models--sentence-transformers--*" | head -1)
    echo "OK: modelo ya presente en ${yaPath}"
    echo "    No se descarga nada."
    exit 0
fi

export HF_HOME="${CACHE_DIR}"

echo "Descargando ${MODELO} (~117 MB la primera vez)..."
python3 - <<PYEOF
import sys
try:
    from fastembed import TextEmbedding
except ImportError:
    sys.stderr.write("fastembed no instalado. Ejecuta: pip install fastembed\n")
    sys.exit(2)
modelo = "${MODELO}"
print(f"Cargando {modelo}...", flush=True)
TextEmbedding(model_name=modelo)
print("OK", flush=True)
PYEOF

echo ""
echo "Modelo descargado al cache."
echo "Ahora podes levantar el stack:"
echo "  bash scripts/dev-ui.sh up           (UI completa)"
echo "  bash scripts/run_e2e_chat.sh        (E2E chat)"
echo "  bash scripts/run_e2e_ingesta.sh     (E2E ingesta)"
