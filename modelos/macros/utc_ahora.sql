{#-
    utc_ahora() — Timestamp UTC actual en formato ISO 8601+Z (ADR-017).

    Uso en bronce para _bronce_loaded_at y cualquier columna de auditoría
    que deba registrar el instante de ingesta en UTC.

    Salida: TEXT  "2026-05-27T14:13:57.000Z"
-#}
{% macro utc_ahora() %}
  {%- if target.type == 'duckdb' -%}
    strftime(current_timestamp::timestamptz, '%Y-%m-%dT%H:%M:%S.000Z')
  {%- elif target.type == 'bigquery' -%}
    FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%E3SZ', CURRENT_TIMESTAMP())
  {%- elif target.type in ('snowflake', 'databricks') -%}
    TO_VARCHAR(CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP()), 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"')
  {%- else -%}
    STRFTIME('%Y-%m-%dT%H:%M:%S.000Z', CURRENT_TIMESTAMP)
  {%- endif -%}
{% endmacro %}
