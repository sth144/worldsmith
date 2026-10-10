extends SceneTree


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	var world := scene.instantiate()
	root.add_child(world)
	await physics_frame
	var preview := world.get_node_or_null("PreviewWorld")
	assert(preview != null, "Preview GLB was not loaded")
	var meshes := preview.find_children("*", "MeshInstance3D", true, false)
	assert(meshes.size() > 0, "Preview has no meshes")
	var terrain: MeshInstance3D = preview.find_child("Grid_001", true, false)
	assert(terrain != null, "Terrain was not imported")
	var terrain_material: Material = terrain.mesh.surface_get_material(0)
	assert(terrain_material is StandardMaterial3D and terrain_material.albedo_texture != null, "Terrain base color was not baked")
	var grass: MultiMeshInstance3D = preview.get_node_or_null("PreviewInstances")
	assert(grass != null and grass.multimesh.instance_count > 0, "Geometry Nodes grass instances were not loaded")
	var floor_ray := PhysicsRayQueryParameters3D.create(Vector3(-13, 27, 10), Vector3(-13, 19, 10), 1)
	assert(not world.get_world_3d().direct_space_state.intersect_ray(floor_ray).is_empty(), "Courtyard has no teleportable collision")
	print("Preview smoke: %d meshes, %d grass instances, baked terrain, collision OK" % [meshes.size(), grass.multimesh.instance_count])
	quit()
