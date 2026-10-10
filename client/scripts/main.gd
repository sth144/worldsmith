extends Node3D

const WALK_SPEED := 2.3
const TELEPORT_RANGE := 15.0
const MOUSE_SENSITIVITY := 0.002
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

var xr_active := false
var smooth_locomotion := false
var aiming := false
var teleport_point := Vector3.ZERO
var mouse_yaw := 0.0
var mouse_pitch := 0.0
var xr_interface: XRInterface
var x_was_pressed := false
var preview_name := ""


func _ready() -> void:
	_load_preview_from_args()
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
		var walkable := _name_has_any(node_name, ["grid", "paving", "floor", "road", "deck"])
		var solid := walkable or _name_has_any(node_name, ["wall", "door", "column", "pillar"])
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
	player.position = spawn
	preview_name = glb_path.get_file()
	print("Preview loaded: %s; %d collision meshes" % [preview_name, collision_count])


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
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		mouse_yaw -= event.relative.x * MOUSE_SENSITIVITY
		mouse_pitch = clampf(mouse_pitch - event.relative.y * MOUSE_SENSITIVITY, -1.45, 1.45)
		desktop_camera.rotation.x = mouse_pitch
		player.rotation.y = mouse_yaw
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			if not event.pressed and aiming and target.visible:
				_teleport()
			aiming = event.pressed


func _physics_process(delta: float) -> void:
	if xr_active:
		_process_xr_input()
	else:
		aiming = Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	_process_movement(delta)
	_update_teleport_target()


func _process_xr_input() -> void:
	var x_pressed := left_controller.is_button_pressed("ax_button")
	if x_pressed and not x_was_pressed:
		smooth_locomotion = not smooth_locomotion
		_update_status()
	x_was_pressed = x_pressed
	var trigger_pressed := right_controller.is_button_pressed("trigger_click")
	if trigger_pressed and not aiming:
		aiming = true
	elif not trigger_pressed and aiming:
		if aiming and target.visible:
			_teleport()
		aiming = false


func _process_movement(delta: float) -> void:
	var input_vector := Vector2.ZERO
	if xr_active and smooth_locomotion:
		input_vector = left_controller.get_vector2("primary")
	elif not xr_active:
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
	player.velocity.x = move_direction.x * WALK_SPEED
	player.velocity.z = move_direction.z * WALK_SPEED
	player.velocity.y -= 9.8 * delta
	player.move_and_slide()


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


func _update_status() -> void:
	if xr_active:
		xr_status.text = "WORLDsmith | Right trigger: teleport | X: smooth %s" % ("ON" if smooth_locomotion else "OFF")
	else:
		var title := preview_name if not preview_name.is_empty() else "M1 VIEWER"
		status.text = "WORLDSMITH  •  %s\nWASD move  •  Mouse look  •  Hold right mouse to aim, release to teleport  •  Esc unlock mouse" % title
