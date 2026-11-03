extends Node
## F5 acceptance over real Waves (Feel Reference: Enemies have to be readable
## first; Round 7). Loads the real main scene, starts Waves, and drives the
## player with a bot through the real Round 7 Input actions (punch taps and
## holds, the specials and kicks, Counter, grabs, dodges and sprints) for
## --seconds of simulation time (default 300 s = 5 minutes, at
## --fixed-fps 120). The bot alternates PASSIVE_TIME of standing open (the
## crowd closes in and both token holders swing) with ACTIVE_TIME of fighting.
## The player is healed so the run lasts; every KILL_EVERY s one enemy is
## finished off so the run reaches the later waves (where the Round 5 startups
## would shrink; Round 7 floors them at the tell minimum): grunts first, a stick enemy or a
## heavy only once it has attacked SPECIAL_MIN_ATTACKS times, so every
## archetype fights.
## Logged and checked:
## - never more than Tuning.TOKEN_MAX token holders (every tick), and in
##   waves 1-4 two holders at once some of the time (ticks with two enemies
##   mid-attack at once are logged);
## - the first active frames of different enemies are always at least
##   Tuning.TOKEN_ACTIVE_GAP apart (world time; the minimum gap per wave is printed);
## - grunts, the stick enemy and the heavy all attack;
## - Round 6: no enemy is stuck (wanting to move, barely moving:
##   AIBrain.stuck_time) for more than MAX_STUCK s in the clutter-filled Yard;
## - every attack's limb glow starts at least AttackDirector.tell_min_frames()
##   (Tuning.R7_COUNTER_WINDOW + Tuning.R7_TELL_MARGIN) before its first
##   active frame, at every wave;
## - no attack starts while the player is held; while he is down only free
##   swings (Tuning.DOWNED_FREE_SWINGS per holder per knockdown).
## Usage: Godot --headless --path <copy> --fixed-fps 120 res://tests/ai/test_token_soak.tscn [-- --seconds=N --seed=N]
## OWNER: agent C (AI tests).

const KILL_EVERY := 8.0          ## s: finish one enemy this often (wave progress)
const SPECIAL_MIN_ATTACKS := 3   ## a stick enemy / heavy is finished only after this many attacks...
const SPECIAL_MAX_LIFE := 60.0   ## ...or this long on the field (a wave never stalls)
const PASSIVE_TIME := 5.0        ## s the bot stands open...
const ACTIVE_TIME := 7.0         ## ...then fights this long, in turn
const REPORT_EVERY := 30.0
const MAX_STUCK := 3.0           ## s (Round 6 acceptance)

var seconds := 300.0
var game: Node
var rng := RandomNumberGenerator.new()
var failures := 0
var held: Array[StringName] = []
var next_action := 0.0
var next_kill := KILL_EVERY
var next_report := REPORT_EVERY
var started := false

var max_holders := 0
var max_attacking := 0
var attacks := 0
var by_arch := {}
var min_gap := INF               ## world s between different enemies' first active frames
var gap_violations := 0
var last_active_t := -INF
var last_active_by: Node3D = null
var glints := {}                 ## enemy -> TellGlint of its current tell
var tell_wave := {}              ## enemy -> wave index when its tell began
var min_lead_early := INF        ## frames, waves 1-4
var min_lead_by_wave := {}       ## wave -> frames
var leads_early := 0
var starts_held := 0
var free_swings := 0
var downs := 0
var swings_per_down := {}        ## enemy -> swings during the current knockdown
var too_many_free := 0
var free_pending := {}           ## enemy -> true while its free swing (tell at a downed player) runs
var free_landed := 0
var was_down := false
var max_wave := 0
var kills := 0
var forced_kills := 0
var stick_drops := 0
var attacks_by := {}             ## enemy -> attacks (tells) it started
var max_stuck := 0.0             ## s, longest stuck run of any enemy
var max_stuck_info := "-"
var stuck_over_1s := {}          ## enemy -> true when it was stuck >= 1 s once
var born := {}                   ## enemy -> _now() when first seen
var wave_stats := {}             ## wave -> {"gap": min s, "attacks": {arch: n}, "two_holders": ticks, "two_attacking": ticks, "max_attacking": n}

