"""Bake Mixamo FBX clips onto the 16-bone HumanoidRig (Blender, headless).

    blender -b --factory-startup -P tools/bake_mixamo.py -- <out_dir> <clip_id>[@inplace]=<file.fbx> ...

Writes <out_dir>/<clip_id>.json, read by PoseLibrary.get_clip(). The FBX files
stay outside the repo (Mixamo allows use in games, not redistributing them).

Per frame (Godot character space: Y up, the character faces -Z, right is +X):
  "r":  16 local rotations (x, y, z, w) in Bones.ALL order; Hips is relative
        to the character, every other bone to its parent. The rig's rest
        rotations are identity, so these are the bone pose rotations.
  "p":  hips offset from the rig's rest hips (0, 0.95, 0), metres at height 1.
  "la" / "ra": ankle positions, "lk" / "rk": knee positions (same space).
  "lp" / "rp": foot pitch, radians (+ toes up; a raised heel is negative).

Retarget: each rig bone takes the world-space change of a Mixamo bone from
its rest (rotation now x rest^-1). Both rest poses stand upright, except the
arms (Mixamo T-pose, rig arms down), which first swing from hanging to the
Mixamo rest direction. Spine1 drives Spine, Spine2 drives Chest, Head keeps
the neck's turn (world space), the clavicles fold into the upper arms.
Positions scale by rig hips height / Mixamo rest hips height. "@inplace"
strips the hips' horizontal travel (clips with root motion, e.g. a stagger).
"""
import json
import math
import sys

import bpy
from mathutils import Matrix, Quaternion, Vector

RIG_HIPS = 0.95
RIG_ANKLE = 0.08   # rest ankle height (HumanoidRig.REST: 0.95 - 0.05 - 0.42 - 0.40)
# Rig bone -> (Mixamo bone, Mixamo bone its rest direction points to); Bones.ALL order.
MAP = [
    ("Hips", "Hips", None), ("Spine", "Spine1", None), ("Chest", "Spine2", None), ("Head", "Head", None),
    ("LeftUpperArm", "LeftArm", "LeftForeArm"), ("LeftLowerArm", "LeftForeArm", "LeftHand"), ("LeftHand", "LeftHand", "LeftForeArm"),
    ("RightUpperArm", "RightArm", "RightForeArm"), ("RightLowerArm", "RightForeArm", "RightHand"), ("RightHand", "RightHand", "RightForeArm"),
    ("LeftUpperLeg", "LeftUpLeg", None), ("LeftLowerLeg", "LeftLeg", None), ("LeftFoot", "LeftFoot", None),
    ("RightUpperLeg", "RightUpLeg", None), ("RightLowerLeg", "RightLeg", None), ("RightFoot", "RightFoot", None),
]
PARENT = {"Spine": "Hips", "Chest": "Spine", "Head": "Chest",
          "LeftUpperArm": "Chest", "LeftLowerArm": "LeftUpperArm", "LeftHand": "LeftLowerArm",
          "RightUpperArm": "Chest", "RightLowerArm": "RightUpperArm", "RightHand": "RightLowerArm",
          "LeftUpperLeg": "Hips", "LeftLowerLeg": "LeftUpperLeg", "LeftFoot": "LeftLowerLeg",
          "RightUpperLeg": "Hips", "RightLowerLeg": "RightUpperLeg", "RightFoot": "RightLowerLeg"}
RIG_ARM_DIR = Vector((0.0, -1.0, 0.0))   # rig arms hang straight down at rest


def _swing(a: Vector, b: Vector) -> Quaternion:
    return a.normalized().rotation_difference(b.normalized())


