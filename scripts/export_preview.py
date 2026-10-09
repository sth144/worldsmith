"""Export the open Blender scene to a local GLB without saving the source blend.

Use: blender --background source.blend --python scripts/export_preview.py -- output.glb
"""

import sys
from pathlib import Path

import bpy


def main() -> None:
    if "--" not in sys.argv or len(sys.argv) - sys.argv.index("--") != 2:
        raise SystemExit("Expected one GLB output path after --")
    output = Path(sys.argv[-1]).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.export_scene.gltf(
        filepath=str(output),
        export_format="GLB",
        export_yup=True,
        use_renderable=True,
        export_cameras=False,
        export_lights=False,
        export_apply=False,
        export_gn_mesh=False,
    )
    print(f"WORLDSMITH exported {output} ({output.stat().st_size} bytes)")


main()
