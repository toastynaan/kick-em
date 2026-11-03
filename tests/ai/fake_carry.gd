extends Carry
## Test double: a grabber's Carry whose drive and connected-hold state can be
## forced (AIBrain.can_try_grab_break reads them). OWNER: agent C (AI tests).

var fake_driving := false
var fake_holding_body := false

func is_driving() -> bool:
	return fake_driving

func is_holding_body() -> bool:
	return fake_holding_body
