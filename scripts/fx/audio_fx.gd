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
##   hit_flying_kick, hit_stomp, arm_break, wall_slam
## Round 3: strike_drywall, strike_brick, strike_wood, strike_concrete,
##   strike_hold (wall_struck; 5 variants each so rapid jabs do not repeat)
## Round 6: snap_wood, glass_tinkle, break_cardboard, break_fabric, creak,
##   tile_pop, thump_low, step_/strike_ glass, cardboard, fabric.
## Round 5: impact_flinch .. impact_sever (one stream per hit tier, played on
##   hit_landed instead of the Upgrade 2 per-move hit_* sounds), boom (under wall
##   breaks), whoosh_charged, sidestep, step / step_water / step_metal,
##   land_hard, land_heavy, vault, wind (loop, follows the speed level), splash,
##   break_glass
## Round 7 (Freeflow combat): hit_crack, hit_smack, hit_thump (a player hit's
##   layers by HitInfo.weight), counter_hit (countered), rush (glide_started),
##   oof, whoosh_up, knee_floor, whip (react_started: fold, lift, buckle, spin),
##   drive_step (drive footsteps); dodged plays sidestep, counter_whiffed a soft
##   whoosh, a drive raises the wind loop. Parry, sidestep and Focus are gone,
##   and their sounds (parry, focus_in, focus_out) with them. The god path
##   (amendment) keeps the teleport, pursuit, jump, landings, parkour, wall run
##   and the ram, and adds step_crunch (a footstep crack at speed), the
##   pursuit spike's floor boom and the ram's level-3 launch.
## Round 8 (Charge and pressure): charge_tick (each step), charge_full,
##   charge_fizzle (charge_cancelled), hit_charged and hit_broken (hit
##   accents), guard_break (pressure_broken), pressure_tick, air_pop (air_hit),
##   dazed (loop while broken). The charge hum follows c; charge_release is the
##   release whoosh, by c.
## Round 9 (Playtest fixes): guard_crackle (the broken loop: a guard break no
##   longer dazes, so the loop is a quiet electric crackle on the guard; the
##   dazed loop plays instead when Tuning.R9_BROKEN_STUN), axe_crack (the axe
##   kick's heel crack, a hit layer, heavier when charged). A spike's floor
##   boom grows with its blast radius (a charged axe kick's is wider).
## Slow motion (Round 5, F0): AudioServer.playback_speed_scale is GLOBAL in
##   4.8: AudioStreamPlaybackResampled multiplies every playback's resample
##   step by it, whatever bus the player sends to, so a bus alone cannot keep
##   a sound at speed (tests/fx/test_audio_time measures this). TimeDirector
##   keeps it equal to Engine.time_scale. The player keeps real time in all
##   slow motion (except a KO), so the player's own sounds (impacts,
##   whooshes, footsteps, wind, landings) get pitch_scale x player_pitch_factor()
##   (= 1 / playback_speed_scale while the player is in real time) and play on
##   the "Player" bus; everything else plays on the "World" bus, which slows and
##   drops in pitch with the world and is muffled by a low-pass that follows
##   the slow-down. Callers pass the source fighter to play(..., source).
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
	&"hit_stomp", &"arm_break", &"wall_slam",
	&"strike_drywall", &"strike_brick", &"strike_wood", &"strike_concrete", &"strike_hold",
	# Round 5 (Feel Reference: Sound, Contact frame, Movement signals)
	&"impact_flinch", &"impact_stumble", &"impact_stagger", &"impact_knockdown", &"impact_launch",
	&"impact_hard_launch", &"impact_sever", &"boom", &"whoosh_charged", &"sidestep",
	&"step", &"step_water", &"step_metal", &"land_hard", &"land_heavy", &"vault", &"wind",
	&"splash", &"break_glass",
	# Round 6 (more destruction): materials and sizes
	&"snap_wood", &"glass_tinkle", &"break_cardboard", &"break_fabric", &"creak", &"tile_pop",
	&"thump_low", &"step_glass", &"step_cardboard", &"step_fabric", &"strike_glass",
	&"strike_cardboard", &"strike_fabric",
	# Round 7 (Freeflow combat): weight layers, counter, movement, reactions, drive
	&"hit_crack", &"hit_smack", &"hit_thump", &"counter_hit", &"rush", &"oof", &"whoosh_up",
	&"knee_floor", &"whip", &"drive_step",
	# Round 7 amendment (god path)
	&"step_crunch",
	# Round 8 (Charge and pressure)
	&"charge_tick", &"charge_full", &"charge_fizzle", &"hit_charged", &"hit_broken", &"guard_break",
	&"pressure_tick", &"air_pop", &"dazed",
	# Round 9 (Playtest fixes)
	&"guard_crackle", &"axe_crack",
]
## Round 6: a body hitting a clutter surface layers that surface's knock.
const SURFACE_IMPACT := {&"glass": &"strike_glass", &"cardboard": &"strike_cardboard", &"fabric": &"strike_fabric",
	&"wood": &"strike_wood"}
## Round 5: one impact stream per hit tier (Feel Reference: "impact sounds
## layered by tier: a slap for flinch, a thud for stagger and up, and a deep
## boom for launch and wall break"). Each is its own synthesised stream, so
## every tier is a different sound (F4 check).
const TIER_SOUND := {
	HitInfo.Tier.FLINCH: &"impact_flinch", HitInfo.Tier.STUMBLE: &"impact_stumble",
	HitInfo.Tier.STAGGER: &"impact_stagger", HitInfo.Tier.KNOCKDOWN: &"impact_knockdown",
	HitInfo.Tier.LAUNCH: &"impact_launch", HitInfo.Tier.HARD_LAUNCH: &"impact_hard_launch",
	HitInfo.Tier.SEVER: &"impact_sever",
}
## Footstep sound by floor surface (anything else: step).
const STEP_BY_SURFACE := {&"water": &"step_water", &"metal": &"step_metal", &"glass": &"step_glass",
	&"cardboard": &"step_cardboard", &"fabric": &"step_fabric"}
## wall_struck sound by surface.
const STRIKE_BY_SURFACE := {
	&"drywall": &"strike_drywall", &"brick": &"strike_brick", &"wood": &"strike_wood",
	&"concrete": &"strike_concrete",
	&"glass": &"strike_glass", &"cardboard": &"strike_cardboard", &"fabric": &"strike_fabric",
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
const LOOP_IDS: Array[StringName] = [&"charge_hum", &"wind", &"dazed", &"guard_crackle"]

## Charge hum: pitch and level (dB). Round 8: they follow the charge amount c
## continuously from the first entry (c = 0) to the last (c = 1); the middle
## entries are the Upgrade 2 levels (kept for reference). Players kept for it.
const HUM_PITCH: Array[float] = [1.0, 1.2, 1.45, 1.8]
const HUM_DB: Array[float] = [-9.0, -6.0, -3.5, -1.0]
const HUM_POOL := 4
## s: a hum with no release event stops anyway (Round 8: the longest legal
## charge, to full and the hold at full, plus a margin: ChargeFX.charge_glow_max()).
const HUM_MAX_TIME := 1.0 - Tuning.R8_TAP_MAX + Tuning.R8_CHARGE_HOLD_AT_FULL + 0.5
const HUM_SLEW := 12.0            ## dB per second toward the level's volume
## A charged release already whooshed: skip the attack_active whoosh this soon after (ms).
const RELEASE_WHOOSH_GAP_MS := 400

## Buses (Round 5, F0). Both send to Master; created at startup if missing.
const WORLD_BUS := &"World"
const PLAYER_BUS := &"Player"
## World low-pass during slow motion: cutoff = 20 kHz x speed^SLOW_LP_EXP, at
## least SLOW_LP_MIN (0.5x -> 6.6 kHz, 0.3x -> 2.9 kHz, 0.2x -> 1.5 kHz). The
## player's own sounds stay crisp on the Player bus, so they cut through.
const SLOW_LP_EXP := 1.6
const SLOW_LP_MIN := 1500.0
const SLOW_LP_OPEN := 20000.0
## Pitch compensation never goes past this (a 0.2x KO is not compensated anyway).
const PLAYER_PITCH_MAX := 6.0

## wall_broken sound by Destructible.surface (anything else: wall_break).
const BREAK_BY_SURFACE := {
	&"drywall": &"break_drywall", &"brick": &"break_brick", &"wood": &"break_wood",
	&"glass": &"break_glass", &"cardboard": &"break_cardboard", &"fabric": &"break_fabric",
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
	&"arm_break": 0.0, &"wall_slam": 0.0,
	&"strike_drywall": -2.0, &"strike_brick": -2.0, &"strike_wood": -2.0, &"strike_concrete": -2.0,
	&"strike_hold": -3.0,
	# Round 5: impacts climb in level with the tier (effect size follows the tier).
	&"impact_flinch": -5.0, &"impact_stumble": -4.0, &"impact_stagger": -2.5, &"impact_knockdown": -1.0,
	&"impact_launch": 0.0, &"impact_hard_launch": 1.0, &"impact_sever": 1.5, &"boom": -1.0,
	&"whoosh_charged": -6.0, &"sidestep": -6.0, &"step": -12.0, &"step_water": -9.0,
	&"step_metal": -10.0, &"land_hard": -3.0, &"land_heavy": 0.0, &"vault": -8.0, &"wind": -4.0,
	&"splash": -3.0, &"break_glass": -3.0,
	&"snap_wood": -4.0, &"glass_tinkle": -8.0, &"break_cardboard": -4.0, &"break_fabric": -3.0,
	&"creak": -3.0, &"tile_pop": -6.0, &"thump_low": -2.0, &"step_glass": -10.0, &"step_cardboard": -12.0,
	&"step_fabric": -13.0, &"strike_glass": -3.0, &"strike_cardboard": -4.0, &"strike_fabric": -4.0,
	# Round 7: the hit layers sit at the impacts' level; the thump carries the weight.
	&"hit_crack": -3.0, &"hit_smack": -3.0, &"hit_thump": -1.0, &"counter_hit": -1.0, &"rush": -6.0,
	&"oof": -4.0, &"whoosh_up": -6.0, &"knee_floor": -4.0, &"whip": -6.0, &"drive_step": -5.0,
	&"step_crunch": -7.0,
	# Round 8: the guard break is the loudest moment; ticks and the dazed loop stay under everything.
	&"charge_tick": -9.0, &"charge_full": -4.0, &"charge_fizzle": -6.0, &"hit_charged": -1.0, &"hit_broken": 0.0,
	&"guard_break": 1.5, &"pressure_tick": -11.0, &"air_pop": -3.0, &"dazed": -14.0,
	# Round 9: the crackle stays under everything like the dazed loop; the heel crack cuts through the hit.
	&"guard_crackle": -15.0, &"axe_crack": 0.0,
}

## Energy (J) at which a sound plays at its base level; louder above, quieter below.
const REF_ENERGY := {
	&"punch": 1500.0, &"kick": 2500.0, &"heavy_hit": 8000.0, &"thud": 1200.0,
	&"body_slam": 5000.0, &"crack": 3000.0, &"wall_break": 6000.0,
	&"break_drywall": 3000.0, &"break_brick": 8000.0, &"break_wood": 2000.0,
	&"hit_cross": 1500.0, &"hit_hook": 2000.0, &"hit_uppercut": 4000.0, &"hit_roundhouse": 4000.0,
	&"hit_flying_kick": 6000.0, &"hit_stomp": 3000.0, &"wall_slam": 2800.0,
}
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
var _hum_level := PackedInt32Array()       ## Upgrade 2 level (unused by Round 8's c-driven hum)
var _hum_start := PackedInt32Array()       ## clock ms of charge_started
var _hum_c := PackedFloat32Array()          ## c the hum follows now
var _hum_full: Array[bool] = []             ## charge_full reached
var _hum_seen: Array[bool] = []             ## the CombatController reported is_charging()
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
	_hum_start.resize(HUM_POOL)
	_hum_c.resize(HUM_POOL)
	_hum_full.resize(HUM_POOL)
	_hum_seen.resize(HUM_POOL)
	_hum_time.resize(HUM_POOL)
	_hum_db.resize(HUM_POOL)
	_task_id = WorkerThreadPool.add_task(_generate_all, false, "AudioFX synth")
	_ensure_limiter()
	_ensure_buses()
	for p in _players:
		p.bus = WORLD_BUS
	for u in _ui_players:
		u.bus = WORLD_BUS
	for h in _hum_players:
		h.bus = WORLD_BUS
	_build_round5()
	_connect_events()


## "World" and "Player" buses into Master; the World bus carries the slow-motion
## low-pass (disabled at normal speed).
func _ensure_buses() -> void:
	for bus_name: StringName in [WORLD_BUS, PLAYER_BUS]:
		if AudioServer.get_bus_index(bus_name) >= 0:
			continue
		AudioServer.add_bus()
		var i := AudioServer.bus_count - 1
		AudioServer.set_bus_name(i, bus_name)
		AudioServer.set_bus_send(i, &"Master")
	var w := AudioServer.get_bus_index(WORLD_BUS)
	_world_lp_index = -1
	for i in AudioServer.get_bus_effect_count(w):
		if AudioServer.get_bus_effect(w, i) is AudioEffectLowPassFilter:
			_world_lp_index = i
	if _world_lp_index < 0:
		var lp := AudioEffectLowPassFilter.new()
		lp.cutoff_hz = SLOW_LP_OPEN
		lp.resonance = 0.5
		AudioServer.add_bus_effect(w, lp)
		_world_lp_index = AudioServer.get_bus_effect_count(w) - 1
	AudioServer.set_bus_effect_enabled(w, _world_lp_index, false)

## Current world low-pass cutoff (Hz), or 0 when the filter is off (tests).
func get_world_lowpass() -> float:
	var w := AudioServer.get_bus_index(WORLD_BUS)
	if w < 0 or _world_lp_index < 0 or not AudioServer.is_bus_effect_enabled(w, _world_lp_index):
		return 0.0
	return (AudioServer.get_bus_effect(w, _world_lp_index) as AudioEffectLowPassFilter).cutoff_hz

func _update_world_lowpass() -> void:
	var w := AudioServer.get_bus_index(WORLD_BUS)
	if w < 0 or _world_lp_index < 0:
		return
	var a := AudioServer.playback_speed_scale
	var on := a < 0.99
	if AudioServer.is_bus_effect_enabled(w, _world_lp_index) != on:
		AudioServer.set_bus_effect_enabled(w, _world_lp_index, on)
	if on:
		var lp := AudioServer.get_bus_effect(w, _world_lp_index) as AudioEffectLowPassFilter
		lp.cutoff_hz = maxf(SLOW_LP_OPEN * pow(maxf(a, 0.01), SLOW_LP_EXP), SLOW_LP_MIN)


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
	for i in _daze_players.size():
		_daze_players[i].stop()
		_daze_players[i].stream = null
		_daze_fighter[i] = null
	if _wind != null:
		_wind.stop()
		_wind.stream = null
		_wind_level = 0.0
	_drives.clear()
	_drive_level = 0.0
	_owned_base.fill(0.0)
	_owned_base_ui.fill(0.0)


# --- Public API --------------------------------------------------------------

## `source`: the fighter making the sound, if any. The player's own sounds keep
## normal pitch in slow motion (see header).
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
	p.bus = PLAYER_BUS if _owned_base[i] > 0.0 else WORLD_BUS
	p.play()
	_used = true
	last_stream[id] = stream
	sound_played.emit(id, position)

## Non-positional (UI, slow-motion stings, player feedback). `player_owned`
## keeps it at normal pitch in slow motion.
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
	p.bus = PLAYER_BUS if player_owned else WORLD_BUS
	p.play()
	_used = true
	last_stream[id] = stream
	sound_played.emit(id, Vector3.ZERO)

static func is_player_source(source: Node) -> bool:
	return source != null and is_instance_valid(source) and source.is_in_group(&"player")

## Pitch multiplier that cancels the world slow-down for the player's sounds.
## playback_speed_scale (a) slows every playback; the player runs at
## player_time_factor() (pf) world seconds per world second, so the player's
## own sounds need pf x time_scale / a: 1 / a while the player keeps real time
## (pf = 1 / time_scale), 1 during a KO (pf = 1, the player slows too), and 1
## if nobody scales the audio (a = 1).
func player_pitch_factor() -> float:
	var td := get_node_or_null(^"/root/TimeDirector")
	var pf := 1.0
	if td != null and td.has_method(&"player_time_factor"):
		pf = float(td.call(&"player_time_factor"))
	var a := maxf(AudioServer.playback_speed_scale, 0.01)
	return clampf(pf * Engine.time_scale / a, 1.0 / PLAYER_PITCH_MAX, PLAYER_PITCH_MAX)

func _process(delta: float) -> void:
	_update_world_lowpass()
	_update_round5(delta)
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
	_update_dazed(delta)

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
		&"strike_drywall": _make_strike_drywall(s)
		&"strike_brick": _make_strike_brick(s)
		&"strike_wood": _make_strike_wood(s)
		&"strike_concrete": _make_strike_concrete(s)
		&"strike_hold": _make_strike_hold(s)
		&"impact_flinch": _make_impact(s, HitInfo.Tier.FLINCH)
		&"impact_stumble": _make_impact(s, HitInfo.Tier.STUMBLE)
		&"impact_stagger": _make_impact(s, HitInfo.Tier.STAGGER)
		&"impact_knockdown": _make_impact(s, HitInfo.Tier.KNOCKDOWN)
		&"impact_launch": _make_impact(s, HitInfo.Tier.LAUNCH)
		&"impact_hard_launch": _make_impact(s, HitInfo.Tier.HARD_LAUNCH)
		&"impact_sever": _make_impact(s, HitInfo.Tier.SEVER)
		&"boom": _make_boom(s)
		&"whoosh_charged": _make_whoosh_charged(s)
		&"sidestep": _make_sidestep(s)
		&"step": _make_step(s)
		&"step_water": _make_step_water(s)
		&"step_metal": _make_step_metal(s)
		&"land_hard": _make_land_hard(s)
		&"land_heavy": _make_land_heavy(s)
		&"vault": _make_vault(s)
		&"wind": _make_wind(s)
		&"splash": _make_splash(s)
		&"break_glass": _make_break_glass(s)
		&"snap_wood": _make_snap_wood(s)
		&"glass_tinkle": _make_glass_tinkle(s)
		&"break_cardboard": _make_break_cardboard(s)
		&"break_fabric": _make_break_fabric(s)
		&"creak": _make_creak(s)
		&"tile_pop": _make_tile_pop(s)
		&"thump_low": _make_thump_low(s)
		&"step_glass": _make_step_glass(s)
		&"step_cardboard": _make_step_cardboard(s)
		&"step_fabric": _make_step_fabric(s)
		&"strike_glass": _make_strike_glass(s)
		&"strike_cardboard": _make_strike_cardboard(s)
		&"strike_fabric": _make_strike_fabric(s)
		&"hit_crack": _make_hit_crack(s)
		&"hit_smack": _make_hit_smack(s)
		&"hit_thump": _make_hit_thump(s)
		&"counter_hit": _make_counter_hit(s)
		&"rush": _make_rush(s)
		&"oof": _make_oof(s)
		&"whoosh_up": _make_whoosh_up(s)
		&"knee_floor": _make_knee_floor(s)
		&"whip": _make_whip(s)
		&"drive_step": _make_drive_step(s)
		&"step_crunch": _make_step_crunch(s)
		&"charge_tick": _make_charge_tick(s)
		&"charge_full": _make_charge_full(s)
		&"charge_fizzle": _make_charge_fizzle(s)
		&"hit_charged": _make_hit_charged(s)
		&"hit_broken": _make_hit_broken(s)
		&"guard_break": _make_guard_break(s)
		&"pressure_tick": _make_pressure_tick(s)
		&"air_pop": _make_air_pop(s)
		&"dazed": _make_dazed(s)
		&"guard_crackle": _make_guard_crackle(s)
		&"axe_crack": _make_axe_crack(s)
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
	GameEvents.grab_started.connect(func(_g: Node3D, v: Node3D) -> void: _stop_hum_of(v))
	GameEvents.fighter_launched.connect(func(f: Node3D, _v: Vector3) -> void: _stop_hum_of(f))
	GameEvents.carry_changed.connect(func(_h: Node3D, held: Node3D) -> void: _stop_hum_of(held))
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

static func _pos_of(n: Node3D) -> Vector3:
	if not is_instance_valid(n):
		return Vector3.ZERO
	if n.has_method(&"get_aim_point"):
		return n.call(&"get_aim_point")
	return n.global_position

## Round 5 contact frame (F4): one impact stream per tier, on the same physics
## frame as hit_landed. Grabs are covered by grab_started. The attacker owns the
## sound, so the player's own impacts keep real-time pitch in slow motion.
func _on_hit_landed(info: HitInfo) -> void:
	if info == null:
		return
	_stop_hum_of(info.victim)  # a hit knocks the victim out of any charge
	if info.kind == &"grab" or FXRules.is_throw_release(info):
		return  # a throw's release whooshes on `thrown`
	if info.pressure > 0.0:
		_pressure_tick(info)  # Round 8
	if FXRules.is_round7(info):
		_r7_hit(info)  # Round 7: layers by weight instead of the tier's stream (Round 8 accents included)
		return
	for layer: Array in r8_accent_layers(info):  # Round 8 accents on a tier hit
		_play_fresh(layer[0], _hit_point(info), layer[1], layer[2], info.attacker)
	var id := tier_sound_for(info)
	if id == &"":
		return
	# Within a tier the level moves only a little with power (the tier is the size).
	var vol := clampf((info.power - _tier_floor(FXRules.tier_of(info))) * 0.6, 0.0, 2.0) if info.power > 0.0 else 0.0
	_last_ms.erase(id)  # two hits in one tick (a sweep on two legs) both land
	play(id, _hit_point(info), vol, 1.0, info.attacker)
	hit_sounds.append({"frame": Engine.get_physics_frames(), "tier": FXRules.tier_of(info), "id": id,
		"stream": last_stream.get(id)})
	if hit_sounds.size() > 64:
		hit_sounds.pop_front()

## The tier's impact sound id for a landed hit (&"" for grabs).
static func tier_sound_for(info: HitInfo) -> StringName:
	if info == null or info.kind == &"grab":
		return &""
	return TIER_SOUND.get(FXRules.tier_of(info), &"impact_flinch")

## Lower P bound of a tier (Tuning.TIER_BANDS), for the small in-tier level step.
static func _tier_floor(tier: int) -> float:
	var b := Tuning.TIER_BANDS
	match tier:
		HitInfo.Tier.STAGGER:
			return b[0]
		HitInfo.Tier.KNOCKDOWN:
			return b[1]
		HitInfo.Tier.LAUNCH:
			return b[2]
		HitInfo.Tier.HARD_LAUNCH:
			return b[3]
		HitInfo.Tier.SEVER:
			return b[4]
	return 0.0

func _on_hit_blocked(info: HitInfo) -> void:
	if info == null:
		return
	play(&"block", _hit_point(info), 0.0, 1.0)
	if info.pressure > 0.0:
		_pressure_tick(info)  # Round 8: blocked hits fill the meter too

## Contact point, or the victim's chest when the hit carries none.
static func _hit_point(info: HitInfo) -> Vector3:
	if info.hit_position != Vector3.ZERO or not is_instance_valid(info.victim):
		return info.hit_position
	return _pos_of(info.victim)

func _on_perfect_dodge(defender: Node3D, _attacker: Node3D) -> void:
	play(&"dodge", _pos_of(defender), 0.0, 1.0, defender)

## Tell sound by kind: an orange &"strike" tell (counter it) pings bright;
## every other kind (&"grab", Round 7's &"charge" for the heavy's shoulder
## charge, any later blue tell: dodge it) buzzes low, the same split as the
## HUD's and the glint's orange / blue.
func _on_teleport_counter(defender: Node3D, _target: Node3D) -> void:
	play(&"teleport", _pos_of(defender), 0.0, 1.0, defender)

func _on_pursuit(attacker: Node3D, _victim: Node3D) -> void:
	play(&"teleport", _pos_of(attacker), -3.0, 1.1, attacker)

func _on_attack_tell(attacker: Node3D, kind: StringName, _duration: float) -> void:
	play(tell_sound_for(kind), _pos_of(attacker))

## The tell sound id for an attack_tell kind.
static func tell_sound_for(kind: StringName) -> StringName:
	return &"tell_strike" if kind == &"strike" else &"tell_grab"

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
	if is_instance_valid(attacker) and clock_ms() - int(_strike_whoosh.get(attacker.get_instance_id(), -100000)) \
			< STRIKE_WHOOSH_COVER_MS:
		return  # Round 5: strike_started already whooshed this strike
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
	# Round 5: a deep boom under every wall break (Feel Reference: Sound).
	play(&"boom", position, clampf(energy_db(energy, 6000.0), -6.0, 2.0), energy_pitch(energy, 6000.0))

## A punch or kick on a wall: per-surface strike sound, volume and pitch by
## power, rapid repeats varied and softened; cracks, holes and breaks layer
## the crack / break sounds. The attacker (the player) keeps its pitch in slow motion.
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
		surface: StringName) -> void:
	var id := &"body_slam" if energy >= SLAM_ENERGY else &"thud"
	var ref: float = REF_ENERGY[id]
	play(id, position, energy_db(energy, ref), energy_pitch(energy, ref))
	if surface == &"water":  # Round 5 (F11): bodies in the water patch
		play(&"splash", position, energy_db(energy, 2500.0), energy_pitch(energy, 2500.0))
	elif SURFACE_IMPACT.has(surface):  # Round 6: a body against glass, cardboard, a sofa
		play(SURFACE_IMPACT[surface], position, energy_db(energy, 2500.0), energy_pitch(energy, 2500.0))

