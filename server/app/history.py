"""Atomic JSON writes and persistent undo timeline."""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
from typing import Any


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, sort_keys=True, allow_nan=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        if hasattr(os, "O_DIRECTORY"):
            directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def history_status(history: dict) -> dict[str, int]:
    return {"cursor": history["cursor"], "length": len(history["entries"])}


def replay(history: dict) -> list[dict]:
    objects = {obj["id"]: obj.copy() for obj in history["base_objects"]}
    for entry in history["entries"][: history["cursor"]]:
        for object_id, state in entry["after"].items():
            if state is None:
                objects.pop(object_id, None)
            else:
                objects[object_id] = state
    return list(objects.values())
