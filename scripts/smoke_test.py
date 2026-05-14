"""
Smoke test nivel 1 (estructural) del caso minera.

Verifica los chunks generados en datos/chunks_generados.json sin necesidad
de Qdrant ni API de embeddings. Lee los umbrales desde configuracion/rules/rules.yaml.

Checks por regla:
  - Conteo dentro de expected_count_min / expected_count_max
  - Sin chunk_id duplicados (global)
  - Todos los firma_hmac verifican con HMAC
  - Dimensiones tienen las claves correctas (planta, ambito, clasificacion)
  - Campos requeridos del payload presentes y no nulos

Uso:
    python scripts/smoke_test.py
    python scripts/smoke_test.py --chunks datos/chunks_generados.json

Salida: PASS / FAIL por check. Exit code 0 si todo pasa, 1 si alguno falla.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import yaml

SCRIPT_DIR = Path(__file__).parent.resolve()
MINERA_ROOT = SCRIPT_DIR.parent
DISENO_ROOT = (MINERA_ROOT / ".." / "diseno").resolve()
RULES_PATH = MINERA_ROOT / "configuracion" / "rules" / "rules.yaml"
DOMAIN_PATH = MINERA_ROOT / "configuracion" / "domain.yaml"
DEFAULT_CHUNKS = str(MINERA_ROOT / "datos" / "chunks_generados.json")

sys.path.insert(0, str(DISENO_ROOT))
from core.security.crypto import calcular_hash_md5, calcular_integrity_tag  # noqa: E402

MASTER_SECRET_TEST: bytes = b"minera_test_MASTER_SECRET_32by!!"


def _cargar_dimensiones_requeridas() -> set[str]:
    data = yaml.safe_load(DOMAIN_PATH.read_text(encoding="utf-8"))
    return set(data.get("dimensiones_de_gobernanza", {}).keys())


def _cargar_smoke_config() -> dict[str, dict]:
    data = yaml.safe_load(RULES_PATH.read_text(encoding="utf-8"))
    return {r["id"]: r.get("smoke_test", {}) for r in data["rules"]}


def _cargar_campos_requeridos() -> dict[str, list[str]]:
    data = yaml.safe_load(RULES_PATH.read_text(encoding="utf-8"))
    return {
        r["id"]: r.get("smoke_test", {}).get("campos_requeridos", [])
        for r in data["rules"]
    }


def _ok(msg: str) -> None:
    print(f"  [OK]   {msg}")


def _fail(msg: str) -> None:
    print(f"  [FAIL] {msg}")


def ejecutar(chunks_path: str) -> bool:
    chunks: list[dict] = json.loads(Path(chunks_path).read_text(encoding="utf-8"))
    smoke_cfg = _cargar_smoke_config()
    dims_requeridas = _cargar_dimensiones_requeridas()
    campos_requeridos = _cargar_campos_requeridos()

    # Agrupar por regla
    por_regla: dict[str, list[dict]] = {}
    for ch in chunks:
        rid = ch["payload"]["regla_id"]
        por_regla.setdefault(rid, []).append(ch)

    total_checks = 0
    total_fallos = 0

    # --- CHECK GLOBAL: sin duplicados ---
    print("\n[Global]")
    ids = [ch["chunk_id"] for ch in chunks]
    duplicados = len(ids) - len(set(ids))
    total_checks += 1
    if duplicados == 0:
        _ok(f"Sin chunk_id duplicados ({len(ids)} chunks)")
    else:
        _fail(f"{duplicados} chunk_id duplicados")
        total_fallos += 1

    # --- CHECKS POR REGLA ---
    for regla_id in sorted(por_regla):
        print(f"\n[{regla_id}]")
        chs = por_regla[regla_id]
        cfg = smoke_cfg.get(regla_id, {})
        campos_req = campos_requeridos.get(regla_id, [])

        # 1. Conteo
        n = len(chs)
        cmin = cfg.get("expected_count_min", 1)
        cmax = cfg.get("expected_count_max", 9999)
        total_checks += 1
        if cmin <= n <= cmax:
            _ok(f"Conteo {n} dentro de [{cmin}, {cmax}]")
        else:
            _fail(f"Conteo {n} fuera de [{cmin}, {cmax}]")
            total_fallos += 1

        # 2. Integrity tags
        fallos_hmac = 0
        for ch in chs:
            p = ch["payload"]
            texto = ch.get("texto_dev")
            if texto is None:
                continue  # sin texto plano (archivo prod): skip por chunk
            h = calcular_hash_md5(texto)
            tag = calcular_integrity_tag(ch["chunk_id"], h, texto, MASTER_SECRET_TEST)
            if h != p["hash_contenido"] or tag != p["firma_hmac"]:
                fallos_hmac += 1
        total_checks += 1
        tiene_texto = any(ch.get("texto_dev") for ch in chs)
        if not tiene_texto:
            _ok(f"firma_hmac — sin texto_dev (archivo prod), check omitido")
        elif fallos_hmac == 0:
            _ok(f"firma_hmac verificada en {n}/{n} chunks")
        else:
            _fail(f"{fallos_hmac} chunks con firma_hmac inválida")
            total_fallos += 1

        # 3. Dimensiones
        fallos_dim = 0
        for ch in chs:
            dims = set(ch["payload"].get("dimensiones", {}).keys())
            if not dims_requeridas.issubset(dims):
                fallos_dim += 1
        total_checks += 1
        if fallos_dim == 0:
            _ok(f"Dimensiones {sorted(dims_requeridas)} presentes en {n}/{n} chunks")
        else:
            _fail(f"{fallos_dim} chunks sin dimensiones requeridas")
            total_fallos += 1

        # 4. Campos requeridos en datos_negocio
        fallos_campos = 0
        campos_nulos: list[str] = []
        for ch in chs:
            pl = ch["payload"].get("cifrado", {}).get("datos_negocio", {})
            for campo in campos_req:
                if pl.get(campo) is None:
                    fallos_campos += 1
                    campos_nulos.append(campo)
        total_checks += 1
        if fallos_campos == 0:
            _ok(f"Campos requeridos {campos_req} presentes y no nulos")
        else:
            _fail(f"{fallos_campos} ausencias en campos requeridos: {sorted(set(campos_nulos))}")
            total_fallos += 1

        # 5. Texto no vacío (solo en archivo dev)
        total_checks += 1
        if not tiene_texto:
            _ok(f"Texto no vacío — sin texto_dev (archivo prod), check omitido")
        else:
            vacios = sum(1 for ch in chs if not ch.get("texto_dev", "").strip())
            if vacios == 0:
                _ok(f"Texto no vacío en {n}/{n} chunks")
            else:
                _fail(f"{vacios} chunks con texto vacío")
                total_fallos += 1

    # --- Resumen ---
    print(f"\n{'='*50}")
    aprobados = total_checks - total_fallos
    if total_fallos == 0:
        print(f"PASS — {aprobados}/{total_checks} checks aprobados")
    else:
        print(f"FAIL — {aprobados}/{total_checks} checks aprobados, {total_fallos} fallaron")

    return total_fallos == 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chunks", default=DEFAULT_CHUNKS,
                        help="Ruta al JSON de chunks generados")
    args = parser.parse_args()

    ok = ejecutar(args.chunks)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
