# Minera — Configuración cliente

Configuración del Asistente Virtual para el caso **Minera**: monitoreo de concentración
de polvo respirable en puntos de medición de faena. Responde 4 preguntas de negocio
sobre mediciones ambientales bajo DS 594.

Compatible con: `asistente-agentico/illari v0.7.1+`

> **Este repositorio es del equipo de servicio.** El cliente nunca lo ve.
> La configuración y los modelos de transformación viajan dentro de la imagen Docker.

---

## Estructura

```
configuracion/
  dominio.yaml         — dimensiones de gobernanza y configuración del dominio
  permisos.yaml        — usuarios, roles y dimensiones de gobernanza por usuario
  fuentes.yaml         — fuentes de datos del lakehouse del cliente
  aterrizaje.yaml      — configuración de la zona de aterrizaje
  reglas/
    P000XX_M000XX.yaml — definición de regla (una por archivo, formato regla: {id: ...})
    consultas/
      P000XX_M000XX.sql     — consulta al mart oro correspondiente
    plantillas/
      P000XX_M000XX.j2      — plantilla Jinja2 de respuesta con {{ campo }}
  reportes/
    definiciones/
      concentracion_anual.yaml  — reporte M3 sobre oro_p00002
    consultas/
      concentracion_anual.sql   — consulta SQL del reporte

modelos/               — capa de transformación (interna; no expuesta al cliente)
  dbt_project.yml
  models/
    bronce/            — staging desde la zona de aterrizaje del cliente
    silver/            — entidades, relaciones y detalles (append-only)
    oro/               — marts M00001–M00004 consumidos por las reglas
  macros/              — utilidades de hashing y transformación
  instantaneos/        — historial por fuente (una instantánea por planilla)
  semillas/            — tablas de referencia (semáforo de límites)

scripts/
  preparar_landing.py       — extrae hojas del xlsx en formato ancho
  run_e2e_escritura.sh/.ps1 — E2E escritura: MK → MV (BDV) ← M1 via docker compose
  run_e2e_lectura.sh/.ps1   — E2E lectura: M2 + MA + MV contra BDV
  check_marts.py             — diagnóstico: cuenta filas en marts oro y silver
  check_snapshots.py         — diagnóstico: cuenta filas y columnas en snapshots

docker-compose.escritura.yml  — orquesta MK + MV + M1 para el E2E de escritura

tests/
  e2e_lectura.yaml       — suite E2E lectura (M2): 4 perfiles, 11 escenarios
  e2e_escritura.yaml     — suite E2E escritura (M1): conteo, gobernanza, PII, cifrado
  e2e_m3_reportes.yaml   — suite E2E reportes (M3): 12 escenarios

datos/                 — gitignoreado (PII + datos del cliente; solo en ambiente local)
  qdrant_mv/           — BDV Qdrant embebida generada por el E2E escritura
```

---

## Lo que recibe el cliente

| Artefacto | Descripción |
|---|---|
| Imagen Docker | `ghcr.io/asistente-agentico/illari:vX.Y.Z` |
| `docker-compose.yml` | Levanta el servicio; referencia la imagen y el `.env` |
| `.env.example` | Variables de conexión al lakehouse; el cliente llena sus credenciales |

El cliente no ve ni `configuracion/`, ni `modelos/`, ni ninguna tecnología interna.

> Artefactos de despliegue (`Dockerfile`, `docker-compose.yml`, `.env.example`) pendientes.

---

## Variables de entorno del cliente (`.env`)

```
DB_TIPO=duckdb
DB_HOST=
DB_PUERTO=
DB_USUARIO=
DB_CLAVE=
DB_NOMBRE=
ASISTENTE_PUERTO=8000
```

---

## Desarrollo (equipo de servicio)

### Prerrequisitos

- Python 3.12+
- dbt-core 1.11+ con el adapter del lakehouse (`dbt-duckdb`)
- Docker con soporte de Compose v2 (`docker compose`)

### Linter de configuración

```bash
# Desde el repo del producto (Illari)
python -m scripts.lint_configuracion /ruta/a/minera/configuracion
```

### Pipeline de preparación (desde el xlsx del cliente)

```bash
# 1. xlsx → CSVs en formato ancho
python scripts/preparar_landing.py --raiz /ruta/a/minera

# 2. dbt: seeds → snapshots → modelos
cd modelos
dbt seed
dbt snapshot
dbt run
```

### Tests E2E

Dos suites complementarias que se ejecutan en orden:

#### E2E escritura (M1 → MV → BDV)

Levanta MK, MV y M1 via docker compose. M1 corre el pipeline completo y deja
los chunks cifrados en `datos/qdrant_mv/` (Qdrant embebido de MV). Requiere `MASTER_SECRET`.

```bash
# Linux/macOS
export MASTER_SECRET="<secreto>"
bash scripts/run_e2e_escritura.sh

# Windows
$env:MASTER_SECRET = "<secreto>"
.\scripts\run_e2e_escritura.ps1
```

#### E2E lectura (M2 + MA + MV)

Valida consultas RAG contra la BDV poblada por la suite de escritura.
Requiere que `datos/qdrant_mv/` exista (correr escritura primero).

```bash
# Linux/macOS
export MASTER_SECRET="<secreto>"
bash scripts/run_e2e_lectura.sh

# Windows
$env:MASTER_SECRET = "<secreto>"
.\scripts\run_e2e_lectura.ps1
```

11 escenarios lectura: 5 de negocio (P1×2 perfiles + P2 + P3 + P4), 2 de autenticación,
1 de payload inválido, 1 sin match semántico, 2 de gobernanza (acceso denegado).

Los resultados se guardan en `tests/results/` (gitignoreado).

#### Notas de implementación (Windows/WSL2)

Los scripts `.ps1` copian los datos del cliente a `/tmp/minera` (tmpfs nativo Linux)
antes de arrancar Qdrant. Esto evita errores de bloqueo de archivos (`portalocker`
falla sobre NTFS/9P de WSL2).

El modelo de embeddings (`paraphrase-multilingual-MiniLM-L12-v2`) se pre-descarga
en el contenedor antes de arrancar MV para garantizar que el health-check pase
sin agotar los reintentos.

---

## Contexto de negocio

Ver [`analisis/preguntas.md`](analisis/preguntas.md) — preguntas del cliente, reglas,
marts y decisiones de diseño del caso.
