class_name Defence
extends Node
## Round 5 timed defence (Feel Reference: Defence and time): tap Block to
## parry, a fresh Dash in the same window to teleport behind (1 Focus) or
## sidestep, pursuit after a launch, and the counter bonus they give.
## OWNER: agent H (fighter, player & defence). CONTRACT STUB: keep every public signature.
##
## Contract:
## - Fighter creates this node for every fighter (setup(fighter)).
## - CombatController.press(BLOCK) calls on_block_pressed() before starting the
##   guard; press(DASH) calls on_dash_pressed() first and stops if it returns true.
##   While is_enabled() is false CombatController keeps its Upgrade 2 perfect-dodge,
##   teleport-counter and pursuit paths; H turns this on when the new defence works.
## - The attacker's CombatController calls intercepts() on the first active
##   frame of any attack (or grab) aimed at this fighter, before hit detection:
##   true = the attack misses (parried or teleported away).
## - CombatController adds counter_bonus() to P and calls consume_counter_bonus()
##   when the next hit lands. Hits on get_pursuit_target() use the pursuit
##   relaunch rule (Power.pursuit_speed).
##
## How it works (agent H):
## - Parry. Every Block press opens a window of Tuning.PARRY_WINDOW real s. An
##   attack aimed at this fighter whose first active frame falls inside an open,
##   unlocked window is parried, and that press then covers every other attack
##   whose first active frame falls inside the same window. A window that closes
##   with no attack in it locks parry for Tuning.PARRY_LOCKOUT from its press
##   (anti-mash: presses made inside a lock never parry, and they lock again
##   when they whiff). Holding Block is B's guard; only the press time matters
##   here. Grabs are never parried. Only the player and fighters whose archetype
##   has "perfect_dodge" (the Duelist) parry: every other Block press is a plain
##   guard (CombatController).
##   Success: the attacker is staggered (Fighter.stagger cancels its attack),
##   both freeze Tuning.PARRY_FREEZE, +Tuning.FOCUS_GAIN.parry Focus, the
##   counter bonus Tuning.COUNTER_BONUS_PARRY for Tuning.COUNTER_BONUS_TIME real
##   s, GameEvents.parried (FX flash, TimeDirector 0.5x).
## - Dash (player only), decided at the press:
##   1. An attack or grab aimed at this fighter whose first active frame is
##      predicted (CombatController.time_to_active, real s) within
##      Tuning.TELEPORT_WINDOW: with a full Focus bar, teleport behind the
##      attacker whose hit lands soonest (first free spot of Tuning.TELEPORT_SPOTS,
##      capsule query), facing its back, +Tuning.COUNTER_BONUS_TELEPORT; with
##      less, or no free spot (nothing spent), a Tuning.SIDESTEP_DIST sidestep.
##      Either way that attack misses.
##   2. Within Tuning.PURSUIT_WINDOW real s after one of this fighter's launches
##      left its hitstop, stick neutral or within Tuning.PURSUIT_STICK_CONE of the
##      flying body: pursuit (1 Focus, at most Tuning.PURSUIT_MAX per launch).
##      The player appears Tuning.PURSUIT_DIST from the body on the side away
##      from where the stick (else the flight) sends it next, at its height, and
##      hangs Tuning.PURSUIT_HANG (Traversal.hang / Fighter.hang) for the attack.
##   3. Anything else returns false: Traversal's short dash and sprint.
##   A held Dash (sprinting) never presses again, so it never spends Focus.
## - Presses that arrive while this fighter is frozen by hitstop wait and fire
##   the tick the freeze ends (Feel Reference: Contact frame).
## - Interception backstop: besides B's intercepts() calls, this node listens to
##   GameEvents.attack_active and runs the same decision for attacks aimed at
##   it (one decision per attack per tick, so a double call is harmless).

## Local tuning (candidates for Tuning).
const PARRY_STAGGER_STRENGTH := 0.85 ## stagger strength on a parried attacker (< 1: its legs stay animated)
const PARRY_POSE_TIME := 0.3         ## s of the parry deflect pose
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
const EPS := 1e-4

var fighter: Fighter

## Debug and tests.
var parries := 0
var parry_whiffs := 0
var teleports := 0
var sidesteps := 0
var pursuits := 0
var refunds := 0

## While false the Upgrade 2 defence in CombatController runs instead (debug).
static var enabled := true

