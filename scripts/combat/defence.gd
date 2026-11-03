class_name Defence
extends Node
## Round 7 defence (docs/Round 7 — Freeflow Combat.md: Defence, God path): the
## counter, plus the teleport and the pursuit on Dash (free: a cooldown and a
## chain cap, no Focus). The dodge and sprint are Traversal's (M). Parry,
## guard via Block, the plain sidestep (only the teleport's fallback remains)
## and the counter bonus are gone.
## OWNER: agent H (fighter, player & defence). CONTRACT STUB: keep every public signature.
##
## Contract:
## - Fighter creates this node for every fighter (setup(fighter)).
## - CombatController.press(COUNTER) calls on_counter_pressed(now) (real time).
## - CombatController.press(DASH) (not holding a body) calls on_dash_pressed(now)
##   first and stops if it returns true; else Traversal dodges or sprints.
## - Fighter.is_invulnerable() reads is_countering(); the attacker's
##   CombatController checks it on the first active frame of every attack, so
##   an attack starting inside the counter's invulnerability misses for good.
##   intercepts() answers the same question for callers that ask Defence.
##
## The counter:
## - Every enemy attack opens a counter window on its target
##   Tuning.R7_COUNTER_WINDOW before its first active frame, through its active
##   frames (the attacker's CombatController.is_counter_window_open(target));
##   grabs and the shoulder charge are uncounterable (is_attack_counterable()
##   false, a blue tell: dodge only).
## - A press with a counterable window open: the earliest such attack (soonest
##   first active frame) is countered. This fighter is invulnerable for
##   Tuning.R7_COUNTER_INVULN real s from the press, GameEvents.countered fires
##   (the caught move is still current), the attacker's attack is cancelled,
##   and CombatController.play_counter
##   (B) glides to the attacker and plays the counter move. Every other attack
##   whose first active frame falls inside the invulnerability misses (intercepts).
## - A press with no counterable window open is a whiff: the counter is locked
##   out for Tuning.R7_COUNTER_WHIFF_LOCK real s from it (GameEvents.counter_whiffed).
##   A press inside the lock does nothing, and with no window open it whiffs
##   again (mashing never counters).
## - Never while reacting, down, held, holding a body, in hitstun or in this
##   fighter's own active frames (those presses do nothing, no lock).
##
## Dash (on_dash_pressed, the player only), in this order:
## 1. Pursuit: within Tuning.PURSUIT_WINDOW real s after one of this fighter's
##    launches (strike, payoff, ram, throw: any hit_landed by it with a launch
##    tier) left its hitstop, stick neutral or within Tuning.PURSUIT_STICK_CONE
##    of the flying body, at most Tuning.debug_pursuit_max per flight (0 = off).
##    The player appears Tuning.PURSUIT_DIST from the body at its height and
##    hangs Tuning.PURSUIT_HANG (Fighter.hang) for the follow-up;
##    get_pursuit_target() names the body until B's pursuit hit lands
##    (on_pursuit_hit). A relaunch reopens the window; a spiked body
##    (HitInfo.react &"spike") is not pursuable again.
## 2. Teleport (Tuning.debug_teleport on, off Tuning.R7_TELEPORT_COOLDOWN): an
##    attack or grab aimed at this fighter whose first active frame is
##    predicted (CombatController.time_to_active, real s) within
##    Tuning.R7_TELEPORT_WINDOW: teleport behind the attacker whose hit lands
##    soonest (first free spot of Tuning.TELEPORT_SPOTS, capsule query), facing
##    its back; with no free spot, a Tuning.SIDESTEP_DIST sidestep. Either way
##    the player is invulnerable through that attack's first active frame (B
##    skips an invulnerable target for the whole attack) and intercepts()
##    answers true.
## 3. Anything else returns false (Traversal's dodge or sprint).
## A press during this fighter's hitstop waits and fires when the hitstop ends.

