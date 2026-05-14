{#-
    P00002 — Resumen anual de concentración por área (planta).
    Incluye: promedio, máximo, semanas medidas, semanas sobre el límite.
    Chunk: uno por planta con resumen anual.
    Temporal policy: append_only (acumula por anio).
-#}
{{
    config(
        tags=['capa:oro', 'dominio:minera_prueba', 'regla:P00002']
    )
}}

WITH base AS (
    SELECT
        planta,
        anio,
        semana,
        concentracion_mg_m3,
        punto_evaluacion
    FROM {{ ref('bronce_mediciones') }}
    WHERE concentracion_mg_m3 IS NOT NULL
)

SELECT
    {{ pk_hash(['planta', 'anio']) }}                    AS chunk_id,
    planta,
    anio,
    COUNT(DISTINCT semana)                              AS semanas_medidas,
    COUNT(DISTINCT punto_evaluacion)                    AS puntos_medidos,
    ROUND(AVG(concentracion_mg_m3), 3)                 AS concentracion_promedio_mg_m3,
    ROUND(MAX(concentracion_mg_m3), 3)                 AS concentracion_max_mg_m3,
    ROUND(MIN(concentracion_mg_m3), 3)                 AS concentracion_min_mg_m3,
    COUNT(CASE WHEN concentracion_mg_m3 > 3.0 THEN 1 END) AS registros_sobre_limite,
    COUNT(*)                                            AS total_registros,
    ROUND(
        COUNT(CASE WHEN concentracion_mg_m3 > 3.0 THEN 1 END) * 100.0 / COUNT(*),
        1
    )                                                   AS pct_sobre_limite,
    3.0                                                 AS limite_legal_mg_m3,
    'DS 594'                                            AS norma

FROM base
GROUP BY planta, anio
ORDER BY pct_sobre_limite DESC, concentracion_promedio_mg_m3 DESC
