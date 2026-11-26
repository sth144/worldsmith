extends Control

const DEFAULT_SERVER := "ws://127.0.0.1:8765"
const SETTINGS_PATH := "user://worldsmith-settings.cfg"
const MAX_IMPORT_BYTES := 256 * 1024 * 1024

# READY works everywhere. DESKTOP needs local files, a keyboard, or Blender.
# PLANNED is shown so the home screen lays out the remaining work.
enum Availability { READY, DESKTOP, PLANNED }

var server_url := DEFAULT_SERVER
var default_provider := "codex"
var scenes: Array = []
var assets: Array = []
var selected_scene := ""
var selected_asset := ""
var scenes_view: HBoxContainer
var assets_view: HBoxContainer
var scene_rows: VBoxContainer
var asset_rows: VBoxContainer
var scene_detail: VBoxContainer
var asset_detail: VBoxContainer
var scene_buttons: Dictionary = {}
var asset_buttons: Dictionary = {}
var connection_label: Label
var status_label: Label
var waiting_requests := -1
var scene_requests: Dictionary = {}
var import_target := ""
var brief_panel: ColorRect
var brief_text: TextEdit
var panel_mode := false
var collision_review: WorldsmithCollisionReview
var create_dialog: ConfirmationDialog
var create_id: LineEdit
var asset_dialog: ConfirmationDialog
var asset_prompt: LineEdit
var scene_file_dialog: FileDialog
var asset_file_dialog: FileDialog
var settings_dialog: ConfirmationDialog
var settings_url: LineEdit
var settings_provider: OptionButton


func _ready() -> void:
	# The headset shows this same screen inside a SubViewport on a 3D panel.
	panel_mode = get_viewport() is SubViewport
	_load_settings()
	var arguments := OS.get_cmdline_user_args()
	if arguments.has("--open-scene") or arguments.has("--offline") or _has_preview_arguments(arguments):
		var selected := _argument_value(arguments, "--scene-id=")
		if not selected.is_empty():
			get_tree().root.set_meta("worldsmith_scene_id", selected)
		get_tree().root.set_meta("worldsmith_server_url", server_url)
		get_tree().change_scene_to_file("res://scenes/main.tscn")
		return
	if not panel_mode and (OS.has_feature("android") or arguments.has("--xr-home")):
		get_tree().change_scene_to_file("res://scenes/home_xr.tscn")
		return
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_build_interface()
	call_deferred("_refresh_all")


func _has_preview_arguments(arguments: PackedStringArray) -> bool:
	for argument in arguments:
		if argument.begins_with("--preview-config=") or argument.begins_with("--preview-glb="):
			return true
	return false


func _argument_value(arguments: PackedStringArray, prefix: String) -> String:
	for argument in arguments:
		if argument.begins_with(prefix):
			return argument.trim_prefix(prefix)
	return ""


func _load_settings() -> void:
	# A headset build cannot edit settings, so it uses the packaged server address.
	if OS.has_feature("android") and FileAccess.file_exists("res://server.json"):
		var packaged: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://server.json"))
		if packaged is Dictionary:
			server_url = str(packaged.get("url", server_url)).trim_suffix("/")
	var settings := ConfigFile.new()
	if settings.load(SETTINGS_PATH) == OK:
		server_url = str(settings.get_value("connection", "server_url", DEFAULT_SERVER))
		default_provider = str(settings.get_value("creation", "provider", "codex"))
	if default_provider != "codex" and default_provider != "claude":
		default_provider = "codex"
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--server-url="):
			server_url = argument.trim_prefix("--server-url=")


func _build_interface() -> void:
	theme = WorldsmithTheme.build()
	var background := ColorRect.new()
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.color = WorldsmithTheme.GROUND
	add_child(background)
	var outer := _margin(32)
	outer.add_theme_constant_override("margin_top", 20)
	outer.add_theme_constant_override("margin_bottom", 18)
	outer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(outer)
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 16)
	outer.add_child(page)
	page.add_child(_build_header())
	scenes_view = _build_view(page, "Scenes", [
		["New scene", func() -> void: create_dialog.popup_centered(Vector2i(520, 190))],
		["Import a GLB", func() -> void: _choose_geometry("")],
	])
	scene_rows = scenes_view.get_meta("rows")
	scene_detail = scenes_view.get_meta("detail")
	assets_view = _build_view(page, "Asset library", [
		["Import an asset", func() -> void: asset_file_dialog.popup_centered_ratio()],
		["Request an asset", func() -> void: asset_dialog.popup_centered(Vector2i(520, 190))],
	])
	asset_rows = assets_view.get_meta("rows")
	asset_detail = assets_view.get_meta("detail")
	assets_view.visible = false
	status_label = WorldsmithTheme.label("Connecting to the scene server…", 14, WorldsmithTheme.MUTED)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(status_label)
	_build_dialogs()
	_build_brief_panel()
	collision_review = WorldsmithCollisionReview.new(_api)
	collision_review.closed.connect(_on_collision_review_closed)
	add_child(collision_review)


