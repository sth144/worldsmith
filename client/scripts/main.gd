extends Node3D

const WALK_SPEED := 2.3
const SPRINT_MULTIPLIER := 2.0
const MAX_STEP_HEIGHT := 0.85
const TELEPORT_RANGE := 15.0
const MOUSE_SENSITIVITY := 0.002
const KEYBOARD_YAW_SPEED := 1.8
const KEYBOARD_PITCH_SPEED := 1.3
const DEADZONE := 0.18

@onready var player: CharacterBody3D = $Player
@onready var xr_origin: XROrigin3D = $Player/XROrigin
@onready var xr_camera: XRCamera3D = $Player/XROrigin/XRCamera
@onready var left_controller: XRController3D = $Player/XROrigin/LeftController
@onready var right_controller: XRController3D = $Player/XROrigin/RightController
@onready var desktop_camera: Camera3D = $Player/DesktopCamera
@onready var target: MeshInstance3D = $TeleportTarget
@onready var status: Label = $DesktopOverlay/Status
@onready var xr_status: Label3D = $Player/XROrigin/XRCamera/XRStatus
@onready var scene_editor: WorldsmithSceneEditor = $PlacedObjects
@onready var edit_panel: WorldsmithEditPanel = $EditPanel
@onready var prompt_panel: WorldsmithPromptPanel = $PromptPanel
@onready var placement_preview: Node3D = $PlacementPreview
@onready var scene_sync: WorldsmithSceneSync = $SceneSync

var xr_active := false
var smooth_locomotion := true
var aiming := false
var teleport_point := Vector3.ZERO
var mouse_yaw := 0.0
var mouse_pitch := 0.0
var xr_interface: XRInterface
var x_was_pressed := false
var preview_name := ""
var selected_id := ""
var placing_asset := ""
var moving_id := ""
var edit_valid := false
var y_was_pressed := false
var grip_was_pressed := false
var trigger_was_pressed := false
var selection_outline: MeshInstance3D
var xr_pointer: MeshInstance3D
var prompt_view: Dictionary = {}
var inventory_view: Dictionary = {}
var inventory_focus_id := ""
var prompt_target_id := ""


func _ready() -> void:
	_load_preview_from_args()
	scene_editor.changed.connect(_on_scene_changed)
	edit_panel.action_requested.connect(_on_edit_action)
	prompt_panel.submitted.connect(_on_prompt_submitted)
	scene_sync.status_changed.connect(_update_status)
	xr_interface = XRServer.find_interface("OpenXR")
	if OS.has_feature("android") and xr_interface:
		if xr_interface.is_initialized() or xr_interface.initialize():
			xr_active = true
			get_viewport().use_xr = true
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
			desktop_camera.current = false
			xr_camera.current = true
		else:
			push_error("OpenXR failed to initialize on this device")
	$DesktopOverlay.visible = not xr_active
	xr_status.visible = xr_active
	if not xr_active:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		_create_xr_pointer()
	edit_panel.set_selection_name("")
	_update_status()


