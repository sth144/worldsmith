"""Constrained natural-language planner. The scene store remains the sole writer."""

from __future__ import annotations

import asyncio
import json
import math
import re
import shutil
import tempfile
from pathlib import Path
from uuid import uuid4

from fastapi import HTTPException

from .scene import SceneError, apply_operation


COLORS = {
    "red": [0.85, 0.08, 0.06, 1], "green": [0.08, 0.7, 0.14, 1],
    "blue": [0.08, 0.22, 0.9, 1], "yellow": [0.95, 0.78, 0.06, 1],
    "white": [1, 1, 1, 1], "black": [0.025, 0.025, 0.025, 1],
}

PLACEABLE = {"chair": "Chair", "table": "Table", "planter": "Planter", "lantern": "Lantern",
             "hill": "Hill", "tree": "Tree"}


def is_placement_request(prompt: str) -> bool:
    words = prompt.lower()
    named_asset = any(re.search(r"\b" + key + r"s?\b", words) for key in PLACEABLE)
    return bool(named_asset and (re.search(r"\b(add|put|place|plant|build|create|spawn)\b", words)
                                 or "hill" in words and "tree" in words))


def resolve_aimed_target(prompt: str, aimed_id: str | None, view: dict | None,
                         scene: dict) -> tuple[str | None, str]:
    """Resolve a described, visible prop before falling back to the aimed prop."""
    objects = {obj["id"]: obj for obj in scene["objects"]}
    if aimed_id is not None and aimed_id not in objects:
        raise HTTPException(422, "Aimed object no longer exists; reopen Ask AI")
    words = prompt.lower()
    named_assets = [key for key in PLACEABLE if re.search(r"\b" + key + r"s?\b", words)]
    describes_existing = bool(re.search(r"\b(delete|remove|discard|hide|duplicate|copy|move|rotate|scale)\b|get rid", words))
    named_colors = ([name for name in COLORS if re.search(r"\b" + name + r"\b", words)]
                    if describes_existing else [])
    if not named_assets and not named_colors:
        return aimed_id, "aimed" if aimed_id else "none"

    def matches(obj: dict) -> bool:
        if named_assets and obj["asset"].removeprefix("assets/").removesuffix(".glb").split("-v-")[0] not in named_assets:
            return False
        if not named_colors:
            return True
        metadata = obj.get("metadata", {})
        colors = [metadata.get("material_color")]
        overrides = metadata.get("material_overrides", {})
        if isinstance(overrides, dict):
            colors += list(overrides.values())
        for color in colors:
            if not isinstance(color, list) or len(color) < 3:
                continue
            try:
                if any(sum((float(color[i]) - COLORS[name][i]) ** 2 for i in range(3)) < 0.08
                       for name in named_colors):
                    return True
            except (TypeError, ValueError):
                continue
        return False

    candidates = [obj for obj in objects.values() if matches(obj)]
    if view is not None:
        camera, direction = view["camera_position"], view["camera_direction"]
        candidates = [obj for obj in candidates if _in_view(obj, camera, direction)]
    else:
        candidates = [obj for obj in candidates if obj["id"] == aimed_id]
    if aimed_id is not None and any(obj["id"] == aimed_id for obj in candidates):
        return aimed_id, "aimed"
    if len(candidates) == 1:
        return candidates[0]["id"], "described in view"
    if len(candidates) > 1:
        raise HTTPException(422, "Several objects match; aim at the one you mean")
    if named_colors or named_assets:
        raise HTTPException(422, "No aimed or visible placed object matches that description")
    return aimed_id, "aimed" if aimed_id else "none"


def _in_view(obj: dict, camera: list[float], direction: list[float]) -> bool:
    center = [obj["position"][0], obj["position"][1] + 0.6, obj["position"][2]]
    offset = [a - b for a, b in zip(center, camera)]
    distance = math.sqrt(sum(item * item for item in offset))
    return 0.1 < distance <= 30 and sum(a * b for a, b in zip(offset, direction)) / distance > 0.3


def placement(asset_key: str, position: list[float], name: str | None = None,
              scale: list[float] | None = None) -> dict:
    return {"type": "add_object", "object": {
        "id": str(uuid4()), "name": name or PLACEABLE[asset_key], "asset": f"assets/{asset_key}.glb",
        "parent_id": None, "position": position, "rotation": [0, 0, 0, 1],
        "scale": scale or [1, 1, 1], "visible": True, "locked": False, "metadata": {},
    }}


