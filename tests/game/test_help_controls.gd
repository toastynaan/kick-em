extends Node
## Round 7 help (J, with the amendment): the F1 controls panel
## (UIKit.control_rows / controls_panel) and the title's HOW TO FIGHT panel list
## every Round 7 action with the keys from Controls: the gamepad kick layer
## "LT + X/A/B", Jump on Space / A with the wall run, Counter on V / mouse
## thumb / Y, Dash's meanings (tap = dodge, teleport just before a hit, pursuit
## right after a launch; hold = sprint), the pursuit hit (attack to launch,
## back + attack to spike), hold for heavy on the punch and the three kicks,
## and the hold actions throw, knee, drive and release. Nothing removed (Focus,
## lock-on, parry / block, crouch, charge, the Heavy and Kick buttons). The
## panel fits a 1600x900 window.

## Title -> [keyboard + mouse, gamepad] the Round 7 doc's Controls table gives.
const EXPECT := {
	"Punch": ["LMB", "X"], "Leg kick": ["RMB", "LT + X"], "Gut punch": ["Q", "B"], "Uppercut": ["E", "LB"],
	"Front kick": ["F", "LT + A"], "Roundhouse": ["R", "LT + B"], "Grab": ["C", "RB"], "Counter": ["V", "Y"],
	"Jump": ["Space", "A"], "Dash / sprint": ["Shift", "RT"], "Pause": ["Esc", "Start"], "Restart": ["Backspace", "Back"],
	"Pursuit": ["Shift (after a launch)", "RT (after a launch)"], "Pursuit hit": ["Attack", "Attack"],
	"Holding: throw": ["LMB", "X"], "Holding: knee": ["RMB", "LT + X"], "Holding: drive": ["Shift (hold)", "RT (hold)"],
	"Holding: release": ["C", "RB"], "Kick layer": ["-", "LT (hold)"], "Help": ["F1", "-"], "Debug": ["F3", "-"],
}
## Words of removed features that must not appear anywhere in the help (lower case).
const REMOVED_WORDS: Array[String] = ["focus", "lock", "parry", "block", "crouch", "charge", "sweep", "sidestep", "strafe"]
## Titles of the Round 5 rows that must be gone.
const REMOVED_TITLES: Array[String] = ["Light", "Heavy", "Kick", "Sweep", "Crouch", "Block", "Focus",
	"Lock on", "Switch target"]

var _fails := 0

