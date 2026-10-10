# Worldsmith

Worldsmith is an open-source, self-hosted VR environment editor for Meta Quest 3. The intended experience is to edit an environment while standing inside it. The repository includes a desktop-testable M1–M6 vertical slice: viewing, object editing, persistence, natural-language operations, approved mesh changes, and portable GLB export. The new M4–M6 headset controls still need a Quest check.

## Milestone 1

The Godot 4.6 client imports an original sample GLB hall, runs in desktop debug mode, and uses OpenXR on Android. The sample has a 16 × 16 meter floor, boundary walls, a table, and display objects. Godot collision bodies cover the floor, walls, and table. World scale is one Godot unit per meter, with Y up.

| Mode | Controls |
| --- | --- |
| Desktop | WASD moves; arrow keys turn and tilt the view. Hold Shift to move twice as fast. Mouse look remains available. Hold right mouse to aim at the floor and release to teleport; Escape releases the mouse, and left click captures it again. |
| Quest 3 | The left thumbstick walks in the direction of your gaze immediately. X toggles walking on or off. The right controller trigger aims and teleports on release. Physical room movement remains available. |

The green sphere marks a valid floor hit. The small in-headset status label shows the smooth locomotion setting.

## Milestone 2: object editing

Open the inventory, choose one of four sample assets, aim at a floor, and place it. A translucent preview shows the landing spot. Aim at a placed object to select it; the yellow outline marks your selection. The inventory also has Move, Rotate, Grow, Shrink, Duplicate, Delete, Undo, and Redo actions. Placement, transforms, and deletion are kept in a local undo stack. Objects have stable UUIDs for the future scene server.

| Mode | Editing controls |
| --- | --- |
| Desktop | Tab opens the inventory. Click an asset, aim at a floor, then left click to place. Left click a placed object to select it. G moves the selection to a new floor point; left click confirms. R rotates 15°; Shift+R rotates the other way. `+` and `-` scale it. Delete removes it. Ctrl/Cmd+D duplicates, Ctrl/Cmd+Z undoes, and Ctrl/Cmd+Y or Ctrl/Cmd+Shift+Z redoes. Escape or right click cancels a placement or move. |
| Quest 3 | Y opens the spatial inventory. Point the right controller at a row and press its trigger. Point at the floor and press the trigger to place. Point at an object and press the trigger to select it. Hold the right grip on an object to move it; release over a floor to place it. Select an object and use the inventory for rotation, scale, duplication, deletion, undo, and redo. |

The Quest editing controls are implemented but await a headset check.

## Milestone 3: persistent scenes

The Python scene server is authoritative. It stores a JSON scene snapshot and a separate undo history under the ignored `data/projects/` directory. Edits are validated against a scene revision, written atomically, and sent to connected clients as small WebSocket deltas. The Godot client applies an edit immediately, queues it while offline, and reconciles it with the server after reconnecting. Keep the app open until its status says **Saved r…**; queued edits are held in memory and are lost if the app exits before reconnecting.

Start the server from the repository root:

```sh
uv sync --project server --extra dev
uv run --project server uvicorn app.main:app --host 0.0.0.0 --port 8765
```

Then start the desktop client with the command below. It connects to `ws://127.0.0.1:8765` and scene `demo` by default; an optional `client/server.json` overrides the address. You can also pass `-- --server-url=ws://127.0.0.1:8765` after the Godot command. Place an object, wait for **Saved**, exit, and launch the client again to see it restored. The server keeps running independently of the client. The demo's base environment remains a bundled GLB; the JSON scene contains the editable placed objects.

For Quest, the server and headset must be on the same trusted Wi-Fi network. Find the computer's LAN IP, copy `client/server.example.json` to ignored `client/server.json`, and replace its example IP. Rebuild the APK so that configuration is included. The Android preset enables `INTERNET`. Do not expose this unauthenticated service outside a trusted LAN.

Available endpoints include `GET /api/scenes/demo`, `POST /api/scenes`, `POST /api/scenes/demo/operations`, `GET /api/scenes/demo/history`, `POST /api/scenes/demo/undo`, `POST /api/scenes/demo/redo`, `GET /api/assets`, `GET /api/assets/chair`, and `WS /ws/scenes/demo`. `http://127.0.0.1:8765/docs` shows request schemas. Supported operations are add, delete, transform, visibility, material color, asset replacement, and duplication. All writes require the current revision. Runtime scene data under `data/` is gitignored, so personal edits are not pushed with source code.

