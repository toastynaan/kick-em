extends Node
## Harness for the anti-infinite tests: the real main scene, a duel round with
## the opponent swapped to an archetype, the real PlayerController driven by
## Input.action_press (8 Hz taps, stick neutral when in range), real AI.
## OWNER: agent B (combat tests).

var game: Node
var player: Fighter
var enemy: Fighter
var failures: Array[String] = []
var _checks := 0
var _timeout := 280.0
const MASH_RANGE := 1.8  ## m: the bot mashes (stick neutral) only this close

# Per-run metrics
var m_combo_kill := false
var m_max_hits := 0
var m_max_noctl := 0.0
var m_escapes := 0
var m_escape_free_min := INF   ## shortest time the enemy stayed free after an escape
var m_acts_after_escape := 0   ## escapes followed by an AI action (tell / block / dodge) within 1 s
var m_deaths := 0
var _escape_times: Array[float] = []
var _act_times: Array[float] = []
var _noctl := 0.0
var _noctl_start := 0.0
var _timeline: Array = []       ## [t, text] of the enemy's reactions this run
var m_worst: Array = []         ## timeline entries inside the longest no-control stretch
var _combo_start_hp := 0.0
var _combo_strike_dmg := 0.0    ## strike damage (no environment) in the enemy's current combo
var m_max_combo_dmg := 0.0      ## largest strike damage of one combo, fraction of max HP
var m_max_stun_noctl := 0.0     ## longest no-control stretch without a knockdown
var m_max_down_noctl := 0.0     ## longest no-control stretch containing a knockdown
var m_max_ground_up := 0.0      ## longest landing (grounded) -> back on its feet
var m_otg_relaunch := 0         ## ordinary hits that relaunched a body after it landed
var m_finisher_relaunch_max := 0 ## ground-finisher relaunches in one knockdown
var _stretch_down := false
var _landed_at := -1.0
var _finisher_relaunches := 0
var _prev_taken := 0

func _ready() -> void:
	get_tree().create_timer(_timeout, true, false, true).timeout.connect(func() -> void:
		print("FAIL timeout")
		get_tree().quit(1))
	game = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(game)
	await get_tree().process_frame
	GameEvents.combo_escaped.connect(func(v: Node3D, _a: Node3D) -> void:
		if v == enemy:
			m_escapes += 1
			_escape_times.append(TimeDirector.now()))
	GameEvents.attack_tell.connect(func(a: Node3D, _k: StringName, _d: float) -> void:
		if a == enemy: _act_times.append(TimeDirector.now()))
	GameEvents.hit_blocked.connect(func(i: HitInfo) -> void:
		if i.victim == enemy and not i.get_meta(&"escape_guard", false): _act_times.append(TimeDirector.now()))
	GameEvents.perfect_dodge.connect(func(d: Node3D, _a: Node3D) -> void:
		if d == enemy: _act_times.append(TimeDirector.now()))
	GameEvents.hit_landed.connect(func(i: HitInfo) -> void:
		if i.victim == enemy:
			if enemy.combat.hits_taken() <= 1:
				_combo_strike_dmg = 0.0
			_combo_strike_dmg += i.damage
			m_max_combo_dmg = maxf(m_max_combo_dmg, _combo_strike_dmg / enemy.max_hp)
			if i.reaction == HitInfo.Reaction.LAUNCH and _landed_at >= 0.0:
				var m := MoveLibrary.get_move(i.move_id)
				if m != null and m.ground_hit:
					_finisher_relaunches += 1
					m_finisher_relaunch_max = maxi(m_finisher_relaunch_max, _finisher_relaunches)
				else:
					m_otg_relaunch += 1
			_timeline.append([TimeDirector.now(), "hit %s react=%d juggle=%s n=%d %s" % [i.move_id, i.reaction, i.juggle,
				enemy.combat.hits_taken(), "ESCAPE" if i.get_meta(&"escaped", false) else ""]]))
	GameEvents.fighter_grounded.connect(func(f: Node3D) -> void:
		if f == enemy and _landed_at < 0.0: _landed_at = TimeDirector.now())
	GameEvents.fighter_recovered.connect(func(f: Node3D) -> void:
		if f == enemy:
			if _landed_at >= 0.0:
				m_max_ground_up = maxf(m_max_ground_up, TimeDirector.now() - _landed_at)
			_landed_at = -1.0
			_finisher_relaunches = 0)
	for sig: StringName in [&"dazed", &"stumbled", &"tripped", &"fighter_launched", &"fighter_grounded", &"fighter_recovered", &"combo_escaped"]:
		var sn := sig
		GameEvents.connect(sn, func(a = null, _b = null) -> void:
			if a == enemy: _timeline.append([TimeDirector.now(), String(sn)]))
	# Subclasses override run() as a coroutine; the base one is empty.
	@warning_ignore("redundant_await")
	await run()
	finish()

