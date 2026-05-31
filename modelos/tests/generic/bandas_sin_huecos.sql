{#-
    bandas_sin_huecos — Verifica que los niveles de una banda de severidad no tengan
    huecos ni solapes: el limite_sup de cada fila debe coincidir con el limite_inf
    de la fila siguiente (ordenando por nivel dentro de cada bandas_severidad_id).

    Uso en schema.yml:
      tests:
        - bandas_sin_huecos:
            id_col: bandas_severidad_id

    Devuelve filas donde hay brecha o solape (test falla si devuelve > 0 filas).
-#}
{% test bandas_sin_huecos(model, id_col) %}

WITH ordenados AS (
    SELECT
        {{ id_col }},
        nivel,
        limite_inf,
        limite_sup,
        LEAD(limite_inf) OVER (
            PARTITION BY {{ id_col }}
            ORDER BY nivel
        ) AS siguiente_limite_inf
    FROM {{ model }}
),

violaciones AS (
    SELECT *
    FROM ordenados
    WHERE
        -- Hay siguiente nivel y el límite superior actual no conecta con el inferior siguiente
        siguiente_limite_inf IS NOT NULL
        AND limite_sup IS NOT NULL
        AND ABS(limite_sup - siguiente_limite_inf) > 0.0001
)

SELECT * FROM violaciones

{% endtest %}
