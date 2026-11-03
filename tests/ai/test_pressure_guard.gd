extends Node
## Round 8 block chance under pressure and by level (docs/Round 8 — Charge
## and Pressure.md: Pressure, Acceptance 6). Pressure comes from the
## FakeCombat double (fake_pressure for B's get_pressure_fraction), on enemies
## with their real AIBrain (Util.spawn_pressure_enemy).
## A. A level-1 grunt's tap guards over GUARD_TRIALS tapped strikes (B's
##    GameEvents.strike_started) at p = 0, 0.5 and 0.9: Tuning.GUARD_TAP_CHANCE
##    x (1 - p).
## B. The Duelist's reads (the player's attack_incoming) at p = 0, 0.5, 0.9:
##    his read chance x (1 - p).
## C. Grunts of level 1, 2 and 3 at p = 0: x Tuning.R8_LEVEL_BLOCK_MULT, so
##    level 2 blocks more than level 1 and level 3 more than level 2; level 3
##    at p = 0.5 is still scaled by (1 - p).
## Every rate must sit within TOL_SD binomial standard deviations (at least
## TOL_MIN) of the expected one. Measured numbers are printed.
## OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")
const FakeCombat := preload("res://tests/ai/fake_combat.gd")
const GUARD_TRIALS := 2000
const PRESSURES: Array[float] = [0.0, 0.5, 0.9]
const TOL_SD := 3.5
const TOL_MIN := 0.01

var failures := 0
var player: Fighter

