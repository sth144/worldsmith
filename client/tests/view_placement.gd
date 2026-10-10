extends SceneTree


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	var world := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(world)
	var editor: WorldsmithSceneEditor = world.get_node("PlacedObjects")
	world.desktop_camera.rotation.x = -0.55
	await physics_frame
	world._toggle_inventory()
	if world.inventory_view.is_empty():
		_fail("Inventory did not capture the viewed floor point")
		return
	world._on_edit_action("ask_ai_here")
	if not world.prompt_panel.is_open or not world.prompt_for_view:
		_fail("View prompt did not open")
		return
	world.prompt_panel.close()
	var hill_id := editor.add_object("hill", Transform3D.IDENTITY)
	var tree_id := editor.add_object("tree", Transform3D(Basis.IDENTITY, Vector3(0, 1.12, 0)))
	if editor.object_node(hill_id) == null or editor.object_node(tree_id) == null:
		_fail("View placement assets failed to load")
		return
	await process_frame
	var hill := editor.object_node(hill_id)
	if hill.get_node_or_null("WalkableHill") == null:
		_fail("Hill lacks walkable collision")
		return
	var query := PhysicsRayQueryParameters3D.create(Vector3(0, 3, 0), Vector3(0, -1, 0), 1)
	var hit: Dictionary = world.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty() or hit["collider"] != hill.get_node("WalkableHill"):
		_fail("View hill cannot be walked on")
		return
	print("View placement: hill and tree load; hill collider is walkable")
	quit()


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