func _on_grab_started(grabber: Node3D, victim: Node3D) -> void:
	play(&"grab", _pos_of(victim), 0.0, 1.0, grabber)

func _on_grab_broken(grabber: Node3D, _victim: Node3D, reversal: bool) -> void:
	play(&"break_grab", _pos_of(grabber), 2.0 if reversal else 0.0, 0.9 if reversal else 1.0)

## A thrown body: a whoosh, louder and lower the faster it leaves (Round 7:
## Tuning.R7_THROW_SPEED_MIN .. MAX, a tap .. a full wind-up); a fast throw
## layers the long charged whoosh under it.
func _on_thrown(grabber: Node3D, victim: Node3D, velocity: Vector3) -> void:
	_throw_whoosh(&"thrown", _pos_of(victim), velocity.length(), grabber, 0.0)

## KO sting for the player's death; a body thud for anyone else. The last
## enemy of a wave is announced by wave_cleared (or round_over for the final
## wave and the duel), which GameMode emits only when nothing is left to spawn.
func _on_fighter_died(fighter: Node3D, _info: HitInfo) -> void:
	if not is_instance_valid(fighter):
		return
	_stop_hum_of(fighter)
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


# --- Upgrade 2: charge, movement, arm break, wall slam ---------------------------

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
	_hum_start[slot] = clock_ms()
	_hum_c[slot] = 0.0
	_hum_full[slot] = false
	_hum_seen[slot] = false
	_hum_db[slot] = HUM_DB[0] - 8.0  # fades in
	h.stream = stream
	h.global_position = _pos_of(fighter)
	h.volume_db = BASE_DB[&"charge_hum"] + _hum_db[slot]
	h.pitch_scale = HUM_PITCH[0] * (player_pitch_factor() if is_player_source(fighter) else 1.0)
	h.bus = PLAYER_BUS if is_player_source(fighter) else WORLD_BUS
	h.play()
	_used = true
	sound_played.emit(&"charge_hum", h.global_position)

## Round 8: each step of the move's meter (level = steps passed) ticks, a
## little higher and louder per step.
func _on_charge_level_changed(fighter: Node3D, level: int) -> void:
	if not is_instance_valid(fighter) or level <= 0:
		return
	var slot := _hum_slot(fighter)
	if slot >= 0:
		_hum_level[slot] = clampi(level, 0, HUM_PITCH.size() - 1)
	var db := R8_TICK_DB + R8_TICK_STEP_DB * (level - 1)
	var pitch := 1.0 + R8_TICK_PITCH_STEP * (level - 1)
	_play_fresh(&"charge_tick", _pos_of(fighter), db, pitch, fighter)
	_log_r8(&"charge_step", [&"charge_tick"], [db], [pitch])

## Round 8: the release whooshes on its own frame, louder, longer and deeper
## with c (the long charged whoosh layers under it from R8_RELEASE_HEAVY_FROM).
## It is the charged strike's swing: the strike_started whoosh that follows
## (after any glide) stands down, and so does attack_active's.
func _on_charge_released(fighter: Node3D, _move_id: StringName, _level: int) -> void:
	if not is_instance_valid(fighter):
		return
	var c := release_charge(fighter)
	var slot := _hum_slot(fighter)
	if slot >= 0:
		_stop_hum(slot)
	var ids: Array = [&"charge_release"]
	var db := lerpf(R8_RELEASE_DB.x, R8_RELEASE_DB.y, c)
	var pitch := lerpf(R8_RELEASE_PITCH.x, R8_RELEASE_PITCH.y, c)
	var dbs: Array = [db]
	var pitches: Array = [pitch]
	_play_fresh(&"charge_release", _pos_of(fighter), db, pitch, fighter)
	if c >= R8_RELEASE_HEAVY_FROM:
		var u := (c - R8_RELEASE_HEAVY_FROM) / (1.0 - R8_RELEASE_HEAVY_FROM)
		var hdb := lerpf(R8_RELEASE_HEAVY_DB.x, R8_RELEASE_HEAVY_DB.y, u)
		_play_fresh(&"whoosh_charged", _pos_of(fighter), hdb, lerpf(1.0, 0.86, u), fighter)
		ids.append(&"whoosh_charged")
		dbs.append(hdb)
		pitches.append(lerpf(1.0, 0.86, u))
	_last_release[fighter.get_instance_id()] = clock_ms()
	_release_pending[fighter.get_instance_id()] = clock_ms()
	_log_r8(&"charge_release", ids, dbs, pitches, c)

## c at a release: the hum's last c, or the CombatController's (B may clear it
## before or after it emits), 1 after charge_full.
func release_charge(fighter: Node3D) -> float:
	var slot := _hum_slot(fighter)
	var c := 0.0
	if slot >= 0:
		c = 1.0 if _hum_full[slot] else _hum_c[slot]
	var cc := FXRules.combat_of(fighter)
	if cc != null and cc.has_method(&"get_charge"):
		c = maxf(c, clampf(float(cc.call(&"get_charge")), 0.0, 1.0))
	return c

## Hums currently playing (tests, debug).
func active_hums() -> int:
	var n := 0
	for f in _hum_fighter:
		if f != null:
			n += 1
	return n

## The hum's base pitch at charge amount c (rising with c).
static func hum_pitch_for(c: float) -> float:
	return lerpf(HUM_PITCH[0], HUM_PITCH[HUM_PITCH.size() - 1], clampf(c, 0.0, 1.0))

## c the hum of `fighter` follows (tests): -1 when it has none.
func hum_charge(fighter: Node3D) -> float:
	var slot := _hum_slot(fighter)
	return _hum_c[slot] if slot >= 0 else -1.0

## Pitch of the hum for `fighter` (tests): 0 when it has none.
func hum_pitch(fighter: Node3D) -> float:
	var slot := _hum_slot(fighter)
	return _hum_players[slot].pitch_scale if slot >= 0 else 0.0

## Stop `fighter`'s charge hum, if any (interrupted charges).
func _stop_hum_of(fighter: Node3D) -> void:
	if not is_instance_valid(fighter):
		return
	var slot := _hum_slot(fighter)
	if slot >= 0:
		_stop_hum(slot)

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
		# Round 8: the hum follows c on the real clock (the player charges in real time).
		var t := (clock_ms() - _hum_start[i]) * 0.001
		var charging := FXRules.combat_flag(f, &"is_charging")
		if charging == 1:
			_hum_seen[i] = true
		# An interrupted charge (down, flying, dead or held, or the CombatController
		# no longer charging) stops its hum, like the glow.
		if t > maxf(HUM_MAX_TIME, R8ChargeFX.charge_glow_max()) or FXRules.cannot_charge(f) \
				or (charging == 0 and _hum_seen[i]):
			_stop_hum(i)
			continue
		var c := 1.0 if _hum_full[i] else maxf(_hum_c[i], FXRules.charge_amount(f, t))
		_hum_c[i] = c
		var goal := lerpf(HUM_DB[0], HUM_DB[HUM_DB.size() - 1], c) + (R8_HUM_FULL_DB if _hum_full[i] else 0.0)
		_hum_db[i] = move_toward(_hum_db[i], goal, HUM_SLEW * delta)
		var h := _hum_players[i]
		h.global_position = _pos_of(f)
		var throb := 0.0
		if _hum_full[i]:
			throb = R8_HUM_FULL_THROB_DB * (0.5 + 0.5 * sin(t * TAU * R8_HUM_FULL_THROB_HZ))
		h.volume_db = BASE_DB[&"charge_hum"] + _hum_db[i] - throb
		var wobble := 1.0 + lerpf(0.01, 0.025, c) * sin(_hum_time[i] * TAU * lerpf(3.0, 7.0, c))
		h.pitch_scale = hum_pitch_for(c) * wobble * (pitch_factor if is_player_source(f) else 1.0)

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
		_landed_deferred.call_deferred(fighter, Engine.get_physics_frames())

