"""Fixed primitive assembler for validated Worldsmith designs; no generated Python."""

import json
import math
import sys
from pathlib import Path

import bpy


config = json.loads(Path(sys.argv[sys.argv.index("--") + 1]).read_text())
bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)

for part in config["parts"]:
    shape = part["shape"]
    if shape == "box":
        bpy.ops.mesh.primitive_cube_add(size=1)
    elif shape == "ellipsoid":
        bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=2, radius=0.5)
    elif shape == "cylinder":
        bpy.ops.mesh.primitive_cylinder_add(vertices=16, radius=0.5, depth=1)
    elif shape == "cone":
        bpy.ops.mesh.primitive_cone_add(vertices=16, radius1=0.5, radius2=0, depth=1)
    else:
        raise ValueError("Unsupported primitive")
    obj = bpy.context.object
    obj.name = part["name"]
    x, y, z = part["center"]
    obj.location = (x, -z, y)
    width, height, depth = part["size"]
    obj.scale = (width, depth, height)
    obj.rotation_euler[2] = math.radians(part["yaw"])
    color = (*part["color"], 1)
    material = bpy.data.materials.new(part["name"] + " material")
    material.diffuse_color = color
    material.use_nodes = True
    material.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = color
    obj.data.materials.append(material)

bpy.ops.export_scene.gltf(filepath=config["output"], export_format="GLB", export_yup=True)