func _load_preview_from_args() -> void:
	if OS.get_cmdline_user_args().has("--no-preview"):
		return
	var glb_path := ""
	var spawn := player.position
	var config_path := "res://assets/local/preview.json"
	if FileAccess.file_exists(config_path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(config_path))
		if parsed is Dictionary:
			var config: Dictionary = parsed
			glb_path = str(config.get("glb", ""))
			var configured_spawn: Array = config.get("spawn", [])
			if configured_spawn.size() == 3:
				spawn = Vector3(float(configured_spawn[0]), float(configured_spawn[1]), float(configured_spawn[2]))
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--preview-glb="):
			glb_path = argument.trim_prefix("--preview-glb=")
		elif argument.begins_with("--spawn="):
			var values := argument.trim_prefix("--spawn=").split(",")
			if values.size() == 3:
				spawn = Vector3(values[0].to_float(), values[1].to_float(), values[2].to_float())
	if glb_path.is_empty():
		return
	var packed: PackedScene = load(glb_path)
	if packed == null:
		push_error("Could not load preview GLB: " + glb_path)
		return
	$SampleHall.queue_free()
	for name in ["Floor", "WestWall", "EastWall", "NorthWall", "SouthWall", "TableObstacle"]:
		get_node(name).collision_layer = 0
	var preview := packed.instantiate()
	preview.name = "PreviewWorld"
	add_child(preview)
	_load_preview_instances(preview, glb_path.get_basename() + "-instances.json")
	var collision_count := 0
	for mesh_node in preview.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := mesh_node as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		var node_name := mesh_instance.name.to_lower()
		if glb_path.get_file() == "merchant.glb" and (node_name.begins_with("gate doors") or node_name.begins_with("gate ironwork") or node_name.begins_with("gate straps")):
			mesh_instance.visible = false
			continue
		var walkable := _name_has_any(node_name, ["grid", "paving", "floor", "road", "deck", "stoop", "stair"])
		var solid := walkable or _name_has_any(node_name, ["wall", "column", "pillar"])
		if not solid:
			continue
		var shape := mesh_instance.mesh.create_trimesh_shape()
		if shape == null:
			continue
		var body := StaticBody3D.new()
		body.collision_layer = 1 if walkable else 2
		mesh_instance.add_child(body)
		var collision := CollisionShape3D.new()
		collision.shape = shape
		body.add_child(collision)
		collision_count += 1
	if glb_path.get_file() == "merchant.glb":
		_add_merchant_fill_lights(preview)
	player.position = spawn
	preview_name = glb_path.get_file()
	print("Preview loaded: %s; %d collision meshes" % [preview_name, collision_count])


func _add_merchant_fill_lights(preview: Node3D) -> void:
	# The imported GLB has no Blender interior lighting. Local lights reveal
	# wall, stair, and floor junctions without changing its source materials.
	var positions := [
		Vector3(14.0, 25.8, 3.5),
		Vector3(2.5, 25.8, 8.5),
		Vector3(25.5, 25.8, 8.5),
		Vector3(13.5, 25.8, 24.5),
		Vector3(26.0, 25.8, 34.0),
	]
	for index in range(positions.size()):
		var light := OmniLight3D.new()
		light.name = "PreviewFill%d" % index
		light.position = positions[index]
		light.light_color = Color(1.0, 0.88, 0.72)
		light.light_energy = 2.0
		light.omni_range = 11.0
		light.shadow_enabled = false
		preview.add_child(light)


func _load_preview_instances(preview: Node3D, manifest_path: String) -> void:
	if not FileAccess.file_exists(manifest_path):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	if not parsed is Dictionary:
		push_error("Invalid preview instance manifest: " + manifest_path)
		return
	for group in parsed.get("groups", []):
		var prototype_scene: PackedScene = load(str(group.get("glb", "")))
		var transform_file := FileAccess.open(str(group.get("transforms", "")), FileAccess.READ)
		var count := int(group.get("count", 0))
		if prototype_scene == null or transform_file == null or count <= 0 or transform_file.get_length() != count * 48:
			push_error("Invalid preview instance group")
			continue
		var prototype_root := prototype_scene.instantiate()
		var prototype_meshes := prototype_root.find_children("*", "MeshInstance3D", true, false)
		if prototype_meshes.is_empty():
			prototype_root.free()
			continue
		var prototype: MeshInstance3D = prototype_meshes[0]
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = prototype.mesh
		multimesh.instance_count = count
		for index in range(count):
			var x_axis := Vector3(transform_file.get_float(), transform_file.get_float(), transform_file.get_float())
			var y_axis := Vector3(transform_file.get_float(), transform_file.get_float(), transform_file.get_float())
			var z_axis := Vector3(transform_file.get_float(), transform_file.get_float(), transform_file.get_float())
			var position := Vector3(transform_file.get_float(), transform_file.get_float(), transform_file.get_float())
			multimesh.set_instance_transform(index, Transform3D(Basis(x_axis, y_axis, z_axis), position))
		var instance_node := MultiMeshInstance3D.new()
		instance_node.name = "PreviewInstances"
		instance_node.multimesh = multimesh
		instance_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		preview.add_child(instance_node)
		prototype_root.free()
		print("Preview instances: %d" % count)


func _name_has_any(value: String, words: Array[String]) -> bool:
	for word in words:
		if value.contains(word):
			return true
	return false