## Round 5: Traversal emits `landing` (with its level) and `landed` on the same
## tick; the level's own sound already played, so the plain one stands down.
func _landed_deferred(fighter: Node3D, frame: int) -> void:
	if not is_instance_valid(fighter):
		return
	if int(_landing_frame.get(fighter.get_instance_id(), -1)) >= frame:
		return
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
		# ceil + 1: start and length are cut with int() separately, so their
		# sum can land one sample past int(seconds * SR).
		var n := int(ceil(seconds * SR)) + 1
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

	## Voiced grunt (Round 7): a sawtooth glottal source whose pitch falls f_a ->
	## f_b, with jitter and breath noise, through parallel two-pole resonators
	## (formants) gliding from `from` to `to` Hz with bandwidths `bws` Hz and
	## gains `gains`. Attack, then an exponential decay.
	func voice(start: float, dur: float, f_a: float, f_b: float, from: Array, to: Array, bws: Array,
			gains: Array, amp: float, breath: float, attack: float, decay_tau: float) -> void:
		ensure(start + dur)
		var i0 := int(start * SR)
		var n := int(dur * SR)
		var nf := from.size()
		var y1 := PackedFloat32Array()
		var y2 := PackedFloat32Array()
		var c1 := PackedFloat32Array()
		var c2 := PackedFloat32Array()
		var g := PackedFloat32Array()
		y1.resize(nf)  # packed arrays are values: resize each one itself
		y2.resize(nf)
		c1.resize(nf)
		c2.resize(nf)
		g.resize(nf)
		var phase := 0.0
		var att_n := maxi(int(attack * SR), 1)
		var fade_n := mini(int(0.01 * SR), n)
		var decay := 1.0
		var decay_k := exp(-1.0 / (SR * decay_tau))
		var src_lp := 0.0
		for k in n:
			var u := float(k) / n
			# Formant coefficients move slowly: refresh them every 32 samples.
			if k % 32 == 0:
				for j in nf:
					var fc := lerpf(float(from[j]), float(to[j]), u)
					var r := exp(-PI * float(bws[j]) / SR)
					c1[j] = 2.0 * r * cos(TAU * fc / SR)
					c2[j] = -r * r
					g[j] = float(gains[j]) * (1.0 - r)
			var f0 := lerpf(f_a, f_b, u) * (1.0 + 0.015 * noise())
			phase += f0 / SR
			phase -= floorf(phase)
			# Saw softened by a one-pole (a glottal pulse is not a hard edge), plus breath.
			src_lp += 0.35 * ((1.0 - 2.0 * phase) - src_lp)
			var x := src_lp + breath * noise()
			var y := 0.0
			for j in nf:
				var v := g[j] * x + c1[j] * y1[j] + c2[j] * y2[j]
				y2[j] = y1[j]
				y1[j] = v
				y += v
			var env: float
			if k < att_n:
				env = float(k) / att_n
			else:
				env = decay
				decay *= decay_k
			if k > n - fade_n:
				env *= float(n - k) / fade_n
			buf[i0 + k] += y * env * amp

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


# =============================================================================
# Round 5: Feel Reference (docs/Feel Reference — Sifu × Prototype). Every
# handler listens to GameEvents; gameplay code never calls these.
# =============================================================================

## A strike_started whoosh covers the move's attack_active whoosh this long (ms).
const STRIKE_WHOOSH_COVER_MS := 600
## Footsteps: one fighter's steps at most this often (two feet in one tick).
const STEP_GAP_MS := 60
## Footstep level (dB) at walking .. full sprint; pitch drops a little with speed.
const STEP_DB := Vector2(-7.0, 1.0)
## Wind loop (Feel Reference: "a wind loop that rises in volume and pitch with
## sprint_charge"): dB at a whisper .. full speed, pitch at the bottom .. top.
## The level follows ScreenFX's speed level (sprint_charge, air dashes,
## pursuit teleports) with a fast attack and a slower release.
const WIND_DB := Vector2(-34.0, 0.0)
const WIND_PITCH := Vector2(0.78, 1.32)
const WIND_ATTACK := 3.0          ## level per real second up
const WIND_RELEASE := 1.6         ## ...and down
const WIND_CURVE := 1.4           ## level^this before the dB mapping (quiet until it builds)
const WIND_OFF := 0.015           ## under this level the loop stops
## Upgraded caps raise the wind's ceiling with ScreenFX's k (1 at 8 m/s, 1.5 at
## 12): +WIND_UPGRADE_DB dB and pitch x (1 + WIND_UPGRADE_PITCH) per unit of k - 1.
const WIND_UPGRADE_DB := 6.0
const WIND_UPGRADE_PITCH := 0.4
const PLAYER_POLL := 0.5          ## s between player lookups

## Every hit_landed impact played: {frame, tier, id, stream} (F4 check, newest last).
var hit_sounds: Array[Dictionary] = []
## Last stream played per id (tests).
var last_stream: Dictionary = {}
var _world_lp_index := -1
var _strike_whoosh: Dictionary = {}   ## fighter id -> clock ms of its last strike_started whoosh
var _step_last: Dictionary = {}       ## fighter id -> clock ms of its last footstep sound
var _landing_frame: Dictionary = {}   ## fighter id -> physics frame of its last `landing`
var _wind: AudioStreamPlayer
var _wind_level := 0.0
var _player: Node3D
var _player_poll := 0.0

func _build_round5() -> void:
	_wind = AudioStreamPlayer.new()
	_wind.name = "Wind"
	_wind.bus = PLAYER_BUS
	add_child(_wind)
	GameEvents.strike_started.connect(_on_strike_started)
	GameEvents.teleported.connect(_on_teleported)
	GameEvents.sprint_started.connect(_on_sprint_started)
	GameEvents.footstep.connect(_on_footstep)
	GameEvents.parkour.connect(_on_parkour)
	GameEvents.wall_run_step.connect(_on_wall_run_step)
	GameEvents.wall_run_ended.connect(_on_wall_run_ended)
	GameEvents.landing.connect(_on_landing)
	GameEvents.prop_broken.connect(_on_prop_broken)
	GameEvents.prop_thrown.connect(_on_prop_thrown)
	GameEvents.prop_picked_up.connect(_on_prop_picked_up)
	GameEvents.body_slammed.connect(_on_body_slammed)
	GameEvents.armor_absorbed.connect(_on_armor_absorbed)
	GameEvents.rammed.connect(_on_rammed)
	GameEvents.limb_severed.connect(_on_limb_severed)
	_connect_round6()
	_connect_round7()
	_connect_round8()

## Wind level 0..1 now (tests, debug).
func get_wind_level() -> float:
	return _wind_level

func _update_round5(delta: float) -> void:
	var real := delta / maxf(Engine.time_scale, 0.001)
	_player_poll -= real
	if _player_poll <= 0.0 or not is_instance_valid(_player):
		_player_poll = PLAYER_POLL
		_player = FXRules.player(get_tree())
	var goal := 0.0
	var k := 1.0
	var sfx := get_node_or_null(^"/root/ScreenFX")
	if sfx != null and sfx.has_method(&"get_speed_level"):
		goal = float(sfx.call(&"get_speed_level"))
		k = float(sfx.call(&"get_speed_scale")) if sfx.has_method(&"get_speed_scale") else 1.0
	elif is_instance_valid(_player):
		goal = FXRules.sprint_charge(_player)
	if is_instance_valid(_player) and _player.has_method(&"is_dead") and _player.call(&"is_dead"):
		goal = 0.0
	_update_drives(real, delta)
	goal = maxf(goal, _drive_level)  # Round 7: a drive raises the wind with its speed
	_wind_level = move_toward(_wind_level, goal, (WIND_ATTACK if goal > _wind_level else WIND_RELEASE) * real)
	if _quitting:
		return
	if _wind_level < WIND_OFF:
		if _wind.playing:
			_wind.stop()
		return
	if not _wind.playing:
		var stream := _pick_loop(&"wind")
		if stream == null:
			return
		_wind.stream = stream
		_wind.play()
		_used = true
		sound_played.emit(&"wind", Vector3.ZERO)
	var top_db := WIND_DB.y + WIND_UPGRADE_DB * (k - 1.0)
	var top_pitch := WIND_PITCH.y * (1.0 + WIND_UPGRADE_PITCH * (k - 1.0))
	_wind.volume_db = BASE_DB[&"wind"] + lerpf(WIND_DB.x, top_db, pow(_wind_level, WIND_CURVE))
	_wind.pitch_scale = lerpf(WIND_PITCH.x, top_pitch, _wind_level) * player_pitch_factor()

## Any strike's startup: a whoosh, longer and deeper for a charged one, a touch
## louder at a sprint. Pitch by the strike class (a jab is quick and light).
## Round 7 player moves (Tuning.R7_MOVES) swing by their weight instead
## (whatever charge level B reports for a heavy): a jab whips high and light;
## from R7_SWING_HEAVY_FROM the long, deep charged whoosh.
func _on_strike_started(attacker: Node3D, _target: Node3D, move_id: StringName, sprint: bool,
		charge_level: int) -> void:
	if not is_instance_valid(attacker):
		return
	# Round 8: a charged strike's swing whooshed at its release (charge_released).
	var rel := int(_release_pending.get(attacker.get_instance_id(), -100000))
	if clock_ms() - rel < R8_RELEASE_COVER_MS:
		_release_pending.erase(attacker.get_instance_id())
		_strike_whoosh[attacker.get_instance_id()] = clock_ms()
		return
	var r7: Dictionary = Tuning.R7_MOVES.get(move_id, {})
	if not r7.is_empty():
		var w := float(r7["weight"])
		var id := &"whoosh_charged" if w >= R7_SWING_HEAVY_FROM else &"whoosh"
		var db := lerpf(R7_SWING_DB.x, R7_SWING_DB.y, w)
		_last_ms.erase(id)
		play(id, _pos_of(attacker), db, lerpf(R7_SWING_PITCH.x, R7_SWING_PITCH.y, w), attacker)
		_strike_whoosh[attacker.get_instance_id()] = clock_ms()
		_log_r7(&"swing", [id], [db])
		return
	var cls := FXRules.strike_class(move_id)
	var pitch: float = {&"jab": 1.2, &"cross": 1.0, &"kick": 0.85, &"sweep": 0.9, &"knee": 1.05,
		&"elbow": 1.1, &"ground": 0.95}.get(cls, 1.0)
	var vol: float = {&"jab": -3.0, &"kick": 1.0}.get(cls, 0.0) + (1.5 if sprint else 0.0)
	_last_ms.erase(&"whoosh")
	_last_ms.erase(&"whoosh_charged")
	if charge_level > 0:
		play(&"whoosh_charged", _pos_of(attacker), vol + 1.5 * charge_level, pitch * (1.08 - 0.07 * charge_level),
				attacker)
	else:
		play(&"whoosh", _pos_of(attacker), vol, pitch, attacker)
	_strike_whoosh[attacker.get_instance_id()] = clock_ms()

## Sprint start: a firmer scuff as the feet dig in (the dust kick is BloodFX).
func _on_sprint_started(fighter: Node3D) -> void:
	if is_instance_valid(fighter):
		_last_ms.erase(&"step")
		play(&"step", _feet_of(fighter), 3.0, 0.85, fighter)

## Footsteps by surface, louder with sprint_charge (the player's own sound).
func _on_footstep(fighter: Node3D, position: Vector3, surface: StringName, sprint_charge: float) -> void:
	_step_frame = Engine.get_physics_frames()  # a footstep crack follows on this frame (God path)
	_step_pos = position
	_step_fighter = fighter if is_instance_valid(fighter) else null
	var key := fighter.get_instance_id() if is_instance_valid(fighter) else 0
	var now := clock_ms()
	if now - int(_step_last.get(key, -100000)) < STEP_GAP_MS:
		return
	_step_last[key] = now
	if _drives.has(key):  # Round 7: a driving holder's feet land as heavy thuds
		_drive_step(_drives[key], position)
		return
	var id: StringName = STEP_BY_SURFACE.get(surface, &"step")
	var c := clampf(sprint_charge, 0.0, 1.0)
	_last_ms.erase(id)
	play(id, position, lerpf(STEP_DB.x, STEP_DB.y, c), lerpf(1.04, 0.94, c), fighter)

func _on_teleported(fighter: Node3D, _from: Vector3, to: Vector3, kind: StringName) -> void:
	var pursuit := kind == &"pursuit"
	play(&"teleport", to, -3.0 if pursuit else 0.0, 1.1 if pursuit else 1.0, fighter)

func _on_parkour(fighter: Node3D, kind: StringName, position: Vector3, height: float) -> void:
	match kind:
		&"step":
			_last_ms.erase(&"step")
			play(&"step", position, -2.0, 1.1, fighter)
		&"vault", &"air_mantle":
			play(&"vault", position, 0.0, 1.0, fighter)
		&"mantle":
			play(&"vault", position, 1.0, 0.88, fighter)
			_last_ms.erase(&"step")
			play(&"step", position, 0.0, 0.9, fighter)
		&"kickoff":
			play(&"land", position, 0.0, 1.25, fighter)
			play(&"strike_hold", position, -6.0, 1.1, fighter)
	if height >= Tuning.MANTLE_MAX:  # a wall kick-off off something tall: the jump swish too
		play(&"jump", position, -2.0, 1.0, fighter)

## Wall-run footsteps: quick scuffs on the wall.
func _on_wall_run_step(fighter: Node3D, position: Vector3, _normal: Vector3) -> void:
	_last_ms.erase(&"step")
	play(&"step", position, -1.0, 1.12, fighter)

func _on_wall_run_ended(fighter: Node3D, reason: StringName) -> void:
	if reason == &"jump" and is_instance_valid(fighter):
		play(&"jump", _feet_of(fighter), 2.0, 0.95, fighter)

## Landings by level (Feel Reference: Landing has levels); water adds a splash.
func _on_landing(fighter: Node3D, level: StringName, position: Vector3, vertical_speed: float) -> void:
	if is_instance_valid(fighter):
		_landing_frame[fighter.get_instance_id()] = Engine.get_physics_frames()
	var surface := FXRules.floor_surface(get_viewport().world_3d if is_inside_tree() else null, position)
	match level:
		&"heavy":
			play(&"land_heavy", position, clampf((vertical_speed - Tuning.LAND_HEAVY_SPEED) * 0.4, 0.0, 3.0),
					1.0, fighter)
		&"hard":
			play(&"land_hard", position, 0.0, 1.0, fighter)
		_:
			play(&"land", position, clampf((vertical_speed - 5.0) * 0.8, -4.0, 2.0), 1.0, fighter)
	if surface == &"water":
		play(&"splash", position, -4.0 if level == &"soft" else 0.0, 1.0, fighter)
	elif surface == &"metal":
		play(&"step_metal", position, 2.0, 0.8, fighter)

## A thrown prop broke (Feel Reference: Props): glass for bottles, wood for
## chair legs, crates and sticks, masonry for bricks.
func _on_prop_broken(_prop: Node3D, position: Vector3, kind: StringName) -> void:
	match kind:
		&"bottle":
			play(&"break_glass", position)
		&"brick":
			play(&"break_brick", position, -6.0, 1.35)
		&"limb":
			play(&"thud", position, -4.0, 1.1)
		_:
			play(&"break_wood", position, -3.0, 1.2)

