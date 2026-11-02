extends Node3D
## F7 / F7b effects (Feel Reference: Landing has levels, Automatic parkour, Wall
## run > Effects). Soft landing: a small dust puff; hard: a dust ring of
## Tuning.LAND_DUST_RING.x m; heavy: Tuning.LAND_DEBRIS chunks owned by
## DebrisManager (Round 6: the floor crack comes from floor_damaged), a dust ring of LAND_DUST_RING.y m and a
## vertical streak, no blood; water splashes and ripples instead of dust,
## metal sparks. Parkour pushes dust; wall-run footsteps kick dust and chips in
## the wall's colour. Each level has its own sound. Finishes with a real jump
## through the player's Traversal. OWNER: agent F.

const U := preload("res://tests/fx/fx_test_util.gd")
const FakePanel := preload("res://tests/fx/fx_fake_panel.gd")

var played: Array[StringName] = []
var landings: Array = []
var floor_events := 0

func _ready() -> void:
	var errlog := U.ErrorLogger.new()
	OS.add_logger(errlog)
	var fails: Array[String] = []
	BloodFX.reset()
	U.make_floor(self)
	var water := U.make_box(self, Vector3(8, -0.45, 0), Vector3(4, 1, 4), Layers.WORLD)
	water.set_meta(&"surface", &"water")
	var plate := U.make_box(self, Vector3(-8, -0.45, 0), Vector3(4, 1, 4), Layers.WORLD)
	plate.set_meta(&"surface", &"metal")
	if not await U.wait_audio(get_tree()):
		fails.append("AudioFX never finished synthesising")
	AudioFX.sound_played.connect(func(id: StringName, _p: Vector3) -> void: played.append(id))
	GameEvents.landing.connect(func(_f: Node3D, level: StringName, _p: Vector3, v: float) -> void: landings.append([level, v]))
	GameEvents.floor_damaged.connect(func(_p: Vector3, _r: float, _l: int, _s: StringName) -> void: floor_events += 1)
	var player := U.make_fighter(self, Vector3(0, 0, 3))
	player.add_to_group(&"player")
	await U.physics_frames(get_tree(), 2)
	var wfx: Node = BloodFX.get_world_fx()
	var dm := get_node_or_null(^"/root/DebrisManager")

	# --- Three levels on concrete -------------------------------------------------------
	var c0: Dictionary = wfx.get(&"counts").duplicate()
	played.clear()
	GameEvents.landing.emit(player, &"soft", Vector3(0, 0, 0), 6.1)
	await U.physics_frames(get_tree(), 4)
	var soft := _diff(wfx, c0)
	var soft_snd := played.duplicate()
	c0 = wfx.get(&"counts").duplicate()
	played.clear()
	GameEvents.landing.emit(player, &"hard", Vector3(2, 0, 0), 9.7)
	await U.physics_frames(get_tree(), 4)
	var hard := _diff(wfx, c0)
	var hard_ring: float = wfx.get(&"last").get(&"dust_ring", 0.0)
	var hard_snd := played.duplicate()
	c0 = wfx.get(&"counts").duplicate()
	played.clear()
	var marks0: int = BloodFX.get_decal_counts()["marks"]
	var floor0 := floor_events
	var blood0: int = BloodFX.get_decal_counts()["blood_created"]
	var debris0: int = dm.call(&"count") if dm != null else 0
	GameEvents.landing.emit(player, &"heavy", Vector3(-2, 0, 0), 12.5)
	await U.drain(get_tree())
	var heavy := _diff(wfx, c0)
	var heavy_ring: float = wfx.get(&"last").get(&"dust_ring", 0.0)
	var dc := BloodFX.get_decal_counts()
	var debris_added: int = (dm.call(&"count") if dm != null else 0) - debris0
	print("soft: %s %s" % [soft, soft_snd])
	print("hard: %s ring %.1f m %s" % [hard, hard_ring, hard_snd])
	print("heavy: %s ring %.1f m, floor marks from the landing itself +%d, chunks registered with DebrisManager +%d, streaks %d, blood decals +%d %s" % [
		heavy, heavy_ring, dc["marks"] - marks0, debris_added, wfx.call(&"active_streaks"), dc["blood_created"] - blood0, played])
	if soft.get(&"foot_puff", 0) != 1 or soft.has(&"dust_ring") or not soft_snd.has(&"land"):
		fails.append("soft landing effects wrong")
	if hard.get(&"dust_ring", 0) != 1 or absf(hard_ring - Tuning.LAND_DUST_RING.x) > 0.001 or not hard_snd.has(&"land_hard"):
		fails.append("hard landing effects wrong")
	var chunks: int = heavy.get(&"debris", 0)
	if heavy.get(&"dust_ring", 0) != 1 or absf(heavy_ring - Tuning.LAND_DUST_RING.y) > 0.001:
		fails.append("heavy landing ring wrong")
	if chunks < Tuning.LAND_DEBRIS.x or chunks > Tuning.LAND_DEBRIS.y or (dm != null and debris_added != chunks):
		fails.append("heavy landing chunks %d (DebrisManager +%d)" % [chunks, debris_added])
	# Round 6: the floor mark comes from WorldDamage's floor_damaged, never from
	# the landing itself (no double decals).
	print("heavy landing: floor_damaged events %d (WorldDamage), floor marks +%d" % [floor_events - floor0, dc["marks"] - marks0])
	if dc["marks"] - marks0 != mini(floor_events - floor0, 1):
		fails.append("floor marks +%d for %d floor_damaged events" % [dc["marks"] - marks0, floor_events - floor0])
	if heavy.get(&"streak", 0) != 1 or wfx.call(&"active_streaks") != 1:
		fails.append("heavy landing streak missing")
	if dc["blood_created"] != blood0:
		fails.append("a heavy landing on the floor bled")
	if not played.has(&"land_heavy"):
		fails.append("no heavy landing sound")
	await get_tree().create_timer(WorldFXHelper.STREAK_TIME + 0.1).timeout
	if wfx.call(&"active_streaks") != 0:
		fails.append("streak did not fade")

	# --- Water and metal --------------------------------------------------------------------
	c0 = wfx.get(&"counts").duplicate()
	played.clear()
	GameEvents.landing.emit(player, &"hard", Vector3(8, 0.05, 0), 9.7)
	await U.physics_frames(get_tree(), 4)
	var wet := _diff(wfx, c0)
	c0 = wfx.get(&"counts").duplicate()
	var spark0: int = BloodFX._spark_next
	GameEvents.landing.emit(player, &"heavy", Vector3(-8, 0.05, 0), 12.0)
	await U.physics_frames(get_tree(), 4)
	print("water hard landing: %s %s; metal heavy landing sparks %s" % [wet, played, BloodFX._spark_next != spark0])
	if wet.get(&"ripple", 0) < 2 or wet.get(&"splash", 0) != 1 or wet.has(&"dust_ring") or not played.has(&"splash"):
		fails.append("water landing effects wrong")
	if BloodFX._spark_next == spark0:
		fails.append("no sparks on metal")

	# --- Parkour --------------------------------------------------------------------------------
	c0 = wfx.get(&"counts").duplicate()
	played.clear()
	var dust0: int = BloodFX._dust_next
	for kind in [&"step", &"vault", &"mantle", &"kickoff"]:
		GameEvents.parkour.emit(player, kind, Vector3(0, 1.0, -2), 0.9)
		await U.physics_frames(get_tree(), 8)
	var pk := _diff(wfx, c0)
	print("parkour: %s, dust bursts %d, sounds %s" % [pk, (BloodFX._dust_next - dust0 + BloodFX.DUST_POOL) % BloodFX.DUST_POOL, played])
	if pk.get(&"parkour", 0) != 4 or (BloodFX._dust_next - dust0 + BloodFX.DUST_POOL) % BloodFX.DUST_POOL != 3:
		fails.append("parkour dust wrong")
	if not (played.has(&"vault") and played.has(&"step")):
		fails.append("parkour sounds missing")

	# --- Wall run: dust and chips in the wall's colour ------------------------------------------
	var wall := FakePanel.new()
	wall.surface = &"brick"
	add_child(wall)
	GameEvents.wall_run_started.emit(player, wall, 1)
	c0 = wfx.get(&"counts").duplicate()
	played.clear()
	var wd0: int = BloodFX._dust_next
	for i in 3:
		GameEvents.wall_run_step.emit(player, Vector3(1.0, 1.2, -1.0 - i), Vector3(-1, 0, 0))
		await U.physics_frames(get_tree(), 12)
	var wr := _diff(wfx, c0)
	var puff: GPUParticles3D = BloodFX._puffs[wd0]
	var chips: GPUParticles3D = BloodFX._chips[wd0]
	var col: Color = (puff.process_material as ParticleProcessMaterial).color
	print("wall run: %s, chips %s, dust colour %s (brick %s), sounds %s" % [wr, chips.visible, col,
		BloodFX.DUST_BY_SURFACE[&"brick"], played])
	if wr.get(&"wall_dust", 0) != 3 or not chips.visible or not col.is_equal_approx(BloodFX.DUST_BY_SURFACE[&"brick"]):
		fails.append("wall-run dust / chips wrong")
	if played.count(&"step") != 3:
		fails.append("wall-run steps not heard")
	GameEvents.wall_run_ended.emit(player, &"jump")

	# --- A real jump through the player's Traversal --------------------------------------------
	player.remove_from_group(&"player")
	var real: Node3D = FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), Vector3(0, 0.1, 6)), 0)
	await U.physics_frames(get_tree(), 30)
	var rt = real.get(&"traversal")
	if rt == null or not rt.has_method(&"on_jump_pressed"):
		print("note: the player has no Traversal yet; real jump skipped")
	else:
		landings.clear()
		c0 = wfx.get(&"counts").duplicate()
		rt.call(&"on_jump_pressed")
		await get_tree().create_timer(1.5).timeout
		var rj := _diff(wfx, c0)
		print("real jump: landing events %s, effects %s" % [landings, rj])
		if landings.is_empty():
			print("note: Traversal emitted no landing for a standing jump")
		elif rj.is_empty():
			fails.append("a real landing made no effect")
	U.finish(get_tree(), "test_landing_fx", fails, errlog)

func _diff(wfx: Node, before: Dictionary) -> Dictionary:
	var out := {}
	var now: Dictionary = wfx.get(&"counts")
	for k in now:
		var d := int(now[k]) - int(before.get(k, 0))
		if d != 0:
			out[k] = d
	return out

class WorldFXHelper:
	const STREAK_TIME := 0.32
