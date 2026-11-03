class_name MoveLibrary
## Every move in the game. OWNER: agent B (combat).
##
## Round 7 (docs/Round 7 — Freeflow Combat.md: Moves): the player's kit is the
## moves of Tuning.R7_MOVES, one per button (the punch button counts jab, cross,
## hook; the punch and the three kicks held give their heavies: ComboGraph),
## plus the dropping strike (any strike in the air or late in a vault). Their
## frame data, damage and reactions come from that table (LOCAL_R7 until the
## lead moves an entry there); this file says where each lands (reach, height,
## hit level, target bone), which way it pushes and which limbs strike. Enemy moves carry a preset tier, damage from Tuning.DMG_ENEMY,
## startup from AttackDirector.enemy_startup_frames() and whether the player
## can counter them.

const PLAYER_MOVES: Array[StringName] = [&"jab", &"cross", &"hook", &"heavy_jab", &"heavy_cross",
	&"heavy_hook", &"uppercut", &"gut_punch", &"leg_kick", &"front_kick", &"roundhouse", &"counter",
	&"heavy_leg_kick", &"heavy_front_kick", &"heavy_roundhouse", &"drop_strike"]
## Round 7 entries (R7_MOVES format) for player moves Tuning does not list yet
## (candidates for Tuning.R7_MOVES). The dropping strike drives a body down:
## startup 6, active until it lands (at most 40), recovery 12 frames.
const LOCAL_R7 := {
	&"drop_strike": {"f": Vector3(6, 40, 12), "dmg": 12.0, "react": &"knockdown", "push": 1.0, "stun": 0.0,
		"hitstop": 0.12, "weight": 0.75, "tier": &"knockdown", "guard_break": true},
}
const ENEMY_MOVES: Array[StringName] = [&"e_jab", &"e_hook", &"e_kick", &"e_grab", &"e_stick_swing",
	&"e_stick_thrust", &"e_heavy", &"e_charge", &"e_grab_slam", &"e_throw_debris", &"e_sweep"]

## Damage of the legacy Duelist sweep before its Round 5 scale (x0.3).
const DMG := {&"e_sweep": 50.0}
## Frames of blockstun a guarded flinch-tier enemy hit leaves (stagger tier and up: 12).
const ENEMY_BLOCKSTUN_LIGHT := 8.0
## Enemy hits on the player (Feel Reference: What enemies can do to you; kept
## in Round 7): punches and kicks flinch or stagger; the heavy's charge and any
## grab-throw knock the player down; enemies never launch the player.
const ENEMY_TIER := {
	&"e_jab": HitInfo.Tier.FLINCH,
	&"e_hook": HitInfo.Tier.FLINCH,          # the grunt's cross: jab-cross reads as two flinches
	&"e_kick": HitInfo.Tier.STAGGER,         # front kick: pushes you back
	&"e_stick_swing": HitInfo.Tier.STAGGER,
	&"e_stick_thrust": HitInfo.Tier.FLINCH,
	&"e_heavy": HitInfo.Tier.STAGGER,        # overhead smash
	&"e_charge": HitInfo.Tier.KNOCKDOWN,     # shoulder charge: knocks you down unless dodged
	&"e_grab": HitInfo.Tier.KNOCKDOWN,       # grab-throw
	&"e_grab_slam": HitInfo.Tier.KNOCKDOWN,
	&"e_throw_debris": HitInfo.Tier.STAGGER, # legacy Thrower: a prop hit is a stagger
	&"e_sweep": HitInfo.Tier.STUMBLE,        # legacy Duelist sweep
}
## Round 7: attacks the player cannot counter (blue tell: dodge only).
const UNCOUNTERABLE: Array[StringName] = [&"e_grab", &"e_grab_slam", &"e_charge"]

## Until agent P poses a move (PoseLibrary.has_move), play the closest existing one.
const ANIM_FALLBACK := {
	&"jab": &"jab1", &"cross": &"jab2", &"hook": &"jab3", &"heavy_jab": &"jab",
	&"heavy_cross": &"power_punch", &"heavy_hook": &"hook", &"uppercut": &"power_punch",
	&"gut_punch": &"crouch_punch", &"leg_kick": &"sweep", &"front_kick": &"kick",
	&"roundhouse": &"sparta_kick", &"counter": &"cross", &"heavy_leg_kick": &"leg_kick",
	&"heavy_front_kick": &"front_kick", &"heavy_roundhouse": &"roundhouse", &"drop_strike": &"hammer_fist",
	&"back_kick": &"e_kick",
	&"e_jab": &"e_hook", &"e_stick_swing": &"e_heavy", &"e_stick_thrust": &"e_hook",
	&"e_grab_slam": &"e_grab", &"e_sweep": &"leg_sweep",
}
## Second choice when the first fallback is missing too.
const ANIM_FALLBACK_2 := {&"heavy_jab": &"jab1", &"heavy_cross": &"cross", &"heavy_hook": &"jab3",
	&"gut_punch": &"jab2", &"leg_kick": &"leg_sweep", &"front_kick": &"sparta_kick", &"counter": &"jab2",
	&"uppercut": &"jab2"}
