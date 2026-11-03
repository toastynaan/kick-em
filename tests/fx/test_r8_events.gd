extends Node3D
## Round 8 effects (docs/Round 8 — Charge and Pressure.md; acceptance row
## "effects on every Round 8 event", owner F). Checks:
## - every Round 8 event produces its effect and sound on its physics frame:
##   charge_started (limb glow, hum), charge_level_changed (a tick per step,
##   higher per step), charge_full (ping, flare), charge_released (a release
##   whoosh scaled by c that stands in for the strike's swing whoosh),
##   charge_cancelled (fizzle), a hit adding pressure (tick spark and sound,
##   landed or blocked), a charged hit (layers scaled by c, the charged crunch),
##   a broken-bonus hit (heavy accent), pressure_broken (break burst, shatter
##   rings, screen flash, guard break sound, dazed loop), pressure_recovered
##   (the loop stops), air_follow_started (whoosh, dust, blur), air_hit (pop
##   rising in pitch with the count, flash);
## - the charge glow (strength and heat) and the hum pitch are monotonic in c;
##   without a CombatController reporting the charge, c follows the doc's ramp;
## - taps play the quick crack alone (weight under the smack threshold);
## - the guard break sound differs from every strike sound (spectrum, envelope,
##   length: measured and logged);
## - the dazed loop starts on the break and stops on pressure_recovered, when
##   is_broken() goes false, on death, and by itself at the latest.
## OWNER: agent F.

const U := preload("res://tests/fx/fx_test_util.gd")
const ChargeFX := preload("res://scripts/fx/charge_fx.gd")

## Every sound that hits a body (the guard break must differ from all of them).
const STRIKE_SOUNDS: Array[StringName] = [&"punch", &"kick", &"heavy_hit", &"block", &"clank", &"hit_cross",
	&"hit_hook", &"hit_uppercut", &"hit_roundhouse", &"hit_flying_kick", &"hit_stomp", &"impact_flinch",
	&"impact_stumble", &"impact_stagger", &"impact_knockdown", &"impact_launch", &"impact_hard_launch",
	&"impact_sever", &"hit_crack", &"hit_smack", &"hit_thump", &"counter_hit", &"hit_charged", &"hit_broken",
	&"air_pop", &"body_slam", &"wall_slam"]

## The guard break's distance to its closest strike sound must exceed this many
## times the strike sounds' median distance to their own nearest neighbour.
const BREAK_APART := 3.0

var played: Array = []   ## [id, physics frame]
var fails: Array[String] = []

func _ready() -> void:
	var errlog := U.ErrorLogger.new()
	OS.add_logger(errlog)
	BloodFX.reset()
	ScreenFX.reset()
	U.make_floor(self)
	if not await U.wait_audio(get_tree()):
		fails.append("AudioFX never finished synthesising")
	AudioFX.sound_played.connect(func(id: StringName, _p: Vector3) -> void: played.append([id, Engine.get_physics_frames()]))
	var player := U.make_fighter(self, Vector3(0, 0, 1.5))
	player.add_to_group(&"player")
	player.add_to_group(&"fighters")
	var pc: Node = player.add_combat()
	var enemy := U.make_fighter(self, Vector3(0, 0, -0.5))
	enemy.add_to_group(&"fighters")
	var ec: Node = enemy.add_combat()
	var cfx: Node = BloodFX.get_charge_fx()
	await U.physics_frames(get_tree(), 2)

	await _check_charge(player, enemy, pc, cfx)
	await _check_hits(player, enemy, ec, cfx)
	await _check_break(player, enemy, ec, cfx)
	_check_break_sound()
	await _check_air(player, enemy, cfx)
	U.finish(get_tree(), "test_r8_events", fails, errlog)


# =============================================================================
# Charge
# =============================================================================

