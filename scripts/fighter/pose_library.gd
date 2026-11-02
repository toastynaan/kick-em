class_name PoseLibrary
extends RefCounted
## Procedural keyframe poses and moves for the HumanoidRig (no clips yet).
## OWNER: agent A (rig & ragdoll).
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
##   is at time 0, and always ends back on the layer below.
##
## Enemy tells (startup = tell time): 60% of the windup almost at once, the
## windup deepens over the whole tell, a ~2 frame "set" freeze, then a ~4
## frame snap to the strike. The perfect-dodge window (last 8 frames) starts
## just before the set.

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
	&"throw_turn": {"pos": Vector3(0, -0.14, 0.02), "hips": Vector3(0, 35, 0), "spine": Vector3(-6, 0, 0), "chest": Vector3(-4, 30, 0), "head": Vector3(6, -45, 0),
		"lfist": Vector3(-0.30, 1.20, -0.20), "lelbow": Vector3(-1, -0.4, 0.2),
		"rfist": Vector3(-0.05, 1.22, -0.42), "relbow": Vector3(1, -0.4, 0.2),
		"lankle": Vector3(-0.16, 0.08, -0.10), "rankle": Vector3(0.18, 0.08, 0.14)},
	&"throw_fling": {"pos": Vector3(0, -0.12, -0.10), "hips": Vector3(0, -40, 0), "spine": Vector3(-14, 0, 0), "chest": Vector3(-6, -35, 0), "head": Vector3(10, 50, 0),
		"lfist": Vector3(0.05, 1.40, -0.85), "lelbow": Vector3(-0.8, -0.6, 0.2),
		"rfist": Vector3(0.35, 1.38, -0.75), "relbow": Vector3(0.8, -0.6, 0.2),
		"lankle": Vector3(-0.16, 0.08, -0.25), "rankle": Vector3(0.18, 0.10, 0.20), "rfp": -20.0},
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
	&"bk_chamber": {"frame": &"body", "pos": Vector3(0, -0.14, 0), "hips": Vector3(-6, -165, 0), "spine": Vector3(-16, 0, 0), "chest": Vector3(-6, 0, 0), "head": Vector3(0, -80, 0),
		"lfist": Vector3(-0.14, 1.30, -0.22), "lelbow": Vector3(-0.5, -1, 0.3),
		"rfist": Vector3(0.16, 1.28, -0.16), "relbow": Vector3(0.5, -1, 0.3),
		"lankle": Vector3(-0.12, 0.08, -0.06), "lknee": Vector3(0, 0, -1),
		"rankle": Vector3(0.10, 0.62, -0.05), "rknee": Vector3(0, 0.3, -1), "rfp": -50.0},
	&"bk_follow": {"frame": &"body", "pos": Vector3(0, -0.10, -0.10), "hips": Vector3(-30, -192, 0), "spine": Vector3(-22, 0, 0), "chest": Vector3(-8, 6, 0), "head": Vector3(14, -72, 0),
		"lfist": Vector3(-0.34, 1.10, -0.32), "lelbow": Vector3(-0.8, -0.5, 0),
		"rfist": Vector3(0.32, 1.10, -0.34), "relbow": Vector3(0.8, -0.5, 0),
		"lankle": Vector3(-0.12, 0.08, -0.14), "lknee": Vector3(0, 0, -1), "lfp": -10.0,
		"rankle": Vector3(0.06, 1.10, 0.95), "rknee": Vector3(0, -1, 0), "rfp": -85.0},
	&"bk_hit": {"frame": &"body", "pos": Vector3(0, -0.08, -0.06), "hips": Vector3(-24, -180, 0), "spine": Vector3(-18, 0, 0), "chest": Vector3(-8, 0, 0), "head": Vector3(10, -70, 0),
		"lfist": Vector3(-0.30, 1.20, -0.30), "lelbow": Vector3(-0.8, -0.5, 0),
		"rfist": Vector3(0.30, 1.20, -0.30), "relbow": Vector3(0.8, -0.5, 0),
		"lankle": Vector3(-0.12, 0.08, -0.10), "lknee": Vector3(0, 0, -1),
		"rankle": Vector3(0.08, 1.02, 0.92), "rknee": Vector3(0, -1, 0), "rfp": -80.0},
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
		"rfist": Vector3(0.18, 1.36, -0.55), "relbow": Vector3(0.6, -1, 0.2), "rla": Vector3(120, 0, 0)},
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
		"lfist": Vector3(-0.32, 0.10, 0.10), "lelbow": Vector3(-0.5, 0.2, 1),
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
	&"e_hook_cock": {"pos": Vector3(0, -0.10, 0.05), "hips": Vector3(0, -30, 0), "spine": Vector3(2, 0, 0), "chest": Vector3(0, -32, 0), "head": Vector3(0, 55, 0),
		"lfist": Vector3(-0.22, 1.36, -0.36), "lelbow": Vector3(-0.5, -1, 0.2),
		"rfist": Vector3(0.50, 1.80, 0.16), "relbow": Vector3(1, 0.1, 0.4),
		"lankle": Vector3(-0.14, 0.08, -0.22), "rankle": Vector3(0.18, 0.08, 0.18)},
	&"e_hook_hit": {"pos": Vector3(0, -0.10, -0.06), "hips": Vector3(0, 20, 0), "spine": Vector3(-10, 0, 0), "chest": Vector3(-4, 34, 0), "head": Vector3(6, -50, 0),
		"lfist": Vector3(-0.18, 1.38, -0.15), "lelbow": Vector3(-0.5, -1, 0.3),
		"rfist": Vector3(-0.12, 1.46, -0.66), "relbow": Vector3(1, 0.35, 0.1),
		"lankle": Vector3(-0.14, 0.08, -0.25), "rankle": Vector3(0.16, 0.10, 0.18), "rfp": -20.0},
	&"e_hook_follow": {"pos": Vector3(0, -0.12, -0.06), "hips": Vector3(0, 32, 0), "spine": Vector3(-12, 0, 0), "chest": Vector3(-4, 42, 0), "head": Vector3(6, -60, 0),
		"lfist": Vector3(-0.18, 1.36, -0.12), "lelbow": Vector3(-0.5, -1, 0.3),
		"rfist": Vector3(-0.48, 1.36, -0.40), "relbow": Vector3(1, 0.4, 0.3)},
	&"e_heavy_cock": {"pos": Vector3(0, -0.04, 0.06), "spine": Vector3(16, 0, 0), "chest": Vector3(10, 0, 0), "head": Vector3(-14, 0, 0),
		"lfist": Vector3(-0.10, 2.12, 0.18), "lelbow": Vector3(-1, 0.5, 0.1),
		"rfist": Vector3(0.10, 2.12, 0.18), "relbow": Vector3(1, 0.5, 0.1),
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
		"lfist": Vector3(-0.42, 1.30, 0.10), "lelbow": Vector3(-1, -0.3, 0.4),
		"rfist": Vector3(0.40, 1.28, 0.16), "relbow": Vector3(1, -0.3, 0.4),
		"lankle": Vector3(-0.10, 0.08, 0.14), "lknee": Vector3(0, 0, -1),
		"rankle": Vector3(0.05, 1.04, -0.92), "rknee": Vector3(0, 1, 0), "rfp": 40.0},
	&"e_grab_cock": {"pos": Vector3(0, -0.16, 0.02), "spine": Vector3(-12, 0, 0), "chest": Vector3(-4, 0, 0), "head": Vector3(16, 0, 0),
		"lfist": Vector3(-0.78, 1.38, -0.18), "lelbow": Vector3(-0.3, -0.4, 1),
		"rfist": Vector3(0.78, 1.38, -0.18), "relbow": Vector3(0.3, -0.4, 1),
		"lankle": Vector3(-0.20, 0.08, -0.10), "rankle": Vector3(0.20, 0.08, 0.12)},
	&"e_grab_hit": {"pos": Vector3(0, -0.14, -0.10), "spine": Vector3(-16, 0, 0), "chest": Vector3(-6, 0, 0), "head": Vector3(16, 0, 0),
		"lfist": Vector3(-0.12, 1.30, -0.70), "lelbow": Vector3(-0.8, -0.6, 0.2),
		"rfist": Vector3(0.12, 1.30, -0.70), "relbow": Vector3(0.8, -0.6, 0.2)},
	&"e_charge_cock": {"pos": Vector3(0, -0.22, 0.04), "hips": Vector3(0, -20, 0), "spine": Vector3(-34, 0, 0), "chest": Vector3(-14, -20, 0), "head": Vector3(36, 35, 0),
		"lfist": Vector3(-0.16, 1.00, -0.34), "lelbow": Vector3(-0.5, -1, 0.2),
		"rfist": Vector3(0.24, 0.98, -0.05), "relbow": Vector3(0.5, -1, 0.5),
		"lankle": Vector3(-0.18, 0.08, -0.32), "rankle": Vector3(0.18, 0.12, 0.36), "rfp": -25.0},
	&"e_charge_hit": {"pos": Vector3(0, -0.24, -0.10), "hips": Vector3(0, -25, 0), "spine": Vector3(-42, 0, 0), "chest": Vector3(-14, -22, 0), "head": Vector3(44, 40, 0),
		"lfist": Vector3(-0.14, 0.98, -0.40), "lelbow": Vector3(-0.5, -1, 0.2),
		"rfist": Vector3(0.24, 0.95, -0.08), "relbow": Vector3(0.5, -1, 0.5)},
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
	&"roundhouse_cock": {"frame": &"body", "pos": Vector3(0, -0.06, 0.02), "hips": Vector3(0, 40, 0), "spine": Vector3(4, 0, 14), "chest": Vector3(2, 0, 6), "head": Vector3(-6, -40, -10),
		"lfist": Vector3(-0.30, 1.42, -0.26), "lelbow": Vector3(-0.6, -1, 0.2),
		"rfist": Vector3(0.10, 1.38, -0.30), "relbow": Vector3(0.6, -1, 0.2),
		"lankle": Vector3(-0.10, 0.08, 0.0), "lknee": Vector3(-0.3, 0, -1), "lfp": -15.0,
		"rankle": Vector3(0.42, 0.78, 0.10), "rknee": Vector3(1, 0.4, -0.4), "rfp": -30.0},
	&"roundhouse_hit": {"frame": &"body", "pos": Vector3(0, -0.08, -0.04), "hips": Vector3(0, 85, 0), "spine": Vector3(4, 0, 24), "chest": Vector3(2, 0, 10), "head": Vector3(-4, -70, -16),
		"lfist": Vector3(-0.40, 1.30, -0.10), "lelbow": Vector3(-0.8, -0.5, 0.2),
		"rfist": Vector3(0.05, 1.30, -0.35), "relbow": Vector3(0.6, -1, 0.2),
		"lankle": Vector3(-0.10, 0.08, 0.0), "lknee": Vector3(-0.3, 0, -1), "lfp": -20.0,
		"rankle": Vector3(0.86, 1.12, -0.08), "rknee": Vector3(0, 1, 0.3), "rfp": -40.0},
	&"roundhouse_follow": {"frame": &"body", "pos": Vector3(0, -0.09, -0.06), "hips": Vector3(0, 125, 0), "spine": Vector3(4, 0, 26), "chest": Vector3(2, 0, 10), "head": Vector3(-4, -100, -16),
		"lfist": Vector3(-0.42, 1.28, -0.08), "lelbow": Vector3(-0.8, -0.5, 0.2),
		"rfist": Vector3(0.05, 1.28, -0.35), "relbow": Vector3(0.6, -1, 0.2),
		"lankle": Vector3(-0.10, 0.08, 0.0), "lknee": Vector3(-0.3, 0, -1), "lfp": -20.0,
		"rankle": Vector3(0.84, 1.05, -0.10), "rknee": Vector3(0, 1, 0.3), "rfp": -40.0},
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
		"lfist": Vector3(-0.08, 0.48, -0.58), "lelbow": Vector3(-1, 0, 0.3),
		"rfist": Vector3(0.08, 0.48, -0.58), "relbow": Vector3(1, 0, 0.3),
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
		"lfist": Vector3(-0.10, 1.40, -0.36), "lelbow": Vector3(-1, -0.4, 0.2),
		"rfist": Vector3(0.10, 1.40, -0.36), "relbow": Vector3(1, -0.4, 0.2)},
	&"headbutt_hit": {"pos": Vector3(0, -0.10, -0.10), "spine": Vector3(-20, 0, 0), "chest": Vector3(-10, 0, 0), "head": Vector3(-30, 0, 0),
		"lfist": Vector3(-0.08, 1.32, -0.30), "lelbow": Vector3(-1, -0.4, 0.2),
		"rfist": Vector3(0.08, 1.32, -0.30), "relbow": Vector3(1, -0.4, 0.2)},
	&"neck_throw_load": {"pos": Vector3(0, -0.14, 0.02), "hips": Vector3(0, -30, 0), "spine": Vector3(-10, 0, 0), "chest": Vector3(-4, -20, 0), "head": Vector3(10, 40, 0),
		"rfist": Vector3(-0.10, 1.20, -0.30), "relbow": Vector3(1, 0.1, -0.2),
		"lfist": Vector3(-0.05, 1.10, -0.45), "lelbow": Vector3(-0.6, -1, 0.2),
		"lankle": Vector3(-0.18, 0.08, -0.18), "rankle": Vector3(0.20, 0.08, 0.16)},
	&"neck_throw_fling": {"pos": Vector3(0, -0.16, -0.06), "hips": Vector3(0, 55, 0), "spine": Vector3(-20, 0, 0), "chest": Vector3(-8, 40, 0), "head": Vector3(12, -60, 0),
		"rfist": Vector3(-0.55, 0.95, -0.45), "relbow": Vector3(1, -0.3, 0.3),
		"lfist": Vector3(-0.65, 1.00, -0.25), "lelbow": Vector3(-0.6, -1, 0.3),
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
		"rfist": Vector3(0.18, 1.0, 0.0), "relbow": Vector3(0.6, 0.3, 0.8),
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
		"rfist": Vector3(0.66, 1.64, -0.04), "relbow": Vector3(0.4, -0.6, 0.6),
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
		"lfist": Vector3(-0.06, 1.05, -0.58), "lelbow": Vector3(-0.6, -1, 0.2),
		"rfist": Vector3(0.10, 1.02, -0.55), "relbow": Vector3(0.6, -1, 0.2),
		"lankle": Vector3(-0.22, 0.08, -0.14), "rankle": Vector3(0.22, 0.08, 0.20)},
	&"giant_swing": {"pos": Vector3(0, -0.16, 0.14), "spine": Vector3(24, 0, 0), "chest": Vector3(10, 0, 0), "head": Vector3(-16, 0, 0),
		"lfist": Vector3(-0.10, 0.92, -0.60), "lelbow": Vector3(-0.5, -1, 0.2),
		"rfist": Vector3(0.10, 0.92, -0.60), "relbow": Vector3(0.5, -1, 0.2),
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
}

