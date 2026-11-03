class_name PoseLibrary
extends RefCounted
## Procedural keyframe poses and moves for the HumanoidRig (no clips yet).
## OWNER: agent P (poses & animation; agent A before Round 5).
##
## Pose format (Dictionary), all at height scale 1.0:
##   "pos": hips offset from rest (m, character space: -Z forward, +X right).
##   "hips" / "spine" / "chest" / "head" / "lua" (LeftUpperArm) / "lla" / "lh" /
##   "rua" / "rla" / "rh" / "lul" (LeftUpperLeg) / "lll" / "lf" / "rul" / "rll" / "rf":
##       local rotation, Euler degrees (Godot YXZ order). +X swings a hanging
##       limb forward and leans the spine back; +Z swings a limb toward +X;
##       +Y turns the torso to the character's left.
##   IK targets in character space (where the opponent is): "lfist"/"rfist" =
##   fist centre, "lankle"/"rankle" = ankle. Poles (where the elbow/knee
##   points): "lelbow", "relbow", "lknee", "rknee". "lfp"/"rfp" = foot pitch
##   in degrees when the leg is solved by IK (0 = flat, + toes up).
##   "frame": &"body" puts targets and poles in the body frame instead
##   (character space turned by the pose's hips yaw), for spinning moves.
## Bones a pose does not mention come from the layer below (locomotion), so a
## punch keeps the legs walking.
##
## Move format: {"keys": [[segment, time, pose, ease], ...], "tell": bool}
##   segment 0 = startup, 1 = active, 2 = recovery. time: float fraction of
##   the segment, or Vector2(f, cap): f >= 0 -> start + min(f*dur, cap);
##   f < 0 -> end - min(-f*dur, cap). ease: &"snap" (fast arrival), &"smooth",
##   &"linear". Optional 5th element: weight 0..1 (the key is that fraction of
##   the way from the layer below to the pose; enemy tells start at 0.6 and
##   build to 1.0). The move starts from the current pose unless its first key
##   is at time 0, and always ends back on the layer below. A pose name ending
##   in "#m" is the left/right mirror of that pose.
##   Round 5 move keys: "legs": &"free" (an upper-body move: while the fighter
##   moves the legs keep running), "timed": Vector3 startup/active/recovery
##   split for PoseAnimator.play_timed (default TIMED_SPLIT), "steps": n quick
##   stumble steps from the locomotion layer ("step_dir" when standing still),
##   "keep_hold" (the hold layer stays under it), "mirror_by_motion".
## The first key of segment 1 is the contact pose: it lands exactly on the
## first active frame (t = startup) for any startup.
##
## Round 7 (docs/Round 7 — Freeflow Combat.md "Poses"): ROUND7_STRIKE_IDS take
## Tuning.R7_MOVES frame data in play_move(); dodge, glide, throw_release and
## the reactions react_snap / react_spin / react_push / react_fold /
## react_buckle / react_lift are play_timed() moves (the first reaction pose
## lands within 0.07 s for any stun). ROUND7_HOLD_IDS are hold_pose() ids
## (react_fold / react_buckle / react_lift are both). Hold keys: "blend_max",
## "ramp", "by_vy", "flail" (see HOLDS). AIM_YAW_ONLY strikes keep their height.
##
## Joint limits (Round 5): compile() fits every pose inside the ragdoll's soft
## ranges (HumanoidRig.JOINT_LIMITS minus LIMIT_MARGIN): elbows / knees swivel
## to a legal plane, hinges keep their axis and range, a chest turn past its
## range moves into the spine, and the ankle lifts the heel when it runs out
## of dorsiflexion. PoseAnimator blends limbs in joint space (jslerp), so the
## ragdoll's muscles never pull against an animated pose.
##
## Enemy tells (startup = tell time): 60% of the windup almost at once, the
## windup deepens over the whole tell, a ~2 frame "set" freeze, then a ~4
## frame snap to the strike. The parry window (last 8 frames) starts just
## before the set.

const IK_ARM_UPPER := 0.29
const IK_ARM_LOWER := 0.33   ## elbow -> fist centre (forearm 0.26 + fist 0.07)
const IK_LEG_UPPER := 0.42
const IK_LEG_LOWER := 0.40

## Which bones carry each strike (hitboxes; agent B).
const STRIKE_BONES := {
	&"jab1": [&"LeftHand"], &"jab2": [&"RightHand"], &"jab3": [&"LeftHand"],
	&"power_punch": [&"RightHand"], &"sparta_kick": [&"RightFoot", &"RightLowerLeg"],
	&"leg_sweep": [&"RightFoot", &"RightLowerLeg"], &"grab": [&"LeftHand", &"RightHand"],
	&"punt": [&"RightFoot", &"RightLowerLeg"],
	# Upgrade 2
	&"cross": [&"RightHand"], &"hook": [&"LeftHand"], &"uppercut": [&"RightHand"],
	&"roundhouse": [&"RightFoot", &"RightLowerLeg"], &"backfist": [&"RightHand"],
	&"flying_kick": [&"RightFoot", &"RightLowerLeg"], &"hammer_fist": [&"RightHand", &"LeftHand"],
	&"crouch_punch": [&"RightHand"], &"rising_uppercut": [&"RightHand"],
	&"knee": [&"RightLowerLeg", &"RightUpperLeg"], &"headbutt": [&"Head"],
	&"neck_throw": [&"RightHand", &"LeftHand"], &"mount_punch": [&"RightHand"], &"stomp": [&"RightFoot"],
	&"upward_throw": [&"LeftHand", &"RightHand"], &"wall_slam": [&"LeftHand", &"RightHand"],
	&"e_sweep": [&"RightFoot", &"RightLowerLeg"],
	&"throw": [&"LeftHand", &"RightHand"], &"back_kick": [&"RightFoot", &"RightLowerLeg"],
	&"grab_break_push": [&"LeftHand", &"RightHand"],
	&"e_hook": [&"RightHand"], &"e_heavy": [&"LeftHand", &"RightHand"],
	&"e_kick": [&"RightFoot", &"RightLowerLeg"], &"e_grab": [&"LeftHand", &"RightHand"],
	&"e_charge": [&"Chest", &"LeftUpperArm"], &"e_throw_debris": [&"RightHand"],
	# Round 5
	&"jab": [&"LeftHand"], &"kick": [&"RightFoot", &"RightLowerLeg"], &"sweep": [&"RightFoot", &"RightLowerLeg"],
	&"elbow": [&"RightLowerArm"], &"ground_stomp": [&"RightFoot"], &"knee_drop": [&"RightLowerLeg"],
	&"drop_strike": [&"RightHand"], &"slam": [&"RightHand", &"LeftHand"],
	&"grab_lunge": [&"LeftHand", &"RightHand"], &"held_knee": [&"RightLowerLeg", &"RightUpperLeg"],
	&"body_slam": [&"LeftHand", &"RightHand"],
	&"e_jab": [&"LeftHand"], &"e_stick_swing": [&"RightHand"], &"e_stick_thrust": [&"RightHand"],
	&"e_grab_slam": [&"LeftHand", &"RightHand"],
	# Round 7 (jab, cross, hook, uppercut and roundhouse are listed above).
	&"heavy_jab": [&"LeftHand"], &"heavy_cross": [&"RightHand"], &"heavy_hook": [&"LeftHand"],
	&"gut_punch": [&"RightHand"], &"counter": [&"RightHand"],
	&"leg_kick": [&"RightFoot", &"RightLowerLeg"], &"front_kick": [&"RightFoot", &"RightLowerLeg"],
	&"heavy_leg_kick": [&"RightFoot", &"RightLowerLeg"], &"heavy_front_kick": [&"RightFoot", &"RightLowerLeg"],
	&"heavy_roundhouse": [&"RightFoot", &"RightLowerLeg"],
}

const ALIAS := {
	"hips": &"Hips", "spine": &"Spine", "chest": &"Chest", "head": &"Head",
	"lua": &"LeftUpperArm", "lla": &"LeftLowerArm", "lh": &"LeftHand",
	"rua": &"RightUpperArm", "rla": &"RightLowerArm", "rh": &"RightHand",
	"lul": &"LeftUpperLeg", "lll": &"LeftLowerLeg", "lf": &"LeftFoot",
	"rul": &"RightUpperLeg", "rll": &"RightLowerLeg", "rf": &"RightFoot",
}