const EPS := 1e-4
## Teleport, sidestep and pursuit (Round 5, kept in Round 7; candidates for Tuning).
const TELEPORT_HIDE := 0.06          ## real s the body is hidden between vanish and appear
const TELEPORT_INVULN := 0.2         ## real s untouchable from the vanish
const SIDESTEP_TIME := 0.16          ## player s of the sidestep slide (SIDESTEP_DIST over this)
const SIDESTEP_POSE_TIME := 0.3      ## s of the sidestep pose (slide, then settle)
const APPEAR_POSE_TIME := 0.3        ## s of the appear pose behind the attacker (any attack cuts it)
const DODGE_ACTIVE_MARGIN := 0.05    ## real s past the dodged attack's active frames it still misses
const DODGE_INVULN_MAX := 0.35       ## real s: the sidestep's i-frames never last longer
const AIMED_MARGIN := 1.0            ## m beyond a move's reach in which an untargeted attack is aimed at you...
const AIMED_FRONT_DOT := 0.3         ## ...when the attacker faces you at least this much
const AIMED_LANE := 0.6              ## m beyond the move's reach_radius either side of a lunge's line that it still sweeps
const STICK_NEUTRAL := 0.3           ## stick length under which it counts as neutral
const PURSUIT_FEET_BELOW := 1.05     ## m (x height scale) the player's feet appear below the body's COM
const PURSUIT_STRIKE_GRACE := 0.35   ## real s after the hang in which the started attack still counts as the pursuit hit
const PURSUIT_TURNS: Array[float] = [0.0, 45.0, -45.0, 90.0, -90.0]  ## degrees tried around the preferred side
const LAUNCH_HITSTOP_FALLBACK := 0.11 ## real s when a launch HitInfo carries no hitstop
const SPOT_LIFT := 0.08              ## m the capsule query floats above the floor

var fighter: Fighter

## Debug and tests.
var counter_presses := 0  ## every on_counter_pressed() call (tests: the press got through)
var counters := 0
var whiffs := 0
var last_countered: Fighter
## CombatController.play_counter's answer for the last counter.
var last_counter_started := false
var teleports := 0
var sidesteps := 0
var pursuits := 0
var refunds := 0

## Round 7 keeps the defence on; the switch stays for old callers.
static var enabled := true

var _counter_until := -INF  ## real time: the counter's invulnerability ends
var _teleport_ready := -INF  ## real time: the next teleport may start (R7_TELEPORT_COOLDOWN)
var _lock_until := -INF     ## real time: the whiff lock ends
# Dash pressed during this fighter's hitstop (fires when it ends).
var _pending_dash := false
# Teleport / sidestep.
var _vanish_until := -INF
var _hidden := false
var _dodged: Fighter                    ## this attacker's current attack misses...
var _dodged_until := -INF               ## ...until here
# Pursuit.
var _launch_victim: Fighter
var _launch_at := -INF                  ## real time of the launch hit
var _launch_free_at := -INF             ## real time its hitstop ends (the body flies)
var _chain_victim: Fighter
var _chain := 0                         ## pursuits spent on _chain_victim's current flight
var _pursuit_target: Fighter
var _pursuit_until := -INF
var _queued_pursuit: Fighter            ## pressed during the launch's hitstop: starts when it ends
var _queued_dir := Vector3.ZERO

func setup(p_fighter: Fighter) -> void:
	fighter = p_fighter
	GameEvents.hit_landed.connect(_on_hit_landed)

func is_enabled() -> bool:
	return enabled

# =============================================================================
# Counter
# =============================================================================

## A Counter press (CombatController.press(COUNTER)), `now` in real time. True
## when it caught a counterable attack (CombatController.play_counter() has
## then been called).
func on_counter_pressed(now: float) -> bool:
	counter_presses += 1
	if fighter == null or fighter.is_dead() or not _can_counter_now():
		return false
	var attackers := get_counterable_attackers()
	if now < _lock_until - EPS:
		if attackers.is_empty():
			_whiff(now)  # mashing inside the lock keeps it locked
		return false
	if attackers.is_empty():
		_whiff(now)
		return false
	_counter(attackers[0], now)
	return true

## Inside the counter's invulnerability (Tuning.R7_COUNTER_INVULN).
func is_countering() -> bool:
	return fighter != null and not fighter.is_dead() and TimeDirector.now() < _counter_until

## The whiff lock is running (presses do nothing).
func is_counter_locked() -> bool:
	return TimeDirector.now() < _lock_until - EPS

## Attackers whose counterable window is open on this fighter now, earliest
## first active frame first (HUD prompts, bots).
func get_counterable_attackers() -> Array[Fighter]:
	return _open_windows(true)

