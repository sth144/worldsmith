"""Catch export failures that made the first Godot PoC white and repetitive.

This is a structural gate, not a substitute for looking at the scene in Godot.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
from pathlib import Path


def inspect_glb(path: Path, unique_node_pattern: str = "",
                require_pbr: bool = False, max_draw_calls: int | None = None,
                max_triangles: int | None = None, max_embedded_texture_bytes: int | None = None) -> dict:
    with path.open("rb") as source:
        header = source.read(20)
        if len(header) != 20:
            raise ValueError("Incomplete GLB header")
        magic, version, total, json_length, json_type = struct.unpack("<4sIIII", header)
        if magic != b"glTF" or version != 2 or total != path.stat().st_size or json_type != 0x4E4F534A:
            raise ValueError("Invalid GLB container")
        document = json.loads(source.read(json_length))
        chunk_header = source.read(8)
        binary = b""
        if chunk_header:
            if len(chunk_header) != 8:
                raise ValueError("Incomplete GLB binary header")
            binary_length, binary_type = struct.unpack("<I4s", chunk_header)
            if binary_type != b"BIN\0":
                raise ValueError("Unexpected GLB chunk")
            binary = source.read(binary_length)
            if len(binary) != binary_length:
                raise ValueError("Incomplete GLB binary data")

    def geometry_signature(mesh_index: int) -> str:
        """Hash vertex positions, even when an exporter gives copies new mesh IDs."""
        mesh = document["meshes"][mesh_index]
        digest = hashlib.sha256()
        for primitive in mesh.get("primitives", []):
            accessor_index = primitive.get("attributes", {}).get("POSITION")
            if accessor_index is None:
                raise ValueError(f"Mesh {mesh_index} has no POSITION accessor")
            accessor = document["accessors"][accessor_index]
            if "sparse" in accessor or "bufferView" not in accessor:
                raise ValueError(f"Unsupported sparse POSITION accessor in mesh {mesh_index}")
            view = document["bufferViews"][accessor["bufferView"]]
            if view.get("buffer", 0) != 0:
                raise ValueError("External GLB buffer is unsupported")
            components = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[accessor["type"]]
            component_bytes = {5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4}[accessor["componentType"]]
            width = components * component_bytes
            stride = view.get("byteStride", width)
            start = view.get("byteOffset", 0) + accessor.get("byteOffset", 0)
            count = accessor["count"]
            digest.update(struct.pack("<III", count, width, accessor["componentType"]))
            for vertex in range(count):
                offset = start + vertex * stride
                sample = binary[offset:offset + width]
                if len(sample) != width:
                    raise ValueError(f"Truncated POSITION data in mesh {mesh_index}")
                digest.update(sample)
        return digest.hexdigest()

    materials = document.get("materials", [])
    used = {primitive["material"] for mesh in document.get("meshes", [])
            for primitive in mesh.get("primitives", []) if "material" in primitive}
    errors = []
    draw_calls = 0
    triangles = 0
    for node in document.get("nodes", []):
        mesh_index = node.get("mesh")
        if mesh_index is None:
            continue
        primitives = document["meshes"][mesh_index].get("primitives", [])
        draw_calls += len(primitives)
        for primitive in primitives:
            mode = primitive.get("mode", 4)
            accessor_index = primitive.get("indices", primitive.get("attributes", {}).get("POSITION"))
            if accessor_index is None:
                continue
            count = document["accessors"][accessor_index]["count"]
            if mode == 4:
                triangles += count // 3
            elif mode in (5, 6):
                triangles += max(0, count - 2)
    embedded_texture_bytes = sum(
        document["bufferViews"][image["bufferView"]]["byteLength"]
        for image in document.get("images", []) if "bufferView" in image
    )
    if max_draw_calls is not None and draw_calls > max_draw_calls:
        errors.append(f"Draw call estimate {draw_calls} exceeds limit {max_draw_calls}")
    if max_triangles is not None and triangles > max_triangles:
        errors.append(f"Triangle count {triangles} exceeds limit {max_triangles}")
    if max_embedded_texture_bytes is not None and embedded_texture_bytes > max_embedded_texture_bytes:
        errors.append(f"Embedded texture bytes {embedded_texture_bytes} exceed limit {max_embedded_texture_bytes}")
    untextured = []
    for index in sorted(used):
        material = materials[index]
        pbr = material.get("pbrMetallicRoughness", {})
        if "baseColorTexture" not in pbr:
            untextured.append(material.get("name", str(index)))
            factor = pbr.get("baseColorFactor", [1, 1, 1, 1])
            if all(float(channel) > 0.9 for channel in factor[:3]):
                errors.append(f"White untextured material: {material.get('name', index)}")
        if require_pbr:
            if "normalTexture" not in material:
                errors.append(f"Missing normal texture: {material.get('name', index)}")
            if "metallicRoughnessTexture" not in pbr:
                errors.append(f"Missing roughness texture: {material.get('name', index)}")
    matched_nodes = [node for node in document.get("nodes", [])
                     if unique_node_pattern and unique_node_pattern.lower() in node.get("name", "").lower()
                     and "mesh" in node]
    distinct_meshes = len({node["mesh"] for node in matched_nodes})
    distinct_geometry = None
    if len(matched_nodes) > 1:
        signatures = [geometry_signature(node["mesh"]) for node in matched_nodes]
        distinct_geometry = len(set(signatures))
        if distinct_geometry < len(matched_nodes):
            errors.append(f"Repeated geometry: {len(matched_nodes)} matching nodes have {distinct_geometry} unique vertex layouts")
    return {"path": str(path), "nodes": len(document.get("nodes", [])),
            "meshes": len(document.get("meshes", [])), "materials": len(materials),
            "estimated_draw_calls": draw_calls, "triangles": triangles,
            "embedded_texture_bytes": embedded_texture_bytes,
            "untextured_materials": untextured, "matched_nodes": len(matched_nodes),
            "distinct_meshes": distinct_meshes,
            "distinct_geometry": distinct_geometry, "errors": errors}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("glb", type=Path)
    parser.add_argument("--unique-node-pattern", default="", metavar="TEXT")
    parser.add_argument("--require-pbr", action="store_true")
    parser.add_argument("--max-draw-calls", type=int)
    parser.add_argument("--max-triangles", type=int)
    parser.add_argument("--max-embedded-texture-bytes", type=int)
    args = parser.parse_args()
    report = inspect_glb(args.glb, args.unique_node_pattern, args.require_pbr,
                         args.max_draw_calls, args.max_triangles, args.max_embedded_texture_bytes)
    print(json.dumps(report, indent=2))
    if report["errors"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
