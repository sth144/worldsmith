"""Generate small floor-origin landscape props for view-based scene prompts."""

from pathlib import Path
import math
import bpy

OUTPUT = Path(__file__).resolve().parents[1] / "client" / "assets" / "inventory"
OUTPUT.mkdir(parents=True, exist_ok=True)


def clear():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)


def material(name, color):
    result = bpy.data.materials.new(name)
    result.diffuse_color = (*color, 1)
    result.use_nodes = True
    result.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (*color, 1)
    return result


grass = material("Hill grass", (0.20, 0.42, 0.11))
bark = material("Tree bark", (0.25, 0.13, 0.065))
leaves = material("Tree leaves", (0.12, 0.34, 0.12))


def export(name):
    bpy.ops.export_scene.gltf(filepath=str(OUTPUT / f"{name}.glb"), export_format="GLB", export_yup=True)


clear()
# Blender is Z-up. Each ring is wider at the bottom and has a slight irregularity.
rings = [(2.35, 0.0), (1.8, 0.38), (1.05, 0.79), (0.35, 1.08)]
vertices = []
segments = 20
for radius, height in rings:
    for index in range(segments):
        angle = index * math.tau / segments
        varied = radius * (1 + 0.045 * math.sin(index * 3.7))
        vertices.append((varied * math.cos(angle), varied * math.sin(angle), height))
vertices.append((0, 0, 1.12))
faces = []
for ring in range(len(rings) - 1):
    for index in range(segments):
        next_index = (index + 1) % segments
        faces.append((ring * segments + index, ring * segments + next_index,
                      (ring + 1) * segments + next_index, (ring + 1) * segments + index))
for index in range(segments):
    faces.append((3 * segments + index, 3 * segments + (index + 1) % segments, 4 * segments))
mesh = bpy.data.meshes.new("Hill mesh")
mesh.from_pydata(vertices, [], faces)
mesh.update()
hill = bpy.data.objects.new("Gentle grassy hill", mesh)
bpy.context.collection.objects.link(hill)
mesh.materials.append(grass)
for face in mesh.polygons:
    face.use_smooth = True
export("hill")

clear()
bpy.ops.mesh.primitive_cylinder_add(vertices=10, radius=0.16, depth=2.0, location=(0, 0, 1.0))
bpy.context.object.name = "Tree trunk"
bpy.context.object.data.materials.append(bark)
for x, y, z, radius in ((0, 0, 2.35, 0.88), (-0.42, 0, 2.15, 0.67), (0.39, 0.08, 2.22, 0.68)):
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=2, radius=radius, location=(x, y, z))
    bpy.context.object.name = "Tree canopy"
    bpy.context.object.data.materials.append(leaves)
export("tree")
