extends Node3D
## F0 performance profile (Feel Reference > F0). OWNER: core (perf agent).
## Builds The Yard the way GameMode does, then loads it with the F0 crowd:
## - the player, driven by a bot through the real Input actions, hp raised so
##   it never dies;
## - `--live` enemies with their real AIBrain + AttackDirector tokens fighting
##   the player (hp raised so the crowd stays the same size; they still take
##   every hit, flinch, launch and get up);
## - `--dead` enemies killed through Fighter.apply_damage (-> RagdollController
##   .kill) so they ragdoll and settle as the game leaves them. GameMode is not
##   used, so its corpse cap never fades any;
## - `--debris` chunks from real wall breaks (Destructible.force_break ->
##   DebrisManager.register), re-registered with pinned lifetimes so none fade.
## Then it times every physics tick for `--seconds` of physics time (120 Hz).
##
## Usage (on a private copy, see docs/ARCHITECTURE.md, or run_perf.sh):
##   Godot --headless --path <copy> --fixed-fps 120 res://tests/integration/perf_crowd.tscn -- [options]
## Options (defaults = the F0 acceptance setup):
##   --seconds=60 --warmup=3 --live=8 --dead=20 --debris=150 --archetype=grunt
##   --bot=fight|passive        player bot attacks, or only walks and blocks
##   --ai=1|0                   0 disables the live enemies' AIBrain (idle crowd)
##   --corpses=game|awake       awake: corpses never freeze (kept simulating)
##   --debris_at=walls|fight    fight: chunks dropped over the middle of the yard
##   --debris_awake=0|1         1: chunks may never sleep
##   --split=0|1                1: AIBrains run after all Fighters (own timing band)
##   --launch_every=S --launch_n=K   stress: every S s launch K standing live
##                              enemies (Fighter.launch, 7-11 m/s) on top of the fight
##   --fixed=1|0                fixed-fps mode (auto-detected from the warm-up)
##   --debug_ai=1               per second: player state and each enemy's token / last denial
##   --csv=<abs path>           per-tick timings
## Output: a "[perf]" line per second, the band breakdown, and the verdict
##   PERF avg=.. p95=.. max=.. verdict=PASS|FAIL   (avg <= 8 ms, max <= 12 ms)
## Exit code is 0 for any measuring run; 1 only if sampling never started
## (setup broke: see the SCRIPT ERROR lines above it).
##
## How a tick is timed (Time.get_ticks_usec, no engine edits):
##   pre      process end -> SceneTree.physics_frame: the physics server sync and
##            flush_queries (body/area state callbacks) plus the idle tail of the
##            previous frame. Counted only under --fixed-fps (without it the
##            headless frame sleep lands here).
##   prelude  SceneTree.physics_frame -> first physics script.
##   scripts  probe nodes at physics priorities -100000 ... 100000 bracket each
##            band: anim (-20 PoseAnimator), ragdoll (-10 RagdollController +
##            PlayerController), auto0 (AttackDirector, BloodFX), bot (this
##            scene: player bot and test hooks), fighters
##            (Fighter + CombatController [+ AIBrain]), brains (AIBrain with
##            --split=1), grab (10), debris (50 DebrisManager), impact (100
##            ImpactResolver).
##   step     last physics script -> SceneTree.process_frame: message queue
##            flush, the Jolt step, physics interpolation bookkeeping.
##   total = pre + prelude + scripts + step  (what Godot's TIME_PHYSICS_PROCESS
##   measures, per tick instead of as a once-a-second maximum).

const BUDGET_AVG_MS := 8.0
const BUDGET_MAX_MS := 12.0
const HZ := 120
const LIVE_RING := 5.0          ## m from the courtyard centre the live enemies start
const CORPSE_SETTLE_MAX := 12.0 ## s to wait for every corpse to settle
const DEBRIS_FLY := 6.0         ## m/s the scripted wall breaks throw chunks into the yard
const PIN_LIFE := 1.0e6         ## s: re-registered timed chunks never fade
const UNKILLABLE_HP := 1.0e6
const SETUP_MAX := 40.0         ## s of physics the setup may take before the run fails

enum Slot { P_START, P_ANIM, P_RAGDOLL, ROOT, ROOT_END, P_FIGHTERS, P_BRAINS, P_GRAB, P_DEBRIS, P_END, PROC_END, COUNT }
enum Ev { NONE, PHYS_SIG, P_END, PROC_SIG, PROC_END }

const BANDS: Array[String] = ["total", "pre", "prelude", "anim", "ragdoll", "auto0", "bot",
	"fighters", "brains", "grab", "debris", "impact", "step"]

