class_name Layers
## Collision and render layer bits. Names are set in Project Settings > Layer Names.
## OWNER: core (contract). Do not change bit values.

# Physics layers
const WORLD := 1 << 0          ## Floor, outer walls, pillars. Static, never breaks.
const DESTRUCTIBLE := 1 << 1   ## Intact breakable panels and props.
const CAPSULE := 1 << 2        ## Fighter CharacterBody3D capsules.
const RAGDOLL := 1 << 3        ## PhysicalBone3D bodies.
const HITBOX := 1 << 4         ## Attack query shapes / Area3D.
const HURTBOX := 1 << 5        ## Fighter hurtbox Area3D on bones.
const DEBRIS := 1 << 6         ## Large chunks, severed limbs.
const DEBRIS_SMALL := 1 << 7   ## Small chunks. Never collide with each other.
## Round 5: dead bodies. Walking capsules ignore them (no jitter over piles);
## a foot Area3D nudges them instead. Nav treats them as walkable.
const DEAD_BODY := 1 << 8

# Masks
## Capsules walk on the world, are blocked by intact walls and by each other.
## They do not collide with ragdolls or debris (they push those instead, see below).
const MASK_CAPSULE := WORLD | DESTRUCTIBLE | CAPSULE
## Bones hit the world, walls, other fighters' bones, standing capsules and debris.
## A fighter's own capsule is excluded with collision exceptions, not masks.
const MASK_RAGDOLL := WORLD | DESTRUCTIBLE | CAPSULE | RAGDOLL | DEBRIS
const MASK_DEBRIS := WORLD | DESTRUCTIBLE | CAPSULE | RAGDOLL | DEBRIS | DEBRIS_SMALL
const MASK_DEBRIS_SMALL := WORLD | DESTRUCTIBLE | CAPSULE | RAGDOLL | DEBRIS
## Dead bodies rest on the world and on each other, take debris and other bodies,
## but never capsules.
const MASK_DEAD_BODY := WORLD | DESTRUCTIBLE | RAGDOLL | DEBRIS | DEAD_BODY

# Render (visual) layers
const VIS_WORLD := 1 << 0
const VIS_CHARACTERS := 1 << 1  ## Fighter meshes. World decals leave this out of their cull mask.
const VIS_FX := 1 << 2
