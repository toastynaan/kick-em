extends Node
## Autoload "TimeDirector": owns every change to Engine.time_scale (slow motion)
## and the real-time clock that all input windows and cooldowns use.
## OWNER: agent E (feel & flow).
##
## Rules (spec: Game feel > Slow motion triggers):
## - Requests sit on a priority stack (KO > wall break > big launch > dodge).
##   A lower-priority request is refused while a higher one is active. A request
##   of the same priority refreshes the active one. When the top request ends,
##   the scale of the request below it is restored, not 1.0.
## - Budget: non-KO slow motion may cover at most Tuning.SLOWMO_BUDGET_FRACTION
##   of any Tuning.SLOWMO_BUDGET_WINDOW s of real time. A request that would
##   break the budget is refused. KO requests ignore and do not use the budget.
## - Going slower is instant; going faster eases over Tuning.SLOWMO_EASE s.
## - AudioServer.playback_speed_scale always follows Engine.time_scale.
## - Everything is timed in real seconds (now(), physics ticks). While the tree
##   is paused the slow-motion timeline is frozen, so a pause never eats a KO.

signal slowmo_started(priority: int, scale: float)
signal slowmo_ended()

const PRIO_DODGE := 1
const PRIO_BIG_LAUNCH := 2
const PRIO_WALL_BREAK := 3
const PRIO_KO := 4

const _PRIO_NAMES := {1: "dodge", 2: "big launch", 3: "wall break", 4: "KO"}
const _EPS := 0.0005

## Active requests, sorted by ascending priority. {"scale", "priority", "end"}
var _stack: Array[Dictionary] = []
## Granted non-KO requests as real-time intervals (x = start, y = end).
var _log: Array[Vector2] = []
var _scale := 1.0
var _ease_from := 1.0
var _ease_to := 1.0
var _ease_start := -1.0   ## real time the current ease began; < 0 when not easing
var _last_real := 0.0
var _frame_delta := 0.0
var _granted := 0
var _refused := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = -100
	_last_real = now()

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

## Request slow motion. Returns false if refused (budget or lower priority).
## Ending a request restores the scale below it in the stack, not 1.0.
func request_slowmo(scale: float, duration_real: float, priority: int) -> bool:
	var t := now()
	_prune(t)
	if duration_real <= 0.0:
		return false
	scale = clampf(scale, 0.01, 1.0)
	if priority < get_active_priority():
		_refused += 1
		return false
	var end := t + duration_real
	if priority != PRIO_KO:
		var candidate := _log.duplicate()
		candidate.append(Vector2(t, end))
		if _max_window_coverage(candidate, t) > get_budget_seconds() + _EPS:
			_refused += 1
			return false
		_log.append(Vector2(t, end))
	var replaced := false
	for r in _stack:
		if r["priority"] == priority:
			r["end"] = maxf(r["end"], end)
			r["scale"] = minf(r["scale"], scale)
			replaced = true
	if not replaced:
		_stack.append({"scale": scale, "priority": priority, "end": end})
		_stack.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["priority"] < b["priority"])
	_granted += 1
	_apply(t)
	slowmo_started.emit(priority, scale)
	return true

## Local hitstop: freezes only the given fighters (attacker and victim).
func hitstop(fighters: Array, duration_real: float) -> void:
	for f in fighters:
		if is_instance_valid(f) and f.has_method(&"freeze_hitstop"):
			f.freeze_hitstop(duration_real)

func is_slowmo() -> bool:
	return Engine.time_scale < 0.99

func get_scale() -> float:
	return Engine.time_scale

## Clears all slow motion (round restart).
func reset() -> void:
	_stack.clear()
	_log.clear()
	_ease_start = -1.0
	_scale = 1.0
	_ease_to = 1.0
	_last_real = now()
	_write()

# --- Introspection (debug overlay, tests) -------------------------------------
## Priority of the top active request, 0 when none.
func get_active_priority() -> int:
	return _stack.back()["priority"] if not _stack.is_empty() else 0

func get_active_name() -> String:
	return _PRIO_NAMES.get(get_active_priority(), "none")

## Real seconds of slow motion allowed per budget window.
func get_budget_seconds() -> float:
	return Tuning.SLOWMO_BUDGET_FRACTION * Tuning.SLOWMO_BUDGET_WINDOW

## Real seconds of budgeted slow motion in the last window, including what the
## active requests have already been granted into the future.
func get_budget_used() -> float:
	var t := now()
	return _coverage(_log, t - Tuning.SLOWMO_BUDGET_WINDOW, INF)