def deterministic_view_plan(prompt: str, target: list[float]) -> list[dict] | None:
    words = prompt.lower()
    if re.search(r"\bhill\b", words) and re.search(r"\btree\b", words):
        return [placement("hill", target), placement("tree", [target[0], target[1] + 1.12, target[2]])]
    if not re.search(r"\b(add|put|place|plant|create)\b", words):
        return None
    for key in PLACEABLE:
        if re.search(r"\b" + key + r"s?\b", words):
            return [placement(key, target)]
    return None


def _operation_schema(properties: dict) -> dict:
    return {"type": "object", "additionalProperties": False,
            "properties": properties, "required": list(properties)}


VIEW_SCHEMA = {
    "type": "object", "additionalProperties": False, "required": ["placements"],
    "properties": {"placements": {"type": "array", "items": _operation_schema({
        "asset_key": {"type": "string", "enum": list(PLACEABLE)}, "name": {"type": "string"},
        "position": {"type": "array", "items": {"type": "number"}},
        "scale": {"type": "array", "items": {"type": "number"}},
    })}},
}


_string = {"type": "string"}
_numbers = {"type": "array", "items": {"type": "number"}}
SCHEMA = {
    "type": "object", "additionalProperties": False, "required": ["operations"],
    "properties": {"operations": {"type": "array", "items": {"anyOf": [
        _operation_schema({"type": {"type": "string", "enum": ["set_transform"]},
                           "object_id": _string, "position": _numbers, "rotation": _numbers, "scale": _numbers}),
        _operation_schema({"type": {"type": "string", "enum": ["set_visibility"]},
                           "object_id": _string, "visible": {"type": "boolean"}}),
        _operation_schema({"type": {"type": "string", "enum": ["set_material"]},
                           "object_id": _string, "color": _numbers,
                           "material_name": {"type": ["string", "null"]}}),
        _operation_schema({"type": {"type": "string", "enum": ["duplicate_object"]},
                           "object_id": _string, "new_id": _string}),
        _operation_schema({"type": {"type": "string", "enum": ["delete_object"]},
                           "object_id": _string}),
    ]}}},
}


def deterministic_plan(prompt: str, selected: list[dict]) -> list[dict] | None:
    """Handle common direct requests locally, without a cloud round trip."""
    words = prompt.lower()
    if not selected:
        return None
    if re.search(r"\b(delete|remove|discard)\b|get rid of", words):
        return [{"type": "delete_object", "object_id": obj["id"]} for obj in selected]
    if ("duplicate" in words or "copy" in words) and not any(phrase in words for phrase in ("along", "row", "line", "across")):
        return [{"type": "duplicate_object", "object_id": obj["id"], "new_id": str(uuid4())} for obj in selected]
    if "hide" in words or "show" in words:
        return [{"type": "set_visibility", "object_id": obj["id"], "visible": "show" in words} for obj in selected]
    for name, color in COLORS.items():
        if re.search(r"\b" + name + r"\b", words) and any(verb in words for verb in ("color", "colour", "make", "paint", "turn", "change")):
            operations = []
            targeted = any(part in words for part in ("upholstery", "fabric", "cushion"))
            for obj in selected:
                operation = {"type": "set_material", "object_id": obj["id"], "color": color}
                if targeted:
                    material = next((material for material in obj.get("available_materials", [])
                                     if any(part in material.lower() for part in ("fabric", "upholstery", "cushion"))), None)
                    if material is None:
                        return None
                    operation["material_name"] = material
                operations.append(operation)
            return operations
    factor = None
    if "twice" in words or "double" in words:
        factor = 2.0
    elif "half" in words or "halve" in words:
        factor = 0.5
    else:
        match = re.search(r"(?:scale|grow|shrink|make).*?\b(\d+(?:\.\d+)?)\s*(?:times|x)\b", words)
        if match:
            factor = float(match.group(1))
    if factor is not None and 0 < factor <= 10:
        axes = [0, 1, 2]
        if "wide" in words or "width" in words:
            axes = [0]
        elif "tall" in words or "height" in words:
            axes = [1]
        elif "deep" in words or "depth" in words:
            axes = [2]
        return [{"type": "set_transform", "object_id": obj["id"],
                 "scale": [value * factor if index in axes else value for index, value in enumerate(obj["scale"])]}
                for obj in selected]
    return None


async def codex_plan(prompt: str, selected: list[dict], scene: dict) -> list[dict]:
    guidance = (
        "You are a scene operation planner. Return JSON with only an operations array. "
        "Allowed types: set_transform (object_id plus all position/rotation/scale arrays), "
        "set_visibility (object_id, visible), set_material (object_id, color RGBA 0..1, "
        "material_name exact asset material name or null for the whole object), "
        "duplicate_object (object_id, new_id UUID), delete_object (object_id). "
        "Use selected object IDs, or IDs created by preceding duplicate_object operations. "
        "Preserve existing values when changing one axis. When the request names upholstery, "
        "fabric, or another part, choose the exact matching available_materials name. "
        "Coordinates are meters, Y up. Never write files or execute code. "
        "If the request cannot be expressed with these operations, return an empty array.\n"
        + json.dumps({"request": prompt, "selected": selected, "scene": scene}, separators=(",", ":"))
    )
    result = await _codex_json(guidance, SCHEMA)
    if "operations" not in result:
        raise HTTPException(502, "Codex returned invalid operations")
    return result["operations"]


