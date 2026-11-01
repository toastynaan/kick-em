extends Node
## Full flow through scenes/main.tscn: title -> duel via pending mode, pause and
## resume, restart (scene reload), waves, back to the main menu. A driver node
## parked under the root survives the scene changes and checks each step.

func _ready() -> void:
	var driver := Node.new()
	driver.name = "MainFlowDriver"
	driver.set_script(load("res://tests/game/main_flow_driver.gd"))
	get_tree().root.add_child.call_deferred(driver)