## Milestones 4–6: AI, geometry, and export

Open the inventory and choose **Ask AI…**. A selected object is the edit target; otherwise the app captures the placed object under your crosshair. For a description such as “get rid of the red chair,” the server checks visible placed objects' asset types and saved colors, so an overlapping brown chair is left alone. Requests such as “make this chair twice as wide,” “paint it red,” “get rid of this chair,” “hide it,” and “duplicate it” use deterministic local planning. Other requests use the installed, authenticated Codex CLI with a read-only sandbox and structured JSON output. Those requests send the prompt and scene graph to Codex. The server checks proposed operations and object IDs, then commits through the same revision-checked scene store. An AI request waits until pending edits are saved; the client shows progress and errors without freezing rendering. **View AI output** in the inventory shows the structured operations, planner source, HTTP response, and any error. Direct requests show `local` as their planner because they did not call an LLM.

Color requests can name an imported material. For the sample chair, “turn the upholstery red” changes only the `Sea green fabric` material and restores the wood if a previous whole-object tint was applied. Other named-part requests use the selected asset's material names; the server rejects names the GLB does not contain. Scene export preserves these targeted colors.

You can also place objects by describing a point in view. Look down at a floor spot, open the inventory, and choose **Ask AI…**. Try “Put a hill over here with a tree on it.” The client captures the floor point when the inventory opens; the server places a walkable hill and a tree together as one saved, undoable edit. Simple “put a tree/chair/table/planter/lantern/hill here” requests also work locally. Other arrangements go through Codex, which can choose from those six existing assets and place them within five meters of the viewed point. Placement requests use the floor point even if a placed object is under the crosshair. If no floor point is under your gaze, close the inventory, look down, and reopen it. The view prompt cannot yet remodel an arbitrary part of the imported merchant GLB. For that, the base environment needs individually addressable meshes or a terrain editing workflow.

“Round the corners,” “make this taller,” and “cut a doorway/opening” create **geometry proposals** for one selected placed object. The scene stays unchanged until you choose **Approve mesh edit** in the inventory. The server runs a fixed Blender script against a copy of that object's GLB, keeps the original asset, registers a versioned GLB, and replaces the scene reference. Undo restores the old asset. The client downloads new versions at runtime. This initial geometry worker uses fixed operations and does not execute arbitrary agent-written Python; geometry work is limited to the selected asset, and openings are centered automatically. Base-environment meshes are not individually selectable yet. The server and Blender run on the local computer; the Quest only receives resulting assets and scene deltas.

The server registers the sample hall as its default base environment. To export your current local merchant preview instead, register its GLB and instance sidecars from the repo root:

```sh
uv run --project server python scripts/register_environment.py client/assets/local/merchant.glb
```

Registration copies the GLB and any Geometry Nodes instance data into ignored server data. It leaves `merchant.blend` untouched. Download the combined scene and its source manifest:

```sh
curl -o worldsmith-scene.glb http://127.0.0.1:8765/api/scenes/demo/export
curl -o worldsmith-manifest.json http://127.0.0.1:8765/api/scenes/demo/manifest
```

The export includes the registered environment, all visible placed objects, versioned geometry, transforms, material-color overrides, and preview instance geometry. Blender can import the GLB. Export makes a portable copy; it does not edit or reconstruct the original `.blend` project. The imported scene may be large, especially with thousands of grass instances.

The scene service is intentionally LAN-only and has no authentication. Run one Uvicorn worker. `blender` must be on `PATH` for mesh changes and export; Codex CLI is needed only for requests outside the direct planner's patterns. The fixed geometry worker copies inputs to a temporary work directory, starts Blender with factory settings and auto-execution disabled, and limits execution time. It does not provide a hardened operating-system sandbox for future generated scripts; arbitrary script generation stays disabled.

## Run on a desktop

From the repository root, run:

```sh
./scripts/godot.sh --editor --path client
./scripts/godot.sh --xr-mode off --path client
```

The launcher uses an existing Godot executable when available. On macOS, if none is installed, it downloads the pinned Godot 4.6.3 release into your user cache and verifies its SHA-256 checksum. On Linux, install a compatible Godot 4.6 release or set `WORLDSMITH_GODOT` to its executable. `--xr-mode off` prevents a desktop without an OpenXR runtime from waiting for a headset. For a nonvisual startup check:

```sh
./scripts/godot.sh --headless --xr-mode off --path client --quit-after 2
./scripts/godot.sh --headless --xr-mode off --path client --script res://tests/smoke.gd -- --no-preview --offline
./scripts/godot.sh --headless --xr-mode off --path client --script res://tests/editing.gd -- --no-preview --offline
./scripts/godot.sh --headless --xr-mode off --path client --script res://tests/view_placement.gd -- --no-preview --offline
uv run --project server pytest -q server/tests
```

The client/server view-prompt integration check is `client/tests/view_flow.gd`; run it against a fresh demo scene on a test server using `--server-url`.

## Preview a Blender scene

For a local `.blend` file, run:

```sh
./scripts/preview_blend.sh /path/to/scene.blend "-13,23.5,10"
```

The optional second argument is the player spawn in Godot `(X,Y,Z)` meters. Blender uses Z up; the GLB exporter maps `(Blender X,Y,Z)` to `(Godot X,Z,-Y)`. Choose a point on a walkable surface. The command exports renderable objects to `client/assets/local/`, imports the GLB, and starts desktop mode. It does not save or modify the `.blend`. The GLB and local preview setting are gitignored. Subsequent desktop runs use that preview; remove `client/assets/local/preview.json` to return to the sample hall.

The preview builds basic collision from meshes named like `Grid`, `Paving`, `Floor`, `Road`, `Deck`, `Stoop`, `Stair`, `Wall`, `Column`, or `Pillar`. Door frames and leaves remain visual so entrances can be traversed; the merchant preview hides its closed gate leaves and hardware. Step-up movement lets the player walk onto raised stoops and climb stairs. Other meshes remain visual only. To better match Blender, the exporter bakes procedural base colors into textures, applies visible modifiers, and turns repeated Geometry Nodes meshes into Godot `MultiMesh` instances. The viewer uses contact shading and fill lighting to reveal surface boundaries; the merchant preview adds local interior lights without changing the GLB. Procedural bump/roughness, shader-specific effects, and Blender lighting can still differ. The [Blender glTF documentation](https://docs.blender.org/manual/en/5.1/addons/import_export/scene_gltf2.html) describes the format's material and mesh limits.

If you export the Quest APK while a local preview is active, the preview GLB and setting are included in that local build. A large Blender environment may need mesh and draw-call optimization before it can meet the Quest frame-rate target.

## Deploy to Quest 3

Set up [Godot Android export](https://docs.godotengine.org/en/4.6/tutorials/export/exporting_for_android.html): OpenJDK 17, Android SDK, Godot export templates, and SDK/JDK paths in Godot Editor Settings. Enable Developer Mode on the Quest and connect it via USB so `adb devices` lists it.

The checked-in `Quest 3` Android preset selects OpenXR, arm64, and Gradle Build. Godot 4.6 includes the Khronos Android OpenXR loader in Gradle builds, so a vendor plugin is not required for this basic viewer. Configure a debug keystore if Godot asks for one. See the [Quest export guide](docs/quest-deployment.md) for the exact checklist and build commands.

After the preset is saved:

```sh
mkdir -p build
(cd client && ../scripts/godot.sh --headless --install-android-build-template --export-debug "Quest 3" ../build/worldsmith.apk)
adb install -r build/worldsmith.apk
```

Launch **Worldsmith** from the Quest's app library. Godot's one-click deploy is also available from the editor once the headset is connected.

## Project layout

```text
client/                        Godot VR editor, scene, and committed GLBs
server/                        FastAPI scene server and tests
projects/demo/                 Initial demo scene and catalog assets
data/projects/                 Local runtime scenes and history (gitignored)
scripts/generate_sample.py     Blender source for the sample hall
scripts/generate_edit_assets.py Blender source for the four inventory props
docs/                          design notes and deployment instructions
```

The committed GLBs can be regenerated with `blender --background --python scripts/generate_sample.py` and `blender --background --python scripts/generate_edit_assets.py`. To inspect another environment, use the local Blender preview command above. Collision bodies for arbitrary scenes may need adjustment.

The roadmap and decisions are in [docs/architecture.md](docs/architecture.md). Changes are recorded in [CHANGELOG.md](CHANGELOG.md).

## License

MIT. The sample environment is generated in this repository and has no external asset dependency.