## 0..1 share of the budget in use.
func get_budget_fraction() -> float:
	return get_budget_used() / maxf(get_budget_seconds(), 0.001)

func get_debug_text() -> String:
	return "time %.2fx  slow-mo %s  budget %.2f/%.2f s  granted %d refused %d" % [
		Engine.time_scale, get_active_name(), get_budget_used(), get_budget_seconds(),
		_granted, _refused]

# --- Internals ---------------------------------------------------------------
func _process(delta: float) -> void:
	# delta was scaled by the time scale in effect when this frame started,
	# which is still Engine.time_scale here (this node runs first, priority -100).
	_frame_delta = clampf(delta / maxf(Engine.time_scale, 0.001), 0.0, 0.1)
	var t := now()
	var dt := t - _last_real
	_last_real = t
	if get_tree().paused and dt > 0.0:
		_shift_timeline(t, dt)
	_prune(t)
	_update_ease(t)

## Freeze the slow-motion timeline while paused: push every live end (and the
## ease) forward by the paused time.
func _shift_timeline(t: float, dt: float) -> void:
	for r in _stack:
		r["end"] += dt
	for i in _log.size():
		var iv := _log[i]
		if iv.y > t - dt:
			_log[i] = Vector2(iv.x + dt if iv.x > t - dt else iv.x, iv.y + dt)
	if _ease_start >= 0.0:
		_ease_start += dt

func _prune(t: float) -> void:
	var before := _stack.size()
	var i := _stack.size() - 1
	while i >= 0:
		if _stack[i]["end"] <= t:
			_stack.remove_at(i)
		i -= 1
	if _stack.size() != before:
		_apply(t)
		if _stack.is_empty():
			slowmo_ended.emit()
	var keep_after := t - Tuning.SLOWMO_BUDGET_WINDOW * 2.0
	i = _log.size() - 1
	while i >= 0:
		if _log[i].y < keep_after:
			_log.remove_at(i)
		i -= 1

## Point the scale at the top request: slower is instant, faster eases.
func _apply(t: float) -> void:
	var target := 1.0
	if not _stack.is_empty():
		target = _stack.back()["scale"]
	if target <= _scale:
		_scale = target
		_ease_start = -1.0
		_ease_to = target
		_write()
	elif not (_ease_start >= 0.0 and is_equal_approx(_ease_to, target)):
		_ease_from = _scale
		_ease_to = target
		_ease_start = t

func _update_ease(t: float) -> void:
	if _ease_start < 0.0:
		return
	var k := clampf((t - _ease_start) / maxf(Tuning.SLOWMO_EASE, 0.001), 0.0, 1.0)
	_scale = lerpf(_ease_from, _ease_to, smoothstep(0.0, 1.0, k))
	if k >= 1.0:
		_scale = _ease_to
		_ease_start = -1.0
	_write()

func _write() -> void:
	Engine.time_scale = _scale
	AudioServer.playback_speed_scale = _scale

## Largest coverage of any budget window that touches the newest interval.
## The max of a sliding window over a union of intervals is reached when the
## window starts at some interval start or ends at some interval end.
func _max_window_coverage(intervals: Array, t: float) -> float:
	var w := Tuning.SLOWMO_BUDGET_WINDOW
	var best := 0.0
	for iv: Vector2 in intervals:
		if iv.y < t - w:
			continue
		best = maxf(best, _coverage(intervals, iv.y - w, iv.y))
		best = maxf(best, _coverage(intervals, iv.x, iv.x + w))
	return best

## Measure of the union of `intervals` clipped to [a, b].
func _coverage(intervals: Array, a: float, b: float) -> float:
	var clipped: Array[Vector2] = []
	for iv: Vector2 in intervals:
		var s := maxf(iv.x, a)
		var e := minf(iv.y, b)
		if e > s:
			clipped.append(Vector2(s, e))
	if clipped.is_empty():
		return 0.0
	clipped.sort_custom(func(p: Vector2, q: Vector2) -> bool: return p.x < q.x)
	var total := 0.0
	var cur := clipped[0]
	for k in range(1, clipped.size()):
		var iv := clipped[k]
		if iv.x <= cur.y:
			cur.y = maxf(cur.y, iv.y)
		else:
			total += cur.y - cur.x
			cur = iv
	total += cur.y - cur.x
	return total