## Attackers whose window is open on this fighter but cannot be countered (blue
## tell: grabs, the shoulder charge), earliest first.
func get_uncounterable_attackers() -> Array[Fighter]:
	return _open_windows(false)

## On the first active frame of an attack aimed at this fighter. true = it
## misses: the counter's invulnerability, a teleport's vanish, or the attack a
## teleport or sidestep dodged.
func intercepts(attacker: Fighter, _move_id: StringName) -> bool:
	if fighter == null or attacker == null or not is_instance_valid(attacker) or attacker == fighter:
		return false
	if is_countering() or is_vanished():
		return true
	return attacker == _dodged and TimeDirector.now() <= _dodged_until + EPS

func _counter(attacker: Fighter, now: float) -> void:
	counters += 1
	last_countered = attacker
	_counter_until = now + Tuning.R7_COUNTER_INVULN
	# Emitted before the cancel, so listeners (FX) still read the caught move
	# from attacker.combat.current_move_id().
	GameEvents.countered.emit(fighter, attacker)
	if attacker.combat != null:
		attacker.combat.cancel()
	last_counter_started = fighter.combat.play_counter(attacker) if fighter.combat != null else false

func _whiff(now: float) -> void:
	whiffs += 1
	_lock_until = now + Tuning.R7_COUNTER_WHIFF_LOCK
	GameEvents.counter_whiffed.emit(fighter)

## Free to counter: on the feet, not reacting or in hitstun, not held or
## holding, not in this fighter's own active frames (startup and recovery are
## fine: play_counter cancels them).
func _can_counter_now() -> bool:
	if fighter.is_down() or fighter.is_body_simulating() or fighter.is_in_hitstun():
		return false
	if fighter.is_holding() or (fighter.carry != null and fighter.carry.is_busy()):
		return false
	var c := fighter.combat
	return c != null and not c.is_attack_active()

## Opponents with an open window on this fighter whose counterability is
## `counterable`, sorted by time to their first active frame.
func _open_windows(counterable: bool) -> Array[Fighter]:
	var out: Array[Fighter] = []
	if fighter == null or not fighter.is_inside_tree():
		return out
	var times: Array[float] = []
	for opp in Targeting.opponents_of(fighter):
		var c := opp.combat
		if c == null or not c.is_counter_window_open(fighter):
			continue
		if c.is_attack_counterable() != counterable:
			continue
		var tta := c.time_to_active()
		if not is_finite(tta):
			tta = 0.0
		var i := 0
		while i < times.size() and times[i] <= tta:
			i += 1
		times.insert(i, tta)
		out.insert(i, opp)
	return out

func get_debug_text() -> String:
	var now := TimeDirector.now()
	var parts: PackedStringArray = []
	if is_countering():
		parts.append("countering %.2fs" % (_counter_until - now))
	if is_counter_locked():
		parts.append("counter locked %.2fs" % (_lock_until - now))
	var open := get_counterable_attackers().size()
	if open > 0:
		parts.append("windows %d" % open)
	if get_pursuit_target() != null:
		parts.append("pursuit %d/%d" % [_chain, Tuning.debug_pursuit_max])
	parts.append("counters %d whiffs %d tele %d side %d purs %d" % [counters, whiffs, teleports, sidesteps, pursuits])
	return "  ".join(parts)

# =============================================================================
# Dash: teleport, sidestep, pursuit (Round 5; kept in Round 7, routing to be decided)
# =============================================================================

## Every fresh Dash press. true = consumed (teleport, sidestep or pursuit).
func on_dash_pressed(now: float) -> bool:
	if fighter == null or not fighter.is_player or fighter.is_dead():
		return false
	if fighter.is_frozen():
		_pending_dash = true  # decided the tick the hitstop ends (_fire_pending_dash)
		return true
	return _dash(now)

func _dash(now: float) -> bool:
	if _try_pursuit(now):
		return true
	if not Tuning.debug_teleport or now < _teleport_ready - EPS:
		return false
	var threat := _soonest_threat()
	if threat.is_empty() or not _can_defend_now():
		return false
	var attacker: Fighter = threat["attacker"]
	var tta: float = threat["tta"]
	_teleport_ready = now + Tuning.R7_TELEPORT_COOLDOWN
	var spot := _teleport_spot(attacker)
	if spot != Vector3.INF:
		_teleport(attacker, spot, tta, now)
	else:
		refunds += 1  # no room anywhere around the attacker: sidestep instead
		_sidestep(attacker, tta, now)
	return true

