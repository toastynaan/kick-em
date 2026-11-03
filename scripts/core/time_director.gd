extends Node
## Autoload "TimeDirector": owns every change to Engine.time_scale (slow motion)
## and the real-time clock that all input windows and cooldowns use.
## OWNER: agent E (camera & time).
##
## Round 5 rules (Feel Reference: Defence and time > Time, in code, Slow-time
## table), with Round 7 (docs/Round 7 — Freeflow Combat.md: Hit feel):
## - The table is Tuning.SLOW_TIME. request(event) asks for one row; the old
##   request_slowmo(scale, seconds, priority) still works for older callers.
## - Only the strongest active request applies (lowest scale). Requests never
##   stack: two at 0.25x give 0.25x, never 0.0625x. Each request holds its scale
##   for its time, then eases back to 1.0 over its own ease. A stronger request
##   arriving later cuts in at once (slower is instant).
## - Cooldown: rows with "cooldown" respect a Tuning.SLOW_TIME_COOLDOWN gap of
##   1.0 at real speed after the last cooldown row has finished easing out. A
##   request that arrives while a cooldown row is still running joins it (the
##   strongest wins), so two events on the same frame never cancel each other.
##   Teleport, last kill and player death ignore the cooldown and do not start it.
## - A request that a stronger active one fully covers (it would never show) is
##   refused and starts no cooldown. KO rows are never refused.
## - The player keeps real time in any slow motion: player_time_factor() is
##   1 / Engine.time_scale. A KO (last kill, player death, legacy PRIO_KO) ends
##   that: the player slows with the world for the cinematic.
## - Triggers: TimeDirector requests the table itself from GameEvents:
##   hit_landed by the player with HitInfo.react == &"launch" (a Round 7 launch
##   payoff, a sprint-strike launch, a pursuit relaunch) -> &"finisher", once per
##   hit; the player's teleported &"counter" -> &"teleport" (the god path keeps
##   the teleport; a pursuit's teleport does not slow time); wall_broken on a
##   panel or pillar; limb_severed; last_kill; the player's fighter_died.
## - Round 7 removed Focus mode and parry. begin_focus() / end_focus() /
##   is_focus_active() stay as harmless no-ops (false) while callers remain;
##   the &"parry" row can still be requested directly.
## - AudioServer.playback_speed_scale always follows Engine.time_scale (F keeps
##   the player's own sounds at normal pitch with player_time_factor()).
## - Everything is timed in real seconds (now(), physics ticks). While the tree
##   is paused the timeline is frozen, so a pause never eats a KO.

## Legacy (request_slowmo callers): kept so older code and tests keep working.
signal slowmo_started(priority: int, scale: float)
signal slowmo_ended()
## Round 7: Focus mode is gone; never emitted. Kept while listeners remain.
signal focus_changed(active: bool)
## Round 5: a slow-time table row was granted (event = the Tuning.SLOW_TIME key,
## or &"legacy" for request_slowmo).
signal slow_time_started(event: StringName, scale: float)

const PRIO_DODGE := 1
const PRIO_BIG_LAUNCH := 2
const PRIO_WALL_BREAK := 3
const PRIO_KO := 4

## Rows that are a KO: the player slows with the world.
const KO_EVENTS: Array[StringName] = [&"last_kill", &"player_death"]
## Legacy priority each row reports through get_active_priority().
const _EVENT_PRIO := {&"parry": PRIO_DODGE, &"teleport": PRIO_DODGE, &"sever": PRIO_WALL_BREAK,
	&"wall_break": PRIO_WALL_BREAK, &"last_kill": PRIO_KO, &"player_death": PRIO_KO,
	&"finisher": PRIO_BIG_LAUNCH}
const _PRIO_NAMES := {1: "dodge", 2: "big launch", 3: "wall break", 4: "KO"}
const _EPS := 0.0005

## Active requests: {"event", "scale", "end" (hold end, real s), "ease", "ko", "cooldown", "prio"}.
## Dropped once eased out.
var _active: Array[Dictionary] = []
## Real time before which a cooldown row is refused (set when a cooldown row has
## eased out; see _refresh_cooldown).
var _cooldown_until := -INF
var _scale := 1.0
var _last_real := 0.0
var _frame_delta := 0.0
var _granted := 0
var _refused := 0
var _was_holding := false
var _last_event: StringName = &""
## Round 7: &"finisher" requests made from hit_landed (granted or not), and the
## last HitInfo that asked (one request per launch payoff hit).
var _finisher_requests := 0
var _finisher_info: HitInfo = null

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = -100
	_last_real = now()
	GameEvents.hit_landed.connect(_on_hit_landed)
	GameEvents.teleported.connect(_on_teleported)
	GameEvents.wall_broken.connect(_on_wall_broken)
	GameEvents.limb_severed.connect(_on_limb_severed)
	GameEvents.last_kill.connect(_on_last_kill)
	GameEvents.fighter_died.connect(_on_fighter_died)