func _check_charge(player: Node3D, enemy: Node3D, pc: Node, cfx: Node) -> void:
	await U.physics_frames(get_tree(), 6)
	played.clear()
	var f := Engine.get_physics_frames()
	GameEvents.charge_started.emit(player, &"cross")
	var g := BloodFX.get_charge_glow(player)
	_on_frame("charge_started", f, [&"charge_hum"], cfx, [&"charge_glow"])
	if g == null or AudioFX.active_hums() != 1:
		fails.append("charge_started: glow %s, hums %d" % [g != null, AudioFX.active_hums()])
		return
	print("charge glow on %s" % g.get(&"bone"))

	# Glow and hum follow c (the CombatController reports it).
	pc.charging = true
	var cs: Array[float] = []
	var glow: Array[float] = []
	var heat: Array[float] = []
	var hum: Array[float] = []
	var hum_c: Array[float] = []
	var hum_err := 0.0
	for k in 11:
		pc.charge = k / 10.0
		await U.physics_frames(get_tree(), 3)
		cs.append(pc.charge)
		glow.append(float(g.get(&"intensity")))
		var col: Color = g.get(&"color")
		heat.append(1.0 - col.b)
		var hc: float = AudioFX.hum_charge(player)
		hum_c.append(hc)
		hum.append(AudioFX.hum_pitch_for(hc))
		hum_err = maxf(hum_err, absf(AudioFX.hum_pitch(player) - AudioFX.hum_pitch_for(hc)) / AudioFX.hum_pitch_for(hc))
	print("GLOW BY c: %s" % _pairs(cs, glow))
	print("glow heat (1 - blue) by c: %s" % _pairs(cs, heat))
	print("HUM PITCH BY c: %s (hum's c %s; live pitch within %.1f%% of it, the wobble)" % [_pairs(cs, hum),
		_fmt(hum_c), hum_err * 100.0])
	for k in range(1, cs.size()):
		if glow[k] <= glow[k - 1]:
			fails.append("glow not rising at c %.1f (%.3f <= %.3f)" % [cs[k], glow[k], glow[k - 1]])
		if heat[k] < heat[k - 1] - 1e-4:
			fails.append("glow cooled at c %.1f" % cs[k])
		if hum[k] <= hum[k - 1]:
			fails.append("hum pitch not rising at c %.1f" % cs[k])
	if absf(hum_c.back() - 1.0) > 1e-3 or hum_err > 0.03:
		fails.append("hum does not follow c (c %.2f, error %.3f)" % [hum_c.back(), hum_err])
	for k in 101:  # the static mapping, finer
		var a := ChargeFX.charge_glow_intensity(k / 100.0)
		var b := ChargeFX.charge_glow_intensity((k + 1) / 100.0)
		if k < 100 and b <= a:
			fails.append("charge_glow_intensity not strictly rising at %.2f" % (k / 100.0))
			break

	# Steps: a tick per step, higher per step.
	pc.charge = 0.5
	var pitches: Array[float] = []
	for lvl in [1, 2]:
		await U.physics_frames(get_tree(), 4)
		played.clear()
		f = Engine.get_physics_frames()
		GameEvents.charge_level_changed.emit(player, lvl)
		_on_frame("charge_level_changed %d" % lvl, f, [&"charge_tick"], cfx, [&"charge_step"])
		pitches.append(float((AudioFX.round8_sounds.back()["pitch"] as Array)[0]))
	print("step ticks: pitch %s, tick length %.3f s" % [_fmt(pitches), AudioFX.generate(&"charge_tick", 0).get_length()])
	if pitches.size() < 2 or pitches[1] <= pitches[0]:
		fails.append("the second step's tick is not higher")
	if AudioFX.generate(&"charge_tick", 0).get_length() > 0.12:
		fails.append("the step tick is not short")

	# Full: ping and flare.
	await U.physics_frames(get_tree(), 4)
	played.clear()
	f = Engine.get_physics_frames()
	GameEvents.charge_full.emit(player, &"cross")
	_on_frame("charge_full", f, [&"charge_full"], cfx, [&"charge_full"])
	pc.charge = 1.0
	var full_glow := 0.0
	for i in 16:  # over a throb
		await get_tree().process_frame
		full_glow = maxf(full_glow, float(g.get(&"intensity")))
	print("glow at full: peaks %.2f (c = 1 gives %.2f), hum pitch %.2f" % [full_glow, ChargeFX.charge_glow_intensity(1.0),
		AudioFX.hum_pitch(player)])
	if full_glow < ChargeFX.CHARGE_GLOW_FULL * (1.0 + ChargeFX.FULL_THROB) * 0.9:
		fails.append("no flare at full (%.2f)" % full_glow)

	# Release at full: the whoosh (with the long charged layer) on its frame;
	# the released strike's swing whoosh stands down; the glow and hum go.
	await U.physics_frames(get_tree(), 4)
	played.clear()
	f = Engine.get_physics_frames()
	GameEvents.charge_released.emit(player, &"cross", 2)
	_on_frame("charge_released", f, [&"charge_release", &"whoosh_charged"], cfx, [&"charge_release"])
	var db_full := float((AudioFX.round8_sounds.back()["db"] as Array)[0])
	pc.charging = false
	await U.physics_frames(get_tree(), 30)  # the glide
	GameEvents.strike_started.emit(player, enemy, &"heavy_cross", false, 1)
	GameEvents.attack_active.emit(player, &"heavy_cross")
	var swings := _ids().filter(func(id: StringName) -> bool: return id == &"whoosh" or id == &"whoosh_charged")
	await get_tree().create_timer(0.2).timeout
	print("after a full release: %s; glow left %s, hums %d" % [_ids(), BloodFX.get_charge_glow(player) != null,
		AudioFX.active_hums()])
	if swings.size() != 1:
		fails.append("the released strike whooshed again: %s" % [_ids()])
	if BloodFX.get_charge_glow(player) != null or AudioFX.active_hums() != 0:
		fails.append("glow or hum outlived the release")

	# Release at a low c: quieter, no long layer.
	GameEvents.charge_started.emit(player, &"cross")
	pc.charging = true
	pc.charge = 0.2
	await U.physics_frames(get_tree(), 4)
	played.clear()
	GameEvents.charge_released.emit(player, &"cross", 0)
	var low: Dictionary = AudioFX.round8_sounds.back()
	print("RELEASE WHOOSH: c %.2f -> %s at %s dB; c 1.00 -> %.1f dB (+ whoosh_charged)" % [low["c"], low["ids"],
		_fmt(low["db"]), db_full])
	if (low["ids"] as Array).has(&"whoosh_charged") or float((low["db"] as Array)[0]) >= db_full:
		fails.append("the release whoosh does not scale with c")
	pc.charging = false

	# Cancel: the fizzle.
	GameEvents.charge_started.emit(player, &"front_kick")
	await U.physics_frames(get_tree(), 6)
	played.clear()
	f = Engine.get_physics_frames()
	GameEvents.charge_cancelled.emit(player, &"front_kick", &"hit")
	_on_frame("charge_cancelled", f, [&"charge_fizzle"], cfx, [&"charge_fizzle"])
	await get_tree().create_timer(0.2).timeout
	if BloodFX.get_charge_glow(player) != null or AudioFX.active_hums() != 0:
		fails.append("glow or hum outlived the cancel")

	# No CombatController report: c follows the doc's ramp from charge_started.
	GameEvents.charge_started.emit(player, &"jab")
	var ramp_t := 0.5 * (Tuning.debug_charge_full - Tuning.R8_TAP_MAX)
	await U.physics_frames(get_tree(), int(ramp_t * Engine.physics_ticks_per_second))
	await get_tree().process_frame
	var cr: float = cfx.call(&"get_glow_charge", player)
	print("ramp fallback: %.3f s after charge_started glow c %.2f, hum c %.2f (want 0.50)" % [ramp_t, cr,
		AudioFX.hum_charge(player)])
	if absf(cr - 0.5) > 0.05 or absf(AudioFX.hum_charge(player) - 0.5) > 0.05:
		fails.append("ramp fallback c %.2f / %.2f" % [cr, AudioFX.hum_charge(player)])
	GameEvents.charge_released.emit(player, &"jab", 0)


