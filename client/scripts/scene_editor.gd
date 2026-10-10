extends Node3D
class_name WorldsmithSceneEditor

signal changed
signal operation_committed(operation: Dictionary)

# All transforms are local to this node, in meters and Godot/glTF Y-up space.
# The origin of every catalog asset is on the floor.
const CATALOG := {
	"chair": {"label": "Chair", "path": "res://assets/inventory/chair.glb", "size": Vector3(0.62, 1.35, 0.62)},
	"table": {"label": "Table", "path": "res://assets/inventory/table.glb", "size": Vector3(1.28, 0.78, 0.78)},
	"planter": {"label": "Planter", "path": "res://assets/inventory/planter.glb", "size": Vector3(0.54, 1.1, 0.54)},
	"lantern": {"label": "Lantern", "path": "res://assets/inventory/lantern.glb", "size": Vector3(0.4, 0.7, 0.4)},
}

var objects: Dictionary = {}
var undo_stack: Array[Dictionary] = []
var redo_stack: Array[Dictionary] = []
var suppress_commits := false
var dynamic_assets: Dictionary = {}


func asset_info(asset_key: String) -> Dictionary:
	return dynamic_assets.get(asset_key, CATALOG.get(asset_key, {}))


func register_dynamic_asset(asset_key: String, file_path: String) -> void:
	var source_key := asset_key.split("-v-")[0]
	var source: Dictionary = CATALOG.get(source_key, {})
	dynamic_assets[asset_key] = {"label": asset_key, "path": file_path, "size": source.get("size", Vector3.ONE)}


func instantiate_asset(asset_key: String) -> Node3D:
	var info := asset_info(asset_key)
	if info.is_empty():
		return null
	var path := str(info["path"])
	if not path.begins_with("res://"):
		var document := GLTFDocument.new()
		var state := GLTFState.new()
		if document.append_from_file(path, state) != OK:
			return null
		return document.generate_scene(state)
	var packed := load(path) as PackedScene
	return packed.instantiate() if packed != null else null


func object_node(object_id: String) -> StaticBody3D:
	return objects.get(object_id) as StaticBody3D


func object_id_from_collider(collider: Object) -> String:
	if collider is StaticBody3D:
		var object_id := str(collider.get_meta("object_id", ""))
		if objects.has(object_id):
			return object_id
	return ""


func object_state(object_id: String) -> Dictionary:
	var body := object_node(object_id)
	if body == null:
		return {}
	return {"id": object_id, "asset": body.get_meta("asset_key"), "transform": body.transform, "data": body.get_meta("scene_data", {}).duplicate(true)}


func add_object(asset_key: String, object_transform: Transform3D, object_id: String = "") -> String:
	if not CATALOG.has(asset_key):
		return ""
	if object_id.is_empty():
		object_id = _new_uuid()
	var state := {"id": object_id, "asset": asset_key, "transform": object_transform, "data": {}}
	_record(object_id, {}, state)
	_emit_operation({"type": "add_object", "object": wire_object(object_id)})
	return object_id


func delete_object(object_id: String) -> bool:
	var before := object_state(object_id)
	if before.is_empty():
		return false
	_record(object_id, before, {})
	_emit_operation({"type": "delete_object", "object_id": object_id})
	return true


func set_object_transform(object_id: String, object_transform: Transform3D) -> bool:
	var before := object_state(object_id)
	if before.is_empty() or before["transform"] == object_transform:
		return false
	var after := before.duplicate()
	after["transform"] = object_transform
	_record(object_id, before, after)
	var body := object_node(object_id)
	_emit_operation({"type": "set_transform", "object_id": object_id, "position": _vec3(body.position), "rotation": _quat(body.transform.basis.orthonormalized().get_rotation_quaternion()), "scale": _vec3(body.scale)})
	return true