## Real seconds since start. Every input window, cooldown and hitstop uses this,
## never scaled game time, so slow motion does not widen windows.
## Counted in physics ticks: ticks run at a fixed real-time rate whatever
## Engine.time_scale is, so this is real time in play and stays in step with the
## simulation under --fixed-fps and movie capture (where the wall clock does not).
func now() -> float:
	return Engine.get_physics_frames() / float(Engine.physics_ticks_per_second)

## Unscaled duration of the current rendered frame (seconds, clamped to 0.1).
## For visual smoothing (camera, HUD) only: it moves every frame, while now()
## advances in physics-tick steps. Gameplay windows keep using now().
func frame_delta() -> float:
	return _frame_delta

## Timer that ignores Engine.time_scale and keeps running during pause.
func real_timer(seconds: float) -> SceneTreeTimer:
	return get_tree().create_timer(seconds, true, false, true)

# --- The slow-time table ------------------------------------------------------------
## Ask for one Tuning.SLOW_TIME row (&"finisher", &"teleport", &"wall_break",
## &"sever", &"last_kill", &"player_death"; &"parry" is still in the table). Returns false when refused (cooldown, a stronger request covers it,
## unknown event). &"focus" is refused: Round 7 removed Focus mode.
func request(event: StringName) -> bool:
	if not Tuning.SLOW_TIME.has(event):
		push_warning("TimeDirector.request: unknown slow-time event %s" % event)
		return false
	if event == &"focus":
		return false
	var row: Dictionary = Tuning.SLOW_TIME[event]
	return _grant(event, float(row["scale"]), float(row["time"]), float(row["ease"]),
		bool(row["cooldown"]), KO_EVENTS.has(event), int(_EVENT_PRIO.get(event, PRIO_DODGE)))

## Legacy entry point: scale for duration_real s, eased out over
## Tuning.SLOWMO_EASE. PRIO_KO is a KO (ignores the cooldown, the player slows
## too); every other priority respects the cooldown. The old
## priority stack and 15% budget are gone: the strongest request wins.
func request_slowmo(scale: float, duration_real: float, priority: int) -> bool:
	var ko := priority >= PRIO_KO
	return _grant(&"legacy", scale, duration_real, Tuning.SLOWMO_EASE, not ko, ko, priority)

func _grant(event: StringName, scale: float, hold: float, ease_s: float, uses_cooldown: bool,
		ko: bool, prio: int) -> bool:
	var t := now()
	_prune(t)
	if hold <= 0.0:
		return false
	scale = clampf(scale, 0.01, 1.0)
	var end := t + hold
	if uses_cooldown and t < _cooldown_until and not _cooldown_row_running(t):
		_refuse(event)
		return false
	if not ko and _covered(scale, end):
		_refuse(event)
		return false
	# The same row again (a second teleport, D and the event both asking for one
	# wall break): extend it instead of adding a copy.
	var merged := false
	for r in _active:
		if r["event"] == event and r["prio"] == prio and is_equal_approx(float(r["scale"]), scale):
			r["end"] = maxf(float(r["end"]), end)
			merged = true
	if not merged:
		_active.append({"event": event, "scale": scale, "end": end, "ease": maxf(ease_s, 0.0),
			"ko": ko, "cooldown": uses_cooldown, "prio": prio})
	if uses_cooldown:
		_refresh_cooldown()
	_granted += 1
	_last_event = event
	_apply(t)
	slow_time_started.emit(event, scale)
	slowmo_started.emit(prio, scale)
	return true

func _refuse(_event: StringName) -> void:
	_refused += 1

## A stronger-or-equal request holds at least until `end`: the new one would
## never show.
func _covered(scale: float, end: float) -> bool:
	for r in _active:
		if float(r["scale"]) <= scale + _EPS and float(r["end"]) >= end - _EPS:
			return true
	return false

## A cooldown row is still holding or easing out (new cooldown rows may join it).
func _cooldown_row_running(t: float) -> bool:
	for r in _active:
		if r["cooldown"] and t < float(r["end"]) + float(r["ease"]):
			return true
	return false