func _unhandled_input(event: InputEvent) -> void:
	if xr_active:
		return
	if prompt_panel.is_open:
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			prompt_panel.close()
			get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		mouse_yaw -= event.relative.x * MOUSE_SENSITIVITY
		mouse_pitch = clampf(mouse_pitch - event.relative.y * MOUSE_SENSITIVITY, -1.45, 1.45)
		desktop_camera.rotation.x = mouse_pitch
		player.rotation.y = mouse_yaw
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_TAB:
			_toggle_inventory()
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_ESCAPE:
			if _is_editing():
				_cancel_edit()
			elif edit_panel.is_open:
				_set_inventory(false)
			else:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			get_viewport().set_input_as_handled()
			return
		if edit_panel.is_open:
			return
		if event.ctrl_pressed or event.meta_pressed:
			if event.keycode == KEY_Z:
				_on_edit_action("redo" if event.shift_pressed else "undo")
			elif event.keycode == KEY_Y:
				_on_edit_action("redo")
			elif event.keycode == KEY_D:
				_on_edit_action("duplicate")
			else:
				return
			get_viewport().set_input_as_handled()
			return
		match event.keycode:
			KEY_G:
				_on_edit_action("move")
			KEY_R:
				_on_edit_action("rotate_left" if event.shift_pressed else "rotate_right")
			KEY_EQUAL:
				_on_edit_action("grow")
			KEY_MINUS:
				_on_edit_action("shrink")
			KEY_DELETE, KEY_BACKSPACE:
				_on_edit_action("delete")
	elif event is InputEventMouseButton:
		if edit_panel.is_open:
			return
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			elif _is_editing():
				_confirm_edit()
			else:
				_select_object(_object_under_ray())
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			if _is_editing():
				if event.pressed:
					_cancel_edit()
				return
			if not event.pressed and aiming and target.visible:
				_teleport()
			aiming = event.pressed


func _physics_process(delta: float) -> void:
	if xr_active:
		_update_xr_panel_ray()
		_process_xr_input()
	else:
		aiming = Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) and not _is_editing() and not edit_panel.is_open
		_process_desktop_look(delta)
	_process_movement(delta)
	_update_edit_preview()
	_update_teleport_target()


func _process_desktop_look(delta: float) -> void:
	if edit_panel.is_open or prompt_panel.is_open:
		return
	var yaw_input := float(Input.is_key_pressed(KEY_LEFT)) - float(Input.is_key_pressed(KEY_RIGHT))
	var pitch_input := float(Input.is_key_pressed(KEY_UP)) - float(Input.is_key_pressed(KEY_DOWN))
	if yaw_input == 0.0 and pitch_input == 0.0:
		return
	mouse_yaw += yaw_input * KEYBOARD_YAW_SPEED * delta
	mouse_pitch = clampf(mouse_pitch + pitch_input * KEYBOARD_PITCH_SPEED * delta, -1.45, 1.45)
	player.rotation.y = mouse_yaw
	desktop_camera.rotation.x = mouse_pitch


func _process_xr_input() -> void:
	var y_pressed := left_controller.is_button_pressed("by_button")
	if y_pressed and not y_was_pressed and not prompt_panel.is_open:
		_toggle_inventory()
	y_was_pressed = y_pressed
	var x_pressed := left_controller.is_button_pressed("ax_button")
	if x_pressed and not x_was_pressed:
		smooth_locomotion = not smooth_locomotion
		_update_status()
	x_was_pressed = x_pressed
	var grip_pressed := right_controller.is_button_pressed("grip_click")
	if grip_pressed and not grip_was_pressed and not edit_panel.is_open and not prompt_panel.is_open and not _is_editing():
		var grabbed_id := _object_under_ray()
		if not grabbed_id.is_empty():
			_select_object(grabbed_id)
		_begin_move()
	elif not grip_pressed and grip_was_pressed and not moving_id.is_empty():
		_confirm_edit()
	grip_was_pressed = grip_pressed
	var trigger_pressed := right_controller.is_button_pressed("trigger_click")
	if trigger_pressed and not trigger_was_pressed:
		if prompt_panel.is_open:
			prompt_panel.activate_hovered()
		elif edit_panel.is_open:
			edit_panel.activate_hovered()
		elif not placing_asset.is_empty():
			_confirm_edit()
		elif moving_id.is_empty():
			var hit_id := _object_under_ray()
			if not hit_id.is_empty():
				_select_object(hit_id)
			else:
				aiming = true
	elif not trigger_pressed and trigger_was_pressed and aiming:
		if target.visible:
			_teleport()
		aiming = false
	trigger_was_pressed = trigger_pressed


