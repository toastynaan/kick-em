extends Node3D
## Round 7 hit feel (docs/Round 7 — Freeflow Combat.md, Hit feel and Effects;
## acceptance row "effects on every Round 7 event, scaled by weight", owner F).
## Every player move of Tuning.R7_MOVES lands once with its own reaction,
## weight, push, stun and hitstop; its flash, sound layers, shock ring, jitter,
## screen flash and push dust spawn on the hit's physics frame, and:
## - a jab (0.2) against a roundhouse (0.85): flash size and brightness, sound
##   layers (crack only against crack + smack + thump), the crack's level, the
##   ring, the jitter;
## - the deep thump plays exactly from weight 0.6; the small screen flash
##   exactly from 0.7; dust and a skid trail exactly on pushes of 1 m or more,
##   the skid following the feet through the slide;
## - reactions add their touch on the react_started frame: fold = a grunt,
##   lift = an upward whoosh and a dust pop, buckle = a knee thud and dust,
##   spin = a whip; snap and push add nothing;
## - enemy hits, thrown bodies and bowled bodies keep the Round 5 tier effects;
## - the counter sound differs from every strike sound: no stream or sample
##   data in common with any strike contact or swing sound, and (measured)
##   brighter and ringing longer than every strike contact sound;
## - budgets hold under 20 Hz mashing: at most one shock ring and one screen
##   flash per Tuning.FX_RING_GAP / FX_FLASH_GAP, at most Tuning.BLOOD_DECAL_MAX
##   blood decals not fading. OWNER: agent F.

const U := preload("res://tests/fx/fx_test_util.gd")
const FreeflowFX := preload("res://scripts/fx/freeflow_fx.gd")

## Sounds a strike makes on contact (Round 5 and Round 7)...
const STRIKE_SOUNDS: Array[StringName] = [&"hit_crack", &"hit_smack", &"hit_thump", &"punch", &"kick",
	&"heavy_hit", &"hit_cross", &"hit_hook", &"hit_uppercut", &"hit_roundhouse", &"hit_flying_kick", &"hit_stomp",
	&"impact_flinch", &"impact_stumble", &"impact_stagger", &"impact_knockdown", &"impact_launch",
	&"impact_hard_launch", &"impact_sever", &"block", &"clank"]
## ...and on its swing.
const SWING_SOUNDS: Array[StringName] = [&"whoosh", &"whoosh_charged"]

var played: Array = []   ## [id, physics frame]

