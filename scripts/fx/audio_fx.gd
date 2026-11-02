extends Node
## Autoload "AudioFX": procedurally synthesised placeholder sounds (no audio
## assets yet) played as pooled AudioStreamPlayer3D. Event-driven via
## GameEvents; volume and pitch scale with energy. Pitch follows
## AudioServer.playback_speed_scale (set by TimeDirector).
## OWNER: agent F (blood & audio). CONTRACT STUB.
##
## Sound ids: punch, kick, heavy_hit, block, whoosh, dodge, teleport, grab,
##   throw, break_grab, crack, wall_break, thud, body_slam, tell_strike,
##   tell_grab, ko, wave_start, ui
## Round 2: clank (armor; agent B plays it), break_drywall, break_brick,
##   break_wood (wall_broken by surface), debris (debris_landed, throttled),
##   miss (dodge_feedback tick)
## Upgrade 2: charge_hum (loop), charge_level, charge_release, jump, land,
##   crouch, hit_cross, hit_hook, hit_uppercut, hit_roundhouse,
##   hit_flying_kick, hit_stomp, arm_break, wall_slam, focus_in, focus_out
## Round 3: strike_drywall, strike_brick, strike_wood, strike_concrete,
##   strike_hold (wall_struck; 5 variants each so rapid jabs do not repeat)
## Focus: world sounds slow with AudioServer.playback_speed_scale (set by
##   TimeDirector); the player's own sounds are pitch-compensated by
##   TimeDirector.player_time_factor() so they stay at normal pitch. Callers
##   pass the source fighter to play(..., source) to get that treatment.
##
## Every id is synthesised at startup on a worker thread into VARIANTS
## AudioStreamWAV (16-bit mono PCM, 44.1 kHz): sine / noise oscillators,
## exponential pitch sweeps, one-pole filters and envelopes. Variant 0 of every
## id is built first so the game has every sound within about a second; the
## extra variants follow. play() before a sound exists is silently skipped.

const MIX_RATE := 44100
const VARIANTS := 3
## Ids that get more variants (rapid repeats on the same wall).
const VARIANTS_BY_ID := {&"strike_drywall": 5, &"strike_brick": 5, &"strike_wood": 5,
	&"strike_concrete": 5, &"strike_hold": 5}
const POOL_3D := 24
const POOL_UI := 6
## Peak level every sound is normalised to (headroom below int16 full scale).
const PEAK := 0.89
## The same id is not retriggered within this many ms (one hit firing two events).
## Timed on the physics-tick clock (like TimeDirector.now()), not wall time.
const RETRIGGER_MS := 25
## Stings that GameMode may also play directly: a longer window removes the double.
const RETRIGGER_MS_BY_ID := {&"ko": 600, &"wave_start": 600}
## Random pitch spread, +-5% (task brief).
const PITCH_JITTER := 0.05
## At exit, the longest wait (ms) for the audio thread to release stopped
## playbacks, so quitting does not report leaked AudioStreamPlaybackWAV.
const EXIT_DRAIN_MS := 300

## Build order: most needed first. Every id the stub lists.
const IDS: Array[StringName] = [
	&"ui", &"punch", &"kick", &"whoosh", &"block", &"tell_strike", &"tell_grab",
	&"wave_start", &"heavy_hit", &"thud", &"body_slam", &"dodge", &"teleport",
	&"grab", &"throw", &"break_grab", &"crack", &"wall_break", &"ko",
	&"miss", &"clank", &"debris", &"break_drywall", &"break_brick", &"break_wood",
	&"charge_hum", &"charge_level", &"charge_release", &"jump", &"land", &"crouch",
	&"hit_cross", &"hit_hook", &"hit_uppercut", &"hit_roundhouse", &"hit_flying_kick",
	&"hit_stomp", &"arm_break", &"wall_slam", &"focus_in", &"focus_out",
	&"strike_drywall", &"strike_brick", &"strike_wood", &"strike_concrete", &"strike_hold",
]
## wall_struck sound by surface.
const STRIKE_BY_SURFACE := {
	&"drywall": &"strike_drywall", &"brick": &"strike_brick", &"wood": &"strike_wood",
	&"concrete": &"strike_concrete",
}
const STRIKE_REF_POWER := 60.0    ## a standing kick: plays at the base level and pitch
const STRIKE_GAP_MS := 70         ## per-surface cooldown (two limbs on one wall in one tick)
const STRIKE_STREAK_MS := 450     ## hits closer than this count as a rapid streak...
const STRIKE_STREAK_DB := 1.2     ## ...each one this much quieter...
const STRIKE_STREAK_MIN_DB := -4.0  ## ...down to this
const STRIKE_PITCH_JITTER := 0.08 ## extra pitch spread on strikes (on top of PITCH_JITTER)
const STRIKE_MIN_DB := -7.0       ## the weakest strike (a jab) is at most this much under the base level
const STRIKE_HOLE_DB := -3.0      ## a hole layers the surface's break sound this much quieter
const STRIKE_CRACK_DB := -6.0     ## a crack layers the crack sound
## Ids synthesised as seamless loops (played until stopped).
const LOOP_IDS: Array[StringName] = [&"charge_hum"]

## Charge hum: pitch and level (dB) by charge level 0..3, players kept for it.
const HUM_PITCH: Array[float] = [1.0, 1.2, 1.45, 1.8]
const HUM_DB: Array[float] = [-9.0, -6.0, -3.5, -1.0]
const HUM_POOL := 4
const HUM_MAX_TIME := 3.0         ## s: a hum with no release event stops anyway
const HUM_SLEW := 12.0            ## dB per second toward the level's volume
## A charged release already whooshed: skip the attack_active whoosh this soon after (ms).
const RELEASE_WHOOSH_GAP_MS := 400
## Charged hits (level 2+) layer heavy_hit under the strike sound, this much quieter (dB).
const CHARGED_LAYER_DB := -6.0

## wall_broken sound by Destructible.surface (anything else: wall_break).
const BREAK_BY_SURFACE := {
	&"drywall": &"break_drywall", &"brick": &"break_brick", &"wood": &"break_wood",
}
## debris_landed throttle: a burst of DEBRIS_BURST, refilled at DEBRIS_RATE per
## second; one chunk is heard at most once per DEBRIS_BODY_GAP s.
const DEBRIS_BURST := 4.0
const DEBRIS_RATE := 10.0
const DEBRIS_BODY_GAP := 0.15
const DEBRIS_MIN_SPEED := 1.0     ## m/s
const DEBRIS_REF_ENERGY := 40.0   ## J (2 kg at about 6 m/s) plays at base level
## Debris pitch by what it is made of / hit (lighter materials ring higher).
const DEBRIS_PITCH_BY_SURFACE := {
	&"drywall": 1.15, &"wood": 1.05, &"brick": 0.95, &"concrete": 0.9,
}

## Mix level per id (dB), so normalised sounds sit together.
const BASE_DB := {
	&"punch": -2.0, &"kick": -1.0, &"heavy_hit": 0.0, &"block": -4.0,
	&"whoosh": -9.0, &"dodge": -5.0, &"teleport": -4.0, &"grab": -6.0,
	&"throw": -6.0, &"break_grab": -5.0, &"crack": -3.0, &"wall_break": 0.0,
	&"thud": -3.0, &"body_slam": -1.0, &"tell_strike": -6.0, &"tell_grab": -5.0,
	&"ko": -1.0, &"wave_start": -4.0, &"ui": -4.0,
	&"miss": -10.0, &"clank": -3.0, &"debris": -8.0,
	&"break_drywall": 0.0, &"break_brick": 0.0, &"break_wood": -1.0,
	&"charge_hum": -8.0, &"charge_level": -8.0, &"charge_release": -3.0, &"jump": -9.0,
	&"land": -7.0, &"crouch": -13.0, &"hit_cross": -2.0, &"hit_hook": -1.0,
	&"hit_uppercut": 0.0, &"hit_roundhouse": 0.0, &"hit_flying_kick": 0.0, &"hit_stomp": 0.0,
	&"arm_break": 0.0, &"wall_slam": 0.0, &"focus_in": -4.0, &"focus_out": -6.0,
	&"strike_drywall": -2.0, &"strike_brick": -2.0, &"strike_wood": -2.0, &"strike_concrete": -2.0,
	&"strike_hold": -3.0,
}

## Energy (J) at which a sound plays at its base level; louder above, quieter below.
const REF_ENERGY := {
	&"punch": 1500.0, &"kick": 2500.0, &"heavy_hit": 8000.0, &"thud": 1200.0,
	&"body_slam": 5000.0, &"crack": 3000.0, &"wall_break": 6000.0,
	&"break_drywall": 3000.0, &"break_brick": 8000.0, &"break_wood": 2000.0,
	&"hit_cross": 1500.0, &"hit_hook": 2000.0, &"hit_uppercut": 4000.0, &"hit_roundhouse": 4000.0,
	&"hit_flying_kick": 6000.0, &"hit_stomp": 3000.0, &"wall_slam": 2800.0,
}
## Hits at or above this energy (J) use heavy_hit whatever the move.
const HEAVY_HIT_ENERGY := 7000.0
## Heavy moves (power punch, e_heavy, e_charge) below this (J) sound like a punch.
const HEAVY_MOVE_MIN_ENERGY := 2500.0
## Body impacts at or above this energy (J) use body_slam instead of thud.
const SLAM_ENERGY := 2500.0

var _streams: Dictionary = {}       ## StringName -> Array of AudioStreamWAV
var _last_variant: Dictionary = {}  ## StringName -> int
var _last_ms: Dictionary = {}       ## StringName -> int (msec)
var _mutex := Mutex.new()
var _task_id := -1
var _abort := false
var _ready_count := 0
var _complete := false            ## every variant of every id is built

