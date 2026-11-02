class_name LabDummy
extends CharacterBody3D
## Minimal fighter host for the ragdoll lab and rig tests: a capsule
## ("Capsule" child, as the Fighter contract requires) with HumanoidRig,
## PoseAnimator and RagdollController, without agent B's Fighter.
## OWNER: agent A.

var archetype: StringName = &"player"
var rig: HumanoidRig
var ragdoll: RagdollController
var animator: PoseAnimator
var profile: RagdollProfile
var active_muscles := true
## World XZ movement intent, 0..1 (lab keys / tests).
var move_input := Vector3.ZERO
var walk_speed := Tuning.WALK_SPEED
## &"stand" or &"crouch" (lab key C); &"air" is set while jumping.
var stance: StringName = &"stand"
var _airborne := false
var _freeze_until := 0.0  ## TimeDirector.now() time the hitstop ends (as Fighter)

## Hitstop as the Fighter does it (TimeDirector.hitstop() calls this): the
## animation stops; the RagdollController sees is_frozen() and holds its bodies.
func freeze_hitstop(duration_real: float) -> void:
	if duration_real <= 0.0:
		return
	_freeze_until = maxf(_freeze_until, TimeDirector.now() + duration_real)
	if animator:
		animator.time_scale = 0.0

func is_frozen() -> bool:
	return TimeDirector.now() < _freeze_until

func get_actor_time() -> float:
	return 0.0 if is_frozen() else 1.0

## Lab jump (Tuning.JUMP_APEX with Tuning.GRAVITY).
func jump() -> void:
	if ragdoll and not ragdoll.is_simulating() and is_on_floor():
		velocity.y = sqrt(2.0 * Tuning.GRAVITY * Tuning.JUMP_APEX)
		_airborne = true

## Call before add_child().
func setup(p_archetype: StringName, p_profile: RagdollProfile = null, p_active := true) -> void:
	archetype = p_archetype
	profile = p_profile
	active_muscles = p_active

func _ready() -> void:
	var cfg: Dictionary = Tuning.ARCHETYPES.get(archetype, Tuning.ARCHETYPES[&"player"])
	var app: Dictionary = cfg["appearance"]
	var h := float(app.get("height", 1.0))
	var w := float(app.get("width", 1.0))
	collision_layer = Layers.CAPSULE
	collision_mask = Layers.MASK_CAPSULE
	var cap := CollisionShape3D.new()
	cap.name = "Capsule"
	var cs := CapsuleShape3D.new()
	cs.radius = 0.3 * w
	cs.height = 1.8 * h
	cap.shape = cs
	cap.position = Vector3(0, 0.9 * h, 0)
	add_child(cap)
	rig = HumanoidRig.new()
	rig.name = "Rig"
	add_child(rig)
	rig.build(app, float(cfg["mass"]))
	animator = PoseAnimator.new()
	animator.name = "PoseAnimator"
	add_child(animator)
	animator.setup(rig)
	ragdoll = RagdollController.new()
	ragdoll.name = "RagdollController"
	ragdoll.profile = profile
	add_child(ragdoll)
	ragdoll.setup(self, rig, animator, active_muscles)

func _physics_process(delta: float) -> void:
	if _freeze_until > 0.0 and not is_frozen():
		_freeze_until = 0.0
		if animator:
			animator.time_scale = 1.0
	if ragdoll == null or ragdoll.is_simulating() or is_frozen():
		return
	if ragdoll.state == RagdollController.State.GETUP:
		velocity = Vector3.ZERO
		return
	var speed := walk_speed * (Tuning.CROUCH_SPEED if stance == &"crouch" else 1.0)
	var v := move_input.limit_length(1.0) * speed
	velocity.x = v.x
	velocity.z = v.z
	if _airborne or not is_on_floor():
		velocity.y -= Tuning.GRAVITY * delta
	else:
		velocity.y = -0.5
	move_and_slide()
	if _airborne and is_on_floor() and velocity.y <= 0.0:
		_airborne = false
		animator.play_move(&"land", 0.0, Tuning.frames(Tuning.JUMP_LAND_FRAMES), 0.12)
	animator.set_stance(&"air" if _airborne else stance, velocity.y if _airborne else NAN)
	if v.length() > 0.1:
		var target := Basis.looking_at(Vector3(v.x, 0, v.z).normalized(), Vector3.UP)
		global_basis = global_basis.slerp(target, clampf(Tuning.TURN_SPEED * delta, 0.0, 1.0)).orthonormalized()
	animator.set_locomotion(global_basis.inverse() * velocity, walk_speed)
