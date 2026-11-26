"""Generate a reusable mesh candidate from a reference image with a local 3D runner.

The model, weights, image, and output directory are supplied at invocation time.
No generated asset is promoted into a scene or the current library version.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
from pathlib import Path

from asset_library import AssetLibrary, DEFAULT_LIBRARY, digest
from check_glb_quality import inspect_glb


def generate_candidate(
    *, asset_id: str, image: Path, runner: Path, shape_weights: Path,
    paint_weights: Path, output_dir: Path, library_root: Path, license_name: str,
    shape_steps: int = 30, octree: int = 256, seed: int = 0,
    paint_steps: int = 8, paint_resolution: int = 256, texture_size: int = 1024,
    max_triangles: int | None = None, max_texture_bytes: int | None = None,
) -> dict:
    if not asset_id or len(asset_id) > 64 or any(
        char not in "abcdefghijklmnopqrstuvwxyz0123456789_-" for char in asset_id
    ):
        raise ValueError("Asset ID must use lowercase letters, digits, underscore, or hyphen")
    if not license_name:
        raise ValueError("Model license is required")
    image = image.resolve(strict=True)
    runner = runner.resolve(strict=True)
    shape_weights = shape_weights.resolve(strict=True)
    paint_weights = paint_weights.resolve(strict=True)
    if not image.is_file() or not runner.is_file():
        raise ValueError("Image and runner must be files")
    if not shape_weights.is_dir() or not paint_weights.is_dir():
        raise ValueError("Model weights must be directories")
    if image.suffix.lower() not in {".png", ".jpg", ".jpeg", ".webp"}:
        raise ValueError("Reference image must be PNG, JPEG, or WebP")
    if min(shape_steps, octree, paint_steps, paint_resolution, texture_size) <= 0:
        raise ValueError("Generation settings must be positive")
    if output_dir.exists() and any(output_dir.iterdir()):
        raise FileExistsError(f"Output directory must be empty: {output_dir}")
    output_dir.mkdir(parents=True, exist_ok=True)
    reference = output_dir / f"reference{image.suffix.lower()}"
    shutil.copy2(image, reference)
    shape = output_dir / "shape.glb"
    textured = output_dir / "textured.glb"
    subprocess.run([
        str(runner), "shape", str(reference), "-o", str(shape),
        "--weights", str(shape_weights), "--steps", str(shape_steps),
        "--octree", str(octree), "--seed", str(seed),
    ], cwd=runner.parent, check=True)
    shape_report = inspect_glb(shape)
    if shape_report["errors"]:
        raise ValueError(f"Shape failed structural checks: {shape_report['errors']}")
    subprocess.run([
        str(runner), "paint", str(shape), str(reference), "-o", str(textured),
        "--weights", str(paint_weights), "--model", "pbr",
        "--res", str(paint_resolution), "--steps", str(paint_steps),
        "--tex", str(texture_size), "--no-superres",
    ], cwd=runner.parent, check=True)
    report = inspect_glb(textured, max_triangles=max_triangles,
                         max_embedded_texture_bytes=max_texture_bytes)
    if report["errors"] or report["untextured_materials"]:
        raise ValueError(f"Textured asset failed structural checks: {report}")
    metadata = {
        "stage": "generated-pbr-candidate", "reference_sha256": digest(reference),
        "shape_sha256": digest(shape), "shape_steps": shape_steps, "octree": octree,
        "seed": seed, "paint_steps": paint_steps, "paint_resolution": paint_resolution,
        "texture_size": texture_size, "shape_weights": str(shape_weights),
        "paint_weights": str(paint_weights), "runner": str(runner),
        "godot_review": False, "quest_review": False,
        "normal_map_present": not any("Missing normal texture" in error for error in
                                      inspect_glb(textured, require_pbr=True)["errors"]),
    }
    manifest = {"asset_id": asset_id, "reference": str(reference),
                "shape": str(shape), "textured": str(textured),
                "quality": report, "metadata": metadata}
    (output_dir / "generation.json").write_text(json.dumps(manifest, indent=2) + "\n")
    library = AssetLibrary(library_root)
    try:
        version = library.register(asset_id, textured, "mesh", "generated",
                                   license_name, source=str(reference),
                                   metadata=metadata, promote=False)
    finally:
        library.database.close()
    return {"version": version, "manifest": manifest}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("asset_id")
    parser.add_argument("image", type=Path)
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--shape-weights", type=Path, required=True)
    parser.add_argument("--paint-weights", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--library-root", type=Path, default=DEFAULT_LIBRARY)
    parser.add_argument("--license", required=True)
    parser.add_argument("--shape-steps", type=int, default=30)
    parser.add_argument("--octree", type=int, default=256)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--paint-steps", type=int, default=8)
    parser.add_argument("--paint-resolution", type=int, default=256)
    parser.add_argument("--texture-size", type=int, default=1024)
    parser.add_argument("--max-triangles", type=int)
    parser.add_argument("--max-texture-bytes", type=int)
    args = parser.parse_args()
    result = generate_candidate(
        asset_id=args.asset_id, image=args.image, runner=args.runner,
        shape_weights=args.shape_weights, paint_weights=args.paint_weights,
        output_dir=args.output_dir, library_root=args.library_root,
        license_name=args.license, shape_steps=args.shape_steps,
        octree=args.octree, seed=args.seed, paint_steps=args.paint_steps,
        paint_resolution=args.paint_resolution, texture_size=args.texture_size,
        max_triangles=args.max_triangles, max_texture_bytes=args.max_texture_bytes,
    )
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