func _ready() -> void:
	await get_tree().process_frame
	await _run()
	print("TEST test_help_controls: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
	get_tree().quit(0 if _fails == 0 else 1)

func _check(cond: bool, what: String) -> void:
	print("  ok   " if cond else "  FAIL ", what)
	if not cond:
		_fails += 1

func _removed_in(text: String) -> PackedStringArray:
	var low := text.to_lower()
	var out := PackedStringArray()
	for w in REMOVED_WORDS:
		if low.contains(w):
			out.append(w)
	return out

func _run() -> void:
	var rows := UIKit.control_rows()
	var by_title := {}
	var order := PackedStringArray()
	for row: Array in rows:
		by_title[row[0]] = row
		order.append(row[0])
		print("    %-17s | %-16s | %-12s | %s" % row)

	# Every Round 7 action in Controls has a row (move_* and cam_* merged).
	var missing := PackedStringArray()
	for action: StringName in Controls.ACTIONS:
		var id := action
		if String(action).begins_with("move_"):
			id = &"move"
		elif String(action).begins_with("cam_"):
			id = &"camera"
		var title: String = UIKit.ACTION_TITLES.get(id, "")
		if title == "" or not by_title.has(title) or String(by_title[title][3]) == "":
			missing.append(String(id))
	_check(missing.is_empty(), "every Controls action has a titled, described row (missing: %s)" % ", ".join(missing))

	# Keys match the Round 7 table.
	for title: String in EXPECT:
		var want: Array = EXPECT[title]
		var row: Array = by_title.get(title, [])
		var ok := not row.is_empty() and String(row[1]).split(" / ").has(want[0]) and String(row[2]).split(" / ").has(want[1])
		_check(ok, "%s: %s / %s (%s | %s)" % [title, want[0], want[1], row[1] if not row.is_empty() else "?", row[2] if not row.is_empty() else "?"])

	# Counter also on the mouse thumb button.
	_check(String(by_title.get("Counter", ["", ""])[1]) == "V / Mouse thumb", "Counter: V / Mouse thumb (%s)" % by_title.get("Counter", ["", "?"])[1])

	# What the rows say: jump and wall run, the Dash meanings, the pursuit choice, heavy kicks.
	var desc := func(title: String) -> String: return String(by_title.get(title, ["", "", "", ""])[3]).to_lower()
	_check(desc.call("Jump").contains("wall run") and desc.call("Jump").contains("sprint"), "Jump: sprint + jump at a wall = wall run (%s)" % desc.call("Jump"))
	var dash: String = desc.call("Dash / sprint")
	_check(dash.contains("tap: dodge") and dash.contains("teleport just before a hit") and dash.contains("pursue right after a launch")
		and dash.contains("hold: sprint"), "Dash: tap = dodge / teleport before a hit / pursue after a launch, hold = sprint (%s)" % dash)
	_check(desc.call("Pursuit").contains("launch") and desc.call("Pursuit hit").contains("spike it into the ground")
		and desc.call("Pursuit hit").contains("pull back") and desc.call("Pursuit hit").contains("launch it further"),
		"Pursuit hit: attack launches, pull back + attack spikes (%s)" % desc.call("Pursuit hit"))
	_check(String(by_title.get("Pursuit hit", ["", ""])[1]).contains("S + attack"), "Pursuit hit keyboard: 'S + attack' (%s)" % by_title.get("Pursuit hit", ["", "?"])[1])
	var heavy_kicks := true
	for k in ["Leg kick", "Front kick", "Roundhouse", "Punch"]:
		if not String(desc.call(k)).contains("hold"):
			heavy_kicks = false
	_check(heavy_kicks, "punch and the three kicks say hold = heavy")
	var di := order.find("Dash / sprint")
	_check(di >= 0 and order.slice(di + 1, di + 3) == PackedStringArray(["Pursuit", "Pursuit hit"]), "the pursuit rows follow Dash")

	# The hold actions come right after Grab.
	var gi := order.find("Grab")
	_check(gi >= 0 and order.slice(gi + 1, gi + 5) == PackedStringArray(["Holding: throw", "Holding: knee", "Holding: drive", "Holding: release"]),
		"throw, knee, drive and release follow the Grab row")

	# Nothing removed: no legacy action, no Round 5 row, no removed word.
	var bad_titles := PackedStringArray()
	for t: String in REMOVED_TITLES:
		if by_title.has(t):
			bad_titles.append(t)
	_check(bad_titles.is_empty(), "no Round 5 rows (found: %s)" % ", ".join(bad_titles))
	var legacy := PackedStringArray()
	for a: StringName in Controls.LEGACY_ACTIONS:
		if UIKit.ACTION_TITLES.has(a) or UIKit.ACTION_HELP.has(a):
			legacy.append(String(a))
	_check(legacy.is_empty(), "no legacy action has a title or help text (%s)" % ", ".join(legacy))

	# The panel as built: every label's text.
	var panel := UIKit.controls_panel()
	panel.visible = true
	add_child(panel)
	await get_tree().process_frame
	await get_tree().process_frame
	var texts := PackedStringArray()
	for l in panel.find_children("*", "Label", true, false):
		texts.append((l as Label).text)
	var all := "\n".join(texts)
	var found := _removed_in(all)
	_check(found.is_empty(), "F1 panel: no removed feature mentioned (found: %s)" % ", ".join(found))
	_check(all.contains("Orange icon") and all.contains("Blue icon") and all.contains("V / Mouse thumb") and all.contains("RT"),
		"F1 panel explains the orange / blue counter icons with their keys")
	var sz := panel.get_combined_minimum_size()
	print("    F1 panel minimum size %s" % sz)
	_check(sz.x <= 1600.0 and sz.y <= 900.0, "F1 panel fits 1600x900 (%.0f x %.0f)" % [sz.x, sz.y])
	panel.queue_free()

	# The title's HOW TO FIGHT panel.
	var lines := GameMenus.title_key_lines()
	var names := PackedStringArray()
	for line: Array in lines:
		names.append_array([line[0], line[2]])
	for want: String in ["Punch", "Leg kick", "Gut punch", "Uppercut", "Front kick", "Roundhouse", "Counter",
			"Dash / sprint", "Jump", "Grab", "Restart"]:
		_check(names.has(want), "title panel lists %s" % want)
	var counter_line: Array = []
	for line: Array in lines:
		if line[0] == "Counter":
			counter_line = line
	_check(not counter_line.is_empty() and counter_line[1] == "V / Mouse thumb", "title: Counter on 'V / Mouse thumb'")
	var tips := GameMenus.title_tips().to_lower()
	_check(tips.contains("teleport") and tips.contains("pursue") and tips.contains("spike") and tips.contains("wall run")
		and tips.contains("v to counter") and tips.contains("hold it, or a kick: the heavy version"),
		"title tips: counter on V, teleport, pursue, spike, wall run, heavy kicks")
	var title_text := str(lines) + "\n" + GameMenus.title_tips()
	print("    title tips: %s" % GameMenus.title_tips().replace("\n", " / "))
	found = _removed_in(title_text)
	_check(found.is_empty(), "title panel: no removed feature mentioned (found: %s)" % ", ".join(found))
	_check(GameMenus.title_tips().contains("Space") and GameMenus.title_tips().contains("Shift") and GameMenus.title_tips().contains("V to counter"),
		"title tips name the Counter, Dash and Jump keys")

	# Key labels for both devices.
	_check(UIKit.key_label(&"counter", false) == "V" and UIKit.key_label(&"counter", true) == "Y"
		and UIKit.key_label(&"dash", false) == "Shift" and UIKit.key_label(&"dash", true) == "RT"
		and UIKit.key_label(&"jump", false) == "Space" and UIKit.key_label(&"jump", true) == "A"
		and UIKit.key_label(&"front_kick", true) == "LT + A" and UIKit.key_label(&"uppercut", true) == "LB"
		and UIKit.key_label(&"restart", false) == "Backspace",
		"key_label: V/Y, Shift/RT, Space/A, LT + A, LB, Backspace")
	_check(GameMenus.restart_text() == "RESTART  (Backspace / Back)", "restart item reads '%s'" % GameMenus.restart_text())
