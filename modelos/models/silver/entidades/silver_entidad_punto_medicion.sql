-- hub_punto_medicion: una fila por punto de medición por planta (BK: planta + punto_evaluacion)
{{
    config(
        materialized='incremental',
        unique_key='pk_hash',
        incremental_strategy='merge',
        tags=['capa:silver', 'dominio:minera_prueba']
    )
}}

SELECT
    {{ pk_hash(['planta', 'punto_evaluacion']) }}    AS pk_hash,
    planta,
    punto_evaluacion,
    current_timestamp                               AS _silver_loaded_at,
    'bronce_mediciones'                             AS _silver_fuente

FROM (SELECT DISTINCT planta, punto_evaluacion FROM {{ ref('bronce_mediciones') }}) t

{% if is_incremental() %}
WHERE {{ pk_hash(['planta', 'punto_evaluacion']) }} NOT IN (SELECT pk_hash FROM {{ this }})
{% endif %}
