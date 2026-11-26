"""An imported environment gets suggested collision roles that a person can review and save."""

import math
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


def scattered_scene_glb() -> bytes:
    """A flat ground and one mesh of small boxes scattered across it, as trees usually are."""
    import json
    import struct

    def box(cx: float, cz: float) -> tuple[list, list]:
        corners = [(cx + x, y, cz + z) for x in (-0.4, 0.4) for y in (0.0, 3.0) for z in (-0.4, 0.4)]
        faces = [0, 1, 3, 0, 3, 2, 4, 6, 7, 4, 7, 5, 0, 4, 5, 0, 5, 1, 2, 3, 7, 2, 7, 6, 0, 2, 6, 0, 6, 4, 1, 5, 7, 1, 7, 3]
        return corners, faces

    ground = ([(-20, 0, -20), (20, 0, -20), (20, 0, 20), (-20, 0, 20)], [0, 2, 1, 0, 3, 2])
    scatter_points, scatter_faces = [], []
    for cx, cz in [(0, 0), (-15, -15), (15, 15), (-15, 15), (15, -15), (6, 0)]:
        corners, faces = box(cx, cz)
        scatter_faces += [index + len(scatter_points) for index in faces]
        scatter_points += corners
    binary, views, accessors, meshes = b"", [], [], []
    for name, (points, faces) in (("Ground", ground), ("Trees", (scatter_points, scatter_faces))):
        position_bytes = b"".join(struct.pack("<3f", *point) for point in points)
        index_bytes = struct.pack(f"<{len(faces)}H", *faces)
        index_bytes += b"\0" * (-len(index_bytes) % 4)
        views += [{"buffer": 0, "byteOffset": len(binary), "byteLength": len(position_bytes)},
                  {"buffer": 0, "byteOffset": len(binary) + len(position_bytes), "byteLength": len(index_bytes)}]
        accessors += [{"bufferView": len(views) - 2, "componentType": 5126, "count": len(points), "type": "VEC3",
                       "min": [min(point[axis] for point in points) for axis in range(3)],
                       "max": [max(point[axis] for point in points) for axis in range(3)]},
                      {"bufferView": len(views) - 1, "componentType": 5123, "count": len(faces), "type": "SCALAR"}]
        meshes.append({"name": name, "primitives": [{"attributes": {"POSITION": len(accessors) - 2}, "indices": len(accessors) - 1}]})
        binary += position_bytes + index_bytes
    document = json.dumps({"asset": {"version": "2.0"}, "scenes": [{"nodes": [0, 1]}],
                           "nodes": [{"name": "Ground", "mesh": 0}, {"name": "Trees", "mesh": 1}],
                           "meshes": meshes, "accessors": accessors, "bufferViews": views,
                           "buffers": [{"byteLength": len(binary)}]}).encode()
    document += b" " * (-len(document) % 4)
    total = 12 + 8 + len(document) + 8 + len(binary)
    return (struct.pack("<4sII", b"glTF", 2, total) + struct.pack("<II", len(document), 0x4E4F534A) + document
            + struct.pack("<II", len(binary), 0x004E4942) + binary)


def test_scattered_meshes_are_not_mistaken_for_ground(tmp_path):
    client = TestClient(create_app(tmp_path / "projects"))
    assert client.post("/api/scenes", json={"scene_id": "woods"}).status_code == 201
    assert client.post("/api/scenes/woods/environment", content=scattered_scene_glb()).status_code == 200
    review = client.get("/api/scenes/woods/collision").json()
    roles = {mesh["name"]: mesh["suggested"] for mesh in review["meshes"]}
    assert roles == {"Ground": "walkable", "Trees": "solid"}
    x, y, z = review["suggested_spawn"]
    assert y == 0.5
    assert math.hypot(x, z) > 1.4 and math.hypot(x - 6, z) > 1.4, "Spawn was placed inside a tree"
    assert math.hypot(x, z) < 6, "Spawn should be near the middle of the scene"
