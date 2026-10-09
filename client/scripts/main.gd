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


func _ready() -> void:
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
		status.text = "WORLDSMITH  •  M1 VIEWER\nWASD move  •  Mouse look  •  Hold right mouse to aim, release to teleport  •  Esc unlock mouse"
