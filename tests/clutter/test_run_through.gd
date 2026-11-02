extends Node3D
## Round 6 run-through (agent K): the player (real Traversal: stick + held
## Dash, the sprint ramp) running into a glass pane or a cardboard box at
## Tuning.RUN_THROUGH_SPEED (6 m/s) or more smashes it (furniture_broken by
## him) and runs on; walking into them (Tuning.WALK_SPEED) does not: the glass
## holds and stops him, the box is shoved loose but not broken. An enemy
## walking into glass does not break it either. Parkour over clutter (the real
## Traversal): sprinting at a table, a bench, a sofa, a barrel or a railing
## vaults it (it stays whole); walking into a shelf stops him (a wall).

const RUN_UP := 12.0     ## m from the start to the object

var _ok := true
var _breaks: Array = []

func _line(s: String, ok: bool) -> void:
	_ok = _ok and ok
	print("[run] %s -> %s" % [s, "PASS" if ok else "FAIL"])

func _ready() -> void:
	ClutterTestUtil.make_floor(self, 400.0)
	ClutterTestUtil.record_breaks(_breaks)
	await ClutterTestUtil.frames(self, 2)
	await _case(&"glass", true, 0.0)
	await _case(&"glass", false, 15.0)
	await _case(&"cardboard", true, 30.0)
	await _case(&"cardboard", false, 45.0)
	await _enemy_walk(60.0)
	var x := 75.0
	for kind: StringName in [&"table", &"bench", &"sofa", &"barrel", &"fence", &"planter"]:
		await _vault(kind, x)
		x += 12.0
	await _shelf_wall(x)
	print("[run] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _case(kind: StringName, sprint: bool, x: float) -> void:
	_breaks.clear()
	var obj := ClutterTestUtil.make(self, kind, Vector3(x, 0, 0))
	await ClutterTestUtil.frames(self, 1)
	var face_z := obj.get_box_transform().origin.z + obj.get_half_extent_along(Vector3.BACK)
	var p := FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), Vector3(x, 0.05, face_z + RUN_UP)),
		Fighter.TEAM_PLAYER)
	await ClutterTestUtil.frames(self, 15)
	p.move_input = Vector3(0, 0, -1)
	if sprint:
		p.combat.press(CombatController.Action.DASH)
	var speed_at := -1.0
	var top := 0.0
	var t := 0.0
	while t < 4.0:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		top = maxf(top, ClutterTestUtil.hspeed(p))
		if obj.is_broken and speed_at < 0.0:
			speed_at = ClutterTestUtil.hspeed(p)
		if obj.is_broken and p.global_position.z < face_z - 2.0:
			break
	if sprint:
		p.combat.release(CombatController.Action.DASH)
	var ev := _breaks.filter(func(e: Dictionary) -> bool: return e["node"] == obj)
	var past := p.global_position.z < face_z - 1.0
	if sprint:
		_line("sprint into %-9s: top speed %.1f m/s, smashed=%s by player=%s at %.1f m/s (min %.1f), ran through=%s" % [
			kind, top, obj.is_broken, ev.size() == 1 and ev[0]["by"] == p, speed_at, Tuning.RUN_THROUGH_SPEED, past],
			obj.is_broken and ev.size() == 1 and ev[0]["by"] == p and speed_at >= Tuning.RUN_THROUGH_SPEED - 0.05 and past)
	else:
		var front := p.global_position.z - face_z
		if kind == &"glass":
			_line("walk into %-9s: top speed %.1f m/s, broken=%s, stopped %.2f m from the face" % [kind, top,
				obj.is_broken, front], not obj.is_broken and top < Tuning.RUN_THROUGH_SPEED and front > 0.0 and front < 0.6)
		else:
			_line("walk into %-9s: top speed %.1f m/s, broken=%s, shoved loose=%s" % [kind, top, obj.is_broken,
				obj.is_loose], not obj.is_broken and obj.is_loose and top < Tuning.RUN_THROUGH_SPEED)
	p.move_input = Vector3.ZERO
	for n in [obj, p]:
		if is_instance_valid(n):
			n.queue_free()
	if obj.loose_body != null and is_instance_valid(obj.loose_body):
		obj.loose_body.queue_free()
	ClutterTestUtil.cleanup()
	await ClutterTestUtil.frames(self, 2)