## A thrown prop: the throw whoosh by speed, a little lighter than a body.
func _on_prop_thrown(holder: Node3D, _prop: Node3D, velocity: Vector3) -> void:
	_throw_whoosh(&"prop_thrown", _pos_of(holder), velocity.length(), holder, R7_PROP_THROW_DB)

func _on_prop_picked_up(holder: Node3D, _prop: Node3D) -> void:
	play(&"grab", _pos_of(holder), -6.0, 1.15, holder)

## Body slam: the body's thud and a heavy landing's boom under it.
func _on_body_slammed(holder: Node3D, _victim: Node3D, position: Vector3) -> void:
	play(&"body_slam", position, 2.0, 0.9, holder)
	play(&"land_heavy", position, -1.0, 1.0, holder)

## A hit soaked by armor (the enemy kept attacking): a metal clank (B stopped playing it).
func _on_armor_absorbed(info: HitInfo) -> void:
	if info != null:
		play(&"clank", info.hit_position, 0.0, 1.0, info.attacker)

## Battering Ram (agent M): a body-on-body thud, heavier when someone goes down;
## the god path's level-3 launch (result &"launch") hits like a launch, with a
## boom under it.
func _on_rammed(runner: Node3D, victim: Node3D, result: StringName, self_result: StringName) -> void:
	if not is_instance_valid(runner) or not is_instance_valid(victim):
		return
	var at := (_pos_of(runner) + _pos_of(victim)) * 0.5
	if result == &"launch":
		_play_fresh(&"impact_launch", at, 0.0, 0.9, runner)
		_play_fresh(&"boom", at, R7_RAM_LAUNCH_BOOM_DB, 1.0, runner)
		_log_r7(&"ram_launch", [&"impact_launch", &"boom"], [0.0, R7_RAM_LAUNCH_BOOM_DB])
		return
	var down := result == &"knockdown" or self_result == &"knockdown"
	var id := &"impact_knockdown" if down else &"impact_stagger"
	play(id, at, 0.0, 0.85, runner)
	_log_r7(&"ram", [id], [0.0])

## A limb came off: a bone snap at the joint (the impact itself is impact_sever).
func _on_limb_severed(fighter: Node3D, cut: StringName, _piece: Node3D) -> void:
	if not is_instance_valid(fighter):
		return
	var at := _pos_of(fighter)
	var rig = fighter.get(&"rig")
	var bone: StringName = Bones.CUTS.get(cut, &"")
	if bone != &"" and rig is Node3D and (rig as Node3D).has_method(&"get_bone_global_position"):
		at = rig.call(&"get_bone_global_position", bone)
	play(&"arm_break", at, -2.0, 0.9)


# --- Round 5 sound designs ----------------------------------------------------------

## Impact by tier. Three layers whose amounts climb with the tier: a skin SLAP
## (bright noise crack + a short knock) on every tier, a body THUD from stagger
## up, and a deep BOOM with a rumble tail from launch up. A stumble adds a
## shoe scuff; a hard launch a sharp crack on top; a sever a bone crunch and a
## wet tear. Each tier is its own stream.
func _make_impact(s: _Synth, tier: int) -> void:
	var t := FXRules.tier_t(tier)
	# Slap: always there, sharper and shorter on small hits.
	var slap := lerpf(1.0, 0.55, t)
	s.noise_burst(0.0, 0.09, 0.95 * slap, s.rr(5200.0, 6800.0), 1800.0, 900.0, 0.0003, s.rr(0.011, 0.016))
	s.tone(0.0, 0.12, s.rr(190.0, 230.0), 110.0, 0.015, 0.45 * slap, 0.0006, 0.022)
	if tier == HitInfo.Tier.STUMBLE:
		s.noise_burst(0.02, 0.22, 0.45, 2200.0, 700.0, 250.0, 0.004, 0.05)  # shoe scuff
		s.tone(0.0, 0.2, 105.0, 62.0, 0.03, 0.55, 0.001, 0.045)
	if tier >= HitInfo.Tier.STAGGER:
		var thud := lerpf(0.7, 1.0, t)
		var f := s.rr(108.0, 122.0) * lerpf(1.1, 0.8, t)
		s.tone(0.0, 0.42, f, f * 0.4, 0.04, thud, 0.001, lerpf(0.07, 0.13, t))
		s.noise_burst(0.0, 0.25, 0.5 * thud, 1100.0, 300.0, 0.0, 0.001, lerpf(0.035, 0.07, t))
	if tier >= HitInfo.Tier.KNOCKDOWN:
		s.crackle(0.004, 0.12, lerpf(0.2, 0.45, t), 900.0, 0.04, 3500.0)
	if tier >= HitInfo.Tier.LAUNCH:
		var boom := lerpf(0.75, 1.15, (t - 0.6) / 0.4)
		var fb := s.rr(56.0, 64.0) * lerpf(1.05, 0.85, t)
		s.tone(0.0, 1.05, fb, fb * 0.5, 0.12, boom, 0.002, lerpf(0.24, 0.38, t))
		s.noise_burst(0.0, 0.9, 0.55 * boom, 220.0, 70.0, 0.0, 0.008, lerpf(0.22, 0.32, t))
	if tier >= HitInfo.Tier.HARD_LAUNCH:
		s.noise_burst(0.0, 0.04, 0.9, 9000.0, 4500.0, 2500.0, 0.0002, 0.007)  # crack on top
		s.tone(0.0, 0.3, 160.0, 70.0, 0.03, 0.4, 0.001, 0.06)
	if tier == HitInfo.Tier.SEVER:
		s.crackle(0.01, 0.28, 0.9, 1800.0, 0.07, 5200.0)  # bone crunch
		s.noise_burst(0.03, 0.4, 0.55, 1500.0, 500.0, 300.0, 0.01, 0.12)  # wet tear
		s.tone(0.02, 0.06, 1700.0, 800.0, 0.01, 0.35, 0.0002, 0.01)  # snap
	s.drive(lerpf(1.6, 2.3, t))

## Deep boom under wall breaks.
func _make_boom(s: _Synth) -> void:
	var f := s.rr(46.0, 54.0)
	s.tone(0.0, 1.3, f, f * 0.55, 0.15, 1.0, 0.003, 0.42)
	s.tone(0.0, 0.5, f * 2.0, f * 0.9, 0.06, 0.35, 0.002, 0.12)
	s.noise_burst(0.0, 1.2, 0.6, 180.0, 60.0, 0.0, 0.01, 0.4)
	s.noise_burst(0.0, 0.06, 0.3, 3000.0, 1200.0, 400.0, 0.0005, 0.015)
	s.drive(1.8)

## Charged strike: a longer, deeper swing with a low push under it.
func _make_whoosh_charged(s: _Synth) -> void:
	var d := 0.55 * s.rr(0.92, 1.08)
	s.swoosh(0.0, d, 1.0, 320.0, 2300.0 * s.rr(0.9, 1.1), 260.0, s.rr(0.38, 0.46))
	s.swoosh(0.04, d * 0.8, 0.45, 900.0, 4200.0, 700.0, 0.42)
	s.tone(0.05, d, 90.0, 55.0, 0.2, 0.3, 0.06, 0.18)

## Sidestep: a quick airy swish (Round 7: the dodge's whoosh).
func _make_sidestep(s: _Synth) -> void:
	s.swoosh(0.0, 0.22 * s.rr(0.9, 1.1), 1.0, 1100.0, 4600.0, 1700.0, 0.25)
	s.noise_burst(0.0, 0.05, 0.2, 2500.0, 1200.0, 400.0, 0.001, 0.012)

## Footstep: a short shoe scuff with a small heel knock.
func _make_step(s: _Synth) -> void:
	s.noise_burst(0.0, 0.08, 0.8, s.rr(2200.0, 3000.0), 800.0, 220.0, 0.001, s.rr(0.014, 0.02))
	s.tone(0.0, 0.08, s.rr(85.0, 100.0), 60.0, 0.015, 0.6, 0.0008, 0.02)
	s.crackle(0.004, 0.05, 0.2, 600.0, 0.02, 3500.0)

## Footstep in shallow water: a slap and a spray of droplets.
func _make_step_water(s: _Synth) -> void:
	s.noise_burst(0.0, 0.22, 0.85, s.rr(3500.0, 4500.0), 1400.0, 500.0, 0.002, 0.05)
	s.crackle(0.01, 0.25, 0.5, 900.0, 0.07, 6000.0)
	s.tone(0.0, 0.1, s.rr(260.0, 320.0), 520.0, 0.04, 0.25, 0.002, 0.03)
	s.tone(0.0, 0.08, 90.0, 60.0, 0.02, 0.4, 0.001, 0.02)

## Footstep on a metal plate: a ringing clank.
func _make_step_metal(s: _Synth) -> void:
	var f := s.rr(520.0, 600.0)
	s.modal(0.0, 0.5, f, [1.0, 2.37, 4.08, 6.31], [0.8, 0.5, 0.3, 0.18], [0.16, 0.1, 0.06, 0.04], 0.55)
	s.tone(0.0, 0.12, 110.0, 70.0, 0.02, 0.7, 0.0008, 0.03)
	s.noise_burst(0.0, 0.03, 0.5, 7000.0, 3500.0, 1500.0, 0.0002, 0.006)
	s.drive(1.3)

## Vault: a cloth swish and a palm slap on the top.
func _make_vault(s: _Synth) -> void:
	s.swoosh(0.0, 0.3, 0.8, 600.0, 2400.0, 800.0, 0.35)
	s.noise_burst(0.03, 0.06, 0.6, 4200.0, 1800.0, 700.0, 0.0004, 0.012)
	s.tone(0.03, 0.08, 150.0, 90.0, 0.02, 0.35, 0.0006, 0.02)

## Hard landing: a body-weight thud and grit.
func _make_land_hard(s: _Synth) -> void:
	s.tone(0.0, 0.32, s.rr(80.0, 90.0), 45.0, 0.04, 1.0, 0.001, 0.09)
	s.noise_burst(0.0, 0.2, 0.7, 1600.0, 400.0, 150.0, 0.001, 0.05)
	s.noise_burst(0.0, 0.05, 0.4, 3500.0, 1500.0, 500.0, 0.0005, 0.012)
	s.crackle(0.01, 0.2, 0.35, 700.0, 0.06, 3200.0)
	s.drive(1.7)

## Heavy landing: a boom, a floor crack and crumbling chunks.
func _make_land_heavy(s: _Synth) -> void:
	s.tone(0.0, 1.0, s.rr(52.0, 60.0), 30.0, 0.12, 1.0, 0.002, 0.32)
	s.noise_burst(0.0, 0.05, 0.9, 7000.0, 3000.0, 1200.0, 0.0003, 0.01)
	s.noise_burst(0.0, 0.7, 0.7, 1800.0, 200.0, 80.0, 0.002, 0.2)
	s.crackle(0.0, 0.6, 0.7, 700.0, 0.15, 3800.0)
	s.knocks(0.08, 0.6, 6, 120.0, 230.0, 0.4, 0.04)
	s.drive(2.0)

## Speed wind: a seamless 2 s loop of airy band noise with slow gusts. The
## gusts complete whole cycles in the loop, and the tail is crossfaded (equal
## power) into the head so the loop point never clicks.
func _make_wind(s: _Synth) -> void:
	var sr := _Synth.SR
	var n := int(2.0 * sr)
	var x := int(0.25 * sr)
	var g := PackedFloat32Array()
	g.resize(n + x)
	var lp1 := 0.0
	var lp2 := 0.0
	var hp := 0.0
	var a_lp := 1.0 - exp(-TAU * 1300.0 / sr)
	var a_hp := 1.0 - exp(-TAU * 260.0 / sr)
	var hiss := 0.0
	var a_h := 1.0 - exp(-TAU * 5200.0 / sr)
	for k in n + x:
		var t := k / sr
		var w := s.noise()
		lp1 += a_lp * (w - lp1)
		lp2 += a_lp * (lp1 - lp2)
		hp += a_hp * (lp2 - hp)
		hiss += a_h * (s.noise() - hiss)
		var gust := 0.72 + 0.18 * sin(TAU * 1.0 * t + 0.6) + 0.1 * sin(TAU * 2.5 * t + 1.9)
		g[k] = ((lp2 - hp) * 7.0 + hiss * 0.12) * gust
	s.buf.resize(n)
	for k in n:
		if k < x:
			var u := float(k) / x
			s.buf[k] = g[k] * sqrt(u) + g[n + k] * sqrt(1.0 - u)
		else:
			s.buf[k] = g[k]

## A body hitting shallow water: a heavy splash and falling droplets.
func _make_splash(s: _Synth) -> void:
	s.noise_burst(0.0, 0.5, 1.0, 3800.0, 900.0, 250.0, 0.003, 0.13)
	s.tone(0.0, 0.25, 90.0, 55.0, 0.04, 0.7, 0.001, 0.07)
	s.crackle(0.05, 0.6, 0.6, 600.0, 0.18, 6500.0)
	s.tone(0.02, 0.15, 300.0, 700.0, 0.05, 0.2, 0.002, 0.05)
	s.drive(1.4)

## A bottle shattering: a bright crash and a shower of glass tinkles.
func _make_break_glass(s: _Synth) -> void:
	s.noise_burst(0.0, 0.12, 1.0, 11000.0, 6000.0, 3500.0, 0.0002, 0.025)
	for i in 9:
		var f := s.rr(2600.0, 6800.0)
		var t0 := s.rr(0.0, 0.35)
		s.modal(t0, 0.3, f, [1.0, 1.73, 2.61], [0.6, 0.35, 0.2], [0.05, 0.035, 0.02], s.rr(0.15, 0.3))
	s.crackle(0.01, 0.45, 0.5, 1300.0, 0.12, 9000.0)
	s.tone(0.0, 0.08, 220.0, 120.0, 0.02, 0.3, 0.001, 0.02)


# =============================================================================
# Round 6: more destruction (docs/ARCHITECTURE.md, "Round 6"). Sounds are
# layered by material and size; slow-motion pitch rules are unchanged (the
# player's own breaks keep real-time pitch, everything else slows).
# =============================================================================

const DestructionFXScript := preload("res://scripts/fx/destruction_fx.gd")
const R8ChargeFX := preload("res://scripts/fx/charge_fx.gd")
## Break level (dB) at the smallest .. biggest break, and pitch (bigger is lower).
const BREAK_DB := Vector2(-9.0, 2.0)
const BREAK_PITCH := Vector2(1.18, 0.88)
const BLAST_REF := 6000.0         ## power x radius / 2.5 at which the blast thump plays at its base level

## Every Round 6 sound played for an event: {frame, event, ids} (tests).
var destruction_sounds: Array[Dictionary] = []
var _r6_connected := false

func _connect_round6() -> void:
	if _r6_connected:
		return
	_r6_connected = true
	GameEvents.furniture_broken.connect(_on_furniture_broken)
	GameEvents.structure_collapsed.connect(_on_structure_collapsed)
	GameEvents.floor_damaged.connect(_on_floor_damaged)
	GameEvents.world_blast.connect(_on_world_blast)

func _log_r6(event: StringName, ids: Array) -> void:
	destruction_sounds.append({"frame": Engine.get_physics_frames(), "event": event, "ids": ids})
	if destruction_sounds.size() > 64:
		destruction_sounds.pop_front()

## A clutter object broke: its material's break, louder and lower the bigger.
func _on_furniture_broken(node: Node3D, position: Vector3, kind: StringName, energy: float, by: Node3D) -> void:
	var surface := DestructionFXScript.surface_for(node, kind)
	var sz := DestructionFXScript.break_size(kind, energy)
	var vol := lerpf(BREAK_DB.x, BREAK_DB.y, sz)
	var pitch := lerpf(BREAK_PITCH.x, BREAK_PITCH.y, sz)
	var ids: Array[StringName] = []
	match surface:
		&"glass":
			ids = [&"break_glass", &"glass_tinkle"]
			_play_fresh(&"break_glass", position, vol, pitch, by)
			_play_fresh(&"glass_tinkle", position, vol - 2.0, 1.0 + (1.0 - sz) * 0.15, by)
		&"cardboard":
			ids = [&"break_cardboard"]
			_play_fresh(&"break_cardboard", position, vol, pitch, by)
		&"fabric":
			ids = [&"break_fabric"]
			_play_fresh(&"break_fabric", position, vol, pitch, by)
		&"concrete", &"brick":
			ids = [&"break_brick", &"strike_concrete"]
			_play_fresh(&"break_brick", position, vol - 2.0, pitch * 1.25, by)
			_play_fresh(&"strike_concrete", position, vol - 4.0, pitch, by)
		_:  # wood: a splinter crack-snap over the wood break
			ids = [&"break_wood", &"snap_wood"]
			_play_fresh(&"break_wood", position, vol, pitch, by)
			_play_fresh(&"snap_wood", position, vol - 1.0, pitch * 1.05, by)
	_log_r6(&"furniture", ids)

