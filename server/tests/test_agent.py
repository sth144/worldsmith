from __future__ import annotations

from uuid import uuid4
import json
import shutil
import struct

from fastapi.testclient import TestClient

from app.main import create_app
from app.agent import _claude_json, validate_proposal
from app.procedural import validate_designs
from fastapi import HTTPException
import pytest
import asyncio
from test_scene_api import chair


def test_claude_cli_returns_structured_output_without_tools(monkeypatch):
    recorded = {}

    class FakeProcess:
        returncode = 0

        async def communicate(self, prompt):
            recorded["prompt"] = prompt
            return b'{"structured_output":{"operations":[{"type":"delete_object","object_id":"selected"}]}}', b""

    async def fake_spawn(*command, **options):
        recorded["command"] = command
        recorded["options"] = options
        return FakeProcess()

    monkeypatch.setattr("app.agent.shutil.which", lambda name: "/bin/claude")
    monkeypatch.setattr("app.agent.asyncio.create_subprocess_exec", fake_spawn)
    result = asyncio.run(_claude_json("Delete selected", {"type": "object"}))
    assert result["operations"][0]["object_id"] == "selected"
    assert recorded["command"][0] == "claude"
    assert recorded["command"][recorded["command"].index("--tools") + 1] == ""
    assert "--safe-mode" in recorded["command"]
    assert "--json-schema" in recorded["command"]
    assert recorded["prompt"] == b"Delete selected"


def test_claude_provider_routes_through_scene_validator(tmp_path, monkeypatch):
    client = TestClient(create_app(tmp_path / "projects"))
    first, second = str(uuid4()), str(uuid4())
    assert client.post("/api/scenes/demo/operations", json={
        "expected_revision": 0, "operations": [
            {"type": "add_object", "object": chair(first)},
            {"type": "add_object", "object": chair(second)},
        ],
    }).status_code == 200

    async def bad_plan(*_args):
        return [{"type": "delete_object", "object_id": second}]

    monkeypatch.setattr("app.main.claude_plan", bad_plan)
    request = {"expected_revision": 1, "prompt": "I no longer want the selected item in this space",
               "provider": "claude", "selected_object_ids": [first]}
    assert client.post("/api/scenes/demo/agent", json=request).status_code == 422
    assert client.get("/api/scenes/demo").json()["revision"] == 1

    async def good_plan(*_args):
        return [{"type": "delete_object", "object_id": first}]

    monkeypatch.setattr("app.main.claude_plan", good_plan)
    result = client.post("/api/scenes/demo/agent", json=request)
    assert result.status_code == 200, result.text
    assert result.json()["planner"] == "claude"
    assert [obj["id"] for obj in client.get("/api/scenes/demo").json()["objects"]] == [second]
    assert client.post("/api/scenes/demo/agent", json={**request, "provider": "unknown"}).status_code == 422


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


def test_view_prompt_places_catalog_asset_as_one_undoable_edit(tmp_path):
    client = TestClient(create_app(tmp_path / "projects"))
    view = {"camera_position": [0, 1.7, 0], "camera_direction": [0, -0.5, -0.8660254],
            "target_position": [0, 0, -3]}
    result = client.post("/api/scenes/demo/agent", json={
        "expected_revision": 0, "prompt": "Put a chair over here",
        "selected_object_ids": [], "view": view,
    })
    assert result.status_code == 200, result.text
    objects = {obj["asset"]: obj for obj in client.get("/api/scenes/demo").json()["objects"]}
    assert set(objects) == {"assets/chair.glb"}
    assert objects["assets/chair.glb"]["position"] == [0, 0, -3]
    assert result.json()["revision"] == 1
    assert client.post("/api/scenes/demo/undo", json={"expected_revision": 1}).status_code == 200
    assert client.get("/api/scenes/demo").json()["objects"] == []
    assert client.post("/api/scenes/demo/redo", json={"expected_revision": 2}).status_code == 200
    assert len(TestClient(create_app(tmp_path / "projects")).get("/api/scenes/demo").json()["objects"]) == 1


@pytest.mark.skipif(shutil.which("blender") is None, reason="Blender unavailable")
def test_unlisted_prompt_generates_asset_and_survives_restart(tmp_path, monkeypatch):
    root = tmp_path / "projects"
    client = TestClient(create_app(root))
    async def design(*_args):
        return [{"name": "Dragon arch", "offset": [0, 0, 0], "parts": [
            {"name": "Foot", "shape": "box", "center": [0, 0.2, 0],
             "size": [1, 0.4, 0.5], "yaw": 0, "color": [0.5, 0.4, 0.3]},
            {"name": "Crest", "shape": "ellipsoid", "center": [0, 0.8, 0],
             "size": [0.6, 0.8, 0.3], "yaw": 15, "color": [0.7, 0.5, 0.2]},
        ]}]
    monkeypatch.setattr("app.main.creative_view_plan", design)
    view = {"camera_position": [0, 1.7, 0], "camera_direction": [0, -0.5, -0.8660254],
            "target_position": [0, 0, -3]}
    response = client.post("/api/scenes/demo/agent", json={
        "expected_revision": 0, "prompt": "put a dragon arch here", "provider": "claude",
        "selected_object_ids": [], "view": view,
    })
    assert response.status_code == 200, response.text
    assert response.json()["planner"] == "claude"
    asset = response.json()["operations"][0]["object"]["asset"]
    assert asset.startswith("assets/generated-")
    assert client.get("/api/assets/" + asset[7:-4], params={"scene_id": "demo"}).status_code == 200
    saved = TestClient(create_app(root)).get("/api/scenes/demo").json()
    assert saved["objects"][0]["position"] == [0, 0, -3]
    assert saved["objects"][0]["asset"] == asset
    exported = client.get("/api/scenes/demo/export")
    assert exported.status_code == 200, exported.text[:300] if exported.status_code != 200 else ""
    length = struct.unpack_from("<I", exported.content, 12)[0]
    gltf = json.loads(exported.content[20:20 + length])
    assert "Crest" in {node.get("name") for node in gltf["nodes"]}
    assert client.post("/api/scenes/demo/undo", json={"expected_revision": 1}).status_code == 200
    assert client.get("/api/scenes/demo").json()["objects"] == []


