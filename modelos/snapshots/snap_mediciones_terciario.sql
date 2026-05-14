{% snapshot snap_mediciones_terciario %}
{{
    config(
        unique_key='etiqueta',
        strategy='check',
        check_cols=['etiqueta']
    )
}}
SELECT * FROM {{ source('landing', 'mediciones_terciario') }}
{% endsnapshot %}