func _process_movement(delta: float) -> void:
	var input_vector := Vector2.ZERO
	if xr_active and smooth_locomotion and not edit_panel.is_open and not prompt_panel.is_open:
		input_vector = left_controller.get_vector2("primary")
		# OpenXR thumbstick Y is positive forward; Godot's camera looks down -Z.
		input_vector.y = -input_vector.y
	elif not xr_active and not edit_panel.is_open and not prompt_panel.is_open:
		input_vector = Vector2(
			float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
			float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W))
		)
	if input_vector.length() < DEADZONE:
		input_vector = Vector2.ZERO
	else:
		input_vector = input_vector.limit_length()
	var facing: Basis = xr_camera.global_basis if xr_active else desktop_camera.global_basis
	var move_direction := facing * Vector3(input_vector.x, 0, input_vector.y)
	move_direction.y = 0
	move_direction = move_direction.normalized() * input_vector.length()
	var speed := WALK_SPEED * (SPRINT_MULTIPLIER if not xr_active and Input.is_key_pressed(KEY_SHIFT) else 1.0)
	player.velocity.x = move_direction.x * speed
	player.velocity.z = move_direction.z * speed
	player.velocity.y -= 9.8 * delta
	var was_on_floor := player.is_on_floor()
	var before := player.global_position
	player.move_and_slide()
	if was_on_floor and not move_direction.is_zero_approx():
		_try_step_up(before, move_direction, speed * delta)


