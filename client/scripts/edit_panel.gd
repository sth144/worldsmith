extends Node3D
class_name WorldsmithEditPanel

signal action_requested(action: String)

const ASSET_ROWS := [
	{"action": "place:chair", "label": "Chair"},
	{"action": "place:table", "label": "Table"},
	{"action": "place:planter", "label": "Planter"},
	{"action": "place:lantern", "label": "Lantern"},
	{"action": "ask_ai", "label": "Ask AI…"},
	{"action": "approve_geometry", "label": "Approve mesh edit"},
]
const EDIT_ROWS := [
	{"action": "move", "label": "Move / grab"},
	{"action": "rotate_left", "label": "Rotate -15°"},
	{"action": "rotate_right", "label": "Rotate +15°"},
	{"action": "grow", "label": "Grow 10%"},
	{"action": "shrink", "label": "Shrink 10%"},
	{"action": "duplicate", "label": "Duplicate"},
	{"action": "delete", "label": "Delete"},
	{"action": "undo", "label": "Undo"},
	{"action": "redo", "label": "Redo"},
]
const ROW_TOP := 0.32
const ROW_STEP := 0.105

var is_open := false
var hover_action := ""
var hover_point := Vector3.ZERO
var xr_panel: Node3D
var desktop_panel: PanelContainer
var desktop_selection: Label
var xr_selection: Label3D
var xr_labels: Dictionary = {}
var desktop_buttons: Dictionary = {}
var edit_enabled: Dictionary = {}


func _ready() -> void:
	_build_desktop_panel()
	_build_xr_panel()
	refresh_actions(false, false, false)


func set_open(value: bool, xr: bool, camera: Camera3D) -> void:
	is_open = value
	desktop_panel.visible = value and not xr
	xr_panel.visible = value and xr
	hover_action = ""
	if value and xr:
		var forward := -camera.global_basis.z
		forward.y = 0.0
		forward = forward.normalized()
		xr_panel.global_position = camera.global_position + forward * 1.5 - Vector3.UP * 0.06
		xr_panel.global_basis = Basis.looking_at(forward, Vector3.UP)
	if not xr:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if value else Input.MOUSE_MODE_CAPTURED
	_update_hover_color()


func update_hover(ray_origin: Vector3, ray_direction: Vector3) -> bool:
	hover_action = ""
	if not is_open or not xr_panel.visible:
		return false
	var normal := xr_panel.global_basis.z
	var denominator := ray_direction.dot(normal)
	if denominator > -0.05:
		_update_hover_color()
		return false
	var distance := (xr_panel.global_position - ray_origin).dot(normal) / denominator
	if distance < 0.0 or distance > 4.0:
		_update_hover_color()
		return false
	hover_point = ray_origin + ray_direction * distance
	var local := xr_panel.to_local(hover_point)
	if absf(local.x) > 0.66 or absf(local.y) > 0.69:
		_update_hover_color()
		return false
	var row := int(floor((ROW_TOP - local.y + ROW_STEP * 0.5) / ROW_STEP))
	if local.x < -0.02 and row >= 0 and row < ASSET_ROWS.size():
		hover_action = ASSET_ROWS[row]["action"]
	elif local.x > 0.02 and row >= 0 and row < EDIT_ROWS.size():
		hover_action = EDIT_ROWS[row]["action"]
	_update_hover_color()
	return true


func activate_hovered() -> void:
	if not hover_action.is_empty():
		action_requested.emit(hover_action)


func set_selection_name(selection_name: String) -> void:
	var value := selection_name if not selection_name.is_empty() else "None"
	desktop_selection.text = "Selected: " + value
	xr_selection.text = "Selected: " + value


func refresh_actions(has_selection: bool, can_undo: bool, can_redo: bool) -> void:
	for row in EDIT_ROWS:
		var action: String = row["action"]
		var enabled := can_undo if action == "undo" else (can_redo if action == "redo" else has_selection)
		edit_enabled[action] = enabled
		if desktop_buttons.has(action):
			desktop_buttons[action].disabled = not enabled
	_update_hover_color()