# =============================================================================
# Hits
# =============================================================================

func _check_hits(player: Node3D, enemy: Node3D, ec: Node, cfx: Node) -> void:
	# Taps: the quick crack alone (weight under the smack layer).
	var crack_len := float(_features(AudioFX.synthesize(&"hit_crack", 0))["len"])  # audible length
	var rows: Array[String] = []
	for move: StringName in Tuning.R8_MOVES:
		var tap: Dictionary = Tuning.R8_MOVES[move]["tap"]
		var h := _r8_hit(player, enemy, move, tap["react"], float(tap["weight"]))
		var ids: Array = AudioFX.hit_layers(h).map(func(l: Array) -> StringName: return l[0])
		rows.append("%s %.2f %s" % [move, h.weight, ids])
		if h.weight < AudioFX.R7_SMACK_FROM and ids != [&"hit_crack"]:
			fails.append("tap %s plays %s, want the crack alone" % [move, ids])
	var smack_len := float(_features(AudioFX.synthesize(&"hit_smack", 0))["len"])
	var thump_len := float(_features(AudioFX.synthesize(&"hit_thump", 0))["len"])
	print("TAP LAYERS: %s (audible length to -34 dB: crack %.3f s, smack %.3f s, thump %.3f s)" % [", ".join(rows),
		crack_len, smack_len, thump_len])
	if crack_len > 0.15 or crack_len > 0.6 * smack_len:
		fails.append("the crack is not quick (%.3f s)" % crack_len)

	# A tap that adds pressure: the crack and the tick on its frame; the tick rises with the meter.
	var tick_pitch: Array[float] = []
	for p in [0.0, 0.8]:
		ec.pressure_fraction = p
		await U.physics_frames(get_tree(), 6)
		played.clear()
		var f := Engine.get_physics_frames()
		var tap := _r8_hit(player, enemy, &"jab", &"flinch", 0.2)
		tap.pressure = 1.0
		GameEvents.hit_landed.emit(tap)
		_on_frame("tap with pressure (p %.1f)" % p, f, [&"hit_crack", &"pressure_tick"], cfx, [&"pressure_tick"])
		tick_pitch.append(float((AudioFX.round8_sounds.back()["pitch"] as Array)[0]))
	ec.pressure_fraction = 0.0
	print("pressure tick pitch at p 0 / 0.8: %s" % _fmt(tick_pitch))
	if tick_pitch[1] <= tick_pitch[0]:
		fails.append("the pressure tick does not rise with the meter")
	# A blocked hit adds pressure too.
	await U.physics_frames(get_tree(), 6)
	played.clear()
	var fb := Engine.get_physics_frames()
	var blk := _r8_hit(player, enemy, &"cross", &"flinch", 0.25)
	blk.pressure = 1.0
	blk.result = HitInfo.Result.BLOCKED
	GameEvents.hit_blocked.emit(blk)
	_on_frame("blocked hit with pressure", fb, [&"block", &"pressure_tick"], cfx, [&"pressure_tick"])

	# Charged hits scale with c on top of the weight.
	var by_c := {}
	for c in [0.0, 1.0]:
		var w := lerpf(0.55, 0.85, c)
		var h := _r8_hit(player, enemy, &"heavy_cross", &"push", w)
		h.charged = true
		h.charge = c
		var plain := _r8_hit(player, enemy, &"heavy_cross", &"push", w)
		var lay: Array = AudioFX.hit_layers(h)
		var crack_db := float(lay[0][1]) - float(AudioFX.hit_layers(plain)[0][1])
		var charged_db := -99.0
		for l: Array in lay:
			if l[0] == &"hit_charged":
				charged_db = l[1]
		by_c[c] = [crack_db, charged_db]
	print("CHARGED HIT: c 0 -> layers +%.1f dB over the weight, charged crunch %.1f dB; c 1 -> +%.1f dB, crunch %.1f dB" % [
		by_c[0.0][0], by_c[0.0][1], by_c[1.0][0], by_c[1.0][1]])
	if by_c[0.0][1] < -90.0 or by_c[1.0][1] <= by_c[0.0][1] or by_c[1.0][0] <= by_c[0.0][0]:
		fails.append("charged hits do not scale with c")
	await U.physics_frames(get_tree(), 6)
	played.clear()
	var fc := Engine.get_physics_frames()
	var ch := _r8_hit(player, enemy, &"heavy_cross", &"push", 0.85)
	ch.charged = true
	ch.charge = 1.0
	GameEvents.hit_landed.emit(ch)
	_on_frame("charged hit", fc, [&"hit_crack", &"hit_smack", &"hit_thump", &"hit_charged"], cfx, [&"charged_hit"])

	# A hit on a broken enemy: the heavy accent.
	await U.physics_frames(get_tree(), 6)
	played.clear()
	var fbr := Engine.get_physics_frames()
	var bh := _r8_hit(player, enemy, &"jab", &"flinch", 0.2)
	bh.broken_bonus = true
	GameEvents.hit_landed.emit(bh)
	_on_frame("broken-bonus hit", fbr, [&"hit_crack", &"hit_broken"], cfx, [&"broken_hit"])