# Parry.
var _presses: Array[Dictionary] = []   ## {t, locked, used}: Block presses with an open window
var _lock_until := -INF
var _cover_from := INF                  ## a successful parry press covers attacks in [from, until]
var _cover_until := -INF
var _last_press := -INF
# Presses held back by hitstop.
var _pending_block := false
var _pending_dash := false
# Counter bonus.
var _bonus := 0.0
var _bonus_until := -INF
var _bonus_kind: StringName = &""
var _counter_target: Fighter
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
# One decision per attack per tick.
var _decided := {}                      ## attacker id -> [physics frame, move id, result]

func setup(p_fighter: Fighter) -> void:
	fighter = p_fighter
	GameEvents.attack_active.connect(_on_attack_active)
	GameEvents.hit_landed.connect(_on_hit_landed)

func is_enabled() -> bool:
	return enabled

## The player and archetypes with "perfect_dodge" (the Duelist) parry; anyone
## else's Block press is a plain guard.
func can_parry() -> bool:
	return fighter != null and (fighter.is_player or bool(fighter.config.get("perfect_dodge", false)))

# =============================================================================
# Block: parry
# =============================================================================

## Every Block press (real time `now`): the parry attempt, or the anti-mash lockout.
func on_block_pressed(now: float) -> void:
	if fighter == null or fighter.is_dead() or not can_parry():
		return
	if fighter.is_frozen():
		_pending_block = true  # fires the tick the hitstop ends
		return
	_add_press(now)

func _add_press(now: float) -> void:
	_expire(now)
	_last_press = now
	_presses.append({"t": now, "locked": now < _lock_until - EPS, "used": false})

## Real time of the last Block press this node took (after any hitstop wait).
func last_block_press_time() -> float:
	return _last_press

func is_parry_locked() -> bool:
	if fighter == null:
		return false
	var now := TimeDirector.now()
	_expire(now)
	return now < _lock_until - EPS

## Close every press window that has passed: a window with no attack in it is a
## whiff and locks parry for Tuning.PARRY_LOCKOUT from its press.
func _expire(now: float) -> void:
	var i := 0
	while i < _presses.size():
		var p: Dictionary = _presses[i]
		var t: float = p["t"]
		if now - t <= Tuning.PARRY_WINDOW + EPS:
			i += 1
			continue
		_presses.remove_at(i)
		if p["used"]:
			continue
		var until := t + Tuning.PARRY_LOCKOUT
		_lock_until = maxf(_lock_until, until)
		for q: Dictionary in _presses:
			if float(q["t"]) > t and float(q["t"]) < until - EPS:
				q["locked"] = true
		if not p["locked"]:
			parry_whiffs += 1
			# Holding Block is a guard, not a missed parry: no whiff feedback.
			if not (fighter.combat != null and fighter.combat.is_blocking()):
				GameEvents.parry_whiffed.emit(fighter)

## The newest unlocked, unused press whose window contains `now` ({} if none).
func _press_in_window(now: float) -> Dictionary:
	for i in range(_presses.size() - 1, -1, -1):
		var p: Dictionary = _presses[i]
		if p["used"] or p["locked"]:
			continue
		var dt := now - float(p["t"])
		if dt >= -EPS and dt <= Tuning.PARRY_WINDOW + EPS:
			return p
	return {}

## Free to parry or teleport: on the feet (or jumping), not held, not in a hit
## reaction, not in this fighter's own active frames, hands free.
func _can_defend_now() -> bool:
	if fighter.is_dead() or fighter.is_down() or fighter.is_body_simulating():
		return false
	var c := fighter.combat
	if c == null or c.is_hit_stunned() or c.is_attack_active():
		return false
	return not (fighter.is_held() or fighter.is_holding() or (fighter.carry != null and fighter.carry.is_busy()))

func _parry(attacker: Fighter) -> void:
	parries += 1
	var c := fighter.combat
	if c.is_attacking():
		c.cancel()  # a parry cuts a wind-up, a charge or a recovery
	var dir := attacker.get_ground_position() - fighter.get_ground_position()
	dir.y = 0.0
	if dir.length_squared() < 1e-4:
		dir = fighter.get_forward()
	dir = dir.normalized()
	if fighter.can_act() or not c.is_attacking():
		fighter.snap_facing(dir)
	# The attacker reels back; Fighter.stagger cancels its attack (CombatController.on_reaction).
	attacker.stagger(dir, PARRY_STAGGER_STRENGTH)
	TimeDirector.hitstop([fighter, attacker], Tuning.PARRY_FREEZE)
	_set_bonus(Tuning.COUNTER_BONUS_PARRY, &"parry", attacker)
	fighter.add_focus(float(Tuning.FOCUS_GAIN[&"parry"]), &"parry")
	_play_pose([&"parry", &"block_hit"], PARRY_POSE_TIME)
	GameEvents.parried.emit(fighter, attacker)

