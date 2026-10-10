"""Project-local GLB catalog with path-safe lookup."""

from __future__ import annotations

import re
from pathlib import Path

from fastapi import HTTPException

ASSET_NAME = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}\.glb\Z")
SCENE_NAME = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}\Z")


def valid_scene_id(scene_id: str) -> str:
    if not SCENE_NAME.fullmatch(scene_id):
        raise HTTPException(400, "Invalid scene ID")
    return scene_id


def list_assets(project: Path) -> list[dict[str, str]]:
    directory = project / "assets"
    if not directory.exists():
        return []
    return [
        {"id": path.name[:-4], "path": f"assets/{path.name}", "name": path.stem.title()}
        for path in sorted(directory.iterdir())
        if path.is_file() and ASSET_NAME.fullmatch(path.name)
    ]


def asset_path(project: Path, asset_id: str) -> Path:
    name = f"{asset_id}.glb"
    if not ASSET_NAME.fullmatch(name):
        raise HTTPException(400, "Invalid asset ID")
    path = project / "assets" / name
    if not path.is_file():
        raise HTTPException(404, "Asset not found")
    return path