# --- Poses ---------------------------------------------------------------------
const POSES := {
	# Fighting stance (orthodox: left foot and left fist lead). Locomotion uses
	# its upper body; its feet are the idle foot targets.
	&"stance": {"pos": Vector3(0, -0.06, 0), "hips": Vector3(0, -15, 0), "spine": Vector3(-4, 0, 0),
		"chest": Vector3(-4, -6, 0), "head": Vector3(6, 20, 0),
		"lfist": Vector3(-0.07, 1.45, -0.34), "lelbow": Vector3(-0.5, -1, 0.3),
		"rfist": Vector3(0.12, 1.41, -0.22), "relbow": Vector3(0.5, -1, 0.4),
		"lankle": Vector3(-0.12, 0.08, -0.17), "lknee": Vector3(-0.15, 0, -1),
		"rankle": Vector3(0.14, 0.08, 0.16), "rknee": Vector3(0.15, 0, -1)},
	&"guard": {"spine": Vector3(-8, 0, 0), "chest": Vector3(-6, -6, 0), "head": Vector3(-4, 18, 0), "pos": Vector3(0, -0.09, 0),
		"lfist": Vector3(-0.08, 1.53, -0.29), "lelbow": Vector3(-0.3, -1, 0.0),
		"rfist": Vector3(0.09, 1.51, -0.25), "relbow": Vector3(0.3, -1, 0.0)},
	&"block": {"spine": Vector3(-12, 0, 0), "chest": Vector3(-6, 0, 0), "head": Vector3(-12, 0, 0), "pos": Vector3(0, -0.10, 0),
		"lfist": Vector3(-0.08, 1.66, -0.22), "lelbow": Vector3(-0.2, -1, -0.4),
		"rfist": Vector3(0.08, 1.66, -0.22), "relbow": Vector3(0.2, -1, -0.4)},
	&"block_recoil": {"spine": Vector3(4, 0, 0), "chest": Vector3(2, 0, 0), "head": Vector3(-18, 0, 0), "pos": Vector3(0, -0.12, 0.06),
		"lfist": Vector3(-0.07, 1.62, -0.14), "lelbow": Vector3(-0.2, -1, -0.4),
		"rfist": Vector3(0.07, 1.62, -0.14), "relbow": Vector3(0.2, -1, -0.4)},
	# Jabs
	&"jab_l_cock": {"hips": Vector3(0, -10, 0), "chest": Vector3(-6, -2, 0), "spine": Vector3(-6, 0, 0), "head": Vector3(6, 12, 0),
		"lfist": Vector3(-0.10, 1.43, -0.28), "lelbow": Vector3(-0.6, -1, 0.2),
		"rfist": Vector3(0.11, 1.44, -0.22), "relbow": Vector3(0.5, -1, 0.4)},
	&"jab_l_hit": {"pos": Vector3(0, -0.07, -0.05), "hips": Vector3(0, -22, 0), "spine": Vector3(-8, 0, 0),
		"chest": Vector3(-4, -24, 0), "head": Vector3(8, 40, 0),
		"lfist": Vector3(-0.04, 1.46, -0.66), "lelbow": Vector3(-0.8, -0.6, 0.2),
		"rfist": Vector3(0.12, 1.45, -0.20), "relbow": Vector3(0.5, -1, 0.4)},
	&"jab_r_cock": {"hips": Vector3(0, -22, 0), "chest": Vector3(-6, -14, 0), "spine": Vector3(-6, 0, 0), "head": Vector3(6, 30, 0),
		"lfist": Vector3(-0.08, 1.46, -0.36), "lelbow": Vector3(-0.5, -1, 0.3),
		"rfist": Vector3(0.14, 1.40, -0.12), "relbow": Vector3(0.6, -1, 0.4)},
	&"jab_r_hit": {"pos": Vector3(0, -0.07, -0.06), "hips": Vector3(0, 14, 0), "spine": Vector3(-8, 0, 0),
		"chest": Vector3(-4, 28, 0), "head": Vector3(8, -38, 0),
		"lfist": Vector3(-0.13, 1.45, -0.18), "lelbow": Vector3(-0.5, -1, 0.4),
		"rfist": Vector3(0.03, 1.46, -0.67), "relbow": Vector3(0.8, -0.6, 0.2), "rfp": -15.0,
		"lankle": Vector3(-0.12, 0.08, -0.22), "rankle": Vector3(0.14, 0.10, 0.12)},
	&"hook_l_cock": {"pos": Vector3(0, -0.08, 0), "hips": Vector3(0, 0, 0), "chest": Vector3(-4, 18, 0), "spine": Vector3(-6, 0, 0), "head": Vector3(6, -15, 0),
		"lfist": Vector3(-0.34, 1.40, -0.18), "lelbow": Vector3(-1, 0.2, 0.3),
		"rfist": Vector3(0.10, 1.47, -0.22), "relbow": Vector3(0.5, -1, 0.4)},
	&"hook_l_hit": {"pos": Vector3(0, -0.09, -0.04), "hips": Vector3(0, -25, 0), "chest": Vector3(-4, -32, 0), "spine": Vector3(-6, 0, 0), "head": Vector3(6, 50, 0),
		"lfist": Vector3(0.04, 1.48, -0.58), "lelbow": Vector3(-1, 0.25, 0.2),
		"rfist": Vector3(0.12, 1.47, -0.18), "relbow": Vector3(0.5, -1, 0.4)},
	# Power punch (right cross) from the cocked charge hold.
	&"power_charge": {"pos": Vector3(0, -0.13, 0.04), "hips": Vector3(0, -30, 0), "spine": Vector3(-4, 0, 0),
		"chest": Vector3(-2, -28, 0), "head": Vector3(4, 55, 0),
		"lfist": Vector3(-0.06, 1.44, -0.42), "lelbow": Vector3(-0.5, -1, 0.0),
		"rfist": Vector3(0.24, 1.36, 0.16), "relbow": Vector3(0.6, -0.6, 1)},
	&"power_hit": {"pos": Vector3(0, -0.12, -0.12), "hips": Vector3(0, 22, 0), "spine": Vector3(-12, 0, 0),
		"chest": Vector3(-6, 34, 0), "head": Vector3(10, -50, 0),
		"lfist": Vector3(-0.14, 1.40, -0.10), "lelbow": Vector3(-0.5, -1, 0.4),
		"rfist": Vector3(0.02, 1.40, -0.95), "relbow": Vector3(0.8, -0.5, 0.2),
		"lankle": Vector3(-0.13, 0.08, -0.34), "rankle": Vector3(0.15, 0.12, 0.30), "rfp": -30.0},
	&"power_follow": {"pos": Vector3(0, -0.14, -0.17), "hips": Vector3(0, 30, 0), "spine": Vector3(-16, 0, 0),
		"chest": Vector3(-8, 44, 0), "head": Vector3(12, -62, 0),
		"lfist": Vector3(-0.16, 1.36, -0.06), "lelbow": Vector3(-0.5, -1, 0.4),
		"rfist": Vector3(-0.14, 1.34, -0.98), "relbow": Vector3(0.9, -0.3, 0.2),
		"lankle": Vector3(-0.13, 0.08, -0.34), "rankle": Vector3(0.15, 0.14, 0.26), "rfp": -40.0},
	# Sparta kick: right front push kick, the wall breaker.
	&"kick_chamber": {"pos": Vector3(0, -0.02, 0.08), "hips": Vector3(8, 0, 0), "spine": Vector3(6, 0, 0), "chest": Vector3(4, 0, 0), "head": Vector3(-14, 0, 0),
		"lfist": Vector3(-0.15, 1.45, -0.26), "lelbow": Vector3(-0.5, -1, 0.3),
		"rfist": Vector3(0.16, 1.40, -0.18), "relbow": Vector3(0.5, -1, 0.3),
		"lankle": Vector3(-0.10, 0.08, 0.04), "lknee": Vector3(0, 0, -1),
		"rankle": Vector3(0.12, 0.62, -0.18), "rknee": Vector3(0, 0.6, -1), "rfp": 30.0},
	&"kick_hit": {"pos": Vector3(0, -0.04, -0.08), "hips": Vector3(16, 4, 0), "spine": Vector3(14, 0, 0), "chest": Vector3(6, -6, 0), "head": Vector3(-30, 2, 0),
		"lfist": Vector3(-0.38, 1.22, 0.18), "lelbow": Vector3(-0.5, -0.3, 1),
		"rfist": Vector3(0.38, 1.18, 0.22), "relbow": Vector3(0.5, -0.3, 1),
		"lankle": Vector3(-0.10, 0.08, 0.14), "lknee": Vector3(0, 0, -1),
		"rankle": Vector3(0.10, 0.96, -0.95), "rknee": Vector3(0, 1, 0), "rfp": 85.0},
	&"kick_follow": {"pos": Vector3(0, -0.05, -0.15), "hips": Vector3(20, 6, 0), "spine": Vector3(16, 0, 0), "chest": Vector3(8, -10, 0), "head": Vector3(-34, 4, 0),
		"lfist": Vector3(-0.42, 1.18, 0.26), "lelbow": Vector3(-0.5, -0.3, 1),
		"rfist": Vector3(0.40, 1.12, 0.30), "relbow": Vector3(0.5, -0.3, 1),
		"lankle": Vector3(-0.10, 0.08, 0.10), "lknee": Vector3(0, 0, -1), "lfp": -12.0,
		"rankle": Vector3(0.10, 1.02, -1.05), "rknee": Vector3(0, 1, 0), "rfp": 80.0},
	&"kick_recoil": {"pos": Vector3(0, -0.04, 0.04), "hips": Vector3(6, 0, 0), "spine": Vector3(4, 0, 0), "head": Vector3(-8, 0, 0),
		"lfist": Vector3(-0.15, 1.42, -0.26), "lelbow": Vector3(-0.5, -1, 0.3),
		"rfist": Vector3(0.16, 1.38, -0.18), "relbow": Vector3(0.5, -1, 0.3),
		"lankle": Vector3(-0.10, 0.08, 0.04), "rankle": Vector3(0.12, 0.45, -0.20), "rknee": Vector3(0, 0.5, -1)},
	# Leg sweep: low crouching spin, right leg out along the floor.
	&"sweep_crouch": {"frame": &"body", "pos": Vector3(0, -0.52, 0), "hips": Vector3(-10, -45, 0), "spine": Vector3(-28, 0, 0), "chest": Vector3(-10, 0, 0), "head": Vector3(25, 20, 0),
		"lfist": Vector3(-0.32, 0.10, -0.30), "lelbow": Vector3(-1, 0, 0.3),
		"rfist": Vector3(0.20, 0.75, -0.30), "relbow": Vector3(0.5, -1, 0.3),
		"lankle": Vector3(-0.20, 0.08, -0.02), "lknee": Vector3(-0.4, 0.2, -1),
		"rankle": Vector3(0.82, 0.07, 0.12), "rknee": Vector3(0, 1, 0), "rfp": 0.0},
	&"sweep_a": {"frame": &"body", "pos": Vector3(0, -0.55, 0), "hips": Vector3(-10, 25, 0), "spine": Vector3(-30, 0, 0), "chest": Vector3(-10, 0, 0), "head": Vector3(25, -20, 0),
		"lfist": Vector3(-0.30, 0.10, -0.28), "lelbow": Vector3(-1, 0, 0.3),
		"rfist": Vector3(0.20, 0.70, -0.30), "relbow": Vector3(0.5, -1, 0.3),
		"lankle": Vector3(-0.20, 0.08, -0.02), "lknee": Vector3(-0.4, 0.2, -1),
		"rankle": Vector3(0.84, 0.07, 0.05), "rknee": Vector3(0, 1, 0), "rfp": 0.0},
	&"sweep_b": {"frame": &"body", "pos": Vector3(0, -0.55, 0), "hips": Vector3(-10, 125, 0), "spine": Vector3(-30, 0, 0), "chest": Vector3(-10, 0, 0), "head": Vector3(25, -40, 0),
		"lfist": Vector3(-0.30, 0.10, -0.28), "lelbow": Vector3(-1, 0, 0.3),
		"rfist": Vector3(0.20, 0.70, -0.30), "relbow": Vector3(0.5, -1, 0.3),
		"lankle": Vector3(-0.20, 0.08, -0.02), "lknee": Vector3(-0.4, 0.2, -1),
		"rankle": Vector3(0.84, 0.07, 0.05), "rknee": Vector3(0, 1, 0), "rfp": 0.0},
	&"sweep_end": {"frame": &"body", "pos": Vector3(0, -0.48, 0), "hips": Vector3(-8, 225, 0), "spine": Vector3(-25, 0, 0), "chest": Vector3(-8, 0, 0), "head": Vector3(20, -20, 0),
		"lfist": Vector3(-0.30, 0.25, -0.30), "lelbow": Vector3(-1, 0, 0.3),
		"rfist": Vector3(0.20, 0.80, -0.30), "relbow": Vector3(0.5, -1, 0.3),
		"lankle": Vector3(-0.20, 0.08, -0.02), "lknee": Vector3(-0.4, 0.2, -1),
		"rankle": Vector3(0.50, 0.08, 0.10), "rknee": Vector3(0.3, 0.6, -1)},
	&"sweep_rise": {"frame": &"body", "pos": Vector3(0, -0.22, 0), "hips": Vector3(-4, 330, 0), "spine": Vector3(-12, 0, 0), "chest": Vector3(-6, 0, 0), "head": Vector3(10, 0, 0),
		"lfist": Vector3(-0.10, 1.30, -0.32), "lelbow": Vector3(-0.5, -1, 0.3),
		"rfist": Vector3(0.12, 1.25, -0.22), "relbow": Vector3(0.5, -1, 0.4),
		"lankle": Vector3(-0.14, 0.08, -0.08), "rankle": Vector3(0.16, 0.08, 0.10)},
	# Punt: low soccer kick at a body on the floor. Left foot plants beside the
	# target, right leg swings through ~0.25 m above the floor.
	&"punt_cock": {"pos": Vector3(0, -0.10, -0.06), "hips": Vector3(6, -8, 0), "spine": Vector3(-8, 0, 0), "chest": Vector3(-4, 10, 0), "head": Vector3(22, 0, 0),
		"lfist": Vector3(-0.42, 1.20, -0.20), "lelbow": Vector3(-1, -0.4, 0.2),
		"rfist": Vector3(0.38, 1.12, 0.12), "relbow": Vector3(1, -0.4, 0.2),
		"lankle": Vector3(-0.14, 0.08, -0.30), "lknee": Vector3(-0.1, 0, -1),
		"rankle": Vector3(0.14, 0.42, 0.34), "rknee": Vector3(0, 0, -1), "rfp": -50.0},
	&"punt_hit": {"pos": Vector3(0, -0.12, -0.16), "hips": Vector3(12, 8, 0), "spine": Vector3(-12, 0, 0), "chest": Vector3(-4, -10, 0), "head": Vector3(26, 0, 0),
		"lfist": Vector3(-0.40, 1.24, 0.02), "lelbow": Vector3(-1, -0.4, 0.4),
		"rfist": Vector3(0.40, 1.16, -0.25), "relbow": Vector3(1, -0.4, 0.2),
		"lankle": Vector3(-0.14, 0.08, -0.30), "lknee": Vector3(-0.1, 0, -1),
		"rankle": Vector3(0.08, 0.25, -0.82), "rknee": Vector3(0, 0.4, -1), "rfp": -30.0},
	&"punt_follow": {"pos": Vector3(0, -0.10, -0.20), "hips": Vector3(16, 10, 0), "spine": Vector3(-6, 0, 0), "chest": Vector3(-2, -14, 0), "head": Vector3(20, 0, 0),
		"lfist": Vector3(-0.42, 1.28, 0.08), "lelbow": Vector3(-1, -0.4, 0.4),
		"rfist": Vector3(0.40, 1.20, -0.30), "relbow": Vector3(1, -0.4, 0.2),
		"lankle": Vector3(-0.14, 0.08, -0.30), "lknee": Vector3(-0.1, 0, -1), "lfp": -15.0,
		"rankle": Vector3(0.06, 0.62, -0.74), "rknee": Vector3(0, 1, -0.3), "rfp": -10.0},
	# Grab / throw
	&"grab_reach": {"pos": Vector3(0, -0.10, -0.08), "spine": Vector3(-14, 0, 0), "chest": Vector3(-6, 0, 0), "head": Vector3(14, 0, 0),
		"lfist": Vector3(-0.16, 1.28, -0.70), "lelbow": Vector3(-0.6, -1, 0.3),
		"rfist": Vector3(0.16, 1.28, -0.70), "relbow": Vector3(0.6, -1, 0.3)},
	&"grab_open": {"pos": Vector3(0, -0.08, 0), "spine": Vector3(-6, 0, 0), "head": Vector3(6, 0, 0),
		"lfist": Vector3(-0.42, 1.36, -0.36), "lelbow": Vector3(-0.6, -1, 0.5),
		"rfist": Vector3(0.42, 1.36, -0.36), "relbow": Vector3(0.6, -1, 0.5)},
	&"grab_hold": {"pos": Vector3(0, -0.10, 0), "spine": Vector3(-8, 0, 0), "chest": Vector3(-4, 0, 0), "head": Vector3(8, 0, 0),
		"lfist": Vector3(-0.06, 1.22, -0.42), "lelbow": Vector3(-1, -0.4, 0.2),
		"rfist": Vector3(0.06, 1.22, -0.42), "relbow": Vector3(1, -0.4, 0.2)},
	&"throw_turn": {"pos": Vector3(0, -0.15, 0.06), "hips": Vector3(0, -30, 0), "spine": Vector3(-6, -12, 0), "chest": Vector3(-4, -20, 0), "head": Vector3(6, 55, 0),
		"lfist": Vector3(0.10, 1.26, -0.12), "lelbow": Vector3(-0.8, -1, 0.2),
		"rfist": Vector3(0.36, 1.22, 0.14), "relbow": Vector3(1, -0.6, 0.3),
		"lankle": Vector3(-0.15, 0.08, -0.18), "rankle": Vector3(0.18, 0.08, 0.22)},
	&"throw_fling": {"pos": Vector3(0, -0.12, -0.12), "hips": Vector3(0, 24, 0), "spine": Vector3(-12, 8, 0), "chest": Vector3(-6, 12, 0), "head": Vector3(10, -44, 0),
		"lfist": Vector3(-0.26, 1.40, -0.58), "lelbow": Vector3(-0.8, -0.6, 0.2),
		"rfist": Vector3(0.10, 1.46, -0.64), "relbow": Vector3(0.8, -0.6, 0.2),
		"lankle": Vector3(-0.15, 0.08, -0.32), "rankle": Vector3(0.17, 0.12, 0.18), "rfp": -30.0},
	&"push_load": {"pos": Vector3(0, -0.10, 0.04), "spine": Vector3(4, 0, 0), "chest": Vector3(2, 0, 0), "head": Vector3(-4, 0, 0),
		"lfist": Vector3(-0.14, 1.32, -0.18), "lelbow": Vector3(-0.7, -1, 0.3),
		"rfist": Vector3(0.14, 1.32, -0.18), "relbow": Vector3(0.7, -1, 0.3)},
	&"push_hit": {"pos": Vector3(0, -0.10, -0.12), "spine": Vector3(-16, 0, 0), "chest": Vector3(-6, 0, 0), "head": Vector3(14, 0, 0),
		"lfist": Vector3(-0.16, 1.36, -0.82), "lelbow": Vector3(-0.7, -1, 0.3),
		"rfist": Vector3(0.16, 1.36, -0.82), "relbow": Vector3(0.7, -1, 0.3),
		"lankle": Vector3(-0.12, 0.08, -0.30), "rankle": Vector3(0.14, 0.10, 0.25), "rfp": -20.0},
	# Spinning back kick (teleport counter): turn away, heel drives back toward
	# the original facing, keep spinning to face forward again.
	&"bk_turn": {"frame": &"body", "pos": Vector3(0, -0.10, 0), "hips": Vector3(0, -140, 0), "spine": Vector3(-8, 0, 0), "head": Vector3(0, -60, 0),
		"lfist": Vector3(-0.12, 1.42, -0.25), "lelbow": Vector3(-0.5, -1, 0.3),
		"rfist": Vector3(0.14, 1.40, -0.18), "relbow": Vector3(0.5, -1, 0.3),
		"lankle": Vector3(-0.10, 0.08, 0.0), "rankle": Vector3(0.12, 0.50, 0.18), "rknee": Vector3(0, -0.3, -1), "rfp": -40.0},
	&"bk_chamber": {"frame": &"body", "pos": Vector3(0, -0.14, 0), "hips": Vector3(-20, -165, 0), "spine": Vector3(-6, 0, 0), "chest": Vector3(-4, 0, 0), "head": Vector3(0, -70, 0),
		"lfist": Vector3(-0.16, 1.32, -0.30), "lelbow": Vector3(-0.5, -1, 0.3),
		"rfist": Vector3(0.16, 1.30, -0.26), "relbow": Vector3(0.5, -1, 0.3),
		"lankle": Vector3(-0.12, 0.08, -0.06), "lknee": Vector3(0, 0, -1),
		"rankle": Vector3(0.10, 0.62, -0.05), "rknee": Vector3(0, 0.3, -1), "rfp": -50.0},
	&"bk_follow": {"frame": &"body", "pos": Vector3(0, -0.10, -0.10), "hips": Vector3(-66, -192, 0), "spine": Vector3(18, -16, 0), "chest": Vector3(18, -22, 0), "head": Vector3(20, -62, 0),
		"lfist": Vector3(-0.32, 1.06, -0.30), "lelbow": Vector3(-0.8, -0.5, 0),
		"rfist": Vector3(0.30, 1.06, -0.32), "relbow": Vector3(0.8, -0.5, 0),
		"lankle": Vector3(-0.12, 0.08, -0.14), "lknee": Vector3(0, 0, -1), "lfp": -10.0,
		"rankle": Vector3(0.06, 0.98, 0.92), "rknee": Vector3(0, -1, 0), "rfp": -85.0},
	&"bk_hit": {"frame": &"body", "pos": Vector3(0, -0.10, -0.08), "hips": Vector3(-64, -180, 0), "spine": Vector3(18, -18, 0), "chest": Vector3(18, -24, 0), "head": Vector3(20, -60, 0),
		"lfist": Vector3(-0.30, 1.10, -0.30), "lelbow": Vector3(-0.8, -0.5, 0),
		"rfist": Vector3(0.30, 1.10, -0.30), "relbow": Vector3(0.8, -0.5, 0),
		"lankle": Vector3(-0.12, 0.08, -0.10), "lknee": Vector3(0, 0, -1),
		"rankle": Vector3(0.08, 0.95, 0.86), "rknee": Vector3(0, -1, 0), "rfp": -80.0},
	&"bk_return": {"frame": &"body", "pos": Vector3(0, -0.07, 0), "hips": Vector3(0, -270, 0), "spine": Vector3(-6, 0, 0), "head": Vector3(0, 40, 0),
		"lfist": Vector3(-0.10, 1.42, -0.30), "lelbow": Vector3(-0.5, -1, 0.3),
		"rfist": Vector3(0.12, 1.40, -0.20), "relbow": Vector3(0.5, -1, 0.3),
		"lankle": Vector3(-0.12, 0.08, -0.05), "rankle": Vector3(0.14, 0.20, 0.10)},
	# Dash / dodge
	&"dash": {"pos": Vector3(0, -0.12, 0), "spine": Vector3(-26, 0, 0), "chest": Vector3(-10, 0, 0), "head": Vector3(26, 0, 0),
		"lfist": Vector3(-0.26, 0.98, 0.26), "lelbow": Vector3(-0.3, 0.2, -1),
		"rfist": Vector3(0.26, 0.98, 0.26), "relbow": Vector3(0.3, 0.2, -1)},
	&"dodge": {"pos": Vector3(-0.30, -0.20, 0.02), "hips": Vector3(0, 6, 14), "spine": Vector3(-8, 0, 20), "chest": Vector3(-4, 4, 14), "head": Vector3(4, -4, -18),
		"lfist": Vector3(-0.52, 1.18, -0.16), "lelbow": Vector3(-0.6, -1, 0.3),
		"rfist": Vector3(-0.22, 1.30, -0.22), "relbow": Vector3(0.5, -1, 0.3),
		"lankle": Vector3(-0.48, 0.08, -0.04), "lknee": Vector3(-0.6, 0, -1),
		"rankle": Vector3(0.10, 0.10, 0.10), "rknee": Vector3(0.2, 0, -1), "rfp": -30.0},
	&"taunt_flex": {"pos": Vector3(0, -0.04, 0), "spine": Vector3(8, 0, 0), "chest": Vector3(6, 0, 0), "head": Vector3(14, 0, 0),
		"lfist": Vector3(-0.36, 1.70, -0.04), "lelbow": Vector3(-1, -0.15, 0.1),
		"rfist": Vector3(0.36, 1.70, -0.04), "relbow": Vector3(1, -0.15, 0.1)},
	&"taunt_beckon": {"pos": Vector3(0, -0.02, 0), "spine": Vector3(4, 0, 0), "chest": Vector3(2, 10, 0), "head": Vector3(10, -10, 0),
		"lfist": Vector3(-0.24, 1.02, 0.02), "lelbow": Vector3(-0.3, -0.2, 1),
		"rfist": Vector3(0.18, 1.36, -0.55), "relbow": Vector3(0.6, -1, 0.2)},
	&"taunt_beckon2": {"pos": Vector3(0, -0.02, 0), "spine": Vector3(4, 0, 0), "chest": Vector3(2, 10, 0), "head": Vector3(14, -10, 0),
		"lfist": Vector3(-0.24, 1.02, 0.02), "lelbow": Vector3(-0.3, -0.2, 1),
		"rfist": Vector3(0.17, 1.42, -0.38), "relbow": Vector3(0.6, -1, 0.2)},
	# Get-ups. Character space: host origin under the pelvis. Face up: head
	# toward +Z (behind), feet forward. Face down: head toward -Z.
	&"lie_up": {"pos": Vector3(0, -0.83, 0.02), "hips": Vector3(88, 0, 0), "spine": Vector3(0, 0, 0), "chest": Vector3(0, 0, 0), "head": Vector3(-10, 0, 0),
		"lua": Vector3(10, 0, -18), "lla": Vector3(20, 0, 0), "rua": Vector3(10, 0, 18), "rla": Vector3(20, 0, 0),
		"lul": Vector3(8, 0, -6), "lll": Vector3(-12, 0, 0), "lf": Vector3(-30, 0, 0),
		"rul": Vector3(8, 0, 6), "rll": Vector3(-12, 0, 0), "rf": Vector3(-30, 0, 0)},
	&"getup_up_sit": {"pos": Vector3(0, -0.80, 0.0), "hips": Vector3(30, 0, 0), "spine": Vector3(-20, 0, 0), "chest": Vector3(-12, 0, 0), "head": Vector3(10, 0, 0),
		"lfist": Vector3(-0.30, 0.12, 0.25), "lelbow": Vector3(-0.3, 0.3, 1),
		"rfist": Vector3(0.30, 0.12, 0.25), "relbow": Vector3(0.3, 0.3, 1),
		"lankle": Vector3(-0.14, 0.08, -0.55), "lknee": Vector3(0, 1, -0.4),
		"rankle": Vector3(0.14, 0.08, -0.35), "rknee": Vector3(0, 1, -0.4)},
	&"getup_up_crouch": {"pos": Vector3(0, -0.50, -0.06), "hips": Vector3(-20, 0, 0), "spine": Vector3(-25, 0, 0), "chest": Vector3(-10, 0, 0), "head": Vector3(25, 0, 0),
		"lfist": Vector3(-0.30, 0.24, -0.14), "lelbow": Vector3(-0.5, 0.2, 1),
		"rfist": Vector3(0.22, 0.75, -0.30), "relbow": Vector3(0.5, -1, 0.3),
		"lankle": Vector3(-0.15, 0.08, -0.12), "lknee": Vector3(-0.2, 0.3, -1),
		"rankle": Vector3(0.15, 0.08, -0.02), "rknee": Vector3(0.2, 0.3, -1)},
	&"lie_down": {"pos": Vector3(0, -0.83, -0.02), "hips": Vector3(-88, 0, 0), "spine": Vector3(0, 0, 0), "chest": Vector3(0, 0, 0), "head": Vector3(15, 0, 0),
		"lua": Vector3(-10, 0, -25), "lla": Vector3(25, 0, 0), "rua": Vector3(-10, 0, 25), "rla": Vector3(25, 0, 0),
		"lul": Vector3(-4, 0, -6), "lll": Vector3(-10, 0, 0), "lf": Vector3(-40, 0, 0),
		"rul": Vector3(-4, 0, 6), "rll": Vector3(-10, 0, 0), "rf": Vector3(-40, 0, 0)},
	&"getup_down_push": {"pos": Vector3(0, -0.62, 0.05), "hips": Vector3(-55, 0, 0), "spine": Vector3(-10, 0, 0), "chest": Vector3(-5, 0, 0), "head": Vector3(30, 0, 0),
		"lfist": Vector3(-0.22, 0.10, -0.55), "lelbow": Vector3(-1, 0, 0.3),
		"rfist": Vector3(0.22, 0.10, -0.55), "relbow": Vector3(1, 0, 0.3),
		"lankle": Vector3(-0.14, 0.06, 0.55), "lknee": Vector3(0, -1, -0.5),
		"rankle": Vector3(0.14, 0.06, 0.55), "rknee": Vector3(0, -1, -0.5), "lfp": -60.0, "rfp": -60.0},
	&"getup_down_kneel": {"pos": Vector3(0, -0.45, 0.10), "hips": Vector3(-25, 0, 0), "spine": Vector3(-20, 0, 0), "chest": Vector3(-10, 0, 0), "head": Vector3(25, 0, 0),
		"lfist": Vector3(-0.22, 0.75, -0.35), "lelbow": Vector3(-0.5, -1, 0.3),
		"rfist": Vector3(0.22, 0.70, -0.30), "relbow": Vector3(0.5, -1, 0.3),
		"lankle": Vector3(-0.14, 0.08, -0.15), "lknee": Vector3(-0.1, 0.3, -1),
		"rankle": Vector3(0.14, 0.06, 0.45), "rknee": Vector3(0.1, -0.6, -1), "rfp": -50.0},
	&"getup_rise": {"pos": Vector3(0, -0.20, 0), "hips": Vector3(-6, -8, 0), "spine": Vector3(-14, 0, 0), "chest": Vector3(-6, 0, 0), "head": Vector3(12, 8, 0),
		"lfist": Vector3(-0.10, 1.30, -0.30), "lelbow": Vector3(-0.5, -1, 0.3),
		"rfist": Vector3(0.12, 1.25, -0.22), "relbow": Vector3(0.5, -1, 0.4),
		"lankle": Vector3(-0.13, 0.08, -0.12), "rankle": Vector3(0.14, 0.08, 0.10)},
	&"land": {"pos": Vector3(0, -0.32, 0.02), "spine": Vector3(-18, 0, 0), "chest": Vector3(-6, 0, 0), "head": Vector3(16, 0, 0),
		"lfist": Vector3(-0.45, 1.05, -0.25), "lelbow": Vector3(-1, -0.5, 0.3),
		"rfist": Vector3(0.45, 1.05, -0.25), "relbow": Vector3(1, -0.5, 0.3),
		"lankle": Vector3(-0.17, 0.08, -0.10), "rankle": Vector3(0.17, 0.08, 0.10)},
	# Enemy moves: exaggerated tells.
	&"e_hook_cock": {"pos": Vector3(0, -0.10, 0.06), "hips": Vector3(0, -32, 0), "spine": Vector3(2, -10, 0), "chest": Vector3(0, -18, 0), "head": Vector3(0, 58, 0),
		"lfist": Vector3(-0.18, 1.42, -0.36), "lelbow": Vector3(-0.5, -1, 0.2),
		"rfist": Vector3(0.36, 1.74, 0.18), "relbow": Vector3(1, 0.2, 0.5),
		"lankle": Vector3(-0.14, 0.08, -0.22), "rankle": Vector3(0.18, 0.08, 0.20)},
	&"e_hook_hit": {"pos": Vector3(0, -0.10, -0.08), "hips": Vector3(0, 20, 0), "spine": Vector3(-10, 10, 0), "chest": Vector3(-4, 22, 0), "head": Vector3(6, -50, 0),
		"lfist": Vector3(-0.16, 1.40, -0.16), "lelbow": Vector3(-0.5, -1, 0.3),
		"rfist": Vector3(0.02, 1.47, -0.72), "relbow": Vector3(0.8, -0.5, 0.2),
		"lankle": Vector3(-0.14, 0.08, -0.25), "rankle": Vector3(0.16, 0.10, 0.18), "rfp": -20.0},
	&"e_hook_follow": {"pos": Vector3(0, -0.11, -0.09), "hips": Vector3(0, 26, 0), "spine": Vector3(-12, 12, 0), "chest": Vector3(-4, 26, 0), "head": Vector3(6, -60, 0),
		"lfist": Vector3(-0.16, 1.38, -0.12), "lelbow": Vector3(-0.5, -1, 0.3),
		"rfist": Vector3(-0.08, 1.44, -0.72), "relbow": Vector3(0.9, -0.4, 0.2),
		"lankle": Vector3(-0.14, 0.08, -0.25), "rankle": Vector3(0.16, 0.11, 0.18), "rfp": -25.0},
	&"e_heavy_cock": {"pos": Vector3(0, -0.04, 0.06), "spine": Vector3(16, 0, 0), "chest": Vector3(10, 0, 0), "head": Vector3(-14, 0, 0),
		"lfist": Vector3(-0.10, 2.0, 0.14), "lelbow": Vector3(-1, 0.5, 0.1),
		"rfist": Vector3(0.10, 2.0, 0.14), "relbow": Vector3(1, 0.5, 0.1),
		"lankle": Vector3(-0.17, 0.08, -0.12), "rankle": Vector3(0.17, 0.08, 0.14)},
	&"e_heavy_hit": {"pos": Vector3(0, -0.30, -0.12), "spine": Vector3(-34, 0, 0), "chest": Vector3(-16, 0, 0), "head": Vector3(30, 0, 0),
		"lfist": Vector3(-0.08, 0.72, -0.72), "lelbow": Vector3(-1, 0, 0.3),
		"rfist": Vector3(0.08, 0.72, -0.72), "relbow": Vector3(1, 0, 0.3),
		"lankle": Vector3(-0.20, 0.08, -0.24), "rankle": Vector3(0.20, 0.08, 0.16)},
	&"e_kick_cock": {"pos": Vector3(0, -0.02, 0.08), "hips": Vector3(10, -10, 0), "spine": Vector3(10, 0, 0), "chest": Vector3(4, 0, 0), "head": Vector3(-14, 12, 0),
		"lfist": Vector3(-0.42, 1.40, -0.10), "lelbow": Vector3(-1, -0.4, 0.2),
		"rfist": Vector3(0.40, 1.36, 0.05), "relbow": Vector3(1, -0.4, 0.2),
		"lankle": Vector3(-0.10, 0.08, 0.04), "lknee": Vector3(0, 0, -1),
		"rankle": Vector3(0.14, 0.72, 0.02), "rknee": Vector3(0.2, 0.8, -1), "rfp": -20.0},
	&"e_kick_hit": {"pos": Vector3(0, -0.04, 0.0), "hips": Vector3(18, 10, 0), "spine": Vector3(14, 0, 0), "chest": Vector3(6, 0, 0), "head": Vector3(-26, -10, 0),
		"lfist": Vector3(-0.30, 1.38, -0.20), "lelbow": Vector3(-1, -0.6, 0.3),
		"rfist": Vector3(0.34, 1.28, -0.04), "relbow": Vector3(1, -0.6, 0.3),
		"lankle": Vector3(-0.10, 0.08, 0.14), "lknee": Vector3(0, 0, -1),
		"rankle": Vector3(0.05, 1.0, -0.86), "rknee": Vector3(0, 1, 0), "rfp": 40.0},
	&"e_grab_cock": {"pos": Vector3(0, -0.16, 0.02), "spine": Vector3(-12, 0, 0), "chest": Vector3(-4, 0, 0), "head": Vector3(16, 0, 0),
		"lfist": Vector3(-0.78, 1.38, -0.18), "lelbow": Vector3(-0.3, -0.4, 1),
		"rfist": Vector3(0.78, 1.38, -0.18), "relbow": Vector3(0.3, -0.4, 1),
		"lankle": Vector3(-0.20, 0.08, -0.10), "rankle": Vector3(0.20, 0.08, 0.12)},
	&"e_grab_hit": {"pos": Vector3(0, -0.14, -0.10), "spine": Vector3(-16, 0, 0), "chest": Vector3(-6, 0, 0), "head": Vector3(16, 0, 0),
		"lfist": Vector3(-0.12, 1.30, -0.70), "lelbow": Vector3(-0.8, -0.6, 0.2),
		"rfist": Vector3(0.12, 1.30, -0.70), "relbow": Vector3(0.8, -0.6, 0.2)},
	&"e_charge_cock": {"pos": Vector3(0, -0.22, 0.06), "hips": Vector3(0, -22, 0), "spine": Vector3(-26, -8, 0), "chest": Vector3(-12, -14, 0), "head": Vector3(36, 40, 0),
		"lfist": Vector3(-0.02, 1.02, -0.30), "lelbow": Vector3(-1, -0.4, -0.3),
		"rfist": Vector3(0.26, 1.0, 0.02), "relbow": Vector3(0.8, -0.6, 0.4),
		"lankle": Vector3(-0.18, 0.08, -0.30), "rankle": Vector3(0.18, 0.12, 0.34), "rfp": -25.0},
	&"e_charge_hit": {"pos": Vector3(0, -0.22, -0.14), "hips": Vector3(0, -28, 0), "spine": Vector3(-30, -8, 0), "chest": Vector3(-14, -16, 0), "head": Vector3(40, 46, 0),
		"lfist": Vector3(0.0, 1.00, -0.34), "lelbow": Vector3(-1, -0.4, -0.3),
		"rfist": Vector3(0.26, 0.98, 0.0), "relbow": Vector3(0.8, -0.6, 0.4),
		"lankle": Vector3(-0.18, 0.08, -0.44), "rankle": Vector3(0.18, 0.14, 0.30), "rfp": -35.0},
	&"e_throw_cock": {"pos": Vector3(0, -0.06, 0.06), "hips": Vector3(0, -30, 0), "spine": Vector3(10, 0, 0), "chest": Vector3(6, -25, 0), "head": Vector3(-6, 50, 0),
		"lfist": Vector3(-0.30, 1.55, -0.60), "lelbow": Vector3(-0.5, -1, 0.3),
		"rfist": Vector3(0.36, 1.80, 0.42), "relbow": Vector3(1, 0, 0.6),
		"lankle": Vector3(-0.13, 0.08, -0.32), "rankle": Vector3(0.16, 0.08, 0.20)},
	&"e_throw_hit": {"pos": Vector3(0, -0.10, -0.10), "hips": Vector3(0, 25, 0), "spine": Vector3(-16, 0, 0), "chest": Vector3(-6, 30, 0), "head": Vector3(10, -45, 0),
		"lfist": Vector3(-0.28, 1.18, 0.02), "lelbow": Vector3(-0.5, -1, 0.5),
		"rfist": Vector3(0.02, 1.55, -0.80), "relbow": Vector3(0.8, -0.5, 0.2),
		"lankle": Vector3(-0.13, 0.08, -0.34), "rankle": Vector3(0.16, 0.12, 0.22), "rfp": -25.0},
	# Holds
	&"held_a": {"pos": Vector3(0, -0.02, 0), "spine": Vector3(10, 0, 6), "chest": Vector3(6, 0, 4), "head": Vector3(-14, 10, 8),
		"lfist": Vector3(-0.40, 1.62, -0.25), "lelbow": Vector3(-1, -0.4, 0.2),
		"rfist": Vector3(0.30, 1.18, -0.36), "relbow": Vector3(1, -1, 0.2),
		"lankle": Vector3(-0.12, 0.24, -0.22), "rankle": Vector3(0.12, 0.08, 0.10)},
	&"held_b": {"pos": Vector3(0, -0.02, 0), "spine": Vector3(10, 0, -6), "chest": Vector3(6, 0, -4), "head": Vector3(-14, -10, -8),
		"lfist": Vector3(-0.30, 1.18, -0.36), "lelbow": Vector3(-1, -1, 0.2),
		"rfist": Vector3(0.40, 1.62, -0.25), "relbow": Vector3(1, -0.4, 0.2),
		"lankle": Vector3(-0.12, 0.08, 0.10), "rankle": Vector3(0.12, 0.24, -0.22)},
	&"stagger_a": {"pos": Vector3(0, -0.08, 0.04), "hips": Vector3(8, 0, 0), "spine": Vector3(14, 0, 4), "chest": Vector3(10, 0, 0), "head": Vector3(-24, 8, 0),
		"lfist": Vector3(-0.50, 1.46, 0.02), "lelbow": Vector3(-1, -0.6, 0.2),
		"rfist": Vector3(0.44, 1.22, -0.12), "relbow": Vector3(1, -0.6, 0.2),
		"lankle": Vector3(-0.12, 0.08, -0.16), "rankle": Vector3(0.15, 0.22, 0.24), "rfp": -25.0},
	&"stagger_b": {"pos": Vector3(0, -0.10, 0.04), "hips": Vector3(8, 0, 0), "spine": Vector3(16, 0, -4), "chest": Vector3(10, 0, 0), "head": Vector3(-26, -8, 0),
		"lfist": Vector3(-0.44, 1.22, -0.12), "lelbow": Vector3(-1, -0.6, 0.2),
		"rfist": Vector3(0.50, 1.46, 0.02), "relbow": Vector3(1, -0.6, 0.2),
		"lankle": Vector3(-0.12, 0.22, 0.20), "rankle": Vector3(0.15, 0.08, -0.06), "lfp": -25.0},
	&"fall_a": {"spine": Vector3(-14, 0, 0), "chest": Vector3(-10, 0, 0), "head": Vector3(-20, 0, 0),
		"lua": Vector3(120, 0, -50), "lla": Vector3(60, 0, 0), "rua": Vector3(40, 0, 70), "rla": Vector3(70, 0, 0),
		"lul": Vector3(70, 0, -10), "lll": Vector3(-90, 0, 0), "lf": Vector3(-10, 0, 0),
		"rul": Vector3(20, 0, 10), "rll": Vector3(-40, 0, 0), "rf": Vector3(-20, 0, 0)},
	&"fall_b": {"spine": Vector3(-14, 0, 0), "chest": Vector3(-10, 0, 0), "head": Vector3(-20, 0, 0),
		"lua": Vector3(40, 0, -70), "lla": Vector3(70, 0, 0), "rua": Vector3(120, 0, 50), "rla": Vector3(60, 0, 0),
		"lul": Vector3(20, 0, -10), "lll": Vector3(-40, 0, 0), "lf": Vector3(-20, 0, 0),
		"rul": Vector3(70, 0, 10), "rll": Vector3(-90, 0, 0), "rf": Vector3(-10, 0, 0)},
	# --- Upgrade 2: stance -----------------------------------------------------------
	# Crouch: head top ~1.1 m (Tuning.CROUCH_HEIGHT). Locomotion blends to it.
	&"crouch": {"pos": Vector3(0, -0.55, 0.02), "hips": Vector3(-18, -12, 0), "spine": Vector3(-18, 0, 0), "chest": Vector3(-12, -6, 0), "head": Vector3(40, 18, 0),
		"lfist": Vector3(-0.10, 1.00, -0.36), "lelbow": Vector3(-0.5, -1, 0.2),
		"rfist": Vector3(0.10, 0.96, -0.26), "relbow": Vector3(0.5, -1, 0.3),
		"lankle": Vector3(-0.19, 0.08, -0.20), "lknee": Vector3(-0.4, 0, -1),
		"rankle": Vector3(0.19, 0.08, 0.18), "rknee": Vector3(0.4, 0, -1)},
	&"block_crouch": {"pos": Vector3(0, -0.57, 0.02), "hips": Vector3(-16, 0, 0), "spine": Vector3(-16, 0, 0), "chest": Vector3(-12, 0, 0), "head": Vector3(20, 0, 0),
		"lfist": Vector3(-0.08, 0.98, -0.24), "lelbow": Vector3(-0.2, -1, -0.4),
		"rfist": Vector3(0.08, 0.98, -0.24), "relbow": Vector3(0.2, -1, -0.4)},
	&"jump_rise": {"pos": Vector3(0, 0.02, 0), "spine": Vector3(-6, 0, 0), "chest": Vector3(-4, 0, 0), "head": Vector3(8, 0, 0),
		"lfist": Vector3(-0.28, 1.62, -0.20), "lelbow": Vector3(-1, -0.3, 0.2),
		"rfist": Vector3(0.28, 1.58, -0.15), "relbow": Vector3(1, -0.3, 0.2),
		"lankle": Vector3(-0.12, 0.42, -0.05), "lknee": Vector3(-0.1, 0.2, -1), "lfp": -20.0,
		"rankle": Vector3(0.13, 0.30, 0.12), "rknee": Vector3(0.1, 0.1, -1), "rfp": -40.0},
	&"jump_fall": {"pos": Vector3(0, -0.04, 0), "spine": Vector3(-4, 0, 0), "head": Vector3(10, 0, 0),
		"lfist": Vector3(-0.42, 1.35, -0.20), "lelbow": Vector3(-1, -0.5, 0.2),
		"rfist": Vector3(0.42, 1.32, -0.18), "relbow": Vector3(1, -0.5, 0.2),
		"lankle": Vector3(-0.14, 0.12, -0.12), "rankle": Vector3(0.15, 0.08, 0.10), "lfp": -25.0, "rfp": -25.0},
	# --- Upgrade 2: string moves -------------------------------------------------------
	&"cross_cock": {"pos": Vector3(0, -0.09, 0.03), "hips": Vector3(0, -24, 0), "spine": Vector3(-4, 0, 0), "chest": Vector3(-2, -18, 0), "head": Vector3(4, 40, 0),
		"lfist": Vector3(-0.08, 1.46, -0.38), "lelbow": Vector3(-0.5, -1, 0.2),
		"rfist": Vector3(0.18, 1.40, -0.06), "relbow": Vector3(0.6, -1, 0.5)},
	&"cross_hit": {"pos": Vector3(0, -0.09, -0.08), "hips": Vector3(0, 20, 0), "spine": Vector3(-10, 0, 0), "chest": Vector3(-4, 32, 0), "head": Vector3(8, -48, 0),
		"lfist": Vector3(-0.13, 1.45, -0.15), "lelbow": Vector3(-0.5, -1, 0.4),
		"rfist": Vector3(0.02, 1.45, -0.74), "relbow": Vector3(0.8, -0.6, 0.2),
		"lankle": Vector3(-0.12, 0.08, -0.24), "rankle": Vector3(0.14, 0.11, 0.13), "rfp": -25.0},
	&"cross_follow": {"pos": Vector3(0, -0.10, -0.11), "hips": Vector3(0, 26, 0), "spine": Vector3(-12, 0, 0), "chest": Vector3(-6, 40, 0), "head": Vector3(10, -58, 0),
		"lfist": Vector3(-0.14, 1.44, -0.12), "lelbow": Vector3(-0.5, -1, 0.4),
		"rfist": Vector3(-0.08, 1.43, -0.78), "relbow": Vector3(0.9, -0.4, 0.2),
		"lankle": Vector3(-0.12, 0.08, -0.24), "rankle": Vector3(0.14, 0.12, 0.12), "rfp": -30.0},
	&"hook_l_follow": {"pos": Vector3(0, -0.10, -0.05), "hips": Vector3(0, -32, 0), "chest": Vector3(-4, -42, 0), "spine": Vector3(-6, 0, 0), "head": Vector3(6, 60, 0),
		"lfist": Vector3(0.30, 1.46, -0.42), "lelbow": Vector3(-1, 0.3, 0.3),
		"rfist": Vector3(0.12, 1.47, -0.18), "relbow": Vector3(0.5, -1, 0.4)},
	&"uppercut_cock": {"pos": Vector3(0, -0.22, 0.0), "hips": Vector3(0, -18, 0), "spine": Vector3(-18, 0, 0), "chest": Vector3(-6, -16, 8), "head": Vector3(20, 28, 0),
		"lfist": Vector3(-0.10, 1.28, -0.32), "lelbow": Vector3(-0.5, -1, 0.2),
		"rfist": Vector3(0.22, 0.98, -0.12), "relbow": Vector3(0.4, -1, 0.5),
		"lankle": Vector3(-0.16, 0.08, -0.20), "rankle": Vector3(0.18, 0.08, 0.16)},
	&"uppercut_hit": {"pos": Vector3(0, -0.03, -0.07), "hips": Vector3(0, 18, 0), "spine": Vector3(4, 0, 0), "chest": Vector3(2, 24, -4), "head": Vector3(-6, -30, 0),
		"lfist": Vector3(-0.14, 1.36, -0.14), "lelbow": Vector3(-0.5, -1, 0.4),
		"rfist": Vector3(0.04, 1.62, -0.44), "relbow": Vector3(0.3, -1, -0.7),
		"lankle": Vector3(-0.14, 0.08, -0.22), "rankle": Vector3(0.16, 0.12, 0.12), "rfp": -35.0},
	&"uppercut_follow": {"pos": Vector3(0, 0.0, -0.08), "hips": Vector3(0, 24, 0), "spine": Vector3(10, 0, 0), "chest": Vector3(4, 30, -4), "head": Vector3(-14, -36, 0),
		"lfist": Vector3(-0.14, 1.34, -0.12), "lelbow": Vector3(-0.5, -1, 0.4),
		"rfist": Vector3(0.0, 1.80, -0.30), "relbow": Vector3(0.3, -1, -0.8),
		"lankle": Vector3(-0.14, 0.08, -0.22), "rankle": Vector3(0.16, 0.14, 0.10), "rfp": -45.0},
	&"rising_cock": {"pos": Vector3(0, -0.52, 0.02), "hips": Vector3(-16, -20, 0), "spine": Vector3(-18, 0, 0), "chest": Vector3(-8, -16, 6), "head": Vector3(40, 30, 0),
		"lfist": Vector3(-0.10, 0.95, -0.30), "lelbow": Vector3(-0.5, -1, 0.2),
		"rfist": Vector3(0.22, 0.62, -0.12), "relbow": Vector3(0.4, -1, 0.5),
		"lankle": Vector3(-0.18, 0.08, -0.20), "lknee": Vector3(-0.4, 0, -1),
		"rankle": Vector3(0.18, 0.08, 0.18), "rknee": Vector3(0.4, 0, -1)},
	&"rising_hit": {"pos": Vector3(0, 0.02, -0.08), "hips": Vector3(0, 18, 0), "spine": Vector3(6, 0, 0), "chest": Vector3(2, 24, -4), "head": Vector3(-10, -30, 0),
		"lfist": Vector3(-0.16, 1.30, -0.10), "lelbow": Vector3(-0.5, -1, 0.4),
		"rfist": Vector3(0.03, 1.70, -0.40), "relbow": Vector3(0.3, -1, -0.7),
		"lankle": Vector3(-0.14, 0.10, -0.18), "rankle": Vector3(0.16, 0.12, 0.12), "lfp": -30.0, "rfp": -40.0},
	&"crouch_punch_cock": {"pos": Vector3(0, -0.52, 0.03), "hips": Vector3(-16, -16, 0), "spine": Vector3(-14, 0, 0), "chest": Vector3(-8, -22, 0), "head": Vector3(38, 34, 0),
		"lfist": Vector3(-0.10, 0.98, -0.32), "lelbow": Vector3(-0.5, -1, 0.2),
		"rfist": Vector3(0.22, 0.84, 0.0), "relbow": Vector3(0.6, -0.6, 0.6),
		"lankle": Vector3(-0.18, 0.08, -0.20), "lknee": Vector3(-0.4, 0, -1),
		"rankle": Vector3(0.18, 0.08, 0.18), "rknee": Vector3(0.4, 0, -1)},
	&"crouch_punch_hit": {"pos": Vector3(0, -0.50, -0.08), "hips": Vector3(-16, 18, 0), "spine": Vector3(-16, 0, 0), "chest": Vector3(-8, 26, 0), "head": Vector3(40, -36, 0),
		"lfist": Vector3(-0.14, 1.0, -0.20), "lelbow": Vector3(-0.5, -1, 0.3),
		"rfist": Vector3(0.02, 0.86, -0.66), "relbow": Vector3(0.8, -0.6, 0.2),
		"lankle": Vector3(-0.18, 0.08, -0.22), "lknee": Vector3(-0.4, 0, -1),
		"rankle": Vector3(0.18, 0.09, 0.16), "rknee": Vector3(0.4, 0, -1), "rfp": -20.0},
	# Roundhouse: pivot on the left foot, hips turn 85 deg left, the right shin
	# swings horizontally into the target (body frame).
	&"roundhouse_cock": {"frame": &"body", "pos": Vector3(0, -0.06, 0.02), "hips": Vector3(0, 40, 12), "spine": Vector3(4, 0, 8), "chest": Vector3(2, 0, 4), "head": Vector3(-6, -40, -10),
		"lfist": Vector3(-0.30, 1.42, -0.26), "lelbow": Vector3(-0.6, -1, 0.2),
		"rfist": Vector3(0.10, 1.38, -0.30), "relbow": Vector3(0.6, -1, 0.2),
		"lankle": Vector3(-0.10, 0.08, 0.0), "lknee": Vector3(-0.3, 0, -1), "lfp": -15.0,
		"rankle": Vector3(0.34, 0.74, 0.0), "rknee": Vector3(1, 0.5, -0.6), "rfp": -30.0},
	&"roundhouse_hit": {"frame": &"body", "pos": Vector3(0, -0.08, -0.04), "hips": Vector3(0, 85, 30), "spine": Vector3(4, 0, 16), "chest": Vector3(2, 0, 8), "head": Vector3(-4, -70, -16),
		"lfist": Vector3(-0.40, 1.30, -0.10), "lelbow": Vector3(-0.8, -0.5, 0.2),
		"rfist": Vector3(0.05, 1.30, -0.35), "relbow": Vector3(0.6, -1, 0.2),
		"lankle": Vector3(-0.10, 0.08, 0.0), "lknee": Vector3(-0.3, 0, -1), "lfp": -20.0,
		"rankle": Vector3(0.84, 1.0, -0.06), "rknee": Vector3(0, 1, 0.3), "rfp": -40.0},
	&"roundhouse_follow": {"frame": &"body", "pos": Vector3(0, -0.09, -0.06), "hips": Vector3(0, 125, 30), "spine": Vector3(4, 0, 18), "chest": Vector3(2, 0, 8), "head": Vector3(-4, -70, -16),
		"lfist": Vector3(-0.42, 1.28, -0.08), "lelbow": Vector3(-0.8, -0.5, 0.2),
		"rfist": Vector3(0.05, 1.28, -0.35), "relbow": Vector3(0.6, -1, 0.2),
		"lankle": Vector3(-0.10, 0.08, 0.0), "lknee": Vector3(-0.3, 0, -1), "lfp": -20.0,
		"rankle": Vector3(0.82, 0.98, -0.08), "rknee": Vector3(0, 1, 0.3), "rfp": -40.0},
	# Spinning backfist: turn right, the extended right arm sweeps round and
	# lands BEHIND the start facing at head height (body frame).
	&"backfist_cock": {"frame": &"body", "pos": Vector3(0, -0.10, 0.0), "hips": Vector3(0, -35, 0), "spine": Vector3(-6, 0, 0), "chest": Vector3(-4, 30, 0), "head": Vector3(0, -80, 0),
		"rfist": Vector3(-0.22, 1.40, -0.22), "relbow": Vector3(1, -0.2, -0.4),
		"lfist": Vector3(-0.28, 1.30, 0.02), "lelbow": Vector3(-0.6, -1, 0.4),
		"lankle": Vector3(-0.12, 0.08, -0.10), "rankle": Vector3(0.16, 0.08, 0.10)},
	&"backfist_hit": {"frame": &"body", "pos": Vector3(0, -0.08, 0.0), "hips": Vector3(0, -95, 0), "spine": Vector3(-4, 0, -6), "chest": Vector3(-2, -8, 0), "head": Vector3(4, -20, 0),
		"rfist": Vector3(0.80, 1.48, 0.04), "relbow": Vector3(0, -1, 0.6),
		"lfist": Vector3(-0.25, 1.30, -0.10), "lelbow": Vector3(-0.6, -1, 0.3),
		"lankle": Vector3(-0.14, 0.08, -0.06), "rankle": Vector3(0.16, 0.08, 0.08)},
	&"backfist_follow": {"frame": &"body", "pos": Vector3(0, -0.09, 0.0), "hips": Vector3(0, -150, 0), "spine": Vector3(-4, 0, -8), "chest": Vector3(-2, -12, 0), "head": Vector3(4, 0, 0),
		"rfist": Vector3(0.74, 1.44, 0.22), "relbow": Vector3(0, -1, 0.6),
		"lfist": Vector3(-0.25, 1.30, -0.10), "lelbow": Vector3(-0.6, -1, 0.3),
		"lankle": Vector3(-0.14, 0.08, -0.06), "rankle": Vector3(0.16, 0.08, 0.08)},
	&"backfist_return": {"frame": &"body", "pos": Vector3(0, -0.07, 0.0), "hips": Vector3(0, -250, 0), "spine": Vector3(-4, 0, 0), "head": Vector3(4, 20, 0),
		"lfist": Vector3(-0.08, 1.44, -0.32), "lelbow": Vector3(-0.5, -1, 0.3),
		"rfist": Vector3(0.12, 1.40, -0.22), "relbow": Vector3(0.5, -1, 0.4),
		"lankle": Vector3(-0.12, 0.08, -0.12), "rankle": Vector3(0.14, 0.08, 0.12)},
	# Air moves (relative to the airborne capsule).
	&"flying_cock": {"spine": Vector3(-8, 0, 0), "chest": Vector3(-4, 0, 0), "head": Vector3(10, 0, 0),
		"lfist": Vector3(-0.30, 1.40, -0.25), "lelbow": Vector3(-1, -0.3, 0.2),
		"rfist": Vector3(0.28, 1.36, -0.20), "relbow": Vector3(1, -0.3, 0.2),
		"lankle": Vector3(-0.12, 0.48, -0.05), "lknee": Vector3(-0.1, 0.4, -1), "lfp": -20.0,
		"rankle": Vector3(0.12, 0.55, -0.05), "rknee": Vector3(0.1, 0.5, -1), "rfp": 10.0},
	&"flying_hit": {"pos": Vector3(0, 0.0, -0.06), "hips": Vector3(14, 0, 0), "spine": Vector3(14, 0, 0), "chest": Vector3(6, 0, 0), "head": Vector3(-26, 0, 0),
		"lfist": Vector3(-0.38, 1.30, 0.12), "lelbow": Vector3(-0.6, -0.3, 1),
		"rfist": Vector3(0.36, 1.26, 0.16), "relbow": Vector3(0.6, -0.3, 1),
		"lankle": Vector3(-0.12, 0.50, 0.20), "lknee": Vector3(0, 0.3, -1), "lfp": -30.0,
		"rankle": Vector3(0.08, 0.98, -0.92), "rknee": Vector3(0, 1, 0), "rfp": 80.0},
	&"hammer_cock": {"spine": Vector3(16, 0, 0), "chest": Vector3(8, 0, 0), "head": Vector3(-12, 0, 0),
		"lfist": Vector3(-0.10, 2.06, 0.14), "lelbow": Vector3(-1, 0.5, 0.1),
		"rfist": Vector3(0.10, 2.06, 0.14), "relbow": Vector3(1, 0.5, 0.1),
		"lankle": Vector3(-0.12, 0.40, 0.05), "rankle": Vector3(0.12, 0.36, 0.10), "lfp": -30.0, "rfp": -30.0},
	&"hammer_hit": {"pos": Vector3(0, -0.04, -0.06), "spine": Vector3(-34, 0, 0), "chest": Vector3(-16, 0, 0), "head": Vector3(28, 0, 0),
		"lfist": Vector3(-0.10, 0.76, -0.56), "lelbow": Vector3(-1, 0, 0.3),
		"rfist": Vector3(0.10, 0.76, -0.56), "relbow": Vector3(1, 0, 0.3),
		"lankle": Vector3(-0.12, 0.30, 0.10), "rankle": Vector3(0.12, 0.28, 0.12), "lfp": -20.0, "rfp": -20.0},
	# Grab follow-ups.
	&"knee_cock": {"pos": Vector3(0, -0.08, 0.04), "spine": Vector3(4, 0, 0), "head": Vector3(-4, 0, 0),
		"lfist": Vector3(-0.08, 1.24, -0.42), "lelbow": Vector3(-1, -0.4, 0.2),
		"rfist": Vector3(0.08, 1.24, -0.42), "relbow": Vector3(1, -0.4, 0.2),
		"lankle": Vector3(-0.14, 0.08, -0.06), "rankle": Vector3(0.13, 0.26, 0.28), "rfp": -40.0},
	&"knee_hit": {"pos": Vector3(0, -0.04, -0.08), "spine": Vector3(-14, 0, 0), "chest": Vector3(-6, 0, 0), "head": Vector3(12, 0, 0),
		"lfist": Vector3(-0.08, 1.10, -0.40), "lelbow": Vector3(-1, -0.4, 0.2),
		"rfist": Vector3(0.08, 1.10, -0.40), "relbow": Vector3(1, -0.4, 0.2),
		"lankle": Vector3(-0.14, 0.08, -0.04), "lfp": -15.0,
		"rankle": Vector3(0.10, 0.62, -0.20), "rknee": Vector3(0, 0.8, -1), "rfp": -50.0},
	&"headbutt_cock": {"pos": Vector3(0, -0.08, 0.05), "spine": Vector3(12, 0, 0), "chest": Vector3(8, 0, 0), "head": Vector3(-24, 0, 0),
		"lfist": Vector3(-0.08, 1.38, -0.40), "lelbow": Vector3(-1, -0.4, 0.2)},
	&"headbutt_hit": {"pos": Vector3(0, -0.10, -0.10), "spine": Vector3(-20, 0, 0), "chest": Vector3(-10, 0, 0), "head": Vector3(-30, 0, 0),
		"lfist": Vector3(-0.08, 1.24, -0.34), "lelbow": Vector3(-1, -0.4, 0.2)},
	&"neck_throw_load": {"pos": Vector3(0, -0.14, 0.02), "hips": Vector3(0, -30, 0), "spine": Vector3(-10, 0, 0), "chest": Vector3(-4, -20, 0), "head": Vector3(10, 40, 0),
		"rfist": Vector3(-0.10, 1.20, -0.30), "relbow": Vector3(1, 0.1, -0.2),
		"lfist": Vector3(-0.05, 1.10, -0.45), "lelbow": Vector3(-0.6, -1, 0.2),
		"lankle": Vector3(-0.18, 0.08, -0.18), "rankle": Vector3(0.20, 0.08, 0.16)},
	&"neck_throw_fling": {"pos": Vector3(0, -0.16, -0.06), "hips": Vector3(0, 55, 0), "spine": Vector3(-20, 0, 0), "chest": Vector3(-8, 40, 0), "head": Vector3(12, -60, 0),
		"rfist": Vector3(-0.55, 0.95, -0.45), "relbow": Vector3(1, -0.3, 0.3),
		"lfist": Vector3(-0.56, 1.02, -0.22), "lelbow": Vector3(-0.6, -1, 0.3),
		"lankle": Vector3(-0.18, 0.08, -0.18), "rankle": Vector3(0.20, 0.10, 0.18), "rfp": -25.0},
	&"uthrow_load": {"pos": Vector3(0, -0.28, 0.02), "spine": Vector3(-16, 0, 0), "chest": Vector3(-6, 0, 0), "head": Vector3(20, 0, 0),
		"lfist": Vector3(-0.14, 0.85, -0.42), "lelbow": Vector3(-1, -0.4, 0.2),
		"rfist": Vector3(0.14, 0.85, -0.42), "relbow": Vector3(1, -0.4, 0.2),
		"lankle": Vector3(-0.20, 0.08, -0.10), "rankle": Vector3(0.20, 0.08, 0.10)},
	&"uthrow_fling": {"pos": Vector3(0, 0.03, 0.0), "spine": Vector3(12, 0, 0), "chest": Vector3(6, 0, 0), "head": Vector3(-26, 0, 0),
		"lfist": Vector3(-0.10, 2.10, -0.22), "lelbow": Vector3(-1, 0.3, 0.2),
		"rfist": Vector3(0.10, 2.10, -0.22), "relbow": Vector3(1, 0.3, 0.2),
		"lankle": Vector3(-0.16, 0.12, -0.06), "rankle": Vector3(0.16, 0.12, 0.06), "lfp": -40.0, "rfp": -40.0},
	&"wslam_load": {"pos": Vector3(0, -0.10, 0.06), "hips": Vector3(0, -10, 0), "spine": Vector3(6, 0, 0), "chest": Vector3(2, -10, 0), "head": Vector3(-4, 20, 0),
		"lfist": Vector3(-0.12, 1.28, -0.28), "lelbow": Vector3(-1, -0.4, 0.2),
		"rfist": Vector3(0.12, 1.28, -0.24), "relbow": Vector3(1, -0.4, 0.2),
		"lankle": Vector3(-0.15, 0.08, -0.06), "rankle": Vector3(0.18, 0.08, 0.14)},
	&"wslam_hit": {"pos": Vector3(0, -0.18, -0.18), "hips": Vector3(0, 8, 0), "spine": Vector3(-22, 0, 0), "chest": Vector3(-10, 4, 0), "head": Vector3(24, -8, 0),
		"lfist": Vector3(-0.12, 1.12, -0.88), "lelbow": Vector3(-0.8, -0.6, 0.2),
		"rfist": Vector3(0.12, 1.10, -0.88), "relbow": Vector3(0.8, -0.6, 0.2),
		"lankle": Vector3(-0.14, 0.08, -0.46), "rankle": Vector3(0.18, 0.12, 0.24), "rfp": -30.0},
	&"wslam_follow": {"pos": Vector3(0, -0.20, -0.22), "hips": Vector3(0, 10, 0), "spine": Vector3(-26, 0, 0), "chest": Vector3(-12, 4, 0), "head": Vector3(28, -8, 0),
		"lfist": Vector3(-0.12, 1.02, -0.92), "lelbow": Vector3(-0.8, -0.6, 0.2),
		"rfist": Vector3(0.12, 1.00, -0.92), "relbow": Vector3(0.8, -0.6, 0.2),
		"lankle": Vector3(-0.14, 0.08, -0.46), "rankle": Vector3(0.18, 0.14, 0.24), "rfp": -35.0},
	# Ground finishers (standing over a downed enemy).
	&"mount_cock": {"pos": Vector3(0, -0.52, 0.10), "hips": Vector3(-20, 0, 0), "spine": Vector3(-20, 0, 0), "chest": Vector3(-8, 0, 0), "head": Vector3(30, 0, 0),
		"rfist": Vector3(0.26, 1.02, -0.08), "relbow": Vector3(0.6, 0.6, 0.8),
		"lfist": Vector3(-0.15, 0.45, -0.40), "lelbow": Vector3(-0.6, -0.4, 0.6),
		"lankle": Vector3(-0.16, 0.06, 0.40), "lknee": Vector3(-0.1, -0.4, -1), "lfp": -60.0,
		"rankle": Vector3(0.18, 0.08, -0.15), "rknee": Vector3(0.2, 0, -1)},
	&"mount_hit": {"pos": Vector3(0, -0.56, 0.02), "hips": Vector3(-26, 8, 0), "spine": Vector3(-26, 0, 0), "chest": Vector3(-12, 10, 0), "head": Vector3(40, -10, 0),
		"rfist": Vector3(0.04, 0.22, -0.52), "relbow": Vector3(0.6, 0.2, 0.6),
		"lfist": Vector3(-0.16, 0.45, -0.35), "lelbow": Vector3(-0.6, -0.4, 0.6),
		"lankle": Vector3(-0.16, 0.06, 0.40), "lknee": Vector3(-0.1, -0.4, -1), "lfp": -60.0,
		"rankle": Vector3(0.18, 0.08, -0.15), "rknee": Vector3(0.2, 0, -1)},
	&"stomp_cock": {"pos": Vector3(0, -0.04, 0.06), "spine": Vector3(4, 0, 0), "head": Vector3(20, 0, 0),
		"lfist": Vector3(-0.40, 1.30, -0.15), "lelbow": Vector3(-1, -0.4, 0.3),
		"rfist": Vector3(0.38, 1.25, -0.10), "relbow": Vector3(1, -0.4, 0.3),
		"lankle": Vector3(-0.12, 0.08, 0.04), "rankle": Vector3(0.12, 0.72, -0.30), "rknee": Vector3(0, 0.6, -1), "rfp": 10.0},
	&"stomp_hit": {"pos": Vector3(0, -0.16, -0.10), "spine": Vector3(-16, 0, 0), "chest": Vector3(-6, 0, 0), "head": Vector3(30, 0, 0),
		"lfist": Vector3(-0.40, 1.10, -0.10), "lelbow": Vector3(-1, -0.4, 0.3),
		"rfist": Vector3(0.38, 1.05, -0.05), "relbow": Vector3(1, -0.4, 0.3),
		"lankle": Vector3(-0.12, 0.08, 0.06), "rankle": Vector3(0.10, 0.12, -0.48), "rknee": Vector3(0, 0.3, -1), "rfp": 0.0},
	# Enemy low sweep: crouched, leg loaded back-right, hand on the floor.
	&"e_sweep_cock": {"frame": &"body", "pos": Vector3(0, -0.50, 0.02), "hips": Vector3(-10, -55, 0), "spine": Vector3(-26, 0, 0), "chest": Vector3(-10, 0, 0), "head": Vector3(28, 50, 0),
		"lfist": Vector3(-0.34, 0.10, -0.26), "lelbow": Vector3(-1, 0, 0.3),
		"rfist": Vector3(0.18, 0.78, -0.30), "relbow": Vector3(0.5, -1, 0.3),
		"lankle": Vector3(-0.20, 0.08, -0.02), "lknee": Vector3(-0.4, 0.2, -1),
		"rankle": Vector3(0.80, 0.08, 0.22), "rknee": Vector3(0, 1, 0), "rfp": 0.0},
	# --- Upgrade 2: states ------------------------------------------------------------
	# Stumble (tap sweep): on its feet, right foot kicked out, arms out for balance.
	&"stumble_a": {"pos": Vector3(-0.06, -0.10, 0.05), "hips": Vector3(6, 0, 6), "spine": Vector3(14, 0, 10), "chest": Vector3(6, 0, 4), "head": Vector3(-12, 6, -8),
		"lfist": Vector3(-0.66, 1.46, -0.04), "lelbow": Vector3(-0.4, -0.6, 0.6),
		"rfist": Vector3(0.62, 1.52, 0.06), "relbow": Vector3(0.4, -0.6, 0.6),
		"lankle": Vector3(-0.12, 0.08, 0.02), "lknee": Vector3(-0.1, 0, -1),
		"rankle": Vector3(0.26, 0.30, -0.36), "rknee": Vector3(0.3, 0.3, -1), "rfp": 20.0},
	&"stumble_b": {"pos": Vector3(-0.09, -0.12, 0.07), "hips": Vector3(8, 0, 9), "spine": Vector3(16, 0, 14), "chest": Vector3(8, 0, 6), "head": Vector3(-14, -6, -12),
		"lfist": Vector3(-0.60, 1.26, 0.08), "lelbow": Vector3(-0.4, -0.6, 0.6),
		"rfist": Vector3(0.44, 1.52, 0.12), "relbow": Vector3(0.4, -0.6, 0.6),
		"lankle": Vector3(-0.12, 0.08, 0.02), "lknee": Vector3(-0.1, 0, -1),
		"rankle": Vector3(0.22, 0.22, -0.30), "rknee": Vector3(0.3, 0.3, -1), "rfp": 15.0},
	# Dazed: hunched over, arms hanging, swaying.
	&"dazed_a": {"pos": Vector3(0.04, -0.12, 0.02), "hips": Vector3(0, 0, -5), "spine": Vector3(-22, 0, -6), "chest": Vector3(-12, 0, -4), "head": Vector3(-18, 10, -10),
		"lfist": Vector3(-0.26, 0.74, -0.14), "lelbow": Vector3(-0.5, -0.3, 0.8),
		"rfist": Vector3(0.24, 0.72, -0.12), "relbow": Vector3(0.5, -0.3, 0.8),
		"lankle": Vector3(-0.14, 0.08, -0.05), "rankle": Vector3(0.14, 0.08, 0.06)},
	&"dazed_b": {"pos": Vector3(-0.04, -0.13, 0.0), "hips": Vector3(0, 0, 5), "spine": Vector3(-24, 0, 6), "chest": Vector3(-12, 0, 4), "head": Vector3(-20, -10, 10),
		"lfist": Vector3(-0.22, 0.70, -0.10), "lelbow": Vector3(-0.5, -0.3, 0.8),
		"rfist": Vector3(0.28, 0.76, -0.14), "relbow": Vector3(0.5, -0.3, 0.8),
		"lankle": Vector3(-0.14, 0.08, -0.05), "rankle": Vector3(0.14, 0.08, 0.06)},
	# Grabber holds (limb grabs).
	&"headlock": {"pos": Vector3(0, -0.10, -0.02), "hips": Vector3(0, -25, 0), "spine": Vector3(-16, 0, 0), "chest": Vector3(-6, -10, 0), "head": Vector3(12, 30, 0),
		"rfist": Vector3(-0.12, 1.22, -0.30), "relbow": Vector3(1, 0.1, -0.2),
		"lfist": Vector3(-0.02, 1.14, -0.50), "lelbow": Vector3(-0.6, -1, 0.2),
		"lankle": Vector3(-0.16, 0.08, -0.20), "rankle": Vector3(0.18, 0.08, 0.18)},
	&"arm_drag": {"pos": Vector3(0, -0.14, 0.10), "spine": Vector3(16, 0, 0), "chest": Vector3(6, 0, 0), "head": Vector3(-10, 0, 0),
		"lfist": Vector3(-0.08, 1.06, -0.34), "lelbow": Vector3(-0.6, -1, 0.2),
		"rfist": Vector3(0.10, 1.04, -0.34), "relbow": Vector3(0.6, -1, 0.2),
		"lankle": Vector3(-0.22, 0.08, -0.14), "rankle": Vector3(0.22, 0.08, 0.20)},
	&"giant_swing": {"pos": Vector3(0, -0.16, 0.14), "spine": Vector3(24, 0, 0), "chest": Vector3(10, 0, 0), "head": Vector3(-16, 0, 0),
		"lfist": Vector3(-0.10, 1.0, -0.28), "lelbow": Vector3(-0.5, -1, 0.2),
		"rfist": Vector3(0.10, 1.0, -0.28), "relbow": Vector3(0.5, -1, 0.2),
		"lankle": Vector3(-0.20, 0.08, -0.10), "rankle": Vector3(0.20, 0.08, 0.18), "lfp": 10.0, "rfp": 10.0},
	# --- Upgrade 2: charge holds (frozen deep wind-ups, readable from behind) ---------
	&"jab1_charge": {"pos": Vector3(0, -0.11, 0.04), "hips": Vector3(0, 5, 0), "spine": Vector3(-4, 0, 0), "chest": Vector3(0, 16, 0), "head": Vector3(4, -20, 0),
		"lfist": Vector3(-0.32, 1.42, 0.10), "lelbow": Vector3(-0.7, -0.5, 0.8),
		"rfist": Vector3(0.10, 1.46, -0.30), "relbow": Vector3(0.5, -1, 0.3)},
	&"cross_charge": {"pos": Vector3(0, -0.12, 0.05), "hips": Vector3(0, -32, 0), "spine": Vector3(2, 0, 0), "chest": Vector3(0, -28, 0), "head": Vector3(2, 55, 0),
		"lfist": Vector3(-0.08, 1.44, -0.44), "lelbow": Vector3(-0.5, -1, 0.0),
		"rfist": Vector3(0.30, 1.40, 0.18), "relbow": Vector3(0.7, -0.5, 1)},
	&"hook_charge": {"pos": Vector3(0, -0.12, 0.02), "hips": Vector3(0, 12, 0), "spine": Vector3(-6, 0, 0), "chest": Vector3(-4, 30, 0), "head": Vector3(6, -35, 0),
		"lfist": Vector3(-0.52, 1.44, 0.02), "lelbow": Vector3(-1, 0.3, 0.4),
		"rfist": Vector3(0.10, 1.47, -0.20), "relbow": Vector3(0.5, -1, 0.4)},
	&"uppercut_charge": {"pos": Vector3(0, -0.30, 0.02), "hips": Vector3(0, -20, 0), "spine": Vector3(-24, 0, 0), "chest": Vector3(-6, -22, 10), "head": Vector3(26, 30, 0),
		"rfist": Vector3(0.26, 0.88, -0.02), "relbow": Vector3(0.4, -1, 0.6),
		"lfist": Vector3(-0.10, 1.22, -0.32), "lelbow": Vector3(-0.5, -1, 0.2),
		"lankle": Vector3(-0.18, 0.08, -0.22), "rankle": Vector3(0.20, 0.08, 0.18)},
	&"sparta_kick_charge": {"pos": Vector3(0, -0.04, 0.10), "hips": Vector3(12, 0, 0), "spine": Vector3(10, 0, 0), "chest": Vector3(4, 0, 0), "head": Vector3(-20, 0, 0),
		"lfist": Vector3(-0.24, 1.42, -0.30), "lelbow": Vector3(-0.6, -1, 0.2),
		"rfist": Vector3(0.24, 1.38, -0.24), "relbow": Vector3(0.6, -1, 0.2),
		"rankle": Vector3(0.12, 0.74, -0.06), "rknee": Vector3(0, 0.7, -1), "rfp": 30.0},
	&"roundhouse_charge": {"frame": &"body", "pos": Vector3(0, -0.06, 0.04), "hips": Vector3(0, 35, 0), "spine": Vector3(4, 0, 14), "chest": Vector3(2, 0, 6), "head": Vector3(-6, -40, -10),
		"lfist": Vector3(-0.30, 1.42, -0.28), "lelbow": Vector3(-0.6, -1, 0.2),
		"rfist": Vector3(0.10, 1.36, -0.30), "relbow": Vector3(0.6, -1, 0.2),
		"rankle": Vector3(0.40, 0.82, 0.12), "rknee": Vector3(1, 0.4, -0.4), "rfp": -30.0},
	&"leg_sweep_charge": {"frame": &"body", "pos": Vector3(0, -0.56, 0.0), "hips": Vector3(-12, -70, 0), "spine": Vector3(-30, 0, 0), "chest": Vector3(-10, 0, 0), "head": Vector3(28, 45, 0),
		"lfist": Vector3(-0.34, 0.10, -0.28), "lelbow": Vector3(-1, 0, 0.3),
		"rfist": Vector3(0.18, 0.70, -0.32), "relbow": Vector3(0.5, -1, 0.3),
		"lankle": Vector3(-0.20, 0.08, -0.02), "lknee": Vector3(-0.4, 0.2, -1),
		"rankle": Vector3(0.84, 0.07, 0.16), "rknee": Vector3(0, 1, 0), "rfp": 0.0},
	&"crouch_punch_charge": {"pos": Vector3(0, -0.52, 0.04), "hips": Vector3(-16, -18, 0), "spine": Vector3(-14, 0, 0), "chest": Vector3(-8, -30, 0), "head": Vector3(38, 40, 0),
		"rfist": Vector3(0.26, 0.80, 0.10), "relbow": Vector3(0.6, -0.6, 0.8),
		"lfist": Vector3(-0.10, 0.98, -0.32), "lelbow": Vector3(-0.5, -1, 0.2),
		"lankle": Vector3(-0.18, 0.08, -0.20), "lknee": Vector3(-0.4, 0, -1),
		"rankle": Vector3(0.18, 0.08, 0.18), "rknee": Vector3(0.4, 0, -1)},
	&"flying_kick_charge": {"pos": Vector3(0, 0.02, 0.02), "spine": Vector3(-10, 0, 0), "chest": Vector3(-6, 0, 0), "head": Vector3(14, 0, 0),
		"lfist": Vector3(-0.30, 1.30, -0.30), "lelbow": Vector3(-1, -0.3, 0.2),
		"rfist": Vector3(0.30, 1.30, -0.30), "relbow": Vector3(1, -0.3, 0.2),
		"lankle": Vector3(-0.12, 0.50, -0.05), "lknee": Vector3(-0.1, 0.4, -1), "lfp": -20.0,
		"rankle": Vector3(0.12, 0.55, -0.02), "rknee": Vector3(0.1, 0.5, -1), "rfp": 10.0},
	&"hammer_fist_charge": {"spine": Vector3(16, 0, 0), "chest": Vector3(10, 0, 0), "head": Vector3(-12, 0, 0),
		"lfist": Vector3(-0.08, 2.10, 0.16), "lelbow": Vector3(-1, 0.5, 0.1),
		"rfist": Vector3(0.08, 2.10, 0.16), "relbow": Vector3(1, 0.5, 0.1),
		"lankle": Vector3(-0.12, 0.38, 0.08), "rankle": Vector3(0.12, 0.34, 0.10), "lfp": -30.0, "rfp": -30.0},
	&"backfist_charge": {"frame": &"body", "pos": Vector3(0, -0.10, 0.0), "hips": Vector3(0, -20, 0), "spine": Vector3(-6, 0, 0), "chest": Vector3(-4, 42, 0), "head": Vector3(0, -75, 0),
		"rfist": Vector3(-0.24, 1.40, -0.20), "relbow": Vector3(1, -0.2, -0.4),
		"lfist": Vector3(-0.30, 1.30, 0.05), "lelbow": Vector3(-0.6, -1, 0.4)},
	## Pinned against a wall: limbs splayed flat (muscle target, see
	## RagdollController.set_flight_pose).
	&"wall_splat": {"spine": Vector3(6, 0, 0), "chest": Vector3(4, 0, 0), "head": Vector3(10, 0, 0),
		"lua": Vector3(-10, 0, -100), "lla": Vector3(30, 0, 0), "rua": Vector3(-10, 0, 100), "rla": Vector3(30, 0, 0),
		"lul": Vector3(0, 0, -25), "lll": Vector3(-20, 0, 0), "lf": Vector3(-30, 0, 0),
		"rul": Vector3(0, 0, 25), "rll": Vector3(-20, 0, 0), "rf": Vector3(-30, 0, 0)},
	## NASA microgravity neutral body posture: knees and hips bent, shoulders
	## forward and out, elbows bent, feet relaxed. Neutral-tension target.
	&"neutral": {"spine": Vector3(-8, 0, 0), "chest": Vector3(-6, 0, 0), "head": Vector3(-15, 0, 0),
		"lua": Vector3(35, 0, -40), "lla": Vector3(55, 0, 0), "lh": Vector3(10, 0, 0),
		"rua": Vector3(35, 0, 40), "rla": Vector3(55, 0, 0), "rh": Vector3(10, 0, 0),
		"lul": Vector3(40, 0, -12), "lll": Vector3(-50, 0, 0), "lf": Vector3(-25, 0, 0),
		"rul": Vector3(40, 0, 12), "rll": Vector3(-50, 0, 0), "rf": Vector3(-25, 0, 0)},
	# =========================================================================
	# Round 5 (Feel Reference: "New animations needed"). Agent P.
	# =========================================================================
	# --- Carry and locomotion overlays -------------------------------------------
	## Carry overlay: the right hand holds the body by the collar in front of the
	## chest (Carry pins the victim there); the left arm is left to the
	## locomotion (guard standing, pumping when running).
	&"carry_hold": {"rfist": Vector3(0.17, 1.30, -0.40), "relbow": Vector3(0.9, -0.7, 0.2), "head": Vector3(4, -6, 0)},
	## Limp (lost the left arm): hunched, listing toward the stump, the right
	## hand clutching the left shoulder. Mirrored for a lost right arm.
	&"limp_hunch": {"spine": Vector3(-18, 0, 7), "chest": Vector3(-10, 6, 4), "head": Vector3(14, -4, -6),
		"rfist": Vector3(-0.13, 1.30, -0.12), "relbow": Vector3(0.6, -1, -0.4),
		"lfist": Vector3(-0.24, 1.0, -0.05), "lelbow": Vector3(-0.6, -1, 0.3)},
	# --- Player strikes (Feel Reference: Wind-up, contact, recovery) ---------------
	# Jab (lead hand, 5 frames): the hips start the turn, the lead foot steps in,
	# the lead shoulder rises over the chin, the rear hand stays on the jaw.
	&"jab_load": {"pos": Vector3(0, -0.07, -0.01), "hips": Vector3(0, -19, 0), "spine": Vector3(-6, -3, 0),
		"chest": Vector3(-5, -8, 0), "head": Vector3(6, 30, 0),
		"lfist": Vector3(-0.07, 1.44, -0.38), "lelbow": Vector3(-0.6, -1, 0.2), "rfist": Vector3(0.10, 1.47, -0.20), "relbow": Vector3(0.4, -1, 0.3),
		"lankle": Vector3(-0.12, 0.11, -0.21), "lfp": 8.0, "rankle": Vector3(0.14, 0.08, 0.15)},
	&"jab_hit": {"pos": Vector3(0, -0.08, -0.07), "hips": Vector3(0, -24, 0), "spine": Vector3(-7, -8, 0),
		"chest": Vector3(-5, -18, -5), "head": Vector3(6, 48, 4),
		"lfist": Vector3(-0.02, 1.48, -0.68), "lelbow": Vector3(-0.7, -0.8, 0.1), "rfist": Vector3(0.08, 1.49, -0.17), "relbow": Vector3(0.4, -1, 0.4),
		"lankle": Vector3(-0.13, 0.08, -0.29), "lknee": Vector3(-0.15, 0, -1), "rankle": Vector3(0.15, 0.09, 0.13), "rfp": -14.0},
	&"jab_reach": {"pos": Vector3(0, -0.08, -0.08), "hips": Vector3(0, -25, 0), "spine": Vector3(-7, -9, 0),
		"chest": Vector3(-5, -20, -5), "head": Vector3(6, 50, 4),
		"lfist": Vector3(-0.01, 1.48, -0.71), "lelbow": Vector3(-0.7, -0.8, 0.1), "rfist": Vector3(0.08, 1.49, -0.17), "relbow": Vector3(0.4, -1, 0.4),
		"lankle": Vector3(-0.13, 0.08, -0.29), "lknee": Vector3(-0.15, 0, -1), "rankle": Vector3(0.15, 0.09, 0.13), "rfp": -14.0},
	&"jab_snap": {"pos": Vector3(0, -0.07, -0.05), "hips": Vector3(0, -18, 0), "spine": Vector3(-6, -4, 0),
		"chest": Vector3(-5, -9, 0), "head": Vector3(6, 30, 0),
		"lfist": Vector3(-0.08, 1.47, -0.32), "lelbow": Vector3(-0.5, -1, 0.3), "rfist": Vector3(0.10, 1.47, -0.19), "relbow": Vector3(0.4, -1, 0.4),
		"lankle": Vector3(-0.13, 0.08, -0.25), "rankle": Vector3(0.14, 0.08, 0.14)},
	# Front kick (12 frames): chamber the knee high, snap the foot out at hip
	# height leaning back, hands stay up, the rear hand drops for balance.
	&"fkick_chamber": {"pos": Vector3(0, -0.03, 0.05), "hips": Vector3(6, -6, 0), "spine": Vector3(8, 0, 0),
		"chest": Vector3(4, -4, 0), "head": Vector3(-12, 8, 0),
		"lfist": Vector3(-0.10, 1.47, -0.30), "lelbow": Vector3(-0.5, -1, 0.3), "rfist": Vector3(0.18, 1.36, -0.12), "relbow": Vector3(0.6, -1, 0.3),
		"lankle": Vector3(-0.10, 0.08, -0.06), "lknee": Vector3(-0.1, 0, -1),
		"rankle": Vector3(0.11, 0.58, -0.12), "rknee": Vector3(0, 0.5, -1), "rfp": 20.0},
	&"fkick_chamber2": {"pos": Vector3(0, -0.03, 0.06), "hips": Vector3(9, -5, 0), "spine": Vector3(10, 0, 0),
		"chest": Vector3(4, -4, 0), "head": Vector3(-16, 8, 0),
		"lfist": Vector3(-0.11, 1.47, -0.30), "lelbow": Vector3(-0.5, -1, 0.3), "rfist": Vector3(0.22, 1.30, -0.06), "relbow": Vector3(0.6, -1, 0.3),
		"lankle": Vector3(-0.10, 0.08, -0.05), "lknee": Vector3(-0.1, 0, -1),
		"rankle": Vector3(0.11, 0.64, -0.14), "rknee": Vector3(0, 0.6, -1), "rfp": 20.0},
	&"fkick_hit": {"pos": Vector3(0, -0.04, -0.08), "hips": Vector3(14, -4, 0), "spine": Vector3(14, 0, 0),
		"chest": Vector3(6, -4, 0), "head": Vector3(-26, 6, 0),
		"lfist": Vector3(-0.16, 1.44, -0.26), "lelbow": Vector3(-0.6, -1, 0.3), "rfist": Vector3(0.32, 1.12, 0.08), "relbow": Vector3(0.8, -0.6, 0.4),
		"lankle": Vector3(-0.10, 0.08, -0.04), "lknee": Vector3(0, 0, -1), "lfp": -6.0,
		"rankle": Vector3(0.10, 0.95, -0.86), "rknee": Vector3(0, 1, 0), "rfp": 70.0},
	&"fkick_ext": {"pos": Vector3(0, -0.04, -0.10), "hips": Vector3(16, -4, 0), "spine": Vector3(15, 0, 0),
		"chest": Vector3(6, -4, 0), "head": Vector3(-28, 6, 0),
		"lfist": Vector3(-0.17, 1.43, -0.25), "lelbow": Vector3(-0.6, -1, 0.3), "rfist": Vector3(0.33, 1.10, 0.10), "relbow": Vector3(0.8, -0.6, 0.4),
		"lankle": Vector3(-0.10, 0.08, -0.04), "lknee": Vector3(0, 0, -1), "lfp": -8.0,
		"rankle": Vector3(0.10, 0.96, -0.90), "rknee": Vector3(0, 1, 0), "rfp": 70.0},
	&"fkick_follow": {"pos": Vector3(0, -0.05, -0.13), "hips": Vector3(18, -3, 0), "spine": Vector3(16, 0, 0),
		"chest": Vector3(6, -4, 0), "head": Vector3(-30, 6, 0),
		"lfist": Vector3(-0.18, 1.42, -0.24), "lelbow": Vector3(-0.6, -1, 0.3), "rfist": Vector3(0.34, 1.08, 0.12), "relbow": Vector3(0.8, -0.6, 0.4),
		"lankle": Vector3(-0.10, 0.08, -0.06), "lknee": Vector3(0, 0, -1), "lfp": -12.0,
		"rankle": Vector3(0.10, 0.90, -0.95), "rknee": Vector3(0, 1, 0), "rfp": 60.0},
	&"fkick_recoil": {"pos": Vector3(0, -0.04, 0.0), "hips": Vector3(6, -6, 0), "spine": Vector3(6, 0, 0), "head": Vector3(-8, 6, 0),
		"lfist": Vector3(-0.10, 1.46, -0.30), "lelbow": Vector3(-0.5, -1, 0.3), "rfist": Vector3(0.16, 1.38, -0.16), "relbow": Vector3(0.5, -1, 0.3),
		"lankle": Vector3(-0.10, 0.08, -0.08), "rankle": Vector3(0.12, 0.42, -0.22), "rknee": Vector3(0, 0.5, -1)},
	# Rear elbow (7 frames): fist by the ear, the hips whip the folded arm across.
	&"elbow_cock": {"pos": Vector3(0, -0.08, 0.02), "hips": Vector3(0, -24, 0), "spine": Vector3(-6, -8, 0),
		"chest": Vector3(-4, -16, 0), "head": Vector3(6, 45, 0),
		"rfist": Vector3(0.24, 1.62, -0.02), "relbow": Vector3(1, 0.1, 0.3), "lfist": Vector3(-0.08, 1.47, -0.32), "lelbow": Vector3(-0.5, -1, 0.3),
		"lankle": Vector3(-0.12, 0.08, -0.20), "rankle": Vector3(0.15, 0.08, 0.16)},
	&"elbow_hit": {"pos": Vector3(0, -0.09, -0.07), "hips": Vector3(0, 22, 0), "spine": Vector3(-8, 10, 0),
		"chest": Vector3(-4, 20, 0), "head": Vector3(6, -50, 0),
		"rfist": Vector3(-0.14, 1.56, -0.24), "relbow": Vector3(0.4, 0.4, -1), "lfist": Vector3(-0.12, 1.44, -0.14), "lelbow": Vector3(-0.5, -1, 0.4),
		"lankle": Vector3(-0.13, 0.08, -0.25), "rankle": Vector3(0.15, 0.12, 0.12), "rfp": -30.0},
	&"elbow_follow": {"pos": Vector3(0, -0.10, -0.09), "hips": Vector3(0, 30, 0), "spine": Vector3(-9, 12, 0),
		"chest": Vector3(-4, 26, 0), "head": Vector3(6, -62, 0),
		"rfist": Vector3(-0.24, 1.52, -0.12), "relbow": Vector3(0.2, 0.4, -1), "lfist": Vector3(-0.13, 1.42, -0.10), "lelbow": Vector3(-0.5, -1, 0.4),
		"lankle": Vector3(-0.13, 0.08, -0.25), "rankle": Vector3(0.15, 0.13, 0.12), "rfp": -35.0},
	# Ground strikes (a body on the floor in front): stomp and knee drop.
	&"gstomp_chamber": {"pos": Vector3(0, -0.02, 0.06), "hips": Vector3(4, 0, 0), "spine": Vector3(2, 0, 0), "head": Vector3(-24, 0, 0),
		"lfist": Vector3(-0.40, 1.30, -0.12), "lelbow": Vector3(-1, -0.4, 0.3), "rfist": Vector3(0.38, 1.26, -0.04), "relbow": Vector3(1, -0.4, 0.3),
		"lankle": Vector3(-0.12, 0.08, 0.04), "lknee": Vector3(-0.1, 0, -1),
		"rankle": Vector3(0.12, 0.78, -0.28), "rknee": Vector3(0, 0.7, -1), "rfp": 10.0},
	&"gstomp_hit": {"pos": Vector3(0, -0.14, -0.10), "hips": Vector3(-6, 0, 0), "spine": Vector3(-16, 0, 0),
		"chest": Vector3(-8, 0, 0), "head": Vector3(-18, 0, 0),
		"lfist": Vector3(-0.40, 1.08, -0.10), "lelbow": Vector3(-1, -0.4, 0.3), "rfist": Vector3(0.36, 1.02, -0.02), "relbow": Vector3(1, -0.4, 0.3),
		"lankle": Vector3(-0.12, 0.08, 0.08), "lknee": Vector3(-0.1, 0, -1),
		"rankle": Vector3(0.10, 0.16, -0.52), "rknee": Vector3(0, 0.3, -1), "rfp": 0.0},
	&"gstomp_lift": {"pos": Vector3(0, -0.10, -0.06), "hips": Vector3(-2, 0, 0), "spine": Vector3(-10, 0, 0), "head": Vector3(-14, 0, 0),
		"lfist": Vector3(-0.30, 1.20, -0.20), "lelbow": Vector3(-1, -0.4, 0.3), "rfist": Vector3(0.30, 1.18, -0.12), "relbow": Vector3(1, -0.4, 0.3),
		"lankle": Vector3(-0.12, 0.08, 0.06), "rankle": Vector3(0.12, 0.34, -0.30), "rknee": Vector3(0, 0.5, -1)},
	&"kdrop_rise": {"pos": Vector3(0, -0.04, 0.0), "spine": Vector3(4, 0, 0), "head": Vector3(-10, 0, 0),
		"lfist": Vector3(-0.30, 1.60, -0.10), "lelbow": Vector3(-1, -0.2, 0.3), "rfist": Vector3(0.30, 1.66, 0.04), "relbow": Vector3(1, 0, 0.3),
		"lankle": Vector3(-0.12, 0.12, -0.06), "lfp": -20.0, "rankle": Vector3(0.12, 0.40, 0.10), "rknee": Vector3(0, 0.4, -1), "rfp": -30.0},
	&"kdrop_hit": {"pos": Vector3(0, -0.33, -0.08), "hips": Vector3(-12, 0, 0), "spine": Vector3(-14, 0, 0),
		"chest": Vector3(-6, 0, 0), "head": Vector3(-14, 0, 0),
		"lfist": Vector3(-0.20, 0.44, -0.45), "lelbow": Vector3(-1, 0, 0.3), "rfist": Vector3(0.24, 1.30, -0.18), "relbow": Vector3(1, 0.3, 0.3),
		"lankle": Vector3(-0.20, 0.08, -0.22), "lknee": Vector3(-0.2, 0.5, -1),
		"rankle": Vector3(0.13, 0.12, 0.10), "rknee": Vector3(0, -0.6, -1), "rfp": -45.0},
	# Dropping strike from the air (vault drop, jump attack): a superman punch.
	&"dstrike_cock": {"pos": Vector3(0, 0.02, 0.04), "hips": Vector3(-10, -15, 0), "spine": Vector3(-6, -6, 0),
		"chest": Vector3(-4, -14, 0), "head": Vector3(14, 35, 0),
		"rfist": Vector3(0.30, 1.40, 0.18), "relbow": Vector3(0.8, 0.2, 1), "lfist": Vector3(-0.18, 1.42, -0.42), "lelbow": Vector3(-0.6, -1, 0.2),
		"lankle": Vector3(-0.10, 0.50, -0.06), "lknee": Vector3(-0.1, 0.4, -1), "lfp": -20.0,
		"rankle": Vector3(0.12, 0.38, 0.22), "rknee": Vector3(0.1, 0, -1), "rfp": -40.0},
	&"dstrike_hit": {"pos": Vector3(0, -0.04, -0.12), "hips": Vector3(-28, 14, 0), "spine": Vector3(-14, 8, 0),
		"chest": Vector3(-8, 20, 0), "head": Vector3(30, -40, 0),
		"rfist": Vector3(0.04, 1.08, -0.84), "relbow": Vector3(0.7, 0.3, 0.6), "lfist": Vector3(-0.28, 1.20, 0.20), "lelbow": Vector3(-0.6, -0.6, 0.8),
		"lankle": Vector3(-0.12, 0.40, 0.42), "lknee": Vector3(-0.1, -0.4, -1), "lfp": -45.0,
		"rankle": Vector3(0.12, 0.25, 0.30), "rknee": Vector3(0.1, -0.2, -1), "rfp": -50.0},
	# Ground slam (an air attack from 2 m+): fists overhead, then both into the floor.
	&"slam_cock": {"pos": Vector3(0, 0.02, 0.04), "spine": Vector3(14, 0, 0), "chest": Vector3(8, 0, 0), "head": Vector3(-10, 0, 0),
		"lfist": Vector3(-0.12, 2.0, 0.10), "lelbow": Vector3(-1, 0.5, 0.1), "rfist": Vector3(0.12, 2.0, 0.10), "relbow": Vector3(1, 0.5, 0.1),
		"lankle": Vector3(-0.12, 0.42, 0.02), "lknee": Vector3(-0.1, 0.4, -1), "lfp": -30.0,
		"rankle": Vector3(0.12, 0.38, 0.08), "rknee": Vector3(0.1, 0.4, -1), "rfp": -30.0},
	&"slam_hit": {"pos": Vector3(0, -0.52, -0.04), "hips": Vector3(-18, 0, 0), "spine": Vector3(-26, 0, 0),
		"chest": Vector3(-12, 0, 0), "head": Vector3(30, 0, 0),
		"lfist": Vector3(-0.16, 0.12, -0.48), "lelbow": Vector3(-1, 0, 0.3), "rfist": Vector3(0.16, 0.12, -0.48), "relbow": Vector3(1, 0, 0.3),
		"lankle": Vector3(-0.20, 0.08, -0.10), "lknee": Vector3(-0.4, 0.2, -1), "lfp": 10.0,
		"rankle": Vector3(0.20, 0.08, 0.14), "rknee": Vector3(0.4, 0.2, -1), "rfp": -20.0},
	&"slam_rise": {"pos": Vector3(0, -0.30, 0.0), "hips": Vector3(-10, 0, 0), "spine": Vector3(-16, 0, 0),
		"chest": Vector3(-8, 0, 0), "head": Vector3(22, 0, 0),
		"lfist": Vector3(-0.30, 0.95, -0.30), "lelbow": Vector3(-1, -0.4, 0.3), "rfist": Vector3(0.30, 0.95, -0.28), "relbow": Vector3(1, -0.4, 0.3),
		"lankle": Vector3(-0.18, 0.08, -0.10), "rankle": Vector3(0.18, 0.08, 0.12)},
	# Charge holds (frozen deep wind-ups; PoseAnimator trembles and coils them per level).
	&"jab_charge": {"pos": Vector3(0, -0.11, 0.05), "hips": Vector3(0, -28, 0), "spine": Vector3(-4, -8, 0),
		"chest": Vector3(-2, -16, 0), "head": Vector3(4, 50, 0),
		"lfist": Vector3(-0.22, 1.44, 0.0), "lelbow": Vector3(-0.7, -1, 0.5), "rfist": Vector3(0.09, 1.48, -0.18), "relbow": Vector3(0.4, -1, 0.4),
		"lankle": Vector3(-0.12, 0.08, -0.18), "rankle": Vector3(0.15, 0.08, 0.20)},
	&"kick_charge": {"pos": Vector3(0, -0.04, 0.08), "hips": Vector3(10, -6, 0), "spine": Vector3(10, 0, 0),
		"chest": Vector3(4, -4, 0), "head": Vector3(-18, 8, 0),
		"lfist": Vector3(-0.12, 1.46, -0.30), "lelbow": Vector3(-0.5, -1, 0.3), "rfist": Vector3(0.24, 1.30, -0.06), "relbow": Vector3(0.6, -1, 0.3),
		"lankle": Vector3(-0.10, 0.08, -0.04), "lknee": Vector3(-0.1, 0, -1),
		"rankle": Vector3(0.11, 0.68, -0.08), "rknee": Vector3(0, 0.6, -1), "rfp": 20.0},
	# --- Movement (Movement spec) ---------------------------------------------------
	# Sprint start: the first drive out, deep lean, arms punching; legs come from
	# the sprint cycle underneath.
	&"sstart_a": {"pos": Vector3(0, -0.12, 0.02), "hips": Vector3(-20, 0, 0), "spine": Vector3(-12, 0, 0),
		"chest": Vector3(-6, 0, 0), "head": Vector3(30, 0, 0),
		"lua": Vector3(68, 0, -8), "lla": Vector3(100, 0, 0), "lh": Vector3(0, 0, 0),
		"rua": Vector3(-42, 0, 10), "rla": Vector3(60, 0, 0), "rh": Vector3(0, 0, 0)},
	&"sstart_b": {"pos": Vector3(0, -0.09, 0.0), "hips": Vector3(-15, 0, 0), "spine": Vector3(-10, 0, 0),
		"chest": Vector3(-5, 0, 0), "head": Vector3(26, 0, 0),
		"lua": Vector3(-36, 0, -10), "lla": Vector3(70, 0, 0), "lh": Vector3(0, 0, 0),
		"rua": Vector3(62, 0, 8), "rla": Vector3(100, 0, 0), "rh": Vector3(0, 0, 0)},
	# Speed vault (capsule-relative; Traversal carries the capsule over): the
	# left hand plants on top, the hips roll over it, the legs swing out right.
	&"vault_plant": {"pos": Vector3(0, -0.10, 0.0), "hips": Vector3(-18, 10, 8), "spine": Vector3(-14, 0, 8),
		"chest": Vector3(-6, 0, 4), "head": Vector3(24, -10, 0),
		"lfist": Vector3(-0.26, 0.62, -0.42), "lelbow": Vector3(-0.5, 0.2, 1), "rfist": Vector3(0.40, 1.10, -0.20), "relbow": Vector3(1, -0.3, 0.3),
		"lankle": Vector3(-0.08, 0.42, 0.12), "lknee": Vector3(-0.1, 0.3, -1), "lfp": -30.0,
		"rankle": Vector3(0.10, 0.30, 0.25), "rknee": Vector3(0.1, 0, -1), "rfp": -40.0},
	&"vault_over": {"pos": Vector3(0, -0.30, 0.0), "hips": Vector3(-20, 20, 34), "spine": Vector3(-10, 0, 12),
		"chest": Vector3(-6, 0, 8), "head": Vector3(16, -20, -20),
		"lfist": Vector3(-0.38, 0.40, -0.10), "lelbow": Vector3(-0.4, 0.3, 1), "rfist": Vector3(0.40, 1.0, -0.12), "relbow": Vector3(1, -0.2, 0.3),
		"lankle": Vector3(0.40, 0.48, -0.30), "lknee": Vector3(0.3, 0.8, -1), "lfp": 0.0,
		"rankle": Vector3(0.52, 0.52, -0.10), "rknee": Vector3(0.4, 0.8, -1), "rfp": 0.0},
	&"vault_land": {"pos": Vector3(0, -0.16, -0.02), "hips": Vector3(-8, 4, 4), "spine": Vector3(-12, 0, 4),
		"chest": Vector3(-6, 0, 0), "head": Vector3(18, -4, 0),
		"lfist": Vector3(-0.40, 1.10, -0.30), "lelbow": Vector3(-1, -0.4, 0.2), "rfist": Vector3(0.38, 1.15, -0.10), "relbow": Vector3(1, -0.4, 0.3),
		"lankle": Vector3(-0.10, 0.14, -0.30), "lknee": Vector3(-0.1, 0.2, -1), "lfp": 10.0,
		"rankle": Vector3(0.14, 0.24, 0.16), "rknee": Vector3(0.1, 0, -1), "rfp": -30.0},
	# Mantle (sprinting into 1.2-2.2 m): a foot on the wall, hands on the ledge,
	# press, a knee up onto it, stand.
	&"mantle_foot": {"pos": Vector3(0, -0.04, 0.0), "hips": Vector3(-6, 0, 0), "spine": Vector3(-6, 0, 0),
		"chest": Vector3(-2, 0, 0), "head": Vector3(30, 0, 0),
		"lfist": Vector3(-0.20, 2.0, -0.36), "lelbow": Vector3(-1, 0.2, 0.4), "rfist": Vector3(0.20, 2.0, -0.36), "relbow": Vector3(1, 0.2, 0.4),
		"lankle": Vector3(-0.12, 0.10, 0.10), "lknee": Vector3(-0.1, 0, -1), "lfp": -40.0,
		"rankle": Vector3(0.10, 0.72, -0.40), "rknee": Vector3(0, 0.6, -1), "rfp": 20.0},
	&"mantle_hands": {"pos": Vector3(0, -0.10, 0.06), "hips": Vector3(-10, 0, 0), "spine": Vector3(-12, 0, 0),
		"chest": Vector3(-6, 0, 0), "head": Vector3(24, 0, 0),
		"lfist": Vector3(-0.20, 1.58, -0.34), "lelbow": Vector3(-0.8, 0, 0.6), "rfist": Vector3(0.20, 1.58, -0.34), "relbow": Vector3(0.8, 0, 0.6),
		"lankle": Vector3(-0.10, 0.50, -0.18), "lknee": Vector3(-0.1, 0.5, -1), "lfp": 10.0,
		"rankle": Vector3(0.10, 0.40, -0.36), "rknee": Vector3(0, 0.6, -1), "rfp": 30.0},
	&"mantle_press": {"pos": Vector3(0, -0.26, -0.06), "hips": Vector3(-28, 0, 0), "spine": Vector3(-18, 0, 0),
		"chest": Vector3(-8, 0, 0), "head": Vector3(30, 0, 0),
		"lfist": Vector3(-0.22, 0.90, -0.30), "lelbow": Vector3(-0.6, 0.4, 1), "rfist": Vector3(0.22, 0.90, -0.30), "relbow": Vector3(0.6, 0.4, 1),
		"lankle": Vector3(-0.12, 0.30, 0.20), "lknee": Vector3(-0.1, -0.4, -1), "lfp": -30.0,
		"rankle": Vector3(0.12, 0.42, -0.28), "rknee": Vector3(0.1, 0.6, -1), "rfp": 0.0},
	&"mantle_rise": {"pos": Vector3(0, -0.28, -0.04), "hips": Vector3(-14, 0, 0), "spine": Vector3(-14, 0, 0),
		"chest": Vector3(-6, 0, 0), "head": Vector3(20, 0, 0),
		"lfist": Vector3(-0.30, 1.0, -0.30), "lelbow": Vector3(-1, -0.4, 0.3), "rfist": Vector3(0.30, 1.0, -0.28), "relbow": Vector3(1, -0.4, 0.3),
		"lankle": Vector3(-0.14, 0.08, -0.02), "lknee": Vector3(-0.2, 0.2, -1), "rankle": Vector3(0.14, 0.08, -0.20), "rknee": Vector3(0.2, 0.3, -1)},
	# Wall kick-off (over 2.2 m at full speed): plant a foot high on the wall,
	# compress, drive off it with the arms swinging up.
	&"kickoff_plant": {"pos": Vector3(0, -0.12, 0.08), "hips": Vector3(8, 0, 0), "spine": Vector3(8, 0, 0),
		"chest": Vector3(4, 0, 0), "head": Vector3(-6, 0, 0),
		"lfist": Vector3(-0.36, 1.30, 0.16), "lelbow": Vector3(-1, -0.3, 0.3), "rfist": Vector3(0.36, 1.30, 0.16), "relbow": Vector3(1, -0.3, 0.3),
		"lankle": Vector3(-0.12, 0.32, 0.18), "lknee": Vector3(-0.1, 0, -1), "lfp": -30.0,
		"rankle": Vector3(0.10, 0.70, -0.42), "rknee": Vector3(0, 0.6, -1), "rfp": 30.0},
	&"kickoff_push": {"pos": Vector3(0, 0.02, -0.02), "hips": Vector3(-4, 0, 0), "spine": Vector3(-6, 0, 0), "head": Vector3(10, 0, 0),
		"lfist": Vector3(-0.26, 1.75, -0.30), "lelbow": Vector3(-1, 0, 0.2), "rfist": Vector3(0.26, 1.75, -0.30), "relbow": Vector3(1, 0, 0.2),
		"lankle": Vector3(-0.12, 0.45, -0.10), "lknee": Vector3(-0.1, 0.4, -1), "lfp": -20.0,
		"rankle": Vector3(0.12, 0.40, 0.30), "rknee": Vector3(0.1, 0, -1), "rfp": -50.0},
	# Landings (Landing has levels): crouch (hard), three-point (heavy), roll.
	&"land_crouch": {"pos": Vector3(0, -0.26, 0.02), "hips": Vector3(-8, 0, 0), "spine": Vector3(-14, 0, 0),
		"chest": Vector3(-6, 0, 0), "head": Vector3(18, 0, 0),
		"lfist": Vector3(-0.36, 1.10, -0.30), "lelbow": Vector3(-1, -0.5, 0.3), "rfist": Vector3(0.36, 1.10, -0.26), "relbow": Vector3(1, -0.5, 0.3),
		"lankle": Vector3(-0.15, 0.08, -0.08), "rankle": Vector3(0.15, 0.08, 0.10)},
	&"land_3pt": {"pos": Vector3(0, -0.50, 0.04), "hips": Vector3(-18, -12, 0), "spine": Vector3(-28, -4, 0),
		"chest": Vector3(-14, -4, 0), "head": Vector3(40, 10, 0),
		"rfist": Vector3(0.20, 0.16, -0.42), "relbow": Vector3(1, 0.2, 0.3), "lfist": Vector3(-0.50, 0.85, 0.12), "lelbow": Vector3(-1, 0, -0.3),
		"lankle": Vector3(-0.20, 0.08, -0.24), "lknee": Vector3(-0.3, 0.4, -1), "lfp": 5.0,
		"rankle": Vector3(0.18, 0.10, 0.40), "rknee": Vector3(0.1, -0.6, -1), "rfp": -45.0},
	&"land_3pt_rise": {"pos": Vector3(0, -0.28, 0.02), "hips": Vector3(-8, -12, 0), "spine": Vector3(-16, -4, 0),
		"chest": Vector3(-8, -4, 0), "head": Vector3(26, 12, 0),
		"rfist": Vector3(0.22, 0.95, -0.30), "relbow": Vector3(1, -0.4, 0.3), "lfist": Vector3(-0.30, 1.15, -0.25), "lelbow": Vector3(-1, -0.4, 0.3),
		"lankle": Vector3(-0.18, 0.08, -0.22), "rankle": Vector3(0.18, 0.08, 0.20)},
	&"roll_tuck": {"pos": Vector3(0, -0.58, 0.14), "hips": Vector3(-40, 0, 0), "spine": Vector3(-26, 0, 0),
		"chest": Vector3(-18, 0, 0), "head": Vector3(-30, 0, 0),
		"lfist": Vector3(-0.20, 0.12, -0.52), "lelbow": Vector3(-1, 0, 0.4), "rfist": Vector3(0.20, 0.12, -0.52), "relbow": Vector3(1, 0, 0.4),
		"lankle": Vector3(-0.14, 0.08, -0.05), "lknee": Vector3(-0.2, 0.3, -1), "rankle": Vector3(0.14, 0.08, 0.08), "rknee": Vector3(0.2, 0.3, -1)},
	&"roll_a": {"pos": Vector3(0, -0.32, 0.15), "hips": Vector3(-130, 0, 0), "spine": Vector3(-24, 0, 0),
		"chest": Vector3(-18, 0, 0), "head": Vector3(-30, 0, 0),
		"lua": Vector3(110, 0, -25), "lla": Vector3(100, 0, 0), "rua": Vector3(110, 0, 25), "rla": Vector3(100, 0, 0),
		"lul": Vector3(115, 0, -8), "lll": Vector3(-135, 0, 0), "lf": Vector3(-25, 0, 0),
		"rul": Vector3(115, 0, 8), "rll": Vector3(-135, 0, 0), "rf": Vector3(-25, 0, 0)},
	&"roll_b": {"pos": Vector3(0, -0.30, -0.13), "hips": Vector3(-220, 0, 0), "spine": Vector3(-24, 0, 0),
		"chest": Vector3(-18, 0, 0), "head": Vector3(-30, 0, 0),
		"lua": Vector3(110, 0, -25), "lla": Vector3(100, 0, 0), "rua": Vector3(110, 0, 25), "rla": Vector3(100, 0, 0),
		"lul": Vector3(115, 0, -8), "lll": Vector3(-135, 0, 0), "lf": Vector3(-25, 0, 0),
		"rul": Vector3(115, 0, 8), "rll": Vector3(-135, 0, 0), "rf": Vector3(-25, 0, 0)},
	&"roll_c": {"pos": Vector3(0, -0.56, -0.12), "hips": Vector3(-305, 0, 0), "spine": Vector3(-20, 0, 0),
		"chest": Vector3(-14, 0, 0), "head": Vector3(-20, 0, 0),
		"lua": Vector3(70, 0, -20), "lla": Vector3(70, 0, 0), "rua": Vector3(70, 0, 20), "rla": Vector3(70, 0, 0),
		"lul": Vector3(105, 0, -8), "lll": Vector3(-125, 0, 0), "lf": Vector3(-15, 0, 0),
		"rul": Vector3(105, 0, 8), "rll": Vector3(-125, 0, 0), "rf": Vector3(-15, 0, 0)},
	&"roll_up": {"pos": Vector3(0, -0.40, 0.0), "hips": Vector3(-14, 0, 0), "spine": Vector3(-18, 0, 0),
		"chest": Vector3(-8, 0, 0), "head": Vector3(22, 0, 0),
		"lfist": Vector3(-0.30, 0.95, -0.30), "lelbow": Vector3(-1, -0.4, 0.3), "rfist": Vector3(0.30, 0.95, -0.28), "relbow": Vector3(1, -0.4, 0.3),
		"lankle": Vector3(-0.14, 0.08, -0.10), "rankle": Vector3(0.14, 0.08, 0.10)},
	# --- Grab (Grab spec) ------------------------------------------------------------
	&"glunge_load": {"pos": Vector3(0, -0.12, 0.02), "hips": Vector3(-6, 0, 0), "spine": Vector3(-10, 0, 0),
		"chest": Vector3(-4, 0, 0), "head": Vector3(16, 0, 0),
		"lfist": Vector3(-0.40, 1.30, -0.30), "lelbow": Vector3(-0.7, -1, 0.4), "rfist": Vector3(0.40, 1.30, -0.30), "relbow": Vector3(0.7, -1, 0.4),
		"lankle": Vector3(-0.13, 0.08, -0.20), "rankle": Vector3(0.15, 0.08, 0.20), "rfp": -10.0},
	&"glunge_reach": {"pos": Vector3(0, -0.16, -0.18), "hips": Vector3(-14, 0, 0), "spine": Vector3(-14, 0, 0),
		"chest": Vector3(-6, 0, 0), "head": Vector3(28, 0, 0),
		"lfist": Vector3(-0.14, 1.24, -0.80), "lelbow": Vector3(-0.7, -0.8, 0.2), "rfist": Vector3(0.14, 1.24, -0.80), "relbow": Vector3(0.7, -0.8, 0.2),
		"lankle": Vector3(-0.14, 0.08, -0.48), "lknee": Vector3(-0.2, 0, -1), "rankle": Vector3(0.15, 0.14, 0.26), "rfp": -35.0},
	# Knee to a held body (Carry): the right arm stays on the body (overlay).
	&"hknee_cock": {"pos": Vector3(0, -0.06, 0.04), "spine": Vector3(4, 0, 0), "head": Vector3(-4, 0, 0),
		"lfist": Vector3(-0.04, 1.26, -0.40), "lelbow": Vector3(-1, -0.4, 0.2),
		"lankle": Vector3(-0.13, 0.08, -0.06), "rankle": Vector3(0.13, 0.26, 0.26), "rknee": Vector3(0.1, 0, -1), "rfp": -40.0},
	&"hknee_hit": {"pos": Vector3(0, -0.03, -0.08), "hips": Vector3(8, 0, 0), "spine": Vector3(-12, 0, 0),
		"chest": Vector3(-6, 0, 0), "head": Vector3(12, 0, 0),
		"lfist": Vector3(-0.04, 1.12, -0.38), "lelbow": Vector3(-1, -0.4, 0.2),
		"lankle": Vector3(-0.13, 0.08, -0.04), "lfp": -15.0, "rankle": Vector3(0.10, 0.66, -0.18), "rknee": Vector3(0, 0.8, -1), "rfp": -50.0},
	# Throw (two-handed heave, the body held on the right side) and its charge.
	&"throw_charge": {"pos": Vector3(0, -0.20, 0.08), "hips": Vector3(0, -38, 0), "spine": Vector3(-4, -16, 0),
		"chest": Vector3(-2, -24, 0), "head": Vector3(4, 66, 0),
		"lfist": Vector3(0.14, 1.24, -0.04), "lelbow": Vector3(-0.8, -1, 0.2), "rfist": Vector3(0.38, 1.20, 0.24), "relbow": Vector3(1, -0.6, 0.3),
		"lankle": Vector3(-0.16, 0.08, -0.22), "rankle": Vector3(0.20, 0.08, 0.26)},
	&"throw_follow": {"pos": Vector3(0, -0.13, -0.14), "hips": Vector3(0, 38, 0), "spine": Vector3(-14, 16, 0),
		"chest": Vector3(-8, 24, 0), "head": Vector3(12, -66, 0),
		"lfist": Vector3(-0.36, 1.18, -0.44), "lelbow": Vector3(-0.8, -0.6, 0.2), "rfist": Vector3(-0.05, 1.22, -0.62), "relbow": Vector3(0.8, -0.6, 0.2),
		"lankle": Vector3(-0.15, 0.08, -0.32), "rankle": Vector3(0.17, 0.14, 0.16), "rfp": -35.0},
	# Body slam (holding a body, attack in the air): lift it overhead, land on it.
	&"bslam_lift": {"pos": Vector3(0, 0.0, 0.04), "spine": Vector3(12, 0, 0), "chest": Vector3(8, 0, 0), "head": Vector3(-6, 0, 0),
		"lfist": Vector3(-0.14, 1.98, -0.12), "lelbow": Vector3(-1, 0.4, 0.2), "rfist": Vector3(0.14, 1.98, -0.12), "relbow": Vector3(1, 0.4, 0.2),
		"lankle": Vector3(-0.12, 0.40, 0.0), "lknee": Vector3(-0.1, 0.4, -1), "lfp": -30.0,
		"rankle": Vector3(0.12, 0.36, 0.06), "rknee": Vector3(0.1, 0.4, -1), "rfp": -30.0},
	&"bslam_hit": {"pos": Vector3(0, -0.46, -0.08), "hips": Vector3(-16, 0, 0), "spine": Vector3(-24, 0, 0),
		"chest": Vector3(-12, 0, 0), "head": Vector3(20, 0, 0),
		"lfist": Vector3(-0.18, 0.30, -0.62), "lelbow": Vector3(-1, 0, 0.3), "rfist": Vector3(0.18, 0.30, -0.62), "relbow": Vector3(1, 0, 0.3),
		"lankle": Vector3(-0.20, 0.08, -0.14), "lknee": Vector3(-0.4, 0.2, -1),
		"rankle": Vector3(0.20, 0.08, 0.16), "rknee": Vector3(0.4, 0.2, -1), "rfp": -15.0},
	# --- Defence (Parry, teleport) ---------------------------------------------------
	# Parry: the lead forearm snaps up in front of the face and sweeps the blow
	# outside; weight rocks back, the rear hand is already cocked to counter.
	&"parry_set": {"pos": Vector3(0, -0.08, 0.03), "hips": Vector3(0, -10, 0), "spine": Vector3(-4, 0, 0),
		"chest": Vector3(-2, 4, 0), "head": Vector3(2, 6, 0),
		"lfist": Vector3(-0.02, 1.62, -0.36), "lelbow": Vector3(-0.3, -1, -0.3), "rfist": Vector3(0.12, 1.46, -0.16), "relbow": Vector3(0.4, -1, 0.4),
		"lankle": Vector3(-0.12, 0.08, -0.15), "rankle": Vector3(0.15, 0.08, 0.18)},
	&"parry_deflect": {"pos": Vector3(0, -0.10, 0.06), "hips": Vector3(0, -22, 0), "spine": Vector3(2, -6, 0),
		"chest": Vector3(2, -10, 0), "head": Vector3(-2, 36, 0),
		"lfist": Vector3(-0.40, 1.62, -0.32), "lelbow": Vector3(-0.5, -1, 0.1), "rfist": Vector3(0.14, 1.46, -0.10), "relbow": Vector3(0.5, -1, 0.5),
		"lankle": Vector3(-0.12, 0.08, -0.12), "rankle": Vector3(0.16, 0.08, 0.22)},
	&"guard_push_hit": {"pos": Vector3(0, -0.14, 0.08), "hips": Vector3(6, -10, 0), "spine": Vector3(8, 0, 0),
		"chest": Vector3(4, 0, 0), "head": Vector3(-16, 10, 0),
		"lfist": Vector3(-0.08, 1.60, -0.14), "lelbow": Vector3(-0.2, -1, -0.4), "rfist": Vector3(0.08, 1.60, -0.14), "relbow": Vector3(0.2, -1, -0.4),
		"lankle": Vector3(-0.12, 0.10, -0.10), "lfp": 15.0, "rankle": Vector3(0.15, 0.08, 0.28), "rfp": -10.0},
	# Sidestep to the left (mirrored for the right): head off the line, a
	# lateral step, guard kept.
	&"sidestep_out": {"pos": Vector3(-0.30, -0.16, 0.02), "hips": Vector3(0, 6, 12), "spine": Vector3(-8, 0, 14),
		"chest": Vector3(-4, 4, 10), "head": Vector3(4, -6, -18),
		"lfist": Vector3(-0.40, 1.30, -0.22), "lelbow": Vector3(-0.6, -1, 0.3), "rfist": Vector3(-0.12, 1.36, -0.20), "relbow": Vector3(0.5, -1, 0.3),
		"lankle": Vector3(-0.48, 0.08, -0.04), "lknee": Vector3(-0.6, 0, -1), "rankle": Vector3(0.06, 0.11, 0.10), "rknee": Vector3(0.2, 0, -1), "rfp": -30.0},
	# Teleport: a low burst (the after-image keeps this pose), then arriving
	# behind the attacker low, rear fist cocked.
	&"vanish_burst": {"pos": Vector3(0, -0.30, -0.04), "hips": Vector3(-24, 0, 0), "spine": Vector3(-18, 0, 0),
		"chest": Vector3(-8, 0, 0), "head": Vector3(36, 0, 0),
		"lfist": Vector3(-0.34, 0.95, 0.24), "lelbow": Vector3(-0.4, 0.3, 1), "rfist": Vector3(0.34, 0.95, 0.24), "relbow": Vector3(0.4, 0.3, 1),
		"lankle": Vector3(-0.12, 0.08, -0.18), "lknee": Vector3(-0.2, 0.3, -1),
		"rankle": Vector3(0.15, 0.22, 0.42), "rknee": Vector3(0.1, -0.2, -1), "rfp": -45.0},
	&"appear_land": {"pos": Vector3(0, -0.32, 0.04), "hips": Vector3(-12, -20, 0), "spine": Vector3(-14, -6, 0),
		"chest": Vector3(-8, -10, 0), "head": Vector3(24, 30, 0),
		"lfist": Vector3(-0.20, 1.08, -0.42), "lelbow": Vector3(-0.6, -1, 0.2), "rfist": Vector3(0.26, 1.06, 0.02), "relbow": Vector3(0.8, -0.6, 0.6),
		"lankle": Vector3(-0.18, 0.08, -0.26), "lknee": Vector3(-0.3, 0.2, -1),
		"rankle": Vector3(0.20, 0.08, 0.24), "rknee": Vector3(0.3, 0.2, -1), "rfp": -25.0},
	&"appear_ready": {"pos": Vector3(0, -0.12, 0.02), "hips": Vector3(0, -24, 0), "spine": Vector3(-6, -6, 0),
		"chest": Vector3(-4, -14, 0), "head": Vector3(6, 44, 0),
		"lfist": Vector3(-0.06, 1.44, -0.40), "lelbow": Vector3(-0.5, -1, 0.2), "rfist": Vector3(0.20, 1.40, 0.02), "relbow": Vector3(0.7, -0.6, 0.8),
		"lankle": Vector3(-0.13, 0.08, -0.22), "rankle": Vector3(0.16, 0.08, 0.20)},
	# --- Reactions (stumble steps come from the locomotion; these are the body) ---
	&"stumble_back_a": {"pos": Vector3(0, -0.08, 0.06), "hips": Vector3(10, 0, 0), "spine": Vector3(12, 0, 0),
		"chest": Vector3(8, 0, 0), "head": Vector3(-26, 0, 0),
		"lfist": Vector3(-0.46, 1.30, -0.30), "lelbow": Vector3(-1, -0.4, 0.3), "rfist": Vector3(0.44, 1.36, -0.26), "relbow": Vector3(1, -0.4, 0.3)},
	&"stumble_back_b": {"pos": Vector3(0, -0.10, 0.06), "hips": Vector3(12, 0, 3), "spine": Vector3(14, 0, 4),
		"chest": Vector3(8, 0, 2), "head": Vector3(-22, 6, -6),
		"lfist": Vector3(-0.50, 1.56, -0.10), "lelbow": Vector3(-1, 0.2, 0.3), "rfist": Vector3(0.42, 1.18, -0.20), "relbow": Vector3(1, -0.6, 0.3)},
	&"stumble_fwd_a": {"pos": Vector3(0, -0.12, -0.04), "hips": Vector3(-12, 0, 0), "spine": Vector3(-16, 0, 0),
		"chest": Vector3(-8, 0, 0), "head": Vector3(34, 0, 0),
		"lfist": Vector3(-0.36, 1.00, -0.46), "lelbow": Vector3(-1, -0.4, 0.3), "rfist": Vector3(0.40, 1.10, -0.36), "relbow": Vector3(1, -0.4, 0.3)},
	&"stumble_fwd_b": {"pos": Vector3(0, -0.14, -0.05), "hips": Vector3(-14, 0, -3), "spine": Vector3(-18, 0, -4),
		"chest": Vector3(-8, 0, -2), "head": Vector3(36, -6, 6),
		"lfist": Vector3(-0.46, 1.20, -0.30), "lelbow": Vector3(-1, -0.4, 0.3), "rfist": Vector3(0.30, 0.92, -0.50), "relbow": Vector3(1, -0.4, 0.3)},
	&"stumble_side_a": {"pos": Vector3(-0.08, -0.10, 0.0), "hips": Vector3(0, 0, 10), "spine": Vector3(-4, 0, 14),
		"chest": Vector3(-2, 0, 8), "head": Vector3(6, 0, -26),
		"lfist": Vector3(-0.50, 1.05, -0.10), "lelbow": Vector3(-1, -0.6, 0.3), "rfist": Vector3(0.42, 1.58, -0.04), "relbow": Vector3(1, 0.2, 0.3)},
	&"stumble_side_b": {"pos": Vector3(-0.10, -0.12, 0.0), "hips": Vector3(0, 0, 12), "spine": Vector3(-4, 0, 16),
		"chest": Vector3(-2, 0, 8), "head": Vector3(6, 0, -28),
		"lfist": Vector3(-0.46, 0.95, -0.22), "lelbow": Vector3(-1, -0.6, 0.3), "rfist": Vector3(0.40, 1.50, 0.02), "relbow": Vector3(1, 0.2, 0.3)},
	# Fast get-up (the player, Running into enemies: 0.8 s on the ground).
	&"gfast_tuck": {"pos": Vector3(0, -0.80, 0.04), "hips": Vector3(75, 0, 0), "spine": Vector3(-10, 0, 0),
		"chest": Vector3(-8, 0, 0), "head": Vector3(-14, 0, 0),
		"lfist": Vector3(-0.30, 0.08, 0.05), "lelbow": Vector3(-0.3, 0.3, 1), "rfist": Vector3(0.30, 0.08, 0.05), "relbow": Vector3(0.3, 0.3, 1),
		"lankle": Vector3(-0.14, 0.08, -0.42), "lknee": Vector3(0, 1, -0.2), "rankle": Vector3(0.14, 0.08, -0.36), "rknee": Vector3(0, 1, -0.2)},
	&"gfast_rock": {"pos": Vector3(0, -0.62, 0.10), "hips": Vector3(40, 0, 0), "spine": Vector3(-30, 0, 0),
		"chest": Vector3(-18, 0, 0), "head": Vector3(14, 0, 0),
		"lfist": Vector3(-0.25, 0.60, -0.25), "lelbow": Vector3(-0.6, -1, 0.3), "rfist": Vector3(0.25, 0.60, -0.25), "relbow": Vector3(0.6, -1, 0.3),
		"lankle": Vector3(-0.14, 0.08, -0.30), "lknee": Vector3(0, 1, -0.4), "rankle": Vector3(0.14, 0.08, -0.22), "rknee": Vector3(0, 1, -0.4)},
	&"gfast_down_spring": {"pos": Vector3(0, -0.50, 0.06), "hips": Vector3(-60, 0, 0), "spine": Vector3(-10, 0, 0),
		"chest": Vector3(-6, 0, 0), "head": Vector3(40, 0, 0),
		"lfist": Vector3(-0.22, 0.08, -0.42), "lelbow": Vector3(-1, 0, 0.3), "rfist": Vector3(0.22, 0.08, -0.42), "relbow": Vector3(1, 0, 0.3),
		"lankle": Vector3(-0.15, 0.10, 0.02), "lknee": Vector3(0, -0.5, -1), "rankle": Vector3(0.15, 0.12, 0.12), "rknee": Vector3(0, -0.5, -1), "rfp": -30.0},
	&"gfast_crouch": {"pos": Vector3(0, -0.42, -0.04), "hips": Vector3(-16, -8, 0), "spine": Vector3(-20, 0, 0),
		"chest": Vector3(-8, -4, 0), "head": Vector3(26, 10, 0),
		"lfist": Vector3(-0.16, 1.05, -0.36), "lelbow": Vector3(-0.5, -1, 0.3), "rfist": Vector3(0.18, 1.02, -0.26), "relbow": Vector3(0.5, -1, 0.3),
		"lankle": Vector3(-0.15, 0.08, -0.14), "lknee": Vector3(-0.2, 0.3, -1), "rankle": Vector3(0.15, 0.08, 0.06), "rknee": Vector3(0.2, 0.3, -1)},
	# --- Enemies: tells cocked big enough to read across the arena ---------------
	&"e_jab_cock": {"pos": Vector3(0, -0.10, 0.06), "hips": Vector3(0, -26, 0), "spine": Vector3(2, -8, 0),
		"chest": Vector3(0, -16, 0), "head": Vector3(0, 48, 0),
		"lfist": Vector3(-0.30, 1.56, 0.02), "lelbow": Vector3(-1, 0.2, 0.6), "rfist": Vector3(0.10, 1.48, -0.16), "relbow": Vector3(0.4, -1, 0.3),
		"lankle": Vector3(-0.12, 0.14, -0.16), "lfp": 15.0, "rankle": Vector3(0.16, 0.08, 0.20)},
	&"e_jab_hit": {"pos": Vector3(0, -0.09, -0.08), "hips": Vector3(0, -24, 0), "spine": Vector3(-8, -8, 0),
		"chest": Vector3(-4, -18, -4), "head": Vector3(6, 48, 2),
		"lfist": Vector3(-0.02, 1.48, -0.72), "lelbow": Vector3(-0.7, -0.8, 0.1), "rfist": Vector3(0.08, 1.48, -0.16), "relbow": Vector3(0.4, -1, 0.4),
		"lankle": Vector3(-0.13, 0.08, -0.34), "lknee": Vector3(-0.15, 0, -1), "rankle": Vector3(0.15, 0.10, 0.12), "rfp": -15.0},
	&"e_jab_follow": {"pos": Vector3(0, -0.09, -0.07), "hips": Vector3(0, -22, 0), "spine": Vector3(-7, -7, 0),
		"chest": Vector3(-4, -14, -3), "head": Vector3(6, 42, 2),
		"lfist": Vector3(-0.06, 1.47, -0.56), "lelbow": Vector3(-0.6, -0.9, 0.2), "rfist": Vector3(0.08, 1.48, -0.16), "relbow": Vector3(0.4, -1, 0.4),
		"lankle": Vector3(-0.13, 0.08, -0.34), "rankle": Vector3(0.15, 0.10, 0.12), "rfp": -15.0},
	# Stick enemy (stick in the right hand): a big diagonal swing, a thrust.
	&"e_stick_cock": {"pos": Vector3(0, -0.10, 0.06), "hips": Vector3(0, -34, 0), "spine": Vector3(4, -10, 0),
		"chest": Vector3(2, -20, -4), "head": Vector3(0, 60, 0),
		"rfist": Vector3(0.34, 1.84, 0.18), "relbow": Vector3(1, 0.4, 0.6), "lfist": Vector3(-0.20, 1.36, -0.40), "lelbow": Vector3(-0.6, -1, 0.2),
		"lankle": Vector3(-0.14, 0.08, -0.24), "rankle": Vector3(0.18, 0.08, 0.20)},
	&"e_stick_hit": {"pos": Vector3(0, -0.12, -0.10), "hips": Vector3(0, 26, 0), "spine": Vector3(-12, 10, 0),
		"chest": Vector3(-6, 18, 4), "head": Vector3(10, -50, 0),
		"rfist": Vector3(-0.04, 1.34, -0.60), "relbow": Vector3(0.8, -0.2, 0.4), "lfist": Vector3(-0.24, 1.24, -0.16), "lelbow": Vector3(-0.6, -1, 0.3),
		"lankle": Vector3(-0.15, 0.08, -0.30), "rankle": Vector3(0.16, 0.12, 0.16), "rfp": -25.0},
	&"e_stick_follow": {"pos": Vector3(0, -0.13, -0.11), "hips": Vector3(0, 36, 0), "spine": Vector3(-14, 14, 0),
		"chest": Vector3(-6, 24, 4), "head": Vector3(12, -66, 0),
		"rfist": Vector3(-0.40, 1.02, -0.34), "relbow": Vector3(0.8, -0.4, 0.4), "lfist": Vector3(-0.20, 1.18, -0.04), "lelbow": Vector3(-0.6, -1, 0.3),
		"lankle": Vector3(-0.15, 0.08, -0.30), "rankle": Vector3(0.16, 0.13, 0.16), "rfp": -30.0},
	&"e_thrust_cock": {"pos": Vector3(0, -0.14, 0.08), "hips": Vector3(0, -36, 0), "spine": Vector3(-2, -10, 0),
		"chest": Vector3(0, -18, 0), "head": Vector3(2, 60, 0),
		"rfist": Vector3(0.30, 1.10, 0.26), "relbow": Vector3(0.8, -0.4, 1), "lfist": Vector3(0.0, 1.16, -0.30), "lelbow": Vector3(-0.8, -1, 0.2),
		"lankle": Vector3(-0.15, 0.08, -0.24), "rankle": Vector3(0.18, 0.08, 0.24)},
	&"e_thrust_hit": {"pos": Vector3(0, -0.16, -0.16), "hips": Vector3(0, -10, 0), "spine": Vector3(-12, 0, 0),
		"chest": Vector3(-6, -4, 0), "head": Vector3(14, 14, 0),
		"rfist": Vector3(0.06, 1.24, -0.74), "relbow": Vector3(0.6, -1, 0.2), "lfist": Vector3(-0.04, 1.22, -0.46), "lelbow": Vector3(-0.6, -1, 0.2),
		"lankle": Vector3(-0.15, 0.08, -0.44), "rankle": Vector3(0.17, 0.14, 0.20), "rfp": -30.0},
	# Heavy: grab and slam (arms wide and low like a wrestler, reach, lift, slam).
	&"e_gslam_cock": {"pos": Vector3(0, -0.22, 0.04), "hips": Vector3(-6, 0, 0), "spine": Vector3(-16, 0, 0),
		"chest": Vector3(-8, 0, 0), "head": Vector3(28, 0, 0),
		"lfist": Vector3(-0.66, 1.12, -0.28), "lelbow": Vector3(-0.4, -0.6, 1), "rfist": Vector3(0.66, 1.12, -0.28), "relbow": Vector3(0.4, -0.6, 1),
		"lankle": Vector3(-0.24, 0.08, -0.14), "lknee": Vector3(-0.4, 0, -1), "rankle": Vector3(0.24, 0.08, 0.16), "rknee": Vector3(0.4, 0, -1)},
	&"e_gslam_hit": {"pos": Vector3(0, -0.18, -0.16), "hips": Vector3(-10, 0, 0), "spine": Vector3(-18, 0, 0),
		"chest": Vector3(-8, 0, 0), "head": Vector3(26, 0, 0),
		"lfist": Vector3(-0.16, 1.16, -0.74), "lelbow": Vector3(-0.8, -0.6, 0.3), "rfist": Vector3(0.16, 1.16, -0.74), "relbow": Vector3(0.8, -0.6, 0.3),
		"lankle": Vector3(-0.20, 0.08, -0.44), "rankle": Vector3(0.22, 0.12, 0.22), "rfp": -25.0},
	&"e_gslam_lift": {"pos": Vector3(0, -0.04, 0.06), "spine": Vector3(14, 0, 0), "chest": Vector3(8, 0, 0), "head": Vector3(-10, 0, 0),
		"lfist": Vector3(-0.16, 1.92, -0.20), "lelbow": Vector3(-1, 0.4, 0.2), "rfist": Vector3(0.16, 1.92, -0.20), "relbow": Vector3(1, 0.4, 0.2),
		"lankle": Vector3(-0.20, 0.08, -0.12), "rankle": Vector3(0.20, 0.08, 0.14)},
	&"e_gslam_down": {"pos": Vector3(0, -0.40, -0.10), "hips": Vector3(-14, 0, 0), "spine": Vector3(-26, 0, 0),
		"chest": Vector3(-12, 0, 0), "head": Vector3(24, 0, 0),
		"lfist": Vector3(-0.18, 0.30, -0.66), "lelbow": Vector3(-1, 0, 0.3), "rfist": Vector3(0.18, 0.30, -0.66), "relbow": Vector3(1, 0, 0.3),
		"lankle": Vector3(-0.22, 0.08, -0.20), "lknee": Vector3(-0.4, 0.2, -1), "rankle": Vector3(0.22, 0.08, 0.18), "rknee": Vector3(0.4, 0.2, -1)},
	# =========================================================================
	# Round 7 (docs/Round 7 — Freeflow Combat.md "Poses"). Agent P. Placeholder
	# quality: every strike reads as wind-up, contact, follow-through; every
	# reaction reads from a third-person camera. The jab, cross and hook reuse
	# the Round 5 / Upgrade 2 poses above.
	# =========================================================================
	# --- Heavy jab: weight sinks back, the lead shoulder coils, then a long
	# stepping jab with the hips behind it and a long reach after contact. ---
	&"hjab_load": {"pos": Vector3(0, -0.15, 0.06), "hips": Vector3(0, 4, 0), "spine": Vector3(-4, 6, 0),
		"chest": Vector3(-2, 16, 0), "head": Vector3(10, -24, 0),
		"lfist": Vector3(-0.17, 1.36, -0.10), "lelbow": Vector3(-0.8, -1, 0.4), "rfist": Vector3(0.10, 1.44, -0.18), "relbow": Vector3(0.4, -1, 0.3),
		"lankle": Vector3(-0.13, 0.08, -0.22), "lknee": Vector3(-0.2, 0, -1), "rankle": Vector3(0.17, 0.08, 0.20), "rknee": Vector3(0.2, 0, -1)},
	&"hjab_hit": {"pos": Vector3(0, -0.11, -0.15), "hips": Vector3(0, -30, 0), "spine": Vector3(-10, -10, 0),
		"chest": Vector3(-6, -22, -4), "head": Vector3(10, 60, 4),
		"lfist": Vector3(-0.02, 1.50, -0.82), "lelbow": Vector3(-0.7, -0.8, 0.1), "rfist": Vector3(0.08, 1.47, -0.16), "relbow": Vector3(0.4, -1, 0.4),
		"lankle": Vector3(-0.13, 0.08, -0.44), "lknee": Vector3(-0.15, 0, -1), "rankle": Vector3(0.15, 0.11, 0.10), "rfp": -20.0},
	&"hjab_follow": {"pos": Vector3(0, -0.12, -0.19), "hips": Vector3(0, -36, 0), "spine": Vector3(-12, -12, 0),
		"chest": Vector3(-6, -26, -4), "head": Vector3(10, 66, 4),
		"lfist": Vector3(0.02, 1.48, -0.86), "lelbow": Vector3(-0.7, -0.8, 0.1), "rfist": Vector3(0.08, 1.46, -0.18), "relbow": Vector3(0.4, -1, 0.4),
		"lankle": Vector3(-0.13, 0.08, -0.44), "lknee": Vector3(-0.15, 0, -1), "rankle": Vector3(0.15, 0.13, 0.06), "rfp": -28.0},
	# --- Heavy cross: hips and shoulders loaded far back, the rear fist cocked
	# behind the shoulder, then the whole body turns through. ---
	&"hcross_load": {"pos": Vector3(0, -0.16, 0.07), "hips": Vector3(0, -34, 0), "spine": Vector3(0, -8, 0),
		"chest": Vector3(0, -28, 0), "head": Vector3(4, 66, 0),
		"lfist": Vector3(-0.06, 1.44, -0.44), "lelbow": Vector3(-0.5, -1, 0.0), "rfist": Vector3(0.30, 1.40, 0.20), "relbow": Vector3(0.7, -0.5, 1),
		"lankle": Vector3(-0.13, 0.08, -0.26), "lknee": Vector3(-0.2, 0, -1), "rankle": Vector3(0.18, 0.08, 0.22), "rknee": Vector3(0.2, 0, -1)},
	&"hcross_hit": {"pos": Vector3(0, -0.12, -0.15), "hips": Vector3(0, 26, 0), "spine": Vector3(-12, 6, 0),
		"chest": Vector3(-6, 30, 0), "head": Vector3(10, -60, 0),
		"lfist": Vector3(-0.14, 1.42, -0.12), "lelbow": Vector3(-0.5, -1, 0.4), "rfist": Vector3(0.02, 1.50, -0.92), "relbow": Vector3(0.8, -0.5, 0.2),
		"lankle": Vector3(-0.13, 0.08, -0.36), "rankle": Vector3(0.15, 0.13, 0.28), "rfp": -32.0},
	&"hcross_follow": {"pos": Vector3(0, -0.14, -0.19), "hips": Vector3(0, 34, 0), "spine": Vector3(-16, 10, 0),
		"chest": Vector3(-8, 30, 0), "head": Vector3(12, -68, 0),
		"lfist": Vector3(-0.16, 1.38, -0.08), "lelbow": Vector3(-0.5, -1, 0.4), "rfist": Vector3(-0.16, 1.44, -0.94), "relbow": Vector3(0.9, -0.3, 0.2),
		"lankle": Vector3(-0.13, 0.08, -0.36), "rankle": Vector3(0.15, 0.15, 0.24), "rfp": -42.0},
	# --- Heavy hook: chest wound far right, the lead arm cocked wide; the turn
	# carries the fist across the target and well past it. ---
	&"hhook_load": {"pos": Vector3(0, -0.15, 0.04), "hips": Vector3(0, 14, 0), "spine": Vector3(-4, 12, 0),
		"chest": Vector3(-4, 28, 0), "head": Vector3(6, -52, 0),
		"lfist": Vector3(-0.56, 1.42, 0.06), "lelbow": Vector3(-1, 0.3, 0.4), "rfist": Vector3(0.10, 1.47, -0.20), "relbow": Vector3(0.5, -1, 0.4),
		"lankle": Vector3(-0.14, 0.08, -0.22), "lknee": Vector3(-0.2, 0, -1), "rankle": Vector3(0.17, 0.08, 0.20), "rknee": Vector3(0.2, 0, -1)},
	&"hhook_hit": {"pos": Vector3(0, -0.12, -0.07), "hips": Vector3(0, -30, 0), "spine": Vector3(-6, -14, 0),
		"chest": Vector3(-4, -30, 0), "head": Vector3(6, 68, 0),
		"lfist": Vector3(0.04, 1.50, -0.62), "lelbow": Vector3(-1, 0.25, 0.2), "rfist": Vector3(0.12, 1.47, -0.16), "relbow": Vector3(0.5, -1, 0.4),
		"lankle": Vector3(-0.13, 0.08, -0.28), "rankle": Vector3(0.16, 0.12, 0.14), "rfp": -25.0},
	&"hhook_follow": {"pos": Vector3(0, -0.13, -0.09), "hips": Vector3(0, -44, 0), "spine": Vector3(-6, -20, 0),
		"chest": Vector3(-4, -30, 0), "head": Vector3(6, 70, 0),
		"lfist": Vector3(0.42, 1.42, -0.30), "lelbow": Vector3(-1, 0.3, 0.3), "rfist": Vector3(0.12, 1.46, -0.14), "relbow": Vector3(0.5, -1, 0.4),
		"lankle": Vector3(-0.13, 0.08, -0.28), "rankle": Vector3(0.15, 0.16, 0.10), "rfp": -35.0},
	# --- Uppercut: the fist starts at the hip (uppercut_cock), lands under the
	# chin on the first active frame and keeps rising (uppercut_hit, then
	# uppercut_follow overhead). ---
	&"upc_hit": {"pos": Vector3(0, -0.09, -0.08), "hips": Vector3(0, 12, 0), "spine": Vector3(-4, 4, 0),
		"chest": Vector3(-2, 20, -4), "head": Vector3(4, -34, 0),
		"lfist": Vector3(-0.14, 1.38, -0.14), "lelbow": Vector3(-0.5, -1, 0.4), "rfist": Vector3(0.05, 1.46, -0.48), "relbow": Vector3(0.3, -1, -0.7),
		"lankle": Vector3(-0.14, 0.08, -0.22), "rankle": Vector3(0.16, 0.10, 0.12), "rfp": -25.0},
	# --- Gut punch: drop the level, the rear fist cocked low at the hip, then
	# a short dig into the stomach with the knees bent and the head behind it. ---
	&"gut_load": {"pos": Vector3(0, -0.17, 0.04), "hips": Vector3(-4, -24, 0), "spine": Vector3(-10, -4, 0),
		"chest": Vector3(-4, -18, 0), "head": Vector3(14, 44, 0),
		"lfist": Vector3(-0.08, 1.36, -0.36), "lelbow": Vector3(-0.5, -1, 0.2), "rfist": Vector3(0.25, 1.02, 0.06), "relbow": Vector3(0.6, -0.8, 0.6),
		"lankle": Vector3(-0.15, 0.08, -0.24), "lknee": Vector3(-0.3, 0, -1), "rankle": Vector3(0.18, 0.08, 0.20), "rknee": Vector3(0.3, 0, -1)},
	&"gut_hit": {"pos": Vector3(0, -0.25, -0.12), "hips": Vector3(-8, 20, 0), "spine": Vector3(-16, 6, 0),
		"chest": Vector3(-8, 26, 0), "head": Vector3(24, -50, 0),
		"lfist": Vector3(-0.12, 1.26, -0.22), "lelbow": Vector3(-0.5, -1, 0.4), "rfist": Vector3(0.02, 1.08, -0.64), "relbow": Vector3(0.8, -0.6, 0.2),
		"lankle": Vector3(-0.15, 0.08, -0.36), "lknee": Vector3(-0.3, 0, -1), "rankle": Vector3(0.17, 0.10, 0.22), "rknee": Vector3(0.3, 0, -1), "rfp": -20.0},
	&"gut_follow": {"pos": Vector3(0, -0.26, -0.16), "hips": Vector3(-10, 26, 0), "spine": Vector3(-18, 8, 0),
		"chest": Vector3(-8, 30, 0), "head": Vector3(26, -58, 0),
		"lfist": Vector3(-0.13, 1.24, -0.20), "lelbow": Vector3(-0.5, -1, 0.4), "rfist": Vector3(-0.02, 1.10, -0.70), "relbow": Vector3(0.8, -0.6, 0.2),
		"lankle": Vector3(-0.15, 0.08, -0.36), "lknee": Vector3(-0.3, 0, -1), "rankle": Vector3(0.17, 0.12, 0.20), "rknee": Vector3(0.3, 0, -1), "rfp": -26.0},
	# --- Leg kick: a low round kick. The lead foot pivots, the hips turn
	# over, the right shin swings across into the thigh (~0.5 m). ---
	&"lk_load": {"pos": Vector3(0, -0.09, 0.02), "hips": Vector3(0, 20, 6), "spine": Vector3(-2, 0, 4),
		"chest": Vector3(-2, -10, 0), "head": Vector3(6, -10, -4),
		"lfist": Vector3(-0.14, 1.42, -0.34), "lelbow": Vector3(-0.5, -1, 0.3), "rfist": Vector3(0.22, 1.34, -0.14), "relbow": Vector3(0.6, -1, 0.3),
		"lankle": Vector3(-0.09, 0.08, -0.14), "lknee": Vector3(-0.2, 0, -1), "lfp": -10.0,
		"rankle": Vector3(0.40, 0.36, 0.06), "rknee": Vector3(0.8, 0.2, -0.8), "rfp": -30.0},
	&"lk_hit": {"pos": Vector3(0, -0.10, -0.06), "hips": Vector3(0, 52, 14), "spine": Vector3(2, 0, 8),
		"chest": Vector3(0, -12, 4), "head": Vector3(4, -40, -8),
		"lfist": Vector3(-0.30, 1.36, -0.22), "lelbow": Vector3(-0.8, -0.6, 0.3), "rfist": Vector3(0.06, 1.40, -0.34), "relbow": Vector3(0.6, -1, 0.2),
		"lankle": Vector3(-0.06, 0.08, -0.06), "lknee": Vector3(-0.3, 0, -1), "lfp": -15.0,
		"rankle": Vector3(-0.04, 0.44, -0.74), "rknee": Vector3(0.6, 0.6, -0.5), "rfp": -45.0},
	&"lk_follow": {"pos": Vector3(0, -0.10, -0.07), "hips": Vector3(0, 70, 14), "spine": Vector3(2, 0, 8),
		"chest": Vector3(0, -16, 4), "head": Vector3(4, -50, -8),
		"lfist": Vector3(-0.32, 1.34, -0.18), "lelbow": Vector3(-0.8, -0.6, 0.3), "rfist": Vector3(0.04, 1.38, -0.34), "relbow": Vector3(0.6, -1, 0.2),
		"lankle": Vector3(-0.06, 0.08, -0.06), "lknee": Vector3(-0.3, 0, -1), "lfp": -15.0,
		"rankle": Vector3(-0.30, 0.42, -0.62), "rknee": Vector3(0.3, 0.6, -0.8), "rfp": -45.0},
	&"lk_recoil": {"pos": Vector3(0, -0.08, 0.0), "hips": Vector3(0, 30, 6), "spine": Vector3(-2, 0, 4),
		"chest": Vector3(-2, -12, 0), "head": Vector3(6, -14, -4),
		"lfist": Vector3(-0.12, 1.42, -0.34), "lelbow": Vector3(-0.5, -1, 0.3), "rfist": Vector3(0.18, 1.38, -0.18), "relbow": Vector3(0.6, -1, 0.3),
		"lankle": Vector3(-0.08, 0.08, -0.10), "lknee": Vector3(-0.2, 0, -1),
		"rankle": Vector3(0.20, 0.30, -0.10), "rknee": Vector3(0.3, 0.3, -1), "rfp": -20.0},
	# --- Front kick: a high knee chamber, then the heel driven straight out at
	# the stomach (~1.05 m), leaning back over the standing leg. ---
	&"fk_chamber": {"pos": Vector3(0, -0.03, 0.06), "hips": Vector3(10, -5, 0), "spine": Vector3(10, 0, 0),
		"chest": Vector3(4, -4, 0), "head": Vector3(-16, 8, 0),
		"lfist": Vector3(-0.11, 1.47, -0.30), "lelbow": Vector3(-0.5, -1, 0.3), "rfist": Vector3(0.22, 1.30, -0.06), "relbow": Vector3(0.6, -1, 0.3),
		"lankle": Vector3(-0.10, 0.08, -0.05), "lknee": Vector3(-0.1, 0, -1),
		"rankle": Vector3(0.11, 0.74, -0.14), "rknee": Vector3(0, 0.7, -1), "rfp": 25.0},
	&"fk_hit": {"pos": Vector3(0, -0.04, -0.09), "hips": Vector3(16, -4, 0), "spine": Vector3(14, 0, 0),
		"chest": Vector3(6, -4, 0), "head": Vector3(-28, 6, 0),
		"lfist": Vector3(-0.16, 1.44, -0.26), "lelbow": Vector3(-0.6, -1, 0.3), "rfist": Vector3(0.32, 1.12, 0.08), "relbow": Vector3(0.8, -0.6, 0.4),
		"lankle": Vector3(-0.10, 0.08, -0.04), "lknee": Vector3(0, 0, -1), "lfp": -6.0,
		"rankle": Vector3(0.10, 1.06, -0.86), "rknee": Vector3(0, 1, 0), "rfp": 70.0},
	&"fk_ext": {"pos": Vector3(0, -0.04, -0.11), "hips": Vector3(17, -4, 0), "spine": Vector3(15, 0, 0),
		"chest": Vector3(6, -4, 0), "head": Vector3(-28, 6, 0),
		"lfist": Vector3(-0.17, 1.43, -0.25), "lelbow": Vector3(-0.6, -1, 0.3), "rfist": Vector3(0.33, 1.10, 0.10), "relbow": Vector3(0.8, -0.6, 0.4),
		"lankle": Vector3(-0.10, 0.08, -0.04), "lknee": Vector3(0, 0, -1), "lfp": -8.0,
		"rankle": Vector3(0.10, 1.06, -0.88), "rknee": Vector3(0, 1, 0), "rfp": 70.0},
	&"fk_follow": {"pos": Vector3(0, -0.05, -0.15), "hips": Vector3(18, -3, 0), "spine": Vector3(16, 0, 0),
		"chest": Vector3(6, -4, 0), "head": Vector3(-30, 6, 0),
		"lfist": Vector3(-0.18, 1.42, -0.24), "lelbow": Vector3(-0.6, -1, 0.3), "rfist": Vector3(0.34, 1.08, 0.12), "relbow": Vector3(0.8, -0.6, 0.4),
		"lankle": Vector3(-0.10, 0.08, -0.06), "lknee": Vector3(0, 0, -1), "lfp": -12.0,
		"rankle": Vector3(0.10, 1.00, -0.94), "rknee": Vector3(0, 1, 0), "rfp": 60.0},
	# --- Roundhouse: pivot on the lead foot, the hips turn over (body frame),
	# the torso leans away and the right foot whips through at head height. ---
	&"rh_load": {"frame": &"body", "pos": Vector3(0, -0.05, 0.02), "hips": Vector3(0, 40, 12), "spine": Vector3(4, 0, 8),
		"chest": Vector3(2, 0, 4), "head": Vector3(-6, -40, -10),
		"lfist": Vector3(-0.30, 1.42, -0.26), "lelbow": Vector3(-0.6, -1, 0.2), "rfist": Vector3(0.10, 1.38, -0.30), "relbow": Vector3(0.6, -1, 0.2),
		"lankle": Vector3(-0.10, 0.08, 0.0), "lknee": Vector3(-0.3, 0, -1), "lfp": -15.0,
		"rankle": Vector3(0.36, 0.86, 0.04), "rknee": Vector3(1, 0.6, -0.6), "rfp": -30.0},
	&"rh_hit": {"pos": Vector3(0, 0.0, -0.04), "hips": Vector3(12, 60, 24), "spine": Vector3(4, 0, 18),
		"chest": Vector3(2, -6, 8), "head": Vector3(-4, -54, -18),
		"lfist": Vector3(-0.40, 1.30, 0.10), "lelbow": Vector3(-0.8, -0.5, 0.2), "rfist": Vector3(-0.10, 1.32, -0.30), "relbow": Vector3(0.6, -1, 0.2),
		"lankle": Vector3(-0.10, 0.08, 0.02), "lknee": Vector3(-0.3, 0, -1), "lfp": -20.0,
		"rankle": Vector3(0.0, 1.47, -0.66), "rknee": Vector3(0.3, 1, 0.3), "rfp": -40.0},
	&"rh_follow": {"pos": Vector3(0, -0.01, -0.06), "hips": Vector3(12, 95, 28), "spine": Vector3(4, 0, 18),
		"chest": Vector3(2, -6, 8), "head": Vector3(-4, -66, -18),
		"lfist": Vector3(-0.30, 1.28, 0.30), "lelbow": Vector3(-0.8, -0.5, 0.2), "rfist": Vector3(-0.30, 1.30, -0.16), "relbow": Vector3(0.6, -1, 0.2),
		"lankle": Vector3(-0.10, 0.08, 0.02), "lknee": Vector3(-0.3, 0, -1), "lfp": -20.0,
		"rankle": Vector3(-0.38, 1.38, -0.50), "rknee": Vector3(0, 1, 0.3), "rfp": -40.0},
	&"rh_recoil": {"frame": &"body", "pos": Vector3(0, -0.06, -0.02), "hips": Vector3(0, 60, 10), "spine": Vector3(2, 0, 6),
		"chest": Vector3(0, 0, 2), "head": Vector3(-2, -50, -6),
		"lfist": Vector3(-0.28, 1.40, -0.24), "lelbow": Vector3(-0.6, -1, 0.2), "rfist": Vector3(0.10, 1.38, -0.30), "relbow": Vector3(0.6, -1, 0.2),
		"lankle": Vector3(-0.10, 0.08, 0.0), "lknee": Vector3(-0.3, 0, -1), "lfp": -10.0,
		"rankle": Vector3(0.36, 0.50, 0.10), "rknee": Vector3(1, 0.4, -0.6), "rfp": -25.0},
	# --- Heavy kicks (held kick buttons): a longer, deeper load and a bigger
	# follow-through; each lands where its light kick lands. ---
	# Heavy leg kick: the lead foot steps out, the hips wind back and sink,
	# then the hips turn over hard (the right arm swings down for power) and
	# the shin carries on across.
	&"hlk_load": {"pos": Vector3(0, -0.15, 0.04), "hips": Vector3(0, -34, 0), "spine": Vector3(-4, -8, 0),
		"chest": Vector3(-2, -12, 0), "head": Vector3(6, 50, 0),
		"lfist": Vector3(-0.10, 1.42, -0.36), "lelbow": Vector3(-0.5, -1, 0.2), "rfist": Vector3(0.18, 1.40, -0.16), "relbow": Vector3(0.5, -1, 0.3),
		"lankle": Vector3(-0.15, 0.08, -0.32), "lknee": Vector3(-0.3, 0, -1),
		"rankle": Vector3(0.20, 0.12, 0.30), "rknee": Vector3(0.2, 0, -1), "rfp": -25.0},
	&"hlk_hit": {"pos": Vector3(0, -0.11, -0.08), "hips": Vector3(0, 60, 16), "spine": Vector3(2, 0, 10),
		"chest": Vector3(0, -14, 4), "head": Vector3(4, -46, -8),
		"lfist": Vector3(-0.32, 1.38, -0.20), "lelbow": Vector3(-0.8, -0.6, 0.3), "rfist": Vector3(0.28, 1.18, 0.12), "relbow": Vector3(0.8, -0.6, 0.4),
		"lankle": Vector3(-0.06, 0.08, -0.06), "lknee": Vector3(-0.3, 0, -1), "lfp": -18.0,
		"rankle": Vector3(-0.04, 0.44, -0.74), "rknee": Vector3(0.6, 0.6, -0.5), "rfp": -45.0},
	&"hlk_follow": {"pos": Vector3(0, -0.12, -0.10), "hips": Vector3(0, 95, 14), "spine": Vector3(2, 0, 8),
		"chest": Vector3(0, -18, 4), "head": Vector3(4, -60, -8),
		"lfist": Vector3(-0.30, 1.34, -0.10), "lelbow": Vector3(-0.8, -0.6, 0.3), "rfist": Vector3(0.24, 1.16, 0.18), "relbow": Vector3(0.8, -0.6, 0.4),
		"lankle": Vector3(-0.06, 0.08, -0.06), "lknee": Vector3(-0.3, 0, -1), "lfp": -18.0,
		"rankle": Vector3(-0.48, 0.42, -0.46), "rknee": Vector3(0.2, 0.6, -0.8), "rfp": -45.0},
	# Heavy front kick: a higher, held knee chamber with the hips tucked under,
	# the same heel strike, then the body drives through behind the foot.
	&"hfk_chamber": {"pos": Vector3(0, -0.02, 0.08), "hips": Vector3(14, -5, 0), "spine": Vector3(12, 0, 0),
		"chest": Vector3(4, -4, 0), "head": Vector3(-20, 8, 0),
		"lfist": Vector3(-0.12, 1.48, -0.30), "lelbow": Vector3(-0.5, -1, 0.3), "rfist": Vector3(0.24, 1.30, -0.04), "relbow": Vector3(0.6, -1, 0.3),
		"lankle": Vector3(-0.10, 0.08, -0.04), "lknee": Vector3(-0.1, 0, -1),
		"rankle": Vector3(0.11, 0.84, -0.10), "rknee": Vector3(0, 0.8, -1), "rfp": 25.0},
	&"hfk_hit": {"pos": Vector3(0, -0.04, -0.12), "hips": Vector3(18, -4, 0), "spine": Vector3(14, 0, 0),
		"chest": Vector3(6, -4, 0), "head": Vector3(-28, 6, 0),
		"lfist": Vector3(-0.18, 1.42, -0.22), "lelbow": Vector3(-0.6, -1, 0.3), "rfist": Vector3(0.34, 1.10, 0.10), "relbow": Vector3(0.8, -0.6, 0.4),
		"lankle": Vector3(-0.10, 0.08, -0.06), "lknee": Vector3(0, 0, -1), "lfp": -8.0,
		"rankle": Vector3(0.10, 1.06, -0.86), "rknee": Vector3(0, 1, 0), "rfp": 70.0},
	&"hfk_follow": {"pos": Vector3(0, -0.06, -0.26), "hips": Vector3(16, -3, 0), "spine": Vector3(8, 0, 0),
		"chest": Vector3(2, -4, 0), "head": Vector3(-16, 6, 0),
		"lfist": Vector3(-0.20, 1.38, -0.30), "lelbow": Vector3(-0.6, -1, 0.3), "rfist": Vector3(0.32, 1.12, 0.0), "relbow": Vector3(0.8, -0.6, 0.4),
		"lankle": Vector3(-0.10, 0.08, -0.14), "lknee": Vector3(0, 0, -1), "lfp": -20.0,
		"rankle": Vector3(0.10, 0.98, -1.04), "rknee": Vector3(0, 1, 0), "rfp": 55.0},
	# Heavy roundhouse: a counter-turn coil (hips wound right, the lead foot
	# steps in), the usual chamber, the same head-height contact, then the
	# hips keep spinning through.
	&"hrh_coil": {"pos": Vector3(0, -0.12, 0.04), "hips": Vector3(0, -38, 0), "spine": Vector3(0, -10, 0),
		"chest": Vector3(0, -16, 0), "head": Vector3(4, 60, 0),
		"lfist": Vector3(-0.10, 1.44, -0.38), "lelbow": Vector3(-0.5, -1, 0.2), "rfist": Vector3(0.22, 1.36, -0.04), "relbow": Vector3(0.6, -1, 0.4),
		"lankle": Vector3(-0.14, 0.08, -0.30), "lknee": Vector3(-0.2, 0, -1),
		"rankle": Vector3(0.20, 0.11, 0.28), "rknee": Vector3(0.2, 0, -1), "rfp": -20.0},
	&"hrh_hit": {"pos": Vector3(0, 0.0, -0.05), "hips": Vector3(12, 64, 26), "spine": Vector3(4, 0, 18),
		"chest": Vector3(2, -8, 8), "head": Vector3(-4, -56, -18),
		"lfist": Vector3(-0.42, 1.28, 0.12), "lelbow": Vector3(-0.8, -0.5, 0.2), "rfist": Vector3(-0.12, 1.30, -0.28), "relbow": Vector3(0.6, -1, 0.2),
		"lankle": Vector3(-0.10, 0.08, 0.02), "lknee": Vector3(-0.3, 0, -1), "lfp": -20.0,
		"rankle": Vector3(0.0, 1.47, -0.66), "rknee": Vector3(0.3, 1, 0.3), "rfp": -40.0},
	&"hrh_follow": {"pos": Vector3(0, -0.02, -0.07), "hips": Vector3(12, 140, 28), "spine": Vector3(4, 0, 18),
		"chest": Vector3(2, -6, 8), "head": Vector3(-4, -70, -18),
		"lfist": Vector3(-0.10, 1.28, 0.36), "lelbow": Vector3(-0.8, -0.5, 0.2), "rfist": Vector3(-0.36, 1.28, 0.02), "relbow": Vector3(0.6, -1, 0.2),
		"lankle": Vector3(-0.10, 0.08, 0.02), "lknee": Vector3(-0.3, 0, -1), "lfp": -20.0,
		"rankle": Vector3(-0.52, 1.28, -0.28), "rknee": Vector3(0, 1, 0.3), "rfp": -40.0},
	&"hrh_recoil": {"frame": &"body", "pos": Vector3(0, -0.07, -0.02), "hips": Vector3(0, 80, 10), "spine": Vector3(2, 0, 6),
		"chest": Vector3(0, 0, 2), "head": Vector3(-2, -60, -6),
		"lfist": Vector3(-0.28, 1.40, -0.24), "lelbow": Vector3(-0.6, -1, 0.2), "rfist": Vector3(0.10, 1.38, -0.30), "relbow": Vector3(0.6, -1, 0.2),
		"lankle": Vector3(-0.10, 0.08, 0.0), "lknee": Vector3(-0.3, 0, -1), "lfp": -10.0,
		"rankle": Vector3(0.36, 0.50, 0.10), "rknee": Vector3(1, 0.4, -0.6), "rfp": -25.0},
	# --- Counter: the lead hand snaps out and catches the incoming arm, then
	# pulls it in while the rear hand lands. ---
	&"counter_catch": {"pos": Vector3(0, -0.10, -0.05), "hips": Vector3(0, -22, 0), "spine": Vector3(-6, -6, 0),
		"chest": Vector3(-4, -16, 0), "head": Vector3(6, 44, 0),
		"lfist": Vector3(-0.12, 1.50, -0.64), "lelbow": Vector3(-0.7, -0.8, 0.1), "rfist": Vector3(0.20, 1.42, -0.04), "relbow": Vector3(0.7, -0.6, 0.8),
		"lankle": Vector3(-0.13, 0.08, -0.30), "rankle": Vector3(0.16, 0.08, 0.18)},
	&"counter_hit": {"pos": Vector3(0, -0.10, -0.13), "hips": Vector3(0, 22, 0), "spine": Vector3(-10, 6, 0),
		"chest": Vector3(-4, 30, 0), "head": Vector3(8, -58, 0),
		"lfist": Vector3(-0.22, 1.34, -0.30), "lelbow": Vector3(-0.8, -1, 0.3), "rfist": Vector3(0.02, 1.50, -0.76), "relbow": Vector3(0.8, -0.6, 0.2),
		"lankle": Vector3(-0.13, 0.08, -0.32), "rankle": Vector3(0.15, 0.12, 0.18), "rfp": -25.0},
	&"counter_follow": {"pos": Vector3(0, -0.11, -0.16), "hips": Vector3(0, 28, 0), "spine": Vector3(-12, 8, 0),
		"chest": Vector3(-6, 30, 0), "head": Vector3(10, -64, 0),
		"lfist": Vector3(-0.20, 1.30, -0.18), "lelbow": Vector3(-0.8, -1, 0.3), "rfist": Vector3(-0.08, 1.47, -0.80), "relbow": Vector3(0.9, -0.4, 0.2),
		"lankle": Vector3(-0.13, 0.08, -0.32), "rankle": Vector3(0.15, 0.14, 0.16), "rfp": -32.0},
	# --- Dodge: a crouched slip. The body drops and the head leaves the line of
	# attack to the left (mirrored when moving right); the legs take quick steps
	# from the locomotion (the move's "steps"), so it reads in any direction. ---
	&"dodge_duck": {"pos": Vector3(-0.17, -0.26, 0.02), "hips": Vector3(-6, 6, 7), "spine": Vector3(-14, 0, 12),
		"chest": Vector3(-6, 4, 7), "head": Vector3(18, -4, -12),
		"lfist": Vector3(-0.36, 1.14, -0.24), "lelbow": Vector3(-0.6, -1, 0.3), "rfist": Vector3(-0.08, 1.20, -0.26), "relbow": Vector3(0.5, -1, 0.3)},
	&"dodge_rise": {"pos": Vector3(-0.10, -0.13, 0.0), "hips": Vector3(-4, -6, 4), "spine": Vector3(-8, 0, 6),
		"chest": Vector3(-4, -4, 4), "head": Vector3(10, 12, -6),
		"lfist": Vector3(-0.18, 1.32, -0.34), "lelbow": Vector3(-0.5, -1, 0.2), "rfist": Vector3(0.02, 1.32, -0.24), "relbow": Vector3(0.5, -1, 0.3)},
	# --- Glide: a fast run-in. Upper body only (the legs run the sprint cycle
	# at the glide's speed): pitched forward, chin down, guard high. ---
	&"glide_lean": {"spine": Vector3(-22, 0, 0), "chest": Vector3(-10, -4, 0), "head": Vector3(30, 6, 0),
		"lfist": Vector3(-0.12, 1.30, -0.44), "lelbow": Vector3(-0.5, -1, 0.2), "rfist": Vector3(0.13, 1.26, -0.32), "relbow": Vector3(0.5, -1, 0.3)},
	# --- Holding a body: the collar clinch (hands at the collar of a body held
	# Carry.CLINCH_DIST = 0.72 m in front), and the drive (shoulder down,
	# leaning hard, both arms driving the body in front). Upper body only so
	# the legs keep the locomotion (the carry style runs at drive speed). ---
	&"clinch": {"pos": Vector3(0, -0.08, 0.0), "hips": Vector3(0, 0, 0), "spine": Vector3(-8, 0, 0), "chest": Vector3(-4, 0, 0), "head": Vector3(8, 0, 0),
		"lfist": Vector3(-0.09, 1.42, -0.58), "lelbow": Vector3(-1, -0.6, 0.1), "rfist": Vector3(0.09, 1.42, -0.58), "relbow": Vector3(1, -0.6, 0.1)},
	&"drive_lean": {"spine": Vector3(-26, 0, 0), "chest": Vector3(-14, -8, -8), "head": Vector3(36, 8, 6),
		"lfist": Vector3(-0.14, 1.26, -0.62), "lelbow": Vector3(-0.9, -0.6, 0.3), "rfist": Vector3(0.12, 1.22, -0.58), "relbow": Vector3(0.9, -0.6, 0.3)},
	# --- Throw: a baseball wind-up with the body (turned back, the throwing
	# arm loaded behind the head, the lead arm pointing at the target), and the
	# release (the arm whips over and through, weight onto the lead foot). ---
	&"throw_wu_a": {"pos": Vector3(0, -0.10, 0.04), "hips": Vector3(0, -20, 0), "spine": Vector3(0, -10, 0),
		"chest": Vector3(2, -18, 0), "head": Vector3(2, 46, 0),
		"lfist": Vector3(-0.18, 1.38, -0.42), "lelbow": Vector3(-0.6, -1, 0.2), "rfist": Vector3(0.32, 1.40, 0.10), "relbow": Vector3(1, -0.3, 0.6),
		"lankle": Vector3(-0.14, 0.08, -0.24), "rankle": Vector3(0.18, 0.08, 0.22)},
	&"throw_wu_b": {"pos": Vector3(0, -0.15, 0.10), "hips": Vector3(0, -45, 0), "spine": Vector3(4, -22, -6),
		"chest": Vector3(4, -28, -8), "head": Vector3(0, 68, 0),
		"lfist": Vector3(-0.08, 1.48, -0.56), "lelbow": Vector3(-0.6, -1, 0.0), "rfist": Vector3(0.40, 1.62, 0.36), "relbow": Vector3(1, 0.2, 0.4),
		"lankle": Vector3(-0.14, 0.12, -0.36), "lfp": 10.0, "rankle": Vector3(0.20, 0.08, 0.26), "rknee": Vector3(0.3, 0, -1)},
	&"throw_whip": {"pos": Vector3(0, -0.14, -0.04), "hips": Vector3(0, 0, 0), "spine": Vector3(-6, 0, 0),
		"chest": Vector3(-2, 6, 0), "head": Vector3(8, -6, 0),
		"lfist": Vector3(-0.30, 1.20, -0.20), "lelbow": Vector3(-1, -0.6, 0.3), "rfist": Vector3(0.30, 1.76, -0.10), "relbow": Vector3(1, 0.4, 0.2),
		"lankle": Vector3(-0.15, 0.08, -0.38), "rankle": Vector3(0.18, 0.10, 0.22), "rfp": -20.0},
	&"throw_rel": {"pos": Vector3(0, -0.15, -0.16), "hips": Vector3(0, 36, 0), "spine": Vector3(-14, 14, 0),
		"chest": Vector3(-8, 26, 0), "head": Vector3(12, -68, 0),
		"lfist": Vector3(-0.32, 1.10, 0.04), "lelbow": Vector3(-1, -0.6, 0.3), "rfist": Vector3(0.0, 1.40, -0.72), "relbow": Vector3(0.8, -0.6, 0.2),
		"lankle": Vector3(-0.15, 0.08, -0.40), "lknee": Vector3(-0.2, 0, -1), "rankle": Vector3(0.17, 0.16, 0.18), "rfp": -40.0},
	&"throw_rel_follow": {"pos": Vector3(0, -0.18, -0.20), "hips": Vector3(0, 44, 0), "spine": Vector3(-22, 14, 0),
		"chest": Vector3(-10, 28, 0), "head": Vector3(20, -70, 0),
		"lfist": Vector3(-0.30, 1.02, 0.08), "lelbow": Vector3(-1, -0.6, 0.3), "rfist": Vector3(-0.30, 0.96, -0.50), "relbow": Vector3(0.8, -0.2, 0.4),
		"lankle": Vector3(-0.15, 0.08, -0.40), "lknee": Vector3(-0.2, 0, -1), "rankle": Vector3(0.14, 0.24, 0.12), "rfp": -50.0},
	# --- Reactions (victim states). Readable from the camera first. ---
	# Snap: the head snaps back, the upper body rocks back then forward.
	&"react_snap_a": {"pos": Vector3(0, -0.05, 0.08), "hips": Vector3(6, 0, 0), "spine": Vector3(12, 0, 0),
		"chest": Vector3(10, 4, 0), "head": Vector3(32, -6, 0),
		"lfist": Vector3(-0.32, 1.28, -0.10), "lelbow": Vector3(-1, -0.5, 0.4), "rfist": Vector3(0.34, 1.22, -0.04), "relbow": Vector3(1, -0.5, 0.4)},
	&"react_snap_b": {"pos": Vector3(0, -0.08, 0.04), "hips": Vector3(4, 0, 0), "spine": Vector3(4, 0, 0),
		"chest": Vector3(2, 0, 0), "head": Vector3(-8, 4, 0),
		"lfist": Vector3(-0.24, 1.30, -0.24), "lelbow": Vector3(-1, -0.6, 0.3), "rfist": Vector3(0.24, 1.26, -0.20), "relbow": Vector3(1, -0.6, 0.3)},
	# Spin: the hook turns the head and shoulders away (to the victim's left),
	# the arms swing with it, then a half-turn stumble.
	&"react_spin_a": {"pos": Vector3(0.04, -0.07, 0.04), "hips": Vector3(4, 22, -4), "spine": Vector3(6, 14, -8),
		"chest": Vector3(6, 26, -6), "head": Vector3(14, 50, -16),
		"lfist": Vector3(-0.46, 1.30, 0.18), "lelbow": Vector3(-1, -0.3, 0.5), "rfist": Vector3(-0.06, 1.22, -0.30), "relbow": Vector3(0.6, -1, 0.3)},
	&"react_spin_b": {"pos": Vector3(0.06, -0.10, 0.05), "hips": Vector3(6, 34, -6), "spine": Vector3(8, 16, -10),
		"chest": Vector3(6, 26, -8), "head": Vector3(10, 46, -18),
		"lfist": Vector3(-0.40, 1.10, 0.26), "lelbow": Vector3(-1, -0.4, 0.5), "rfist": Vector3(-0.14, 1.12, -0.32), "relbow": Vector3(0.6, -1, 0.3)},
	# Push: shoved back hard, bent at the waist, arms flailing (two beats).
	&"react_push_a": {"pos": Vector3(0, -0.10, 0.07), "hips": Vector3(-6, 0, 0), "spine": Vector3(-14, 0, 4),
		"chest": Vector3(-6, 0, 2), "head": Vector3(22, 0, 6),
		"lfist": Vector3(-0.38, 1.66, -0.32), "lelbow": Vector3(-1, 0.2, 0.3), "rfist": Vector3(0.44, 1.10, -0.26), "relbow": Vector3(1, -0.6, 0.3)},
	&"react_push_b": {"pos": Vector3(0, -0.12, 0.07), "hips": Vector3(-6, 0, 0), "spine": Vector3(-14, 0, -4),
		"chest": Vector3(-6, 0, -2), "head": Vector3(22, 0, -6),
		"lfist": Vector3(-0.44, 1.10, -0.26), "lelbow": Vector3(-1, -0.6, 0.3), "rfist": Vector3(0.38, 1.66, -0.32), "relbow": Vector3(1, 0.2, 0.3)},
	# Fold: doubled over, hands at the stomach, head low and forward (two
	# poses: the hold heaves slowly between them).
	&"react_fold_a": {"pos": Vector3(0, -0.17, 0.10), "hips": Vector3(-20, 0, 0), "spine": Vector3(-30, 0, 0),
		"chest": Vector3(-22, 0, 0), "head": Vector3(14, 0, 0),
		"lfist": Vector3(-0.08, 0.98, -0.34), "lelbow": Vector3(-1, -0.6, 0.2), "rfist": Vector3(0.08, 0.95, -0.32), "relbow": Vector3(1, -0.6, 0.2),
		"lankle": Vector3(-0.14, 0.08, -0.14), "lknee": Vector3(-0.2, 0, -1), "rankle": Vector3(0.16, 0.08, 0.16), "rknee": Vector3(0.2, 0, -1)},
	&"react_fold_b": {"pos": Vector3(0, -0.19, 0.11), "hips": Vector3(-22, 0, 0), "spine": Vector3(-33, 0, 0),
		"chest": Vector3(-24, 0, 0), "head": Vector3(12, 0, 0),
		"lfist": Vector3(-0.07, 0.95, -0.34), "lelbow": Vector3(-1, -0.6, 0.2), "rfist": Vector3(0.07, 0.92, -0.32), "relbow": Vector3(1, -0.6, 0.2),
		"lankle": Vector3(-0.14, 0.08, -0.14), "lknee": Vector3(-0.2, 0, -1), "rankle": Vector3(0.16, 0.08, 0.16), "rknee": Vector3(0.2, 0, -1)},
	# Buckle: the kicked (lead, left) leg gives way: down on the left knee, the
	# right foot planted in front, a hand on the knee and one reaching down.
	&"react_buckle_a": {"pos": Vector3(0, -0.40, 0.04), "hips": Vector3(-4, -10, 0), "spine": Vector3(-8, 0, 0),
		"chest": Vector3(-4, 4, 0), "head": Vector3(8, 8, 0),
		"lfist": Vector3(-0.30, 0.56, -0.20), "lelbow": Vector3(-1, -0.4, 0.3), "rfist": Vector3(0.16, 0.66, -0.36), "relbow": Vector3(1, -0.4, 0.3),
		"lankle": Vector3(-0.12, 0.10, 0.36), "lknee": Vector3(0, -1, -0.4), "lfp": -55.0,
		"rankle": Vector3(0.17, 0.08, -0.34), "rknee": Vector3(0.1, 0.3, -1)},
	&"react_buckle_b": {"pos": Vector3(0, -0.42, 0.05), "hips": Vector3(-6, -10, 0), "spine": Vector3(-10, 0, 0),
		"chest": Vector3(-5, 4, 0), "head": Vector3(10, 8, 0),
		"lfist": Vector3(-0.30, 0.52, -0.18), "lelbow": Vector3(-1, -0.4, 0.3), "rfist": Vector3(0.16, 0.64, -0.36), "relbow": Vector3(1, -0.4, 0.3),
		"lankle": Vector3(-0.12, 0.10, 0.36), "lknee": Vector3(0, -1, -0.4), "lfp": -55.0,
		"rankle": Vector3(0.17, 0.08, -0.34), "rknee": Vector3(0.1, 0.3, -1)},
	# Lift: popped off the ground, tilted back, limbs loose. Rising: the limbs
	# trail below; at the top and falling: they float up and out. The hold
	# blends the two by vertical speed and flails them (PoseAnimator).
	&"react_lift_rise": {"hips": Vector3(20, 0, 0), "spine": Vector3(12, 0, 0), "chest": Vector3(8, 0, 0), "head": Vector3(28, 0, 0),
		"lua": Vector3(20, 0, -35), "lla": Vector3(25, 0, 0), "rua": Vector3(10, 0, 40), "rla": Vector3(30, 0, 0),
		"lul": Vector3(25, 0, -8), "lll": Vector3(-40, 0, 0), "lf": Vector3(-30, 0, 0),
		"rul": Vector3(35, 0, 8), "rll": Vector3(-55, 0, 0), "rf": Vector3(-30, 0, 0)},
	&"react_lift_fall": {"hips": Vector3(26, 0, 0), "spine": Vector3(16, 0, 0), "chest": Vector3(12, 0, 0), "head": Vector3(10, 0, 0),
		"lua": Vector3(70, 0, -70), "lla": Vector3(40, 0, 0), "rua": Vector3(60, 0, 80), "rla": Vector3(45, 0, 0),
		"lul": Vector3(55, 0, -12), "lll": Vector3(-70, 0, 0), "lf": Vector3(-20, 0, 0),
		"rul": Vector3(40, 0, 10), "rll": Vector3(-45, 0, 0), "rf": Vector3(-25, 0, 0)},
}

