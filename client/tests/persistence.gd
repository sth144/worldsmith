extends SceneTree


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	var world := scene.instantiate()
	root.add_child(world)
	var sync: WorldsmithSceneSync = world.get_node("SceneSync")
	var editor: WorldsmithSceneEditor = world.get_node("PlacedObjects")
	if not await _wait_for(func() -> bool: return sync.online, 300):
		_fail("Did not connect to the scene server")
		return
	if OS.get_cmdline_user_args().has("--verify-existing"):
		if editor.objects.size() != 1:
			_fail("Placed chair was not restored after restart")
			return
		var object_id: String = editor.objects.keys()[0]
		var chair := editor.object_node(object_id)
		if not chair.position.is_equal_approx(Vector3(1, 0, 2)):
			_fail("Restored chair position differs")
			return
		editor.set_object_transform(object_id, Transform3D(Basis.IDENTITY, Vector3(2, 0, 2)))
		if not await _wait_for(func() -> bool: return sync.pending.is_empty() and sync.revision == 2, 300):
			_fail("Move was not saved")
			return
		editor.undo()
		if not await _wait_for(func() -> bool: return sync.pending.is_empty() and sync.revision == 3, 300):
			_fail("Undo was not saved")
			return
		if not editor.object_node(object_id).position.is_equal_approx(Vector3(1, 0, 2)):
			_fail("Undo did not restore the chair")
			return
		editor.redo()
		if not await _wait_for(func() -> bool: return sync.pending.is_empty() and sync.revision == 4, 300):
			_fail("Redo was not saved")
			return
		if not editor.object_node(object_id).position.is_equal_approx(Vector3(2, 0, 2)):
			_fail("Redo did not move the chair")
			return
		print("M3 client: restored chair, move, server undo/redo OK")
	else:
		if not editor.objects.is_empty():
			_fail("Expected empty test scene")
			return
		var object_id := editor.add_object("chair", Transform3D(Basis.IDENTITY, Vector3(1, 0, 2)))
		if not await _wait_for(func() -> bool: return sync.pending.is_empty() and sync.revision == 1, 300):
			_fail("Chair was not saved")
			return
		if editor.object_node(object_id) == null:
			_fail("Chair disappeared after server acknowledgement")
			return
		print("M3 client: chair saved; restart to verify")
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
