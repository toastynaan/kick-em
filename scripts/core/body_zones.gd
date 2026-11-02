class_name BodyZones
## The five strike and grab zones (Upgrade 2: Body-zone targeting).
## OWNER: core (contract). The player's aim picks a zone on the soft target
## (Fighter.aim_zone); strikes and grabs read it, the HUD/FX highlight it.

enum Zone { TORSO, HEAD, ARM_L, ARM_R, LEGS }

const NAMES := {
	Zone.TORSO: &"torso", Zone.HEAD: &"head", Zone.ARM_L: &"arm_l",
	Zone.ARM_R: &"arm_r", Zone.LEGS: &"legs",
}

const BONES := {
	Zone.TORSO: [Bones.HIPS, Bones.SPINE, Bones.CHEST],
	Zone.HEAD: [Bones.HEAD],
	Zone.ARM_L: [Bones.L_UPPER_ARM, Bones.L_LOWER_ARM, Bones.L_HAND],
	Zone.ARM_R: [Bones.R_UPPER_ARM, Bones.R_LOWER_ARM, Bones.R_HAND],
	Zone.LEGS: [Bones.L_UPPER_LEG, Bones.L_LOWER_LEG, Bones.L_FOOT,
		Bones.R_UPPER_LEG, Bones.R_LOWER_LEG, Bones.R_FOOT],
}

## Default bone a strike aims at, or a limb grab anchors to, in each zone.
const AIM_BONE := {
	Zone.TORSO: Bones.CHEST, Zone.HEAD: Bones.HEAD, Zone.ARM_L: Bones.L_LOWER_ARM,
	Zone.ARM_R: Bones.R_LOWER_ARM, Zone.LEGS: Bones.L_LOWER_LEG,
}

static func of_bone(bone: StringName) -> int:
	for zone: int in BONES:
		if (BONES[zone] as Array).has(bone):
			return zone
	return Zone.TORSO

static func bones(zone: int) -> Array[StringName]:
	var out: Array[StringName] = []
	out.assign(BONES.get(zone, BONES[Zone.TORSO]))
	return out

static func name_of(zone: int) -> StringName:
	return NAMES.get(zone, &"torso")

static func is_arm(zone: int) -> bool:
	return zone == Zone.ARM_L or zone == Zone.ARM_R

static func is_limb(zone: int) -> bool:
	return is_arm(zone) or zone == Zone.LEGS
