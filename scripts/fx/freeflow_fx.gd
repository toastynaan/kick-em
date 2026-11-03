extends Node
## Round 7 effects (docs/Round 7 — Freeflow Combat.md, Effects and Hit feel).
## A child of BloodFX ("FreeflowFX"); every effect listens to GameEvents and
## spawns on the event's physics frame. The weight-scaled contact flash is
## BloodFX's hit_landed; the screen flash, after-image and speed streaks are
## ScreenFX's; the sounds AudioFX's.
## - hit_landed, a Round 7 hit with HitInfo.push >= PUSH_DUST_FROM: dust at the
##   victim's feet kicked along the push, and a short skid trail of dust puffs
##   that follows its feet through the slide (Tuning.R7_PUSH_SLIDE_SHARE of the stun).
## - react_started: lift = a dust pop at the feet; buckle = dust where the knee lands.
## - countered: a sharp, cold-white flash at the attacker's caught limb (the
##   striking limb of the move it was countered in), sparks both ways, and a
##   short glow on that limb.
## - dodged: a dust kick at the feet, away from the dodge.
## - drive_started .. drive_ended: a dust puff at each heavy step (the same
##   stride clock as AudioFX's thuds: FXRules.drive_step_gap).
## - drive_impact: break = a flash and a dust burst through the hole; slam = a
##   big flash with a shock ring, a dust burst with chips, a dust ring and debris
##   chunks (DebrisManager); bowl = a flash and dust at the bowled body; shove =
##   a little dust.
## - throw_windup: the throwing arm (upper arm, forearm and hand) glows through
##   BloodFX.limb_glow, brighter and hotter with the wind-up, flaring when it is
##   full; it goes at amount 0, on the throw, when the hold ends, on a hit or a
##   death, and after THROW_GLOW_MAX at the latest.
## - shockwave of a pursuit spike (God path amendment; FXRules.is_spike_shockwave):
##   the body hit the floor. A big flash with a shock ring, a dust ring over the
##   blast radius, a dust burst with chips, debris chunks and a vertical streak
##   (water: rings and a splash). WorldDamage draws the crater. Round 9: the
##   axe kick lands the same way; the dust, chips and debris grow with the
##   blast radius (FXRules.spike_heft), so a charged axe kick's is heavier.
## OWNER: agent F (FX & audio).

# --- Local tuning (candidates for Tuning) ---------------------------------------
const PUSH_DUST_FROM := 1.0       ## m: pushes this long kick up dust and a skid (doc: Hit feel)
const PUSH_FULL := 2.8            ## m: the front kick's push, the longest (the biggest dust)
const PUSH_DUST_ENERGY := Vector2(900.0, 2600.0)  ## BloodFX.dust energy at PUSH_DUST_FROM .. PUSH_FULL
const SKID_EVERY := 0.05          ## s between skid puffs (the victim's own time)
const SKID_SIZE := Vector2(0.45, 0.9)   ## WorldFX.foot_puff size at PUSH_DUST_FROM .. PUSH_FULL
const SKID_TIME_DEFAULT := 0.3    ## s of skid when the hit carries no stun (a knockdown's shove)
const SKID_MAX := 6               ## skids followed at once (the oldest is dropped)
const LIFT_DUST_ENERGY := 1100.0  ## lift: the feet pop off the floor
const BUCKLE_DUST_ENERGY := 900.0 ## buckle: the knee lands...
const BUCKLE_KNEE_AHEAD := 0.25   ## ...this far in front of the feet (m)
const COUNTER_COLOR := Color(0.78, 0.92, 1.0)  ## cold steel white, unlike the warm strike flash
const COUNTER_FLASH := 0.75       ## impact_flash size (0..1) at the caught limb
const COUNTER_BRIGHT := 4.0       ## brighter than any strike (BloodFX.R7_FLASH_BRIGHT.y)
const COUNTER_RING := 0.35        ## a tight ring (0..1 size) when the ring budget allows
const COUNTER_GLOW := 2.2         ## glow on the caught limb...
const COUNTER_GLOW_TIME := 0.18   ## ...for this long (the attacker's time)
const STRIKE_MEMORY := 2.5        ## s an attacker's last strike move id is kept (to find the caught limb)
const DODGE_DUST_ENERGY := 700.0
const DRIVE_DUST := Vector2(0.45, 0.9)   ## foot_puff size at a drive step, start .. top speed
const BREAK_FLASH := Vector2(0.45, 0.8)  ## flash size, a slow .. a top-speed drive
const BREAK_BRIGHT := 2.6
const BREAK_DUST_ENERGY := Vector2(2000.0, 5000.0)
const SLAM_FLASH := Vector2(0.6, 1.0)
const SLAM_BRIGHT := 3.2
const SLAM_DUST_ENERGY := Vector2(3000.0, 8000.0)
const SLAM_RING := Vector2(1.5, 2.8)     ## m: the dust ring rolling out from the wall's foot
const SLAM_DEBRIS := Vector2i(3, 8)      ## chunks thrown out (DebrisManager owns them)
const BOWL_FLASH := 0.5
const BOWL_DUST_ENERGY := 1500.0
const SHOVE_DUST_ENERGY := 700.0
const THROW_GLOW_BONE := Bones.R_LOWER_ARM  ## the halo and light sit on the forearm...
const THROW_ARM: Array[StringName] = [Bones.R_UPPER_ARM, Bones.R_HAND]  ## ...and these parts glow with it
const THROW_GLOW := Vector2(0.25, 1.8)   ## intensity at the start .. a full wind-up
const THROW_COLOR := Color(1.0, 0.6, 0.22)  ## hot orange at a full wind-up (Tuning.TRAIL_COLOR at the start)
const THROW_GLOW_MAX := Tuning.R7_HOLD_MAX + 1.0  ## s: no wind-up glow outlives the clinch
const THROW_POLL := 0.05          ## s between checks of the winding fighters
const SPIKE_FLASH := 1.0          ## impact_flash size at the floor impact...
const SPIKE_BRIGHT := 3.4         ## ...as bright as the heaviest strike
const SPIKE_DUST_ENERGY := 7000.0
const SPIKE_CHIPS := 1.4          ## chip scale
const SPIKE_DEBRIS := Vector2i(6, 10)  ## chunks thrown out (DebrisManager owns them)
const SPIKE_RING_MIN := 1.5       ## m: the dust ring covers the blast radius, at least this

