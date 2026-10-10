extends Node
class_name WorldsmithSceneSync

signal status_changed

const RETRY_SECONDS := 2.0
const CONNECTION_TIMEOUT := 8.0

@onready var editor: WorldsmithSceneEditor = $"../PlacedObjects"

var socket: WebSocketPeer
var server_url := "ws://127.0.0.1:8765"
var scene_id := "demo"
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
var geometry_job_id := ""
var geometry_summary := ""


func _ready() -> void:
	editor.operation_committed.connect(_on_local_operation)
	agent_request = HTTPRequest.new()
	agent_request.timeout = 100.0
	add_child(agent_request)
	agent_request.request_completed.connect(_on_agent_result)
	disabled = OS.get_cmdline_user_args().has("--offline")
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
	if downloading.has(asset_key) or not asset_key.begins_with("chair-v-") and not asset_key.begins_with("table-v-") and not asset_key.begins_with("planter-v-") and not asset_key.begins_with("lantern-v-") and not asset_key.begins_with("hill-v-") and not asset_key.begins_with("tree-v-"):
		return
	var cached := "user://assets/" + asset_key + ".glb"
	if FileAccess.file_exists(cached):
		editor.register_dynamic_asset(asset_key, cached)
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
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://assets"))
	var file_path := "user://assets/" + asset_key + ".glb"
	var file := FileAccess.open(file_path, FileAccess.WRITE)
	if file == null:
		last_error = "Could not save asset " + asset_key
		status_changed.emit()
		return
	file.store_buffer(body)
	file.close()
	editor.register_dynamic_asset(asset_key, file_path)
	_rebuild_local()


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
		return "Blender working…" if not geometry_job_id.is_empty() else "AI working…"
	if not geometry_job_id.is_empty():
		return "Approve mesh: " + geometry_summary
	if disabled:
		return "Local only"
	if not last_error.is_empty():
		return "Sync error: " + last_error
	if online:
		return "Saved r%d" % revision if pending.is_empty() else "Syncing %d edit(s)" % pending.size()
	return "Offline — %d edit(s) queued" % pending.size()


func request_agent(prompt: String, selected_ids: Array[String], view: Dictionary = {}) -> void:
	if disabled or not online or agent_busy or not pending.is_empty():
		last_error = "Connect and save edits before asking AI"
		status_changed.emit()
		return
	var endpoint := server_url.replace("ws://", "http://").replace("wss://", "https://")
	var payload := {"expected_revision": revision, "prompt": prompt, "selected_object_ids": selected_ids}
	if not view.is_empty():
		payload["view"] = view
	var error := agent_request.request(endpoint + "/api/scenes/" + scene_id + "/agent", ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(payload))
	if error != OK:
		last_error = "Could not send AI request"
	else:
		agent_busy = true
		last_error = ""
	status_changed.emit()


func _on_agent_result(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	agent_busy = false
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		last_error = str(parsed.get("detail", "AI request failed")) if parsed is Dictionary else "AI request failed"
	else:
		last_error = ""
		if parsed is Dictionary and parsed.get("status") == "approval_required":
			var job: Dictionary = parsed["job"]
			geometry_job_id = str(job["id"])
			geometry_summary = str(job["operation"])
	status_changed.emit()


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
