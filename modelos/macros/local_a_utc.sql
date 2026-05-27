{#-
    local_a_utc(columna) — Convierte una columna TIMESTAMP en hora local
    (sin información de zona horaria) a texto ISO 8601+Z (UTC), usando
    la zona horaria del cliente definida en dominio.yaml y pasada por M1
    como variable dbt `zona_horaria`.

    Uso: en modelos bronce para normalizar timestamps de la fuente cuando
    el sistema del cliente almacena en hora local.

    Parámetro dbt var: zona_horaria (default "UTC")
    Salida: TEXT  "2026-05-27T14:13:57.000Z"

    Ejemplo:
        {{ local_a_utc('fecha_medicion') }}  AS fecha_medicion
-#}
{% macro local_a_utc(columna) %}
  {%- set tz = var("zona_horaria", "UTC") -%}
  {%- if target.type == 'duckdb' -%}
    strftime(
      {{ columna }}::timestamp AT TIME ZONE '{{ tz }}',
      '%Y-%m-%dT%H:%M:%S.000Z'
    )
  {%- elif target.type == 'bigquery' -%}
    FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%E3SZ',
      TIMESTAMP({{ columna }}, '{{ tz }}'))
  {%- else -%}
    CAST({{ columna }} AS TEXT)
  {%- endif -%}
{% endmacro %}
