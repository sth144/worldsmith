from __future__ import annotations

from uuid import uuid4

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
