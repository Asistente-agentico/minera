-- sat_medicion_detalle: atributos descriptivos de cada evento de medición
-- Historicidad DV2: append-only, unique_key = (pk_hash, valid_from).
{{
    config(
        materialized='incremental',
        unique_key=['pk_hash', 'valid_from'],
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
        {{ pk_hash(['planta', 'punto_evaluacion', 'anio', 'semana']) }}             AS pk_hash,
        {{ diff_hash(['concentracion_mg_m3', 'fecha', 'hora_inicio', 'hora_termino']) }} AS _diff_hash,
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
WHERE _diff_hash NOT IN (
    SELECT _diff_hash FROM {{ this }}
    WHERE pk_hash IN (SELECT pk_hash FROM con_hash)
)
{% endif %}
