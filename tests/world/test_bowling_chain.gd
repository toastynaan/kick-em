extends Node3D
## Round 5 bowling chain (Feel Reference: Thrown bodies are projectiles: "The
## thrown body loses 40% of its speed per hit and keeps tumbling. A 16 m/s throw
## goes launch -> knockdown (9.6 m/s) -> stagger (5.8 m/s)").
## A grunt is thrown the way Carry throws (GameEvents.thrown, Tuning.THROW_UP_ANGLE
## up) into 3 standing grunts in a line, 2.5 m apart, at 12 and 16 m/s, four
## runs each. Measured per hit:
## - the speed the tier reads: the thrown body's pelvis speed across the floor
##   at each victim (ImpactResolver.bowl_dealt);
## - the rule itself: its horizontal centre-of-mass speed going into the hit
##   and coming out of it (after the contact freeze).
## Expected:
##   16 m/s: launch -> knockdown -> stagger, speeds 16 -> 9.6 -> 5.8
##   12 m/s: launch -> knockdown at the 2nd (7.2 m/s)
## Tolerances:
## - Rule: COM speed out / in = 0.60 +- 0.02 at the 1st and 2nd hits (airborne:
##   the resolver scales the bones by exactly 0.6; 0.02 covers the tick of
##   contact) and +- 0.06 at the 3rd, where the body may already be sliding on
##   the floor: at ~4 m/s, ~8 m/s^2 of friction over the ~3 ticks of contact
##   and thaw takes ~0.2 m/s, 0.05 of the ratio (measured 0.555-0.601).
## - Arrival at the 2nd victim / the 1st: 0.60 +- 0.09. The tier reads the
##   pelvis, whose speed differs from the centre of mass by up to ~0.5 m/s of
##   limb spin (measured in test_bowling: 4.8 -> 5.0, 3.0 -> 3.5): 5% at 10 m/s,
##   9% at 6 m/s.
## - Arrival at the 3rd: at most 0.60 + 0.09 of the 2nd, and still a projectile
##   (Tuning.PROJECTILE_MIN_SPEED). With 2.5 m spacing and a 15 deg throw from
##   standing height the body lands 0.3-0.6 m before the 3rd grunt and slides
##   into it; sliding (~8 m/s^2) takes 0-1.4 m/s of its 5.6 (measured 5.6 down
##   to 4.2), and the floor only ever takes speed away, so the honest lower
##   bound is the projectile limit itself.
## Tiers must match the doc exactly, in every run.

const SPACING := 2.5
const FIRST := 2.0       ## m from the thrown body's COM to the first grunt
## Runs per speed. Each run seeds every ragdoll's random limb spin (the only
## randomness; Jolt is deterministic), so a run is reproducible and the seeds
## cover different tumbles.
const RUNS := {16.0: 6, 12.0: 4}
const RULE_TOL := 0.02
const RULE_TOL_3RD := 0.06
const ARRIVE_TOL := 0.09

var _bowls: Array = []
var _ok := true
var _lane := 0

