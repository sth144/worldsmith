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

### Fixed

- Preview and export behavior no longer branches on specific environment filenames or mesh names in application code.
- Inventory and agent placement use the selected project's catalog rather than a fixed asset list.
- Preview movement is disabled when no environment is loaded.
