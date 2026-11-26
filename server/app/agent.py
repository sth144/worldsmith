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

def mentions_asset(words: str, key: str) -> bool:
    return bool(re.search(r"\b" + re.escape(key.lower()) + r"s?\b", words))


def matching_assets(prompt: str, catalog: list[dict]) -> list[dict]:
    words = prompt.lower()
    return [item for item in catalog if mentions_asset(words, item["name"].lower())
            or mentions_asset(words, item["id"].replace("-", " ").replace("_", " "))]


def is_creation_request(prompt: str) -> bool:
    return bool(re.search(r"\b(add|put|place|plant|build|create|spawn)\b", prompt.lower()))


def is_placement_request(prompt: str, catalog: list[dict]) -> bool:
    words = prompt.lower()
    return bool(matching_assets(words, catalog) and is_creation_request(prompt))


def resolve_aimed_target(prompt: str, aimed_id: str | None, view: dict | None,
                         scene: dict, catalog: list[dict] | None = None) -> tuple[str | None, str]:
    """Resolve a described, visible prop before falling back to the aimed prop."""
    objects = {obj["id"]: obj for obj in scene["objects"]}
    if aimed_id is not None and aimed_id not in objects:
        raise HTTPException(422, "Aimed object no longer exists; reopen AI command")
    words = prompt.lower()
    named_assets = {item["path"] for item in matching_assets(words, catalog or [])}
    describes_existing = bool(re.search(r"\b(delete|remove|discard|hide|duplicate|copy|move|rotate|scale)\b|get rid", words))
    named_colors = ([name for name in COLORS if re.search(r"\b" + name + r"\b", words)]
                    if describes_existing else [])
    if not named_assets and not named_colors:
        return aimed_id, "aimed" if aimed_id else "none"

    def matches(obj: dict) -> bool:
        if named_assets and obj["asset"] not in named_assets:
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


def placement(asset: dict, position: list[float], name: str | None = None,
              scale: list[float] | None = None) -> dict:
    return {"type": "add_object", "object": {
        "id": str(uuid4()), "name": name or asset["name"],
        "asset": asset["path"],
        "parent_id": None, "position": position, "rotation": [0, 0, 0, 1],
        "scale": scale or [1, 1, 1], "visible": True, "locked": False, "metadata": {},
    }}


def generated_placement(asset: str, position: list[float], name: str) -> dict:
    return {"type": "add_object", "object": {
        "id": str(uuid4()), "name": name, "asset": asset, "parent_id": None,
        "position": position, "rotation": [0, 0, 0, 1], "scale": [1, 1, 1],
        "visible": True, "locked": False, "metadata": {},
    }}


def deterministic_view_plan(prompt: str, target: list[float], catalog: list[dict]) -> list[dict] | None:
    words = prompt.lower()
    if not is_creation_request(prompt) or re.search(r"\b(row|line|several|multiple)\b", words):
        return None
    matches = matching_assets(words, catalog)
    if len(matches) == 1:
        return [placement(matches[0], target)]
    return None


def _operation_schema(properties: dict) -> dict:
    return {"type": "object", "additionalProperties": False,
            "properties": properties, "required": list(properties)}


def view_schema(catalog: list[dict]) -> dict:
    return {"type": "object", "additionalProperties": False, "required": ["placements"],
            "properties": {"placements": {"type": "array", "items": _operation_schema({
                "asset_key": {"type": "string", "enum": [item["id"] for item in catalog]},
                "name": {"type": "string"},
                "position": {"type": "array", "items": {"type": "number"}},
                "scale": {"type": "array", "items": {"type": "number"}},
            })}}}