## A Round 8 player hit on `victim` (react and weight as B fills them).
func _r8_hit(attacker: Node3D, victim: Node3D, move: StringName, react: StringName, weight: float) -> HitInfo:
	var h := U.hit(victim, move, victim.global_position + Vector3(0, 1.3, 0.1), Vector3(0, 0, -1), 6.0, 0.0,
			&"strike", HitInfo.Tier.FLINCH)
	h.attacker = attacker
	h.react = react
	h.weight = weight
	return h


# =============================================================================
# The break and the dazed loop
# =============================================================================

func _check_break(player: Node3D, enemy: Node3D, ec: Node, cfx: Node) -> void:
	await U.physics_frames(get_tree(), 6)
	played.clear()
	ec.broken = true
	var flashes := ScreenFX.flash_log.size()
	var f := Engine.get_physics_frames()
	GameEvents.pressure_broken.emit(enemy, player)
	_on_frame("pressure_broken", f, [&"guard_break", &"dazed"], cfx, [&"break_burst", &"daze_start"])
	var lb: Dictionary = cfx.get(&"last_break")
	var ring: MeshInstance3D = cfx.call(&"last_ring_node")
	var screen_ok: bool = ScreenFX.flash_log.size() > flashes and int(ScreenFX.flash_log.back()["frame"]) == f
	print("BREAK BURST: frame %d at %s (chest %s), shatter rings %d, outer ring %.2f m, screen flash %s, glass %d" % [
		int(lb.get("frame", -1)), lb.get("position"), FXRules.upper_body(enemy), int(cfx.call(&"active_break_rings")),
		ring.scale.x, screen_ok, int(BloodFX.get_world_fx().counts.get(&"glass", 0))])
	if int(cfx.call(&"active_break_rings")) < 1 or not screen_ok:
		fails.append("break burst incomplete (rings %d, screen flash %s)" % [int(cfx.call(&"active_break_rings")), screen_ok])
	await get_tree().create_timer(0.2).timeout
	if ring.scale.x < 1.5:
		fails.append("the shatter ring did not expand (%.2f m)" % ring.scale.x)
	await get_tree().create_timer(0.5).timeout
	var node: Node3D = cfx.call(&"get_daze_node", enemy)
	var above := node.global_position.y - FXRules.head_of(enemy).y if node != null else -1.0
	print("DAZED LOOP 0.7 s into the break: visual %s (%.2f m above the head), sound %s" % [cfx.call(&"is_dazed", enemy),
		above, AudioFX.is_dazed_playing(enemy)])
	if not cfx.call(&"is_dazed", enemy) or not AudioFX.is_dazed_playing(enemy) or above <= 0.0:
		fails.append("dazed loop missing while broken")
	ec.broken = false
	played.clear()
	f = Engine.get_physics_frames()
	GameEvents.pressure_recovered.emit(enemy)
	_on_frame("pressure_recovered", f, [], cfx, [&"daze_stop"])
	await get_tree().create_timer(0.4).timeout
	print("after pressure_recovered: visual %d, sound %d" % [cfx.call(&"active_dazes"), AudioFX.active_dazed()])
	if int(cfx.call(&"active_dazes")) != 0 or AudioFX.active_dazed() != 0:
		fails.append("dazed loop outlived pressure_recovered")

	# is_broken() going false (after it was seen true) ends it without the event.
	ec.broken = true
	GameEvents.pressure_broken.emit(enemy, player)
	await U.physics_frames(get_tree(), 12)
	ec.broken = false
	await get_tree().create_timer(0.4).timeout
	if int(cfx.call(&"active_dazes")) != 0 or AudioFX.active_dazed() != 0:
		fails.append("dazed loop outlived is_broken()")
	# Death ends it at once.
	ec.broken = true
	GameEvents.pressure_broken.emit(enemy, player)
	await U.physics_frames(get_tree(), 6)
	GameEvents.fighter_died.emit(enemy, null)
	await U.physics_frames(get_tree(), 2)
	if int(cfx.call(&"active_dazes")) != 0 or AudioFX.active_dazed() != 0:
		fails.append("dazed loop outlived death")
	# No report and no event: it stops by itself after R8_BREAK_TIME + slack.
	ec.broken = false
	GameEvents.pressure_broken.emit(enemy, player)
	await get_tree().create_timer(Tuning.R8_BREAK_TIME - 0.1).timeout
	var mid: bool = cfx.call(&"is_dazed", enemy) and AudioFX.is_dazed_playing(enemy)
	await get_tree().create_timer(ChargeFX.DAZE_SLACK + 0.6).timeout
	print("orphan dazed loop: on at %.1f s %s, off by %.1f s %s" % [Tuning.R8_BREAK_TIME - 0.1, mid,
		Tuning.R8_BREAK_TIME + ChargeFX.DAZE_SLACK + 0.5, int(cfx.call(&"active_dazes")) == 0 and AudioFX.active_dazed() == 0])
	if not mid or int(cfx.call(&"active_dazes")) != 0 or AudioFX.active_dazed() != 0:
		fails.append("orphan dazed loop wrong (on mid-break %s)" % mid)

