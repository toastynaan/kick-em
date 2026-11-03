extends Node3D
## Round 7 (Grab, drive and throw: "Holding"), the buttons while holding, through
## the real input path (Input.action_press -> PlayerController -> InputInterpreter
## -> CombatController's routing -> Carry):
## - RMB (leg_kick): up to Tuning.HOLD_KNEES_MAX knees (the third a headbutt),
##   each a flinch-tier hit for Power.strike_damage(&"knee"), the hold kept; no
##   knees while driving;
## - the other strike buttons do nothing with a body in hand (no strike starts,
##   the hold stays);
## - LMB pressed and released during the clinch: a tap throw once the hold connects;
## - Shift pressed during the clinch: the drive starts once the hold connects.
## (Throw speeds and aim: test_throw. The drive's contacts: test_drive_yard.)
## OWNER: agent G.

var _fail: Array[String] = []
var _hits: Array[HitInfo] = []
var _starts: Array[StringName] = []

func _ready() -> void:
	get_tree().create_timer(150.0, true, false, true).timeout.connect(func() -> void:
		print("FAIL timeout")
		get_tree().quit(1))
	Carry.force_enabled = true
	GameEvents.hit_landed.connect(func(info: HitInfo) -> void: _hits.append(info))
	GrabTestUtil.make_floor(self, 400.0)
	await get_tree().physics_frame
	await _knees()
	await _other_buttons()
	await _knee_while_driving()
	await _clinch_throw()
	await _clinch_drive()
	_finish()

## The real player at the origin, a camera looking -Z, a grunt 1 m ahead held
## by the collar (or only caught, in the clinch, when `clinch`).
func _pair(clinch := false) -> Array:
	GrabTestUtil.reset_world()
	GrabTestUtil.release_all_input()
	_hits.clear()
	_starts.clear()
	var p := GrabTestUtil.spawn_player(self, Vector3.ZERO, Vector3.FORWARD)
	var cam := GrabTestUtil.make_camera(self, p, Vector3.FORWARD)
	var e := GrabTestUtil.spawn(self, &"grunt", Vector3(0.0, 0.0, -1.0), Vector3.BACK)
	p.combat.attack_started.connect(func(id: StringName) -> void: _starts.append(id))
	await GrabTestUtil.frames(self, 20)
	if clinch:
		await GrabTestUtil.key_tap(self, &"grab", 1)
		await GrabTestUtil.wait_until(self, func() -> bool: return e.carry.is_held(), 0.5)
	else:
		p.carry.grab_now(e, &"", true)
		await GrabTestUtil.wait(self, 0.3)
	return [p, e, cam]

func _clear(nodes: Array) -> void:
	GrabTestUtil.release_all_input()
	for n in nodes:
		if is_instance_valid(n):
			n.queue_free()
	await GrabTestUtil.frames(self, 4)

func _knee_hits(e: Fighter) -> Array[HitInfo]:
	var out: Array[HitInfo] = []
	for h in _hits:
		if h.victim == e and h.move_id in [&"held_knee", &"headbutt"]:
			out.append(h)
	return out

func _knees() -> void:
	var pr: Array = await _pair()
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	var hp0 := e.hp
	for i in 4:
		await GrabTestUtil.key_tap(self, &"leg_kick", 2)
		await GrabTestUtil.wait(self, 0.4)
	var knees := _knee_hits(e)
	var desc := ", ".join(knees.map(func(h: HitInfo) -> String:
		return "%s %s %.0f dmg" % [h.move_id, HitInfo.tier_name(h.tier), h.damage]))
	print("[knees] 4 RMB presses -> %d hits: %s; hp %.0f -> %.0f; still holding=%s, strikes started %s" % [knees.size(), desc,
		hp0, e.hp, p.carry.is_holding_body(), _starts])
	_check(knees.size() == Tuning.HOLD_KNEES_MAX, "up to 3 knees per hold")
	var all_flinch := true
	for h: HitInfo in knees:
		all_flinch = all_flinch and h.tier == HitInfo.Tier.FLINCH and is_equal_approx(h.damage, Power.strike_damage(&"knee", 0))
	_check(all_flinch, "each a flinch-tier hit, knee damage")
	_check(knees.size() == 3 and knees[2].move_id == &"headbutt", "the third is a headbutt")
	_check(p.carry.is_holding_body() and _starts.is_empty(), "the knees keep the hold (no leg kick strike)")
	p.carry.drop(&"release")
	await _clear(pr)

