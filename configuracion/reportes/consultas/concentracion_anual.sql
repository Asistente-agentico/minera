SELECT
    planta,
    anio,
    semanas_medidas,
    puntos_medidos,
    concentracion_promedio_mg_m3,
    concentracion_max_mg_m3,
    concentracion_min_mg_m3,
    registros_sobre_limite,
    total_registros,
    pct_sobre_limite,
    limite_interno_mg_m3
FROM {{ modelo_oro }}
WHERE 1=1
{{ where_gobernanza }}
{% if anio %}AND anio = {{ anio }}{% endif %}
ORDER BY planta, anio