func _ready() -> void:
	var errlog := U.ErrorLogger.new()
	OS.add_logger(errlog)
	var fails: Array[String] = []
	BloodFX.reset()
	ScreenFX.reset()
	U.make_floor(self)
	if not await U.wait_audio(get_tree(), 240000, true):
		fails.append("AudioFX never finished synthesising")
	AudioFX.sound_played.connect(func(id: StringName, _p: Vector3) -> void: played.append([id, Engine.get_physics_frames()]))
	var player := U.make_fighter(self, Vector3(0, 0, 1.2))
	player.add_to_group(&"player")
	player.add_to_group(&"fighters")
	var victim := U.make_fighter(self, Vector3(0, 0, -0.2))
	victim.add_to_group(&"fighters")
	var ff: Node = BloodFX.get_freeflow_fx()
	var wfx: Node = BloodFX.get_world_fx()
	await U.physics_frames(get_tree(), 2)

	# --- Every move: same frame, scaled by weight ---------------------------------------
	var rows := {}
	print("move          w     flash m  bright  ring m  jitter s   layers (dB)                         screen  dust")
	for move: StringName in Tuning.R7_MOVES:
		await U.physics_frames(get_tree(), 36)  # past the 0.2 s ring and flash budgets and the last skid
		var row: Dictionary = Tuning.R7_MOVES[move]
		var h := _r7_hit(victim, player, move, row)
		played.clear()
		var frame := Engine.get_physics_frames()
		var scr0 := ScreenFX.flash_log.size()
		var ff0: int = ff.get(&"effect_log").size()
		GameEvents.hit_landed.emit(h)
		var c: Dictionary = BloodFX.contact_log.back()
		var snd: Dictionary = AudioFX.hit_sounds.back()
		var nodes: Array = BloodFX.last_impact_nodes()
		var r := {"w": float(row["weight"]), "frame": frame, "flash_frame": c["frame"], "snd_frame": snd["frame"],
			"flash": (nodes[0] as MeshInstance3D).scale.x, "bright": BloodFX.last_impact_brightness(),
			"ring": float(c.get("ring_size", 0.0)), "ring0": (nodes[1] as MeshInstance3D).scale.x if c["ring"] else 0.0,
			"jitter_t": BloodFX.jitter_left(victim),
			"layers": snd.get("layers", []), "db": snd.get("db", []),
			"screen": ScreenFX.flash_log.size() > scr0 and ScreenFX.flash_log.back()["frame"] == frame,
			"screen_alpha": ScreenFX.flash_log.back()["alpha"] if ScreenFX.flash_log.size() > scr0 else 0.0,
			"dust": _logged(ff, ff0, &"push_dust", frame), "played": played.duplicate()}
		await get_tree().process_frame  # resumes before BloodFX._process...
		await get_tree().process_frame  # ...which has now shaken the mesh once
		r["jitter"] = BloodFX.get_jitter(victim).length()
		rows[move] = r
		var lay: Array[String] = []
		for k in (r["layers"] as Array).size():
			lay.append("%s %+.1f" % [r["layers"][k], r["db"][k]])
		print("%-12s %.2f  %.2f     %.2f    %.2f    %.3f      %-36s %s %s  %s" % [move, r["w"], r["flash"], r["bright"],
			r["ring"], r["jitter_t"], ", ".join(lay), r["screen"], ("%.2f" % r["screen_alpha"]) if r["screen"] else "    ",
			r["dust"]])
		var w: float = r["w"]
		if r["flash_frame"] != frame or r["snd_frame"] != frame:
			fails.append("%s: flash frame %d, sound frame %d, hit frame %d" % [move, r["flash_frame"], r["snd_frame"], frame])
		for p: Array in r["played"]:
			if p[1] != frame:
				fails.append("%s: %s played on frame %d, hit frame %d" % [move, p[0], p[1], frame])
		var layers: Array = r["layers"]
		if layers.is_empty() or layers[0] != &"hit_crack":
			fails.append("%s: no crack layer (%s)" % [move, layers])
		if layers.has(&"hit_thump") != (w >= 0.6):
			fails.append("%s (w %.2f): thump %s" % [move, w, layers.has(&"hit_thump")])
		if layers.has(&"hit_smack") != (w >= AudioFX.R7_SMACK_FROM):
			fails.append("%s (w %.2f): smack %s" % [move, w, layers.has(&"hit_smack")])
		for id in layers:
			if not (r["played"] as Array).any(func(p: Array) -> bool: return p[0] == id):
				fails.append("%s: layer %s logged but not played" % [move, id])
		if r["screen"] != (w >= 0.7):
			fails.append("%s (w %.2f): screen flash %s" % [move, w, r["screen"]])
		if r["dust"] != (float(row["push"]) >= 1.0):
			fails.append("%s (push %.1f m): push dust %s" % [move, row["push"], r["dust"]])
		if (r["ring"] > 0.0) != (w >= BloodFX.R7_RING_FROM):
			fails.append("%s (w %.2f): ring %.2f" % [move, w, r["ring"]])
		if absf(float(r["jitter_t"]) - float(row["hitstop"])) > 0.001:
			fails.append("%s: jitter for %.3f s, hitstop %.3f" % [move, r["jitter_t"], row["hitstop"]])
	# Monotonic: a heavier move never flashes smaller or dimmer.
	var by_w: Array = rows.keys()
	by_w.sort_custom(func(a: StringName, b: StringName) -> bool: return rows[a]["w"] < rows[b]["w"])
	for k in range(1, by_w.size()):
		var a: Dictionary = rows[by_w[k - 1]]
		var b: Dictionary = rows[by_w[k]]
		if b["w"] > a["w"] and (b["flash"] < a["flash"] or b["bright"] < a["bright"]):
			fails.append("%s (w %.2f) flashes smaller than %s (w %.2f)" % [by_w[k], b["w"], by_w[k - 1], a["w"]])

	# --- Jab (0.2) against roundhouse (0.85) ------------------------------------------------
	var jab: Dictionary = rows[&"jab"]
	var rh: Dictionary = rows[&"roundhouse"]
	print("WEIGHT CHECK jab (w 0.20) vs roundhouse (w 0.85): flash %.2f m vs %.2f m (x%.2f), brightness %.2f vs %.2f, ring (full size) %.2f m vs %.2f m, jitter %.3f m vs %.3f m for %.2f s vs %.2f s; layers %s vs %s; crack %+.1f dB vs %+.1f dB" % [
		jab["flash"], rh["flash"], rh["flash"] / jab["flash"], jab["bright"], rh["bright"], jab["ring"], rh["ring"],
		jab["jitter"], rh["jitter"], jab["jitter_t"], rh["jitter_t"], jab["layers"], rh["layers"], jab["db"][0], rh["db"][0]])
	if rh["flash"] < jab["flash"] * 1.8 or rh["bright"] < jab["bright"] + 1.0:
		fails.append("roundhouse flash not clearly bigger than the jab's")
	if (jab["layers"] as Array) != [&"hit_crack"] or (rh["layers"] as Array) != [&"hit_crack", &"hit_smack", &"hit_thump"]:
		fails.append("layers: jab %s, roundhouse %s" % [jab["layers"], rh["layers"]])
	if float(rh["db"][0]) <= float(jab["db"][0]) or jab["ring"] != 0.0 or rh["ring"] < 1.5:
		fails.append("crack level / ring do not grow with weight")
	if float(rh["jitter"]) <= float(jab["jitter"]):
		fails.append("roundhouse jitter %.3f m not above the jab's %.3f m" % [rh["jitter"], jab["jitter"]])
	# What the layers are: the crack is short and bright, the thump long and low.
	var shape: Array[String] = []
	for id in [&"hit_crack", &"hit_smack", &"hit_thump"]:
		var buf: PackedFloat32Array = AudioFX.synthesize(id, 0)
		shape.append("%s %.2f s, low %.2f, bright %.2f" % [id, buf.size() / 44100.0, _band_share(buf, 200.0, false),
			_band_share(buf, 1500.0, true)])
	print("layer streams: %s" % "; ".join(shape))
	var crack_buf := AudioFX.synthesize(&"hit_crack", 0)
	var thump_buf := AudioFX.synthesize(&"hit_thump", 0)
	if _band_share(thump_buf, 200.0, false) < _band_share(crack_buf, 200.0, false) * 2.0 \
			or thump_buf.size() < crack_buf.size() * 3:
		fails.append("the thump is not the deep, long layer")

	# --- Push dust and the skid trail ----------------------------------------------------------
	await U.physics_frames(get_tree(), 40)
	var row_hc: Dictionary = Tuning.R7_MOVES[&"heavy_cross"]
	var hc := _r7_hit(victim, player, &"heavy_cross", row_hc)
	var slide: float = float(row_hc["stun"]) * Tuning.R7_PUSH_SLIDE_SHARE
	var puffs0: int = ff.get(&"counts").get(&"skid_puff", 0)
	var start := victim.global_position
	GameEvents.hit_landed.emit(hc)
	var first: int = ff.get(&"counts").get(&"skid_puff", 0) - puffs0
	var t0 := Time.get_ticks_msec()
	var far := 0.0
	var steps := int(slide * 120.0) + 12
	for i in steps:  # slide the victim back 1.8 m over the slide time
		if i < int(slide * 120.0):
			victim.global_position += Vector3(0, 0, -float(row_hc["push"]) / (slide * 120.0))
		await get_tree().physics_frame
		await get_tree().process_frame
		var foot := wfx.get(&"_foot")[(int(wfx.get(&"_foot_next")) + 9) % 10] as GPUParticles3D
		far = maxf(far, start.distance_to(foot.global_position))
	var puffs: int = ff.get(&"counts").get(&"skid_puff", 0) - puffs0
	print("PUSH CHECK heavy cross (push %.1f m, slide %.2f s): dust on the hit frame, skid puffs %d (first frame %d), last puff %.2f m from the start, skids left %d after %d ms" % [
		row_hc["push"], slide, puffs, first, far, ff.call(&"active_skids"), Time.get_ticks_msec() - t0])
	var want_puffs := int(slide / FreeflowFX.SKID_EVERY)
	if first != 1 or puffs < want_puffs - 1 or puffs > want_puffs + 2:
		fails.append("skid puffs %d over a %.2f s slide (first %d)" % [puffs, slide, first])
	if far < float(row_hc["push"]) * 0.7:
		fails.append("skid does not follow the feet (%.2f m)" % far)
	if int(ff.call(&"active_skids")) != 0:
		fails.append("skid outlived its slide")
	victim.global_position = Vector3(0, 0, -0.2)
	# Bigger pushes kick up more dust.
	var e_dust: Array[float] = []
	for m: StringName in [&"heavy_jab", &"front_kick"]:
		await U.physics_frames(get_tree(), 36)
		GameEvents.hit_landed.emit(_r7_hit(victim, player, m, Tuning.R7_MOVES[m]))
		e_dust.append(float((ff.get(&"effect_log") as Array).back()["size"]))
	print("push dust energy: heavy jab (1.4 m) %.0f, front kick (2.8 m) %.0f" % [e_dust[0], e_dust[1]])
	if e_dust[1] <= e_dust[0]:
		fails.append("a longer push does not kick up more dust")

	# --- Reactions --------------------------------------------------------------------------------
	var want := {&"fold": &"oof", &"lift": &"whoosh_up", &"buckle": &"knee_floor", &"spin": &"whip",
		&"snap": &"", &"push": &""}
	var react_log: Array[String] = []
	for kind: StringName in want:
		await U.physics_frames(get_tree(), 12)
		played.clear()
		var frame := Engine.get_physics_frames()
		var ff0: int = ff.get(&"effect_log").size()
		GameEvents.react_started.emit(victim, kind, player)
		var ids: Array = played.filter(func(p: Array) -> bool: return p[1] == frame).map(func(p: Array) -> StringName: return p[0])
		var dust_ev: StringName = StringName(String(kind) + "_dust")
		var dusted := _logged(ff, ff0, dust_ev, frame)
		react_log.append("%s -> %s%s" % [kind, ids, " + dust" if dusted else ""])
		if want[kind] == &"":
			if not ids.is_empty():
				fails.append("%s played %s (nothing wanted)" % [kind, ids])
		elif ids != [want[kind]]:
			fails.append("%s played %s, want %s on the event frame" % [kind, ids, want[kind]])
		if dusted != (kind == &"lift" or kind == &"buckle"):
			fails.append("%s dust %s" % [kind, dusted])
	print("REACTION CHECK (same frame): %s" % ", ".join(react_log))
	var oof := AudioFX.synthesize(&"oof", 0)
	print("oof: %.2f s, voiced band (300-1500 Hz) share %.2f" % [oof.size() / 44100.0,
		_band_share(oof, 300.0, true) - _band_share(oof, 1500.0, true)])

	# --- Everything else keeps the Round 5 tiers ----------------------------------------------------
	var enemy := victim
	for spec in [["enemy hook on the player", player, enemy, &"e_hook", &"strike", HitInfo.Tier.STAGGER],
			["thrown body", enemy, player, &"throw", &"throw", HitInfo.Tier.KNOCKDOWN],
			["bowled body", enemy, null, &"bowl", &"bowl", HitInfo.Tier.LAUNCH]]:
		await U.physics_frames(get_tree(), 36)
		var t: int = spec[5]
		var h := U.hit(spec[1], spec[3], (spec[1] as Node3D).global_position + Vector3.UP * 1.3, Vector3(0, 0, -1), 10.0,
				2000.0, spec[4], t)
		h.attacker = spec[2]
		var frame := Engine.get_physics_frames()
		GameEvents.hit_landed.emit(h)
		var c: Dictionary = BloodFX.contact_log.back()
		var snd: Dictionary = AudioFX.hit_sounds.back()
		var want_size := lerpf(BloodFX.IMPACT_FLASH_SIZE.x, BloodFX.IMPACT_FLASH_SIZE.y, BloodFX.TIER_FLASH[t])
		print("TIER CHECK %s (tier %s): sound %s, flash %.2f m (tier size %.2f), ring %s, weight path %s, frame ok %s" % [
			spec[0], HitInfo.tier_name(t), snd["id"], c["flash_size"], want_size, c["ring"], c["weight"] >= 0.0,
			c["frame"] == frame and snd["frame"] == frame])
		if snd["id"] != AudioFX.TIER_SOUND[t] or snd.has("layers") or c["weight"] >= 0.0 \
				or absf(float(c["flash_size"]) - want_size) > 0.001 or c["frame"] != frame:
			fails.append("%s left the tier rules" % spec[0])

	# --- The counter sound is unlike every strike sound --------------------------------------------
	var counter_streams: Array = AudioFX._streams[&"counter_hit"]
	var same := 0
	var strike_streams := 0
	for id in STRIKE_SOUNDS + SWING_SOUNDS:
		for st: AudioStreamWAV in AudioFX._streams[id]:
			strike_streams += 1
			for cs: AudioStreamWAV in counter_streams:
				if cs == st or cs.data == st.data:
					same += 1
	var cbuf := AudioFX.synthesize(&"counter_hit", 0)
	var c_ring := _bright_ring(cbuf)
	var c_bright := _band_share(cbuf, 1500.0, true)
	var worst_ring := 0.0
	var worst_id := &""
	var worst_bright := 0.0
	var table: Array[String] = []
	for id in STRIKE_SOUNDS + SWING_SOUNDS:
		var buf := AudioFX.synthesize(id, 0)
		var rt := _bright_ring(buf)
		var bs := _band_share(buf, 1500.0, true)
		table.append("%s %.2f s / %.2f" % [id, rt, bs])
		if id in SWING_SOUNDS:
			continue
		worst_bright = maxf(worst_bright, bs)
		if rt > worst_ring:
			worst_ring = rt
			worst_id = id
	print("COUNTER CHECK: %d counter variants x %d strike contact and swing streams compared, %d identical; counter: bright band (> 1.5 kHz) rings %.2f s, bright share %.2f; strike contact sounds at most %.2f s (%s) and %.2f" % [
		counter_streams.size(), strike_streams, same, c_ring, c_bright, worst_ring, worst_id, worst_bright])
	print("bright-band ring / bright share per strike sound (swings last, not compared): %s" % ", ".join(table))
	if counter_streams.is_empty() or same != 0:
		fails.append("the counter sound shares a stream with a strike")
	if c_ring < worst_ring * 1.5 or c_bright < worst_bright * 2.0:
		fails.append("the counter (%.2f s, %.2f) is not clearly brighter and longer than every strike (%.2f s, %.2f)" % [
			c_ring, c_bright, worst_ring, worst_bright])

	# --- Budgets under 20 Hz mashing -------------------------------------------------------------------
	await U.physics_frames(get_tree(), 40)
	var moves: Array = Tuning.R7_MOVES.keys()
	var rings: Array[float] = []
	var screens0 := ScreenFX.flash_log.size()
	var screen_frames: Array[int] = []
	var players_busy := 0
	for i in 60:
		var m: StringName = moves[i % moves.size()]
		var h := _r7_hit(victim, player, m, Tuning.R7_MOVES[m])
		GameEvents.hit_landed.emit(h)
		if BloodFX.contact_log.back()["ring"]:
			rings.append(Engine.get_physics_frames() / 120.0)
		var busy := 0
		for p: AudioStreamPlayer3D in AudioFX._players:
			if p.playing:
				busy += 1
		players_busy = maxi(players_busy, busy)
		await U.physics_frames(get_tree(), 6)  # 20 Hz
	for k in range(screens0, ScreenFX.flash_log.size()):
		screen_frames.append(ScreenFX.flash_log[k]["frame"])
	var ring_gap := _min_gap(rings)
	var flash_gap := _min_gap(screen_frames.map(func(f: int) -> float: return f / 120.0))
	await U.drain(get_tree())
	var dc := BloodFX.get_decal_counts()
	print("BUDGET CHECK 60 hits at 20 Hz: %d rings (closest %.2f s, budget %.2f), %d screen flashes (closest %.2f s, budget %.2f), blood decals %d live of %d created (cap %d), 3D voices busy at most %d of %d" % [
		rings.size(), ring_gap, Tuning.FX_RING_GAP, screen_frames.size(), flash_gap, Tuning.FX_FLASH_GAP, dc["blood"],
		dc["blood_created"], Tuning.BLOOD_DECAL_MAX, players_busy, AudioFX.POOL_3D])
	if ring_gap < Tuning.FX_RING_GAP - 0.001 or flash_gap < Tuning.FX_FLASH_GAP - 0.001:
		fails.append("ring / screen flash budget broken")
	if rings.is_empty() or screen_frames.is_empty():
		fails.append("no rings or flashes while mashing")
	if int(dc["blood"]) > Tuning.BLOOD_DECAL_MAX:
		fails.append("%d blood decals over the cap" % dc["blood"])
	if int(dc["blood_created"]) <= Tuning.BLOOD_DECAL_MAX:
		fails.append("the mash did not test the decal cap (%d created)" % dc["blood_created"])
	U.finish(get_tree(), "test_r7_hit_weight", fails, errlog)

