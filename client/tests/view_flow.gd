extends SceneTree


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	var world := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(world)
	var sync: WorldsmithSceneSync = world.get_node("SceneSync")
	var editor: WorldsmithSceneEditor = world.get_node("PlacedObjects")
	if not await _wait_for(func() -> bool: return sync.online, 300):
		_fail("Scene server did not connect")
		return
	var view := {"camera_position": [0, 1.7, 0], "camera_direction": [0, -0.5, -0.8660254],
		"target_position": [0, 0, -3]}
	sync.request_agent("Put a hill here with a tree on it", [], view)
	if not await _wait_for(func() -> bool: return sync.revision == 1 and not sync.agent_busy, 600):
		_fail("View prompt was not saved: " + sync.last_error)
		return
	if editor.objects.size() != 2:
		_fail("View placements did not appear in the client")
		return
	var assets := {}
	for object_id in editor.objects:
		assets[editor.wire_object(object_id)["asset"]] = true
	if not assets.has("assets/hill.glb") or not assets.has("assets/tree.glb"):
		_fail("View placements use wrong assets")
		return
	editor.undo()
	if not await _wait_for(func() -> bool: return sync.revision == 2 and editor.objects.is_empty(), 300):
		_fail("One undo did not remove the arrangement")
		return
	print("View flow: prompt, scene sync, two assets, one undo OK")
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