var _players: Array[AudioStreamPlayer3D] = []
var _ui_players: Array[AudioStreamPlayer] = []
var _next_3d := 0
var _next_ui := 0
var _rng := RandomNumberGenerator.new()
var _debris_tokens := DEBRIS_BURST
var _debris_ms := 0               ## clock of the last token refill
var _debris_last: Dictionary = {} ## chunk instance id -> clock ms it was last heard
var _quitting := false
var _used := false                ## any sound was started (exit drain needed)
var _owned_base := PackedFloat32Array()     ## per 3D player: base pitch of a player-owned sound, 0 = world
var _owned_base_ui := PackedFloat32Array()  ## per UI player
var _hum_players: Array[AudioStreamPlayer3D] = []
var _hum_fighter: Array = []                ## Node3D per hum slot (null = idle)
var _hum_level := PackedInt32Array()
var _hum_time := PackedFloat32Array()
var _hum_db := PackedFloat32Array()         ## current volume (slewed)
var _last_release: Dictionary = {}          ## fighter id -> clock ms of its last charged release
var _strike_last: Dictionary = {}           ## surface -> clock ms of its last strike sound
var _strike_streak: Dictionary = {}         ## surface -> rapid hits in a row
var _struck_frame: Dictionary = {}          ## wall id -> process frame of its last wall_struck

## Every sound that actually played (tests, debug overlay).
signal sound_played(id: StringName, position: Vector3)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rng.randomize()
	for id in IDS:
		_streams[id] = []
	for i in POOL_3D:
		var p := AudioStreamPlayer3D.new()
		p.name = "SFX3D_%d" % i
		p.unit_size = 8.0
		p.max_distance = 70.0
		p.max_db = 4.0
		p.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
		p.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		add_child(p)
		_players.append(p)
	for i in POOL_UI:
		var u := AudioStreamPlayer.new()
		u.name = "SFXUI_%d" % i
		add_child(u)
		_ui_players.append(u)
	_owned_base.resize(POOL_3D)
	_owned_base_ui.resize(POOL_UI)
	for i in HUM_POOL:
		var h := AudioStreamPlayer3D.new()
		h.name = "Hum_%d" % i
		h.unit_size = 6.0
		h.max_distance = 50.0
		h.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
		h.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		add_child(h)
		_hum_players.append(h)
		_hum_fighter.append(null)
	_hum_level.resize(HUM_POOL)
	_hum_time.resize(HUM_POOL)
	_hum_db.resize(HUM_POOL)
	_task_id = WorkerThreadPool.add_task(_generate_all, false, "AudioFX synth")
	_ensure_limiter()
	_connect_events()


## Every sound is normalised near full scale, so a hit + whoosh + thud landing
## together would clip: a hard limiter at the end of the Master bus catches it.
func _ensure_limiter() -> void:
	var master := AudioServer.get_bus_index(&"Master")
	if master < 0:
		return
	for i in AudioServer.get_bus_effect_count(master):
		if AudioServer.get_bus_effect(master, i) is AudioEffectHardLimiter:
			return
	var lim := AudioEffectHardLimiter.new()
	lim.ceiling_db = -0.5
	lim.pre_gain_db = -2.0
	AudioServer.add_bus_effect(master, lim)


## Window close: stop everything before the engine starts tearing down.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_quitting = true
		stop_all()

## Children leave the tree before this runs, which only pauses their
## playbacks; stop them explicitly, drop every stream reference, and give the
## audio thread one mix step to release the stopped playbacks. Without this,
## quitting mid-sound prints "N ObjectDB instances were leaked".
func _exit_tree() -> void:
	_quitting = true
	_abort = true
	if _task_id >= 0:
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_id = -1
	if _used:
		_drain_playbacks()
	else:
		stop_all()
	_mutex.lock()
	for id in _streams:
		(_streams[id] as Array).clear()
	_mutex.unlock()


## Stop everything, then wait (bounded) until the audio thread has run two
## more mix steps: a mix step is what takes stopped playbacks off the
## AudioServer's list. A new mix step shows as get_time_since_last_mix()
## dropping.
func _drain_playbacks() -> void:
	stop_all()
	var mixes := 0
	var last := AudioServer.get_time_since_last_mix()
	var waited := 0
	while mixes < 2 and waited < EXIT_DRAIN_MS:
		OS.delay_msec(2)
		waited += 2
		var t := AudioServer.get_time_since_last_mix()
		if t < last:
			mixes += 1
		last = t

## Stop every playing sound (quit, round restart).
func stop_all() -> void:
	for p in _players:
		p.stop()
		p.stream = null
	for u in _ui_players:
		u.stop()
		u.stream = null
	for i in _hum_players.size():
		_hum_players[i].stop()
		_hum_players[i].stream = null
		_hum_fighter[i] = null
	_owned_base.fill(0.0)
	_owned_base_ui.fill(0.0)


# --- Public API --------------------------------------------------------------

## `source`: the fighter making the sound, if any. The player's own sounds keep
## normal pitch during Focus (see header).
func play(id: StringName, position: Vector3, volume_db := 0.0, pitch := 1.0, source: Node3D = null) -> void:
	if _quitting:
		return
	var stream := _pick(id)
	if stream == null:
		return
	var i := _take_3d_index()
	var p := _players[i]
	var base := maxf(pitch * _rng.randf_range(1.0 - PITCH_JITTER, 1.0 + PITCH_JITTER), 0.05)
	_owned_base[i] = base if is_player_source(source) else 0.0
	p.stream = stream
	p.global_position = position
	p.volume_db = BASE_DB.get(id, 0.0) + volume_db
	p.pitch_scale = base * (player_pitch_factor() if _owned_base[i] > 0.0 else 1.0)
	p.play()
	_used = true
	sound_played.emit(id, position)

## Non-positional (UI, slow-motion stings, player feedback). `player_owned`
## keeps it at normal pitch during Focus.
func play_ui(id: StringName, volume_db := 0.0, pitch := 1.0, player_owned := false) -> void:
	if _quitting:
		return
	var stream := _pick(id)
	if stream == null:
		return
	var i := _next_ui
	_next_ui = (_next_ui + 1) % _ui_players.size()
	var p := _ui_players[i]
	var base := maxf(pitch * _rng.randf_range(1.0 - PITCH_JITTER * 0.5, 1.0 + PITCH_JITTER * 0.5), 0.05)
	_owned_base_ui[i] = base if player_owned else 0.0
	p.stream = stream
	p.volume_db = BASE_DB.get(id, 0.0) + volume_db
	p.pitch_scale = base * (player_pitch_factor() if player_owned else 1.0)
	p.play()
	_used = true
	sound_played.emit(id, Vector3.ZERO)

static func is_player_source(source: Node) -> bool:
	return source != null and is_instance_valid(source) and source.is_in_group(&"player")

## Pitch multiplier that cancels the world slow-down for the player's sounds:
## TimeDirector.player_time_factor() (1 / time scale in Focus, else 1).
func player_pitch_factor() -> float:
	var td := get_node_or_null(^"/root/TimeDirector")
	if td == null or not td.has_method(&"player_time_factor"):
		return 1.0
	return clampf(float(td.call(&"player_time_factor")), 0.25, 4.0)

func _process(delta: float) -> void:
	var f := player_pitch_factor()
	for i in _players.size():
		if _owned_base[i] > 0.0:
			if _players[i].playing:
				_players[i].pitch_scale = _owned_base[i] * f
			else:
				_owned_base[i] = 0.0
	for i in _ui_players.size():
		if _owned_base_ui[i] > 0.0:
			if _ui_players[i].playing:
				_ui_players[i].pitch_scale = _owned_base_ui[i] * f
			else:
				_owned_base_ui[i] = 0.0
	_update_hums(delta, f)

## Every sound id this module can play.
func get_ids() -> Array[StringName]:
	return IDS

## True once every id has at least one variant.
func is_ready() -> bool:
	return _ready_count >= IDS.size()

## True once every variant of every id is built (a few seconds after start).
func is_complete() -> bool:
	return _complete

## Number of variants generated so far for `id`.
func variant_count(id: StringName) -> int:
	_mutex.lock()
	var n: int = (_streams.get(id, []) as Array).size()
	_mutex.unlock()
	return n

## Synthesise one variant of `id` now (used by the worker thread and tests).
## Returns null for an unknown id.
func generate(id: StringName, variant := 0) -> AudioStreamWAV:
	var buf := synthesize(id, variant)
	if buf.is_empty():
		return null
	return _to_wav(buf, LOOP_IDS.has(id))

## Raw float samples (-1..1) of one variant, normalised to PEAK.
func synthesize(id: StringName, variant := 0) -> PackedFloat32Array:
	var s := _Synth.new(hash(String(id)) * 31 + variant * 7919 + 17)
	match id:
		&"punch": _make_punch(s)
		&"kick": _make_kick(s)
		&"heavy_hit": _make_heavy_hit(s)
		&"block": _make_block(s)
		&"whoosh": _make_whoosh(s, 0.3, 500.0, 2600.0, 1.0)
		&"dodge": _make_dodge(s)
		&"teleport": _make_teleport(s)
		&"grab": _make_grab(s)
		&"throw": _make_whoosh(s, 0.45, 300.0, 1700.0, 1.0)
		&"break_grab": _make_break_grab(s)
		&"crack": _make_crack(s)
		&"wall_break": _make_wall_break(s)
		&"thud": _make_thud(s)
		&"body_slam": _make_body_slam(s)
		&"tell_strike": _make_tell_strike(s)
		&"tell_grab": _make_tell_grab(s)
		&"ko": _make_ko(s)
		&"wave_start": _make_wave_start(s)
		&"ui": _make_ui(s)
		&"miss": _make_miss(s)
		&"clank": _make_clank(s)
		&"debris": _make_debris(s)
		&"break_drywall": _make_break_drywall(s)
		&"break_brick": _make_break_brick(s)
		&"break_wood": _make_break_wood(s)
		&"charge_hum": _make_charge_hum(s)
		&"charge_level": _make_charge_level(s)
		&"charge_release": _make_charge_release(s)
		&"jump": _make_jump(s)
		&"land": _make_land(s)
		&"crouch": _make_crouch(s)
		&"hit_cross": _make_hit_cross(s)
		&"hit_hook": _make_hit_hook(s)
		&"hit_uppercut": _make_hit_uppercut(s)
		&"hit_roundhouse": _make_hit_roundhouse(s)
		&"hit_flying_kick": _make_hit_flying_kick(s)
		&"hit_stomp": _make_hit_stomp(s)
		&"arm_break": _make_arm_break(s)
		&"wall_slam": _make_wall_slam(s)
		&"focus_in": _make_focus_in(s)
		&"focus_out": _make_focus_out(s)
		&"strike_drywall": _make_strike_drywall(s)
		&"strike_brick": _make_strike_brick(s)
		&"strike_wood": _make_strike_wood(s)
		&"strike_concrete": _make_strike_concrete(s)
		&"strike_hold": _make_strike_hold(s)
		_:
			return PackedFloat32Array()
	s.normalize(PEAK)
	return s.buf


