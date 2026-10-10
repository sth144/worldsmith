"""Canonical scene schema and deterministic object operations."""

from __future__ import annotations

import math
from copy import deepcopy
from typing import Any
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


class SceneError(ValueError):
    pass


def vector(value: Any, length: int, *, positive: bool = False) -> list[float]:
    if not isinstance(value, list) or len(value) != length:
        raise SceneError(f"Expected an array of {length} numbers")
    try:
        result = [float(item) for item in value]
    except (TypeError, ValueError) as exc:
        raise SceneError("Vector contains a non-number") from exc
    if any(not math.isfinite(item) for item in result):
        raise SceneError("Vector contains a non-finite number")
    if positive and any(item <= 0 or item > 100 for item in result):
        raise SceneError("Scale components must be greater than 0 and at most 100")
    return result


def quaternion(value: Any) -> list[float]:
    result = vector(value, 4)
    length = math.sqrt(sum(item * item for item in result))
    if length < 1e-8:
        raise SceneError("Rotation quaternion cannot be zero")
    return [item / length for item in result]


def valid_uuid(value: Any) -> str:
    try:
        parsed = UUID(str(value))
    except (ValueError, TypeError, AttributeError) as exc:
        raise SceneError("Object ID must be a UUID") from exc
    return str(parsed)


class SceneObject(BaseModel):
    model_config = ConfigDict(extra="forbid")
    id: str
    name: str = Field(min_length=1, max_length=128)
    asset: str
    parent_id: str | None = None
    position: list[float] = Field(default_factory=lambda: [0.0, 0.0, 0.0])
    rotation: list[float] = Field(default_factory=lambda: [0.0, 0.0, 0.0, 1.0])
    scale: list[float] = Field(default_factory=lambda: [1.0, 1.0, 1.0])
    visible: bool = True
    locked: bool = False
    metadata: dict[str, Any] = Field(default_factory=dict)

    @field_validator("id", "parent_id")
    @classmethod
    def check_uuid(cls, value: str | None) -> str | None:
        return valid_uuid(value) if value is not None else None

    @field_validator("position")
    @classmethod
    def check_position(cls, value: list[float]) -> list[float]:
        return vector(value, 3)

    @field_validator("rotation")
    @classmethod
    def check_rotation(cls, value: list[float]) -> list[float]:
        return quaternion(value)

    @field_validator("scale")
    @classmethod
    def check_scale(cls, value: list[float]) -> list[float]:
        return vector(value, 3, positive=True)

    @field_validator("asset")
    @classmethod
    def check_asset(cls, value: str) -> str:
        if not value.startswith("assets/") or not value.endswith(".glb") or "/" in value[7:] or ".." in value:
            raise ValueError("Asset must be assets/<name>.glb")
        return value


class SceneDocument(BaseModel):
    model_config = ConfigDict(extra="forbid")
    schema_version: int = 1
    scene_id: str
    revision: int = Field(ge=0)
    objects: list[SceneObject] = Field(default_factory=list)

    @model_validator(mode="after")
    def check_graph(self) -> SceneDocument:
        ids = {obj.id for obj in self.objects}
        if len(ids) != len(self.objects):
            raise ValueError("Duplicate object IDs")
        parents = {obj.id: obj.parent_id for obj in self.objects}
        for obj in self.objects:
            seen = {obj.id}
            parent = obj.parent_id
            while parent is not None:
                if parent not in ids or parent in seen:
                    raise ValueError("Invalid parent graph")
                seen.add(parent)
                parent = parents[parent]
        if self.schema_version != 1:
            raise ValueError("Unsupported scene schema")
        return self


def apply_operation(objects: dict[str, dict], operation: dict, assets: set[str], material_names: dict[str, set[str]] | None = None) -> set[str]:
    """Mutate a working copy and return changed IDs. Caller commits only after all validate."""
    if not isinstance(operation, dict):
        raise SceneError("Operation must be an object")
    kind = operation.get("type")
    allowed = {
        "add_object": {"type", "object"},
        "delete_object": {"type", "object_id"},
        "set_transform": {"type", "object_id", "position", "rotation", "scale"},
        "set_visibility": {"type", "object_id", "visible"},
        "set_material": {"type", "object_id", "color", "material_name"},
        "replace_asset": {"type", "object_id", "asset"},
        "duplicate_object": {"type", "object_id", "new_id"},
    }
    if kind not in allowed:
        raise SceneError("Unsupported operation type")
    if operation.keys() - allowed[kind]:
        raise SceneError("Unexpected operation fields")
    if kind == "add_object" and not isinstance(operation.get("object"), dict):
        raise SceneError("add_object needs an object")
    object_id = valid_uuid(operation.get("object_id")) if kind != "add_object" else valid_uuid(operation.get("object", {}).get("id"))
    current = objects.get(object_id)

    if kind == "add_object":
        if current is not None:
            raise SceneError("Object ID already exists")
        obj = SceneObject.model_validate(operation.get("object", {})).model_dump()
        if obj["asset"] not in assets:
            raise SceneError("Unknown asset")
        if obj["parent_id"] is not None and obj["parent_id"] not in objects:
            raise SceneError("Unknown parent")
        objects[object_id] = obj
    elif kind == "duplicate_object":
        if current is None:
            raise SceneError("Object does not exist")
        if current["locked"]:
            raise SceneError("Object is locked")
        new_id = valid_uuid(operation.get("new_id"))
        if new_id in objects:
            raise SceneError("Duplicate ID already exists")
        copied = deepcopy(current)
        copied["id"] = new_id
        copied["name"] = copied["name"] + " copy"
        copied["position"] = [copied["position"][0] + 0.55, copied["position"][1], copied["position"][2] + 0.55]
        objects[new_id] = copied
        return {new_id}
    elif current is None:
        raise SceneError("Object does not exist")
    elif current["locked"]:
        raise SceneError("Object is locked")
    elif kind == "delete_object":
        if any(obj["parent_id"] == object_id for obj in objects.values()):
            raise SceneError("Delete child objects before their parent")
        del objects[object_id]
    elif kind == "set_transform":
        fields = {key for key in ("position", "rotation", "scale") if key in operation}
        if not fields:
            raise SceneError("set_transform needs position, rotation, or scale")
        for key in fields:
            current[key] = quaternion(operation[key]) if key == "rotation" else vector(operation[key], 3, positive=key == "scale")
    elif kind == "set_visibility":
        if type(operation.get("visible")) is not bool:
            raise SceneError("visible must be a boolean")
        current["visible"] = operation["visible"]
    elif kind == "set_material":
        color = vector(operation.get("color"), 4)
        if any(component < 0 or component > 1 for component in color):
            raise SceneError("Material color must be within 0–1")
        material_name = operation.get("material_name")
        if material_name is None:
            current["metadata"]["material_color"] = color
            current["metadata"].pop("material_overrides", None)
        else:
            if not isinstance(material_name, str) or not 1 <= len(material_name) <= 128:
                raise SceneError("material_name must be a nonempty name")
            if material_names is not None and material_name not in material_names.get(current["asset"], set()):
                raise SceneError("Asset has no material named " + material_name)
            # A targeted repaint supersedes a previous whole-object tint.
            current["metadata"].pop("material_color", None)
            overrides = current["metadata"].setdefault("material_overrides", {})
            if not isinstance(overrides, dict):
                raise SceneError("Invalid material_overrides metadata")
            overrides[material_name] = color
    elif kind == "replace_asset":
        asset = operation.get("asset")
        if asset not in assets:
            raise SceneError("Unknown asset")
        current["asset"] = asset
    return {object_id}
