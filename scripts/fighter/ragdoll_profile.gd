class_name RagdollProfile
extends Resource
## All ragdoll gains in one resource with presets (spec: "build it realistic;
## wacky is then just different numbers"). OWNER: agent A. Extend freely.
##
## Torque gains are per unit of joint inertia: each joint's torque is
## I_joint * (gain * error), where I_joint is the reduced inertia of the
## joint's two bodies about it, per axis (HumanoidRig.get_joint_inertia). So
## kp is a squared natural frequency (1/s^2) and kd / damping are rates (1/s);
## the same numbers behave the same on a 65 kg Duelist and a 140 kg Brute, and
## damping is explicit-stable while kd * dt < 1 (kd < 120 at 120 Hz).
##
## Per-bone torque (spec): tau = s*(kp*(theta_anim - theta) - kd*omega)
##   + kn*(theta_neutral - theta) - c(theta)*omega, plus a spring back inside
## the soft-limit zone.

@export var muscle_kp := 150.0       ## Pull toward the animated pose (scaled by tone).
@export var muscle_kd := 14.0
@export var neutral_kn := 25.0       ## Neutral-posture tension.
@export var soft_limit_damping := 40.0  ## c(theta) max near the joint limits.
@export var soft_limit_zone := 0.2   ## Last fraction of the range where damping ramps up.
@export var max_torque := 400.0      ## Clamp per bone (Jolt explodes on big springs).
@export var limb_spin := 6.0         ## rad/s of V1 limb spin on launch.
@export var limb_spin_random := 0.25

@export_group("Extra (agent A)")
@export var use_soft_limits := true
@export var use_neutral := true
@export var use_muscles := true
@export var neutral_kd := 2.0        ## Small damping on the neutral spring (1/s).
@export var soft_limit_spring := 300.0  ## Spring back inside the soft-limit zone (1/s^2 per rad).
@export var body_angular_damp := 0.8 ## PhysicalBone3D angular damp (replace mode).
@export var launch_tone := 0.25      ## Muscle tone while LAUNCHED (falling loop target): "very low".
@export var flinch_tone := 3.0       ## Legacy name of chain_tone (kept for old callers).
## Round 5: tone of a bone at full muscle strength in a partial ragdoll (a
## chain bone at strength s gets s * chain_tone). With muscle_kp 150 and
## muscle_kd 14 this is critically damped (snaps back without wobble).
@export var chain_tone := 3.0
@export var knockdown_tone := 0.12   ## Round 5: upper-body tone in a knockdown ("low"; the legs go to 0 and buckle).
@export var held_torso_tone := 0.45  ## Round 5: spine/chest/head tone of a live body held by a grabber.
@export var held_limb_tone := 0.12   ## Round 5: legs and free arm of a live held body (they dangle and swing).
## Round 5: extra joint damping (1/s) on a held body, so the legs swing with
## every start, stop and hop of the holder but settle in about 0.4 s instead of
## pendulum-swinging over the top (a carried body, not a flag).
@export var held_joint_damp := 6.0
@export var stagger_arm_tone := 0.12
@export var stagger_spine_tone := 0.35
@export var stagger_leg_tone := 0.8  ## Leg tone when the legs start to give (ramps to launch_tone).
@export var flinch_dv := 4.0         ## m/s nudge on a downed body's hit bone for strength 1 (x0.5).
## Round 5 flinch: the hit bone gets flinch_impulse / its mass (N s / kg = m/s),
## clamped, x strength. 22 N s: a 6 kg head snaps back about 30 degrees, a
## 16 kg chest bends about 10, a heavy's head moves less.
@export var flinch_impulse := 22.0
@export var flinch_dv_min := 1.2
@export var flinch_dv_max := 5.0
@export var stagger_dv := 2.4        ## m/s on the upper body for strength 1.
@export var hit_bone_extra := 0.3    ## Extra launch velocity fraction on the hit bone.
@export var pelvis_extra := 0.15     ## Extra launch velocity fraction on the pelvis.
@export var fall_rate_by_vy := 0.5   ## Falling loop speeds up while rising, slows while falling.

static func realistic() -> RagdollProfile:
	return RagdollProfile.new()

## Jolt hard limits only: no scripted soft limits, tension or muscles. The
## "before" side of the V1 comparison in the ragdoll lab.
static func hard_limits_only() -> RagdollProfile:
	var p := RagdollProfile.new()
	p.use_soft_limits = false
	p.use_neutral = false
	p.use_muscles = false
	p.body_angular_damp = 0.1
	p.limb_spin = 0.0
	return p

## Same model, different numbers: floppier joints, bigger limb spin.
static func wacky() -> RagdollProfile:
	var p := RagdollProfile.new()
	p.soft_limit_damping = 10.0
	p.soft_limit_spring = 80.0
	p.neutral_kn = 8.0
	p.muscle_kp = 60.0
	p.limb_spin = 14.0
	p.limb_spin_random = 0.5
	p.body_angular_damp = 0.2
	return p
