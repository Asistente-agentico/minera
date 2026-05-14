"""
Genera chunks del caso minera desde los modelos oro de DuckDB.

Para cada regla declarada en rules.yaml:
  - Ejecuta configuracion/sql/<regla>.sql contra DuckDB
  - Renderiza cada fila con la plantilla configuracion/templates/<regla>.txt
  - Computa chunk_id desde id_synthesis (md5 de las columnas identificadoras)
  - Materializa el PayloadChunk con HMAC usando las funciones crypto del producto diseno

Salida: datos/chunks_generados.json  (gitignored por datos/)

Uso:
    python scripts/generar_chunks.py
    python scripts/generar_chunks.py --dry-run   # imprime sin guardar
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import sys
import uuid
from decimal import Decimal
from datetime import date
from pathlib import Path

import duckdb
import yaml

SCRIPT_DIR = Path(__file__).parent.resolve()
MINERA_ROOT = SCRIPT_DIR.parent
DISENO_ROOT = (MINERA_ROOT / ".." / "diseno").resolve()
DB_PATH = str(MINERA_ROOT / "datos" / "minera.duckdb")
SQL_DIR = MINERA_ROOT / "configuracion" / "sql"
TEMPLATES_DIR = MINERA_ROOT / "configuracion" / "templates"
RULES_PATH = MINERA_ROOT / "configuracion" / "rules" / "rules.yaml"
MANIFEST_PATH = MINERA_ROOT / "modelos" / "target" / "manifest.json"
OUT_PATH = str(MINERA_ROOT / "datos" / "chunks_generados.json")
OUT_DEV_PATH = str(MINERA_ROOT / "datos" / "chunks_generados_dev.json")

# Importa utilidades crypto del producto diseno
sys.path.insert(0, str(DISENO_ROOT))
from core.security.crypto import (  # noqa: E402
    calcular_hash_md5,
    calcular_integrity_tag,
    cifrar_con_clave,
    cifrar_dek_con_kek,
    cifrar_texto_con_dek,
    derivar_kek,
    generar_dek,
)

# MASTER_SECRET de prueba — en producción se carga desde el Secret Manager
# del cliente vía la variable de entorno MASTER_SECRET.
MASTER_SECRET_TEST: bytes = b"minera_test_MASTER_SECRET_32by!!"
KEK_VERSION = "v1"


def _cargar_rules() -> dict[str, dict]:
    data = yaml.safe_load(RULES_PATH.read_text(encoding="utf-8"))
    return {r["id"]: r for r in data["rules"]}


def _cargar_sql(regla_id: str) -> str:
    return (SQL_DIR / f"{regla_id}.sql").read_text(encoding="utf-8").strip()


def _cargar_template(regla_id: str) -> str:
    return (TEMPLATES_DIR / f"{regla_id}.txt").read_text(encoding="utf-8").strip()


def _generar_chunk_id(id_synthesis: dict, row: dict) -> str:
    sep = id_synthesis.get("separator", "_")
    cols = id_synthesis["columns"]
    key = sep.join(str(row[c]) for c in cols)
    return hashlib.md5(key.encode()).hexdigest()


def _fmt(v, default: str = "—") -> str:
    if v is None:
        return default
    if isinstance(v, Decimal):
        return str(v)
    if isinstance(v, date):
        return v.isoformat()
    return str(v)


def _cargar_transform_hash() -> str:
    raw = MANIFEST_PATH.read_bytes()
    return hashlib.md5(raw, usedforsecurity=False).hexdigest()


def _serializar_valor(v):
    """Convierte valores DuckDB a tipos JSON-serializables para datos_negocio."""
    if v is None:
        return None
    if isinstance(v, Decimal):
        return float(v)
    if isinstance(v, date):
        return v.isoformat()
    return v


def _resolver_dimensiones(dims_declaradas: dict, row: dict) -> dict:
    """Construye el dict de dimensiones del chunk.

    El valor especial "todas" indica que la dimensión varía por fila
    y debe tomarse del dato correspondiente (ej. planta).
    """
    return {
        clave: row[clave] if valor == "todas" else valor
        for clave, valor in dims_declaradas.items()
    }


def _procesar_regla(
    con: duckdb.DuckDBPyConnection,
    regla_id: str,
    regla_cfg: dict,
    corrida_id: str,
    valido_desde: str,
    transform_hash: str,
    kek: bytes,
) -> list[dict]:
    id_synthesis = regla_cfg["id_synthesis"]
    dims_declaradas = regla_cfg.get("dimensiones", {})
    sql = _cargar_sql(regla_id)
    tpl = _cargar_template(regla_id)

    result = con.execute(sql)
    cols = [d[0] for d in result.description]
    rows = result.fetchall()

    chunks = []
    for r in rows:
        d = dict(zip(cols, r))

        chunk_id = _generar_chunk_id(id_synthesis, d)
        ctx = {k: _fmt(v) for k, v in d.items()}
        texto = tpl.format_map(ctx)

        datos_negocio = {k: _serializar_valor(v) for k, v in d.items()}
        dimensiones = _resolver_dimensiones(dims_declaradas, d)

        hash_contenido = calcular_hash_md5(texto)
        firma_hmac = calcular_integrity_tag(
            chunk_id, hash_contenido, texto, MASTER_SECRET_TEST
        )

        campos_pii = regla_cfg.get("pii_tokens", [])
        pii_tokens = {campo: d[campo] for campo in campos_pii if campo in d}

        dek = generar_dek()
        ciphertext_b64 = base64.b64encode(cifrar_texto_con_dek(texto, dek)).decode("ascii")
        datos_negocio_b64 = base64.b64encode(
            cifrar_con_clave(dek, json.dumps(datos_negocio, ensure_ascii=False, default=str).encode("utf-8"))
        ).decode("ascii")
        dek_cifrada_b64 = base64.b64encode(cifrar_dek_con_kek(dek, kek)).decode("ascii")

        chunks.append({
            "chunk_id": chunk_id,
            "texto_dev": texto,  # solo para chunks_generados_dev.json
            "id": {
                "chunk_id": chunk_id,
                "regla_id": regla_id,
                "fecha_creacion": valido_desde,
            },
            "vigencia": {
                "valido_hasta": -1,
                "politica_vigencia": regla_cfg.get("politica_vigencia", "preservar"),
            },
            "gobernanza": {
                "dimensiones": dimensiones,
                "dimensiones_en_texto": regla_cfg.get("dimensiones_en_texto", []),
                "pii_estrategia": regla_cfg.get("pii_estrategia", "tokens"),
                "pii_tokens": pii_tokens,
                "estrategia_olvido": regla_cfg.get("estrategia_olvido", "borrar_chunk"),
            },
            "integridad": {
                "hash_contenido": hash_contenido,
                "firma_hmac": firma_hmac,
            },
            "trazabilidad": {
                "corrida_id": corrida_id,
                "transform_hash": transform_hash,
            },
            "cifrado": {
                "ciphertext": ciphertext_b64,
                "datos_negocio": datos_negocio_b64,
                "dek_cifrada": dek_cifrada_b64,
                "kek_version": KEK_VERSION,
            },
        })

    return chunks


def _aplanar_chunk(ch: dict) -> dict:
    """Produce la versión plana del chunk para el archivo de producción."""
    plano = {"chunk_id": ch["chunk_id"]}
    for grupo in ("id", "vigencia", "gobernanza", "integridad", "trazabilidad", "cifrado"):
        for k, v in ch.get(grupo, {}).items():
            if k != "chunk_id":
                plano[k] = v
    return plano


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="Imprime sin guardar")
    parser.add_argument("--dev", action="store_true",
                        help="Guarda también chunks_generados_dev.json con texto en plano")
    args = parser.parse_args()

    corrida_id = str(uuid.uuid4())
    valido_desde = date.today().isoformat()
    transform_hash = _cargar_transform_hash()
    rules = _cargar_rules()
    kek = derivar_kek(MASTER_SECRET_TEST, KEK_VERSION)

    print(f"Conectando a DuckDB: {DB_PATH}")
    con = duckdb.connect(DB_PATH, read_only=True)

    todos_los_chunks: list[dict] = []
    for regla_id, regla_cfg in rules.items():
        chunks = _procesar_regla(
            con, regla_id, regla_cfg, corrida_id, valido_desde, transform_hash, kek
        )
        print(f"  [{regla_id}] {len(chunks)} chunks generados")
        todos_los_chunks.extend(chunks)

    con.close()

    print(f"\nTotal: {len(todos_los_chunks)} chunks | corrida_id: {corrida_id}")

    if args.dry_run:
        for ch in todos_los_chunks:
            print(f"\n--- {ch['payload']['regla_id']} | {ch['chunk_id']}")
            print(ch["texto_dev"])
        return

    # Archivo de producción: plano (sin grupos, sin texto_dev)
    chunks_prod = [_aplanar_chunk(ch) for ch in todos_los_chunks]
    with open(OUT_PATH, "w", encoding="utf-8") as f:
        json.dump(chunks_prod, f, ensure_ascii=False, indent=2)
    print(f"Guardado en: {OUT_PATH}")

    if args.dev:
        # Archivo dev: agrupado con texto_dev para debugging y smoke test
        chunks_dev = [{k: v for k, v in ch.items()} for ch in todos_los_chunks]
        with open(OUT_DEV_PATH, "w", encoding="utf-8") as f:
            json.dump(chunks_dev, f, ensure_ascii=False, indent=2)
        print(f"Dev guardado en: {OUT_DEV_PATH}")


if __name__ == "__main__":
    main()
