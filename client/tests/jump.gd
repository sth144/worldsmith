extends SceneTree

# Run against a scene server with a walkable scene:
#   --server-url=ws://host:port --scene-id=<walkable scene>


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	var world := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(world)
	var player: CharacterBody3D = world.get_node("Player")
	if not await _wait_for(func() -> bool: return not str(world.get("preview_name")).is_empty() and player.is_on_floor(), 3000):
		_fail("Player never stood on the ground")
		return
	var ground := player.global_position.y
	var key := InputEventKey.new()
	key.keycode = KEY_SPACE
	key.pressed = true
	Input.parse_input_event(key)
	var peak := ground
	for frame in range(90):
		await physics_frame
		peak = maxf(peak, player.global_position.y)
	key = key.duplicate()
	key.pressed = false
	Input.parse_input_event(key)
	if peak - ground < 0.8 or peak - ground > 1.5:
		_fail("Jump rose %.2f m; expected about 1 m" % (peak - ground))
		return
	if not await _wait_for(func() -> bool: return player.is_on_floor() and absf(player.global_position.y - ground) < 0.1, 300):
		_fail("Player did not land back on the ground")
		return
	print("Jump: rose %.2f m and landed OK" % (peak - ground))
	quit()


func _wait_for(condition: Callable, frames: int) -> bool:
	for index in range(frames):
		await process_frame
		if condition.call():
			return true
	return false


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