# --- Pool --------------------------------------------------------------------

## Milliseconds on the physics-tick clock (TimeDirector.now() uses the same
## source; read directly so this autoload has no script dependency).
static func clock_ms() -> int:
	@warning_ignore("integer_division")
	return int(Engine.get_physics_frames() * 1000 / maxi(Engine.physics_ticks_per_second, 1))

func _pick(id: StringName) -> AudioStreamWAV:
	var now := clock_ms()
	if now - int(_last_ms.get(id, -100000)) < int(RETRIGGER_MS_BY_ID.get(id, RETRIGGER_MS)):
		return null
	_mutex.lock()
	var list: Array = _streams.get(id, [])
	var n := list.size()
	var stream: AudioStreamWAV = null
	if n > 0:
		var v := _rng.randi_range(0, n - 1)
		if n > 1 and v == int(_last_variant.get(id, -1)):
			v = (v + 1) % n
		_last_variant[id] = v
		stream = list[v]
	_mutex.unlock()
	if stream != null:
		_last_ms[id] = now
	return stream

func _take_3d() -> AudioStreamPlayer3D:
	return _players[_take_3d_index()]

## Prefer an idle player; steal round-robin when all are busy.
func _take_3d_index() -> int:
	var n := _players.size()
	for i in n:
		var k := (_next_3d + i) % n
		if not _players[k].playing:
			_next_3d = (k + 1) % n
			return k
	var q := _next_3d
	_next_3d = (_next_3d + 1) % n
	return q


# --- Event wiring ------------------------------------------------------------

func _connect_events() -> void:
	GameEvents.hit_landed.connect(_on_hit_landed)
	GameEvents.hit_blocked.connect(_on_hit_blocked)
	GameEvents.perfect_dodge.connect(_on_perfect_dodge)
	GameEvents.teleport_counter.connect(_on_teleport_counter)
	GameEvents.pursuit.connect(_on_pursuit)
	GameEvents.attack_tell.connect(_on_attack_tell)
	GameEvents.attack_active.connect(_on_attack_active)
	GameEvents.wall_cracked.connect(_on_wall_cracked)
	GameEvents.wall_broken.connect(_on_wall_broken)
	GameEvents.body_impact.connect(_on_body_impact)
	GameEvents.grab_started.connect(_on_grab_started)
	GameEvents.grab_broken.connect(_on_grab_broken)
	GameEvents.thrown.connect(_on_thrown)
	GameEvents.fighter_died.connect(_on_fighter_died)
	GameEvents.wave_started.connect(_on_wave_started)
	GameEvents.wave_cleared.connect(_on_wave_cleared)
	GameEvents.round_over.connect(_on_round_over)
	GameEvents.debris_landed.connect(_on_debris_landed)
	GameEvents.dodge_feedback.connect(_on_dodge_feedback)
	GameEvents.charge_started.connect(_on_charge_started)
	GameEvents.charge_level_changed.connect(_on_charge_level_changed)
	GameEvents.charge_released.connect(_on_charge_released)
	GameEvents.jumped.connect(_on_jumped)
	GameEvents.landed.connect(_on_landed)
	GameEvents.crouch_changed.connect(_on_crouch_changed)
	GameEvents.arm_broken.connect(_on_arm_broken)
	GameEvents.wall_slam.connect(_on_wall_slam)
	GameEvents.focus_started.connect(_on_focus_started)
	GameEvents.focus_ended.connect(_on_focus_ended)
	GameEvents.wall_struck.connect(_on_wall_struck)
	GameEvents.stumbled.connect(_on_stumbled)
	GameEvents.tripped.connect(_on_tripped)

## dB offset for an energy relative to a reference: +-6 dB per x4, clamped.
static func energy_db(energy: float, ref: float) -> float:
	if energy <= 0.0:
		return -3.0
	return clampf(4.3 * log(energy / ref) / log(4.0) * 1.4, -10.0, 4.0)

## Heavier hits sound slightly lower.
static func energy_pitch(energy: float, ref: float) -> float:
	if energy <= 0.0:
		return 1.0
	return clampf(1.0 - 0.06 * log(energy / ref) / log(2.0), 0.85, 1.12)

## Sound for a landed hit, or &"" when another event already covers it
## (grab -> grab_started, throw -> thrown + the body impact).
static func hit_sound_for(info: HitInfo) -> StringName:
	var m := String(info.move_id)
	match info.kind:
		&"bowl":
			return &"body_slam"
		&"grab", &"throw":
			return &""
		&"projectile":
			return &"thud"
		&"counter":
			return &"heavy_hit"
	var variant := strike_variant(m)
	if variant != &"":
		return variant
	if info.energy >= HEAVY_HIT_ENERGY:
		return &"heavy_hit"
	if (m.contains("power") or m.contains("heavy") or m.contains("charge")) \
			and info.energy >= HEAVY_MOVE_MIN_ENERGY:
		return &"heavy_hit"
	if m.contains("kick") or m.contains("sweep"):
		return &"kick"
	return &"punch"

static func _pos_of(n: Node3D) -> Vector3:
	if not is_instance_valid(n):
		return Vector3.ZERO
	if n.has_method(&"get_aim_point"):
		return n.call(&"get_aim_point")
	return n.global_position

## Upgrade 2 strike sounds by move id (cross, hook, uppercut, roundhouse,
## flying kick, stomp / hammer fist); &"" when the move has none.
static func strike_variant(m: String) -> StringName:
	if m.contains("uppercut"):
		return &"hit_uppercut"
	if m.contains("roundhouse"):
		return &"hit_roundhouse"
	if m.contains("flying"):
		return &"hit_flying_kick"
	if m.contains("stomp") or m.contains("hammer"):
		return &"hit_stomp"
	if m.contains("cross"):
		return &"hit_cross"
	if m.contains("hook") or m.contains("backfist"):
		return &"hit_hook"
	return &""

func _on_hit_landed(info: HitInfo) -> void:
	if info == null:
		return
	var id := hit_sound_for(info)
	if id == &"":
		return
	var e := maxf(info.energy, info.damage * 25.0)
	var ref: float = REF_ENERGY.get(id, 2000.0)
	var vol := energy_db(e, ref)
	if String(info.move_id).begins_with("jab"):
		vol -= 2.0
	var at := _hit_point(info)
	play(id, at, vol, energy_pitch(e, ref), info.attacker)
	if info.charge_level >= 2 and id != &"heavy_hit":
		play(&"heavy_hit", at, CHARGED_LAYER_DB + 2.0 * (info.charge_level - 2), 1.0, info.attacker)

func _on_hit_blocked(info: HitInfo) -> void:
	if info == null:
		return
	play(&"block", _hit_point(info), 0.0, 1.0)

## Contact point, or the victim's chest when the hit carries none.
static func _hit_point(info: HitInfo) -> Vector3:
	if info.hit_position != Vector3.ZERO or not is_instance_valid(info.victim):
		return info.hit_position
	return _pos_of(info.victim)

func _on_perfect_dodge(defender: Node3D, _attacker: Node3D) -> void:
	play(&"dodge", _pos_of(defender), 0.0, 1.0, defender)

func _on_teleport_counter(defender: Node3D, _target: Node3D) -> void:
	play(&"teleport", _pos_of(defender), 0.0, 1.0, defender)

func _on_pursuit(attacker: Node3D, _victim: Node3D) -> void:
	play(&"teleport", _pos_of(attacker), -3.0, 1.1, attacker)

func _on_attack_tell(attacker: Node3D, kind: StringName, _duration: float) -> void:
	play(&"tell_grab" if kind == &"grab" else &"tell_strike", _pos_of(attacker))

func _on_attack_active(attacker: Node3D, move_id: StringName) -> void:
	var m := String(move_id)
	var pitch := 1.0
	var vol := 0.0
	if m.contains("kick") or m.contains("sweep"):
		pitch = 0.85
	elif m.contains("heavy") or m.contains("power") or m.contains("charge"):
		pitch = 0.75
		vol = 2.0
	elif m.begins_with("jab"):
		pitch = 1.2
		vol = -3.0
	elif m.contains("grab"):
		return
	if m.contains("uppercut") or m.contains("roundhouse") or m.contains("flying"):
		pitch = 0.8
		vol = 1.0
	if is_instance_valid(attacker) and clock_ms() - int(_last_release.get(attacker.get_instance_id(), -100000)) \
			< RELEASE_WHOOSH_GAP_MS:
		return  # the charged release already whooshed
	play(&"whoosh", _pos_of(attacker), vol, pitch, attacker)

func _on_wall_cracked(wall: Node3D, position: Vector3, energy: float) -> void:
	# Scripted cracks (enemy entry telegraph) carry 0 J: play them at a firm level.
	var e := energy if energy > 0.0 else REF_ENERGY[&"crack"]
	# A strike's own crack layer replaces this one (same frame, same wall).
	_crack_sound_deferred.call_deferred(wall.get_instance_id() if is_instance_valid(wall) else 0,
			position, e, Engine.get_process_frames())

func _crack_sound_deferred(wall_id: int, position: Vector3, energy: float, frame: int) -> void:
	if wall_id != 0 and int(_struck_frame.get(wall_id, -1)) == frame:
		return
	play(&"crack", position, energy_db(energy, REF_ENERGY[&"crack"]), energy_pitch(energy, 3000.0))

