"""Scene-scoped requests for reviewed assets from the reusable library."""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path
from uuid import UUID, uuid4

from fastapi import HTTPException

from .assets import validate_glb
from .history import write_json

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))
from asset_library import AssetLibrary, digest  # noqa: E402


def create_asset_request(project: Path, scene_id: str, revision: int,
                         prompt: str, target: list[float]) -> dict:
    job = {
        "id": str(uuid4()), "kind": "asset_request", "status": "needs_asset",
        "scene_id": scene_id, "revision": revision, "prompt": prompt,
        "target_position": target,
        "requirements": ["editable source or reproducible generation", "Godot visual review",
                         "usable geometry and PBR materials", "collision and device budget review"],
    }
    write_json(project / "jobs" / f"{job['id']}.json", job)
    return job


def read_asset_request(project: Path, job_id: str) -> dict:
    try:
        UUID(job_id)
    except ValueError as exc:
        raise HTTPException(400, "Invalid asset request ID") from exc
    path = project / "jobs" / f"{job_id}.json"
    if not path.is_file():
        raise HTTPException(404, "Asset request not found")
    try:
        job = json.loads(path.read_text())
    except ValueError as exc:
        raise HTTPException(500, "Invalid stored asset request") from exc
    if job.get("kind") != "asset_request":
        raise HTTPException(404, "Asset request not found")
    return job


def current_mesh(library_root: Path, asset_id: str) -> dict:
    library = AssetLibrary(library_root)
    try:
        try:
            version = library.get(asset_id)
        except KeyError as exc:
            raise HTTPException(404, "No promoted library asset with this ID") from exc
    finally:
        library.database.close()
    if version["kind"] != "mesh" or Path(version["blob"]).suffix.lower() != ".glb":
        raise HTTPException(422, "Promoted library asset must be a GLB mesh")
    if version["metadata"].get("godot_review") is not True:
        raise HTTPException(422, "Library asset needs a recorded Godot visual approval")
    blob = Path(version["blob"])
    if digest(blob) != version["sha256"]:
        raise HTTPException(500, "Library asset checksum mismatch")
    try:
        validate_glb(blob)
    except ValueError as exc:
        raise HTTPException(422, "Library asset is not a valid GLB") from exc
    return version


def copy_version_to_project(project: Path, version: dict) -> tuple[str, bool]:
    """Return a stable per-version path and whether this call created it."""
    asset_id = version["asset_id"][:45].rstrip("_-")
    name = f"{asset_id}-{version['sha256'][:16]}.glb"
    target = project / "assets" / name
    if target.is_file():
        if digest(target) != version["sha256"]:
            raise HTTPException(409, "Project asset path has unexpected contents")
        return f"assets/{name}", False
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(".part")
    try:
        shutil.copyfile(version["blob"], temporary)
        if digest(temporary) != version["sha256"]:
            raise HTTPException(500, "Asset copy checksum mismatch")
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)
    return f"assets/{name}", True
