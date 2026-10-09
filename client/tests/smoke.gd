extends SceneTree


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	assert(scene != null, "Main scene did not load")
	var world := scene.instantiate()
	root.add_child(world)
	await physics_frame
	var hall := world.get_node("SampleHall")
	assert(hall.get_child_count() > 0, "Sample GLB was not imported")
	assert(world.get_node("Player/DesktopCamera").current, "Desktop camera inactive")
	var floor_ray := PhysicsRayQueryParameters3D.create(Vector3(0, 2, 4), Vector3(0, -1, 4), 1)
	assert(not world.get_world_3d().direct_space_state.intersect_ray(floor_ray).is_empty(), "No teleportable floor")
	print("M1 smoke: scene, GLB, camera, floor collision OK")
	quit()
