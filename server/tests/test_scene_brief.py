"""A scene prompt produces a durable plan without inserting draft objects."""

from fastapi.testclient import TestClient
import pytest

from app.main import create_app
from app.scene_brief import validate_brief


BRIEF = {
    "concept": "A walkable outdoor space with a clear focal destination.",
    "visual_direction": "Layered materials, varied silhouettes, and soft evening light.",
    "walkable_layout": "A main route connects the entrance to the focal structure.",
    "ground_strategy": "Physical relief supports tiled soil and stone materials.",
    "lighting": "A warm low sun and cool sky fill establish depth.",
    "assets": [
        {"key": "terrain", "description": "Walkable terrain with relief and material zones.",
         "role": "terrain", "quantity": 1, "placement": "Under all routes at y=0.",
         "editable": False},
        {"key": "focal_structure", "description": "A distinct modular focal structure.",
         "role": "architecture", "quantity": 1, "placement": "At the far end of the route.",
         "editable": True},
    ],
}


def test_brief_is_saved_and_scene_remains_editable(tmp_path, monkeypatch):
    async def fake_plan(prompt: str, provider: str) -> dict:
        assert provider == "codex"
        assert "walkable" in prompt
        return BRIEF

    monkeypatch.setattr("app.main.plan_scene_brief", fake_plan)
    client = TestClient(create_app(tmp_path / "projects"))
    before = client.get("/api/scenes/demo").json()
    response = client.post("/api/scenes/demo/brief", json={
        "expected_revision": before["revision"],
        "prompt": "Create a walkable space with a clear destination",
    })
    assert response.status_code == 200, response.text
    assert response.json()["status"] == "needs_assets"
    assert response.json()["brief"]["assets"][1]["key"] == "focal_structure"
    assert client.get("/api/scenes/demo/brief").json() == response.json()
    assert client.get("/api/scenes/demo").json() == before
    assert (tmp_path / "projects" / "demo" / "brief.json").is_file()


def test_brief_rejects_stale_revision_before_planning(tmp_path, monkeypatch):
    async def should_not_plan(_prompt: str, _provider: str) -> dict:
        pytest.fail("Planner should not run for a stale revision")

    monkeypatch.setattr("app.main.plan_scene_brief", should_not_plan)
    client = TestClient(create_app(tmp_path / "projects"))
    response = client.post("/api/scenes/demo/brief", json={
        "expected_revision": 99,
        "prompt": "Create a walkable space with a clear destination",
    })
    assert response.status_code == 409


def test_brief_rejects_duplicate_asset_keys():
    with pytest.raises(Exception):
        validate_brief({**BRIEF, "assets": [BRIEF["assets"][0]] * 2})
