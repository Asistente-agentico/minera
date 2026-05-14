# Preguntas del cliente — Caso Minera

---
**DECISIÓN DE DISEÑO — dimensiones_de_gobernanza**
En el nuevo diseño, todas las dimensiones de etiquetado de chunks (`ambito`, `clasificacion`, `dominio` y cualquier otra) se declaran en `domain.yaml.dimensiones_de_gobernanza`, no como campos predefinidos del sistema.
Impacto en código: revisar D2 del HANDOFF, el schema de `rules.yaml` (campo `dimensiones` y `payload`), el linter (V44/V45/V46) y la documentación del sistema de etiquetas. Requiere ADR.

---
**DEUDA TÉCNICA — ingesta**
Usamos `ingestion_pattern: overwrite` (Camino A) para este caso de prueba.
No escala: cada semana se reprocesa el histórico completo y el CSV crece indefinidamente (una columna por semana).
Resolver en sprint futuro: evaluar Opción D (hash del archivo) o rediseñar la planilla en formato largo con columna timestamp para usar Camino B incremental.

---
**MODELO DV2 PLATA — entidades identificadas**

- `hub_persona` → BK compuesta: `dni` + `tipo_dni` + `dni_pais_emisor`
  - Catálogo de referencia en `datos/referencia/personas.yaml` (gitignoreado, PII)
  - 6 técnicos (solo nombre de pila en fuente → normalizar via catálogo)
  - ~50 operadores (variantes ortográficas en fuente → normalizar via catálogo)
  - En producción: reemplazar por landing desde sistema HR/ERP del cliente
- `hub_punto_medicion` → BK: `planta` + `punto_evaluacion`
- `hub_sesion_medicion` → BK: `planta` + `semana`
- `lnk_medicion` → hub_punto_medicion + hub_sesion_medicion
- `sat_medicion_detalle` → concentracion_mg_m3, fecha, hora_inicio, hora_termino
- `lnk_medicion_persona` (rol: operador/tecnico) → lnk_medicion + hub_persona

---


## P1 — Puntos sobre el límite esta semana
"¿Qué puntos superaron el límite permitido esta semana?"

- **Regla:** `P00001`
- **Fuente:** mediciones de la semana en curso
- **Límite legal:** 3 mg/m³ (DS 594, polvo respirable)
- **Campos clave:** planta, punto_evaluacion, semana, concentracion_mg_m3
- **Chunk:** uno por punto que supera el límite

## P2 — Área con peor historial del año
"¿Qué área tiene el peor historial del año?"

- **Regla:** `P00002`
- **Fuente:** todas las mediciones del año, agrupadas por planta
- **Campos clave:** planta, semana, concentracion_promedio_mg_m3, concentracion_max_mg_m3
- **Chunk:** uno por planta con resumen anual

## P3 — Condiciones de la medición más alta por área
"¿Qué estaba pasando cuando se midió la concentración más alta de [área]?"

- **Regla:** `P00003`
- **Fuente:** detalle de la medición con mayor concentración por planta
- **Campos clave:** planta, punto_evaluacion, fecha, semana, concentracion_mg_m3, operador, tecnico, hora_inicio, hora_termino
- **Chunk:** uno por planta con el detalle completo de su peak
