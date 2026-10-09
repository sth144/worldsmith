extends SceneTree


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	var world := scene.instantiate()
	root.add_child(world)
	await physics_frame
	var preview := world.get_node_or_null("PreviewWorld")
	assert(preview != null, "Preview GLB was not loaded")
	var meshes := preview.find_children("*", "MeshInstance3D", true, false)
	assert(meshes.size() > 0, "Preview has no meshes")
	var floor_ray := PhysicsRayQueryParameters3D.create(Vector3(-13, 27, 10), Vector3(-13, 19, 10), 1)
	assert(not world.get_world_3d().direct_space_state.intersect_ray(floor_ray).is_empty(), "Courtyard has no teleportable collision")
	print("Preview smoke: %d imported meshes and courtyard collision OK" % meshes.size())
	quit()
