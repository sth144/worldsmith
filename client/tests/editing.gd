extends SceneTree


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	assert(scene != null)
	var world := scene.instantiate()
	root.add_child(world)
	await physics_frame
	var editor: WorldsmithSceneEditor = world.get_node("PlacedObjects")
	var panel: WorldsmithEditPanel = world.get_node("EditPanel")
	var camera: Camera3D = world.get_node("Player/DesktopCamera")
	camera.rotation.x = -0.48
	world._set_inventory(true)
	panel.desktop_buttons["place:chair"].pressed.emit()
	assert(not panel.is_open and world.placing_asset == "chair", "Inventory did not start chair placement")
	await physics_frame
	assert(world.edit_valid and world.placement_preview.visible, "Chair preview did not find the floor")
	world._confirm_edit()
	await physics_frame
	var chair_id: String = world.selected_id
	assert(chair_id.length() == 36, "Placed object needs a stable UUID")
	assert(editor.object_node(chair_id) != null, "Chair was not placed")
	assert(world._object_under_ray() == chair_id, "Camera ray could not select the chair")
	var initial: Transform3D = editor.object_node(chair_id).transform
	world._on_edit_action("rotate_right")
	world._on_edit_action("grow")
	assert(editor.object_node(chair_id).scale.x > 1.0, "Scale action did not change the chair")
	world._on_edit_action("undo")
	world._on_edit_action("undo")
	assert(editor.object_node(chair_id).transform.is_equal_approx(initial), "Undo did not restore the transform")
	world._on_edit_action("redo")
	world._on_edit_action("redo")
	assert(editor.object_node(chair_id).scale.x > 1.0, "Redo did not reapply the transform")
	world._on_edit_action("move")
	assert(not editor.object_node(chair_id).visible, "Moving should hide the old chair")
	world.player.rotation.y = 0.22
	await physics_frame
	assert(world.edit_valid, "Move preview did not find the floor")
	world._confirm_edit()
	assert(editor.object_node(chair_id).visible, "Chair stayed hidden after moving")
	assert(editor.object_node(chair_id).position.distance_to(initial.origin) > 0.2, "Move did not change the chair position")
	world._on_edit_action("duplicate")
	var duplicate_id: String = world.selected_id
	assert(duplicate_id != chair_id and editor.objects.size() == 2, "Duplicate did not make an independent object")
	world._on_edit_action("delete")
	assert(editor.object_node(duplicate_id) == null, "Delete did not remove the duplicate")
	world._on_edit_action("undo")
	assert(editor.object_node(duplicate_id) != null, "Undo did not restore the duplicate")
	world._on_edit_action("undo")
	assert(editor.object_node(duplicate_id) == null, "Undo did not reverse duplication")
	world._on_edit_action("redo")
	assert(editor.object_node(duplicate_id) != null, "Redo did not restore the duplicate")
	print("M2 editing: place, ray select, transform, move, duplicate, delete, undo/redo OK")
	quit()
