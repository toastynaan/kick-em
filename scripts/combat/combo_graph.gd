class_name ComboGraph
extends Resource
## Combo strings as data. OWNER: agent B (combat).
##
## Round 5 (Feel Reference: Controls and targeting; Upgrade Spec 2's combo
## graph, kept): three attack buttons, Light (jab, action "punch"), Heavy
## (cross) and Kick. Knees and elbows come out of strings, not buttons. A
## string is at most three hits: the button picks the strike, the position in
## the string picks its variant, and the third hit of a tap string gets the
## finisher bonus (+1 P, Tuning.FINISHER_BONUS). Tapped, standing P in brackets.
##
##            1st hit               2nd hit                  3rd hit (+1 P)
##   Light    jab          (1.0)    jab, other hand (1.0)    elbow       (2.5 stagger)
##   Heavy    cross        (2.0)    cross; hook after a      uppercut    (3.0 stagger)
##                                  cross or hook  (2.0)
##   Kick     front kick   (2.5)    knee           (1.5)     roundhouse  (3.5 knockdown)
##
## Readable rules: Light, Light, Light = jab, jab, elbow. Light, Heavy = the
## one-two. Any string that ends on Kick ends on a roundhouse knockdown
## (jab, jab, roundhouse; front kick, knee, roundhouse). Heavy, Heavy, Heavy =
## cross, hook, uppercut.
##
## Any position (they take the string's slot, so a third one gets the bonus):
##   back + Kick       sweep (crouch + Kick is an alias)   1.5: stumble
##   back + Light      spinning backfist: turns to whoever is behind   2.0
##   crouch + Light / Heavy        crouch punch (low)   1.0
##   Light / Heavy just after standing up from a crouch: rising uppercut   2.0
##   any attack in the air         dropping strike (class by button)
## Next to a body on the ground, any attack is a ground strike instead
## (stomp on Kick, knee drop on Light / Heavy): CombatController decides that
## before asking this graph.
##
## Cancel rules (CombatController): on a HIT, a strike may cancel its recovery
## (MoveData.cancel_window frames from the end of its active frames) into the
## string's next hit. No cancels on a whiff, out of a charged strike, or out of
## the third hit. Holding a press charges that move and ends the string after it.

## Tokens: plain buttons, then stance variants.
const P := &"P"    ## Light (the "punch" action)
const H := &"H"    ## Heavy
const K := &"K"    ## Kick
const BP := &"bP"  ## back + Light
const BK := &"bK"  ## back + Kick
const CP := &"cP"  ## crouch + Light / Heavy
const CK := &"cK"  ## crouch + Kick
const RP := &"rP"  ## Light / Heavy while rising out of a crouch
const JP := &"jP"  ## Light in the air
const JH := &"jH"  ## Heavy in the air
const JK := &"jK"  ## Kick in the air
## Upgrade 2 token kept so old callers resolve (forward + Light is a plain Light).
const FP := &"fP"

const MAX_HITS := 3

## Plain tokens by string position: index 0 = 1st hit, 1 = 2nd, 2 = 3rd.
@export var by_position: Array[Dictionary] = []
## Position overrides: {position (1-based): {previous move: {token: move}}}.
@export var overrides: Dictionary = {}
## Tokens that mean the same move at any position.
@export var specials: Dictionary = {}
## Tokens read as another token (forward + Light is a plain Light).
@export var fallback: Dictionary = {}

static var _default: ComboGraph

static func default_graph() -> ComboGraph:
	if _default != null:
		return _default
	var g := ComboGraph.new()
	g.by_position = [
		{P: &"jab1", H: &"cross", K: &"sparta_kick"},
		{P: &"jab2", H: &"cross", K: &"knee_strike"},
		{P: &"elbow", H: &"uppercut", K: &"roundhouse"},
	]
	g.overrides = {
		2: {&"cross": {H: &"hook"}, &"hook": {H: &"hook"}},
	}
	g.specials = {
		BK: &"leg_sweep", CK: &"leg_sweep", BP: &"backfist", CP: &"crouch_punch",
		RP: &"rising_uppercut", JP: &"drop_strike", JH: &"drop_strike", JK: &"drop_strike",
	}
	g.fallback = {FP: P}
	_default = g
	return g

## The move `token` plays as hit number `pos` (1-based) of a string whose
## previous move is `prev` (&"" = none). pos < 1: 1 without a previous move, else 2.
func next_move(prev: StringName, token: StringName, pos := -1) -> StringName:
	if pos < 1:
		pos = 1 if prev == &"" else 2
	pos = clampi(pos, 1, MAX_HITS)
	var tok: StringName = fallback.get(token, token)
	if specials.has(tok):
		return specials[tok]
	var ov: Dictionary = overrides.get(pos, {})
	if prev != &"" and ov.has(prev) and (ov[prev] as Dictionary).has(tok):
		return ov[prev][tok]
	if by_position.size() >= pos:
		return by_position[pos - 1].get(tok, &"")
	return &""

## The first move of a string for `token`.
func starter(token: StringName) -> StringName:
	return next_move(&"", token, 1)

## True when `move_id` can open a string.
func is_starter(move_id: StringName) -> bool:
	return (by_position[0] as Dictionary).values().has(move_id) or specials.values().has(move_id)

## True when `next` can follow `prev` as the next hit of a string.
func is_link(prev: StringName, next: StringName) -> bool:
	if prev == &"" or not moves().has(prev):
		return false
	for pos in range(2, MAX_HITS + 1):
		for tok in [P, H, K, BP, BK, CP, CK, RP]:
			if next_move(prev, tok, pos) == next:
				return true
	return false

## Every move id the graph knows.
func moves() -> Array[StringName]:
	var out: Array[StringName] = []
	for row: Dictionary in by_position:
		for m: StringName in row.values():
			if not out.has(m):
				out.append(m)
	for m: StringName in specials.values():
		if not out.has(m):
			out.append(m)
	for pos: int in overrides:
		for prev: StringName in overrides[pos]:
			for m: StringName in (overrides[pos][prev] as Dictionary).values():
				if not out.has(m):
					out.append(m)
	return out