## An enemy walking into glass does not break it.
func _enemy_walk(x: float) -> void:
	var obj := ClutterTestUtil.make(self, &"glass", Vector3(x, 0, 0))
	await ClutterTestUtil.frames(self, 1)
	var face_z := obj.get_box_transform().origin.z + obj.get_half_extent_along(Vector3.BACK)
	var e := FighterFactory.spawn_dummy(self, &"grunt", Transform3D(Basis(), Vector3(x, 0.05, face_z + 4.0)))
	await ClutterTestUtil.frames(self, 15)
	e.move_input = Vector3(0, 0, -1)
	var top := 0.0
	for i in 360:
		await get_tree().physics_frame
		top = maxf(top, ClutterTestUtil.hspeed(e))
	_line("enemy walking into glass at %.1f m/s: broken=%s" % [top, obj.is_broken], not obj.is_broken)
	for n in [obj, e]:
		n.queue_free()
	ClutterTestUtil.cleanup()
	await ClutterTestUtil.frames(self, 2)

## Sprinting at low clutter: a vault (Traversal), and it stays whole.
func _vault(kind: StringName, x: float) -> void:
	var obj := ClutterTestUtil.make(self, kind, Vector3(x, 0, 0))
	await ClutterTestUtil.frames(self, 1)
	var face_z := obj.get_box_transform().origin.z + obj.get_half_extent_along(Vector3.BACK)
	var p := FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), Vector3(x, 0.05, face_z + RUN_UP)),
		Fighter.TEAM_PLAYER)
	await ClutterTestUtil.frames(self, 15)
	p.move_input = Vector3(0, 0, -1)
	p.combat.press(CombatController.Action.DASH)
	var kinds := {}
	var t := 0.0
	while t < 3.5 and p.global_position.z > face_z - 3.0:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		var k: StringName = p.traversal.get_parkour_kind() if p.traversal != null else &""
		if k != &"":
			kinds[k] = true
	p.combat.release(CombatController.Action.DASH)
	var over := p.global_position.z < face_z - 1.0
	_line("sprint at a %-7s (top %.2f m): parkour %s, got over=%s, intact=%s" % [kind, obj.get_spec().bounds.end.y,
		kinds.keys(), over, not obj.is_broken and not obj.is_loose],
		(kinds.has(&"vault") or kinds.has(&"step")) and over and not obj.is_broken and not obj.is_loose)
	p.move_input = Vector3.ZERO
	for n in [obj, p]:
		n.queue_free()
	ClutterTestUtil.cleanup()
	await ClutterTestUtil.frames(self, 2)

## Walking into a shelf: stopped (tall clutter is a wall until it breaks).
func _shelf_wall(x: float) -> void:
	var obj := ClutterTestUtil.make(self, &"shelf", Vector3(x, 0, 0))
	await ClutterTestUtil.frames(self, 1)
	var face_z := obj.get_box_transform().origin.z + obj.get_half_extent_along(Vector3.BACK)
	var p := FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), Vector3(x, 0.05, face_z + 5.0)),
		Fighter.TEAM_PLAYER)
	await ClutterTestUtil.frames(self, 15)
	p.move_input = Vector3(0, 0, -1)
	for i in 300:
		await get_tree().physics_frame
	var front := p.global_position.z - face_z
	_line("walk into a shelf: stopped %.2f m from its face, shelf intact=%s" % [front, not obj.is_broken],
		front > 0.0 and front < 0.6 and not obj.is_broken)
	p.move_input = Vector3.ZERO
	for n in [obj, p]:
		n.queue_free()
	ClutterTestUtil.cleanup()
	await ClutterTestUtil.frames(self, 2)
