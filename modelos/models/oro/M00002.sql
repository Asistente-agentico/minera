{#-
    P00002 — Resumen anual de concentración por área (planta).
    Incluye: promedio, máximo, semanas medidas, semanas sobre el límite.
    Chunk: uno por planta con resumen anual.
    Temporal policy: append_only (acumula por anio).
-#}
{{
    config(
        materialized='table',
        tags=['capa:oro', 'dominio:minera_prueba', 'regla:P00002']
    )
}}

WITH limite_vigente AS (
    SELECT ln.limite AS mg_m3
    FROM {{ ref('limites_normativos') }} ln
    WHERE ln.variable_id = '01KSXY0NV10SKHS01HFYHV2YCX'
      AND ln.fuente_tipo = 'legal'
      AND ln.vigencia_desde <= (SELECT MAX(anio * 100 + semana) FROM {{ ref('silver_entidad_sesion_medicion') }})
      AND (ln.vigencia_hasta = -1
           OR (SELECT MAX(anio * 100 + semana) FROM {{ ref('silver_entidad_sesion_medicion') }}) <= ln.vigencia_hasta)
    ORDER BY ln.version DESC
    LIMIT 1
),

base AS (
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
    b.planta,
    b.anio,
    COUNT(DISTINCT b.semana)                              AS semanas_medidas,
    CASE WHEN COUNT(DISTINCT b.semana) = 1
         THEN 'semana medida' ELSE 'semanas medidas' END  AS semanas_label,
    COUNT(DISTINCT b.punto_evaluacion)                    AS puntos_medidos,
    CASE WHEN COUNT(DISTINCT b.punto_evaluacion) = 1
         THEN 'punto' ELSE 'puntos' END                   AS puntos_label,
    ROUND(AVG(b.concentracion_mg_m3), 3)                 AS concentracion_promedio_mg_m3,
    ROUND(MAX(b.concentracion_mg_m3), 3)                 AS concentracion_max_mg_m3,
    ROUND(MIN(b.concentracion_mg_m3), 3)                 AS concentracion_min_mg_m3,
    COUNT(CASE WHEN b.concentracion_mg_m3 > li.mg_m3 THEN 1 END) AS registros_sobre_limite,
    COUNT(*)                                              AS total_registros,
    ROUND(
        COUNT(CASE WHEN b.concentracion_mg_m3 > li.mg_m3 THEN 1 END) * 100.0 / COUNT(*),
        1
    )                                                     AS pct_sobre_limite,
    li.mg_m3                                              AS limite_interno_mg_m3

FROM base b
CROSS JOIN limite_vigente li
GROUP BY b.planta, b.anio, li.mg_m3
ORDER BY pct_sobre_limite DESC, concentracion_promedio_mg_m3 DESC
