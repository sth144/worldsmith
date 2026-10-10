"""Build a portable GLB from the server snapshot and registered environment."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from fastapi import HTTPException

from .history import write_json
from .assets import validate_glb

REPO = Path(__file__).resolve().parents[2]


def register_environment(project: Path, source: Path) -> dict:
    if not source.is_file() or source.suffix.lower() != ".glb" or source.stat().st_size < 20:
        raise ValueError("Environment must be an existing GLB")
    validate_glb(source)
    manifest = {"asset": "assets/environment.glb", "source": source.name, "instances": []}
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
