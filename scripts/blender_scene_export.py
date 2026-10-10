"""Blender child process: compose server assets in a clean scene and export GLB."""

import json
import re
import struct
import sys
from pathlib import Path

import bpy
from mathutils import Matrix, Quaternion, Vector


config = json.loads(Path(sys.argv[sys.argv.index("--") + 1]).read_text())
project = Path(config["project"])
scene = config["scene"]
bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)

# Godot/glTF coordinates are X right, Y up, -Z forward; Blender is Z up.
conversion = Matrix(((1, 0, 0, 0), (0, 0, -1, 0), (0, 1, 0, 0), (0, 0, 0, 1)))


def local_matrix(item):
    q = item["rotation"]
    matrix = Matrix.Translation(Vector(item["position"])) @ Quaternion((q[3], q[0], q[1], q[2])).to_matrix().to_4x4()
    return matrix @ Matrix.Diagonal((*item["scale"], 1))


by_id = {item["id"]: item for item in scene["objects"]}


def world_matrix(item):
    matrix = local_matrix(item)
    if item["parent_id"]:
        matrix = world_matrix(by_id[item["parent_id"]]) @ matrix
    return matrix


def import_asset(relative, transform=None, metadata=None):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=str(project / relative))
    imported = set(bpy.data.objects) - before
    if transform is not None:
        target = conversion @ transform @ conversion.inverted()
        for obj in imported:
            if obj.parent not in imported:
                obj.matrix_world = target @ obj.matrix_world
    if metadata:
        global_color = metadata.get("material_color")
        overrides = metadata.get("material_overrides", {})
        if not isinstance(overrides, dict):
            overrides = {}
        for obj in imported:
            if obj.type != "MESH":
                continue
            for slot in obj.material_slots:
                if slot.material is None:
                    continue
                name = re.sub(r"\.\d{3}$", "", slot.material.name)
                color = global_color if global_color is not None else overrides.get(slot.material.name, overrides.get(name))
                if color is None:
                    continue
                material = slot.material.copy()
                slot.material = material
                material.diffuse_color = color
                material.use_nodes = True
                for node in material.node_tree.nodes:
                    if node.type == "BSDF_PRINCIPLED":
                        for socket_name in ("Base Color", "Alpha"):
                            for link in list(node.inputs[socket_name].links):
                                material.node_tree.links.remove(link)
                        node.inputs["Base Color"].default_value = color
                        node.inputs["Alpha"].default_value = color[3]
    return imported


environment_objects = import_asset(config["environment"]["asset"])
if config["environment"].get("source") == "merchant.glb":
    for obj in environment_objects:
        name = obj.name.lower()
        if name.startswith(("gate doors", "gate ironwork", "gate straps")):
            bpy.data.objects.remove(obj, do_unlink=True)
for group_index, group in enumerate(config["environment"].get("instances", [])):
    imported = import_asset(group["glb"])
    prototypes = [obj for obj in imported if obj.type == "MESH"]
    if not prototypes:
        raise RuntimeError("Instance prototype has no mesh")
    prototype = prototypes[0]
    values = (project / group["transforms"]).read_bytes()
    if len(values) != group["count"] * 48:
        raise RuntimeError("Invalid instance transforms")
    for index, floats in enumerate(struct.iter_unpack("<12f", values)):
        matrix = Matrix(((floats[0], floats[3], floats[6], floats[9]),
                         (floats[1], floats[4], floats[7], floats[10]),
                         (floats[2], floats[5], floats[8], floats[11]),
                         (0, 0, 0, 1)))
        replica = bpy.data.objects.new(f"Worldsmith instance {group_index}-{index}", prototype.data)
        bpy.context.collection.objects.link(replica)
        replica.matrix_world = conversion @ matrix @ conversion.inverted() @ prototype.matrix_world
    for obj in imported:
        bpy.data.objects.remove(obj, do_unlink=True)
for item in scene["objects"]:
    if not item["visible"]:
        continue
    import_asset(item["asset"], world_matrix(item), item["metadata"])

bpy.ops.export_scene.gltf(filepath=config["output"], export_format="GLB", export_apply=True,
                          export_gpu_instances=True)
