"""Suggest, read, and save collision roles and a spawn point for a scene environment.

An imported GLB has no collision data. This module measures each mesh from the
GLB's own bounds, suggests which meshes are walkable ground or solid obstacles,
and stores the roles a person confirms in the scene's presentation settings.
"""

from __future__ import annotations

import json
import math
import re
from pathlib import Path

from fastapi import HTTPException

from .assets import glb_document
from .export import _presentation_settings
from .history import write_json

Matrix = list[float]  # 4x4, column-major, as in glTF
IDENTITY: Matrix = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
ROLES = ("walkable", "solid", "none")
MAX_MESHES = 1024
GROUND_FOOTPRINT_SHARE = 0.2
GROUND_HEIGHT_BAND = 0.25
OBSTACLE_MIN_HEIGHT = 0.3
SPAWN_DROP = 0.5
SPAWN_CLEARANCE = 0.6


def _multiply(left: Matrix, right: Matrix) -> Matrix:
    return [sum(left[k * 4 + row] * right[column * 4 + k] for k in range(4))
            for column in range(4) for row in range(4)]


def _local_matrix(node: dict) -> Matrix:
    if "matrix" in node:
        return [float(value) for value in node["matrix"]]
    tx, ty, tz = node.get("translation", (0, 0, 0))
    x, y, z, w = node.get("rotation", (0, 0, 0, 1))
    sx, sy, sz = node.get("scale", (1, 1, 1))
    return [
        (1 - 2 * (y * y + z * z)) * sx, (2 * (x * y + z * w)) * sx, (2 * (x * z - y * w)) * sx, 0,
        (2 * (x * y - z * w)) * sy, (1 - 2 * (x * x + z * z)) * sy, (2 * (y * z + x * w)) * sy, 0,
        (2 * (x * z + y * w)) * sz, (2 * (y * z - x * w)) * sz, (1 - 2 * (x * x + y * y)) * sz, 0,
        tx, ty, tz, 1,
    ]


def _transform_bounds(matrix: Matrix, low: list[float], high: list[float]) -> tuple[list[float], list[float]]:
    corners = [[(low, high)[(index >> axis) & 1][axis] for axis in range(3)] for index in range(8)]
    moved = [[sum(matrix[axis_in * 4 + axis] * corner[axis_in] for axis_in in range(3)) + matrix[12 + axis]
              for axis in range(3)] for corner in corners]
    return ([min(point[axis] for point in moved) for axis in range(3)],
            [max(point[axis] for point in moved) for axis in range(3)])


def _mesh_local_bounds(document: dict, mesh_index: int) -> tuple[list[float], list[float]] | None:
    """Union of the POSITION accessor bounds of a mesh's primitives."""
    low, high = [math.inf] * 3, [-math.inf] * 3
    for primitive in document["meshes"][mesh_index].get("primitives", []):
        accessor_index = primitive.get("attributes", {}).get("POSITION")
        if accessor_index is None:
            continue
        accessor = document["accessors"][accessor_index]
        if "min" not in accessor or "max" not in accessor:
            continue
        low = [min(a, b) for a, b in zip(low, accessor["min"])]
        high = [max(a, b) for a, b in zip(high, accessor["max"])]
    return (low, high) if math.isfinite(low[0]) else None


def runtime_name(name: str) -> str:
    """The node name the client sees: the engine replaces these characters on import."""
    return re.sub(r'[.:@/"%]', "_", name)


def mesh_bounds(document: dict) -> list[dict]:
    """World-space bounds of every named mesh node in the default scene."""
    nodes = document.get("nodes", [])
    scenes = document.get("scenes", [])
    roots = scenes[document.get("scene", 0)].get("nodes", []) if scenes else list(range(len(nodes)))
    found: list[dict] = []
    pending = [(index, IDENTITY) for index in roots]
    while pending and len(found) < MAX_MESHES:
        index, parent = pending.pop()
        node = nodes[index]
        world = _multiply(parent, _local_matrix(node))
        pending.extend((child, world) for child in node.get("children", []))
        if "mesh" not in node:
            continue
        name = node.get("name") or document["meshes"][node["mesh"]].get("name")
        bounds = _mesh_local_bounds(document, node["mesh"])
        if not name or bounds is None:
            continue
        low, high = _transform_bounds(world, *bounds)
        found.append({"name": runtime_name(str(name)), "min": low, "max": high})
    return found


def _footprint(mesh: dict) -> float:
    return (mesh["max"][0] - mesh["min"][0]) * (mesh["max"][2] - mesh["min"][2])


def _height(mesh: dict) -> float:
    return mesh["max"][1] - mesh["min"][1]


def _is_ground(mesh: dict, scene_low: float, scene_height: float, scene_footprint: float) -> bool:
    """Ground is broad, low in the scene, and wider than it is tall."""
    width = max(mesh["max"][0] - mesh["min"][0], mesh["max"][2] - mesh["min"][2])
    return (_footprint(mesh) >= GROUND_FOOTPRINT_SHARE * scene_footprint
            and mesh["min"][1] <= scene_low + GROUND_HEIGHT_BAND * scene_height
            and _height(mesh) <= 0.5 * width)


