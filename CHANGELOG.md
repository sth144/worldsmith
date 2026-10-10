# Changelog

## Unreleased

### Added

- Milestone 4 selected-object natural-language prompt on desktop and in VR, deterministic direct requests, and read-only Codex CLI planning with server-side proposal validation.
- Milestone 5 explicit geometry approval, fixed Blender bevel/stretch/opening operations, versioned GLB assets, runtime downloads, and persistent undo for asset replacement.
- Milestone 6 registered base-environment assets, source manifest, Blender-composed portable GLB export, and Geometry Nodes preview instance inclusion.
- Backend geometry/export tests and a desktop AI-to-geometry integration check.
- Milestone 3 FastAPI scene server with validated operations, revision conflicts, atomic JSON snapshots, persistent undo/redo history, asset retrieval, and WebSocket deltas.
- Godot WebSocket sync with optimistic local edits, reconnect, queued in-session edits, and server reconciliation.
- Demo project template, server API tests, and desktop client persistence/reconnect integration checks.
- Android `INTERNET` permission and optional ignored Quest server configuration.
- Milestone 2 local object editing: a desktop inventory and spatial Quest inventory with four generated GLB props, floor placement preview, ray selection, move, rotate, scale, duplicate, delete, and undo/redo.
- Stable UUIDs for placed objects and a dedicated selection collision layer; yellow selection outline and right-controller editing ray.
- A headless desktop integration check covering placement, ray selection, transforms, duplication, deletion, and undo/redo.
- Godot 4.6 OpenXR project with desktop fallback and a generated sample GLB hall.
- Controller teleportation, optional smooth XR locomotion, desktop movement, and simple collision.
- Desktop and in-headset status displays.
- Quest export and development documentation.
- A headless smoke check for scene import, desktop camera, and teleportable floor collision.
- A repository launcher that finds Godot or fetches the pinned macOS editor when it is absent.
- Local Blender-to-GLB preview with a configurable spawn and generated walkable collision.
- Daylight ambient fill for readable shadowed areas in imported environments.
- Higher-fidelity local Blender previews with baked procedural colors, visible modifiers, and Geometry Nodes instances rendered through MultiMesh.
- Desktop Shift sprinting; walkable merchant entrances with step-up handling and an open gate in the preview.
- Desktop arrow-key view control alongside WASD movement and mouse look.
- Contact shading and fill lights that separate flat architectural surfaces in the merchant preview.
- Walkable preview stair collision and step-up movement through the merchant's straight staircases to the upper floor.

### Fixed

- Repaint a named upholstery material without recoloring the chair's wood; a targeted repaint also clears a previous whole-object tint and exports with the same appearance.
- Enable Android ETC2/ASTC texture import so Godot 4.6.3 can export the Quest APK.
- Use Godot's Gradle Android build so the Quest APK includes the OpenXR loader.
- Enable left-thumbstick walking by default and map OpenXR's forward axis to Godot's forward direction.