## Structure gave way: a creak (D drops overhead pieces Tuning.PILLAR_COLLAPSE_DELAY
## after the snap); the boom comes when the heavy piece lands (collapse_boom).
func _on_structure_collapsed(_node: Node3D, position: Vector3, kind: StringName) -> void:
	_play_fresh(&"creak", position, 0.0 if kind == &"overhead" else -4.0, 1.0 if kind == &"overhead" else 1.2)
	_log_r6(&"collapse", [&"creak"])

## DestructionFX: a heavy fallen piece landed near a fresh collapse.
func collapse_boom(position: Vector3, energy: float) -> void:
	_play_fresh(&"boom", position, clampf(energy_db(energy, 4000.0), -4.0, 3.0), energy_pitch(energy, 4000.0) * 0.9)
	_play_fresh(&"land_heavy", position, -3.0, 1.0)
	_log_r6(&"collapse_landing", [&"boom", &"land_heavy"])

## Floor damage by level: a crack, a crack and a low thump, then a crumble.
func _on_floor_damaged(position: Vector3, _radius: float, level: int, _surface: StringName) -> void:
	if level <= 0:
		return  # no new level (a lone tile pop): the tick is DestructionFX's
	if level == 1 and is_step_crack(position):
		_step_crunch(position)
		return
	var ids: Array[StringName] = [&"crack"]
	match clampi(level, 1, 3):
		1:
			_play_fresh(&"crack", position, -5.0, 1.1)
		2:
			_play_fresh(&"crack", position, -1.0, 0.95)
			_play_fresh(&"thump_low", position, -3.0, 1.05)
			ids.append(&"thump_low")
		3:
			_play_fresh(&"crack", position, 0.0, 0.88)
			_play_fresh(&"break_brick", position, -3.0, 0.85)
			_play_fresh(&"thump_low", position, 0.0, 0.95)
			ids.append_array([&"break_brick", &"thump_low"])
	# Tile pops (surface &"tile") tick through DestructionFX.tile_pop(), which throttles bursts.
	_log_r6(&"floor", ids)

## A blast: a low thump scaled by power and radius.
func _on_world_blast(center: Vector3, radius: float, power: float, _source: StringName) -> void:
	var e := power * radius / 2.5
	_play_fresh(&"thump_low", center, clampf(energy_db(e, BLAST_REF), -10.0, 3.0),
			clampf(energy_pitch(e, BLAST_REF), 0.8, 1.15))
	_log_r6(&"blast", [&"thump_low"])

## A plaza tile popping out: a ceramic tick-crack (DestructionFX throttles bursts).
func tile_pop(position: Vector3) -> void:
	_play_fresh(&"tile_pop", position, 0.0, 1.0)

## play() without the 25 ms same-id guard: Round 6 events are throttled at their source.
func _play_fresh(id: StringName, position: Vector3, volume_db := 0.0, pitch := 1.0, source: Node3D = null) -> void:
	_last_ms.erase(id)
	play(id, position, volume_db, pitch, source)


# --- Round 6 sound designs ----------------------------------------------------------

## A sharp wood crack-snap (fibres giving way).
func _make_snap_wood(s: _Synth) -> void:
	s.noise_burst(0.0, 0.04, 1.0, 9000.0, 5000.0, 2200.0, 0.0002, 0.006)
	s.tone(0.0, 0.06, s.rr(1100.0, 1400.0), 380.0, 0.01, 0.45, 0.0002, 0.012)
	s.crackle(0.003, 0.18, 0.7, 2200.0, 0.05, 6000.0)
	s.tone(0.0, 0.18, 190.0, 110.0, 0.03, 0.4, 0.001, 0.04)
	s.drive(1.5)

## The tail of a glass break: sparse high pings thinning out over a second.
func _make_glass_tinkle(s: _Synth) -> void:
	s.ensure(1.2)
	var n := 16
	for i in n:
		var u := float(i) / n
		var t0 := 0.08 + pow(u, 1.5) * 1.0 + s.rr(-0.02, 0.02)
		var f := s.rr(2800.0, 7200.0)
		s.modal(maxf(t0, 0.0), 0.18, f, [1.0, 1.61, 2.47], [0.7, 0.35, 0.15], [0.04, 0.025, 0.015],
				s.rr(0.25, 0.5) * (1.0 - 0.6 * u))

## Cardboard: a papery crumple over a soft hollow thump.
func _make_break_cardboard(s: _Synth) -> void:
	s.crackle(0.0, 0.45, 0.8, 1100.0, 0.12, 2600.0)
	s.noise_burst(0.0, 0.2, 0.6, 1800.0, 600.0, 250.0, 0.002, 0.06)
	s.tone(0.0, 0.2, s.rr(105.0, 125.0), 70.0, 0.03, 0.6, 0.002, 0.05)
	s.crackle(0.08, 0.3, 0.35, 300.0, 0.15, 1800.0)
	s.drive(1.3)

## Fabric (a sofa): a muffled heavy thump and a cloth tear.
func _make_break_fabric(s: _Synth) -> void:
	s.tone(0.0, 0.35, s.rr(85.0, 95.0), 52.0, 0.05, 1.0, 0.002, 0.11)
	s.noise_burst(0.0, 0.3, 0.7, 700.0, 250.0, 0.0, 0.002, 0.1)
	s.noise_burst(0.05, 0.3, 0.35, 2600.0, 1500.0, 900.0, 0.01, 0.08)
	s.crackle(0.05, 0.25, 0.3, 700.0, 0.08, 2400.0)
	s.lowpass(3000.0)
	s.drive(1.4)

## Structure creak: a slow groan with a pitch wobble and a strained squeal.
func _make_creak(s: _Synth) -> void:
	s.tone(0.0, 0.75, s.rr(68.0, 76.0), 96.0, 0.35, 0.8, 0.08, 0.5, 2, 5.0, 0.03)
	s.tone(0.05, 0.6, s.rr(380.0, 430.0), 520.0, 0.3, 0.25, 0.1, 0.35, 1, 7.0, 0.02)
	s.crackle(0.0, 0.7, 0.25, 160.0, 0.4, 1500.0)
	s.lowpass(1600.0)
	s.drive(1.4)

## A plaza tile popping: a ceramic tick and a small crack.
func _make_tile_pop(s: _Synth) -> void:
	var f := s.rr(2200.0, 2700.0)
	s.modal(0.0, 0.2, f, [1.0, 1.73, 2.9], [0.8, 0.4, 0.2], [0.03, 0.02, 0.012], 0.5)
	s.noise_burst(0.0, 0.03, 0.8, 7000.0, 3500.0, 1500.0, 0.0002, 0.005)
	s.tone(0.0, 0.08, 220.0, 140.0, 0.02, 0.35, 0.0005, 0.02)
	s.crackle(0.005, 0.1, 0.3, 900.0, 0.03, 4000.0)

## A low thump (blasts, craters): a sub hit with a dull rumble.
func _make_thump_low(s: _Synth) -> void:
	s.tone(0.0, 0.6, s.rr(46.0, 52.0), 30.0, 0.08, 1.0, 0.002, 0.17)
	s.noise_burst(0.0, 0.5, 0.6, 160.0, 70.0, 0.0, 0.005, 0.15)
	s.noise_burst(0.0, 0.04, 0.25, 1500.0, 600.0, 200.0, 0.0006, 0.01)
	s.drive(1.6)

## Footstep on broken glass: a bright crunch of grit.
func _make_step_glass(s: _Synth) -> void:
	s.crackle(0.0, 0.14, 0.8, 1600.0, 0.04, 7500.0)
	s.noise_burst(0.0, 0.05, 0.4, 5000.0, 2500.0, 1200.0, 0.0005, 0.01)
	s.modal(0.01, 0.1, s.rr(3500.0, 5000.0), [1.0, 1.6], [0.4, 0.2], [0.02, 0.012], 0.3)

## Footstep on cardboard: a papery scuff.
func _make_step_cardboard(s: _Synth) -> void:
	s.noise_burst(0.0, 0.08, 0.7, 2000.0, 700.0, 350.0, 0.001, 0.025)
	s.crackle(0.0, 0.1, 0.4, 700.0, 0.04, 2200.0)
	s.tone(0.0, 0.07, 110.0, 80.0, 0.02, 0.4, 0.001, 0.02)

## Footstep on fabric (a sofa cushion): a soft muffled pat.
func _make_step_fabric(s: _Synth) -> void:
	s.tone(0.0, 0.1, 82.0, 58.0, 0.02, 0.8, 0.002, 0.025)
	s.noise_burst(0.0, 0.08, 0.5, 650.0, 300.0, 0.0, 0.002, 0.025)

## A knock on glass that holds: a thud and a short ring.
func _make_strike_glass(s: _Synth) -> void:
	s.tone(0.0, 0.15, 160.0, 110.0, 0.02, 0.7, 0.0008, 0.03)
	s.modal(0.0, 0.45, s.rr(1700.0, 2000.0), [1.0, 2.32, 3.9], [0.6, 0.3, 0.15], [0.12, 0.07, 0.04], 0.5)
	s.noise_burst(0.0, 0.02, 0.5, 9000.0, 5000.0, 3000.0, 0.0002, 0.004)

## A hit on cardboard: a hollow papery thump.
func _make_strike_cardboard(s: _Synth) -> void:
	s.tone(0.0, 0.16, s.rr(135.0, 150.0), 88.0, 0.02, 0.8, 0.001, 0.045)
	s.noise_burst(0.0, 0.1, 0.5, 1800.0, 700.0, 300.0, 0.001, 0.035)
	s.crackle(0.01, 0.1, 0.25, 600.0, 0.04, 2400.0)

## A hit on fabric (a sofa): a muffled thump.
func _make_strike_fabric(s: _Synth) -> void:
	s.tone(0.0, 0.2, s.rr(92.0, 100.0), 60.0, 0.03, 0.9, 0.002, 0.06)
	s.noise_burst(0.0, 0.15, 0.5, 500.0, 220.0, 0.0, 0.002, 0.05)


# =============================================================================
# Round 7: Freeflow combat (docs/Round 7 — Freeflow Combat.md, Effects and Hit
# feel). A player hit (HitInfo.react set) is layered by HitInfo.weight, on its
# physics frame: a sharp crack on every hit (higher and tighter on light hits),
# a meaty smack from R7_SMACK_FROM, a deep body thump from R7_THUMP_FROM (the
# doc's "heavy thump at weight >= 0.6"), and the tier's launch boom under a
# launch payoff. Every other hit keeps its Round 5 tier stream. The counter,
# dodge, glide, reactions, drive and throw listen to the Round 7 events.
# =============================================================================

## Layer thresholds (HitInfo.weight): the smack joins at the hook and leg kick,
## the thump at the heavies, the uppercut and up.
const R7_SMACK_FROM := 0.4
const R7_THUMP_FROM := 0.6
## Level (dB) and pitch of each layer from its threshold to weight 1.
const R7_CRACK_DB := Vector2(-2.0, 1.5)
const R7_CRACK_PITCH := Vector2(1.14, 0.9)
const R7_SMACK_DB := Vector2(-6.0, 0.5)
const R7_SMACK_PITCH := Vector2(1.06, 0.92)
const R7_THUMP_DB := Vector2(-3.0, 3.0)
const R7_THUMP_PITCH := Vector2(1.05, 0.86)
const R7_LAUNCH_DB := -2.0         ## the tier's launch boom under a launch payoff
## Swing whoosh of a Round 7 move (strike_started) by its weight: level (dB)
## and pitch at weight 0 .. 1; from R7_SWING_HEAVY_FROM the long charged whoosh.
const R7_SWING_DB := Vector2(-4.0, 1.5)
const R7_SWING_PITCH := Vector2(1.25, 0.82)
const R7_SWING_HEAVY_FROM := 0.6
## Counter whiff: a soft, light whoosh (dB, pitch).
const R7_WHIFF_DB := -8.0
const R7_WHIFF_PITCH := 1.25
## Dodge: the quick swish and a shoe scuff under it (dB).
const R7_DODGE_SCUFF_DB := -4.0
## Glide rush (dB, pitch) from a short glide to FXRules.GLIDE_FULL.
const R7_RUSH_DB := Vector2(-7.0, 1.0)
const R7_RUSH_PITCH := Vector2(1.15, 0.9)
## Reaction sounds by Fighter.react kind, with their level (dB). A heavy
## enemy's grunt and knee are a little lower (R7_HEAVY_PITCH).
const R7_REACT_SOUND := {&"fold": &"oof", &"lift": &"whoosh_up", &"repop": &"whoosh_up",
	&"buckle": &"knee_floor", &"spin": &"whip"}
const R7_REACT_DB := {&"fold": 0.0, &"lift": 0.0, &"repop": -4.0, &"buckle": 0.0, &"spin": -1.0}
const R7_HEAVY_PITCH := 0.85
## Drive: footstep thud level (dB) and pitch from the start speed to the top
## speed; a drive with no drive_ended stops after R7_DRIVE_MAX_TIME + this (s).
const R7_DRIVE_STEP_DB := Vector2(-4.0, 2.0)
const R7_DRIVE_STEP_PITCH := Vector2(1.05, 0.92)
const R7_DRIVE_TIME_PAD := 1.0
## The wind loop's level at the start of a drive; it rises to 1 at the top speed.
const R7_DRIVE_WIND_FLOOR := 0.35
## Drive impacts: energy (J) at which the boom plays at its base level (about
## 105 kg at 7 m/s through FXRules.drive_energy).
const R7_DRIVE_REF_ENERGY := 2600.0
## Throw release (dB, pitch) from a tap to a full wind-up; past
## R7_THROW_HEAVY_FROM of the range the charged whoosh layers under it.
const R7_THROW_DB := Vector2(-3.0, 3.0)
const R7_THROW_PITCH := Vector2(1.15, 0.8)
const R7_THROW_HEAVY_FROM := 0.5
const R7_THROW_HEAVY_DB := Vector2(-8.0, -1.0)
const R7_PROP_THROW_DB := -2.0     ## a prop is lighter than a body
## God path (amendment). The ram's level-3 launch layers a boom (dB) under the
## launch impact. The pursuit spike's floor impact (FXRules.is_spike_shockwave):
## a big boom (dB, pitch), the heavy crumble and a low thump. A level-1 floor
## crack on the frame of a footstep within STEP_CRUNCH_REACH m is a footstep
## crack at speed: a small crunch layered on the step instead of the big crack.
const R7_RAM_LAUNCH_BOOM_DB := -3.0
const R7_SPIKE_BOOM_DB := 3.0
const R7_SPIKE_BOOM_PITCH := 0.82
## Round 9: dB per unit of spike heft over 1 (FXRules.spike_heft), and the
## pitch drop (pitch x heft^-this).
const R9_SPIKE_HEFT_DB := 6.0
const R9_SPIKE_HEFT_PITCH := 0.35
## Round 9: the axe kick's heel crack (dB, pitch): tap, charged at c = 0, at c = 1.
const R9_AXE_DB := Vector3(-1.0, 1.0, 3.5)
const R9_AXE_PITCH := Vector3(1.08, 0.97, 0.86)
const STEP_CRUNCH_REACH := 0.9
const R7_STEP_CRUNCH_DB := Vector2(-2.0, 1.0)  ## at R7_SPEED_CRACK_FROM .. the top cap

## Every Round 7 sound group played: {frame (physics), event, ids, db} (tests, newest last).
var round7_sounds: Array[Dictionary] = []
## Drive footsteps played since start (tests).
var drive_steps := 0
var _drives: Dictionary = {}       ## holder id -> {"holder", "t", "next"}
var _drive_level := 0.0
var _r7_connected := false
var _step_frame := -1               ## physics frame of the last footstep (footstep cracks)
var _step_pos := Vector3.ZERO
var _step_fighter: Node3D

