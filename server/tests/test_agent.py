from __future__ import annotations

from uuid import uuid4
import json
import shutil
import struct

from fastapi.testclient import TestClient

from app.main import create_app
from app.agent import validate_proposal
from fastapi import HTTPException
import pytest
from test_scene_api import chair


def test_direct_agent_edits_share_history_and_revision(tmp_path):
    client = TestClient(create_app(tmp_path / "projects"))
    object_id = str(uuid4())
    assert client.post("/api/scenes/demo/operations", json={
        "expected_revision": 0, "operations": [{"type": "add_object", "object": chair(object_id)}],
    }).status_code == 200
    result = client.post("/api/scenes/demo/agent", json={
        "expected_revision": 1, "prompt": "Make this chair twice as wide", "selected_object_ids": [object_id],
    })
    assert result.status_code == 200, result.text
    assert result.json()["revision"] == 2
    assert result.json()["changes"][0]["object"]["scale"] == [2, 1, 1]
    assert client.post("/api/scenes/demo/undo", json={"expected_revision": 2}).json()["changes"][0]["object"]["scale"] == [1, 1, 1]


def test_agent_rejects_stale_and_invalid_selection(tmp_path):
    client = TestClient(create_app(tmp_path / "projects"))
    object_id = str(uuid4())
    assert client.post("/api/scenes/demo/agent", json={
        "expected_revision": 0, "prompt": "Make it red", "selected_object_ids": [object_id],
    }).status_code == 422
    client.post("/api/scenes/demo/operations", json={
        "expected_revision": 0, "operations": [{"type": "add_object", "object": chair(object_id)}],
    })
    assert client.post("/api/scenes/demo/agent", json={
        "expected_revision": 0, "prompt": "Make it red", "selected_object_ids": [object_id],
    }).status_code == 409
    assert client.get("/api/scenes/demo").json()["revision"] == 1


def test_agent_cannot_edit_unselected_object():
    first, second = str(uuid4()), str(uuid4())
    scene = {"objects": [chair(first), chair(second)]}
    with pytest.raises(HTTPException) as error:
        validate_proposal([{"type": "delete_object", "object_id": second}], scene, [first], {"assets/chair.glb"})
    assert error.value.status_code == 422
    copy_id = str(uuid4())
    validate_proposal([
        {"type": "duplicate_object", "object_id": first, "new_id": copy_id},
        {"type": "set_transform", "object_id": copy_id, "position": [3, 0, 0]},
    ], scene, [first], {"assets/chair.glb"})


def test_view_prompt_places_hill_and_tree_as_one_undoable_edit(tmp_path):
    client = TestClient(create_app(tmp_path / "projects"))
    view = {"camera_position": [0, 1.7, 0], "camera_direction": [0, -0.5, -0.8660254],
            "target_position": [0, 0, -3]}
    result = client.post("/api/scenes/demo/agent", json={
        "expected_revision": 0, "prompt": "Put a hill over here with a tree on it",
        "selected_object_ids": [], "view": view,
    })
    assert result.status_code == 200, result.text
    objects = {obj["asset"]: obj for obj in client.get("/api/scenes/demo").json()["objects"]}
    assert set(objects) == {"assets/hill.glb", "assets/tree.glb"}
    assert objects["assets/tree.glb"]["position"] == [0, 1.12, -3]
    assert result.json()["revision"] == 1
    assert client.post("/api/scenes/demo/undo", json={"expected_revision": 1}).status_code == 200
    assert client.get("/api/scenes/demo").json()["objects"] == []
    assert client.post("/api/scenes/demo/redo", json={"expected_revision": 2}).status_code == 200
    assert len(TestClient(create_app(tmp_path / "projects")).get("/api/scenes/demo").json()["objects"]) == 2


def test_view_prompt_needs_valid_target_and_cannot_place_outside_view(tmp_path, monkeypatch):
    client = TestClient(create_app(tmp_path / "projects"))
    base = {"expected_revision": 0, "prompt": "Put a hill here", "selected_object_ids": []}
    assert client.post("/api/scenes/demo/agent", json=base).status_code == 422
    view = {"camera_position": [0, 1.7, 0], "camera_direction": [0, -1, 0],
            "target_position": [0, 0, -3]}
    assert client.post("/api/scenes/demo/agent", json={**base, "view": {
        **view, "target_position": [0, 0, -31]}}).status_code == 422

    async def bad_plan(*_args):
        return [{"type": "add_object", "object": {**chair(str(uuid4())),
                 "position": [100, 0, 0]}}]

    monkeypatch.setattr("app.main.codex_view_plan", bad_plan)
    response = client.post("/api/scenes/demo/agent", json={**base,
        "prompt": "Something elaborate", "view": view})
    assert response.status_code == 422
    assert client.get("/api/scenes/demo").json()["revision"] == 0


@pytest.mark.skipif(shutil.which("blender") is None, reason="Blender unavailable")
def test_view_placements_are_in_scene_export(tmp_path):
    client = TestClient(create_app(tmp_path / "projects"))
    response = client.post("/api/scenes/demo/agent", json={
        "expected_revision": 0, "prompt": "Put a hill here with a tree on it", "selected_object_ids": [],
        "view": {"camera_position": [0, 1.7, 0], "camera_direction": [0, -0.5, -0.8660254],
                 "target_position": [0, 0, -3]},
    })
    assert response.status_code == 200, response.text
    exported = client.get("/api/scenes/demo/export")
    assert exported.status_code == 200, exported.text[:300] if exported.status_code != 200 else ""
    length = struct.unpack_from("<I", exported.content, 12)[0]
    gltf = json.loads(exported.content[20:20 + length])
    names = {node.get("name") for node in gltf["nodes"]}
    assert "Gentle grassy hill" in names
    assert "Tree trunk" in names