## Every Round 7 effect spawned: {frame (physics), event, what, size} (tests, newest last).
var effect_log: Array[Dictionary] = []
## Effects since the last reset, by name (tests).
var counts: Dictionary = {}
## The last counter flash: {position, bone, fighter} (tests).
var last_counter: Dictionary = {}
## Heft of the last spike floor impact (FXRules.spike_heft; tests).
var last_spike_heft := 0.0

var _fx: Node          ## BloodFX
var _world: Node       ## WorldFX
var _holder: Node3D
var _skids: Array[Dictionary] = []   ## {fighter, left, next, size, color, dir}
var _drives: Dictionary = {}          ## holder id -> {holder, t, next}
var _strikes: Dictionary = {}         ## attacker id -> [move id, real time]
var _throw_glow: Dictionary = {}      ## holder id -> {glow, flared, amount}
var _throw_poll := 0.0

func setup(fx: Node, world: Node, holder: Node3D) -> void:
	_fx = fx
	_world = world
	_holder = holder
	GameEvents.hit_landed.connect(_on_hit_landed)
	GameEvents.react_started.connect(_on_react_started)
	GameEvents.countered.connect(_on_countered)
	GameEvents.dodged.connect(_on_dodged)
	GameEvents.strike_started.connect(_on_strike_started)
	GameEvents.attack_active.connect(_remember_strike)
	GameEvents.counter_window.connect(_on_counter_window)
	GameEvents.footstep.connect(_on_footstep)
	GameEvents.drive_started.connect(_on_drive_started)
	GameEvents.drive_ended.connect(_on_drive_ended)
	GameEvents.drive_impact.connect(_on_drive_impact)
	GameEvents.throw_windup.connect(_on_throw_windup)
	GameEvents.shockwave.connect(_on_shockwave)
	GameEvents.thrown.connect(func(g: Node3D, _v: Node3D, _vel: Vector3) -> void: _drop_throw_glow(g))
	GameEvents.prop_thrown.connect(func(h: Node3D, _p: Node3D, _vel: Vector3) -> void: _drop_throw_glow(h))
	GameEvents.carry_changed.connect(_on_carry_changed)
	GameEvents.fighter_died.connect(func(f: Node3D, _i: HitInfo) -> void: _drop_throw_glow(f))

func reset() -> void:
	effect_log.clear()
	counts.clear()
	last_counter.clear()
	_skids.clear()
	_drives.clear()
	_strikes.clear()
	for id: int in _throw_glow:
		var g = (_throw_glow[id] as Dictionary).get("glow")
		if is_instance_valid(g):
			(g as Node).queue_free()
	_throw_glow.clear()

