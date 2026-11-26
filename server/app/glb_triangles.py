"""Read sampled world-space triangles from a GLB's binary chunk.

Bounding boxes cannot tell a terrain from a mesh of scattered trees, so the
collision suggestions look at real triangles. Only plain, uncompressed
triangle data is read; anything else yields no triangles and the caller falls
back to bounds.
"""

from __future__ import annotations

import struct
from pathlib import Path

MAX_TRIANGLES_PER_MESH = 6000
BIN_CHUNK = 0x004E4942
INDEX_FORMATS = {5121: ("B", 1), 5123: ("H", 2), 5125: ("I", 4)}

Point = tuple[float, float, float]
Triangle = tuple[Point, Point, Point]


def glb_binary(path: Path) -> bytes | None:
    """The GLB's embedded binary buffer, or None when it has none."""
    with path.open("rb") as source:
        header = source.read(20)
        if len(header) != 20:
            return None
        json_size = struct.unpack_from("<I", header, 12)[0]
        source.seek(20 + json_size)
        chunk = source.read(8)
        if len(chunk) != 8:
            return None
        size, kind = struct.unpack("<II", chunk)
        return source.read(size) if kind == BIN_CHUNK else None


def _view_bytes(document: dict, binary: bytes, accessor: dict, item_size: int) -> memoryview | None:
    if "bufferView" not in accessor or "sparse" in accessor:
        return None
    view = document["bufferViews"][accessor["bufferView"]]
    if view.get("buffer", 0) != 0 or view.get("byteStride", item_size) != item_size:
        return None
    start = view.get("byteOffset", 0) + accessor.get("byteOffset", 0)
    end = start + accessor["count"] * item_size
    return memoryview(binary)[start:end] if end <= len(binary) else None


def _positions(document: dict, binary: bytes, primitive: dict) -> memoryview | None:
    index = primitive.get("attributes", {}).get("POSITION")
    if index is None or "extensions" in primitive:
        return None
    accessor = document["accessors"][index]
    if accessor.get("componentType") != 5126 or accessor.get("type") != "VEC3":
        return None
    data = _view_bytes(document, binary, accessor, 12)
    return data.cast("f") if data is not None else None


def _indices(document: dict, binary: bytes, primitive: dict, vertex_count: int):
    if "indices" not in primitive:
        return range(vertex_count)
    accessor = document["accessors"][primitive["indices"]]
    if accessor.get("componentType") not in INDEX_FORMATS:
        return None
    code, size = INDEX_FORMATS[accessor["componentType"]]
    data = _view_bytes(document, binary, accessor, size)
    return data.cast(code) if data is not None else None


def _point(matrix: list[float], positions: memoryview, vertex: int) -> Point:
    x, y, z = positions[vertex * 3], positions[vertex * 3 + 1], positions[vertex * 3 + 2]
    return (matrix[0] * x + matrix[4] * y + matrix[8] * z + matrix[12],
            matrix[1] * x + matrix[5] * y + matrix[9] * z + matrix[13],
            matrix[2] * x + matrix[6] * y + matrix[10] * z + matrix[14])


def mesh_triangles(document: dict, binary: bytes | None, mesh_index: int, matrix: list[float]) -> list[Triangle]:
    """An evenly spaced sample of a mesh's triangles, moved into world space."""
    if binary is None:
        return []
    triangles: list[Triangle] = []
    for primitive in document["meshes"][mesh_index].get("primitives", []):
        if primitive.get("mode", 4) != 4:
            continue
        positions = _positions(document, binary, primitive)
        if positions is None:
            continue
        indices = _indices(document, binary, primitive, len(positions) // 3)
        if indices is None:
            continue
        count = len(indices) // 3
        step = max(1, count // MAX_TRIANGLES_PER_MESH)
        for triangle in range(0, count, step):
            triangles.append(tuple(_point(matrix, positions, indices[triangle * 3 + corner]) for corner in range(3)))
    return triangles
