"""Carga los CSVs declarados en aterrizaje.yaml en el schema landing de DuckDB.

Lee configuracion/aterrizaje.yaml, crea el schema landing si no existe y
carga cada fuente con CREATE OR REPLACE TABLE landing.<nombre> AS SELECT *
FROM read_csv_auto(...). Idempotente.

Uso:
    python scripts/cargar_landing.py --raiz /cliente/minera
"""
from __future__ import annotations

import argparse
from pathlib import Path

import duckdb
import yaml


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raiz", type=Path, required=True,
                        help="Directorio raíz del repo minera.")
    args = parser.parse_args()
    raiz = args.raiz.resolve()

    aterrizaje_path = raiz / "configuracion" / "aterrizaje.yaml"
    db_path = raiz / "datos" / "minera.duckdb"

    cfg = yaml.safe_load(aterrizaje_path.read_text())
    fuentes = cfg.get("landing", [])

    con = duckdb.connect(str(db_path))
    con.execute("CREATE SCHEMA IF NOT EXISTS landing")

    for src in fuentes:
        nombre = src["nombre"]
        ubicacion: str = src["ubicacion"]
        # Rutas absolutas en aterrizaje.yaml usan /datos/ (path dentro del
        # contenedor Docker original). Se resuelven relativas a --raiz.
        csv_path = raiz / ubicacion.lstrip("/") if ubicacion.startswith("/") else raiz / ubicacion

        if not csv_path.exists():
            print(f"  [SKIP] {nombre}: {csv_path} no encontrado")
            continue

        con.execute(
            f"CREATE OR REPLACE TABLE landing.{nombre} AS "
            f"SELECT * FROM read_csv_auto('{csv_path}', header=true)"
        )
        n = con.execute(f"SELECT COUNT(*) FROM landing.{nombre}").fetchone()[0]
        print(f"  [OK] landing.{nombre}: {n} filas desde {csv_path.name}")

    con.close()
    print("Landing cargado.")


if __name__ == "__main__":
    main()
