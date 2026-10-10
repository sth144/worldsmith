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
	var player: CharacterBody3D = world.get_node("Player")
	_press_key(KEY_UP, true)
	for frame in range(30):
		await physics_frame
	var walking_distance := 4.0 - player.global_position.z
	_press_key(KEY_SHIFT, true)
	for frame in range(30):
		await physics_frame
	var sprint_distance := 4.0 - player.global_position.z - walking_distance
	_press_key(KEY_SHIFT, false)
	_press_key(KEY_UP, false)
	assert(walking_distance > 0.8, "Up arrow did not move the player")
	assert(sprint_distance > walking_distance * 1.6, "Shift did not increase walking speed")
	print("M1 smoke: scene, GLB, camera, floor collision OK")
	quit()


func _press_key(code: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)