func _on_wall_broken(wall: Node3D, position: Vector3, energy: float, _velocity: Vector3) -> void:
	# A strike that opens a hole emits wall_broken and wall_struck in the same
	# frame; the strike handler layers the break sound itself, so wait for the
	# end of the frame and skip if a strike on this wall arrived.
	_break_sound_deferred.call_deferred(wall.get_instance_id() if is_instance_valid(wall) else 0,
			break_sound_for(wall), position, energy, Engine.get_process_frames())

func _break_sound_deferred(wall_id: int, id: StringName, position: Vector3, energy: float, frame: int) -> void:
	if wall_id != 0 and int(_struck_frame.get(wall_id, -1)) == frame:
		return
	var ref: float = REF_ENERGY.get(id, 6000.0)
	play(id, position, energy_db(energy, ref), energy_pitch(energy, ref))

## A punch or kick on a wall: per-surface strike sound, volume and pitch by
## power, rapid repeats varied and softened; cracks, holes and breaks layer
## the crack / break sounds. The attacker (the player) keeps Focus pitch.
func _on_wall_struck(attacker: Node3D, wall: Node3D, position: Vector3, _normal: Vector3, power: float,
		result: StringName, surface: StringName) -> void:
	if is_instance_valid(wall):
		_struck_frame[wall.get_instance_id()] = Engine.get_process_frames()
	var now := clock_ms()
	var last := int(_strike_last.get(surface, -100000))
	if now - last < STRIKE_GAP_MS and result != &"hole" and result != &"break":
		return
	var streak: int = int(_strike_streak.get(surface, 0)) + 1 if now - last < STRIKE_STREAK_MS else 0
	_strike_streak[surface] = streak
	_strike_last[surface] = now
	var p := maxf(power, 1.0)
	var vol := clampf(4.2 * log(p / STRIKE_REF_POWER) / log(2.0), STRIKE_MIN_DB, 5.0)
	vol += maxf(-STRIKE_STREAK_DB * streak, STRIKE_STREAK_MIN_DB)
	var pitch := clampf(1.08 - 0.07 * log(p / STRIKE_REF_POWER) / log(2.0), 0.82, 1.2)
	pitch *= 1.0 + _rng.randf_range(-STRIKE_PITCH_JITTER, STRIKE_PITCH_JITTER)
	pitch *= 1.0 + 0.03 * ((streak % 3) - 1)
	var id: StringName = STRIKE_BY_SURFACE.get(surface, &"strike_concrete")
	if result == &"hold":
		play(&"strike_hold", position, vol, pitch, attacker)
		if surface == &"concrete":
			_last_ms.erase(&"strike_concrete")
			play(&"strike_concrete", position, vol - 9.0, pitch * 1.1, attacker)
		return
	_last_ms.erase(id)  # the per-surface gap above is the throttle for strikes
	play(id, position, vol, pitch, attacker)
	match result:
		&"crack":
			play(&"crack", position, vol + STRIKE_CRACK_DB, pitch * 1.1, attacker)
		&"hole", &"break":
			var b: StringName = BREAK_BY_SURFACE.get(surface, &"wall_break")
			var extra := STRIKE_HOLE_DB if result == &"hole" else 0.0
			play(b, position, vol + extra, pitch, attacker)

## Break sound for a Destructible by its `surface` (duck-typed).
static func break_sound_for(wall: Object) -> StringName:
	if is_instance_valid(wall):
		var surf = wall.get(&"surface")
		if surf != null:
			return BREAK_BY_SURFACE.get(StringName(surf), &"wall_break")
	return &"wall_break"

## A chunk landing: pitch by size and material, volume by speed; throttled so
## a collapsing wall patters instead of machine-gunning.
func _on_debris_landed(body: Node3D, position: Vector3, speed: float, surface: StringName) -> void:
	if speed < DEBRIS_MIN_SPEED:
		return
	var now := clock_ms()
	_debris_tokens = minf(DEBRIS_BURST, _debris_tokens + (now - _debris_ms) * 0.001 * DEBRIS_RATE)
	_debris_ms = now
	if _debris_tokens < 1.0:
		return
	var key := body.get_instance_id() if is_instance_valid(body) else 0
	if key != 0 and now - int(_debris_last.get(key, -100000)) < int(DEBRIS_BODY_GAP * 1000.0):
		return
	var mass := 1.0
	if body is RigidBody3D:
		mass = maxf((body as RigidBody3D).mass, 0.05)
	_debris_tokens -= 1.0
	if key != 0:
		if _debris_last.size() > 256:
			_debris_last.clear()
		_debris_last[key] = now
	var e := 0.5 * mass * speed * speed
	var pitch := clampf(1.3 - 0.22 * log(mass + 0.3) / log(2.0), 0.6, 1.5) \
			* clampf(0.94 + speed * 0.01, 0.94, 1.06) * float(DEBRIS_PITCH_BY_SURFACE.get(surface, 1.0))
	# Bypass the per-id retrigger guard: the bucket above is the throttle.
	_last_ms.erase(&"debris")
	play(&"debris", position, clampf(energy_db(e, DEBRIS_REF_ENERGY), -12.0, 3.0), pitch)

## Mistimed dodge: a soft tick, higher when early, lower when late.
func _on_dodge_feedback(defender: Node3D, result: StringName) -> void:
	play_ui(&"miss", 0.0, 1.12 if result == &"early" else 0.88, is_player_source(defender))

func _on_body_impact(_fighter: Node3D, position: Vector3, _normal: Vector3, energy: float,
		_surface: StringName) -> void:
	var id := &"body_slam" if energy >= SLAM_ENERGY else &"thud"
	var ref: float = REF_ENERGY[id]
	play(id, position, energy_db(energy, ref), energy_pitch(energy, ref))

func _on_grab_started(grabber: Node3D, victim: Node3D) -> void:
	play(&"grab", _pos_of(victim), 0.0, 1.0, grabber)

func _on_grab_broken(grabber: Node3D, _victim: Node3D, reversal: bool) -> void:
	play(&"break_grab", _pos_of(grabber), 2.0 if reversal else 0.0, 0.9 if reversal else 1.0)

func _on_thrown(_grabber: Node3D, victim: Node3D, velocity: Vector3) -> void:
	play(&"throw", _pos_of(victim), 0.0, clampf(velocity.length() / 12.0, 0.8, 1.2))

## KO sting for the player's death; a body thud for anyone else. The last
## enemy of a wave is announced by wave_cleared (or round_over for the final
## wave and the duel), which GameMode emits only when nothing is left to spawn.
func _on_fighter_died(fighter: Node3D, _info: HitInfo) -> void:
	if not is_instance_valid(fighter):
		return
	if fighter.is_in_group(&"player"):
		play_ui(&"ko")
	else:
		play(&"thud", _pos_of(fighter), -2.0, 0.9)

func _on_wave_cleared(_index: int) -> void:
	play_ui(&"ko")

func _on_round_over(_player_won: bool) -> void:
	play_ui(&"ko")

func _on_wave_started(_index: int, _total: int) -> void:
	play_ui(&"wave_start")


# --- Upgrade 2: charge, movement, arm break, wall slam, Focus --------------------

func _on_charge_started(fighter: Node3D, _move_id: StringName) -> void:
	if not is_instance_valid(fighter) or _quitting:
		return
	var slot := _hum_slot(fighter)
	if slot < 0:
		slot = _free_hum_slot()
	var stream := _pick_loop(&"charge_hum")
	if stream == null:
		return
	var h := _hum_players[slot]
	_hum_fighter[slot] = fighter
	_hum_level[slot] = 0
	_hum_time[slot] = 0.0
	_hum_db[slot] = HUM_DB[0] - 8.0  # fades in
	h.stream = stream
	h.global_position = _pos_of(fighter)
	h.volume_db = BASE_DB[&"charge_hum"] + _hum_db[slot]
	h.pitch_scale = HUM_PITCH[0] * (player_pitch_factor() if is_player_source(fighter) else 1.0)
	h.play()
	_used = true
	sound_played.emit(&"charge_hum", h.global_position)

func _on_charge_level_changed(fighter: Node3D, level: int) -> void:
	if not is_instance_valid(fighter):
		return
	var slot := _hum_slot(fighter)
	if slot >= 0:
		_hum_level[slot] = clampi(level, 0, HUM_PITCH.size() - 1)
	if level > 0:
		play(&"charge_level", _pos_of(fighter), -2.0 + 2.0 * level, 1.0 + 0.25 * (level - 1), fighter)

func _on_charge_released(fighter: Node3D, _move_id: StringName, level: int) -> void:
	if not is_instance_valid(fighter):
		return
	var slot := _hum_slot(fighter)
	if slot >= 0:
		_stop_hum(slot)
	if level > 0:
		play(&"charge_release", _pos_of(fighter), -4.0 + 2.5 * level, 1.15 - 0.1 * level, fighter)
		_last_release[fighter.get_instance_id()] = clock_ms()

## Hums currently playing (tests, debug).
func active_hums() -> int:
	var n := 0
	for f in _hum_fighter:
		if f != null:
			n += 1
	return n

## Pitch of the hum for `fighter` (tests): 0 when it has none.
func hum_pitch(fighter: Node3D) -> float:
	var slot := _hum_slot(fighter)
	return _hum_players[slot].pitch_scale if slot >= 0 else 0.0

func _hum_slot(fighter: Node3D) -> int:
	for i in _hum_fighter.size():
		if _hum_fighter[i] != null and _hum_fighter[i] == fighter:
			return i
	return -1

func _free_hum_slot() -> int:
	var oldest := 0
	for i in _hum_fighter.size():
		if _hum_fighter[i] == null:
			return i
		if _hum_time[i] > _hum_time[oldest]:
			oldest = i
	_stop_hum(oldest)
	return oldest

func _stop_hum(slot: int) -> void:
	_hum_players[slot].stop()
	_hum_fighter[slot] = null