## The guard break against every strike sound: spectrum (5 bands), envelope
## (12 x 0.1 s) and length, as one distance; logged with the closest strike.
func _check_break_sound() -> void:
	var br := _features(AudioFX.synthesize(&"guard_break", 0))
	var strikes := {}
	for id in STRIKE_SOUNDS:
		strikes[id] = _features(AudioFX.synthesize(id, 0))
	var closest := &""
	var dmin := INF
	var longest := 0.0
	for id: StringName in strikes:
		var d := _distance(br, strikes[id])
		longest = maxf(longest, float(strikes[id]["len"]))
		if d < dmin:
			dmin = d
			closest = id
	# For scale: how far apart the strike sounds are from their nearest neighbour.
	var nn: Array[float] = []
	for a: StringName in strikes:
		var m := INF
		for b: StringName in strikes:
			if a != b:
				m = minf(m, _distance(strikes[a], strikes[b]))
		nn.append(m)
	nn.sort()
	var nn_max: float = nn.back()
	print("BREAK SOUND: %.2f s, bands %s; strike sounds %d, longest %.2f s; closest strike %s at distance %.2f (strikes' nearest-neighbour distance: median %.2f, max %.2f)" % [
		br["len"], _fmt(Array(br["bands"])), strikes.size(), longest, closest, dmin, nn[int(nn.size() / 2.0)], nn_max])
	var nn_med: float = nn[int(nn.size() / 2.0)]
	if dmin <= BREAK_APART * nn_med:
		fails.append("the guard break is too close to %s (%.2f, want over %.0fx the strikes' median %.2f)" % [closest,
			dmin, BREAK_APART, nn_med])
	if float(br["len"]) <= longest:
		fails.append("the guard break is not longer than every strike sound")