def test_unlisted_creation_needs_view_and_invalid_design_is_rejected(tmp_path):
    client = TestClient(create_app(tmp_path / "projects"))
    response = client.post("/api/scenes/demo/agent", json={
        "expected_revision": 0, "prompt": "put a dragon statue here", "selected_object_ids": [],
    })
    assert response.status_code == 422
    assert "Look at a floor point" in response.json()["detail"]
    with pytest.raises(HTTPException) as error:
        validate_designs([{"name": "Huge", "offset": [0, 0, 0], "parts": [{
            "name": "Bad", "shape": "box", "center": [0, 0, 0],
            "size": [100, 1, 1], "yaw": 0, "color": [1, 1, 1],
        }]}])
    assert error.value.status_code == 422


def test_aimed_chair_can_be_removed_or_used_as_placement_context(tmp_path):
    client = TestClient(create_app(tmp_path / "projects"))
    chair_id = str(uuid4())
    assert client.post("/api/scenes/demo/operations", json={
        "expected_revision": 0, "operations": [{"type": "add_object", "object": chair(chair_id)}],
    }).status_code == 200
    view = {"camera_position": [0, 1.7, 0], "camera_direction": [0, -0.5, -0.8660254],
            "target_position": [0, 0, -3]}
    removed = client.post("/api/scenes/demo/agent", json={
        "expected_revision": 1, "prompt": "Get rid of the red chair", "selected_object_ids": [chair_id],
        "view": view,
    })
    assert removed.status_code == 200, removed.text
    assert removed.json()["planner"] == "local"
    assert removed.json()["operations"] == [{"type": "delete_object", "object_id": chair_id}]
    assert client.get("/api/scenes/demo").json()["objects"] == []
    assert client.post("/api/scenes/demo/undo", json={"expected_revision": 2}).status_code == 200
    placed = client.post("/api/scenes/demo/agent", json={
        "expected_revision": 3, "prompt": "Put a hill here",
        "selected_object_ids": [chair_id], "view": view,
    })
    assert placed.status_code == 200, placed.text
    assert len(client.get("/api/scenes/demo").json()["objects"]) == 2


def test_described_red_chair_wins_over_overlapping_brown_chair(tmp_path):
    client = TestClient(create_app(tmp_path / "projects"))
    brown_id, red_id = str(uuid4()), str(uuid4())
    brown = {**chair(brown_id), "position": [1, 0, -3]}
    red = {**chair(red_id), "position": [0, 0, -3],
           "metadata": {"material_color": [0.85, 0.08, 0.06, 1]}}
    assert client.post("/api/scenes/demo/operations", json={
        "expected_revision": 0, "operations": [
            {"type": "add_object", "object": brown}, {"type": "add_object", "object": red}],
    }).status_code == 200
    view = {"camera_position": [0, 1.7, 0], "camera_direction": [0, -0.5, -0.8660254],
            "target_position": [0, 0, -3]}
    result = client.post("/api/scenes/demo/agent", json={
        "expected_revision": 1, "prompt": "Get rid of the red chair", "selected_object_ids": [],
        "aimed_object_id": brown_id, "view": view,
    })
    assert result.status_code == 200, result.text
    assert result.json()["target_source"] == "described in view"
    assert result.json()["operations"] == [{"type": "delete_object", "object_id": red_id}]
    assert [obj["id"] for obj in client.get("/api/scenes/demo").json()["objects"]] == [brown_id]


def test_view_prompt_needs_valid_target_and_cannot_place_outside_view(tmp_path, monkeypatch):
    client = TestClient(create_app(tmp_path / "projects"))
    base = {"expected_revision": 0, "prompt": "Put a hill here", "selected_object_ids": []}
    assert client.post("/api/scenes/demo/agent", json=base).status_code == 422
    view = {"camera_position": [0, 1.7, 0], "camera_direction": [0, -0.5, -0.8660254],
            "target_position": [0, 0, -3]}
    assert client.post("/api/scenes/demo/agent", json={**base, "view": {
        **view, "target_position": [0, 0, -31]}}).status_code == 422

    async def bad_plan(*_args):
        return [{"type": "add_object", "object": {**chair(str(uuid4())),
                 "position": [100, 0, 0]}}]

    monkeypatch.setattr("app.main.codex_view_plan", bad_plan)
    response = client.post("/api/scenes/demo/agent", json={**base,
        "prompt": "Build a row of chairs", "view": view})
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
