"""Build a portable GLB from the server snapshot and registered environment."""

from __future__ import annotations

import hashlib
import json
import math
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from fastapi import HTTPException

from .history import write_json
from .assets import validate_glb

REPO = Path(__file__).resolve().parents[2]


def _finite_vector(value: object, size: int, label: str) -> list[float]:
    if not isinstance(value, list) or len(value) != size or any(
        type(item) not in (int, float) or not math.isfinite(item) or abs(item) > 100_000
        for item in value
    ):
        raise ValueError(f"{label} must contain {size} finite numbers")
    return [float(item) for item in value]


def _finite_scalar(value: object, label: str, low: float, high: float) -> float:
    if type(value) not in (int, float) or not math.isfinite(value) or not low <= value <= high:
        raise ValueError(f"{label} must be in {low}..{high}")
    return float(value)


def _presentation_settings(settings: dict) -> dict:
    """Validate portable runtime settings without tying them to an environment."""
    allowed = {"spawn", "collision", "hidden_meshes", "sky", "fog", "lights", "lighting"}
    if not isinstance(settings, dict) or set(settings) - allowed:
        raise ValueError("Unsupported presentation settings")
    clean: dict = {}
    if "spawn" in settings:
        clean["spawn"] = _finite_vector(settings["spawn"], 3, "spawn")
    for key in ("hidden_meshes",):
        if key in settings:
            names = settings[key]
            if not isinstance(names, list) or len(names) > 128 or any(
                not isinstance(name, str) or not 1 <= len(name) <= 128 for name in names
            ):
                raise ValueError(f"{key} must be an array of mesh names")
            clean[key] = names
    if "collision" in settings:
        collision = settings["collision"]
        if not isinstance(collision, dict) or set(collision) - {"walkable", "solid"}:
            raise ValueError("Invalid collision settings")
        clean_collision = {}
        for key in ("walkable", "solid"):
            names = collision.get(key, [])
            if not isinstance(names, list) or len(names) > 128 or any(
                not isinstance(name, str) or not 1 <= len(name) <= 128 for name in names
            ):
                raise ValueError(f"collision.{key} must be an array of mesh names")
            clean_collision[key] = names
        clean["collision"] = clean_collision
    if "sky" in settings:
        sky = settings["sky"]
        fields = {"sky_top_color", "sky_horizon_color", "ground_horizon_color", "ground_bottom_color"}
        if not isinstance(sky, dict) or set(sky) - fields:
            raise ValueError("Invalid sky settings")
        clean["sky"] = {key: _finite_vector(value, 3, f"sky.{key}") for key, value in sky.items()}
    if "fog" in settings:
        fog = settings["fog"]
        if not isinstance(fog, dict) or set(fog) - {"enabled", "color", "density", "sky_affect"}:
            raise ValueError("Invalid fog settings")
        clean_fog = {}
        if "enabled" in fog:
            if type(fog["enabled"]) is not bool:
                raise ValueError("fog.enabled must be a boolean")
            clean_fog["enabled"] = fog["enabled"]
        if "color" in fog:
            clean_fog["color"] = _finite_vector(fog["color"], 3, "fog.color")
        for key in ("density", "sky_affect"):
            if key in fog:
                clean_fog[key] = _finite_scalar(fog[key], f"fog.{key}", 0, 1)
        clean["fog"] = clean_fog
    if "lighting" in settings:
        lighting = settings["lighting"]
        fields = {"sun_energy", "fill_energy", "ambient_energy"}
        if not isinstance(lighting, dict) or set(lighting) - fields:
            raise ValueError("Invalid lighting settings")
        clean["lighting"] = {
            key: _finite_scalar(value, f"lighting.{key}", 0, 16)
            for key, value in lighting.items()
        }
    if "lights" in settings:
        lights = settings["lights"]
        if not isinstance(lights, list) or len(lights) > 64:
            raise ValueError("lights must be an array of objects")
        clean_lights = []
        for item in lights:
            if not isinstance(item, dict) or set(item) - {"position", "color", "energy", "range", "shadows"}:
                raise ValueError("Invalid light settings")
            light = {}
            if "position" in item:
                light["position"] = _finite_vector(item["position"], 3, "light.position")
            if "color" in item:
                light["color"] = _finite_vector(item["color"], 3, "light.color")
            for key in ("energy", "range"):
                if key in item:
                    light[key] = _finite_scalar(item[key], f"light.{key}", 0, 100_000)
            if "shadows" in item:
                if type(item["shadows"]) is not bool:
                    raise ValueError("light.shadows must be a boolean")
                light["shadows"] = item["shadows"]
            clean_lights.append(light)
        clean["lights"] = clean_lights
    return clean