static func _features(buf: PackedFloat32Array) -> Dictionary:
	var sr := 44100.0
	var peak := 0.0
	for v in buf:
		peak = maxf(peak, absf(v))
	var last := 0
	for i in buf.size():
		if absf(buf[i]) > peak * 0.02:
			last = i
	var cuts: Array[float] = [200.0, 600.0, 1500.0, 4000.0]
	var lp := PackedFloat32Array()
	lp.resize(cuts.size())
	var coef: Array[float] = []
	for c in cuts:
		coef.append(1.0 - exp(-TAU * c / sr))
	var bands := PackedFloat32Array()
	bands.resize(cuts.size() + 1)
	var env := PackedFloat32Array()
	env.resize(12)
	var total := 0.0
	for i in buf.size():
		var v := buf[i]
		var prev := 0.0
		for k in cuts.size():
			lp[k] += coef[k] * (v - lp[k])
			var band := lp[k] - prev
			bands[k] += band * band
			prev = lp[k]
		var hi := v - prev
		bands[cuts.size()] += hi * hi
		var w := int(i / (sr * 0.1))
		if w < 12:
			env[w] += v * v
		total += v * v
	var bsum := 0.0
	for b in bands:
		bsum += b
	for k in bands.size():
		bands[k] /= maxf(bsum, 1e-9)
	for k in env.size():
		env[k] /= maxf(total, 1e-9)
	return {"len": last / sr, "bands": bands, "env": env}

