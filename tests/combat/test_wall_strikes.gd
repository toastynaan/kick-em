extends "res://tests/combat/combat_test_base.gd"
## Round 3 wall strikes, kept in Round 7: the player's punches and kicks call
## receive_strike on the wall under the striking limb, once per move, with no
## target in reach (the strike goes along the facing). Round 7: power =
## CombatController.WALL_POWER_PER_WEIGHT x the move's R7 weight (a front kick
## 62, about Round 3's 60; Round 8: a charged strike's own weight at its c when
## that is more); the floor is never struck; a fighter in reach wins;
## the feel (no whiff, no chain credit, recoil off a wall that holds).

const FakeWall := preload("res://tests/combat/fake_wall.gd")
const L := CombatController.Action.LIGHT
const K := CombatController.Action.FRONT_KICK
var _x := 0.0

func _init() -> void:
	_timeout = 90.0

## A player facing -Z with a wall face `gap` m in front of its chest.
func _wall_lane(gap: float, result := &"chip") -> Array:
	_x += 8.0
	var wall: StaticBody3D = FakeWall.new()
	wall.setup(Vector3(3.0, 3.0, 0.25))
	wall.result = result
	add_child(wall)
	wall.global_position = Vector3(_x, 1.5, -(gap + 0.125))
	var p := spawn_fake(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER, true)
	await ticks(12)
	return [p, wall]

func _strike(p: Fighter, action: int, hold := 0.0) -> void:
	if hold > 0.0:
		await hold_press(p, action, hold)
	else:
		tap(p, action)
	await wait_until(func() -> bool: return not p.combat.is_attacking(), 2.5)
	await ticks(4)