func run() -> void:
	pass

func check(cond: bool, msg: String) -> void:
	_checks += 1
	print("  %s %s" % ["PASS" if cond else "FAIL", msg])
	if not cond:
		failures.append(msg)

func finish() -> void:
	_release_all()
	TimeDirector.reset()
	if failures.is_empty() and _checks > 0:
		print("RESULT PASS ", name)
		get_tree().quit(0)
	else:
		print("RESULT FAIL ", name, " ", failures)
		get_tree().quit(1)

func _release_all() -> void:
	for a in InputMap.get_actions():
		if not String(a).begins_with("ui_"):
			Input.action_release(a)

## Start a duel against `arch` (the Duelist is swapped out).
func start_duel(arch: StringName) -> void:
	_release_all()
	game.start_round(&"duel")
	await get_tree().physics_frame
	player = game.player
	enemy = game._alive[0]
	if arch != &"duelist":
		var old: Fighter = enemy
		var nf: Fighter = game._spawn_enemy(arch, old.global_transform, PackedVector3Array())
		game._alive.erase(old)
		AttackDirector.unregister_enemy(old)
		old.get_parent().remove_child(old)
		old.queue_free()
		enemy = nf
	await get_tree().physics_frame

func _reset_metrics() -> void:
	m_combo_kill = false
	m_max_hits = 0
	m_max_noctl = 0.0
	m_escapes = 0
	m_escape_free_min = INF
	m_acts_after_escape = 0
	m_deaths = 0
	_escape_times.clear()
	_act_times.clear()
	_noctl = 0.0
	_prev_taken = 0
	_timeline.clear()
	m_worst = []
	m_max_combo_dmg = 0.0
	_combo_strike_dmg = 0.0
	m_max_stun_noctl = 0.0
	m_max_down_noctl = 0.0
	m_max_ground_up = 0.0
	m_otg_relaunch = 0
	m_finisher_relaunch_max = 0
	_stretch_down = false
	_landed_at = -1.0
	_finisher_relaunches = 0

func _steer(to_pos: Vector3, stop_at: float) -> void:
	for a in [&"move_forward", &"move_back", &"move_left", &"move_right"]:
		Input.action_release(a)
	var to := to_pos - player.get_ground_position()
	to.y = 0.0
	if to.length() < stop_at:
		return  # stick neutral while mashing in range
	var b: Basis = game.camera_rig.get_flat_basis() if game.camera_rig else Basis()
	var fwd := -b.z
	fwd.y = 0
	fwd = fwd.normalized()
	var right := b.x
	right.y = 0
	right = right.normalized()
	to = to.normalized()
	var f := fwd.dot(to)
	var r := right.dot(to)
	if f > 0.1: Input.action_press(&"move_forward", f)
	if f < -0.1: Input.action_press(&"move_back", -f)
	if r > 0.1: Input.action_press(&"move_right", r)
	if r < -0.1: Input.action_press(&"move_left", -r)