def register_environment(project: Path, source: Path, settings: dict | None = None) -> dict:
    if not source.is_file() or source.suffix.lower() != ".glb" or source.stat().st_size < 20:
        raise ValueError("Environment must be an existing GLB")
    validate_glb(source)
    manifest = {"asset": "assets/environment.glb", "source": source.name, "instances": []}
    if settings is not None:
        presentation = _presentation_settings(settings)
        manifest["presentation"] = presentation
        if "hidden_meshes" in presentation:
            manifest["hidden_meshes"] = presentation["hidden_meshes"]
    sidecar = source.with_name(source.stem + "-instances.json")
    copies: list[tuple[Path, Path]] = []
    if sidecar.is_file():
        groups = json.loads(sidecar.read_text()).get("groups", [])
        if not isinstance(groups, list) or len(groups) > 64:
            raise ValueError("Invalid instance manifest")
        for index, group in enumerate(groups):
            count = group.get("count")
            if type(count) is not int or not 0 < count <= 100_000:
                raise ValueError("Invalid instance count")
            prototype = source.parent / Path(group["glb"]).name
            transforms = source.parent / Path(group["transforms"]).name
            if not prototype.is_file() or not transforms.is_file() or transforms.stat().st_size != count * 48:
                raise ValueError("Missing instance data")
            validate_glb(prototype)
            prototype_name = f"environment-instance-{index}.glb"
            transforms_name = f"environment-instance-{index}.bin"
            copies.extend(((prototype, project / "assets" / prototype_name),
                           (transforms, project / "assets" / transforms_name)))
            manifest["instances"].append({"glb": f"assets/{prototype_name}",
                                          "transforms": f"assets/{transforms_name}", "count": count})
    copies.insert(0, (source, project / "assets" / "environment.glb"))
    (project / "assets").mkdir(parents=True, exist_ok=True)
    for incoming_path, destination in copies:
        with tempfile.NamedTemporaryFile(dir=destination.parent, suffix=destination.suffix, delete=False) as temporary:
            temporary_path = Path(temporary.name)
            with incoming_path.open("rb") as incoming:
                shutil.copyfileobj(incoming, temporary)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_path, destination)
    write_json(project / "environment.json", manifest)
    return manifest


def scene_package(project: Path) -> dict:
    """Describe the scene's runtime environment without exporting its edit graph."""
    path = project / "environment.json"
    if not path.is_file():
        return {"environment": None, "presentation": {}, "instances": []}
    manifest = json.loads(path.read_text())
    asset = manifest.get("asset")
    if asset != "assets/environment.glb":
        raise HTTPException(500, "Stored environment manifest is invalid")
    source = project / asset
    if not source.is_file():
        raise HTTPException(500, "Stored environment asset is missing")
    try:
        presentation = _presentation_settings(manifest.get("presentation", {}))
    except ValueError as exc:
        raise HTTPException(500, "Stored presentation settings are invalid") from exc
    if "hidden_meshes" not in presentation and manifest.get("hidden_meshes"):
        presentation["hidden_meshes"] = manifest["hidden_meshes"]
    groups = []
    for index, group in enumerate(manifest.get("instances", [])):
        count = group.get("count")
        if type(count) is not int or not 0 < count <= 100_000 or index >= 64:
            raise HTTPException(500, "Stored instance group is invalid")
        prototype = scene_instance_path(project, index, "prototype")
        transforms = scene_instance_path(project, index, "transforms")
        if transforms.stat().st_size != count * 48:
            raise HTTPException(500, "Stored instance transforms are invalid")
        groups.append({"index": index, "count": count,
                       "prototype_sha256": _file_sha256(prototype),
                       "transforms_sha256": _file_sha256(transforms)})
    return {"environment": {"asset_id": "environment", "sha256": _file_sha256(source)},
            "presentation": presentation, "instances": groups}


