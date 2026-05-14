-- hub_persona: una fila por persona del catálogo (BK: dni + tipo_dni + dni_pais_emisor)
-- Fuente: seed personas_alias (catálogo de personas con RUNs sintéticos para este caso de prueba).
-- En producción: reemplazar por landing desde sistema HR/ERP del cliente.
{{
    config(
        materialized='incremental',
        unique_key='pk_hash',
        incremental_strategy='merge',
        tags=['capa:silver', 'dominio:minera_prueba']
    )
}}

SELECT
    {{ pk_hash(['dni', 'tipo_dni', 'dni_pais_emisor']) }}   AS pk_hash,
    dni,
    tipo_dni,
    dni_pais_emisor,
    nombre_completo,
    tipo_persona,
    current_timestamp                                       AS _silver_loaded_at,
    'semillas.personas_alias'                               AS _silver_fuente

FROM (
    SELECT DISTINCT
        dni,
        tipo_dni,
        dni_pais_emisor,
        nombre_completo,
        tipo_persona
    FROM {{ ref('personas_alias') }}
) t

{% if is_incremental() %}
WHERE {{ pk_hash(['dni', 'tipo_dni', 'dni_pais_emisor']) }} NOT IN (SELECT pk_hash FROM {{ this }})
{% endif %}
