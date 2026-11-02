extends Node3D
## Round 6 clutter under real flying bodies (agent K): real 70 kg ragdolls
## launched or thrown (GameEvents.thrown, as Carry does) into every clutter
## kind, judged by the real ImpactResolver (WorldTags.breakable_of):
## - at E = 1.6 x its break energy the body breaks it (wall_decided "break",
##   furniture_broken by that body), keeps sqrt(1 - absorb) of its speed (its
##   horizontal speed just before vs right after the decision) and takes
##   Tuning.FURNITURE_BODY_DAMAGE (5);
## - at E = 0.7 x it holds (crack; light kinds come loose) and the body takes
##   no break damage;
## - after every break no piece moves faster than FurnitureKit.PIECE_GUARD_SHARE
##   x the body's speed for PIECE_WATCH s (chairs broken CHAIR_RUNS times by a
##   6 m/s launch: the light chair back is the piece that used to spike);
## - one thrown body (12 m/s) breaks two things in a line: a table, then a glass pane;
## - Sifu 3's coffee table: a P5 launch (Power.launch_velocity: 6 m/s at 30
##   degrees) from 1.6 m comes down on a coffee table or a table and breaks it
##   (a body landing on low clutter crushes it with its whole speed); a sofa
##   (1,500 J) holds such a landing (crack).

const START := 1.2        ## m from the object's face to the body's centre
const SPEED_TOL := 0.05   ## share
## s after a break the pieces' speed is watched (the guard's time; later,
## gravity alone may take a falling piece past the cap): none may pass
## FurnitureKit.PIECE_GUARD_SHARE x the body's speed (at least PIECE_GUARD_MIN).
const PIECE_WATCH := FurnitureKit.PIECE_GUARD_TIME
const CHAIR_RUNS := 8

var _ok := true
var _decisions: Array = []
var _breaks: Array = []
var _watch: Fighter = null
var _last_h := 0.0
var _before := {}         ## wall id -> horizontal speed the tick before its decision
var _after := {}          ## wall id -> horizontal speed right after it
var _last_v := 0.0        ## the watched body's full speed last tick
var _break_v := 0.0       ## ...at the last break decision
var _track: Array = []    ## pieces of the last break, sampled for PIECE_WATCH s
var _track_t := 0.0
var _max_piece := 0.0

func _line(s: String, ok: bool) -> void:
	_ok = _ok and ok
	print("[bodies] %s -> %s" % [s, "PASS" if ok else "FAIL"])

