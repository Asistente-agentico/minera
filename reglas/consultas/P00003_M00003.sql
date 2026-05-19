-- P00003 — Detalle completo de la medición con mayor concentración histórica por área.
SELECT
    planta,
    punto_evaluacion,
    anio,
    semana,
    concentracion_mg_m3,
    etiqueta_semaforo,
    veces_sobre_limite,
    fecha,
    hora_inicio,
    hora_termino,
    operador,
    operador_dni,
    tecnico,
    tecnico_dni,
    limite_interno_mg_m3
FROM {{ mart('M00003') }}
