"""Project-local GLB catalog with path-safe lookup."""

from __future__ import annotations

import re
import json
import struct
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


def validate_glb(path: Path) -> None:
    """Check the GLB container and require at least one mesh before registration."""
    size = path.stat().st_size
    with path.open("rb") as source:
        header = source.read(20)
        if len(header) != 20:
            raise ValueError("GLB header is incomplete")
        magic, version, declared, chunk_size, chunk_type = struct.unpack("<4sIIII", header)
        if magic != b"glTF" or version != 2 or declared != size or chunk_type != 0x4E4F534A or chunk_size > size - 20:
            raise ValueError("Invalid GLB container")
        try:
            document = json.loads(source.read(chunk_size))
        except (ValueError, UnicodeDecodeError) as exc:
            raise ValueError("Invalid GLB JSON") from exc
    if not document.get("meshes"):
        raise ValueError("GLB has no meshes")
