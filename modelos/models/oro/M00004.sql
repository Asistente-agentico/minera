{#-
    P00004 — Todas las mediciones de la última jornada de medición global.
    "Última jornada" = sesión con MAX(anio*100+semana) a nivel de todas las plantas.
    Incluye todos los puntos medidos, con y sin exceso del límite normativo.
    Chunk: uno por planta+punto_evaluacion.
    Temporal policy: vigente (siempre la jornada más reciente conocida).

    Severidad: JOIN punto-en-el-tiempo contra bandas_severidad versionadas (ADR-019).
    Vigencia: vigencia_desde <= sesion_max AND (vigencia_hasta = -1 OR sesion_max <= vigencia_hasta).
-#}
{{
    config(
        tags=['capa:oro', 'dominio:minera_prueba', 'regla:P00004']
    )
}}

WITH ultima_sesion_global AS (
    SELECT MAX(anio * 100 + semana) AS sesion_max
    FROM {{ ref('silver_entidad_sesion_medicion') }}
),

-- Límite normativo vigente en la última jornada
limite_vigente AS (
    SELECT ln.limite AS mg_m3
    FROM {{ ref('limites_normativos') }} ln
    JOIN ultima_sesion_global u
      ON ln.vigencia_desde <= u.sesion_max
     AND (ln.vigencia_hasta = -1 OR u.sesion_max <= ln.vigencia_hasta)
    WHERE ln.variable_id = '01KSXY0NV10SKHS01HFYHV2YCX'
      AND ln.fuente_tipo = 'legal'
    ORDER BY ln.version DESC
    LIMIT 1
),

-- Banda de severidad vigente en la última jornada
banda_vigente AS (
    SELECT
        bh.bandas_severidad_id,
        bh.version AS version_umbral
    FROM {{ ref('bandas_severidad') }} bh
    JOIN ultima_sesion_global u
      ON bh.vigencia_desde <= u.sesion_max
     AND (bh.vigencia_hasta = -1 OR u.sesion_max <= bh.vigencia_hasta)
    WHERE bh.variable_id = '01KSXY0NV10SKHS01HFYHV2YCX'
      AND bh.criterio = 'absoluto'
    ORDER BY bh.version DESC
    LIMIT 1
),

mediciones AS (
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
    JOIN ultima_sesion_global u
        ON (b.anio * 100 + b.semana) = u.sesion_max
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
    FROM mediciones m
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
    ROUND(cp.concentracion_mg_m3 / li.mg_m3, 2)                      AS veces_sobre_limite,
    CASE WHEN cp.concentracion_mg_m3 > li.mg_m3 THEN 'sobre_limite'
         ELSE 'bajo_limite'
    END                                                               AS estado_limite,
    cp.fecha,
    cp.hora_inicio,
    cp.hora_termino,
    cp.operador,
    cp.tecnico,
    li.mg_m3                                                          AS limite_interno_mg_m3,
    bn.nivel,
    bn.etiqueta,
    bn.color,
    bv.version_umbral
FROM con_personas cp
CROSS JOIN limite_vigente li
CROSS JOIN banda_vigente bv
LEFT JOIN {{ ref('banda_severidad_nivel') }} bn
    ON bn.bandas_severidad_id = bv.bandas_severidad_id
   AND cp.concentracion_mg_m3 >= bn.limite_inf
   AND (cp.concentracion_mg_m3 < bn.limite_sup OR bn.limite_sup IS NULL)
ORDER BY cp.concentracion_mg_m3 DESC
