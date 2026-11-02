extends "res://tests/move/move_test_base.gd"
## Round 6 acceptance (M): "Parkour in the new Yard: low clutter vaults, tall
## clutter blocks walking", on K's real clutter layout in D's real Yard, through
## the real game path (PlayerController reading Input, Dash held).
## For every courtyard clutter item: an approach direction whose run-up and
## landing are clear of everything else is found (items with none are listed as
## skipped). Low static items (box top 1.2 m or under, not glass / cardboard)
## are sprinted at: each must be stepped or vaulted with no dead stop. Tall
## items (shelves, glass panes) are walked into: each must block. Glass and
## cardboard are also sprinted through (K smashes them): the speed kept is logged.

## m of clear run-up tried for a sprint (the longest that fits), and for a walk.
const RUN_UPS: Array[float] = [6.0, 5.0, 4.0, 3.0, 2.5]
const WALK_RUN_UP := 1.5  ## walking is at full speed within ~0.3 m
const LAND := 2.8          ## m clear of structure beyond the item: the 0.3 s after landing at speed (other clutter there is fine)

var yard: YardBuilder
var p: Fighter
var _clutter: Array = []
var _run_up := 6.0
var _q := PhysicsShapeQueryParameters3D.new()
var _shape := CapsuleShape3D.new()

func _init() -> void:
	_timeout = 1500.0

func run() -> void:
	for c in get_children():
		if c is StaticBody3D and c.name == "Floor":
			c.queue_free()
	yard = YardBuilder.new()
	yard.name = "Yard"
	add_child(yard)
	yard.build()
	await ticks(5)
	p = spawn_real_player(Vector3(0.0, 0.05, 6.0))
	await ticks(30)
	_shape.radius = Fighter.CAPSULE_RADIUS
	_shape.height = Fighter.CAPSULE_HEIGHT
	_q.shape = _shape
	_q.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE | Layers.CAPSULE
	var items := ClutterLayout.get_courtyard_items(yard)
	# Low clutter beyond an item is more parkour (a chain); tall clutter (a
	# shelf, a pane) is a wall until it breaks (Round 6 rules), like structure.
	_clutter = []
	for it in ClutterLayout.get_items(yard):
		var it_top := it.get_box_transform().origin.y + it.size.y * 0.5
		if (not it.get_spec().tall and it_top <= Tuning.VAULT_MAX + 0.01 and it.kind != &"glass") \
				or it.kind in Tuning.RUN_THROUGH_KINDS:
			_clutter.append(it)  # glass and cardboard past it: a sprint smashes them
	for crate in yard.get_parkour_features()["crates"]:
		_clutter.append(crate)  # D's 1.1 m crates vault like low clutter
	for n in yard.find_children("LowWall_*", "", true, false):
		if n is CollisionObject3D and n.has_meta(&"low_wall"):
			_clutter.append(n)  # D's 0.9 m low walls: a speed vault, a chain
	print("  courtyard clutter: %d items" % items.size())
	check(items.size() >= Tuning.CLUTTER_MIN_COUNT, "K's courtyard clutter is in (%d items)" % items.size())
	var low_done := 0
	var low_ok := 0
	var tall_done := 0
	var tall_ok := 0
	var through := []
	var skipped := []
	var gone := []
	# Glass and cardboard first: a later item's run (a chain past it) would
	# smash them before their own turn.
	var order: Array = items.filter(func(it: Furniture) -> bool: return it.kind in Tuning.RUN_THROUGH_KINDS)
	order.append_array(items.filter(func(it: Furniture) -> bool: return not it.kind in Tuning.RUN_THROUGH_KINDS))
	for f: Furniture in order:
		if not is_instance_valid(f):
			continue
		if f.is_broken or f.is_loose:
			# Broken by an earlier run through it, or loose (shoved, not parkour).
			gone.append("%s@(%.1f,%.1f) %s" % [f.kind, f.global_position.x, f.global_position.z, "broken" if f.is_broken else "loose"])
			continue
		var spec := f.get_spec()
		var top := f.get_box_transform().origin.y + f.size.y * 0.5
		var run_through := f.kind in Tuning.RUN_THROUGH_KINDS
		var tall := spec.tall or top > Tuning.VAULT_MAX + 0.01 or f.kind == &"glass"
		var app := _clear_approach(f, not tall or run_through, [WALK_RUN_UP] if tall and not run_through else RUN_UPS,
			[0.0] if run_through else [0.0, -0.9, 0.9])
		var dir: Vector3 = app[0]
		_run_up = app[1]
		if dir == Vector3.ZERO:
			skipped.append("%s@(%.1f,%.1f)" % [f.kind, f.global_position.x, f.global_position.z])
			continue
		if f.kind == &"glass":
			# Glass is tall: walking into it (square to the pane) blocks; a sprint smashes it.
			var wapp := _square_approach(f)
			if wapp[0] != Vector3.ZERO:
				_run_up = wapp[1]
				tall_done += 1
				if await _walk_into(f, wapp[0], top):
					tall_ok += 1
				_run_up = app[1]
		if run_through:
			through.append(await _sprint_through(f, dir))
		elif tall:
			var sq := _square_approach(f)
			if sq[0] == Vector3.ZERO:
				skipped.append("%s@(%.1f,%.1f) walk" % [f.kind, f.global_position.x, f.global_position.z])
				continue
			_run_up = sq[1]
			tall_done += 1
			if await _walk_into(f, sq[0], top):
				tall_ok += 1
		else:
			low_done += 1
			if await _sprint_over(f, dir, top):
				low_ok += 1
	print("  low items: %d / %d crossed with no dead stop; tall items: %d / %d block walking; run-through: %s; skipped (no clear approach): %s; not run (broken or loose): %s" % [
		low_ok, low_done, tall_ok, tall_done, through, skipped, gone])
	check(low_done >= 8 and low_ok == low_done,
		"every low clutter item is stepped (100%%) or vaulted (>= 90%%) at a sprint, never stopped (%d / %d)" % [low_ok, low_done])
	check(skipped.is_empty(), "every courtyard clutter item has a clear approach from some angle (skipped %d)" % skipped.size())
	check(tall_done >= 2 and tall_ok == tall_done, "every tall clutter item tried blocks walking (%d / %d)" % [tall_ok, tall_done])
	done()