func _margin(size: int) -> MarginContainer:
	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, size)
	return margin


func _build_header() -> HBoxContainer:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	var wordmark := WorldsmithTheme.label("Worldsmith", 30, WorldsmithTheme.CHALK, WorldsmithTheme.serif(600))
	header.add_child(wordmark)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(28, 0)
	header.add_child(gap)
	var tabs := ButtonGroup.new()
	_tab(header, tabs, "Scenes", true)
	_tab(header, tabs, "Asset library", false)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	connection_label = WorldsmithTheme.label("", 13, WorldsmithTheme.MUTED)
	connection_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(connection_label)
	_button(header, "Settings", func() -> void: settings_dialog.popup_centered(Vector2i(520, 260)), Availability.DESKTOP)
	return header


func _tab(parent: Control, group: ButtonGroup, label: String, scenes_tab: bool) -> void:
	var tab := Button.new()
	tab.text = label
	tab.theme_type_variation = "TabButton"
	tab.toggle_mode = true
	tab.button_group = group
	tab.button_pressed = scenes_tab
	tab.pressed.connect(func() -> void:
		scenes_view.visible = scenes_tab
		assets_view.visible = not scenes_tab
	)
	parent.add_child(tab)


# A list on the left and a sheet for the chosen entry on the right.
func _build_view(page: Control, heading: String, actions: Array) -> HBoxContainer:
	var view := HBoxContainer.new()
	view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	view.add_theme_constant_override("separation", 28)
	page.add_child(view)
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 10)
	view.add_child(column)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	column.add_child(top)
	var title := WorldsmithTheme.label(heading, 22, WorldsmithTheme.CHALK, WorldsmithTheme.serif())
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(title)
	for action in actions:
		_button(top, action[0], action[1], Availability.DESKTOP)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 0)
	scroll.add_child(rows)
	var sheet := PanelContainer.new()
	sheet.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view.add_child(sheet)
	var padding := _margin(14)
	sheet.add_child(padding)
	var detail := VBoxContainer.new()
	detail.add_theme_constant_override("separation", 12)
	padding.add_child(detail)
	view.set_meta("rows", rows)
	view.set_meta("detail", detail)
	return view


func _button(parent: Control, label: String, handler: Callable, availability := Availability.READY, primary := false) -> Button:
	var button := Button.new()
	button.text = label
	button.custom_minimum_size = Vector2(0, 40)
	if primary:
		button.theme_type_variation = "PrimaryButton"
		button.custom_minimum_size = Vector2(0, 48)
	if availability == Availability.PLANNED:
		button.text += " · not built yet"
		button.disabled = true
	elif availability == Availability.DESKTOP and panel_mode:
		button.text += " · desktop only"
		button.disabled = true
	else:
		button.pressed.connect(handler)
	parent.add_child(button)
	return button


# One entry in a list: a serif name, a quiet second line, and its state on the right.
func _row(parent: Control, group: ButtonGroup, title: String, subtitle: String, state: String, state_color: Color) -> Button:
	var row := Button.new()
	row.theme_type_variation = "RowButton"
	row.toggle_mode = true
	row.button_group = group
	row.custom_minimum_size = Vector2(0, 66)
	parent.add_child(row)
	var padding := _margin(14)
	padding.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	padding.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(padding)
	var line := HBoxContainer.new()
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_theme_constant_override("separation", 14)
	padding.add_child(line)
	var words := VBoxContainer.new()
	words.mouse_filter = Control.MOUSE_FILTER_IGNORE
	words.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	words.alignment = BoxContainer.ALIGNMENT_CENTER
	words.add_theme_constant_override("separation", 0)
	line.add_child(words)
	var name_label := WorldsmithTheme.label(title, 19, WorldsmithTheme.CHALK, WorldsmithTheme.serif())
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	words.add_child(name_label)
	if not subtitle.is_empty():
		words.add_child(WorldsmithTheme.label(subtitle, 13, WorldsmithTheme.MUTED))
	var state_label := WorldsmithTheme.label(state, 14, state_color)
	state_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(state_label)
	return row


