"""Export the open Blender scene as a Godot-friendly local preview.

Plain glTF export does not preserve this scene's procedural materials or grass
instances in Godot. This bakes base colors and writes repeated mesh instances
separately for Godot MultiMesh. The source .blend is never saved.

Use: blender --background source.blend --python scripts/export_preview.py -- output.glb
"""

import json
import struct
import sys
from collections import defaultdict
from pathlib import Path

import bpy
from mathutils import Matrix


def procedural_base_color(material):
    if material is None or not material.use_nodes:
        return None
    for node in material.node_tree.nodes:
        if node.type == "BSDF_PRINCIPLED" and node.inputs["Base Color"].is_linked:
            return node
    return None


def collect_instances():
    groups = defaultdict(list)
    conversion = Matrix(((1, 0, 0, 0), (0, 0, 1, 0), (0, -1, 0, 0), (0, 0, 0, 1)))
    inverse = conversion.inverted()
    for instance in bpy.context.evaluated_depsgraph_get().object_instances:
        if not instance.is_instance or instance.object.type != "MESH":
            continue
        mesh = instance.object.data.original
        transform = conversion @ instance.matrix_world @ inverse
        groups[mesh.name].append(transform.copy())
    return groups


def ensure_uv(object_):
    if object_.data.uv_layers:
        return
    bpy.ops.object.select_all(action="DESELECT")
    object_.select_set(True)
    bpy.context.view_layer.objects.active = object_
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(island_margin=0.01)
    bpy.ops.object.mode_set(mode="OBJECT")


def bake_color(object_, slot_index):
    # Each object gets its own UVs and material because procedural coordinates
    # may differ even when multiple objects share one Blender material.
    object_.data = object_.data.copy()
    ensure_uv(object_)
    slot = object_.material_slots[slot_index]
    material = slot.material.copy()
    slot.link = "DATA"
    slot.material = material
    shader = procedural_base_color(material)
    if shader is None:
        return
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    output = next(node for node in nodes if node.type == "OUTPUT_MATERIAL")
    source_surface = output.inputs["Surface"].links[0].from_socket
    source_color = shader.inputs["Base Color"].links[0].from_socket
    polygons = len(object_.data.polygons)
    size = 2048 if polygons > 10000 else 1024 if polygons > 100 else 512
    image = bpy.data.images.new(f"{object_.name} color", width=size, height=size, alpha=False)
    image_node = nodes.new("ShaderNodeTexImage")
    image_node.image = image
    nodes.active = image_node
    emission = nodes.new("ShaderNodeEmission")
    links.new(source_color, emission.inputs["Color"])
    links.new(emission.outputs[0], output.inputs["Surface"])
    bpy.ops.object.select_all(action="DESELECT")
    object_.select_set(True)
    bpy.context.view_layer.objects.active = object_
    bpy.ops.object.bake(type="EMIT", margin=2)
    links.new(source_surface, output.inputs["Surface"])
    links.new(image_node.outputs["Color"], shader.inputs["Base Color"])
    nodes.remove(emission)
    image.pack()
    print(f"WORLDSMITH baked {object_.name} at {size}px")


def export_instances(output, groups):
    manifest = {"groups": []}
    for index, (mesh_name, transforms) in enumerate(groups.items()):
        mesh = bpy.data.meshes.get(mesh_name)
        if mesh is None:
            continue
        prototype = bpy.data.objects.new(f"Worldsmith Instance {index}", mesh)
        bpy.context.collection.objects.link(prototype)
        bpy.ops.object.select_all(action="DESELECT")
        prototype.select_set(True)
        bpy.context.view_layer.objects.active = prototype
        prototype_path = output.with_name(f"{output.stem}-instance-{index}.glb")
        bpy.ops.export_scene.gltf(
            filepath=str(prototype_path),
            export_format="GLB",
            export_yup=True,
            use_selection=True,
            export_cameras=False,
            export_lights=False,
        )
        bpy.data.objects.remove(prototype, do_unlink=True)
        binary_path = output.with_name(f"{output.stem}-instance-{index}.bin")
        with binary_path.open("wb") as file:
            for transform in transforms:
                columns = [transform.col[i] for i in range(4)]
                values = [component for column in columns for component in column[:3]]
                file.write(struct.pack("<12f", *values))
        manifest["groups"].append(
            {
                "glb": f"res://assets/local/{prototype_path.name}",
                "transforms": f"res://assets/local/{binary_path.name}",
                "count": len(transforms),
            }
        )
        print(f"WORLDSMITH instanced {mesh_name}: {len(transforms)}")
    manifest_path = output.with_name(f"{output.stem}-instances.json")
    manifest_path.write_text(json.dumps(manifest) + "\n")


def main():
    if "--" not in sys.argv or len(sys.argv) - sys.argv.index("--") != 2:
        raise SystemExit("Expected one GLB output path after --")
    output = Path(sys.argv[-1]).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    instances = collect_instances()
    # Export Geometry Nodes instances separately through MultiMesh.
    for object_ in bpy.context.scene.objects:
        if object_.type == "MESH":
            for modifier in object_.modifiers:
                if modifier.type == "NODES":
                    modifier.show_viewport = False
                    modifier.show_render = False
    bpy.context.scene.render.engine = "CYCLES"
    bpy.context.scene.cycles.samples = 1
    bake_targets = []
    for object_ in bpy.context.scene.objects:
        if object_.type != "MESH" or object_.hide_render:
            continue
        for index, slot in enumerate(object_.material_slots):
            if procedural_base_color(slot.material):
                bake_targets.append((object_, index))
    for object_, index in bake_targets:
        bake_color(object_, index)
    bpy.ops.export_scene.gltf(
        filepath=str(output),
        export_format="GLB",
        export_yup=True,
        use_renderable=True,
        export_cameras=False,
        export_lights=False,
        export_apply=True,
        export_gn_mesh=False,
    )
    export_instances(output, instances)
    print(f"WORLDSMITH exported {output} ({output.stat().st_size} bytes)")


main()
