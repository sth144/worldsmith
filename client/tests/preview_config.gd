extends SceneTree


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	var config_path := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--preview-config="):
			config_path = argument.trim_prefix("--preview-config=")
	assert(not config_path.is_empty(), "Supply a preview config to test")
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(config_path))
	var scene: PackedScene = load("res://scenes/main.tscn")
	var world := scene.instantiate()
	root.add_child(world)
	await physics_frame
	assert(world.scene_sync.disabled, "An explicit local preview must override server configuration")
	var preview: Node3D = world.get_node_or_null("PreviewWorld")
	assert(preview != null, "Configured preview was not loaded")
	for overlay_path in config.get("overlays", []):
		assert(preview.get_node_or_null(str(overlay_path).get_file().get_basename()) != null,
			"Configured overlay was not loaded")
	var walkable := 0
	for node in preview.find_children("*", "StaticBody3D", true, false):
		if node.collision_layer == 1:
			walkable += 1
	assert(walkable > 0, "Preview has no walkable collision")
	for entry in config.get("materials", []):
		var matched := false
		for node in preview.find_children("*", "MeshInstance3D", true, false):
			if node.name.to_lower().contains(str(entry["mesh"]).to_lower()):
				assert(node.material_override is ShaderMaterial, "Configured material is missing")
				matched = true
		assert(matched, "Configured material target was not found")
	if config.has("sky"):
		var environment: WorldEnvironment = world.get_node("DaylightEnvironment")
		assert(environment.environment.background_mode == Environment.BG_SKY, "Configured sky is missing")
	if config.has("fog"):
		var environment: WorldEnvironment = world.get_node("DaylightEnvironment")
		assert(environment.environment.fog_enabled, "Configured fog is missing")
	print("Preview config: material, collision, and sky settings loaded")
	quit()