func _try_step_up(before: Vector3, direction: Vector3, travel: float) -> void:
	var actual := player.global_position - before
	if Vector2(actual.x, actual.z).length() >= travel * 0.8:
		return
	var probe_distance := maxf(travel, 0.45)
	var destination := before + direction * probe_distance
	var ray_start := destination + Vector3.UP * (MAX_STEP_HEIGHT + 0.2)
	var ray_end := destination - Vector3.UP * 0.1
	var query := PhysicsRayQueryParameters3D.create(ray_start, ray_end, 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return
	var rise: float = hit.position.y - before.y
	if rise < 0.08 or rise > MAX_STEP_HEIGHT:
		return
	var horizontal := direction * probe_distance
	# The capsule may overlap the next tread even when the probed tread is clear.
	# Try the smallest lift first, then rise only as far as needed to pass it.
	for attempt in range(9):
		var lift := minf(rise + 0.05 + attempt * 0.1, MAX_STEP_HEIGHT + 0.02)
		var raised_origin := before + Vector3.UP * lift
		if not _destination_is_clear(raised_origin + horizontal):
			continue
		if player.test_move(Transform3D(player.global_basis, raised_origin), horizontal):
			continue
		player.global_position = raised_origin + horizontal
		player.velocity.y = 0.0
		return


func _update_teleport_target() -> void:
	target.visible = false
	if not aiming:
		return
	var source: Node3D = right_controller if xr_active else desktop_camera
	var ray_start := source.global_position
	var ray_end := ray_start - source.global_basis.z * TELEPORT_RANGE
	var query := PhysicsRayQueryParameters3D.create(ray_start, ray_end, 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return
	teleport_point = hit.position
	if not _destination_is_clear(_teleport_origin(teleport_point)):
		return
	target.global_position = teleport_point + Vector3.UP * 0.08
	target.visible = true


func _teleport() -> void:
	player.global_position = _teleport_origin(teleport_point)
	player.velocity = Vector3.ZERO
	target.visible = false


func _teleport_origin(point: Vector3) -> Vector3:
	var camera: Camera3D = xr_camera if xr_active else desktop_camera
	var offset := camera.global_position - player.global_position
	return point - Vector3(offset.x, 0, offset.z)


func _destination_is_clear(origin: Vector3) -> bool:
	var body_shape: CollisionShape3D = $Player/BodyCollision
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = body_shape.shape
	query.transform = Transform3D(player.global_basis, origin + Vector3.UP * 0.85)
	query.collision_mask = 2
	query.exclude = [player.get_rid()]
	return get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()


func _is_editing() -> bool:
	return not placing_asset.is_empty() or not moving_id.is_empty()


func _toggle_inventory() -> void:
	_set_inventory(not edit_panel.is_open)


func _set_inventory(value: bool) -> void:
	if value:
		inventory_view = _view_context()
		inventory_focus_id = _object_under_ray()
	if value and _is_editing():
		_cancel_edit()
	aiming = false
	target.visible = false
	edit_panel.set_open(value, xr_active, xr_camera if xr_active else desktop_camera)
	_update_status()


func _on_edit_action(action: String) -> void:
	if action == "approve_geometry":
		scene_sync.approve_geometry()
		_set_inventory(false)
		return
	if action == "ai_details":
		_set_inventory(false)
		prompt_panel.show_result(xr_active, xr_camera if xr_active else desktop_camera, scene_sync.last_agent_details)
		return
	if action == "ask_ai":
		prompt_target_id = selected_id if not selected_id.is_empty() else inventory_focus_id
		prompt_view = inventory_view
		var context := "Selected object" if not selected_id.is_empty() else ("Aimed object" if not prompt_target_id.is_empty() else "Viewed ground")
		_set_inventory(false)
		prompt_panel.open(xr_active, xr_camera if xr_active else desktop_camera, context)
		return
	if action.begins_with("place:"):
		_start_place(action.trim_prefix("place:"))
		return
	if action == "move":
		_begin_move()
		return
	if _is_editing():
		_cancel_edit()
	match action:
		"rotate_left":
			_rotate_selected(-15.0)
		"rotate_right":
			_rotate_selected(15.0)
		"grow":
			_scale_selected(1.1)
		"shrink":
			_scale_selected(1.0 / 1.1)
		"duplicate":
			if not selected_id.is_empty():
				var new_id := scene_editor.duplicate_object(selected_id)
				if not new_id.is_empty():
					_select_object(new_id)
		"delete":
			if not selected_id.is_empty():
				scene_editor.delete_object(selected_id)
				_select_object("")
		"undo":
			scene_editor.undo()
		"redo":
			scene_editor.redo()
	_update_status()


func _on_prompt_submitted(prompt: String) -> void:
	if not prompt_target_id.is_empty() or not prompt_view.is_empty():
		var targets: Array[String] = []
		if not selected_id.is_empty():
			targets.append(selected_id)
		scene_sync.request_agent(prompt, targets, prompt_view, prompt_target_id if selected_id.is_empty() else "")
	else:
		scene_sync.last_error = "Aim at a placed object or look at a floor point, then open Ask AI"
		scene_sync.status_changed.emit()
	_update_status()


func _view_context() -> Dictionary:
	var camera: Camera3D = xr_camera if xr_active else desktop_camera
	var origin := camera.global_position
	var direction := -camera.global_basis.z.normalized()
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * 30.0, 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return {}
	var point: Vector3 = hit["position"]
	return {"camera_position": [origin.x, origin.y, origin.z],
		"camera_direction": [direction.x, direction.y, direction.z],
		"target_position": [point.x, point.y, point.z]}


func _start_place(asset_key: String) -> void:
	if scene_editor.asset_info(asset_key).is_empty():
		return
	if _is_editing():
		_cancel_edit()
	placing_asset = asset_key
	_build_ghost(asset_key)
	_set_inventory(false)
	_update_status()


func _begin_move() -> void:
	if selected_id.is_empty() or _is_editing():
		return
	var selected := scene_editor.object_node(selected_id)
	if selected == null:
		return
	moving_id = selected_id
	_build_ghost(str(selected.get_meta("asset_key")))
	placement_preview.transform = selected.transform
	selected.visible = false
	_set_inventory(false)
	_update_status()


func _build_ghost(asset_key: String) -> void:
	for child in placement_preview.get_children():
		child.free()
	var visual := scene_editor.instantiate_asset(asset_key)
	if visual == null:
		push_error("Could not load placement preview for " + asset_key)
		return
	placement_preview.add_child(visual)
	for mesh_node in visual.find_children("*", "MeshInstance3D", true, false):
		var mesh := mesh_node as MeshInstance3D
		mesh.transparency = 0.42
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	placement_preview.visible = false
	edit_valid = false


func _update_edit_preview() -> void:
	if not _is_editing():
		return
	var ray := _edit_ray()
	var query := PhysicsRayQueryParameters3D.create(ray["origin"], ray["origin"] + ray["direction"] * TELEPORT_RANGE, 3)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	edit_valid = not hit.is_empty() and hit.normal.y > 0.45
	placement_preview.visible = edit_valid
	if edit_valid:
		var next_transform := placement_preview.transform
		next_transform.origin = hit.position
		placement_preview.transform = next_transform


func _confirm_edit() -> void:
	if not edit_valid:
		if not moving_id.is_empty():
			_cancel_edit()
		return
	var next_transform := placement_preview.transform
	if not placing_asset.is_empty():
		var new_id := scene_editor.add_object(placing_asset, next_transform)
		placing_asset = ""
		_clear_ghost()
		_select_object(new_id)
	elif not moving_id.is_empty():
		var moved := scene_editor.object_node(moving_id)
		if moved != null:
			moved.visible = true
		scene_editor.set_object_transform(moving_id, next_transform)
		moving_id = ""
		_clear_ghost()
		_refresh_selection()
	_update_status()


func _cancel_edit() -> void:
	if not moving_id.is_empty():
		var moved := scene_editor.object_node(moving_id)
		if moved != null:
			moved.visible = true
	placing_asset = ""
	moving_id = ""
	_clear_ghost()
	_update_status()


func _clear_ghost() -> void:
	placement_preview.visible = false
	edit_valid = false
	for child in placement_preview.get_children():
		child.free()
	placement_preview.transform = Transform3D.IDENTITY


func _edit_ray() -> Dictionary:
	var source: Node3D = right_controller if xr_active else desktop_camera
	return {"origin": source.global_position, "direction": -source.global_basis.z.normalized()}


func _object_under_ray() -> String:
	var ray := _edit_ray()
	var query := PhysicsRayQueryParameters3D.create(ray["origin"], ray["origin"] + ray["direction"] * TELEPORT_RANGE, 8)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return scene_editor.object_id_from_collider(hit.get("collider"))


func _select_object(object_id: String) -> void:
	selected_id = object_id
	_refresh_selection()
	_update_status()


func _on_scene_changed() -> void:
	if not selected_id.is_empty() and scene_editor.object_node(selected_id) == null:
		selected_id = ""
	_refresh_selection()
	_update_status()


func _refresh_selection() -> void:
	if is_instance_valid(selection_outline):
		selection_outline.queue_free()
	selection_outline = null
	var selected := scene_editor.object_node(selected_id)
	var selection_name := ""
	if selected != null:
		var asset: Dictionary = scene_editor.asset_info(str(selected.get_meta("asset_key")))
		selection_name = str(scene_editor.wire_object(selected_id).get("name", asset.get("label", "Object")))
		selection_outline = _make_outline(asset["size"])
		selected.add_child(selection_outline)
	edit_panel.set_selection_name(selection_name)
	edit_panel.refresh_actions(selected != null, scene_sync.can_undo(), scene_sync.can_redo())


func _make_outline(size: Vector3) -> MeshInstance3D:
	var margin := Vector3(0.03, 0.03, 0.03)
	var low := Vector3(-size.x * 0.5, 0, -size.z * 0.5) - margin
	var high := Vector3(size.x * 0.5, size.y, size.z * 0.5) + margin
	var corners := [
		Vector3(low.x, low.y, low.z), Vector3(high.x, low.y, low.z),
		Vector3(high.x, low.y, high.z), Vector3(low.x, low.y, high.z),
		Vector3(low.x, high.y, low.z), Vector3(high.x, high.y, low.z),
		Vector3(high.x, high.y, high.z), Vector3(low.x, high.y, high.z),
	]
	var lines := ImmediateMesh.new()
	lines.surface_begin(Mesh.PRIMITIVE_LINES)
	for edge in [[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4], [0, 4], [1, 5], [2, 6], [3, 7]]:
		lines.surface_add_vertex(corners[edge[0]])
		lines.surface_add_vertex(corners[edge[1]])
	lines.surface_end()
	var outline := MeshInstance3D.new()
	outline.name = "SelectionOutline"
	outline.mesh = lines
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 0.85, 0.18)
	material.no_depth_test = true
	outline.material_override = material
	outline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return outline


func _rotate_selected(degrees: float) -> void:
	var selected := scene_editor.object_node(selected_id)
	if selected == null:
		return
	var next_transform := selected.transform
	next_transform.basis = Basis(Vector3.UP, deg_to_rad(degrees)) * next_transform.basis
	scene_editor.set_object_transform(selected_id, next_transform)


func _scale_selected(factor: float) -> void:
	var selected := scene_editor.object_node(selected_id)
	if selected == null:
		return
	var next_scale := selected.scale * factor
	if next_scale.x < 0.25 or next_scale.x > 3.0:
		return
	var next_transform := selected.transform
	next_transform.basis = next_transform.basis.scaled(Vector3.ONE * factor)
	scene_editor.set_object_transform(selected_id, next_transform)


func _create_xr_pointer() -> void:
	xr_pointer = MeshInstance3D.new()
	xr_pointer.name = "EditRay"
	var beam := BoxMesh.new()
	beam.size = Vector3(0.008, 0.008, 1.0)
	xr_pointer.mesh = beam
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.2, 0.95, 0.85)
	material.no_depth_test = true
	xr_pointer.material_override = material
	xr_pointer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	xr_pointer.visible = false
	add_child(xr_pointer)


