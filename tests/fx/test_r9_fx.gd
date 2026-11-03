extends Node3D
## Round 9 effects (docs/Round 9 — Playtest Fixes.md, sections 3 and 4; owner F).
## Light: one check per change.
## - Guard broken: pressure_broken centres the burst on the guard (not the
##   head) and starts the cracked guard (arcs on both forearms, the arm glows,
##   the guard crackle) instead of the daze; pressure_recovered stops it. With
##   broken_stun (Tuning.R9_BROKEN_STUN) the Round 8 dazed loop plays instead.
## - Axe kick: a spike hit_landed with move_id axe_kick / air_axe adds the heel
##   crack (effect and sound) on its frame, heavier when charged; the spike's
##   floor shockwave is heavier for a wider (charged) blast.
## OWNER: agent F.

const U := preload("res://tests/fx/fx_test_util.gd")

var played: Array = []   ## [id, physics frame]
var fails: Array[String] = []

func _ready() -> void:
	var errlog := U.ErrorLogger.new()
	OS.add_logger(errlog)
	BloodFX.reset()
	U.make_floor(self)
	if not await U.wait_audio(get_tree()):
		fails.append("AudioFX never finished synthesising")
	AudioFX.sound_played.connect(func(id: StringName, _p: Vector3) -> void: played.append([id, Engine.get_physics_frames()]))
	var player := U.make_fighter(self, Vector3(0, 0, 1.5))
	player.add_to_group(&"player")
	var enemy := U.make_fighter(self, Vector3(0, 0, -0.5))
	var ec: Node = enemy.add_combat()
	var cfx: Node = BloodFX.get_charge_fx()
	await U.physics_frames(get_tree(), 2)
	await _check_guard_broken(player, enemy, ec, cfx)
	await _check_axe(player, enemy, cfx)
	U.finish(get_tree(), "test_r9_fx", fails, errlog)

func _check_guard_broken(player: Node3D, enemy: Node3D, ec: Node, cfx: Node) -> void:
	ec.broken = true
	played.clear()
	var f := Engine.get_physics_frames()
	GameEvents.pressure_broken.emit(enemy, player)
	var at: Vector3 = (cfx.get(&"last_break") as Dictionary).get("position", Vector3.ZERO)
	var guard := FXRules.guard_point(enemy)
	var head := FXRules.head_of(enemy)
	await get_tree().create_timer(0.3).timeout
	var node: Node3D = cfx.call(&"get_crack_node", enemy)
	var glows: Array = cfx.call(&"get_crack_glows", enemy)
	var worst := 0.0  # farthest arc from its forearm
	if node != null:
		var per: int = cfx.get(&"CRACK_SPARKS")
		for j in node.get_child_count():
			var arm := FXRules.limb_point(enemy, Bones.L_LOWER_ARM if j < per else Bones.R_LOWER_ARM)
			worst = maxf(worst, (node.get_child(j) as Node3D).global_position.distance_to(arm))
	print("GUARD BROKEN: burst %s (guard %s, head %s); cracked %s, dazed %s, arcs %s (worst %.2f m off the forearm), glows %d, loop %s, crackle on frame %s" % [
		at, guard, head, cfx.call(&"is_guard_cracked", enemy), cfx.call(&"is_dazed", enemy), node != null, worst,
		glows.size(), AudioFX.broken_loop_id(enemy), _played_on(&"guard_crackle", f)])
	if at.distance_to(guard) > 0.05 or at.y > head.y - 0.25:
		fails.append("the break burst is not on the guard (%s)" % at)
	if not cfx.call(&"is_guard_cracked", enemy) or cfx.call(&"is_dazed", enemy) or node == null \
			or worst > 0.2 or glows.size() != 2:
		fails.append("cracked guard missing or wrong")
	if AudioFX.broken_loop_id(enemy) != &"guard_crackle" or not AudioFX.is_broken_loop_playing(enemy) \
			or not _played_on(&"guard_crackle", f) or _played_on(&"dazed", f):
		fails.append("guard crackle not playing (loop %s)" % AudioFX.broken_loop_id(enemy))
	ec.broken = false
	GameEvents.pressure_recovered.emit(enemy)
	await get_tree().create_timer(0.4).timeout
	if int(cfx.call(&"active_broken_loops")) != 0 or AudioFX.active_dazed() != 0:
		fails.append("cracked guard outlived pressure_recovered")
	# R9_BROKEN_STUN true: the Round 8 daze comes back.
	cfx.set(&"broken_stun", true)
	AudioFX.broken_stun = true
	ec.broken = true
	GameEvents.pressure_broken.emit(enemy, player)
	await U.physics_frames(get_tree(), 4)
	var dazed: bool = cfx.call(&"is_dazed", enemy) and AudioFX.broken_loop_id(enemy) == &"dazed"
	print("with broken_stun: dazed %s" % dazed)
	if not dazed:
		fails.append("broken_stun does not bring the daze back")
	ec.broken = false
	GameEvents.pressure_recovered.emit(enemy)
	cfx.set(&"broken_stun", Tuning.R9_BROKEN_STUN)
	AudioFX.broken_stun = Tuning.R9_BROKEN_STUN
	await get_tree().create_timer(0.4).timeout