def _file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def scene_instance_path(project: Path, index: int, kind: str) -> Path:
    manifest_path = project / "environment.json"
    if not manifest_path.is_file():
        raise HTTPException(404, "Scene environment is not registered")
    groups = json.loads(manifest_path.read_text()).get("instances", [])
    if index < 0 or index >= len(groups) or index >= 64 or kind not in {"prototype", "transforms"}:
        raise HTTPException(404, "Instance data not found")
    expected = f"assets/environment-instance-{index}.{'glb' if kind == 'prototype' else 'bin'}"
    key = "glb" if kind == "prototype" else "transforms"
    if groups[index].get(key) != expected:
        raise HTTPException(500, "Stored instance manifest is invalid")
    path = project / expected
    if not path.is_file():
        raise HTTPException(500, "Stored instance asset is missing")
    return path


def source_manifest(project: Path, scene: dict) -> dict:
    environment_file = project / "environment.json"
    if not environment_file.is_file():
        raise HTTPException(422, "No environment GLB registered")
    environment = json.loads(environment_file.read_text())
    paths = {environment["asset"]} | {obj["asset"] for obj in scene["objects"]}
    for group in environment.get("instances", []):
        paths.update((group["glb"], group["transforms"]))
    sources = []
    for relative in sorted(paths):
        path = project / relative
        if not path.is_file() or path.parent != project / "assets":
            raise HTTPException(422, f"Missing source asset: {relative}")
        digest = hashlib.sha256()
        with path.open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
        sources.append({"path": relative, "bytes": path.stat().st_size, "sha256": digest.hexdigest()})
    exporter_hash = hashlib.sha256((REPO / "scripts" / "blender_scene_export.py").read_bytes()).hexdigest()
    return {"scene_id": scene["scene_id"], "revision": scene["revision"],
            "environment": environment, "sources": sources, "exporter_sha256": exporter_hash}


def export_scene(project: Path, scene: dict) -> tuple[Path, dict]:
    manifest = source_manifest(project, scene)
    output_dir = project / "exports"
    output_dir.mkdir(exist_ok=True)
    output = output_dir / f"{scene['scene_id']}-r{scene['revision']}.glb"
    manifest_path = output.with_suffix(".json")
    if output.is_file() and manifest_path.is_file() and json.loads(manifest_path.read_text()) == manifest:
        return output, manifest
    blender = shutil.which("blender")
    if blender is None:
        raise HTTPException(503, "Blender executable is unavailable")
    with tempfile.TemporaryDirectory(prefix="worldsmith-export-") as directory:
        config = Path(directory) / "config.json"
        config.write_text(json.dumps({"project": str(project), "scene": scene,
                                      "environment": manifest["environment"], "output": str(Path(directory) / "scene.glb")}))
        try:
            result = subprocess.run(
                [blender, "--background", "--factory-startup", "--disable-autoexec", "--python",
                 str(REPO / "scripts" / "blender_scene_export.py"), "--", str(config)],
                cwd=directory, capture_output=True, text=True, timeout=600,
            )
        except subprocess.TimeoutExpired as exc:
            raise HTTPException(504, "Blender export timed out") from exc
        generated = Path(directory) / "scene.glb"
        if result.returncode != 0 or not generated.is_file():
            raise HTTPException(500, "Blender export failed: " + (result.stderr or result.stdout)[-500:])
        try:
            validate_glb(generated)
        except ValueError as exc:
            raise HTTPException(500, f"Blender produced an invalid GLB: {exc}") from exc
        with tempfile.NamedTemporaryFile(dir=output_dir, suffix=".glb", delete=False) as temporary:
            staged = Path(temporary.name)
            with generated.open("rb") as incoming:
                shutil.copyfileobj(incoming, temporary)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(staged, output)
    write_json(manifest_path, manifest)
    return output, manifest