const MOVES := {
	&"jab1": {"legs": &"free", "keys": [[0, 0.45, &"jab_l_cock"], [1, 0.0, &"jab_l_hit", &"snap"], [1, 1.0, &"jab_l_hit"], [2, 0.45, &"stance"]]},
	&"jab2": {"legs": &"free", "keys": [[0, 0.45, &"jab_r_cock"], [1, 0.0, &"jab_r_hit", &"snap"], [1, 1.0, &"jab_r_hit"], [2, 0.45, &"stance"]]},
	&"jab3": {"legs": &"free", "keys": [[0, 0.55, &"hook_l_cock"], [1, 0.0, &"hook_l_hit", &"snap"], [1, 1.0, &"hook_l_hit"], [2, 0.45, &"stance"]]},
	&"power_punch": {"keys": [[0, 0.4, &"power_charge"], [1, 0.0, &"power_hit", &"snap"], [1, 1.0, &"power_hit"], [2, 0.16, &"power_follow", &"snap"], [2, 0.55, &"jab_r_cock"]]},
	&"sparta_kick": {"keys": [[0, 0.55, &"kick_chamber"], [0, 0.8, &"kick_chamber"], [1, 0.0, &"kick_hit", &"snap"], [1, 1.0, &"kick_hit"], [2, 0.16, &"kick_follow", &"snap"], [2, 0.45, &"kick_recoil"]]},
	&"leg_sweep": {"keys": [[0, 0.6, &"sweep_crouch"], [1, 0.0, &"sweep_a", &"snap"], [1, 1.0, &"sweep_b", &"linear"], [2, 0.35, &"sweep_end"], [2, 0.75, &"sweep_rise"]]},
	&"grab": {"keys": [[0, 0.5, &"grab_open"], [1, 0.0, &"grab_reach", &"snap"], [1, 1.0, &"grab_reach"], [2, 0.6, &"grab_hold"]]},
	&"throw": {"legs": &"free", "timed": Vector3(0.35, 0.15, 0.5), "keys": [[0, 0.7, &"throw_turn"], [1, 0.0, &"throw_fling", &"snap"], [1, 1.0, &"throw_fling"],
		[2, 0.25, &"throw_follow", &"snap"], [2, 0.65, &"stance"]]},
	# Short startup (player): a fast spin. Long startup (AI teleport counter,
	# startup = tell): turn away fast, the chamber deepens over the tell, a
	# short set, then the heel snaps back toward the original facing.
	&"back_kick": {"keys": [[0, Vector2(0.45, 0.12), &"bk_turn"], [0, Vector2(-0.3, 0.103), &"bk_chamber"], [0, Vector2(-0.18, 0.07), &"bk_chamber", &"linear"],
		[1, 0.0, &"bk_hit", &"snap"], [1, 1.0, &"bk_hit"], [2, 0.18, &"bk_follow", &"snap"], [2, 0.55, &"bk_return"]]},
	&"punt": {"keys": [[0, 0.6, &"punt_cock"], [1, 0.0, &"punt_hit", &"snap"], [1, 1.0, &"punt_hit"], [2, 0.3, &"punt_follow", &"snap"], [2, 0.7, &"stance"]]},
	&"dash": {"keys": [[0, 1.0, &"dash", &"snap"], [1, 1.0, &"dash"]]},
	&"block_hit": {"keys": [[0, 1.0, &"block_recoil", &"snap"], [1, 1.0, &"block_recoil"], [2, 0.6, &"block"]]},
	&"getup_face_up": {"keys": [[0, 0.0, &"lie_up"], [0, 0.55, &"getup_up_sit"], [1, 0.0, &"getup_up_crouch"], [1, 1.0, &"getup_rise"]]},
	&"getup_face_down": {"keys": [[0, 0.0, &"lie_down"], [0, 0.6, &"getup_down_push"], [1, 0.0, &"getup_down_kneel"], [1, 1.0, &"getup_rise"]]},
	&"grab_break_push": {"keys": [[0, 0.6, &"push_load"], [1, 0.0, &"push_hit", &"snap"], [1, 1.0, &"push_hit"]]},
	&"taunt": {"keys": [[0, 0.6, &"taunt_flex"], [0, 1.0, &"taunt_flex"], [1, 0.25, &"taunt_beckon"], [1, 0.5, &"taunt_beckon2"], [1, 0.75, &"taunt_beckon"], [1, 1.0, &"taunt_beckon2"]]},
	&"land": {"keys": [[0, 0.0, &"land"], [1, 1.0, &"land"]]},
	# --- Upgrade 2 -------------------------------------------------------------------
	&"cross": {"legs": &"free", "keys": [[0, 0.45, &"cross_cock"], [1, 0.0, &"cross_hit", &"snap"], [1, 1.0, &"cross_hit"], [2, 0.2, &"cross_follow", &"snap"], [2, 0.6, &"stance"]]},
	&"hook": {"legs": &"free", "keys": [[0, 0.5, &"hook_l_cock"], [1, 0.0, &"hook_l_hit", &"snap"], [1, 1.0, &"hook_l_hit"], [2, 0.2, &"hook_l_follow", &"snap"], [2, 0.6, &"stance"]]},
	&"rising_uppercut": {"keys": [[0, 0.45, &"rising_cock"], [1, 0.0, &"rising_hit", &"snap"], [1, 1.0, &"rising_hit"], [2, 0.25, &"uppercut_follow", &"snap"], [2, 0.65, &"stance"]]},
	&"crouch_punch": {"keys": [[0, 0.5, &"crouch_punch_cock"], [1, 0.0, &"crouch_punch_hit", &"snap"], [1, 1.0, &"crouch_punch_hit"], [2, 0.5, &"crouch"]]},
	&"backfist": {"keys": [[0, Vector2(0.45, 0.10), &"backfist_cock"], [1, 0.0, &"backfist_hit", &"snap"], [1, 1.0, &"backfist_hit"], [2, 0.2, &"backfist_follow", &"snap"], [2, 0.55, &"backfist_return"]]},
	&"flying_kick": {"keys": [[0, 0.5, &"flying_cock"], [1, 0.0, &"flying_hit", &"snap"], [1, 1.0, &"flying_hit"], [2, 0.5, &"jump_fall"]]},
	&"hammer_fist": {"keys": [[0, 0.5, &"hammer_cock"], [1, 0.0, &"hammer_hit", &"snap"], [1, 1.0, &"hammer_hit"], [2, 0.5, &"jump_fall"]]},
	&"knee": {"keep_hold": true, "keys": [[0, 0.5, &"knee_cock"], [1, 0.0, &"knee_hit", &"snap"], [1, 1.0, &"knee_hit"], [2, 0.45, &"knee_cock"]]},
	&"headbutt": {"keep_hold": true, "timed": Vector3(0.4, 0.15, 0.45), "keys": [[0, 0.5, &"headbutt_cock"], [1, 0.0, &"headbutt_hit", &"snap"], [1, 1.0, &"headbutt_hit"], [2, 0.5, &"headbutt_cock"]]},
	&"neck_throw": {"keys": [[0, 0.6, &"neck_throw_load"], [1, 0.0, &"neck_throw_fling", &"snap"], [1, 1.0, &"neck_throw_fling"], [2, 0.5, &"stance"]]},
	&"mount_punch": {"keys": [[0, 0.5, &"mount_cock"], [1, 0.0, &"mount_hit", &"snap"], [1, 1.0, &"mount_hit"], [2, 0.6, &"mount_cock"]]},
	&"stomp": {"keys": [[0, 0.55, &"stomp_cock"], [1, 0.0, &"stomp_hit", &"snap"], [1, 1.0, &"stomp_hit"], [2, 0.5, &"stance"]]},
	&"upward_throw": {"keys": [[0, 0.6, &"uthrow_load"], [1, 0.0, &"uthrow_fling", &"snap"], [1, 1.0, &"uthrow_fling"], [2, 0.5, &"stance"]]},
	&"wall_slam": {"keys": [[0, 0.6, &"wslam_load"], [1, 0.0, &"wslam_hit", &"snap"], [1, 1.0, &"wslam_hit"], [2, 0.25, &"wslam_follow", &"snap"], [2, 0.6, &"stance"]]},
	&"e_sweep": {"tell": true, "keys": [[0, Vector2(0.2, 0.08), &"e_sweep_cock", &"snap", 0.6], [0, Vector2(-0.23, 0.103), &"e_sweep_cock"], [0, Vector2(-0.155, 0.07), &"e_sweep_cock", &"linear"], [1, 0.0, &"sweep_a", &"snap"], [1, 1.0, &"sweep_b", &"linear"], [2, 0.35, &"sweep_end"], [2, 0.75, &"sweep_rise"]]},
	# States as one-shots too (startup, active = state time, recovery).
	&"stumble": {"keys": [[0, 1.0, &"stumble_a", &"snap"], [1, 0.33, &"stumble_b"], [1, 0.66, &"stumble_a"], [1, 1.0, &"stumble_b"]]},
	&"dazed": {"keys": [[0, 1.0, &"dazed_a"], [1, 0.3, &"dazed_b"], [1, 0.65, &"dazed_a"], [1, 1.0, &"dazed_b"]]},
	# e_hook starts its build at 70% so the glowing fist reads HIGH (head
	# height, 1.6-1.7 m) for the whole tell (agent C's limb-glow tells).
	&"e_hook": {"tell": true, "keys": [[0, Vector2(0.2, 0.08), &"e_hook_cock", &"snap", 0.7], [0, Vector2(-0.23, 0.103), &"e_hook_cock"], [0, Vector2(-0.155, 0.07), &"e_hook_cock", &"linear"], [1, 0.0, &"e_hook_hit", &"snap"], [1, 1.0, &"e_hook_follow"], [2, 0.45, &"stance"]]},
	&"e_heavy": {"tell": true, "keys": [[0, Vector2(0.2, 0.08), &"e_heavy_cock", &"snap", 0.6], [0, Vector2(-0.23, 0.103), &"e_heavy_cock"], [0, Vector2(-0.155, 0.07), &"e_heavy_cock", &"linear"], [1, 0.0, &"e_heavy_hit", &"snap"], [1, 1.0, &"e_heavy_hit"], [2, 0.5, &"e_heavy_hit"]]},
	&"e_kick": {"tell": true, "keys": [[0, Vector2(0.2, 0.08), &"e_kick_cock", &"snap", 0.6], [0, Vector2(-0.23, 0.103), &"e_kick_cock"], [0, Vector2(-0.155, 0.07), &"e_kick_cock", &"linear"], [1, 0.0, &"e_kick_hit", &"snap"], [1, 1.0, &"e_kick_hit"], [2, 0.4, &"kick_recoil"]]},
	&"e_grab": {"tell": true, "keys": [[0, Vector2(0.2, 0.08), &"e_grab_cock", &"snap", 0.6], [0, Vector2(-0.23, 0.103), &"e_grab_cock"], [0, Vector2(-0.155, 0.07), &"e_grab_cock", &"linear"], [1, 0.0, &"e_grab_hit", &"snap"], [1, 1.0, &"e_grab_hit"], [2, 0.5, &"grab_hold"]]},
	&"e_charge": {"tell": true, "keys": [[0, Vector2(0.2, 0.08), &"e_charge_cock", &"snap", 0.6], [0, Vector2(-0.23, 0.103), &"e_charge_cock"], [0, Vector2(-0.155, 0.07), &"e_charge_cock", &"linear"], [1, 0.0, &"e_charge_hit", &"snap"], [1, 1.0, &"e_charge_hit"], [2, 0.5, &"e_charge_cock"]]},
	&"e_throw_debris": {"tell": true, "keys": [[0, Vector2(0.2, 0.08), &"e_throw_cock", &"snap", 0.6], [0, Vector2(-0.23, 0.103), &"e_throw_cock"], [0, Vector2(-0.155, 0.07), &"e_throw_cock", &"linear"], [1, 0.0, &"e_throw_hit", &"snap"], [1, 1.0, &"e_throw_hit"], [2, 0.45, &"stance"]]},
	# =========================================================================
	# Round 5 (agent P). "legs": &"free" = an upper-body move whose legs keep
	# running while the fighter moves (PoseAnimator.LEGS_FREE_FROM). "timed" =
	# the startup / active / recovery split play_timed() uses. "steps" = quick
	# stumble steps from the locomotion layer, `step_dir` when standing still.
	# =========================================================================
	# Player strikes: contact key at [1, 0.0] = the first active frame.
	&"jab": {"legs": &"free", "keys": [[0, 0.4, &"jab_load"], [1, 0.0, &"jab_hit", &"snap"], [1, 1.0, &"jab_reach"],
		[2, 0.3, &"jab_snap", &"snap"], [2, 0.7, &"stance"]]},
	&"kick": {"keys": [[0, 0.5, &"fkick_chamber"], [0, 0.82, &"fkick_chamber2"], [1, 0.0, &"fkick_hit", &"snap"], [1, 1.0, &"fkick_ext"],
		[2, 0.16, &"fkick_follow", &"snap"], [2, 0.45, &"fkick_recoil"], [2, 0.8, &"stance"]]},
	&"sweep": {"keys": [[0, 0.6, &"sweep_crouch"], [1, 0.0, &"sweep_a", &"snap"], [1, 1.0, &"sweep_b", &"linear"], [2, 0.35, &"sweep_end"], [2, 0.75, &"sweep_rise"]]},
	&"elbow": {"legs": &"free", "keys": [[0, 0.45, &"elbow_cock"], [1, 0.0, &"elbow_hit", &"snap"], [1, 1.0, &"elbow_hit"],
		[2, 0.2, &"elbow_follow", &"snap"], [2, 0.6, &"stance"]]},
	&"ground_stomp": {"keys": [[0, 0.55, &"gstomp_chamber"], [1, 0.0, &"gstomp_hit", &"snap"], [1, 1.0, &"gstomp_hit"],
		[2, 0.4, &"gstomp_lift"], [2, 0.8, &"stance"]]},
	&"knee_drop": {"keys": [[0, 0.5, &"kdrop_rise"], [1, 0.0, &"kdrop_hit", &"snap"], [1, 1.0, &"kdrop_hit"], [2, 0.45, &"kdrop_hit"]]},
	&"drop_strike": {"timed": Vector3(0.45, 0.2, 0.35), "keys": [[0, 0.5, &"dstrike_cock"], [1, 0.0, &"dstrike_hit", &"snap"], [1, 1.0, &"dstrike_hit"], [2, 0.5, &"jump_fall"]]},
	&"slam": {"timed": Vector3(0.5, 0.15, 0.35), "keys": [[0, 0.6, &"slam_cock"], [1, 0.0, &"slam_hit", &"snap"], [1, 1.0, &"slam_hit"], [2, 0.55, &"slam_rise"]]},
	# Movement (Traversal: play_timed with the tween's length; set_move_progress).
	&"sprint_start": {"timed": Vector3(0.15, 0.45, 0.4), "keys": [[0, 1.0, &"sstart_a", &"snap"], [1, 1.0, &"sstart_b"]]},
	&"vault_speed": {"timed": Vector3(0.3, 0.35, 0.35), "keys": [[0, 0.7, &"vault_plant", &"snap"], [1, 0.5, &"vault_over"], [2, 0.4, &"vault_land"]]},
	&"mantle": {"timed": Vector3(0.35, 0.35, 0.3), "keys": [[0, 0.55, &"mantle_foot", &"snap"], [0, 1.0, &"mantle_hands"], [1, 1.0, &"mantle_press"], [2, 0.5, &"mantle_rise"]]},
	&"wall_kickoff": {"timed": Vector3(0.35, 0.25, 0.4), "keys": [[0, 1.0, &"kickoff_plant", &"snap"], [1, 1.0, &"kickoff_push", &"snap"], [2, 0.5, &"jump_rise"]]},
	&"land_crouch": {"timed": Vector3(0.2, 0.3, 0.5), "keys": [[0, 1.0, &"land_crouch", &"snap"], [1, 1.0, &"land_crouch"]]},
	&"land_three_point": {"timed": Vector3(0.15, 0.5, 0.35), "keys": [[0, 1.0, &"land_3pt", &"snap"], [1, 1.0, &"land_3pt"], [2, 0.5, &"land_3pt_rise"]]},
	&"land_roll": {"timed": Vector3(0.2, 0.55, 0.25), "keys": [[0, 1.0, &"roll_tuck", &"snap"], [1, 0.33, &"roll_a", &"linear"],
		[1, 0.66, &"roll_b", &"linear"], [1, 1.0, &"roll_c", &"linear"], [2, 0.5, &"roll_up"]]},
	# Grab and carry (Carry).
	&"grab_lunge": {"keys": [[0, 0.6, &"glunge_load"], [1, 0.0, &"glunge_reach", &"snap"], [1, 1.0, &"glunge_reach"], [2, 0.5, &"grab_hold"]]},
	&"held_knee": {"keep_hold": true, "timed": Vector3(0.4, 0.15, 0.45), "keys": [[0, 0.5, &"hknee_cock"], [1, 0.0, &"hknee_hit", &"snap"], [1, 1.0, &"hknee_hit"], [2, 0.5, &"hknee_cock"]]},
	&"body_slam": {"timed": Vector3(0.55, 0.15, 0.3), "keys": [[0, 0.6, &"bslam_lift"], [1, 0.0, &"bslam_hit", &"snap"], [1, 1.0, &"bslam_hit"], [2, 0.55, &"slam_rise"]]},
	# Defence (Defence: parry, guard, sidestep, teleport).
	&"parry": {"legs": &"free", "timed": Vector3(0.2, 0.3, 0.5), "keys": [[0, 1.0, &"parry_set", &"snap"], [1, 0.6, &"parry_deflect", &"snap"], [1, 1.0, &"parry_deflect"]]},
	&"guard_push": {"keep_hold": true, "timed": Vector3(0.15, 0.35, 0.5), "keys": [[0, 1.0, &"guard_push_hit", &"snap"], [1, 1.0, &"guard_push_hit"], [2, 0.6, &"block"]]},
	&"sidestep_l": {"timed": Vector3(0.3, 0.4, 0.3), "keys": [[0, 1.0, &"sidestep_out", &"snap"], [1, 1.0, &"sidestep_out"]]},
	&"sidestep_r": {"timed": Vector3(0.3, 0.4, 0.3), "keys": [[0, 1.0, &"sidestep_out#m", &"snap"], [1, 1.0, &"sidestep_out#m"]]},
	&"vanish": {"timed": Vector3(0.4, 0.6, 0.0), "keys": [[0, 1.0, &"vanish_burst", &"snap"], [1, 1.0, &"vanish_burst"]]},
	&"appear": {"timed": Vector3(0.3, 0.3, 0.4), "keys": [[0, 0.0, &"appear_land"], [0, 1.0, &"appear_land"], [1, 1.0, &"appear_ready"]]},
	# Reactions (RagdollController stumble / stagger: 2-3 quick steps).
	&"stumble_back": {"steps": 3, "step_dir": Vector3(0, 0, 1), "timed": Vector3(0.12, 0.6, 0.28),
		"keys": [[0, 1.0, &"stumble_back_a", &"snap"], [1, 0.4, &"stumble_back_b"], [1, 0.8, &"stumble_back_a"]]},
	&"stumble_fwd": {"steps": 3, "step_dir": Vector3(0, 0, -1), "timed": Vector3(0.12, 0.6, 0.28),
		"keys": [[0, 1.0, &"stumble_fwd_a", &"snap"], [1, 0.4, &"stumble_fwd_b"], [1, 0.8, &"stumble_fwd_a"]]},
	&"stumble_side_l": {"steps": 3, "step_dir": Vector3(-1, 0, 0), "timed": Vector3(0.12, 0.6, 0.28),
		"keys": [[0, 1.0, &"stumble_side_a", &"snap"], [1, 0.4, &"stumble_side_b"], [1, 0.8, &"stumble_side_a"]]},
	&"stumble_side_r": {"steps": 3, "step_dir": Vector3(1, 0, 0), "timed": Vector3(0.12, 0.6, 0.28),
		"keys": [[0, 1.0, &"stumble_side_a#m", &"snap"], [1, 0.4, &"stumble_side_b#m"], [1, 0.8, &"stumble_side_a#m"]]},
	&"getup_fast": {"timed": Vector3(0.4, 0.3, 0.3), "keys": [[0, 0.0, &"lie_up"], [0, 0.45, &"gfast_tuck"], [0, 1.0, &"gfast_rock", &"snap"],
		[1, 1.0, &"gfast_crouch"], [2, 0.6, &"getup_rise"]]},
	&"getup_fast_down": {"timed": Vector3(0.4, 0.3, 0.3), "keys": [[0, 0.0, &"lie_down"], [0, 0.5, &"getup_down_push"], [0, 1.0, &"gfast_down_spring", &"snap"],
		[1, 1.0, &"gfast_crouch"], [2, 0.6, &"getup_rise"]]},
	# Enemies (startup = the whole tell; the contact key is the first active frame).
	&"e_jab": {"tell": true, "keys": [[0, Vector2(0.2, 0.08), &"e_jab_cock", &"snap", 0.6], [0, Vector2(-0.23, 0.103), &"e_jab_cock"],
		[0, Vector2(-0.155, 0.07), &"e_jab_cock", &"linear"], [1, 0.0, &"e_jab_hit", &"snap"], [1, 1.0, &"e_jab_follow"], [2, 0.45, &"stance"]]},
	&"e_stick_swing": {"tell": true, "keys": [[0, Vector2(0.2, 0.08), &"e_stick_cock", &"snap", 0.6], [0, Vector2(-0.23, 0.103), &"e_stick_cock"],
		[0, Vector2(-0.155, 0.07), &"e_stick_cock", &"linear"], [1, 0.0, &"e_stick_hit", &"snap"], [1, 1.0, &"e_stick_follow"], [2, 0.5, &"stance"]]},
	&"e_stick_thrust": {"tell": true, "keys": [[0, Vector2(0.2, 0.08), &"e_thrust_cock", &"snap", 0.6], [0, Vector2(-0.23, 0.103), &"e_thrust_cock"],
		[0, Vector2(-0.155, 0.07), &"e_thrust_cock", &"linear"], [1, 0.0, &"e_thrust_hit", &"snap"], [1, 1.0, &"e_thrust_hit"], [2, 0.5, &"stance"]]},
	&"e_grab_slam": {"tell": true, "keys": [[0, Vector2(0.2, 0.08), &"e_gslam_cock", &"snap", 0.6], [0, Vector2(-0.23, 0.103), &"e_gslam_cock"],
		[0, Vector2(-0.155, 0.07), &"e_gslam_cock", &"linear"], [1, 0.0, &"e_gslam_hit", &"snap"], [1, 1.0, &"e_gslam_hit"], [2, 0.5, &"e_gslam_cock"]]},
	## The heavy's slam once e_grab_slam connected (lift overhead, drive down).
	&"e_slam": {"timed": Vector3(0.4, 0.15, 0.45), "keys": [[0, 1.0, &"e_gslam_lift"], [1, 0.0, &"e_gslam_down", &"snap"], [1, 1.0, &"e_gslam_down"], [2, 0.5, &"e_gslam_down"]]},
	&"guard": {"legs": &"free", "keys": [[0, 1.0, &"guard", &"snap"], [1, 1.0, &"guard"]]},
	&"sidestep": {"mirror_by_motion": true, "timed": Vector3(0.3, 0.4, 0.3), "keys": [[0, 1.0, &"sidestep_out", &"snap"], [1, 1.0, &"sidestep_out"]]},
	# =========================================================================
	# Round 7 (agent P). Strikes: play_move(id, startup, active, recovery) with
	# Tuning.R7_MOVES frames; the contact key [1, 0.0] lands on the first active
	# frame. A two-stage wind-up ([0, a, load, smooth, 0.7], [0, b, load]) keeps
	# deepening through a long startup. Follow-throughs sit in the first half of
	# the recovery (a hit chains after R7_CHAIN_CUT of it). jab, cross and hook
	# are the Round 5 / Upgrade 2 moves above.
	# =========================================================================
	&"heavy_jab": {"legs": &"free", "keys": [[0, 0.35, &"hjab_load", &"smooth", 0.7], [0, 0.85, &"hjab_load"],
		[1, 0.0, &"hjab_hit", &"snap"], [1, 1.0, &"hjab_hit"], [2, 0.25, &"hjab_follow", &"snap"], [2, 0.7, &"stance"]]},
	&"heavy_cross": {"legs": &"free", "keys": [[0, 0.35, &"hcross_load", &"smooth", 0.7], [0, 0.85, &"hcross_load"],
		[1, 0.0, &"hcross_hit", &"snap"], [1, 1.0, &"hcross_hit"], [2, 0.25, &"hcross_follow", &"snap"], [2, 0.7, &"stance"]]},
	&"heavy_hook": {"legs": &"free", "keys": [[0, 0.35, &"hhook_load", &"smooth", 0.7], [0, 0.85, &"hhook_load"],
		[1, 0.0, &"hhook_hit", &"snap"], [1, 1.0, &"hhook_hit"], [2, 0.25, &"hhook_follow", &"snap"], [2, 0.7, &"stance"]]},
	## Uppercut: from the hip, the contact key under the chin, still rising
	## through the active frames, overhead in the follow-through.
	&"uppercut": {"keys": [[0, 0.5, &"uppercut_cock"], [1, 0.0, &"upc_hit", &"snap"], [1, 1.0, &"uppercut_hit", &"linear"],
		[2, 0.25, &"uppercut_follow", &"snap"], [2, 0.65, &"stance"]]},
	&"gut_punch": {"keys": [[0, 0.5, &"gut_load"], [1, 0.0, &"gut_hit", &"snap"], [1, 1.0, &"gut_hit"],
		[2, 0.25, &"gut_follow", &"snap"], [2, 0.65, &"stance"]]},
	&"leg_kick": {"keys": [[0, 0.55, &"lk_load"], [1, 0.0, &"lk_hit", &"snap"], [1, 1.0, &"lk_hit"],
		[2, 0.22, &"lk_follow", &"snap"], [2, 0.55, &"lk_recoil"], [2, 0.85, &"stance"]]},
	&"front_kick": {"keys": [[0, 0.45, &"fkick_chamber"], [0, 0.82, &"fk_chamber"], [1, 0.0, &"fk_hit", &"snap"], [1, 1.0, &"fk_ext"],
		[2, 0.18, &"fk_follow", &"snap"], [2, 0.45, &"fkick_recoil"], [2, 0.8, &"stance"]]},
	&"roundhouse": {"keys": [[0, 0.45, &"rh_load", &"smooth", 0.75], [0, 0.85, &"rh_load"], [1, 0.0, &"rh_hit", &"snap"], [1, 1.0, &"rh_hit"],
		[2, 0.22, &"rh_follow", &"snap"], [2, 0.55, &"rh_recoil"], [2, 0.85, &"stance"]]},
	## Heavy kicks (the held kick buttons): a longer load, the same contact
	## point as the light kick, a bigger follow-through.
	&"heavy_leg_kick": {"keys": [[0, 0.35, &"hlk_load", &"smooth", 0.7], [0, 0.68, &"hlk_load"], [0, 0.88, &"lk_load"],
		[1, 0.0, &"hlk_hit", &"snap"], [1, 1.0, &"hlk_hit"], [2, 0.25, &"hlk_follow", &"snap"], [2, 0.55, &"lk_recoil"], [2, 0.85, &"stance"]]},
	&"heavy_front_kick": {"keys": [[0, 0.3, &"fkick_chamber"], [0, 0.55, &"hfk_chamber"], [0, 0.86, &"hfk_chamber", &"linear"],
		[1, 0.0, &"hfk_hit", &"snap"], [1, 1.0, &"fk_ext"], [2, 0.22, &"hfk_follow", &"snap"], [2, 0.5, &"fkick_recoil"], [2, 0.82, &"stance"]]},
	&"heavy_roundhouse": {"keys": [[0, 0.3, &"hrh_coil", &"smooth", 0.8], [0, 0.55, &"hrh_coil"], [0, 0.86, &"rh_load"],
		[1, 0.0, &"hrh_hit", &"snap"], [1, 1.0, &"hrh_hit"], [2, 0.25, &"hrh_follow", &"snap"], [2, 0.55, &"hrh_recoil"], [2, 0.85, &"stance"]]},
	## Counter: the lead hand catches (hold &"counter_catch" through a glide),
	## then pulls in as the rear hand lands.
	&"counter": {"legs": &"free", "keys": [[0, 0.6, &"counter_catch", &"snap"], [1, 0.0, &"counter_hit", &"snap"], [1, 1.0, &"counter_hit"],
		[2, 0.25, &"counter_follow", &"snap"], [2, 0.65, &"stance"]]},
	## Dodge (play_timed over R7_DODGE_TIME): a crouched slip, head off the line
	## (to the left; mirrored when moving right); the legs take two quick steps
	## along the motion.
	&"dodge": {"steps": 2, "step_dir": Vector3(0, 0, 1), "mirror_by_motion": true, "timed": Vector3(0.2, 0.5, 0.3),
		"keys": [[0, 1.0, &"dodge_duck", &"snap"], [1, 1.0, &"dodge_duck"], [2, 0.5, &"dodge_rise"]]},
	## Glide (play_timed over the glide, or hold_pose(&"glide")): the upper body
	## pitches into the run-in, the legs run the locomotion's sprint.
	&"glide": {"legs": &"free", "timed": Vector3(0.2, 0.65, 0.15), "keys": [[0, Vector2(1.0, 0.06), &"glide_lean", &"snap"], [1, 1.0, &"glide_lean"]]},
	## Throw release from the throw_windup hold: the arm comes over the top and
	## whips through; the body is let go on the first active frame.
	&"throw_release": {"timed": Vector3(0.3, 0.15, 0.55), "keys": [[0, 0.55, &"throw_whip"], [1, 0.0, &"throw_rel", &"snap"], [1, 1.0, &"throw_rel"],
		[2, 0.3, &"throw_rel_follow", &"snap"], [2, 0.75, &"stance"]]},
	# Reactions: play_timed(id, stun). The first pose lands within 0.05-0.07 s
	# whatever the stun ("Vector2" keys); "steps" = stumble steps from the
	# locomotion (along the push slide, else `step_dir`). fold / buckle / lift
	# are also HOLDS (hold_pose); their moves are the same states, timed.
	&"react_snap": {"steps": 2, "step_dir": Vector3(0, 0, 1), "timed": Vector3(0.1, 0.55, 0.35),
		"keys": [[0, Vector2(1.0, 0.05), &"react_snap_a", &"snap"], [1, 0.3, &"react_snap_a"], [1, 1.0, &"react_snap_b"]]},
	## Spin: turned to the victim's left (a left hook to the right cheek);
	## react_spin_r is the mirror (hit from the other side).
	&"react_spin": {"steps": 2, "step_dir": Vector3(-0.5, 0, 0.85), "timed": Vector3(0.1, 0.55, 0.35),
		"keys": [[0, Vector2(1.0, 0.05), &"react_spin_a", &"snap"], [1, 0.45, &"react_spin_b"], [1, 1.0, &"react_spin_b"]]},
	&"react_spin_r": {"steps": 2, "step_dir": Vector3(0.5, 0, 0.85), "timed": Vector3(0.1, 0.55, 0.35),
		"keys": [[0, Vector2(1.0, 0.05), &"react_spin_a#m", &"snap"], [1, 0.45, &"react_spin_b#m"], [1, 1.0, &"react_spin_b#m"]]},
	&"react_push": {"steps": 3, "step_dir": Vector3(0, 0, 1), "timed": Vector3(0.08, 0.62, 0.3),
		"keys": [[0, Vector2(1.0, 0.05), &"react_push_a", &"snap"], [1, 0.33, &"react_push_b"], [1, 0.66, &"react_push_a"], [1, 1.0, &"react_push_b"]]},
	&"react_fold": {"timed": Vector3(0.08, 0.77, 0.15),
		"keys": [[0, Vector2(1.0, 0.06), &"react_fold_a", &"snap"], [1, 0.5, &"react_fold_b"], [1, 1.0, &"react_fold_a"]]},
	&"react_buckle": {"timed": Vector3(0.08, 0.72, 0.2),
		"keys": [[0, Vector2(1.0, 0.07), &"react_buckle_a", &"snap"], [1, 0.5, &"react_buckle_b"], [1, 1.0, &"react_buckle_a"]]},
	&"react_lift": {"timed": Vector3(0.06, 0.84, 0.1),
		"keys": [[0, Vector2(1.0, 0.05), &"react_lift_rise", &"snap"], [1, 0.35, &"react_lift_fall"], [1, 1.0, &"react_lift_fall"]]},
}

