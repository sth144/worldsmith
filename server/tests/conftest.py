"""Use synthetic scene data only in server tests."""

from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def scene_fixture(monkeypatch):
    monkeypatch.setenv("WORLDSMITH_SCENE_SEED", str(Path(__file__).parent / "fixtures" / "scene"))
    monkeypatch.setenv("WORLDSMITH_INITIAL_SCENE_ID", "demo")
