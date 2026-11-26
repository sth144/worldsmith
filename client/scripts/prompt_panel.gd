extends Node3D
class_name WorldsmithPromptPanel

signal submitted(prompt: String, provider: String)
signal voice_toggled
signal closed

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
var xr_provider: Label3D
var xr_voice_status: Label3D
var desktop_voice_status: Label
var desktop_voice_button: Button
var desktop_provider: OptionButton
var provider := "codex"
var creation_mode := "reviewed"
var context_label := "Viewed ground"
var desktop_creation_mode: OptionButton
var desktop_planning_note: Label
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
	context_label = context
	desktop_title.text = "Scene command · " + context
	xr_title.text = "SCENE COMMAND"
	_refresh_provider()
	text_value = ""
	_update_text()
	set_voice_status("Tap VOICE to speak", false)
	desktop_result_panel.visible = false
	xr_result_panel.visible = false
	desktop_panel.visible = not xr
	xr_panel.visible = xr
	if xr:
		_position_xr(xr_panel, camera)
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		desktop_input.grab_focus()


func open_scene_planner(xr: bool, camera: Camera3D) -> void:
	creation_mode = "scene_brief"
	open(xr, camera, "New scene")


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
	closed.emit()


func set_transcript(value: String) -> void:
	if not is_open or result_mode:
		return
	text_value = value.left(200)
	_update_text()


func set_voice_status(message: String, recording: bool) -> void:
	if is_instance_valid(xr_voice_status):
		xr_voice_status.text = message.left(58)
	if is_instance_valid(desktop_voice_status):
		desktop_voice_status.text = message
	if is_instance_valid(desktop_voice_button):
		desktop_voice_button.text = "Stop recording" if recording else "Record voice"


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
	if local.y > 0.39 and local.x > 0.25:
		hovered = "PROVIDER"
		_color_keys()
		return true
	if local.y > 0.39 and local.x < 0.25:
		hovered = "QUALITY"
		_color_keys()
		return true
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
		hovered = "VOICE" if local.x < 0.05 else "CANCEL"
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
		"PROVIDER":
			provider = "claude" if provider == "codex" else "codex"
			_refresh_provider()
		"QUALITY":
			creation_mode = "draft" if creation_mode == "reviewed" else ("scene_brief" if creation_mode == "draft" else "reviewed")
			_refresh_provider()
		"BACK":
			text_value = text_value.substr(0, maxi(0, text_value.length() - 1))
		"SPACE":
			text_value += " "
		"SEND":
			_submit(text_value)
		"CANCEL":
			close()
		"VOICE":
			voice_toggled.emit()
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
	submitted.emit(cleaned, provider)


func _update_text() -> void:
	if is_instance_valid(prompt_label):
		var lines: Array[String] = []
		var remaining := text_value
		while not remaining.is_empty():
			lines.append(remaining.left(50))
			remaining = remaining.substr(mini(50, remaining.length()))
		prompt_label.text = "Command: " + "\n".join(lines)
	if is_instance_valid(desktop_input):
		desktop_input.text = text_value


func _build_desktop() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 2
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
	desktop_provider = OptionButton.new()
	desktop_provider.add_item("Codex", 0)
	desktop_provider.add_item("Claude", 1)
	desktop_provider.item_selected.connect(func(index: int) -> void:
		provider = "claude" if index == 1 else "codex"
	)
	rows.add_child(desktop_provider)
	desktop_creation_mode = OptionButton.new()
	desktop_creation_mode.add_item("Reviewed asset for new objects", 0)
	desktop_creation_mode.add_item("Quick draft shapes", 1)
	desktop_creation_mode.add_item("Plan this scene", 2)
	desktop_creation_mode.item_selected.connect(func(index: int) -> void:
		creation_mode = "scene_brief" if index == 2 else ("draft" if index == 1 else "reviewed")
		_refresh_provider()
	)
	rows.add_child(desktop_creation_mode)
	desktop_planning_note = Label.new()
	desktop_planning_note.text = "Planning saves a production brief. Scene geometry and assets are not generated in this step."
	desktop_planning_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rows.add_child(desktop_planning_note)
	desktop_input = LineEdit.new()
	desktop_input.placeholder_text = "Make this chair twice as wide"
	desktop_input.text_submitted.connect(_submit)
	rows.add_child(desktop_input)
	desktop_voice_button = Button.new()
	desktop_voice_button.text = "Record voice"
	desktop_voice_button.pressed.connect(func() -> void: voice_toggled.emit())
	rows.add_child(desktop_voice_button)
	desktop_voice_status = Label.new()
	rows.add_child(desktop_voice_status)
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
	xr_title = _add_label("SCENE COMMAND", Vector3(-0.62, 0.45, 0.018), 27)
	xr_provider = _add_label("CODEX  ↔", Vector3(0.28, 0.45, 0.018), 22)
	prompt_label = _add_label("Command: ", Vector3(-0.62, 0.33, 0.018), 18)
	xr_voice_status = _add_label("Tap VOICE to speak", Vector3(-0.62, 0.17, 0.018), 16)
	for row_index in range(KEY_ROWS.size()):
		var letters: String = KEY_ROWS[row_index]
		var start_x := -KEY_STEP * float(letters.length() - 1) * 0.5
		for column in range(letters.length()):
			var letter := letters.substr(column, 1)
			key_labels[letter] = _add_label(letter, Vector3(start_x + column * KEY_STEP - 0.015, 0.10 - row_index * 0.15, 0.018), 31)
	key_labels["BACK"] = _add_label("⌫", Vector3(-0.52, -0.35, 0.018), 27)
	key_labels["SPACE"] = _add_label("SPACE", Vector3(-0.16, -0.35, 0.018), 25)
	key_labels["SEND"] = _add_label("SEND", Vector3(0.37, -0.35, 0.018), 25)
	key_labels["VOICE"] = _add_label("VOICE", Vector3(-0.47, -0.49, 0.018), 21)
	key_labels["CANCEL"] = _add_label("CANCEL", Vector3(0.20, -0.49, 0.018), 21)


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


func _refresh_provider() -> void:
	if is_instance_valid(desktop_provider):
		desktop_provider.select(1 if provider == "claude" else 0)
	if is_instance_valid(desktop_creation_mode):
		desktop_creation_mode.select(2 if creation_mode == "scene_brief" else (1 if creation_mode == "draft" else 0))
	if is_instance_valid(desktop_title):
		desktop_title.text = "Plan this scene from prompt" if creation_mode == "scene_brief" else "Scene command · " + context_label
	if is_instance_valid(desktop_input):
		desktop_input.placeholder_text = "Describe the scene you want to create" if creation_mode == "scene_brief" else "Describe a change or addition"
	if is_instance_valid(desktop_planning_note):
		desktop_planning_note.visible = creation_mode == "scene_brief"
	if is_instance_valid(xr_provider):
		xr_provider.text = ("CLAUDE" if provider == "claude" else "CODEX") + "  ↔"
	if is_instance_valid(xr_title):
		xr_title.text = ("PLAN SCENE" if creation_mode == "scene_brief" else ("DRAFT" if creation_mode == "draft" else "REVIEWED")) + "  ↔"


func _color_keys() -> void:
	for key in key_labels:
		(key_labels[key] as Label3D).modulate = Color(1.0, 0.88, 0.35) if key == hovered else Color.WHITE