## play_timed() split of a move's length into startup / active / recovery when
## the move gives no "timed" split of its own.
const TIMED_SPLIT := Vector3(0.3, 0.2, 0.5)

## Held poses: a static pose, or a loop between poses at `rate` Hz.
const HOLDS := {
	&"block": {"poses": [&"block"], "crouch": &"block_crouch"},
	&"power_charge": {"poses": [&"power_charge"], "tremble": 1.6},
	&"grab_hold": {"poses": [&"grab_hold"]},
	&"held": {"poses": [&"held_a", &"held_b"], "rate": 2.6},
	&"stagger": {"poses": [&"stagger_a", &"stagger_b"], "rate": 2.2},
	&"guard": {"poses": [&"guard"]},
	&"fall": {"poses": [&"fall_a", &"fall_b"], "rate": 1.4},
	&"wall_splat": {"poses": [&"wall_splat"]},
	# --- Upgrade 2 -------------------------------------------------------------------
	&"crouch": {"poses": [&"crouch"]},
	&"crouch_walk": {"poses": [&"crouch"]},
	&"block_crouch": {"poses": [&"block_crouch"]},
	&"jump_rise": {"poses": [&"jump_rise"]},
	&"jump_fall": {"poses": [&"jump_fall"]},
	&"land": {"poses": [&"land"]},
	&"stumble": {"poses": [&"stumble_a", &"stumble_b"], "rate": 2.4},
	&"dazed": {"poses": [&"dazed_a", &"dazed_b"], "rate": 0.8},
	&"headlock": {"poses": [&"headlock"]},
	&"arm_drag": {"poses": [&"arm_drag"]},
	&"giant_swing": {"poses": [&"giant_swing"]},
	# Charge holds: frozen at the end of the wind-up; tremble and coil grow with
	# PoseAnimator.set_charge_level(). "coil" = chest Euler degrees per level.
	&"jab1_charge": {"poses": [&"jab1_charge"], "charge": true, "coil": Vector3(0, 4, 0)},
	&"cross_charge": {"poses": [&"cross_charge"], "charge": true, "coil": Vector3(0, -4, 0)},
	&"hook_charge": {"poses": [&"hook_charge"], "charge": true, "coil": Vector3(0, 4, 0)},
	&"uppercut_charge": {"poses": [&"uppercut_charge"], "charge": true, "coil": Vector3(-3, -3, 0)},
	&"sparta_kick_charge": {"poses": [&"sparta_kick_charge"], "charge": true, "coil": Vector3(4, 0, 0)},
	&"roundhouse_charge": {"poses": [&"roundhouse_charge"], "charge": true, "coil": Vector3(0, -4, 2)},
	&"leg_sweep_charge": {"poses": [&"leg_sweep_charge"], "charge": true, "coil": Vector3(0, -3, 0)},
	&"crouch_punch_charge": {"poses": [&"crouch_punch_charge"], "charge": true, "coil": Vector3(0, -4, 0)},
	&"flying_kick_charge": {"poses": [&"flying_kick_charge"], "charge": true, "coil": Vector3(-3, 0, 0)},
	&"hammer_fist_charge": {"poses": [&"hammer_fist_charge"], "charge": true, "coil": Vector3(4, 0, 0)},
	&"backfist_charge": {"poses": [&"backfist_charge"], "charge": true, "coil": Vector3(0, 4, 0)},
	&"neutral": {"poses": [&"neutral"]},
	# --- Round 5 ---------------------------------------------------------------------
	&"jab_charge": {"poses": [&"jab_charge"], "charge": true, "coil": Vector3(0, -4, 0)},
	&"kick_charge": {"poses": [&"kick_charge"], "charge": true, "coil": Vector3(4, 0, 0)},
	&"sweep_charge": {"poses": [&"leg_sweep_charge"], "charge": true, "coil": Vector3(0, -3, 0)},
	&"throw_charge": {"poses": [&"throw_charge"], "charge": true, "coil": Vector3(0, -4, 0)},
	&"carry_hold": {"poses": [&"carry_hold"]},
	&"hold_idle": {"poses": [&"carry_hold"]},
	# --- Round 7 ---------------------------------------------------------------------
	# "legs": &"free" = the legs keep the locomotion while moving (a drive runs
	# the carry style's sprint). "blend_max": s the hold blends in at most,
	# whatever hold_pose() is given (reactions land with the hit). "ramp": s to
	# blend poses[0] -> poses[1] once, then hold (the throw wind-up grows to
	# full at Tuning.R7_THROW_WINDUP_FULL). "by_vy": poses[0] while rising,
	# poses[1] at the top and falling (the rig's vertical speed). "flail":
	# degrees of slow loose-limb wobble on the arms and legs.
	&"throw_windup": {"poses": [&"throw_wu_a", &"throw_wu_b"], "ramp": 0.7, "legs": &"free", "tremble": 0.8},
	&"drive_hold": {"poses": [&"drive_lean"], "legs": &"free"},
	&"clinch_hold": {"poses": [&"clinch"], "legs": &"free"},
	&"glide": {"poses": [&"glide_lean"], "legs": &"free"},
	&"counter_catch": {"poses": [&"counter_catch"], "legs": &"free", "blend_max": 0.04},
	# Heavy wind-ups held while the punch button waits for the hold decision
	# (play_move(&"heavy_*", startup_left, ...) then carries on from here).
	&"heavy_jab_load": {"poses": [&"hjab_load"], "legs": &"free", "tremble": 0.6},
	&"heavy_cross_load": {"poses": [&"hcross_load"], "legs": &"free", "tremble": 0.6},
	&"heavy_hook_load": {"poses": [&"hhook_load"], "legs": &"free", "tremble": 0.6},
	&"heavy_leg_kick_load": {"poses": [&"hlk_load"], "tremble": 0.6},
	&"heavy_front_kick_load": {"poses": [&"hfk_chamber"], "tremble": 0.6},
	&"heavy_roundhouse_load": {"poses": [&"hrh_coil"], "tremble": 0.6},
	&"react_fold": {"poses": [&"react_fold_a", &"react_fold_b"], "rate": 1.4, "blend_max": 0.06},
	&"react_buckle": {"poses": [&"react_buckle_a", &"react_buckle_b"], "rate": 1.0, "blend_max": 0.07},
	&"react_lift": {"poses": [&"react_lift_rise", &"react_lift_fall"], "by_vy": true, "flail": 8.0, "blend_max": 0.05},
}

