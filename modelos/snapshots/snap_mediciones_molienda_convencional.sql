{% snapshot snap_mediciones_molienda_convencional %}
{{
    config(
        unique_key='etiqueta',
        strategy='check',
        check_cols=['etiqueta']
    )
}}
SELECT * FROM {{ source('landing', 'mediciones_molienda_convencional') }}
{% endsnapshot %}
