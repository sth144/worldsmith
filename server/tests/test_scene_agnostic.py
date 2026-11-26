from fastapi.testclient import TestClient
from pathlib import Path
from uuid import uuid4
import shutil
import hashlib
import json
import struct
import pytest

from app.main import create_app
from app.export import register_environment


def test_new_install_has_no_bundled_scene_or_assets(tmp_path, monkeypatch):
    monkeypatch.delenv("WORLDSMITH_SCENE_SEED", raising=False)
    monkeypatch.delenv("WORLDSMITH_INITIAL_SCENE_ID", raising=False)
    client = TestClient(create_app(tmp_path / "projects"))
    assert list((tmp_path / "projects").iterdir()) == []
    assert client.get("/api/scenes/workshop").status_code == 404
    assert client.post("/api/scenes", json={"scene_id": "workshop"}).status_code == 201
    assert client.get("/api/assets?scene_id=workshop").json() == []
    assert client.get("/api/scenes/workshop/package").json() == {
        "scene_id": "workshop", "environment": None, "presentation": {}, "instances": []}
    assert client.get("/api/scenes/workshop/manifest").status_code == 422


def test_project_package_serves_environment_and_scene_settings(tmp_path):
    client = TestClient(create_app(tmp_path / "projects"))
    source = Path(__file__).parent / "fixtures" / "scene" / "assets" / "environment.glb"
    project = tmp_path / "projects" / "demo"
    settings = {"spawn": [1, 1.8, 2], "collision": {"walkable": ["floor"], "solid": ["wall"]},
                "hidden_meshes": ["hidden"], "sky": {"sky_top_color": [0.3, 0.4, 0.6]},
                "fog": {"density": 0.01}, "lights": [{"position": [0, 3, 0], "energy": 2}],
                "lighting": {"sun_energy": 0.4, "fill_energy": 0.2, "ambient_energy": 0.3}}
    register_environment(project, source, settings)
    package = client.get("/api/scenes/demo/package").json()
    assert package["environment"]["asset_id"] == "environment"
    assert len(package["environment"]["sha256"]) == 64
    assert package["presentation"]["spawn"] == [1, 1.8, 2]
    assert package["presentation"]["collision"]["walkable"] == ["floor"]
    assert package["presentation"]["lighting"]["sun_energy"] == 0.4
    assert client.get("/api/assets/environment?scene_id=demo").content[:4] == b"glTF"


def test_environment_registration_rejects_invalid_runtime_settings(tmp_path):
    source = Path(__file__).parent / "fixtures" / "scene" / "assets" / "environment.glb"
    with pytest.raises(ValueError, match="spawn"):
        register_environment(tmp_path, source, {"spawn": [0, "above", 0]})
    assert not (tmp_path / "environment.json").exists()


def test_scene_package_serves_versioned_instance_data(tmp_path):
    client = TestClient(create_app(tmp_path / "projects"))
    fixture = Path(__file__).parent / "fixtures" / "scene" / "assets"
    source = tmp_path / "source.glb"
    shutil.copyfile(fixture / "environment.glb", source)
    shutil.copyfile(fixture / "chair.glb", tmp_path / "prototype.glb")
    transform = struct.pack("<12f", 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0)
    (tmp_path / "transforms.bin").write_bytes(transform)
    source.with_name("source-instances.json").write_text(json.dumps({"groups": [
        {"glb": "prototype.glb", "transforms": "transforms.bin", "count": 1}]}))
    register_environment(tmp_path / "projects" / "demo", source)
    group = client.get("/api/scenes/demo/package").json()["instances"][0]
    assert group["count"] == 1
    prototype = client.get("/api/scenes/demo/package/instances/0/prototype")
    transforms = client.get("/api/scenes/demo/package/instances/0/transforms")
    assert prototype.status_code == transforms.status_code == 200
    assert hashlib.sha256(prototype.content).hexdigest() == group["prototype_sha256"]
    assert transforms.content == transform
    assert hashlib.sha256(transform).hexdigest() == group["transforms_sha256"]


def test_uncataloged_generated_asset_can_be_saved_without_entering_inventory(tmp_path):
    client = TestClient(create_app(tmp_path / "projects"))
    project = tmp_path / "projects" / "demo"
    shutil.copyfile(project / "assets" / "chair.glb", project / "assets" / "generated.glb")
    assert "generated" not in {item["id"] for item in client.get("/api/assets?scene_id=demo").json()}
    obj = {"id": str(uuid4()), "name": "Generated", "asset": "assets/generated.glb",
           "parent_id": None, "position": [0, 0, 0], "rotation": [0, 0, 0, 1],
           "scale": [1, 1, 1], "visible": True, "locked": False, "metadata": {}}
    response = client.post("/api/scenes/demo/operations", json={
        "expected_revision": 0, "operations": [{"type": "add_object", "object": obj}]})
    assert response.status_code == 200, response.text