## A horizontal direction to approach `f` along: a clear run-up and (when
## `need_landing`) clear floor past it along each lane in `lanes` (m to the
## side), ignoring `f` itself. ZERO when none. A run-through keeps its line
## (one lane); a vault may land up to 0.9 m to a side.
func _clear_approach(f: Furniture, need_landing: bool, run_ups: Array, lanes: Array) -> Array:
	var c := f.get_box_transform().origin
	c.y = 0.0
	for run_up: float in run_ups:
		var best := Vector3.ZERO
		var best_score := -INF
		for i in 32:
			var a := TAU * i / 32.0
			var d := Vector3(sin(a), 0.0, cos(a))
			var h := f.get_half_extent_along(d)
			var start := c - d * (h + run_up)
			var stop := c - d * (h + 0.45)
			if not _sweep_clear(start, stop, [f]):
				continue
			# Past it only structure and tall clutter must leave room: low
			# clutter and low walls there are more parkour (a chain), glass
			# and cardboard smash at a sprint: not a reason to skip.
			# ...across the band a landing beside a fighter or a chained
			# landing may take (VAULT_SIDE_OFFSETS reach 0.9 m either side).
			var side := d.cross(Vector3.UP).normalized()
			var room := true
			if need_landing:
				for off: float in lanes:
					if not _sweep_clear(c + d * (h + 0.45) + side * off, c + d * (h + LAND) + side * off, _clutter):
						room = false
						break
			if not room:
				continue
			var score := -start.length()  # prefer run-ups from the open middle
			if score > best_score:
				best_score = score
				best = d
		if best != Vector3.ZERO:
			return [best, run_up]
	return [Vector3.ZERO, 0.0]

## A clear walking approach square to the item's broad face (along its
## thinnest horizontal axis), either side. [direction, run-up] or [ZERO, 0].
func _square_approach(f: Furniture) -> Array:
	var b := f.get_box_transform().basis
	var axis := b.x.normalized() if f.size.x < f.size.z else b.z.normalized()
	axis.y = 0.0
	axis = axis.normalized()
	var c := f.get_box_transform().origin
	c.y = 0.0
	for d: Vector3 in [axis, -axis]:
		var h := f.get_half_extent_along(d)
		if _sweep_clear(c - d * (h + WALK_RUN_UP), c - d * (h + 0.45), [f]):
			return [d, WALK_RUN_UP]
	return [Vector3.ZERO, 0.0]

## The player's capsule moves from `a` to `b` (feet, a little off the floor)
## without touching anything but `ignore` (and the player).
func _sweep_clear(a: Vector3, b: Vector3, ignore: Array) -> bool:
	var ex: Array[RID] = [p.get_rid()]
	for n in ignore:
		ex.append((n as CollisionObject3D).get_rid())
	_q.exclude = ex
	_q.transform = Transform3D(Basis(), a + Vector3.UP * (Fighter.CAPSULE_HEIGHT * 0.5 + 0.06))
	var space := get_world_3d().direct_space_state
	if not space.intersect_shape(_q, 1).is_empty():
		return false
	_q.motion = b - a
	var r := space.cast_motion(_q)
	_q.motion = Vector3.ZERO
	return r.size() > 0 and r[0] >= 0.999

