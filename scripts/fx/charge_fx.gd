extends Node
## Round 8 effects (docs/Round 8 — Charge and Pressure.md). A child of BloodFX
## ("ChargeFX"); every effect listens to GameEvents and spawns on the event's
## physics frame. The sounds are AudioFX's (its Round 8 section).
## - Charge: charge_started lights the striking limb (BloodFX.limb_glow). The
##   glow's strength and colour follow the charge amount c every frame
##   (charge_glow_intensity / charge_glow_color: monotonic in c; c from
##   CombatController.get_charge(), FXRules.charge_amount). Each
##   charge_level_changed step pulses it with a small flash; charge_full flares
##   it (a bright hot flash and sparks at the limb, then a fast throb until the
##   release). charge_released ends it with a release flash sized by c;
##   charge_cancelled fizzles it out (a dim grey puff and a few sparks falling).
##   An interrupted charge (down, flying, dead, held, a hit on the charger)
##   drops the glow; none outlives charge_glow_max().
## - Hits: a charged hit adds a hot flash sized by HitInfo.charge on top of
##   BloodFX's weight flash; a hit on a broken enemy (HitInfo.broken_bonus) adds
##   a heavy accent (a bright break-coloured flash and sparks); a hit (landed or
##   blocked) that adds pressure (HitInfo.pressure > 0) leaves a small
##   break-coloured tick spark, bigger as the victim's pressure fills.
## - pressure_broken: the break burst centred on the guard (forearms and
##   chest, FXRules.guard_point): a big break-coloured flash with a shock ring,
##   two shatter rings (jagged ring and crack spokes) expanding through the
##   guard, glass-like shards, sparks all round and off each forearm, a white
##   body flash and a shudder; ScreenFX flashes the screen.
## - The broken loop, from pressure_broken until pressure_recovered (or death,
##   or CombatController.is_broken() going false after it was seen true, or
##   R8_BREAK_TIME + DAZE_SLACK at the latest). Round 9 (guard broken, not
##   stunned; `broken_stun` = Tuning.R9_BROKEN_STUN false): the cracked guard,
##   crackling break-coloured sparks jumping on both forearms, a spark spat off
##   one now and then, and a faint flicker on the arms (limb glows). With
##   broken_stun true: the Round 8 dazed loop (small sparks orbiting above the
##   head and a woozy shimmer on it).
## - Round 9 axe kick (FXRules.is_axe_kick): a sharp heel-impact crack at the
##   contact, a hot white flash, a chop streak and sparks fanning down and out,
##   heavier when charged (by HitInfo.charge). The floor shockwave that
##   follows is FreeflowFX's spike impact.
## - air_follow_started: a dust pop at the jumper's feet. air_hit: a small
##   cool flash on the body, a little bigger with the count.
## OWNER: agent F (FX & audio).

const BILLBOARD_XRAY := preload("res://shaders/fx_billboard_add_xray.gdshader")

# --- Local tuning (candidates for Tuning) ---------------------------------------
## Charge glow strength at c = 0 .. 1 and at full (a throb of +-FULL_THROB around it).
const CHARGE_GLOW := Vector2(0.35, 2.0)
const CHARGE_GLOW_FULL := 2.5
const FULL_THROB := 0.35
const FULL_THROB_HZ := 9.0
## Glow colour: the brand's warm white at c = 0, orange at CHARGE_MID_AT, red-hot
## at c = 1 (the HUD meter's white / orange / red).
const CHARGE_COLD := Tuning.TRAIL_COLOR
const CHARGE_MID := Color(1.0, 0.62, 0.22)
const CHARGE_HOT := Color(1.0, 0.3, 0.12)
const CHARGE_MID_AT := 0.5
const STEP_FLASH := 0.14          ## impact_flash size at the limb on each step
const FULL_FLASH := 0.5           ## ...and at full
const FULL_BRIGHT := 3.6
const FULL_SPARK := 0.6
const RELEASE_FLASH := Vector2(0.12, 0.45)  ## release flash size at c = 0 .. 1
const FIZZLE_COLOR := Color(0.55, 0.55, 0.62)
const FIZZLE_FLASH := 0.12
const FIZZLE_BRIGHT := 0.9
const FIZZLE_SPARK := 0.3
const CHARGE_SLACK := 0.5         ## s past the longest legal charge before a glow is dropped anyway
const CHARGE_POLL := 0.05         ## s between state checks of the charging fighters
## Hits.
const CHARGED_FLASH := Vector2(0.25, 0.75)   ## extra hot flash size at c = 0 .. 1
const CHARGED_BRIGHT := Vector2(1.4, 3.2)
const BROKEN_FLASH := 0.8
const BROKEN_BRIGHT := 3.8
const BROKEN_SPARK := 0.9
const TICK_FLASH := Vector2(0.05, 0.16)      ## pressure tick flash size, empty .. nearly full meter
const TICK_BRIGHT := Vector2(1.2, 2.2)
const TICK_SPARK := Vector2(0.15, 0.4)
## The break.
const BREAK_COLOR := Color(0.55, 0.9, 1.0)   ## shattered-glass cyan: unlike any strike (warm) or counter (steel)
const BREAK_FLASH := 1.0
const BREAK_BRIGHT := 4.6
const BREAK_RING_TIME := 0.42      ## real s: a shatter ring expands and fades
const BREAK_RING_SIZE := [Vector2(0.5, 3.0), Vector2(0.4, 2.1)]  ## m: start .. end, outer and inner ring
const BREAK_RING_DELAY := [0.0, 0.06]       ## s the inner ring follows the outer one
const BREAK_RING_BRIGHT := 2.6
const BREAK_RING_POOL := 2          ## bursts at once (each has two rings)
const BREAK_SPARKS := 4          ## round the guard, plus one off each forearm (BloodFX has 6 spark emitters)
const BREAK_SHARDS := 1.0           ## WorldFX.glass size
const BREAK_JITTER := 0.18          ## s of shudder
## The dazed loop.
const DAZE_POOL := 4
const DAZE_SPARKS := 4
const DAZE_HEIGHT := 0.3            ## m above the head bone
const DAZE_RADIUS := 0.28           ## m
const DAZE_SPEED := 4.5             ## rad/s
const DAZE_STAR := 0.13             ## m
const DAZE_SHIMMER := 0.55          ## m: the woozy halo on the head
const DAZE_SLACK := 1.0             ## s past R8_BREAK_TIME before a loop with no pressure_recovered stops
const DAZE_FADE := 0.15             ## s fade in and out
## The cracked guard (Round 9).
const CRACK_SPARKS := 3             ## arcs jumping on each forearm
const CRACK_STAR := 0.1             ## m
const CRACK_JUMP := 0.09            ## m: how far an arc jumps off the forearm
const CRACK_HZ := 18.0              ## arc re-strikes per s
const CRACK_SPIT_GAP := Vector2(0.14, 0.32)  ## s between sparks spat off a forearm
const CRACK_SPIT := 0.35            ## BloodFX.spark size
const CRACK_GLOW := 0.32            ## the arms' faint flicker (limb glow intensity)...
const CRACK_GLOW_FLICKER := 0.6     ## ...drops by up to this share at random
const BREAK_ARM_SPARK := 0.7        ## the break burst's spark off each forearm
## The axe kick's heel crack (Round 9): tap, charged at c = 0 .. 1.
const AXE_COLOR := Color(1.0, 0.95, 0.85)
const AXE_FLASH := Vector3(0.45, 0.6, 0.85)
const AXE_BRIGHT := Vector3(3.6, 4.2, 5.2)
const AXE_SPARK := Vector3(0.6, 0.8, 1.0)
## Air.
const AIR_DUST := 1200.0
const AIR_COLOR := Color(0.85, 0.93, 1.0)
const AIR_FLASH := Vector2(0.3, 0.55)       ## by the count, 1 .. debug_air_hits
const AIR_BRIGHT := 2.4

