from __future__ import annotations

import json
import shutil
import struct
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from app.main import create_app
from app.export import register_environment
from test_scene_api import chair


@pytest.mark.skipif(shutil.which("blender") is None, reason="Blender unavailable")
def test_approved_mesh_edit_undo_and_portable_export(tmp_path):
    client = TestClient(create_app(tmp_path / "projects"))
    object_id = str(uuid4())
    add = client.post("/api/scenes/demo/operations", json={
        "expected_revision": 0, "operations": [{"type": "add_object", "object": chair(object_id)}],
    })
    assert add.status_code == 200
    proposal = client.post("/api/scenes/demo/agent", json={
        "expected_revision": 1, "prompt": "Round the corners of this chair",
        "selected_object_ids": [object_id],
    })
    assert proposal.status_code == 200
    job = proposal.json()["job"]
    assert job["status"] == "approval_required"
    assert client.get("/api/scenes/demo").json()["objects"][0]["asset"] == "assets/chair.glb"
    assert client.post(f"/api/scenes/demo/geometry/{job['id']}/approve", json={"expected_revision": 0}).status_code == 409
    assert client.get("/api/scenes/demo").json()["revision"] == 1
    approval = client.post(f"/api/scenes/demo/geometry/{job['id']}/approve", json={"expected_revision": 1})
    assert approval.status_code == 200, approval.text
    modified = approval.json()["changes"][0]["object"]["asset"]
    assert modified.startswith("assets/chair-v-")
    assert client.get("/api/assets/chair").content[:4] == b"glTF"
    assert modified in {item["path"] for item in client.get("/api/scenes/demo/manifest").json()["sources"]}
    undo = client.post("/api/scenes/demo/undo", json={"expected_revision": 2})
    assert undo.json()["changes"][0]["object"]["asset"] == "assets/chair.glb"
    redo = client.post("/api/scenes/demo/redo", json={"expected_revision": 3})
    assert redo.json()["changes"][0]["object"]["asset"] == modified
    exported = client.get("/api/scenes/demo/export")
    assert exported.status_code == 200, exported.text[:500] if exported.status_code != 200 else ""
    data = exported.content
    assert data[:4] == b"glTF"
    json_length = struct.unpack_from("<I", data, 12)[0]
    gltf = json.loads(data[20:20 + json_length])
    assert len(gltf["meshes"]) >= 2
    seat = next(node for node in gltf["nodes"] if node.get("name") == "Chair seat")
    assert seat["translation"][0] == pytest.approx(1)
    assert seat["translation"][2] == pytest.approx(2)
    assert client.get("/api/scenes/demo/manifest").json()["revision"] == 4


def test_register_environment_validates_before_replacing(tmp_path):
    app = create_app(tmp_path / "projects")
    project = app.state.store.project("demo")
    original = (project / "assets" / "environment.glb").read_bytes()
    bad = tmp_path / "bad.glb"
    bad.write_bytes(b"glTF" + b"bad" * 10)
    with pytest.raises(ValueError):
        register_environment(project, bad)
    assert (project / "assets" / "environment.glb").read_bytes() == original
