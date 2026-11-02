extends Node3D
## Round 5 bodies as projectiles (Feel Reference: Thrown bodies are projectiles).
## A flying body whose pelvis is faster than Tuning.PROJECTILE_MIN_SPEED (4 m/s)
## hits standing enemies by speed (Power.bowl_tier): under 6 m/s a stagger,
## 6-10 a knockdown, 10+ a launch, with Tuning.BOWL_DAMAGE 5 / 10 / 15, as a
## preset-tier HitInfo (kind &"bowl") through victim.take_hit(); the flyer loses
## Tuning.BOWL_SPEED_LOSS (40%) of its speed per hit and keeps tumbling.
## 1. 4.8, 8 and 12 m/s into a standing grunt: stagger / knockdown / launch,
##    damage 5 / 10 / 15, victim down for knockdown and launch only.
## 2. A 3 m/s launch (pelvis under 4 m/s): not a projectile, no bowl.
## 3. 16 m/s into 3 grunts in a line (the F9 check): the first is launched,
##    and the chain (the thrown body, or the first grunt flying ahead of it)
##    knocks down or launches at least 2 of 3; the chain counter counts 1, 2, ...
## 3b. Each hit costs the flyer 40%: its speed right after the hit (after the
##    contact freeze) is 0.6 of its speed going in (16 -> 9.6 -> 5.8).
## 4. A flying enemy never bowls the player; a body thrown by a grabber never
##    bowls that grabber.

var _bowls: Array = []          ## from ImpactResolver.bowl_dealt
var _events: Array = []         ## GameEvents.body_bowled
var _ok := true