## Mash `pattern` ("P", "K", "PK") at 8 Hz for `seconds` of real time.
func mash(pattern: String, seconds: float) -> void:
	_reset_metrics()
	var t0 := TimeDirector.now()
	var next := t0
	var release_at := -1.0
	var step := 0
	var last := t0
	while TimeDirector.now() - t0 < seconds:
		await get_tree().physics_frame
		var now := TimeDirector.now()
		var dt := now - last
		last = now
		if not is_instance_valid(enemy) or enemy.is_dead():
			break
		if player.is_dead():
			break
		if player.hp < player.max_hp * 0.4:
			player.heal_fraction(1.0)
		_sample(now, dt)
		# Close in without attacking; mash only in range with the stick neutral.
		var gap := enemy.get_ground_position() - player.get_ground_position()
		gap.y = 0.0
		var in_range := gap.length() <= MASH_RANGE
		_steer(enemy.get_ground_position(), MASH_RANGE - 0.3 if not in_range else 99.0)
		if release_at >= 0.0 and now >= release_at:
			Input.action_release(&"punch")
			Input.action_release(&"kick")
			release_at = -1.0
		if now >= next and in_range:
			next = now + 0.125
			release_at = now + 0.066
			var key := &"punch"
			match pattern:
				"K": key = &"kick"
				"PK": key = &"punch" if step % 2 == 0 else &"kick"
			step += 1
			Input.action_press(key)
	_release_all()
	_finish_metrics()

func _sample(now: float, dt: float) -> void:
	var c := enemy.combat
	var taken := c.hits_taken()
	if taken > 0 and _prev_taken == 0:
		_combo_start_hp = enemy.hp + (c.last_received.damage if c.last_received else 0.0)
	_prev_taken = taken
	m_max_hits = maxi(m_max_hits, taken)
	var noctl := enemy.is_in_hitstun() or enemy.is_down() or enemy.carry.is_held()
	if noctl and _noctl == 0.0:
		_noctl_start = now - dt
		_stretch_down = false
	_noctl = _noctl + dt if noctl else 0.0
	if noctl and enemy.is_down():
		_stretch_down = true
	if noctl:
		if _stretch_down:
			m_max_down_noctl = maxf(m_max_down_noctl, _noctl)
		else:
			m_max_stun_noctl = maxf(m_max_stun_noctl, _noctl)
	if _noctl > m_max_noctl:
		m_max_noctl = _noctl
		m_worst = [_noctl_start, now]
	# Freedom after each escape: time until the enemy is next out of control.
	for i in _escape_times.size():
		var te: float = _escape_times[i]
		if te < 0.0:
			continue
		if noctl and now - te > 2.0 / 120.0:
			m_escape_free_min = minf(m_escape_free_min, now - te)
			_escape_times[i] = -te
		elif now - te > 1.0:
			m_escape_free_min = minf(m_escape_free_min, 1.0)
			_escape_times[i] = -te
	if enemy.is_dead() and taken > 0 and _combo_start_hp >= enemy.max_hp - 0.5 \
			and _combo_strike_dmg >= enemy.max_hp - 0.5:
		m_combo_kill = true  # strikes alone (environment damage is not a combo)

## Timeline lines inside the longest no-control stretch.
func worst_timeline() -> Array:
	var out: Array = []
	if m_worst.size() < 2:
		return out
	for e: Array in _timeline:
		if e[0] >= m_worst[0] - 0.6 and e[0] <= m_worst[1] + 0.05:
			out.append("%+.2f %s" % [e[0] - m_worst[0], e[1]])
	return out

func _finish_metrics() -> void:
	if is_instance_valid(enemy) and enemy.is_dead():
		m_deaths += 1
		if enemy.combat.hits_taken() > 0 and _combo_start_hp >= enemy.max_hp - 0.5 \
				and _combo_strike_dmg >= enemy.max_hp - 0.5:
			m_combo_kill = true
	for te: float in _escape_times:
		var t := absf(te)
		for ta: float in _act_times:
			if ta > t and ta - t <= 1.0:
				m_acts_after_escape += 1
				break