func _ready() -> void:
	ImpactResolver.bowl_dealt.connect(func(flyer: Node3D, victim: Node3D, speed: float, tier: int, _i: HitInfo) -> void:
		_bowls.append({"flyer": flyer, "victim": victim, "speed": speed, "tier": tier}))
	WorldTestUtil.make_floor(self, 300.0)
	await get_tree().physics_frame
	if not await WorldTestUtil.real_ragdoll_available(self):
		print("[chain] FAIL: real ragdoll unavailable")
		get_tree().quit(1)
		return
	for speed: float in [16.0, 12.0]:
		for run in int(RUNS[speed]):
			await _chain(speed, run)
	print("[chain] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _line(s: String, ok: bool) -> void:
	_ok = _ok and ok
	print("[chain] %s -> %s" % [s, "PASS" if ok else "FAIL"])

func _hv(f: Fighter) -> float:
	var v := f.get_com_velocity()
	return Vector2(v.x, v.z).length()

func _chain(speed: float, run: int) -> void:
	_lane += 1
	var z := _lane * 10.0
	_bowls.clear()
	var thrower := WorldTestUtil.spawn_body(self, Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(FIRST + 1.0, 0.05, z)),
		false, &"player", Fighter.TEAM_PLAYER)
	var body := WorldTestUtil.spawn_body(self, Transform3D(Basis(Vector3.UP, -PI * 0.5), Vector3(FIRST, 0.05, z)), false)
	var line: Array[Fighter] = []
	for k in 3:
		line.append(WorldTestUtil.spawn_body(self, Transform3D(Basis(Vector3.UP, PI * 0.5),
			Vector3(-SPACING * k, 0.05, z)), false))
	for i in 6:
		await get_tree().physics_frame
	for f: Fighter in [body] + line:
		var rng: Variant = f.ragdoll.get(&"_rng") if f.ragdoll else null
		if rng is RandomNumberGenerator:
			(rng as RandomNumberGenerator).seed = 1000 * (run + 1) + line.find(f) + 1
	var a := deg_to_rad(Tuning.THROW_UP_ANGLE)
	var vel := Vector3(-cos(a), sin(a), 0.0) * speed
	body.launch(vel - body.get_com_velocity(), body.get_center_of_mass())
	GameEvents.thrown.emit(thrower, body, vel)
	# Per hit: COM speed in (the last unfrozen tick before the hit) and out
	# (the best of the first ticks after the freeze, while the stored velocity comes back).
	var com_in: Array[float] = []
	var com_out: Array[float] = []
	var last_hv := _hv(body)
	var seen := 0
	var thaw_ticks := 0
	for i in 200:
		await get_tree().physics_frame
		var mine := _bowls.filter(func(b: Dictionary) -> bool: return b["flyer"] == body).size()
		if mine > seen:
			seen = mine
			com_in.append(last_hv)
			com_out.append(0.0)
			thaw_ticks = 0
		if not body.is_frozen():
			var hv := _hv(body)
			if com_out.size() > 0 and thaw_ticks < 6:
				thaw_ticks += 1
				com_out[com_out.size() - 1] = maxf(com_out[com_out.size() - 1], hv)
			last_hv = hv
	var hits: Array = []
	for k in 3:
		var found := {}
		for b: Dictionary in _bowls:
			if b["flyer"] == body and b["victim"] == line[k]:
				found = b
				break
		hits.append(found if not found.is_empty() else {"speed": -1.0, "tier": HitInfo.Tier.NONE})
	var keep := 1.0 - Tuning.BOWL_SPEED_LOSS
	var speeds: Array = hits.map(func(h: Dictionary) -> String: return "%.1f" % h["speed"])
	var tiers: Array = hits.map(func(h: Dictionary) -> StringName: return HitInfo.tier_name(h["tier"]))
	var rules: Array = []
	var need := 3 if speed >= 16.0 else 2
	var rule_ok := com_in.size() >= need
	for k in mini(com_in.size(), need):
		var r := com_out[k] / maxf(com_in[k], 0.01)
		rules.append("%.2f->%.2f (%.3f)" % [com_in[k], com_out[k], r])
		rule_ok = rule_ok and absf(r - keep) <= (RULE_TOL if k < 2 else RULE_TOL_3RD)
	var r2 := float(hits[1]["speed"]) / maxf(float(hits[0]["speed"]), 0.01)
	var r3 := float(hits[2]["speed"]) / maxf(float(hits[1]["speed"]), 0.01)
	var ok: bool = rule_ok and hits[0]["tier"] == HitInfo.Tier.LAUNCH and hits[1]["tier"] == HitInfo.Tier.KNOCKDOWN \
		and absf(r2 - keep) <= ARRIVE_TOL
	var want := "launch, knockdown"
	if speed >= 16.0:
		ok = ok and hits[2]["tier"] == HitInfo.Tier.STAGGER and float(hits[2]["speed"]) >= Tuning.PROJECTILE_MIN_SPEED \
			and r3 <= keep + ARRIVE_TOL
		want = "launch, knockdown, stagger"
	_line("%2.0f m/s run %d: at the victims %s m/s (doc %.1f, %.1f, %.1f), arrival ratios %.2f / %.2f, tiers %s (want %s); COM in->out per hit %s (rule %.2f)" % [
		speed, run + 1, speeds, speed, speed * keep, speed * keep * keep, r2, r3, tiers, want, rules, keep], ok)
	for n in [thrower, body, line[0], line[1], line[2]]:
		if is_instance_valid(n):
			n.queue_free()
	WorldTestUtil.cleanup()
	await get_tree().physics_frame