def suggest_roles(meshes: list[dict]) -> dict[str, str]:
    """Suggest a role per mesh. A person reviews this; it is a starting point only."""
    if not meshes:
        return {}
    scene_low = min(mesh["min"][1] for mesh in meshes)
    scene_height = max(mesh["max"][1] for mesh in meshes) - scene_low
    scene_footprint = ((max(mesh["max"][0] for mesh in meshes) - min(mesh["min"][0] for mesh in meshes))
                       * (max(mesh["max"][2] for mesh in meshes) - min(mesh["min"][2] for mesh in meshes)))
    ground = {mesh["name"] for mesh in meshes if _is_ground(mesh, scene_low, scene_height, scene_footprint)}
    if not ground:
        ground = {max(meshes, key=_footprint)["name"]}
    ground_top = max(mesh["max"][1] for mesh in meshes if mesh["name"] in ground)
    roles = {}
    for mesh in meshes:
        # A thin mesh lying on the ground is a decal; a thin mesh above it still blocks.
        flat_on_ground = _height(mesh) < OBSTACLE_MIN_HEIGHT and mesh["max"][1] <= ground_top + OBSTACLE_MIN_HEIGHT
        if mesh["name"] in ground:
            roles[mesh["name"]] = "walkable"
        else:
            roles[mesh["name"]] = "none" if flat_on_ground else "solid"
    return roles


def _blocked(x: float, z: float, obstacles: list[dict]) -> bool:
    return any(mesh["min"][0] - SPAWN_CLEARANCE <= x <= mesh["max"][0] + SPAWN_CLEARANCE
               and mesh["min"][2] - SPAWN_CLEARANCE <= z <= mesh["max"][2] + SPAWN_CLEARANCE
               for mesh in obstacles)


def suggest_spawn(meshes: list[dict], roles: dict[str, str]) -> list[float]:
    """A point just above the largest walkable mesh, away from solid meshes where possible."""
    walkable = [mesh for mesh in meshes if roles.get(mesh["name"]) == "walkable"]
    if not walkable:
        return [0.0, 1.8, 0.0]
    ground = max(walkable, key=_footprint)
    obstacles = [mesh for mesh in meshes if roles.get(mesh["name"]) == "solid"]
    height = ground["max"][1] + SPAWN_DROP
    steps = [0.5, 0.25, 0.75, 0.125, 0.875]
    for x_step in steps:
        for z_step in steps:
            x = ground["min"][0] + (ground["max"][0] - ground["min"][0]) * x_step
            z = ground["min"][2] + (ground["max"][2] - ground["min"][2]) * z_step
            if not _blocked(x, z, obstacles):
                return [round(x, 3), round(height, 3), round(z, 3)]
    return [round((ground["min"][0] + ground["max"][0]) / 2, 3), round(height, 3),
            round((ground["min"][2] + ground["max"][2]) / 2, 3)]


def _matches(name: str, words: list[str]) -> bool:
    """Same rule as the client: a mesh takes a role when its name contains a listed name."""
    return any(word and word.lower() in name.lower() for word in words)


def _saved_role(name: str, collision: dict) -> str:
    if _matches(name, collision.get("walkable", [])):
        return "walkable"
    return "solid" if _matches(name, collision.get("solid", [])) else "none"


def _manifest(project: Path) -> dict:
    path = project / "environment.json"
    if not path.is_file():
        raise HTTPException(404, "Scene has no environment")
    return json.loads(path.read_text())


def has_walkable(project: Path) -> bool:
    """Whether the scene's environment has at least one walkable collision name."""
    path = project / "environment.json"
    if not path.is_file():
        return False
    presentation = json.loads(path.read_text()).get("presentation", {})
    return bool(presentation.get("collision", {}).get("walkable"))


def collision_review(project: Path) -> dict:
    """Every mesh with its size, suggested role, and current role, plus the spawn point."""
    manifest = _manifest(project)
    meshes = mesh_bounds(glb_document(project / manifest["asset"]))
    suggested = suggest_roles(meshes)
    presentation = manifest.get("presentation", {})
    collision = presentation.get("collision")
    rows = []
    for mesh in sorted(meshes, key=_footprint, reverse=True):
        name = mesh["name"]
        rows.append({
            "name": name,
            "size": [round(mesh["max"][axis] - mesh["min"][axis], 3) for axis in range(3)],
            "suggested": suggested[name],
            "role": _saved_role(name, collision) if collision else suggested[name],
        })
    suggested_spawn = suggest_spawn(meshes, suggested)
    return {"reviewed": bool(collision), "meshes": rows,
            "spawn": presentation.get("spawn", suggested_spawn), "suggested_spawn": suggested_spawn}


def save_collision(project: Path, walkable: list[str], solid: list[str], spawn: list[float]) -> dict:
    """Store reviewed roles and spawn, keeping the scene's other presentation settings."""
    manifest = _manifest(project)
    known = {mesh["name"] for mesh in mesh_bounds(glb_document(project / manifest["asset"]))}
    unknown = sorted((set(walkable) | set(solid)) - known)
    if unknown:
        raise HTTPException(422, "Unknown mesh: " + unknown[0])
    if not walkable:
        raise HTTPException(422, "Choose at least one walkable mesh")
    if set(walkable) & set(solid):
        raise HTTPException(422, "A mesh cannot be both walkable and solid")
    presentation = dict(manifest.get("presentation", {}))
    presentation["collision"] = {"walkable": sorted(walkable), "solid": sorted(solid)}
    presentation["spawn"] = spawn
    try:
        manifest["presentation"] = _presentation_settings(presentation)
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from exc
    write_json(project / "environment.json", manifest)
    return collision_review(project)