func _other_buttons() -> void:
	var pr: Array = await _pair()
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	for a: StringName in [&"gut_punch", &"uppercut", &"front_kick", &"roundhouse"]:
		await GrabTestUtil.key_tap(self, a, 2)
		await GrabTestUtil.wait(self, 0.15)
	print("[buttons] Q, E, F, R with a body: strikes started %s, hits on it %d, holding=%s" % [_starts,
		_hits.filter(func(h: HitInfo) -> bool: return h.victim == e).size(), p.carry.is_holding_body()])
	_check(_starts.is_empty() and p.carry.is_holding_body(), "the other strike buttons do nothing with a body in hand")
	p.carry.drop(&"release")
	await _clear(pr)

func _knee_while_driving() -> void:
	var pr: Array = await _pair()
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	p.carry.on_drive_pressed(TimeDirector.now())   # the drive's routing is test_drive_yard's
	await GrabTestUtil.wait(self, 0.2)
	var driving := p.carry.is_driving()
	await GrabTestUtil.key_tap(self, &"leg_kick", 2)
	await GrabTestUtil.wait(self, 0.3)
	var knees := _knee_hits(e)
	p.carry.on_drive_released(TimeDirector.now())
	print("[drive knee] driving=%s, RMB -> %d knees, holding=%s" % [driving, knees.size(), p.carry.is_holding_body()])
	_check(driving and knees.is_empty() and p.carry.is_holding_body(), "no knees while driving")
	p.carry.drop(&"release")
	await _clear(pr)

func _clinch_throw() -> void:
	var pr: Array = await _pair(true)
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	var in_clinch := e.carry.is_held() and not p.carry.is_holding_body()
	await GrabTestUtil.key_tap(self, &"punch", 1)
	var thrown := await GrabTestUtil.wait_until(self, func() -> bool: return not p.carry.is_holding(), 0.5)
	var v := p.carry.last_throw_velocity.length()
	print("[clinch throw] LMB tapped in the clinch (%s): thrown=%s at %.2f m/s" % [in_clinch, thrown, v])
	_check(in_clinch and thrown and absf(v - Tuning.R7_THROW_SPEED_MIN) < 0.3, "an LMB tap in the clinch throws once the hold connects")
	await _clear(pr)

func _clinch_drive() -> void:
	var pr: Array = await _pair(true)
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	var in_clinch := e.carry.is_held() and not p.carry.is_holding_body()
	p.carry.on_drive_pressed(TimeDirector.now())   # Shift pressed during the clinch
	var driving := await GrabTestUtil.wait_until(self, func() -> bool: return p.carry.is_driving(), 0.5)
	var held_body := p.carry.is_holding_body()
	p.carry.on_drive_released(TimeDirector.now())
	print("[clinch drive] Shift in the clinch (%s): drive started=%s with the body=%s" % [in_clinch, driving, held_body])
	_check(in_clinch and driving and held_body, "Shift in the clinch starts the drive once the hold connects")
	p.carry.drop(&"release")
	await _clear(pr)

func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		_fail.append(what)

func _finish() -> void:
	Carry.force_enabled = false
	GrabTestUtil.release_all_input()
	if _fail.is_empty():
		print("PASS test_carry_actions")
		get_tree().quit(0)
	else:
		print("FAIL test_carry_actions: ", _fail)
		get_tree().quit(1)
