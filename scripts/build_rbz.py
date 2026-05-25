#!/usr/bin/env python3
from pathlib import Path
import zipfile
import shutil

ROOT = Path(__file__).resolve().parents[1]
EXT_NAME = "deusapps_blender_obj_importer_lite"
ROOT_LOADER = ROOT / f"{EXT_NAME}.rb"
SUPPORT_DIR = ROOT / EXT_NAME
DIST_DIR = ROOT / "dist"
OUT = DIST_DIR / "deusapps_blender_obj_importer_lite_v1_0_2_extension_warehouse.rbz"

if not ROOT_LOADER.exists():
    raise SystemExit(f"Missing loader: {ROOT_LOADER}")
if not SUPPORT_DIR.exists():
    raise SystemExit(f"Missing support folder: {SUPPORT_DIR}")

DIST_DIR.mkdir(exist_ok=True)

if OUT.exists():
    OUT.unlink()

with zipfile.ZipFile(OUT, "w", compression=zipfile.ZIP_DEFLATED) as z:
    z.write(ROOT_LOADER, ROOT_LOADER.name)
    for p in SUPPORT_DIR.rglob("*"):
        if p.is_file():
            z.write(p, p.relative_to(ROOT))

print(f"Built: {OUT}")