func _connect_round7() -> void:
	if _r7_connected:
		return
	_r7_connected = true
	GameEvents.countered.connect(_on_countered)
	GameEvents.counter_whiffed.connect(_on_counter_whiffed)
	GameEvents.dodged.connect(_on_dodged)
	GameEvents.glide_started.connect(_on_glide_started)
	GameEvents.react_started.connect(_on_react_started)
	GameEvents.drive_started.connect(_on_drive_started)
	GameEvents.drive_ended.connect(_on_drive_ended)
	GameEvents.drive_impact.connect(_on_drive_impact)
	GameEvents.shockwave.connect(_on_shockwave)
	GameEvents.round_started.connect(func(_m: StringName) -> void: _drives.clear())

func _log_r7(event: StringName, ids: Array, dbs: Array) -> void:
	round7_sounds.append({"frame": Engine.get_physics_frames(), "event": event, "ids": ids, "db": dbs})
	if round7_sounds.size() > 64:
		round7_sounds.pop_front()

## The layers a Round 7 hit plays: [[id, dB, pitch], ...], lightest first.
static func hit_layers(info: HitInfo) -> Array:
	var w := FXRules.weight_of(info)
	var out: Array = [[&"hit_crack", lerpf(R7_CRACK_DB.x, R7_CRACK_DB.y, w),
		lerpf(R7_CRACK_PITCH.x, R7_CRACK_PITCH.y, w)]]
	if w >= R7_SMACK_FROM:
		var u := clampf((w - R7_SMACK_FROM) / (1.0 - R7_SMACK_FROM), 0.0, 1.0)
		out.append([&"hit_smack", lerpf(R7_SMACK_DB.x, R7_SMACK_DB.y, u), lerpf(R7_SMACK_PITCH.x, R7_SMACK_PITCH.y, u)])
	if w >= R7_THUMP_FROM:
		var u := clampf((w - R7_THUMP_FROM) / (1.0 - R7_THUMP_FROM), 0.0, 1.0)
		out.append([&"hit_thump", lerpf(R7_THUMP_DB.x, R7_THUMP_DB.y, u), lerpf(R7_THUMP_PITCH.x, R7_THUMP_PITCH.y, u)])
	if info != null and info.react == &"launch":
		out.append([TIER_SOUND[HitInfo.Tier.LAUNCH], R7_LAUNCH_DB, 1.0])
	# Round 8: a charged hit scales every layer with c on top of the weight.
	if FXRules.is_charged(info):
		var c := clampf(info.charge, 0.0, 1.0)
		for layer: Array in out:
			layer[1] = float(layer[1]) + R8_CHARGE_DB * c
			layer[2] = float(layer[2]) * lerpf(1.0, R8_CHARGE_PITCH, c)
	out.append_array(r8_accent_layers(info))
	return out

## Round 8 accents on a hit: [[id, dB, pitch], ...]. A charged hit adds the
## charged crunch (louder and deeper with c); a hit on a broken enemy adds the
## heavy broken accent.
static func r8_accent_layers(info: HitInfo) -> Array:
	var out: Array = []
	if info == null:
		return out
	if FXRules.is_charged(info):
		var c := clampf(info.charge, 0.0, 1.0)
		out.append([&"hit_charged", lerpf(R8_CHARGED_DB.x, R8_CHARGED_DB.y, c),
			lerpf(R8_CHARGED_PITCH.x, R8_CHARGED_PITCH.y, c)])
	if info.broken_bonus:
		out.append([&"hit_broken", R8_BROKEN_DB, 1.0])
	out.append_array(axe_layers(info))
	return out

## Round 9: the axe kick's heel crack, [[id, dB, pitch]] (or []): louder and
## deeper for a charged one, more with c.
static func axe_layers(info: HitInfo) -> Array:
	if not FXRules.is_axe_kick(info):
		return []
	if not FXRules.is_charged(info):
		return [[&"axe_crack", R9_AXE_DB.x, R9_AXE_PITCH.x]]
	var c := clampf(info.charge, 0.0, 1.0)
	return [[&"axe_crack", lerpf(R9_AXE_DB.y, R9_AXE_DB.z, c), lerpf(R9_AXE_PITCH.y, R9_AXE_PITCH.z, c)]]

## A Round 7 player hit: every layer on the hit's physics frame. The attacker
## owns the sound (the player's hits keep real-time pitch in slow motion).
func _r7_hit(info: HitInfo) -> void:
	var at := _hit_point(info)
	var ids: Array[StringName] = []
	var dbs: Array[float] = []
	var streams: Array = []
	for layer: Array in hit_layers(info):
		var id: StringName = layer[0]
		_last_ms.erase(id)  # two hits in one tick both land
		play(id, at, layer[1], layer[2], info.attacker)
		ids.append(id)
		dbs.append(layer[1])
		streams.append(last_stream.get(id))
	hit_sounds.append({"frame": Engine.get_physics_frames(), "tier": FXRules.tier_of(info), "id": ids[0],
		"stream": streams[0], "weight": FXRules.weight_of(info), "layers": ids, "db": dbs, "streams": streams})
	if hit_sounds.size() > 64:
		hit_sounds.pop_front()

## Counter: a crack into a bright steel ring between the two fighters, unlike
## any strike (the defender, usually the player, owns it).
func _on_countered(defender: Node3D, attacker: Node3D) -> void:
	if not is_instance_valid(defender) and not is_instance_valid(attacker):
		return
	var at := _pos_of(defender) if is_instance_valid(defender) else _pos_of(attacker)
	if is_instance_valid(defender) and is_instance_valid(attacker):
		at = at.lerp(_pos_of(attacker), 0.5)
	_play_fresh(&"counter_hit", at, 0.0, 1.0, defender)
	_log_r7(&"countered", [&"counter_hit"], [0.0])

## A Counter press with nothing to counter: a soft whoosh.
func _on_counter_whiffed(defender: Node3D) -> void:
	if not is_instance_valid(defender):
		return
	_play_fresh(&"whoosh", _pos_of(defender), R7_WHIFF_DB, R7_WHIFF_PITCH, defender)
	_log_r7(&"counter_whiffed", [&"whoosh"], [R7_WHIFF_DB])

## Dodge: a quick swish and a shoe scuff as the feet push off.
func _on_dodged(fighter: Node3D, _direction: Vector3) -> void:
	if not is_instance_valid(fighter):
		return
	_play_fresh(&"sidestep", _pos_of(fighter), 0.0, 1.05, fighter)
	_play_fresh(&"step", _feet_of(fighter), R7_DODGE_SCUFF_DB, 1.1, fighter)
	_log_r7(&"dodged", [&"sidestep", &"step"], [0.0, R7_DODGE_SCUFF_DB])

## Glide: a rush of air, louder and lower the longer the glide.
func _on_glide_started(fighter: Node3D, _target: Node3D, distance: float) -> void:
	if not is_instance_valid(fighter):
		return
	var t := FXRules.glide_share(distance)
	var db := lerpf(R7_RUSH_DB.x, R7_RUSH_DB.y, t)
	_play_fresh(&"rush", _pos_of(fighter), db, lerpf(R7_RUSH_PITCH.x, R7_RUSH_PITCH.y, t), fighter)
	_log_r7(&"glide_started", [&"rush"], [db])

## Reaction touches: fold = a winded grunt, lift (and a re-pop) = an upward
## whoosh, buckle = a knee on the floor, spin = a head-turn whip. Snap and push
## need nothing on top of the hit.
func _on_react_started(victim: Node3D, kind: StringName, _attacker: Node3D) -> void:
	var id: StringName = R7_REACT_SOUND.get(kind, &"")
	if id == &"" or not is_instance_valid(victim):
		return
	var at := _pos_of(victim)
	if kind == &"buckle" or kind == &"lift":
		at = _feet_of(victim) + Vector3.UP * (0.3 if kind == &"buckle" else 0.6)
	var heavy: bool = victim.has_method(&"is_heavy") and victim.call(&"is_heavy")
	var db: float = R7_REACT_DB.get(kind, 0.0)
	_play_fresh(id, at, db, R7_HEAVY_PITCH if heavy else 1.0, victim)
	_log_r7(StringName("react_" + String(kind)), [id], [db])

## Drive: the push-off thuds at once; then a heavy thud every stride
## (FXRules.drive_step_gap, quicker as the speed builds) and the wind loop
## rising with the speed, until drive_ended.
func _on_drive_started(holder: Node3D, _held: Node3D) -> void:
	if not is_instance_valid(holder):
		return
	var d := {"holder": holder, "t": 0.0, "next": 0.0}
	_drives[holder.get_instance_id()] = d
	_drive_step(d, _feet_of(holder))
	_log_r7(&"drive_started", [&"drive_step", &"wind"], [d.get("db", 0.0)])

func _on_drive_ended(holder: Node3D, _reason: StringName) -> void:
	if is_instance_valid(holder):
		_drives.erase(holder.get_instance_id())

## 0..1 wind level the drives ask for now (tests, debug).
func get_drive_wind() -> float:
	return _drive_level

## Drives being heard (tests, debug).
func active_drives() -> int:
	return _drives.size()

## Step the drive clocks: a thud whenever a stride is due (a Traversal footstep
## during the drive also lands as one and restarts the clock). Player drives
## count real time (the player keeps real time in slow motion).
func _update_drives(real: float, delta: float) -> void:
	var level := 0.0
	for id: int in _drives.keys():
		var d: Dictionary = _drives[id]
		var h = d["holder"]
		if not is_instance_valid(h) or not (h as Node3D).is_inside_tree():
			_drives.erase(id)
			continue
		var dt := real if (h as Node3D).is_in_group(&"player") else delta
		d["t"] = float(d["t"]) + dt
		if float(d["t"]) > Tuning.R7_DRIVE_MAX_TIME + R7_DRIVE_TIME_PAD:
			_drives.erase(id)
			continue
		d["next"] = float(d["next"]) - dt
		if float(d["next"]) <= 0.0:
			_drive_step(d, _feet_of(h))
		var v := FXRules.drive_speed(h, float(d["t"]))
		level = maxf(level, lerpf(R7_DRIVE_WIND_FLOOR, 1.0, FXRules.drive_share(v)))
	_drive_level = level

## One drive footstep thud at `position`, louder and lower with the speed.
func _drive_step(d: Dictionary, position: Vector3) -> void:
	var h: Node3D = d["holder"]
	var v := FXRules.drive_speed(h, float(d["t"]))
	var k := FXRules.drive_share(v)
	var db := lerpf(R7_DRIVE_STEP_DB.x, R7_DRIVE_STEP_DB.y, k)
	_play_fresh(&"drive_step", position, db, lerpf(R7_DRIVE_STEP_PITCH.x, R7_DRIVE_STEP_PITCH.y, k), h)
	d["next"] = FXRules.drive_step_gap(v)
	d["db"] = db
	drive_steps += 1
	if _drive_level <= 0.0:  # the wind starts on the push-off, not a frame later
		_drive_level = R7_DRIVE_WIND_FLOOR

## The driven body met something: a boom on top of a break; a big boom, the
## wall slam and the crumble on a slam; a body crash on a bowl; a light thud
## on a shove. Levels follow FXRules.drive_energy at the contact speed.
func _on_drive_impact(holder: Node3D, victim: Node3D, target: Node3D, position: Vector3, speed: float,
		result: StringName) -> void:
	var e := FXRules.drive_energy(victim, holder, speed)
	var db := clampf(energy_db(e, R7_DRIVE_REF_ENERGY), -6.0, 3.0)
	var pitch := energy_pitch(e, R7_DRIVE_REF_ENERGY)
	var src: Node3D = holder if is_instance_valid(holder) else null
	var ids: Array[StringName] = []
	var dbs: Array[float] = []
	match result:
		&"break":
			_play_fresh(&"boom", position, db, pitch, src)
			_play_fresh(&"body_slam", position, db - 3.0, pitch * 1.05, src)
			ids = [&"boom", &"body_slam"]
			dbs = [db, db - 3.0]
		&"slam":
			_play_fresh(&"boom", position, db + 3.0, pitch * 0.9, src)
			_play_fresh(&"wall_slam", position, db + 1.0, pitch, src)
			_play_fresh(&"land_heavy", position, db - 2.0, 1.0, src)
			ids = [&"boom", &"wall_slam", &"land_heavy"]
			dbs = [db + 3.0, db + 1.0, db - 2.0]
		&"bowl":
			var at := _pos_of(target) if is_instance_valid(target) else position
			_play_fresh(&"body_slam", at, db, pitch, src)
			_play_fresh(&"impact_knockdown", at, db - 3.0, 1.0, src)
			ids = [&"body_slam", &"impact_knockdown"]
			dbs = [db, db - 3.0]
		_:  # &"shove" (or an unknown result): bodies bump
			_play_fresh(&"thud", position, db - 2.0, 1.1, src)
			ids = [&"thud"]
			dbs = [db - 2.0]
	_log_r7(StringName("drive_" + String(result)), ids, dbs)

## Throw release: the throw whoosh by speed share (FXRules.throw_share); a fast
## throw layers the charged whoosh under it.
func _throw_whoosh(event: StringName, at: Vector3, speed: float, source: Node3D, extra_db: float) -> void:
	var k := FXRules.throw_share(speed)
	var db := lerpf(R7_THROW_DB.x, R7_THROW_DB.y, k) + extra_db
	_play_fresh(&"throw", at, db, lerpf(R7_THROW_PITCH.x, R7_THROW_PITCH.y, k), source)
	var ids: Array[StringName] = [&"throw"]
	var dbs: Array[float] = [db]
	if k >= R7_THROW_HEAVY_FROM:
		var u := (k - R7_THROW_HEAVY_FROM) / (1.0 - R7_THROW_HEAVY_FROM)
		var hdb := lerpf(R7_THROW_HEAVY_DB.x, R7_THROW_HEAVY_DB.y, u) + extra_db
		_play_fresh(&"whoosh_charged", at, hdb, 0.95, source)
		ids.append(&"whoosh_charged")
		dbs.append(hdb)
	_log_r7(event, ids, dbs)


# --- Round 7 sound designs ----------------------------------------------------------

## Crack (every Round 7 hit): a tight skin crack with a knuckle snap and a small knock.
func _make_hit_crack(s: _Synth) -> void:
	s.noise_burst(0.0, 0.06, 1.0, s.rr(7000.0, 8500.0), 2600.0, 1400.0, 0.0002, s.rr(0.008, 0.011))
	s.tone(0.0, 0.05, s.rr(1500.0, 1800.0), 700.0, 0.008, 0.35, 0.0002, 0.008)
	s.tone(0.0, 0.14, s.rr(180.0, 220.0), 105.0, 0.015, 0.55, 0.0005, 0.03)
	s.noise_burst(0.0, 0.09, 0.3, 1400.0, 500.0, 0.0, 0.001, 0.025)
	s.drive(1.9)

## Smack (weight >= R7_SMACK_FROM): the fist or shin sinking into the body.
func _make_hit_smack(s: _Synth) -> void:
	var f := s.rr(130.0, 150.0)
	s.tone(0.0, 0.26, f, f * 0.5, 0.03, 1.0, 0.0008, 0.06)
	s.noise_burst(0.0, 0.16, 0.7, 2200.0, 600.0, 150.0, 0.0005, 0.04)
	s.crackle(0.003, 0.08, 0.25, 900.0, 0.03, 3000.0)
	s.drive(1.9)

## Thump (weight >= R7_THUMP_FROM): a deep body thump, a low sweep with a long
## tail and a sub push.
func _make_hit_thump(s: _Synth) -> void:
	var f := s.rr(62.0, 72.0)
	s.tone(0.0, 0.7, f * 1.4, f * 0.55, 0.06, 1.0, 0.001, s.rr(0.16, 0.2))
	s.tone(0.0, 0.35, f * 2.1, f * 0.9, 0.04, 0.35, 0.001, 0.07)
	s.noise_burst(0.0, 0.5, 0.55, 700.0, 140.0, 0.0, 0.002, 0.12)
	s.noise_burst(0.0, 0.05, 0.25, 2500.0, 1200.0, 300.0, 0.0005, 0.012)
	s.drive(2.1)

