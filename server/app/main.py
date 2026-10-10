"""FastAPI entry point. All writes use SceneStore's shared operation path."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from .assets import asset_path, list_assets
from .history import history_status
from .storage import SceneStore
from .websocket import Connections

REPO = Path(__file__).resolve().parents[2]


class CreateScene(BaseModel):
    scene_id: str


class OperationBatch(BaseModel):
    expected_revision: int = Field(ge=0)
    operations: list[dict[str, Any]]


class RevisionRequest(BaseModel):
    expected_revision: int = Field(ge=0)


def create_app(data_dir: Path | None = None) -> FastAPI:
    root = data_dir or Path(os.environ.get("WORLDSMITH_DATA_DIR", REPO / "data")) / "projects"
    store = SceneStore(root, REPO / "projects" / "demo")
    connections = Connections()
    app = FastAPI(title="Worldsmith Scene Server", version="0.3.0")
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