const ALL_MOVE_IDS: Array[StringName] = [&"jab1", &"jab2", &"jab3", &"power_punch", &"sparta_kick",
	&"leg_sweep", &"grab", &"throw", &"back_kick", &"dash", &"block_hit", &"dodge", &"getup_face_up",
	&"getup_face_down", &"e_hook", &"e_heavy", &"e_kick", &"e_grab", &"e_charge", &"e_throw_debris",
	&"grab_break_push", &"taunt", &"punt",
	&"cross", &"hook", &"uppercut", &"roundhouse", &"backfist", &"flying_kick", &"hammer_fist",
	&"crouch_punch", &"rising_uppercut", &"knee", &"headbutt", &"neck_throw", &"mount_punch", &"stomp",
	&"upward_throw", &"wall_slam", &"e_sweep", &"stumble", &"dazed", &"land"]
const ALL_HOLD_IDS: Array[StringName] = [&"block", &"power_charge", &"grab_hold", &"held", &"stagger",
	&"guard", &"fall", &"neutral", &"wall_splat",
	&"crouch", &"crouch_walk", &"block_crouch", &"jump_rise", &"jump_fall", &"land", &"stumble", &"dazed",
	&"headlock", &"arm_drag", &"giant_swing"]

## Round 5 ids (Feel Reference "New animations needed"); ALL_MOVE_IDS /
## ALL_HOLD_IDS above stay the older rounds' lists (the lab and A's tests).
const ROUND5_MOVE_IDS: Array[StringName] = [&"jab", &"cross", &"kick", &"sweep", &"knee", &"elbow",
	&"ground_stomp", &"knee_drop", &"drop_strike", &"slam",
	&"sprint_start", &"vault_speed", &"mantle", &"wall_kickoff", &"land_three_point", &"land_roll", &"land_crouch",
	&"grab_lunge", &"held_knee", &"headbutt", &"throw", &"body_slam",
	&"parry", &"guard_push", &"sidestep_l", &"sidestep_r", &"vanish", &"appear",
	&"stumble_fwd", &"stumble_back", &"stumble_side_l", &"stumble_side_r", &"getup_fast", &"getup_fast_down",
	&"e_jab", &"e_hook", &"e_kick", &"e_grab", &"e_stick_swing", &"e_stick_thrust", &"e_heavy", &"e_charge",
	&"e_grab_slam", &"e_slam", &"sidestep", &"guard"]
