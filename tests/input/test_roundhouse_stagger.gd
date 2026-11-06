extends "res://tests/input/input_test_base.gd"
## Tuning.ROUNDHOUSE_STAGGER (real input, real fighters):
## - a tapped roundhouse on a grunt whose guard isn't broken staggers it: a
##   push reaction, never a full ragdoll, the upper body partly ragdoll right
##   after the hit, pushed back, able to act again after the stun; with the
##   Mixamo clips on (F5) and off;
## - on a broken guard the same tap still knocks it down.

var _reacts: Array = []   ## [victim, kind]

func run() -> void:
	_timeout = 90.0
	GameEvents.react_started.connect(func(f: Node3D, kind: StringName, _a: Node3D) -> void:
		_reacts.append([f, kind]))
	var p := spawn_player(Vector3.ZERO)
	await ticks(40)
	for clips in [true, false]:
		Tuning.debug_clip_anims = clips
		await _stagger_case(p, clips)
	Tuning.debug_clip_anims = false
	await _broken_case(p)
	done()

func _stagger_case(p: Fighter, clips: bool) -> void:
	var tag := "clips on" if clips else "clips off"
	var v := await _victim(p, Vector3(4.0 if clips else -4.0, 0, 0))
	_reacts.clear()
	var z0 := v.global_position
	await _tap(&"roundhouse")
	var hit := await wait_until(func() -> bool: return _reacted(v, &"push") or _reacted(v, &"knockdown") \
		or v.ragdoll.is_full_ragdoll(), 240)
	var min_strength := 1.0
	var full := false
	var pushed := 0.0
	for i in 120:
		await get_tree().physics_frame
		min_strength = minf(min_strength, v.ragdoll.get_bone_strength(Bones.CHEST))
		full = full or v.ragdoll.is_full_ragdoll()
		pushed = maxf(pushed, Vector2(v.global_position.x - z0.x, v.global_position.z - z0.z).length())
	print("  %s: hit %s, reacts %s, chest strength min %.2f, full ragdoll %s, pushed %.2f m" % [
		tag, hit, _kinds(v), min_strength, full, pushed])
	check(hit and _reacted(v, &"push") and not full, "%s: a tapped roundhouse on an unbroken guard staggers (push, no knockdown)" % tag)
	check(min_strength < 0.5, "%s: the upper body goes partly ragdoll (chest strength %.2f)" % [tag, min_strength])
	check(pushed > 0.5, "%s: pushed back (%.2f m)" % [tag, pushed])
	var acts := await wait_until(func() -> bool: return v.can_act(), 240)
	check(acts and not v.ragdoll.is_full_ragdoll(), "%s: on its feet and able to act after the stun" % tag)
	v.queue_free()
	await ticks(10)

func _broken_case(p: Fighter) -> void:
	var v := await _victim(p, Vector3(0, 0, 4.0))
	var taps := 0
	while not v.combat.is_broken() and taps < 8:
		await _tap(&"punch")
		taps += 1
		await wait_until(func() -> bool: return v.combat.is_broken() or (p.can_act() and not p.combat.is_attacking()), 240)
	check(v.combat.is_broken(), "the guard breaks under punch taps (%d)" % taps)
	await wait_until(func() -> bool: return p.can_act() and not p.combat.is_attacking(), 240)
	_reacts.clear()
	await _tap(&"roundhouse")
	var down := await wait_until(func() -> bool: return v.ragdoll.is_full_ragdoll(), 240)
	print("  broken: reacts %s, full ragdoll %s" % [_kinds(v), down])
	check(down and not _reacted(v, &"push"), "a tapped roundhouse on a broken guard still knocks it down")

func _victim(p: Fighter, at: Vector3) -> Fighter:
	await wait_until(func() -> bool: return p.can_act() and not p.combat.is_attacking() and not p.is_airborne(), 600)
	p.teleport_to(at, Vector3.FORWARD)
	var v := spawn_dummy(&"grunt", at + Vector3(0, 0, -1.2), Vector3.BACK)
	await ticks(30)
	return v

func _tap(action: StringName) -> void:
	press(action)
	await ticks(1)
	release(action)
	await ticks(1)

func _reacted(v: Fighter, kind: StringName) -> bool:
	for e: Array in _reacts:
		if e[0] == v and e[1] == kind:
			return true
	return false

func _kinds(v: Fighter) -> Array[StringName]:
	var out: Array[StringName] = []
	for e: Array in _reacts:
		if e[0] == v:
			out.append(e[1])
	return out