class Probe extends Node:
	var host: Node
	var slot := 0
	var physics := true
	func _ready() -> void:
		set_physics_process(physics)
		set_process(not physics)
	func _physics_process(_d: float) -> void:
		host.call(&"_mark", slot)
	func _process(_d: float) -> void:
		host.call(&"_mark", slot)

# Options
var seconds := 60.0
var warmup := 3.0
var n_live := 8
var n_dead := 20
var n_debris := 150
var archetype: StringName = &"grunt"
var bot_mode: StringName = &"fight"
var ai_on := true
var corpses_mode: StringName = &"game"
var debris_at: StringName = &"walls"
var debris_awake := false
var split := false
var csv_path := ""
var launch_every := 0.0       ## s; > 0 launches launch_n standing live enemies this often (stress)
var launch_n := 2
var fixed_arg := -1           ## --fixed=1|0 overrides the fixed-fps auto-detection
var debug_ai := false         ## --debug_ai=1 prints each live enemy's token state every second

# World
var arena: YardBuilder
var fighters_root: Node3D
var player: Fighter
var camera_rig: CameraRig
var hud: HUD
var live: Array[Fighter] = []
var dead: Array[Fighter] = []

# Timing state
var _fixed := false
var _cur := PackedInt64Array()
var _last_ev := Ev.NONE
var _t_phys_sig := 0
var _t_proc_sig := 0
var _t_proc_end := 0
var _pre_us := 0
var _proc_us := 0
var _setup_ticks := 0         ## physics ticks before sampling started
var _sampling := false
var _sample_target := 0
var _sampled := 0
var _tick_ready := false
var _series := {}              ## band -> PackedFloat32Array (ms per tick)
var _rd_live := PackedFloat32Array()   ## per frame: sum of RagdollController.last_tick_ms, live fighters
var _rd_dead := PackedFloat32Array()
var _proc_ms := PackedFloat32Array()
var _mon_last := -1.0
var _mon_seconds := PackedFloat32Array()  ## TIME_PHYSICS_PROCESS readings (max per real second), ms
var _mon_changes := 0
var _sec_total := PackedFloat32Array()
var _stat_active := 0.0
var _stat_pairs := 0.0
var _stat_islands := 0.0
var _stat_n := 0
var _min_debris := 1 << 30
var _min_dead := 1 << 30
var _min_live := 1 << 30
var _scale_sum := 0.0
var _events := {"hits": 0, "blocks": 0, "launches": 0, "tells": 0, "breaks": 0, "deaths": 0}
var _done := false
var _fight_on := false
var _wall_start := 0

# Bot
var _bot_t := 0.0
var _next_action := 0.0
var _held: Array[StringName] = []
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_parse_args()
	seed(1234)
	_rng.seed = 1234
	_cur.resize(Slot.COUNT)
	for b in BANDS:
		_series[b] = PackedFloat32Array()
	get_tree().physics_frame.connect(_on_physics_frame)
	get_tree().process_frame.connect(_on_process_frame)
	_add_probe(Slot.P_START, -100000)
	_add_probe(Slot.P_ANIM, -15)
	_add_probe(Slot.P_RAGDOLL, -5)
	_add_probe(Slot.P_BRAINS, 5)
	_add_probe(Slot.P_GRAB, 30)
	_add_probe(Slot.P_DEBRIS, 75)
	_add_probe(Slot.P_END, 100000)
	_add_probe(Slot.PROC_END, 100000, false)
	GameEvents.hit_landed.connect(func(_i: HitInfo) -> void: _count(&"hits"))
	GameEvents.hit_blocked.connect(func(_i: HitInfo) -> void: _count(&"blocks"))
	GameEvents.fighter_launched.connect(func(_f: Node3D, _v: Vector3) -> void: _count(&"launches"))
	GameEvents.attack_tell.connect(func(_f: Node3D, _k: StringName, _d: float) -> void: _count(&"tells"))
	GameEvents.wall_broken.connect(func(_w: Node3D, _p: Vector3, _e: float, _v: Vector3) -> void: _count(&"breaks"))
	GameEvents.fighter_died.connect(func(_f: Node3D, _i: HitInfo) -> void: _count(&"deaths"))
	print("[perf] options seconds=%.0f live=%d dead=%d debris=%d archetype=%s bot=%s ai=%s corpses=%s debris_at=%s debris_awake=%s split=%s fixed=%d launch_every=%.2f launch_n=%d" % [
		seconds, n_live, n_dead, n_debris, archetype, bot_mode, ai_on, corpses_mode, debris_at,
		debris_awake, split, fixed_arg, launch_every, launch_n])
	_setup.call_deferred()

