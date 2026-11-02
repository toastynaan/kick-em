class_name MoveLibrary
## Every move in the game (spec: Combat system > Moves; Enemies and AI rule 5).
## Player frame data is the spec table at 60 fps. Enemy moves replace startup
## with the tell time given to CombatController.start_enemy_attack().
## OWNER: agent B (fighter & combat).

const PLAYER_MOVES: Array[StringName] = [&"jab1", &"cross", &"hook", &"uppercut", &"sparta_kick",
	&"roundhouse", &"leg_sweep", &"backfist", &"flying_kick", &"hammer_fist", &"crouch_punch",
	&"rising_uppercut", &"knee", &"headbutt", &"mount_punch", &"stomp", &"punt", &"grab", &"throw",
	&"neck_throw", &"upward_throw", &"wall_slam", &"back_kick", &"jab2", &"jab3", &"power_punch"]
const ENEMY_MOVES: Array[StringName] = [&"e_hook", &"e_heavy", &"e_kick", &"e_grab",
	&"e_charge", &"e_throw_debris", &"e_sweep"]

## Power punch (legacy move id; HEAVY is now a charged punch press).
const POWER_STARTUP_MIN := 14.0
const POWER_STARTUP_MAX := 30.0
## Leg sweep: small launch so the body falls in place (m/s) - the trip.
const SWEEP_LAUNCH := 2.2
## Punt / stomp (kick a downed body): fixed launch and damage.
const PUNT_LAUNCH := 9.0
const PUNT_UP_ANGLE := 15.0
const PUNT_DAMAGE := 35.0
## Legacy (round 2) jab cancel list; Upgrade 2 cancels come from ComboGraph.
const JAB_CANCELS: Array[StringName] = [&"sparta_kick", &"leg_sweep", &"power_punch", &"grab"]
const CANCEL_WINDOW := 10.0
## Upgrade 2 move damage (local tuning starts; spec gives only the existing ones).
const DMG := {&"cross": 18.0, &"hook": 25.0, &"uppercut": 25.0, &"roundhouse": 45.0,
	&"backfist": 22.0, &"flying_kick": 55.0, &"hammer_fist": 30.0, &"crouch_punch": 18.0,
	&"rising_uppercut": 30.0, &"knee": 20.0, &"headbutt": 30.0, &"mount_punch": 20.0,
	&"stomp": 40.0, &"neck_throw": 50.0, &"upward_throw": 35.0, &"wall_slam": 50.0, &"e_sweep": 50.0}
