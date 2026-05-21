"""Crea la colección Qdrant en datos/qdrant_mv/ si no existe.

Lee dimensiones y nombre de colección desde configuracion/dominio.yaml y
pre-crea la colección con Distance=COSINE antes de que el compose levante MV.
Esto permite que el contenedor MV (imagen dev-0.7.x sin ensure_collection)
encuentre la colección ya creada y pueda hacer upsert directamente.

Uso:
    python3 scripts/preparar_bdv.py --raiz /cliente/minera
"""
from __future__ import annotations

import argparse
from pathlib import Path

import yaml
from qdrant_client import QdrantClient
from qdrant_client.http.models import Distance, VectorParams


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raiz", type=Path, default=Path.cwd())
    args = parser.parse_args()
    raiz = args.raiz.resolve()

    dominio_path = raiz / "configuracion" / "dominio.yaml"
    dominio = yaml.safe_load(dominio_path.read_text()) or {}
    emb = dominio.get("embeddings") or {}
    vs = emb.get("vector_store") or {}

    dim = int(emb.get("dimensiones", 1536))
    collection = vs.get("collection", "chunks")
    qdrant_path = str(raiz / "datos" / "qdrant_mv")

    client = QdrantClient(path=qdrant_path)
    try:
        existing = {c.name for c in client.get_collections().collections}
        if collection not in existing:
            client.create_collection(
                collection_name=collection,
                vectors_config=VectorParams(size=dim, distance=Distance.COSINE),
            )
            print(f"  [OK] Colección '{collection}' creada (dim={dim}) en {qdrant_path}")
        else:
            print(f"  [OK] Colección '{collection}' ya existe en {qdrant_path}")
    finally:
        client.close()


if __name__ == "__main__":
    main()
