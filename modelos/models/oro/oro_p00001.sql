{#-
    P00001 — Puntos que superaron 3 mg/m³ en la semana más reciente.
    Regla: P00001 (DS 594, polvo respirable, límite 3 mg/m³).
    Chunk: uno por punto que supera el límite.
    Temporal policy: vigente (semana en curso = max(anio, semana) con datos).
-#}
{{
    config(
        tags=['capa:oro', 'dominio:minera_prueba', 'regla:P00001']
    )
}}

WITH ultima_sesion AS (
    SELECT planta, MAX(anio * 100 + semana) AS sesion_max
    FROM {{ ref('silver_entidad_sesion_medicion') }}
    GROUP BY planta
),

mediciones_vigentes AS (
    SELECT
        b.planta,
        b.punto_evaluacion,
        b.anio,
        b.semana,
        b.concentracion_mg_m3,
        b.fecha,
        b.hora_inicio,
        b.hora_termino,
        b.operador_alias,
        b.tecnico_alias
    FROM {{ ref('bronce_mediciones') }} b
    JOIN ultima_sesion u
        ON b.planta = u.planta
       AND (b.anio * 100 + b.semana) = u.sesion_max
    WHERE b.concentracion_mg_m3 > 3.0
),

con_personas AS (
    SELECT
        m.planta,
        m.punto_evaluacion,
        m.anio,
        m.semana,
        m.concentracion_mg_m3,
        m.fecha,
        m.hora_inicio,
        m.hora_termino,
        MAX(CASE WHEN p_op.tipo_persona = 'operador' THEN p_op.nombre_completo END) AS operador,
        MAX(CASE WHEN p_tc.tipo_persona = 'tecnico'  THEN p_tc.nombre_completo END) AS tecnico
    FROM mediciones_vigentes m
    LEFT JOIN {{ ref('personas_alias') }} op_a
        ON trim(m.operador_alias) = op_a.alias_fuente
    LEFT JOIN {{ ref('silver_entidad_persona') }} p_op
        ON {{ pk_hash(['op_a.dni', 'op_a.tipo_dni', 'op_a.dni_pais_emisor']) }} = p_op.pk_hash
    LEFT JOIN {{ ref('personas_alias') }} tc_a
        ON trim(m.tecnico_alias) = tc_a.alias_fuente
    LEFT JOIN {{ ref('silver_entidad_persona') }} p_tc
        ON {{ pk_hash(['tc_a.dni', 'tc_a.tipo_dni', 'tc_a.dni_pais_emisor']) }} = p_tc.pk_hash
    GROUP BY
        m.planta, m.punto_evaluacion, m.anio, m.semana,
        m.concentracion_mg_m3, m.fecha, m.hora_inicio, m.hora_termino
)

SELECT
    {{ pk_hash(['planta', 'punto_evaluacion', 'anio', 'semana']) }}     AS chunk_id,
    planta,
    punto_evaluacion,
    anio,
    semana,
    concentracion_mg_m3,
    ROUND(concentracion_mg_m3 / 3.0, 2)                                AS veces_sobre_limite,
    fecha,
    hora_inicio,
    hora_termino,
    operador,
    tecnico,
    3.0                                                                 AS limite_legal_mg_m3,
    'DS 594'                                                            AS norma
FROM con_personas
ORDER BY concentracion_mg_m3 DESC