func _ready() -> void:
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	print("[ai] %s: %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures += 1

func _run() -> void:
	AttackDirector.reset()
	AIBrain.test_seed = 8008
	Tuning.difficulty = Tuning.Difficulty.NORMAL
	Util.build_floor(self)
	player = Util.spawn_fake(self, &"player", Fighter.TEAM_PLAYER, Vector3(0, 0.05, 0))
	AttackDirector.set_player(player)
	await _ticks(10)
	_part_grunt()
	_part_duelist()
	_part_levels()
	_finish()

## Expected rate and its tolerance for `n` trials.
func _tol(expected: float, n: int) -> float:
	return maxf(TOL_MIN, TOL_SD * sqrt(maxf(expected * (1.0 - expected), 1e-6) / n))

## A brain switched off (the trials drive it), fighting, facing the player.
func _enemy(archetype: StringName, pos: Vector3, level := 1) -> Fighter:
	var e := Util.spawn_pressure_enemy(self, archetype, pos, (player.global_position - pos).normalized(), level)
	var b := e.brain as AIBrain
	b.process_mode = Node.PROCESS_MODE_DISABLED
	b.mode = AIBrain.Mode.FIGHT
	return e

## Share of `n` tapped punches aimed at `e` that raise a tap guard.
func _tap_guard_rate(e: Fighter, n: int) -> float:
	var b := e.brain as AIBrain
	var taps: Array[StringName] = Tuning.R7_PUNCH_STRING
	var guards := 0
	for i in n:
		b._tap_guard_until = -INF
		b._want_guard = false
		b._apply_guard()
		var before := b.tap_guards
		GameEvents.strike_started.emit(player, e, taps[i % taps.size()], false, 0)
		if b.tap_guards > before:
			guards += 1
	b._tap_guard_until = -INF
	b._want_guard = false
	b._apply_guard()
	return float(guards) / n

# --- A. Grunt tap guards by pressure ------------------------------------------------

func _part_grunt() -> void:
	var g := _enemy(&"grunt", Vector3(0, 0.05, -1.5))
	var fc := g.combat as FakeCombat
	var gb := g.brain as AIBrain
	var rows: Array[String] = []
	var rates: Array[float] = []
	for p in PRESSURES:
		fc.fake_pressure = p
		var rate := _tap_guard_rate(g, GUARD_TRIALS)
		var expected := Tuning.GUARD_TAP_CHANCE * (1.0 - p)
		rates.append(rate)
		rows.append("p %.1f: %.3f (expected %.3f, brain says %.3f)" % [p, rate, expected, gb.get_guard_chance()])
		check(absf(rate - expected) <= _tol(expected, GUARD_TRIALS),
			"grunt L1 at p %.1f guards %.1f%% of %d tapped punches (expected %.1f%% = %.2f x (1 - p))" % [
				p, rate * 100.0, GUARD_TRIALS, expected * 100.0, Tuning.GUARD_TAP_CHANCE])
	print("[ai] info: grunt tap guard rate by pressure: " + ", ".join(rows))
	check(rates[0] > rates[1] and rates[1] > rates[2], "the grunt guards less as pressure rises (%.3f > %.3f > %.3f)" % [
		rates[0], rates[1], rates[2]])
	fc.fake_pressure = -1.0
	AttackDirector.unregister_enemy(g)
	g.queue_free()

# --- B. Duelist reads by pressure --------------------------------------------------------

func _part_duelist() -> void:
	var d := _enemy(&"duelist", Vector3(0, 0.05, -2.0))
	var fc := d.combat as FakeCombat
	var db := d.brain as AIBrain
	player.snap_facing((d.global_position - player.global_position).normalized())
	db._watch_player(player)
	var base := db._read_chance()
	var rows: Array[String] = []
	var rates: Array[float] = []
	for p in PRESSURES:
		fc.fake_pressure = p
		var reads := 0
		for i in GUARD_TRIALS:
			db._guard_until = 0.0
			db._want_guard = false
			db._apply_guard()
			db._player_moves = []  # no anti-mash repeats: the base chance
			var before := db.guard_reads
			player.combat.attack_incoming.emit(&"jab", 0.2)
			if db.guard_reads > before:
				reads += 1
		var rate := float(reads) / GUARD_TRIALS
		var expected := base * (1.0 - p)
		rates.append(rate)
		rows.append("p %.1f: %.3f (expected %.3f)" % [p, rate, expected])
		check(absf(rate - expected) <= _tol(expected, GUARD_TRIALS),
			"Duelist at p %.1f reads %.1f%% of %d strikes (expected %.1f%% = %.2f x (1 - p))" % [
				p, rate * 100.0, GUARD_TRIALS, expected * 100.0, base])
	print("[ai] info: Duelist read rate by pressure: " + ", ".join(rows))
	check(rates[0] > rates[1] and rates[1] > rates[2], "the Duelist reads less as pressure rises (%.3f > %.3f > %.3f)" % [
		rates[0], rates[1], rates[2]])
	check(d.level == 1, "the Duelist is level 1 (%d)" % d.level)
	db._guard_until = 0.0
	db._want_guard = false
	db._apply_guard()
	AttackDirector.unregister_enemy(d)
	d.queue_free()

# --- C. Levels -----------------------------------------------------------------------------

func _part_levels() -> void:
	var rates: Array[float] = []
	var rows: Array[String] = []
	for level in [1, 2, 3]:
		var g := _enemy(&"grunt", Vector3(1.5 * (level - 2), 0.05, -1.5), level)
		var rate := _tap_guard_rate(g, GUARD_TRIALS)
		var expected := Tuning.GUARD_TAP_CHANCE * Tuning.R8_LEVEL_BLOCK_MULT[level - 1]
		rates.append(rate)
		rows.append("L%d %.3f (expected %.3f)" % [level, rate, expected])
		check(absf(rate - expected) <= _tol(expected, GUARD_TRIALS),
			"grunt L%d at p 0 guards %.1f%% (expected %.1f%% = %.2f x %.1f)" % [
				level, rate * 100.0, expected * 100.0, Tuning.GUARD_TAP_CHANCE, Tuning.R8_LEVEL_BLOCK_MULT[level - 1]])
		if level == 3:
			var fc := g.combat as FakeCombat
			fc.fake_pressure = 0.5
			var r3 := _tap_guard_rate(g, GUARD_TRIALS)
			var e3 := expected * 0.5
			print("[ai] info: grunt L3 at p 0.5: %.3f (expected %.3f)" % [r3, e3])
			check(absf(r3 - e3) <= _tol(e3, GUARD_TRIALS), "grunt L3 at p 0.5 guards %.1f%% (expected %.1f%%: level and pressure multiply)" % [
				r3 * 100.0, e3 * 100.0])
		AttackDirector.unregister_enemy(g)
		g.queue_free()
	print("[ai] info: grunt tap guard rate by level: " + ", ".join(rows))
	check(rates[1] > rates[0] and rates[2] > rates[1], "level 2 and 3 grunts block more than level 1 (%.3f < %.3f < %.3f)" % [
		rates[0], rates[1], rates[2]])

# --- Helpers ---------------------------------------------------------------------------------

func _ticks(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

func _finish() -> void:
	AttackDirector.reset()
	AIBrain.test_seed = -1
	print("[ai] test_pressure_guard: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
