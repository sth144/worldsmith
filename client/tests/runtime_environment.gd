extends SceneTree


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	var target := ProjectSettings.globalize_path("res://tests/fixtures/assets/environment.glb")
	assert(FileAccess.file_exists(target), "Synthetic environment fixture is missing")
	var scene: PackedScene = load("res://scenes/main.tscn")
	var world := scene.instantiate()
	root.add_child(world)
	var settings := {"spawn": [0, 1.8, 4], "collision": {"walkable": ["floor", "grid"], "solid": ["wall"]},
		"lighting": {"sun_energy": 0.4, "fill_energy": 0.2, "ambient_energy": 0.3}}
	world.load_environment_file(target, settings)
	await physics_frame
	assert(world.preview_name == "environment.glb", "Runtime environment did not load")
	assert(world.player.position == Vector3(0, 1.8, 4), "Scene spawn did not load")
	assert(is_equal_approx(world.get_node("Sun").light_energy, 0.4), "Sun energy did not load")
	assert(is_equal_approx(world.get_node("InteriorFill").light_energy, 0.2), "Fill energy did not load")
	assert(is_equal_approx(world.get_node("DaylightEnvironment").environment.ambient_light_energy, 0.3),
		"Ambient energy did not load")
	var preview: Node3D = world.get_node("PreviewWorld")
	var walkable := 0
	for body in preview.find_children("*", "StaticBody3D", true, false):
		if body.collision_layer == 1:
			walkable += 1
	assert(walkable > 0, "Runtime environment has no walkable collision")
	var instance_group := {
		"glb": ProjectSettings.globalize_path("res://tests/fixtures/assets/chair.glb"),
		"transforms": ProjectSettings.globalize_path("res://tests/fixtures/instance_transform.bin"),
		"count": 1,
	}
	assert(world.add_preview_instance_group(instance_group), "Runtime instance group did not load")
	assert(preview.find_children("*", "MultiMeshInstance3D", true, false).size() == 1,
		"Runtime instance was not added to the environment")
	world.load_environment_file("", {})
	assert(world.preview_name.is_empty(), "Clearing a scene retained the old environment")
	assert(world.get_node_or_null("PreviewWorld") == null, "Clearing a scene retained its meshes")
	assert(is_equal_approx(world.get_node("Sun").light_energy, 1.0), "Scene lighting leaked into empty workspace")
	print("Runtime environment: GLB, spawn, collision, instances, and clearing work")
	quit()
