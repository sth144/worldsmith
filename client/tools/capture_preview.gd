extends SceneTree

# Render an eye-level preview with the real Worldsmith client. All content and
# camera settings come from command-line arguments and ignored project data.


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	var output := ""
	var width := 1280
	var height := 800
	var frames := 60
	var allow_empty := false
	var home := false
	var home_dialog := ""
	var home_view_brief := ""
	var camera_position := ""
	var yaw := 0.0
	var pitch := 0.0
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--output="):
			output = argument.trim_prefix("--output=")
		elif argument.begins_with("--width="):
			width = int(argument.trim_prefix("--width="))
		elif argument.begins_with("--height="):
			height = int(argument.trim_prefix("--height="))
		elif argument.begins_with("--frames="):
			frames = int(argument.trim_prefix("--frames="))
		elif argument == "--allow-empty":
			allow_empty = true
		elif argument == "--home":
			home = true
		elif argument.begins_with("--home-dialog="):
			home_dialog = argument.trim_prefix("--home-dialog=")
		elif argument.begins_with("--home-view-brief="):
			home_view_brief = argument.trim_prefix("--home-view-brief=")
		elif argument.begins_with("--camera-position="):
			camera_position = argument.trim_prefix("--camera-position=")
		elif argument.begins_with("--yaw-deg="):
			yaw = float(argument.trim_prefix("--yaw-deg="))
		elif argument.begins_with("--pitch-deg="):
			pitch = float(argument.trim_prefix("--pitch-deg="))
	if output.is_empty() or width < 64 or height < 64 or frames < 2:
		push_error("Supply --output=<absolute.png> and positive --width, --height, --frames")
		quit(2)
		return
	root.size = Vector2i(width, height)
	if home:
		root.gui_embed_subwindows = true
	var packed: PackedScene = load("res://scenes/home.tscn" if home else "res://scenes/main.tscn")
	if packed == null:
		push_error("Worldsmith main scene could not load")
		quit(1)
		return
	var world: Node = packed.instantiate()
	root.add_child(world)
	if home and not home_dialog.is_empty():
		var dialog: Window = world.get(home_dialog + "_dialog")
		if dialog != null:
			dialog.popup_centered()
	if not home:
		# Hold the review camera at the requested pose while assets finish loading.
		# Preview terrain may not have collision beneath every inspection position.
		world.set_physics_process(false)
		var player := world.get_node("Player") as CharacterBody3D
		var camera := world.get_node("Player/DesktopCamera") as Camera3D
		if camera_position != "":
			var components := camera_position.split(",")
			if components.size() != 3:
				push_error("Camera position must be x,y,z")
				quit(2)
				return
			player.position = Vector3(float(components[0]), float(components[1]), float(components[2]))
		player.rotation.y = deg_to_rad(yaw)
		camera.rotation.x = deg_to_rad(pitch)
	for frame in range(frames):
		await process_frame
	if home and not home_view_brief.is_empty():
		await create_timer(1.0).timeout
		print("Home capture scenes: ", (world.get("scene_list") as ItemList).item_count)
		world.call("_select_scene_id", home_view_brief)
		print("Home capture selected: ", world.get("selected_scene"))
		world.call("_view_brief")
		await create_timer(3.0).timeout
		print("Home capture status: ", (world.get("status_label") as Label).text)
		print("Home capture brief dialog: ", (world.get("brief_dialog") as AcceptDialog).visible)
	if not home and not allow_empty and world.get_node_or_null("PreviewWorld") == null:
		push_error("No preview world loaded")
		quit(1)
		return
	var image := root.get_texture().get_image()
	var result := image.save_png(output)
	print("Preview capture: %s (%d x %d), result=%d" % [output, width, height, result])
	quit(0 if result == OK else 1)
