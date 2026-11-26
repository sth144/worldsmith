"""Import a reusable GLB into a new editable Blender file."""

import sys
from pathlib import Path

import bpy


arguments = sys.argv[sys.argv.index("--") + 1:]
source, destination = (Path(value).resolve() for value in arguments)
if source.suffix.lower() != ".glb" or destination.suffix.lower() != ".blend":
    raise SystemExit("Expected source.glb and destination.blend")
bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)
bpy.ops.import_scene.gltf(filepath=str(source))
bpy.ops.wm.save_as_mainfile(filepath=str(destination))