func _check_axe(player: Node3D, enemy: Node3D, cfx: Node) -> void:
	var ffx: Node = BloodFX.get_freeflow_fx()
	var sizes: Array[float] = []
	var dbs: Array[float] = []
	for setup: Array in [[&"axe_kick", false, 0.0], [&"air_axe", true, 1.0]]:
		await U.physics_frames(get_tree(), 6)
		played.clear()
		var h := U.hit(enemy, setup[0], enemy.global_position + Vector3(0, 1.6, 0), Vector3(0, -1, -0.2), 10.0, 0.0,
				&"strike", HitInfo.Tier.LAUNCH)
		h.attacker = player
		h.react = &"spike"
		h.weight = 0.75
		h.charged = setup[1]
		h.charge = setup[2]
		h.launch_velocity = Vector3(0, -12.0 if not setup[1] else -18.0, 0)
		var f := Engine.get_physics_frames()
		GameEvents.hit_landed.emit(h)
		var size := -1.0
		for rec: Dictionary in cfx.get(&"effect_log"):
			if rec["event"] == &"axe_crack" and int(rec["frame"]) == f:
				size = float(rec["size"])
		var layer: Array = AudioFX.axe_layers(h)
		sizes.append(size)
		dbs.append(float(layer[0][1]) if not layer.is_empty() else -99.0)
		var contact: Dictionary = BloodFX.contact_log.back()
		print("%s (charged %s): heel crack %.2f, sound %s on frame %s (%.1f dB), spike flash %s on frame %s" % [setup[0],
			setup[1], size, _played_on(&"axe_crack", f), layer, dbs.back(), contact.get("flash"), int(contact["frame"]) == f])
		if size < 0.0 or not _played_on(&"axe_crack", f) or not contact.get("flash", false) or int(contact["frame"]) != f:
			fails.append("%s: heel crack or spike flash missing on the hit's frame" % setup[0])
	if sizes[1] <= sizes[0] or dbs[1] <= dbs[0]:
		fails.append("the charged axe kick is not heavier (flash %s, dB %s)" % [sizes, dbs])
	# The floor shockwave: a wider blast (a charged axe kick) is heavier.
	var heft: Array[float] = []
	for blast: float in [Tuning.R9_AXE["tap"]["blast"], Tuning.R9_AXE["charged"]["blast"].y]:
		await U.physics_frames(get_tree(), 6)
		GameEvents.shockwave.emit(player, enemy.global_position, blast, 0.0)
		heft.append(float(ffx.get(&"last_spike_heft")))
	print("spike floor heft: tap %.2f, full charge %.2f" % [heft[0], heft[1]])
	if heft[1] <= heft[0]:
		fails.append("the charged axe kick's floor impact is not heavier")

func _played_on(id: StringName, f: int) -> bool:
	for p in played:
		if p[0] == id and int(p[1]) == f:
			return true
	return false
