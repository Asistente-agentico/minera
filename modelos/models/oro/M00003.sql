{#-
    P00003 — Condiciones completas de la medición con mayor concentración histórica por área.
    Incluye: fecha, operador, técnico, horario, punto de medición exacto.
    Chunk: uno por planta con el detalle completo de su peak histórico.
    Temporal policy: vigente (siempre el peak más alto conocido).

    Severidad: JOIN punto-en-el-tiempo contra bandas_severidad versionadas (ADR-019).
-#}
{{
    config(
        tags=['capa:oro', 'dominio:minera_prueba', 'regla:P00003']
    )
}}

WITH limite_vigente AS (
    SELECT ln.limite AS mg_m3
    FROM {{ ref('limites_normativos') }} ln
    WHERE ln.variable_id = '01KSXY0NV10SKHS01HFYHV2YCX'
      AND ln.fuente_tipo = 'legal'
      AND ln.vigencia_desde <= (SELECT MAX(anio * 100 + semana) FROM {{ ref('silver_entidad_sesion_medicion') }})
      AND (ln.vigencia_hasta = -1
           OR (SELECT MAX(anio * 100 + semana) FROM {{ ref('silver_entidad_sesion_medicion') }}) <= ln.vigencia_hasta)
    ORDER BY ln.version DESC
    LIMIT 1
),

ranked AS (
    SELECT
        planta,
        punto_evaluacion,
        anio,
        semana,
        concentracion_mg_m3,
        fecha,
        hora_inicio,
        hora_termino,
        operador_alias,
        tecnico_alias,
        ROW_NUMBER() OVER (
            PARTITION BY planta
            ORDER BY concentracion_mg_m3 DESC
        ) AS rn
    FROM {{ ref('bronce_mediciones') }}
    WHERE concentracion_mg_m3 IS NOT NULL
),

peak AS (
    SELECT * FROM ranked WHERE rn = 1
),

con_personas AS (
    SELECT
        p.planta,
        p.punto_evaluacion,
        p.anio,
        p.semana,
        p.concentracion_mg_m3,
        p.fecha,
        p.hora_inicio,
        p.hora_termino,
        MAX(CASE WHEN ep_op.tipo_persona = 'operador' THEN ep_op.nombre_completo END) AS operador,
        MAX(CASE WHEN ep_tc.tipo_persona = 'tecnico'  THEN ep_tc.nombre_completo END) AS tecnico,
        MAX(CASE WHEN ep_op.tipo_persona = 'operador' THEN ep_op.dni END)             AS operador_dni,
        MAX(CASE WHEN ep_tc.tipo_persona = 'tecnico'  THEN ep_tc.dni END)             AS tecnico_dni
    FROM peak p
    LEFT JOIN {{ ref('personas_alias') }} op_a
        ON trim(p.operador_alias) = op_a.alias_fuente
    LEFT JOIN {{ ref('silver_entidad_persona') }} ep_op
        ON {{ huella_registro(['op_a.dni', 'op_a.tipo_dni', 'op_a.dni_pais_emisor']) }} = ep_op.huella_registro
    LEFT JOIN {{ ref('personas_alias') }} tc_a
        ON trim(p.tecnico_alias) = tc_a.alias_fuente
    LEFT JOIN {{ ref('silver_entidad_persona') }} ep_tc
        ON {{ huella_registro(['tc_a.dni', 'tc_a.tipo_dni', 'tc_a.dni_pais_emisor']) }} = ep_tc.huella_registro
    GROUP BY
        p.planta, p.punto_evaluacion, p.anio, p.semana,
        p.concentracion_mg_m3, p.fecha, p.hora_inicio, p.hora_termino
)

SELECT
    cp.planta,
    cp.punto_evaluacion,
    cp.anio,
    cp.semana,
    cp.concentracion_mg_m3,
    ROUND(cp.concentracion_mg_m3 / li.mg_m3, 2) AS veces_sobre_limite,
    cp.fecha,
    cp.hora_inicio,
    cp.hora_termino,
    cp.operador,
    cp.operador_dni,
    cp.tecnico,
    cp.tecnico_dni,
    li.mg_m3                                      AS limite_interno_mg_m3,
    bn.nivel,
    bn.etiqueta,
    bn.color,
    bh.version                                    AS version_umbral
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
ORDER BY cp.planta
