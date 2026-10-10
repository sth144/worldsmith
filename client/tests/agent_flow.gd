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
	var object_id := editor.add_object("chair", Transform3D.IDENTITY)
	if not await _wait_for(func() -> bool: return sync.revision == 1 and sync.pending.is_empty(), 300):
		_fail("Chair was not saved")
		return
	sync.request_agent("Make this chair twice as wide", [object_id])
	if not await _wait_for(func() -> bool: return sync.revision == 2 and not sync.agent_busy, 600):
		_fail("AI transform was not applied: " + sync.last_error)
		return
	if not is_equal_approx(editor.object_node(object_id).scale.x, 2.0):
		_fail("AI did not double width")
		return
	sync.request_agent("Round the corners of this chair", [object_id])
	if not await _wait_for(func() -> bool: return not sync.geometry_job_id.is_empty(), 600):
		_fail("Geometry proposal was not created: " + sync.last_error)
		return
	if sync.revision != 2:
		_fail("Geometry changed before approval")
		return
	sync.approve_geometry()
	if not await _wait_for(func() -> bool: return sync.revision == 3 and not sync.agent_busy, 900):
		_fail("Approved geometry was not applied: " + sync.last_error)
		return
	if not await _wait_for(func() -> bool: return editor.object_node(object_id) != null, 600):
		_fail("Modified mesh was not downloaded")
		return
	var modified_asset := str(editor.wire_object(object_id)["asset"])
	if not modified_asset.begins_with("assets/chair-v-"):
		_fail("Scene still uses old mesh")
		return
	editor.undo()
	if not await _wait_for(func() -> bool: return sync.revision == 4 and sync.pending.is_empty(), 300):
		_fail("Server undo failed")
		return
	if editor.wire_object(object_id)["asset"] != "assets/chair.glb":
		_fail("Undo did not restore original mesh")
		return
	print("M4/M5 client: AI edit, approved Blender geometry, download, undo OK")
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