async def codex_view_plan(prompt: str, view: dict, scene: dict) -> list[dict]:
    guidance = (
        "Plan placements in a 3D scene. Return JSON with only a placements array. "
        "Use only the catalog asset keys. Coordinates are meters and Y up. "
        "The target is where the user is looking on the floor. Place requested objects near it; "
        "put a tree on a hill at hill center plus 1.12 meters Y. "
        "Do not alter existing objects or the base environment. If available assets cannot "
        "express the request, return an empty array. Use scale [1,1,1] by default. "
        "Never write files or execute code.\n" + json.dumps({
            "request": prompt, "view": view, "catalog": PLACEABLE,
            "nearby_objects": [obj for obj in scene["objects"] if math.dist(
                obj["position"], view["target_position"]) < 10],
        }, separators=(",", ":"))
    )
    result = await _codex_json(guidance, VIEW_SCHEMA)
    proposals = result.get("placements")
    if not isinstance(proposals, list):
        raise HTTPException(502, "Codex returned invalid placements")
    try:
        return [placement(item["asset_key"], item["position"], item["name"], item["scale"])
                for item in proposals]
    except (KeyError, TypeError) as exc:
        raise HTTPException(502, "Codex returned invalid placements") from exc


async def _codex_json(guidance: str, schema: dict) -> dict:
    if shutil.which("codex") is None:
        raise HTTPException(503, "Codex CLI is unavailable; try a direct placement or selected-object request")
    with tempfile.TemporaryDirectory(prefix="worldsmith-agent-") as directory:
        root = Path(directory)
        schema_path, answer_path = root / "schema.json", root / "answer.json"
        schema_path.write_text(json.dumps(schema))
        process = await asyncio.create_subprocess_exec(
            "codex", "exec", "--sandbox", "read-only", "--skip-git-repo-check", "--output-schema", str(schema_path),
            "--output-last-message", str(answer_path), "-", cwd=root,
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            _, stderr = await asyncio.wait_for(process.communicate(guidance.encode()), timeout=90)
        except TimeoutError as exc:
            process.kill()
            await process.communicate()
            raise HTTPException(504, "AI request timed out") from exc
        if process.returncode != 0 or not answer_path.is_file():
            raise HTTPException(502, "Codex could not plan this edit: " + stderr.decode(errors="replace")[-300:])
        try:
            result = json.loads(answer_path.read_text())
            if not isinstance(result, dict):
                raise TypeError("Expected a JSON object")
            return result
        except (ValueError, TypeError) as exc:
            raise HTTPException(502, "Codex returned invalid operations") from exc


def validate_proposal(operations: list[dict], scene: dict, selected_ids: list[str], assets: set[str],
                      target: list[float] | None = None) -> None:
    if not isinstance(operations, list) or not 1 <= len(operations) <= 16:
        raise HTTPException(422, "AI request produced no supported edit")
    editable = set(selected_ids)
    working = {obj["id"]: obj.copy() for obj in scene["objects"]}
    try:
        for operation in operations:
            if isinstance(operation, dict) and operation.get("type") == "add_object" and target is not None:
                obj = operation.get("object", {})
                if not isinstance(obj, dict):
                    raise SceneError("Placement object is invalid")
                if obj.get("asset") not in {f"assets/{key}.glb" for key in PLACEABLE}:
                    raise SceneError("Agent may place catalog assets only")
                position = obj.get("position")
                if (not isinstance(position, list) or len(position) != 3 or
                    math.dist(position, target) > 5):
                    raise SceneError("Placement must be within five meters of the viewed point")
                apply_operation(working, operation, assets)
                editable.add(obj["id"])
                continue
            if not isinstance(operation, dict) or operation.get("type") not in {
                "set_transform", "set_visibility", "set_material", "duplicate_object", "delete_object"
            } or operation.get("object_id") not in editable:
                raise SceneError("Agent may edit selected objects only")
            apply_operation(working, operation, assets)
            if operation["type"] == "duplicate_object":
                editable.add(operation["new_id"])
    except (SceneError, ValueError, TypeError) as exc:
        raise HTTPException(422, f"AI proposal rejected: {exc}") from exc