## Every Round 8 effect spawned: {frame (physics), event, what, size} (tests, newest last).
var effect_log: Array[Dictionary] = []
## Effects since the last reset, by name (tests).
var counts: Dictionary = {}
## The last break burst: {frame, position, fighter, ring} (tests).
var last_break: Dictionary = {}

var _fx: Node          ## BloodFX
var _world: Node       ## WorldFX
var _holder: Node3D
var _charges: Dictionary = {}       ## fighter id -> {fighter, glow, move, t, c, full, seen}
var _poll := 0.0
var _ring_mat: ShaderMaterial
var _rings: Array[MeshInstance3D] = []   ## BREAK_RING_POOL x 2
var _ring_age := PackedFloat32Array()    ## per burst, real s; < 0 idle
var _ring_next := 0
var _dazes: Array[Node3D] = []
var _daze_fighter: Array = []
var _daze_age := PackedFloat32Array()    ## world s since the break; < 0 idle
var _daze_out := PackedFloat32Array()    ## s of fade-out left; < 0 = not stopping
var _daze_seen: Array[bool] = []         ## is_broken() was seen true
var _daze_stun: Array[bool] = []         ## this slot shows the dazed loop (else the cracked guard)
var _cracks: Array[Node3D] = []          ## the cracked-guard arcs, per slot
var _crack_glows: Array = []             ## per slot: [left, right] arm glows
var _crack_spit := PackedFloat32Array()  ## s to the next spat spark, per slot
## Round 9: the break dazes (the Round 8 loop) instead of cracking the guard.
## Tuning.R9_BROKEN_STUN; tests may flip it.
var broken_stun: bool = Tuning.R9_BROKEN_STUN

func setup(fx: Node, world: Node, holder: Node3D) -> void:
	_fx = fx
	_world = world
	_holder = holder
	_build()
	GameEvents.charge_started.connect(_on_charge_started)
	GameEvents.charge_level_changed.connect(_on_charge_level_changed)
	GameEvents.charge_full.connect(_on_charge_full)
	GameEvents.charge_released.connect(_on_charge_released)
	GameEvents.charge_cancelled.connect(_on_charge_cancelled)
	GameEvents.hit_landed.connect(_on_hit_landed)
	GameEvents.hit_blocked.connect(_on_hit_blocked)
	GameEvents.pressure_broken.connect(_on_pressure_broken)
	GameEvents.pressure_recovered.connect(_on_pressure_recovered)
	GameEvents.air_follow_started.connect(_on_air_follow_started)
	GameEvents.air_hit.connect(_on_air_hit)
	GameEvents.fighter_died.connect(func(f: Node3D, _i: HitInfo) -> void:
		drop_charge_glow(f)
		_stop_daze(f, true))
	GameEvents.fighter_launched.connect(func(f: Node3D, _v: Vector3) -> void: drop_charge_glow(f))
	GameEvents.grab_started.connect(func(_g: Node3D, v: Node3D) -> void: drop_charge_glow(v))
	GameEvents.limb_grab_started.connect(func(_g: Node3D, v: Node3D, _b: StringName) -> void: drop_charge_glow(v))
	GameEvents.carry_changed.connect(func(_h: Node3D, held: Node3D) -> void: drop_charge_glow(held))
	GameEvents.thrown.connect(func(_g: Node3D, v: Node3D, _vel: Vector3) -> void: drop_charge_glow(v))

