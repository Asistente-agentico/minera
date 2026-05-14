-- hub_planta: una fila por área de planta (BK: planta)
{{
    config(
        materialized='incremental',
        unique_key='pk_hash',
        incremental_strategy='merge',
        tags=['capa:silver', 'dominio:minera_prueba']
    )
}}

SELECT
    {{ pk_hash(['planta']) }}   AS pk_hash,
    planta,
    current_timestamp           AS _silver_loaded_at,
    'bronce_mediciones'         AS _silver_fuente

FROM (SELECT DISTINCT planta FROM {{ ref('bronce_mediciones') }}) t

{% if is_incremental() %}
WHERE {{ pk_hash(['planta']) }} NOT IN (SELECT pk_hash FROM {{ this }})
{% endif %}