func _clear(container: Control) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()


func _note(parent: Control, text: String, size: int = 15, color: Color = WorldsmithTheme.MUTED) -> Label:
	var note := WorldsmithTheme.label(text, size, color)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(note)
	return note


func _refresh_all() -> void:
	status_label.text = "Loading scenes and assets…"
	var scene_result := await _api("/api/scenes")
	_show_connection(scene_result["ok"])
	if not scene_result["ok"]:
		status_label.text = str(scene_result["message"])
		return
	scenes = scene_result["data"]
	var asset_result := await _api("/api/library/assets")
	if not asset_result["ok"]:
		status_label.text = str(asset_result["message"])
		return
	assets = []
	for item in asset_result["data"]:
		if item["kind"] == "mesh":
			assets.append(item)
	var requests_result := await _api("/api/library/requests")
	waiting_requests = (requests_result["data"] as Array).size() if requests_result["ok"] else -1
	scene_requests = {}
	var queue_result := await _api("/api/requests")
	for job in (queue_result["data"] if queue_result["ok"] else []):
		scene_requests.get_or_add(str(job["scene_id"]), []).append(job)
	_fill_scene_rows()
	_fill_asset_rows()
	var preferred := selected_scene
	if preferred.is_empty():
		preferred = str(get_tree().root.get_meta("worldsmith_scene_id", ""))
	if preferred.is_empty():
		preferred = _argument_value(OS.get_cmdline_user_args(), "--scene-id=")
	_select_scene_id(preferred)
	_select_asset_id(selected_asset)
	status_label.text = ""


func _show_connection(online: bool) -> void:
	var host := _http_base().trim_prefix("http://").trim_prefix("https://")
	connection_label.text = ("Connected to " if online else "Can't reach ") + host
	connection_label.add_theme_color_override("font_color", WorldsmithTheme.MOSS if online else WorldsmithTheme.CLAY)


func _fill_scene_rows() -> void:
	_clear(scene_rows)
	scene_buttons = {}
	var group := ButtonGroup.new()
	for item in scenes:
		var scene_id := str(item["scene_id"])
		var title := _scene_title(item)
		var row := _row(scene_rows, group, title if not title.is_empty() else scene_id,
			scene_id if not title.is_empty() else "", _scene_state(item), _scene_color(item))
		row.pressed.connect(_on_scene_selected.bind(scene_id))
		scene_buttons[scene_id] = row
	if scenes.is_empty():
		_note(scene_rows, "No scenes yet. Create one, or import a GLB exported from Blender.")


func _fill_asset_rows() -> void:
	_clear(asset_rows)
	asset_buttons = {}
	var group := ButtonGroup.new()
	for item in assets:
		var asset_id := str(item["asset_id"])
		var reviewed := bool(item.get("metadata", {}).get("godot_review", false))
		var row := _row(asset_rows, group, asset_id, str(item["origin"]).capitalize(),
			"Reviewed" if reviewed else "Not reviewed", WorldsmithTheme.MOSS if reviewed else WorldsmithTheme.MUTED)
		row.pressed.connect(_on_asset_selected.bind(asset_id))
		asset_buttons[asset_id] = row
	if assets.is_empty():
		_note(asset_rows, "No reusable meshes yet. Import a GLB to start the library.")


# Selects the named scene, or the first one when it is not listed.
func _select_scene_id(scene_id: String) -> void:
	if not scene_buttons.has(scene_id):
		scene_id = str(scenes[0]["scene_id"]) if not scenes.is_empty() else ""
	if scene_buttons.has(scene_id):
		(scene_buttons[scene_id] as Button).button_pressed = true
	_on_scene_selected(scene_id)


func _select_asset_id(asset_id: String) -> void:
	if not asset_buttons.has(asset_id):
		asset_id = str(assets[0]["asset_id"]) if not assets.is_empty() else ""
	if asset_buttons.has(asset_id):
		(asset_buttons[asset_id] as Button).button_pressed = true
	_on_asset_selected(asset_id)


