class_name FighterFactory
## Spawns fully wired fighters. OWNER: core (contract). Used by GameMode,
## the ragdoll lab and tests.

static func spawn_player(parent: Node, xform: Transform3D) -> Fighter:
	var f := Fighter.new()
	f.name = "Player"
	f.setup(&"player", Fighter.TEAM_PLAYER)
	f.transform = xform
	parent.add_child(f)
	var pc := PlayerController.new()
	pc.name = "PlayerController"
	f.add_child(pc)
	return f

static func spawn_enemy(parent: Node, archetype: StringName, xform: Transform3D,
		entry_path := PackedVector3Array()) -> Fighter:
	var f := Fighter.new()
	f.name = String(archetype).capitalize()
	f.setup(archetype, Fighter.TEAM_ENEMY)
	# Round 8: enemy level from the wave (pressure capacity, blocking); the Duelist
	# stays 1. AttackDirector.wave_index is 1-based in Waves (GameMode sets
	# index + 1) and 0 outside it; R8_LEVEL_BY_WAVE is 0-based.
	f.level = 1 if archetype == &"duelist" else Tuning.r8_level_for_wave(AttackDirector.wave_index - 1)
	f.transform = xform
	parent.add_child(f)
	var brain := AIBrain.new()
	brain.name = "AIBrain"
	brain.entry_path = entry_path
	f.add_child(brain)
	return f

## A fighter with no controller (lab dummies, tests).
static func spawn_dummy(parent: Node, archetype: StringName, xform: Transform3D,
		team := Fighter.TEAM_ENEMY) -> Fighter:
	var f := Fighter.new()
	f.name = String(archetype).capitalize() + "Dummy"
	f.setup(archetype, team)
	f.transform = xform
	parent.add_child(f)
	return f
