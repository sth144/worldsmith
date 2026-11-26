# Worldsmith

Worldsmith is a scene-agnostic 3D and VR editor. A user can walk through a loaded environment, place and modify assets with direct controls or natural language, and save changes to an authoritative scene store. The Godot client supports desktop and OpenXR on Android; the FastAPI server stores scenes, versions, and edit history.

**The application contains no default scene or asset catalog.** Scene geometry, reusable assets, previews, material settings, and spawn points are data supplied at runtime. The repository contains platform code, generic tools, documentation, and synthetic test fixtures. Runtime data belongs under `data/` or the ignored `client/assets/local/` preview area.

## Run

For a local connected scene, use one command:

```sh
./scripts/run_local.sh
```

It starts the local server if needed and opens the Worldsmith home screen. From there, create or import a scene, load one for editing, or run one with a registered 3D environment. You can pass a scene ID to preselect it: `./scripts/run_local.sh <scene_id>`. The home screen also manages reusable GLB imports, asset production requests, editing copies in Blender, and local connection settings. A scene plan saves a production brief; it does not yet generate a walkable 3D scene or assets. Actions that are not built yet stay visible on the home screen, dimmed and labelled, so it shows the remaining work.

On a Quest headset the same home screen appears on a floating panel. Point the right controller at it, pull the trigger to select, and tilt the right thumbstick to scroll. The headset can browse scenes and assets, open a scene to edit or run, and read a saved brief; creating, importing, planning, and settings need the desktop app. Inside a scene, the left controller's menu button returns home. To try the panel on the desktop with the mouse, run `./scripts/godot.sh --xr-mode off --path client -- --xr-home`.

Imported scene GLBs need walkable collision settings before normal navigation can be trusted. Imported mesh assets enter the versioned local library with visual review pending. **Create Asset** records a production request; asset geometry generation and review are still manual.

```sh
uv run --project server uvicorn app.main:app --host 127.0.0.1 --port 8765
./scripts/godot.sh --xr-mode off --path client
```

Create a scene with `POST /api/scenes` and a `scene_id`, then set that ID and the server URL in an ignored `client/server.json` (see `client/server.example.json`). For a connected scene, the client downloads its registered environment and presentation settings from `/api/scenes/<id>/package`; it does not need a local preview file. The inventory loads from `/api/assets?scene_id=<id>`.

For a local visual preview, export any `.blend` file with `scripts/preview_blend.sh <file.blend> <spawn_x,y,z> <settings.json>`. It writes a GLB and a matching ignored preview configuration, then opens that configuration in Godot. The optional settings file supplies collision mesh names, hidden meshes, shader materials and textures, a sky, and fill lights. Run a particular preview configuration with:

```sh
./scripts/godot.sh --xr-mode off --path client -- \
  --preview-config=res://assets/local/preview.json
```

The optional `--spawn=x,y,z` and `--preview-glb=res://...` arguments override the preview configuration. World units are meters and Godot/glTF use Y up. A scene without a registered environment has no walkable surface until one is supplied.

## Scene data

The server keeps each scene under `data/projects/<scene_id>/`. Its `scene.json` and `history.json` hold editable objects and undo/redo history. Assets live in that project's `assets/` directory. A `catalog.json` supplies the inventory entries, including display names and walkability; without it, the inventory is empty. Register a base GLB for scene export with:

```sh
python3 scripts/register_environment.py /absolute/path/to/environment.glb \
  --scene <scene_id> --settings /absolute/path/to/presentation.json
```

The scene's presentation data supplies spawn, collision mesh names, optional hidden meshes, sky, fog, and lights. It belongs in project data, not in application source. Connected clients check for a newly registered environment every 15 seconds. A project with no registered environment opens as an empty workspace.

For a new object absent from the catalog, the scene command defaults to **Reviewed asset**. It saves the request and viewed target for asset production; it does not insert a primitive stand-in. Choose **Quick draft shapes** when blockout geometry is useful. A promoted, Godot-reviewed library asset can fulfill the request as a versioned, undoable placement. See [asset-library.md](docs/asset-library.md) for that workflow. Automated high-quality asset generation from a prompt is still in development.

In a connected scene, open the scene command from the inventory and choose **Plan this scene** to turn a broad prompt into a saved production brief. The result lists the walkable layout, ground treatment, lighting, and reusable asset families. It is stored as `brief.json` in that scene's project data and can be read with `GET /api/scenes/<id>/brief`. Planning does not insert geometry; the listed assets still need production and review.

For preview collision and presentation settings, see [architecture.md](docs/architecture.md). The local versioned asset index and quality workflow are described in [asset-library.md](docs/asset-library.md) and [asset-quality.md](docs/asset-quality.md). The [Worldsmith scene skill](.agents/skills/worldsmith-scenes/SKILL.md) guides Codex when authoring different kinds of scenes. [Quest deployment](docs/quest-deployment.md) covers headset setup.

## Verification

```sh
server/.venv/bin/pytest server/tests
./scripts/godot.sh --headless --xr-mode off --editor --path client --quit
```

The test assets are synthetic fixtures under `server/tests/fixtures/` and `client/tests/fixtures/`; they are not an application catalog. A local Blender installation is needed for export tests. Quest visual quality and frame time require headset testing.

## License

MIT.