## The gap starts when the last cooldown row has eased back to 1.0.
func _refresh_cooldown() -> void:
	for r in _active:
		if r["cooldown"]:
			_cooldown_until = maxf(_cooldown_until,
				float(r["end"]) + float(r["ease"]) + Tuning.SLOW_TIME_COOLDOWN)

# --- Focus (removed in Round 7) -------------------------------------------------------
## Round 7 removed Focus mode. These stay harmless while callers remain:
## begin_focus() is refused, end_focus() does nothing, is_focus_active() is false.
func begin_focus(_scale := 0.0) -> bool:
	return false

func end_focus() -> void:
	pass

func is_focus_active() -> bool:
	return false

## Player seconds per world second: 1 / Engine.time_scale in any slow motion
## (finisher, teleport, wall break, sever), so the player keeps real time; 1.0 at normal
## speed. 1 during a KO (last kill, player death): the player slows with the world.
func player_time_factor() -> float:
	if _ko_running(now()):
		return 1.0
	return 1.0 / maxf(Engine.time_scale, 0.01)

## The player's delta for a physics delta. Route every player timer, velocity,
## gravity and animation step through this so none is missed in slow motion.
func player_delta(delta: float) -> float:
	return delta * player_time_factor()

## Local hitstop: freezes only the given fighters (attacker and victim).
func hitstop(fighters: Array, duration_real: float) -> void:
	for f in fighters:
		if is_instance_valid(f) and f.has_method(&"freeze_hitstop"):
			f.freeze_hitstop(duration_real)

func is_slowmo() -> bool:
	return Engine.time_scale < 0.99

func get_scale() -> float:
	return Engine.time_scale

## Clears all slow motion and the cooldown (round restart).
func reset() -> void:
	_active.clear()
	_cooldown_until = -INF
	_scale = 1.0
	_was_holding = false
	_last_event = &""
	_last_real = now()
	_write()

# --- Introspection (debug overlay, camera, tests) ---------------------------------
## Legacy priority of the strongest holding request, 0 when none holds.
## A KO row reports PRIO_KO whatever its scale.
func get_active_priority() -> int:
	var t := now()
	if _ko_holding(t):
		return PRIO_KO
	var r := _strongest_holding(t)
	return int(r["prio"]) if not r.is_empty() else 0

## Table event of the strongest holding request, &"" when none.
func get_active_event() -> StringName:
	var r := _strongest_holding(now())
	return StringName(r["event"]) if not r.is_empty() else &""

func get_active_name() -> String:
	var e := get_active_event()
	return String(e) if e != &"" else "none"

## The most recent granted event (tests, camera).
func get_last_event() -> StringName:
	return _last_event

## Real seconds left before a cooldown row may start again (0 = free).
func get_cooldown_left() -> float:
	var t := now()
	if _cooldown_row_running(t):
		return 0.0
	return maxf(_cooldown_until - t, 0.0)

## True while a KO row (last kill, player death, legacy PRIO_KO) holds or eases out.
func is_ko_active() -> bool:
	return _ko_running(now())

func get_granted() -> int:
	return _granted

func get_refused() -> int:
	return _refused

## &"finisher" requests TimeDirector made from hit_landed (granted or refused).
func get_finisher_requests() -> int:
	return _finisher_requests

func get_debug_text() -> String:
	return "time %.2fx  slow-mo %s  player x%.2f  cooldown %.2f s  granted %d refused %d" % [
		Engine.time_scale, get_active_name(), player_time_factor(),
		get_cooldown_left(), _granted, _refused]

# --- Internals ---------------------------------------------------------------
func _process(delta: float) -> void:
	# delta was scaled by the time scale in effect when this frame started,
	# which is still Engine.time_scale here (this node runs first, priority -100).
	_frame_delta = clampf(delta / maxf(Engine.time_scale, 0.001), 0.0, 0.1)
	var t := now()
	var dt := t - _last_real
	_last_real = t
	if get_tree().paused and dt > 0.0:
		_shift_timeline(dt)
	_prune(t)
	_apply(t)

## Freeze the timeline while paused: push every end and the cooldown forward.
func _shift_timeline(dt: float) -> void:
	for r in _active:
		r["end"] = float(r["end"]) + dt
	if _cooldown_until > -INF:
		_cooldown_until += dt