func reset() -> void:
	effect_log.clear()
	counts.clear()
	last_break.clear()
	for id: int in _charges:
		var g = (_charges[id] as Dictionary).get("glow")
		if is_instance_valid(g):
			(g as Node).queue_free()
	_charges.clear()
	for i in BREAK_RING_POOL:
		_ring_age[i] = -1.0
		_rings[i * 2].visible = false
		_rings[i * 2 + 1].visible = false
	for i in DAZE_POOL:
		_daze_fighter[i] = null
		_daze_age[i] = -1.0
		_daze_out[i] = -1.0
		_dazes[i].visible = false
		_cracks[i].visible = false
		_drop_crack_glows(i)

func _record(event: StringName, what: Variant, size: float) -> void:
	counts[event] = int(counts.get(event, 0)) + 1
	effect_log.append({"frame": Engine.get_physics_frames(), "event": event, "what": what, "size": size})
	if effect_log.size() > 128:
		effect_log.pop_front()


# =============================================================================
# Charge
# =============================================================================

## Glow strength at charge amount c (strictly rising in c).
static func charge_glow_intensity(c: float) -> float:
	return lerpf(CHARGE_GLOW.x, CHARGE_GLOW.y, clampf(c, 0.0, 1.0))

## Glow colour at charge amount c: warm white, orange, red-hot.
static func charge_glow_color(c: float) -> Color:
	var u := clampf(c, 0.0, 1.0)
	if u <= CHARGE_MID_AT:
		return CHARGE_COLD.lerp(CHARGE_MID, u / CHARGE_MID_AT)
	return CHARGE_MID.lerp(CHARGE_HOT, (u - CHARGE_MID_AT) / (1.0 - CHARGE_MID_AT))

## Longest a charge glow may live (s): the longest legal charge (to full, then
## the hold at full) plus CHARGE_SLACK.
static func charge_glow_max() -> float:
	return maxf(Tuning.debug_charge_full, 1.0) - Tuning.R8_TAP_MAX + Tuning.R8_CHARGE_HOLD_AT_FULL + CHARGE_SLACK

func _on_charge_started(fighter: Node3D, move_id: StringName) -> void:
	if not is_instance_valid(fighter):
		return
	drop_charge_glow(fighter)
	var bone := FXRules.strike_limb(move_id)
	var g: Node3D = _fx.call(&"limb_glow", fighter, bone, charge_glow_color(0.0), 0.0, charge_glow_intensity(0.0))
	if g == null:
		return
	_charges[fighter.get_instance_id()] = {"fighter": fighter, "glow": g, "move": move_id, "bone": bone, "t": 0.0,
		"c": 0.0, "full": false, "seen": false}
	_record(&"charge_glow", bone, 0.0)

## A step of the move's meter: a pulse and a small flash at the limb.
func _on_charge_level_changed(fighter: Node3D, level: int) -> void:
	var rec := _charge_of(fighter)
	if rec.is_empty() or level <= 0:
		return
	var g: Node3D = rec["glow"]
	g.call(&"pulse")
	_fx.call(&"impact_flash", g.global_position, STEP_FLASH, false, false, -1.0, -1.0, charge_glow_color(rec["c"]))
	_record(&"charge_step", level, STEP_FLASH)

## Full: a bright hot flare and sparks at the limb; the glow throbs until the release.
func _on_charge_full(fighter: Node3D, move_id: StringName) -> void:
	if not is_instance_valid(fighter):
		return
	var rec := _charge_of(fighter)
	var at := FXRules.limb_point(fighter, FXRules.strike_limb(move_id))
	if not rec.is_empty():
		rec["full"] = true
		rec["c"] = 1.0
		var g: Node3D = rec["glow"]
		g.call(&"pulse")
		g.call(&"set_color", CHARGE_HOT)
		g.call(&"set_intensity", CHARGE_GLOW_FULL)
		at = g.global_position
	_fx.call(&"impact_flash", at, FULL_FLASH, true, false, FULL_BRIGHT, -1.0, CHARGE_HOT)
	_fx.call(&"spark", at, Vector3.UP, FULL_SPARK)
	_record(&"charge_full", move_id, FULL_FLASH)

## The release: the glow goes with a flash sized by c.
func _on_charge_released(fighter: Node3D, move_id: StringName, _level: int) -> void:
	if not is_instance_valid(fighter):
		return
	var rec := _charge_of(fighter)
	var c := release_charge(fighter)
	var at: Vector3 = (rec["glow"] as Node3D).global_position if not rec.is_empty() \
			else FXRules.limb_point(fighter, FXRules.strike_limb(move_id))
	var size := lerpf(RELEASE_FLASH.x, RELEASE_FLASH.y, c)
	_fx.call(&"impact_flash", at, size, c > 0.5, false, -1.0, -1.0, charge_glow_color(c))
	drop_charge_glow(fighter)
	_record(&"charge_release", c, size)

## c at the release: the last c the glow followed, or the CombatController's
## (whichever is larger: B may clear it before or after it emits).
func release_charge(fighter: Node3D) -> float:
	var rec := _charge_of(fighter)
	var c := float(rec.get("c", 0.0))
	if bool(rec.get("full", false)):
		return 1.0
	var cc := FXRules.combat_of(fighter)
	if cc != null and cc.has_method(&"get_charge"):
		c = maxf(c, clampf(float(cc.call(&"get_charge")), 0.0, 1.0))
	return c