## Hold the stick along `d` (the real input: camera-free axes, -Z forward).
func _stick(d: Vector3) -> void:
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

func _start(f: Furniture, d: Vector3) -> Vector3:
	release_all_input()
	await settle(p, 10)
	var c := f.get_box_transform().origin
	c.y = 0.0
	var h := f.get_half_extent_along(d)
	p.global_position = c - d * (h + _run_up) + Vector3.UP * 0.05
	p.snap_facing(d)
	p.velocity = Vector3.ZERO
	await ticks(8)
	return c

func _sprint_over(f: Furniture, d: Vector3, top: float) -> bool:
	var c := await _start(f, d)
	var h := f.get_half_extent_along(d)
	clear_events()
	_stick(d)
	hold(&"dash")
	var m := {"kinds": [], "lo": INF, "v_in": 0.0, "stop": 0}
	var passed := false
	parkour_reset()
	for i in 360:
		await get_tree().physics_frame
		parkour_track(p)
		var along := (p.global_position - c).dot(d)
		var v := hspeed(p)
		if along < -(h + 1.2):
			m["v_in"] = v
		elif along < h + 0.8:
			m["lo"] = minf(float(m["lo"]), v)
			if v < 1.0:
				m["stop"] = int(m["stop"]) + 1
		var k := p.traversal.get_parkour_kind()
		if k != &"" and not (m["kinds"] as Array).has(k):
			(m["kinds"] as Array).append(k)
		if along > h + 1.0 and not p.traversal.is_vaulting():
			passed = true
			break
	for i in 40:  # 0.3 s after the landing
		await get_tree().physics_frame
		parkour_track(p)
	release_all_input()
	var moves := parkour_finish()
	var ok := passed and int(m["stop"]) < 6 and not (m["kinds"] as Array).is_empty() and parkour_ok(moves)
	print("  %s %.2f m @(%.1f, %.1f) from (%.2f, %.2f), %.1f m run-up: %s; passed %s%s" % [
		f.kind, top, c.x, c.z, -d.x, -d.z, _run_up, parkour_text(moves), passed, "" if ok else "  <-- FAIL"])
	return ok

func _walk_into(f: Furniture, d: Vector3, top: float) -> bool:
	var c := await _start(f, d)
	var h := f.get_half_extent_along(d)
	clear_events()
	_stick(d)
	await ticks(int((_run_up + 1.0) / Tuning.WALK_SPEED * 120.0))
	var v_end := hspeed(p)
	release_all_input()
	var along := (p.global_position - c).dot(d)
	# Blocked: it did not get past the item's middle, came to rest against it,
	# no parkour, and the item stands (a thin pane met at an angle stops the
	# capsule well inside its diagonal half-extent).
	var ok := count_events(&"parkour") == 0 and along < -0.05 and v_end < 0.5 and not f.is_broken
	print("  walking into %s %.2f m @(%.1f, %.1f): stops %.2f m before its centre, speed %.2f, parkour %d, broken %s%s" % [
		f.kind, top, c.x, c.z, -along, v_end, count_events(&"parkour"), f.is_broken, "" if ok else "  <-- FAIL"])
	return ok

func _sprint_through(f: Furniture, d: Vector3) -> String:
	var c := await _start(f, d)
	_stick(d)
	hold(&"dash")
	var m := {"before": 0.0, "lo": INF, "pk": false}
	parkour_reset()
	for i in 360:
		await get_tree().physics_frame
		parkour_track(p)
		var along := (p.global_position - c).dot(d)
		# Clutter behind the pane is parkour (judged by the parkour metric):
		# the run-through's own reading stops at the first move.
		if p.traversal.get_parkour_kind() != &"":
			m["pk"] = true
		if along < -1.6:
			m["before"] = hspeed(p)
		elif along < 1.5:
			if not m["pk"]:
				m["lo"] = minf(float(m["lo"]), hspeed(p))
		else:
			break
	for i in 40:
		await get_tree().physics_frame
		parkour_track(p)
	release_all_input()
	var moves := parkour_finish()
	var kept := float(m["lo"]) / maxf(float(m["before"]), 0.01)
	var s := "%s %.1f m/s from (%.1f, %.1f) -> %.0f%% (broken %s)%s" % [f.kind, m["before"], -d.x, -d.z, kept * 100.0, f.is_broken,
		"" if moves.is_empty() else ", then " + parkour_text(moves)]
	check(float(m["before"]) < Tuning.RUN_THROUGH_SPEED or (f.is_broken and kept >= 0.95 and parkour_ok(moves)),
		"sprinting through %s at %.1f m/s smashes it and keeps its speed (%.0f%%)" % [f.kind, m["before"], kept * 100.0])
	return s