const MOVES := {
	&"jab1": {"keys": [[0, 0.45, &"jab_l_cock"], [1, 0.0, &"jab_l_hit", &"snap"], [1, 1.0, &"jab_l_hit"], [2, 0.45, &"stance"]]},
	&"jab2": {"keys": [[0, 0.45, &"jab_r_cock"], [1, 0.0, &"jab_r_hit", &"snap"], [1, 1.0, &"jab_r_hit"], [2, 0.45, &"stance"]]},
	&"jab3": {"keys": [[0, 0.55, &"hook_l_cock"], [1, 0.0, &"hook_l_hit", &"snap"], [1, 1.0, &"hook_l_hit"], [2, 0.45, &"stance"]]},
	&"power_punch": {"keys": [[0, 0.4, &"power_charge"], [1, 0.0, &"power_hit", &"snap"], [1, 1.0, &"power_hit"], [2, 0.16, &"power_follow", &"snap"], [2, 0.55, &"jab_r_cock"]]},
	&"sparta_kick": {"keys": [[0, 0.55, &"kick_chamber"], [0, 0.8, &"kick_chamber"], [1, 0.0, &"kick_hit", &"snap"], [1, 1.0, &"kick_hit"], [2, 0.16, &"kick_follow", &"snap"], [2, 0.45, &"kick_recoil"]]},
	&"leg_sweep": {"keys": [[0, 0.6, &"sweep_crouch"], [1, 0.0, &"sweep_a", &"snap"], [1, 1.0, &"sweep_b", &"linear"], [2, 0.35, &"sweep_end"], [2, 0.75, &"sweep_rise"]]},
	&"grab": {"keys": [[0, 0.5, &"grab_open"], [1, 0.0, &"grab_reach", &"snap"], [1, 1.0, &"grab_reach"], [2, 0.6, &"grab_hold"]]},
	&"throw": {"keys": [[0, 0.7, &"throw_turn"], [1, 0.0, &"throw_fling", &"snap"], [1, 1.0, &"throw_fling"], [2, 0.5, &"stance"]]},
	# Short startup (player): a fast spin. Long startup (AI teleport counter,
	# startup = tell): turn away fast, the chamber deepens over the tell, a
	# short set, then the heel snaps back toward the original facing.
	&"back_kick": {"keys": [[0, Vector2(0.45, 0.12), &"bk_turn"], [0, Vector2(-0.3, 0.103), &"bk_chamber"], [0, Vector2(-0.18, 0.07), &"bk_chamber", &"linear"],
		[1, 0.0, &"bk_hit", &"snap"], [1, 1.0, &"bk_hit"], [2, 0.18, &"bk_follow", &"snap"], [2, 0.55, &"bk_return"]]},
	&"punt": {"keys": [[0, 0.6, &"punt_cock"], [1, 0.0, &"punt_hit", &"snap"], [1, 1.0, &"punt_hit"], [2, 0.3, &"punt_follow", &"snap"], [2, 0.7, &"stance"]]},
	&"dash": {"keys": [[0, 1.0, &"dash", &"snap"], [1, 1.0, &"dash"]]},
	&"block_hit": {"keys": [[0, 1.0, &"block_recoil", &"snap"], [1, 1.0, &"block_recoil"], [2, 0.6, &"block"]]},
	&"dodge": {"keys": [[1, Vector2(0.3, 0.06), &"dodge", &"snap"], [1, 1.0, &"dodge"]], "mirror_by_motion": true},
	&"getup_face_up": {"keys": [[0, 0.0, &"lie_up"], [0, 0.55, &"getup_up_sit"], [1, 0.0, &"getup_up_crouch"], [1, 1.0, &"getup_rise"]]},
	&"getup_face_down": {"keys": [[0, 0.0, &"lie_down"], [0, 0.6, &"getup_down_push"], [1, 0.0, &"getup_down_kneel"], [1, 1.0, &"getup_rise"]]},
	&"grab_break_push": {"keys": [[0, 0.6, &"push_load"], [1, 0.0, &"push_hit", &"snap"], [1, 1.0, &"push_hit"]]},
	&"taunt": {"keys": [[0, 0.6, &"taunt_flex"], [0, 1.0, &"taunt_flex"], [1, 0.25, &"taunt_beckon"], [1, 0.5, &"taunt_beckon2"], [1, 0.75, &"taunt_beckon"], [1, 1.0, &"taunt_beckon2"]]},
	&"land": {"keys": [[0, 0.0, &"land"], [1, 1.0, &"land"]]},
	# --- Upgrade 2 -------------------------------------------------------------------
	&"cross": {"keys": [[0, 0.45, &"cross_cock"], [1, 0.0, &"cross_hit", &"snap"], [1, 1.0, &"cross_hit"], [2, 0.2, &"cross_follow", &"snap"], [2, 0.6, &"stance"]]},
	&"hook": {"keys": [[0, 0.5, &"hook_l_cock"], [1, 0.0, &"hook_l_hit", &"snap"], [1, 1.0, &"hook_l_hit"], [2, 0.2, &"hook_l_follow", &"snap"], [2, 0.6, &"stance"]]},
	&"uppercut": {"keys": [[0, 0.5, &"uppercut_cock"], [1, 0.0, &"uppercut_hit", &"snap"], [1, 1.0, &"uppercut_hit"], [2, 0.25, &"uppercut_follow", &"snap"], [2, 0.65, &"stance"]]},
	&"rising_uppercut": {"keys": [[0, 0.45, &"rising_cock"], [1, 0.0, &"rising_hit", &"snap"], [1, 1.0, &"rising_hit"], [2, 0.25, &"uppercut_follow", &"snap"], [2, 0.65, &"stance"]]},
	&"crouch_punch": {"keys": [[0, 0.5, &"crouch_punch_cock"], [1, 0.0, &"crouch_punch_hit", &"snap"], [1, 1.0, &"crouch_punch_hit"], [2, 0.5, &"crouch"]]},
	&"roundhouse": {"keys": [[0, 0.55, &"roundhouse_cock"], [1, 0.0, &"roundhouse_hit", &"snap"], [1, 1.0, &"roundhouse_hit"], [2, 0.25, &"roundhouse_follow", &"snap"], [2, 0.65, &"kick_recoil"]]},
	&"backfist": {"keys": [[0, Vector2(0.45, 0.10), &"backfist_cock"], [1, 0.0, &"backfist_hit", &"snap"], [1, 1.0, &"backfist_hit"], [2, 0.2, &"backfist_follow", &"snap"], [2, 0.55, &"backfist_return"]]},
	&"flying_kick": {"keys": [[0, 0.5, &"flying_cock"], [1, 0.0, &"flying_hit", &"snap"], [1, 1.0, &"flying_hit"], [2, 0.5, &"jump_fall"]]},
	&"hammer_fist": {"keys": [[0, 0.5, &"hammer_cock"], [1, 0.0, &"hammer_hit", &"snap"], [1, 1.0, &"hammer_hit"], [2, 0.5, &"jump_fall"]]},
	&"knee": {"keep_hold": true, "keys": [[0, 0.5, &"knee_cock"], [1, 0.0, &"knee_hit", &"snap"], [1, 1.0, &"knee_hit"], [2, 0.6, &"grab_hold"]]},
	&"headbutt": {"keep_hold": true, "keys": [[0, 0.5, &"headbutt_cock"], [1, 0.0, &"headbutt_hit", &"snap"], [1, 1.0, &"headbutt_hit"], [2, 0.6, &"headlock"]]},
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
}

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

