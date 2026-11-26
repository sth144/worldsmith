from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from asset_library import AssetLibrary


def test_library_keeps_immutable_versions_and_verifies_blobs(tmp_path):
    library = AssetLibrary(tmp_path / "library")
    source = tmp_path / "asset.glb"
    source.write_bytes(b"first version")
    first = library.register("own_tree", source, "mesh", "authored", "MIT")
    source.write_bytes(b"second version")
    second = library.register("own_tree", source, "mesh", "authored", "MIT")
    assert first["sha256"] != second["sha256"]
    assert Path(first["blob"]).read_bytes() == b"first version"
    assert Path(second["blob"]).read_bytes() == b"second version"
    assert library.get("own_tree")["sha256"] == second["sha256"]
    assert library.verify("own_tree")


def test_candidate_needs_explicit_promotion(tmp_path):
    library = AssetLibrary(tmp_path / "library")
    source = tmp_path / "asset.glb"
    source.write_bytes(b"reviewed")
    reviewed = library.register("own_asset", source, "mesh", "authored", "MIT")
    source.write_bytes(b"candidate")
    candidate = library.register("own_asset", source, "mesh", "generated", "MIT", promote=False)
    assert library.get("own_asset")["sha256"] == reviewed["sha256"]
    assert library.version("own_asset", candidate["sha256"])["origin"] == "generated"
    library.promote("own_asset", candidate["sha256"])
    assert library.get("own_asset")["sha256"] == candidate["sha256"]
