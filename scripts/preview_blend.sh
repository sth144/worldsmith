#!/usr/bin/env bash
# Export a Blender file to an ignored local GLB, import it in Godot, and preview it.
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 path/to/scene.blend [godot_spawn_x,y,z]" >&2
    exit 2
fi
if ! command -v blender >/dev/null 2>&1; then
    echo "Blender must be available on PATH." >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "Python 3 is needed to write the local preview settings." >&2
    exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
blend_file="$1"
spawn="${2:-0,0,0}"
if [[ ! -f "$blend_file" ]]; then
    echo "Blender file not found: $blend_file" >&2
    exit 1
fi
name="$(basename "$blend_file")"
name="${name%.blend}"
local_dir="${repo_root}/client/assets/local"
mkdir -p "$local_dir"
glb_file="${local_dir}/${name}.glb"
export_log="${local_dir}/${name}-export.log"
import_log="${local_dir}/${name}-import.log"

echo "Exporting ${name}.blend to a local GLB..."
if ! blender --background "$blend_file" --python "${repo_root}/scripts/export_preview.py" -- "$glb_file" > "$export_log" 2>&1; then
    tail -40 "$export_log" >&2
    exit 1
fi
rg '^WORLDSMITH exported' "$export_log" || tail -5 "$export_log"

echo "Importing GLB into Godot..."
if ! "${repo_root}/scripts/godot.sh" --headless --xr-mode off --editor --path "${repo_root}/client" --quit > "$import_log" 2>&1; then
    tail -40 "$import_log" >&2
    exit 1
fi

python3 - "$name" "$spawn" "${local_dir}/preview.json" <<'PY'
import json
from pathlib import Path
import sys

name, spawn_text, config_path = sys.argv[1:]
spawn = [float(value) for value in spawn_text.split(",")]
if len(spawn) != 3:
    raise SystemExit("Spawn must contain X,Y,Z values")
Path(config_path).write_text(json.dumps({"glb": f"res://assets/local/{name}.glb", "spawn": spawn}) + "\n")
PY

echo "Starting preview at ${spawn} (Godot X,Y,Z)..."
exec "${repo_root}/scripts/godot.sh" --xr-mode off --path "${repo_root}/client"
