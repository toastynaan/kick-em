extends Node
## Test double: a stand-in brain whose fleeing state can be forced
## (Fighter.is_fleeing() asks brain.is_fleeing()). OWNER: agent C (AI tests).

var fleeing := false

func is_fleeing() -> bool:
	return fleeing