func _ready() -> void:
	var run_seed := 5150
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seconds="):
			seconds = float(arg.get_slice("=", 1))
		elif arg.begins_with("--seed="):
			run_seed = int(arg.get_slice("=", 1))
	rng.seed = run_seed
	seed(run_seed)
	AIBrain.test_seed = run_seed
	print("[ai] info: seed %d" % run_seed)
	GameEvents.attack_tell.connect(_on_tell)
	GameEvents.attack_active.connect(_on_active)
	GameEvents.hit_landed.connect(func(i: HitInfo) -> void:
		if i.attacker != null and free_pending.has(i.attacker) and i.victim is Fighter and (i.victim as Fighter).is_player:
			free_landed += 1
			free_pending.erase(i.attacker))
	GameEvents.attack_whiff.connect(func(a: Node3D, _m: StringName) -> void: free_pending.erase(a))
	GameEvents.fighter_died.connect(func(f: Node3D, _i: HitInfo) -> void:
		if f is Fighter and not (f as Fighter).is_player: kills += 1)
	GameEvents.round_over.connect(func(_won: bool) -> void:
		print("[ai] info: round over at %.0f s, restarting" % _now())
		_start.call_deferred())
	var packed: PackedScene = load("res://scenes/main.tscn")
	game = packed.instantiate()
	add_child(game)
	await get_tree().process_frame
	_start()

