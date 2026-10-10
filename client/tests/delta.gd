extends SceneTree


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	var world := scene.instantiate()
	root.add_child(world)
	var sync: WorldsmithSceneSync = world.get_node("SceneSync")
	var editor: WorldsmithSceneEditor = world.get_node("PlacedObjects")
	var initial_count := -1
	for index in range(200):
		await create_timer(0.05).timeout
		if sync.online and initial_count < 0:
			initial_count = editor.objects.size()
			print("M3 client: connected with %d objects" % initial_count)
		elif sync.online and initial_count >= 0 and editor.objects.size() > initial_count:
			print("M3 client: live server delta added an object")
			quit()
			return
	push_error("Live server delta did not arrive")
	quit(1)
