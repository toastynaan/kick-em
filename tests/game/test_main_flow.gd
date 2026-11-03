extends Node
## Full flow through scenes/main.tscn: title -> duel, pause (restart, debug
## settings: the upgrades speed cap / Battering Ram / teleport / pursuit chain,
## Round 8's charge time / pressure / launch step / air hits, and the overlay,
## saved, loaded and clamped; in the Duel they edit the player's own values
## while the live ones stay at max; no starting Focus) and resume,
## restart (scene reload) from the pause item, Backspace in play and in the
## pause menu, Start then Back on the gamepad, back to the main menu
## (Backspace does nothing there), waves. A driver node parked under the root
## survives the scene changes and checks each step.

func _ready() -> void:
	var driver := Node.new()
	driver.name = "MainFlowDriver"
	driver.set_script(load("res://tests/game/main_flow_driver.gd"))
	get_tree().root.add_child.call_deferred(driver)