static func _distance(a: Dictionary, b: Dictionary) -> float:
	var d := absf(float(a["len"]) - float(b["len"]))
	for k in (a["bands"] as PackedFloat32Array).size():
		d += absf(a["bands"][k] - b["bands"][k])
	for k in (a["env"] as PackedFloat32Array).size():
		d += absf(a["env"][k] - b["env"][k])
	return d


# =============================================================================
# Air combo
# =============================================================================

func _check_air(player: Node3D, enemy: Node3D, cfx: Node) -> void:
	await U.physics_frames(get_tree(), 6)
	played.clear()
	var f := Engine.get_physics_frames()
	GameEvents.air_follow_started.emit(player, enemy)
	_on_frame("air_follow_started", f, [&"whoosh_up", &"rush"], cfx, [&"air_follow"])
	await get_tree().process_frame  # process_frame fires before the nodes' _process: wait two
	await get_tree().process_frame
	print("air follow: speed level %.2f" % ScreenFX.get_speed_level())
	if ScreenFX.get_speed_level() < 0.3:
		fails.append("no speed blur pulse on the launcher jump")
	var pitches: Array[float] = []
	for count in range(1, Tuning.debug_air_hits + 2):
		await U.physics_frames(get_tree(), 10)
		played.clear()
		f = Engine.get_physics_frames()
		GameEvents.air_hit.emit(player, enemy, count)
		_on_frame("air_hit %d" % count, f, [&"air_pop"], cfx, [&"air_hit"])
		pitches.append(float((AudioFX.round8_sounds.back()["pitch"] as Array)[0]))
	print("AIR POP PITCH by count 1..%d: %s" % [pitches.size(), _fmt(pitches)])
	for k in range(1, pitches.size()):
		if pitches[k] <= pitches[k - 1]:
			fails.append("air pop pitch not rising at count %d" % (k + 1))


# =============================================================================
# Helpers
# =============================================================================

## Every sound in `ids` played on physics frame `f`, and ChargeFX logged every
## effect in `effects` on it.
func _on_frame(what: String, f: int, ids: Array, cfx: Node, effects: Array) -> void:
	var missing: Array = []
	for id in ids:
		var ok := false
		for p in played:
			if p[0] == id and int(p[1]) == f:
				ok = true
		if not ok:
			missing.append(id)
	var elog: Array = cfx.get(&"effect_log")
	for e in effects:
		var ok := false
		for rec: Dictionary in elog:
			if rec["event"] == e and int(rec["frame"]) == f:
				ok = true
		if not ok:
			missing.append(e)
	print("%-28s frame %d: sounds %s, effects %s%s" % [what, f, ids, effects,
		"" if missing.is_empty() else "  MISSING %s" % [missing]])
	if not missing.is_empty():
		fails.append("%s: %s not on the event's frame" % [what, missing])

func _ids() -> Array:
	return played.map(func(p: Array) -> StringName: return p[0])

static func _fmt(a: Array) -> String:
	return "[%s]" % ", ".join(a.map(func(v) -> String: return "%.2f" % float(v)))

static func _pairs(cs: Array, vs: Array) -> String:
	var out: Array[String] = []
	for k in cs.size():
		out.append("%.1f:%.2f" % [cs[k], vs[k]])
	return " ".join(out)
