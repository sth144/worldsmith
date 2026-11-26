extends Node
class_name WorldsmithSceneSync

signal status_changed
signal brief_result_ready

const RETRY_SECONDS := 2.0
const CONNECTION_TIMEOUT := 8.0
const PACKAGE_REFRESH_SECONDS := 15.0

@onready var editor: WorldsmithSceneEditor = $"../PlacedObjects"

var socket: WebSocketPeer
var server_url := "ws://127.0.0.1:8765"
var scene_id := ""
var disabled := false
var online := false
var waiting_for_ack := false
var retry_time := 0.0
var connection_time := 0.0
var acknowledgement_time := 0.0
var revision := 0
var history_cursor := 0
var history_length := 0
var server_objects: Dictionary = {}
var pending: Array[Dictionary] = []
var last_error := ""
var agent_busy := false
var agent_request: HTTPRequest
var downloading: Dictionary = {}
var catalog_entries: Dictionary = {}
var environment_hash := ""
var environment_loading_hash := ""
var environment_settings_signature := ""
var pending_environment_settings: Dictionary = {}
var package_refresh_time := 0.0
var package_request_in_flight := false
var pending_instance_groups: Array = []
var instance_downloading: Dictionary = {}
var loaded_instance_keys: Dictionary = {}
var geometry_job_id := ""
var geometry_summary := ""
var asset_request_id := ""
var last_agent_details := ""
var brief_in_flight := false
var brief_ready := false
var brief_load_in_flight := false


func _ready() -> void:
	editor.operation_committed.connect(_on_local_operation)
	agent_request = HTTPRequest.new()
	agent_request.timeout = 100.0
	add_child(agent_request)
	agent_request.request_completed.connect(_on_agent_result)
	var user_args := OS.get_cmdline_user_args()
	disabled = user_args.has("--offline")
	for argument in user_args:
		if argument.begins_with("--preview-config=") or argument.begins_with("--preview-glb="):
			disabled = true
	if disabled:
		return
	if FileAccess.file_exists("res://server.json"):
		var config: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://server.json"))
		if config is Dictionary:
			server_url = str(config.get("url", server_url)).trim_suffix("/")
			scene_id = str(config.get("scene_id", scene_id))
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--server-url="):
			server_url = argument.trim_prefix("--server-url=").trim_suffix("/")
		elif argument.begins_with("--scene-id="):
			scene_id = argument.trim_prefix("--scene-id=")
	server_url = str(get_tree().root.get_meta("worldsmith_server_url", server_url))
	scene_id = str(get_tree().root.get_meta("worldsmith_scene_id", scene_id))
	if scene_id.is_empty():
		disabled = true
		return
	_connect()


func _process(delta: float) -> void:
	if disabled:
		return
	if socket == null:
		retry_time -= delta
		if retry_time <= 0:
			_connect()
		return
	socket.poll()
	match socket.get_ready_state():
		WebSocketPeer.STATE_CONNECTING:
			connection_time += delta
			if connection_time > CONNECTION_TIMEOUT:
				socket.close()
				_disconnect()
		WebSocketPeer.STATE_OPEN:
			connection_time = 0.0
			if online:
				package_refresh_time -= delta
				if package_refresh_time <= 0.0:
					_refresh_environment()
			while socket.get_available_packet_count() > 0:
				var parsed: Variant = JSON.parse_string(socket.get_packet().get_string_from_utf8())
				if parsed is Dictionary:
					_handle_message(parsed)
			if waiting_for_ack:
				acknowledgement_time += delta
				if acknowledgement_time > CONNECTION_TIMEOUT:
					socket.close()
					_disconnect()
		WebSocketPeer.STATE_CLOSED:
			_disconnect()


func _connect() -> void:
	socket = WebSocketPeer.new()
	connection_time = 0.0
	var result := socket.connect_to_url(server_url + "/ws/scenes/" + scene_id)
	if result != OK:
		_disconnect()


func _disconnect() -> void:
	socket = null
	online = false
	environment_loading_hash = ""
	waiting_for_ack = false
	acknowledgement_time = 0.0
	retry_time = RETRY_SECONDS
	status_changed.emit()