func _update_xr_panel_ray() -> void:
	if not is_instance_valid(xr_pointer):
		return
	var ray := _edit_ray()
	var ray_end := Vector3.ZERO
	if prompt_panel.is_open:
		if prompt_panel.update_hover(ray["origin"], ray["direction"]):
			ray_end = prompt_panel.hover_point
		else:
			ray_end = ray["origin"] + ray["direction"] * 3.0
	elif edit_panel.is_open:
		if edit_panel.update_hover(ray["origin"], ray["direction"]):
			ray_end = edit_panel.hover_point
		else:
			ray_end = ray["origin"] + ray["direction"] * 3.0
	elif not _is_editing():
		var query := PhysicsRayQueryParameters3D.create(ray["origin"], ray["origin"] + ray["direction"] * TELEPORT_RANGE, 8)
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		if not hit.is_empty():
			ray_end = hit.position
	if ray_end == Vector3.ZERO:
		xr_pointer.visible = false
		return
	var between: Vector3 = ray_end - ray["origin"]
	var up := Vector3.FORWARD if absf(between.normalized().dot(Vector3.UP)) > 0.95 else Vector3.UP
	xr_pointer.global_transform = Transform3D(Basis.looking_at(between.normalized(), up).scaled(Vector3(1, 1, between.length())), ray["origin"] + between * 0.5)
	xr_pointer.visible = true


