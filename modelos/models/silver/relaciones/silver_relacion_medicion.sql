-- lnk_medicion: vincula un punto de medición con una sesión semanal
-- BK compuesta: hub_punto_medicion + hub_sesion_medicion
{{
    config(
        materialized='incremental',
        unique_key='pk_hash',
        incremental_strategy='merge',
        tags=['capa:silver', 'dominio:minera_prueba']
    )
}}

SELECT
    {{ pk_hash(['planta', 'punto_evaluacion', 'anio', 'semana']) }}     AS pk_hash,
    {{ pk_hash(['planta', 'punto_evaluacion']) }}                        AS hub_punto_medicion_hk,
    {{ pk_hash(['planta', 'anio', 'semana']) }}                          AS hub_sesion_medicion_hk,
    planta,
    punto_evaluacion,
    anio,
    semana,
    current_timestamp                                                   AS _silver_loaded_at,
    'bronce_mediciones'                                                 AS _silver_fuente

FROM (
    SELECT DISTINCT planta, punto_evaluacion, anio, semana
    FROM {{ ref('bronce_mediciones') }}
) t

{% if is_incremental() %}
WHERE {{ pk_hash(['planta', 'punto_evaluacion', 'anio', 'semana']) }} NOT IN (SELECT pk_hash FROM {{ this }})
{% endif %}