func _update_hums(delta: float, pitch_factor: float) -> void:
	for i in _hum_fighter.size():
		var f = _hum_fighter[i]
		if f == null:
			continue
		if not is_instance_valid(f) or not (f as Node3D).is_inside_tree():
			_stop_hum(i)
			continue
		_hum_time[i] += delta
		if _hum_time[i] > HUM_MAX_TIME:
			_stop_hum(i)
			continue
		var lvl := _hum_level[i]
		_hum_db[i] = move_toward(_hum_db[i], HUM_DB[lvl], HUM_SLEW * delta)
		var h := _hum_players[i]
		h.global_position = _pos_of(f)
		h.volume_db = BASE_DB[&"charge_hum"] + _hum_db[i]
		var wobble := 1.0 + 0.01 * sin(_hum_time[i] * TAU * (3.0 + lvl))
		h.pitch_scale = HUM_PITCH[lvl] * wobble * (pitch_factor if is_player_source(f) else 1.0)

## A looping stream ignores the retrigger guard (one per charging fighter).
func _pick_loop(id: StringName) -> AudioStreamWAV:
	_mutex.lock()
	var list: Array = _streams.get(id, [])
	var stream: AudioStreamWAV = list[_rng.randi_range(0, list.size() - 1)] if not list.is_empty() else null
	_mutex.unlock()
	return stream

func _on_jumped(fighter: Node3D) -> void:
	if is_instance_valid(fighter):
		play(&"jump", _feet_of(fighter), 0.0, 1.0, fighter)

func _on_landed(fighter: Node3D) -> void:
	if is_instance_valid(fighter):
		play(&"land", _feet_of(fighter), 0.0, 1.0, fighter)

func _on_crouch_changed(fighter: Node3D, crouching: bool) -> void:
	if is_instance_valid(fighter):
		play(&"crouch", _feet_of(fighter) + Vector3.UP * 0.5, 0.0 if crouching else -5.0,
				1.0 if crouching else 1.15, fighter)

func _on_stumbled(fighter: Node3D, _duration: float) -> void:
	if is_instance_valid(fighter):
		play(&"land", _feet_of(fighter), -3.0, 1.2)

func _on_tripped(fighter: Node3D) -> void:
	if is_instance_valid(fighter):
		play(&"thud", _feet_of(fighter), -1.0, 1.05)

func _on_arm_broken(fighter: Node3D, zone: int) -> void:
	if not is_instance_valid(fighter):
		return
	var at := _pos_of(fighter)
	var rig = fighter.get(&"rig")
	if rig is Node3D and (rig as Node3D).has_method(&"get_bone_global_position"):
		at = rig.call(&"get_bone_global_position", BodyZones.AIM_BONE.get(zone, Bones.R_LOWER_ARM))
	play(&"arm_break", at)

func _on_wall_slam(grabber: Node3D, victim: Node3D, _wall: Node3D) -> void:
	var at := _pos_of(victim) if is_instance_valid(victim) else _pos_of(grabber)
	play(&"wall_slam", at, 0.0, 1.0, grabber)

func _on_focus_started(fighter: Node3D) -> void:
	play_ui(&"focus_in", 0.0, 1.0, is_player_source(fighter))

func _on_focus_ended(fighter: Node3D) -> void:
	play_ui(&"focus_out", 0.0, 1.0, is_player_source(fighter))

static func _feet_of(f: Node3D) -> Vector3:
	if f.has_method(&"get_ground_position"):
		return f.call(&"get_ground_position")
	return f.global_position


# --- Generation --------------------------------------------------------------

func _generate_all() -> void:
	var most := VARIANTS
	for id in VARIANTS_BY_ID:
		most = maxi(most, int(VARIANTS_BY_ID[id]))
	for v in most:
		for id in IDS:
			if _abort:
				return
			if v >= int(VARIANTS_BY_ID.get(id, VARIANTS)):
				continue
			var wav := generate(id, v)
			_mutex.lock()
			(_streams[id] as Array).append(wav)
			if v == 0:
				_ready_count += 1
			_mutex.unlock()
	_complete = true

