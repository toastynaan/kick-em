extends "res://tests/input/input_test_base.gd"
## Shared helpers for tests/defence/* (Round 5: parry, teleport, sidestep,
## pursuit, Focus). Builds on the input test base (floor, events, checks).
## OWNER: agent H (fighter, player & defence).

const DEF_EVENTS: Array[StringName] = [&"parried", &"parry_whiffed", &"teleported", &"sidestepped",
	&"counter_bonus_changed", &"hit_landed", &"pursuit", &"attack_active", &"fighter_launched"]

func _ready() -> void:
	_timeout = 280.0
	for sig: StringName in DEF_EVENTS:
		var s := sig
		GameEvents.connect(s, func(a = null, b = null, c = null, d = null) -> void:
			events.append([s, a, b, c, TimeDirector.now(), d]))
	super._ready()

## An enemy dummy (no brain) `dist` m in front of the player, facing it.
func spawn_attacker(p: Fighter, archetype: StringName, offset: Vector3) -> Fighter:
	var pos := p.global_position + offset
	return spawn_dummy(archetype, pos, p.global_position - pos)

## Step until `e`'s attack is `lead` real s (or less) from its first active frame.
func wait_for_lead(e: Fighter, lead: float, max_ticks := 600) -> bool:
	for i in max_ticks:
		var tta := e.combat.time_to_active()
		if is_finite(tta) and tta <= lead + 1e-5:
			return true
		await get_tree().physics_frame
	return false

## Real time of `e`'s next first active frame (waits for it).
func wait_active(e: Fighter, max_ticks := 600) -> float:
	for i in max_ticks:
		if e.combat.is_attack_active():
			return TimeDirector.now()
		await get_tree().physics_frame
	return -1.0

## Wait until the fighter can act again (and the world runs at normal speed).
func settle(f: Fighter, max_ticks := 600) -> void:
	await wait_until(func() -> bool: return (f.is_dead() or (f.can_act() and not f.combat.is_attacking())) \
		and Engine.time_scale > 0.99, max_ticks)

## Put `f` back on its feet at `pos` facing `facing` (between scripted rounds).
func reset_fighter(f: Fighter, pos: Vector3, facing: Vector3) -> void:
	if f.ragdoll and f.ragdoll.is_simulating():
		f.ragdoll.force_recover()
	f.combat.cancel()
	f.clear_forced_velocity()
	f.teleport_to(pos, facing)
	f.reset_air_state()
	await ticks(2)

## The last HitInfo of a hit_landed event by `attacker` (null if none).
func last_hit_by(attacker: Fighter) -> HitInfo:
	for i in range(events.size() - 1, -1, -1):
		var e: Array = events[i]
		if e[0] == &"hit_landed" and e[1] is HitInfo and (e[1] as HitInfo).attacker == attacker:
			return e[1]
	return null

## A strike HitInfo from `attacker` on `victim` with a preset tier (and the
## matching legacy reaction), to drive Focus income and pursuit windows
## without depending on move data.
func scripted_hit(attacker: Fighter, victim: Fighter, tier: int, p := 0.0) -> HitInfo:
	var info := HitInfo.new()
	info.attacker = attacker
	info.victim = victim
	info.move_id = &"jab1"
	info.kind = &"strike"
	info.tier = tier
	info.power = p
	info.reaction = HitInfo.reaction_for_tier(tier)
	var d := victim.get_ground_position() - attacker.get_ground_position()
	d.y = 0.0
	info.hit_direction = d.normalized() if d.length() > 0.05 else attacker.get_forward()
	info.hit_position = victim.get_aim_point()
	info.hit_bone = Bones.CHEST
	info.unblockable = true
	info.damage = 1.0
	if HitInfo.is_launch_tier(tier):
		var pp := p if p > 0.0 else 5.5
		info.launch_velocity = Power.launch_velocity(pp, info.hit_direction, victim.get_total_mass(), victim.is_heavy())
		info.energy = 0.5 * victim.get_total_mass() * info.launch_velocity.length_squared()
	info.hitstop = Power.hitstop_for(tier)
	return info
