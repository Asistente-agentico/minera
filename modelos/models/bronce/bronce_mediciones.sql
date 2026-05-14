{#-
    bronce_mediciones — Transforma las 9 hojas de medición del formato ancho (CSV)
    al formato largo: una fila por (planta, punto_evaluacion, anio, semana).

    Fuente: 9 snapshots (uno por área de planta), Camino A (overwrite + snapshot).
    Macro: unpivot_mediciones_planta (maneja el UNPIVOT + metadata + filtros).

    Columnas de salida:
      planta, punto_evaluacion, semana, anio, concentracion_mg_m3,
      fecha, operador_alias, tecnico_alias, hora_inicio, hora_termino,
      _col_posicion, _bronce_fuente, _bronce_loaded_at
-#}
{{
    config(
        materialized='view',
        tags=['capa:bronce', 'dominio:minera_prueba']
    )
}}

{{ unpivot_mediciones_planta(ref('snap_mediciones_prechancado'),         'Pre-Chancado')           }}
UNION ALL
{{ unpivot_mediciones_planta(ref('snap_mediciones_chancado_2_3'),        'Chancado 2° y 3°')       }}
UNION ALL
{{ unpivot_mediciones_planta(ref('snap_mediciones_terciario'),           'Chancado Fino 3°')       }}
UNION ALL
{{ unpivot_mediciones_planta(ref('snap_mediciones_cuaternario'),         'Chancado Fino 4°')       }}
UNION ALL
{{ unpivot_mediciones_planta(ref('snap_mediciones_molienda_sag'),        'Molienda SAG')           }}
UNION ALL
{{ unpivot_mediciones_planta(ref('snap_mediciones_molienda_convencional'), 'Molienda Convencional') }}
UNION ALL
{{ unpivot_mediciones_planta(ref('snap_mediciones_cdm_1'),               'CDM')                    }}
UNION ALL
{{ unpivot_mediciones_planta(ref('snap_mediciones_cdm_2'),               'CDM')                    }}
UNION ALL
{{ unpivot_mediciones_planta(ref('snap_mediciones_nodo'),                'Nodo 3500')              }}
