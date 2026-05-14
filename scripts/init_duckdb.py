"""
Carga los CSV de mediciones en DuckDB con el schema correcto.
El pipeline del producto (diseno) haría esto automáticamente vía el motor de ingesta.
Este script simula esa carga para el caso de prueba.

Uso: python scripts/init_duckdb.py
"""
import duckdb
import os

DB_PATH = os.path.join(os.path.dirname(__file__), '..', 'datos', 'minera.duckdb')
DB_PATH = os.path.normpath(DB_PATH)
CSV_DIR = os.path.join(os.path.dirname(__file__), '..', 'datos', 'csv')
CSV_DIR = os.path.normpath(CSV_DIR)

FUENTES = {
    'mediciones_prechancado':           'Prechancado.csv',
    'mediciones_chancado_2_3':          '2_y_3.csv',
    'mediciones_terciario':             'Terciario.csv',
    'mediciones_cuaternario':           'Cuaternario.csv',
    'mediciones_molienda_sag':          'Molienda_Sag.csv',
    'mediciones_molienda_convencional': 'Molienda_Convencional.csv',
    'mediciones_cdm_1':                 'CDM_(1).csv',
    'mediciones_cdm_2':                 'CDM_(2).csv',
    'mediciones_nodo':                  'Nodo.csv',
}

def main():
    print(f"Conectando a DuckDB: {DB_PATH}")
    con = duckdb.connect(DB_PATH)
    con.execute("CREATE SCHEMA IF NOT EXISTS landing")
    con.execute("CREATE SCHEMA IF NOT EXISTS semillas")
    con.execute("CREATE SCHEMA IF NOT EXISTS instantaneos")
    con.execute("CREATE SCHEMA IF NOT EXISTS main")

    for tabla, csv_file in FUENTES.items():
        csv_path = os.path.join(CSV_DIR, csv_file)
        if not os.path.exists(csv_path):
            print(f"  [SKIP] No encontrado: {csv_path}")
            continue

        # Detectar nombre real de la primera columna (nombre de planta en el CSV)
        cols_desc = con.execute(
            f"SELECT * FROM read_csv('{csv_path}', header=true, all_varchar=true) LIMIT 0"
        ).description
        cols = [d[0] for d in cols_desc]
        primera_col = cols[0]

        # Renombrar primera columna a 'etiqueta'
        partes = [f'"{primera_col}" AS etiqueta']
        partes += [f'"{c}"' for c in cols[1:]]
        select_str = ', '.join(partes)

        con.execute(f"DROP TABLE IF EXISTS landing.{tabla}")
        con.execute(f"""
            CREATE TABLE landing.{tabla} AS
            SELECT {select_str}
            FROM read_csv('{csv_path}', header=true, all_varchar=true)
        """)
        n = con.execute(f"SELECT COUNT(*) FROM landing.{tabla}").fetchone()[0]
        print(f"  [OK] landing.{tabla}: {n} filas")

    con.close()
    print("Listo.")

if __name__ == '__main__':
    main()