func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		var k := arg.get_slice("=", 0).trim_prefix("--")
		var v := arg.get_slice("=", 1)
		match k:
			"seconds": seconds = float(v)
			"warmup": warmup = float(v)
			"live": n_live = int(v)
			"dead": n_dead = int(v)
			"debris": n_debris = int(v)
			"archetype": archetype = StringName(v)
			"bot": bot_mode = StringName(v)
			"ai": ai_on = v != "0"
			"corpses": corpses_mode = StringName(v)
			"debris_at": debris_at = StringName(v)
			"debris_awake": debris_awake = v == "1"
			"split": split = v == "1"
			"csv": csv_path = v
			"launch_every": launch_every = float(v)
			"launch_n": launch_n = int(v)
			"fixed": fixed_arg = int(v)
			"debug_ai": debug_ai = v == "1"

func _add_probe(slot: int, priority: int, physics := true) -> void:
	var p := Probe.new()
	p.name = "Probe%d" % slot
	p.host = self
	p.slot = slot
	p.physics = physics
	if physics:
		p.process_physics_priority = priority
	else:
		p.process_priority = priority
	add_child(p)

func _count(key: StringName) -> void:
	if _sampling:
		_events[String(key)] += 1

# --- Setup (GameMode.start_round order) ------------------------------------------
func _setup() -> void:
	TimeDirector.reset()
	AttackDirector.reset()
	ImpactResolver.reset()
	DebrisManager.reset()
	BloodFX.reset()
	arena = YardBuilder.new()
	arena.name = "Arena"
	add_child(arena)
	if not arena.is_in_group(&"arena"):
		arena.add_to_group(&"arena")
	arena.build()
	fighters_root = Node3D.new()
	fighters_root.name = "Fighters"
	add_child(fighters_root)
	# Priority 0 like Fighter/AIBrain, after the Fighters node in tree order:
	# closes the "fighters" band.
	_add_probe(Slot.P_FIGHTERS, 0)

	var centre := arena.get_courtyard_bounds().get_center()
	centre.y = 0.0
	var p_xform := _facing(arena.get_player_spawn(), centre)
	player = FighterFactory.spawn_player(fighters_root, p_xform)
	player.face_dir = -p_xform.basis.z
	player.reset_physics_interpolation()
	player.max_hp = UNKILLABLE_HP
	player.hp = UNKILLABLE_HP
	AttackDirector.set_player(player)
	camera_rig = CameraRig.new()
	camera_rig.name = "CameraRig"
	camera_rig.target = player
	add_child(camera_rig)
	hud = HUD.new()
	hud.name = "HUD"
	add_child(hud)
	hud.set_player(player)
	hud.set_mode(&"waves")
	await _steps(2)

	var t0 := Time.get_ticks_msec()
	await _setup_corpses()
	print("[perf] corpses: %d spawned and killed, %d settled (%.1f s wall)" % [
		dead.size(), _settled_corpses(), (Time.get_ticks_msec() - t0) / 1000.0])
	t0 = Time.get_ticks_msec()
	await _setup_debris()
	print("[perf] debris: %d registered (large %d, timed %d), %d panels broken (%.1f s wall)" % [
		DebrisManager.count(), DebrisManager.count_large(), DebrisManager.count_small(), _events_breaks_setup,
		(Time.get_ticks_msec() - t0) / 1000.0])
	_spawn_live(centre)
	_fight_on = true
	if split:
		for f in live + dead:
			if f.brain:
				f.brain.process_physics_priority = 2
	TimeDirector.reset()  # wall-break slow motion from the setup
	_collect_props()
	var w0 := Time.get_ticks_msec()
	await _steps(int(warmup * HZ))
	var wall := (Time.get_ticks_msec() - w0) / 1000.0
	# Godot does not report --fixed-fps to scripts: under it the warm-up runs
	# much faster than real time (unless a tick costs more than 8.3 ms).
	_fixed = wall < warmup * 0.75 if fixed_arg < 0 else fixed_arg == 1
	print("[perf] warm-up done (%.2f s wall for %.1f s physics -> fixed_fps=%s): live=%d dead=%d debris=%d props=%d; sampling %d ticks" % [
		wall, warmup, _fixed, _live_count(), _dead_count(), DebrisManager.count(), _props.size(), int(seconds * HZ)])
	_sample_target = int(seconds * HZ)
	_sampled = 0
	_wall_start = Time.get_ticks_msec()
	_mon_last = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
	_sampling = true