## A charge that ended without a strike fizzles: a dim grey puff and a few
## sparks falling off the limb.
func _on_charge_cancelled(fighter: Node3D, move_id: StringName, reason: StringName) -> void:
	if not is_instance_valid(fighter):
		return
	var rec := _charge_of(fighter)
	var at: Vector3 = (rec["glow"] as Node3D).global_position if not rec.is_empty() \
			else FXRules.limb_point(fighter, FXRules.strike_limb(move_id))
	drop_charge_glow(fighter)
	_fx.call(&"impact_flash", at, FIZZLE_FLASH, false, false, FIZZLE_BRIGHT, -1.0, FIZZLE_COLOR)
	_fx.call(&"spark", at, Vector3.DOWN, FIZZLE_SPARK)
	_record(&"charge_fizzle", reason, FIZZLE_FLASH)

## The charge glow on a fighter (tests), or null.
func get_charge_glow(fighter: Node3D) -> Node3D:
	var g = _charge_of(fighter).get("glow")
	return g if is_instance_valid(g) else null

## c the glow follows now (tests): -1 when the fighter has no charge glow.
func get_glow_charge(fighter: Node3D) -> float:
	var rec := _charge_of(fighter)
	return float(rec["c"]) if not rec.is_empty() else -1.0

## End a fighter's charge glow (a short fade), if any.
func drop_charge_glow(fighter: Node3D) -> void:
	if not is_instance_valid(fighter):
		return
	var id := fighter.get_instance_id()
	var g = (_charges.get(id, {}) as Dictionary).get("glow")
	if is_instance_valid(g):
		g.call(&"stop")
	_charges.erase(id)

func _charge_of(fighter: Node3D) -> Dictionary:
	if not is_instance_valid(fighter):
		return {}
	var rec: Dictionary = _charges.get(fighter.get_instance_id(), {})
	if not rec.is_empty() and not is_instance_valid(rec.get("glow")):
		_charges.erase(fighter.get_instance_id())
		return {}
	return rec

## Every frame: each glow follows its fighter's c; a fighter that went down,
## flew, died or was grabbed, whose CombatController stopped reporting the
## charge, or whose charge outlived charge_glow_max() loses it.
func _update_charges(real: float) -> void:
	if _charges.is_empty():
		return
	_poll -= real
	var check := _poll <= 0.0
	if check:
		_poll = CHARGE_POLL
	var cap := charge_glow_max()
	for id: int in _charges.keys():
		var rec: Dictionary = _charges[id]
		var f = rec["fighter"]
		var g = rec["glow"]
		if not is_instance_valid(f) or not is_instance_valid(g):
			if is_instance_valid(g):
				g.call(&"stop")
			_charges.erase(id)
			continue
		rec["t"] = float(rec["t"]) + real
		if check:
			var charging := FXRules.combat_flag(f, &"is_charging")
			if charging == 1:
				rec["seen"] = true
			if float(rec["t"]) > cap or FXRules.cannot_charge(f) or (charging == 0 and rec["seen"]):
				drop_charge_glow(f)
				continue
		if rec["full"]:
			var throb := 1.0 + FULL_THROB * sin(float(rec["t"]) * TAU * FULL_THROB_HZ)
			g.call(&"set_intensity", CHARGE_GLOW_FULL * throb)
			continue
		var c := maxf(float(rec["c"]), FXRules.charge_amount(f, float(rec["t"])))
		rec["c"] = c
		g.call(&"set_intensity", charge_glow_intensity(c))
		g.call(&"set_color", charge_glow_color(c))


# =============================================================================
# Hits and pressure
# =============================================================================

func _on_hit_landed(info: HitInfo) -> void:
	if info == null or not is_instance_valid(info.victim):
		return
	drop_charge_glow(info.victim)  # a hit knocks the victim out of its charge (B also cancels it)
	if info.kind == &"grab" or FXRules.is_throw_release(info):
		return
	var at := _hit_point(info)
	if FXRules.is_charged(info):
		var c := clampf(info.charge, 0.0, 1.0)
		var size := lerpf(CHARGED_FLASH.x, CHARGED_FLASH.y, c)
		_fx.call(&"impact_flash", at, size, true, false, lerpf(CHARGED_BRIGHT.x, CHARGED_BRIGHT.y, c), -1.0,
				charge_glow_color(c))
		_record(&"charged_hit", c, size)
	if info.broken_bonus:
		_fx.call(&"impact_flash", at, BROKEN_FLASH, false, false, BROKEN_BRIGHT, -1.0, BREAK_COLOR)
		_fx.call(&"spark", at, -info.hit_direction, BROKEN_SPARK)
		_fx.call(&"spark", at, info.hit_direction, BROKEN_SPARK * 0.7)
		_record(&"broken_hit", info.move_id, BROKEN_FLASH)
	if info.pressure > 0.0:
		_pressure_tick(info, at)
	if FXRules.is_axe_kick(info):
		_axe_crack(info, at)

