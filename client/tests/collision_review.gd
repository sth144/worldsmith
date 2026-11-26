extends SceneTree

# An imported environment is not runnable until its collision is reviewed. After
# the review is saved, the scene loads with walkable collision and the player
# lands on the ground. Needs a server holding a scene with an unreviewed
# environment: pass --server-url=ws://host:port and --scene-id=<id>.


func _initialize() -> void:
	call_deferred("_check")


func _argument(prefix: String) -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(prefix):
			return argument.trim_prefix(prefix)
	return ""


func _check() -> void:
	var scene_id := _argument("--scene-id=")
	assert(not scene_id.is_empty() and not _argument("--server-url=").is_empty(), "Supply --server-url and --scene-id")
	var home: Control = (load("res://scenes/home.tscn") as PackedScene).instantiate()
	root.add_child(home)
	await create_timer(1.0).timeout
	home._select_scene_id(scene_id)
	assert(home.selected_scene == scene_id, "Scene is not listed")
	home._open_selected_scene(true)
	assert(home.status_label.text.contains("no walkable collision"), "An unreviewed import was allowed to run")

	home._review_collision()
	await create_timer(1.0).timeout
	var review: WorldsmithCollisionReview = home.collision_review
	assert(review.visible and not review.meshes.is_empty(), "Review did not list the environment's meshes")
	var first_role: String = review.meshes[0]["role"]
	review._on_mesh_clicked(0, Vector2.ZERO, MOUSE_BUTTON_LEFT)
	assert(review.meshes[0]["role"] != first_role, "Selecting a mesh did not change its role")
	review._use_suggestions()
	assert(review.meshes[0]["role"] == "walkable", "The largest mesh was not suggested as walkable ground")
	var spawn_height: float = review.spawn_boxes[1].value
	review._save()
	await create_timer(1.5).timeout
	assert(not review.visible and home.status_label.text.contains("Collision saved"), "Review did not save: " + review.status.text)
	assert(home._selected_scene_item()["has_walkable"], "Saved scene is not listed as walkable")

	root.set_meta("worldsmith_scene_id", scene_id)
	root.set_meta("worldsmith_server_url", home.server_url)
	root.set_meta("worldsmith_view_only", true)
	home.queue_free()
	var world: Node3D = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(world)
	for attempt in range(100):
		if world.get_node_or_null("PreviewWorld") != null:
			break
		await create_timer(0.1).timeout
	var preview := world.get_node_or_null("PreviewWorld")
	assert(preview != null, "Reviewed environment did not load")
	var walkable := 0
	for body in preview.find_children("*", "StaticBody3D", true, false):
		if body.collision_layer == 1:
			walkable += 1
	assert(walkable > 0, "Reviewed scene has no walkable collision")
	var player := world.get_node("Player") as CharacterBody3D
	for frame in range(120):
		await physics_frame
	assert(player.is_on_floor(), "Player did not land on the ground")
	assert(player.position.y < spawn_height and player.position.y > spawn_height - 1.0, "Player fell through the ground")
	print("Collision review: import blocked until reviewed; %d walkable meshes; player landed at y=%.2f" % [walkable, player.position.y])
	quit()
