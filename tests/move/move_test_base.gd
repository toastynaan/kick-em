extends Node3D
## Shared helpers for tests/move/* (agent M). Each test extends this, overrides
## run(), and calls done(). Prints "PASS ..." / "FAIL ..." per check, the
## measured numbers, and quits 0 / 1.
## OWNER: agent M (movement).
##
## Two players: spawn_player() is controller-less (it gets a Traversal; tests
## write move_input and call combat.press()/release() and
## traversal.on_jump_pressed() directly, so they do not depend on input
## routing), and spawn_real_player() has the game's PlayerController reading
## Input actions (the real path: Input -> PlayerController -> InputInterpreter
## -> CombatController -> Traversal). Geometry is built here (floor, low wall,
## platform, runnable wall, stairs), so the checks do not wait on the Yard.

const CarryDouble := preload("res://tests/move/carry_double.gd")

var failures: Array[String] = []
var events: Array = []  ## [name, args, real time]
var _timeout := 120.0
var _checks := 0
var _completed := false
var _saved_cap := 8.0
var _saved_ram := 0

func _ready() -> void:
	_saved_cap = Tuning.debug_speed_cap
	_saved_ram = Tuning.debug_ram_level
	make_box(Vector3(0.0, -0.5, 0.0), Vector3(400.0, 1.0, 400.0), "Floor")
	_capture_events()
	get_tree().create_timer(_timeout, true, false, true).timeout.connect(func() -> void:
		print("FAIL timeout after %.0f s" % _timeout)
		_restore()
		get_tree().quit(1))
	await get_tree().physics_frame
	@warning_ignore("redundant_await")
	await run()
	if not _completed:
		failures.append("run() did not complete (script error or early abort)")
		print("  FAIL run() did not complete")
	finish()

## Override; end with done().
func run() -> void:
	done()

func done() -> void:
	_completed = true

# --- Geometry -------------------------------------------------------------------
## A static box (centre, size). layer WORLD unless given.
func make_box(center: Vector3, size: Vector3, box_name := "Box", layer := Layers.WORLD) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = box_name
	body.collision_layer = layer
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	body.add_child(cs)
	add_child(body)
	body.global_position = center
	return body

## A wall of `height` across X at z = `z` (its near face toward +Z), `depth` thick.
func make_wall_across(z: float, height: float, depth := 0.3, width := 6.0, x := 0.0) -> StaticBody3D:
	return make_box(Vector3(x, height * 0.5, z - depth * 0.5), Vector3(width, height, depth), "Wall%.1f" % height)

## A flight of `steps` stairs rising toward -Z from z = `z0` at x (rise / run
## per step), then a `landing` m long. Returns the top's height.
func make_stairs(x: float, z0: float, steps: int, rise := 0.25, run := 0.3, width := 1.6, landing := 2.0) -> float:
	for k in steps:
		var h := rise * (k + 1)
		make_box(Vector3(x, h * 0.5, z0 - run * (k + 0.5)), Vector3(width, h, run), "Stair%d" % k)
	var top := rise * steps
	make_box(Vector3(x, top * 0.5, z0 - run * steps - landing * 0.5), Vector3(width, top, landing), "Landing")
	return top

## An 8 m runnable wall along Z at x = `x` (face toward -X if side > 0, i.e. the
## wall is on the runner's right when running toward -Z).
func make_runnable_wall(x: float, z0: float, z1: float, height := 4.0, thick := 0.4) -> StaticBody3D:
	var len := absf(z1 - z0)
	var b := make_box(Vector3(x, height * 0.5, (z0 + z1) * 0.5), Vector3(thick, height, len), "RunWall")
	b.add_to_group(&"runnable")
	return b

# --- Fighters -----------------------------------------------------------------------
## A controller-less player at `pos` facing `facing` (it gets a Traversal).
func spawn_player(pos := Vector3.ZERO, facing := Vector3.FORWARD) -> Fighter:
	var xf := Transform3D(Basis.looking_at(facing.normalized(), Vector3.UP), pos)
	var f := FighterFactory.spawn_dummy(self, &"player", xf, Fighter.TEAM_PLAYER)
	f.name = "Player"
	return f

## The real player: FighterFactory's PlayerController reads Input actions (the
## real game path: Input -> PlayerController -> CombatController / Traversal).
## With no camera rig, move_forward is -Z and move_right +X.
func spawn_real_player(pos := Vector3.ZERO, facing := Vector3.FORWARD) -> Fighter:
	var f := FighterFactory.spawn_player(self, Transform3D(Basis.looking_at(facing.normalized(), Vector3.UP), pos))
	f.name = "Player"
	return f

