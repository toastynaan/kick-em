extends Node3D
## The charge glow (and its hum) never outlives its charge (lead review): it
## drops on charge_released at any level (B and G send level 0 on a cancel),
## on a hit landing on the charging fighter, when that fighter dies, flies,
## goes down or is grabbed, and after CHARGE_GLOW_MAX at the latest. A hit the
## charging fighter deals does not drop it. OWNER: agent F.

const U := preload("res://tests/fx/fx_test_util.gd")

func _ready() -> void:
	var errlog := U.ErrorLogger.new()
	OS.add_logger(errlog)
	var fails: Array[String] = []
	BloodFX.reset()
	U.make_floor(self)
	await U.wait_audio(get_tree())
	var p := U.make_fighter(self, Vector3(0, 0, 1.2))
	p.add_to_group(&"player")
	var e := U.make_fighter(self, Vector3(0, 0, -0.2))
	await U.physics_frames(get_tree(), 2)
	var chest := e.global_position + Vector3(0, 1.3, 0.1)

	var cases := {
		"cancel (charge_released level 0)": func() -> void: GameEvents.charge_released.emit(p, &"sparta_kick", 0),
		"hit on the charging fighter": func() -> void:
			var h := U.hit(p, &"e_jab", p.global_position + Vector3(0, 1.3, -0.1), Vector3(0, 0, 1), 10.0, 0.0,
					&"strike", HitInfo.Tier.FLINCH)
			h.attacker = e
			GameEvents.hit_landed.emit(h),
		"dies": func() -> void: GameEvents.fighter_died.emit(p, null),
		"launched": func() -> void: GameEvents.fighter_launched.emit(p, Vector3(0, 3, 8)),
		"grabbed": func() -> void: GameEvents.grab_started.emit(e, p),
		"held (carry)": func() -> void: GameEvents.carry_changed.emit(e, p),
		"goes down (polled)": func() -> void: p.set(&"down", true),
	}
	for name: String in cases:
		p.set(&"down", false)
		GameEvents.charge_started.emit(p, &"sparta_kick")
		GameEvents.charge_level_changed.emit(p, 1)
		await U.physics_frames(get_tree(), 6)
		var g := BloodFX.get_charge_glow(p)
		var had := g != null  # read now: a freed handle compares equal to null later
		var hum := AudioFX.active_hums()
		(cases[name] as Callable).call()
		await get_tree().create_timer(0.25).timeout
		var left := BloodFX.get_charge_glow(p)
		print("%-34s glow before %s, after %s (handle freed %s); hums %d -> %d" % [name, had, left != null,
			not is_instance_valid(g), hum, AudioFX.active_hums()])
		if not had or left != null or is_instance_valid(g):
			fails.append("%s: the charge glow stayed" % name)
		if AudioFX.active_hums() != 0:
			fails.append("%s: the hum stayed" % name)
		GameEvents.charge_released.emit(p, &"sparta_kick", 0)
	p.set(&"down", false)

	# The charging fighter's own hit does not drop its glow.
	GameEvents.charge_started.emit(p, &"sparta_kick")
	var own := U.hit(e, &"jab1", chest, Vector3(0, 0, -1), 4.0, 0.0, &"strike", HitInfo.Tier.FLINCH)
	own.attacker = p
	GameEvents.hit_landed.emit(own)
	await get_tree().create_timer(0.2).timeout
	if BloodFX.get_charge_glow(p) == null:
		fails.append("dealing a hit dropped the glow")

	# No release ever: gone after CHARGE_GLOW_MAX.
	var t0 := TimeDirector.now()
	while BloodFX.get_charge_glow(p) != null and TimeDirector.now() - t0 < 4.0:
		await get_tree().physics_frame
	var lived := TimeDirector.now() - t0 + 0.2
	print("glow with no release lived %.2f s (cap %.2f s)" % [lived, BloodFX.CHARGE_GLOW_MAX])
	if lived > BloodFX.CHARGE_GLOW_MAX + 0.3:
		fails.append("glow without a release lived %.2f s" % lived)
	U.finish(get_tree(), "test_charge_glow", fails, errlog)
