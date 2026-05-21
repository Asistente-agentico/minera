docker run --rm \
  --entrypoint sh \
  -v "$(pwd)/datos/fastembed_cache:/home/asistente/.cache" \
  ghcr.io/asistente-agentico/illari:dev-0.7.1 \
  -c "pip install fastembed -q && \
  python3 -c \"
from fastembed import TextEmbedding; \
TextEmbedding('sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2'); \
print('modelo descargado OK')\""