func _record(event: StringName, what: Variant, size: float) -> void:
	counts[event] = int(counts.get(event, 0)) + 1
	effect_log.append({"frame": Engine.get_physics_frames(), "event": event, "what": what, "size": size})
	if effect_log.size() > 128:
		effect_log.pop_front()

static func _now() -> float:
	return Engine.get_physics_frames() / float(Engine.physics_ticks_per_second)


# =============================================================================
# Events
# =============================================================================

## A pushing Round 7 hit: dust at the feet along the push, then the skid.
## Any hit on a winding fighter ends its wind-up glow.
func _on_hit_landed(info: HitInfo) -> void:
	if info == null or not is_instance_valid(info.victim):
		return
	_drop_throw_glow(info.victim)
	if not FXRules.is_round7(info) or info.kind == &"grab" or info.push < PUSH_DUST_FROM - 1e-4:
		return
	var victim := info.victim
	var t := clampf((info.push - PUSH_DUST_FROM) / (PUSH_FULL - PUSH_DUST_FROM), 0.0, 1.0)
	var feet := FXRules.feet_of(victim)
	var dir := Vector3(info.hit_direction.x, 0.0, info.hit_direction.z)
	dir = dir.normalized() if dir.length_squared() > 1e-6 else -FXRules.forward_of(victim)
	var surface := _floor(feet)
	var c: Color = _world.call(&"surface_color", surface)
	var at := feet + Vector3.UP * 0.05
	var energy := lerpf(PUSH_DUST_ENERGY.x, PUSH_DUST_ENERGY.y, t)
	if surface == &"water":
		_fx.call(&"splash", at, (dir + Vector3.UP * 0.6).normalized(), energy)
	else:
		_fx.call(&"dust", at, c, energy, (dir + Vector3.UP * 0.6).normalized(), false)
	var slide := info.stun * Tuning.R7_PUSH_SLIDE_SHARE if info.stun > 0.0 else SKID_TIME_DEFAULT
	var skid := {"fighter": victim, "left": slide, "next": SKID_EVERY, "size": lerpf(SKID_SIZE.x, SKID_SIZE.y, t),
		"color": c, "dir": dir}
	_skid_puff(skid)  # the first puff on the hit's frame
	_skids.append(skid)
	if _skids.size() > SKID_MAX:
		_skids.pop_front()
	_record(&"push_dust", info.push, energy)

## Lift pops the feet off the floor; buckle drops a knee onto it.
func _on_react_started(victim: Node3D, kind: StringName, _attacker: Node3D) -> void:
	if not is_instance_valid(victim):
		return
	var feet := FXRules.feet_of(victim)
	match kind:
		&"lift":
			_fx.call(&"dust", feet + Vector3.UP * 0.05, _world.call(&"surface_color", _floor(feet)), LIFT_DUST_ENERGY,
					Vector3.UP, false)
			_record(&"lift_dust", kind, LIFT_DUST_ENERGY)
		&"buckle":
			var knee := feet + FXRules.forward_of(victim) * BUCKLE_KNEE_AHEAD
			_fx.call(&"dust", knee + Vector3.UP * 0.05, _world.call(&"surface_color", _floor(knee)), BUCKLE_DUST_ENERGY,
					Vector3.UP, false)
			_record(&"buckle_dust", kind, BUCKLE_DUST_ENERGY)

## Counter: the caught limb flashes cold white and glows for a moment.
func _on_countered(defender: Node3D, attacker: Node3D) -> void:
	if not is_instance_valid(attacker):
		return
	var bone := caught_bone(attacker)
	var at := FXRules.limb_point(attacker, bone)
	var ring: bool = _fx.call(&"_ring_allowed")
	_fx.call(&"impact_flash", at, COUNTER_FLASH, false, ring, COUNTER_BRIGHT, COUNTER_RING, COUNTER_COLOR)
	var dir := Vector3.UP
	if is_instance_valid(defender):
		var d := FXRules.limb_point(defender, Bones.CHEST) - at
		dir = d.normalized() if d.length_squared() > 1e-6 else Vector3.UP
	_fx.call(&"spark", at, dir, 1.0)
	_fx.call(&"spark", at, -dir, 0.6)
	_fx.call(&"limb_glow", attacker, bone, COUNTER_COLOR, COUNTER_GLOW_TIME, COUNTER_GLOW)
	last_counter = {"position": at, "bone": bone, "fighter": attacker, "ring": ring}
	_record(&"counter_flash", bone, COUNTER_FLASH)

