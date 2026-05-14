{% snapshot snap_mediciones_cuaternario %}
{{
    config(
        unique_key='etiqueta',
        strategy='check',
        check_cols=['etiqueta']
    )
}}
SELECT * FROM {{ source('landing', 'mediciones_cuaternario') }}
{% endsnapshot %}