CREATIVE_SCHEMA = {
    "type": "object", "additionalProperties": False, "required": ["objects"],
    "properties": {"objects": {"type": "array", "items": _operation_schema({
        "name": {"type": "string"},
        "offset": {"type": "array", "items": {"type": "number"}},
        "parts": {"type": "array", "items": _operation_schema({
            "name": {"type": "string"},
            "shape": {"type": "string", "enum": ["box", "ellipsoid", "cylinder", "cone"]},
            "center": {"type": "array", "items": {"type": "number"}},
            "size": {"type": "array", "items": {"type": "number"}},
            "yaw": {"type": "number"},
            "color": {"type": "array", "items": {"type": "number"}},
        })},
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
    return await _object_plan(prompt, selected, scene, "codex")


async def claude_plan(prompt: str, selected: list[dict], scene: dict) -> list[dict]:
    return await _object_plan(prompt, selected, scene, "claude")


async def _object_plan(prompt: str, selected: list[dict], scene: dict, provider: str) -> list[dict]:
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
    result = await _agent_json(provider, guidance, SCHEMA)
    if "operations" not in result:
        raise HTTPException(502, f"{provider.title()} returned invalid operations")
    return result["operations"]


async def codex_view_plan(prompt: str, view: dict, scene: dict, catalog: list[dict]) -> list[dict]:
    return await _view_plan(prompt, view, scene, catalog, "codex")


async def claude_view_plan(prompt: str, view: dict, scene: dict, catalog: list[dict]) -> list[dict]:
    return await _view_plan(prompt, view, scene, catalog, "claude")


async def _view_plan(prompt: str, view: dict, scene: dict, catalog: list[dict], provider: str) -> list[dict]:
    guidance = (
        "Plan placements in a 3D scene. Return JSON with only a placements array. "
        "Use only the catalog asset keys. Coordinates are meters and Y up. "
        "The target is where the user is looking on the floor. Place requested objects near it; "
        "Do not alter existing objects or the base environment. If available assets cannot "
        "express the request, return an empty array. Use scale [1,1,1] by default. "
        "Never write files or execute code.\n" + json.dumps({
            "request": prompt, "view": view, "catalog": catalog,
            "nearby_objects": [obj for obj in scene["objects"] if math.dist(
                obj["position"], view["target_position"]) < 10],
        }, separators=(",", ":"))
    )
    result = await _agent_json(provider, guidance, view_schema(catalog))
    proposals = result.get("placements")
    if not isinstance(proposals, list):
        raise HTTPException(502, f"{provider.title()} returned invalid placements")
    try:
        by_id = {asset["id"]: asset for asset in catalog}
        return [placement(by_id[item["asset_key"]], item["position"], item["name"], item["scale"])
                for item in proposals]
    except (KeyError, TypeError) as exc:
        raise HTTPException(502, f"{provider.title()} returned invalid placements") from exc


async def creative_view_plan(prompt: str, view: dict, scene: dict, provider: str) -> list[dict]:
    guidance = (
        "You design simple, recognizable low-poly 3D props for a VR world. Return JSON with an objects array. "
        "Each object has a short name, an offset [x,y,z] in meters from the viewed target, and parts. "
        "Each part has a name, shape (box, ellipsoid, cylinder, cone), center [x,y,z] relative to its "
        "object's floor origin, size [width,height,depth] in meters, yaw in degrees around Y, and RGB "
        "color [0..1]. Y is up, -Z points forward. Build a clear silhouette with several parts, sensible "
        "materials/colors, and a stable base touching y=0. Use no more than three objects and 32 parts "
        "per object. You may invent forms beyond the existing catalog. If the request cannot be "
        "represented as new 3D props, return an empty objects array. Do not write code or files.\n"
        + json.dumps({"request": prompt, "view": view,
                      "nearby_objects": [obj for obj in scene["objects"] if math.dist(
                          obj["position"], view["target_position"]) < 10]}, separators=(",", ":"))
    )
    result = await _agent_json(provider, guidance, CREATIVE_SCHEMA)
    if not isinstance(result.get("objects"), list):
        raise HTTPException(502, f"{provider.title()} returned invalid geometry")
    return result["objects"]


async def _agent_json(provider: str, guidance: str, schema: dict) -> dict:
    if provider == "claude":
        return await _claude_json(guidance, schema)
    return await _codex_json(guidance, schema)


async def _claude_json(guidance: str, schema: dict) -> dict:
    if shutil.which("claude") is None:
        raise HTTPException(503, "Claude Code CLI is unavailable on the scene server")
    # Claude has no scene files to inspect. Disable all built-in and MCP tools;
    # only its structured proposal is used by the shared scene validator.
    with tempfile.TemporaryDirectory(prefix="worldsmith-agent-") as directory:
        process = await asyncio.create_subprocess_exec(
            "claude", "--safe-mode", "--print", "--output-format", "json",
            "--json-schema", json.dumps(schema), "--tools", "",
            "--disallowedTools", "mcp__*", "--no-session-persistence",
            cwd=directory, stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )
        try:
            stdout, stderr = await asyncio.wait_for(process.communicate(guidance.encode()), timeout=90)
        except TimeoutError as exc:
            process.kill()
            await process.communicate()
            raise HTTPException(504, "AI command timed out") from exc
        if process.returncode != 0:
            raise HTTPException(502, "Claude could not plan this edit: " + stderr.decode(errors="replace")[-300:])
        try:
            envelope = json.loads(stdout)
            if envelope.get("is_error"):
                raise HTTPException(502, "Claude could not plan this edit: " + str(envelope.get("result", "unknown error"))[-300:])
            result = envelope["structured_output"]
            if not isinstance(result, dict):
                raise TypeError("Expected a JSON object")
            return result
        except (ValueError, TypeError, KeyError) as exc:
            raise HTTPException(502, "Claude returned invalid structured output") from exc


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
            raise HTTPException(504, "AI command timed out") from exc
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
                      target: list[float] | None = None, generated_assets: set[str] | None = None) -> None:
    if not isinstance(operations, list) or not 1 <= len(operations) <= 16:
        raise HTTPException(422, "Command produced no supported edit")
    editable = set(selected_ids)
    working = {obj["id"]: obj.copy() for obj in scene["objects"]}
    try:
        for operation in operations:
            if isinstance(operation, dict) and operation.get("type") == "add_object" and target is not None:
                obj = operation.get("object", {})
                if not isinstance(obj, dict):
                    raise SceneError("Placement object is invalid")
                if obj.get("asset") not in (assets | (generated_assets or set())):
                    raise SceneError("Agent may place catalog or validated generated assets only")
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
