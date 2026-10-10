# Worldsmith

Worldsmith is an open-source, self-hosted VR environment editor for Meta Quest 3. The intended experience is to edit an environment while standing inside it. This repository currently contains **Milestone 1: the scene viewer**. Object editing, persistence, a scene server, and AI editing are planned but are not implemented yet.

## Milestone 1

The Godot 4.6 client imports an original sample GLB hall, runs in desktop debug mode, and uses OpenXR on Android. The sample has a 16 × 16 meter floor, boundary walls, a table, and display objects. Godot collision bodies cover the floor, walls, and table. World scale is one Godot unit per meter, with Y up.

| Mode | Controls |
| --- | --- |
| Desktop | WASD move, mouse look, hold right mouse to aim at the floor and release to teleport, Escape releases the mouse, left click captures it again. |
| Quest 3 | Right controller trigger aims and teleports on release. X on the left controller toggles smooth locomotion; when enabled, the left thumbstick moves in the direction of your gaze. Physical room movement remains available. |

The green sphere marks a valid floor hit. The small in-headset status label shows the smooth locomotion setting.

## Run on a desktop

From the repository root, run:

```sh
./scripts/godot.sh --editor --path client
./scripts/godot.sh --xr-mode off --path client
```

The launcher uses an existing Godot executable when available. On macOS, if none is installed, it downloads the pinned Godot 4.6.3 release into your user cache and verifies its SHA-256 checksum. On Linux, install a compatible Godot 4.6 release or set `WORLDSMITH_GODOT` to its executable. `--xr-mode off` prevents a desktop without an OpenXR runtime from waiting for a headset. For a nonvisual startup check:

```sh
./scripts/godot.sh --headless --xr-mode off --path client --quit-after 2
./scripts/godot.sh --headless --xr-mode off --path client --script res://tests/smoke.gd -- --no-preview
```

## Preview a Blender scene

For a local `.blend` file, run:

```sh
./scripts/preview_blend.sh /path/to/scene.blend "-13,23.5,10"
```

The optional second argument is the player spawn in Godot `(X,Y,Z)` meters. Blender uses Z up; the GLB exporter maps `(Blender X,Y,Z)` to `(Godot X,Z,-Y)`. Choose a point on a walkable surface. The command exports renderable objects to `client/assets/local/`, imports the GLB, and starts desktop mode. It does not save or modify the `.blend`. The GLB and local preview setting are gitignored. Subsequent desktop runs use that preview; remove `client/assets/local/preview.json` to return to the sample hall.

The preview builds basic collision from meshes named like `Grid`, `Paving`, `Floor`, `Road`, `Deck`, `Wall`, or `Door`. Other meshes remain visual only. To better match Blender, the exporter bakes procedural base colors into textures, applies visible modifiers, and turns repeated Geometry Nodes meshes into Godot `MultiMesh` instances. Procedural bump/roughness, shader-specific effects, and Blender lighting can still differ. The [Blender glTF documentation](https://docs.blender.org/manual/en/5.1/addons/import_export/scene_gltf2.html) describes the format's material and mesh limits.

If you export the Quest APK while a local preview is active, the preview GLB and setting are included in that local build. A large Blender environment may need mesh and draw-call optimization before it can meet the Quest frame-rate target.

## Deploy to Quest 3

Set up [Godot Android export](https://docs.godotengine.org/en/4.6/tutorials/export/exporting_for_android.html): OpenJDK 17, Android SDK, Godot export templates, and SDK/JDK paths in Godot Editor Settings. Enable Developer Mode on the Quest and connect it via USB so `adb devices` lists it.

The checked-in `Quest 3` Android preset selects OpenXR and arm64. Godot 4.6 includes the Khronos Android OpenXR loader, so a vendor plugin is not required for this basic viewer. Configure a debug keystore if Godot asks for one. See the [Quest export guide](docs/quest-deployment.md) for the exact checklist and build commands.

After the preset is saved:

```sh
mkdir -p build
(cd client && ../scripts/godot.sh --headless --export-debug "Quest 3" ../build/worldsmith.apk)
adb install -r build/worldsmith.apk
```

Launch **Worldsmith** from the Quest's app library. Godot's one-click deploy is also available from the editor once the headset is connected.

## Project layout

```text
client/                  Godot viewer and imported sample GLB
scripts/generate_sample.py  Blender source for the sample GLB
docs/                    design notes and deployment instructions
```

The committed GLB can be regenerated with `blender --background --python scripts/generate_sample.py`. To inspect another GLB in this milestone, copy it into `client/assets/` and change the `SampleHall` external resource in `client/scenes/main.tscn`. Collision bodies are authored separately and need adjustment for a different environment.

The roadmap and decisions are in [docs/architecture.md](docs/architecture.md). Changes are recorded in [CHANGELOG.md](CHANGELOG.md).

## License

MIT. The sample environment is generated in this repository and has no external asset dependency.