func hold(action: StringName, strength := 1.0) -> void:
	Input.action_press(action, strength)

func let_go(action: StringName) -> void:
	Input.action_release(action)

func release_all_input() -> void:
	for a: StringName in Controls.ACTIONS:
		if InputMap.has_action(a):
			Input.action_release(a)

## A press held for `n` ticks, then released.
func tap(action: StringName, n := 2) -> void:
	Input.action_press(action)
	await ticks(n)
	Input.action_release(action)

## A physical key event through Input (the real binding path: Controls maps
## physical keycodes to actions).
func key(code: Key, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.keycode = code
	ev.pressed = pressed
	Input.parse_input_event(ev)

## A key held for `n` ticks, then released.
func tap_key(code: Key, n := 3) -> void:
	key(code, true)
	await ticks(n)
	key(code, false)

## Hold the real stick along the flat direction `d` (camera-free axes: -Z forward, +X right).
func stick(d: Vector3) -> void:
	for a: StringName in [&"move_left", &"move_right", &"move_forward", &"move_back"]:
		let_go(a)
	if d.x > 0.01:
		hold(&"move_right", d.x)
	elif d.x < -0.01:
		hold(&"move_left", -d.x)
	if d.z > 0.01:
		hold(&"move_back", d.z)
	elif d.z < -0.01:
		hold(&"move_forward", -d.z)

func spawn_enemy(archetype: StringName, pos: Vector3, facing := Vector3.BACK) -> Fighter:
	var xf := Transform3D(Basis.looking_at(facing.normalized(), Vector3.UP), pos)
	return FighterFactory.spawn_dummy(self, archetype, xf, Fighter.TEAM_ENEMY)

func hspeed(f: Fighter) -> float:
	return Vector2(f.velocity.x, f.velocity.z).length()

func dash_down(p: Fighter) -> void:
	p.combat.press(CombatController.Action.DASH)

func dash_up(p: Fighter) -> void:
	p.combat.release(CombatController.Action.DASH)

## Hold Dash with the stick along `dir` until the player runs at the cap (or `max_ticks`).
func sprint_to_cap(p: Fighter, dir: Vector3, max_ticks := 240) -> bool:
	p.move_input = dir.normalized()
	dash_down(p)
	return await wait_until(func() -> bool:
		return p.traversal.sprint_charge >= 0.999, max_ticks)

## Swap in a Carry test double (holding a body with `mult` walking share, or
## a prop). Returns it; undo with remove_carry_double().
func install_carry_double(p: Fighter, mult := 0.7, prop := false) -> Carry:
	var d: Carry = CarryDouble.new()
	d.name = "CarryDouble"
	d.set(&"real", p.carry)
	d.set(&"move_mult", mult)
	d.set(&"prop", prop)
	p.add_child(d)
	d.setup(p)
	p.carry = d
	return d

func remove_carry_double(p: Fighter, d: Carry) -> void:
	var real: Carry = d.get(&"real")
	if real != null:
		p.carry = real
	d.queue_free()

func ticks(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

## Step until `cond` is true or `max_ticks` pass. Returns cond().
func wait_until(cond: Callable, max_ticks := 360) -> bool:
	for i in max_ticks:
		if cond.call():
			return true
		await get_tree().physics_frame
	return cond.call()

## Let a fighter come to rest standing (after a test step).
func settle(p: Fighter, n := 30) -> void:
	p.move_input = Vector3.ZERO
	if p.traversal != null and p.traversal.is_driving():
		p.traversal.set_drive_speed(0.0)
		p.traversal.end_drive()
	if p.traversal != null and p.traversal.is_dash_held():
		dash_up(p)
	await ticks(n)
	if p.is_down() or not p.can_act():
		await wait_until(func() -> bool: return not p.is_down() and p.can_act(), 900)

## Put a fighter at `pos` facing `facing`, at rest.
func place(p: Fighter, pos: Vector3, facing := Vector3.FORWARD) -> void:
	p.global_position = pos
	p.snap_facing(facing)
	p.velocity = Vector3.ZERO
	p.reset_physics_interpolation()
	await ticks(4)

# --- Parkour speed metric -----------------------------------------------------------
## Speed kept by each parkour move: from its trigger (the speed on the tick
## before the curve starts) to 0.3 s after the player is back on the ground (or
## the next move's trigger), the lowest horizontal speed. Call parkour_track()
## every tick of a run; read parkour_moves (each {kind, v, lo, keep}).
var parkour_moves: Array = []
var _pm_prev_kind: StringName = &""
var _pm_prev_speed := 0.0
var _pm_open := {}
var _pm_ground := 0.0

func parkour_reset() -> void:
	parkour_moves.clear()
	_pm_open = {}
	_pm_prev_kind = &""

func parkour_track(f: Fighter) -> void:
	var k := f.traversal.get_parkour_kind()
	var v := Vector2(f.velocity.x, f.velocity.z).length()
	if k != &"" and _pm_prev_kind == &"":
		_parkour_close()
		_pm_open = {"kind": k, "v": _pm_prev_speed, "lo": minf(v, _pm_prev_speed)}
		_pm_ground = 0.0
	elif not _pm_open.is_empty():
		_pm_open["lo"] = minf(float(_pm_open["lo"]), v)
		if k == &"" and not f.traversal.is_airborne():
			_pm_ground += 1.0 / 120.0
			if _pm_ground >= 0.3:
				_parkour_close()
	_pm_prev_kind = k
	# The reference is run speed: a dodge's burst above the cap is not (Round 7;
	# parkour starts at the cap at most, like the Round 5 dash the dodge replaces).
	_pm_prev_speed = minf(v, f.traversal.get_speed_cap())

func _parkour_close() -> void:
	if _pm_open.is_empty():
		return
	_pm_open["keep"] = float(_pm_open["lo"]) / maxf(float(_pm_open["v"]), 0.01)
	parkour_moves.append(_pm_open)
	_pm_open = {}

## Closes the last move and checks every step kept 100% and every vault >= 90%.
func parkour_finish() -> Array:
	_parkour_close()
	return parkour_moves

static func parkour_ok(moves: Array) -> bool:
	for m: Dictionary in moves:
		var need := 0.999 if m["kind"] == &"step" else (Tuning.VAULT_KEEP - 0.001 if m["kind"] == &"vault" else 0.0)
		if float(m["keep"]) < need:
			return false
	return true

static func parkour_text(moves: Array) -> String:
	var out := []
	for m: Dictionary in moves:
		out.append("%s %.2f->%.2f (%.1f%%)" % [m["kind"], m["v"], m["lo"], float(m["keep"]) * 100.0])
	return ", ".join(out)

# --- Events -------------------------------------------------------------------------
func _capture_events() -> void:
	for sig: StringName in [&"sprint_started", &"sprint_ended", &"footstep", &"parkour",
			&"wall_run_started", &"wall_run_step", &"wall_run_ended", &"landing", &"shockwave",
			&"rammed", &"jumped", &"landed", &"hit_landed", &"fighter_launched", &"stumbled",
			&"strike_started", &"dodged", &"react_started"]:
		if not GameEvents.has_signal(sig):
			continue
		var s := sig
		GameEvents.connect(s, func(a = null, b = null, c = null, d = null, e = null, f = null) -> void:
			events.append([s, [a, b, c, d, e, f], TimeDirector.now()]))

func count_events(what: StringName) -> int:
	var n := 0
	for e in events:
		if e[0] == what:
			n += 1
	return n

func events_of(what: StringName) -> Array:
	var out: Array = []
	for e in events:
		if e[0] == what:
			out.append(e[1])
	return out

func last_event(what: StringName) -> Array:
	for i in range(events.size() - 1, -1, -1):
		if events[i][0] == what:
			return events[i][1]
	return []

## Real time of the last `what` event (-1 when none).
func last_event_time(what: StringName) -> float:
	for i in range(events.size() - 1, -1, -1):
		if events[i][0] == what:
			return events[i][2]
	return -1.0

func clear_events() -> void:
	events.clear()

# --- Checks -------------------------------------------------------------------------
func check(cond: bool, msg: String) -> void:
	_checks += 1
	if cond:
		print("  PASS ", msg)
	else:
		print("  FAIL ", msg)
		failures.append(msg)

func near(a: float, b: float, tol: float) -> bool:
	return absf(a - b) <= tol

static func yaw_of(v: Vector3) -> float:
	return atan2(-v.x, -v.z)

func _restore() -> void:
	Tuning.debug_speed_cap = _saved_cap
	Tuning.debug_ram_level = _saved_ram
	Engine.time_scale = 1.0

func finish() -> void:
	release_all_input()
	_restore()
	if TimeDirector.has_method(&"reset"):
		TimeDirector.reset()
	if failures.is_empty() and _checks == 0:
		failures.append("no checks ran")
	if failures.is_empty():
		print("RESULT PASS ", name)
		get_tree().quit(0)
	else:
		print("RESULT FAIL ", name, " ", failures)
		get_tree().quit(1)
