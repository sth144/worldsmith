"""FastAPI entry point. All writes use SceneStore's shared operation path."""

from __future__ import annotations

import os
import asyncio
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from .assets import asset_path, glb_material_names, list_assets
from .agent import codex_plan, codex_view_plan, deterministic_plan, deterministic_view_plan, is_placement_request, resolve_aimed_target, validate_proposal
from .export import export_scene, source_manifest
from .geometry import create_proposal, interpret_geometry, read_job, run_geometry
from .history import write_json
from .history import history_status
from .storage import SceneStore
from .scene import SceneError, vector
from .websocket import Connections

REPO = Path(__file__).resolve().parents[2]


class CreateScene(BaseModel):
    scene_id: str


class OperationBatch(BaseModel):
    expected_revision: int = Field(ge=0)
    operations: list[dict[str, Any]]


class RevisionRequest(BaseModel):
    expected_revision: int = Field(ge=0)


class AgentRequest(BaseModel):
    expected_revision: int = Field(ge=0)
    prompt: str = Field(min_length=3, max_length=1000)
    selected_object_ids: list[str] = Field(default_factory=list, max_length=16)
    aimed_object_id: str | None = None
    view: dict[str, Any] | None = None


def validate_view(view: dict[str, Any] | None) -> dict:
    if not isinstance(view, dict):
        raise HTTPException(422, "Look at a floor point to place objects")
    try:
        camera = vector(view.get("camera_position"), 3)
        target = vector(view.get("target_position"), 3)
        direction = vector(view.get("camera_direction"), 3)
        if sum(item * item for item in direction) < 0.9 or sum(item * item for item in direction) > 1.1:
            raise SceneError("View direction must be normalized")
        if sum((a - b) ** 2 for a, b in zip(camera, target)) > 30 ** 2:
            raise SceneError("Viewed point is too far away")
        offset = [a - b for a, b in zip(target, camera)]
        distance = sum(item * item for item in offset) ** 0.5
        if distance < 0.1 or sum(a * b for a, b in zip(offset, direction)) < distance * 0.9:
            raise SceneError("Viewed point must be in front of the camera")
    except SceneError as exc:
        raise HTTPException(422, str(exc)) from exc
    return {"camera_position": camera, "camera_direction": direction, "target_position": target}


