extends "res://scripts/core/time_director.gd"
## Test stand-in for TimeDirector's Focus (tests/input only). begin_focus()
## sets Engine.time_scale to the Focus scale; player_time_factor() undoes it
## exactly. Every other TimeDirector call runs the real code.
## OWNER: agent H (body & player input).

var fake_active := false

func begin_focus(scale := Tuning.FOCUS_SCALE) -> bool:
	fake_active = true
	Engine.time_scale = clampf(scale, 0.01, 1.0)
	return true

func end_focus() -> void:
	fake_active = false
	Engine.time_scale = 1.0

func is_focus_active() -> bool:
	return fake_active

func player_time_factor() -> float:
	return 1.0 / maxf(Engine.time_scale, 0.01) if fake_active else 1.0

func player_delta(delta: float) -> float:
	return delta * player_time_factor()