## Real seconds before the teleport may start again (0 = ready).
func get_teleport_cooldown() -> float:
	return maxf(_teleport_ready - TimeDirector.now(), 0.0)

## The attack or grab aimed at this fighter whose first active frame comes
## soonest, if it is predicted inside Tuning.R7_TELEPORT_WINDOW: {attacker, tta} or {}.
func _soonest_threat() -> Dictionary:
	var best := {}
	var best_t := INF
	for opp in Targeting.opponents_of(fighter):
		var c := opp.combat
		if c == null or not c.is_attacking() or c.is_attack_active() or c.is_in_recovery() or c.is_charging():
			continue
		var tta := c.time_to_active()
		if not is_finite(tta) or tta > Tuning.R7_TELEPORT_WINDOW + EPS or tta >= best_t:
			continue
		if not _aimed_at_me(opp, c.current_move_id()):
			continue
		best_t = tta
		best = {"attacker": opp, "tta": tta}
	return best

## First free spot of Tuning.TELEPORT_SPOTS (side, behind) around `attacker`, or INF.
func _teleport_spot(attacker: Fighter) -> Vector3:
	var ap := attacker.get_ground_position()
	var fwd := attacker.get_forward()
	var right := fwd.cross(Vector3.UP).normalized()
	for s: Vector2 in Tuning.TELEPORT_SPOTS:
		var p := ap - fwd * s.y + right * s.x
		if _capsule_fits(p):
			return p
	return Vector3.INF

func _teleport(attacker: Fighter, spot: Vector3, tta: float, now: float) -> void:
	teleports += 1
	var c := fighter.combat
	if c.is_attacking():
		c.cancel()
	var from := fighter.global_position
	fighter.reset_air_state()
	fighter.teleport_to(spot, attacker.get_ground_position() - spot)
	_vanish_until = now + TELEPORT_HIDE
	_set_hidden(true)
	fighter.invuln_until = maxf(fighter.invuln_until, now + TELEPORT_INVULN)
	_dodge(attacker, tta, now)
	# B checks Fighter.is_invulnerable() on the first active frame: cover it.
	fighter.invuln_until = maxf(fighter.invuln_until, now + minf(maxf(tta, 0.0) + DODGE_ACTIVE_MARGIN, DODGE_INVULN_MAX))
	_play_pose([&"appear"], APPEAR_POSE_TIME)
	GameEvents.teleported.emit(fighter, from, spot, &"counter")

## Tuning.SIDESTEP_DIST across the attack line: toward the stick's side when it
## has one, else the side with room. The dodged attack misses.
func _sidestep(attacker: Fighter, tta: float, now: float) -> void:
	sidesteps += 1
	var away := fighter.get_ground_position() - attacker.get_ground_position()
	away.y = 0.0
	if away.length_squared() < 1e-4:
		away = -fighter.get_forward()
	away = away.normalized()
	var side := Vector3(-away.z, 0.0, away.x)
	var stick := _stick()
	if stick.length() > STICK_NEUTRAL and absf(stick.normalized().dot(side)) > 0.2:
		if stick.dot(side) < 0.0:
			side = -side
	else:
		var here := fighter.get_ground_position()
		if not _capsule_fits(here + side * Tuning.SIDESTEP_DIST) \
				and _capsule_fits(here - side * Tuning.SIDESTEP_DIST):
			side = -side
	var c := fighter.combat
	if c.is_attacking():
		c.cancel()
	fighter.knockback(side * (Tuning.SIDESTEP_DIST / SIDESTEP_TIME), SIDESTEP_TIME, true)
	_dodge(attacker, tta, now)
	var cover := minf(_dodged_until - now, DODGE_INVULN_MAX)
	fighter.invuln_until = maxf(fighter.invuln_until, now + cover)
	var right := fighter.get_forward().cross(Vector3.UP)
	var step_pose: StringName = &"sidestep_r" if side.dot(right) >= 0.0 else &"sidestep_l"
	_play_pose([step_pose, &"sidestep", &"dodge"], SIDESTEP_POSE_TIME)
	GameEvents.sidestepped.emit(fighter, side)