## Counter: a whip-like crack into a bright steel ring with a beating shimmer,
## over a short knock. Strikes are thuds and slaps that die in a tenth of a
## second; this rings high for most of a second.
func _make_counter_hit(s: _Synth) -> void:
	s.noise_burst(0.0, 0.03, 1.0, 11000.0, 7000.0, 3500.0, 0.0002, 0.004)
	var f := s.rr(1850.0, 2050.0)
	s.modal(0.0, 0.9, f, [1.0, 2.32, 4.25, 6.63, 9.38], [1.0, 0.7, 0.45, 0.3, 0.18],
			[0.42, 0.28, 0.16, 0.1, 0.06], 0.55)
	s.tone(0.0, 0.6, f * 2.0, f * 2.03, 1.0, 0.18, 0.001, 0.3)
	s.swoosh(0.01, 0.12, 0.45, 2500.0, 7000.0, 4000.0, 0.25)
	s.tone(0.0, 0.18, 170.0, 95.0, 0.03, 0.45, 0.001, 0.04)
	s.drive(1.3)

## Glide rush: a fast forward rush of air, a cloth flutter and a push-off scuff.
func _make_rush(s: _Synth) -> void:
	var d := 0.34 * s.rr(0.92, 1.08)
	s.swoosh(0.0, d, 1.0, 260.0, 1900.0 * s.rr(0.9, 1.1), 420.0, s.rr(0.35, 0.45))
	s.swoosh(0.03, d * 0.7, 0.4, 1200.0, 4200.0, 1500.0, 0.3)
	s.crackle(0.0, d * 0.8, 0.2, 700.0, 0.12, 3200.0)
	s.noise_burst(0.0, 0.07, 0.35, 2600.0, 900.0, 250.0, 0.001, 0.018)

## Fold: a winded "oof": a huff of air, then a voiced grunt falling in pitch
## while the vowel closes from "uh" to "oo", and a breathy tail.
func _make_oof(s: _Synth) -> void:
	var f0 := s.rr(125.0, 150.0)
	var k := s.rr(0.94, 1.06)  # vocal tract size
	s.noise_burst(0.0, 0.06, 0.5, 2600.0, 1400.0, 500.0, 0.001, 0.02)
	s.voice(0.015, 0.34, f0, f0 * 0.68, [680.0 * k, 1150.0 * k, 2450.0 * k], [360.0 * k, 820.0 * k, 2300.0 * k],
			[90.0, 120.0, 180.0], [1.0, 0.55, 0.22], 1.0, 0.18, 0.012, 0.13)
	s.noise_burst(0.12, 0.3, 0.25, 1800.0, 700.0, 300.0, 0.02, 0.1)
	s.lowpass(4200.0)
	s.drive(1.4)

## Lift: an upward whoosh with a rising undertone.
func _make_whoosh_up(s: _Synth) -> void:
	var d := 0.38 * s.rr(0.92, 1.08)
	s.swoosh(0.0, d, 1.0, 350.0, 2600.0 * s.rr(0.9, 1.1), 4200.0, s.rr(0.55, 0.65))
	s.tone(0.02, d, 180.0, 520.0, 0.15, 0.18, 0.05, 0.2)

## Buckle: a knee hitting the floor: a hard bony knock, a trouser scuff and grit.
func _make_knee_floor(s: _Synth) -> void:
	var f := s.rr(95.0, 115.0)
	s.tone(0.0, 0.22, f * 1.6, f, 0.012, 1.0, 0.0006, 0.045)
	s.noise_burst(0.0, 0.04, 0.7, s.rr(4000.0, 5200.0), 2000.0, 900.0, 0.0003, 0.007)
	s.noise_burst(0.0, 0.16, 0.45, 1600.0, 600.0, 250.0, 0.002, 0.045)
	s.tone(0.0, 0.3, 62.0, 45.0, 0.04, 0.55, 0.001, 0.07)
	s.crackle(0.005, 0.12, 0.3, 600.0, 0.04, 3000.0)
	s.drive(1.7)

## Spin: a head-turn whip, a fast swish with a flutter of cloth and hair.
func _make_whip(s: _Synth) -> void:
	var d := 0.2 * s.rr(0.9, 1.1)
	s.swoosh(0.0, d, 1.0, 1400.0, 5200.0 * s.rr(0.9, 1.1), 2200.0, s.rr(0.3, 0.4))
	s.crackle(0.0, d, 0.25, 900.0, 0.06, 4500.0)

## Drive footstep: a heavy foot plant under two bodies' weight, with a scuff.
func _make_drive_step(s: _Synth) -> void:
	var f := s.rr(64.0, 74.0)
	s.tone(0.0, 0.3, f * 1.3, f * 0.7, 0.03, 1.0, 0.001, s.rr(0.06, 0.08))
	s.noise_burst(0.0, 0.12, 0.6, 1500.0, 500.0, 120.0, 0.001, 0.035)
	s.noise_burst(0.0, 0.05, 0.45, s.rr(2800.0, 3600.0), 1300.0, 400.0, 0.0005, 0.012)
	s.crackle(0.004, 0.1, 0.3, 600.0, 0.03, 3200.0)
	s.drive(1.8)


# --- God path (Round 7 amendment) ------------------------------------------------------

## A level-1 floor crack at `position` on the frame of a footstep within
## STEP_CRUNCH_REACH m (flat): Traversal cracks the floor right after the
## footstep event when sprinting at Tuning.R7_SPEED_CRACK_FROM or faster.
func is_step_crack(position: Vector3) -> bool:
	if _step_frame != Engine.get_physics_frames():
		return false
	return Vector2(position.x - _step_pos.x, position.z - _step_pos.z).length() <= STEP_CRUNCH_REACH \
			and absf(position.y - _step_pos.y) < 0.6

## A footstep crack: a small crunch layered on the step, louder at a higher cap.
func _step_crunch(position: Vector3) -> void:
	var k := clampf((Power.speed_cap() - Tuning.R7_SPEED_CRACK_FROM)
			/ maxf(Tuning.SPRINT_CAPS[Tuning.SPRINT_CAPS.size() - 1] - Tuning.R7_SPEED_CRACK_FROM, 0.01), 0.0, 1.0)
	var db := lerpf(R7_STEP_CRUNCH_DB.x, R7_STEP_CRUNCH_DB.y, k)
	_play_fresh(&"step_crunch", position, db, 1.0, _step_fighter)
	_log_r6(&"floor", [&"step_crunch"])
	_log_r7(&"step_crack", [&"step_crunch"], [db])

## The pursuit spike's floor impact (B's shockwave with no knockdown radius;
## a heavy landing's shockwave is the landing's): a big floor boom, the heavy
## crumble and a low thump. The spiker (the player) owns it.
## Round 9: the blast radius sets the heft (FXRules.spike_heft): a wider blast
## (a charged axe kick) booms louder and deeper.
func _on_shockwave(fighter: Node3D, position: Vector3, stumble_radius: float, knockdown_radius: float) -> void:
	if not FXRules.is_spike_shockwave(knockdown_radius):
		return
	var src: Node3D = fighter if is_instance_valid(fighter) else null
	var heft := FXRules.spike_heft(stumble_radius)
	var db := R7_SPIKE_BOOM_DB + R9_SPIKE_HEFT_DB * (heft - 1.0)
	var low := pow(heft, -R9_SPIKE_HEFT_PITCH)
	_play_fresh(&"boom", position, db, R7_SPIKE_BOOM_PITCH * low, src)
	_play_fresh(&"land_heavy", position, 0.0, 0.95 * low, src)
	_play_fresh(&"thump_low", position, R9_SPIKE_HEFT_DB * 0.5 * (heft - 1.0), 0.9 * low, src)
	_log_r7(&"spike", [&"boom", &"land_heavy", &"thump_low"], [db, 0.0, R9_SPIKE_HEFT_DB * 0.5 * (heft - 1.0)])

## Footstep crack at speed: a small gritty crunch of the floor giving underfoot.
func _make_step_crunch(s: _Synth) -> void:
	s.crackle(0.0, 0.16, 0.9, 2600.0, 0.05, 5200.0)
	s.noise_burst(0.0, 0.06, 0.6, s.rr(3500.0, 4500.0), 1500.0, 600.0, 0.0004, 0.014)
	s.tone(0.0, 0.1, s.rr(150.0, 190.0), 90.0, 0.015, 0.5, 0.0006, 0.02)
	s.knocks(0.02, 0.1, 2, 900.0, 1500.0, 0.2, 0.01)
	s.drive(1.6)


# =============================================================================
# Round 8: Charge and pressure (docs/Round 8 — Charge and Pressure.md). Every
# handler listens to GameEvents and plays on the event's physics frame:
# - charge_started: the hum (a seamless loop) fades in; its pitch and level
#   follow the charge amount c (hum_pitch_for; c from
#   CombatController.get_charge(), FXRules.charge_amount). charge_level_changed:
#   a short tick per step, higher per step. charge_full: a bright ping; the hum
#   sits at its top pitch and throbs. charge_released: the release whoosh,
#   louder, longer and deeper with c (it is the charged strike's swing).
#   charge_cancelled: the hum stops and the charge fizzles out.
# - Hits: a tap is a quick crack (its weight, 0.2 to 0.3, plays the crack layer
#   alone); a charged hit lifts every layer by c and adds the charged crunch; a
#   hit on a broken enemy adds the heavy broken accent; a hit (landed or
#   blocked) that adds pressure ticks softly, higher as the meter fills.
# - pressure_broken: the guard break, unlike any hit: a glass shatter, a
#   descending power-down tone, a ringing inharmonic clang and a sub boom (well
#   over a second long). A quiet woozy loop plays on the broken enemy until
#   pressure_recovered.
# - air_follow_started: a rising whoosh and a rush. air_hit: a punchy pop,
#   higher with every hit of the combo.
# =============================================================================

const R8_TICK_DB := -2.0             ## the first step's tick...
const R8_TICK_STEP_DB := 1.5         ## ...this much louder per further step
const R8_TICK_PITCH_STEP := 0.12     ## ...and this much higher
const R8_FULL_DB := 0.0
const R8_HUM_FULL_DB := 1.5          ## the hum at full sits this much over its c = 1 level...
const R8_HUM_FULL_THROB_DB := 4.0    ## ...and throbs down by up to this...
const R8_HUM_FULL_THROB_HZ := 8.0    ## ...this fast
## Release whoosh (charge_release) at c = 0 .. 1; the long charged whoosh layers
## under it from R8_RELEASE_HEAVY_FROM (dB from there .. c = 1).
const R8_RELEASE_DB := Vector2(-6.0, 2.5)
const R8_RELEASE_PITCH := Vector2(1.2, 0.85)
const R8_RELEASE_HEAVY_FROM := 0.4
const R8_RELEASE_HEAVY_DB := Vector2(-6.0, 1.0)
## A strike_started this soon after the attacker's release is the released
## strike (after its glide): its swing whoosh already played (ms).
const R8_RELEASE_COVER_MS := 900
const R8_FIZZLE_DB := 0.0
## Charged hits: every layer + R8_CHARGE_DB x c dB and pitch x lerp(1, R8_CHARGE_PITCH, c);
## the charged crunch at c = 0 .. 1.
const R8_CHARGE_DB := 3.0
const R8_CHARGE_PITCH := 0.9
const R8_CHARGED_DB := Vector2(-8.0, 1.0)
const R8_CHARGED_PITCH := Vector2(1.1, 0.88)
const R8_BROKEN_DB := 0.0
## Pressure tick: dB and pitch from an empty meter to a nearly full one.
const R8_PRESSURE_DB := Vector2(-3.0, 1.0)
const R8_PRESSURE_PITCH := Vector2(0.9, 1.5)
const R8_BREAK_DB := 0.0
const R8_DAZED_POOL := 3
const R8_DAZED_DB := 0.0              ## the loop's level (over BASE_DB) once faded in
const R8_DAZED_FADE := 14.0           ## dB per s in...
const R8_DAZED_FADE_OUT := 150.0      ## ...and out (gone in 0.2 s)
const R8_DAZED_SLACK := 1.0           ## s past R8_BREAK_TIME before a loop with no pressure_recovered stops
## Air combo.
const R8_AIR_FOLLOW_DB := Vector2(2.0, -3.0)  ## whoosh_up, rush
const R8_AIR_POP_DB := 0.0
const R8_AIR_POP_PITCH_STEP := 0.09   ## pitch x (1 + this x (count - 1))
const R8_AIR_POP_PITCH_MAX := 1.7
const R8_AIR_PAST_CAP_DB := -3.0      ## past debug_air_hits (no hang) the pop is a little quieter

## Every Round 8 sound group played: {frame (physics), event, ids, db, pitch, c} (tests, newest last).
var round8_sounds: Array[Dictionary] = []
var _release_pending: Dictionary = {}      ## fighter id -> clock ms of its release (strike_started stands down)
var _daze_players: Array[AudioStreamPlayer3D] = []
var _daze_fighter: Array = []
var _daze_start := PackedInt32Array()      ## clock ms
var _daze_db := PackedFloat32Array()
var _daze_out: Array[bool] = []            ## fading out
var _daze_seen: Array[bool] = []           ## is_broken() was seen true
var _daze_id: Array[StringName] = []       ## the loop each slot plays (dazed or guard_crackle)
## Round 9: the break dazes (the Round 8 dazed loop) instead of crackling on the
## guard. Tuning.R9_BROKEN_STUN; tests may flip it.
var broken_stun: bool = Tuning.R9_BROKEN_STUN
var _r8_connected := false

func _connect_round8() -> void:
	if _r8_connected:
		return
	_r8_connected = true
	for i in R8_DAZED_POOL:
		var h := AudioStreamPlayer3D.new()
		h.name = "Dazed_%d" % i
		h.unit_size = 5.0
		h.max_distance = 40.0
		h.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
		h.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		h.bus = WORLD_BUS
		add_child(h)
		_daze_players.append(h)
		_daze_fighter.append(null)
		_daze_out.append(false)
		_daze_seen.append(false)
		_daze_id.append(&"dazed")
	_daze_start.resize(R8_DAZED_POOL)
	_daze_db.resize(R8_DAZED_POOL)
	GameEvents.charge_full.connect(_on_charge_full)
	GameEvents.charge_cancelled.connect(_on_charge_cancelled)
	GameEvents.pressure_broken.connect(_on_pressure_broken)
	GameEvents.pressure_recovered.connect(_on_pressure_recovered)
	GameEvents.air_follow_started.connect(_on_air_follow_started)
	GameEvents.air_hit.connect(_on_air_hit)
	GameEvents.fighter_died.connect(func(f: Node3D, _i: HitInfo) -> void: _stop_dazed(f, true))
	GameEvents.round_started.connect(func(_m: StringName) -> void: _release_pending.clear())

func _log_r8(event: StringName, ids: Array, dbs: Array, pitches: Array, c := -1.0) -> void:
	round8_sounds.append({"frame": Engine.get_physics_frames(), "event": event, "ids": ids, "db": dbs,
		"pitch": pitches, "c": c})
	if round8_sounds.size() > 64:
		round8_sounds.pop_front()

## Full charge: a bright ping; the hum goes to its top and throbs.
func _on_charge_full(fighter: Node3D, _move_id: StringName) -> void:
	if not is_instance_valid(fighter):
		return
	var slot := _hum_slot(fighter)
	if slot >= 0:
		_hum_full[slot] = true
		_hum_c[slot] = 1.0
	_play_fresh(&"charge_full", _pos_of(fighter), R8_FULL_DB, 1.0, fighter)
	_log_r8(&"charge_full", [&"charge_full"], [R8_FULL_DB], [1.0], 1.0)

## A charge that ended without a strike: the hum stops and it fizzles out.
func _on_charge_cancelled(fighter: Node3D, _move_id: StringName, reason: StringName) -> void:
	if not is_instance_valid(fighter):
		return
	var c := release_charge(fighter)
	_stop_hum_of(fighter)
	var pitch := lerpf(1.1, 0.9, c)
	_play_fresh(&"charge_fizzle", _pos_of(fighter), R8_FIZZLE_DB, pitch, fighter)
	_log_r8(StringName("charge_cancelled_" + String(reason)), [&"charge_fizzle"], [R8_FIZZLE_DB], [pitch], c)

## A hit that added pressure: a soft glassy tick, higher as the meter fills.
func _pressure_tick(info: HitInfo) -> void:
	var p := FXRules.pressure_fraction(info.victim)
	var db := lerpf(R8_PRESSURE_DB.x, R8_PRESSURE_DB.y, p)
	var pitch := lerpf(R8_PRESSURE_PITCH.x, R8_PRESSURE_PITCH.y, p)
	_play_fresh(&"pressure_tick", _hit_point(info), db, pitch, info.attacker)
	_log_r8(&"pressure_tick", [&"pressure_tick"], [db], [pitch], p)

