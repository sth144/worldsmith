extends Node3D
class_name WorldsmithPromptPanel

signal submitted(prompt: String)

const KEY_ROWS := ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
const KEY_STEP := 0.125

var is_open := false
var xr_active := false
var text_value := ""
var hovered := ""
var hover_point := Vector3.ZERO
var xr_panel: Node3D
var prompt_label: Label3D
var key_labels: Dictionary = {}
var desktop_panel: PanelContainer
var desktop_input: LineEdit


func _ready() -> void:
	_build_desktop()
	_build_xr()


func open(xr: bool, camera: Camera3D) -> void:
	is_open = true
	xr_active = xr
	text_value = ""
	_update_text()
	desktop_panel.visible = not xr
	xr_panel.visible = xr
	if xr:
		var forward := -camera.global_basis.z
		forward.y = 0.0
		forward = forward.normalized()
		xr_panel.global_position = camera.global_position + forward * 1.3
		xr_panel.global_basis = Basis.looking_at(forward, Vector3.UP)
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		desktop_input.grab_focus()


func close() -> void:
	is_open = false
	desktop_panel.visible = false
	xr_panel.visible = false
	if not xr_active:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func update_hover(ray_origin: Vector3, ray_direction: Vector3) -> bool:
	hovered = ""
	if not is_open or not xr_active:
		return false
	var normal := xr_panel.global_basis.z
	var denominator := ray_direction.dot(normal)
	if denominator > -0.05:
		_color_keys()
		return false
	var distance := (xr_panel.global_position - ray_origin).dot(normal) / denominator
	if distance < 0.0 or distance > 3.0:
		_color_keys()
		return false
	hover_point = ray_origin + ray_direction * distance
	var local := xr_panel.to_local(hover_point)
	if absf(local.x) > 0.68 or absf(local.y) > 0.54:
		_color_keys()
		return false
	var row := int(round((0.10 - local.y) / 0.15))
	if row >= 0 and row < KEY_ROWS.size():
		var letters: String = KEY_ROWS[row]
		var start_x := -KEY_STEP * float(letters.length() - 1) * 0.5
		var col := int(round((local.x - start_x) / KEY_STEP))
		if col >= 0 and col < letters.length() and absf(local.x - start_x - col * KEY_STEP) < 0.052:
			hovered = letters.substr(col, 1)
	elif row == 3:
		if local.x < -0.30:
			hovered = "BACK"
		elif local.x < 0.22:
			hovered = "SPACE"
		else:
			hovered = "SEND"
	elif row == 4:
		hovered = "CANCEL"
	_color_keys()
	return true


func activate_hovered() -> void:
	match hovered:
		"BACK":
			text_value = text_value.substr(0, maxi(0, text_value.length() - 1))
		"SPACE":
			text_value += " "
		"SEND":
			_submit(text_value)
		"CANCEL":
			close()
		"":
			pass
		_:
			if text_value.length() < 200:
				text_value += hovered
	_update_text()


func _submit(value: String) -> void:
	var cleaned := value.strip_edges()
	if cleaned.length() < 3:
		return
	close()
	submitted.emit(cleaned)


func _update_text() -> void:
	if is_instance_valid(prompt_label):
		prompt_label.text = "Request: " + text_value.right(45)
	if is_instance_valid(desktop_input):
		desktop_input.text = text_value


func _build_desktop() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	desktop_panel = PanelContainer.new()
	desktop_panel.position = Vector2(320, 180)
	desktop_panel.custom_minimum_size = Vector2(650, 0)
	desktop_panel.visible = false
	layer.add_child(desktop_panel)
	var rows := VBoxContainer.new()
	desktop_panel.add_child(rows)
	var title := Label.new()
	title.text = "Ask AI to edit the selected object"
	rows.add_child(title)
	desktop_input = LineEdit.new()
	desktop_input.placeholder_text = "Make this chair twice as wide"
	desktop_input.text_submitted.connect(_submit)
	rows.add_child(desktop_input)
	var send := Button.new()
	send.text = "Send"
	send.pressed.connect(func() -> void: _submit(desktop_input.text))
	rows.add_child(send)


func _build_xr() -> void:
	xr_panel = Node3D.new()
	xr_panel.visible = false
	add_child(xr_panel)
	var background := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.42, 1.12, 0.025)
	background.mesh = box
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.035, 0.055, 0.085, 0.97)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	background.material_override = material
	xr_panel.add_child(background)
	_add_label("ASK AI  /  SELECTED OBJECT", Vector3(-0.62, 0.45, 0.018), 27)
	prompt_label = _add_label("Request: ", Vector3(-0.62, 0.30, 0.018), 21)
	for row_index in range(KEY_ROWS.size()):
		var letters: String = KEY_ROWS[row_index]
		var start_x := -KEY_STEP * float(letters.length() - 1) * 0.5
		for column in range(letters.length()):
			var letter := letters.substr(column, 1)
			key_labels[letter] = _add_label(letter, Vector3(start_x + column * KEY_STEP - 0.015, 0.10 - row_index * 0.15, 0.018), 31)
	key_labels["BACK"] = _add_label("⌫", Vector3(-0.52, -0.35, 0.018), 27)
	key_labels["SPACE"] = _add_label("SPACE", Vector3(-0.16, -0.35, 0.018), 25)
	key_labels["SEND"] = _add_label("SEND", Vector3(0.37, -0.35, 0.018), 25)
	key_labels["CANCEL"] = _add_label("CANCEL", Vector3(-0.13, -0.49, 0.018), 21)


func _add_label(value: String, location: Vector3, size: int) -> Label3D:
	var label := Label3D.new()
	label.text = value
	label.position = location
	label.font_size = size
	label.pixel_size = 0.002
	label.no_depth_test = true
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	xr_panel.add_child(label)
	return label


func _color_keys() -> void:
	for key in key_labels:
		(key_labels[key] as Label3D).modulate = Color(1.0, 0.88, 0.35) if key == hovered else Color.WHITE