func _on_scene_selected(scene_id: String) -> void:
	selected_scene = scene_id
	_clear(scene_detail)
	var item := _selected_scene_item()
	if item.is_empty():
		_note(scene_detail, "Scenes you create or import appear here.")
		return
	var title := _scene_title(item)
	var heading := _note(scene_detail, title if not title.is_empty() else scene_id, 26, WorldsmithTheme.CHALK)
	heading.add_theme_font_override("font", WorldsmithTheme.serif())
	heading.max_lines_visible = 2
	heading.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_note(scene_detail, "%s, revision %d, %d placed objects" % [scene_id, item["revision"], item["object_count"]], 13)
	_note(scene_detail, _scene_summary(item), 17, _scene_color(item))
	for line in _request_lines(scene_id):
		_note(scene_detail, line, 13)
	var actions := _scene_actions(item)
	_button(scene_detail, actions[0][0], actions[0][1], actions[0][2], true)
	var others := HFlowContainer.new()
	others.add_theme_constant_override("h_separation", 8)
	others.add_theme_constant_override("v_separation", 8)
	scene_detail.add_child(others)
	for action in actions.slice(1):
		_button(others, action[0], action[1], action[2])
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scene_detail.add_child(spacer)
	_note(scene_detail, "From prompt to walkable scene", 13)
	var steps := _scene_steps(item)
	for index in range(steps.size()):
		_step(scene_detail, index + 1, steps[index])


# The prompt a scene was planned from, when it has one, reads better than its ID.
func _scene_title(item: Dictionary) -> String:
	var title := str(item.get("title", ""))
	return title.left(1).to_upper() + title.substr(1)


# What people have asked for in this scene that has not been placed yet.
func _request_lines(scene_id: String) -> Array[String]:
	var states := {"needs_asset": "waiting for an agent", "in_progress": "being built", "failed": "could not be made"}
	var lines: Array[String] = []
	for job in scene_requests.get(scene_id, []):
		var line := "Requested: \"%s\" is %s" % [str(job["prompt"]).left(60), states.get(job["status"], str(job["status"]))]
		if job.has("note"):
			line += " (%s)" % str(job["note"]).left(80)
		lines.append(line)
	return lines.slice(0, 3)


func _scene_state(item: Dictionary) -> String:
	if item["has_walkable"]:
		return "Walkable"
	if item["has_environment"]:
		return "Needs collision review"
	return "Planned" if item["has_brief"] else "Empty"


func _scene_color(item: Dictionary) -> Color:
	if item["has_walkable"]:
		return WorldsmithTheme.MOSS
	if item["has_environment"]:
		return WorldsmithTheme.CLAY
	return WorldsmithTheme.SKY if item["has_brief"] else WorldsmithTheme.MUTED


func _scene_summary(item: Dictionary) -> String:
	if item["has_walkable"]:
		return "Ready to walk."
	if item["has_environment"]:
		return "It has geometry, but nothing to stand on yet."
	return "Planned. It has no geometry yet." if item["has_brief"] else "Empty. Plan it, or add geometry."


# What can be done with a scene, most useful first. The first entry is the main button.
func _scene_actions(item: Dictionary) -> Array:
	var has_geometry := bool(item["has_environment"])
	var has_brief := bool(item["has_brief"])
	var actions: Array = []
	if item["has_walkable"]:
		actions.append(["Run scene", func() -> void: _open_selected_scene(true), Availability.READY])
	if has_geometry:
		actions.append(["Review collision", _review_collision, Availability.READY])
	elif not has_brief:
		actions.append(["Plan this scene", _plan_selected_scene, Availability.DESKTOP])
	if not has_geometry:
		actions.append(["Add geometry from a GLB", func() -> void: _choose_geometry(selected_scene), Availability.DESKTOP])
	if has_brief:
		actions.append(["View brief", _view_brief, Availability.READY])
	actions.append(["Edit scene", func() -> void: _open_selected_scene(false), Availability.READY])
	if has_brief and not has_geometry:
		actions.append(["Plan again", _plan_selected_scene, Availability.DESKTOP])
	if not has_geometry:
		actions.append(["Build from brief", Callable(), Availability.PLANNED])
	return actions


