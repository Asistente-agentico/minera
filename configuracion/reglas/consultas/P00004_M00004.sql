-- P00004 — Todas las mediciones de la última jornada de medición global.
SELECT
    planta,
    punto_evaluacion,
    anio,
    semana,
    concentracion_mg_m3,
    etiqueta_semaforo,
    veces_sobre_limite,
    limite_interno_mg_m3,
    hora_inicio,
    hora_termino,
    operador,
    tecnico
FROM {{ mart('M00004') }}
