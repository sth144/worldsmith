extends SceneTree


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	var world := scene.instantiate()
	root.add_child(world)
	await physics_frame
	var preview: Node3D = world.get_node_or_null("PreviewWorld")
	assert(preview != null, "Configured preview was not loaded")
	var meshes := preview.find_children("*", "MeshInstance3D", true, false)
	assert(not meshes.is_empty(), "Preview has no meshes")
	var collision_count := 0
	for node in preview.find_children("*", "StaticBody3D", true, false):
		if node.collision_layer == 1:
			collision_count += 1
	assert(collision_count > 0, "Preview has no walkable collision")
	print("Preview smoke: %d meshes and %d walkable collision bodies" % [meshes.size(), collision_count])
	quit()
