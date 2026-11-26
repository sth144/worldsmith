"""FastAPI entry point. All writes use SceneStore's shared operation path."""

from __future__ import annotations

import os
import asyncio
import json
import re
import tempfile
from pathlib import Path
from typing import Any, Literal
from uuid import uuid4

from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from .assets import asset_path, glb_material_names, list_assets, valid_asset_paths, validate_glb, valid_scene_id
from .asset_requests import AssetLibrary, copy_version_to_project, create_asset_request, current_mesh, read_asset_request
from .agent import claude_plan, claude_view_plan, codex_plan, codex_view_plan, creative_view_plan, deterministic_plan, deterministic_view_plan, generated_placement, is_creation_request, is_placement_request, resolve_aimed_target, validate_proposal
from .export import export_scene, register_environment, scene_instance_path, scene_package, source_manifest
from .geometry import create_proposal, interpret_geometry, read_job, run_geometry
from .procedural import build_assets, validate_designs
from .history import write_json
from .history import history_status
from .storage import SceneStore
from .scene import SceneError, vector
from .scene_brief import plan_scene_brief, read_scene_brief, save_scene_brief
from .websocket import Connections
from .voice import MAX_WAV_BYTES, transcribe

REPO = Path(__file__).resolve().parents[2]


class CreateScene(BaseModel):
    scene_id: str


class BriefRequest(BaseModel):
    expected_revision: int = Field(ge=0)
    prompt: str = Field(min_length=20, max_length=2000)
    provider: Literal["codex", "claude"] = "codex"


class LibraryRequest(BaseModel):
    prompt: str = Field(min_length=10, max_length=1000)


class OperationBatch(BaseModel):
    expected_revision: int = Field(ge=0)
    operations: list[dict[str, Any]]


class RevisionRequest(BaseModel):
    expected_revision: int = Field(ge=0)


class AgentRequest(BaseModel):
    expected_revision: int = Field(ge=0)
    prompt: str = Field(min_length=3, max_length=1000)
    provider: Literal["codex", "claude"] = "codex"
    creation_mode: Literal["draft", "reviewed"] = "draft"
    selected_object_ids: list[str] = Field(default_factory=list, max_length=16)
    aimed_object_id: str | None = None
    view: dict[str, Any] | None = None