func _handle_message(message: Dictionary) -> void:
	match str(message.get("type", "")):
		"snapshot", "conflict":
			_set_snapshot(message["scene"], message.get("history", {}))
			waiting_for_ack = false
			_send_next()
		"ack":
			if pending.is_empty() or str(message.get("request_id", "")) != str(pending[0]["id"]):
				return
			pending.pop_front()
			waiting_for_ack = false
			_apply_delta(message)
			_send_next()
		"delta":
			if int(message.get("revision", -1)) != revision + 1:
				# Reconnect for a fresh snapshot if a delta was missed.
				socket.close()
				return
			_apply_delta(message)
		"error":
			last_error = str(message.get("detail", "Server rejected edit"))
			if not pending.is_empty() and str(message.get("request_id", "")) == str(pending[0]["id"]):
				pending.pop_front()
			waiting_for_ack = false
			_rebuild_local()
			status_changed.emit()
			_send_next()


func _set_snapshot(scene: Dictionary, history: Dictionary) -> void:
	revision = int(scene.get("revision", 0))
	history_cursor = int(history.get("cursor", 0))
	history_length = int(history.get("length", 0))
	server_objects.clear()
	for value in scene.get("objects", []):
		server_objects[str(value["id"])] = value
	while not pending.is_empty() and _operation_already_applied(pending[0]["operation"]):
		pending.pop_front()
	online = true
	last_error = ""
	_refresh_environment()
	_refresh_catalog()
	_refresh_saved_brief()
	_rebuild_local()
	status_changed.emit()


func _operation_already_applied(operation: Dictionary) -> bool:
	var kind := str(operation.get("type", ""))
	if kind == "add_object":
		return server_objects.has(str(operation["object"]["id"]))
	if kind == "duplicate_object":
		return server_objects.has(str(operation["new_id"]))
	var object_id := str(operation.get("object_id", ""))
	if kind == "delete_object":
		return not server_objects.has(object_id)
	if not server_objects.has(object_id):
		return false
	var current: Dictionary = server_objects[object_id]
	if kind == "set_transform":
		for field in ["position", "rotation", "scale"]:
			if operation.has(field) and current.get(field) != operation[field]:
				return false
		return true
	if kind == "set_visibility":
		return current.get("visible") == operation.get("visible")
	if kind == "replace_asset":
		return current.get("asset") == operation.get("asset")
	if kind == "set_material":
		return current.get("metadata", {}).get("material_color") == operation.get("color")
	return false


func _apply_delta(message: Dictionary) -> void:
	revision = int(message["revision"])
	var history: Dictionary = message.get("history", {})
	history_cursor = int(history.get("cursor", history_cursor))
	history_length = int(history.get("length", history_length))
	for change in message.get("changes", []):
		if change.get("type") == "upsert":
			var object_data: Dictionary = change["object"]
			server_objects[str(object_data["id"])] = object_data
		elif change.get("type") == "delete":
			server_objects.erase(str(change["object_id"]))
	_rebuild_local()
	status_changed.emit()


func _rebuild_local() -> void:
	var available: Array = []
	for value in server_objects.values():
		var asset_key := str(value.get("asset", "")).get_file().get_basename()
		if editor.asset_info(asset_key).is_empty():
			_download_asset(asset_key)
		if not editor.asset_info(asset_key).is_empty():
			available.append(value)
	var world := get_parent()
	var selected: String = world.selected_id
	editor.load_wire_objects(available)
	for item in pending:
		editor.replay_operation(item["operation"])
	if editor.object_node(selected) != null:
		world._select_object(selected)
	elif server_objects.has(selected):
		# Keep selection while a new mesh version downloads.
		world.selected_id = selected
	else:
		world._select_object("")


func _download_asset(asset_key: String) -> void:
	var pattern := RegEx.new()
	pattern.compile("^[a-z0-9][a-z0-9_-]{0,63}$")
	if downloading.has(asset_key) or pattern.search(asset_key) == null:
		return
	var cached := "user://assets/" + scene_id + "/" + asset_key + ".glb"
	if FileAccess.file_exists(cached):
		_register_asset(asset_key, cached)
		return
	var request := HTTPRequest.new()
	request.timeout = 60.0
	add_child(request)
	downloading[asset_key] = request
	request.request_completed.connect(_on_asset_downloaded.bind(asset_key, request))
	var endpoint := server_url.replace("ws://", "http://").replace("wss://", "https://")
	var error := request.request(endpoint + "/api/assets/" + asset_key + "?scene_id=" + scene_id)
	if error != OK:
		downloading.erase(asset_key)
		request.queue_free()


