extends Node3D
## Arm-drag spike (Upgrade 2 risk: hand-to-bone joints stretching or exploding
## under Jolt at 120 Hz). Grabs a grunt's right forearm and swings it around
## the grabber with a scripted direction turning at 2, 4 ... 12 rad/s (1.5 s
## each, no rate clamp, no swing stop or slip), per variant: hold method (PIN,
## SIX_DOF, PULL), bone velocity clamp, held-limb mass boost. Prints per stage:
## grip stretch (hand to wrist), the ragdoll's own worst joint gap, peak bone
## speeds, COM speed and radius around the grabber, NaN ticks. Then runs the
## shipped setup (PIN, clamp, LimbGrab.ARM_MASS_BOOST, rate clamp
## LimbGrab.SWING_RATE_MAX, safety on) asking for 4, 8 and 12 rad/s.
## Passes when the shipped setup keeps the grip stretch and every ragdoll joint
## gap under 5 cm with no NaN and no bone over 40 m/s.
## User args: `-- all` adds the x4 / x16 boosts; `-- only=A,B` runs those labels.
## Finding (Nov 2026): Jolt never produced NaN or an explosion, even at 12
## rad/s; the failure is stretch. A 1.5 kg forearm on a kinematic hand holding
## 68 kg opens the elbow 15-21 cm once the body flies (>= 6 rad/s, COM 10+ m/s).
## PIN and SIX_DOF behave the same; PULL (scripted velocity) is far worse. A
## hand-to-body velocity rope helped little (COM) or spun the body up to Jolt's
## 47 rad/s cap (shoulder). Making the held limb x8 heavier while gripped
## evens the chain's mass ratios: stretch 1.6-2.7 cm, joint gap 3.6-5.3 cm.
## 30 velocity / 10 position Jolt steps would also help (x4 boost: gap 2-4 cm)
## but cost every ragdoll.
## OWNER: agent G.

const RATES: Array[float] = [2.0, 4.0, 6.0, 8.0, 10.0, 12.0]
const STAGE_TIME := 1.5
const STRETCH_OK := 0.05
const JOINT_OK := 0.05
const EXPLODE_SPEED := 40.0

var _fail: Array[String] = []

func _ready() -> void:
	get_tree().create_timer(240.0, true, false, true).timeout.connect(func() -> void:
		print("FAIL timeout")
		get_tree().quit(1))
	GrabTestUtil.make_floor(self)
	await get_tree().physics_frame
	var summary: Array[String] = []
	# Variant: [label, method, bone velocity clamp, held-limb mass boost]
	var variants: Array = [
		["PIN", LimbGrab.Method.PIN, false, 1.0],
		["PIN+clamp", LimbGrab.Method.PIN, true, 1.0],
		["SIX_DOF+clamp", LimbGrab.Method.SIX_DOF, true, 1.0],
		["PULL+clamp", LimbGrab.Method.PULL, true, 1.0],
		["PIN+clamp+x8", LimbGrab.Method.PIN, true, 8.0],
		["PIN+clamp+x4", LimbGrab.Method.PIN, true, 4.0, true],
		["SIX_DOF+clamp+x8", LimbGrab.Method.SIX_DOF, true, 8.0, true],
		["PIN+clamp+x16", LimbGrab.Method.PIN, true, 16.0, true],
	]
	var only := ""
	var all := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("only="):
			only = a.substr(5)
		elif a == "all":
			all = true
	for v: Array in variants:
		if only != "" and not (v[0] as String) in only.split(","):
			continue
		if only == "" and v.size() > 4 and not all:
			continue
		var rows := await _run(v[1], v[2], RATES, false, v[3])
		for r: Dictionary in rows:
			summary.append(_line(v[0], v[2], r))
	# Shipped configuration: rate clamp and safety on; ask for up to 12 rad/s.
	var shipped := await _run(LimbGrab.Method.PIN, true, [4.0, 8.0, 12.0], true, 0.0)
	print("\n[spike] ---- summary (method, clamp, asked rate) ----")
	for s in summary:
		print(s)
	print("[spike] ---- shipped: PIN, clamp on, arm mass x%.0f, rate clamp %.1f rad/s, safety on ----" % [
		LimbGrab.ARM_MASS_BOOST, LimbGrab.SWING_RATE_MAX])
	for r: Dictionary in shipped:
		print(_line("shipped", true, r))
		if r["stretch_max"] > STRETCH_OK:
			_fail.append("shipped stretch %.3f m at asked %.0f rad/s" % [r["stretch_max"], r["rate"]])
		if r["nan"] > 0:
			_fail.append("shipped NaN at asked %.0f rad/s" % r["rate"])
		if r["lin"] > EXPLODE_SPEED:
			_fail.append("shipped bone speed %.1f m/s" % r["lin"])
		if r["joint"] > JOINT_OK:
			_fail.append("shipped ragdoll joint gap %.3f m (%s)" % [r["joint"], r["joint_bone"]])
	LimbGrab.method = LimbGrab.Method.PIN
	LimbGrab.swing_rate_max = LimbGrab.SWING_RATE_MAX
	LimbGrab.clamp_bones = true
	LimbGrab.mass_boost = 0.0
	LimbGrab.hold_max = LimbGrab.HOLD_MAX
	LimbGrab.safety = true
	TimeDirector.reset()
	if _fail.is_empty():
		print("PASS spike: shipped arm drag holds (stretch < %.0f cm, no NaN, no explosion)" % (STRETCH_OK * 100.0))
		get_tree().quit(0)
	else:
		for f in _fail:
			print("FAIL ", f)
		get_tree().quit(1)