class FulfillAssetRequest(BaseModel):
    expected_revision: int = Field(ge=0)
    asset_id: str = Field(min_length=1, max_length=64)
    name: str | None = Field(default=None, min_length=1, max_length=100)


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
    seed_setting = os.environ.get("WORLDSMITH_SCENE_SEED")
    store = SceneStore(root, Path(seed_setting) if seed_setting else None,
                       os.environ.get("WORLDSMITH_INITIAL_SCENE_ID"))
    connections = Connections()
    app = FastAPI(title="Worldsmith Scene Server", version="0.7.1")
    app.state.store = store
    library_root = root.parent / "library"

    async def receive_glb(request: Request) -> Path:
        uploads = root.parent / "uploads"
        uploads.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=uploads, suffix=".glb", delete=False) as temporary:
            path = Path(temporary.name)
            size = 0
            try:
                async for chunk in request.stream():
                    size += len(chunk)
                    if size > 256 * 1024 * 1024:
                        raise HTTPException(413, "GLB exceeds 256 MB")
                    temporary.write(chunk)
            except BaseException:
                path.unlink(missing_ok=True)
                raise
        try:
            validate_glb(path)
        except ValueError as exc:
            path.unlink(missing_ok=True)
            raise HTTPException(422, "File is not a valid mesh GLB") from exc
        return path

    @app.post("/api/transcribe")
    async def transcribe_command(request: Request) -> dict:
        if request.headers.get("content-type", "").split(";")[0] != "audio/wav":
            raise HTTPException(415, "Send audio/wav")
        chunks = []
        size = 0
        async for chunk in request.stream():
            size += len(chunk)
            if size > MAX_WAV_BYTES:
                raise HTTPException(413, "Recording is too large")
            chunks.append(chunk)
        return {"text": await asyncio.to_thread(transcribe, b"".join(chunks))}

    @app.get("/api/scenes")
    def list_scenes() -> list[dict]:
        return store.list_scenes()

    @app.get("/api/scenes/{scene_id}")
    def get_scene(scene_id: str) -> dict:
        return store.read(scene_id)[0]

    @app.get("/api/scenes/{scene_id}/package")
    def get_scene_package(scene_id: str) -> dict:
        store.read(scene_id)
        return {"scene_id": scene_id, **scene_package(store.project(scene_id))}

    @app.get("/api/scenes/{scene_id}/package/instances/{index}/{kind}")
    def get_scene_instance(scene_id: str, index: int, kind: str) -> FileResponse:
        store.read(scene_id)
        path = scene_instance_path(store.project(scene_id), index, kind)
        return FileResponse(path, media_type="model/gltf-binary" if kind == "prototype" else "application/octet-stream")

    @app.post("/api/scenes", status_code=201)
    def create_scene(body: CreateScene) -> dict:
        return store.create(body.scene_id)

    @app.post("/api/scenes/{scene_id}/environment")
    async def import_scene_environment(scene_id: str, request: Request) -> dict:
        store.read(scene_id)
        project = store.project(scene_id)
        if (project / "environment.json").exists():
            raise HTTPException(409, "Scene already has an environment")
        path = await receive_glb(request)
        try:
            return register_environment(project, path)
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from exc
        finally:
            path.unlink(missing_ok=True)

    @app.get("/api/library/assets")
    def list_library_assets() -> list[dict]:
        library = AssetLibrary(library_root)
        try:
            return [{key: item[key] for key in ("asset_id", "sha256", "kind", "origin", "metadata")}
                    for item in library.list()]
        finally:
            library.database.close()

    @app.post("/api/library/assets/{asset_id}", status_code=201)
    async def import_library_asset(asset_id: str, request: Request) -> dict:
        valid_scene_id(asset_id)
        path = await receive_glb(request)
        library = AssetLibrary(library_root)
        try:
            item = library.register(asset_id, path, "mesh", "imported", "unverified",
                                    metadata={"godot_review": False, "source_filename": request.headers.get("x-filename", "")})
            return {key: item[key] for key in ("asset_id", "sha256", "kind", "origin", "metadata")}
        finally:
            library.database.close()
            path.unlink(missing_ok=True)

    @app.get("/api/library/assets/{asset_id}/glb")
    def download_library_asset(asset_id: str) -> FileResponse:
        valid_scene_id(asset_id)
        library = AssetLibrary(library_root)
        try:
            try:
                item = library.get(asset_id)
            except KeyError as exc:
                raise HTTPException(404, "Asset not found") from exc
            return FileResponse(item["blob"], media_type="model/gltf-binary",
                                filename=f"{asset_id}.glb")
        finally:
            library.database.close()

    @app.get("/api/library/requests")
    def list_library_requests() -> list[dict]:
        directory = library_root / "requests"
        if not directory.is_dir():
            return []
        return [json.loads(path.read_text()) for path in sorted(directory.glob("*.json"), reverse=True)]

    @app.post("/api/library/requests", status_code=201)
    def request_library_asset(body: LibraryRequest) -> dict:
        job = {"id": str(uuid4()), "prompt": body.prompt.strip(), "status": "needs_production"}
        write_json(library_root / "requests" / f"{job['id']}.json", job)
        return job

    @app.get("/api/scenes/{scene_id}/brief")
    def get_scene_brief(scene_id: str) -> dict:
        store.read(scene_id)
        return read_scene_brief(store.project(scene_id))

    @app.post("/api/scenes/{scene_id}/brief")
    async def create_scene_brief(scene_id: str, body: BriefRequest) -> dict:
        scene, _ = store.read(scene_id)
        if scene["revision"] != body.expected_revision:
            raise HTTPException(409, "Scene changed since this brief was requested")
        brief = await plan_scene_brief(body.prompt, body.provider)
        with store.lock:
            current, _ = store.read(scene_id)
            if current["revision"] != body.expected_revision:
                raise HTTPException(409, "Scene changed while planning the brief")
            return save_scene_brief(store.project(scene_id), scene_id,
                                    current["revision"], body.prompt, body.provider, brief)

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
        creation = is_creation_request(body.prompt)
        if creation and context_view is None:
            raise HTTPException(422, "Look at a floor point to place objects")
        place_in_view = context_view is not None and (creation or
                        not body.selected_object_ids and (body.aimed_object_id is None or
                        re.search(r"\b(here|there|over here|over there)\b", body.prompt.lower())))
        catalog = list_assets(store.project(scene_id))
        known_catalog_request = is_placement_request(body.prompt, catalog)
        view = context_view if place_in_view else None
        if view is not None and creation and not known_catalog_request and body.creation_mode == "reviewed":
            job = create_asset_request(store.project(scene_id), scene_id, scene["revision"],
                                       body.prompt, view["target_position"])
            return {"status": "needs_asset", "job": job,
                    "message": "A reviewed mesh is needed. Generate or author it, promote it in the library, then fulfill this request."}
        target_ids = list(body.selected_object_ids)
        target_source = "view" if place_in_view else ("selected" if target_ids else "none")
        if not place_in_view and not target_ids:
            resolved_id, target_source = resolve_aimed_target(body.prompt, body.aimed_object_id,
                                                               context_view, scene, catalog)
            if resolved_id is None:
                raise HTTPException(422, "Aim at a placed object or look at a floor point for a new object")
            target_ids = [resolved_id]
        selected = []
        for object_id in target_ids:
            obj = by_id[object_id].copy()
            obj["available_materials"] = sorted(glb_material_names(store.project(scene_id) / obj["asset"]))
            selected.append(obj)
        operations = (deterministic_view_plan(body.prompt, view["target_position"], catalog) if view is not None and known_catalog_request
                      else deterministic_plan(body.prompt, selected))
        generated_assets: set[str] = set()
        generated_designs: list[dict] = []
        planner = "local" if operations is not None else body.provider
        if operations is None:
            if view is not None:
                if known_catalog_request:
                    operations = await (claude_view_plan(body.prompt, view, scene, catalog) if body.provider == "claude"
                                        else codex_view_plan(body.prompt, view, scene, catalog))
                else:
                    designs = validate_designs(await creative_view_plan(body.prompt, view, scene, body.provider))
                    generated_designs = designs
                    paths = await asyncio.to_thread(build_assets, store.project(scene_id), designs)
                    generated_assets = set(paths)
                    target = view["target_position"]
                    operations = [generated_placement(path, [target[i] + design["offset"][i] for i in range(3)], design["name"])
                                  for path, design in zip(paths, designs)]
            else:
                geometry_spec = interpret_geometry(body.prompt)
                if geometry_spec is not None:
                    if len(selected) != 1:
                        raise HTTPException(422, "Select one object for a geometry edit")
                    job = create_proposal(store.project(scene_id), scene, selected[0]["id"], body.prompt, geometry_spec)
                    return {"status": "approval_required", "job": job, "planner": "geometry template"}
                operations = await (claude_plan(body.prompt, selected, scene) if body.provider == "claude"
                                    else codex_plan(body.prompt, selected, scene))
        assets = valid_asset_paths(store.project(scene_id))
        try:
            validate_proposal(operations, scene, target_ids, assets,
                              view["target_position"] if view is not None else None, generated_assets)
            result = store.apply(scene_id, body.expected_revision, operations)
        except Exception:
            for asset in generated_assets:
                (store.project(scene_id) / asset).unlink(missing_ok=True)
            raise
        await connections.broadcast(scene_id, {"type": "delta", **result})
        return {"planner": planner, "target_source": target_source, "operations": operations,
                "generated_designs": generated_designs, **result}

    @app.get("/api/scenes/{scene_id}/asset-requests/{job_id}")
    def get_asset_request(scene_id: str, job_id: str) -> dict:
        store.read(scene_id)
        return read_asset_request(store.project(scene_id), job_id)

    @app.post("/api/scenes/{scene_id}/asset-requests/{job_id}/fulfill")
    async def fulfill_asset_request(scene_id: str, job_id: str, body: FulfillAssetRequest) -> dict:
        project = store.project(scene_id)
        with store.lock:
            scene, _ = store.read(scene_id)
            job = read_asset_request(project, job_id)
            if job["scene_id"] != scene_id or job["status"] != "needs_asset":
                raise HTTPException(422, "Asset request is no longer open")
            if scene["revision"] != body.expected_revision or scene["revision"] != job["revision"]:
                raise HTTPException(409, "Scene changed since this asset was requested; request it again")
            version = current_mesh(library_root, body.asset_id)
            catalog_path = project / "catalog.json"
            original_catalog = catalog_path.read_bytes() if catalog_path.is_file() else None
            try:
                catalog = json.loads(original_catalog) if original_catalog is not None else {}
            except ValueError as exc:
                raise HTTPException(500, "Project catalog is invalid") from exc
            if not isinstance(catalog, dict) or not isinstance(catalog.get("assets", {}), dict):
                raise HTTPException(500, "Project catalog is invalid")
            asset, created = copy_version_to_project(project, version)
            asset_key = Path(asset).stem
            name = body.name or body.asset_id.replace("_", " ").replace("-", " ").title()
            catalog.setdefault("assets", {})[asset_key] = {
                "name": name, "walkable": False, "library_asset_id": body.asset_id,
                "library_sha256": version["sha256"],
            }
            operation = generated_placement(asset, job["target_position"], name)
            try:
                write_json(catalog_path, catalog)
                result = store.apply(scene_id, body.expected_revision, [operation])
            except Exception:
                if original_catalog is None:
                    catalog_path.unlink(missing_ok=True)
                else:
                    catalog_path.write_bytes(original_catalog)
                if created:
                    (project / asset).unlink(missing_ok=True)
                raise
            job.update({"status": "complete", "asset_id": body.asset_id,
                        "asset_sha256": version["sha256"], "project_asset": asset,
                        "object_id": operation["object"]["id"]})
            write_json(project / "jobs" / f"{job_id}.json", job)
        await connections.broadcast(scene_id, {"type": "delta", **result})
        return {"job": job, "operation": operation, **result}

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
    def get_assets(scene_id: str) -> list[dict]:
        store.read(scene_id)
        return list_assets(store.project(scene_id))

    @app.get("/api/assets/{asset_id}")
    def get_asset(asset_id: str, scene_id: str) -> FileResponse:
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