func duplicate_object(object_id: String, new_id: String = "") -> String:
	var before := object_state(object_id)
	if before.is_empty():
		return ""
	var copied_transform: Transform3D = before["transform"]
	copied_transform.origin += Vector3(0.55, 0, 0.55)
	var old_suppression := suppress_commits
	suppress_commits = true
	var copied_id := add_object(str(before["asset"]), copied_transform, new_id)
	suppress_commits = old_suppression
	if not copied_id.is_empty():
		_emit_operation({"type": "duplicate_object", "object_id": object_id, "new_id": copied_id})
	return copied_id


func undo() -> bool:
	if undo_stack.is_empty():
		_emit_operation({"type": "undo"})
		return false
	var entry: Dictionary = undo_stack.pop_back()
	_apply_state(str(entry["id"]), entry["before"])
	redo_stack.append(entry)
	changed.emit()
	_emit_operation({"type": "undo"})
	return true


func redo() -> bool:
	if redo_stack.is_empty():
		_emit_operation({"type": "redo"})
		return false
	var entry: Dictionary = redo_stack.pop_back()
	_apply_state(str(entry["id"]), entry["after"])
	undo_stack.append(entry)
	changed.emit()
	_emit_operation({"type": "redo"})
	return true


func _emit_operation(operation: Dictionary) -> void:
	if not suppress_commits:
		operation_committed.emit(operation)


func wire_object(object_id: String) -> Dictionary:
	var body := object_node(object_id)
	if body == null:
		return {}
	var stored: Dictionary = body.get_meta("scene_data", {})
	var info: Dictionary = asset_info(str(body.get_meta("asset_key")))
	return {
		"id": object_id,
		"name": stored.get("name", info.get("label", "Object")),
		"asset": "assets/%s.glb" % body.get_meta("asset_key"),
		"parent_id": stored.get("parent_id", null),
		"position": _vec3(body.position),
		"rotation": _quat(body.transform.basis.orthonormalized().get_rotation_quaternion()),
		"scale": _vec3(body.scale),
		"visible": body.visible,
		"locked": stored.get("locked", false),
		"metadata": stored.get("metadata", {}),
	}


func load_wire_objects(wire_objects: Array) -> void:
	for old in objects.values():
		old.queue_free()
	objects.clear()
	undo_stack.clear()
	redo_stack.clear()
	for value in wire_objects:
		apply_wire_object(value)
	changed.emit()


func apply_wire_object(value: Dictionary) -> void:
	var asset_key := str(value.get("asset", "")).get_file().get_basename()
	if asset_info(asset_key).is_empty():
		push_error("Scene references unavailable asset: " + str(value.get("asset", "")))
		return
	var position := _array_vec3(value.get("position", [0, 0, 0]))
	var rotation_values: Array = value.get("rotation", [0, 0, 0, 1])
	var rotation := Quaternion(float(rotation_values[0]), float(rotation_values[1]), float(rotation_values[2]), float(rotation_values[3]))
	var scale := _array_vec3(value.get("scale", [1, 1, 1]))
	var object_transform := Transform3D(Basis(rotation).scaled(scale), position)
	_apply_state(str(value["id"]), {"id": value["id"], "asset": asset_key, "transform": object_transform, "data": value.duplicate(true)})
	var body := object_node(str(value["id"]))
	if body != null:
		body.visible = bool(value.get("visible", true))
		_apply_material(body, value.get("metadata", {}))


func _apply_material(body: StaticBody3D, metadata: Dictionary) -> void:
	var color_values: Array = metadata.get("material_color", [])
	var material: StandardMaterial3D
	if color_values.size() == 4:
		material = StandardMaterial3D.new()
		material.albedo_color = Color(float(color_values[0]), float(color_values[1]), float(color_values[2]), float(color_values[3]))
		if material.albedo_color.a < 1.0:
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var overrides: Variant = metadata.get("material_overrides", {})
	if not overrides is Dictionary:
		overrides = {}
	var visual := body.get_node("Visual")
	for mesh_node in visual.find_children("*", "MeshInstance3D", true, false):
		var mesh := mesh_node as MeshInstance3D
		mesh.material_override = material
		if mesh.mesh == null:
			continue
		for index in range(mesh.mesh.get_surface_count()):
			var source := mesh.mesh.surface_get_material(index)
			var name := source.resource_name if source != null else ""
			if overrides.has(name):
				var values: Array = overrides[name]
				if values.size() == 4:
					var tinted: BaseMaterial3D = source.duplicate() if source is BaseMaterial3D else StandardMaterial3D.new()
					tinted.albedo_color = Color(float(values[0]), float(values[1]), float(values[2]), float(values[3]))
					mesh.set_surface_override_material(index, tinted)
					continue
			mesh.set_surface_override_material(index, null)


