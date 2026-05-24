#!/usr/bin/env sh
# Descarga el modelo fastembed a datos/fastembed_cache/ usando Python local.
# Ese directorio se monta como caché en mv-api durante el E2E ingesta.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="$SCRIPT_DIR/../datos/fastembed_cache"

mkdir -p "$CACHE_DIR"

echo "Cache: $CACHE_DIR"
echo ""

export FASTEMBED_CACHE_PATH="$CACHE_DIR"

pip install fastembed -q || exit 1

python3 -c "
from fastembed import TextEmbedding
TextEmbedding('sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2')
print('modelo descargado OK')
" || exit 1

echo ""
echo "OK — modelo en $CACHE_DIR"