def bake(clip_id: str, path: str, out_dir: str, in_place: bool = False) -> None:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.fbx(filepath=path)
    arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")
    act = arm.animation_data.action
    hips_name = next(b.name for b in arm.data.bones if b.name.endswith("Hips"))
    pre = hips_name[: -len("Hips")]
    mw = arm.matrix_world

    def rest_head(name: str) -> Vector:
        return mw @ arm.data.bones[pre + name].head_local

    # Blender world -> Godot character space: world up (the FBX import is
    # Z up; the rest spine leans a little), the shoulders give right.
    up = Vector((0.0, 0.0, 1.0))
    right = rest_head("RightArm") - rest_head("LeftArm")
    right = (right - up * right.dot(up)).normalized()
    back = right.cross(up)
    m = Matrix((right, up, back))           # rows: v_godot = m @ v_blender
    mt = m.transposed()
    origin = mw.translation.copy()

    def to_g_rot(r3: Matrix) -> Matrix:
        return m @ r3 @ mt

    def world_rot(mat4: Matrix) -> Matrix:
        return (mw @ mat4).to_3x3().normalized()

    rest_rot = {src: to_g_rot(world_rot(arm.data.bones[pre + src].matrix_local)) for _, src, _ in MAP}
    hips_rest_y = (m @ (rest_head("Hips") - origin)).y
    scale = RIG_HIPS / hips_rest_y
    # Leg proportions differ: shift ankles / knees so a rest ankle sits at the rig's.
    leg_dy = RIG_ANKLE - (m @ (rest_head("LeftFoot") - origin)).y * scale
    corr = {}
    for rig, src, toward in MAP:
        if toward is None:
            corr[rig] = Quaternion()
        else:
            d = m @ (rest_head(toward) - rest_head(src))
            if rig.endswith("Hand"):
                d = -d  # the hand continues its forearm (forearm -> hand)
            corr[rig] = _swing(RIG_ARM_DIR, d)

    f0, f1 = (int(round(v)) for v in act.frame_range)
    frames = []
    sc = bpy.context.scene
    for f in range(f0, f1 + 1):
        sc.frame_set(f)
        glob = {}
        for rig, src, _ in MAP:
            now = to_g_rot(world_rot(arm.pose.bones[pre + src].matrix))
            delta = (now @ rest_rot[src].transposed()).to_quaternion()
            glob[rig] = (delta @ corr[rig]).normalized()
        rots = []
        for rig, _, _ in MAP:
            q = glob[rig] if rig == "Hips" else (glob[PARENT[rig]].inverted() @ glob[rig]).normalized()
            if q.w < 0.0:
                q = -q
            rots += [round(q.x, 5), round(q.y, 5), round(q.z, 5), round(q.w, 5)]

        def pos(name: str, dy: float = 0.0) -> list:
            v = m @ ((mw @ arm.pose.bones[pre + name].head) - origin) * scale
            return [round(v.x, 4), round(v.y + dy, 4), round(v.z, 4)]

        def pitch(rig: str) -> float:
            toe = glob[rig] @ Vector((0.0, 0.0, -1.0))   # the rig foot points -Z at rest
            return round(math.atan2(toe.y, math.hypot(toe.x, toe.z)), 4)

        hp = pos("Hips")
        frames.append({"r": rots, "p": [hp[0], round(hp[1] - RIG_HIPS, 4), hp[2]],
                       "la": pos("LeftFoot", leg_dy), "ra": pos("RightFoot", leg_dy),
                       "lk": pos("LeftLeg", leg_dy), "rk": pos("RightLeg", leg_dy),
                       "lp": pitch("LeftFoot"), "rp": pitch("RightFoot")})
    if in_place:
        # Strip the travel: the game moves the body (push slides), so the hips
        # and every ankle / knee keep only their offset from the hips' path.
        x0, z0 = frames[0]["p"][0], frames[0]["p"][2]
        for fr in frames:
            dx, dz = fr["p"][0] - x0, fr["p"][2] - z0
            for k in ("p", "la", "ra", "lk", "rk"):
                fr[k] = [round(fr[k][0] - dx, 4), fr[k][1], round(fr[k][2] - dz, 4)]
    out = {"source": path.rsplit("/", 1)[-1], "fps": sc.render.fps, "frames": frames}
    with open(f"{out_dir}/{clip_id}.json", "w") as fh:
        json.dump(out, fh, separators=(",", ":"))
    print(f"baked {clip_id}: {len(frames)} frames @ {sc.render.fps} fps, rest hips {hips_rest_y:.3f} -> scale {scale:.4f}")


args = sys.argv[sys.argv.index("--") + 1:]
for spec in args[1:]:
    cid, fbx = spec.split("=", 1)
    bake(cid.removesuffix("@inplace"), fbx, args[0], cid.endswith("@inplace"))
