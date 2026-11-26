"""Scene-independent production briefs for prompt-created worlds."""

from __future__ import annotations

import json
from pathlib import Path

from fastapi import HTTPException
from pydantic import BaseModel, ConfigDict, Field, ValidationError

from .agent import _agent_json
from .history import write_json


class AssetNeed(BaseModel):
    model_config = ConfigDict(extra="forbid")

    key: str = Field(min_length=2, max_length=64, pattern=r"^[a-z][a-z0-9_-]*$")
    description: str = Field(min_length=10, max_length=800)
    role: str = Field(pattern=r"^(terrain|architecture|foliage|prop|effect)$")
    quantity: int = Field(ge=1, le=1000)
    placement: str = Field(min_length=3, max_length=500)
    editable: bool


class SceneBrief(BaseModel):
    model_config = ConfigDict(extra="forbid")

    concept: str = Field(min_length=10, max_length=1000)
    visual_direction: str = Field(min_length=10, max_length=1000)
    walkable_layout: str = Field(min_length=10, max_length=1600)
    ground_strategy: str = Field(min_length=10, max_length=1600)
    lighting: str = Field(min_length=10, max_length=1000)
    assets: list[AssetNeed] = Field(min_length=1, max_length=24)


def _schema() -> dict:
    string = {"type": "string"}
    return {
        "type": "object", "additionalProperties": False,
        "required": ["concept", "visual_direction", "walkable_layout", "ground_strategy", "lighting", "assets"],
        "properties": {
            "concept": string, "visual_direction": string, "walkable_layout": string,
            "ground_strategy": string, "lighting": string,
            "assets": {"type": "array", "items": {
                "type": "object", "additionalProperties": False,
                "required": ["key", "description", "role", "quantity", "placement", "editable"],
                "properties": {
                    "key": string, "description": string,
                    "role": {"type": "string", "enum": ["terrain", "architecture", "foliage", "prop", "effect"]},
                    "quantity": {"type": "integer"}, "placement": string,
                    "editable": {"type": "boolean"},
                },
            }},
        },
    }


def validate_brief(value: dict) -> dict:
    try:
        brief = SceneBrief.model_validate(value)
    except ValidationError as exc:
        raise HTTPException(502, "Scene planner returned an invalid production brief") from exc
    keys = [asset.key for asset in brief.assets]
    if len(keys) != len(set(keys)) or sum(asset.quantity for asset in brief.assets) > 5000:
        raise HTTPException(502, "Scene planner returned duplicate or excessive assets")
    if not any(asset.role == "terrain" for asset in brief.assets):
        raise HTTPException(502, "Scene planner omitted a walkable terrain asset")
    return brief.model_dump()


async def plan_scene_brief(prompt: str, provider: str) -> dict:
    guidance = (
        "Design a production brief for a walkable, editable 3D/VR scene. Return only JSON. "
        "Plan 3 to 12 reusable asset families with distinct silhouettes and practical quantities. "
        "Include terrain and describe geometry, tiled surface materials, and physical ground detail. "
        "Describe a coherent route and focal points, lighting, and visual direction. "
        "The brief is a plan, not a claim that models or a playable scene already exist. "
        "Do not write code, files, or name any external stock asset as a requirement. "
        "Use lowercase stable asset keys and Y-up meters in placement descriptions. "
        "Prompt: " + json.dumps(prompt)
    )
    return validate_brief(await _agent_json(provider, guidance, _schema()))


def read_scene_brief(project: Path) -> dict:
    path = project / "brief.json"
    if not path.is_file():
        raise HTTPException(404, "Scene has no production brief")
    try:
        document = json.loads(path.read_text())
        document["brief"] = validate_brief(document["brief"])
        return document
    except HTTPException as exc:
        raise HTTPException(500, "Stored scene brief is invalid") from exc
    except (ValueError, KeyError, TypeError) as exc:
        raise HTTPException(500, "Stored scene brief is invalid") from exc


def save_scene_brief(project: Path, scene_id: str, revision: int,
                     prompt: str, provider: str, brief: dict) -> dict:
    document = {
        "scene_id": scene_id, "source_revision": revision,
        "prompt": prompt, "provider": provider,
        "status": "needs_assets", "brief": validate_brief(brief),
    }
    write_json(project / "brief.json", document)
    return document
