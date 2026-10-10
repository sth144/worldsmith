extends SceneTree


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	var path := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--asset="):
			path = argument.trim_prefix("--asset=")
	if path.is_empty():
		push_error("Supply --asset=/absolute/path/to/version.glb")
		quit(1)
		return
	var editor := WorldsmithSceneEditor.new()
	root.add_child(editor)
	editor.register_dynamic_asset("chair-v-test", path)
	var instance := editor.instantiate_asset("chair-v-test")
	if instance == null or instance.find_children("*", "MeshInstance3D", true, false).is_empty():
		push_error("Dynamic GLB did not load")
		quit(1)
		return
	instance.free()
	print("Dynamic GLB runtime import OK")
	quit()
