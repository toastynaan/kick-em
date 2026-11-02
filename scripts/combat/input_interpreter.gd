class_name InputInterpreter
extends Node
## The player's button reader (Upgrade 2: Input model > How a press is read).
## PlayerController calls poll() once per physics tick; it returns this tick's
## presses and releases in a fixed order, each stamped in player time: a clock
## that advances by TimeDirector.player_delta(), so a hold lasts as long in
## Focus as out of it. What a press means (tap or hold, charge level, combo
## string) is CombatController's call, not this node's.
##
## Presses made while Cmd (meta) is held are dropped together with their
## release, so macOS shortcuts (Cmd+Ctrl+F fullscreen, Cmd+Q) never also grab
## or block.
## OWNER: agent H (body & player input).

## A press or a release, as poll() reports it.
class ButtonEvent:
	var action: StringName
	var pressed: bool
	var time: float     ## player seconds (InputInterpreter.clock) of the press or release
	var held: float     ## release only: player seconds the button was down

	func _init(p_action: StringName, p_pressed: bool, p_time: float, p_held := 0.0) -> void:
		action = p_action
		pressed = p_pressed
		time = p_time
		held = p_held

	func _to_string() -> String:
		return "%s %s t=%.3f held=%.3f" % [action, "press" if pressed else "release", time, held]

## Every player button. Movement and Focus come first so a crouch or jump made
## on the same tick as an attack press is already in effect when the attack
## arrives (crouch + kick is the sweep, jump + kick the flying kick).
const ACTIONS: Array[StringName] = [&"crouch", &"jump", &"focus",
	&"punch", &"heavy", &"kick", &"grab", &"block", &"dash"]

## Player seconds since this node started (only advances while poll() runs).
var clock := 0.0
## Presses dropped because Cmd was held (debug, tests).
var dropped_presses := 0

var _down := {}          ## action -> clock at its accepted press (still held)
var _swallow := {}       ## action -> true: its press was dropped, so drop its release too
var _meta_event := {}    ## action -> true: a raw event with meta_pressed arrived since the last poll
var _last_press := {}    ## action -> clock
var _last_release := {}  ## action -> clock
var _last_hold := {}     ## action -> player seconds of the last completed hold

## Raw events carry their modifier state: a key or click that arrives with Cmd
## held is remembered here, so the poll drops it even if Cmd was let go first.
func _input(event: InputEvent) -> void:
	var m := event as InputEventWithModifiers
	if m == null or not m.meta_pressed or not event.is_pressed() or event.is_echo():
		return
	for a in ACTIONS:
		if InputMap.has_action(a) and event.is_action(a):
			_meta_event[a] = true

## Read this tick's button changes. `delta` is the physics delta (the clock
## advances by its player-time value). With `accept` false (input disabled:
## menus, round over) new presses are dropped and every held button is
## released once, so nothing stays held behind the player's back.
##
## Edges come from the action's state against our own record, not from
## Input.is_action_just_pressed alone: a press made by code after this tick's
## poll (Input.action_press from a bot) still counts on the next tick, and a
## press and release inside one tick (a very fast tap) gives both events.
func poll(delta: float, accept := true) -> Array[ButtonEvent]:
	clock += TimeDirector.player_delta(delta)
	var out: Array[ButtonEvent] = []
	var meta := is_meta_held()
	for a in ACTIONS:
		if not InputMap.has_action(a):
			continue
		var down := Input.is_action_pressed(a)
		var tapped := not down and Input.is_action_just_pressed(a)
		if (down or tapped) and not _down.has(a) and not _swallow.has(a):
			if not accept or meta or _meta_event.has(a):
				if accept:
					dropped_presses += 1
				_swallow[a] = true
			else:
				_down[a] = clock
				_last_press[a] = clock
				out.append(ButtonEvent.new(a, true, clock))
		_meta_event.erase(a)
		if _down.has(a) and (not down or not accept):
			out.append(_release(a))
			if down:
				_swallow[a] = true  # disabled while held: ignore the real key-up later
		elif not down:
			_swallow.erase(a)
	return out

## Release every held button now (returns the release events) and ignore
## their real key-ups.
func release_all() -> Array[ButtonEvent]:
	var out: Array[ButtonEvent] = []
	for a in ACTIONS:
		if _down.has(a):
			out.append(_release(a))
			_swallow[a] = true
	return out

func _release(a: StringName) -> ButtonEvent:
	var t0: float = _down[a]
	_down.erase(a)
	var held := clock - t0
	_last_release[a] = clock
	_last_hold[a] = held
	return ButtonEvent.new(a, false, clock, held)

# --- Queries -------------------------------------------------------------------
## Player time now (same clock as the event stamps).
func now() -> float:
	return clock

## True while an accepted press of `action` is still down.
func is_held(action: StringName) -> bool:
	return _down.has(action)

## Player seconds `action` has been held (0 when it is up).
func held_time(action: StringName) -> float:
	return clock - float(_down[action]) if _down.has(action) else 0.0

## Player time of the last accepted press (-INF if never).
func last_press_time(action: StringName) -> float:
	return float(_last_press.get(action, -INF))

## Player time of the last release (-INF if never).
func last_release_time(action: StringName) -> float:
	return float(_last_release.get(action, -INF))

## Player seconds the last completed press of `action` was held (-1 if none).
func last_hold(action: StringName) -> float:
	return float(_last_hold.get(action, -1.0))

## Cmd on macOS (the Windows key elsewhere).
static func is_meta_held() -> bool:
	return Input.is_key_pressed(KEY_META) or Input.is_physical_key_pressed(KEY_META)