# =============================================================================
# Interception (the attack's first active frame)
# =============================================================================

## On the first active frame of an attack aimed at this fighter. true = it misses.
func intercepts(attacker: Fighter, move_id: StringName) -> bool:
	if fighter == null or attacker == null or not is_instance_valid(attacker) or attacker == fighter:
		return false
	var frame := Engine.get_physics_frames()
	var key := attacker.get_instance_id()
	var seen: Array = _decided.get(key, [])
	if not seen.is_empty() and seen[0] == frame and seen[1] == move_id:
		return seen[2]
	var result := _decide(attacker, move_id)
	_decided[key] = [frame, move_id, result]
	return result

func _decide(attacker: Fighter, move_id: StringName) -> bool:
	if fighter.is_dead():
		return false
	var now := TimeDirector.now()
	if is_vanished():
		return true
	if attacker == _dodged and now <= _dodged_until + EPS:
		return true  # sidestepped or teleported away from this attack
	var m := MoveLibrary.get_move(move_id)
	if m != null and m.kind == &"grab":
		return false  # grabs can't be parried (break them, or teleport)
	if not can_parry() or not _can_defend_now():
		return false
	_expire(now)
	if now >= _cover_from - EPS and now <= _cover_until + EPS:
		_parry(attacker)  # the same press covers every attack in its window
		return true
	var p := _press_in_window(now)
	if p.is_empty():
		return false
	p["used"] = true
	_cover_from = float(p["t"])
	_cover_until = _cover_from + Tuning.PARRY_WINDOW
	_parry(attacker)
	return true

## Backstop for B's intercepts() call: the same decision on GameEvents.attack_active.
func _on_attack_active(attacker: Node3D, move_id: StringName) -> void:
	if not is_enabled() or fighter == null or fighter.is_dead():
		return
	var a := attacker as Fighter
	if a == null or a == fighter or a.team == fighter.team or not is_instance_valid(a):
		return
	if not (can_parry() or fighter.is_player):
		return
	if not _aimed_at_me(a, move_id):
		return
	intercepts(a, move_id)

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
# Dash: teleport, sidestep, pursuit
# =============================================================================

## Every fresh Dash press. true = consumed (teleport, sidestep or pursuit).
func on_dash_pressed(now: float) -> bool:
	if fighter == null or not fighter.is_player or fighter.is_dead():
		return false
	if fighter.is_frozen():
		_pending_dash = true  # re-pressed through CombatController the tick the hitstop ends
		return true
	return _dash(now)

func _dash(now: float) -> bool:
	var threat := _soonest_threat()
	if not threat.is_empty() and _can_defend_now():
		var attacker: Fighter = threat["attacker"]
		var tta: float = threat["tta"]
		if fighter.focus + EPS >= Tuning.TELEPORT_COST:
			var spot := _teleport_spot(attacker)
			if spot != Vector3.INF:
				_teleport(attacker, spot, tta, now)
				return true
			refunds += 1  # no room behind: sidestep, the bar stays
		_sidestep(attacker, tta, now)
		return true
	return _try_pursuit(now)

## The attack or grab aimed at this fighter whose first active frame comes
## soonest, if it is predicted inside Tuning.TELEPORT_WINDOW: {attacker, tta} or {}.
func _soonest_threat() -> Dictionary:
	var best := {}
	var best_t := INF
	for opp in Targeting.opponents_of(fighter):
		var c := opp.combat
		if c == null or not c.is_attacking() or c.is_attack_active() or c.is_in_recovery() or c.is_charging():
			continue
		var tta := c.time_to_active()
		if not is_finite(tta) or tta > Tuning.TELEPORT_WINDOW + EPS or tta >= best_t:
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
	fighter.spend_focus(Tuning.TELEPORT_COST)
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
	_set_bonus(Tuning.COUNTER_BONUS_TELEPORT, &"teleport", attacker)
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
	if v == _chain_victim and _chain >= Tuning.PURSUIT_MAX:
		return false  # at most PURSUIT_MAX pursuits chain off one launch
	if fighter.focus + EPS < Tuning.PURSUIT_COST or not _can_pursue_now():
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
	if fighter.is_dead() or fighter.is_down() or fighter.is_body_simulating():
		return false
	var c := fighter.combat
	if c == null or c.is_hit_stunned():
		return false
	return not (fighter.is_held() or fighter.is_holding() or (fighter.carry != null and fighter.carry.is_busy()))