# The four stages every scene passes through, with where this one stands.
func _scene_steps(item: Dictionary) -> Array:
	var done := WorldsmithTheme.MOSS
	var next := WorldsmithTheme.BRASS
	var waiting := WorldsmithTheme.FAINT
	var has_geometry := bool(item["has_environment"])
	var walkable := bool(item["has_walkable"])
	return [
		["Plan", "Brief saved" if item["has_brief"] else "No brief. Optional when you import geometry.",
			done if item["has_brief"] else waiting],
		["Build geometry", "Environment imported" if has_geometry else "Import a GLB for now. Building from a brief is not built yet.",
			done if has_geometry else next],
		["Review collision", "Walkable surfaces and spawn point saved" if walkable else ("Needs your review" if has_geometry else "Waits for geometry"),
			done if walkable else (next if has_geometry else waiting)],
		["Walk and edit", "Ready on desktop and headset" if walkable else "Waits for collision",
			done if walkable else waiting],
	]


func _step(parent: Control, number: int, step: Array) -> void:
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 12)
	parent.add_child(line)
	var marker := WorldsmithTheme.label(str(number), 20, step[2], WorldsmithTheme.serif())
	marker.custom_minimum_size = Vector2(20, 0)
	line.add_child(marker)
	var words := VBoxContainer.new()
	words.add_theme_constant_override("separation", 0)
	words.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(words)
	words.add_child(WorldsmithTheme.label(step[0], 15))
	_note(words, step[1], 13)


func _on_asset_selected(asset_id: String) -> void:
	selected_asset = asset_id
	_clear(asset_detail)
	var item := {}
	for candidate in assets:
		if candidate["asset_id"] == asset_id:
			item = candidate
	if item.is_empty():
		_note(asset_detail, "Reusable meshes you import appear here.")
		return
	var reviewed := bool(item.get("metadata", {}).get("godot_review", false))
	var heading := _note(asset_detail, asset_id, 28, WorldsmithTheme.CHALK)
	heading.add_theme_font_override("font", WorldsmithTheme.serif())
	_note(asset_detail, "%s mesh" % str(item["origin"]).capitalize(), 13)
	_note(asset_detail, "Reviewed in Godot. It can fulfil an asset request." if reviewed else "Not reviewed yet, so it can't fulfil an asset request.",
		17, WorldsmithTheme.MOSS if reviewed else WorldsmithTheme.CLAY)
	_button(asset_detail, "Edit in Blender", _edit_selected_asset, Availability.DESKTOP, true)
	var others := HFlowContainer.new()
	others.add_theme_constant_override("h_separation", 8)
	others.add_theme_constant_override("v_separation", 8)
	asset_detail.add_child(others)
	_button(others, "Review and promote", Callable(), Availability.PLANNED)
	_button(others, "Generate asset", Callable(), Availability.PLANNED)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	asset_detail.add_child(spacer)
	if waiting_requests >= 0:
		_note(asset_detail, "%d asset requests are waiting to be produced." % waiting_requests, 13)


func _choose_geometry(target_scene: String) -> void:
	import_target = target_scene
	scene_file_dialog.popup_centered_ratio()


func _import_scene(path: String) -> void:
	var bytes := _read_glb(path)
	if bytes.is_empty():
		return
	var scene_id := import_target
	status_label.text = "Importing scene…"
	if scene_id.is_empty():
		scene_id = _slug(path.get_file()) + "-" + str(int(Time.get_unix_time_from_system()))
		var created := await _api("/api/scenes", HTTPClient.METHOD_POST, {"scene_id": scene_id})
		if not created["ok"]:
			status_label.text = str(created["message"])
			return
	var uploaded := await _upload("/api/scenes/" + scene_id + "/environment", bytes, path.get_file())
	selected_scene = scene_id
	await _refresh_all()
	if not uploaded["ok"]:
		status_label.text = "GLB import failed: " + str(uploaded["message"])
		return
	status_label.text = "Imported the GLB. Review its collision to make it walkable."
	collision_review.open(scene_id)


