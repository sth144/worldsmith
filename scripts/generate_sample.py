"""Generate the small, original sample environment used by the M1 viewer.

Run: blender --background --python scripts/generate_sample.py
"""

from pathlib import Path
import bpy

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "client" / "assets" / "sample_hall.glb"

bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)


def material(name, color, roughness=0.8):
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = (*color, 1.0)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (*color, 1.0)
    bsdf.inputs["Roughness"].default_value = roughness
    return mat


stone = material("warm limestone", (0.57, 0.52, 0.43))
tile = material("floor stone", (0.36, 0.38, 0.36))
wood = material("dark timber", (0.23, 0.13, 0.075))
brass = material("aged brass", (0.58, 0.38, 0.13), 0.35)
teal = material("painted blue", (0.08, 0.31, 0.36))


def cube(name, location, scale, mat):
    # Inputs are Godot/glTF Y-up; Blender exports its Z-up coordinates to glTF.
    x, y, z = location
    sx, sy, sz = scale
    bpy.ops.mesh.primitive_cube_add(size=1, location=(x, -z, y))
    obj = bpy.context.object
    obj.name = name
    obj.dimensions = (sx, sz, sy)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.data.materials.append(mat)
    return obj


cube("floor", (0, -0.055, 0), (16, 0.11, 16), tile)
for coordinate in range(-7, 8, 2):
    cube(f"floor_line_x_{coordinate}", (coordinate, 0.002, 0), (0.015, 0.003, 16), stone)
    cube(f"floor_line_z_{coordinate}", (0, 0.002, coordinate), (16, 0.003, 0.015), stone)

for side in (-1, 1):
    cube(f"wall_x_{side}", (side * 8, 1.5, 0), (0.3, 3, 16.3), stone)
    cube(f"wall_z_{side}", (0, 1.5, side * 8), (16.3, 3, 0.3), stone)
    cube(f"wall_cap_x_{side}", (side * 8, 3.05, 0), (0.4, 0.16, 16.4), wood)
    cube(f"wall_cap_z_{side}", (0, 3.05, side * 8), (16.4, 0.16, 0.4), wood)

for x in (-6.5, 6.5):
    for z in (-6.5, 6.5):
        cube(f"column_{x}_{z}", (x, 1.4, z), (0.45, 2.8, 0.45), stone)
        cube(f"column_cap_{x}_{z}", (x, 2.85, z), (0.7, 0.22, 0.7), brass)

cube("table_top", (1.5, 0.82, -1.5), (2.4, 0.13, 1.4), wood)
for x in (0.5, 2.5):
    for z in (-2.0, -1.0):
        cube(f"table_leg_{x}_{z}", (x, 0.4, z), (0.14, 0.8, 0.14), wood)

for x in (-5.5, -4.2, -2.9):
    cube(f"display_base_{x}", (x, 0.3, -5.5), (0.85, 0.6, 0.85), wood)
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=0.35, location=(x, 5.5, 1.0))
    bpy.context.object.name = f"display_sculpture_{x}"
    bpy.context.object.data.materials.append(teal if x == -4.2 else brass)

bpy.ops.export_scene.gltf(filepath=str(OUTPUT), export_format="GLB", export_yup=True)
print(f"Generated {OUTPUT}")