const ROUND5_HOLD_IDS: Array[StringName] = [&"jab_charge", &"cross_charge", &"kick_charge", &"sweep_charge",
	&"throw_charge", &"carry_hold", &"hold_idle", &"guard"]

## Round 7 ids (docs/Round 7 — Freeflow Combat.md "Poses"). Strikes take
## Tuning.R7_MOVES frame data in play_move(); the rest are play_timed() moves.
const ROUND7_STRIKE_IDS: Array[StringName] = [&"jab", &"cross", &"hook", &"heavy_jab", &"heavy_cross",
	&"heavy_hook", &"uppercut", &"gut_punch", &"leg_kick", &"front_kick", &"roundhouse", &"counter",
	&"heavy_leg_kick", &"heavy_front_kick", &"heavy_roundhouse"]
const ROUND7_MOVE_IDS: Array[StringName] = [&"jab", &"cross", &"hook", &"heavy_jab", &"heavy_cross",
	&"heavy_hook", &"uppercut", &"gut_punch", &"leg_kick", &"front_kick", &"roundhouse", &"counter",
	&"heavy_leg_kick", &"heavy_front_kick", &"heavy_roundhouse",
	&"dodge", &"glide", &"throw_release", &"react_snap", &"react_spin", &"react_spin_r", &"react_push",
	&"react_fold", &"react_buckle", &"react_lift"]
