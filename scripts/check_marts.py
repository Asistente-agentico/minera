import duckdb
con = duckdb.connect("/cliente/minera/datos/minera.duckdb", read_only=True)

tablas = [
    "silver_entidad_sesion_medicion",
    "silver_detalle_medicion",
    "bronce_mediciones",
]
for t in tablas:
    try:
        n = con.execute(f"SELECT COUNT(*) FROM main.{t}").fetchone()[0]
        print(f"{t}: {n} filas")
    except Exception as e:
        print(f"{t}: ERROR - {e}")

try:
    lim = con.execute(
        "SELECT MIN(concentracion_min_mg_m3) FROM main_semillas.semaforo_polvo_respirable WHERE es_sobre_limite_interno = true"
    ).fetchone()[0]
    print(f"limite_interno: {lim}")
except Exception as e:
    print(f"limite_interno: ERROR - {e}")

# Muestra sample de bronce_mediciones
try:
    rows = con.execute(
        "SELECT planta, semana, concentracion_mg_m3 FROM main.bronce_mediciones LIMIT 5"
    ).fetchall()
    print("bronce sample:", rows)
except Exception as e:
    print(f"bronce sample: ERROR - {e}")
