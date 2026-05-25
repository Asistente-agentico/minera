#!/usr/bin/env bash
# dev-ui.sh — Levanta el stack de desarrollo de la UI (MK + MA + M2 + M3 + UI)
#             con la configuracion de minera.
#
# Lee MASTER_SECRET desde minera/.env y delega en Illari/scripts/dev-ui.ps1
# (via PowerShell) o en docker compose directamente, apuntando CLIENTE_DIR
# al repo minera.
#
# Requiere que el repo Illari este en ../Illari relativo a minera.
#
# Uso:
#   bash scripts/dev-ui.sh [up|down|logs|ps]

set -euo pipefail

CMD="${1:-up}"
REPO_RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
ILLARI_DIR="$(cd "$REPO_RAIZ/../Illari" 2>/dev/null && pwd || true)"

if [[ -z "$ILLARI_DIR" || ! -f "$ILLARI_DIR/scripts/dev-ui.ps1" ]]; then
    echo "ERROR: No se encontro Illari/scripts/dev-ui.ps1 en $REPO_RAIZ/../Illari" >&2
    exit 1
fi

# Leer variables desde minera/.env si no estan en el entorno.
ENV_FILE="$REPO_RAIZ/.env"
_read_env() {
    local var="$1"
    if [[ -z "${!var:-}" ]] && [[ -f "$ENV_FILE" ]]; then
        local val
        val=$(grep -E "^\s*(export\s+)?${var}\s*=" "$ENV_FILE" \
            | head -1 | sed -E "s/^\s*(export\s+)?${var}\s*=\s*//" \
            | tr -d '"'"'" | xargs || true)
        [[ -n "$val" ]] && export "$var=$val"
    fi
}
_read_env MASTER_SECRET
_read_env ILLARI_IMAGE
_read_env ILLARI_UI_IMAGE

if [[ -z "${MASTER_SECRET:-}" ]]; then
    echo "ERROR: MASTER_SECRET no definido. Agregalo a minera/.env o exportalo antes de correr el script." >&2
    exit 1
fi

export MASTER_SECRET
export CLIENTE_DIR="$REPO_RAIZ"

COMPOSE_FILE="$ILLARI_DIR/docker-compose.ui.yml"

# ---------------------------------------------------------------------------
# Pre-flight: verificar imágenes locales (solo en subcomando up)
# Se activa si existe minera/imagenes/versiones.yaml.
# ---------------------------------------------------------------------------
VERSIONES_FILE="$REPO_RAIZ/imagenes/versiones.yaml"
if [[ "$CMD" == "up" && -f "$VERSIONES_FILE" ]]; then
    declare -A _MOD_VARS=(
        [mk]="ILLARI_MK_IMAGE"
        [ma]="ILLARI_MA_IMAGE"
        [mv]="ILLARI_MV_IMAGE"
        [m2]="ILLARI_M2_IMAGE"
        [m3]="ILLARI_M3_IMAGE"
        [ui]="ILLARI_UI_IMAGE"
    )
    declare -A _MOD_DEFAULTS=(
        [mk]="illari-mk:local"
        [ma]="illari-ma:local"
        [mv]="illari-mv:local"
        [m2]="illari-m2:local"
        [m3]="illari-m3:local"
        [ui]="illari-ui:local"
    )
    FALTANTES=()
    for MOD in mk ma mv m2 m3 ui; do
        VAR="${_MOD_VARS[$MOD]}"
        IMAGEN="${!VAR:-${_MOD_DEFAULTS[$MOD]}}"
        if ! docker image inspect "$IMAGEN" >/dev/null 2>&1; then
            FALTANTES+=("$MOD")
        fi
    done
    if [[ ${#FALTANTES[@]} -gt 0 ]]; then
        echo "" >&2
        echo "ERROR: imágenes faltantes en Docker local:" >&2
        for MOD in "${FALTANTES[@]}"; do echo "  illari-${MOD}:local" >&2; done
        echo "" >&2
        echo "Construye con:" >&2
        echo "  bash scripts/build-imagenes.sh ${FALTANTES[*]}" >&2
        echo "" >&2
        exit 1
    fi
fi

case "$CMD" in
    down)
        docker compose -f "$COMPOSE_FILE" down --remove-orphans
        ;;
    logs)
        docker compose -f "$COMPOSE_FILE" logs -f
        ;;
    ps)
        docker compose -f "$COMPOSE_FILE" ps
        ;;
    up)
        echo ""
        echo "=== Illari dev-ui -- MK + MA + M2 + UI ==="
        echo "Cliente : $REPO_RAIZ"
        echo ""
        docker compose -f "$COMPOSE_FILE" down --remove-orphans 2>/dev/null || true
        docker compose -f "$COMPOSE_FILE" up --build -d

        echo "  Esperando MA en http://localhost:8001/health..."
        for i in $(seq 1 24); do
            if curl -fsS http://localhost:8001/health >/dev/null 2>&1; then
                echo "  MA listo (intento $i/24)"; break
            fi
            echo "  Intento $i/24 -- esperando 5s..."; sleep 5
            [[ $i -eq 24 ]] && { echo "FAILED: MA no respondio en 120s." >&2; docker compose -f "$COMPOSE_FILE" logs --tail=30; exit 1; }
        done

        echo "  Esperando M2 en http://localhost:8004/health..."
        for i in $(seq 1 24); do
            if curl -fsS http://localhost:8004/health >/dev/null 2>&1; then
                echo "  M2 listo (intento $i/24)"; break
            fi
            echo "  Intento $i/24 -- esperando 5s..."; sleep 5
            [[ $i -eq 24 ]] && { echo "FAILED: M2 no respondio en 120s." >&2; docker compose -f "$COMPOSE_FILE" logs m2 --tail=30; exit 1; }
        done

        echo ""
        echo "Stack listo. La UI puede tardar ~2 min mas en compilar."
        echo ""
        echo "  UI  -> http://localhost:3000"
        echo "  MA  -> http://localhost:8001"
        echo "  M2  -> http://localhost:8004"
        echo ""
        echo "  Logs:  bash scripts/dev-ui.sh logs"
        echo "  Stop:  bash scripts/dev-ui.sh down"
        ;;
    *)
        echo "Uso: bash scripts/dev-ui.sh [up|down|logs|ps]" >&2
        exit 1
        ;;
esac