## Round 7 holds (hold_pose; the throw wind-up and the body holds also work as
## set_upper_overlay). react_fold / react_buckle / react_lift are moves too.
const ROUND7_HOLD_IDS: Array[StringName] = [&"throw_windup", &"drive_hold", &"clinch_hold", &"glide",
	&"counter_catch", &"heavy_jab_load", &"heavy_cross_load", &"heavy_hook_load",
	&"heavy_leg_kick_load", &"heavy_front_kick_load", &"heavy_roundhouse_load",
	&"react_fold", &"react_buckle", &"react_lift"]

## Every move id (older rounds, Round 5 and Round 7).
static func all_move_ids() -> Array[StringName]:
	var out: Array[StringName] = ALL_MOVE_IDS.duplicate()
	for id in ROUND5_MOVE_IDS + ROUND7_MOVE_IDS:
		if not out.has(id):
			out.append(id)
	return out

## Moves with a held &"<id>_charge" pose (Upgrade 2: hold any attack to charge).
const CHARGEABLE: Array[StringName] = [&"jab1", &"cross", &"hook", &"uppercut", &"sparta_kick",
	&"roundhouse", &"leg_sweep", &"crouch_punch", &"flying_kick", &"hammer_fist", &"backfist",
	&"jab", &"kick", &"sweep", &"throw"]