func _update_status() -> void:
	var selected := scene_editor.object_node(selected_id)
	var selected_name := "none"
	if selected != null:
		selected_name = str(scene_editor.asset_info(str(selected.get_meta("asset_key"))).get("label", "object"))
	if xr_active:
		var mode := "PLACE" if not placing_asset.is_empty() else ("MOVE" if not moving_id.is_empty() else "VIEW")
		xr_status.text = "Worldsmith  •  %s  •  Selected: %s  •  %s\nY inventory  •  Left stick walk %s  •  Right trigger select/place/teleport  •  Right grip grab" % [mode, selected_name, scene_sync.status_text(), "ON" if smooth_locomotion else "OFF"]
	else:
		var title := preview_name if not preview_name.is_empty() else "SAMPLE HALL"
		var mode := "Placing " + placing_asset if not placing_asset.is_empty() else ("Moving " + selected_name if not moving_id.is_empty() else "Selected: " + selected_name)
		status.text = "WORLDSMITH  •  %s  •  %s  •  %s\nTab inventory  •  Left click select/place  •  G move  •  R rotate  •  +/- scale  •  Delete remove\nCtrl/Cmd+D duplicate  •  Ctrl/Cmd+Z undo  •  Ctrl/Cmd+Y redo  •  Right mouse teleport/cancel  •  WASD move" % [title, mode, scene_sync.status_text()]