def create_app(data_dir: Path | None = None) -> FastAPI:
    root = data_dir or Path(os.environ.get("WORLDSMITH_DATA_DIR", REPO / "data")) / "projects"
    store = SceneStore(root, REPO / "projects" / "demo")
    connections = Connections()
    app = FastAPI(title="Worldsmith Scene Server", version="0.7.1")
    app.state.store = store

    @app.get("/api/scenes/{scene_id}")
    def get_scene(scene_id: str) -> dict:
        return store.read(scene_id)[0]

    @app.post("/api/scenes", status_code=201)
    def create_scene(body: CreateScene) -> dict:
        return store.create(body.scene_id)

    @app.post("/api/scenes/{scene_id}/operations")
    async def apply_operations(scene_id: str, body: OperationBatch) -> dict:
        result = store.apply(scene_id, body.expected_revision, body.operations)
        await connections.broadcast(scene_id, {"type": "delta", **result})
        return result

    @app.post("/api/scenes/{scene_id}/agent")
    async def agent_edit(scene_id: str, body: AgentRequest) -> dict:
        scene, _ = store.read(scene_id)
        if scene["revision"] != body.expected_revision:
            raise HTTPException(409, {"message": "Scene revision conflict", "current_revision": scene["revision"]})
        by_id = {obj["id"]: obj for obj in scene["objects"]}
        if len(set(body.selected_object_ids)) != len(body.selected_object_ids) or any(
            object_id not in by_id for object_id in body.selected_object_ids
        ):
            raise HTTPException(422, "Select existing objects")
        context_view = validate_view(body.view) if body.view is not None else None
        if is_placement_request(body.prompt) and context_view is None:
            raise HTTPException(422, "Look at a floor point to place objects")
        place_in_view = context_view is not None and is_placement_request(body.prompt)
        view = context_view if place_in_view else None
        target_ids = list(body.selected_object_ids)
        target_source = "view" if place_in_view else ("selected" if target_ids else "none")
        if not place_in_view and not target_ids:
            resolved_id, target_source = resolve_aimed_target(body.prompt, body.aimed_object_id,
                                                               context_view, scene)
            if resolved_id is None:
                raise HTTPException(422, "Aim at a placed object or describe a catalog object to add")
            target_ids = [resolved_id]
        selected = []
        for object_id in target_ids:
            obj = by_id[object_id].copy()
            obj["available_materials"] = sorted(glb_material_names(store.project(scene_id) / obj["asset"]))
            selected.append(obj)
        operations = (deterministic_view_plan(body.prompt, view["target_position"]) if view is not None
                      else deterministic_plan(body.prompt, selected))
        planner = "local" if operations is not None else "codex"
        if operations is None:
            if view is not None:
                operations = await codex_view_plan(body.prompt, view, scene)
            else:
                geometry_spec = interpret_geometry(body.prompt)
                if geometry_spec is not None:
                    if len(selected) != 1:
                        raise HTTPException(422, "Select one object for a geometry edit")
                    job = create_proposal(store.project(scene_id), scene, selected[0]["id"], body.prompt, geometry_spec)
                    return {"status": "approval_required", "job": job, "planner": "geometry template"}
                operations = await codex_plan(body.prompt, selected, scene)
        assets = {item["path"] for item in list_assets(store.project(scene_id))}
        validate_proposal(operations, scene, target_ids, assets,
                          view["target_position"] if view is not None else None)
        result = store.apply(scene_id, body.expected_revision, operations)
        await connections.broadcast(scene_id, {"type": "delta", **result})
        return {"planner": planner, "target_source": target_source, "operations": operations, **result}

    @app.get("/api/scenes/{scene_id}/geometry/{job_id}")
    def get_geometry_job(scene_id: str, job_id: str) -> dict:
        store.read(scene_id)
        return read_job(store.project(scene_id), job_id)

    @app.post("/api/scenes/{scene_id}/geometry/{job_id}/approve")
    async def approve_geometry(scene_id: str, job_id: str, body: RevisionRequest) -> dict:
        project = store.project(scene_id)
        with store.lock:
            scene, _ = store.read(scene_id)
            job = read_job(project, job_id)
            if job["scene_id"] != scene_id or job["status"] != "approval_required":
                raise HTTPException(422, "Job is not waiting for approval")
            if scene["revision"] != body.expected_revision or scene["revision"] != job["revision"]:
                raise HTTPException(409, "Scene changed since geometry was proposed; request it again")
            obj = next((item for item in scene["objects"] if item["id"] == job["object_id"]), None)
            if obj is None or obj["asset"] != job["source_asset"]:
                raise HTTPException(409, "Selected asset changed since geometry was proposed")
            job["status"] = "running"
            write_json(project / "jobs" / f"{job_id}.json", job)
        try:
            new_asset = await asyncio.to_thread(run_geometry, project, job)
            result = store.apply(scene_id, body.expected_revision, [{
                "type": "replace_asset", "object_id": job["object_id"], "asset": new_asset,
            }])
        except HTTPException as exc:
            job["status"] = "failed"
            job["error"] = str(exc.detail)
            write_json(project / "jobs" / f"{job_id}.json", job)
            raise
        job["status"] = "complete"
        job["result_asset"] = new_asset
        write_json(project / "jobs" / f"{job_id}.json", job)
        await connections.broadcast(scene_id, {"type": "delta", **result})
        return {"job": job, **result}

    @app.post("/api/scenes/{scene_id}/undo")
    async def undo(scene_id: str, body: RevisionRequest) -> dict:
        result = store.travel(scene_id, body.expected_revision, "undo")
        await connections.broadcast(scene_id, {"type": "delta", **result})
        return result

    @app.post("/api/scenes/{scene_id}/redo")
    async def redo(scene_id: str, body: RevisionRequest) -> dict:
        result = store.travel(scene_id, body.expected_revision, "redo")
        await connections.broadcast(scene_id, {"type": "delta", **result})
        return result

    @app.get("/api/scenes/{scene_id}/history")
    def get_history(scene_id: str) -> dict:
        _, history = store.read(scene_id)
        return history

    @app.get("/api/assets")
    def get_assets(scene_id: str = "demo") -> list[dict]:
        store.read(scene_id)
        return list_assets(store.project(scene_id))

    @app.get("/api/assets/{asset_id}")
    def get_asset(asset_id: str, scene_id: str = "demo") -> FileResponse:
        store.read(scene_id)
        return FileResponse(asset_path(store.project(scene_id), asset_id), media_type="model/gltf-binary")

    @app.get("/api/scenes/{scene_id}/manifest")
    def get_manifest(scene_id: str) -> dict:
        scene, _ = store.read(scene_id)
        return source_manifest(store.project(scene_id), scene)

    @app.get("/api/scenes/{scene_id}/export")
    async def get_export(scene_id: str) -> FileResponse:
        scene, _ = store.read(scene_id)
        output, _ = await asyncio.to_thread(export_scene, store.project(scene_id), scene)
        return FileResponse(output, media_type="model/gltf-binary", filename=output.name)

    @app.websocket("/ws/scenes/{scene_id}")
    async def scene_socket(socket: WebSocket, scene_id: str) -> None:
        try:
            scene, history = store.read(scene_id)
        except HTTPException:
            await socket.close(code=1008)
            return
        await socket.accept()
        connections.add(scene_id, socket)
        await socket.send_json({"type": "snapshot", "scene": scene, "history": history_status(history)})
        try:
            while True:
                message = await socket.receive_json()
                request_id = message.get("request_id", "") if isinstance(message, dict) else ""
                try:
                    if not isinstance(message, dict):
                        raise HTTPException(422, "Message must be an object")
                    kind = message.get("type")
                    expected = message.get("expected_revision")
                    if type(expected) is not int or expected < 0:
                        raise HTTPException(422, "expected_revision must be a nonnegative integer")
                    if kind == "operation":
                        operations = message.get("operations")
                        if not isinstance(operations, list):
                            raise HTTPException(422, "operations must be an array")
                        result = store.apply(scene_id, expected, operations)
                    elif kind in ("undo", "redo"):
                        result = store.travel(scene_id, expected, kind)
                    else:
                        raise HTTPException(422, "Unsupported message type")
                    await socket.send_json({"type": "ack", "request_id": request_id, **result})
                    await connections.broadcast(scene_id, {"type": "delta", **result}, except_socket=socket)
                except HTTPException as exc:
                    if exc.status_code == 409:
                        current, current_history = store.read(scene_id)
                        await socket.send_json({"type": "conflict", "request_id": request_id, "scene": current, "history": history_status(current_history)})
                    else:
                        await socket.send_json({"type": "error", "request_id": request_id, "status": exc.status_code, "detail": exc.detail})
        except (WebSocketDisconnect, ValueError):
            pass
        finally:
            connections.remove(scene_id, socket)

    return app


app = create_app()