## Hold id of a move's charge pose (&"" if the move has none).
static func charge_hold_of(move_id: StringName) -> StringName:
	var h := StringName(String(move_id) + "_charge")
	return h if HOLDS.has(h) else &""

## Moves that ignore PoseAnimator.set_aim_target (a floor sweep must stay on
## the floor; a throw flings where the grabber faces).
const NO_AIM: Array[StringName] = [&"leg_sweep", &"throw", &"backfist", &"e_sweep", &"neck_throw",
	&"upward_throw", &"wall_slam", &"sweep", &"slam", &"body_slam", &"e_grab_slam"]

## Moves whose height is the point of the move: set_aim_target turns them
## toward the target but never raises or lowers them (a gut punch stays at the
## stomach, a leg kick at the thigh, a roundhouse at the head).
const AIM_YAW_ONLY: Array[StringName] = [&"uppercut", &"gut_punch", &"leg_kick", &"front_kick", &"roundhouse",
	&"heavy_leg_kick", &"heavy_front_kick", &"heavy_roundhouse"]

## IK target keys of each strike bone (aiming).
const AIM_LIMB := {&"LeftHand": "lfist", &"RightHand": "rfist", &"LeftFoot": "lankle", &"RightFoot": "rankle"}

## A compiled pose: local rotations for the bones it defines (null otherwise).
class Pose:
	var rot: Array = []          ## 16 entries: Quaternion or null
	var has_pos := false
	var pos := Vector3.ZERO      ## hips offset (unit scale)
	var hips_yaw := 0.0          ## radians (body frame of the IK targets)
	var defines_legs := [false, false]

static var _cache := {}
static var _warm := false

## Compile every pose (and every mirrored one a move uses) once, so no move
## pays for its first compile mid-fight (~20 ms in all; PoseAnimator.setup).
static func warm() -> void:
	if _warm:
		return
	_warm = true
	for pn in POSES:
		get_pose(pn)
	for id in MOVES:
		for k in MOVES[id]["keys"]:
			get_pose(k[2])

static func has_pose(pose_name: StringName) -> bool:
	return POSES.has(pose_name)

## True if play_move() knows this move id.
static func has_move(id: StringName) -> bool:
	return MOVES.has(id)

## Compiled pose by name; "<name>#m" is the left/right mirror.
static func get_pose(pose_name: StringName) -> Pose:
	if _cache.has(pose_name):
		return _cache[pose_name]
	var p: Pose
	var s := String(pose_name)
	if s.ends_with("#m"):
		p = mirror(get_pose(StringName(s.trim_suffix("#m"))))
	else:
		p = compile(POSES.get(pose_name, {}))
	_cache[pose_name] = p
	return p

static func mirror(src: Pose) -> Pose:
	var p := Pose.new()
	p.rot.resize(HumanoidRig.BONE_COUNT)
	for i in HumanoidRig.BONE_COUNT:
		var b: StringName = Bones.ALL[i]
		var sb := b
		if String(b).begins_with("Left"):
			sb = StringName("Right" + String(b).substr(4))
		elif String(b).begins_with("Right"):
			sb = StringName("Left" + String(b).substr(5))
		var q = src.rot[HumanoidRig.bone_index(sb)]
		if q != null:
			var qq: Quaternion = q
			p.rot[i] = Quaternion(qq.x, -qq.y, -qq.z, qq.w)
	p.has_pos = src.has_pos
	p.pos = Vector3(-src.pos.x, src.pos.y, src.pos.z)
	p.hips_yaw = -src.hips_yaw
	p.defines_legs = [src.defines_legs[1], src.defines_legs[0]]
	return p

static func euler_q(deg: Vector3) -> Quaternion:
	return Quaternion.from_euler(deg * (PI / 180.0))

# --- Joint limits (Round 5: every compiled pose sits inside the ragdoll's soft
# ranges, HumanoidRig.JOINT_LIMITS, so the muscles never pull against them) ---
## Degrees kept inside each soft range when fitting a pose.
const LIMIT_MARGIN := 2.0
## Shortest distance shoulder -> fist and hip -> ankle the IK accepts: the
## elbow and knee never fold past ~145 degrees (their hinge range is 0..150).
const IK_MIN_REACH_ARM := 0.175
const IK_MIN_REACH_LEG := 0.225
## Degrees of shoulder / hip swing the IK avoids when a swivel allows it:
## near 180 the swing / twist split the ragdoll measures limits with turns
## ill-conditioned (a few degrees of tremble flip the twist).
const SWING_SOFT_MAX := 150.0
## Elbow / knee swivel steps tried (degrees about the shoulder->target line)
## when the pole would twist the upper bone out of its range.
const SWIVEL_STEP := 10.0

## Shortest rotation vector (axis * angle, radians).
static func rotvec(q: Quaternion) -> Vector3:
	if q.w < 0.0:
		q = -q
	var v := Vector3(q.x, q.y, q.z)
	var s := v.length()
	if s < 0.000001:
		return v * 2.0
	return v * (2.0 * atan2(s, q.w) / s)

static func from_rotvec(v: Vector3) -> Quaternion:
	var a := v.length()
	if a < 0.000001:
		return Quaternion.IDENTITY
	return Quaternion(v / a, a)

## Joint angles (radians) as RagdollController measures them: hinges by the
## rotation vector; cones by swing X / Z and twist about the bone (Y).
static func joint_angles(bone: StringName, q: Quaternion) -> Vector3:
	var spec: Dictionary = HumanoidRig.JOINT_LIMITS[bone]
	if spec["type"] == &"hinge":
		return rotvec(q)
	var tq := Quaternion(0.0, q.y, 0.0, q.w)
	var tl := tq.length()
	var twist := 0.0
	var swing := q
	if tl > 0.000001:
		tq = tq / tl
		twist = wrapf(2.0 * atan2(tq.y, tq.w), -PI, PI)
		swing = q * tq.inverse()
	var sv := rotvec(swing)
	return Vector3(sv.x, twist, sv.z)

## Swing X, twist (about the bone, Y) and swing Z of `q`, radians.
static func swing_twist(q: Quaternion) -> Vector3:
	var tq := Quaternion(0.0, q.y, 0.0, q.w)
	var tl := tq.length()
	if tl < 0.000001:
		var sv0 := rotvec(q)
		return Vector3(sv0.x, 0.0, sv0.z)
	tq = tq / tl
	var sv := rotvec(q * tq.inverse())
	return Vector3(sv.x, wrapf(2.0 * atan2(tq.y, tq.w), -PI, PI), sv.z)

## 0 = no joint limit (hips), 1 = cone, 2 = hinge; by Bones.ALL index.
static var _jtype: PackedInt32Array = PackedInt32Array()

static func joint_type(i: int) -> int:
	if _jtype.is_empty():
		_jtype.resize(HumanoidRig.BONE_COUNT)
		for k in HumanoidRig.BONE_COUNT:
			var spec = HumanoidRig.JOINT_LIMITS.get(Bones.ALL[k])
			_jtype[k] = 0 if spec == null else (2 if spec["type"] == &"hinge" else 1)
	return _jtype[i]

## Blend two local rotations of bone `i` in joint space: a cone's swing
## (X / Z) and twist blend separately, a hinge by its angle. A blend between
## two legal poses then stays legal (a plain slerp between far-apart arm
## rotations can swing round through the far side of the shoulder).
## Close rotations take the plain slerp (same result, cheaper).
static func jslerp(i: int, a: Quaternion, b: Quaternion, f: float) -> Quaternion:
	if f <= 0.0:
		return a
	if f >= 1.0:
		return b
	if absf(a.dot(b)) > 0.97:
		return a.slerp(b, f)
	match joint_type(i):
		1:
			var j := swing_twist(a).lerp(swing_twist(b), f)
			return from_rotvec(Vector3(j.x, 0.0, j.z)) * Quaternion(Vector3.UP, j.y)
		2:
			return Quaternion(Vector3.RIGHT, lerpf(rotvec(a).x, rotvec(b).x, f))
	return a.slerp(b, f)

## Degrees by which `q` lies outside the bone's soft range shrunk by `margin`.
static func limit_excess(bone: StringName, q: Quaternion, margin := 0.0) -> float:
	if not HumanoidRig.JOINT_LIMITS.has(bone):
		return 0.0
	var spec: Dictionary = HumanoidRig.JOINT_LIMITS[bone]
	var a := joint_angles(bone, q) * (180.0 / PI)
	var ex := _range_out(a.x, spec["x"], margin)
	if spec["type"] != &"hinge":
		ex = maxf(ex, _range_out(a.y, spec["y"], margin))
		ex = maxf(ex, _range_out(a.z, spec["z"], margin))
	return ex

static func _range_out(v: float, r: Vector2, m: float) -> float:
	if v < r.x + m:
		return r.x + m - v
	if v > r.y - m:
		return v - (r.y - m)
	return 0.0

## `q` moved into the bone's soft range (minus LIMIT_MARGIN): hinges keep only
## their X rotation; cones clamp swing X / Z and the twist separately.
static func clamp_joint(bone: StringName, q: Quaternion) -> Quaternion:
	if not HumanoidRig.JOINT_LIMITS.has(bone):
		return q
	var spec: Dictionary = HumanoidRig.JOINT_LIMITS[bone]
	var m := deg_to_rad(LIMIT_MARGIN)
	var k := PI / 180.0
	var xr: Vector2 = spec["x"] * k
	if spec["type"] == &"hinge":
		return Quaternion(Vector3.RIGHT, clampf(rotvec(q).x, xr.x + m, xr.y - m))
	var yr: Vector2 = spec["y"] * k
	var zr: Vector2 = spec["z"] * k
	var a := joint_angles(bone, q)
	var sx := clampf(a.x, xr.x + m, xr.y - m)
	var tw := clampf(a.y, yr.x + m, yr.y - m)
	var sz := clampf(a.z, zr.x + m, zr.y - m)
	if is_equal_approx(sx, a.x) and is_equal_approx(tw, a.y) and is_equal_approx(sz, a.z):
		return q
	return from_rotvec(Vector3(sx, 0.0, sz)) * Quaternion(Vector3.UP, tw)

## Torso Euler values fitted to the spine / chest / head ranges: a chest
## turn or bend past its range moves into the spine (the body turns from the
## waist), the rest is clamped later.
static func _fit_torso(d: Dictionary) -> Dictionary:
	if not d.has("chest"):
		return d
	var chest: Vector3 = d["chest"]
	var spine: Vector3 = d.get("spine", Vector3.ZERO)
	var cl: Dictionary = HumanoidRig.JOINT_LIMITS[&"Chest"]
	var sl: Dictionary = HumanoidRig.JOINT_LIMITS[&"Spine"]
	var moved := false
	for ax: int in [0, 1]:   # x (bend), y (turn)
		var key := "x" if ax == 0 else "y"
		var cr: Vector2 = cl[key]
		var sr: Vector2 = sl[key]
		var c: float = chest[ax]
		var lo := cr.x + LIMIT_MARGIN
		var hi := cr.y - LIMIT_MARGIN
		var over := c - clampf(c, lo, hi)
		if absf(over) > 0.01:
			var s: float = spine[ax]
			var s2 := clampf(s + over, sr.x + LIMIT_MARGIN, sr.y - LIMIT_MARGIN)
			chest[ax] = c - (s2 - s)
			spine[ax] = s2
			moved = true
	if not moved:
		return d
	var d2 := d.duplicate()
	d2["chest"] = chest
	d2["spine"] = spine
	return d2

static func compile(src: Dictionary) -> Pose:
	var d := _fit_torso(src)
	var p := Pose.new()
	p.rot.resize(HumanoidRig.BONE_COUNT)
	for key in ALIAS:
		if d.has(key):
			p.rot[HumanoidRig.bone_index(ALIAS[key])] = euler_q(d[key])
	# Explicit torso / limb rotations are clamped before the IK uses them.
	for i in range(1, HumanoidRig.BONE_COUNT):
		if p.rot[i] != null:
			p.rot[i] = clamp_joint(Bones.ALL[i], p.rot[i])
	if d.has("pos"):
		p.has_pos = true
		p.pos = d["pos"]
	var hips_e: Vector3 = d.get("hips", Vector3.ZERO)
	p.hips_yaw = deg_to_rad(hips_e.y)
	var hips_q: Quaternion = p.rot[0] if p.rot[0] != null else Quaternion.IDENTITY
	var hips_xf := Transform3D(Basis(hips_q), HumanoidRig.REST[&"Hips"] + p.pos)
	var spine_q: Quaternion = p.rot[1] if p.rot[1] != null else Quaternion.IDENTITY
	var chest_q: Quaternion = p.rot[2] if p.rot[2] != null else Quaternion.IDENTITY
	var spine_xf := hips_xf * Transform3D(Basis(spine_q), HumanoidRig.REST[&"Spine"])
	var chest_xf := spine_xf * Transform3D(Basis(chest_q), HumanoidRig.REST[&"Chest"])
	var yaw := Basis(Vector3.UP, p.hips_yaw) if d.get("frame", &"char") == &"body" else Basis()
	var origin := Vector3(hips_xf.origin.x, 0.0, hips_xf.origin.z) if d.get("frame", &"char") == &"body" else Vector3.ZERO
	for side in [0, 1]:
		var pre := "l" if side == 0 else "r"
		var bside := "Left" if side == 0 else "Right"
		if d.has(pre + "fist"):
			var target: Vector3 = origin + yaw * (d[pre + "fist"] as Vector3)
			var pole: Vector3 = yaw * (d.get(pre + "elbow", Vector3(0.4 * (1 if side else -1), -1, 0.3)) as Vector3)
			var ua := HumanoidRig.bone_index(StringName(bside + "UpperArm"))
			var shoulder := chest_xf * (HumanoidRig.REST[StringName(bside + "UpperArm")] as Vector3)
			var res := _limb_ik(chest_xf.basis, Bones.ALL[ua], shoulder, target, IK_ARM_UPPER, IK_ARM_LOWER, pole, true)
			if p.rot[ua] == null:
				p.rot[ua] = res[0]
			if p.rot[ua + 1] == null:
				p.rot[ua + 1] = Quaternion(Vector3.RIGHT, res[1])
			if p.rot[ua + 2] == null:
				p.rot[ua + 2] = Quaternion.IDENTITY
		if d.has(pre + "ankle"):
			var target: Vector3 = origin + yaw * (d[pre + "ankle"] as Vector3)
			var pole: Vector3 = yaw * (d.get(pre + "knee", Vector3(0.1 * (1 if side else -1), 0, -1)) as Vector3)
			var pitch := deg_to_rad(float(d.get(pre + "fp", 0.0)))
			var rots := leg_ik(hips_xf, side, target, pole, p.hips_yaw, pitch, true)
			var ul := HumanoidRig.bone_index(StringName(bside + "UpperLeg"))
			for k in 3:
				if p.rot[ul + k] == null:
					p.rot[ul + k] = rots[k]
		p.defines_legs[side] = p.rot[HumanoidRig.bone_index(StringName(bside + "UpperLeg"))] != null
	for i in range(1, HumanoidRig.BONE_COUNT):
		if p.rot[i] != null:
			p.rot[i] = clamp_joint(Bones.ALL[i], p.rot[i])
	return p

## Two-bone IK for a limb whose upper bone hangs from `parent_basis` (pose
## space): returns [upper bone local rotation, bend angle]. When the pole
## would twist or swing the upper bone out of its range, the elbow / knee
## swivels about the shoulder->target line to the nearest legal plane (the
## fist / ankle stays on target).
static func _limb_ik(parent_basis: Basis, bone: StringName, s: Vector3, t: Vector3, a: float, b: float,
		pole: Vector3, is_arm: bool) -> Array:
	var axis := t - s
	axis = axis.normalized() if axis.length_squared() > 0.000001 else Vector3.DOWN
	var inv := parent_basis.inverse()
	var best: Array = []
	var best_ex := INF
	var steps := int(180.0 / SWIVEL_STEP)
	for n in steps * 2 + 1:
		var k := ceili(n / 2.0) * (1 if n % 2 == 1 else -1)
		var pk := pole if k == 0 else pole.rotated(axis, deg_to_rad(SWIVEL_STEP * k))
		var res := solve_ik(s, t, a, b, pk, is_arm)
		var q := Quaternion((inv * (res[0] as Basis)).orthonormalized())
		var ex := limit_excess(bone, q, LIMIT_MARGIN)
		var st := swing_twist(q)
		ex += maxf(rad_to_deg(Vector2(st.x, st.z).length()) - SWING_SOFT_MAX, 0.0) * 0.5
		if ex < best_ex - 0.01:
			best_ex = ex
			best = [q, res[1]]
		if ex <= 0.0:
			break
	return best

## Two-bone IK. Returns [upper bone global Basis, bend angle (rad, >= 0)].
## The elbow/knee points toward `pole`. Arms bend toward bone-local -Z
## (elbow +X), legs toward +Z (knee -X). The bend never passes ~145 degrees.
static func solve_ik(s: Vector3, t: Vector3, a: float, b: float, pole: Vector3, is_arm: bool) -> Array:
	var dv := t - s
	var d := dv.length()
	var dir := dv / d if d > 0.0001 else Vector3.DOWN
	d = clampf(d, maxf(absf(a - b) + 0.02, IK_MIN_REACH_ARM if is_arm else IK_MIN_REACH_LEG), (a + b) * 0.998)
	var pp := pole - dir * pole.dot(dir)
	if pp.length_squared() < 0.000001:
		pp = Vector3.FORWARD - dir * dir.z
		if pp.length_squared() < 0.000001:
			pp = Vector3.RIGHT
	var bend := pp.normalized()
	var cos_a := clampf((a * a + d * d - b * b) / (2.0 * a * d), -1.0, 1.0)
	var u := dir * cos_a + bend * sqrt(maxf(0.0, 1.0 - cos_a * cos_a))
	var e := s + u * a
	var v := ((s + dir * d) - e).normalized()
	var w := v - u * v.dot(u)
	if w.length_squared() < 0.00000001:
		w = -bend
	else:
		w = w.normalized()
	var y := -u
	var z := -w if is_arm else w
	var x := y.cross(z)
	var ang := acos(clampf(u.dot(v), -1.0, 1.0))
	return [Basis(x, y, z).orthonormalized(), ang]

## Leg IK in pose space. Returns [thigh, shin, foot] local quaternions. The
## foot keeps `pitch` (+ toes up) as far as the ankle hinge allows (the heel
## lifts in a deep crouch). `limited` also swivels the knee so the thigh
## stays in range (compile time; locomotion skips it every tick).
static func leg_ik(hips_xf: Transform3D, side: int, ankle: Vector3, pole: Vector3, yaw: float, pitch: float,
		limited := false) -> Array:
	var r := _leg_ik_once(hips_xf, side, ankle, pole, yaw, pitch, limited)
	# The ankle ran out of range and tipped the sole below where the wanted
	# pitch puts it (a trailing foot flat on the floor needs more dorsiflexion
	# than the ankle has): lift the heel instead, the toe stays on the floor.
	var drop: float = r[3]
	if drop > 0.001:
		r = _leg_ik_once(hips_xf, side, ankle + Vector3.UP * drop, pole, yaw, pitch, limited)
	return [r[0], r[1], r[2]]

## Sole points (ankle-relative, foot frame): toe and heel bottom.
const SOLE_TOE := Vector3(0, -0.08, -0.17)
const SOLE_HEEL := Vector3(0, -0.08, 0.07)

static func _leg_ik_once(hips_xf: Transform3D, side: int, ankle: Vector3, pole: Vector3, yaw: float, pitch: float,
		limited: bool) -> Array:
	var bside := "Left" if side == 0 else "Right"
	var hip := hips_xf * (HumanoidRig.REST[StringName(bside + "UpperLeg")] as Vector3)
	var thigh_q: Quaternion
	var bend: float
	if limited:
		var r := _limb_ik(hips_xf.basis, StringName(bside + "UpperLeg"), hip, ankle, IK_LEG_UPPER, IK_LEG_LOWER, pole, false)
		thigh_q = r[0]
		bend = r[1]
	else:
		var res := solve_ik(hip, ankle, IK_LEG_UPPER, IK_LEG_LOWER, pole, false)
		thigh_q = Quaternion((hips_xf.basis.inverse() * (res[0] as Basis)).orthonormalized())
		bend = res[1]
	var thigh_g := hips_xf.basis * Basis(thigh_q)
	var shin_local := Quaternion(Vector3.RIGHT, -bend)
	var shin_g := thigh_g * Basis(shin_local)
	var foot_g := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch)
	var foot_q := Quaternion((shin_g.inverse() * foot_g).orthonormalized())
	# Ankle hinge: X only, inside its range.
	var fl: Vector2 = HumanoidRig.JOINT_LIMITS[StringName(bside + "Foot")]["x"] * (PI / 180.0)
	var m := deg_to_rad(LIMIT_MARGIN)
	var fx := rotvec(foot_q).x
	foot_q = Quaternion(Vector3.RIGHT, clampf(fx, fl.x + m, fl.y - m))
	var drop := 0.0
	if fx > fl.y - m:
		var act := shin_g * Basis(foot_q)
		var want_low := minf((foot_g * SOLE_TOE).y, (foot_g * SOLE_HEEL).y)
		var act_low := minf((act * SOLE_TOE).y, (act * SOLE_HEEL).y)
		drop = want_low - act_low
	return [thigh_q, shin_local, foot_q, drop]

## Forward kinematics at unit scale: global transforms (pose space) of all 16
## bones from local rotations and the hips offset.
static func fk(rots: Array, hips_offset: Vector3) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	out.resize(HumanoidRig.BONE_COUNT)
	var pidx := HumanoidRig.parent_indices()
	for i in HumanoidRig.BONE_COUNT:
		var b: StringName = Bones.ALL[i]
		var q: Quaternion = rots[i] if rots[i] != null else Quaternion.IDENTITY
		var off: Vector3 = HumanoidRig.REST[b]
		if i == 0:
			off += hips_offset
		var local := Transform3D(Basis(q), off)
		out[i] = out[pidx[i]] * local if pidx[i] >= 0 else local
	return out
