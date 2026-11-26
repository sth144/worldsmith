---
name: worldsmith-requests
description: Work the Worldsmith request queue — build the assets people asked for inside a scene and place them. Use when asked to "work the queue", "pick up requests", "fulfil requests", or to make something a player requested in Worldsmith.
---

# Working the Worldsmith request queue

People ask for things from inside a scene ("add a small scruffy terrier here"). In the default mode the scene server saves that as a request with the spot they were looking at, and places nothing. Your job is to build what was asked for, check it honestly, and place it. Read `worldsmith-scenes` first for the quality rules; this skill is only the queue procedure.

All commands run from the repository root and need the scene server running (`./scripts/run_local.sh` starts it; default `http://127.0.0.1:8765`, or pass `--server`).

## The loop

1. **See what is waiting.** `python3 scripts/request_queue.py list` prints the waiting requests, oldest first, each with `id`, `scene_id`, `prompt`, and `target_position` (Y-up meters). Add `--all` to also see requests being built or failed. Take the oldest unless told otherwise.
2. **Reuse before you build.** `python3 scripts/asset_library.py list` shows the library. If a promoted mesh with `metadata.godot_review` true already fits the prompt, skip to step 7 with it.
3. **Claim it.** `python3 scripts/request_queue.py claim <scene-id> <request-id> --note "Building in Blender"`. The game then shows the request as being built, and another agent will not take it.
4. **Build the asset.** Write a self-contained Blender script at `data/asset_candidates/<asset-id>/build.py` and run it with `blender --background --python`. It must:
   - generate its own geometry and textures, so the asset is original and reproducible;
   - be one mesh object, in meters, standing on the origin with its base at height 0;
   - face −Y in Blender, which is +Z after export, so it faces someone approaching from the default view;
   - match the look of the scene it is going into — open that scene's source under `data/scene_sources/` if there is one;
   - export `data/asset_candidates/<asset-id>/<asset-id>.glb`, and save the packed `.blend` to `~/Drive/D/Documents/CAD/Blender/` when that folder exists.
5. **Check the structure.** `python3 scripts/check_glb_quality.py <glb> --max-triangles <budget> --max-draw-calls <budget>`. A small prop should stay under roughly 8,000 triangles and 8 draw calls. Fix any `errors`.
6. **Look at it in Godot. This is the review; do not skip it.** Copy the GLB to `client/assets/local/`, run `./scripts/godot.sh --headless --xr-mode off --editor --path client --quit` to import it, then capture at least a front and a back view:

   ```sh
   ./scripts/godot.sh --xr-mode off --path client --script res://tools/capture_asset.gd -- \
     --asset=res://assets/local/<asset-id>.glb --output=/absolute/path/front.png --yaw-deg=35
   ```

   Open the images and judge them. Does it read as what was asked for? Any holes, inside-out faces, floating parts, or shading faults? Fix and rebuild until it holds up, within reason. Save one capture beside the build script.
7. **Register and place it.** Register with an honest review note, then fulfil:

   ```sh
   python3 scripts/asset_library.py register <asset-id> /absolute/path/<asset-id>.glb \
     --kind mesh --origin authored --license "Original work for this project" \
     --source data/asset_candidates/<asset-id>/build.py \
     --metadata '{"godot_review": true, "review_note": "<what you saw, including faults>"}'
   python3 scripts/request_queue.py fulfil <scene-id> <request-id> <asset-id> --name "<Display name>"
   ```

   Fulfilling copies that exact version into the scene, adds it to the scene's inventory, and places it at the requested spot as one undoable edit. It works even if the scene was edited after the request was made.
8. **Confirm and report.** Capture the scene with `client/tools/capture_preview.gd` aimed at the target position and check the asset is there, on the ground, at a sensible size. Tell the person what you made, where it is, and what is weak about it. Then take the next request.

## Rules

- **Your review is the only review.** Setting `godot_review` to true is a claim that you looked at Godot captures and the asset is acceptable. Never set it for something you have not looked at. Write its faults in `review_note`.
- **Give up honestly.** If you cannot make something that reads as the request — a recognisable person, a very intricate object, anything needing reference you do not have — run `python3 scripts/request_queue.py fail <scene-id> <request-id> --note "<plain reason>"`. The requester sees the reason. Do not place a stand-in.
- **Release what you stop working on.** `python3 scripts/request_queue.py release <scene-id> <request-id>` puts a claimed request back in the queue.
- **One asset per request.** If the prompt asks for several different things, build the main one and say so in your report.
- **Stay inside the request.** Do not edit the scene beyond placing the asset, and keep asset files under `data/asset_candidates/`. Scene and asset names never go into application code or shared docs.
- Requests made on the home screen's Asset library tab ("Request an asset") are a separate list with no scene or position, and are not part of this queue yet.
