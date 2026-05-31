SELECT
    planta,
    punto_evaluacion,
    concentracion_mg_m3,
    estado_limite,
    limite_interno_mg_m3,
    anio,
    semana,
    fecha,
    hora_inicio,
    hora_termino,
    operador,
    tecnico,
    nivel,
    etiqueta,
    color,
    version_umbral
FROM {{ modelo_oro }}
WHERE 1=1
{{ where_gobernanza }}
ORDER BY concentracion_mg_m3 DESC
