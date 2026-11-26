extends RefCounted
class_name WorldsmithTestAssets


static func register(editor: WorldsmithSceneEditor) -> void:
	for key in ["chair", "table", "planter", "lantern", "hill", "tree"]:
		editor.register_dynamic_asset(key, "res://tests/fixtures/assets/%s.glb" % key,
			key.capitalize(), key == "hill")
	editor.register_dynamic_asset("tree-v-foliage1", "res://tests/fixtures/assets/tree.glb", "Tree")
