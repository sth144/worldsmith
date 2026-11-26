"""Register a local GLB as the server's base environment for scene export."""

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "server"))
from app.export import register_environment


parser = argparse.ArgumentParser()
parser.add_argument("glb", type=Path)
parser.add_argument("--scene", required=True)
parser.add_argument("--settings", type=Path)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
root = Path(os.environ.get("WORLDSMITH_DATA_DIR", repo / "data")) / "projects"
project = root / args.scene
if not (project / "scene.json").is_file():
    raise SystemExit("Start the scene server once before registering an environment")
settings = json.loads(args.settings.read_text()) if args.settings else None
print(register_environment(project, args.glb, settings))
