extends SceneTree


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	var panel := WorldsmithEditPanel.new()
	root.add_child(panel)
	var assets: Array = []
	for index in range(6):
		assets.append({"id": "asset_%d" % index, "name": "Asset %d" % index})
	panel.set_assets(assets)
	assert(panel.asset_rows.size() == 8, "First catalog page should show four assets, next page, and commands")
	assert(panel.asset_rows[0]["action"] == "place:asset_0")
	panel._activate("assets_next")
	assert(panel.asset_rows[0]["action"] == "place:asset_4")
	assert(panel.asset_rows.size() == 6)
	panel.set_assets([])
	assert(panel.asset_rows.size() == 3, "Empty catalog should expose commands only")
	print("Catalog inventory: dynamic pages and empty catalog loaded")
	quit()