func _on_asset_downloaded(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, asset_key: String, request: HTTPRequest) -> void:
	downloading.erase(asset_key)
	request.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or code != 200 or body.size() < 20 or body.slice(0, 4).get_string_from_ascii() != "glTF":
		last_error = "Could not download asset " + asset_key
		status_changed.emit()
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://assets/" + scene_id))
	var file_path := "user://assets/" + scene_id + "/" + asset_key + ".glb"
	var file := FileAccess.open(file_path, FileAccess.WRITE)
	if file == null:
		last_error = "Could not save asset " + asset_key
		status_changed.emit()
		return
	file.store_buffer(body)
	file.close()
	_register_asset(asset_key, file_path)
	_rebuild_local()


func _register_asset(asset_key: String, file_path: String) -> void:
	var info: Dictionary = catalog_entries.get(asset_key, {})
	editor.register_dynamic_asset(asset_key, file_path,
		str(info.get("name", asset_key)), bool(info.get("walkable", false)))
	_publish_catalog()


func _refresh_environment() -> void:
	if package_request_in_flight:
		return
	package_request_in_flight = true
	package_refresh_time = PACKAGE_REFRESH_SECONDS
	var request := HTTPRequest.new()
	request.timeout = 30.0
	add_child(request)
	request.request_completed.connect(_on_package_loaded.bind(request))
	var endpoint := server_url.replace("ws://", "http://").replace("wss://", "https://")
	if request.request(endpoint + "/api/scenes/" + scene_id + "/package") != OK:
		package_request_in_flight = false
		request.queue_free()


func _on_package_loaded(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, request: HTTPRequest) -> void:
	package_request_in_flight = false
	request.queue_free()
	if not online:
		return
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		last_error = "Could not load scene environment settings"
		status_changed.emit()
		return
	var package: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not package is Dictionary:
		last_error = "Scene environment settings are invalid"
		status_changed.emit()
		return
	var environment: Variant = package.get("environment")
	var world := get_parent()
	if environment == null:
		environment_loading_hash = ""
		world.load_environment_file("", {})
		environment_hash = ""
		environment_settings_signature = ""
		pending_instance_groups.clear()
		loaded_instance_keys.clear()
		return
	if not environment is Dictionary:
		last_error = "Scene environment reference is invalid"
		status_changed.emit()
		return
	var digest := str(environment.get("sha256", ""))
	var pattern := RegEx.new()
	pattern.compile("^[a-f0-9]{64}$")
	if str(environment.get("asset_id", "")) != "environment" or pattern.search(digest) == null:
		last_error = "Scene environment reference is invalid"
		status_changed.emit()
		return
	var settings_value: Variant = package.get("presentation", {})
	if not settings_value is Dictionary:
		last_error = "Scene presentation settings are invalid"
		status_changed.emit()
		return
	var settings: Dictionary = settings_value
	pending_environment_settings = settings
	var instance_value: Variant = package.get("instances", [])
	if not instance_value is Array:
		last_error = "Scene instance settings are invalid"
		status_changed.emit()
		return
	pending_instance_groups = instance_value
	var settings_signature := JSON.stringify({"presentation": settings, "instances": pending_instance_groups})
	if digest == environment_loading_hash:
		return
	if digest == environment_hash and settings_signature == environment_settings_signature:
		_load_instance_groups()
		return
	var cached := "user://assets/" + scene_id + "/environment-" + digest + ".glb"
	if FileAccess.file_exists(cached):
		world.load_environment_file(cached, settings)
		environment_hash = digest if not world.preview_name.is_empty() else ""
		environment_settings_signature = settings_signature if not environment_hash.is_empty() else ""
		loaded_instance_keys.clear()
		_load_instance_groups()
		return
	environment_loading_hash = digest
	var download := HTTPRequest.new()
	download.timeout = 120.0
	add_child(download)
	download.request_completed.connect(_on_environment_downloaded.bind(digest, cached, download))
	var endpoint := server_url.replace("ws://", "http://").replace("wss://", "https://")
	if download.request(endpoint + "/api/assets/environment?scene_id=" + scene_id) != OK:
		environment_loading_hash = ""
		download.queue_free()


