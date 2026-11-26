import json
from pathlib import Path
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from check_glb_quality import inspect_glb


def write_glb(path, document, binary=b""):
    encoded = json.dumps(document).encode()
    encoded += b" " * (-len(encoded) % 4)
    binary += b"\0" * (-len(binary) % 4)
    chunk = struct.pack("<I4s", len(binary), b"BIN\0") + binary if binary else b""
    path.write_bytes(struct.pack("<4sII", b"glTF", 2, len(encoded) + 20 + len(chunk))
                     + struct.pack("<I4s", len(encoded), b"JSON") + encoded + chunk)


def test_quality_gate_rejects_white_materials_and_duplicate_geometry(tmp_path):
    path = tmp_path / "bad.glb"
    positions = struct.pack("<fff", 0, 0, 0)
    write_glb(path, {"materials": [{"name": "Grass"}],
                     "meshes": [{"primitives": [{"material": 0, "attributes": {"POSITION": 0}}]}],
                     "accessors": [{"bufferView": 0, "componentType": 5126, "count": 1, "type": "VEC3"}],
                     "bufferViews": [{"buffer": 0, "byteLength": len(positions)}],
                     "nodes": [{"name": "Prop A", "mesh": 0}, {"name": "Prop B", "mesh": 0}]}, positions)
    report = inspect_glb(path, unique_node_pattern="Prop")
    assert any("White untextured" in issue for issue in report["errors"])
    assert any("Repeated geometry" in issue for issue in report["errors"])


def test_quality_gate_catches_copied_vertices_with_separate_mesh_ids(tmp_path):
    path = tmp_path / "copies.glb"
    positions = struct.pack("<fff", 1, 2, 3)
    write_glb(path, {"meshes": [{"primitives": [{"attributes": {"POSITION": 0}}]}] * 2,
                     "accessors": [{"bufferView": 0, "componentType": 5126, "count": 1, "type": "VEC3"}],
                     "bufferViews": [{"buffer": 0, "byteLength": len(positions)}],
                     "nodes": [{"name": "Prop A", "mesh": 0}, {"name": "Prop B", "mesh": 1}]}, positions)
    report = inspect_glb(path, unique_node_pattern="Prop")
    assert report["distinct_meshes"] == 2
    assert report["distinct_geometry"] == 1
    assert any("Repeated geometry" in issue for issue in report["errors"])


def test_quality_gate_requires_exported_pbr_maps(tmp_path):
    path = tmp_path / "flat.glb"
    write_glb(path, {"materials": [{"name": "Terrain", "pbrMetallicRoughness": {"baseColorTexture": {"index": 0}}}],
                     "meshes": [{"primitives": [{"material": 0}]}]})
    report = inspect_glb(path, require_pbr=True)
    assert any("Missing normal texture" in issue for issue in report["errors"])
    assert any("Missing roughness texture" in issue for issue in report["errors"])


def test_quality_gate_reports_scene_budget_and_rejects_excess(tmp_path):
    path = tmp_path / "heavy.glb"
    write_glb(path, {"meshes": [{"primitives": [{"attributes": {"POSITION": 0}}]}],
                     "accessors": [{"count": 6, "type": "VEC3", "componentType": 5126}],
                     "nodes": [{"mesh": 0}, {"mesh": 0}],
                     "images": [{"bufferView": 0}],
                     "bufferViews": [{"byteLength": 12}]}, b"0" * 12)
    report = inspect_glb(path, max_draw_calls=1, max_triangles=3, max_embedded_texture_bytes=8)
    assert report["estimated_draw_calls"] == 2
    assert report["triangles"] == 4
    assert report["embedded_texture_bytes"] == 12
    assert len(report["errors"]) == 3
