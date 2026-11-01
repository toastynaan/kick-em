extends Node3D
## Human bowling: a 13 m/s launched body hitting a standing enemy launches it;
## the chain counter increments and carries to the next body; low energies
## flinch / stagger; a flying enemy never bowls the player; a thrown body does
## not bowl its own grabber; a throw into brick is a finisher impact.

var _use_fake := false
var _bowls: Array = []
var _ok := true

func _ready() -> void:
	GameEvents.body_bowled.connect(func(flyer_body: Node3D, victim_body: Node3D, e: float, chain: int) -> void:
		_bowls.append({"flyer": flyer_body, "victim": victim_body, "energy": e, "chain": chain}))
	WorldTestUtil.make_floor(self)
	await get_tree().physics_frame
	_use_fake = not await WorldTestUtil.real_ragdoll_available(self)
	print("[bowl] ragdoll: ", "TEST STAND-IN" if _use_fake else "real RagdollController")

	# 1. 13 m/s flyer into a standing enemy: launch.
	var r := await _shot(13.0, Fighter.TEAM_ENEMY)
	var v1: Fighter = r["victim"]
	var launched_ok: bool = r["bowl"] != null and r["bowl"]["chain"] == 1 and r["victim_state"] == RagdollController.State.LAUNCHED
	print("[bowl] 13 m/s into standing enemy: E=%.0f chain=%s victim state=%s victim speed=%.2f -> %s" % [
		r["bowl"]["energy"] if r["bowl"] else -1.0, r["bowl"]["chain"] if r["bowl"] else -1,
		r["victim_state"], r["victim_speed"], "PASS" if launched_ok else "FAIL"])
	_ok = _ok and launched_ok
	_clear([r["flyer"], v1])

	# 2. Chain: 16 m/s flyer -> enemy A (launched at 8 m/s) -> enemy B.
	_bowls.clear()
	var flyer := _spawn(Vector3(6, 0.05, 0), Fighter.TEAM_ENEMY)
	var a := _spawn(Vector3(3, 0.05, 0), Fighter.TEAM_ENEMY)
	var b := _spawn(Vector3(0, 0.05, 0), Fighter.TEAM_ENEMY)
	await _settle()
	flyer.launch(Vector3(-16, 1.5, 0), flyer.get_center_of_mass())
	await WorldTestUtil.wait_game(self, 1.2)
	var chains: Array = _bowls.map(func(x: Dictionary) -> int: return x["chain"])
	var victims: Array = _bowls.map(func(x: Dictionary) -> String: return (x["victim"] as Node).name)
	var chain_ok: bool = _bowls.size() >= 2 and chains[0] == 1 and chains[1] == 2 and b.is_down()
	print("[bowl] chain 16 m/s: bowls=%d chains=%s victims=%s B down=%s -> %s" % [
		_bowls.size(), chains, victims, b.is_down(), "PASS" if chain_ok else "FAIL"])
	_ok = _ok and chain_ok
	_clear([flyer, a, b])

	# 3. Low energies: flinch below 600 J, stagger below 1,500 J (no launch).
	r = await _shot(3.6, Fighter.TEAM_ENEMY, 1.5)   # ~454 J
	var fl_ok: bool = r["bowl"] != null and r["bowl"]["energy"] < Tuning.BOWL_FLINCH_BELOW and r["victim_state"] != RagdollController.State.LAUNCHED
	print("[bowl] 3.6 m/s: E=%.0f -> flinch, victim state=%s -> %s" % [
		r["bowl"]["energy"] if r["bowl"] else -1.0, r["victim_state"], "PASS" if fl_ok else "FAIL"])
	_ok = _ok and fl_ok
	_clear([r["flyer"], r["victim"]])
	r = await _shot(5.5, Fighter.TEAM_ENEMY, 1.5)   # ~1,059 J
	var st_ok: bool = r["bowl"] != null and r["bowl"]["energy"] >= Tuning.BOWL_FLINCH_BELOW \
		and r["bowl"]["energy"] < Tuning.BOWL_LAUNCH_ABOVE and r["victim_state"] != RagdollController.State.LAUNCHED
	print("[bowl] 5.5 m/s: E=%.0f -> stagger, victim state=%s -> %s" % [
		r["bowl"]["energy"] if r["bowl"] else -1.0, r["victim_state"], "PASS" if st_ok else "FAIL"])
	_ok = _ok and st_ok
	_clear([r["flyer"], r["victim"]])

	# 4. A flying enemy never bowls the player.
	r = await _shot(13.0, Fighter.TEAM_PLAYER)
	var pl_ok: bool = r["bowl"] == null and r["victim_state"] != RagdollController.State.LAUNCHED
	print("[bowl] flying enemy into the player: bowled=%s player state=%s -> %s" % [
		r["bowl"] != null, r["victim_state"], "PASS" if pl_ok else "FAIL"])
	_ok = _ok and pl_ok
	_clear([r["flyer"], r["victim"]])

	# 5. A launched player bowls enemies.
	r = await _shot(13.0, Fighter.TEAM_ENEMY, 3.2, Fighter.TEAM_PLAYER)
	var pb_ok: bool = r["bowl"] != null and r["victim_state"] == RagdollController.State.LAUNCHED
	print("[bowl] launched player into an enemy: bowled=%s victim state=%s -> %s" % [
		r["bowl"] != null, r["victim_state"], "PASS" if pb_ok else "FAIL"])
	_ok = _ok and pb_ok
	_clear([r["flyer"], r["victim"]])

	# 6. A thrown body never bowls its own grabber right after the throw
	#    (GameEvents.thrown marks the launcher; grace Tuning-free 0.25 s).
	_bowls.clear()
	var grabber := _spawn(Vector3(0, 0.05, 0), Fighter.TEAM_ENEMY)
	var thrown := _spawn(Vector3(-0.7, 0.05, 0), Fighter.TEAM_PLAYER)
	await _settle()
	thrown.launch(Vector3(-12, 1.0, 0), thrown.get_center_of_mass())
	GameEvents.thrown.emit(grabber, thrown, Vector3(-12, 1.0, 0))
	await WorldTestUtil.wait_game(self, 0.5)
	var g_ok := _bowls.filter(func(x: Dictionary) -> bool: return x["victim"] == grabber).is_empty()
	print("[bowl] thrown away from its grabber at 0.7 m: bowled=%s -> %s" % [not g_ok, "PASS" if g_ok else "FAIL"])
	_ok = _ok and g_ok
	_clear([grabber, thrown])

	# 7. A throw into brick is a finisher on the impact HitInfo.
	var infos: Array[HitInfo] = []
	var cb := func(info: HitInfo) -> void: infos.append(info)
	ImpactResolver.impact_info.connect(cb)
	var panel := WorldTestUtil.make_panel(self, &"brick", Vector3(-3, 0, 0))
	var thrower := _spawn(Vector3(3, 0.05, 3), Fighter.TEAM_ENEMY)
	var victim := _spawn(Vector3(-0.8, 0.05, 0), Fighter.TEAM_PLAYER)
	await _settle()
	victim.launch(Vector3(-8, 1.5, 0), victim.get_center_of_mass())
	GameEvents.thrown.emit(thrower, victim, Vector3(-8, 1.5, 0))
	await WorldTestUtil.wait_game(self, 0.6)
	var brick_infos := infos.filter(func(i: HitInfo) -> bool: return i.victim == victim and i.move_id == &"wall")
	var fin_ok: bool = brick_infos.size() >= 1 and brick_infos[0].is_finisher
	print("[bowl] throw into brick: impact infos=%d is_finisher=%s -> %s" % [brick_infos.size(),
		brick_infos[0].is_finisher if brick_infos.size() > 0 else false, "PASS" if fin_ok else "FAIL"])
	_ok = _ok and fin_ok
	ImpactResolver.impact_info.disconnect(cb)
	_clear([thrower, victim, panel])

	print("[bowl] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _spawn(pos: Vector3, team: int) -> Fighter:
	var arch := &"player" if team == Fighter.TEAM_PLAYER else &"grunt"
	return WorldTestUtil.spawn_body(self, Transform3D(Basis(Vector3.UP, -PI * 0.5), pos), _use_fake, arch, team)

func _settle() -> void:
	for i in 4:
		await get_tree().physics_frame

func _shot(speed: float, victim_team: int, dist := 3.2, flyer_team := Fighter.TEAM_ENEMY) -> Dictionary:
	_bowls.clear()
	var flyer := _spawn(Vector3(dist, 0.05, 0), flyer_team)
	var victim := _spawn(Vector3(0, 0.05, 0), victim_team)
	await _settle()
	flyer.launch(Vector3(-speed, 1.2, 0), flyer.get_center_of_mass())
	var t := 0.0
	var state := victim.get_state()
	var vs := 0.0
	while t < 0.8:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		if victim.get_state() == RagdollController.State.LAUNCHED:
			state = RagdollController.State.LAUNCHED
			vs = maxf(vs, Vector2(victim.get_com_velocity().x, victim.get_com_velocity().z).length())
	var bowl: Variant = null
	for x: Dictionary in _bowls:
		if x["victim"] == victim:
			bowl = x
			break
	return {"flyer": flyer, "victim": victim, "bowl": bowl, "victim_state": state, "victim_speed": vs}

func _clear(nodes: Array) -> void:
	for n in nodes:
		if is_instance_valid(n):
			n.queue_free()
	WorldTestUtil.cleanup()