func _on_environment_downloaded(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, digest: String, cached: String, request: HTTPRequest) -> void:
	request.queue_free()
	if not online or digest != environment_loading_hash:
		return
	environment_loading_hash = ""
	if result != HTTPRequest.RESULT_SUCCESS or code != 200 or body.size() < 20 or body.slice(0, 4).get_string_from_ascii() != "glTF":
		last_error = "Could not download scene environment"
		status_changed.emit()
		return
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	hasher.update(body)
	if hasher.finish().hex_encode() != digest:
		last_error = "Scene environment checksum mismatch"
		status_changed.emit()
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://assets/" + scene_id))
	var file := FileAccess.open(cached, FileAccess.WRITE)
	if file == null:
		last_error = "Could not cache scene environment"
		status_changed.emit()
		return
	file.store_buffer(body)
	file.close()
	var world := get_parent()
	world.load_environment_file(cached, pending_environment_settings)
	environment_hash = digest if not world.preview_name.is_empty() else ""
	environment_settings_signature = JSON.stringify({"presentation": pending_environment_settings, "instances": pending_instance_groups}) if not environment_hash.is_empty() else ""
	loaded_instance_keys.clear()
	_load_instance_groups()
	status_changed.emit()


func _load_instance_groups() -> void:
	if environment_hash.is_empty():
		return
	for group_value in pending_instance_groups:
		if not group_value is Dictionary:
			continue
		var group: Dictionary = group_value
		var index := int(group.get("index", -1))
		var count := int(group.get("count", 0))
		var prototype_sha := str(group.get("prototype_sha256", ""))
		var transforms_sha := str(group.get("transforms_sha256", ""))
		if index < 0 or count <= 0 or prototype_sha.length() != 64 or transforms_sha.length() != 64:
			continue
		var key := "%d:%s:%s" % [index, prototype_sha, transforms_sha]
		if loaded_instance_keys.has(key):
			continue
		var directory := "user://assets/" + scene_id + "/"
		var prototype_path := directory + "instance-%d-%s.glb" % [index, prototype_sha]
		var transforms_path := directory + "instance-%d-%s.bin" % [index, transforms_sha]
		var prototype_ready := _ensure_instance_file(index, "prototype", prototype_sha, prototype_path)
		var transforms_ready := _ensure_instance_file(index, "transforms", transforms_sha, transforms_path)
		if prototype_ready and transforms_ready:
			var placement := {"glb": prototype_path, "transforms": transforms_path, "count": count}
			if get_parent().add_preview_instance_group(placement):
				loaded_instance_keys[key] = true


func _ensure_instance_file(index: int, kind: String, digest: String, path: String) -> bool:
	if FileAccess.file_exists(path):
		return true
	if instance_downloading.has(path):
		return false
	var request := HTTPRequest.new()
	request.timeout = 120.0
	add_child(request)
	instance_downloading[path] = request
	request.request_completed.connect(_on_instance_file.bind(path, digest, request))
	var endpoint := server_url.replace("ws://", "http://").replace("wss://", "https://")
	if request.request(endpoint + "/api/scenes/" + scene_id + "/package/instances/%d/%s" % [index, kind]) != OK:
		instance_downloading.erase(path)
		request.queue_free()
	return false


func _on_instance_file(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, path: String, digest: String, request: HTTPRequest) -> void:
	instance_downloading.erase(path)
	request.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		last_error = "Could not download scene instances"
		status_changed.emit()
		return
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	hasher.update(body)
	if hasher.finish().hex_encode() != digest:
		last_error = "Scene instance checksum mismatch"
		status_changed.emit()
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://assets/" + scene_id))
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		last_error = "Could not cache scene instances"
		status_changed.emit()
		return
	file.store_buffer(body)
	file.close()
	_load_instance_groups()


func _refresh_catalog() -> void:
	var request := HTTPRequest.new()
	request.timeout = 30.0
	add_child(request)
	request.request_completed.connect(_on_catalog_loaded.bind(request))
	var endpoint := server_url.replace("ws://", "http://").replace("wss://", "https://")
	if request.request(endpoint + "/api/assets?scene_id=" + scene_id) != OK:
		request.queue_free()