## Moves with a held &"<id>_charge" pose (Upgrade 2: hold any attack to charge).
const CHARGEABLE: Array[StringName] = [&"jab1", &"cross", &"hook", &"uppercut", &"sparta_kick",
	&"roundhouse", &"leg_sweep", &"crouch_punch", &"flying_kick", &"hammer_fist", &"backfist"]

## Hold id of a move's charge pose (&"" if the move has none).
static func charge_hold_of(move_id: StringName) -> StringName:
	var h := StringName(String(move_id) + "_charge")
	return h if HOLDS.has(h) else &""

## Moves that ignore PoseAnimator.set_aim_target (a floor sweep must stay on
## the floor; a throw flings where the grabber faces).
const NO_AIM: Array[StringName] = [&"leg_sweep", &"throw", &"backfist", &"e_sweep", &"neck_throw",
	&"upward_throw", &"wall_slam"]

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

static func compile(d: Dictionary) -> Pose:
	var p := Pose.new()
	p.rot.resize(HumanoidRig.BONE_COUNT)
	for key in ALIAS:
		if d.has(key):
			p.rot[HumanoidRig.bone_index(ALIAS[key])] = euler_q(d[key])
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
			var res := solve_ik(shoulder, target, IK_ARM_UPPER, IK_ARM_LOWER, pole, true)
			if p.rot[ua] == null:
				p.rot[ua] = Quaternion((chest_xf.basis.inverse() * (res[0] as Basis)).orthonormalized())
			if p.rot[ua + 1] == null:
				p.rot[ua + 1] = Quaternion(Vector3.RIGHT, res[1])
			if p.rot[ua + 2] == null:
				p.rot[ua + 2] = Quaternion.IDENTITY
		if d.has(pre + "ankle"):
			var target: Vector3 = origin + yaw * (d[pre + "ankle"] as Vector3)
			var pole: Vector3 = yaw * (d.get(pre + "knee", Vector3(0.1 * (1 if side else -1), 0, -1)) as Vector3)
			var pitch := deg_to_rad(float(d.get(pre + "fp", 0.0)))
			var rots := leg_ik(hips_xf, side, target, pole, p.hips_yaw, pitch)
			var ul := HumanoidRig.bone_index(StringName(bside + "UpperLeg"))
			for k in 3:
				if p.rot[ul + k] == null:
					p.rot[ul + k] = rots[k]
		p.defines_legs[side] = p.rot[HumanoidRig.bone_index(StringName(bside + "UpperLeg"))] != null
	return p

