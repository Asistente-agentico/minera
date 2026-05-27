{#-
    unpivot_mediciones_planta — Transforma una hoja CSV de mediciones (formato ancho)
    al formato largo: una fila por (punto_evaluacion, semana).

    Estructura de entrada (snapshot con columnas etiqueta + column01..column71):
      - Fila 'Semanas'/'Semana'   → números de semana (1-52 año1, 1-19 año2)
      - Fila 'Fecha ...'          → fechas de medición
      - Fila '%Operador%'         → nombre alias del operador
      - Fila '%Tecnico%'          → nombre alias del técnico
      - Fila 'Hora inicio'        → hora inicio medición
      - Fila 'Hora termino'       → hora término medición
      - Filas numéricas restantes → puntos de medición (concentración mg/m³)

    Filtro de concentración: 0 ≤ valor < 100 — excluye 'Tratamiento tph'
    (valores 1100-1800) y cualquier fila operacional con números grandes.

    El anio se deriva de la posición de columna: column01-52 = 2025, column53-71 = 2026.
    Si la fecha está presente, tiene precedencia para determinar el año.

    Parámetros:
      snapshot_ref      — ref() al snapshot de la planta (eg. ref('snap_mediciones_prechancado'))
      planta_canonical  — nombre canónico según domain.yaml (eg. 'Pre-Chancado')
-#}
{% macro unpivot_mediciones_planta(snapshot_ref, planta_canonical) %}
SELECT * FROM (
    WITH src AS (
        SELECT * EXCLUDE (dbt_scd_id, dbt_updated_at, dbt_valid_from, dbt_valid_to)
        FROM {{ snapshot_ref }}
        WHERE dbt_valid_to IS NULL
    ),

    unpivoted AS (
        UNPIVOT src
        ON COLUMNS(* EXCLUDE etiqueta)
        INTO NAME col_nombre VALUE valor
    ),

    semanas AS (
        SELECT
            col_nombre,
            TRY_CAST(valor AS INTEGER) AS semana_num
        FROM unpivoted
        WHERE trim(etiqueta) IN ('Semanas', 'Semana')
          AND TRY_CAST(valor AS INTEGER) IS NOT NULL
    ),

    metadata AS (
        SELECT
            col_nombre,
            MAX(CASE WHEN trim(etiqueta) LIKE 'Fecha%' THEN valor END)      AS fecha_str,
            MAX(CASE WHEN trim(etiqueta) LIKE '%Operador%' THEN valor END)   AS operador_alias,
            MAX(CASE WHEN trim(etiqueta) LIKE '%Tecnico%'
                      OR trim(etiqueta) LIKE '%Técnico%' THEN valor END)     AS tecnico_alias,
            MAX(CASE WHEN trim(etiqueta) = 'Hora inicio'  THEN valor END)    AS hora_inicio,
            MAX(CASE WHEN trim(etiqueta) = 'Hora termino' THEN valor END)    AS hora_termino
        FROM unpivoted
        GROUP BY col_nombre
    ),

    mediciones AS (
        SELECT
            col_nombre,
            trim(etiqueta)              AS punto_evaluacion,
            TRY_CAST(valor AS DOUBLE)   AS concentracion_mg_m3
        FROM unpivoted
        WHERE TRY_CAST(valor AS DOUBLE) IS NOT NULL
          AND TRY_CAST(valor AS DOUBLE) >= 0
          AND TRY_CAST(valor AS DOUBLE) < 100
          AND trim(etiqueta) NOT IN ('Semanas', 'Semana', 'Lugar Monitoreo')
          AND trim(etiqueta) NOT LIKE '%Operador%'
          AND trim(etiqueta) NOT LIKE '%Tecnico%'
          AND trim(etiqueta) NOT LIKE '%Técnico%'
          AND trim(etiqueta) NOT LIKE 'Hora%'
          AND trim(etiqueta) NOT LIKE 'Fecha%'
          AND trim(etiqueta) != ''
    )

    SELECT
        '{{ planta_canonical }}'                                                 AS planta,
        m.punto_evaluacion,
        s.semana_num                                                             AS semana,
        -- anio desde posición de columna (no desde fecha): la fecha puede tener errores de captura
        -- column01-52 = semanas 1-52 del año 1 (2025); column53-71 = semanas 1-19 del año 2 (2026)
        CASE WHEN CAST(SUBSTRING(m.col_nombre, 7) AS INTEGER) <= 52 THEN 2025
             ELSE 2026
        END                                                                      AS anio,
        m.concentracion_mg_m3,
        TRY_CAST(md.fecha_str AS DATE)                                           AS fecha,
        NULLIF(trim(coalesce(md.operador_alias, '')), '')                        AS operador_alias,
        NULLIF(trim(coalesce(md.tecnico_alias,  '')), '')                        AS tecnico_alias,
        md.hora_inicio,
        md.hora_termino,
        m.col_nombre                                                             AS _col_posicion,
        '{{ snapshot_ref }}'                                                     AS _bronce_fuente,
        {{ utc_ahora() }}                                                        AS _bronce_loaded_at

    FROM mediciones m
    JOIN     semanas  s  ON m.col_nombre = s.col_nombre
    LEFT JOIN metadata md ON m.col_nombre = md.col_nombre
)
{% endmacro %}