## Round 9: the axe kick's heel crack at the contact (see the header). The
## sizes step from a tap (x) to a charged one at c = 0 (y) and c = 1 (z).
func _axe_crack(info: HitInfo, at: Vector3) -> void:
	var k := axe_heft(info)
	var size := _axe_lerp(AXE_FLASH, k)
	var sp := _axe_lerp(AXE_SPARK, k)
	_fx.call(&"impact_flash", at, size, true, false, _axe_lerp(AXE_BRIGHT, k), -1.0, AXE_COLOR)
	_world.call(&"streak", at + Vector3.DOWN * 0.6)
	_fx.call(&"spark", at, Vector3.DOWN, sp)
	var flat := Vector3(info.hit_direction.x, 0.0, info.hit_direction.z)
	var side := flat.cross(Vector3.UP).normalized() if flat.length_squared() > 1e-4 else Vector3.RIGHT
	_fx.call(&"spark", at, (side + Vector3.DOWN * 0.7).normalized(), sp * 0.7)
	_fx.call(&"spark", at, (-side + Vector3.DOWN * 0.7).normalized(), sp * 0.7)
	_record(&"axe_crack", info.move_id, size)

## 0 for a tap axe kick; 1 .. 2 for a charged one at c = 0 .. 1.
static func axe_heft(info: HitInfo) -> float:
	return 1.0 + clampf(info.charge, 0.0, 1.0) if FXRules.is_charged(info) else 0.0

static func _axe_lerp(v: Vector3, k: float) -> float:
	return lerpf(v.x, v.y, k) if k <= 1.0 else lerpf(v.y, v.z, k - 1.0)

## A blocked hit still adds pressure (that is how guards break).
func _on_hit_blocked(info: HitInfo) -> void:
	if info == null or info.pressure <= 0.0 or not is_instance_valid(info.victim):
		return
	_pressure_tick(info, _hit_point(info))

## A small break-coloured tick spark, bigger as the victim's meter fills.
func _pressure_tick(info: HitInfo, at: Vector3) -> void:
	var p := FXRules.pressure_fraction(info.victim)
	var size := lerpf(TICK_FLASH.x, TICK_FLASH.y, p)
	_fx.call(&"impact_flash", at, size, false, false, lerpf(TICK_BRIGHT.x, TICK_BRIGHT.y, p), -1.0, BREAK_COLOR)
	_fx.call(&"spark", at, -info.hit_direction, lerpf(TICK_SPARK.x, TICK_SPARK.y, p))
	_record(&"pressure_tick", info.pressure, size)

static func _hit_point(info: HitInfo) -> Vector3:
	if info.hit_position != Vector3.ZERO or not is_instance_valid(info.victim):
		return info.hit_position
	return FXRules.upper_body(info.victim)

## The break burst on the guard (see the header), then the broken loop.
func _on_pressure_broken(fighter: Node3D, _attacker: Node3D) -> void:
	if not is_instance_valid(fighter):
		return
	var at := FXRules.guard_point(fighter)
	_fx.call(&"_ring_allowed")  # spend the ring budget: the break's ring is never refused
	_fx.call(&"impact_flash", at, BREAK_FLASH, false, true, BREAK_BRIGHT, 1.0, BREAK_COLOR)
	_start_rings(at)
	_world.call(&"glass", at, BREAK_SHARDS)
	for k in BREAK_SPARKS:
		var a := TAU * k / BREAK_SPARKS
		_fx.call(&"spark", at, Vector3(cos(a), 0.35, sin(a)).normalized(), 1.0)
	for bone: StringName in [Bones.L_LOWER_ARM, Bones.R_LOWER_ARM]:
		var arm := FXRules.limb_point(fighter, bone)
		_fx.call(&"spark", arm, (arm - FXRules.upper_body(fighter) + Vector3.UP * 0.1).normalized(), BREAK_ARM_SPARK)
	_fx.call(&"_flash", fighter)
	_fx.call(&"_jitter_start", fighter, HitInfo.Tier.STAGGER, 1.0, BREAK_JITTER)
	_start_daze(fighter)
	last_break = {"frame": Engine.get_physics_frames(), "position": at, "fighter": fighter, "ring": true}
	_record(&"break_burst", fighter.name, BREAK_FLASH)

func _on_pressure_recovered(fighter: Node3D) -> void:
	_stop_daze(fighter, false)
	if is_instance_valid(fighter):
		_record(&"break_recovered", fighter.name, 0.0)

func _start_rings(at: Vector3) -> void:
	var i := _ring_next
	_ring_next = (_ring_next + 1) % BREAK_RING_POOL
	_ring_age[i] = 0.0
	for k in 2:
		var r := _rings[i * 2 + k]
		r.global_position = at
		r.set_instance_shader_parameter(&"spin", randf() * TAU)
	_update_ring(i, 0.0)

## Shatter rings showing now (tests).
func active_break_rings() -> int:
	var n := 0
	for a in _ring_age:
		if a >= 0.0:
			n += 1
	return n

## The outer shatter ring of the most recent burst (tests).
func last_ring_node() -> MeshInstance3D:
	return _rings[((_ring_next + BREAK_RING_POOL - 1) % BREAK_RING_POOL) * 2]

func _update_ring(i: int, age: float) -> void:
	var done := true
	for k in 2:
		var r := _rings[i * 2 + k]
		var u: float = (age - float(BREAK_RING_DELAY[k])) / BREAK_RING_TIME
		if u < 0.0:
			r.visible = false
			done = false
			continue
		if u > 1.0:
			r.visible = false
			continue
		done = false
		var sz: Vector2 = BREAK_RING_SIZE[k]
		var s := lerpf(sz.x, sz.y, 1.0 - pow(1.0 - u, 2.2))
		r.scale = Vector3(s, s, s)
		r.visible = true
		r.set_instance_shader_parameter(&"tint", Color(BREAK_COLOR.r, BREAK_COLOR.g, BREAK_COLOR.b,
				BREAK_RING_BRIGHT * pow(1.0 - u, 1.3)))
	if done:
		_ring_age[i] = -1.0