## Two-bone IK. Returns [upper bone global Basis, bend angle (rad, >= 0)].
## The elbow/knee points toward `pole`. Arms bend toward bone-local -Z
## (elbow +X), legs toward +Z (knee -X).
static func solve_ik(s: Vector3, t: Vector3, a: float, b: float, pole: Vector3, is_arm: bool) -> Array:
	var dv := t - s
	var d := dv.length()
	var dir := dv / d if d > 0.0001 else Vector3.DOWN
	d = clampf(d, absf(a - b) + 0.02, (a + b) * 0.998)
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

## Leg IK in pose space. Returns [thigh, shin, foot] local quaternions.
static func leg_ik(hips_xf: Transform3D, side: int, ankle: Vector3, pole: Vector3, yaw: float, pitch: float) -> Array:
	var bside := "Left" if side == 0 else "Right"
	var hip := hips_xf * (HumanoidRig.REST[StringName(bside + "UpperLeg")] as Vector3)
	var res := solve_ik(hip, ankle, IK_LEG_UPPER, IK_LEG_LOWER, pole, false)
	var thigh_g: Basis = res[0]
	var shin_local := Quaternion(Vector3.RIGHT, -float(res[1]))
	var shin_g := thigh_g * Basis(shin_local)
	var foot_g := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch)
	return [Quaternion((hips_xf.basis.inverse() * thigh_g).orthonormalized()), shin_local,
		Quaternion((shin_g.inverse() * foot_g).orthonormalized())]

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
