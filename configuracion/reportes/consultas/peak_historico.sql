SELECT
    planta,
    punto_evaluacion,
    anio,
    semana,
    concentracion_mg_m3,
    veces_sobre_limite,
    fecha,
    operador,
    tecnico,
    nivel_semaforo
FROM {{ modelo_oro }}
WHERE 1=1
{{ where_gobernanza }}
ORDER BY planta
