"""Generate the four original GLB props used by the local M2 inventory.

Run: blender --background --python scripts/generate_edit_assets.py
Each asset's origin is at floor level; dimensions are in meters.
"""

from pathlib import Path
import bpy


OUTPUT = Path(__file__).resolve().parents[1] / "client" / "assets" / "inventory"
OUTPUT.mkdir(parents=True, exist_ok=True)


def clear():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)


def material(name, rgb, roughness=0.75, metallic=0.0):
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = (*rgb, 1.0)
    mat.use_nodes = True
    shader = mat.node_tree.nodes.get("Principled BSDF")
    shader.inputs["Base Color"].default_value = (*rgb, 1.0)
    shader.inputs["Roughness"].default_value = roughness
    shader.inputs["Metallic"].default_value = metallic
    return mat


wood = material("Honey oak", (0.48, 0.25, 0.11))
dark_wood = material("Walnut", (0.20, 0.11, 0.07))
fabric = material("Sea green fabric", (0.13, 0.43, 0.39))
clay = material("Terracotta", (0.55, 0.25, 0.15))
leaf = material("Leaf green", (0.12, 0.36, 0.13))
metal = material("Dark iron", (0.12, 0.15, 0.17), 0.35, 0.55)
glass = material("Warm glass", (0.90, 0.62, 0.22), 0.25)


def box(name, xyz, size, mat, bevel=0.0):
    x, y, z = xyz
    sx, sy, sz = size
    bpy.ops.mesh.primitive_cube_add(size=1, location=(x, -z, y))
    obj = bpy.context.object
    obj.name = name
    obj.dimensions = (sx, sz, sy)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    if bevel:
        modifier = obj.modifiers.new("Soft edges", "BEVEL")
        modifier.width = bevel
        modifier.segments = 2
        obj.modifiers.new("Weighted normals", "WEIGHTED_NORMAL")
    obj.data.materials.append(mat)
    return obj


def cylinder(name, xyz, radius, depth, mat, vertices=12):
    x, y, z = xyz
    bpy.ops.mesh.primitive_cylinder_add(vertices=vertices, radius=radius, depth=depth, location=(x, -z, y))
    obj = bpy.context.object
    obj.name = name
    obj.data.materials.append(mat)
    return obj


def export(name):
    path = OUTPUT / f"{name}.glb"
    bpy.ops.export_scene.gltf(filepath=str(path), export_format="GLB", export_yup=True)
    print(f"Generated {path}")


clear()
box("Chair seat", (0, 0.48, 0), (0.56, 0.09, 0.54), wood, 0.025)
box("Chair cushion", (0, 0.55, 0), (0.48, 0.045, 0.45), fabric, 0.02)
for x in (-0.21, 0.21):
    for z in (-0.19, 0.19):
        box("Chair leg", (x, 0.23, z), (0.075, 0.46, 0.075), dark_wood, 0.012)
for x in (-0.21, 0.21):
    box("Chair back post", (x, 0.91, 0.2), (0.075, 0.82, 0.075), dark_wood, 0.012)
box("Chair back", (0, 1.06, 0.2), (0.49, 0.27, 0.065), wood, 0.025)
export("chair")

clear()
box("Table top", (0, 0.72, 0), (1.22, 0.11, 0.7), wood, 0.035)
for x in (-0.49, 0.49):
    for z in (-0.25, 0.25):
        box("Table leg", (x, 0.33, z), (0.09, 0.66, 0.09), dark_wood, 0.012)
box("Table apron front", (0, 0.59, -0.25), (1.05, 0.16, 0.05), dark_wood)
box("Table apron back", (0, 0.59, 0.25), (1.05, 0.16, 0.05), dark_wood)
export("table")

clear()
cylinder("Planter pot", (0, 0.24, 0), 0.23, 0.48, clay, 16)
cylinder("Planter rim", (0, 0.47, 0), 0.25, 0.07, clay, 16)
cylinder("Soil", (0, 0.49, 0), 0.21, 0.015, dark_wood, 16)
for x, z, height in ((-0.11, 0.02, 0.45), (0.09, -0.07, 0.53), (0.02, 0.11, 0.40)):
    bpy.ops.mesh.primitive_cone_add(vertices=8, radius1=0.10, radius2=0.0, depth=height, location=(x, -z, 0.49 + height / 2))
    bpy.context.object.name = "Planter leaves"
    bpy.context.object.data.materials.append(leaf)
export("planter")

clear()
box("Lantern base", (0, 0.06, 0), (0.31, 0.12, 0.31), metal, 0.015)
box("Lantern glow", (0, 0.33, 0), (0.23, 0.42, 0.23), glass, 0.015)
for x in (-0.13, 0.13):
    for z in (-0.13, 0.13):
        box("Lantern frame", (x, 0.34, z), (0.035, 0.48, 0.035), metal)
box("Lantern roof", (0, 0.61, 0), (0.35, 0.1, 0.35), metal, 0.025)
export("lantern")
