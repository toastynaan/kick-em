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
