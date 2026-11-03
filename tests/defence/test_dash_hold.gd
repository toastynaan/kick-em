extends "res://tests/defence/defence_test_base.gd"
## Dash held (agent H; Round 5 F6, kept for the Round 7 free teleport): a bot
## holding Dash to sprint through 100 enemy wind-ups never teleports or
## pursues (Feel Reference: What Dash does: the teleport needs a fresh press).
## The bot presses Dash once, with nothing coming, and holds it while it runs
## around inside a ring of grunts that keep winding up at it; 100 of their
## attacks reach their first active frame while Dash is held.

const RING_R := 2.6
const MOVES: Array[StringName] = [&"move_right", &"move_left", &"move_back", &"move_forward"]

func run() -> void:
	var p := spawn_player(Vector3.ZERO)
	await ticks(30)
	var es: Array[Fighter] = []
	for i in 6:
		var a := TAU * i / 6.0
		var at := Vector3(sin(a), 0, cos(a)) * RING_R
		es.append(spawn_dummy(&"grunt", at, -at))
	await ticks(20)
	var teleport_was := Tuning.debug_teleport
	Tuning.debug_teleport = true
	clear_events()
	var pc := p.brain as PlayerController
	press(&"dash")  # one fresh press, nothing in its window; then held
	var windups := 0
	var actives_while_held := 0
	var seen := {}
	var t := 0
	while actives_while_held < 100 and t < 150 * 120:
		await get_tree().physics_frame
		t += 1
		p.hp = p.max_hp
		_steer(p, t)
		for e in es:
			var c := e.combat
			var id := e.get_instance_id()
			if c.is_attack_active():
				if not seen.has(id):
					seen[id] = true
					if pc.interpreter.is_held(&"dash"):
						actives_while_held += 1
			elif not c.is_attacking():
				seen.erase(id)
				if e.is_down() and e.ragdoll:
					e.ragdoll.force_recover()
				if e.can_act():
					var to := p.global_position - e.global_position
					to.y = 0.0
					if to.length() < 2.4:
						e.snap_facing(to)
						if c.start_enemy_attack(&"e_jab" if windups % 2 == 0 else &"e_kick", Tuning.frames(18)):
							windups += 1
	release(&"dash")
	for act in MOVES:
		release(act)
	print("  %d wind-ups started, %d first active frames while Dash was held, %.1f s" % [windups, actives_while_held, t / 120.0])
	check(actives_while_held >= 100, "100 enemy attacks went active while Dash was held (%d)" % actives_while_held)
	check(count_events(&"teleported") == 0 and count_events(&"sidestepped") == 0, "no teleport, no sidestep")
	check(p.defence.teleports == 0 and p.defence.pursuits == 0, "Defence counted no teleport or pursuit")
	Tuning.debug_teleport = teleport_was
	done()

## Run at a point circling inside the ring (no camera: the stick is world XZ).
func _steer(p: Fighter, t: int) -> void:
	var a := t / 120.0 * 1.8
	var goal := Vector3(cos(a), 0.0, sin(a)) * 1.2
	var d := goal - p.global_position
	d.y = 0.0
	d = d.normalized() if d.length() > 0.2 else Vector3(-sin(a), 0.0, cos(a))
	_axis(&"move_right", &"move_left", d.x)
	_axis(&"move_back", &"move_forward", d.z)

func _axis(pos_action: StringName, neg_action: StringName, v: float) -> void:
	if v > 0.05:
		Input.action_press(pos_action, minf(v, 1.0))
		Input.action_release(neg_action)
	elif v < -0.05:
		Input.action_press(neg_action, minf(-v, 1.0))
		Input.action_release(pos_action)
	else:
		Input.action_release(pos_action)
		Input.action_release(neg_action)
