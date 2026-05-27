# Preguntas del cliente — Caso Minera

---
**DECISIÓN DE DISEÑO — dimensiones_de_gobernanza**
En el nuevo diseño, todas las dimensiones de etiquetado de chunks (`ambito`, `clasificacion`, `dominio` y cualquier otra) se declaran en `dominio.yaml.dimensiones_de_gobernanza`, no como campos predefinidos del sistema.
Impacto en código: revisar D2 del HANDOFF, el schema de `reglas.yaml` (campo `dimensiones` y `payload`), el linter (V44/V45/V46) y la documentación del sistema de etiquetas. Requiere ADR.

---
**DEUDA TÉCNICA — ingesta**
Usamos `ingestion_pattern: overwrite` (Camino A) para este caso de prueba.
No escala: cada semana se reprocesa el histórico completo y el CSV crece indefinidamente (una columna por semana).
Resolver en sprint futuro: evaluar Opción D (hash del archivo) o rediseñar la planilla en formato largo con columna timestamp para usar Camino B incremental.

---
**MODELO PLATA — entidades identificadas**

- `ent_persona` → BK compuesta: `dni` + `tipo_dni` + `dni_pais_emisor`
  - Catálogo de referencia en `datos/referencia/personas.yaml` (gitignoreado, PII)
  - 6 técnicos (solo nombre de pila en fuente → normalizar via catálogo)
  - ~50 operadores (variantes ortográficas en fuente → normalizar via catálogo)
  - En producción: reemplazar por landing desde sistema HR/ERP del cliente
- `ent_punto_medicion` → BK: `planta` + `punto_evaluacion`
- `ent_sesion_medicion` → BK: `planta` + `semana`
- `rel_medicion` → ent_punto_medicion + ent_sesion_medicion
- `det_medicion` → concentracion_mg_m3, fecha, hora_inicio, hora_termino
- `rel_medicion_persona` (rol: operador/tecnico) → rel_medicion + ent_persona

---

**CONVENCIONES DE ARCHIVOS DE REGLA (schema v2)**

Cada regla tiene tres artefactos en `configuracion/`:
- `reglas/reglas.yaml` — declaración YAML de la regla (identidad, chunk_id, privacidad, gobernanza, vigencia)
- `consultas/<regla_id>.sql` — consulta al mart gold con `{{ mart('<mart_id>') }}`; **sin `SELECT *`**, columnas explícitas
- `plantillas/<regla_id>.txt` — texto con variables `{campo}`; cada `{campo}` debe estar en el `SELECT` del SQL

El mart en el nombre de la regla (`P00001_M00001` → `M00001`) debe coincidir con la referencia `{{ mart('M00001') }}` del SQL. Una regla lee de exactamente un mart.

---


## P1 — Puntos sobre el límite esta semana
"¿Qué puntos superaron el límite permitido esta semana?"

- **Regla:** `P00001_M00001`
- **Mart:** `M00001` (`modelos/models/oro/M00001.sql`)
- **Fuente:** mediciones de la semana en curso (última sesión por planta)
- **Límite:** 2,5 mg/m³ (límite interno; DS 594 fija 3 mg/m³ legal)
- **Campos clave:** planta, punto_evaluacion, semana, concentracion_mg_m3, etiqueta_semaforo
- **Chunk:** uno por punto que supera el límite interno

## P2 — Resumen anual por área
"¿Qué área tiene el peor historial del año?"

- **Regla:** `P00002_M00002`
- **Mart:** `M00002` (`modelos/models/oro/M00002.sql`)
- **Fuente:** todas las mediciones del año, agrupadas por planta
- **Campos clave:** planta, anio, concentracion_promedio_mg_m3, concentracion_max_mg_m3, pct_sobre_limite
- **Chunk:** uno por planta con resumen anual

## P3 — Condiciones de la medición más alta por área
"¿Qué estaba pasando cuando se midió la concentración más alta de [área]?"

- **Regla:** `P00003_M00003`
- **Mart:** `M00003` (`modelos/models/oro/M00003.sql`)
- **Fuente:** detalle de la medición con mayor concentración histórica por planta
- **Campos clave:** planta, punto_evaluacion, fecha, semana, concentracion_mg_m3, operador, operador_dni, tecnico, tecnico_dni, hora_inicio, hora_termino
- **Chunk:** uno por planta con el detalle completo de su peak histórico

## P4 — Todas las mediciones de la última jornada
"¿Cómo fue la última jornada de medición?"

- **Regla:** `P00004_M00004`
- **Mart:** `M00004` (`modelos/models/oro/M00004.sql`)
- **Fuente:** todas las mediciones de la sesión más reciente a nivel global (todas las plantas)
- **Campos clave:** planta, punto_evaluacion, semana, concentracion_mg_m3, etiqueta_semaforo, operador, tecnico
- **Chunk:** uno por planta+punto de medición
