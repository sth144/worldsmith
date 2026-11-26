extends SceneTree


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	var world := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(world)
	var editor: WorldsmithSceneEditor = world.get_node("PlacedObjects")
	WorldsmithTestAssets.register(editor)
	world.desktop_camera.rotation.x = -0.55
	await physics_frame
	world._toggle_inventory()
	if world.inventory_view.is_empty():
		_fail("Inventory did not capture the viewed floor point")
		return
	world._on_edit_action("scene_command")
	if not world.prompt_panel.is_open or world.prompt_view.is_empty():
		_fail("Single AI prompt did not capture the viewed ground")
		return
	if world.prompt_panel.creation_mode != "reviewed":
		_fail("New-object prompts must default to reviewed assets")
		return
	world.prompt_panel.desktop_creation_mode.item_selected.emit(1)
	if world.prompt_panel.creation_mode != "draft":
		_fail("Quick draft mode could not be selected")
		return
	world.prompt_panel.desktop_creation_mode.item_selected.emit(0)
	world.prompt_panel.close()
	world._on_edit_action("ai_details")
	if not world.prompt_panel.is_open or not world.prompt_panel.result_mode:
		_fail("AI output viewer did not open")
		return
	world.prompt_panel.close()
	var chair_id := editor.add_object("chair", Transform3D(Basis.IDENTITY, Vector3(0, 0, 2)))
	world.desktop_camera.rotation.x = -0.25
	await physics_frame
	world._toggle_inventory()
	if world.inventory_focus_id != chair_id:
		_fail("Inventory did not capture the chair under the crosshair")
		return
	world._on_edit_action("scene_command")
	if world.prompt_target_id != chair_id:
		_fail("AI prompt did not target the aimed chair")
		return
	world.prompt_panel.close()
	var hill_id := editor.add_object("hill", Transform3D.IDENTITY)
	var tree_id := editor.add_object("tree-v-foliage1", Transform3D(Basis.IDENTITY, Vector3(0, 1.12, 0)))
	if editor.object_node(hill_id) == null or editor.object_node(tree_id) == null:
		_fail("View placement assets failed to load")
		return
	await process_frame
	var hill := editor.object_node(hill_id)
	if hill.get_node_or_null("WalkableAsset") == null:
		_fail("Hill lacks walkable collision")
		return
	var query := PhysicsRayQueryParameters3D.create(Vector3(0, 3, 0), Vector3(0, -1, 0), 1)
	var hit: Dictionary = world.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty() or hit["collider"] != hill.get_node("WalkableAsset"):
		_fail("View hill cannot be walked on")
		return
	print("View placement: hill and tree load; hill collider is walkable")
	quit()


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
