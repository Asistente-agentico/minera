-- P00001 — Puntos de medición que superaron el límite interno (2,5 mg/m³) en la semana vigente.
-- "Vigente" = última sesión de medición disponible por planta.
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
FROM {{ mart('M00001') }}
