extends SceneTree


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	var editor := WorldsmithSceneEditor.new()
	root.add_child(editor)
	var object_id := editor.add_object("chair", Transform3D.IDENTITY)
	var wire := editor.wire_object(object_id)
	wire["metadata"] = {"material_color": [0.85, 0.08, 0.06, 1]}
	editor.apply_wire_object(wire)
	wire["metadata"] = {"material_overrides": {"Sea green fabric": [0.85, 0.08, 0.06, 1]}}
	editor.apply_wire_object(wire)
	var visual := editor.object_node(object_id).get_node("Visual")
	var cushion := visual.find_child("Chair cushion", true, false) as MeshInstance3D
	var seat := visual.find_child("Chair seat", true, false) as MeshInstance3D
	if cushion == null or seat == null:
		_fail("Chair GLB parts were not found")
		return
	if cushion.material_override != null or seat.material_override != null:
		_fail("Whole-object tint was not cleared")
		return
	var fabric := cushion.get_surface_override_material(0) as BaseMaterial3D
	if fabric == null or not is_equal_approx(fabric.albedo_color.r, 0.85):
		_fail("Upholstery was not repainted")
		return
	if seat.get_surface_override_material(0) != null:
		_fail("Wood was repainted")
		return
	print("M4 material scope: red upholstery, original wood OK")
	quit()


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
