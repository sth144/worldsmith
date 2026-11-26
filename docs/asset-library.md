# Reusable asset library

Worldsmith's asset library is independent of the currently loaded scene. `scripts/asset_library.py` keeps metadata in `data/library/library.sqlite3` and immutable, content-addressed files in `data/library/blobs/`. Both locations are runtime data and are ignored by Git. Registering a new hash under an asset ID preserves earlier versions; `verify` checks a stored blob against its SHA-256.

```sh
python3 scripts/asset_library.py register <asset-id> /absolute/path/to/asset.glb \
  --kind mesh --origin authored --license <license> --source <source>
python3 scripts/asset_library.py list
python3 scripts/asset_library.py verify <asset-id>
```

Generated or revised assets can be stored as candidates without changing the current library version:

```sh
python3 scripts/asset_library.py register <asset-id> /absolute/path/to/candidate.glb \
  --kind mesh --origin generated --license <license> --candidate
python3 scripts/asset_library.py promote <asset-id> <sha256-from-register-output>
```

Promote a candidate after visual review in Godot and any device-budget checks. The earlier version stays available by hash.

For a local image-to-mesh runner with `shape` and `paint` commands, the generic pipeline runs both stages, records their inputs and output checksums, checks the textured GLB, and registers it as a candidate:

```sh
python3 scripts/generate_local_asset.py <asset-id> /absolute/path/to/reference.png \
  --runner /absolute/path/to/runner \
  --shape-weights /absolute/path/to/shape-weights \
  --paint-weights /absolute/path/to/paint-weights \
  --output-dir /absolute/path/to/empty-output-directory \
  --license '<model-weights-license>'
```

The reference image can be authored or generated for any asset brief. The command does not create a scene or approve its output. Inspect the generated object from several angles, clean up geometry and textures in Blender, create appropriate LODs and collision, then review it in Godot before promotion. The runner and weights remain local data supplied by the operator; a new output directory prevents accidental overwrite of earlier candidates.

The library records kind, origin, license, attribution, hash, and metadata. Use `authored`, `generated`, `captured`, and `external` origins accurately. Prefer assets with editable source and distinct desktop and headset exports. Keep external reference assets traceable to their source and terms. Scene objects should reference an immutable version so improving the library does not silently change a saved world.

A scene's placement catalog is separate: `data/projects/<scene_id>/catalog.json` selects which project GLBs appear in the inventory. Its `assets` object maps GLB stem IDs to `name` and optional `walkable` metadata. The client downloads those assets and builds inventory pages at runtime. A library entry is not automatically placed in every scene.

## Reviewed creation requests and the queue

The client defaults to **Reviewed asset** when a prompt requests an object absent from the scene catalog. The server saves the prompt and the viewed point as a scene request with status `needs_asset`; it does not generate primitive geometry or change the scene. **Quick draft shapes** remains an explicit client option. Existing catalog assets can still be placed immediately.

Saved requests form a queue that a person or an agent works through:

```sh
python3 scripts/request_queue.py list
python3 scripts/request_queue.py claim <scene-id> <request-id> --note "Building in Blender"
python3 scripts/request_queue.py fulfil <scene-id> <request-id> <library-asset-id> --name "Display name"
python3 scripts/request_queue.py fail <scene-id> <request-id> --note "Why it could not be made"
```

A request is `needs_asset` while it waits, `in_progress` once claimed, then `complete` or `failed`. The home screen lists a scene's unplaced requests, and the in-scene status line counts those waiting or being built. `GET /api/requests` returns the queue across all scenes.

Fulfilling needs a promoted GLB mesh registered with `--metadata '{"godot_review":true}'`. The server checks its content hash, copies that version into the project, adds it to the scene's catalog, and places it at the requested point as one undoable edit. A request stores a point in the world, so it stays valid when the scene is edited after it was made.

The [request queue skill](../.agents/skills/worldsmith-requests/SKILL.md) gives an agent the full procedure: build in Blender, check the structure, review captures in Godot, register, and place. Nothing starts that agent automatically, and its Godot review is the only quality check, so its review note should state the asset's faults. Requests made from the home screen's Asset library tab are a separate list and are not part of this queue.

## Quality acceptance

Review assets close up, at eye level, and in their intended composition. Silhouette, geometry, textures, lighting, and repetition all matter. Terrain needs material scale appropriate to a walker, blend masks, physical elevation, and close-range objects where the design calls for them. A single large color image cannot provide that depth. Export materials through glTF-compatible PBR maps or a scene-supplied Godot shader. Run `scripts/check_glb_quality.py` for structural problems, then inspect the scene in Godot; automated checks cannot judge whether an asset looks convincing.

Keep collision simpler than visual geometry. Measure mesh count, triangle count, draw calls, texture memory, and frame time on each target device before promoting an asset as headset-ready. Save preview images and editable source alongside the library metadata so the result can be reviewed and rebuilt.

## Splat assets

Treat Gaussian splats as a source type rather than ordinary GLB meshes. Import a capture as an immutable `splat_source`, record its scale, coordinates, checksum, license, and provenance, then save cleanup steps as non-destructive versions. Cleanup may crop, orient, remove floaters, adjust opacity, and segment reusable objects. A cleaned splat can be a visual asset; walkability needs separate collision geometry. Mesh extraction and PBR baking should be explicit conversions for objects that need conventional edits or broad device support. Benchmark desktop and headset renderers separately before enabling splats in a scene.

[Nerfstudio documents PLY export for Splatfacto](https://docs.nerf.studio/nerfology/methods/splat.html). [Blender's developer update](https://code.blender.org/2026/10/splatting-the-gaussians-into-blender/) describes native splat work. Neither by itself establishes the Worldsmith runtime or headset performance path.