func _ready() -> void:
	ImpactResolver.bowl_dealt.connect(func(flyer: Node3D, victim: Node3D, speed: float, tier: int, info: HitInfo) -> void:
		_bowls.append({"flyer": flyer, "victim": victim, "speed": speed, "tier": tier, "info": info}))
	GameEvents.body_bowled.connect(func(flyer: Node3D, victim: Node3D, e: float, chain: int) -> void:
		_events.append({"flyer": flyer, "victim": victim, "energy": e, "chain": chain}))
	WorldTestUtil.make_floor(self, 200.0)
	await get_tree().physics_frame
	if not await WorldTestUtil.real_ragdoll_available(self):
		print("[bowl] FAIL: real ragdoll unavailable")
		get_tree().quit(1)
		return

	# 1. Tiers by speed.
	var lane := 0.0
	for c: Array in [[4.8, HitInfo.Tier.STAGGER], [8.0, HitInfo.Tier.KNOCKDOWN], [12.0, HitInfo.Tier.LAUNCH]]:
		lane += 8.0
		var r := await _shot(c[0], lane)
		var b: Dictionary = r["bowl"]
		var want_tier: int = c[1]
		var want_dmg: float = Tuning.BOWL_DAMAGE[HitInfo.tier_name(want_tier)]
		var down: bool = r["victim_down"]
		var ok: bool = not b.is_empty() and b["tier"] == want_tier and absf(r["hp_lost"] - want_dmg) < 0.01 \
			and (b["info"] as HitInfo).kind == &"bowl" and down == (want_tier >= HitInfo.Tier.KNOCKDOWN)
		_line("%.1f m/s into a grunt: pelvis %.2f m/s -> %s (want %s), damage %.0f (want %.0f), victim down=%s" % [
			c[0], b.get("speed", -1.0), HitInfo.tier_name(b.get("tier", 0)), HitInfo.tier_name(want_tier),
			r["hp_lost"], want_dmg, down], ok)
		_clear([r["flyer"], r["victim"]])

	# 2. Under the projectile speed: nothing.
	var slow := await _shot(3.0, 40.0)
	_line("3.0 m/s launch: bowled=%s at pelvis %.2f m/s (under %.0f m/s is not a projectile)" % [not slow["bowl"].is_empty(),
		slow["bowl"].get("speed", -1.0), Tuning.PROJECTILE_MIN_SPEED], slow["bowl"].is_empty())
	_clear([slow["flyer"], slow["victim"]])

	# 3. 16 m/s into 3 grunts in a line, 2.2 m apart.
	_bowls.clear()
	_events.clear()
	var z := 60.0
	var flyer := _spawn(Vector3(5.2, 0.05, z), Fighter.TEAM_ENEMY, &"player")
	var g: Array[Fighter] = [_spawn(Vector3(2.6, 0.05, z), Fighter.TEAM_ENEMY), _spawn(Vector3(0.4, 0.05, z), Fighter.TEAM_ENEMY),
		_spawn(Vector3(-1.8, 0.05, z), Fighter.TEAM_ENEMY)]
	await _settle()
	flyer.launch(Vector3(-16, 1.2, 0), flyer.get_center_of_mass())
	var t := 0.0
	var downs := {}
	while t < 1.5:
		await get_tree().physics_frame
		t += 1.0 / 120.0
		for v in g:
			if v.is_down():
				downs[v.get_instance_id()] = true
	var mine := _bowls.filter(func(x: Dictionary) -> bool: return x["flyer"] == flyer)
	var speeds: Array = mine.map(func(x: Dictionary) -> String: return "%.1f" % x["speed"])
	var tiers: Array = mine.map(func(x: Dictionary) -> StringName: return HitInfo.tier_name(x["tier"]))
	var chains: Array = _events.map(func(x: Dictionary) -> int: return x["chain"])
	var line_ok: bool = downs.size() >= 2 and mine.size() >= 1 and mine[0]["tier"] == HitInfo.Tier.LAUNCH \
		and chains.size() >= 2 and chains.slice(0, 2) == [1, 2]
	_line("16 m/s into 3 grunts: thrown body's hits at %s m/s %s, chain %s, down %d of 3 (need 2)" % [
		speeds, tiers, chains, downs.size()], line_ok)
	_clear([flyer, g[0], g[1], g[2]])

	# 3b. Speed loss per hit, measured on the flyer.
	_bowls.clear()
	z = 70.0
	flyer = _spawn(Vector3(3.0, 0.05, z), Fighter.TEAM_ENEMY, &"player")
	var lone := _spawn(Vector3(0.0, 0.05, z), Fighter.TEAM_ENEMY)
	await _settle()
	flyer.launch(Vector3(-16, 1.2, 0), flyer.get_center_of_mass())
	var before := 0.0
	var after := 0.0
	var hit_seen := false
	var was_frozen := false
	var thawed_at := -1.0
	t = 0.0
	while t < 0.8:
		await get_tree().physics_frame
		t += 1.0 / 120.0
		var hv := Vector2(flyer.get_com_velocity().x, flyer.get_com_velocity().z).length()
		if not hit_seen:
			if _bowls.is_empty():
				before = hv
			else:
				hit_seen = true
		elif flyer.is_frozen():
			was_frozen = true
		elif was_frozen:
			if thawed_at < 0.0:
				thawed_at = t
			if t - thawed_at <= 0.06:
				after = maxf(after, hv)   # the stored velocity is back within a tick or two
	var ratio := after / maxf(before, 0.01)
	_line("one hit at %.1f m/s: flyer leaves at %.1f m/s = %.2f of its speed (want %.2f), contact freeze=%s" % [
		before, after, ratio, 1.0 - Tuning.BOWL_SPEED_LOSS, was_frozen],
		absf(ratio - (1.0 - Tuning.BOWL_SPEED_LOSS)) <= 0.08 and was_frozen)
	_clear([flyer, lone])

	# 4. A flying enemy never bowls the player; a thrown body never bowls its grabber.
	_bowls.clear()
	var e1 := _spawn(Vector3(3.2, 0.05, 80), Fighter.TEAM_ENEMY)
	var pl := _spawn(Vector3(0, 0.05, 80), Fighter.TEAM_PLAYER, &"player")
	await _settle()
	e1.launch(Vector3(-13, 1.2, 0), e1.get_center_of_mass())
	await WorldTestUtil.wait_game(self, 0.6)
	var p_ok := _bowls.filter(func(x: Dictionary) -> bool: return x["victim"] == pl).is_empty()
	_clear([e1, pl])
	_bowls.clear()
	var grabber := _spawn(Vector3(0, 0.05, 90), Fighter.TEAM_ENEMY)
	var thrown := _spawn(Vector3(-0.7, 0.05, 90), Fighter.TEAM_ENEMY, &"player")
	await _settle()
	thrown.launch(Vector3(-12, 1.0, 0), thrown.get_center_of_mass())
	GameEvents.thrown.emit(grabber, thrown, Vector3(-12, 1.0, 0))
	await WorldTestUtil.wait_game(self, 0.5)
	var g_ok := _bowls.filter(func(x: Dictionary) -> bool: return x["victim"] == grabber).is_empty()
	_line("a flying enemy into the player: bowled=%s; thrown away from its grabber at 0.7 m: bowled=%s" % [
		not p_ok, not g_ok], p_ok and g_ok)
	_clear([grabber, thrown])

	print("[bowl] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _line(s: String, ok: bool) -> void:
	_ok = _ok and ok
	print("[bowl] %s -> %s" % [s, "PASS" if ok else "FAIL"])

func _spawn(pos: Vector3, team: int, arch: StringName = &"grunt") -> Fighter:
	var f := WorldTestUtil.spawn_body(self, Transform3D(Basis(Vector3.UP, -PI * 0.5), pos), false, arch, team)
	return f

func _settle() -> void:
	for i in 4:
		await get_tree().physics_frame

## A 70 kg flyer launched at `speed` (-X, a little lift) at a grunt 3 m away (1.9 m when slow).
func _shot(speed: float, z: float) -> Dictionary:
	_bowls.clear()
	# Slow shots start closer so the body is still in the air when it arrives.
	var dist := 3.0 if speed >= 6.0 else 1.9
	var flyer := _spawn(Vector3(dist, 0.05, z), Fighter.TEAM_ENEMY, &"player")
	var victim := _spawn(Vector3(0, 0.05, z), Fighter.TEAM_ENEMY)
	await _settle()
	var hp0 := victim.hp
	flyer.launch(Vector3(-speed, 1.0, 0), flyer.get_center_of_mass())
	var t := 0.0
	var down := false
	while t < 0.8:
		await get_tree().physics_frame
		t += 1.0 / 120.0
		down = down or victim.is_down()
	var bowl := {}
	for x: Dictionary in _bowls:
		if x["victim"] == victim:
			bowl = x
			break
	return {"flyer": flyer, "victim": victim, "bowl": bowl, "victim_down": down, "hp_lost": hp0 - victim.hp}

func _clear(nodes: Array) -> void:
	for n in nodes:
		if is_instance_valid(n):
			n.queue_free()
	WorldTestUtil.cleanup()
