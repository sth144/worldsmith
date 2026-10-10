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
		_fail("Initial connection failed")
		return
	if editor.objects.size() != 1:
		_fail("Expected a saved chair")
		return
	var object_id: String = editor.objects.keys()[0]
	var expected_revision := sync.revision + 1
	sync.socket.close()
	if not await _wait_for(func() -> bool: return not sync.online, 300):
		_fail("Client did not notice disconnect")
		return
	editor.set_object_transform(object_id, Transform3D(Basis.IDENTITY, Vector3(3, 0, 2)))
	if sync.pending.size() != 1:
		_fail("Offline edit was not queued")
		return
	if not await _wait_for(func() -> bool: return sync.online and sync.pending.is_empty() and sync.revision == expected_revision, 600):
		_fail("Queued edit was not saved after reconnect")
		return
	if not editor.object_node(object_id).position.is_equal_approx(Vector3(3, 0, 2)):
		_fail("Reconnected object position is wrong")
		return
	print("M3 client: offline edit queued and saved after reconnect")
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