func replay_operation(operation: Dictionary) -> void:
	var old_suppression := suppress_commits
	suppress_commits = true
	match str(operation.get("type", "")):
		"add_object":
			var data: Dictionary = operation["object"]
			apply_wire_object(data)
			undo_stack.append({"id": data["id"], "before": {}, "after": object_state(str(data["id"]))})
			redo_stack.clear()
		"delete_object":
			delete_object(str(operation["object_id"]))
		"set_transform":
			var object_id := str(operation["object_id"])
			var body := object_node(object_id)
			if body != null:
				var data := wire_object(object_id)
				for key in ["position", "rotation", "scale"]:
					if operation.has(key):
						data[key] = operation[key]
				var before := object_state(object_id)
				apply_wire_object(data)
				undo_stack.append({"id": object_id, "before": before, "after": object_state(object_id)})
		"duplicate_object":
			duplicate_object(str(operation["object_id"]), str(operation["new_id"]))
		"undo":
			undo()
		"redo":
			redo()
	suppress_commits = old_suppression
	changed.emit()


func _vec3(value: Vector3) -> Array:
	return [value.x, value.y, value.z]


func _quat(value: Quaternion) -> Array:
	return [value.x, value.y, value.z, value.w]


func _array_vec3(value: Array) -> Vector3:
	return Vector3(float(value[0]), float(value[1]), float(value[2]))


func _record(object_id: String, before: Dictionary, after: Dictionary) -> void:
	_apply_state(object_id, after)
	undo_stack.append({"id": object_id, "before": before, "after": after})
	redo_stack.clear()
	changed.emit()


func _apply_state(object_id: String, state: Dictionary) -> void:
	var old := object_node(object_id)
	if state.is_empty():
		if old != null:
			objects.erase(object_id)
			old.queue_free()
		return
	if old != null and old.get_meta("asset_key") == state["asset"]:
		old.transform = state["transform"]
		old.set_meta("scene_data", state.get("data", {}))
		return
	if old != null:
		objects.erase(object_id)
		old.queue_free()
	var asset: Dictionary = asset_info(str(state["asset"]))
	if asset.is_empty():
		push_error("Unknown catalog asset: " + str(state["asset"]))
		return
	var visual := instantiate_asset(str(state["asset"]))
	if visual == null:
		push_error("Could not load catalog asset: " + str(asset["path"]))
		return
	var body := StaticBody3D.new()
	body.name = str(asset["label"]) + "_" + object_id.substr(0, 8)
	body.collision_layer = 8 # Selection ray only; player movement ignores placed props in M2.
	body.collision_mask = 0
	body.transform = state["transform"]
	body.set_meta("object_id", object_id)
	body.set_meta("asset_key", state["asset"])
	body.set_meta("scene_data", state.get("data", {}))
	add_child(body)
	visual.name = "Visual"
	body.add_child(visual)
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	var size: Vector3 = asset["size"]
	shape.size = size
	collision.shape = shape
	collision.position.y = size.y * 0.5
	body.add_child(collision)
	objects[object_id] = body


func _new_uuid() -> String:
	var data := Crypto.new().generate_random_bytes(16)
	data[6] = (data[6] & 0x0f) | 0x40
	data[8] = (data[8] & 0x3f) | 0x80
	var value := data.hex_encode()
	return "%s-%s-%s-%s-%s" % [value.substr(0, 8), value.substr(8, 4), value.substr(12, 4), value.substr(16, 4), value.substr(20, 12)]