## Striking bones when PoseLibrary.STRIKE_BONES (authoritative) lists neither
## the move nor its pose; kept equal to STRIKE_BONES where both exist.
const LIMB_FALLBACK := {
	&"jab": [&"LeftHand"], &"cross": [&"RightHand"], &"hook": [&"LeftHand"],
	&"heavy_jab": [&"LeftHand"], &"heavy_cross": [&"RightHand"], &"heavy_hook": [&"LeftHand"],
	&"uppercut": [&"RightHand"], &"gut_punch": [&"RightHand"],
	&"leg_kick": [&"RightFoot", &"RightLowerLeg"], &"front_kick": [&"RightFoot", &"RightLowerLeg"],
	&"roundhouse": [&"RightFoot", &"RightLowerLeg"], &"counter": [&"RightHand"],
	&"heavy_leg_kick": [&"RightFoot", &"RightLowerLeg"], &"heavy_front_kick": [&"RightFoot", &"RightLowerLeg"],
	&"heavy_roundhouse": [&"RightFoot", &"RightLowerLeg"], &"drop_strike": [&"RightHand"],
	&"back_kick": [&"RightFoot", &"RightLowerLeg"],
	&"e_sweep": [&"RightFoot", &"RightLowerLeg"], &"e_jab": [&"LeftHand"], &"e_stick_swing": [&"RightHand"],
	&"e_stick_thrust": [&"RightHand"], &"e_grab_slam": [&"LeftHand", &"RightHand"],
}

static var _moves: Dictionary = {}

static func get_move(id: StringName) -> MoveData:
	if _moves.is_empty():
		_build()
	return _moves.get(id)

static func has_move(id: StringName) -> bool:
	if _moves.is_empty():
		_build()
	return _moves.has(id)

static func _add(m: MoveData) -> void:
	if m.anim == &"":
		m.anim = anim_for(m.id)
	# The pose library is the source of truth for which limb strikes.
	var sb: Dictionary = PoseLibrary.STRIKE_BONES
	var src: Array = sb.get(m.id, sb.get(m.anim, LIMB_FALLBACK.get(m.id, [])))
	if not src.is_empty():
		var bones: Array[StringName] = []
		for b in src:
			bones.append(StringName(b))
		m.limbs = bones
		m.limb = bones[0]
	_moves[m.id] = m

## Pose for a move id: its own once agent P has it, else the closest fallback
## (a heavy kick falls back to its light kick's pose, and so on).
static func anim_for(id: StringName, depth := 0) -> StringName:
	if PoseLibrary.has_move(id):
		return id
	for table: Dictionary in [ANIM_FALLBACK, ANIM_FALLBACK_2]:
		var alt: StringName = table.get(id, &"")
		if alt != &"" and PoseLibrary.has_move(alt):
			return alt
	var first: StringName = ANIM_FALLBACK.get(id, &"")
	if first != &"" and depth < 3:
		return anim_for(first, depth + 1)
	return id

## A Round 7 player move: frame data and damage from Tuning.R7_MOVES[id].
## `target`: the bone it lands on without a limb contact (head for high
## punches, the waist for the gut punch, the leg for the leg kick).
static func _r7(id: StringName, level: int, reach: float, height: float, target: StringName,
		push := Vector3(0.0, 0.0, 1.0)) -> MoveData:
	var e: Dictionary = Tuning.R7_MOVES.get(id, LOCAL_R7.get(id, {}))
	var f: Vector3 = e["f"]
	var m := MoveData.new()
	m.id = id
	m.r7 = true
	m.startup = f.x
	m.active = f.y
	m.recovery = f.z
	m.damage = float(e["dmg"])
	m.guard_break = bool(e.get("guard_break", false))
	m.hit_level = level
	m.reach = reach
	m.height = height
	m.target_bone = target
	m.push_dir = push.normalized()
	return m

