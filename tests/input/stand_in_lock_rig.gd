extends Node3D
## Test stand-in for agent E's Round 4 CameraRig lock-on (tests/input only,
## used while scripts/game/camera_rig.gd has no get_lock_target()). In group
## "camera_rig" with the same API the player side reads: get_lock_target(),
## get_soft_target(), get_camera(), get_flat_basis(), apply_manual_input().
## Locked: the camera sits behind the player on the player -> target line and
## looks at an aim point on the target's body, which apply_manual_input()
## (mouse) moves; the aim point stays at the screen centre with a shoulder
## h_offset on the camera, like the real rig's. Free: the camera keeps a yaw
## and pitch the mouse turns, orbiting a point above the player.
## OWNER: agent H (body & player input).

const DIST := 3.2          ## m behind the player
const HEIGHT := 1.7        ## m look height above the player's feet (free)
const SHOULDER := -0.45    ## m camera h_offset (the real rig shifts the view too)
const AIM_RANGE := Vector2(0.45, 0.95)  ## m the aim point may move (sideways, up/down) from the chest

var target: Fighter        ## the player
var camera: Camera3D
var lock: Fighter
var aim_offset := Vector2.ZERO  ## m: x right, y up from the locked target's chest
var _yaw := 0.0
var _pitch := -0.2

func _ready() -> void:
	add_to_group(&"camera_rig")
	process_physics_priority = -20  # place the camera before PlayerController reads it
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.top_level = true
	camera.fov = 70.0
	camera.h_offset = SHOULDER
	add_child(camera)
	camera.make_current()

func get_lock_target() -> Fighter:
	return lock if lock != null and is_instance_valid(lock) and not lock.is_dead() else null

func get_soft_target() -> Fighter:
	return get_lock_target()

func get_camera() -> Camera3D:
	return camera

func get_flat_basis() -> Basis:
	return Basis(Vector3.UP, _yaw)

## Mouse: locked, moves the aim point over the target's body; free, turns the camera.
## Positive d.y is mouse-down (screen space), as in the real rig.
func apply_manual_input(d: Vector2) -> void:
	if get_lock_target() != null:
		aim_offset.x = clampf(aim_offset.x + d.x, -AIM_RANGE.x, AIM_RANGE.x)
		aim_offset.y = clampf(aim_offset.y - d.y, -AIM_RANGE.y, AIM_RANGE.y)
	else:
		_yaw -= d.x
		_pitch = clampf(_pitch - d.y, -1.2, 0.8)

func set_lock(f: Fighter) -> void:
	lock = f
	aim_offset = Vector2.ZERO

## World aim point on the locked target's body.
func get_aim_world() -> Vector3:
	var t := get_lock_target()
	if t == null or target == null:
		return Vector3.ZERO
	var to := t.global_position - target.global_position
	to.y = 0.0
	var right := to.normalized().cross(Vector3.UP) if to.length_squared() > 1e-4 else Vector3.RIGHT
	var chest := t.rig.get_bone_global_position(Bones.CHEST) if t.rig else t.get_aim_point()
	return chest + right * aim_offset.x + Vector3.UP * aim_offset.y

func _physics_process(_delta: float) -> void:
	if target == null or not is_instance_valid(target):
		return
	var t := get_lock_target()
	if t == null:
		var look := target.global_position + Vector3.UP * HEIGHT
		var b := Basis.from_euler(Vector3(_pitch, _yaw, 0.0))
		camera.global_transform = Transform3D(b, look + b.z * DIST)
		return
	var to := t.global_position - target.global_position
	to.y = 0.0
	if to.length_squared() < 1e-4:
		return
	to = to.normalized()
	_yaw = atan2(-to.x, -to.z)
	var aim := get_aim_world()
	var base := target.global_position + Vector3.UP * HEIGHT - to * DIST
	# Keep the aim point at the screen centre: the centre ray starts at the
	# shoulder-shifted origin (get_camera_transform), so aim from there.
	var xf := Transform3D(Basis.looking_at(aim - base, Vector3.UP), base)
	for i in 3:
		var origin := base + xf.basis.x * SHOULDER
		xf.basis = Basis.looking_at(aim - origin, Vector3.UP)
	camera.global_transform = xf