const ROUNDHOUSE_LAUNCH := 9.0
const FLYING_KICK_LAUNCH := 9.0
const E_SWEEP_LAUNCH := 2.5
## Until agent A poses a move, play the closest existing one.
const ANIM_FALLBACK := {
	&"cross": &"jab2", &"hook": &"jab3", &"uppercut": &"power_punch", &"roundhouse": &"sparta_kick",
	&"backfist": &"jab3", &"flying_kick": &"sparta_kick", &"hammer_fist": &"power_punch",
	&"crouch_punch": &"jab1", &"rising_uppercut": &"power_punch", &"knee": &"sparta_kick",
	&"headbutt": &"jab1", &"neck_throw": &"throw", &"mount_punch": &"power_punch",
	&"stomp": &"punt", &"upward_throw": &"throw", &"wall_slam": &"throw", &"e_sweep": &"leg_sweep",
	&"punt": &"sparta_kick",
}
## Striking bones until PoseLibrary.STRIKE_BONES lists the move.
const LIMB_FALLBACK := {
	&"cross": [&"RightHand"], &"hook": [&"LeftHand"], &"uppercut": [&"RightHand"],
	&"roundhouse": [&"RightFoot", &"RightLowerLeg"], &"backfist": [&"RightHand"],
	&"flying_kick": [&"RightFoot", &"RightLowerLeg"], &"hammer_fist": [&"RightHand"],
	&"crouch_punch": [&"LeftHand"], &"rising_uppercut": [&"RightHand"], &"knee": [&"RightLowerLeg"],
	&"headbutt": [&"Head"], &"mount_punch": [&"RightHand"], &"stomp": [&"RightFoot"],
	&"e_sweep": [&"RightFoot", &"RightLowerLeg"],
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

## Power punch launch speed for a charge 0..1 (0 below the stagger threshold).
static func power_launch(charge: float) -> float:
	if charge < Tuning.POWER_STAGGER_BELOW:
		return 0.0
	var t := inverse_lerp(Tuning.POWER_STAGGER_BELOW, 1.0, charge)
	return lerpf(Tuning.POWER_LAUNCH_MID, Tuning.POWER_LAUNCH_FULL, t)

static func power_damage(charge: float) -> float:
	return lerpf(Tuning.DMG_POWER_MIN, Tuning.DMG_POWER_MAX, clampf(charge, 0.0, 1.0))

static func power_startup(charge: float) -> float:
	return lerpf(POWER_STARTUP_MIN, POWER_STARTUP_MAX, clampf(charge, 0.0, 1.0))

static func power_hitstop(charge: float) -> float:
	return lerpf(Tuning.HITSTOP[&"power_min"], Tuning.HITSTOP[&"power_max"], clampf(charge, 0.0, 1.0))

static func _add(m: MoveData) -> void:
	if m.anim == &"":
		m.anim = m.id if pose_has_move(m.id) else ANIM_FALLBACK.get(m.id, m.id)
	# The pose library is the source of truth for which limb strikes.
	var sb: Dictionary = PoseLibrary.STRIKE_BONES
	var src: Array = sb.get(m.id, LIMB_FALLBACK.get(m.id, []))
	if not src.is_empty():
		var bones: Array[StringName] = []
		for b in src:
			bones.append(StringName(b))
		m.limbs = bones
		m.limb = bones[0]
	if m.chargeable and m.charge_hold == &"":
		m.charge_hold = charge_hold_for(m)
	_moves[m.id] = m

## `<id>_charge` when agent A has posed it, else the closest existing hold.
static func charge_hold_for(m: MoveData) -> StringName:
	var own := StringName(String(m.id) + "_charge")
	if PoseLibrary.HOLDS.has(own) or PoseLibrary.POSES.has(own):
		return own
	if m.is_kick and PoseLibrary.POSES.has(&"kick_chamber"):
		return &"kick_chamber"
	return &"power_charge"

static func _strike(id: StringName, startup: float, active: float, recovery: float, damage: float,
		reaction: int, level: int, reach: float, height: float) -> MoveData:
	var m := MoveData.new()
	m.id = id
	m.startup = startup
	m.active = active
	m.recovery = recovery
	m.damage = damage
	m.reaction = reaction
	m.hit_level = level
	m.reach = reach
	m.height = height
	m.chargeable = true
	return m

## PoseLibrary.has_move(id) when agent A provides it, else its MOVES table.
static func pose_has_move(id: StringName) -> bool:
	var lib: Script = PoseLibrary
	for md in lib.get_script_method_list():
		if md.get("name", "") == "has_move":
			return bool(lib.call(&"has_move", id))
	return PoseLibrary.MOVES.has(id)

static func _build() -> void:
	# --- Player --------------------------------------------------------------
	for i in 3:
		var j := MoveData.new()
		j.id = StringName("jab%d" % (i + 1))
		j.startup = 5.0 if i < 2 else 6.0
		j.active = 3.0
		j.recovery = 10.0 if i < 2 else 14.0
		j.damage = Tuning.DMG_JAB
		j.reaction = HitInfo.Reaction.FLINCH
		j.limb = &"RightHand" if i != 1 else &"LeftHand"
		j.reach = 1.05
		j.height = 1.4
		j.hitstop_key = &"jab"
		j.hitstun = 0.3 if i < 2 else 0.4
		j.blockstun = 8.0
		j.lunge_speed = 1.6
		j.nominal_speed = 2.0
		j.hit_level = HitInfo.Level.HIGH
		j.chargeable = true
		j.stagger_l1 = true
		j.shake = 0.04
		_add(j)

	var pp := MoveData.new()
	pp.id = &"power_punch"
	pp.startup = POWER_STARTUP_MIN
	pp.active = 4.0
	pp.recovery = 22.0
	pp.damage = Tuning.DMG_POWER_MIN
	pp.reaction = HitInfo.Reaction.STAGGER
	pp.launch_speed = Tuning.POWER_LAUNCH_MID
	pp.limb = &"RightHand"
	pp.reach = 1.2
	pp.height = 1.35
	pp.hitstop_key = &"power_min"
	pp.blockstun = 14.0
	pp.block_pushback = 3.5
	pp.lunge_speed = 2.0
	pp.lunge_start = 0.5
	pp.nominal_speed = 4.0
	pp.shake = 0.15
	pp.hit_level = HitInfo.Level.HIGH
	_add(pp)

	# --- Upgrade 2 strings (spec: Combos and new moves) -----------------------
	var cr := _strike(&"cross", 6.0, 3.0, 12.0, DMG[&"cross"], HitInfo.Reaction.FLINCH, HitInfo.Level.HIGH, 1.1, 1.4)
	cr.stagger_l1 = true
	cr.lunge_speed = 1.8
	cr.hitstop_key = &"jab"
	cr.blockstun = 9.0
	cr.shake = 0.05
	_add(cr)

	var hk := _strike(&"hook", 8.0, 3.0, 16.0, DMG[&"hook"], HitInfo.Reaction.STAGGER, HitInfo.Level.HIGH, 1.05, 1.45)
	hk.ender = true
	hk.hitstop_key = &"power_min"
	hk.blockstun = 12.0
	hk.block_pushback = 2.0
	hk.nominal_speed = 3.5
	hk.shake = 0.1
	_add(hk)

	var up := _strike(&"uppercut", 9.0, 3.0, 18.0, DMG[&"uppercut"], HitInfo.Reaction.LAUNCH, HitInfo.Level.MID, 1.0, 1.2)
	up.launch_lift = Tuning.LAUNCHER_LIFT
	up.fixed_launch = true
	up.ender = true
	up.target_bone = &"Chest"
	up.force_bone = true
	up.hitstop_key = &"power_min"
	up.blockstun = 12.0
	up.shake = 0.2
	_add(up)

	var rh := _strike(&"roundhouse", 11.0, 4.0, 22.0, DMG[&"roundhouse"], HitInfo.Reaction.LAUNCH, HitInfo.Level.HIGH, 1.45, 1.35)
	rh.launch_speed = ROUNDHOUSE_LAUNCH
	rh.sideways = true
	rh.is_kick = true
	rh.ender = true
	rh.limb_radius = 0.26
	rh.reach_radius = 0.45
	rh.hitstop_key = &"kick"
	rh.blockstun = 14.0
	rh.block_pushback = 4.0
	rh.shake = 0.25
	_add(rh)

	var bf := _strike(&"backfist", 7.0, 3.0, 14.0, DMG[&"backfist"], HitInfo.Reaction.FLINCH, HitInfo.Level.HIGH, 1.15, 1.4)
	bf.hits_behind = true
	bf.ender = true
	bf.hitstop_key = &"jab"
	bf.hitstun = 0.4
	bf.shake = 0.08
	_add(bf)

	var fk := _strike(&"flying_kick", 7.0, 5.0, 14.0, DMG[&"flying_kick"], HitInfo.Reaction.LAUNCH, HitInfo.Level.MID, 1.4, 1.1)
	fk.launch_speed = FLYING_KICK_LAUNCH
	fk.is_kick = true
	fk.ender = true
	fk.limb_radius = 0.26
	fk.reach_radius = 0.45
	fk.target_bone = &"Chest"
	fk.force_bone = true
	fk.hitstop_key = &"kick"
	fk.shake = 0.3
	_add(fk)

	var hf := _strike(&"hammer_fist", 8.0, 4.0, 14.0, DMG[&"hammer_fist"], HitInfo.Reaction.FLINCH, HitInfo.Level.HIGH, 1.1, 0.9)
	hf.ground_hit = true
	hf.ender = true
	hf.reach_radius = 0.5
	hf.hitstop_key = &"power_min"
	hf.shake = 0.15
	_add(hf)

	var cp := _strike(&"crouch_punch", 6.0, 3.0, 12.0, DMG[&"crouch_punch"], HitInfo.Reaction.FLINCH, HitInfo.Level.LOW, 1.05, 0.75)
	cp.stagger_l1 = true
	cp.hitstop_key = &"jab"
	_add(cp)

	var ru := _strike(&"rising_uppercut", 9.0, 4.0, 20.0, DMG[&"rising_uppercut"], HitInfo.Reaction.LAUNCH, HitInfo.Level.MID, 1.0, 1.2)
	ru.launch_lift = Tuning.LAUNCHER_LIFT
	ru.fixed_launch = true
	ru.ender = true
	ru.target_bone = &"Chest"
	ru.force_bone = true
	ru.hitstop_key = &"power_min"
	ru.shake = 0.2
	_add(ru)

	var kn := _strike(&"knee", 6.0, 3.0, 12.0, DMG[&"knee"], HitInfo.Reaction.NONE, HitInfo.Level.MID, 0.9, 1.0)
	kn.on_held = true
	kn.chargeable = false
	kn.hitstop_key = &"jab"
	kn.shake = 0.08
	_add(kn)

	var hb := _strike(&"headbutt", 8.0, 3.0, 16.0, DMG[&"headbutt"], HitInfo.Reaction.NONE, HitInfo.Level.HIGH, 0.8, 1.6)
	hb.on_held = true
	hb.chargeable = false
	hb.hitstop_key = &"power_min"
	hb.shake = 0.12
	_add(hb)

	var mp := _strike(&"mount_punch", 7.0, 3.0, 12.0, DMG[&"mount_punch"], HitInfo.Reaction.FLINCH, HitInfo.Level.LOW, 1.2, 0.35)
	mp.ground_hit = true
	mp.reach_radius = 0.5
	mp.hitstop_key = &"jab"
	mp.shake = 0.08
	_add(mp)

	var sk := MoveData.new()
	sk.id = &"sparta_kick"
	sk.startup = 12.0
	sk.active = 4.0
	sk.recovery = 24.0
	sk.damage = Tuning.DMG_KICK
	sk.reaction = HitInfo.Reaction.LAUNCH
	sk.launch_speed = Tuning.KICK_LAUNCH
	sk.limb = &"RightFoot"
	sk.limb_radius = 0.24
	sk.reach = 1.4
	sk.height = 1.0
	sk.reach_radius = 0.42
	sk.target_bone = &"Chest"
	sk.force_bone = true
	sk.hitstop_key = &"kick"
	sk.is_kick = true
	sk.chargeable = true
	sk.hit_level = HitInfo.Level.MID
	sk.blockstun = 16.0
	sk.block_pushback = 4.5
	sk.lunge_speed = 1.5
	sk.lunge_start = 0.4
	sk.shake = 0.25
	_add(sk)

	var sw := MoveData.new()
	sw.id = &"leg_sweep"
	sw.startup = 10.0
	sw.active = 5.0
	sw.recovery = 20.0
	sw.damage = Tuning.DMG_SWEEP
	sw.reaction = HitInfo.Reaction.LAUNCH
	sw.launch_speed = SWEEP_LAUNCH
	sw.fixed_launch = true
	sw.up_angle = 20.0
	sw.sweep = true
	sw.limb = &"RightFoot"
	sw.limb_radius = 0.26
	sw.reach = 1.25
	sw.reach_radius = 0.4
	sw.height = 0.3
	sw.target_bone = &"RightLowerLeg"
	sw.hitstop_key = &"sweep"
	sw.blockstun = 12.0
	sw.nominal_speed = 3.0
	sw.shake = 0.12
	sw.is_kick = true
	sw.chargeable = true
	sw.hit_level = HitInfo.Level.LOW
	_add(sw)

	var pt := MoveData.new()
	pt.id = &"punt"
	pt.anim = &"punt" if pose_has_move(&"punt") else &"sparta_kick"
	pt.startup = 9.0
	pt.active = 4.0
	pt.recovery = 18.0
	pt.damage = PUNT_DAMAGE
	pt.reaction = HitInfo.Reaction.LAUNCH
	pt.launch_speed = PUNT_LAUNCH
	pt.fixed_launch = true
	pt.up_angle = PUNT_UP_ANGLE
	pt.limb = &"RightFoot"
	pt.limb_radius = 0.28
	pt.reach = 1.6
	pt.reach_radius = 0.42
	pt.height = 0.3
	pt.target_bone = &"Hips"
	pt.force_bone = true
	pt.hitstop_key = &"kick"
	pt.blockstun = 12.0
	pt.lunge_speed = 1.5
	pt.lunge_start = 0.3
	pt.shake = 0.25
	pt.is_kick = true
	pt.ground_hit = true
	pt.hit_level = HitInfo.Level.LOW
	_add(pt)

	var st := MoveData.new()
	st.id = &"stomp"
	st.startup = 9.0
	st.active = 4.0
	st.recovery = 18.0
	st.damage = DMG[&"stomp"]
	st.reaction = HitInfo.Reaction.LAUNCH
	st.launch_speed = PUNT_LAUNCH
	st.fixed_launch = true
	st.up_angle = PUNT_UP_ANGLE
	st.limb_radius = 0.3
	st.reach = 1.0
	st.reach_radius = 0.5
	st.height = 0.25
	st.target_bone = &"Hips"
	st.force_bone = true
	st.hitstop_key = &"kick"
	st.shake = 0.25
	st.is_kick = true
	st.ground_hit = true
	st.hit_level = HitInfo.Level.LOW
	_add(st)

	var gr := MoveData.new()
	gr.id = &"grab"
	gr.kind = &"grab"
	gr.startup = 8.0
	gr.active = 3.0
	gr.recovery = 6.0
	gr.whiff_recovery = 30.0
	gr.unblockable = true
	gr.reaction = HitInfo.Reaction.NONE
	gr.reach = Tuning.GRAB_RANGE
	gr.limb = &"RightHand"
	gr.hitstop_key = &"throw"
	gr.hit_level = HitInfo.Level.HIGH
	_add(gr)

	var th := MoveData.new()
	th.id = &"throw"
	th.kind = &"throw"
	th.startup = 0.0
	th.active = 3.0
	th.recovery = 16.0
	th.damage = Tuning.DMG_THROW
	th.reaction = HitInfo.Reaction.LAUNCH
	th.launch_speed = Tuning.THROW_SPEED
	th.fixed_launch = true
	th.up_angle = Tuning.THROW_UP_ANGLE
	th.is_finisher = true
	th.unblockable = true
	th.hitstop_key = &"throw"
	th.shake = 0.3
	_add(th)

	for tid: StringName in [&"neck_throw", &"upward_throw", &"wall_slam"]:
		var t2 := MoveData.new()
		t2.id = tid
		t2.kind = &"throw"
		t2.startup = 0.0
		t2.active = 3.0
		t2.recovery = 16.0
		t2.damage = DMG[tid]
		t2.reaction = HitInfo.Reaction.LAUNCH
		t2.launch_speed = Tuning.WALL_SLAM_SPEED if tid == &"wall_slam" else Tuning.THROW_SPEED
		t2.fixed_launch = true
		t2.up_angle = 25.0 if tid == &"neck_throw" else (4.0 if tid == &"wall_slam" else Tuning.THROW_UP_ANGLE)
		t2.is_finisher = true
		t2.unblockable = true
		t2.hitstop_key = &"throw"
		t2.target_bone = &"Head" if tid == &"wall_slam" else &"Chest"
		t2.shake = 0.35
		_add(t2)

	var bk := MoveData.new()
	bk.id = &"back_kick"
	bk.kind = &"counter"
	bk.startup = 4.0
	bk.active = 4.0
	bk.recovery = 20.0
	bk.damage = Tuning.DMG_COUNTER
	bk.reaction = HitInfo.Reaction.LAUNCH
	bk.launch_speed = Tuning.COUNTER_LAUNCH
	bk.fixed_launch = true
	bk.is_finisher = true
	bk.unblockable = true
	bk.limb = &"RightFoot"
	bk.limb_radius = 0.26
	bk.reach = 1.5
	bk.reach_radius = 0.45
	bk.height = 1.1
	bk.hitstop_key = &"counter"
	bk.hit_level = HitInfo.Level.MID
	bk.force_bone = true
	bk.shake = 0.45
	_add(bk)

	# --- Enemy (startup = tell time, set per attack) -------------------------
	var hook := _enemy(&"e_hook", 4.0, 18.0, HitInfo.Reaction.FLINCH, 0.0)
	hook.limb = &"RightHand"
	hook.reach = 1.25
	hook.height = 1.4
	hook.hitstun = 0.35
	hook.lunge_speed = 2.0
	hook.lunge_start = 0.7
	hook.nominal_speed = 2.5
	hook.blockstun = 6.0
	hook.armor = 0
	hook.hit_level = HitInfo.Level.HIGH
	_add(hook)

	var heavy := _enemy(&"e_heavy", 5.0, 26.0, HitInfo.Reaction.LAUNCH, Tuning.ENEMY_LAUNCH[&"e_heavy"])
	heavy.limb = &"RightHand"
	heavy.reach = 1.35
	heavy.height = 1.35
	heavy.block_pushback = 4.0
	heavy.blockstun = 10.0
	heavy.armor = 1
	heavy.lunge_speed = 2.5
	heavy.lunge_start = 0.75
	heavy.shake = 0.3
	heavy.hit_level = HitInfo.Level.MID
	_add(heavy)

	var kick := _enemy(&"e_kick", 5.0, 24.0, HitInfo.Reaction.LAUNCH, Tuning.ENEMY_LAUNCH[&"e_kick"])
	kick.limb = &"RightFoot"
	kick.limb_radius = 0.24
	kick.reach = 1.45
	kick.height = 1.0
	kick.block_pushback = 4.5
	kick.blockstun = 10.0
	kick.armor = 1
	kick.force_bone = true
	kick.lunge_speed = 1.5
	kick.lunge_start = 0.75
	kick.shake = 0.3
	kick.is_kick = true
	kick.hit_level = HitInfo.Level.MID
	_add(kick)

	var eg := _enemy(&"e_grab", 3.0, 6.0, HitInfo.Reaction.NONE, 0.0)
	eg.kind = &"grab"
	eg.tell_kind = &"grab"
	eg.whiff_recovery = 30.0
	eg.unblockable = true
	eg.reach = Tuning.GRAB_RANGE
	eg.hitstop_key = &"throw"
	eg.hit_level = HitInfo.Level.HIGH
	_add(eg)

	var charge := _enemy(&"e_charge", 14.0, 30.0, HitInfo.Reaction.LAUNCH, Tuning.ENEMY_LAUNCH[&"e_charge"])
	charge.fixed_launch = true
	charge.limb = &"RightUpperArm"
	charge.limb_radius = 0.35
	charge.reach = 1.3
	charge.reach_radius = 0.5
	charge.height = 1.2
	charge.lunge_speed = 7.5
	charge.lunge_start = 0.45
	charge.block_pushback = 6.0
	charge.blockstun = 18.0
	charge.armor = 1
	charge.force_bone = true
	charge.shake = 0.4
	charge.hit_level = HitInfo.Level.MID
	_add(charge)

	var deb := _enemy(&"e_throw_debris", 2.0, 20.0, HitInfo.Reaction.STAGGER, 0.0)
	deb.kind = &"projectile"
	deb.nominal_speed = 4.0
	deb.blockstun = 12.0
	deb.block_pushback = 3.0
	deb.hit_level = HitInfo.Level.MID
	_add(deb)

	var es := _enemy(&"e_sweep", 5.0, 24.0, HitInfo.Reaction.LAUNCH, E_SWEEP_LAUNCH)
	es.damage = Tuning.DMG_ENEMY.get(&"e_sweep", DMG[&"e_sweep"])
	es.fixed_launch = true
	es.up_angle = 20.0
	es.sweep = true
	es.is_kick = true
	es.limb_radius = 0.28
	es.reach = 1.35
	es.reach_radius = 0.42
	es.height = 0.3
	es.target_bone = &"RightLowerLeg"
	es.blockstun = 10.0
	es.hit_level = HitInfo.Level.LOW
	es.shake = 0.15
	_add(es)

static func _enemy(id: StringName, active: float, recovery: float, reaction: int, launch: float) -> MoveData:
	var m := MoveData.new()
	m.id = id
	m.enemy = true
	m.startup = 27.0  # default tell when none is given (0.45 s)
	m.active = active
	m.recovery = recovery
	m.damage = Tuning.DMG_ENEMY.get(id, 50.0)
	m.reaction = reaction
	m.launch_speed = launch
	m.hitstop_key = &"enemy"
	m.blockstun = 12.0
	m.nominal_speed = 3.0
	m.shake = 0.12
	return m