func _refresh_saved_brief() -> void:
	if brief_load_in_flight or brief_in_flight:
		return
	brief_load_in_flight = true
	var request := HTTPRequest.new()
	request.timeout = 30.0
	add_child(request)
	request.request_completed.connect(_on_saved_brief_loaded.bind(request))
	var endpoint := server_url.replace("ws://", "http://").replace("wss://", "https://")
	if request.request(endpoint + "/api/scenes/" + scene_id + "/brief") != OK:
		brief_load_in_flight = false
		request.queue_free()


func _on_saved_brief_loaded(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, request: HTTPRequest) -> void:
	brief_load_in_flight = false
	request.queue_free()
	if agent_busy or brief_ready or result != HTTPRequest.RESULT_SUCCESS or code != 200:
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if parsed is Dictionary and parsed.get("status") == "needs_assets":
		brief_ready = true
		last_agent_details = _format_scene_brief(parsed)
		status_changed.emit()


func _on_catalog_loaded(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, request: HTTPRequest) -> void:
	request.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not parsed is Array:
		return
	catalog_entries.clear()
	for item in parsed:
		if not item is Dictionary:
			continue
		var asset_key := str(item.get("id", ""))
		catalog_entries[asset_key] = item
		if editor.asset_info(asset_key).is_empty():
			_download_asset(asset_key)
	_publish_catalog()


func _publish_catalog() -> void:
	var available: Array = []
	for asset_key in catalog_entries:
		if not editor.asset_info(asset_key).is_empty():
			available.append(catalog_entries[asset_key])
	available.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["name"]) < str(b["name"]))
	(get_parent().get_node("EditPanel") as WorldsmithEditPanel).set_assets(available)


func _on_local_operation(operation: Dictionary) -> void:
	if disabled:
		return
	pending.append({"id": _new_request_id(), "operation": operation})
	status_changed.emit()
	_send_next()


func _send_next() -> void:
	if not online or waiting_for_ack or pending.is_empty() or socket == null:
		return
	var item: Dictionary = pending[0]
	var operation: Dictionary = item["operation"]
	var kind := str(operation.get("type", ""))
	var message := {"type": kind if kind == "undo" or kind == "redo" else "operation", "request_id": item["id"], "expected_revision": revision}
	if message["type"] == "operation":
		message["operations"] = [operation]
	if socket.send_text(JSON.stringify(message)) == OK:
		waiting_for_ack = true
		acknowledgement_time = 0.0


func can_undo() -> bool:
	return (online and history_cursor > 0) or not editor.undo_stack.is_empty()


func can_redo() -> bool:
	return (online and history_cursor < history_length) or not editor.redo_stack.is_empty()


func status_text() -> String:
	if agent_busy:
		return "Planning scene…" if brief_in_flight else ("Blender working…" if not geometry_job_id.is_empty() else "AI working…")
	if not geometry_job_id.is_empty():
		return "Approve mesh: " + geometry_summary
	if disabled:
		return "Local only"
	if not last_error.is_empty():
		return "Sync error: " + last_error
	if not asset_request_id.is_empty():
		return "Asset requested · open AI output for details"
	if brief_ready:
		return "Scene plan saved · open AI output for details"
	if online:
		return "Saved r%d" % revision if pending.is_empty() else "Syncing %d edit(s)" % pending.size()
	return "Offline — %d edit(s) queued" % pending.size()


func request_agent(prompt: String, selected_ids: Array[String], view: Dictionary = {}, aimed_id: String = "", provider: String = "codex", creation_mode: String = "draft") -> void:
	if disabled or not online or agent_busy or not pending.is_empty():
		last_error = "Connect and save edits before asking AI"
		status_changed.emit()
		return
	var endpoint := server_url.replace("ws://", "http://").replace("wss://", "https://")
	asset_request_id = ""
	brief_ready = false
	brief_in_flight = false
	var payload := {"expected_revision": revision, "prompt": prompt, "selected_object_ids": selected_ids, "provider": provider, "creation_mode": creation_mode}
	if not aimed_id.is_empty():
		payload["aimed_object_id"] = aimed_id
	if not view.is_empty():
		payload["view"] = view
	var error := agent_request.request(endpoint + "/api/scenes/" + scene_id + "/agent", ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(payload))
	if error != OK:
		last_error = "Could not send AI request"
	else:
		agent_busy = true
		last_error = ""
	status_changed.emit()