func _to_wav(buf: PackedFloat32Array, loop := false) -> AudioStreamWAV:
	var n := buf.size()
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	for i in n:
		bytes.encode_s16(i * 2, int(clampf(buf[i], -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIX_RATE
	wav.stereo = false
	wav.data = bytes
	if loop:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = n
	return wav


## Minimal additive/subtractive synth over a float buffer.
class _Synth:
	const SR := 44100.0
	var buf := PackedFloat32Array()
	var _seed: int

	func _init(seed_value: int) -> void:
		_seed = absi(seed_value) % 2147483647
		if _seed == 0:
			_seed = 12345

	## Uniform 0..1 (LCG; no RandomNumberGenerator calls in sample loops).
	func rand() -> float:
		_seed = (_seed * 1103515245 + 12345) & 0x7fffffff
		return float(_seed) / 2147483647.0

	func rr(a: float, b: float) -> float:
		return a + (b - a) * rand()

	func noise() -> float:
		_seed = (_seed * 1103515245 + 12345) & 0x7fffffff
		return float(_seed) / 1073741823.5 - 1.0

	func ensure(seconds: float) -> void:
		var n := int(seconds * SR)
		if buf.size() < n:
			buf.resize(n)

	## Sine/triangle/saw tone with an exponential pitch sweep f0 -> f1 (time
	## constant sweep_tau), linear attack, exponential decay (decay_tau).
	## wave: 0 sine, 1 triangle, 2 saw (naive), 3 square-ish (tanh of sine).
	func tone(start: float, dur: float, f0: float, f1: float, sweep_tau: float, amp: float,
			attack: float, decay_tau: float, wave := 0, vib_hz := 0.0, vib_depth := 0.0) -> void:
		ensure(start + dur)
		var i0 := int(start * SR)
		var n := int(dur * SR)
		var phase := rand()
		var att := maxf(attack, 0.0005)
		var att_n := int(att * SR)
		var fade_n := mini(int(0.006 * SR), n)
		# Exponential sweep and decay as per-sample multipliers (no exp() per sample).
		var sweep := 1.0
		var sweep_k := exp(-1.0 / (SR * maxf(sweep_tau, 0.0001)))
		var decay := 1.0
		var decay_k := exp(-1.0 / (SR * decay_tau))
		var df := f0 - f1
		var vib_w := TAU * vib_hz / SR
		for k in n:
			var f := f1 + df * sweep
			sweep *= sweep_k
			if vib_depth > 0.0:
				f *= 1.0 + vib_depth * sin(vib_w * k)
			phase += f / SR
			phase -= floorf(phase)
			var v: float
			if wave == 0:
				v = sin(TAU * phase)
			elif wave == 1:
				v = 4.0 * absf(phase - 0.5) - 1.0
			elif wave == 2:
				v = 2.0 * phase - 1.0
			else:
				v = tanh(3.0 * sin(TAU * phase))
			var env: float
			if k < att_n:
				env = float(k) / att_n
			else:
				env = decay
				decay *= decay_k
			if k > n - fade_n:
				env *= float(n - k) / fade_n
			buf[i0 + k] += v * env * amp

	## Filtered noise: one-pole low-pass sweeping lp0 -> lp1 Hz (linear over dur),
	## optional one-pole high-pass at hp Hz, attack + exponential decay.
	func noise_burst(start: float, dur: float, amp: float, lp0: float, lp1: float, hp: float,
			attack: float, decay_tau: float) -> void:
		ensure(start + dur)
		var i0 := int(start * SR)
		var n := int(dur * SR)
		var lp := 0.0
		var lp2 := 0.0
		var hp_state := 0.0
		var a_hp := 1.0 - exp(-TAU * maxf(hp, 1.0) / SR)
		var att := maxf(attack, 0.0005)
		var att_n := int(att * SR)
		var fade_n := mini(int(0.006 * SR), n)
		var decay := 1.0
		var decay_k := exp(-1.0 / (SR * decay_tau))
		var a := 0.0
		var gain := 0.0
		for k in n:
			# The cutoff sweep is slow: refresh its coefficient every 32 samples.
			if k % 32 == 0:
				var fc := lerpf(lp0, lp1, float(k) / n)
				a = 1.0 - exp(-TAU * fc / SR)
				# Two cascaded one-poles leave about 0.29 * sqrt(a) of the noise RMS;
				# compensate so low and high cutoffs come out at similar loudness.
				gain = amp / sqrt(a)
			lp += a * (noise() - lp)
			lp2 += a * (lp - lp2)
			var v := lp2
			if hp > 0.0:
				hp_state += a_hp * (v - hp_state)
				v -= hp_state
			var env: float
			if k < att_n:
				env = float(k) / att_n
			else:
				env = decay
				decay *= decay_k
			if k > n - fade_n:
				env *= float(n - k) / fade_n
			buf[i0 + k] += v * env * gain

	## Band-limited noise whose amplitude swells then falls (whooshes).
	## Band centre sweeps c0 -> c_peak -> c1, envelope peaks at peak_frac of dur.
	func swoosh(start: float, dur: float, amp: float, c0: float, c_peak: float, c1: float,
			peak_frac: float) -> void:
		ensure(start + dur)
		var i0 := int(start * SR)
		var n := int(dur * SR)
		var lp := 0.0
		var lp2 := 0.0
		var hp_state := 0.0
		var a := 0.0
		var a_hp := 0.0
		var gain := 0.0
		var env := 0.0
		for k in n:
			# Envelope and band move slowly: refresh them every 32 samples.
			if k % 32 == 0:
				var x := float(k) / n
				var fc: float
				if x < peak_frac:
					var u := x / peak_frac
					env = u * u
					fc = lerpf(c0, c_peak, u)
				else:
					var u := (x - peak_frac) / (1.0 - peak_frac)
					env = pow(1.0 - u, 1.6)
					fc = lerpf(c_peak, c1, u)
				a = 1.0 - exp(-TAU * fc * 1.6 / SR)
				a_hp = 1.0 - exp(-TAU * fc * 0.6 / SR)
				gain = env * amp * 1.6 / sqrt(a)
			lp += a * (noise() - lp)
			lp2 += a * (lp - lp2)
			hp_state += a_hp * (lp2 - hp_state)
			buf[i0 + k] += (lp2 - hp_state) * gain

	## Sparse random clicks (crackle / debris), density falls off with tau.
	func crackle(start: float, dur: float, amp: float, rate: float, tau: float, lp_hz: float) -> void:
		ensure(start + dur + 0.02)
		var i0 := int(start * SR)
		var n := int(dur * SR)
		var a := 1.0 - exp(-TAU * lp_hz / SR)
		var k := 0
		while k < n:
			var t := k / SR
			var density := rate * exp(-t / tau)
			if density < 1.0:
				break
			# Next click after an exponential gap.
			k += int(-log(maxf(rand(), 0.0001)) / density * SR) + 1
			if k >= n:
				break
			var click_amp := amp * rr(0.3, 1.0) * exp(-t / (tau * 1.5))
			var click_len := int(rr(0.002, 0.008) * SR)
			var lp := 0.0
			var polarity := 1.0 if rand() > 0.5 else -1.0
			for j in click_len:
				var idx := i0 + k + j
				if idx >= buf.size():
					break
				lp += a * (noise() - lp)
				buf[idx] += (lp * 2.5 + polarity * 0.3 * exp(-j / 30.0)) * click_amp \
						* (1.0 - float(j) / click_len)

	## Modal ring: inharmonic partials with their own decays (clangs, bells).
	func modal(start: float, dur: float, f: float, ratios: Array, amps: Array, taus: Array, amp: float) -> void:
		for i in ratios.size():
			tone(start, dur, f * ratios[i], f * ratios[i], 1.0, amp * amps[i], 0.0008, taus[i])

	## Scattered low knocks with falling level (tumbling chunks, debris).
	func knocks(start: float, dur: float, count: int, f_lo: float, f_hi: float, amp: float,
			tau: float) -> void:
		for i in count:
			var u := float(i) / maxf(count - 1, 1)
			var t := start + dur * pow(u, 1.4) * rr(0.85, 1.1)
			var f := rr(f_lo, f_hi)
			var a := amp * rr(0.6, 1.0) * (1.0 - 0.6 * u)
			tone(t, tau * 5.0, f * 1.3, f, 0.012, a, 0.0006, tau * rr(0.8, 1.2))
			noise_burst(t, 0.05, a * 0.5, rr(1800.0, 2800.0), 1000.0, 250.0, 0.0004, 0.012)

	## Soft saturation for weight.
	func drive(amount: float) -> void:
		var norm := tanh(amount)
		for i in buf.size():
			buf[i] = tanh(buf[i] * amount) / norm

	## One-pole low-pass over the whole buffer.
	func lowpass(hz: float) -> void:
		var a := 1.0 - exp(-TAU * hz / SR)
		var y := 0.0
		for i in buf.size():
			y += a * (buf[i] - y)
			buf[i] = y

	func normalize(peak: float) -> void:
		var m := 0.0
		for v in buf:
			m = maxf(m, absf(v))
		if m < 0.000001:
			return
		var g := peak / m
		for i in buf.size():
			buf[i] *= g


# --- Sound designs -----------------------------------------------------------

## Tight low thud + skin slap.
func _make_punch(s: _Synth) -> void:
	var f := s.rr(120.0, 150.0)
	s.tone(0.0, 0.22, f, f * 0.4, 0.03, 1.0, 0.001, s.rr(0.055, 0.075))
	s.noise_burst(0.0, 0.08, 0.75, s.rr(4500.0, 6000.0), 1500.0, 700.0, 0.0005, s.rr(0.012, 0.02))
	s.noise_burst(0.0, 0.12, 0.35, 900.0, 300.0, 0.0, 0.001, 0.035)
	s.drive(1.6)

## Deeper thud.
func _make_kick(s: _Synth) -> void:
	var f := s.rr(95.0, 115.0)
	s.tone(0.0, 0.32, f, f * 0.38, 0.04, 1.0, 0.001, s.rr(0.09, 0.12))
	s.tone(0.0, 0.2, f * 2.1, f * 0.9, 0.02, 0.25, 0.001, 0.04)
	s.noise_burst(0.0, 0.09, 0.55, s.rr(3000.0, 4000.0), 900.0, 400.0, 0.0005, 0.022)
	s.noise_burst(0.0, 0.18, 0.4, 700.0, 200.0, 0.0, 0.002, 0.05)
	s.drive(1.8)

## Boomy, crunchy big hit.
func _make_heavy_hit(s: _Synth) -> void:
	var f := s.rr(80.0, 95.0)
	s.tone(0.0, 0.62, f, f * 0.36, 0.06, 1.0, 0.001, s.rr(0.14, 0.18))
	s.tone(0.0, 0.3, f * 1.5, f * 0.6, 0.03, 0.35, 0.001, 0.07)
	s.noise_burst(0.0, 0.1, 0.8, 6500.0, 2000.0, 900.0, 0.0004, 0.018)
	s.noise_burst(0.0, 0.4, 0.6, 1400.0, 250.0, 0.0, 0.002, 0.09)
	s.crackle(0.005, 0.08, 0.35, 900.0, 0.03, 3500.0)
	s.drive(1.9)

## Dull clack (forearm guard).
func _make_block(s: _Synth) -> void:
	var f := s.rr(280.0, 340.0)
	s.tone(0.0, 0.16, f, f * 0.85, 0.02, 0.7, 0.0005, 0.035)
	s.tone(0.0, 0.12, f * 2.3, f * 2.1, 0.02, 0.3, 0.0005, 0.02)
	s.noise_burst(0.0, 0.07, 0.8, 1800.0, 700.0, 350.0, 0.0003, 0.014)
	s.tone(0.0, 0.18, 110.0, 70.0, 0.03, 0.4, 0.001, 0.04)
	s.drive(1.4)

## Filtered noise sweep (swings, throws).
func _make_whoosh(s: _Synth, dur: float, c_lo: float, c_hi: float, amp: float) -> void:
	var d := dur * s.rr(0.9, 1.1)
	s.swoosh(0.0, d, amp, c_lo, c_hi * s.rr(0.85, 1.15), c_lo * 0.8, s.rr(0.25, 0.35))

## Airy whoosh + shimmer.
func _make_dodge(s: _Synth) -> void:
	s.swoosh(0.0, 0.42, 0.9, 900.0, 4200.0, 1500.0, 0.18)
	var base := s.rr(1900.0, 2300.0)
	var ratios := [1.0, 1.5, 2.01, 2.52]
	for i in ratios.size():
		s.tone(0.05 + i * 0.025, 0.42, base * ratios[i], base * ratios[i] * 1.06, 0.3, 0.12, 0.01, 0.12,
				0, 9.0, 0.01)

## Electric zap.
func _make_teleport(s: _Synth) -> void:
	s.tone(0.0, 0.18, s.rr(1800.0, 2200.0), 160.0, 0.035, 0.45, 0.001, 0.07, 2)
	s.tone(0.0, 0.14, 900.0, 90.0, 0.03, 0.3, 0.001, 0.05, 3)
	s.crackle(0.0, 0.25, 0.4, 1500.0, 0.06, 6000.0)
	s.tone(0.1, 0.32, 320.0, 2400.0, 0.12, 0.25, 0.02, 0.09)
	s.noise_burst(0.0, 0.2, 0.3, 8000.0, 3000.0, 2500.0, 0.001, 0.05)

## Cloth grab: grainy rustle + soft thump.
func _make_grab(s: _Synth) -> void:
	s.crackle(0.0, 0.18, 0.5, 1800.0, 0.06, 2600.0)
	s.noise_burst(0.0, 0.16, 0.45, 2800.0, 1400.0, 900.0, 0.004, 0.04)
	s.tone(0.0, 0.14, 120.0, 80.0, 0.03, 0.45, 0.002, 0.04)

## Metallic clang (grab break).
func _make_break_grab(s: _Synth) -> void:
	var f := s.rr(480.0, 560.0)
	s.modal(0.0, 0.6, f, [1.0, 2.76, 5.4, 8.93], [1.0, 0.6, 0.35, 0.2], [0.22, 0.14, 0.08, 0.05], 0.55)
	s.noise_burst(0.0, 0.04, 0.6, 7000.0, 3000.0, 1500.0, 0.0003, 0.008)
	s.tone(0.0, 0.2, 160.0, 90.0, 0.03, 0.5, 0.001, 0.05)
	s.drive(1.3)

## Meaty crack (wall cracks): a sharp snap over a heavy thump and crumble.
func _make_crack(s: _Synth) -> void:
	s.noise_burst(0.0, 0.05, 0.9, 6500.0, 2500.0, 1200.0, 0.0003, 0.009)
	s.tone(0.0, 0.42, s.rr(88.0, 100.0), 42.0, 0.05, 1.0, 0.0015, 0.11)
	s.noise_burst(0.0, 0.28, 0.55, 1300.0, 350.0, 0.0, 0.002, 0.06)
	s.crackle(0.0, 0.5, 0.75, 650.0, 0.13, 4200.0)
	s.knocks(0.06, 0.35, 3, 150.0, 240.0, 0.25, 0.03)
	s.drive(1.8)

## Crash + low rumble (wall breaks).
func _make_wall_break(s: _Synth) -> void:
	s.noise_burst(0.0, 0.9, 0.9, 4500.0, 900.0, 200.0, 0.001, 0.22)
	s.crackle(0.0, 1.1, 0.7, 500.0, 0.35, 3800.0)
	s.crackle(0.15, 0.9, 0.5, 120.0, 0.4, 1800.0)
	s.noise_burst(0.0, 1.35, 0.9, 160.0, 80.0, 0.0, 0.01, 0.5)
	s.tone(0.0, 1.2, 62.0, 38.0, 0.25, 0.8, 0.004, 0.4)
	s.tone(0.0, 0.35, 120.0, 50.0, 0.05, 0.5, 0.001, 0.08)
	s.drive(1.8)

## Body hits a surface.
func _make_thud(s: _Synth) -> void:
	var f := s.rr(75.0, 90.0)
	s.tone(0.0, 0.34, f, f * 0.55, 0.05, 1.0, 0.0015, s.rr(0.08, 0.1))
	s.noise_burst(0.0, 0.14, 0.55, 900.0, 300.0, 0.0, 0.001, 0.04)
	s.noise_burst(0.0, 0.05, 0.25, 3000.0, 1500.0, 500.0, 0.0005, 0.012)
	s.drive(1.5)

## Hard body slam.
func _make_body_slam(s: _Synth) -> void:
	var f := s.rr(65.0, 78.0)
	s.tone(0.0, 0.6, f, f * 0.45, 0.07, 1.0, 0.0015, s.rr(0.13, 0.16))
	s.noise_burst(0.0, 0.3, 0.7, 1200.0, 250.0, 0.0, 0.001, 0.08)
	s.noise_burst(0.0, 0.07, 0.5, 4000.0, 1800.0, 600.0, 0.0004, 0.016)
	s.crackle(0.0, 0.2, 0.25, 700.0, 0.06, 2500.0)
	s.drive(1.8)

## Bright high ping (white glint: block this).
func _make_tell_strike(s: _Synth) -> void:
	var f := s.rr(2500.0, 2700.0)
	s.tone(0.0, 0.48, f, f * 1.02, 0.1, 0.8, 0.002, 0.13)
	s.tone(0.0, 0.4, f * 2.0, f * 2.0, 1.0, 0.25, 0.002, 0.07)
	s.tone(0.035, 0.42, f * 1.335, f * 1.335, 1.0, 0.45, 0.002, 0.12)
	s.noise_burst(0.0, 0.02, 0.15, 9000.0, 6000.0, 4000.0, 0.0002, 0.004)

## Low warning buzz (red glint: grab this).
func _make_tell_grab(s: _Synth) -> void:
	var f := s.rr(105.0, 115.0)
	s.tone(0.0, 0.5, f, f, 1.0, 0.5, 0.03, 0.35, 2, 18.0, 0.015)
	s.tone(0.0, 0.5, f * 1.06, f * 1.06, 1.0, 0.4, 0.03, 0.35, 2)
	s.tone(0.0, 0.5, f * 0.5, f * 0.5, 1.0, 0.5, 0.03, 0.35, 3)
	s.lowpass(900.0)
	s.drive(1.6)

## Boom + ring (final KO sting).
func _make_ko(s: _Synth) -> void:
	s.tone(0.0, 1.0, 85.0, 30.0, 0.12, 1.0, 0.002, 0.42)
	s.noise_burst(0.0, 0.6, 0.7, 900.0, 120.0, 0.0, 0.002, 0.2)
	s.noise_burst(0.0, 0.08, 0.5, 6000.0, 2000.0, 800.0, 0.0004, 0.02)
	var f := s.rr(640.0, 700.0)
	s.modal(0.02, 1.7, f, [1.0, 2.0, 2.98, 4.18], [0.5, 0.25, 0.14, 0.08], [0.75, 0.5, 0.32, 0.2], 0.6)
	s.drive(1.7)

## Horn-like swell (wave start).
func _make_wave_start(s: _Synth) -> void:
	s.ensure(1.4)
	var root := 146.83  # D3
	var notes := [root, root * 1.5, root * 2.0]
	for f in notes:
		for h in range(1, 9):
			var a := 0.35 / float(h) * (1.0 if h < 5 else 0.6)
			s.tone(0.0, 1.35, f * h, f * h, 1.0, a, 0.32, 0.9, 0, 5.0, 0.004)
	s.lowpass(2200.0)
	# Release fade over the last 0.35 s so the swell ends cleanly.
	var n := s.buf.size()
	var rel := int(0.35 * _Synth.SR)
	for k in rel:
		s.buf[n - rel + k] *= 1.0 - float(k) / rel
	s.drive(1.3)

## UI click.
func _make_ui(s: _Synth) -> void:
	s.tone(0.0, 0.06, 1900.0, 1500.0, 0.01, 0.8, 0.0003, 0.012)
	s.noise_burst(0.0, 0.01, 0.5, 8000.0, 5000.0, 2000.0, 0.0002, 0.002)

## Soft "miss" tick (mistimed dodge): two quick falling ticks.
func _make_miss(s: _Synth) -> void:
	s.tone(0.0, 0.09, 1300.0, 900.0, 0.02, 0.6, 0.002, 0.02)
	s.tone(0.035, 0.1, 950.0, 650.0, 0.02, 0.4, 0.002, 0.025)
	s.noise_burst(0.0, 0.03, 0.25, 6000.0, 3000.0, 1500.0, 0.0005, 0.005)

## Metallic thud (armor absorbs a hit).
func _make_clank(s: _Synth) -> void:
	s.tone(0.0, 0.26, 140.0, 85.0, 0.03, 0.8, 0.001, 0.05)
	var f := s.rr(320.0, 380.0)
	s.modal(0.0, 0.5, f, [1.0, 2.32, 4.25, 6.63, 8.9], [0.8, 0.6, 0.45, 0.3, 0.2],
			[0.14, 0.1, 0.07, 0.05, 0.035], 0.5)
	s.noise_burst(0.0, 0.03, 0.7, 7000.0, 3500.0, 1500.0, 0.0002, 0.006)
	s.drive(1.6)

## A chunk hits the floor: short knock plus grit.
func _make_debris(s: _Synth) -> void:
	var f := s.rr(110.0, 160.0)
	s.tone(0.0, 0.2, f * 1.4, f, 0.015, 1.0, 0.0006, s.rr(0.035, 0.05))
	s.noise_burst(0.0, 0.08, 0.7, s.rr(2500.0, 3500.0), 1000.0, 250.0, 0.0004, 0.018)
	s.crackle(0.005, 0.15, 0.35, 500.0, 0.04, 3500.0)
	s.drive(1.4)

## Drywall: dry crunch, crumble, then plaster patter and a dust hiss.
func _make_break_drywall(s: _Synth) -> void:
	s.noise_burst(0.0, 0.35, 0.9, 3800.0, 1500.0, 600.0, 0.001, 0.07)
	s.crackle(0.0, 0.3, 0.8, 1400.0, 0.08, 4200.0)
	s.tone(0.0, 0.25, 110.0, 65.0, 0.04, 0.55, 0.002, 0.06)
	s.crackle(0.12, 0.95, 0.35, 90.0, 0.5, 2600.0)
	s.noise_burst(0.05, 0.9, 0.18, 1800.0, 900.0, 300.0, 0.05, 0.3)
	s.drive(1.4)

## Brick: heavy masonry crash, low boom and rumble, bricks tumbling after.
func _make_break_brick(s: _Synth) -> void:
	s.tone(0.0, 0.9, 70.0, 38.0, 0.12, 1.0, 0.002, 0.3)
	s.noise_burst(0.0, 0.6, 0.9, 2600.0, 600.0, 120.0, 0.001, 0.16)
	s.crackle(0.0, 0.45, 0.7, 700.0, 0.12, 3000.0)
	s.knocks(0.1, 1.15, 9, 95.0, 190.0, 0.55, 0.05)
	s.noise_burst(0.0, 1.4, 0.6, 140.0, 70.0, 0.0, 0.01, 0.45)
	s.drive(1.9)

## Wood: sharp splinter crack over a hollow knock, a few pieces after.
func _make_break_wood(s: _Synth) -> void:
	s.noise_burst(0.0, 0.05, 1.0, 9000.0, 4000.0, 2000.0, 0.0002, 0.008)
	s.crackle(0.0, 0.5, 0.75, 1600.0, 0.1, 5500.0)
	s.modal(0.0, 0.45, s.rr(200.0, 240.0), [1.0, 2.43, 3.95, 5.6], [1.0, 0.5, 0.3, 0.15],
			[0.09, 0.06, 0.04, 0.03], 0.6)
	s.tone(0.0, 0.3, 120.0, 70.0, 0.04, 0.5, 0.001, 0.07)
	s.knocks(0.12, 0.6, 4, 160.0, 260.0, 0.3, 0.04)
	s.drive(1.5)


# --- Upgrade 2 sound designs -------------------------------------------------------

## Seamless 0.5 s loop: every partial completes whole cycles in the loop (base
## a multiple of 2 Hz), with a 6 Hz tremolo (3 cycles) and a beating partial.
func _make_charge_hum(s: _Synth) -> void:
	var bases := [104.0, 110.0, 116.0]
	var f0: float = bases[int(s.rr(0.0, 2.999))]
	var n := int(0.5 * _Synth.SR)
	s.buf.resize(n)
	for k in n:
		var t := k / _Synth.SR
		var v := sin(TAU * f0 * t) * 0.5 + sin(TAU * 2.0 * f0 * t) * 0.28 \
				+ sin(TAU * 3.0 * f0 * t) * 0.14 + sin(TAU * (f0 + 4.0) * t) * 0.3 \
				+ sin(TAU * 5.0 * f0 * t) * 0.05
		s.buf[k] = tanh(1.6 * v * (0.85 + 0.15 * sin(TAU * 6.0 * t)))

## Bright rising "shing" when a charge reaches the next level.
func _make_charge_level(s: _Synth) -> void:
	var f := s.rr(880.0, 960.0)
	s.tone(0.0, 0.3, f, f * 1.5, 0.05, 0.7, 0.002, 0.09)
	s.tone(0.0, 0.3, f * 2.0, f * 3.0, 0.05, 0.3, 0.002, 0.06)
	s.noise_burst(0.0, 0.12, 0.25, 9000.0, 6000.0, 4000.0, 0.001, 0.03)

## Charged release: an air pop and a fast rising whoosh.
func _make_charge_release(s: _Synth) -> void:
	s.swoosh(0.0, 0.32, 1.0, 700.0, 4200.0, 900.0, 0.18)
	s.tone(0.0, 0.2, 140.0, 60.0, 0.03, 0.6, 0.001, 0.05)
	s.noise_burst(0.0, 0.04, 0.4, 5000.0, 2500.0, 900.0, 0.0005, 0.01)

## Jump: a cloth swish and a soft push-off.
func _make_jump(s: _Synth) -> void:
	s.swoosh(0.0, 0.2, 0.7, 700.0, 2600.0, 900.0, 0.3)
	s.tone(0.0, 0.12, 95.0, 70.0, 0.03, 0.45, 0.002, 0.03)
	s.noise_burst(0.0, 0.05, 0.3, 2500.0, 1200.0, 400.0, 0.001, 0.012)

## Land: a soft body thud and a shoe scuff.
func _make_land(s: _Synth) -> void:
	s.tone(0.0, 0.2, 85.0, 55.0, 0.03, 1.0, 0.001, 0.05)
	s.noise_burst(0.0, 0.12, 0.6, 1800.0, 700.0, 250.0, 0.001, 0.035)
	s.crackle(0.01, 0.12, 0.25, 500.0, 0.04, 3000.0)
	s.drive(1.3)

## Crouch: a short cloth shuffle.
func _make_crouch(s: _Synth) -> void:
	s.crackle(0.0, 0.18, 0.5, 1200.0, 0.07, 2800.0)
	s.noise_burst(0.0, 0.18, 0.4, 2400.0, 1200.0, 800.0, 0.01, 0.05)
	s.tone(0.02, 0.1, 110.0, 85.0, 0.03, 0.2, 0.003, 0.03)

## Cross: a crisp straight punch, more snap than thud.
func _make_hit_cross(s: _Synth) -> void:
	var f := s.rr(150.0, 175.0)
	s.tone(0.0, 0.2, f, f * 0.42, 0.025, 0.85, 0.0008, 0.05)
	s.noise_burst(0.0, 0.07, 1.0, s.rr(6500.0, 7500.0), 2000.0, 900.0, 0.0003, 0.014)
	s.noise_burst(0.0, 0.1, 0.3, 1100.0, 400.0, 0.0, 0.001, 0.03)
	s.drive(1.7)

## Hook: a meatier swinging punch, longer body.
func _make_hit_hook(s: _Synth) -> void:
	var f := s.rr(110.0, 130.0)
	s.tone(0.0, 0.3, f, f * 0.4, 0.04, 1.0, 0.001, 0.085)
	s.noise_burst(0.0, 0.18, 0.6, 1300.0, 350.0, 0.0, 0.001, 0.05)
	s.noise_burst(0.0, 0.07, 0.7, 4500.0, 1800.0, 700.0, 0.0004, 0.018)
	s.drive(1.9)

## Uppercut: a heavy thud with a rising "whump" and a crunch.
func _make_hit_uppercut(s: _Synth) -> void:
	var f := s.rr(95.0, 110.0)
	s.tone(0.0, 0.4, f, f * 0.42, 0.05, 1.0, 0.001, 0.12)
	s.tone(0.02, 0.25, f * 0.8, f * 1.7, 0.06, 0.35, 0.004, 0.07)
	s.noise_burst(0.0, 0.07, 0.75, 5000.0, 2000.0, 800.0, 0.0004, 0.016)
	s.crackle(0.005, 0.12, 0.35, 900.0, 0.04, 3500.0)
	s.drive(2.0)

## Roundhouse: a loud slapping thwack over a low thud.
func _make_hit_roundhouse(s: _Synth) -> void:
	var f := s.rr(88.0, 100.0)
	s.noise_burst(0.0, 0.09, 1.0, s.rr(5500.0, 6500.0), 2200.0, 700.0, 0.0003, 0.03)
	s.tone(0.0, 0.42, f, f * 0.42, 0.05, 1.0, 0.001, 0.13)
	s.noise_burst(0.0, 0.25, 0.5, 1400.0, 300.0, 0.0, 0.001, 0.07)
	s.drive(2.0)

## Flying kick: the biggest boom of the strikes.
func _make_hit_flying_kick(s: _Synth) -> void:
	var f := s.rr(78.0, 90.0)
	s.tone(0.0, 0.6, f, f * 0.38, 0.06, 1.0, 0.001, 0.2)
	s.noise_burst(0.0, 0.09, 0.85, 6000.0, 2000.0, 800.0, 0.0003, 0.02)
	s.noise_burst(0.0, 0.35, 0.6, 1500.0, 250.0, 0.0, 0.001, 0.1)
	s.crackle(0.004, 0.1, 0.3, 900.0, 0.03, 3500.0)
	s.drive(2.2)

## Stomp / hammer fist: a deep thud into the ground with grit.
func _make_hit_stomp(s: _Synth) -> void:
	var f := s.rr(58.0, 66.0)
	s.tone(0.0, 0.5, f, f * 0.5, 0.06, 1.0, 0.001, 0.18)
	s.noise_burst(0.0, 0.3, 0.7, 600.0, 200.0, 0.0, 0.001, 0.12)
	s.crackle(0.0, 0.2, 0.45, 800.0, 0.06, 2800.0)
	s.noise_burst(0.0, 0.05, 0.4, 3500.0, 1500.0, 500.0, 0.0004, 0.012)
	s.drive(2.0)

## Arm break: a sharp bone snap, a short grind and a muffled thud.
func _make_arm_break(s: _Synth) -> void:
	s.noise_burst(0.0, 0.03, 1.0, 9500.0, 5000.0, 2500.0, 0.0002, 0.006)
	s.tone(0.0, 0.05, 1900.0, 900.0, 0.01, 0.5, 0.0002, 0.008)
	s.crackle(0.004, 0.16, 0.7, 1800.0, 0.05, 4000.0)
	s.tone(0.0, 0.25, 120.0, 70.0, 0.03, 0.6, 0.001, 0.06)
	s.drive(1.6)

## Wall slam: a head driven into a wall, body slam plus a surface crunch.
func _make_wall_slam(s: _Synth) -> void:
	var f := s.rr(62.0, 72.0)
	s.tone(0.0, 0.7, f, f * 0.45, 0.07, 1.0, 0.001, 0.22)
	s.noise_burst(0.0, 0.45, 0.85, 2600.0, 600.0, 150.0, 0.001, 0.13)
	s.crackle(0.0, 0.35, 0.6, 800.0, 0.1, 3200.0)
	s.knocks(0.08, 0.5, 3, 120.0, 220.0, 0.3, 0.04)
	s.drive(2.0)

## Focus in: the world sinks, a falling whoosh into a low swell.
func _make_focus_in(s: _Synth) -> void:
	s.swoosh(0.0, 0.5, 0.9, 3200.0, 1400.0, 250.0, 0.2)
	s.tone(0.0, 0.6, 140.0, 55.0, 0.18, 0.7, 0.05, 0.3)
	s.tone(0.0, 0.5, 880.0, 440.0, 0.15, 0.12, 0.01, 0.15)

## Focus out: a quick rising whoosh back to speed.
func _make_focus_out(s: _Synth) -> void:
	s.swoosh(0.0, 0.3, 0.8, 300.0, 3000.0, 2000.0, 0.7)
	s.tone(0.05, 0.25, 220.0, 440.0, 0.1, 0.2, 0.02, 0.08)


# --- Round 3 wall strike designs ----------------------------------------------------

## Drywall: a crunchy thud with a crumble of gypsum.
func _make_strike_drywall(s: _Synth) -> void:
	var f := s.rr(95.0, 120.0)
	s.tone(0.0, 0.25, f, f * 0.55, 0.03, 0.85, 0.001, s.rr(0.05, 0.07))
	s.noise_burst(0.0, 0.18, 0.8, s.rr(3200.0, 4200.0), 1200.0, 500.0, 0.0005, s.rr(0.035, 0.05))
	s.crackle(0.004, 0.3, 0.55, s.rr(900.0, 1300.0), 0.08, 3600.0)
	s.crackle(0.06, 0.35, 0.2, 120.0, 0.2, 2400.0)
	s.drive(1.6)

## Brick: a hard, short knock with grit.
func _make_strike_brick(s: _Synth) -> void:
	var f := s.rr(170.0, 210.0)
	s.tone(0.0, 0.16, f, f * 0.7, 0.015, 0.9, 0.0005, s.rr(0.025, 0.035))
	s.tone(0.0, 0.2, f * 0.5, f * 0.35, 0.02, 0.6, 0.0008, 0.04)
	s.noise_burst(0.0, 0.06, 0.9, s.rr(5000.0, 6500.0), 2500.0, 1200.0, 0.0003, 0.012)
	s.crackle(0.002, 0.15, 0.45, s.rr(600.0, 900.0), 0.05, 4500.0)
	s.drive(1.9)

## Wood: a hollow thud and a small crack.
func _make_strike_wood(s: _Synth) -> void:
	var f := s.rr(180.0, 230.0)
	s.modal(0.0, 0.35, f, [1.0, 2.31, 3.7], [1.0, 0.45, 0.2], [s.rr(0.07, 0.09), 0.05, 0.03], 0.7)
	s.tone(0.0, 0.2, f * 0.5, f * 0.4, 0.03, 0.6, 0.001, 0.05)
	s.noise_burst(0.0, 0.03, 0.6, 8000.0, 4000.0, 2000.0, 0.0002, 0.006)
	s.crackle(0.01, 0.12, 0.3, 700.0, 0.04, 5000.0)
	s.drive(1.5)

## Concrete: a dull, heavy hit with chips skittering off.
func _make_strike_concrete(s: _Synth) -> void:
	var f := s.rr(70.0, 85.0)
	s.tone(0.0, 0.3, f, f * 0.6, 0.03, 1.0, 0.001, s.rr(0.06, 0.08))
	s.noise_burst(0.0, 0.12, 0.6, 1600.0, 500.0, 0.0, 0.001, 0.035)
	s.noise_burst(0.0, 0.04, 0.5, 4500.0, 2200.0, 1000.0, 0.0003, 0.008)
	s.knocks(0.02, 0.22, 3, 900.0, 1600.0, 0.25, 0.012)
	s.drive(1.8)

## Knuckles on a wall that holds: short, tight and satisfying.
func _make_strike_hold(s: _Synth) -> void:
	var f := s.rr(120.0, 150.0)
	s.tone(0.0, 0.14, f, f * 0.6, 0.015, 1.0, 0.0005, s.rr(0.03, 0.04))
	s.noise_burst(0.0, 0.05, 0.7, s.rr(3500.0, 4500.0), 1500.0, 600.0, 0.0003, 0.01)
	s.tone(0.0, 0.08, f * 3.1, f * 2.8, 0.01, 0.2, 0.0003, 0.012)
	s.drive(1.7)
