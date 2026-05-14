-- hub_sesion_medicion: una fila por sesión semanal de medición (BK: planta + anio + semana)
-- BK incluye anio para evitar colisión: el CSV tiene semanas 1-52 de 2025 y 1-19 de 2026.
{{
    config(
        materialized='incremental',
        unique_key='pk_hash',
        incremental_strategy='merge',
        tags=['capa:silver', 'dominio:minera_prueba']
    )
}}

SELECT
    {{ pk_hash(['planta', 'anio', 'semana']) }}      AS pk_hash,
    planta,
    anio,
    semana,
    current_timestamp                               AS _silver_loaded_at,
    'bronce_mediciones'                             AS _silver_fuente

FROM (SELECT DISTINCT planta, anio, semana FROM {{ ref('bronce_mediciones') }}) t

{% if is_incremental() %}
WHERE {{ pk_hash(['planta', 'anio', 'semana']) }} NOT IN (SELECT pk_hash FROM {{ this }})
{% endif %}
