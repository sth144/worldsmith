"""Build AI-described props with a fixed, validated Blender worker."""

from __future__ import annotations

import json
import math
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from uuid import uuid4

from fastapi import HTTPException

from .assets import validate_glb

REPO = Path(__file__).resolve().parents[2]


def _numbers(value: object, count: int, low: float, high: float, label: str) -> list[float]:
    if not isinstance(value, list) or len(value) != count or any(
        type(item) not in (int, float) or not math.isfinite(item) or not low <= item <= high
        for item in value
    ):
        raise HTTPException(422, f"Generated {label} must contain {count} finite values in {low}..{high}")
    return [float(item) for item in value]


def validate_designs(designs: list[dict]) -> list[dict]:
    if not isinstance(designs, list) or not 1 <= len(designs) <= 3:
        raise HTTPException(422, "The request produced no buildable 3D objects")
    clean = []
    for design in designs:
        if not isinstance(design, dict) or set(design) != {"name", "offset", "parts"}:
            raise HTTPException(422, "Generated object has invalid fields")
        name = design["name"]
        if not isinstance(name, str) or not 1 <= len(name.strip()) <= 80:
            raise HTTPException(422, "Generated object needs a short name")
        offset = _numbers(design["offset"], 3, -5, 5, "offset")
        if math.dist(offset, [0, 0, 0]) > 5:
            raise HTTPException(422, "Generated object is too far from the viewed point")
        parts = design["parts"]
        if not isinstance(parts, list) or not 1 <= len(parts) <= 32:
            raise HTTPException(422, "Generated object needs 1–32 mesh parts")
        clean_parts = []
        for part in parts:
            if not isinstance(part, dict) or set(part) != {"name", "shape", "center", "size", "yaw", "color"}:
                raise HTTPException(422, "Generated mesh part has invalid fields")
            if not isinstance(part["name"], str) or not 1 <= len(part["name"].strip()) <= 60:
                raise HTTPException(422, "Generated mesh part needs a name")
            if not isinstance(part["shape"], str) or part["shape"] not in {"box", "ellipsoid", "cylinder", "cone"}:
                raise HTTPException(422, "Generated mesh part has an unsupported shape")
            center = _numbers(part["center"], 3, -5, 5, "part center")
            size = _numbers(part["size"], 3, 0.02, 6, "part size")
            color = _numbers(part["color"], 3, 0, 1, "part color")
            yaw = part["yaw"]
            if type(yaw) not in (int, float) or not math.isfinite(yaw) or not -360 <= yaw <= 360:
                raise HTTPException(422, "Generated mesh part has invalid yaw")
            if center[1] - size[1] / 2 < -0.2 or center[1] + size[1] / 2 > 8:
                raise HTTPException(422, "Generated mesh must stay near its floor origin")
            clean_parts.append({"name": part["name"].strip(), "shape": part["shape"],
                                "center": center, "size": size, "yaw": float(yaw), "color": color})
        clean.append({"name": name.strip(), "offset": offset, "parts": clean_parts})
    return clean


def build_assets(project: Path, designs: list[dict]) -> list[str]:
    """Generate GLBs off-scene, then publish their immutable asset versions."""
    blender = shutil.which("blender")
    if blender is None:
        raise HTTPException(503, "Blender executable is unavailable on the scene server")
    with tempfile.TemporaryDirectory(prefix="worldsmith-procedural-") as directory:
        work = Path(directory)
        prepared = []
        for design in designs:
            asset_name = f"generated-{uuid4()}.glb"
            output = work / asset_name
            config = work / f"{asset_name}.json"
            config.write_text(json.dumps({"output": str(output), "parts": design["parts"]}))
            try:
                result = subprocess.run(
                    [blender, "--background", "--factory-startup", "--disable-autoexec", "--python",
                     str(REPO / "scripts" / "blender_procedural.py"), "--", str(config)],
                    cwd=work, capture_output=True, text=True, timeout=60,
                    env={**{key: value for key, value in os.environ.items()
                            if key in {"PATH", "LANG", "LC_ALL", "SYSTEMROOT"}},
                         "HOME": str(work), "TMPDIR": str(work)},
                )
            except subprocess.TimeoutExpired as exc:
                raise HTTPException(504, "Generated asset timed out") from exc
            if result.returncode != 0 or not output.is_file() or output.stat().st_size > 5_000_000:
                raise HTTPException(502, "Could not build generated asset: " + (result.stderr or result.stdout)[-300:])
            try:
                validate_glb(output)
            except ValueError as exc:
                raise HTTPException(502, f"Generated asset is invalid: {exc}") from exc
            prepared.append((asset_name, output))
        destinations = []
        try:
            for asset_name, output in prepared:
                destination = project / "assets" / asset_name
                with tempfile.NamedTemporaryFile(dir=destination.parent, suffix=".glb", delete=False) as temporary:
                    staged = Path(temporary.name)
                    with output.open("rb") as incoming:
                        shutil.copyfileobj(incoming, temporary)
                    temporary.flush()
                    os.fsync(temporary.fileno())
                os.replace(staged, destination)
                destinations.append(destination)
        except OSError:
            for destination in destinations:
                destination.unlink(missing_ok=True)
            if "staged" in locals():
                staged.unlink(missing_ok=True)
            raise
    return [f"assets/{name}" for name, _ in prepared]