func _line(mname: String, clamp_on: bool, r: Dictionary) -> String:
	return "[spike] %-16s clamp=%-3s w=%4.1f (got %4.1f) | stretch max %.3f mean %.3f m | joint gap %.3f m %-14s | bone %5.1f m/s %5.1f rad/s | COM %4.1f m/s r %.2f m | NaN %d%s" % [
		mname, "on" if clamp_on else "off", r["rate"], r["got_rate"], r["stretch_max"], r["stretch_mean"],
		r["joint"], r["joint_bone"], r["lin"], r["ang"], r["com_speed"], r["com_r"], r["nan"],
		"  ** ENDED: %s" % r["ended"] if r["ended"] != "" else ""]

## One grab, one stage per rate. Returns a row per stage.
func _run(m: int, clamp_on: bool, rates: Array, shipped: bool, boost: float) -> Array:
	var grabber := GrabTestUtil.spawn(self, &"player", Vector3.ZERO, Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var victim := GrabTestUtil.spawn(self, &"grunt", Vector3(0.0, 0.0, -1.0), Vector3.BACK)
	for i in 15:
		await get_tree().physics_frame
	LimbGrab.method = m
	LimbGrab.clamp_bones = clamp_on
	LimbGrab.mass_boost = boost
	LimbGrab.swing_rate_max = LimbGrab.SWING_RATE_MAX if shipped else 100.0
	LimbGrab.safety = shipped
	LimbGrab.hold_max = 100.0
	var lg := LimbGrab.start(grabber, victim, BodyZones.Zone.ARM_R)
	var rows: Array = []
	if lg == null:
		_fail.append("start refused (method %d)" % m)
		grabber.queue_free()
		victim.queue_free()
		await get_tree().physics_frame
		return rows
	var in_yaw := GrabTestUtil.yaw_of(victim.global_position - grabber.global_position)
	var dt := 1.0 / float(Engine.physics_ticks_per_second)
	var ended := ""
	for rate: float in rates:
		var r := {"rate": rate, "stretch_max": 0.0, "stretch_mean": 0.0, "joint": 0.0, "joint_bone": &"",
			"lin": 0.0, "ang": 0.0, "nan": 0, "com_speed": 0.0, "com_r": 0.0, "got_rate": 0.0, "ended": ended}
		var n := 0
		var t := 0.0
		var yaw0 := lg.get_swing_yaw() if lg and is_instance_valid(lg) else 0.0
		while t < STAGE_TIME and ended == "":
			in_yaw += rate * dt
			lg.set_swing_input(GrabTestUtil.yaw_dir(in_yaw))
			await get_tree().physics_frame
			t += dt
			if not is_instance_valid(lg) or not lg.is_active():
				ended = "grip ended at %.2f s into the stage" % t
				break
			if t < 0.3:
				continue   # let the swing settle into the new rate
			var s := lg.get_stretch()
			r["stretch_max"] = maxf(r["stretch_max"], s)
			r["stretch_mean"] += s
			var js := GrabTestUtil.joint_separation(victim)
			if js[0] > r["joint"]:
				r["joint"] = js[0]
				r["joint_bone"] = js[1]
			var sp := GrabTestUtil.bone_speeds(victim)
			r["lin"] = maxf(r["lin"], sp[0])
			r["ang"] = maxf(r["ang"], sp[1])
			if sp[2]:
				r["nan"] += 1
			var v := victim.get_com_velocity()
			r["com_speed"] += Vector2(v.x, v.z).length()
			var c := victim.get_center_of_mass() - grabber.global_position
			r["com_r"] += Vector2(c.x, c.z).length()
			n += 1
		if n > 0:
			r["stretch_mean"] /= n
			r["com_speed"] /= n
			r["com_r"] /= n
		if is_instance_valid(lg):
			r["got_rate"] = (lg.get_swing_yaw() - yaw0) / maxf(t, dt)
		r["ended"] = ended
		rows.append(r)
		if ended != "":
			break
	if is_instance_valid(lg) and lg.is_active():
		lg.drop()
	await get_tree().physics_frame
	grabber.queue_free()
	victim.queue_free()
	for i in 3:
		await get_tree().physics_frame
	return rows
