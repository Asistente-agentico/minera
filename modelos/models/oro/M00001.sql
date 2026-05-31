{#-
    P00001 — Puntos que superaron el límite normativo en la semana más reciente por planta.
    Límite normativo leído desde limites_normativos (ADR-019).
    Severidad: JOIN punto-en-el-tiempo contra bandas_severidad versionadas.
    Chunk: uno por punto que supera el límite normativo.
    Temporal policy: vigente (semana en curso = max(anio, semana) con datos por planta).
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

limite_vigente AS (
    SELECT ln.limite AS mg_m3
    FROM {{ ref('limites_normativos') }} ln
    WHERE ln.variable_id = '01KSXY0NV10SKHS01HFYHV2YCX'
      AND ln.fuente_tipo = 'legal'
      AND ln.vigencia_desde <= (SELECT MAX(sesion_max) FROM ultima_sesion)
      AND (ln.vigencia_hasta = -1
           OR (SELECT MAX(sesion_max) FROM ultima_sesion) <= ln.vigencia_hasta)
    ORDER BY ln.version DESC
    LIMIT 1
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
    WHERE b.concentracion_mg_m3 > (SELECT mg_m3 FROM limite_vigente)
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
        ON {{ huella_registro(['op_a.dni', 'op_a.tipo_dni', 'op_a.dni_pais_emisor']) }} = p_op.huella_registro
    LEFT JOIN {{ ref('personas_alias') }} tc_a
        ON trim(m.tecnico_alias) = tc_a.alias_fuente
    LEFT JOIN {{ ref('silver_entidad_persona') }} p_tc
        ON {{ huella_registro(['tc_a.dni', 'tc_a.tipo_dni', 'tc_a.dni_pais_emisor']) }} = p_tc.huella_registro
    GROUP BY
        m.planta, m.punto_evaluacion, m.anio, m.semana,
        m.concentracion_mg_m3, m.fecha, m.hora_inicio, m.hora_termino
)

SELECT
    cp.planta,
    cp.punto_evaluacion,
    cp.anio,
    cp.semana,
    cp.concentracion_mg_m3,
    ROUND(cp.concentracion_mg_m3 / li.mg_m3, 2)  AS veces_sobre_limite,
    cp.fecha,
    cp.hora_inicio,
    cp.hora_termino,
    cp.operador,
    cp.tecnico,
    li.mg_m3                                       AS limite_interno_mg_m3,
    bn.nivel,
    bn.etiqueta,
    bn.color,
    bh.version                                     AS version_umbral
FROM con_personas cp
CROSS JOIN limite_vigente li
LEFT JOIN {{ ref('bandas_severidad') }} bh
    ON bh.variable_id = '01KSXY0NV10SKHS01HFYHV2YCX'
   AND bh.criterio = 'absoluto'
   AND bh.vigencia_desde <= (cp.anio * 100 + cp.semana)
   AND (bh.vigencia_hasta = -1 OR (cp.anio * 100 + cp.semana) <= bh.vigencia_hasta)
LEFT JOIN {{ ref('banda_severidad_nivel') }} bn
    ON bn.bandas_severidad_id = bh.bandas_severidad_id
   AND cp.concentracion_mg_m3 >= bn.limite_inf
   AND (cp.concentracion_mg_m3 < bn.limite_sup OR bn.limite_sup IS NULL)
ORDER BY cp.concentracion_mg_m3 DESC