## A Round 7 player hit as CombatController fills it from Tuning.R7_MOVES.
static func _r7_hit(victim: Node3D, attacker: Node3D, move: StringName, row: Dictionary) -> HitInfo:
	var tier := HitInfo.Tier.FLINCH
	for t: int in HitInfo.TIER_NAMES:
		if HitInfo.TIER_NAMES[t] == row["tier"]:
			tier = t
	var h := U.hit(victim, move, victim.global_position + Vector3(0, 1.35, 0.12), Vector3(0, 0, -1), float(row["dmg"]),
			0.0, &"strike", tier)
	h.attacker = attacker
	h.react = row["react"]
	h.weight = row["weight"]
	h.push = row["push"]
	h.stun = row["stun"]
	h.hitstop = row["hitstop"]
	h.chain_index = 1
	h.counter = move == &"counter"
	return h

## True when `event` was logged by FreeflowFX on `frame` after entry `from`.
static func _logged(ff: Node, from: int, event: StringName, frame: int) -> bool:
	var log: Array = ff.get(&"effect_log")
	for k in range(from, log.size()):
		if log[k]["event"] == event and log[k]["frame"] == frame:
			return true
	return false

static func _min_gap(times: Array) -> float:
	var g := INF
	for k in range(1, times.size()):
		g = minf(g, float(times[k]) - float(times[k - 1]))
	return g