## `attacker`'s current attack misses this fighter through its active frames.
func _dodge(attacker: Fighter, tta: float, now: float) -> void:
	var active := Tuning.frames(4.0)
	var m := MoveLibrary.get_move(attacker.combat.current_move_id()) if attacker.combat else null
	if m != null:
		active = m.active_s() / maxf(Engine.time_scale, 0.05)
	_dodged = attacker
	_dodged_until = now + maxf(tta, 0.0) + active + DODGE_ACTIVE_MARGIN

## Pursuit after one of this fighter's launches (see the class doc).
func _try_pursuit(now: float) -> bool:
	var v := _launch_victim
	if v == null or not is_instance_valid(v) or v.is_dead() or not v.is_launched():
		return false
	if now < _launch_at - EPS or now > _launch_free_at + Tuning.PURSUIT_WINDOW + EPS:
		return false
	if v == _chain_victim and _chain >= Tuning.debug_pursuit_max:
		return false  # at most debug_pursuit_max pursuits chain off one flight (0 = off)
	if Tuning.debug_pursuit_max <= 0 or not _can_pursue_now():
		return false
	var to := v.get_center_of_mass() - fighter.get_center_of_mass()
	to.y = 0.0
	var stick := _stick()
	if stick.length() > STICK_NEUTRAL and to.length() > 0.1:
		if rad_to_deg(stick.normalized().angle_to(to.normalized())) > Tuning.PURSUIT_STICK_CONE:
			return false  # pointing away: a sprint, not a pursuit
	var want := stick.normalized() if stick.length() > STICK_NEUTRAL else Vector3.ZERO
	if now < _launch_free_at:
		_queued_pursuit = v  # still in its hitstop: appear once it flies
		_queued_dir = want
		return true
	return _start_pursuit(v, want, now)

## The player may pursue from any non-active part of its own attack (the
## launch's recovery included), but not while down, held or reeling.
func _can_pursue_now() -> bool:
	if fighter.is_dead() or fighter.is_down() or fighter.is_body_simulating() or fighter.is_reacting():
		return false
	var c := fighter.combat
	if c == null or c.is_hit_stunned():
		return false
	return not (fighter.is_held() or fighter.is_holding() or (fighter.carry != null and fighter.carry.is_busy()))

func _start_pursuit(v: Fighter, want: Vector3, now: float) -> bool:
	if v == null or not is_instance_valid(v) or v.is_dead() or not v.is_launched() or not _can_pursue_now():
		return false
	var com := v.get_center_of_mass()
	if want.length_squared() < 1e-4:
		# Stick neutral: keep the body flying the way it goes.
		var vel := v.get_com_velocity()
		want = Vector3(vel.x, 0.0, vel.z)
		if want.length() < 1.0:
			want = com - fighter.global_position
			want.y = 0.0
	want = want.normalized() if want.length_squared() > 1e-4 else fighter.get_forward()
	var flat := Vector3(com.x, 0.0, com.z)
	var spot := Vector3.INF
	for deg in PURSUIT_TURNS:
		var d := want.rotated(Vector3.UP, deg_to_rad(deg))
		var p := flat - d * Tuning.PURSUIT_DIST
		var floor_y := _floor_y(Vector3(p.x, com.y + 0.5, p.z))
		if is_nan(floor_y):
			continue
		p.y = maxf(floor_y, com.y - PURSUIT_FEET_BELOW * fighter.get_height_scale())
		if _capsule_fits(p, false):
			spot = p
			break
	if spot == Vector3.INF:
		return false
	pursuits += 1
	if v != _chain_victim:
		_chain_victim = v
		_chain = 0
	_chain += 1
	var c := fighter.combat
	if c.is_attacking():
		c.cancel()
	var from := fighter.global_position
	fighter.teleport_to(spot, com - spot)
	fighter.hang(Tuning.PURSUIT_HANG)
	_pursuit_target = v
	_pursuit_until = now + Tuning.PURSUIT_HANG + PURSUIT_STRIKE_GRACE
	_launch_victim = null  # this launch's window is used; the relaunch opens the next
	GameEvents.teleported.emit(fighter, from, spot, &"pursuit")
	GameEvents.pursuit.emit(fighter, v)
	return true