## The guard break on the guard, then the broken loop on the enemy (Round 9:
## the guard crackle; the dazed loop when broken_stun). The attacker (the
## player) owns the break sound: it keeps its pitch in slow motion.
func _on_pressure_broken(fighter: Node3D, attacker: Node3D) -> void:
	if not is_instance_valid(fighter):
		return
	var at := FXRules.guard_point(fighter)
	_play_fresh(&"guard_break", at, R8_BREAK_DB, 1.0, attacker if is_instance_valid(attacker) else null)
	var loop := _start_dazed(fighter)
	_log_r8(&"pressure_broken", [&"guard_break", loop], [R8_BREAK_DB, R8_DAZED_DB], [1.0, 1.0])

func _on_pressure_recovered(fighter: Node3D) -> void:
	_stop_dazed(fighter, false)

## The launcher jump: a rising whoosh and a rush of air.
func _on_air_follow_started(fighter: Node3D, _target: Node3D) -> void:
	if not is_instance_valid(fighter):
		return
	_play_fresh(&"whoosh_up", _pos_of(fighter), R8_AIR_FOLLOW_DB.x, 0.95, fighter)
	_play_fresh(&"rush", _pos_of(fighter), R8_AIR_FOLLOW_DB.y, 1.1, fighter)
	_log_r8(&"air_follow_started", [&"whoosh_up", &"rush"], [R8_AIR_FOLLOW_DB.x, R8_AIR_FOLLOW_DB.y], [0.95, 1.1])

## An air hit: a punchy pop on top of the hit, higher with the count.
func _on_air_hit(attacker: Node3D, victim: Node3D, count: int) -> void:
	if not is_instance_valid(victim):
		return
	var pitch := air_pop_pitch(count)
	var db := R8_AIR_POP_DB + (R8_AIR_PAST_CAP_DB if count > Tuning.debug_air_hits else 0.0)
	_play_fresh(&"air_pop", FXRules.upper_body(victim), db, pitch, attacker)
	_log_r8(&"air_hit", [&"air_pop"], [db], [pitch], float(count))

## The air pop's pitch for the count-th air hit of a combo (rising).
static func air_pop_pitch(count: int) -> float:
	return minf(1.0 + R8_AIR_POP_PITCH_STEP * maxi(count - 1, 0), R8_AIR_POP_PITCH_MAX)

# --- The dazed loop ---------------------------------------------------------------------

## True while `fighter`'s dazed loop plays (tests).
func is_dazed_playing(fighter: Node3D) -> bool:
	return is_broken_loop_playing(fighter) and broken_loop_id(fighter) == &"dazed"

## True while `fighter`'s broken loop (either kind) plays (tests).
func is_broken_loop_playing(fighter: Node3D) -> bool:
	var i := _daze_slot(fighter)
	return i >= 0 and not _daze_out[i] and _daze_players[i].playing

## The broken loop `fighter` plays (&"guard_crackle" or &"dazed"), or &"".
func broken_loop_id(fighter: Node3D) -> StringName:
	var i := _daze_slot(fighter)
	return _daze_id[i] if i >= 0 else &""

## Broken loops playing, either kind (tests, debug).
func active_dazed() -> int:
	var n := 0
	for i in _daze_fighter.size():
		if _daze_fighter[i] != null:
			n += 1
	return n

func _daze_slot(fighter: Node3D) -> int:
	if not is_instance_valid(fighter):
		return -1
	for i in _daze_fighter.size():
		if _daze_fighter[i] != null and _daze_fighter[i] == fighter:
			return i
	return -1

## Starts the broken loop on `fighter`; returns its id (&"" when none).
func _start_dazed(fighter: Node3D) -> StringName:
	if _quitting or _daze_players.is_empty():
		return &""
	var slot := _daze_slot(fighter)
	if slot < 0:
		var oldest := 0
		for i in _daze_fighter.size():
			if _daze_fighter[i] == null:
				slot = i
				break
			if _daze_start[i] < _daze_start[oldest]:
				oldest = i
		if slot < 0:
			slot = oldest
	var id: StringName = &"dazed" if broken_stun else &"guard_crackle"
	var stream := _pick_loop(id)
	if stream == null:
		return &""
	var h := _daze_players[slot]
	_daze_fighter[slot] = fighter
	_daze_id[slot] = id
	_daze_start[slot] = clock_ms()
	_daze_out[slot] = false
	_daze_seen[slot] = false
	_daze_db[slot] = R8_DAZED_DB - 18.0  # fades in
	h.stream = stream
	h.global_position = _broken_loop_pos(slot)
	h.volume_db = BASE_DB[id] + _daze_db[slot]
	h.pitch_scale = _rng.randf_range(0.95, 1.05)
	h.play()
	_used = true
	sound_played.emit(id, h.global_position)
	return id

## Where a broken loop sits: the head (dazed) or the guard (guard crackle).
func _broken_loop_pos(i: int) -> Vector3:
	var f: Node3D = _daze_fighter[i]
	return FXRules.head_of(f) if _daze_id[i] == &"dazed" else FXRules.guard_point(f)

func _stop_dazed(fighter: Node3D, at_once: bool) -> void:
	var i := _daze_slot(fighter)
	if i < 0:
		return
	if at_once:
		_free_dazed(i)
	else:
		_daze_out[i] = true

func _free_dazed(i: int) -> void:
	_daze_players[i].stop()
	_daze_fighter[i] = null
	_daze_out[i] = false

func _update_dazed(delta: float) -> void:
	for i in _daze_fighter.size():
		var f = _daze_fighter[i]
		if f == null:
			continue
		if not is_instance_valid(f) or not (f as Node3D).is_inside_tree() \
				or ((f as Node).has_method(&"is_dead") and f.call(&"is_dead")):
			_free_dazed(i)
			continue
		if not _daze_out[i]:
			var broken := FXRules.combat_flag(f, &"is_broken")
			if broken == 1:
				_daze_seen[i] = true
			if (clock_ms() - _daze_start[i]) * 0.001 > Tuning.R8_BREAK_TIME + R8_DAZED_SLACK \
					or (broken == 0 and _daze_seen[i]):
				_daze_out[i] = true
		var goal := R8_DAZED_DB - 30.0 if _daze_out[i] else R8_DAZED_DB
		_daze_db[i] = move_toward(_daze_db[i], goal, (R8_DAZED_FADE_OUT if _daze_out[i] else R8_DAZED_FADE) * delta)
		if _daze_out[i] and _daze_db[i] <= goal + 0.01:
			_free_dazed(i)
			continue
		var h := _daze_players[i]
		h.global_position = _broken_loop_pos(i)
		h.volume_db = BASE_DB[_daze_id[i]] + _daze_db[i]

# --- Round 8 sound designs ---------------------------------------------------------------

## Charge step: a short dry tick, a click with a small ping (under 0.1 s).
func _make_charge_tick(s: _Synth) -> void:
	var f := s.rr(1650.0, 1800.0)
	s.noise_burst(0.0, 0.025, 0.7, 7000.0, 5000.0, 2500.0, 0.0002, 0.004)
	s.tone(0.0, 0.07, f, f, 1.0, 0.6, 0.0004, 0.014)
	s.tone(0.0, 0.05, f * 2.0, f * 2.0, 1.0, 0.2, 0.0004, 0.008)

## Full charge: a bright bell ping with a rising sparkle and a shimmer tail.
func _make_charge_full(s: _Synth) -> void:
	var f := s.rr(1280.0, 1360.0)
	s.modal(0.0, 0.8, f, [1.0, 2.0, 3.01, 4.17], [1.0, 0.55, 0.3, 0.18], [0.32, 0.2, 0.12, 0.08], 0.6)
	s.tone(0.0, 0.25, f * 0.5, f * 1.5, 0.06, 0.35, 0.002, 0.08)
	s.tone(0.0, 0.7, f * 2.0, f * 2.02, 1.0, 0.15, 0.003, 0.25)
	s.noise_burst(0.0, 0.2, 0.25, 10000.0, 7000.0, 5000.0, 0.001, 0.05)

## Fizzle: a falling, sputtering tone with a dry hiss and crackle.
func _make_charge_fizzle(s: _Synth) -> void:
	s.tone(0.0, 0.45, s.rr(560.0, 620.0), 140.0, 0.15, 0.55, 0.002, 0.16, 1, 23.0, 0.06)
	s.crackle(0.0, 0.4, 0.45, 900.0, 0.15, 5000.0)
	s.noise_burst(0.0, 0.42, 0.35, 5000.0, 900.0, 600.0, 0.004, 0.14)
	s.lowpass(7000.0)

## Charged crunch (a charged hit's accent): a deep compressed boom with a bony crunch.
func _make_hit_charged(s: _Synth) -> void:
	var f := s.rr(70.0, 80.0)
	s.tone(0.0, 0.6, f * 1.6, f * 0.5, 0.05, 1.0, 0.001, 0.15)
	s.noise_burst(0.0, 0.35, 0.7, 1200.0, 200.0, 0.0, 0.001, 0.08)
	s.crackle(0.002, 0.14, 0.6, 1400.0, 0.05, 4200.0)
	s.noise_burst(0.0, 0.03, 0.6, 8000.0, 4000.0, 2000.0, 0.0002, 0.006)
	s.drive(2.4)

## Broken accent (a hit on a broken enemy): a very low slam, a crack, and a
## short glassy splinter that echoes the guard break.
func _make_hit_broken(s: _Synth) -> void:
	var f := s.rr(52.0, 58.0)
	s.tone(0.0, 0.8, f * 1.8, f * 0.6, 0.06, 1.0, 0.001, 0.2)
	s.noise_burst(0.0, 0.05, 0.8, 9000.0, 5000.0, 2500.0, 0.0002, 0.008)
	s.noise_burst(0.0, 0.4, 0.5, 900.0, 160.0, 0.0, 0.002, 0.1)
	s.modal(0.01, 0.35, s.rr(2300.0, 2500.0), [1.0, 1.53, 2.31], [0.5, 0.35, 0.2], [0.09, 0.06, 0.04], 0.35)
	s.crackle(0.005, 0.12, 0.35, 2000.0, 0.04, 8000.0)
	s.drive(2.0)

## Guard break: unlike any hit. A glass shatter (dense bright crackle and a
## hissing burst), a descending power-down tone, a ringing inharmonic clang and
## a sub boom with a long tail (about 1.5 s; hits die in well under a second).
func _make_guard_break(s: _Synth) -> void:
	s.noise_burst(0.0, 0.03, 1.0, 12000.0, 8000.0, 4000.0, 0.0002, 0.005)
	s.crackle(0.0, 0.55, 0.8, 3200.0, 0.14, 9500.0)
	s.noise_burst(0.0, 0.5, 0.5, 11000.0, 5000.0, 3000.0, 0.001, 0.12)
	var f := s.rr(1020.0, 1080.0)
	s.modal(0.0, 1.4, f, [1.0, 1.48, 2.17, 2.93, 3.83], [1.0, 0.8, 0.55, 0.35, 0.22],
			[0.5, 0.38, 0.26, 0.18, 0.12], 0.45)
	s.tone(0.02, 1.0, 520.0, 95.0, 0.3, 0.55, 0.004, 0.4, 2)
	var b := s.rr(48.0, 54.0)
	s.tone(0.0, 1.5, b * 1.4, b * 0.6, 0.2, 0.9, 0.003, 0.45)
	s.noise_burst(0.0, 1.1, 0.4, 260.0, 70.0, 0.0, 0.01, 0.35)
	s.drive(1.6)

## Pressure tick: a soft glassy tink (subtle; it rises in pitch as the meter fills).
func _make_pressure_tick(s: _Synth) -> void:
	var f := s.rr(2500.0, 2700.0)
	s.modal(0.0, 0.16, f, [1.0, 2.76], [1.0, 0.4], [0.035, 0.02], 0.6)
	s.noise_burst(0.0, 0.02, 0.2, 9000.0, 6000.0, 3500.0, 0.0002, 0.004)

## Air pop: a punchy, airy pop: a fast-falling knock, a click and a short fwip.
func _make_air_pop(s: _Synth) -> void:
	var f := s.rr(300.0, 340.0)
	s.tone(0.0, 0.16, f, f * 0.4, 0.012, 1.0, 0.0004, 0.04)
	s.noise_burst(0.0, 0.03, 0.6, 6500.0, 3500.0, 1500.0, 0.0002, 0.006)
	s.swoosh(0.0, 0.14, 0.45, 1500.0, 5200.0, 3000.0, 0.3)
	s.drive(1.8)

## Dazed: a quiet, woozy 1 s seamless loop: three soft chimes twinkling in turn
## with a slow pitch wobble (every partial and modulator completes whole cycles
## in the loop).
func _make_dazed(s: _Synth) -> void:
	var n := int(1.0 * _Synth.SR)
	s.buf.resize(n)
	var fs := [880.0, 1320.0, 1760.0]
	var ph := [s.rand(), s.rand(), s.rand()]
	for k in n:
		var t := k / _Synth.SR
		var v := 0.0
		for j in 3:
			# Phase modulation by a 2 Hz wobble (whole cycles: seamless).
			var p: float = TAU * (float(fs[j]) * t + float(ph[j])) + 0.9 * sin(TAU * 2.0 * t + j)
			var tw := pow(0.5 + 0.5 * sin(TAU * 3.0 * t + j * TAU / 3.0), 3.0)
			v += sin(p) * tw * (0.5 if j == 0 else 0.3)
		s.buf[k] = v * (0.8 + 0.2 * sin(TAU * 1.0 * t))


# --- Round 9 sound designs ---------------------------------------------------------------

## Guard crackle: a quiet 1 s seamless loop of a cracked guard. Sparse electric
## snaps (short bright noise ticks with a high ping) over a faint 100 Hz buzz
## that flickers 6 times a second (whole cycles in the loop; no tick spans the
## loop point).
func _make_guard_crackle(s: _Synth) -> void:
	var n := int(1.0 * _Synth.SR)
	s.buf.resize(n)
	for k in n:
		var t := k / _Synth.SR
		var flick := pow(0.5 + 0.5 * sin(TAU * 6.0 * t + 0.7 * sin(TAU * 2.0 * t)), 4.0)
		s.buf[k] = tanh(2.5 * sin(TAU * 100.0 * t)) * 0.06 * (0.3 + 0.7 * flick)
	var a := 1.0 - exp(-TAU * 9000.0 / _Synth.SR)
	var hp := 1.0 - exp(-TAU * 2500.0 / _Synth.SR)
	var snaps := 16
	for _c in snaps:
		var t0 := s.rr(0.01, 0.95)
		var dur := s.rr(0.003, 0.012)
		var amp := s.rr(0.35, 1.0)
		var ping := s.rr(3200.0, 5200.0)
		var i0 := int(t0 * _Synth.SR)
		var m := int(dur * _Synth.SR)
		var lp := 0.0
		var lo := 0.0
		for j in m:
			var env := exp(-float(j) / (m * 0.3))
			lp += a * (s.noise() - lp)
			lo += hp * (lp - lo)
			s.buf[i0 + j] += ((lp - lo) * 1.4 + 0.3 * sin(TAU * ping * j / _Synth.SR)) * env * amp

## Axe crack: the heel chopping down. A hard broadband snap, a splintering
## crackle, a bright heel click and a fast-falling chop thunk (under 0.3 s).
func _make_axe_crack(s: _Synth) -> void:
	s.noise_burst(0.0, 0.03, 1.0, 14000.0, 9000.0, 2500.0, 0.0001, 0.004)
	s.crackle(0.002, 0.07, 0.6, 2600.0, 0.025, 9000.0)
	s.tone(0.0, 0.07, s.rr(1900.0, 2100.0), s.rr(950.0, 1050.0), 0.012, 0.35, 0.0002, 0.012)
	var f := s.rr(120.0, 135.0)
	s.tone(0.0, 0.28, f * 2.4, f * 0.55, 0.018, 0.95, 0.0005, 0.06)
	s.noise_burst(0.0, 0.12, 0.5, 2200.0, 300.0, 0.0, 0.0005, 0.03)
	s.drive(2.3)