func _prune(t: float) -> void:
	var i := _active.size() - 1
	while i >= 0:
		var r := _active[i]
		if t >= float(r["end"]) + float(r["ease"]):
			_active.remove_at(i)
		i -= 1
	var holding := not _strongest_holding(t).is_empty()
	if _was_holding and not holding:
		slowmo_ended.emit()
	_was_holding = holding

## Scale of one request at real time t: its scale while holding, then a
## smoothstep back to 1.0 over its ease.
static func _row_scale(r: Dictionary, t: float) -> float:
	var end := float(r["end"])
	if t < end:
		return float(r["scale"])
	var ease_s := float(r["ease"])
	if ease_s <= 0.0 or t >= end + ease_s:
		return 1.0
	return lerpf(float(r["scale"]), 1.0, smoothstep(0.0, 1.0, (t - end) / ease_s))

## World scale now: the strongest request. Never a product.
func _target_scale(t: float) -> float:
	var s := 1.0
	for r in _active:
		s = minf(s, _row_scale(r, t))
	return s

func _apply(t: float) -> void:
	var s := _target_scale(t)
	if not is_equal_approx(s, _scale) or not is_equal_approx(Engine.time_scale, s):
		_scale = s
		_write()

func _write() -> void:
	Engine.time_scale = _scale
	AudioServer.playback_speed_scale = _scale

func _strongest_holding(t: float) -> Dictionary:
	var best := {}
	for r in _active:
		if t < float(r["end"]) and (best.is_empty() or float(r["scale"]) < float(best["scale"])):
			best = r
	return best

func _ko_holding(t: float) -> bool:
	for r in _active:
		if r["ko"] and t < float(r["end"]):
			return true
	return false

func _ko_running(t: float) -> bool:
	for r in _active:
		if r["ko"] and t < float(r["end"]) + float(r["ease"]):
			return true
	return false

# --- Triggers (GameEvents) ------------------------------------------------------------
## Round 7: a launch payoff by the player (HitInfo.react == &"launch") asks for
## the finisher slow time, once per hit (the same HitInfo reported twice asks
## once). Enemy launches and the player's other reactions do not.
func _on_hit_landed(info: HitInfo) -> void:
	if info == null or info.react != &"launch" or not _is_player(info.attacker):
		return
	if info == _finisher_info:
		return
	_finisher_info = info
	_finisher_requests += 1
	request(&"finisher")

## Teleport slow time is the player's reward for a teleport counter (Dash just
## before an enemy's hit): only the player's own &"counter" teleports. An
## enemy's teleport or the player's pursuit teleport does not slow the world.
func _on_teleported(fighter: Node3D, _from: Vector3, _to: Vector3, kind: StringName) -> void:
	if kind == &"counter" and _is_player(fighter):
		request(&"teleport")

static func _is_player(n) -> bool:
	return is_instance_valid(n) and n is Node and (n as Node).is_in_group(&"player")

## A body through a wall (or a strike that broke the whole panel / opened its
## first hole). Follow-up strike holes in a panel and broken furniture (desks,
## crates: wall_broken fires for them too) do not slow time.
func _on_wall_broken(wall: Node3D, _position: Vector3, _energy: float, _velocity: Vector3) -> void:
	if is_real_wall(wall) and is_headline_break(wall):
		request(&"wall_break")

## A wall panel (Destructible kind &"panel") or a pillar, not furniture. An
## unknown or missing node counts as a wall (older emitters, tests).
func is_real_wall(wall) -> bool:
	if not is_instance_valid(wall) or not ("kind" in wall):
		return true
	var kind := StringName(wall.get(&"kind"))
	return kind == &"panel" or kind == &"pillar"

func _on_limb_severed(_fighter: Node3D, _cut: StringName, _piece: Node3D) -> void:
	request(&"sever")

func _on_last_kill(_fighter: Node3D) -> void:
	request(&"last_kill")

func _on_fighter_died(fighter: Node3D, _info: HitInfo) -> void:
	if _is_player(fighter):
		request(&"player_death")

## Same rule as the camera's WALL BREAK banner: impact breaks always; a
## strike-made break on the panel's first strike hole or a full break.
static func is_headline_break(wall) -> bool:
	if not is_instance_valid(wall) or not ("last_break_by_strike" in wall):
		return true
	if not bool(wall.get(&"last_break_by_strike")):
		return true
	var holes := int(wall.get(&"strike_holes")) if "strike_holes" in wall else 1
	var broken := bool(wall.get(&"is_broken")) if "is_broken" in wall else false
	return holes <= 1 or broken
