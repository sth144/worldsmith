"""Reviewed prompt requests must not become primitive scene objects by accident."""

import json
import struct
from pathlib import Path
from uuid import uuid4

from fastapi.testclient import TestClient

from app.main import create_app
from app.asset_requests import AssetLibrary
from test_scene_api import chair


VIEW = {"camera_position": [0, 1.7, 0], "camera_direction": [0, -0.5, -0.8660254],
        "target_position": [0, 0, -3]}


def minimal_glb(path: Path) -> None:
    document = json.dumps({"meshes": [{"primitives": [{}]}], "nodes": [{"mesh": 0}]}).encode()
    document += b" " * (-len(document) % 4)
    path.write_bytes(struct.pack("<4sII", b"glTF", 2, len(document) + 20)
                     + struct.pack("<I4s", len(document), b"JSON") + document)


def test_reviewed_prompt_waits_for_promoted_asset_then_places_immutable_version(tmp_path):
    root = tmp_path / "projects"
    client = TestClient(create_app(root))
    response = client.post("/api/scenes/demo/agent", json={
        "expected_revision": 0, "prompt": "Place an ornate observatory here",
        "view": VIEW, "creation_mode": "reviewed",
    })
    assert response.status_code == 200, response.text
    job = response.json()["job"]
    assert response.json()["status"] == "needs_asset"
    assert client.get("/api/scenes/demo").json()["objects"] == []
    assert client.get("/api/scenes/demo").json()["revision"] == 0

    source = tmp_path / "observatory.glb"
    minimal_glb(source)
    library = AssetLibrary(tmp_path / "library")
    candidate = library.register("observatory", source, "mesh", "authored", "project-owned",
                                 metadata={"godot_review": True}, promote=False)
    library.register("unreviewed", source, "mesh", "authored", "project-owned")
    library.database.close()
    url = f"/api/scenes/demo/asset-requests/{job['id']}/fulfill"
    blocked = client.post(url, json={"expected_revision": 0, "asset_id": "observatory"})
    assert blocked.status_code == 404
    assert client.post(url, json={"expected_revision": 0,
                                  "asset_id": "unreviewed"}).status_code == 422
    library = AssetLibrary(tmp_path / "library")
    library.promote("observatory", candidate["sha256"])
    library.database.close()

    placed = client.post(url, json={"expected_revision": 0, "asset_id": "observatory"})
    assert placed.status_code == 200, placed.text
    assert placed.json()["revision"] == 1
    assert placed.json()["job"]["asset_sha256"] == candidate["sha256"]
    obj = client.get("/api/scenes/demo").json()["objects"][0]
    assert obj["position"] == [0, 0, -3]
    assert obj["asset"].endswith(candidate["sha256"][:16] + ".glb")
    assert obj["asset"] in {item["path"] for item in client.get(
        "/api/assets", params={"scene_id": "demo"}).json()}
    assert client.get("/api/assets/" + Path(obj["asset"]).stem,
                      params={"scene_id": "demo"}).content == source.read_bytes()
    assert client.post(url, json={"expected_revision": 1, "asset_id": "observatory"}).status_code == 422
    assert client.post("/api/scenes/demo/undo", json={"expected_revision": 1}).status_code == 200
    assert client.get("/api/scenes/demo").json()["objects"] == []


def test_reviewed_request_conflicts_after_scene_changes(tmp_path):
    client = TestClient(create_app(tmp_path / "projects"))
    response = client.post("/api/scenes/demo/agent", json={
        "expected_revision": 0, "prompt": "Place a sculpted arch here",
        "view": VIEW, "creation_mode": "reviewed",
    })
    job_id = response.json()["job"]["id"]
    assert client.get(f"/api/scenes/demo/asset-requests/{job_id}").json()["status"] == "needs_asset"
    changed = client.post("/api/scenes/demo/operations", json={"expected_revision": 0,
        "operations": [{"type": "add_object", "object": chair(str(uuid4()))}]})
    assert changed.status_code == 200
    blocked = client.post(f"/api/scenes/demo/asset-requests/{job_id}/fulfill", json={
        "expected_revision": 1, "asset_id": "arch"})
    assert blocked.status_code == 409
