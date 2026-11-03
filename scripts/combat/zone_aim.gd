class_name ZoneAim
extends RefCounted
## Round 7 removed zone aiming (docs/Round 7 — Freeflow Combat.md: Decisions 2).
## Nothing updates or reads this class any more: Fighter.aim_zone / aim_bone
## keep their defaults (torso, chest) and strikes take the torso. The class is
## kept empty so the file can be deleted at the end of Round 7 without a
## dangling class name in the middle of the round.
## OWNER: agent H (fighter, player & defence).
