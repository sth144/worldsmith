# Changelog

## Unreleased

### Added

- Scene data, asset catalogs, preview settings, and initial project state are supplied outside application code. A new installation starts with an empty workspace.
- Connected clients load a scene package containing a content-hashed environment, presentation settings, and repeated mesh groups directly from the selected project.
- Connected clients refresh the selected scene package while open, so newly published environment settings appear without reconnecting.
- Runtime inventory loads from the selected project's catalog. Assets keep stable IDs for saved placements, while generated assets can be saved before they are cataloged.
- Local preview configuration controls environment geometry, spawn, collision roles, hidden meshes, materials, sky, and lights.
- A reusable Blender scene authoring skill, a local asset library, and generic GLB quality checks support a range of visual styles and environments.
- Asset revisions can be stored as candidates before promotion, and GLB checks report draw calls, triangles, and embedded texture size against optional budgets.
- Desktop and OpenXR navigation, selection, placement, transform tools, undo and redo, and persistent scene synchronization.
- Natural language commands for selected objects and viewed locations, with deterministic catalog placement, validated agent proposals, and generated geometry.
- Optional microphone transcription and review before sending scene commands.
- Versioned geometry edits with explicit approval and portable scene export.
- Quest build and deployment support.
- In-scene asset requests form a queue that an agent or a person can list, claim, fulfil, or fail, with progress shown on the home screen and in the scene. Requests stay valid when the scene is edited.
- Review Collision suggests walkable and solid meshes and a spawn point for an imported environment, and saves the reviewed roles. A scene cannot be run until it has walkable collision.
- The home screen has a new look: scenes are named by their prompt, and each shows one main action and its progress through plan, geometry, collision, and walking.
- A home screen on desktop and on a headset panel lists scenes and reusable assets, opens a scene to edit or run, and shows planned actions as not built yet.

### Fixed

- Preview and export behavior no longer branches on specific environment filenames or mesh names in application code.
- Inventory and agent placement use the selected project's catalog rather than a fixed asset list.
- Preview movement is disabled when no environment is loaded.
