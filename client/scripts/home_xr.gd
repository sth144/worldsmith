extends Node3D

# Shows the home screen on a floating panel. The panel hosts the same Control
# scene as the desktop window; a controller ray (or the mouse, when no headset
# is active) is translated into pointer events for it.

const HOME_SCENE := "res://scenes/home.tscn"
const VIEW_SIZE := Vector2i(1280, 720)
const PANEL_SIZE := Vector2(2.4, 1.35)
const PANEL_CENTER := Vector3(0, 1.45, -1.7)
const EYE_HEIGHT := 1.6
const SCROLL_DEADZONE := 0.5
const SCROLL_INTERVAL := 0.12

var viewport: SubViewport
var home: Control
var panel: MeshInstance3D
var beam: MeshInstance3D
var camera: XRCamera3D
var right_controller: XRController3D
var xr_active := false
var pointer := Vector2(-1, -1)
var pressed := false
var scroll_wait := 0.0


func _ready() -> void:
	_build_rig()
	_build_panel()
	xr_active = _start_xr()
	if not xr_active:
		camera.position.y = EYE_HEIGHT
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _start_xr() -> bool:
	var interface := XRServer.find_interface("OpenXR")
	if not OS.has_feature("android") or interface == null:
		return false
	if not (interface.is_initialized() or interface.initialize()):
		push_error("OpenXR failed to initialize on this device")
		return false
	get_viewport().use_xr = true
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	return true


func _build_rig() -> void:
	var origin := XROrigin3D.new()
	add_child(origin)
	camera = XRCamera3D.new()
	origin.add_child(camera)
	camera.current = true
	right_controller = XRController3D.new()
	right_controller.tracker = &"right_hand"
	origin.add_child(right_controller)
	beam = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.008, 0.008, 1.0)
	beam.mesh = box
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.2, 0.95, 0.85)
	beam.material_override = material
	beam.visible = false
	add_child(beam)


func _build_panel() -> void:
	viewport = SubViewport.new()
	viewport.size = VIEW_SIZE
	viewport.disable_3d = true
	viewport.gui_embed_subwindows = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	home = (load(HOME_SCENE) as PackedScene).instantiate()
	viewport.add_child(home)
	panel = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = PANEL_SIZE
	panel.mesh = quad
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_texture = viewport.get_texture()
	panel.material_override = material
	panel.position = PANEL_CENTER
	add_child(panel)


func _process(delta: float) -> void:
	var ray := _pointer_ray()
	point_at(ray["origin"], ray["direction"], _select_pressed())
	if xr_active:
		_scroll_with_stick(delta)


func _input(event: InputEvent) -> void:
	# Without a headset the mouse wheel scrolls the panel under the cursor.
	if xr_active or not (event is InputEventMouseButton) or pointer.x < 0:
		return
	if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_push_button(event.button_index, event.pressed)


func _pointer_ray() -> Dictionary:
	if xr_active:
		return {"origin": right_controller.global_position, "direction": -right_controller.global_basis.z.normalized()}
	var mouse := get_viewport().get_mouse_position()
	return {"origin": camera.project_ray_origin(mouse), "direction": camera.project_ray_normal(mouse)}


func _select_pressed() -> bool:
	if xr_active:
		return right_controller.is_button_pressed("trigger_click")
	return get_window().has_focus() and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)


# Returns the panel pixel under a ray, or (-1, -1) when the ray misses it.
func panel_pixel(origin: Vector3, direction: Vector3) -> Vector2:
	var normal := panel.global_basis.z
	var denominator := direction.dot(normal)
	if denominator > -0.001:
		return Vector2(-1, -1)
	var distance := (panel.global_position - origin).dot(normal) / denominator
	if distance < 0.0:
		return Vector2(-1, -1)
	var local := panel.to_local(origin + direction * distance)
	if absf(local.x) > PANEL_SIZE.x * 0.5 or absf(local.y) > PANEL_SIZE.y * 0.5:
		return Vector2(-1, -1)
	return Vector2((local.x / PANEL_SIZE.x + 0.5) * VIEW_SIZE.x, (0.5 - local.y / PANEL_SIZE.y) * VIEW_SIZE.y)


# Moves the panel pointer along a ray and presses or releases its button.
func point_at(origin: Vector3, direction: Vector3, select: bool) -> void:
	var pixel := panel_pixel(origin, direction)
	_update_beam(origin, direction, pixel.x >= 0)
	if pixel.x < 0:
		if pressed:
			_push_button(MOUSE_BUTTON_LEFT, false)
			pressed = false
		pointer = pixel
		return
	if pixel != pointer:
		pointer = pixel
		var motion := InputEventMouseMotion.new()
		motion.position = pointer
		motion.global_position = pointer
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		viewport.push_input(motion)
	if select != pressed:
		pressed = select
		_push_button(MOUSE_BUTTON_LEFT, pressed)


func _push_button(button: MouseButton, down: bool) -> void:
	var click := InputEventMouseButton.new()
	click.button_index = button
	click.pressed = down
	click.position = pointer
	click.global_position = pointer
	viewport.push_input(click)


func _scroll_with_stick(delta: float) -> void:
	scroll_wait = maxf(scroll_wait - delta, 0.0)
	var tilt := right_controller.get_vector2("primary").y
	if pointer.x < 0 or absf(tilt) < SCROLL_DEADZONE or scroll_wait > 0.0:
		return
	scroll_wait = SCROLL_INTERVAL
	var button := MOUSE_BUTTON_WHEEL_UP if tilt > 0.0 else MOUSE_BUTTON_WHEEL_DOWN
	_push_button(button, true)
	_push_button(button, false)


func _update_beam(origin: Vector3, direction: Vector3, hit: bool) -> void:
	beam.visible = xr_active and hit
	if not beam.visible:
		return
	var between := direction * ((panel.global_position - origin).dot(panel.global_basis.z) / direction.dot(panel.global_basis.z))
	beam.global_transform = Transform3D(Basis.looking_at(between.normalized(), Vector3.UP).scaled(Vector3(1, 1, between.length())), origin + between * 0.5)