func _build_dialogs() -> void:
	create_dialog = ConfirmationDialog.new()
	create_dialog.title = "Create Scene"
	var create_rows := _dialog_rows(create_dialog)
	create_rows.add_child(_field_label("Create an empty project. Plan or import geometry afterward."))
	create_id = LineEdit.new()
	create_id.placeholder_text = "scene-id"
	create_rows.add_child(create_id)
	create_dialog.confirmed.connect(_create_scene)
	add_child(create_dialog)
	asset_dialog = ConfirmationDialog.new()
	asset_dialog.title = "Request Asset"
	var asset_rows := _dialog_rows(asset_dialog)
	asset_rows.add_child(_field_label("Save an asset production request. Geometry is not automatic yet."))
	asset_prompt = LineEdit.new()
	asset_prompt.placeholder_text = "Describe the asset to create"
	asset_rows.add_child(asset_prompt)
	asset_dialog.confirmed.connect(_request_asset)
	add_child(asset_dialog)
	scene_file_dialog = FileDialog.new()
	scene_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	scene_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	scene_file_dialog.filters = PackedStringArray(["*.glb ; Binary glTF"])
	scene_file_dialog.file_selected.connect(_import_scene)
	add_child(scene_file_dialog)
	asset_file_dialog = FileDialog.new()
	asset_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	asset_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	asset_file_dialog.filters = PackedStringArray(["*.glb ; Binary glTF"])
	asset_file_dialog.file_selected.connect(_import_asset)
	add_child(asset_file_dialog)
	settings_dialog = ConfirmationDialog.new()
	settings_dialog.title = "Settings"
	var settings_rows := _dialog_rows(settings_dialog)
	settings_rows.add_child(_field_label("Server WebSocket URL"))
	settings_url = LineEdit.new()
	settings_url.text = server_url
	settings_rows.add_child(settings_url)
	settings_rows.add_child(_field_label("Planning provider"))
	settings_provider = OptionButton.new()
	settings_provider.add_item("Codex (local sign-in)", 0)
	settings_provider.add_item("Claude", 1)
	settings_provider.select(1 if default_provider == "claude" else 0)
	settings_rows.add_child(settings_provider)
	settings_dialog.confirmed.connect(_save_settings)
	add_child(settings_dialog)


# The brief opens in the page, not a popup window, so it also works on the headset panel.
func _build_brief_panel() -> void:
	brief_panel = ColorRect.new()
	brief_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	brief_panel.color = WorldsmithTheme.GROUND
	brief_panel.visible = false
	add_child(brief_panel)
	var padding := MarginContainer.new()
	padding.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]:
		padding.add_theme_constant_override("margin_" + side, 30)
	brief_panel.add_child(padding)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 12)
	padding.add_child(rows)
	rows.add_child(WorldsmithTheme.label("Scene production brief", 26, WorldsmithTheme.CHALK, WorldsmithTheme.serif()))
	brief_text = TextEdit.new()
	brief_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	brief_text.editable = false
	brief_text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	brief_text.add_theme_color_override("font_readonly_color", WorldsmithTheme.CHALK)
	rows.add_child(brief_text)
	var close := _button(rows, "Back to Home", func() -> void: brief_panel.visible = false)
	close.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN


func _dialog_rows(dialog: ConfirmationDialog) -> VBoxContainer:
	var rows := VBoxContainer.new()
	rows.position = Vector2(20, 48)
	rows.custom_minimum_size = Vector2(460, 0)
	rows.add_theme_constant_override("separation", 12)
	dialog.add_child(rows)
	return rows


func _field_label(value: String) -> Label:
	var label := Label.new()
	label.text = value
	return label


func _http_base() -> String:
	return server_url.replace("ws://", "http://").replace("wss://", "https://").trim_suffix("/")


func _api(path: String, method: HTTPClient.Method = HTTPClient.METHOD_GET, payload: Variant = null) -> Dictionary:
	var request := HTTPRequest.new()
	request.timeout = 120.0
	add_child(request)
	var headers := PackedStringArray()
	var body := ""
	if payload != null:
		headers.append("Content-Type: application/json")
		body = JSON.stringify(payload)
	var error := request.request(_http_base() + path, headers, method, body)
	if error != OK:
		request.queue_free()
		return {"ok": false, "message": "Could not connect to scene server"}
	var response: Array = await request.request_completed
	request.queue_free()
	if int(response[0]) != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "message": "Could not reach the scene server at " + _http_base()}
	var code := int(response[1])
	var parsed: Variant = JSON.parse_string((response[3] as PackedByteArray).get_string_from_utf8())
	if code < 200 or code >= 300:
		return {"ok": false, "message": str(parsed.get("detail", "HTTP %d" % code)) if parsed is Dictionary else "HTTP %d" % code}
	return {"ok": true, "data": parsed}