# =============================================================================
# The broken loop: the cracked guard (Round 9) or the dazed head (Round 8)
# =============================================================================

## True while `fighter` shows the dazed loop (tests).
func is_dazed(fighter: Node3D) -> bool:
	var i := _daze_slot(fighter)
	return i >= 0 and _daze_stun[i]

## True while `fighter` shows the cracked guard (tests).
func is_guard_cracked(fighter: Node3D) -> bool:
	var i := _daze_slot(fighter)
	return i >= 0 and not _daze_stun[i]

## Broken loops showing, either kind (tests, debug).
func active_broken_loops() -> int:
	var n := 0
	for i in DAZE_POOL:
		if _daze_fighter[i] != null:
			n += 1
	return n

## Dazed loops showing (tests, debug).
func active_dazes() -> int:
	var n := 0
	for i in DAZE_POOL:
		if _daze_fighter[i] != null and _daze_stun[i]:
			n += 1
	return n

## The dazed loop's node for a fighter (tests), or null.
func get_daze_node(fighter: Node3D) -> Node3D:
	var i := _daze_slot(fighter)
	return _dazes[i] if i >= 0 and _daze_stun[i] else null

## The cracked guard's node for a fighter (tests), or null: it sits on the
## guard; its children are the arcs (CRACK_SPARKS per forearm, left first).
func get_crack_node(fighter: Node3D) -> Node3D:
	var i := _daze_slot(fighter)
	return _cracks[i] if i >= 0 and not _daze_stun[i] else null

## The arm glows of a fighter's cracked guard (tests): [left, right], or [].
func get_crack_glows(fighter: Node3D) -> Array:
	var i := _daze_slot(fighter)
	return _crack_glows[i] if i >= 0 and not _daze_stun[i] else []

func _daze_slot(fighter: Node3D) -> int:
	if not is_instance_valid(fighter):
		return -1
	for i in DAZE_POOL:
		if _daze_fighter[i] != null and _daze_fighter[i] == fighter and _daze_out[i] < 0.0:
			return i
	return -1

func _start_daze(fighter: Node3D) -> void:
	var slot := -1
	for i in DAZE_POOL:  # a second break on the same fighter restarts its loop
		if _daze_fighter[i] != null and _daze_fighter[i] == fighter:
			slot = i
	if slot < 0:
		var oldest := 0
		for i in DAZE_POOL:
			if _daze_fighter[i] == null:
				slot = i
				break
			if _daze_age[i] > _daze_age[oldest]:
				oldest = i
		if slot < 0:
			slot = oldest
	_drop_crack_glows(slot)
	_daze_fighter[slot] = fighter
	_daze_age[slot] = 0.0
	_daze_out[slot] = -1.0
	_daze_seen[slot] = false
	_daze_stun[slot] = broken_stun
	_dazes[slot].visible = broken_stun
	_cracks[slot].visible = not broken_stun
	if broken_stun:
		_place_daze(slot)
		_record(&"daze_start", fighter.name, 0.0)
		return
	_crack_spit[slot] = 0.0
	var glows: Array = []
	for bone: StringName in [Bones.L_LOWER_ARM, Bones.R_LOWER_ARM]:
		var g: Node3D = _fx.call(&"limb_glow", fighter, bone, BREAK_COLOR, 0.0, CRACK_GLOW)
		if g != null:
			glows.append(g)
	_crack_glows[slot] = glows
	_place_crack(slot, 0.0)
	_record(&"guard_crack_start", fighter.name, 0.0)

func _stop_daze(fighter: Node3D, at_once: bool) -> void:
	if not is_instance_valid(fighter):
		return
	for i in DAZE_POOL:
		if _daze_fighter[i] != null and _daze_fighter[i] == fighter:
			if at_once:
				_free_daze(i)
			elif _daze_out[i] < 0.0:
				_daze_out[i] = DAZE_FADE
			_record(&"daze_stop" if _daze_stun[i] else &"guard_crack_stop", fighter.name, 0.0)

func _free_daze(i: int) -> void:
	_daze_fighter[i] = null
	_daze_age[i] = -1.0
	_daze_out[i] = -1.0
	_dazes[i].visible = false
	_cracks[i].visible = false
	_drop_crack_glows(i)

func _drop_crack_glows(i: int) -> void:
	for g in _crack_glows[i]:
		if is_instance_valid(g):
			(g as Node).call(&"stop")
	_crack_glows[i] = []

func _update_dazes(delta: float) -> void:
	for i in DAZE_POOL:
		var f = _daze_fighter[i]
		if f == null:
			continue
		if not is_instance_valid(f) or not (f as Node3D).is_inside_tree() \
				or ((f as Node).has_method(&"is_dead") and f.call(&"is_dead")):
			_free_daze(i)
			continue
		_daze_age[i] += delta
		if _daze_out[i] >= 0.0:
			_daze_out[i] -= delta
			if _daze_out[i] < 0.0:
				_free_daze(i)
				continue
		else:
			var broken := FXRules.combat_flag(f, &"is_broken")
			if broken == 1:
				_daze_seen[i] = true
			if _daze_age[i] > Tuning.R8_BREAK_TIME + DAZE_SLACK or (broken == 0 and _daze_seen[i]):
				_daze_out[i] = DAZE_FADE
		if _daze_stun[i]:
			_place_daze(i)
		else:
			_place_crack(i, delta)

