extends SceneTree

# The headset home panel must turn a pointing ray into clicks on the shared
# home screen, and must switch off the actions that need the desktop app.


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	var shell: Node3D = (load("res://scenes/home_xr.tscn") as PackedScene).instantiate()
	root.add_child(shell)
	shell.set_process(false)
	await create_timer(0.5).timeout
	var home: Control = shell.home
	assert(home.panel_mode, "Home did not detect that it is hosted on a panel")
	home.scenes = [{"scene_id": "panel-first", "revision": 0, "object_count": 0, "has_environment": false,
		"has_walkable": false, "has_brief": true, "title": ""},
		{"scene_id": "panel-test", "revision": 0, "object_count": 0, "has_environment": false,
		"has_walkable": false, "has_brief": false, "title": ""}]
	home._fill_scene_rows()
	home._select_scene_id("panel-first")
	await process_frame
	var disabled := {}
	for button in home.find_children("*", "Button", true, false):
		disabled[(button as Button).text] = (button as Button).disabled
	assert(disabled.get("Import a GLB · desktop only", false), "Desktop-only action is enabled on the panel")
	assert(disabled.get("Build from brief · not built yet", false), "Planned action is enabled")
	assert(disabled.get("Edit scene", true) == false, "Edit scene should work on the panel")

	var row: Button = home.scene_buttons["panel-test"]
	var pixel := row.get_global_rect().get_center()
	var local := Vector3((pixel.x / shell.VIEW_SIZE.x - 0.5) * shell.PANEL_SIZE.x,
		(0.5 - pixel.y / shell.VIEW_SIZE.y) * shell.PANEL_SIZE.y, 0.0)
	var origin := Vector3(0.3, 1.2, 0.0)
	var direction: Vector3 = (shell.panel.to_global(local) - origin).normalized()
	assert(shell.panel_pixel(origin, direction).distance_to(pixel) < 1.0, "Ray did not map to the expected pixel")
	assert(shell.panel_pixel(origin, Vector3.UP).x < 0, "A ray that misses the panel reported a hit")
	shell.point_at(origin, direction, false)
	shell.point_at(origin, direction, true)
	await process_frame
	shell.point_at(origin, direction, false)
	await process_frame
	assert(home.selected_scene == "panel-test", "Pointing and clicking did not select the scene")
	print("Home panel: ray pointer selects a scene; unavailable actions are disabled")
	quit()