func _upload(path: String, bytes: PackedByteArray, name: String) -> Dictionary:
	var request := HTTPRequest.new()
	request.timeout = 180.0
	add_child(request)
	var headers := PackedStringArray(["Content-Type: model/gltf-binary", "X-Filename: " + name])
	var error := request.request_raw(_http_base() + path, headers, HTTPClient.METHOD_POST, bytes)
	if error != OK:
		request.queue_free()
		return {"ok": false, "message": "Could not send GLB"}
	var response: Array = await request.request_completed
	request.queue_free()
	var code := int(response[1])
	var parsed: Variant = JSON.parse_string((response[3] as PackedByteArray).get_string_from_utf8())
	if code < 200 or code >= 300:
		return {"ok": false, "message": str(parsed.get("detail", "HTTP %d" % code)) if parsed is Dictionary else "HTTP %d" % code}
	return {"ok": true, "data": parsed}


func _download_glb(path: String) -> Dictionary:
	var request := HTTPRequest.new()
	request.timeout = 120.0
	add_child(request)
	if request.request(_http_base() + path) != OK:
		request.queue_free()
		return {"ok": false, "message": "Could not request asset"}
	var response: Array = await request.request_completed
	request.queue_free()
	if int(response[0]) != HTTPRequest.RESULT_SUCCESS or int(response[1]) != 200:
		return {"ok": false, "message": "Could not download asset"}
	var bytes: PackedByteArray = response[3]
	if bytes.size() < 20 or bytes.slice(0, 4).get_string_from_ascii() != "glTF":
		return {"ok": false, "message": "Downloaded asset is not a GLB"}
	return {"ok": true, "bytes": bytes}


func _selected_scene_item() -> Dictionary:
	for item in scenes:
		if item["scene_id"] == selected_scene:
			return item
	return {}


func _review_collision() -> void:
	if not bool(_selected_scene_item().get("has_environment", false)):
		status_label.text = "Select a scene with a 3D environment first. Import Scene adds one."
		return
	collision_review.open(selected_scene)


func _on_collision_review_closed(message: String) -> void:
	if message.is_empty():
		return
	await _refresh_all()
	status_label.text = message


func _valid_id(value: String) -> bool:
	var pattern := RegEx.new()
	pattern.compile("^[a-z0-9][a-z0-9_-]{0,63}$")
	return pattern.search(value) != null


func _slug(value: String) -> String:
	var candidate := value.get_basename().to_lower().replace(" ", "-")
	var pattern := RegEx.new()
	pattern.compile("[^a-z0-9_-]+")
	candidate = pattern.sub(candidate, "-", true).trim_prefix("-").trim_suffix("-")
	return candidate.left(40) if not candidate.is_empty() else "asset"


func _create_scene() -> void:
	var scene_id := create_id.text.strip_edges()
	if not _valid_id(scene_id):
		status_label.text = "Scene ID needs lowercase letters, digits, hyphen, or underscore."
		return
	var result := await _api("/api/scenes", HTTPClient.METHOD_POST, {"scene_id": scene_id})
	if not result["ok"]:
		status_label.text = str(result["message"])
		return
	selected_scene = scene_id
	await _refresh_all()
	status_label.text = "Created empty scene. Select Plan Scene or Import Scene to add content."


func _import_asset(path: String) -> void:
	var bytes := _read_glb(path)
	if bytes.is_empty():
		return
	var asset_id := _slug(path.get_file())
	status_label.text = "Importing reusable asset…"
	var result := await _upload("/api/library/assets/" + asset_id, bytes, path.get_file())
	if not result["ok"]:
		status_label.text = str(result["message"])
		return
	selected_asset = asset_id
	await _refresh_all()
	status_label.text = "Asset stored in the reusable library. Godot visual review is still required."


func _read_glb(path: String) -> PackedByteArray:
	if path.get_extension().to_lower() != "glb" or not FileAccess.file_exists(path):
		status_label.text = "Choose a GLB file."
		return PackedByteArray()
	var source := FileAccess.open(path, FileAccess.READ)
	if source == null:
		status_label.text = "Could not read the GLB file."
		return PackedByteArray()
	if source.get_length() > MAX_IMPORT_BYTES:
		status_label.text = "GLB exceeds the 256 MB import limit."
		return PackedByteArray()
	return source.get_buffer(source.get_length())


func _request_asset() -> void:
	var prompt := asset_prompt.text.strip_edges()
	if prompt.length() < 10:
		status_label.text = "Describe the asset in at least 10 characters."
		return
	var result := await _api("/api/library/requests", HTTPClient.METHOD_POST, {"prompt": prompt})
	if result["ok"]:
		await _refresh_all()
	status_label.text = "Asset request saved for local production. No mesh exists yet." if result["ok"] else str(result["message"])