## The flying body a pursuit is chasing (null when none).
func get_pursuit_target() -> Fighter:
	if _pursuit_target == null or not is_instance_valid(_pursuit_target):
		return null
	if TimeDirector.now() > _pursuit_until or _pursuit_target.is_dead():
		return null
	return _pursuit_target

## CombatController: the pursuit follow-up hit `victim`.
func on_pursuit_hit(victim: Fighter) -> void:
	if victim == _pursuit_target:
		_pursuit_target = null

## Pursuits spent on the current flight of `victim` (tests, HUD).
func pursuit_chain(victim: Fighter) -> int:
	return _chain if victim != null and victim == _chain_victim else 0

## Our launches (strikes, Round 7 launch payoffs, pursuit relaunches) open
## the pursuit window.
func _on_hit_landed(info: HitInfo) -> void:
	if info == null or fighter == null or info.attacker != fighter or info.result != HitInfo.Result.HIT:
		return
	var v := info.victim as Fighter
	if v == null or not is_instance_valid(v):
		return
	if v == _pursuit_target:
		_pursuit_target = null
	if info.react == &"spike":
		# A spiked body is driven into the floor: not pursuable again this flight.
		if v == _launch_victim:
			_launch_victim = null
		if v == _queued_pursuit:
			_queued_pursuit = null
		return
	var launch := HitInfo.is_launch_tier(info.tier) if info.tier != HitInfo.Tier.NONE \
		else info.reaction == HitInfo.Reaction.LAUNCH
	if not launch or v.is_dead():
		return
	var now := TimeDirector.now()
	# A fresh flight starts a new chain; a relaunch in the same flight keeps it.
	if v != _chain_victim or (v.flight_launches <= 1 and not info.pursuit):
		_chain_victim = v
		_chain = 0
	var stop := info.hitstop if info.hitstop > 0.0 else Power.hitstop_for(info.tier)
	if stop <= 0.0:
		stop = LAUNCH_HITSTOP_FALLBACK
	_launch_victim = v
	_launch_at = now
	_launch_free_at = now + stop

## Free to teleport or sidestep: on the feet (or jumping), not held, not in a hit
## reaction (Round 5 or Round 7), not in this fighter's own active frames, hands free.
func _can_defend_now() -> bool:
	if fighter.is_dead() or fighter.is_down() or fighter.is_body_simulating() or fighter.is_reacting():
		return false
	var c := fighter.combat
	if c == null or c.is_hit_stunned() or c.is_attack_active():
		return false
	return not (fighter.is_held() or fighter.is_holding() or (fighter.carry != null and fighter.carry.is_busy()))

## The attack of `a` is aimed at this fighter: its target (CombatController.
## get_attack_target), else this fighter is inside the move's reach (plus
## AIMED_MARGIN) in front of the attacker, or inside the ground the attack
## will still cover before its active frames end: a charging attacker (the
## heavy's shoulder charge lunges ~4 m) threatens you from well beyond its reach.
func _aimed_at_me(a: Fighter, move_id: StringName) -> bool:
	var c := a.combat
	if c != null and c.has_method(&"get_attack_target"):
		var t: Fighter = c.get_attack_target()
		if t != null and is_instance_valid(t):
			return t == fighter
	var m := MoveLibrary.get_move(move_id)
	var hs := a.get_height_scale()
	var reach := (m.reach if m != null else 1.2) * hs + AIMED_MARGIN
	var to := fighter.get_ground_position() - a.get_ground_position()
	to.y = 0.0
	var d := to.length()
	if d < 0.05:
		return true
	var fwd := a.get_forward()
	if d <= reach:
		return fwd.dot(to / d) >= AIMED_FRONT_DOT
	# Beyond the reach: in front, near the line of the attack, and no further
	# than the reach plus the distance still to come.
	var along := fwd.dot(to)
	var side := (to - fwd * along).length()
	var lane := (m.reach_radius if m != null else 0.4) * hs + AIMED_LANE
	return along > 0.0 and side <= lane and along <= reach + _approach_left(a, m)

