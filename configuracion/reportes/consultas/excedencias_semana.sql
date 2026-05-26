SELECT
    planta,
    punto_evaluacion,
    concentracion_mg_m3,
    veces_sobre_limite,
    nivel_semaforo,
    color_semaforo,
    fecha,
    operador,
    tecnico
FROM {{ modelo_oro }}
WHERE 1=1
{{ where_gobernanza }}
ORDER BY planta, concentracion_mg_m3 DESC
