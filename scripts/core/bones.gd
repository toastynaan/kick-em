class_name Bones
## Shared bone names for the procedural humanoid rig. Names follow Godot's
## SkeletonProfileHumanoid so a Mixamo rig can be retargeted onto them later.
## OWNER: core (contract). HumanoidRig must create exactly these bones.
##
## Rig conventions (see docs/ARCHITECTURE.md, "Rig conventions"):
## - Character faces -Z. Character's right is +X. Y is up.
## - Every bone rest rotation is identity; rest pose is a standing I-pose
##   (arms straight down at the sides, legs straight).
## - Spine bones and Head point +Y; arm and leg bones point -Y; feet point -Z.

const HIPS := &"Hips"
const SPINE := &"Spine"
const CHEST := &"Chest"
const HEAD := &"Head"
const L_UPPER_ARM := &"LeftUpperArm"
const L_LOWER_ARM := &"LeftLowerArm"
const L_HAND := &"LeftHand"
const R_UPPER_ARM := &"RightUpperArm"
const R_LOWER_ARM := &"RightLowerArm"
const R_HAND := &"RightHand"
const L_UPPER_LEG := &"LeftUpperLeg"
const L_LOWER_LEG := &"LeftLowerLeg"
const L_FOOT := &"LeftFoot"
const R_UPPER_LEG := &"RightUpperLeg"
const R_LOWER_LEG := &"RightLowerLeg"
const R_FOOT := &"RightFoot"

## All bones, parents before children.
const ALL: Array[StringName] = [
	HIPS, SPINE, CHEST, HEAD,
	L_UPPER_ARM, L_LOWER_ARM, L_HAND,
	R_UPPER_ARM, R_LOWER_ARM, R_HAND,
	L_UPPER_LEG, L_LOWER_LEG, L_FOOT,
	R_UPPER_LEG, R_LOWER_LEG, R_FOOT,
]

## Parent of each bone (Hips is the root).
const PARENT := {
	&"Spine": &"Hips", &"Chest": &"Spine", &"Head": &"Chest",
	&"LeftUpperArm": &"Chest", &"LeftLowerArm": &"LeftUpperArm", &"LeftHand": &"LeftLowerArm",
	&"RightUpperArm": &"Chest", &"RightLowerArm": &"RightUpperArm", &"RightHand": &"RightLowerArm",
	&"LeftUpperLeg": &"Hips", &"LeftLowerLeg": &"LeftUpperLeg", &"LeftFoot": &"LeftLowerLeg",
	&"RightUpperLeg": &"Hips", &"RightLowerLeg": &"RightUpperLeg", &"RightFoot": &"RightLowerLeg",
}

## Bones that get a PhysicalBone3D. Hands ride on the forearm (their mass is
## added to the forearm) because 0.4 kg bodies are unstable.
const PHYSICAL: Array[StringName] = [
	HIPS, SPINE, CHEST, HEAD,
	L_UPPER_ARM, L_LOWER_ARM, R_UPPER_ARM, R_LOWER_ARM,
	L_UPPER_LEG, L_LOWER_LEG, L_FOOT,
	R_UPPER_LEG, R_LOWER_LEG, R_FOOT,
]

## Bones simulated in a Flinch (partial ragdoll of the upper body).
const UPPER_BODY: Array[StringName] = [
	SPINE, CHEST, HEAD, L_UPPER_ARM, L_LOWER_ARM, R_UPPER_ARM, R_LOWER_ARM,
]

## Dismemberment cut ids -> the bone whose subtree comes off.
## Round 5 severing launches take a whole limb (arm_l/arm_r at the shoulder,
## leg_l/leg_r at the hip); no heads for now. The partial cuts stay for older paths.
const CUTS := {
	&"head": &"Head",
	&"forearm_l": &"LeftLowerArm",
	&"forearm_r": &"RightLowerArm",
	&"shin_l": &"LeftLowerLeg",
	&"shin_r": &"RightLowerLeg",
	&"arm_l": &"LeftUpperArm",
	&"arm_r": &"RightUpperArm",
	&"leg_l": &"LeftUpperLeg",
	&"leg_r": &"RightUpperLeg",
}

## Round 5: which whole-limb cut a hit bone takes. Head and torso hits return
## &"" (the caller picks the arm nearest the hit point).
static func limb_cut_for(bone: StringName) -> StringName:
	match bone:
		L_UPPER_ARM, L_LOWER_ARM, L_HAND:
			return &"arm_l"
		R_UPPER_ARM, R_LOWER_ARM, R_HAND:
			return &"arm_r"
		L_UPPER_LEG, L_LOWER_LEG, L_FOOT:
			return &"leg_l"
		R_UPPER_LEG, R_LOWER_LEG, R_FOOT:
			return &"leg_r"
	return &""

## Dempster mass fractions of a 70.1 kg body (spec, Ragdoll system), per physical bone.
## Hand mass (0.4) is folded into each forearm. Multiply by (mass_kg / 70.1).
const MASS_70 := {
	&"Hips": 9.9, &"Spine": 10.0, &"Chest": 14.9, &"Head": 5.7,
	&"LeftUpperArm": 2.0, &"LeftLowerArm": 1.5, &"RightUpperArm": 2.0, &"RightLowerArm": 1.5,
	&"LeftUpperLeg": 7.0, &"LeftLowerLeg": 3.3, &"LeftFoot": 1.0,
	&"RightUpperLeg": 7.0, &"RightLowerLeg": 3.3, &"RightFoot": 1.0,
}