## The cracked guard: arcs re-strike at random on both forearms (a hashed
## flicker, CRACK_HZ times a second), a spark spits off one forearm now and
## then, and the arm glows flicker faintly.
func _place_crack(i: int, delta: float) -> void:
	var f: Node3D = _daze_fighter[i]
	var node := _cracks[i]
	var age := maxf(_daze_age[i], 0.0)
	var fade := clampf(age / DAZE_FADE, 0.0, 1.0) * (1.0 - float(_fx.call(&"get_fighter_fade", f)))
	if _daze_out[i] >= 0.0:
		fade *= clampf(_daze_out[i] / DAZE_FADE, 0.0, 1.0)
	node.global_position = FXRules.guard_point(f)
	var step := floorf(age * CRACK_HZ)
	var arms: Array[Vector3] = [FXRules.limb_point(f, Bones.L_LOWER_ARM), FXRules.limb_point(f, Bones.R_LOWER_ARM)]
	for a in 2:
		for k in CRACK_SPARKS:
			var j := a * CRACK_SPARKS + k
			var arc := node.get_child(j) as MeshInstance3D
			var h := Vector3(_hash01(step, j, 1.0), _hash01(step, j, 2.0), _hash01(step, j, 3.0)) * 2.0 - Vector3.ONE
			arc.global_position = arms[a] + h * CRACK_JUMP
			var on := 1.0 if _hash01(step, j, 4.0) > 0.45 else 0.15
			arc.set_instance_shader_parameter(&"spin", step * 1.7 + j)
			arc.set_instance_shader_parameter(&"tint", Color(BREAK_COLOR.r, BREAK_COLOR.g, BREAK_COLOR.b,
					2.2 * on * fade))
	var flick := 1.0 - CRACK_GLOW_FLICKER * _hash01(step, 7.0, 5.0)
	for g in _crack_glows[i]:
		if is_instance_valid(g):
			(g as Node).call(&"set_intensity", CRACK_GLOW * flick * fade)
	_crack_spit[i] -= delta
	if _crack_spit[i] <= 0.0 and _daze_out[i] < 0.0 and fade > 0.5:
		_crack_spit[i] = randf_range(CRACK_SPIT_GAP.x, CRACK_SPIT_GAP.y)
		var at: Vector3 = arms[randi() % 2]
		var dir := Vector3(randf_range(-1.0, 1.0), randf_range(0.2, 1.0), randf_range(-1.0, 1.0)).normalized()
		_fx.call(&"spark", at, dir, CRACK_SPIT)
		_record(&"guard_crack_spark", f.name, CRACK_SPIT)

## A stable pseudo-random 0..1 for (step, index, salt).
static func _hash01(step: float, index: float, salt: float) -> float:
	return fposmod(sin(step * 12.9898 + index * 78.233 + salt * 37.719) * 43758.5453, 1.0)

func _place_daze(i: int) -> void:
	var f: Node3D = _daze_fighter[i]
	var node := _dazes[i]
	var head := FXRules.head_of(f)
	node.global_position = head + Vector3.UP * DAZE_HEIGHT
	var age := maxf(_daze_age[i], 0.0)
	var fade := clampf(age / DAZE_FADE, 0.0, 1.0) * (1.0 - float(_fx.call(&"get_fighter_fade", f)))
	if _daze_out[i] >= 0.0:
		fade *= clampf(_daze_out[i] / DAZE_FADE, 0.0, 1.0)
	for k in DAZE_SPARKS:
		var star := node.get_child(k) as MeshInstance3D
		var ang := age * DAZE_SPEED + k * TAU / DAZE_SPARKS
		# A tilted, wobbling orbit: woozy rather than a neat halo.
		var tilt := 0.06 * sin(age * 2.3)
		star.position = Vector3(cos(ang) * DAZE_RADIUS, tilt * cos(ang) * 3.0 + 0.03 * sin(age * 9.0 + k),
				sin(ang) * DAZE_RADIUS * 0.6)
		var flick := 0.75 + 0.25 * sin(age * 23.0 + k * 1.7)
		star.set_instance_shader_parameter(&"spin", age * 6.0 + k)
		star.set_instance_shader_parameter(&"tint", Color(BREAK_COLOR.r, BREAK_COLOR.g, BREAK_COLOR.b,
				1.6 * fade * flick))
	var shimmer := node.get_child(DAZE_SPARKS) as MeshInstance3D
	shimmer.global_position = head
	var wob := 1.0 + 0.12 * sin(age * TAU * 1.3)
	shimmer.scale = Vector3.ONE * DAZE_SHIMMER * wob
	shimmer.set_instance_shader_parameter(&"spin", age * 0.8)
	shimmer.set_instance_shader_parameter(&"tint", Color(BREAK_COLOR.r, BREAK_COLOR.g, BREAK_COLOR.b,
			(0.35 + 0.2 * sin(age * TAU * 2.1)) * fade))


# =============================================================================
# Air combo
# =============================================================================

## The launcher jump: a dust pop as the feet leave the floor.
func _on_air_follow_started(fighter: Node3D, _target: Node3D) -> void:
	if not is_instance_valid(fighter):
		return
	var feet := FXRules.feet_of(fighter)
	_fx.call(&"dust", feet + Vector3.UP * 0.05, _world.call(&"surface_color", &"floor"), AIR_DUST, Vector3.UP, false)
	_record(&"air_follow", fighter.name, AIR_DUST)

