import duckdb
con = duckdb.connect("/cliente/minera/datos/minera.duckdb", read_only=True)

snaps = [
    "snap_mediciones_prechancado",
    "snap_mediciones_chancado_2_3",
    "snap_mediciones_molienda_sag",
]
for t in snaps:
    try:
        n = con.execute(f"SELECT COUNT(*) FROM instantaneos.{t}").fetchone()[0]
        cols = [d[0] for d in con.execute(f"SELECT * FROM instantaneos.{t} LIMIT 0").description]
        print(f"{t}: {n} filas, cols={cols[:8]}")
    except Exception as e:
        print(f"{t}: ERROR - {e}")