func _build_desktop_panel() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	desktop_panel = PanelContainer.new()
	desktop_panel.position = Vector2(945, 145)
	desktop_panel.custom_minimum_size = Vector2(310, 0)
	desktop_panel.visible = false
	layer.add_child(desktop_panel)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 3)
	desktop_panel.add_child(rows)
	var heading := Label.new()
	heading.text = "WORLDSMITH  /  INVENTORY"
	rows.add_child(heading)
	desktop_selection = Label.new()
	rows.add_child(desktop_selection)
	rows.add_child(HSeparator.new())
	var asset_heading := Label.new()
	asset_heading.text = "Place an object"
	rows.add_child(asset_heading)
	for row in ASSET_ROWS:
		_add_desktop_button(rows, row)
	rows.add_child(HSeparator.new())
	var edit_heading := Label.new()
	edit_heading.text = "Edit selected object"
	rows.add_child(edit_heading)
	for row in EDIT_ROWS:
		_add_desktop_button(rows, row)


func _add_desktop_button(parent: VBoxContainer, row: Dictionary) -> void:
	var button := Button.new()
	button.text = str(row["label"])
	button.custom_minimum_size.y = 29
	parent.add_child(button)
	var action := str(row["action"])
	desktop_buttons[action] = button
	button.pressed.connect(_on_button_pressed.bind(action))


func _on_button_pressed(action: String) -> void:
	action_requested.emit(action)


func _build_xr_panel() -> void:
	xr_panel = Node3D.new()
	xr_panel.name = "SpatialInventory"
	xr_panel.visible = false
	add_child(xr_panel)
	var background := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.36, 1.42, 0.025)
	background.mesh = box
	var surface := StandardMaterial3D.new()
	surface.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	surface.albedo_color = Color(0.035, 0.055, 0.085, 0.96)
	surface.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	surface.no_depth_test = true
	background.material_override = surface
	xr_panel.add_child(background)
	_add_xr_label("WORLDsmith  /  INVENTORY", Vector3(-0.59, 0.60, 0.018), 30)
	xr_selection = _add_xr_label("Selected: None", Vector3(-0.59, 0.50, 0.018), 22)
	_add_xr_label("ASSETS", Vector3(-0.59, 0.42, 0.018), 22)
	_add_xr_label("EDIT", Vector3(0.08, 0.42, 0.018), 22)
	for index in range(ASSET_ROWS.size()):
		var row: Dictionary = ASSET_ROWS[index]
		xr_labels[row["action"]] = _add_xr_label(str(row["label"]), Vector3(-0.59, ROW_TOP - index * ROW_STEP, 0.018), 26)
	for index in range(EDIT_ROWS.size()):
		var row: Dictionary = EDIT_ROWS[index]
		xr_labels[row["action"]] = _add_xr_label(str(row["label"]), Vector3(0.08, ROW_TOP - index * ROW_STEP, 0.018), 25)


func _add_xr_label(value: String, location: Vector3, size: int) -> Label3D:
	var label := Label3D.new()
	label.text = value
	label.position = location
	label.font_size = size
	label.pixel_size = 0.002
	label.no_depth_test = true
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	xr_panel.add_child(label)
	return label


func _update_hover_color() -> void:
	for row in ASSET_ROWS:
		var action: String = row["action"]
		if xr_labels.has(action):
			xr_labels[action].modulate = Color(1.0, 0.88, 0.35) if action == hover_action else Color.WHITE
	for row in EDIT_ROWS:
		var action: String = row["action"]
		if xr_labels.has(action):
			var enabled: bool = edit_enabled.get(action, false)
			xr_labels[action].modulate = Color(1.0, 0.88, 0.35) if action == hover_action and enabled else (Color.WHITE if enabled else Color(0.45, 0.49, 0.55))