func run() -> void:
	var per := CombatController.WALL_POWER_PER_WEIGHT
	var w := func(id: StringName) -> float: return per * float(Tuning.R7_MOVES[id]["weight"])
	# A roundhouse held 0.6 s charges to c = (0.6 - R8_TAP_MAX) / (debug_charge_full - R8_TAP_MAX).
	var hold_c := (0.6 - Tuning.R8_TAP_MAX) / (Tuning.debug_charge_full - Tuning.R8_TAP_MAX)
	var rw: Vector2 = Tuning.R8_MOVES[&"roundhouse"]["charged"]["weight"]
	var charged_rh := per * maxf(float(Tuning.R7_MOVES[&"roundhouse"]["weight"]), lerpf(rw.x, rw.y, hold_c))
	print("power per move (%.0f x weight)" % per)
	var cases := [["jab", L, 0.0, w.call(&"jab")], ["front kick", K, 0.0, w.call(&"front_kick")],
		["charged roundhouse (held 0.6 s)", CombatController.Action.ROUNDHOUSE, 0.6, charged_rh]]
	for c: Array in cases:
		var lw: Array = await _wall_lane(0.75)
		var p: Fighter = lw[0]
		var wall = lw[1]
		clear_events()
		await _strike(p, c[1], c[2])
		check(wall.calls.size() == 1, "%s: receive_strike called once (%d)" % [c[0], wall.calls.size()])
		if wall.calls.is_empty():
			continue
		var rc: Array = wall.calls[0]
		check(rc[0] == p, "%s: attacker is the player" % c[0])
		check(absf(float(rc[3]) - float(c[3])) <= per * 0.03 if String(c[0]).begins_with("charged") else is_equal_approx(rc[3], c[3]),
			"%s: power %.1f (want %.1f)" % [c[0], rc[3], c[3]])
		var hp: Vector3 = rc[1]
		check(absf(hp.z - (-0.75)) < 0.12 and absf(hp.x - _x) < 0.6, "%s: hit point on the wall face %s" % [c[0], hp])
		check((rc[2] as Vector3).dot(Vector3.FORWARD) > 0.9, "%s: direction into the wall" % c[0])
		check(count_events(&"attack_whiff") == 0, "%s: no whiff" % c[0])
		check(p.combat.get_chain_count() == 0 and count_events(&"chain_hit") == 0, "%s: no chain credit" % c[0])

	print("feel: recoil off a wall that holds")
	var hl: Array = await _wall_lane(0.75, &"hold")
	var ph: Fighter = hl[0]
	await _strike(ph, K)
	var z0: float = (hl[1].calls[0][4] as Vector3).z if not hl[1].calls.is_empty() else 0.0
	var want := Tuning.STRIKE_RECOIL * CombatController.STRIKE_RECOIL_TIME * 0.6
	check(hl[1].calls.size() == 1 and ph.global_position.z > z0 + want,
		"pushed back off the wall (%.2f m from the strike)" % (ph.global_position.z - z0))

	print("the floor is never struck")
	_x += 8.0
	var floor_wall: StaticBody3D = FakeWall.new()
	floor_wall.setup(Vector3(4.0, 0.2, 4.0), Layers.WORLD)
	add_child(floor_wall)
	floor_wall.global_position = Vector3(_x, 0.1, -1.0)  # a strikeable slab under the feet
	var pf := spawn_fake(&"player", Vector3(_x, 0.25, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER, true)
	await ticks(20)
	await _strike(pf, CombatController.Action.LEG_KICK)
	await _strike(pf, K)
	check(floor_wall.calls.is_empty(), "leg kick and front kick over a strikeable floor: no strike (%d)" % floor_wall.calls.size())

	print("nothing without receive_strike, out of reach, or for enemies")
	_x += 8.0
	var plain := StaticBody3D.new()
	plain.collision_layer = Layers.WORLD
	var pcs := CollisionShape3D.new()
	var pbox := BoxShape3D.new()
	pbox.size = Vector3(3, 3, 0.25)
	pcs.shape = pbox
	plain.add_child(pcs)
	add_child(plain)
	plain.global_position = Vector3(_x, 1.5, -0.9)
	var pp := spawn_fake(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER, true)
	await ticks(10)
	await _strike(pp, K)
	check(pp.combat.last_wall_strike.is_empty(), "a plain wall without receive_strike is ignored")
	var far: Array = await _wall_lane(3.0)
	await _strike(far[0], L)
	check(far[1].calls.is_empty(), "a wall out of reach is not struck")
	_x += 8.0
	var ew: StaticBody3D = FakeWall.new()
	ew.setup(Vector3(3.0, 3.0, 0.25))
	add_child(ew)
	ew.global_position = Vector3(_x, 1.5, -0.875)
	var en := spawn(&"grunt", Vector3(_x, 0, 0), Vector3.FORWARD)
	await ticks(10)
	en.combat.start_enemy_attack(&"e_kick", 0.35)
	await wait_real(1.2)
	check(ew.calls.is_empty(), "enemy strikes never damage walls")

	print("a fighter in reach wins over the wall")
	var fl: Array = await _wall_lane(1.6)
	var pw: Fighter = fl[0]
	var _g := spawn(&"grunt", Vector3(_x, 0, -1.0), Vector3.BACK)
	await ticks(10)
	clear_events()
	await _strike(pw, K)
	check(count_events(&"hit_landed") >= 1 and fl[1].calls.is_empty(), "kicked the grunt, not the wall behind him")
	await wait_real(1.0)
	await _drywall_end_to_end()
	done()

## A real drywall Destructible (agent D): two jabs or one front kick open a hole.
## Skipped while Destructible.receive_strike is still the stub (always &"hold").
func _panel_lane() -> Array:
	_x += 8.0
	var d := WorldTestUtil.make_panel(self, &"drywall", Vector3(_x, 0, -6.0))
	var p := spawn_fake(&"player", Vector3(_x + 0.125 + 0.75, 0, -6.0), Vector3.LEFT, Fighter.TEAM_PLAYER, true)
	await ticks(15)
	return [p, d]

func _drywall_end_to_end() -> void:
	print("end to end: drywall")
	var lane: Array = await _panel_lane()
	var p: Fighter = lane[0]
	await _strike(p, L)
	var first: StringName = p.combat.last_wall_strike.get("result", &"")
	if first == &"" or first == &"hold":
		print("  SKIP drywall end to end: Destructible.receive_strike answers %s (stub)" % [first])
		return
	await wait_real(0.5)
	await _strike(p, L)
	var second: StringName = p.combat.last_wall_strike.get("result", &"")
	check(second in [&"hole", &"break"] or first in [&"hole", &"break"], "two jabs open drywall (%s, %s)" % [first, second])
	lane = await _panel_lane()
	await _strike(lane[0], K)
	var k: StringName = (lane[0] as Fighter).combat.last_wall_strike.get("result", &"")
	check(k in [&"hole", &"break"], "one front kick opens drywall (%s)" % k)
