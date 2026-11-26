extends SceneTree

# Render any imported GLB under fixed real-time studio lighting. This is a
# material and geometry review, separate from the walkable scene preview.


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	var asset_path := ""
	var output := ""
	var width := 1000
	var height := 1000
	var frames := 24
	var yaw_deg := 25.0
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--asset="):
			asset_path = argument.trim_prefix("--asset=")
		elif argument.begins_with("--output="):
			output = argument.trim_prefix("--output=")
		elif argument.begins_with("--width="):
			width = int(argument.trim_prefix("--width="))
		elif argument.begins_with("--height="):
			height = int(argument.trim_prefix("--height="))
		elif argument.begins_with("--frames="):
			frames = int(argument.trim_prefix("--frames="))
		elif argument.begins_with("--yaw-deg="):
			yaw_deg = float(argument.trim_prefix("--yaw-deg="))
	if asset_path.is_empty() or output.is_empty() or width < 64 or height < 64 or frames < 2:
		push_error("Supply --asset=<GLB> and --output=<absolute.png> with valid dimensions")
		quit(2)
		return
	root.size = Vector2i(width, height)
	var scene: PackedScene = load(asset_path)
	if scene == null:
		push_error("Asset GLB is not imported: " + asset_path)
		quit(1)
		return
	var stage := Node3D.new()
	stage.name = "AssetReviewStage"
	root.add_child(stage)
	var asset := scene.instantiate() as Node3D
	stage.add_child(asset)
	var bounds := _world_bounds(asset)
	if bounds.size.length() <= 0.001:
		push_error("Asset has no visible mesh bounds: " + asset_path)
		quit(1)
		return
	var center := bounds.get_center()
	var radius := maxf(bounds.size.length() * 0.5, 0.5)
	_add_environment(stage)
	_add_floor(stage, bounds, radius)
	_add_lights(stage, center, radius)
	var camera := Camera3D.new()
	camera.name = "ReviewCamera"
	stage.add_child(camera)
	var yaw := deg_to_rad(yaw_deg)
	camera.position = center + Vector3(sin(yaw) * radius * 2.7,
		bounds.size.y * 0.08 + radius * 0.35, cos(yaw) * radius * 2.7)
	camera.look_at(center + Vector3(0, bounds.size.y * 0.06, 0), Vector3.UP)
	camera.fov = 38.0
	camera.current = true
	for frame in range(frames):
		await process_frame
	var image := root.get_texture().get_image()
	if image == null:
		push_error("No viewport image available; run capture with the GPU renderer")
		quit(1)
		return
	var result := image.save_png(output)
	print("Asset capture: %s (%d x %d), result=%d" % [output, width, height, result])
	quit(0 if result == OK else 1)


func _world_bounds(asset: Node3D) -> AABB:
	var found := false
	var bounds := AABB()
	for node in asset.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		var local := mesh_instance.get_aabb()
		for x in [local.position.x, local.end.x]:
			for y in [local.position.y, local.end.y]:
				for z in [local.position.z, local.end.z]:
					var point := mesh_instance.global_transform * Vector3(x, y, z)
					if not found:
						bounds = AABB(point, Vector3.ZERO)
						found = true
					else:
						bounds = bounds.expand(point)
	return bounds


func _add_environment(stage: Node3D) -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.23, 0.26, 0.30)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.62, 0.67, 0.73)
	environment.ambient_light_energy = 0.28
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	stage.add_child(world_environment)


func _add_floor(stage: Node3D, bounds: AABB, radius: float) -> void:
	var floor := MeshInstance3D.new()
	floor.name = "NeutralReviewFloor"
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(radius * 12, radius * 12)
	floor.mesh = mesh
	floor.position.y = bounds.position.y - 0.02
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.16, 0.17, 0.19)
	material.roughness = 0.92
	floor.material_override = material
	stage.add_child(floor)


func _add_lights(stage: Node3D, center: Vector3, radius: float) -> void:
	for setup in [
		{"offset": Vector3(-2.0, 3.5, 3.0), "energy": 0.60, "color": Color(1.0, 0.91, 0.78)},
		{"offset": Vector3(2.0, 2.0, -2.5), "energy": 0.22, "color": Color(0.73, 0.82, 1.0)},
	]:
		var light := DirectionalLight3D.new()
		stage.add_child(light)
		light.position = center + (setup["offset"] as Vector3) * radius
		light.look_at(center, Vector3.UP)
		light.light_energy = float(setup["energy"])
		light.light_color = setup["color"] as Color
		light.shadow_enabled = false