func _ready() -> void:
	ImpactResolver.wall_decided.connect(_on_decided)
	ClutterTestUtil.record_breaks(_breaks)
	ClutterTestUtil.make_floor(self, 600.0)
	await ClutterTestUtil.frames(self, 2)
	if not await _real_ragdoll():
		_line("real ragdoll unavailable", false)
		get_tree().quit(1)
		return
	var lane := 0
	for kind: StringName in Tuning.FURNITURE:
		lane += 1
		await _lane(kind, 1.6, lane * 10.0)
		lane += 1
		await _lane(kind, 0.7, lane * 10.0)
	await _two_in_line(-20.0)
	await _chair_stress(-130.0)
	await _kicked_onto(&"coffee_table", 5.0, -40.0, 1.6)
	await _kicked_onto(&"table", 5.0, -55.0, 1.6)
	await _kicked_onto(&"sofa", 5.0, -70.0, 1.6)
	await _kicked_onto(&"coffee_table", 5.0, -85.0, 2.6)
	await _kicked_onto(&"coffee_table", 5.0, -100.0, 3.2)
	await _kicked_onto(&"coffee_table", 7.0, -115.0, 3.5)
	print("[bodies] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _physics_process(delta: float) -> void:
	if _watch != null and is_instance_valid(_watch):
		var v := _watch.get_com_velocity()
		_last_h = Vector2(v.x, v.z).length()
		_last_v = v.length()
	if _track_t > 0.0:
		_track_t -= delta
		for i in _track.size():
			var p: Variant = _track[i]
			if is_instance_valid(p):
				_max_piece = maxf(_max_piece, (p as RigidBody3D).linear_velocity.length())

func _on_decided(f: Node3D, w: Node3D, outcome: StringName, energy: float, _p: Vector3) -> void:
	_decisions.append({"fighter": f, "wall": w, "outcome": outcome, "energy": energy})
	if f == _watch:
		var v := (f as Fighter).get_com_velocity()
		_before[w.get_instance_id()] = _last_h
		_after[w.get_instance_id()] = Vector2(v.x, v.z).length()
		if outcome == &"break":
			var chunks: Variant = w.get(&"last_chunks")
			_track = (chunks as Array).duplicate() if chunks is Array else []
			_track_t = PIECE_WATCH
			_max_piece = 0.0
			_break_v = _last_v

func _real_ragdoll() -> bool:
	var f := ClutterTestUtil.spawn_body(self, Vector3(0, 0.05, -60))
	await ClutterTestUtil.frames(self, 2)
	f.launch(Vector3(0, 1, 0), f.get_center_of_mass())
	await ClutterTestUtil.frames(self, 3)
	var ok := f.get_state() == RagdollController.State.LAUNCHED
	f.queue_free()
	ClutterTestUtil.cleanup()
	await ClutterTestUtil.frames(self, 2)
	return ok

## A body sent at the object's face with E = share x its break energy.
func _lane(kind: StringName, share: float, z: float) -> void:
	_decisions.clear()
	_breaks.clear()
	_before.clear()
	_after.clear()
	var obj := ClutterTestUtil.make(self, kind, Vector3(0, 0, z), PI * 0.5)
	await ClutterTestUtil.frames(self, 1)
	var face_x := obj.get_box_transform().origin.x + obj.get_half_extent_along(Vector3.RIGHT)
	var body := ClutterTestUtil.spawn_body(self, Vector3(face_x + START, 0.05, z), -PI * 0.5)
	await ClutterTestUtil.frames(self, 8)
	var b := float(Tuning.FURNITURE[kind]["break"])
	var m := body.get_total_mass()
	var speed := sqrt(2.0 * share * b / m)
	var hp0 := body.hp
	_watch = body
	body.launch(Vector3(-speed, 0.6, 0), body.get_center_of_mass())
	await ClutterTestUtil.wait_game(self, 0.9)
	var hp_mid := body.hp   # breaking (or cracking) is the only damage a flight here can take
	_watch = null
	var mine := _decisions.filter(func(d: Dictionary) -> bool: return d["wall"] == obj and d["fighter"] == body)
	var outcome: StringName = mine[0]["outcome"] if mine.size() > 0 else &"none"
	var e: float = mine[0]["energy"] if mine.size() > 0 else -1.0
	var ev := _breaks.filter(func(x: Dictionary) -> bool: return x["node"] == obj)
	var absorb := float(Tuning.FURNITURE[kind]["absorb"])
	var want := sqrt(1.0 - absorb)
	var id := obj.get_instance_id()
	var ratio := float(_after.get(id, 0.0)) / maxf(float(_before.get(id, 0.0)), 0.01)
	var dmg := hp0 - hp_mid
	var ok := false
	if share >= 1.0:
		var cap := maxf(FurnitureKit.PIECE_GUARD_SHARE * _break_v, FurnitureKit.PIECE_GUARD_MIN)
		ok = outcome == &"break" and obj.is_broken and ev.size() == 1 and ev[0]["by"] == body \
			and absf(ratio - want) <= SPEED_TOL and is_equal_approx(dmg, Tuning.FURNITURE_BODY_DAMAGE) \
			and _max_piece <= cap + 0.05
		_line("%-12s %.1f m/s, E=%5.0f J (%.1fx break) -> %-6s by body=%s; speed kept %.3f (want sqrt(1-%.2f) = %.3f); damage %.0f (want %.0f); fastest piece %.1f m/s (cap %.1f)" % [
			kind, speed, e, e / b, outcome, ev.size() == 1 and ev[0]["by"] == body, ratio, absorb, want, dmg,
			Tuning.FURNITURE_BODY_DAMAGE, _max_piece, cap], ok)
	else:
		ok = outcome == &"crack" and not obj.is_broken and ev.is_empty() and dmg < 0.01 \
			and obj.is_loose == (kind in Furniture.LOOSE_KINDS)
		_line("%-12s %.1f m/s, E=%5.0f J (%.1fx break) -> %-6s holds=%s%s; damage %.0f" % [
			kind, speed, e, e / b, outcome, not obj.is_broken, " (came loose)" if obj.is_loose else "", dmg], ok)
	for n in [obj, body]:
		if is_instance_valid(n):
			n.queue_free()
	if is_instance_valid(obj) and obj.loose_body != null and is_instance_valid(obj.loose_body):
		obj.loose_body.queue_free()
	ClutterTestUtil.cleanup()
	await ClutterTestUtil.frames(self, 2)

## One thrown body breaks a table, then a glass pane behind it.
func _two_in_line(z: float) -> void:
	_decisions.clear()
	_breaks.clear()
	var table := ClutterTestUtil.make(self, &"table", Vector3(0, 0, z), PI * 0.5)
	var glass := ClutterTestUtil.make(self, &"glass", Vector3(-2.2, 0, z), PI * 0.5)
	await ClutterTestUtil.frames(self, 1)
	var face_x := table.get_box_transform().origin.x + table.get_half_extent_along(Vector3.RIGHT)
	var thrower := ClutterTestUtil.spawn_body(self, Vector3(face_x + START + 1.4, 0.05, z + 1.5), 0.0, &"player",
		Fighter.TEAM_PLAYER)
	var body := ClutterTestUtil.spawn_body(self, Vector3(face_x + START, 0.05, z), -PI * 0.5)
	await ClutterTestUtil.frames(self, 8)
	var v := Vector3(-12.0, 1.0, 0)
	body.launch(v, body.get_center_of_mass())
	GameEvents.thrown.emit(thrower, body, v)
	await ClutterTestUtil.wait_game(self, 1.0)
	var got: Array = []
	for d: Dictionary in _decisions:
		if d["fighter"] == body:
			got.append("%s %s %.0f J" % [(d["wall"] as Node).name, d["outcome"], d["energy"]])
	var by_body := _breaks.filter(func(x: Dictionary) -> bool: return x["by"] == body)
	var ok := table.is_broken and glass.is_broken and by_body.size() == 2
	_line("one thrown body (12 m/s) through a table then a glass pane 2.2 m behind: %s; broken by it %d (want 2)" % [
		got, by_body.size()], ok)
	for n in [table, glass, thrower, body]:
		if is_instance_valid(n):
			n.queue_free()
	ClutterTestUtil.cleanup()
	await ClutterTestUtil.frames(self, 2)

## A launch at power `p` toward low clutter `kind` whose near edge is 1.6 m off.
func _kicked_onto(kind: StringName, p: float, z: float, gap: float) -> void:
	_decisions.clear()
	_breaks.clear()
	var obj := ClutterTestUtil.make(self, kind, Vector3(0, 0, z), PI * 0.5)
	await ClutterTestUtil.frames(self, 1)
	var face_x := obj.get_box_transform().origin.x + obj.get_half_extent_along(Vector3.RIGHT)
	var body := ClutterTestUtil.spawn_body(self, Vector3(face_x + gap, 0.05, z), -PI * 0.5)
	await ClutterTestUtil.frames(self, 8)
	var v := Power.launch_velocity(p, Vector3.LEFT, body.get_total_mass())
	body.launch(v, body.get_center_of_mass())
	await ClutterTestUtil.wait_game(self, 1.5)
	var mine := _decisions.filter(func(d: Dictionary) -> bool: return d["wall"] == obj and d["fighter"] == body)
	var ev := _breaks.filter(func(x: Dictionary) -> bool: return x["node"] == obj)
	var b := float(Tuning.FURNITURE[kind]["break"])
	var want_break := b <= 0.5 * body.get_total_mass() * v.length_squared()
	var outcome: StringName = mine[0]["outcome"] if mine.size() > 0 else &"none"
	var ok := obj.is_broken == want_break and (ev.size() == 1) == want_break and mine.size() >= 1
	_line("P%.0f launch (%.1f m/s at %.0f deg) from %.1f m onto a %s (break %.0f J): %s at E=%.0f J (event %.0f J) -> broken=%s (want %s)" % [
		p, v.length(), rad_to_deg(atan2(v.y, Vector2(v.x, v.z).length())), gap, kind, b, outcome,
		float(mine[0]["energy"]) if mine.size() > 0 else -1.0, float(ev[0]["energy"]) if ev.size() > 0 else -1.0,
		obj.is_broken, want_break], ok)
	for n in [obj, body]:
		if is_instance_valid(n):
			n.queue_free()
	ClutterTestUtil.cleanup()
	await ClutterTestUtil.frames(self, 2)

## A P5 launch (6 m/s) into a chair, CHAIR_RUNS times: the fastest piece each time.
func _chair_stress(z0: float) -> void:
	var worst := 0.0
	var speeds: Array = []
	var ok := true
	for k in CHAIR_RUNS:
		var z := z0 - k * 8.0
		var chair := ClutterTestUtil.make(self, &"chair", Vector3(0, 0, z), PI * 0.5 + k * 0.4)
		await ClutterTestUtil.frames(self, 1)
		var face_x := chair.get_box_transform().origin.x + chair.get_half_extent_along(Vector3.RIGHT)
		var body := ClutterTestUtil.spawn_body(self, Vector3(face_x + 1.4, 0.05, z), -PI * 0.5)
		await ClutterTestUtil.frames(self, 8)
		_watch = body
		_max_piece = 0.0
		_track_t = 0.0
		body.launch(Power.launch_velocity(5.0, Vector3.LEFT, body.get_total_mass()), body.get_center_of_mass())
		await ClutterTestUtil.wait_game(self, 0.8)
		_watch = null
		var cap := maxf(FurnitureKit.PIECE_GUARD_SHARE * _break_v, FurnitureKit.PIECE_GUARD_MIN)
		speeds.append("%.1f/%.1f" % [_max_piece, cap])
		worst = maxf(worst, _max_piece / cap)
		ok = ok and chair.is_broken and _max_piece <= cap + 0.05
		for n in [chair, body]:
			if is_instance_valid(n):
				n.queue_free()
		ClutterTestUtil.cleanup()
		await ClutterTestUtil.frames(self, 2)
	_line("P5 launch into a chair x%d: fastest piece / cap per run (m/s) %s; worst %.2f of the cap" % [
		CHAIR_RUNS, speeds, worst], ok)
