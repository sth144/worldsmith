"""Connected clients for incremental scene broadcasts."""

from __future__ import annotations

from collections import defaultdict

from fastapi import WebSocket, WebSocketDisconnect


class Connections:
    def __init__(self) -> None:
        self.by_scene: dict[str, set[WebSocket]] = defaultdict(set)

    def add(self, scene_id: str, socket: WebSocket) -> None:
        self.by_scene[scene_id].add(socket)

    def remove(self, scene_id: str, socket: WebSocket) -> None:
        self.by_scene[scene_id].discard(socket)

    async def broadcast(self, scene_id: str, message: dict, except_socket: WebSocket | None = None) -> None:
        for socket in tuple(self.by_scene[scene_id]):
            if socket is except_socket:
                continue
            try:
                await socket.send_json(message)
            except (RuntimeError, OSError, WebSocketDisconnect):
                self.remove(scene_id, socket)