static func _build() -> void:
	var hi := HitInfo.Level.HIGH
	var mid := HitInfo.Level.MID
	var low := HitInfo.Level.LOW
	# --- Player moves (Round 7) -----------------------------------------------------
	# push_dir (x right, y up, z forward of the attacker): which way the hit
	# drives the victim. Heights are m above the feet at height scale 1 (head
	# ~1.65, chest 1.35, waist 1.0, knee 0.5).
	_add(_r7(&"jab", hi, 1.05, 1.45, Bones.HEAD))
	_add(_r7(&"cross", hi, 1.1, 1.45, Bones.HEAD))
	# Left hook: the fist sweeps left to right, so the head turns to the attacker's right.
	_add(_r7(&"hook", hi, 1.05, 1.45, Bones.HEAD, Vector3(0.75, 0.0, 0.65)))
	_add(_r7(&"heavy_jab", hi, 1.1, 1.45, Bones.HEAD))
	_add(_r7(&"heavy_cross", hi, 1.15, 1.45, Bones.HEAD))
	_add(_r7(&"heavy_hook", hi, 1.1, 1.45, Bones.HEAD, Vector3(0.75, 0.0, 0.65)))
	# Uppercut: up under the chin, lifting.
	_add(_r7(&"uppercut", hi, 1.0, 1.45, Bones.HEAD, Vector3(0.0, 0.75, 0.65)))
	# Gut punch: into the waist.
	var gp := _r7(&"gut_punch", mid, 1.0, 1.0, Bones.SPINE)
	gp.reach_radius = 0.42
	_add(gp)
	# Leg kick: the right shin into the victim's lead (left) leg, low, sweeping across.
	var lk := _r7(&"leg_kick", low, 1.25, 0.5, Bones.L_LOWER_LEG, Vector3(-0.4, 0.0, 0.9))
	lk.is_kick = true
	lk.limb_radius = 0.26
	lk.reach_radius = 0.4
	_add(lk)
	# Front kick: a straight push kick to the body.
	var fk := _r7(&"front_kick", mid, 1.4, 1.05, Bones.SPINE)
	fk.is_kick = true
	fk.limb_radius = 0.24
	fk.reach_radius = 0.42
	_add(fk)
	# Right roundhouse to the head: the shin sweeps right to left.
	var rh := _r7(&"roundhouse", hi, 1.45, 1.45, Bones.HEAD, Vector3(-0.75, 0.1, 0.65))
	rh.is_kick = true
	rh.limb_radius = 0.26
	rh.reach_radius = 0.45
	_add(rh)
	# Counter: a straight punch to the body that always connects (play_counter).
	_add(_r7(&"counter", mid, 1.1, 1.35, Bones.CHEST))
	# Heavy kicks (the kick buttons held): the light kick's line, a little longer.
	var hlk := _r7(&"heavy_leg_kick", low, 1.3, 0.5, Bones.L_LOWER_LEG, Vector3(-0.4, 0.0, 0.9))
	var hfk := _r7(&"heavy_front_kick", mid, 1.45, 1.05, Bones.SPINE)
	var hrh := _r7(&"heavy_roundhouse", hi, 1.5, 1.45, Bones.HEAD, Vector3(-0.75, 0.1, 0.65))
	for hk: MoveData in [hlk, hfk, hrh]:
		hk.is_kick = true
		hk.limb_radius = 0.26
		hk.reach_radius = 0.45
		_add(hk)
	# Dropping strike: any strike in the air (a jump) or late in a vault, down
	# and forward onto the target; active until the fighter lands.
	var ds := _r7(&"drop_strike", mid, 1.3, 0.7, Bones.CHEST, Vector3(0.0, -0.35, 0.95))
	ds.drop = true
	ds.drop_max = float(LOCAL_R7[&"drop_strike"]["f"].y)
	ds.limb_radius = 0.3
	ds.reach_radius = 0.5
	_add(ds)

	# The Duelist's teleport counter (CombatController.start_counter): a back
	# kick from behind, a blue tell. On the player it is an enemy hit: a knockdown.
	var bk := MoveData.new()
	bk.id = &"back_kick"
	bk.kind = &"counter"
	bk.enemy = true
	bk.counterable = false
	bk.tell_kind = &"counter"
	bk.startup = 4.0
	bk.active = 4.0
	bk.recovery = 20.0
	bk.damage = Tuning.DMG_ENEMY[&"e_kick"]
	bk.preset_tier = HitInfo.Tier.KNOCKDOWN
	bk.unblockable = true
	bk.is_kick = true
	bk.limb_radius = 0.26
	bk.reach = 1.5
	bk.reach_radius = 0.45
	bk.height = 1.1
	bk.hit_level = mid
	bk.force_bone = true
	_add(bk)

	# --- Enemy roster (startup = AttackDirector.enemy_startup_frames, set per attack) --
	var ej := _enemy(&"e_jab", 3.0, 16.0)
	ej.reach = 1.2
	ej.height = 1.4
	ej.lunge_speed = 1.6
	ej.lunge_start = 0.7
	ej.hit_level = hi
	_add(ej)

	var hook := _enemy(&"e_hook", 4.0, 18.0)
	hook.reach = 1.25
	hook.height = 1.4
	hook.lunge_speed = 2.0
	hook.lunge_start = 0.7
	hook.push_dir = Vector3(0.6, 0.0, 0.8)
	hook.hit_level = hi
	_add(hook)

	var kick := _enemy(&"e_kick", 4.0, 24.0)
	kick.limb_radius = 0.24
	kick.reach = 1.45
	kick.height = 1.0
	kick.force_bone = true
	kick.lunge_speed = 1.5
	kick.lunge_start = 0.75
	kick.is_kick = true
	kick.hit_level = mid
	_add(kick)

	var swing := _enemy(&"e_stick_swing", 5.0, 24.0)
	swing.reach = 2.2
	swing.reach_radius = 0.45
	swing.limb_radius = 0.3
	swing.height = 1.35
	swing.push_dir = Vector3(-0.7, 0.0, 0.7)
	swing.hit_level = hi
	_add(swing)

	var thrust := _enemy(&"e_stick_thrust", 4.0, 20.0)
	thrust.reach = 2.2
	thrust.reach_radius = 0.35
	thrust.limb_radius = 0.25
	thrust.height = 1.25
	thrust.lunge_speed = 1.5
	thrust.lunge_start = 0.7
	thrust.hit_level = mid
	_add(thrust)

	var heavy := _enemy(&"e_heavy", 5.0, 26.0)
	heavy.reach = 1.4
	heavy.height = 1.35
	heavy.push_dir = Vector3(0.0, -0.4, 0.9)
	heavy.lunge_speed = 2.0
	heavy.lunge_start = 0.75
	heavy.hit_level = mid
	_add(heavy)

	var charge := _enemy(&"e_charge", 14.0, 30.0)
	charge.unblockable = true
	charge.limb = &"RightUpperArm"
	charge.limbs = [&"RightUpperArm", &"Chest"] as Array[StringName]
	charge.limb_radius = 0.38
	charge.reach = 1.3
	charge.reach_radius = 0.55
	charge.height = 1.2
	charge.lunge_speed = 7.5
	charge.lunge_start = 0.45
	charge.force_bone = true
	charge.hit_level = mid
	charge.tell_kind = &"charge"  # uncounterable: a blue tell (HUD colours anything but &"strike" blue)
	_add(charge)

	for gid: StringName in [&"e_grab", &"e_grab_slam"]:
		var eg := _enemy(gid, 3.0, 6.0)
		eg.kind = &"grab"
		eg.tell_kind = &"grab"
		eg.whiff_recovery = 30.0
		eg.unblockable = true
		eg.reach = Tuning.GRAB_RANGE
		eg.hit_level = hi
		_add(eg)

	var deb := _enemy(&"e_throw_debris", 2.0, 20.0)
	deb.kind = &"projectile"
	deb.blockstun = 12.0
	deb.hit_level = mid
	_add(deb)

	var es := _enemy(&"e_sweep", 5.0, 24.0)
	es.damage = DMG[&"e_sweep"] * 0.3
	es.is_kick = true
	es.force_bone = true
	es.limb_radius = 0.28
	es.reach = 1.35
	es.reach_radius = 0.42
	es.height = 0.3
	es.target_bone = &"RightLowerLeg"
	es.hit_level = low
	_add(es)

static func _enemy(id: StringName, active: float, recovery: float) -> MoveData:
	var m := MoveData.new()
	m.id = id
	m.enemy = true
	m.startup = Tuning.ENEMY_STARTUP.get(id, 27.0)
	m.active = active
	m.recovery = recovery
	m.damage = Tuning.DMG_ENEMY.get(id, 10.0)
	m.preset_tier = ENEMY_TIER.get(id, HitInfo.Tier.FLINCH)
	m.counterable = not UNCOUNTERABLE.has(id)
	# Guarding a light enemy hit leaves a punish window; heavier hits hold the guard longer.
	m.blockstun = ENEMY_BLOCKSTUN_LIGHT if m.preset_tier <= HitInfo.Tier.FLINCH else 12.0
	return m