func _start_pursuit(v: Fighter, want: Vector3, now: float) -> bool:
	if v == null or not is_instance_valid(v) or v.is_dead() or not v.is_launched() or not _can_pursue_now():
		return false
	if fighter.focus + EPS < Tuning.PURSUIT_COST:
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
	if not fighter.spend_focus(Tuning.PURSUIT_COST):
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

## Our launches (strikes, pursuit relaunches) open the pursuit window; any of
## our hits that lands uses up the counter bonus.
func _on_hit_landed(info: HitInfo) -> void:
	if info == null or fighter == null or info.attacker != fighter or info.result != HitInfo.Result.HIT:
		return
	if _bonus > 0.0:
		consume_counter_bonus()
	var v := info.victim as Fighter
	if v == null or not is_instance_valid(v):
		return
	var launch := HitInfo.is_launch_tier(info.tier) if info.tier != HitInfo.Tier.NONE \
		else info.reaction == HitInfo.Reaction.LAUNCH
	if v == _pursuit_target:
		_pursuit_target = null
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

# =============================================================================
# Counter bonus
# =============================================================================

func _set_bonus(value: float, kind: StringName, target: Fighter) -> void:
	_bonus = value
	_bonus_until = TimeDirector.now() + Tuning.COUNTER_BONUS_TIME
	_bonus_kind = kind
	_counter_target = target
	GameEvents.counter_bonus_changed.emit(fighter, value)

## Counter bonus to add to the next hit's P (0 when none).
func counter_bonus() -> float:
	if _bonus <= 0.0 or TimeDirector.now() > _bonus_until + EPS:
		return 0.0
	return _bonus

func consume_counter_bonus() -> void:
	if _bonus <= 0.0:
		return
	_bonus = 0.0
	_bonus_kind = &""
	_counter_target = null
	GameEvents.counter_bonus_changed.emit(fighter, 0.0)

## &"parry" or &"teleport" while a counter bonus is waiting, else &"".
func get_counter_kind() -> StringName:
	return _bonus_kind if counter_bonus() > 0.0 else &""

## The fighter the waiting counter bonus came from (a neutral stick aims the
## next strike at it: PlayerController.get_aim_dir). null when none.
func get_counter_target() -> Fighter:
	if counter_bonus() <= 0.0 or _counter_target == null or not is_instance_valid(_counter_target):
		return null
	if _counter_target.is_dead():
		return null
	return _counter_target

# =============================================================================
# Per tick
# =============================================================================

func _physics_process(_delta: float) -> void:
	if fighter == null:
		return
	var now := TimeDirector.now()
	if fighter.is_dead():
		_presses.clear()
		_pending_block = false
		_pending_dash = false
		_queued_pursuit = null
		_pursuit_target = null
		if _hidden:
			_set_hidden(false)
		return
	if not fighter.is_frozen():
		if _pending_block:
			_pending_block = false
			_add_press(now)
		if _pending_dash:
			_pending_dash = false
			_fire_pending_dash()
	_expire(now)
	if _hidden and (now >= _vanish_until or fighter.is_down() \
			or (fighter.combat != null and fighter.combat.is_attacking())):
		_set_hidden(false)
	if _bonus > 0.0 and now > _bonus_until + EPS:
		consume_counter_bonus()
	if _queued_pursuit != null and now >= _launch_free_at:
		var v := _queued_pursuit
		_queued_pursuit = null
		_start_pursuit(v, _queued_dir, now)
	if _pursuit_target != null and (now > _pursuit_until or not is_instance_valid(_pursuit_target)):
		_pursuit_target = null
	if _decided.size() > 16:
		_decided.clear()

## A Dash pressed during hitstop: press it again now, through CombatController,
## so Traversal gets it if Defence does not; let go at once if the button is up.
func _fire_pending_dash() -> void:
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

func get_debug_text() -> String:
	var parts: PackedStringArray = []
	if counter_bonus() > 0.0:
		parts.append("counter +%.1f (%s) %.2fs" % [_bonus, _bonus_kind, _bonus_until - TimeDirector.now()])
	if is_parry_locked():
		parts.append("parry locked")
	if get_pursuit_target() != null:
		parts.append("pursuit %d/%d" % [_chain, Tuning.PURSUIT_MAX])
	parts.append("parry %d whiff %d tele %d side %d purs %d" % [parries, parry_whiffs, teleports, sidesteps, pursuits])
	return "  ".join(parts)
