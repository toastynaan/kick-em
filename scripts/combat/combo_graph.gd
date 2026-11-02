class_name ComboGraph
extends Resource
## Combo strings as data (Upgrade spec 2: Combos and new moves). A press is
## turned into an input token by CombatController (button + crouch / jump /
## forward / back / rising), then:
##   next = links[previous string move][token], else starters[token].
## Cancel rules (CombatController): on HIT, a move may cancel its recovery
## (MoveData.cancel_window frames from the end of its active frames) into its
## linked move, or into another string's starter unless it is an ender
## (MoveData.ender). On whiff: no cancels. Charged moves: only a perfect dodge.
## OWNER: agent B (combat).
##
## Tokens: P K (plain), fP (forward + P), bP (back + P), cP cK (crouch),
## jP jK (jumping), rP (P while rising out of a crouch), gP gK (holding a grab:
## knee, headbutt).

const P := &"P"
const K := &"K"
const FP := &"fP"
const BP := &"bP"
const CP := &"cP"
const CK := &"cK"
const JP := &"jP"
const JK := &"jK"
const RP := &"rP"

## token -> first move of a string.
@export var starters: Dictionary = {}
## move -> {token -> next move}.
@export var links: Dictionary = {}
## Tokens tried when a token has no link and no starter (fP falls back to P).
@export var fallback: Dictionary = {}

static var _default: ComboGraph

## The game's strings (spec table):
##   P, P, P            jab1, cross, hook          hook staggers
##   P, P, forward + P  jab1, cross, uppercut      launcher, lifts 1.5 m
##   P, P, K            jab1, cross, sparta_kick   launch toward the wall
##   K, K               sparta_kick, roundhouse    spins the target sideways
##   crouch + K, K      leg_sweep, sparta_kick     stumble, then the flat launch
##   uppercut, jump + K uppercut, flying_kick      air juggle
##   grab, P (x3)       knees while holding        then throw (grab flow)
##   back + P           backfist, at any point     hits the enemy behind
static func default_graph() -> ComboGraph:
	if _default != null:
		return _default
	var g := ComboGraph.new()
	g.starters = {
		P: &"jab1", K: &"sparta_kick", CK: &"leg_sweep", CP: &"crouch_punch",
		JK: &"flying_kick", JP: &"hammer_fist", RP: &"rising_uppercut", BP: &"backfist",
	}
	g.links = {
		&"jab1": {P: &"cross", FP: &"cross"},
		&"cross": {P: &"hook", FP: &"uppercut", K: &"sparta_kick"},
		&"sparta_kick": {K: &"roundhouse"},
		&"leg_sweep": {K: &"sparta_kick"},
		&"uppercut": {JK: &"flying_kick"},
		&"rising_uppercut": {JK: &"flying_kick"},
		&"crouch_punch": {RP: &"rising_uppercut"},
		# Ground finisher: mount punches chain on hit (CombatController caps them per down).
		&"mount_punch": {P: &"mount_punch"},
	}
	g.fallback = {FP: P}
	_default = g
	return g

## The move a token plays after `prev` (&"" = no string running).
func next_move(prev: StringName, token: StringName) -> StringName:
	var link := link_of(prev, token)
	if link != &"":
		return link
	var st: StringName = starters.get(token, &"")
	if st != &"":
		return st
	var fb: StringName = fallback.get(token, &"")
	if fb != &"":
		return next_move(prev, fb)
	return &""

## Explicit link from `prev` on `token`, else &"".
func link_of(prev: StringName, token: StringName) -> StringName:
	if prev == &"" or not links.has(prev):
		return &""
	var l: Dictionary = links[prev]
	if l.has(token):
		return l[token]
	var fb: StringName = fallback.get(token, &"")
	if fb != &"" and l.has(fb):
		return l[fb]
	return &""

func is_link(prev: StringName, next: StringName) -> bool:
	if not links.has(prev):
		return false
	return (links[prev] as Dictionary).values().has(next)

func is_starter(move_id: StringName) -> bool:
	return starters.values().has(move_id)

## Every string move id the graph knows (starters and link targets).
func moves() -> Array[StringName]:
	var out: Array[StringName] = []
	for m: StringName in starters.values():
		if not out.has(m):
			out.append(m)
	for from: StringName in links:
		if not out.has(from):
			out.append(from)
		for m: StringName in (links[from] as Dictionary).values():
			if not out.has(m):
				out.append(m)
	return out