## The striking limb of the attack a counter caught: the attacker's current
## move (CombatController.current_move_id), else the move it had when its
## counter window opened or the last strike it started, within STRIKE_MEMORY
## s (Defence cancels the attack before it emits countered), else the right hand.
func caught_bone(attacker: Node3D) -> StringName:
	var id := &""
	var combat = attacker.get(&"combat")
	if combat != null and is_instance_valid(combat) and (combat as Object).has_method(&"current_move_id"):
		id = StringName(combat.call(&"current_move_id"))
	if id == &"":
		var rec: Array = _strikes.get(attacker.get_instance_id(), [])
		if not rec.is_empty() and _now() - float(rec[1]) <= STRIKE_MEMORY:
			id = rec[0]
	return FXRules.strike_limb(id) if id != &"" else Bones.R_HAND

func _on_strike_started(attacker: Node3D, _target: Node3D, move_id: StringName, _sprint: bool,
		_charge_level: int) -> void:
	_remember_strike(attacker, move_id)

## A counter window opened: remember the attacker's move (the limb to flash
## if it gets countered).
func _on_counter_window(attacker: Node3D, _target: Node3D, open: bool, _counterable: bool) -> void:
	if not open or not is_instance_valid(attacker):
		return
	var combat = attacker.get(&"combat")
	if combat != null and is_instance_valid(combat) and (combat as Object).has_method(&"current_move_id"):
		_remember_strike(attacker, StringName(combat.call(&"current_move_id")))

func _remember_strike(attacker: Node3D, move_id: StringName) -> void:
	if is_instance_valid(attacker) and move_id != &"":
		_strikes[attacker.get_instance_id()] = [move_id, _now()]

## Dodge: dust kicked away from the dodge as the feet push off.
func _on_dodged(fighter: Node3D, direction: Vector3) -> void:
	if not is_instance_valid(fighter):
		return
	var feet := FXRules.feet_of(fighter)
	var d := Vector3(direction.x, 0.0, direction.z)
	var kick := (-d.normalized() + Vector3.UP * 0.6).normalized() if d.length_squared() > 1e-6 else Vector3.UP
	_fx.call(&"dust", feet + Vector3.UP * 0.05, _world.call(&"surface_color", _floor(feet)), DODGE_DUST_ENERGY, kick,
			false)
	_record(&"dodge_dust", direction, DODGE_DUST_ENERGY)

func _on_drive_started(holder: Node3D, _held: Node3D) -> void:
	if not is_instance_valid(holder):
		return
	var d := {"holder": holder, "t": 0.0, "next": 0.0}
	_drives[holder.get_instance_id()] = d
	_drive_puff(d)

func _on_drive_ended(holder: Node3D, _reason: StringName) -> void:
	if is_instance_valid(holder):
		_drives.erase(holder.get_instance_id())

## Drives being followed (tests, debug).
func active_drives() -> int:
	return _drives.size()

## True while `fighter` drives a body (WorldFX leaves its steps to the drive dust).
func is_driving(fighter: Node) -> bool:
	return is_instance_valid(fighter) and _drives.has(fighter.get_instance_id())

## A Traversal footstep during a drive lands as the drive's dust puff and
## restarts the stride clock (AudioFX does the same with its thud).
func _on_footstep(fighter: Node3D, _position: Vector3, _surface: StringName, _sprint_charge: float) -> void:
	if is_driving(fighter):
		_drive_puff(_drives[fighter.get_instance_id()])

