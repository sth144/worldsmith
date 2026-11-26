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
var scene_list: ItemList
var asset_list: ItemList
var scene_details: Label
var asset_details: Label
var asset_request_label: Label
var status_label: Label
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
	var background := ColorRect.new()
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.color = Color(0.055, 0.075, 0.105)
	add_child(background)
	var outer := MarginContainer.new()
	outer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]:
		outer.add_theme_constant_override("margin_" + side, 30)
	add_child(outer)
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 18)
	outer.add_child(page)
	var header := HBoxContainer.new()
	page.add_child(header)
	var title := Label.new()
	title.text = "Worldsmith"
	title.add_theme_font_size_override("font_size", 34)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var settings_button := Button.new()
	settings_button.text = "Settings · desktop only" if panel_mode else "Settings"
	settings_button.disabled = panel_mode
	settings_button.pressed.connect(func() -> void: settings_dialog.popup_centered(Vector2i(520, 260)))
	header.add_child(settings_button)
	var intro := Label.new()
	intro.text = "Create and manage scenes and reusable 3D assets. A production brief is a plan; walkability also requires 3D geometry and collision. Dimmed actions are not built yet or need the desktop app."
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(intro)
	var columns := HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 18)
	page.add_child(columns)
	var scene_column := _section(columns, "Scenes")
	scene_list = ItemList.new()
	scene_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scene_list.item_selected.connect(_on_scene_selected)
	scene_list.item_activated.connect(func(_index: int) -> void: _open_selected_scene(false))
	scene_column.add_child(scene_list)
	scene_details = Label.new()
	scene_details.text = "Select a scene to inspect it."
	scene_details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	scene_column.add_child(scene_details)
	var scene_actions := GridContainer.new()
	scene_actions.columns = 2
	scene_column.add_child(scene_actions)
	_button(scene_actions, "Create Scene", func() -> void: create_dialog.popup_centered(Vector2i(520, 190)), Availability.DESKTOP)
	_button(scene_actions, "Import Scene", func() -> void: scene_file_dialog.popup_centered_ratio(), Availability.DESKTOP)
	_button(scene_actions, "Load for Editing", func() -> void: _open_selected_scene(false))
	_button(scene_actions, "Run Scene", func() -> void: _open_selected_scene(true))
	_button(scene_actions, "Plan Scene", func() -> void: _plan_selected_scene(), Availability.DESKTOP)
	_button(scene_actions, "View Brief", func() -> void: _view_brief())
	_button(scene_actions, "Build from Brief", Callable(), Availability.PLANNED)
	_button(scene_actions, "Review Collision", func() -> void: _review_collision())
	_button(scene_actions, "Refresh", func() -> void: _refresh_all())
	var asset_column := _section(columns, "Reusable 3D assets")
	asset_list = ItemList.new()
	asset_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	asset_list.item_selected.connect(_on_asset_selected)
	asset_column.add_child(asset_list)
	asset_details = Label.new()
	asset_details.text = "Select an asset to inspect it."
	asset_details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	asset_column.add_child(asset_details)
	asset_request_label = Label.new()
	asset_column.add_child(asset_request_label)
	var asset_actions := GridContainer.new()
	asset_actions.columns = 2
	asset_column.add_child(asset_actions)
	_button(asset_actions, "Request Asset", func() -> void: asset_dialog.popup_centered(Vector2i(520, 190)), Availability.DESKTOP)
	_button(asset_actions, "Import Asset", func() -> void: asset_file_dialog.popup_centered_ratio(), Availability.DESKTOP)
	_button(asset_actions, "Edit in Blender", func() -> void: _edit_selected_asset(), Availability.DESKTOP)
	_button(asset_actions, "Generate Asset", Callable(), Availability.PLANNED)
	_button(asset_actions, "Review and Promote", Callable(), Availability.PLANNED)
	_button(asset_actions, "Refresh", func() -> void: _refresh_all())
	status_label = Label.new()
	status_label.text = "Connecting to the local server…"
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(status_label)
	_build_dialogs()
	_build_brief_panel()
	collision_review = WorldsmithCollisionReview.new(_api)
	collision_review.closed.connect(_on_collision_review_closed)
	add_child(collision_review)


func _section(parent: HBoxContainer, heading: String) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(panel)
	var padding := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		padding.add_theme_constant_override("margin_" + side, 16)
	panel.add_child(padding)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	padding.add_child(column)
	var label := Label.new()
	label.text = heading
	label.add_theme_font_size_override("font_size", 23)
	column.add_child(label)
	return column


