-- det_medicion: atributos descriptivos de cada evento de medición
-- Historicidad: append-only, unique_key = (huella_registro, valid_from).
{{
    config(
        materialized='incremental',
        unique_key=['huella_registro', 'valid_from'],
        incremental_strategy='append',
        tags=['capa:silver', 'dominio:minera_prueba']
    )
}}

WITH src AS (
    SELECT
        planta,
        punto_evaluacion,
        anio,
        semana,
        concentracion_mg_m3,
        fecha,
        hora_inicio,
        hora_termino
    FROM {{ ref('bronce_mediciones') }}
),

con_hash AS (
    SELECT
        {{ huella_registro(['planta', 'punto_evaluacion', 'anio', 'semana']) }}             AS huella_registro,
        {{ huella_contenido(['concentracion_mg_m3', 'fecha', 'hora_inicio', 'hora_termino']) }} AS _huella_contenido,
        -- variable_id identifica la variable medida; hardcodeado hasta que exista una 2ª variable
        '01KSXY0NV10SKHS01HFYHV2YCX'                                                      AS variable_id,
        concentracion_mg_m3,
        fecha,
        hora_inicio,
        hora_termino,
        current_timestamp   AS valid_from,
        NULL::TIMESTAMP     AS valid_to,
        1                   AS version_seq,
        'bronce_mediciones' AS _silver_fuente
    FROM src
)

SELECT * FROM con_hash

{% if is_incremental() %}
WHERE _huella_contenido NOT IN (
    SELECT _huella_contenido FROM {{ this }}
    WHERE huella_registro IN (SELECT huella_registro FROM con_hash)
)
{% endif %}