## The driven body met something (see the header).
func _on_drive_impact(holder: Node3D, _victim: Node3D, target: Node3D, position: Vector3, speed: float,
		result: StringName) -> void:
	var k := clampf(speed / Tuning.R7_DRIVE_MAX_SPEED, 0.0, 1.0)
	var fwd := FXRules.forward_of(holder) if is_instance_valid(holder) else Vector3.FORWARD
	var wall_c: Color = _fx.call(&"_surface_color", target)
	var ground := position
	if is_instance_valid(holder):
		ground.y = FXRules.feet_of(holder).y
	var floor_c: Color = _world.call(&"surface_color", _floor(ground))
	match result:
		&"break":
			_fx.call(&"impact_flash", position, lerpf(BREAK_FLASH.x, BREAK_FLASH.y, k), false, false, BREAK_BRIGHT)
			_fx.call(&"dust", position + fwd * 0.3, wall_c, lerpf(BREAK_DUST_ENERGY.x, BREAK_DUST_ENERGY.y, k),
					(fwd + Vector3.UP * 0.3).normalized(), true, 1.2)
		&"slam":
			var ring: bool = _fx.call(&"_ring_allowed")
			_fx.call(&"impact_flash", position, lerpf(SLAM_FLASH.x, SLAM_FLASH.y, k), false, ring, SLAM_BRIGHT)
			_fx.call(&"dust", position - fwd * 0.05, wall_c, lerpf(SLAM_DUST_ENERGY.x, SLAM_DUST_ENERGY.y, k),
					(-fwd + Vector3.UP * 0.4).normalized(), true, 1.5)
			_world.call(&"dust_ring", ground, lerpf(SLAM_RING.x, SLAM_RING.y, k), floor_c)
			_world.call(&"debris", ground - fwd * 0.3, roundi(lerpf(SLAM_DEBRIS.x, SLAM_DEBRIS.y, k)),
					wall_c.darkened(0.1))
		&"bowl":
			var at := FXRules.limb_point(target, Bones.CHEST) if is_instance_valid(target) else position
			_fx.call(&"impact_flash", at, BOWL_FLASH, false, false)
			var tf := FXRules.feet_of(target) if is_instance_valid(target) else ground
			_fx.call(&"dust", tf + Vector3.UP * 0.05, floor_c, BOWL_DUST_ENERGY, Vector3.UP, false)
		_:
			_fx.call(&"dust", ground + Vector3.UP * 0.05, floor_c, SHOVE_DUST_ENERGY, Vector3.UP, false)
	_record(StringName("drive_" + String(result)), result, k)

## A pursuit spike drove the body into the floor (see the header).
func _on_shockwave(_fighter: Node3D, position: Vector3, stumble_radius: float, knockdown_radius: float) -> void:
	if not FXRules.is_spike_shockwave(knockdown_radius):
		return
	var surface := _floor(position)
	var c: Color = _world.call(&"surface_color", surface)
	var ring: bool = _fx.call(&"_ring_allowed")
	var heft := FXRules.spike_heft(stumble_radius)
	_fx.call(&"impact_flash", position + Vector3.UP * 0.3, SPIKE_FLASH, false, ring, SPIKE_BRIGHT * sqrt(heft))
	if surface == &"water":
		_world.call(&"water_impact", position, SPIKE_DUST_ENERGY * heft)
	else:
		_world.call(&"dust_ring", position, maxf(stumble_radius, SPIKE_RING_MIN), c)
		_fx.call(&"dust", position + Vector3.UP * 0.1, c, SPIKE_DUST_ENERGY * heft, Vector3.UP, true, SPIKE_CHIPS * heft)
		_world.call(&"debris", position, roundi(randi_range(SPIKE_DEBRIS.x, SPIKE_DEBRIS.y) * heft), c.darkened(0.1))
	_world.call(&"streak", position)
	last_spike_heft = heft
	_record(&"spike", surface, maxf(stumble_radius, SPIKE_RING_MIN))

## Throw wind-up: the arm glow follows the amount; 0 ends it.
func _on_throw_windup(holder: Node3D, amount: float) -> void:
	if not is_instance_valid(holder):
		return
	if amount <= 0.0:
		_drop_throw_glow(holder)
		return
	var id := holder.get_instance_id()
	var rec: Dictionary = _throw_glow.get(id, {})
	var g = rec.get("glow")
	if not is_instance_valid(g):
		g = _fx.call(&"limb_glow", holder, THROW_GLOW_BONE, Tuning.TRAIL_COLOR, 0.0, THROW_GLOW.x)
		if g == null:
			return
		var extra: Array = []
		for b in THROW_ARM:
			extra.append_array(_fx.call(&"_bone_parts", holder, b))
		g.call(&"add_parts", extra)
		rec = {"glow": g, "flared": false, "amount": 0.0}
		_throw_glow[id] = rec
		_record(&"throw_glow", THROW_GLOW_BONE, amount)
	var a := clampf(amount, 0.0, 1.0)
	g.call(&"set_intensity", lerpf(THROW_GLOW.x, THROW_GLOW.y, a))
	g.call(&"set_color", Tuning.TRAIL_COLOR.lerp(THROW_COLOR, a))
	if a >= 1.0 and not rec["flared"]:
		rec["flared"] = true
		g.call(&"pulse")
		_record(&"throw_full", THROW_GLOW_BONE, a)
	rec["amount"] = a