func _button(parent: Control, label: String, handler: Callable, availability := Availability.READY) -> Button:
	var button := Button.new()
	button.text = label
	button.custom_minimum_size = Vector2(250, 38)
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
	brief_panel.color = Color(0.055, 0.075, 0.105)
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
	var heading := Label.new()
	heading.text = "Scene production brief"
	heading.add_theme_font_size_override("font_size", 23)
	rows.add_child(heading)
	brief_text = TextEdit.new()
	brief_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	brief_text.editable = false
	brief_text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	brief_text.add_theme_color_override("font_readonly_color", Color(0.93, 0.95, 0.98))
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


func _refresh_all() -> void:
	status_label.text = "Loading scenes and assets…"
	var scene_result := await _api("/api/scenes")
	if not scene_result["ok"]:
		status_label.text = str(scene_result["message"])
		return
	scenes = scene_result["data"]
	scene_list.clear()
	for item in scenes:
		var index := scene_list.add_item(str(item["scene_id"]) + " · " + _scene_state(item))
		scene_list.set_item_metadata(index, str(item["scene_id"]))
	var asset_result := await _api("/api/library/assets")
	if not asset_result["ok"]:
		status_label.text = str(asset_result["message"])
		return
	assets = []
	for item in asset_result["data"]:
		if item["kind"] == "mesh":
			assets.append(item)
	asset_list.clear()
	for item in assets:
		var index := asset_list.add_item(str(item["asset_id"]) + " · " + str(item["origin"]))
		asset_list.set_item_metadata(index, str(item["asset_id"]))
	var requests_result := await _api("/api/library/requests")
	if requests_result["ok"]:
		asset_request_label.text = "%d asset production requests waiting" % (requests_result["data"] as Array).size()
	else:
		asset_request_label.text = "Asset requests unavailable"
	var preferred := selected_scene
	if preferred.is_empty():
		preferred = str(get_tree().root.get_meta("worldsmith_scene_id", ""))
	if preferred.is_empty():
		preferred = _argument_value(OS.get_cmdline_user_args(), "--scene-id=")
	_select_scene_id(preferred)
	_select_asset_id(selected_asset)
	status_label.text = "%d scenes · %d reusable assets" % [scenes.size(), assets.size()]


func _select_scene_id(scene_id: String) -> void:
	for index in range(scene_list.item_count):
		if str(scene_list.get_item_metadata(index)) == scene_id:
			scene_list.select(index)
			_on_scene_selected(index)
			return
	selected_scene = ""
	scene_details.text = "Select a scene to inspect it."


func _select_asset_id(asset_id: String) -> void:
	for index in range(asset_list.item_count):
		if str(asset_list.get_item_metadata(index)) == asset_id:
			asset_list.select(index)
			_on_asset_selected(index)
			return
	selected_asset = ""
	asset_details.text = "Select an asset to inspect it."


func _on_scene_selected(index: int) -> void:
	selected_scene = str(scene_list.get_item_metadata(index))
	for item in scenes:
		if item["scene_id"] == selected_scene:
			scene_details.text = "%s · revision %d · %d objects" % [_scene_state(item), item["revision"], item["object_count"]]
			return


func _scene_state(item: Dictionary) -> String:
	if item["has_walkable"]:
		return "walkable"
	if item["has_environment"]:
		return "3D source, collision not reviewed"
	return "planned, geometry pending" if item["has_brief"] else "empty"


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


func _on_asset_selected(index: int) -> void:
	selected_asset = str(asset_list.get_item_metadata(index))
	for item in assets:
		if item["asset_id"] == selected_asset:
			var reviewed := bool(item.get("metadata", {}).get("godot_review", false))
			asset_details.text = "%s · %s" % [str(item["kind"]), "Godot reviewed" if reviewed else "review pending"]
			return


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


func _import_scene(path: String) -> void:
	var bytes := _read_glb(path)
	if bytes.is_empty():
		return
	var scene_id := _slug(path.get_file()) + "-" + str(int(Time.get_unix_time_from_system()))
	status_label.text = "Importing scene…"
	var created := await _api("/api/scenes", HTTPClient.METHOD_POST, {"scene_id": scene_id})
	if not created["ok"]:
		status_label.text = str(created["message"])
		return
	var uploaded := await _upload("/api/scenes/" + scene_id + "/environment", bytes, path.get_file())
	selected_scene = scene_id
	await _refresh_all()
	if not uploaded["ok"]:
		status_label.text = "Scene project created, but GLB import failed: " + str(uploaded["message"])
		return
	status_label.text = "Imported scene GLB. Review its collision to make it walkable."
	collision_review.open(scene_id)


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
		"SCENE PLAN SAVED · 3D ASSETS STILL NEEDED", "",
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
