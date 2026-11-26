---
name: worldsmith-scenes
description: Create or substantially improve walkable Blender scenes for Worldsmith, including reusable assets, Godot previews, and VR-ready exports. Use for scene authoring and visual quality work in this repository.
---

# Worldsmith scene authoring

Build scenes that hold up from a walker's eye level and remain editable through Worldsmith. Treat screenshots and reference art as a visual target, then inspect the result at similar framing and at close range. A clean export is only a technical check; it does not establish visual quality.

## Scene and asset choices

- Establish the scene's mood, scale, walkable routes, focal points, and which objects users may edit. Work from the user's references; use judgment for unspecified details.
- Prefer reusable, project-created assets with editable Blender source or generation code. Record generated, authored, captured, and external origins accurately. An external asset can be a benchmark or a needed component, but record its license and source.
- Build assets with distinctive silhouettes and material detail. Do not make a scene look varied by merely scaling or rotating identical hero geometry. Use separate source designs for repeated prominent forms such as trees and buildings.
- Give terrain real elevation, tiled material layers, blend masks, and close-range geometry. A large color image spread across one mesh reads as a flat photograph. Use deliberate paths and physical details such as roots, plants, debris, and rocks only when their individual assets meet the visual target.
- Use PBR textures that survive glTF export. Check color, normal, roughness, transparency, and UV behavior in Godot. Blender-only procedural nodes need a bake or a corresponding Godot shader.
- Plan distinct desktop and Quest budgets. Keep collision simpler than visual meshes and verify headset performance before calling an asset VR-ready.
- For prompt-created scenes, write a scene-specific production brief outside shared code: reference views, intended camera-height look, modular asset list, interaction map, and per-device budgets. Model prominent objects individually from clean references; select silhouette and topology before UV/texture work. Register only assets that survive close inspection in the actual client.
- Build foliage as a family of distinct forms with controlled atlas/LOD/wind behavior, not a field of duplicated spikes. Use tiled PBR on broad surfaces and separate physical geometry for depth. Finish atmosphere in Godot and compare fixed-camera runtime captures with the visual target; inspect motion and eye-level views before accepting the scene.
- Keep cinematic and offline renders as references. A scripted video or Cycles still is not evidence of real-time, editable, or headset quality. Do not promote generated assets with baked lighting, texture speckling, broken topology, or absent required material maps merely because the export passes structural checks.

## Local-first asset production

- Start with an original, isolated reference that clearly shows the asset's silhouette, separable parts, surface wear, and plausible back/side construction. Keep the image prompt and source alongside the asset data.
- Use local image-to-3D shape and paint tools as candidate makers, not as an automatic final stage. Generate a few shape seeds and inspect untextured front, side, and three-quarter views before spending time on UVs and paint. Fine relief in an image may disappear in reconstruction; a studio backdrop may attach to the mesh and need deliberate removal.
- On the M4 workstation, use the proven modest paint settings first and watch memory and elapsed time. A larger paint resolution can stall rather than improve a model. Stop a stalled run and record the settings and failure in the asset's working notes.
- For important assets, consider rebuilding separable parts in Blender with authored geometry and dedicated stone, wood, metal, fabric, or foliage materials. Use physical relief and material-specific PBR maps to carry detail at eye level. A generic color texture on a single mesh cannot replace a readable silhouette or clean material boundaries.
- Compare the best generated candidate and authored candidate at the same camera in Blender and Godot. Preserve the stronger visual traits of each. Denoising is an experiment, not a universal repair: reject a result if it erases the wear, carving, or color variation that made the reference compelling.
- Keep the intact high-detail mesh as the source of truth. Test each derived LOD with a neutral material and with its final materials in the real-time renderer. Aggressive decimation can produce tiny holes and fragmented shading that resemble texture speckles; diagnose the geometry before repainting or filtering the albedo.
- Keep the build recipe and inputs in the asset's data directory and register only a client-reviewed export. Do not make third-party generators or downloaded stock assets a prerequisite for the default workflow.

## Project handoff

1. Preserve the existing Blender scene and user edits. When command-line Blender hangs or crashes, use the connected live Blender session in small, inspectable steps.
2. Save reproducible source and previews. Register accepted assets and scene versions with `scripts/asset_library.py`; keep immutable hashes and provenance so saved scene references remain stable.
3. Export a GLB and run `scripts/check_glb_quality.py` with the relevant checks. Import it into Godot and inspect the actual walkable view, including material parity, collision, visual repetition, and performance. Fix visible failures before promoting an asset to the reusable library.
4. Show the user the current render or Godot view and state what still misses the reference. Do not describe a sparse technical PoC as a finished high-quality scene.

Read `docs/asset-library.md` and `docs/asset-quality.md` for the platform's asset and visual acceptance rules. Treat each scene's references, source files, catalog, and preview settings as external project data. Do not introduce scene names, asset IDs, or visual presets into application code or shared documentation.
