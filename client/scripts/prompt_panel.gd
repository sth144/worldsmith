extends Node3D
class_name WorldsmithPromptPanel

signal submitted(prompt: String)

const KEY_ROWS := ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
const KEY_STEP := 0.125

var is_open := false
var xr_active := false
var result_mode := false
var text_value := ""
var hovered := ""
var hover_point := Vector3.ZERO
var xr_panel: Node3D
var prompt_label: Label3D
var key_labels: Dictionary = {}
var desktop_panel: PanelContainer
var desktop_input: LineEdit
var desktop_title: Label
var xr_title: Label3D
var desktop_result_panel: PanelContainer
var desktop_result_text: TextEdit
var xr_result_panel: Node3D
var xr_result_text: Label3D
var xr_result_footer: Label3D
var result_pages: Array[String] = []
var result_page := 0


func _ready() -> void:
	_build_desktop()
	_build_xr()
	_build_result()


func open(xr: bool, camera: Camera3D, context: String = "Viewed ground") -> void:
	is_open = true
	xr_active = xr
	result_mode = false
	desktop_title.text = "Ask AI · " + context
	xr_title.text = "ASK AI  /  " + context.to_upper()
	desktop_input.placeholder_text = "Describe a change or addition"
	text_value = ""
	_update_text()
	desktop_result_panel.visible = false
	xr_result_panel.visible = false
	desktop_panel.visible = not xr
	xr_panel.visible = xr
	if xr:
		_position_xr(xr_panel, camera)
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		desktop_input.grab_focus()


func show_result(xr: bool, camera: Camera3D, details: String) -> void:
	is_open = true
	xr_active = xr
	result_mode = true
	desktop_panel.visible = false
	xr_panel.visible = false
	desktop_result_text.text = details
	desktop_result_panel.visible = not xr
	xr_result_panel.visible = xr
	result_pages = _paginate(details)
	result_page = 0
	_refresh_result_page()
	if xr:
		_position_xr(xr_result_panel, camera)
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _position_xr(panel: Node3D, camera: Camera3D) -> void:
	var forward := -camera.global_basis.z
	forward.y = 0.0
	forward = forward.normalized()
	panel.global_position = camera.global_position + forward * 1.3
	panel.global_basis = Basis.looking_at(forward, Vector3.UP)


func close() -> void:
	is_open = false
	desktop_panel.visible = false
	xr_panel.visible = false
	desktop_result_panel.visible = false
	xr_result_panel.visible = false
	if not xr_active:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func update_hover(ray_origin: Vector3, ray_direction: Vector3) -> bool:
	hovered = ""
	if not is_open or not xr_active:
		return false
	var panel: Node3D = xr_result_panel if result_mode else xr_panel
	var normal := panel.global_basis.z
	var denominator := ray_direction.dot(normal)
	if denominator > -0.05:
		_color_keys()
		return false
	var distance := (panel.global_position - ray_origin).dot(normal) / denominator
	if distance < 0.0 or distance > 3.0:
		_color_keys()
		return false
	hover_point = ray_origin + ray_direction * distance
	var local := panel.to_local(hover_point)
	if result_mode:
		if absf(local.x) <= 0.68 and local.y < -0.41 and local.y > -0.62:
			hovered = "PREV" if local.x < -0.22 else ("NEXT" if local.x < 0.22 else "CLOSE")
		return true
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
	if result_mode:
		match hovered:
			"PREV":
				result_page = maxi(0, result_page - 1)
				_refresh_result_page()
			"NEXT":
				result_page = mini(result_pages.size() - 1, result_page + 1)
				_refresh_result_page()
			"CLOSE":
				close()
		return
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
	desktop_title = Label.new()
	rows.add_child(desktop_title)
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
	xr_title = _add_label("ASK AI  /  SELECTED OBJECT", Vector3(-0.62, 0.45, 0.018), 27)
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


func _build_result() -> void:
	desktop_result_panel = PanelContainer.new()
	desktop_result_panel.position = Vector2(260, 110)
	desktop_result_panel.custom_minimum_size = Vector2(760, 540)
	desktop_result_panel.visible = false
	desktop_panel.get_parent().add_child(desktop_result_panel)
	var rows := VBoxContainer.new()
	desktop_result_panel.add_child(rows)
	var heading := Label.new()
	heading.text = "AI output · structured proposal and server response"
	rows.add_child(heading)
	desktop_result_text = TextEdit.new()
	desktop_result_text.editable = false
	desktop_result_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rows.add_child(desktop_result_text)
	var close_button := Button.new()
	close_button.text = "Close"
	close_button.pressed.connect(close)
	rows.add_child(close_button)

	xr_result_panel = Node3D.new()
	xr_result_panel.visible = false
	add_child(xr_result_panel)
	var background := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.42, 1.22, 0.025)
	background.mesh = box
	var surface := StandardMaterial3D.new()
	surface.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	surface.albedo_color = Color(0.035, 0.055, 0.085, 0.97)
	surface.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	surface.no_depth_test = true
	background.material_override = surface
	xr_result_panel.add_child(background)
	xr_result_panel.add_child(_result_label("AI OUTPUT", Vector3(-0.62, 0.50, 0.018), 27))
	xr_result_text = _result_label("", Vector3(-0.62, 0.38, 0.018), 19)
	xr_result_panel.add_child(xr_result_text)
	xr_result_footer = _result_label("", Vector3(-0.62, -0.34, 0.018), 20)
	xr_result_panel.add_child(xr_result_footer)
	xr_result_panel.add_child(_result_label("PREV", Vector3(-0.53, -0.52, 0.018), 24))
	xr_result_panel.add_child(_result_label("NEXT", Vector3(-0.11, -0.52, 0.018), 24))
	xr_result_panel.add_child(_result_label("CLOSE", Vector3(0.31, -0.52, 0.018), 24))


func _result_label(value: String, location: Vector3, size: int) -> Label3D:
	var label := Label3D.new()
	label.text = value
	label.position = location
	label.font_size = size
	label.pixel_size = 0.002
	label.no_depth_test = true
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	return label


func _paginate(details: String) -> Array[String]:
	var lines: Array[String] = []
	for raw_line in details.left(16000).split("\n", true):
		var remaining := str(raw_line)
		while remaining.length() > 54:
			lines.append(remaining.substr(0, 54))
			remaining = remaining.substr(54)
		lines.append(remaining)
	var pages: Array[String] = []
	for index in range(0, lines.size(), 11):
		pages.append("\n".join(lines.slice(index, mini(index + 11, lines.size()))))
	if pages.is_empty():
		pages.append("No output")
	return pages


func _refresh_result_page() -> void:
	xr_result_text.text = result_pages[result_page]
	xr_result_footer.text = "Page %d / %d" % [result_page + 1, result_pages.size()]


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