func _view_brief() -> void:
	if selected_scene.is_empty():
		status_label.text = "Select a scene first."
		return
	var result := await _api("/api/scenes/" + selected_scene + "/brief")
	if not result["ok"]:
		status_label.text = str(result["message"])
		return
	var brief: Dictionary = result["data"]["brief"]
	var lines: Array[String] = [
		"The plan is saved. Its 3D assets still need to be made.", "",
		"Concept: " + str(brief.get("concept", "")), "",
		"Visual direction: " + str(brief.get("visual_direction", "")), "",
		"Walkable layout: " + str(brief.get("walkable_layout", "")), "",
		"Ground: " + str(brief.get("ground_strategy", "")), "",
		"Lighting: " + str(brief.get("lighting", "")), "",
		"Reusable assets:",
	]
	for item in brief.get("assets", []):
		lines.append("• %s ×%d (%s): %s" % [item.get("key", ""), item.get("quantity", 1), item.get("role", ""), item.get("description", "")])
	brief_text.text = "\n".join(lines)
	brief_panel.visible = true


func _open_selected_scene(view_only: bool) -> void:
	if selected_scene.is_empty():
		status_label.text = "Select a scene first."
		return
	var item := _selected_scene_item()
	var has_environment := bool(item.get("has_environment", false))
	if view_only and not has_environment:
		status_label.text = "This scene has no 3D environment to run. Plan or import it first."
		return
	if view_only and not bool(item.get("has_walkable", false)):
		status_label.text = "This scene has no walkable collision yet. Use Review Collision first."
		return
	_enter_scene(view_only, not has_environment, false)


func _plan_selected_scene() -> void:
	if selected_scene.is_empty():
		status_label.text = "Select a scene first."
		return
	_enter_scene(false, true, true)


func _enter_scene(view_only: bool, workspace: bool, open_planner: bool) -> void:
	get_tree().root.set_meta("worldsmith_scene_id", selected_scene)
	get_tree().root.set_meta("worldsmith_server_url", server_url)
	get_tree().root.set_meta("worldsmith_view_only", view_only)
	get_tree().root.set_meta("worldsmith_provider", default_provider)
	get_tree().root.set_meta("worldsmith_workspace_on_open", workspace)
	get_tree().root.set_meta("worldsmith_plan_on_open", open_planner)
	get_tree().change_scene_to_file("res://scenes/main.tscn")


func _edit_selected_asset() -> void:
	if selected_asset.is_empty():
		status_label.text = "Select an asset first."
		return
	status_label.text = "Preparing editable GLB…"
	var result := await _download_glb("/api/library/assets/" + selected_asset + "/glb")
	if not result["ok"]:
		status_label.text = str(result["message"])
		return
	var directory := "user://asset_edits"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	var glb := ProjectSettings.globalize_path(directory + "/" + selected_asset + ".glb")
	var file := FileAccess.open(glb, FileAccess.WRITE)
	if file == null:
		status_label.text = "Could not save asset for editing."
		return
	file.store_buffer(result["bytes"])
	file.close()
	var blender := "/opt/homebrew/bin/blender"
	if not FileAccess.file_exists(blender):
		blender = "/Applications/Blender.app/Contents/MacOS/Blender"
	if not FileAccess.file_exists(blender):
		status_label.text = "Saved GLB for editing: " + glb
		return
	var script := ProjectSettings.globalize_path("res://").path_join("../scripts/open_asset_for_edit.py").simplify_path()
	var blend := ProjectSettings.globalize_path(directory + "/" + selected_asset + ".blend")
	var pid := OS.create_process(blender, PackedStringArray(["--python", script, "--", glb, blend]))
	status_label.text = "Opening asset in Blender. Re-import the edited GLB to save a new version." if pid > 0 else "Saved GLB for editing: " + glb


func _save_settings() -> void:
	var value := settings_url.text.strip_edges().trim_suffix("/")
	if not value.begins_with("ws://") and not value.begins_with("wss://"):
		status_label.text = "Server URL must start with ws:// or wss://"
		return
	server_url = value
	default_provider = "claude" if settings_provider.selected == 1 else "codex"
	var settings := ConfigFile.new()
	settings.set_value("connection", "server_url", server_url)
	settings.set_value("creation", "provider", default_provider)
	var result := settings.save(SETTINGS_PATH)
	status_label.text = "Settings saved." if result == OK else "Could not save settings."
	_refresh_all()
