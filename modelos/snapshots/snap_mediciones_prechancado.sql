{% snapshot snap_mediciones_prechancado %}
{{
    config(
        unique_key='etiqueta',
        strategy='check',
        check_cols=['etiqueta']
    )
}}
SELECT * FROM {{ source('landing', 'mediciones_prechancado') }}
{% endsnapshot %}
