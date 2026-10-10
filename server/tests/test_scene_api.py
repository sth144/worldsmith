from __future__ import annotations

from uuid import uuid4

from fastapi.testclient import TestClient

from app.main import create_app


def chair(object_id: str) -> dict:
    return {
        "id": object_id,
        "name": "Chair",
        "asset": "assets/chair.glb",
        "parent_id": None,
        "position": [1, 0, 2],
        "rotation": [0, 0, 0, 1],
        "scale": [1, 1, 1],
        "visible": True,
        "locked": False,
        "metadata": {},
    }


def test_atomic_edits_revision_and_restart(tmp_path):
    app = create_app(tmp_path / "projects")
    client = TestClient(app)
    object_id = str(uuid4())
    assert client.get("/api/scenes/demo").json()["revision"] == 0
    failed = client.post("/api/scenes/demo/operations", json={
        "expected_revision": 0,
        "operations": [
            {"type": "add_object", "object": chair(object_id)},
            {"type": "set_transform", "object_id": object_id, "scale": [0, 1, 1]},
        ],
    })
    assert failed.status_code == 422
    assert client.get("/api/scenes/demo").json()["objects"] == []
    add = client.post("/api/scenes/demo/operations", json={
        "expected_revision": 0, "operations": [{"type": "add_object", "object": chair(object_id)}],
    })
    assert add.status_code == 200, add.text
    assert add.json()["revision"] == 1
    conflict = client.post("/api/scenes/demo/operations", json={
        "expected_revision": 0,
        "operations": [{"type": "set_transform", "object_id": object_id, "position": [2, 0, 2]}],
    })
    assert conflict.status_code == 409
    assert conflict.json()["detail"]["current_revision"] == 1
    move = client.post("/api/scenes/demo/operations", json={
        "expected_revision": 1,
        "operations": [{"type": "set_transform", "object_id": object_id, "position": [2, 0, 2]}],
    })
    assert move.status_code == 200
    assert move.json()["changes"][0]["object"]["position"] == [2, 0, 2]

    # A new process reads the same data and can still undo and redo.
    restarted = TestClient(create_app(tmp_path / "projects"))
    assert restarted.get("/api/scenes/demo").json()["objects"][0]["position"] == [2, 0, 2]
    undo = restarted.post("/api/scenes/demo/undo", json={"expected_revision": 2})
    assert undo.status_code == 200
    assert restarted.get("/api/scenes/demo").json()["objects"][0]["position"] == [1, 0, 2]
    redo = restarted.post("/api/scenes/demo/redo", json={"expected_revision": 3})
    assert redo.status_code == 200
    assert restarted.get("/api/scenes/demo").json()["objects"][0]["position"] == [2, 0, 2]
    assert restarted.get("/api/scenes/demo/history").json()["cursor"] == 2


def test_websocket_delta_and_assets(tmp_path):
    client = TestClient(create_app(tmp_path / "projects"))
    object_id = str(uuid4())
    assets = client.get("/api/assets").json()
    assert {item["id"] for item in assets} == {"chair", "table", "planter", "lantern", "hill", "tree", "environment"}
    assert client.get("/api/assets/chair").content[:4] == b"glTF"
    assert client.get("/api/assets/../scene.json").status_code in (400, 404)
    with client.websocket_connect("/ws/scenes/demo") as first:
        with client.websocket_connect("/ws/scenes/demo") as second:
            assert first.receive_json()["type"] == "snapshot"
            assert second.receive_json()["type"] == "snapshot"
            first.send_json({
                "type": "operation", "request_id": "one", "expected_revision": 0,
                "operations": [{"type": "add_object", "object": chair(object_id)}],
            })
            ack = first.receive_json()
            delta = second.receive_json()
            assert ack["type"] == "ack" and ack["revision"] == 1
            assert delta["type"] == "delta" and delta["changes"][0]["object"]["id"] == object_id
            first.send_json({
                "type": "operation", "request_id": "stale", "expected_revision": 0,
                "operations": [{"type": "delete_object", "object_id": object_id}],
            })
            conflict = first.receive_json()
            assert conflict["type"] == "conflict" and conflict["scene"]["revision"] == 1


def test_history_recovery_and_validation(tmp_path):
    app = create_app(tmp_path / "projects")
    client = TestClient(app)
    object_id = str(uuid4())
    response = client.post("/api/scenes/demo/operations", json={
        "expected_revision": 0, "operations": [{"type": "add_object", "object": chair(object_id)}],
    })
    assert response.status_code == 200
    path = tmp_path / "projects" / "demo" / "scene.json"
    path.write_text('{"schema_version":1,"scene_id":"demo","revision":0,"objects":[]}')
    recovered = TestClient(create_app(tmp_path / "projects"))
    assert recovered.get("/api/scenes/demo").json()["objects"][0]["id"] == object_id
    assert recovered.get("/api/scenes/demo").json()["revision"] == 1


def test_supported_object_operations(tmp_path):
    client = TestClient(create_app(tmp_path / "projects"))
    original_id, copy_id = str(uuid4()), str(uuid4())
    revision = 0

    def edit(operation):
        nonlocal revision
        response = client.post("/api/scenes/demo/operations", json={
            "expected_revision": revision, "operations": [operation],
        })
        assert response.status_code == 200, response.text
        revision = response.json()["revision"]
        return response.json()

    edit({"type": "add_object", "object": chair(original_id)})
    edit({"type": "set_visibility", "object_id": original_id, "visible": False})
    edit({"type": "set_material", "object_id": original_id, "color": [1, 0.1, 0.1, 1]})
    edit({"type": "replace_asset", "object_id": original_id, "asset": "assets/table.glb"})
    duplicate = edit({"type": "duplicate_object", "object_id": original_id, "new_id": copy_id})
    assert duplicate["changes"][0]["object"]["asset"] == "assets/table.glb"
    scene = client.get("/api/scenes/demo").json()
    assert len(scene["objects"]) == 2
    assert scene["objects"][0]["visible"] is False
    assert scene["objects"][0]["metadata"]["material_color"] == [1, 0.1, 0.1, 1]
    edit({"type": "delete_object", "object_id": copy_id})
    assert len(client.get("/api/scenes/demo").json()["objects"]) == 1

    bad = client.post("/api/scenes/demo/operations", json={
        "expected_revision": revision,
        "operations": [{"type": "replace_asset", "object_id": original_id, "asset": "assets/../secret.glb"}],
    })
    assert bad.status_code == 422
    bad = client.post("/api/scenes/demo/operations", json={
        "expected_revision": revision,
        "operations": [{"type": "set_transform", "object_id": original_id, "position": ["nan", 0, 0]}],
    })
    assert bad.status_code == 422
    assert client.get("/api/scenes/demo").json()["revision"] == revision
