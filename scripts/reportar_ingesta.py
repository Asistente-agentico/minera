#!/usr/bin/env python3
"""Reporte de métricas de la corrida E2E ingesta.

Dos subcomandos:

  snapshot --raiz <RAIZ> --salida <RUTA_JSON>
      Captura el estado actual de las tablas del medallón (duckdb) y de la
      BDV (Qdrant embebido) a un JSON. Pensado para correr ANTES del wipe
      que hace el runner E2E.

  reporte --raiz <RAIZ> --pre <RUTA_JSON_PRE>
      Imprime un reporte legible al stdout comparando el snapshot pre con
      el estado actual + el archivo `datos/chunks_generados_dev.json`.

Diseño defensivo: cualquier fallo al leer una sección la deja como
"(no disponible: <razón>)" pero no aborta el script, para no romper la
corrida E2E.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from collections import Counter
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

# En Windows, stdout default es cp1252 cuando se pipea (Tee-Object/tee).
# El reporte contiene caracteres no-ASCII (Δ, tildes en "medallón"). Forzar
# UTF-8 evita UnicodeEncodeError al imprimir.
try:
    sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
    sys.stderr.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
except Exception:  # noqa: BLE001
    pass

try:
    import yaml
except ImportError:
    yaml = None  # type: ignore[assignment]


# Nombres a ignorar al introspectar las tablas del medallón. Lista corta
# y expandible: cubre internos del motor de transformación y cualquier
# tabla con prefijo `_`.
TABLAS_IGNORAR_PREFIJOS = ("_",)
TABLAS_IGNORAR_EXACTAS = frozenset({
    # Tablas internas del motor de transformación (no del usuario).
    # Si aparecen otras, agregarlas acá.
})


# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------


def _resolver_path_duckdb(raiz: Path) -> Path:
    """Resuelve el path de la duckdb leyendo app.yaml.datos.url; fallback
    a `<raiz>/datos/minera.duckdb`."""
    app_yaml = raiz / "configuracion" / "app.yaml"
    if yaml is not None and app_yaml.exists():
        try:
            doc = yaml.safe_load(app_yaml.read_text(encoding="utf-8")) or {}
            url = (doc.get("datos") or {}).get("url")
            if url:
                p = Path(url)
                if not p.is_absolute():
                    p = raiz / url
                return p
        except Exception:  # noqa: BLE001
            pass
    return raiz / "datos" / "minera.duckdb"


def _capturar_tablas(db_path: Path) -> dict[str, Any]:
    """Devuelve dict con tablas del medallón y sus conteos. Si la duckdb
    no existe o falla, retorna estructura con `existe: false`."""
    if not db_path.exists():
        return {"existe": False, "tablas": []}

    try:
        import duckdb  # noqa: WPS433
    except ImportError:
        return {"existe": True, "tablas": [], "error": "duckdb no instalado"}

    try:
        con = duckdb.connect(str(db_path), read_only=True)
    except Exception as exc:  # noqa: BLE001
        return {"existe": True, "tablas": [], "error": f"connect: {exc}"}

    try:
        rows = con.execute(
            """
            SELECT table_schema, table_name
            FROM information_schema.tables
            WHERE table_type = 'BASE TABLE'
              AND table_schema NOT IN ('information_schema', 'pg_catalog')
            ORDER BY table_schema, table_name
            """
        ).fetchall()

        tablas: list[dict[str, Any]] = []
        for esquema, nombre in rows:
            if nombre.startswith(TABLAS_IGNORAR_PREFIJOS):
                continue
            if nombre in TABLAS_IGNORAR_EXACTAS:
                continue
            try:
                qn = f'"{esquema}"."{nombre}"'
                count = con.execute(f"SELECT COUNT(*) FROM {qn}").fetchone()[0]
            except Exception as exc:  # noqa: BLE001
                tablas.append({"esquema": esquema, "nombre": nombre, "count": None, "error": str(exc)[:120]})
                continue
            tablas.append({"esquema": esquema, "nombre": nombre, "count": int(count)})
        return {"existe": True, "tablas": tablas}
    finally:
        con.close()


def _capturar_bdv(raiz: Path) -> dict[str, Any]:
    """Lee la BDV Qdrant embebida en `<raiz>/datos/qdrant_mv/`. Devuelve
    `count` y el set completo de `chunk_ids` (necesario para diferenciar
    nuevos vs reemplazos)."""
    qdrant_dir = raiz / "datos" / "qdrant_mv"
    if not qdrant_dir.exists():
        return {"existe": False, "count": 0, "chunk_ids": []}

    try:
        from qdrant_client import QdrantClient  # noqa: WPS433
    except ImportError:
        return {"existe": True, "count": 0, "chunk_ids": [], "error": "qdrant_client no instalado"}

    try:
        client = QdrantClient(path=str(qdrant_dir))
    except Exception as exc:  # noqa: BLE001
        return {"existe": True, "count": 0, "chunk_ids": [], "error": f"connect: {exc}"}

    try:
        count = client.count("chunks", exact=True).count
    except Exception as exc:  # noqa: BLE001
        try:
            client.close()
        except Exception:  # noqa: BLE001
            pass
        return {"existe": True, "count": 0, "chunk_ids": [], "error": f"count: {exc}"}

    ids: list[str] = []
    if count > 0:
        offset: Any = None
        try:
            while True:
                points, offset = client.scroll(
                    collection_name="chunks",
                    limit=512,
                    with_payload=False,
                    with_vectors=False,
                    offset=offset,
                )
                ids.extend(str(p.id) for p in points)
                if offset is None:
                    break
        except Exception as exc:  # noqa: BLE001
            try:
                client.close()
            except Exception:  # noqa: BLE001
                pass
            return {"existe": True, "count": int(count), "chunk_ids": ids, "error": f"scroll: {exc}"}

    try:
        client.close()
    except Exception:  # noqa: BLE001
        pass
    return {"existe": True, "count": int(count), "chunk_ids": ids}


def _capturar_snapshot(raiz: Path) -> dict[str, Any]:
    """Snapshot completo: tablas del medallón + BDV."""
    return {
        "timestamp": datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
        "tablas": _capturar_tablas(_resolver_path_duckdb(raiz)),
        "bdv": _capturar_bdv(raiz),
    }


def _leer_chunks_generados(raiz: Path) -> list[dict[str, Any]] | None:
    p = raiz / "datos" / "chunks_generados_dev.json"
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001
        return None


def _md5_id(chunk_clave: str) -> str:
    """Mismo cálculo que mv/api/routers/chunks.py: chunk_id = MD5(chunk_clave)."""
    return hashlib.md5(chunk_clave.encode("utf-8"), usedforsecurity=False).hexdigest()


# ----------------------------------------------------------------------
# Subcomando: snapshot
# ----------------------------------------------------------------------


def cmd_snapshot(args: argparse.Namespace) -> int:
    raiz = Path(args.raiz).resolve()
    salida = Path(args.salida).resolve()
    salida.parent.mkdir(parents=True, exist_ok=True)
    snapshot = _capturar_snapshot(raiz)
    salida.write_text(json.dumps(snapshot, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0


# ----------------------------------------------------------------------
# Subcomando: reporte
# ----------------------------------------------------------------------


def _formato_signo(delta: int) -> str:
    if delta > 0:
        return f"+{delta}"
    if delta < 0:
        return str(delta)
    return "0"


def _print(line: str, archivo) -> None:
    print(line)
    if archivo is not None:
        archivo.write(line + "\n")


def cmd_reporte(args: argparse.Namespace) -> int:
    raiz = Path(args.raiz).resolve()

    # Snapshot pre (puede no existir si es la primera corrida).
    pre: dict[str, Any] = {}
    pre_path = Path(args.pre) if args.pre else None
    if pre_path is not None and pre_path.exists():
        try:
            pre = json.loads(pre_path.read_text(encoding="utf-8"))
        except Exception as exc:  # noqa: BLE001
            print(f"WARN: no se pudo leer snapshot pre ({exc}); se asumira corrida inicial.", file=sys.stderr)

    pre_tablas: dict[str, int] = {}
    for t in (pre.get("tablas") or {}).get("tablas", []) or []:
        if t.get("count") is None:
            continue
        key = f"{t['esquema']}.{t['nombre']}"
        pre_tablas[key] = int(t["count"])

    pre_bdv = (pre.get("bdv") or {})
    pre_chunk_ids: set[str] = set((pre_bdv.get("chunk_ids") or []))
    pre_bdv_count = int(pre_bdv.get("count") or 0)

    # Snapshot post (estado actual).
    post = _capturar_snapshot(raiz)

    # ----- Imprimir reporte -----
    ANCHO = 84
    sep = "=" * ANCHO
    sub = "-" * ANCHO

    out = None
    archivo = None  # Tee solo via stdout; el runner usa Tee-Object/tee.

    _print("", archivo)
    _print(sep, archivo)
    _print("REPORTE INGESTA E2E".center(ANCHO), archivo)
    _print(sep, archivo)

    # --- Modelos del medallon ---
    _print("", archivo)
    _print("Modelos del medallón", archivo)
    _print(f"  {'Tabla':<50}{'Antes':>10}{'Ahora':>10}{'Δ':>10}", archivo)
    _print(sub, archivo)

    post_tablas = post.get("tablas") or {}
    if not post_tablas.get("existe"):
        _print(f"  (no disponible: {post_tablas.get('error', 'duckdb no existe aun')})", archivo)
        total_antes = sum(pre_tablas.values())
        total_ahora = 0
    else:
        total_antes = 0
        total_ahora = 0
        for t in post_tablas.get("tablas") or []:
            key = f"{t['esquema']}.{t['nombre']}"
            antes = pre_tablas.get(key, 0)
            ahora = t.get("count")
            if ahora is None:
                _print(f"  {key:<50}{antes:>10}{'N/A':>10}{'N/A':>10}", archivo)
                continue
            delta = ahora - antes
            _print(f"  {key:<50}{antes:>10}{ahora:>10}{_formato_signo(delta):>10}", archivo)
            total_antes += antes
            total_ahora += ahora

    _print(sub, archivo)
    _print(
        f"  {'TOTAL':<50}{total_antes:>10}{total_ahora:>10}{_formato_signo(total_ahora - total_antes):>10}",
        archivo,
    )

    # --- Chunks por regla ---
    _print("", archivo)
    _print("Chunks por regla (esta corrida)", archivo)
    chunks = _leer_chunks_generados(raiz)
    if chunks is None:
        _print("  (no disponible: chunks_generados_dev.json no encontrado)", archivo)
        generated_ids: set[str] = set()
        total_gen = 0
    else:
        conteos = Counter(c.get("regla_id", "(sin regla)") for c in chunks)
        for regla in sorted(conteos):
            _print(f"  {regla:<50}{conteos[regla]:>10}", archivo)
        _print(sub, archivo)
        total_gen = len(chunks)
        _print(f"  {'TOTAL generados':<50}{total_gen:>10}", archivo)
        generated_ids = {_md5_id(c["chunk_clave"]) for c in chunks if c.get("chunk_clave")}

    # --- BDV ---
    _print("", archivo)
    _print("Cambios en la BDV (vector store)", archivo)
    bdv_post = post.get("bdv") or {}
    finales = int(bdv_post.get("count") or 0)
    finales_ids: set[str] = set(bdv_post.get("chunk_ids") or [])

    nuevos = len(generated_ids - pre_chunk_ids)
    reemplazos = len(generated_ids & pre_chunk_ids)
    descartados = max(0, total_gen - len(generated_ids & finales_ids)) if finales_ids else 0

    _print(f"  {'Chunks pre-corrida':<50}{pre_bdv_count:>10}", archivo)
    _print(f"  {'Chunks generados en la corrida':<50}{total_gen:>10}", archivo)
    _print(f"    {'de los cuales nuevos':<48}{nuevos:>10}", archivo)
    _print(f"    {'de los cuales reemplazos':<48}{reemplazos:>10}", archivo)
    if descartados:
        _print(f"    {'descartados por MV (no llegaron a BDV)':<48}{descartados:>10}", archivo)
    _print(f"  {'Chunks finales en BDV':<50}{finales:>10}", archivo)

    _print(sep, archivo)
    _print("", archivo)
    return 0


# ----------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_snap = sub.add_parser("snapshot", help="Captura estado a JSON.")
    p_snap.add_argument("--raiz", required=True, help="Raíz del repo cliente.")
    p_snap.add_argument("--salida", required=True, help="Ruta de salida del JSON.")
    p_snap.set_defaults(func=cmd_snapshot)

    p_rep = sub.add_parser("reporte", help="Imprime reporte legible.")
    p_rep.add_argument("--raiz", required=True, help="Raíz del repo cliente.")
    p_rep.add_argument("--pre", default="", help="Ruta al snapshot pre (opcional).")
    p_rep.set_defaults(func=cmd_reporte)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