func check(ok: bool, what: String) -> void:
	print("[ai] %s: %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures += 1

func _now() -> float:
	return Engine.get_physics_frames() / float(Engine.physics_ticks_per_second)

func _start() -> void:
	if game.has_method(&"start_round"):
		game.start_round(&"waves")
		started = true
	print("[ai] info: Waves started (seconds=%.0f)" % seconds)

# --- Logging ---------------------------------------------------------------------

func _enemy(n: Node3D) -> bool:
	return n is Fighter and not (n as Fighter).is_player

func _on_tell(attacker: Node3D, _kind: StringName, _d: float) -> void:
	if not _enemy(attacker):
		return
	attacks += 1
	var a := attacker as Fighter
	by_arch[a.archetype] = by_arch.get(a.archetype, 0) + 1
	attacks_by[a] = int(attacks_by.get(a, 0)) + 1
	var ws := _ws()
	ws["attacks"][a.archetype] = int(ws["attacks"].get(a.archetype, 0)) + 1
	tell_wave[a] = AttackDirector.wave_index
	glints[a] = null
	for c in a.get_children():
		if c is TellGlint and not c.is_queued_for_deletion():
			glints[a] = c
	var p := Targeting.player(get_tree())
	if p != null and (p.carry and p.carry.is_held()):
		starts_held += 1
	if p != null and p.is_down() and not p.is_dead():
		free_swings += 1
		swings_per_down[a] = int(swings_per_down.get(a, 0)) + 1
		free_pending[a] = true
		if swings_per_down[a] > Tuning.DOWNED_FREE_SWINGS:
			too_many_free += 1

func _on_active(attacker: Node3D, _move: StringName) -> void:
	if not _enemy(attacker):
		return
	var t := AttackDirector.world_now()
	if last_active_by != null and last_active_by != attacker and is_instance_valid(last_active_by):
		var gap := t - last_active_t
		min_gap = minf(min_gap, gap)
		var ws := _ws()
		ws["gap"] = minf(float(ws["gap"]), gap)
		if gap < Tuning.TOKEN_ACTIVE_GAP - 0.004:
			gap_violations += 1
			print("[ai] gap violation: %.1f frames between %s and %s at %.1f s" % [gap * 60.0, last_active_by.name, attacker.name, _now()])
	last_active_t = t
	last_active_by = attacker
	var g: TellGlint = glints.get(attacker)
	if g != null and is_instance_valid(g) and g.glow_world_time >= 0.0:
		var lead := (t - g.glow_world_time) * 60.0
		var w: int = tell_wave.get(attacker, AttackDirector.wave_index)
		min_lead_by_wave[w] = minf(float(min_lead_by_wave.get(w, INF)), lead)
		if w < Tuning.ENEMY_STARTUP_SHRINK_FROM:
			min_lead_early = minf(min_lead_early, lead)
			leads_early += 1
	glints.erase(attacker)

# --- Bot ---------------------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	if not started:
		return
	var t := _now()
	var player := Targeting.player(get_tree())
	max_holders = maxi(max_holders, AttackDirector.get_token_holders().size())
	var attacking := 0
	for e in AttackDirector.get_enemies():
		if is_instance_valid(e) and e.combat and e.combat.is_attacking() and not e.is_dead():
			attacking += 1
		var b := e.brain as AIBrain if is_instance_valid(e) else null
		if b and b.dropped_stick != null and not b.has_meta(&"drop_counted"):
			b.set_meta(&"drop_counted", true)
			stick_drops += 1
	max_attacking = maxi(max_attacking, attacking)
	var ws := _ws()
	ws["max_attacking"] = maxi(int(ws["max_attacking"]), attacking)
	if attacking >= 2:
		ws["two_attacking"] = int(ws["two_attacking"]) + 1
	if AttackDirector.get_token_holders().size() >= 2:
		ws["two_holders"] = int(ws["two_holders"]) + 1
	for e in AttackDirector.get_enemies():
		if is_instance_valid(e) and not born.has(e):
			born[e] = t
		var sb := e.brain as AIBrain if is_instance_valid(e) else null
		if sb != null:
			if sb.stuck_time >= 1.0:
				stuck_over_1s[e] = true
			if sb.stuck_time > max_stuck:
				max_stuck = sb.stuck_time
				max_stuck_info = "%s at %s, wave %d, t=%.0f s: %s" % [e.archetype, e.get_ground_position().snapped(Vector3.ONE * 0.1),
					AttackDirector.wave_index, t, sb.get_debug_text().substr(0, 110)]
	max_wave = maxi(max_wave, AttackDirector.wave_index)
	if player != null:
		var down := player.is_down() and not player.is_dead()
		if down and not was_down:
			downs += 1
			swings_per_down.clear()
		was_down = down
		if player.hp < player.max_hp * 0.5 and not player.is_dead():
			player.heal_fraction(1.0)
	if t >= next_kill:
		next_kill += KILL_EVERY
		_finish_one()
	if t >= next_report:
		next_report += REPORT_EVERY
		_report(t)
	if t >= seconds:
		_end()
		return
	_drive(player, t)

## Finish one live enemy (stands in for the player's kills): the most damaged
## grunt; a stick enemy or heavy only once it has attacked SPECIAL_MIN_ATTACKS
## times (or been out SPECIAL_MAX_LIFE s), so every archetype gets to fight.
func _finish_one() -> void:
	var best: Fighter = null
	var best_key := INF
	for e in AttackDirector.get_enemies():
		if not is_instance_valid(e) or e.is_dead():
			continue
		var key := e.hp
		if e.archetype != &"grunt":
			var life := _now() - float(born.get(e, _now()))
			if int(attacks_by.get(e, 0)) < SPECIAL_MIN_ATTACKS and life < SPECIAL_MAX_LIFE:
				continue
			key += 1000.0  # after every grunt
		if key < best_key:
			best_key = key
			best = e
	if best != null:
		forced_kills += 1
		best.apply_damage(best.hp, &"test")

## Stats of the current wave.
func _ws() -> Dictionary:
	var w := AttackDirector.wave_index
	if not wave_stats.has(w):
		wave_stats[w] = {"gap": INF, "attacks": {}, "two_holders": 0, "two_attacking": 0, "max_attacking": 0}
	return wave_stats[w]

## The bot stands open for PASSIVE_TIME, then fights for ACTIVE_TIME.
func _passive(t: float) -> bool:
	return fmod(t, PASSIVE_TIME + ACTIVE_TIME) < PASSIVE_TIME

func _drive(player: Fighter, t: float) -> void:
	if player == null or player.is_dead():
		_release_all()
		return
	var target := Targeting.pick_target(player, Vector3.ZERO, 40.0)
	if _passive(t):
		# Stand open: no moves, no attacks; the crowd closes in and swings.
		_steer(player, null)
		_release_all()
		return
	_steer(player, target)
	if t < next_action:
		return
	next_action = t + rng.randf_range(0.18, 0.55)
	_release_all()
	if target == null:
		return
	var dist := player.get_ground_position().distance_to(target.get_ground_position())
	var roll := rng.randf()
	var actions: Array[StringName] = []
	if dist > 4.5:
		if roll < 0.45:
			actions = [&"dash"]          # sprint at him
		elif roll < 0.6:
			actions = [&"punch"]         # a strike glides in
	elif roll < 0.3:
		actions = [&"punch"]             # held 0.18-0.55 s: a tap or a heavy
	elif roll < 0.4:
		actions = [&"uppercut"]
	elif roll < 0.5:
		actions = [&"gut_punch"]
	elif roll < 0.57:
		actions = [&"leg_kick"]
	elif roll < 0.63:
		actions = [&"front_kick"]
	elif roll < 0.67:
		actions = [&"roundhouse"]
	elif roll < 0.8:
		actions = [&"counter"]
	elif roll < 0.88:
		actions = [&"grab"]
	else:
		actions = [&"dash"]              # a dodge (or a drive with a body)
	for action in actions:
		if InputMap.has_action(action):
			Input.action_press(action)
			held.append(action)

func _steer(player: Fighter, target: Fighter) -> void:
	for a in [&"move_forward", &"move_back", &"move_left", &"move_right"]:
		if InputMap.has_action(a):
			Input.action_release(a)
	if target == null:
		return
	var to := target.get_ground_position() - player.get_ground_position()
	to.y = 0.0
	if to.length() < 1.2:
		return
	var cam := get_viewport().get_camera_3d()
	var basis := cam.global_basis if cam else Basis()
	var fwd := -basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	var right := basis.x
	right.y = 0.0
	right = right.normalized() if right.length() > 0.01 else Vector3.RIGHT
	to = to.normalized()
	var f := fwd.dot(to)
	var r := right.dot(to)
	if f > 0.1: Input.action_press(&"move_forward", f)
	if f < -0.1: Input.action_press(&"move_back", -f)
	if r > 0.1: Input.action_press(&"move_right", r)
	if r < -0.1: Input.action_press(&"move_left", -r)

func _release_all() -> void:
	for a in held:
		Input.action_release(a)
	held.clear()

# --- Report ------------------------------------------------------------------------

func _report(t: float) -> void:
	print("[ai] t=%.0fs wave=%d attacks=%d holders_max=%d attacking_max=%d min_gap=%.1ff glow_min_early=%.1ff kills=%d (forced %d) downs=%d free_swings=%d" % [
		t, AttackDirector.wave_index, attacks, max_holders, max_attacking, min_gap * 60.0, min_lead_early, kills, forced_kills, downs, free_swings])

static func waves_of(d: Dictionary) -> Array:
	var out := d.keys()
	out.sort()
	return out

func _end() -> void:
	set_physics_process(false)
	_release_all()
	_report(_now())
	var guards := 0
	for e in get_tree().get_nodes_in_group(&"enemies"):
		var b := (e as Fighter).brain as AIBrain if e is Fighter else null
		if b:
			guards += b.tap_guards
	var waves := []
	for w in min_lead_by_wave.keys():
		waves.append(w)
	waves.sort()
	var per_wave := []
	for w in waves:
		per_wave.append("w%d %.1ff" % [w, min_lead_by_wave[w]])
	print("[ai] info: %.0f s of Waves: reached wave %d, %d attacks %s, kills %d (forced %d), player downs %d, free swings %d (landed %d), stick drops %d, tap guards of live enemies %d" % [
		seconds, max_wave, attacks, str(by_arch), kills, forced_kills, downs, free_swings, free_landed, stick_drops, guards])
	print("[ai] info: min glow lead per wave (frames): %s" % ", ".join(per_wave))
	var two_holders_early := 0
	var two_attacking_early := 0
	for w: int in waves_of(wave_stats):
		var st: Dictionary = wave_stats[w]
		print("[ai] info: wave %d: attacks %s, min first-active gap %s, ticks with 2 holders %d, with 2 attacking %d (max attacking %d)" % [
			w, str(st["attacks"]), ("%.1f frames" % (float(st["gap"]) * 60.0)) if is_finite(float(st["gap"])) else "-",
			st["two_holders"], st["two_attacking"], st["max_attacking"]])
		if w >= 1 and w < Tuning.ENEMY_STARTUP_SHRINK_FROM:
			two_holders_early += int(st["two_holders"])
			two_attacking_early += int(st["two_attacking"])
	print("[ai] info: AttackDirector.min_active_gap %.1f frames (since the last reset), this run %.1f frames" % [AttackDirector.min_active_gap * 60.0, min_gap * 60.0])
	print("[ai] info: longest stuck time %.2f s (%s); %d of %d enemies stuck 1 s or more once" % [max_stuck, max_stuck_info, stuck_over_1s.size(), born.size()])
	check(max_stuck <= MAX_STUCK, "no enemy stuck for more than %.0f s in the clutter (longest %.2f s)" % [MAX_STUCK, max_stuck])
	check(attacks >= int(seconds / 6.0), "enemies attacked throughout (%d attacks in %.0f s)" % [attacks, seconds])
	for arch: StringName in [&"grunt", &"stick", &"heavy"]:
		check(int(by_arch.get(arch, 0)) >= SPECIAL_MIN_ATTACKS, "%s attacks (%d)" % [arch, int(by_arch.get(arch, 0))])
	check(two_holders_early > 0, "waves 1-4: two token holders at once (%d ticks; two enemies mid-attack at once %d ticks)" % [
		two_holders_early, two_attacking_early])
	check(max_holders <= Tuning.TOKEN_MAX, "never more than %d token holders (max %d)" % [Tuning.TOKEN_MAX, max_holders])
	check(gap_violations == 0 and min_gap >= Tuning.TOKEN_ACTIVE_GAP - 0.004,
		"first active frames of different enemies always >= %.0f frames apart (min %.1f frames, %d violations)" % [
			Tuning.TOKEN_ACTIVE_GAP * 60.0, min_gap * 60.0, gap_violations])
	var floor_f := AttackDirector.tell_min_frames()
	check(leads_early > 0 and min_lead_early >= floor_f - 0.01,
		"waves 1-4: every glow starts >= %.0f frames before the first active frame (min %.1f over %d attacks)" % [
			floor_f, min_lead_early, leads_early])
	var later_ok := true
	for w: int in min_lead_by_wave:
		later_ok = later_ok and float(min_lead_by_wave[w]) >= floor_f - 0.01
	check(later_ok, "every wave: glows never shorter than %.0f frames (the counter window + margin)" % floor_f)
	check(max_wave >= Tuning.ENEMY_STARTUP_SHRINK_FROM, "the run reached the faster waves (wave %d)" % max_wave)
	check(starts_held == 0, "no attack started while the player was held (%d)" % starts_held)
	check(too_many_free == 0, "while the player was down, at most %d free swing per enemy per knockdown (%d over)" % [Tuning.DOWNED_FREE_SWINGS, too_many_free])
	print("[ai] test_token_soak: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