## The hold ended (held = null): no throw is coming.
func _on_carry_changed(holder: Node3D, held: Node3D) -> void:
	if held == null:
		_drop_throw_glow(holder)

## The wind-up glow on a fighter (tests), or null.
func get_throw_glow(holder: Node3D) -> Node3D:
	if not is_instance_valid(holder):
		return null
	var g = (_throw_glow.get(holder.get_instance_id(), {}) as Dictionary).get("glow")
	return g if is_instance_valid(g) else null

func _drop_throw_glow(holder: Node3D) -> void:
	if not is_instance_valid(holder):
		return
	var id := holder.get_instance_id()
	var g = (_throw_glow.get(id, {}) as Dictionary).get("glow")
	if is_instance_valid(g):
		g.call(&"stop")
	_throw_glow.erase(id)


# =============================================================================
# Frame update
# =============================================================================

func _process(delta: float) -> void:
	var real := delta / maxf(Engine.time_scale, 0.001)
	_update_skids(delta)
	_update_drives(real, delta)
	_update_throw_glows(real)

## Skids follow the victim's feet in its own (world) time.
func _update_skids(delta: float) -> void:
	var i := _skids.size() - 1
	while i >= 0:
		var s := _skids[i]
		var f = s["fighter"]
		s["left"] = float(s["left"]) - delta
		if not is_instance_valid(f) or not (f as Node3D).is_inside_tree() or float(s["left"]) <= 0.0:
			_skids.remove_at(i)
			i -= 1
			continue
		s["next"] = float(s["next"]) - delta
		if float(s["next"]) <= 0.0:
			s["next"] = SKID_EVERY
			_skid_puff(s)
		i -= 1

## Skids still running (tests).
func active_skids() -> int:
	return _skids.size()

func _skid_puff(s: Dictionary) -> void:
	var f: Node3D = s["fighter"]
	var dir: Vector3 = s["dir"]
	_world.call(&"foot_puff", FXRules.feet_of(f) + Vector3.UP * 0.04, s["color"], s["size"],
			(dir * 0.7 + Vector3.UP).normalized())
	counts[&"skid_puff"] = int(counts.get(&"skid_puff", 0)) + 1

## Drive clocks: a dust puff at every stride (player drives in real time).
func _update_drives(real: float, delta: float) -> void:
	for id: int in _drives.keys():
		var d: Dictionary = _drives[id]
		var h = d["holder"]
		if not is_instance_valid(h) or not (h as Node3D).is_inside_tree():
			_drives.erase(id)
			continue
		var dt := real if (h as Node3D).is_in_group(&"player") else delta
		d["t"] = float(d["t"]) + dt
		if float(d["t"]) > Tuning.R7_DRIVE_MAX_TIME + 1.0:
			_drives.erase(id)
			continue
		d["next"] = float(d["next"]) - dt
		if float(d["next"]) <= 0.0:
			_drive_puff(d)

func _drive_puff(d: Dictionary) -> void:
	var h: Node3D = d["holder"]
	var v := FXRules.drive_speed(h, float(d["t"]))
	var feet := FXRules.feet_of(h)
	var back := -FXRules.forward_of(h)
	_world.call(&"foot_puff", feet + back * 0.2 + Vector3.UP * 0.05, _world.call(&"surface_color", _floor(feet)),
			lerpf(DRIVE_DUST.x, DRIVE_DUST.y, FXRules.drive_share(v)), (back * 0.8 + Vector3.UP).normalized())
	d["next"] = FXRules.drive_step_gap(v)
	counts[&"drive_dust"] = int(counts.get(&"drive_dust", 0)) + 1

## Winding fighters that went down, died or held too long lose the glow.
func _update_throw_glows(real: float) -> void:
	if _throw_glow.is_empty():
		return
	_throw_poll -= real
	if _throw_poll > 0.0:
		return
	_throw_poll = THROW_POLL
	for id: int in _throw_glow.keys():
		var g = (_throw_glow[id] as Dictionary).get("glow")
		var f := instance_from_id(id) as Node3D
		if not is_instance_valid(g) or f == null:
			if is_instance_valid(g):
				g.call(&"stop")
			_throw_glow.erase(id)
			continue
		if float(g.get(&"age")) > THROW_GLOW_MAX or FXRules.cannot_charge(f):
			_drop_throw_glow(f)

func _floor(position: Vector3) -> StringName:
	return FXRules.floor_surface(_holder.get_world_3d() if _holder != null and _holder.is_inside_tree() else null,
			position)
