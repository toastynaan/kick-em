extends Node
## Upgrade 2 U3 limb-glow tells: the tell glows on the attacking limb
## (BloodFX.limb_glow) with the timing ring round it; while limb_glow returns
## null (F has not landed it) the star glint above the head stays, so a tell
## never vanishes. Glow bones follow the move's height; the ring's meet point
## follows the time scale (Focus). OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")

var failures := 0

func _ready() -> void:
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	print("[ai] %s: %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures += 1

func _glint(f: Node) -> TellGlint:
	for c in f.get_children():
		if c is TellGlint and not c.is_queued_for_deletion():
			return c
	return null

func _run() -> void:
	AttackDirector.reset()
	AttackDirector.camera_busy = true
	Util.build_floor(self)
	var player := FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), Vector3(0, 0.05, 0)), Fighter.TEAM_PLAYER)
	Util.ensure_wired(player)
	AttackDirector.set_player(player)
	var e := FighterFactory.spawn_enemy(self, &"grunt", Transform3D(Basis(), Vector3(0, 0.05, -1.4)))
	await get_tree().physics_frame

	# Bones per move / height.
	var hook := TellGlint.glow_bones(&"e_hook")
	var kick := TellGlint.glow_bones(&"e_kick")
	var grab := TellGlint.glow_bones(&"e_grab", &"grab")
	var sweep := TellGlint.glow_bones(&"e_sweep")
	var counter := TellGlint.glow_bones(&"back_kick", &"counter")
	check(hook.size() == 1 and String(hook[0]).ends_with("Hand"), "HIGH hook glows a fist (%s)" % str(hook))
	check(kick.size() == 1 and String(kick[0]).ends_with("Foot"), "MID kick glows a foot (%s)" % str(kick))
	check(sweep.size() == 1 and String(sweep[0]).ends_with("Foot"), "LOW sweep glows a foot (%s)" % str(sweep))
	check(grab.size() == 2 and grab.all(func(b): return String(b).ends_with("Hand")), "a grab glows both hands (%s)" % str(grab))
	check(counter.size() == 1 and String(counter[0]).ends_with("Foot"), "the counter back kick glows a foot (%s)" % str(counter))

	# Does BloodFX have limb_glow yet? Probe once.
	var probe: Node3D = BloodFX.limb_glow(e, &"RightHand", Color.WHITE, 0.1, 1.0)
	var has_glow := probe != null
	if probe:
		probe.queue_free()
	print("[ai] info: BloodFX.limb_glow %s" % ("returns a glow" if has_glow else "returns null (fallback expected)"))

	if not e.has_method(&"_physics_process") or not e.combat.start_enemy_attack(&"e_hook", 0.5):
		# No real combat: emit the tell by hand.
		GameEvents.attack_tell.emit(e, &"strike", 0.5)
	for i in 6:
		await get_tree().process_frame
	var g := _glint(e)
	check(g != null, "a tell node exists while the hook winds up")
	if g:
		if has_glow:
			check(g.is_limb_glow() and g.mesh == null, "limb glow shown, star hidden")
			var bone_pos: Vector3 = e.rig.get_bone_global_position(g.get_glow_bones()[0]) if e.rig else g.get_anchor_position()
			check(g.get_ring() != null and g.get_ring().global_position.distance_to(bone_pos) < 0.3,
				"the timing ring sits on the glowing limb (%.2f m from the bone)" % g.get_ring().global_position.distance_to(bone_pos))
			print("[ai] info: hook glow at %.2f m above the feet during the tell (HIGH reads as head height when A's pose raises the fist)" % (
				g.get_anchor_position().y - e.get_ground_position().y))
		else:
			check(not g.is_limb_glow() and g.mesh != null, "fallback: the star glint above the head is shown")
			check(g.global_position.y > e.get_aim_point().y + 0.3, "fallback star above the head")
			check(g.get_ring() != null, "the timing ring is kept")
		# The ring's meet point follows the time scale (Focus slows the world).
		var d := g.duration
		var meet1 := g.get_meet_time()
		Engine.time_scale = 0.3
		await get_tree().process_frame
		var meet2 := g.get_meet_time()
		Engine.time_scale = 1.0
		check(absf(meet1 - (d - Tuning.PERFECT_DODGE_WINDOW)) < 0.01 and absf(meet2 - (d - Tuning.PERFECT_DODGE_WINDOW * 0.3)) < 0.01,
			"ring meet point: %.3f s at 1x, %.3f s at 0.3x (tell %.2f)" % [meet1, meet2, d])
	_finish()

func _finish() -> void:
	Engine.time_scale = 1.0
	AttackDirector.reset()
	print("[ai] test_glow_tell: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