func request_scene_brief(prompt: String, provider: String = "codex") -> void:
	if disabled or not online or agent_busy or not pending.is_empty():
		last_error = "Connect and save edits before planning a scene"
		status_changed.emit()
		return
	if prompt.strip_edges().length() < 20:
		last_error = "Describe the scene in at least 20 characters"
		status_changed.emit()
		return
	var endpoint := server_url.replace("ws://", "http://").replace("wss://", "https://")
	var payload := {"expected_revision": revision, "prompt": prompt, "provider": provider}
	var error := agent_request.request(endpoint + "/api/scenes/" + scene_id + "/brief", ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(payload))
	if error != OK:
		last_error = "Could not send scene plan request"
	else:
		agent_busy = true
		brief_in_flight = true
		brief_ready = false
		asset_request_id = ""
		last_error = ""
	status_changed.emit()


func _on_agent_result(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	agent_busy = false
	var was_brief := brief_in_flight
	brief_in_flight = false
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	last_agent_details = JSON.stringify(parsed, "  ") if parsed is Dictionary else body.get_string_from_utf8()
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		last_error = str(parsed.get("detail", "AI request failed")) if parsed is Dictionary else "AI request failed"
		last_agent_details = "HTTP %d\n%s" % [code, last_agent_details]
	else:
		last_error = ""
		asset_request_id = ""
		if was_brief:
			brief_ready = parsed is Dictionary and parsed.get("status") == "needs_assets"
			if not brief_ready:
				last_error = "Scene server returned an invalid plan"
			else:
				last_agent_details = _format_scene_brief(parsed)
		if parsed is Dictionary and parsed.get("status") == "needs_asset":
			asset_request_id = str(parsed.get("job", {}).get("id", ""))
		if parsed is Dictionary and parsed.get("status") == "approval_required":
			var job: Dictionary = parsed["job"]
			geometry_job_id = str(job["id"])
			geometry_summary = str(job["operation"])
	status_changed.emit()
	if brief_ready and was_brief:
		brief_result_ready.emit()


func _format_scene_brief(document: Dictionary) -> String:
	var brief: Dictionary = document.get("brief", {})
	var lines: Array[String] = [
		"SCENE PLAN SAVED · ASSETS STILL NEEDED",
		"",
		"Concept: " + str(brief.get("concept", "")),
		"Visual direction: " + str(brief.get("visual_direction", "")),
		"Walkable layout: " + str(brief.get("walkable_layout", "")),
		"Ground: " + str(brief.get("ground_strategy", "")),
		"Lighting: " + str(brief.get("lighting", "")),
		"",
		"Reusable assets:",
	]
	for asset in brief.get("assets", []):
		if asset is Dictionary:
			lines.append("• %s ×%s (%s): %s" % [str(asset.get("key", "")), str(asset.get("quantity", 1)), str(asset.get("role", "")), str(asset.get("description", ""))])
	return "\n".join(lines)


func approve_geometry() -> void:
	if geometry_job_id.is_empty() or agent_busy or not online:
		last_error = "No pending mesh edit"
		status_changed.emit()
		return
	var endpoint := server_url.replace("ws://", "http://").replace("wss://", "https://")
	var request := HTTPRequest.new()
	request.timeout = 130.0
	add_child(request)
	request.request_completed.connect(_on_geometry_result.bind(request))
	var payload := JSON.stringify({"expected_revision": revision})
	var error := request.request(endpoint + "/api/scenes/" + scene_id + "/geometry/" + geometry_job_id + "/approve", ["Content-Type: application/json"], HTTPClient.METHOD_POST, payload)
	if error != OK:
		last_error = "Could not start Blender"
		request.queue_free()
	else:
		agent_busy = true
	status_changed.emit()


func _on_geometry_result(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, request: HTTPRequest) -> void:
	request.queue_free()
	agent_busy = false
	geometry_job_id = ""
	geometry_summary = ""
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
		last_error = str(parsed.get("detail", "Mesh edit failed")) if parsed is Dictionary else "Mesh edit failed"
	else:
		last_error = ""
	status_changed.emit()


func _new_request_id() -> String:
	return "%d-%d" % [Time.get_ticks_usec(), randi()]
