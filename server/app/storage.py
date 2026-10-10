"""Single-process authoritative scene store."""

from __future__ import annotations

import json
import os
import shutil
import threading
from copy import deepcopy
from pathlib import Path
from uuid import uuid4

from fastapi import HTTPException
from pydantic import ValidationError

from .assets import list_assets, valid_scene_id
from .history import history_status, replay, write_json
from .scene import SceneDocument, SceneError, apply_operation

REPO = Path(__file__).resolve().parents[2]


class SceneStore:
    def __init__(self, root: Path, seed: Path):
        self.root = root
        self.seed = seed
        self.lock = threading.RLock()
        self.root.mkdir(parents=True, exist_ok=True)
        if not (self.root / "demo" / "scene.json").exists():
            shutil.copytree(self.seed, self.root / "demo", dirs_exist_ok=True)
        self._ensure_environment(self.root / "demo")

    @staticmethod
    def _ensure_environment(project: Path) -> None:
        manifest = project / "environment.json"
        if manifest.exists():
            return
        source = REPO / "client" / "assets" / "sample_hall.glb"
        destination = project / "assets" / "environment.glb"
        destination.parent.mkdir(parents=True, exist_ok=True)
        if not destination.exists():
            shutil.copy2(source, destination)
        write_json(manifest, {"asset": "assets/environment.glb", "source": "sample_hall.glb"})

    def project(self, scene_id: str) -> Path:
        return self.root / valid_scene_id(scene_id)

    def create(self, scene_id: str) -> dict:
        project = self.project(scene_id)
        with self.lock:
            if project.exists():
                raise HTTPException(409, "Scene already exists")
            project.mkdir(parents=True)
            (project / "assets").mkdir()
            for asset in (self.seed / "assets").glob("*.glb"):
                shutil.copy2(asset, project / "assets" / asset.name)
            scene = SceneDocument(scene_id=scene_id, revision=0).model_dump()
            write_json(project / "scene.json", scene)
            self._ensure_environment(project)
            return scene

    def _load(self, scene_id: str) -> tuple[dict, dict]:
        project = self.project(scene_id)
        path = project / "scene.json"
        if not path.is_file():
            raise HTTPException(404, "Scene not found")
        try:
            scene = SceneDocument.model_validate_json(path.read_text()).model_dump()
            if scene["scene_id"] != scene_id:
                raise ValueError("Scene ID does not match directory")
            history_path = project / "history.json"
            if history_path.is_file():
                history = json.loads(history_path.read_text())
            else:
                history = {"scene_id": scene_id, "revision": scene["revision"], "cursor": 0, "base_objects": deepcopy(scene["objects"]), "entries": []}
                write_json(history_path, history)
            if history["scene_id"] != scene_id or not 0 <= history["cursor"] <= len(history["entries"]):
                raise ValueError("Invalid scene history")
            if history["revision"] > scene["revision"]:
                scene["objects"] = replay(history)
                scene["revision"] = history["revision"]
                scene = SceneDocument.model_validate(scene).model_dump()
                write_json(path, scene)
            elif history["revision"] < scene["revision"]:
                raise ValueError("Scene snapshot is ahead of history")
            return scene, history
        except (ValueError, KeyError, ValidationError) as exc:
            raise HTTPException(500, "Stored scene or history is invalid") from exc

    def read(self, scene_id: str) -> tuple[dict, dict]:
        with self.lock:
            return self._load(scene_id)

    def _commit(self, scene_id: str, scene: dict, history: dict) -> dict:
        project = self.project(scene_id)
        # History first: a crash before the snapshot write is recovered on next load.
        write_json(project / "history.json", history)
        write_json(project / "scene.json", scene)
        return {"scene_id": scene_id, "revision": scene["revision"], "history": history_status(history)}

    def apply(self, scene_id: str, expected_revision: int, operations: list[dict]) -> dict:
        if not operations or len(operations) > 64:
            raise HTTPException(422, "Supply 1–64 operations")
        with self.lock:
            scene, history = self._load(scene_id)
            self._check_revision(scene, expected_revision)
            before = {obj["id"]: obj for obj in scene["objects"]}
            objects = deepcopy(before)
            assets = {item["path"] for item in list_assets(self.project(scene_id))}
            try:
                for operation in operations:
                    apply_operation(objects, operation, assets)
                candidate = {**scene, "objects": list(objects.values()), "revision": scene["revision"] + 1}
                candidate = SceneDocument.model_validate(candidate).model_dump()
            except (SceneError, ValidationError, TypeError) as exc:
                raise HTTPException(422, str(exc)) from exc
            after = {obj["id"]: obj for obj in candidate["objects"]}
            changed = {object_id for object_id in before.keys() | after.keys() if before.get(object_id) != after.get(object_id)}
            if not changed:
                raise HTTPException(422, "Operation made no change")
            history["entries"] = history["entries"][: history["cursor"]]
            history["entries"].append({
                "id": str(uuid4()),
                "operations": operations,
                "before": {key: before.get(key) for key in sorted(changed)},
                "after": {key: after.get(key) for key in sorted(changed)},
            })
            history["cursor"] += 1
            history["revision"] = candidate["revision"]
            result = self._commit(scene_id, candidate, history)
            result["changes"] = self._changes(after, changed)
            return result

    def travel(self, scene_id: str, expected_revision: int, direction: str) -> dict:
        with self.lock:
            scene, history = self._load(scene_id)
            self._check_revision(scene, expected_revision)
            cursor = history["cursor"]
            if direction == "undo" and cursor == 0 or direction == "redo" and cursor == len(history["entries"]):
                raise HTTPException(422, f"Nothing to {direction}")
            entry = history["entries"][cursor - 1 if direction == "undo" else cursor]
            states = entry["before" if direction == "undo" else "after"]
            objects = {obj["id"]: obj for obj in scene["objects"]}
            for object_id, state in states.items():
                if state is None:
                    objects.pop(object_id, None)
                else:
                    objects[object_id] = state
            candidate = SceneDocument.model_validate({**scene, "revision": scene["revision"] + 1, "objects": list(objects.values())}).model_dump()
            history["cursor"] += -1 if direction == "undo" else 1
            history["revision"] = candidate["revision"]
            result = self._commit(scene_id, candidate, history)
            result["changes"] = self._changes(objects, set(states))
            return result

    @staticmethod
    def _check_revision(scene: dict, expected: int) -> None:
        if expected != scene["revision"]:
            raise HTTPException(409, {"message": "Scene revision conflict", "current_revision": scene["revision"]})

    @staticmethod
    def _changes(objects: dict[str, dict], ids: set[str]) -> list[dict]:
        return [
            {"type": "upsert", "object": objects[object_id]} if object_id in objects else {"type": "delete", "object_id": object_id}
            for object_id in sorted(ids)
        ]
