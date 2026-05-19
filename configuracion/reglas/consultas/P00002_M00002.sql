-- P00002 — Resumen anual de concentración por área (planta).
SELECT
    planta,
    anio,
    semanas_medidas,
    semanas_label,
    puntos_medidos,
    puntos_label,
    concentracion_promedio_mg_m3,
    concentracion_max_mg_m3,
    concentracion_min_mg_m3,
    registros_sobre_limite,
    total_registros,
    pct_sobre_limite,
    limite_interno_mg_m3
FROM {{ mart('M00002') }}