## An air hit: a small cool flash on the body, a little bigger with the count.
func _on_air_hit(_attacker: Node3D, victim: Node3D, count: int) -> void:
	if not is_instance_valid(victim):
		return
	var u := clampf(float(count - 1) / maxf(float(Tuning.debug_air_hits - 1), 1.0), 0.0, 1.0)
	var size := lerpf(AIR_FLASH.x, AIR_FLASH.y, u)
	_fx.call(&"impact_flash", FXRules.upper_body(victim), size, false, false, AIR_BRIGHT, -1.0, AIR_COLOR)
	_record(&"air_hit", count, size)


# =============================================================================
# Frame update and construction
# =============================================================================

func _process(delta: float) -> void:
	var real := delta / maxf(Engine.time_scale, 0.001)
	_update_charges(real)
	for i in BREAK_RING_POOL:
		if _ring_age[i] >= 0.0:
			_ring_age[i] += real
			_update_ring(i, _ring_age[i])
	_update_dazes(delta)

func _build() -> void:
	var trng := RandomNumberGenerator.new()
	trng.seed = 8088
	_ring_mat = _fx.call(&"_billboard_mat", BILLBOARD_XRAY, _make_shatter_tex(trng))
	_ring_age.resize(BREAK_RING_POOL)
	_ring_age.fill(-1.0)
	for i in BREAK_RING_POOL * 2:
		_rings.append(_fx.call(&"_fx_quad", _ring_mat, "BreakRing%d" % i, _holder))
	var star_mat: Material = _fx.get(&"_star_mat")
	var halo_mat: Material = _fx.get(&"_halo_mat")
	_daze_age.resize(DAZE_POOL)
	_daze_age.fill(-1.0)
	_daze_out.resize(DAZE_POOL)
	_daze_out.fill(-1.0)
	for i in DAZE_POOL:
		var n := Node3D.new()
		n.name = "BrokenDaze%d" % i
		n.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		n.visible = false
		_holder.add_child(n)
		for k in DAZE_SPARKS:
			var star: MeshInstance3D = _fx.call(&"_fx_quad", star_mat, "Spark%d" % k, n)
			star.scale = Vector3.ONE * DAZE_STAR
			star.visible = true
		var sh: MeshInstance3D = _fx.call(&"_fx_quad", halo_mat, "Shimmer", n)
		sh.visible = true
		_dazes.append(n)
		_daze_fighter.append(null)
		_daze_seen.append(false)
		_daze_stun.append(false)
		var cn := Node3D.new()
		cn.name = "CrackedGuard%d" % i
		cn.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		cn.visible = false
		_holder.add_child(cn)
		for k in CRACK_SPARKS * 2:
			var arc: MeshInstance3D = _fx.call(&"_fx_quad", star_mat, "Arc%d" % k, cn)
			arc.scale = Vector3.ONE * CRACK_STAR
			arc.visible = true
		_cracks.append(cn)
		_crack_glows.append([])
	_crack_spit.resize(DAZE_POOL)
	_crack_spit.fill(0.0)

## A shatter ring: a jagged broken ring with crack spokes running in and out.
func _make_shatter_tex(r: RandomNumberGenerator) -> ImageTexture:
	var S := 128
	var alpha := PackedFloat32Array()
	var value := PackedFloat32Array()
	alpha.resize(S * S)
	value.resize(S * S)
	var spokes := 11
	var spoke_ang: Array[float] = []
	var spoke_len: Array[float] = []
	for k in spokes:
		spoke_ang.append(TAU * (k + r.randf_range(-0.3, 0.3)) / spokes)
		spoke_len.append(r.randf_range(0.25, 0.5))
	var jag: Array[float] = []  # the ring's radius wobble, 32 steps round
	for k in 32:
		jag.append(r.randf_range(-0.05, 0.05))
	var gaps: Array[float] = []  # breaks in the ring
	for k in 5:
		gaps.append(r.randf() * TAU)
	for y in S:
		for x in S:
			var px := (x + 0.5) / S * 2.0 - 1.0
			var py := (y + 0.5) / S * 2.0 - 1.0
			var d := sqrt(px * px + py * py)
			var a := atan2(py, px)
			var ja := fposmod(a, TAU) / TAU * 32.0
			var j0 := int(ja) % 32
			var rr := 0.74 + lerpf(jag[j0], jag[(j0 + 1) % 32], ja - floorf(ja))
			var ring := clampf(1.0 - absf(d - rr) / 0.045, 0.0, 1.0)
			for g in gaps:
				if absf(angle_difference(a, g)) < 0.09:
					ring = 0.0
			var crack := 0.0
			for k in spokes:
				var off := absf(angle_difference(a, spoke_ang[k])) * d
				var r0 := rr - spoke_len[k] * 0.6
				var r1 := rr + spoke_len[k] * 0.4
				if d > r0 and d < minf(r1, 0.98):
					var w := clampf(1.0 - off / 0.018, 0.0, 1.0)
					crack = maxf(crack, w * (1.0 - absf(d - rr) / spoke_len[k]))
			var glow := exp(-pow((d - rr) / 0.12, 2.0)) * 0.35
			var i := y * S + x
			alpha[i] = clampf(maxf(ring, crack) + glow, 0.0, 1.0) * clampf((1.0 - d) / 0.05, 0.0, 1.0)
			value[i] = 1.0
	return _fx.call(&"_image_from", alpha, value, S, S)