func _steps(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

var _events_breaks_setup := 0
var _props: Array[RigidBody3D] = []   ## loose arena props (chairs, drums, cabinets)
var _launch_t := 0.0
var _awake_sum := 0.0
var _awake_max := 0
var _bones_sum := 0.0
var _bones_max := 0

func _collect_props() -> void:
	_props.clear()
	var stack: Array[Node] = [arena]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is RigidBody3D and not n.is_in_group(&"debris"):
			_props.append(n)
		stack.append_array(n.get_children())

## Physical bones simulating now (live fighters, the player and unfrozen corpses).
func _sim_bones() -> int:
	var n := 0
	for f in [player] + live + dead:
		if not is_instance_valid(f) or f.ragdoll == null or not f.ragdoll.is_simulating():
			continue
		if f.is_dead() and _corpse_frozen(f):
			continue
		var sim = f.ragdoll.get(&"_sim")
		if sim is PackedByteArray:
			for b in sim:
				n += 1 if b else 0
		else:
			n += 14
	return n

## Stress: launch `launch_n` standing live enemies (the public Fighter.launch).
func _launch_some() -> void:
	var standing: Array[Fighter] = []
	for f in live:
		if is_instance_valid(f) and not f.is_dead() and not f.is_down():
			standing.append(f)
	_shuffle(standing)
	for i in mini(launch_n, standing.size()):
		var f := standing[i]
		var a := _rng.randf() * TAU
		var v := Vector3(cos(a), 0.0, sin(a)) * _rng.randf_range(7.0, 11.0) + Vector3.UP * _rng.randf_range(2.0, 4.0)
		f.launch(v, f.get_aim_point(), &"Chest")

func _setup_corpses() -> void:
	if n_dead <= 0:
		return
	var spots := _corpse_spots(n_dead)
	for i in n_dead:
		var xf := Transform3D(Basis(Vector3.UP, _rng.randf() * TAU), spots[i])
		var f := FighterFactory.spawn_enemy(fighters_root, archetype, xf, PackedVector3Array())
		f.name = "Corpse%d" % i
		f.face_dir = -xf.basis.z
		f.reset_physics_interpolation()
		dead.append(f)
	await _steps(2)
	for f in dead:
		f.apply_damage(f.hp + 1.0, &"perf")  # Fighter._die -> RagdollController.kill
	var waited := 0
	while waited < int(CORPSE_SETTLE_MAX * HZ):
		await get_tree().physics_frame
		waited += 1
		if _settled_corpses() >= dead.size():
			break

## Spread over the courtyard on a jittered grid, clear of the pillars and of
## the player's start.
func _corpse_spots(n: int) -> PackedVector3Array:
	var cand := PackedVector3Array()
	var step := 3.4
	var x := -9.0
	while x <= 9.01:
		var z := -9.0
		while z <= 9.01:
			cand.append(Vector3(x, 0.05, z))
			z += step
		x += step
	# Round 5 Yard: keep corpses off the platform, low walls and crates too.
	var blocked: Array[AABB] = []
	if arena != null and arena.has_method(&"get_parkour_features"):
		var feats: Dictionary = arena.get_parkour_features()
		blocked.append(feats["platform"])
		for a: AABB in feats["low_walls"]:
			blocked.append(a)
		for crate: Node3D in feats["crates"]:
			blocked.append(AABB(crate.global_position - Vector3(0.7, 0, 0.7), Vector3(1.4, 1.2, 1.4)))
	var ok := PackedVector3Array()
	var p := player.global_position
	for c in cand:
		var near_pillar := false
		for pl: Vector2 in YardBuilder.PILLARS:
			if Vector2(c.x - pl.x, c.z - pl.y).length() < 1.8:
				near_pillar = true
		for box in blocked:
			if box.grow(0.9).has_point(Vector3(c.x, box.position.y + 0.05, c.z)):
				near_pillar = true
		if not near_pillar and Vector2(c.x - p.x, c.z - p.z).length() > 3.0:
			ok.append(c)
	var out := PackedVector3Array()
	var order := range(ok.size())
	for i in range(order.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var tmp: int = order[i]
		order[i] = order[j]
		order[j] = tmp
	for i in n:
		var base: Vector3 = ok[order[i % ok.size()]]
		var jitter := Vector3(_rng.randf_range(-0.6, 0.6), 0.0, _rng.randf_range(-0.6, 0.6))
		if i >= ok.size():
			jitter *= 2.0
		out.append(base + jitter)
	return out

func _setup_debris() -> void:
	if n_debris <= 0:
		return
	var b0: int = _events["breaks"]
	var facade: Array[Destructible] = []
	var other: Array[Destructible] = []
	for d in arena.get_destructibles():
		if d.kind != &"panel" or d.is_broken or d.is_unbreakable():
			continue
		(facade if d.has_meta(&"facade") else other).append(d)
	_shuffle(facade)
	_shuffle(other)
	var broke := 0
	for d in facade + other:
		if _debris_live() >= n_debris:
			break
		# +Z is the courtyard face: chunks fly into the yard, like a breach.
		d.force_break(d.global_position, d.global_basis.z * DEBRIS_FLY)
		broke += 1
		await _steps(4)
	_events_breaks_setup = broke
	await _steps(HZ * 3)  # let the chunks land
	_pin_debris()
	if debris_at == &"fight":
		_drop_debris_on_fight()
	if debris_awake:
		for b in DebrisManager.get_bodies():
			b.can_sleep = false
			b.sleeping = false
	await _steps(HZ * 2)
	_events["breaks"] = b0

func _shuffle(arr: Array) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp

func _debris_live() -> int:
	return DebrisManager.get_bodies().size()

## Keep exactly n_debris chunks and stop any of them fading: timed chunks are
## re-registered with PIN_LIFE, medium ones as persistent. Extras are freed.
func _pin_debris() -> void:
	var bodies := DebrisManager.get_bodies()
	var kept := 0
	for b in bodies:
		var small: bool = b.get_meta(&"debris_small", false)
		DebrisManager.release(b)
		if kept < n_debris:
			DebrisManager.register(b, small, PIN_LIFE if small else -1.0)
			kept += 1
		else:
			b.queue_free()

## --debris_at=fight: the same chunks, dropped from 0.3-1.5 m over a disc of
## 8 m around the courtyard centre (rubble under the fight).
func _drop_debris_on_fight() -> void:
	for b in DebrisManager.get_bodies():
		var a := _rng.randf() * TAU
		var r := sqrt(_rng.randf()) * 8.0
		var pos := Vector3(cos(a) * r, _rng.randf_range(0.3, 1.5), sin(a) * r)
		var rot := Basis.from_euler(Vector3(_rng.randf() * TAU, _rng.randf() * TAU, _rng.randf() * TAU))
		b.global_transform = Transform3D(rot, pos)
		b.linear_velocity = Vector3.ZERO
		b.angular_velocity = Vector3.ZERO
		b.sleeping = false
		b.reset_physics_interpolation()

func _spawn_live(centre: Vector3) -> void:
	for i in n_live:
		var ang := TAU * float(i) / maxf(float(n_live), 1.0)
		var pos := centre + Vector3(sin(ang), 0.0, cos(ang)) * LIVE_RING
		pos.y = YardBuilder.SPAWN_Y
		var xf := _facing(Transform3D(Basis(), pos), player.global_position)
		var f := FighterFactory.spawn_enemy(fighters_root, archetype, xf, PackedVector3Array())
		f.name = "Live%d" % i
		f.face_dir = -xf.basis.z
		f.reset_physics_interpolation()
		f.max_hp = UNKILLABLE_HP
		f.hp = UNKILLABLE_HP
		AttackDirector.register_enemy(f)
		if not ai_on and f.brain:
			f.brain.process_mode = Node.PROCESS_MODE_DISABLED
		live.append(f)

static func _facing(xform: Transform3D, toward: Vector3) -> Transform3D:
	var d := toward - xform.origin
	d.y = 0.0
	if d.length() < 0.01:
		return xform
	return Transform3D(Basis.looking_at(d.normalized(), Vector3.UP), xform.origin)

# --- Counts -----------------------------------------------------------------------
func _settled_corpses() -> int:
	var n := 0
	for f in dead:
		if is_instance_valid(f) and f.ragdoll and _corpse_frozen(f):
			n += 1
	return n

func _corpse_frozen(f: Fighter) -> bool:
	var v = f.ragdoll.get(&"_dead_frozen")
	if v == null:
		return not f.ragdoll.is_simulating()
	return bool(v)

func _live_count() -> int:
	var n := 0
	for f in live:
		if is_instance_valid(f) and not f.is_dead():
			n += 1
	return n

func _dead_count() -> int:
	var n := 0
	for f in dead:
		if is_instance_valid(f) and f.is_dead():
			n += 1
	return n

# --- Per tick ---------------------------------------------------------------------
func _physics_process(delta: float) -> void:
	_mark(Slot.ROOT)
	if not _sampling and not _done:
		_setup_ticks += 1
		if _setup_ticks > int((warmup + SETUP_MAX) * HZ):
			print("PERF setup failed: sampling never started (live=%d dead=%d debris=%d)" % [
				_live_count(), _dead_count(), DebrisManager.count()])
			get_tree().quit(1)
	if _fight_on:
		_bot_t += delta / maxf(Engine.time_scale, 0.01)
		_drive_bot()
		if launch_every > 0.0:
			_launch_t += delta
			if _launch_t >= launch_every:
				_launch_t -= launch_every
				_launch_some()
		if corpses_mode == &"awake":
			_keep_corpses_awake()
	_mark(Slot.ROOT_END)

## --corpses=awake: undo the settle freeze and keep the settle timers at 0
## (test-only reach into RagdollController privates; an experiment).
func _keep_corpses_awake() -> void:
	for f in dead:
		if not is_instance_valid(f) or f.ragdoll == null:
			continue
		var r := f.ragdoll
		if bool(r.get(&"_dead_frozen")) and r.has_method(&"_unfreeze_dead"):
			r.call(&"_unfreeze_dead")
		r.set(&"_dead_still_t", 0.0)
		r.set(&"_state_t", 0.0)

func _mark(slot: int) -> void:
	var t := Time.get_ticks_usec()
	if slot == Slot.PROC_END:
		_proc_us = t - _t_proc_sig
		_t_proc_end = t
		_last_ev = Ev.PROC_END
		return
	_cur[slot] = t
	if slot == Slot.P_END:
		_last_ev = Ev.P_END

func _on_physics_frame() -> void:
	var t := Time.get_ticks_usec()
	if _last_ev == Ev.P_END:
		_finish_tick(t)  # several ticks in one frame: the previous step ended here
		_pre_us = 0
	elif _last_ev == Ev.PROC_END:
		_pre_us = t - _t_proc_end
	else:
		_pre_us = 0
	_t_phys_sig = t
	_last_ev = Ev.PHYS_SIG

func _on_process_frame() -> void:
	var t := Time.get_ticks_usec()
	if _last_ev == Ev.P_END:
		_finish_tick(t)
	_t_proc_sig = t
	_last_ev = Ev.PROC_SIG

func _finish_tick(t_after: int) -> void:
	if not _sampling or _done:
		return
	var c := _cur
	var step := t_after - c[Slot.P_END]
	var prelude := c[Slot.P_START] - _t_phys_sig
	var pre := _pre_us if _fixed else 0
	var total := pre + prelude + (c[Slot.P_END] - c[Slot.P_START]) + step
	_push(&"total", total)
	_push(&"pre", _pre_us)
	_push(&"prelude", prelude)
	_push(&"anim", c[Slot.P_ANIM] - c[Slot.P_START])
	_push(&"ragdoll", c[Slot.P_RAGDOLL] - c[Slot.P_ANIM])
	_push(&"auto0", c[Slot.ROOT] - c[Slot.P_RAGDOLL])
	_push(&"bot", c[Slot.ROOT_END] - c[Slot.ROOT])
	_push(&"fighters", c[Slot.P_FIGHTERS] - c[Slot.ROOT_END])
	_push(&"brains", c[Slot.P_BRAINS] - c[Slot.P_FIGHTERS])
	_push(&"grab", c[Slot.P_GRAB] - c[Slot.P_BRAINS])
	_push(&"debris", c[Slot.P_DEBRIS] - c[Slot.P_GRAB])
	_push(&"impact", c[Slot.P_END] - c[Slot.P_DEBRIS])
	_push(&"step", step)
	_sampled += 1
	_tick_ready = true

func _push(band: StringName, us: int) -> void:
	var arr: PackedFloat32Array = _series[String(band)]
	arr.append(us / 1000.0)
	_series[String(band)] = arr

## Idle-side bookkeeping (not inside the physics timing).
func _process(_delta: float) -> void:
	if not _sampling or _done:
		return
	var mon := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
	if mon != _mon_last:
		_mon_last = mon
		_mon_changes += 1
		if _mon_changes > 1:  # the first reading's real second began before sampling
			_mon_seconds.append(mon * 1000.0)
	if _tick_ready:
		_tick_ready = false
		var rl := 0.0
		var rd := 0.0
		for f in live:
			if is_instance_valid(f) and f.ragdoll:
				rl += float(f.ragdoll.get(&"last_tick_ms"))
		if player and player.ragdoll:
			rl += float(player.ragdoll.get(&"last_tick_ms"))
		for f in dead:
			if is_instance_valid(f) and f.ragdoll:
				rd += float(f.ragdoll.get(&"last_tick_ms"))
		_rd_live.append(rl)
		_rd_dead.append(rd)
		_proc_ms.append(_proc_us / 1000.0)
		_scale_sum += Engine.time_scale
	if _sampled > 0 and _sampled % HZ == 0 and _sampled != _last_report:
		_last_report = _sampled
		_report_second()
	if _sampled >= _sample_target:
		_finish()

var _last_report := -1

func _report_second() -> void:
	var tot: PackedFloat32Array = _series["total"]
	var a := 0.0
	var m := 0.0
	for i in range(tot.size() - HZ, tot.size()):
		a += tot[i]
		m = maxf(m, tot[i])
	a /= HZ
	_sec_total.append(a)
	var active := int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS))
	var pairs := int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS))
	var islands := int(Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT))
	_stat_active += active
	_stat_pairs += pairs
	_stat_islands += islands
	_stat_n += 1
	var lc := _live_count()
	var dc := _dead_count()
	var deb := DebrisManager.count()
	_min_live = mini(_min_live, lc)
	_min_dead = mini(_min_dead, dc)
	_min_debris = mini(_min_debris, deb)
	var awake := 0
	for b in DebrisManager.get_bodies():
		if not b.sleeping:
			awake += 1
	var props_awake := 0
	for b in _props:
		if is_instance_valid(b) and not b.sleeping:
			props_awake += 1
	var bones := _sim_bones()
	var dyn := awake + props_awake + bones
	if debug_ai:
		var parts := PackedStringArray()
		for f in live:
			if is_instance_valid(f):
				parts.append("%s:%s%s d=%.1f" % [f.name, "T " if AttackDirector.has_token(f) else "",
					AttackDirector.get_last_denial(f), f.get_ground_position().distance_to(player.get_ground_position())])
		print("[perf-ai] player state=%d down=%s hitstun=%s pos=%s | %s" % [player.get_state(), player.is_down(),
			player.is_in_hitstun(), player.get_ground_position().snapped(Vector3.ONE * 0.1), " | ".join(parts)])
	_awake_sum += dyn
	_awake_max = maxi(_awake_max, dyn)
	_bones_sum += bones
	_bones_max = maxi(_bones_max, bones)
	var sim_live := 0
	for f in live:
		if is_instance_valid(f) and f.ragdoll and f.ragdoll.is_simulating():
			sim_live += 1
	var sim_dead := 0
	for f in dead:
		if is_instance_valid(f) and f.ragdoll and not _corpse_frozen(f):
			sim_dead += 1
	print("[perf] t=%2ds phys avg=%.2f max=%.2f ms (mon_max=%.2f) awake_dynamic=%d (bones %d, debris %d, props %d) live=%d (ragdolling %d) dead=%d (unfrozen %d) debris=%d scale=%.2f" % [
		int(_sampled / float(HZ)), a, m, _mon_last * 1000.0, dyn, bones, awake, props_awake, lc, sim_live, dc, sim_dead, deb, Engine.time_scale])

