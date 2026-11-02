class_name MoveLibrary
## Every move in the game. OWNER: agent B (fighter & combat).
##
## Round 5 (Feel Reference: Strikes and body reactions; Health, damage and
## enemies): every player strike has a strike class that sets its base power,
## frame data (Tuning.STRIKE_FRAMES: jab 5/3/10, cross 9/4/16, kick 12/4/22,
## sweep 10/5/20, knee and elbow 7/3/14, frames of the fighter's own time) and
## damage (Tuning.STRIKE_DAMAGE). The reaction comes from the power score at
## contact, never from the move. Enemy moves carry a preset tier, damage from
## Tuning.DMG_ENEMY, and startup from AttackDirector.enemy_startup_frames().

const PLAYER_MOVES: Array[StringName] = [&"jab1", &"jab2", &"cross", &"hook", &"uppercut",
	&"elbow", &"knee_strike", &"sparta_kick", &"roundhouse", &"leg_sweep", &"backfist",
	&"crouch_punch", &"rising_uppercut", &"drop_strike", &"ground_stomp", &"knee_drop", &"back_kick",
	&"jab3", &"power_punch", &"hammer_fist", &"flying_kick", &"mount_punch", &"stomp", &"punt"]
const ENEMY_MOVES: Array[StringName] = [&"e_jab", &"e_hook", &"e_kick", &"e_grab", &"e_stick_swing",
	&"e_stick_thrust", &"e_heavy", &"e_charge", &"e_grab_slam", &"e_throw_debris", &"e_sweep"]

## Dropping strike (jump or vault attack): not in the doc's frame table.
## Startup is short so it comes out on the way down; the active frames last
## until the fighter lands (at most DROP_ACTIVE_MAX); a short landing recovery.
const DROP_STARTUP := 6.0
const DROP_ACTIVE_MAX := 40.0
const DROP_RECOVERY := 12.0
## Frames of blockstun a guarded flinch-tier enemy hit leaves (stagger tier and up: 12).
const ENEMY_BLOCKSTUN_LIGHT := 8.0
## Damage of the legacy Duelist sweep before its Round 5 scale (x0.3).
const DMG := {&"e_sweep": 50.0}
## Enemy hits on the player (Feel Reference: What enemies can do to you):
## punches and kicks flinch or stagger; the heavy's charge and any grab-throw
## knock the player down; enemies never launch the player.
const ENEMY_TIER := {
	&"e_jab": HitInfo.Tier.FLINCH,
	&"e_hook": HitInfo.Tier.FLINCH,          # the grunt's cross: jab-cross reads as two flinches
	&"e_kick": HitInfo.Tier.STAGGER,         # front kick: pushes you back
	&"e_stick_swing": HitInfo.Tier.STAGGER,
	&"e_stick_thrust": HitInfo.Tier.FLINCH,
	&"e_heavy": HitInfo.Tier.STAGGER,        # overhead smash
	&"e_charge": HitInfo.Tier.KNOCKDOWN,     # shoulder charge: knocks you down unless parried or teleported
	&"e_grab": HitInfo.Tier.KNOCKDOWN,       # grab-throw
	&"e_grab_slam": HitInfo.Tier.KNOCKDOWN,
	&"e_throw_debris": HitInfo.Tier.STAGGER, # legacy Thrower: a prop hit is a stagger
	&"e_sweep": HitInfo.Tier.STUMBLE,        # legacy Duelist sweep
}
## Round 5 poses (agent P) that a string move plays when they exist.
const ROUND5_ANIM := {&"jab1": &"jab", &"sparta_kick": &"kick", &"leg_sweep": &"sweep",
	&"knee_strike": &"knee"}
## Until agent P poses a move, play the closest existing one.
const ANIM_FALLBACK := {
	&"cross": &"jab2", &"hook": &"jab3", &"uppercut": &"power_punch", &"roundhouse": &"sparta_kick",
	&"backfist": &"jab3", &"flying_kick": &"sparta_kick", &"hammer_fist": &"power_punch",
	&"crouch_punch": &"jab1", &"rising_uppercut": &"power_punch", &"knee": &"sparta_kick",
	&"headbutt": &"jab1", &"neck_throw": &"throw", &"mount_punch": &"power_punch",
	&"stomp": &"punt", &"upward_throw": &"throw", &"wall_slam": &"throw", &"e_sweep": &"leg_sweep",
	&"punt": &"sparta_kick", &"elbow": &"jab3", &"knee_strike": &"knee", &"drop_strike": &"hammer_fist",
	&"ground_stomp": &"stomp", &"knee_drop": &"mount_punch",
	&"e_jab": &"e_hook", &"e_stick_swing": &"e_heavy", &"e_stick_thrust": &"e_hook",
	&"e_grab_slam": &"e_grab",
}
## Second choice when the first fallback is missing too.
const ANIM_FALLBACK_2 := {&"knee_strike": &"sparta_kick", &"ground_stomp": &"punt",
	&"knee_drop": &"power_punch", &"drop_strike": &"power_punch", &"elbow": &"jab2"}
