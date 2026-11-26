# Visual asset quality

A scene should be judged from the player's eye level in the actual Godot renderer. A good isolated model does not guarantee a convincing environment: material scale, terrain depth, distinct silhouettes, contact shadows, lighting, composition, and performance need to work together. Use the user's references to set an art direction for each scene rather than applying one style to every project.

Capture a reproducible desktop view from any ignored local preview configuration with the real client renderer:

```sh
./scripts/godot.sh --xr-mode off --path client \
  --script res://tools/capture_preview.gd -- \
  --preview-config=res://assets/local/<preview>.json \
  --output=/absolute/path/to/review.png \
  --camera-position=0,1.8,4
```

Vary `--camera-position`, `--yaw-deg`, and `--pitch-deg` to inspect close and distant views. The capture tool uses the same environment and materials as the desktop client. It is a visual review artifact, not proof of headset performance or scene quality by itself.

For isolated asset review, import a GLB into the local Godot project and capture it with a fixed neutral stage:

```sh
./scripts/godot.sh --xr-mode off --path client \
  --script res://tools/capture_asset.gd -- \
  --asset=res://assets/local/<asset>.glb \
  --output=/absolute/path/to/asset-review.png
```

Use the GPU renderer for image capture; `--headless` selects a dummy renderer on this workstation. Compare the source mesh, each LOD, and material variants under identical settings. If a defect remains with a single opaque material and shadows disabled, investigate topology and normals before altering textures. If it disappears only when shadows are disabled, inspect shadow settings and mesh surfaces. A clean studio capture is still followed by an eye-level client review.

## Source and export

Keep editable Blender source or reproducible generation code for authored assets. Bake Blender-only procedural color, roughness, and normal detail before glTF export, or supply a corresponding Godot shader in the scene's preview data. Check alpha-cutout foliage, UVs, texture repetition, and material slots after Godot import. `scripts/export_preview.py` handles general Blender preview baking and repeated instance transforms. `scripts/check_glb_quality.py` catches structural export failures; visual review remains required.

Terrain materials usually tile at a close-range scale and blend through masks. Height changes belong in mesh geometry when they affect silhouette, collision, or shadows. Ground cover and props should be real, reusable assets with credible shapes; density alone cannot make weak assets look better. Prominent repeated objects need independent source designs or convincing structural variation.

## Device budgets

Maintain separately reviewed desktop and headset exports. Record triangle and draw-call counts, texture memory, collision proxy, and LODs. Do not infer headset readiness from a desktop render. Test frame time and comfort on the target headset, especially for alpha foliage, splats, complex shaders, and large scenes.

## Production loop for a new scene

1. Turn the prompt into a scene brief: camera-height references, art direction, route and interaction map, asset list, and desktop/headset budgets. Keep this brief with the scene data, not in application code.
2. Produce each prominent asset from its own clean, evenly lit reference views. Generate multiple shape candidates when necessary. Preserve a high-detail source, then derive lower-detail meshes and bake or transfer materials as needed. Review every LOD in Godot at close range before accepting it; a triangle target alone cannot establish that thin parts, UVs, normals, and shadows survived reduction.
3. Keep a reusable Blender source and asset record for each accepted model. A generated GLB is a candidate, not a library asset. Inspect close views for holes, warped topology, painted shadows, speckling, material seams, and recognizable repetition. Reject or repair failures.
4. Build the environment from modular, varied assets. Use tileable PBR layers on large surfaces, separate geometry where terrain must cast shadows or alter collision, and authored foliage families with believable leaf/blade form, normal response, LODs, and wind where the target supports it.
5. Finish lighting, fog, exposure, color, and effects in the runtime. Render fixed-camera screenshots from the actual walkable client, compare them with a target image, then inspect at eye level while moving. Review improvements blind when possible; a cinematic still or offline render is not proof of runtime quality.
6. Run structural, desktop performance, and headset performance checks independently. Preserve a low-cost fallback for prototyping, but do not silently substitute it for a requested high-quality asset.

This sequence is supported by creator-reported workflows on r/TopologyAI: [modular architecture, tiled PBR, and Unreal atmosphere](https://www.reddit.com/r/TopologyAI/comments/1w0su7r/i_built_an_optimized_dark_fantasy_environment_in/); [geometry selection before texturing](https://www.reddit.com/r/TopologyAI/comments/1y5bo90/how_to_generate_clean_optimized_3d_models_with_ai/); [plant parts, atlases, LODs, and wind](https://www.reddit.com/r/TopologyAI/comments/1y1xp6n/i_built_a_workflow_that_turns_photos_into/); and [same-camera visual iteration with independent review](https://www.reddit.com/r/TopologyAI/comments/1y5gztw/dark_souls_inspired_game_in_3_days_with_threejs/). These are self-reported examples, not controlled benchmarks. The separate [Blender short workflow](https://www.reddit.com/r/TopologyAI/comments/1y5ihd4/i_directed_a_blender_short_with_gpt_astra_62/) used photographic references, scripted Blender geometry, Cycles rendering, and post-production to make a film; its look is a useful art target, but its render path and frame budget differ from an editable VR scene.

## Splat imports

Treat an imported splat as a visual source or background layer until it has been segmented, cleaned, and given explicit geometry and collision. Keep source provenance and derived mesh versions. A scene made of [separate editable meshes with a splat environment](https://www.reddit.com/r/TopologyAI/comments/1x0ps5b/imagetoscene_is_here_separate_3d_meshes_gaussian/) is a useful design pattern; it does not make the splat itself editable or physically walkable.