## Share of the energy below (high = false) or above (high = true) `hz`
## (two cascaded one-poles).
static func _band_share(buf: PackedFloat32Array, hz: float, high: bool) -> float:
	var a := 1.0 - exp(-TAU * hz / 44100.0)
	var l1 := 0.0
	var l2 := 0.0
	var band := 0.0
	var total := 0.0
	for v in buf:
		l1 += a * (v - l1)
		l2 += a * (l1 - l2)
		var b := v - l2 if high else l2
		band += b * b
		total += v * v
	return band / maxf(total, 1e-9)

## Seconds the band above 1.5 kHz stays within 30 dB of its peak (how long
## the sound rings bright).
static func _bright_ring(buf: PackedFloat32Array) -> float:
	var a := 1.0 - exp(-TAU * 1500.0 / 44100.0)
	var r := exp(-1.0 / (44100.0 * 0.005))
	var l1 := 0.0
	var l2 := 0.0
	var env := 0.0
	var envs := PackedFloat32Array()
	envs.resize(buf.size())
	var peak := 0.0
	for k in buf.size():
		l1 += a * (buf[k] - l1)
		l2 += a * (l1 - l2)
		env = maxf(absf(buf[k] - l2), env * r)
		envs[k] = env
		peak = maxf(peak, env)
	var floor_v := peak * pow(10.0, -30.0 / 20.0)
	var last := 0
	for k in envs.size():
		if envs[k] > floor_v:
			last = k
	return last / 44100.0
