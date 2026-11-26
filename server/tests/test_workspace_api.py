"""Home-screen scene and asset actions use durable, scene-independent APIs."""

from pathlib import Path

from fastapi.testclient import TestClient

from app.main import create_app


FIXTURE = Path(__file__).parent / "fixtures" / "scene" / "assets" / "chair.glb"


def test_scene_listing_and_environment_import(tmp_path):
    client = TestClient(create_app(tmp_path / "projects"))
    assert all(item["scene_id"] != "new_world" for item in client.get("/api/scenes").json())
    assert client.post("/api/scenes", json={"scene_id": "new_world"}).status_code == 201
    assert next(item for item in client.get("/api/scenes").json() if item["scene_id"] == "new_world")["has_environment"] is False
    imported = client.post("/api/scenes/new_world/environment", content=FIXTURE.read_bytes())
    assert imported.status_code == 200, imported.text
    assert next(item for item in client.get("/api/scenes").json() if item["scene_id"] == "new_world")["has_environment"] is True
    assert client.get("/api/scenes/new_world/package").json()["environment"] is not None
    assert client.post("/api/scenes/new_world/environment", content=FIXTURE.read_bytes()).status_code == 409


def test_asset_import_and_production_request(tmp_path):
    client = TestClient(create_app(tmp_path / "projects"))
    uploaded = client.post("/api/library/assets/new_prop", content=FIXTURE.read_bytes(),
                           headers={"X-Filename": "new_prop.glb"})
    assert uploaded.status_code == 201, uploaded.text
    assert uploaded.json()["metadata"]["godot_review"] is False
    listed = client.get("/api/library/assets").json()
    assert [item["asset_id"] for item in listed] == ["new_prop"]
    assert client.get("/api/library/assets/new_prop/glb").content == FIXTURE.read_bytes()
    requested = client.post("/api/library/requests", json={"prompt": "Carved timber doorway with metalwork"})
    assert requested.status_code == 201
    assert requested.json()["status"] == "needs_production"
    assert client.get("/api/library/requests").json()[0]["id"] == requested.json()["id"]
    assert client.post("/api/library/assets/bad_prop", content=b"not a glb").status_code == 422
