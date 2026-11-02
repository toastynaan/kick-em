extends Node3D
## Round 5 thrown bodies into walls (Feel Reference: Thrown bodies are
## projectiles; "Throws are no stronger than strikes"; G's F9 checks rely on
## this). A 70 kg body is thrown (GameEvents.thrown, as Carry does) straight at
## a panel; the wall decides on E = 1/2 M v^2 into it, and the thrown body
## takes wall damage like a launched one:
##   tapped standing throw   6 m/s  1,260 J: cracks drywall (not a break)
##   level-3 charged throw  12 m/s  5,040 J: breaks drywall, cracks brick
##   charged sprint throw   16 m/s  8,960 J: breaks brick
## A throw into brick or concrete is a finisher (the wall HitInfo).
## Dead bodies are projectiles too: a corpse thrown at 12 m/s breaks a drywall
## panel (5,040 J) and bowls the grunt standing behind it at about
## 12 sqrt(0.7) = 10 m/s (knockdown or launch).

const START := 1.4   ## m from the panel face to the thrown body's COM

var _decisions: Array = []
var _bowls: Array = []
var _infos: Array[HitInfo] = []
var _ok := true
var _lane := 0

func _ready() -> void:
	ImpactResolver.wall_decided.connect(func(f: Node3D, w: Node3D, outcome: StringName, e: float, _p: Vector3) -> void:
		_decisions.append({"fighter": f, "wall": w, "outcome": outcome, "energy": e}))
	ImpactResolver.bowl_dealt.connect(func(flyer: Node3D, victim: Node3D, speed: float, tier: int, _i: HitInfo) -> void:
		_bowls.append({"flyer": flyer, "victim": victim, "speed": speed, "tier": tier}))
	ImpactResolver.impact_info.connect(func(info: HitInfo) -> void: _infos.append(info))
	WorldTestUtil.make_floor(self, 300.0)
	await get_tree().physics_frame
	if not await WorldTestUtil.real_ragdoll_available(self):
		print("[throw] FAIL: real ragdoll unavailable")
		get_tree().quit(1)
		return
	await _throw(6.0, &"drywall", &"crack", "tapped standing throw")
	await _throw(12.0, &"drywall", &"break", "level-3 charged throw")
	await _throw(12.0, &"brick", &"crack", "level-3 charged throw")
	await _throw(16.0, &"brick", &"break", "charged sprint throw")
	await _dead_body()
	print("[throw] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _line(s: String, ok: bool) -> void:
	_ok = _ok and ok
	print("[throw] %s -> %s" % [s, "PASS" if ok else "FAIL"])

func _throw(speed: float, surface: StringName, expect: StringName, label: String) -> void:
	_lane += 1
	var z := _lane * 12.0
	_decisions.clear()
	_infos.clear()
	var panel := WorldTestUtil.make_panel(self, surface, Vector3(0, 0, z))
	var thrower := WorldTestUtil.spawn_body(self, Transform3D(Basis(), Vector3(START + 1.4, 0.05, z + 1.5)), false,
		&"player", Fighter.TEAM_PLAYER)
	var body := WorldTestUtil.spawn_body(self, Transform3D(Basis(Vector3.UP, -PI * 0.5), Vector3(START + 0.125, 0.05, z)),
		false, &"player", Fighter.TEAM_ENEMY)
	body.max_hp = 1000.0
	body.hp = 1000.0
	await _settle()
	var hp0 := body.hp
	var v := Vector3(-speed, 1.0, 0)
	body.launch(v, body.get_center_of_mass())
	GameEvents.thrown.emit(thrower, body, v)
	await WorldTestUtil.wait_game(self, 0.6)
	var d := _decisions.filter(func(x: Dictionary) -> bool: return x["fighter"] == body and x["wall"] == panel)
	var outcome: StringName = d[0]["outcome"] if d.size() > 0 else &"none"
	var e: float = d[0]["energy"] if d.size() > 0 else -1.0
	var lost := hp0 - body.hp
	var want := 0.0
	if outcome == &"crack":
		want = Tuning.WALL_DAMAGE[&"crack"]
	elif outcome == &"break":
		want = Tuning.WALL_DAMAGE[surface]
	var wall_infos := _infos.filter(func(i: HitInfo) -> bool: return i.victim == body and i.move_id == &"wall")
	var fin_ok := surface != &"brick" or (wall_infos.size() >= 1 and (wall_infos[0] as HitInfo).is_finisher \
		and (wall_infos[0] as HitInfo).attacker == thrower)
	var ok := outcome == expect and absf(lost - want) < 0.01 and fin_ok
	_line("%s %4.1f m/s into %-8s E=%5.0f J (spec %5.0f) -> %-6s (expect %-6s) wall damage %.0f (want %.0f)%s" % [
		label, speed, surface, e, 0.5 * body.get_total_mass() * speed * speed, outcome, expect, lost, want,
		" finisher=%s" % fin_ok if surface == &"brick" else ""], ok)
	for n in [panel, thrower, body]:
		n.queue_free()
	WorldTestUtil.cleanup()
	await get_tree().physics_frame

## A corpse thrown at 12 m/s: breaks a drywall panel, then bowls the grunt behind it.
func _dead_body() -> void:
	_lane += 1
	var z := _lane * 12.0
	_decisions.clear()
	_bowls.clear()
	var panel := WorldTestUtil.make_panel(self, &"drywall", Vector3(1.2, 0, z))
	var thrower := WorldTestUtil.spawn_body(self, Transform3D(Basis(), Vector3(5.5, 0.05, z + 1.5)), false,
		&"player", Fighter.TEAM_PLAYER)
	var corpse := WorldTestUtil.spawn_body(self, Transform3D(Basis(Vector3.UP, -PI * 0.5), Vector3(3.4, 0.05, z)), false,
		&"player", Fighter.TEAM_ENEMY)
	var grunt := WorldTestUtil.spawn_body(self, Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(-0.6, 0.05, z)), false)
	await _settle()
	corpse.apply_damage(corpse.hp + 1.0, &"test")
	await WorldTestUtil.wait_game(self, 2.5)   # it falls and settles
	var dead := corpse.is_dead() and corpse.get_state() == RagdollController.State.DEAD
	if corpse.ragdoll.has_method(&"wake"):
		corpse.ragdoll.wake()
	# Carry lifts a body before the throw: put it back at chest height first.
	var v := Vector3(-12, 1.2, 0)
	corpse.ragdoll.launch(v, corpse.get_center_of_mass(), Bones.CHEST)
	GameEvents.thrown.emit(thrower, corpse, v)
	await WorldTestUtil.wait_game(self, 1.0)
	var b := _bowls.filter(func(x: Dictionary) -> bool: return x["flyer"] == corpse and x["victim"] == grunt)
	var d := _decisions.filter(func(x: Dictionary) -> bool: return x["fighter"] == corpse and x["wall"] == panel)
	# It leaves the wall at about 12 sqrt(0.7) = 10 m/s: right on the launch line, so knockdown or launch.
	var ok: bool = dead and b.size() == 1 and b[0]["tier"] >= HitInfo.Tier.KNOCKDOWN and grunt.is_down() and d.size() >= 1 \
		and d[0]["outcome"] == &"break"
	_line("dead body thrown 12 m/s: dead=%s, drywall E=%s -> %s, then bowled the grunt at %.1f m/s -> %s (grunt down=%s)" % [
		dead, d.map(func(x: Dictionary) -> int: return int(x["energy"])), d[0]["outcome"] if d.size() > 0 else &"none",
		b[0]["speed"] if b.size() > 0 else -1.0, HitInfo.tier_name(b[0]["tier"]) if b.size() > 0 else &"none",
		grunt.is_down()], ok)
	for n in [panel, thrower, corpse, grunt]:
		n.queue_free()
	WorldTestUtil.cleanup()
	await get_tree().physics_frame

func _settle() -> void:
	for i in 6:
		await get_tree().physics_frame
