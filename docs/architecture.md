# Architecture and roadmap

## Current vertical slice

The M1 client imports a self-contained GLB for visuals and keeps simple Godot `StaticBody3D` shapes alongside it for movement and teleportation. The visual GLB is not modified at runtime. The player uses a `CharacterBody3D`; its `XROrigin3D` owns the tracked camera and two tracked controllers. Desktop mode uses a separate camera on the same body. The floor is on collision layer 1 for teleport rays, while walls and the table are on layer 2. The player collides with both.

One world unit is one meter. Godot and glTF use Y up. The Blender generator takes Y-up coordinates and maps them to Blender's Z-up axes before GLB export. The sample asset is small and uses simple materials to keep the initial draw count modest. Quest performance and comfort still need device verification.

## Planned components

1. **VR client:** inventory, object selection/manipulation, and local undo in M2.
2. **Scene server:** FastAPI authoritative scene graph, asset serving, atomic JSON snapshots, revision checks, history, and WebSocket deltas in M3.
3. **AI editing worker:** a constrained structured-operation interface in M4; isolated Blender geometry jobs with approval in M5.
4. **Export:** portable scene GLB and source asset manifest in M6.

For persistence, objects will use stable UUIDs, meter units, Y-up positions, and `(x, y, z, w)` quaternions. Client edits will be optimistic, then reconciled to server revisions. All edits, including AI proposals, will pass through one validated operation interface. These later components have not been scaffolded yet so that M1 stays independently runnable.

## M1 boundaries

The sample collision layout is fixed. Local previews derive approximate collision from object names; arbitrary meshes are not guaranteed to have usable collision or teleport surfaces. Physical room movement is tracked by OpenXR; the `CharacterBody3D` collision currently governs stick/keyboard locomotion, not every possible real-world head movement. M1 has no asset browser, save format, server, or AI worker.

For local `.blend` previews, `scripts/preview_blend.sh` exports a GLB under the ignored `client/assets/local/` directory. The client loads that GLB and creates temporary collision meshes for floor and structural objects based on their names. The `.blend` is never changed. This is a development preview, not a native Blender round trip. Milestone 6 will export the edited scene to GLB for Blender import; preserving Blender-specific modifiers and collections would need a later operation-replay path into a copy of the source `.blend`.
