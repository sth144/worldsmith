import json
from pathlib import Path
import sys

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from asset_library import AssetLibrary
from generate_local_asset import generate_candidate
from test_glb_quality import write_glb


def test_generation_registers_only_a_structurally_reviewable_candidate(tmp_path, monkeypatch):
    image = tmp_path / "reference.png"
    image.write_bytes(b"reference")
    runner = tmp_path / "runner"
    runner.write_text("runner")
    shape_weights = tmp_path / "shape-weights"
    paint_weights = tmp_path / "paint-weights"
    shape_weights.mkdir()
    paint_weights.mkdir()
    calls = []

    def run(command, **kwargs):
        calls.append(command)
        output = Path(command[command.index("-o") + 1])
        if command[1] == "shape":
            write_glb(output, {"meshes": [], "nodes": []})
        else:
            write_glb(output, {
                "materials": [{"pbrMetallicRoughness": {
                    "baseColorTexture": {"index": 0},
                    "metallicRoughnessTexture": {"index": 1},
                }}],
                "meshes": [{"primitives": [{"material": 0}]}],
                "nodes": [{"mesh": 0}],
            })

    monkeypatch.setattr("generate_local_asset.subprocess.run", run)
    result = generate_candidate(
        asset_id="asset_a", image=image, runner=runner,
        shape_weights=shape_weights, paint_weights=paint_weights,
        output_dir=tmp_path / "output", library_root=tmp_path / "library",
        license_name="Model terms", max_triangles=100,
    )
    assert [call[1] for call in calls] == ["shape", "paint"]
    assert result["version"]["metadata"]["godot_review"] is False
    assert result["version"]["metadata"]["normal_map_present"] is False
    assert json.loads((tmp_path / "output" / "generation.json").read_text())["quality"]["errors"] == []
    library = AssetLibrary(tmp_path / "library")
    assert library.version("asset_a", result["version"]["sha256"])
    with pytest.raises(KeyError):
        library.get("asset_a")
    library.database.close()


def test_generation_rejects_bad_asset_id_before_running(tmp_path):
    with pytest.raises(ValueError, match="Asset ID"):
        generate_candidate(
            asset_id="Scene Name", image=tmp_path / "missing.png",
            runner=tmp_path / "missing", shape_weights=tmp_path,
            paint_weights=tmp_path, output_dir=tmp_path / "output",
            library_root=tmp_path / "library", license_name="Model terms",
        )