## Striking bones when PoseLibrary.STRIKE_BONES (authoritative) does not list
## the move or its pose; kept equal to STRIKE_BONES where both exist.
const LIMB_FALLBACK := {
	&"cross": [&"RightHand"], &"hook": [&"LeftHand"], &"uppercut": [&"RightHand"],
	&"roundhouse": [&"RightFoot", &"RightLowerLeg"], &"backfist": [&"RightHand"],
	&"flying_kick": [&"RightFoot", &"RightLowerLeg"], &"hammer_fist": [&"RightHand", &"LeftHand"],
	&"crouch_punch": [&"RightHand"], &"rising_uppercut": [&"RightHand"], &"knee": [&"RightLowerLeg", &"RightUpperLeg"],
	&"headbutt": [&"Head"], &"mount_punch": [&"RightHand"], &"stomp": [&"RightFoot"],
	&"e_sweep": [&"RightFoot", &"RightLowerLeg"], &"jab2": [&"RightHand"],
	&"elbow": [&"RightLowerArm"], &"knee_strike": [&"RightLowerLeg", &"RightUpperLeg"],
	&"drop_strike": [&"RightHand"],
	&"ground_stomp": [&"RightFoot"], &"knee_drop": [&"RightLowerLeg"],
	&"e_jab": [&"LeftHand"], &"e_stick_swing": [&"RightHand"],
	&"e_stick_thrust": [&"RightHand"], &"e_grab_slam": [&"LeftHand", &"RightHand"],
}
## Round 5 classes of the legacy Upgrade 2 moves (no button reaches them; kept
## for the lab and old callers).
const LEGACY_CLASS := {&"jab3": &"jab", &"power_punch": &"cross", &"hammer_fist": &"cross",
	&"flying_kick": &"kick", &"mount_punch": &"ground", &"stomp": &"ground", &"punt": &"ground"}

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
	if m.chargeable and m.charge_hold == &"":
		m.charge_hold = charge_hold_for(m)
	_moves[m.id] = m

## Pose for a move id: its Round 5 pose, its own, else a fallback.
static func anim_for(id: StringName) -> StringName:
	var r5: StringName = ROUND5_ANIM.get(id, &"")
	if r5 != &"" and pose_has_move(r5):
		return r5
	if pose_has_move(id):
		return id
	for table: Dictionary in [ANIM_FALLBACK, ANIM_FALLBACK_2]:
		var alt: StringName = table.get(id, &"")
		if alt != &"" and pose_has_move(alt):
			return alt
	return ANIM_FALLBACK.get(id, id)

## The Round 5 `<class>_charge` hold (agent P), else `<id>_charge`, else the
## closest existing hold.
static func charge_hold_for(m: MoveData) -> StringName:
	if m.strike_class != &"":
		var cls := StringName(String(m.strike_class) + "_charge")
		if PoseLibrary.HOLDS.has(cls):
			return cls
	var own := StringName(String(m.id) + "_charge")
	if PoseLibrary.HOLDS.has(own) or PoseLibrary.POSES.has(own):
		return own
	if m.is_kick and PoseLibrary.POSES.has(&"kick_chamber"):
		return &"kick_chamber"
	return &"power_charge"

## A Round 5 player strike of class `cls` (frame data from Tuning.STRIKE_FRAMES).
static func _strike(id: StringName, cls: StringName, level: int, reach: float, height: float,
		push := Vector3(0.0, 0.0, 1.0)) -> MoveData:
	var m := MoveData.new()
	m.id = id
	m.set_class_frames(cls)
	m.damage = Tuning.STRIKE_DAMAGE.get(cls, 4.0)
	m.hit_level = level
	m.reach = reach
	m.height = height
	m.push_dir = push.normalized()
	m.chargeable = true
	m.is_kick = cls in [&"kick", &"sweep"]
	m.cancel_window = 10.0
	return m

## PoseLibrary.has_move(id) when agent P provides it, else its MOVES table.
static func pose_has_move(id: StringName) -> bool:
	var lib: Script = PoseLibrary
	for md in lib.get_script_method_list():
		if md.get("name", "") == "has_move":
			return bool(lib.call(&"has_move", id))
	return PoseLibrary.MOVES.has(id)

