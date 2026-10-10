from __future__ import annotations

import json
import shutil
import struct
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from app.main import create_app
from test_scene_api import chair


def _prepared_client(tmp_path):
    client = TestClient(create_app(tmp_path / "projects"))
    object_id = str(uuid4())
    client.post("/api/scenes/demo/operations", json={
        "expected_revision": 0, "operations": [{"type": "add_object", "object": chair(object_id)}],
    })
    client.post("/api/scenes/demo/operations", json={
        "expected_revision": 1, "operations": [{"type": "set_material", "object_id": object_id,
                                             "color": [0.85, 0.08, 0.06, 1]}],
    })
    result = client.post("/api/scenes/demo/agent", json={
        "expected_revision": 2, "prompt": "Turn the upholstery red", "selected_object_ids": [object_id],
    })
    assert result.status_code == 200, result.text
    assert result.json()["operations"] == [{"type": "set_material", "object_id": object_id,
                                               "color": [0.85, 0.08, 0.06, 1],
                                               "material_name": "Sea green fabric"}]
    metadata = client.get("/api/scenes/demo").json()["objects"][0]["metadata"]
    assert "material_color" not in metadata
    assert metadata["material_overrides"] == {"Sea green fabric": [0.85, 0.08, 0.06, 1]}
    bad = client.post("/api/scenes/demo/operations", json={
        "expected_revision": 3, "operations": [{"type": "set_material", "object_id": object_id,
                                             "color": [1, 0, 0, 1], "material_name": "Imaginary fabric"}],
    })
    assert bad.status_code == 422
    assert client.get("/api/scenes/demo").json()["revision"] == 3
    return client


def test_upholstery_request_replaces_global_tint_and_validates_material(tmp_path):
    _prepared_client(tmp_path)


@pytest.mark.skipif(shutil.which("blender") is None, reason="Blender unavailable")
def test_export_recolors_only_cushion(tmp_path):
    client = _prepared_client(tmp_path)
    response = client.get("/api/scenes/demo/export")
    assert response.status_code == 200, response.text[:500] if response.status_code != 200 else ""
    data = response.content
    json_length = struct.unpack_from("<I", data, 12)[0]
    gltf = json.loads(data[20:20 + json_length])
    nodes = {node["name"]: node for node in gltf["nodes"] if "name" in node}
    def color_for(name: str) -> list[float]:
        mesh = gltf["meshes"][nodes[name]["mesh"]]
        material = gltf["materials"][mesh["primitives"][0]["material"]]
        return material["pbrMetallicRoughness"]["baseColorFactor"]
    cushion = color_for("Chair cushion")
    seat = color_for("Chair seat")
    assert cushion[0] == pytest.approx(0.85, abs=0.01)
    assert cushion[1] == pytest.approx(0.08, abs=0.01)
    assert seat[0] != pytest.approx(cushion[0], abs=0.01) or seat[1] != pytest.approx(cushion[1], abs=0.01)
