extends SceneTree


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	var world := scene.instantiate()
	root.add_child(world)
	var expect_instances := OS.get_cmdline_user_args().has("--expect-instances")
	var expect_refresh := OS.get_cmdline_user_args().has("--expect-refresh")
	var first_signature := ""
	var first_spawn := Vector3.ZERO
	for attempt in range(900 if expect_refresh else 600):
		await create_timer(0.05).timeout
		var preview: Node3D = world.get_node_or_null("PreviewWorld")
		if preview == null or not world.scene_sync.online:
			continue
		var instances := preview.find_children("*", "MultiMeshInstance3D", true, false)
		if expect_instances and instances.is_empty():
			continue
		if expect_refresh:
			if first_signature.is_empty():
				first_signature = world.scene_sync.environment_settings_signature
				first_spawn = world.player.position
				print("Waiting for package refresh")
				continue
			if world.scene_sync.environment_settings_signature == first_signature:
				continue
			if world.player.position.distance_to(first_spawn) < 1.0:
				push_error("Package settings changed without updating the world")
				quit(1)
				return
		print("Connected package: environment=%s, instances=%d, revision=%d" % [
			world.preview_name, instances.size(), world.scene_sync.revision])
		quit()
		return
	push_error("Timed out loading the connected scene package: " + world.scene_sync.last_error)
	quit(1)
