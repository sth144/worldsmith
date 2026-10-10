"""Approved, versioned geometry jobs using fixed Blender operations."""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from uuid import UUID, uuid4

from fastapi import HTTPException

from .history import write_json
from .assets import validate_glb

REPO = Path(__file__).resolve().parents[2]


def interpret_geometry(prompt: str) -> dict | None:
    words = prompt.lower()
    number = re.search(r"(\d+(?:\.\d+)?)\s*(?:m|meters?)\b", words)
    if "round" in words or "bevel" in words:
        width = float(number.group(1)) if number else 0.04
        if not 0.001 <= width <= 0.25:
            raise HTTPException(422, "Bevel width must be 0.001–0.25 meters")
        return {"kind": "bevel", "width": width}
    if "taller" in words or "stretch" in words or "extend" in words:
        factor = 1.5
        match = re.search(r"(\d+(?:\.\d+)?)\s*(?:times|x)\b", words)
        if match:
            factor = float(match.group(1))
        if not 1.01 <= factor <= 5:
            raise HTTPException(422, "Height factor must be 1.01–5")
        return {"kind": "stretch_height", "factor": factor}
    if "opening" in words or "doorway" in words or "cut a door" in words:
        width = float(number.group(1)) if number else 1.0
        if not 0.2 <= width <= 4:
            raise HTTPException(422, "Opening width must be 0.2–4 meters")
        return {"kind": "cut_opening", "width": width, "height": 2.1}
    return None


def create_proposal(project: Path, scene: dict, object_id: str, prompt: str, spec: dict) -> dict:
    obj = next((item for item in scene["objects"] if item["id"] == object_id), None)
    if obj is None or obj["locked"]:
        raise HTTPException(422, "Select an unlocked object")
    job = {"id": str(uuid4()), "status": "approval_required", "scene_id": scene["scene_id"],
           "revision": scene["revision"], "object_id": object_id, "source_asset": obj["asset"],
           "prompt": prompt, "operation": spec}
    path = project / "jobs" / f"{job['id']}.json"
    write_json(path, job)
    return job


def read_job(project: Path, job_id: str) -> dict:
    try:
        normalized = str(UUID(job_id))
    except ValueError as exc:
        raise HTTPException(400, "Invalid job ID") from exc
    path = project / "jobs" / f"{normalized}.json"
    if not path.is_file():
        raise HTTPException(404, "Geometry job not found")
    return json.loads(path.read_text())


def run_geometry(project: Path, job: dict) -> str:
    blender = shutil.which("blender")
    if blender is None:
        raise HTTPException(503, "Blender executable is unavailable")
    source = project / job["source_asset"]
    if not source.is_file():
        raise HTTPException(422, "Source asset is missing")
    original_name = source.stem.split("-v-")[0]
    asset_name = f"{original_name}-v-{job['id']}.glb"
    destination = project / "assets" / asset_name
    if destination.exists():
        return f"assets/{asset_name}"
    with tempfile.TemporaryDirectory(prefix="worldsmith-geometry-") as directory:
        work = Path(directory)
        copied = work / "source.glb"
        shutil.copy2(source, copied)
        config = work / "config.json"
        config.write_text(json.dumps({"source": str(copied), "output": str(work / "result.glb"),
                                      "operation": job["operation"]}))
        try:
            result = subprocess.run(
                [blender, "--background", "--factory-startup", "--disable-autoexec", "--python",
                 str(REPO / "scripts" / "blender_geometry.py"), "--", str(config)],
                cwd=work, capture_output=True, text=True, timeout=120, env={
                    **{key: value for key, value in os.environ.items()
                       if key in {"PATH", "LANG", "LC_ALL", "SYSTEMROOT"}},
                    "HOME": str(work), "TMPDIR": str(work),
                },
            )
        except subprocess.TimeoutExpired as exc:
            raise HTTPException(504, "Geometry worker timed out") from exc
        output = work / "result.glb"
        if result.returncode != 0 or not output.is_file():
            raise HTTPException(500, "Geometry worker failed: " + (result.stderr or result.stdout)[-500:])
        try:
            validate_glb(output)
        except ValueError as exc:
            raise HTTPException(500, f"Geometry worker produced an invalid GLB: {exc}") from exc
        with tempfile.NamedTemporaryFile(dir=destination.parent, suffix=".glb", delete=False) as temporary:
            staged = Path(temporary.name)
            with output.open("rb") as incoming:
                shutil.copyfileobj(incoming, temporary)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(staged, destination)
    return f"assets/{asset_name}"
