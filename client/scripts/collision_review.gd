extends ColorRect
class_name WorldsmithCollisionReview

# Lists the meshes of a scene's environment with a collision role each. The
# server suggests the roles; a person corrects them here and saves. Every
# control is a list row, a button, or a spin box, so a headset pointer can use it.

signal closed(message: String)

const ROLES := ["walkable", "solid", "none"]
const ROLE_COLORS := {
	"walkable": Color(0.45, 0.9, 0.6),
	"solid": Color(0.95, 0.75, 0.4),
	"none": Color(0.6, 0.64, 0.7),
}

var api: Callable
var scene_id := ""
var meshes: Array = []
var suggested_spawn: Array = []
var heading: Label
var mesh_list: ItemList
var spawn_boxes: Array[SpinBox] = []
var status: Label


func _init(api_call: Callable) -> void:
	api = api_call
	color = Color(0.055, 0.075, 0.105)
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var padding := MarginContainer.new()
	padding.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]:
		padding.add_theme_constant_override("margin_" + side, 30)
	add_child(padding)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 12)
	padding.add_child(rows)
	heading = Label.new()
	heading.add_theme_font_size_override("font_size", 23)
	rows.add_child(heading)
	var help := Label.new()
	help.text = "Select a mesh to change its role. Walkable: you can stand on it and teleport to it. Solid: it blocks movement. None: you pass through it. A role also applies to meshes whose names contain that mesh's name."
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rows.add_child(help)
	mesh_list = ItemList.new()
	mesh_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mesh_list.item_clicked.connect(_on_mesh_clicked)
	rows.add_child(mesh_list)
	rows.add_child(_spawn_row())
	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rows.add_child(status)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 12)
	rows.add_child(actions)
	_button(actions, "Use Suggestions", _use_suggestions)
	_button(actions, "Save", _save)
	_button(actions, "Back to Home", func() -> void: _close(""))


func _spawn_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var label := Label.new()
	label.text = "Spawn point (meters; you start here and drop onto the ground)"
	row.add_child(label)
	for axis in ["X ", "Y ", "Z "]:
		var box := SpinBox.new()
		box.prefix = axis
		box.min_value = -100000
		box.max_value = 100000
		box.step = 0.1
		box.custom_minimum_size = Vector2(130, 0)
		spawn_boxes.append(box)
		row.add_child(box)
	return row


func _button(parent: Control, label: String, handler: Callable) -> void:
	var button := Button.new()
	button.text = label
	button.custom_minimum_size = Vector2(200, 38)
	button.pressed.connect(handler)
	parent.add_child(button)


func open(target_scene: String) -> void:
	scene_id = target_scene
	heading.text = "Review collision · " + scene_id
	meshes = []
	mesh_list.clear()
	status.text = "Measuring meshes…"
	visible = true
	var result: Dictionary = await api.call("/api/scenes/" + scene_id + "/collision")
	if not result["ok"]:
		status.text = str(result["message"])
		return
	var review: Dictionary = result["data"]
	meshes = review["meshes"]
	suggested_spawn = review["suggested_spawn"]
	_set_spawn(review["spawn"])
	for index in range(meshes.size()):
		mesh_list.add_item("")
		_show_row(index)
	status.text = "Saved roles are shown." if review["reviewed"] else "These roles are suggestions. Check them, then save."


func _set_spawn(spawn: Array) -> void:
	for axis in range(3):
		spawn_boxes[axis].value = float(spawn[axis])


func _show_row(index: int) -> void:
	var mesh: Dictionary = meshes[index]
	var size: Array = mesh["size"]
	mesh_list.set_item_text(index, "%s  ·  %.1f × %.1f × %.1f m  ·  %s" % [mesh["name"], size[0], size[1], size[2], mesh["role"]])
	mesh_list.set_item_custom_fg_color(index, ROLE_COLORS[mesh["role"]])


func _on_mesh_clicked(index: int, _at: Vector2, button: int) -> void:
	if button != MOUSE_BUTTON_LEFT:
		return
	var mesh: Dictionary = meshes[index]
	mesh["role"] = ROLES[(ROLES.find(mesh["role"]) + 1) % ROLES.size()]
	_show_row(index)
	mesh_list.deselect_all()


func _use_suggestions() -> void:
	if meshes.is_empty():
		return
	for index in range(meshes.size()):
		meshes[index]["role"] = meshes[index]["suggested"]
		_show_row(index)
	_set_spawn(suggested_spawn)
	status.text = "Suggestions restored. Save to keep them."


func _names_with(role: String) -> Array:
	var names := []
	for mesh in meshes:
		if mesh["role"] == role:
			names.append(mesh["name"])
	return names


func _save() -> void:
	if meshes.is_empty():
		return
	var payload := {
		"walkable": _names_with("walkable"),
		"solid": _names_with("solid"),
		"spawn": [spawn_boxes[0].value, spawn_boxes[1].value, spawn_boxes[2].value],
	}
	status.text = "Saving…"
	var result: Dictionary = await api.call("/api/scenes/" + scene_id + "/collision", HTTPClient.METHOD_PUT, payload)
	if not result["ok"]:
		status.text = str(result["message"])
		return
	_close("Collision saved for %s. Run Scene to walk it." % scene_id)


func _close(message: String) -> void:
	visible = false
	closed.emit(message)
