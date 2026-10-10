"""Fixed geometry transforms. Only receives server-authored config and copied GLB."""

import json
import sys
from pathlib import Path

import bpy
from mathutils import Vector


config = json.loads(Path(sys.argv[sys.argv.index("--") + 1]).read_text())
bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)
bpy.ops.import_scene.gltf(filepath=config["source"])
meshes = [obj for obj in bpy.context.scene.objects if obj.type == "MESH"]
if not meshes:
    raise RuntimeError("GLB has no meshes")
spec = config["operation"]
for obj in meshes:
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    if spec["kind"] == "bevel":
        modifier = obj.modifiers.new("Worldsmith bevel", "BEVEL")
        modifier.width = spec["width"]
        modifier.segments = 3
        modifier.limit_method = "ANGLE"
        bpy.ops.object.modifier_apply(modifier=modifier.name)
    elif spec["kind"] == "stretch_height":
        low = min(vertex.co.z for vertex in obj.data.vertices)
        for vertex in obj.data.vertices:
            vertex.co.z = low + (vertex.co.z - low) * spec["factor"]
        obj.data.update()
    elif spec["kind"] == "cut_opening":
        corners = [obj.matrix_world @ Vector(corner) for corner in obj.bound_box]
        minimum = [min(corner[index] for corner in corners) for index in range(3)]
        maximum = [max(corner[index] for corner in corners) for index in range(3)]
        bpy.ops.mesh.primitive_cube_add(size=1)
        cutter = bpy.context.object
        cutter.name = "Worldsmith temporary cutter"
        cutter.location = ((minimum[0] + maximum[0]) / 2, (minimum[1] + maximum[1]) / 2,
                           minimum[2] + spec["height"] / 2)
        cutter.dimensions = (spec["width"], maximum[1] - minimum[1] + 2, spec["height"])
        bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
        bpy.ops.object.select_all(action="DESELECT")
        obj.select_set(True)
        bpy.context.view_layer.objects.active = obj
        modifier = obj.modifiers.new("Worldsmith opening", "BOOLEAN")
        modifier.operation = "DIFFERENCE"
        modifier.solver = "EXACT"
        modifier.object = cutter
        bpy.ops.object.modifier_apply(modifier=modifier.name)
        bpy.data.objects.remove(cutter, do_unlink=True)
    else:
        raise RuntimeError("Unsupported fixed geometry operation")
bpy.ops.export_scene.gltf(filepath=config["output"], export_format="GLB", export_apply=True)