## Metres `a` will still close before its current attack's active frames end:
## the move's own lunge (MoveData.lunge_speed, in the attacker's time), or its
## present closing speed, whichever is more.
func _approach_left(a: Fighter, m: MoveData) -> float:
	var c := a.combat
	if c == null or m == null:
		return 0.0
	var tta := c.time_to_active()
	if not is_finite(tta):
		return 0.0
	var game_left := maxf(tta, 0.0) * Engine.time_scale + m.active_s()  # attacker's own seconds
	var lunge := m.lunge_speed * a.get_height_scale() * game_left
	var vel := a.velocity
	var closing := maxf(Vector3(vel.x, 0.0, vel.z).dot(a.get_forward()), 0.0) * game_left
	return maxf(lunge, closing)

# =============================================================================
# Per tick
# =============================================================================

func _physics_process(_delta: float) -> void:
	if fighter == null:
		return
	var now := TimeDirector.now()
	if fighter.is_dead():
		_pending_dash = false
		_queued_pursuit = null
		_pursuit_target = null
		if _hidden:
			_set_hidden(false)
		return
	if _pending_dash and not fighter.is_frozen():
		_pending_dash = false
		_fire_pending_dash()
	if _hidden and (now >= _vanish_until or fighter.is_down() \
			or (fighter.combat != null and fighter.combat.is_attacking())):
		_set_hidden(false)
	if _queued_pursuit != null and now >= _launch_free_at:
		var v := _queued_pursuit
		_queued_pursuit = null
		_start_pursuit(v, _queued_dir, now)
	if _pursuit_target != null and (now > _pursuit_until or not is_instance_valid(_pursuit_target)):
		_pursuit_target = null

## A Dash pressed during hitstop: Defence decides now; if it does not take it,
## press Dash again through CombatController (Traversal's dodge or sprint) and
## let go at once if the button is up.
func _fire_pending_dash() -> void:
	if _dash(TimeDirector.now()):
		return
	var c := fighter.combat
	if c == null:
		return
	c.press(CombatController.Action.DASH)
	var held := true
	var pc := fighter.brain as PlayerController
	if pc != null and pc.interpreter != null:
		held = pc.interpreter.is_held(&"dash")
	if not held:
		c.release(CombatController.Action.DASH)

# =============================================================================
# Helpers
# =============================================================================

## Vanished mid-teleport (untouchable, hidden).
func is_vanished() -> bool:
	return TimeDirector.now() < _vanish_until

func _set_hidden(on: bool) -> void:
	_hidden = on
	if fighter.rig:
		fighter.rig.set_body_visible(not on)

func _stick() -> Vector3:
	if fighter.brain != null and fighter.brain.has_method(&"get_stick_world"):
		var s: Vector3 = fighter.brain.get_stick_world()
		return Vector3(s.x, 0.0, s.z)
	return Vector3(fighter.move_input.x, 0.0, fighter.move_input.z)

## A standing capsule of this fighter's size fits at floor point `p`: clear of
## walls, props and other capsules, with floor under it (unless `need_floor`
## is false: a pursuit spot hangs in the air).
func _capsule_fits(p: Vector3, need_floor := true) -> bool:
	if not fighter.is_inside_tree():
		return false
	var space := fighter.get_world_3d().direct_space_state
	var own := fighter.capsule.shape as CapsuleShape3D if fighter.capsule else null
	var cap := CapsuleShape3D.new()
	cap.radius = own.radius if own else Fighter.CAPSULE_RADIUS
	cap.height = maxf(fighter.get_height() - 0.1, cap.radius * 2.0)
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = cap
	q.transform = Transform3D(Basis(), p + Vector3.UP * (cap.height * 0.5 + SPOT_LIFT))
	q.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE | Layers.CAPSULE
	q.exclude = [fighter.get_rid()]
	if not space.intersect_shape(q, 1).is_empty():
		return false
	if not need_floor:
		return true
	return not is_nan(_floor_y(p + Vector3.UP * 0.5, 1.5))

## Floor height under `from` (NAN when none within `depth`).
func _floor_y(from: Vector3, depth := 40.0) -> float:
	var space := fighter.get_world_3d().direct_space_state
	var ray := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * depth, Layers.WORLD | Layers.DESTRUCTIBLE)
	var hit := space.intersect_ray(ray)
	return NAN if hit.is_empty() else (hit["position"] as Vector3).y

## Play the first pose of `ids` the library has, over `duration` s.
func _play_pose(ids: Array[StringName], duration: float) -> void:
	if fighter.animator == null:
		return
	for id in ids:
		if PoseLibrary.has_move(id):
			fighter.animator.play_timed(id, duration)
			return
