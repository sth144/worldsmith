extends Node3D
class_name WorldsmithSceneEditor

signal changed

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


func asset_info(asset_key: String) -> Dictionary:
	return CATALOG.get(asset_key, {})


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
	return {"id": object_id, "asset": body.get_meta("asset_key"), "transform": body.transform}


func add_object(asset_key: String, object_transform: Transform3D) -> String:
	if not CATALOG.has(asset_key):
		return ""
	var object_id := _new_uuid()
	_record(object_id, {}, {"id": object_id, "asset": asset_key, "transform": object_transform})
	return object_id


func delete_object(object_id: String) -> bool:
	var before := object_state(object_id)
	if before.is_empty():
		return false
	_record(object_id, before, {})
	return true


func set_object_transform(object_id: String, object_transform: Transform3D) -> bool:
	var before := object_state(object_id)
	if before.is_empty() or before["transform"] == object_transform:
		return false
	var after := before.duplicate()
	after["transform"] = object_transform
	_record(object_id, before, after)
	return true


func duplicate_object(object_id: String) -> String:
	var before := object_state(object_id)
	if before.is_empty():
		return ""
	var copied_transform: Transform3D = before["transform"]
	copied_transform.origin += Vector3(0.55, 0, 0.55)
	return add_object(str(before["asset"]), copied_transform)


func undo() -> bool:
	if undo_stack.is_empty():
		return false
	var entry: Dictionary = undo_stack.pop_back()
	_apply_state(str(entry["id"]), entry["before"])
	redo_stack.append(entry)
	changed.emit()
	return true


func redo() -> bool:
	if redo_stack.is_empty():
		return false
	var entry: Dictionary = redo_stack.pop_back()
	_apply_state(str(entry["id"]), entry["after"])
	undo_stack.append(entry)
	changed.emit()
	return true


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
		return
	if old != null:
		objects.erase(object_id)
		old.queue_free()
	var asset: Dictionary = asset_info(str(state["asset"]))
	if asset.is_empty():
		push_error("Unknown catalog asset: " + str(state["asset"]))
		return
	var packed := load(str(asset["path"])) as PackedScene
	if packed == null:
		push_error("Could not load catalog asset: " + str(asset["path"]))
		return
	var body := StaticBody3D.new()
	body.name = str(asset["label"]) + "_" + object_id.substr(0, 8)
	body.collision_layer = 8 # Selection ray only; player movement ignores placed props in M2.
	body.collision_mask = 0
	body.transform = state["transform"]
	body.set_meta("object_id", object_id)
	body.set_meta("asset_key", state["asset"])
	add_child(body)
	var visual := packed.instantiate()
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