static func _build() -> void:
	var hi := HitInfo.Level.HIGH
	var mid := HitInfo.Level.MID
	var low := HitInfo.Level.LOW
	# --- Player strings (ComboGraph) ---------------------------------------------
	# push_dir (x right, y up, z forward of the attacker): which way the hit
	# drives the struck chain and, from the launch tier, the whole body.
	var j1 := _strike(&"jab1", &"jab", hi, 1.05, 1.4)
	_add(j1)
	var j2 := _strike(&"jab2", &"jab", hi, 1.05, 1.4)
	_add(j2)
	var j3 := _strike(&"jab3", &"jab", hi, 1.05, 1.4)  # legacy
	_add(j3)
	var cr := _strike(&"cross", &"cross", hi, 1.1, 1.4)
	_add(cr)
	# Left hook: the fist sweeps left to right, so the head turns to the attacker's right.
	var hk := _strike(&"hook", &"cross", hi, 1.05, 1.45, Vector3(0.75, 0.0, 0.65))
	_add(hk)
	var up := _strike(&"uppercut", &"cross", mid, 1.0, 1.3, Vector3(0.0, 0.75, 0.65))
	up.ender = true
	_add(up)
	# Right horizontal elbow: sweeps right to left.
	var el := _strike(&"elbow", &"elbow", hi, 0.85, 1.4, Vector3(-0.5, 0.0, 0.85))
	el.ender = true
	el.limb_radius = 0.22
	el.reach_radius = 0.42
	_add(el)
	var kn := _strike(&"knee_strike", &"knee", mid, 0.85, 1.0, Vector3(0.0, 0.55, 0.85))
	kn.limb_radius = 0.22
	kn.reach_radius = 0.42
	_add(kn)
	var sk := _strike(&"sparta_kick", &"kick", mid, 1.4, 1.0)
	sk.limb_radius = 0.24
	sk.reach_radius = 0.42
	_add(sk)
	# Right roundhouse: the shin sweeps right to left.
	var rh := _strike(&"roundhouse", &"kick", hi, 1.45, 1.35, Vector3(-0.75, 0.1, 0.65))
	rh.ender = true
	rh.limb_radius = 0.26
	rh.reach_radius = 0.45
	_add(rh)
	var sw := _strike(&"leg_sweep", &"sweep", low, 1.25, 0.3, Vector3(-0.4, 0.0, 0.9))
	sw.sweep = true
	sw.limb_radius = 0.26
	sw.reach_radius = 0.4
	sw.target_bone = &"RightLowerLeg"
	_add(sw)
	var bf := _strike(&"backfist", &"cross", hi, 1.15, 1.4, Vector3(0.45, 0.0, 0.9))
	bf.hits_behind = true
	_add(bf)
	var cp := _strike(&"crouch_punch", &"jab", low, 1.05, 0.75)
	_add(cp)
	var ru := _strike(&"rising_uppercut", &"cross", mid, 1.0, 1.25, Vector3(0.0, 0.75, 0.65))
	_add(ru)
	# Dropping strike (any attack in the air, or late in a vault). Its class is
	# the button's (CombatController sets it per press); this is the kick default.
	var ds := _strike(&"drop_strike", &"kick", mid, 1.3, 0.7, Vector3(0.0, -0.35, 0.95))
	ds.startup = DROP_STARTUP
	ds.active = DROP_ACTIVE_MAX
	ds.recovery = DROP_RECOVERY
	ds.drop = true
	ds.drop_max = DROP_ACTIVE_MAX
	ds.chargeable = false
	ds.limb_radius = 0.3
	ds.reach_radius = 0.5
	_add(ds)
	# Ground strikes (Hitting bodies that are down): stomp on Kick, knee drop on
	# Light / Heavy. A small push into the body, never a launch.
	var gs := _strike(&"ground_stomp", &"ground", low, 1.1, 0.25, Vector3(0.0, -0.9, 0.3))
	gs.ground_strike = true
	gs.ground_hit = true
	gs.limb_radius = 0.3
	gs.reach_radius = 0.5
	gs.target_bone = &"Chest"
	_add(gs)
	var kd := _strike(&"knee_drop", &"ground", low, 1.0, 0.3, Vector3(0.0, -0.9, 0.3))
	kd.ground_strike = true
	kd.ground_hit = true
	kd.limb_radius = 0.3
	kd.reach_radius = 0.5
	kd.target_bone = &"Chest"
	_add(kd)
	# Legacy Upgrade 2 strikes (no button reaches them now).
	for id: StringName in LEGACY_CLASS:
		var cls: StringName = LEGACY_CLASS[id]
		var lm := _strike(id, cls, low if cls == &"ground" else mid, 1.2, 0.35 if cls == &"ground" else 1.2)
		lm.ground_strike = cls == &"ground"
		lm.ground_hit = cls == &"ground"
		_add(lm)

	# The Duelist's teleport counter (CombatController.start_counter): a back
	# kick from behind. On the player it is an enemy hit: a knockdown.
	var bk := MoveData.new()
	bk.id = &"back_kick"
	bk.kind = &"counter"
	bk.startup = 4.0
	bk.active = 4.0
	bk.recovery = 20.0
	bk.damage = Tuning.DMG_ENEMY[&"e_kick"]
	bk.preset_tier = HitInfo.Tier.KNOCKDOWN
	bk.strike_class = &"kick"
	bk.unblockable = true
	bk.limb = &"RightFoot"
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
	es.sweep = true
	es.is_kick = true
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
	# Guarding a light enemy hit leaves a punish window (a kick lands before a
	# guarded hook recovers); heavier hits hold the guard longer.
	m.blockstun = ENEMY_BLOCKSTUN_LIGHT if m.preset_tier <= HitInfo.Tier.FLINCH else 12.0
	return m
