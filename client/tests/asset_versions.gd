extends SceneTree


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	var editor := WorldsmithSceneEditor.new()
	root.add_child(editor)
	WorldsmithTestAssets.register(editor)
	var original_id := editor.add_object("tree", Transform3D.IDENTITY)
	var new_id := editor.add_object("tree-v-foliage1", Transform3D.IDENTITY)
	if original_id.is_empty() or new_id.is_empty():
		_fail("Tree assets did not instantiate")
		return
	if editor.wire_object(original_id)["asset"] != "assets/tree.glb":
		_fail("Existing tree asset changed")
		return
	if editor.wire_object(new_id)["asset"] != "assets/tree-v-foliage1.glb":
		_fail("New tree has the wrong saved asset ID")
		return
	print("Asset versions load with stable IDs")
	quit()


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
