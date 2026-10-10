# Architecture and roadmap

## Current vertical slice

The M3 client imports a self-contained GLB for visuals and keeps simple Godot `StaticBody3D` shapes alongside it for movement and teleportation. The visual GLB is not modified at runtime. The player uses a `CharacterBody3D`; its `XROrigin3D` owns the tracked camera and two tracked controllers. Desktop mode uses a separate camera on the same body. The floor is on collision layer 1 for teleport rays, while walls and the table are on layer 2. Placed prop selection shapes use layer 8; the player does not collide with them yet. The player collides with floor and walls. The Compatibility renderer uses screen-space ambient occlusion to define contact edges; one shadowless directional fill and merchant-specific shadowless interior lights make room geometry legible without modifying source assets. Quest frame rate with these effects needs device profiling.

One world unit is one meter. Godot and glTF use Y up. The Blender generators take Y-up coordinates and map them to Blender's Z-up axes before GLB export. The sample assets are small and use simple materials to keep the initial draw count modest. Quest performance and comfort still need device verification.

The `WorldsmithSceneEditor` owns runtime placed objects and records each edit as a before/after snapshot keyed by a UUID. The inventory emits actions to the main client; a floor ray determines placement, while a separate ray on layer 8 selects placed objects. The desktop panel and headset panel invoke the same actions. `WorldsmithSceneSync` sends those edits over a WebSocket and keeps pending edits in memory until acknowledged. On reconnect, it loads the authoritative snapshot and reapplies pending edits. The same operation path serves REST and WebSocket callers.

The FastAPI server keeps `scene.json` and `history.json` in `data/projects/<scene_id>/`, copied initially from `projects/demo/`. Every write checks the expected revision and validates the full resulting scene. It atomically replaces the history file before the snapshot; if interrupted between the two writes, the server replays history on the next read and repairs the snapshot. History has a cursor for persistent undo/redo. WebSocket updates contain only changed objects. The base GLB environment remains in the client package; the JSON graph contains placed editable props. Runtime data is ignored by Git.

## Planned components

1. **VR client:** viewer, in-world editing, and server synchronization through M3.
2. **Scene server:** FastAPI authoritative scene graph, asset serving, atomic JSON snapshots, revision checks, history, and WebSocket deltas through M3.
3. **AI editing worker:** a constrained structured-operation interface in M4; isolated Blender geometry jobs with approval in M5.
4. **Export:** portable scene GLB and source asset manifest in M6.

Persistent objects use stable UUIDs, meter units, Y-up positions, and `(x, y, z, w)` quaternions. Client edits are optimistic, then reconciled to server revisions. Later AI proposals will use the same validated operation interface. The AI worker has not been scaffolded yet.

## Current boundaries

The sample collision layout is fixed. Local previews derive approximate collision from object names; stairs and stoops get walkable collision and step-up movement of up to 0.85 meters, while door leaves and frames have no collision so entrances stay usable. The merchant preview hides its closed gate leaves and hardware at runtime. Arbitrary meshes are not guaranteed to have usable collision or teleport surfaces. Physical room movement is tracked by OpenXR; the `CharacterBody3D` collision currently governs stick/keyboard locomotion, not every possible real-world head movement. Props can only be placed on floors recognized by the collision builder, and their collision shapes serve selection rather than blocking player movement. New asset downloads, parented prop editing, and Quest verification remain future work. Pending edits are held in memory and need an open client to reconnect. The LAN service has no authentication and must not be exposed to the Internet.

For local `.blend` previews, `scripts/preview_blend.sh` exports a GLB under the ignored `client/assets/local/` directory. It bakes procedural base colors into textures and exports repeated Geometry Nodes meshes as compact transform data for Godot `MultiMesh`; this avoids thousands of separate scene nodes. The client creates temporary collision meshes for floor and structural objects based on their names. The `.blend` is never changed. This is a development preview, not a native Blender round trip. Milestone 6 will export the edited scene to GLB for Blender import; preserving Blender-specific modifiers and collections would need a later operation-replay path into a copy of the source `.blend`.