# --- Bot (same action mix as tests/integration/soak_test.gd, minus Focus) -----------
func _drive_bot() -> void:
	if player.is_dead():
		_release_all()
		return
	var target: Fighter = Targeting.pick_target(player, Vector3.ZERO, 40.0)
	_steer(target)
	if _bot_t < _next_action:
		return
	_next_action = _bot_t + _rng.randf_range(0.15, 0.6)
	_release_all()
	if target == null:
		return
	var dist := player.get_ground_position().distance_to(target.get_ground_position())
	var roll := _rng.randf()
	var actions: Array[StringName] = []
	if bot_mode == &"passive":
		if roll < 0.5:
			actions = [&"block"]
	elif dist > 4.0:
		if roll < 0.3:
			actions = [&"dash"]
		elif roll < 0.38:
			actions = [&"jump"]
	elif roll < 0.35:
		actions = [&"punch"]
	elif roll < 0.5:
		actions = [&"kick"]
	elif roll < 0.58:
		actions = [&"crouch", &"kick"]
	elif roll < 0.64:
		actions = [&"jump", &"kick"]
	elif roll < 0.74:
		actions = [&"grab"]
	elif roll < 0.9:
		actions = [&"block"]
	else:
		actions = [&"dash"]
	for action in actions:
		if InputMap.has_action(action):
			Input.action_press(action)
			_held.append(action)

