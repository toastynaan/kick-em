extends Node3D
## Round 2 FX: per-surface break sounds on wall_broken, a meaty crack on
## wall_cracked, debris_landed throttling (burst cap, refill, per-chunk gap,
## minimum speed), the dodge_feedback miss tick, the clank id, the armor spark
## on armor_absorbed, and concrete dust + chips on hard concrete body impacts.
## OWNER: agent F.

const U := preload("res://tests/fx/fx_test_util.gd")
const FakePanel := preload("res://tests/fx/fx_fake_panel.gd")

var played: Array[StringName] = []

func _ready() -> void:
	var errlog := U.ErrorLogger.new()
	OS.add_logger(errlog)
	var fails: Array[String] = []
	BloodFX.reset()
	U.make_floor(self)
	if not await U.wait_audio(get_tree()):
		fails.append("AudioFX never finished synthesising")
	AudioFX.sound_played.connect(func(id: StringName, _p: Vector3) -> void: played.append(id))

	# Every round-2 id exists.
	for id in [&"clank", &"break_drywall", &"break_brick", &"break_wood", &"debris", &"miss"]:
		if not AudioFX.get_ids().has(id):
			fails.append("missing sound id %s" % id)

	# wall_broken picks the break sound from the panel's surface.
	var expect := {&"drywall": &"break_drywall", &"brick": &"break_brick", &"wood": &"break_wood",
		&"concrete": &"wall_break"}
	for surf: StringName in expect:
		var panel := FakePanel.new()
		panel.surface = surf
		add_child(panel)
		await U.physics_frames(get_tree(), 6)  # past the 25 ms same-id retrigger guard
		played.clear()
		GameEvents.wall_broken.emit(panel, Vector3(0, 1, -2), 4000.0, Vector3(0, 0, -9))
		if not played.has(expect[surf]):
			fails.append("%s break played %s, want %s" % [surf, played, expect[surf]])
		panel.queue_free()
	await U.physics_frames(get_tree(), 6)
	played.clear()
	GameEvents.wall_broken.emit(null, Vector3(0, 1, -2), 4000.0, Vector3.ZERO)
	if not played.has(&"wall_break"):
		fails.append("null wall did not fall back to wall_break")
	played.clear()
	GameEvents.wall_cracked.emit(null, Vector3(0, 1, -2), 3000.0)
	if not played.has(&"crack"):
		fails.append("wall_cracked played %s" % [played])

	# debris_landed: 40 chunks in one tick -> at most the burst.
	await U.physics_frames(get_tree(), 120)  # refill the bucket
	var chunks: Array[RigidBody3D] = []
	for i in 40:
		var c := RigidBody3D.new()
		c.mass = 0.5 + i * 0.1
		c.freeze = true
		add_child(c)
		chunks.append(c)
	played.clear()
	for c in chunks:
		GameEvents.debris_landed.emit(c, Vector3(0, 0, 0), 5.0, &"brick")
	var burst := played.count(&"debris")
	print("debris: %d of 40 in one tick (burst %d)" % [burst, int(AudioFX.DEBRIS_BURST)])
	if burst < 1 or burst > int(AudioFX.DEBRIS_BURST):
		fails.append("debris burst %d, want 1..%d" % [burst, int(AudioFX.DEBRIS_BURST)])
	# Over one second of ticks, the rate allows about DEBRIS_RATE more.
	played.clear()
	for t in 120:
		GameEvents.debris_landed.emit(chunks[t % 40], Vector3(0, 0, 0), 5.0, &"brick")
		await get_tree().physics_frame
	var per_sec := played.count(&"debris")
	print("debris: %d in 1 s of steady landings (rate %.0f/s)" % [per_sec, AudioFX.DEBRIS_RATE])
	if per_sec < int(AudioFX.DEBRIS_RATE) - 2 or per_sec > int(AudioFX.DEBRIS_RATE + AudioFX.DEBRIS_BURST) + 1:
		fails.append("debris rate %d per second" % per_sec)
	# One chunk is heard at most once per DEBRIS_BODY_GAP; slow touches are silent.
	await U.physics_frames(get_tree(), 120)
	played.clear()
	GameEvents.debris_landed.emit(chunks[0], Vector3.ZERO, 5.0, &"drywall")
	GameEvents.debris_landed.emit(chunks[0], Vector3.ZERO, 5.0, &"drywall")
	GameEvents.debris_landed.emit(chunks[1], Vector3.ZERO, 0.5, &"drywall")
	if played.count(&"debris") != 1:
		fails.append("per-chunk gap / min speed: %d plays, want 1" % played.count(&"debris"))

	# dodge_feedback -> miss tick (early and late, a few ticks apart).
	played.clear()
	GameEvents.dodge_feedback.emit(null, &"early")
	await U.physics_frames(get_tree(), 6)
	GameEvents.dodge_feedback.emit(null, &"late")
	if played.count(&"miss") != 2:
		fails.append("dodge_feedback played %d miss ticks, want 2" % played.count(&"miss"))
	if played.has(&"dodge"):
		fails.append("dodge_feedback played the perfect-dodge whoosh")

	# clank plays (agent B triggers it on armored hits).
	played.clear()
	AudioFX.play(&"clank", Vector3(0, 1, 0))
	if not played.has(&"clank"):
		fails.append("clank did not play")

	# armor_absorbed -> a small spark at the hit.
	var f := U.make_fighter(self, Vector3(0, 0, -1))
	var spark_i: int = BloodFX._spark_next
	var hit := U.hit(f, &"jab1", Vector3(0, 1.4, -0.8), Vector3(0, 0, -1), 10.0, 100.0)
	GameEvents.armor_absorbed.emit(hit)
	var sp: GPUParticles3D = BloodFX._sparks[spark_i]
	if BloodFX._spark_next == spark_i or not sp.visible or sp.global_position.distance_to(hit.hit_position) > 0.01:
		fails.append("armor_absorbed made no spark at the hit")
	elif sp.amount_ratio >= 1.0:
		fails.append("armor spark not smaller than a block spark")

	# Concrete: hard body hits kick up dust and chips; soft ones do not.
	var dust_i: int = BloodFX._dust_next
	GameEvents.body_impact.emit(f, Vector3(0, 1.0, -3.0), Vector3(0, 0, 1), 1500.0, &"concrete")
	if BloodFX._dust_next != dust_i:
		fails.append("concrete dust below the energy threshold")
	GameEvents.body_impact.emit(f, Vector3(0, 1.0, -3.0), Vector3(0, 0, 1), 4000.0, &"concrete")
	var puff: GPUParticles3D = BloodFX._puffs[dust_i]
	var chips: GPUParticles3D = BloodFX._chips[dust_i]
	if BloodFX._dust_next == dust_i or not puff.visible or not chips.visible \
			or puff.global_position.distance_to(Vector3(0, 1.0, -3.0)) > 0.1:
		fails.append("no concrete dust and chips at the contact point")
	U.finish(get_tree(), "test_round2_fx", fails, errlog)
