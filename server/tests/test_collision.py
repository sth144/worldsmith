"""An imported environment gets suggested collision roles that a person can review and save."""

from pathlib import Path

from fastapi.testclient import TestClient

from app.collision import mesh_bounds, suggest_roles, suggest_spawn
from app.main import create_app


ENVIRONMENT = Path(__file__).parent / "fixtures" / "scene" / "assets" / "environment.glb"


def imported(tmp_path) -> TestClient:
    client = TestClient(create_app(tmp_path / "projects"))
    assert client.post("/api/scenes", json={"scene_id": "world"}).status_code == 201
    assert client.post("/api/scenes/world/environment", content=ENVIRONMENT.read_bytes()).status_code == 200
    return client


def listed(client: TestClient) -> dict:
    return next(item for item in client.get("/api/scenes").json() if item["scene_id"] == "world")


def test_bounds_follow_node_transforms():
    document = {
        "scenes": [{"nodes": [0]}],
        "nodes": [{"name": "parent", "translation": [10, 0, 0], "scale": [2, 2, 2], "children": [1]},
                  {"name": "Slab.001", "mesh": 0, "translation": [0, 1, 0],
                   "rotation": [0, 0.7071068, 0, 0.7071068]}],
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0}}]}],
        "accessors": [{"min": [-1, 0, -3], "max": [1, 0.5, 3]}],
    }
    slab = mesh_bounds(document)[0]
    assert slab["name"] == "Slab_001"
    assert [round(value, 3) for value in slab["min"]] == [4, 2, -2]
    assert [round(value, 3) for value in slab["max"]] == [16, 3, 2]


def test_suggestions_separate_ground_obstacles_and_decals():
    meshes = [{"name": "terrain", "min": [-20, -1, -20], "max": [20, 2, 20]},
              {"name": "house", "min": [-3, 0, -3], "max": [3, 5, 3]},
              {"name": "path_decal", "min": [-1, 0, -10], "max": [1, 0.02, 10]},
              {"name": "table_top", "min": [8, 2.9, 8], "max": [10, 3.0, 9]}]
    roles = suggest_roles(meshes)
    assert roles == {"terrain": "walkable", "house": "solid", "path_decal": "none", "table_top": "solid"}
    x, y, z = suggest_spawn(meshes, roles)
    assert y == 2.5
    assert not (-3.6 <= x <= 3.6 and -3.6 <= z <= 3.6), "Spawn was placed inside the house"


def test_import_is_not_walkable_until_reviewed(tmp_path):
    client = imported(tmp_path)
    assert listed(client)["has_walkable"] is False
    review = client.get("/api/scenes/world/collision").json()
    assert review["reviewed"] is False
    roles = {mesh["name"]: mesh["role"] for mesh in review["meshes"]}
    assert roles["floor"] == "walkable"
    assert any(role == "solid" for role in roles.values())

    walkable = [name for name, role in roles.items() if role == "walkable"]
    solid = [name for name, role in roles.items() if role == "solid"]
    saved = client.put("/api/scenes/world/collision",
                       json={"walkable": walkable, "solid": solid, "spawn": review["spawn"]})
    assert saved.status_code == 200, saved.text
    assert saved.json()["reviewed"] is True
    assert listed(client)["has_walkable"] is True
    presentation = client.get("/api/scenes/world/package").json()["presentation"]
    assert presentation["collision"]["walkable"] == sorted(walkable)
    assert presentation["spawn"] == review["spawn"]


def test_review_rejects_invalid_roles(tmp_path):
    client = imported(tmp_path)
    spawn = [0, 1, 0]
    assert client.put("/api/scenes/world/collision", json={"walkable": [], "spawn": spawn}).status_code == 422
    assert client.put("/api/scenes/world/collision", json={"walkable": ["missing"], "spawn": spawn}).status_code == 422
    assert client.put("/api/scenes/world/collision",
                      json={"walkable": ["floor"], "solid": ["floor"], "spawn": spawn}).status_code == 422
    assert client.get("/api/scenes/empty/collision").status_code == 404
    assert client.post("/api/scenes", json={"scene_id": "empty"}).status_code == 201
    assert client.get("/api/scenes/empty/collision").status_code == 404
    assert listed(client)["has_walkable"] is False
