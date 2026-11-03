class_name ComboGraph
extends Resource
## The punch button's string and the heavy versions, as data. OWNER: agent B
## (combat).
##
## Round 7 (docs/Round 7 — Freeflow Combat.md: Moves; amendment): one button,
## one move. The only string is the punch button's: it counts 1, 2, 3 (jab,
## cross, hook) and wraps back to the jab. Combos come from states, not strings
## (Tuning.R7_PAYOFFS). CombatController keeps the string position (Round 9:
## it goes back to the jab only after Tuning.R9_STRING_RESET with no punch press).
## Round 8 (docs/Round 8 — Charge and Pressure.md: Charge): a held press no
## longer switches to a heavy; CombatController charges the position's punch
## (or any strike) continuously. The heavy ids (Tuning.R7_HEAVY_OF) stay: they
## are the charged strikes' payoff rows (R8_MOVES "payoff_id"), Round 7 moves
## for scripted play_move (the lab, bots), and index_of() / is_heavy() still
## know them.

## Punch string positions: index 0 = 1st press, 1 = 2nd, 2 = 3rd.
@export var punches: Array[StringName] = []
## Move -> its Round 7 heavy version (the string punches and the three kicks).
@export var heavies: Dictionary = {}

static var _default: ComboGraph

static func default_graph() -> ComboGraph:
	if _default != null:
		return _default
	var g := ComboGraph.new()
	g.punches.assign(Tuning.R7_PUNCH_STRING)
	g.heavies = Tuning.R7_HEAVY_OF.duplicate()
	_default = g
	return g

func size() -> int:
	return punches.size()

## The punch at string position `index` (wraps).
func punch_at(index: int) -> StringName:
	if punches.is_empty():
		return &""
	return punches[posmod(index, punches.size())]

## The heavy version of a move (&"" when it has none: the uppercut, the gut punch).
func heavy_of(id: StringName) -> StringName:
	return heavies.get(id, &"")

## Position after `index` (wraps after the hook).
func next_index(index: int) -> int:
	return posmod(index + 1, maxi(punches.size(), 1))

## String position of a punch or its heavy (-1 when `id` is not a string punch).
func index_of(id: StringName) -> int:
	var i := punches.find(id)
	if i >= 0:
		return i
	for p: StringName in heavies:
		if heavies[p] == id:
			return punches.find(p)
	return -1

func is_heavy(id: StringName) -> bool:
	return heavies.values().has(id)

## Every move id the graph knows (the string punches, the moves with heavies,
## and the heavies).
func moves() -> Array[StringName]:
	var out: Array[StringName] = []
	out.append_array(punches)
	for m: StringName in heavies:
		for id: StringName in [m, heavies[m]]:
			if not out.has(id):
				out.append(id)
	return out