func _steer(target: Fighter) -> void:
	for a in [&"move_forward", &"move_back", &"move_left", &"move_right"]:
		Input.action_release(a)
	if target == null:
		return
	var to := target.get_ground_position() - player.get_ground_position()
	to.y = 0.0
	if to.length() < 1.2:
		return
	var cam := get_viewport().get_camera_3d()
	var cb := cam.global_basis if cam else Basis()
	var fwd := -cb.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	var right := cb.x
	right.y = 0.0
	right = right.normalized() if right.length() > 0.01 else Vector3.RIGHT
	to = to.normalized()
	var f := fwd.dot(to)
	var r := right.dot(to)
	if f > 0.1: Input.action_press(&"move_forward", f)
	if f < -0.1: Input.action_press(&"move_back", -f)
	if r > 0.1: Input.action_press(&"move_right", r)
	if r < -0.1: Input.action_press(&"move_left", -r)

func _release_all() -> void:
	for a in _held:
		Input.action_release(a)
	_held.clear()

# --- Results ----------------------------------------------------------------------
func _finish() -> void:
	_done = true
	_sampling = false
	_release_all()
	var wall := (Time.get_ticks_msec() - _wall_start) / 1000.0
	print("[perf] sampled %d ticks (%.1f s physics) in %.1f s wall; avg time scale %.2f" % [
		_sampled, _sampled / float(HZ), wall, _scale_sum / maxf(float(_rd_live.size()), 1.0)])
	print("[perf] counts: live>=%d dead>=%d debris>=%d props=%d; awake dynamic bodies avg=%.0f max=%d (simulating bones avg=%.0f max=%d); Performance PHYSICS_3D monitors avg active=%.0f pairs=%.0f islands=%.0f (Jolt reports 0)" % [
		_min_live, _min_dead, _min_debris, _props.size(), _awake_sum / maxf(_stat_n, 1), _awake_max,
		_bones_sum / maxf(_stat_n, 1), _bones_max, _stat_active / maxf(_stat_n, 1), _stat_pairs / maxf(_stat_n, 1),
		_stat_islands / maxf(_stat_n, 1)])
	print("[perf] events during sampling: %s" % [_events])
	print("[perf] band           avg     p95     p99     max   (ms per tick)")
	for b in BANDS:
		var s := _stats(_series[b])
		print("[perf]   %-10s %7.3f %7.3f %7.3f %7.3f" % [b, s.avg, s.p95, s.p99, s.max])
	var rl := _stats(_rd_live)
	var rd := _stats(_rd_dead)
	var pr := _stats(_proc_ms)
	print("[perf]   %-10s %7.3f %7.3f %7.3f %7.3f   (sum of RagdollController.last_tick_ms, player + live)" % ["rd_live", rl.avg, rl.p95, rl.p99, rl.max])
	print("[perf]   %-10s %7.3f %7.3f %7.3f %7.3f   (sum of RagdollController.last_tick_ms, corpses)" % ["rd_dead", rd.avg, rd.p95, rd.p99, rd.max])
	print("[perf]   %-10s %7.3f %7.3f %7.3f %7.3f   (idle frame, not physics)" % ["process", pr.avg, pr.p95, pr.p99, pr.max])
	var mon := _stats(_mon_seconds)
	print("[perf] TIME_PHYSICS_PROCESS monitor (max per real second, %d readings): mean=%.2f max=%.2f ms" % [
		_mon_seconds.size(), mon.avg, mon.max])
	var sec := _stats(_sec_total)
	print("[perf] per-second avg of total: min=%.2f max=%.2f ms" % [sec.min, sec.max])
	var t := _stats(_series["total"])
	var ok: bool = t.avg <= BUDGET_AVG_MS and t.max <= BUDGET_MAX_MS
	print("PERF avg=%.2f p95=%.2f max=%.2f verdict=%s (live=%d dead=%d debris=%d fixed_fps=%s)" % [
		t.avg, t.p95, t.max, "PASS" if ok else "FAIL", n_live, n_dead, n_debris, _fixed])
	if csv_path != "":
		_write_csv()
	get_tree().quit(0)

func _stats(arr: PackedFloat32Array) -> Dictionary:
	if arr.is_empty():
		return {"avg": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0, "min": 0.0}
	var s := arr.duplicate()
	s.sort()
	var sum := 0.0
	for v in s:
		sum += v
	return {"avg": sum / s.size(), "p95": s[int(0.95 * (s.size() - 1))], "p99": s[int(0.99 * (s.size() - 1))],
		"max": s[s.size() - 1], "min": s[0]}

func _write_csv() -> void:
	var f := FileAccess.open(csv_path, FileAccess.WRITE)
	if f == null:
		push_warning("perf_crowd: cannot write %s" % csv_path)
		return
	f.store_line(",".join(BANDS) + ",rd_live,rd_dead")
	var n: int = (_series["total"] as PackedFloat32Array).size()
	for i in n:
		var row := PackedStringArray()
		for b in BANDS:
			row.append("%.3f" % (_series[b] as PackedFloat32Array)[i])
		row.append("%.3f" % (_rd_live[i] if i < _rd_live.size() else 0.0))
		row.append("%.3f" % (_rd_dead[i] if i < _rd_dead.size() else 0.0))
		f.store_line(",".join(row))
	f.close()
	print("[perf] wrote %s" % csv_path)
