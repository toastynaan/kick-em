extends Node3D
## Round 6 panel collapse (docs/ARCHITECTURE.md Round 6 check, owner D):
## "knocking out the cells under part of a panel leaves no floating cells;
## unsupported cells fall within Tuning.COLLAPSE_DELAY".
## 1. A free-standing drywall partition (held only from below) loses a band of
##    cells across its whole width at mid-height: everything above is left
##    floating. GameEvents.structure_collapsed (kind &"panel") comes at once
##    (dust first), the floating cells still stand during the delay, and they
##    fall Tuning.COLLAPSE_DELAY s (game time) later as chunks: 0 floating.
## 2. 40 random body-sized holes (break_hole) across 10 wall panels of every
##    surface, and 60 kick strikes: after each, within Tuning.COLLAPSE_DELAY
##    (+1 tick), no panel has a floating cell.

var _collapses: Array = []
var _game := 0.0
var _ok := true

func _physics_process(delta: float) -> void:
	_game += delta

func _ready() -> void:
	GameEvents.structure_collapsed.connect(func(n: Node3D, p: Vector3, kind: StringName) -> void:
		_collapses.append({"node": n, "pos": p, "kind": kind, "g": _game}))
	WorldTestUtil.make_floor(self, 200.0)
	await get_tree().physics_frame
	await _band_cut()
	await _random_holes()
	print("[collapse] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _line(s: String, ok: bool) -> void:
	_ok = _ok and ok
	print("[collapse] %s -> %s" % [s, "PASS" if ok else "FAIL"])

func _panel(surface: StringName, at: Vector3, size: Vector3, support: int) -> Destructible:
	var d := Destructible.new()
	d.surface = surface
	d.size = size
	d.support_mask = support
	d.transform = Transform3D(Basis.looking_at(Vector3(-1, 0, 0), Vector3.UP), at + Vector3(0, size.y * 0.5, 0))
	add_child(d)
	return d

func _band_cut() -> void:
	var p := _panel(&"drywall", Vector3(0, 0, 0), Vector3(3.0, 2.4, 0.12), PanelFracture.SIDE_BOTTOM)
	await get_tree().physics_frame
	_collapses.clear()
	var cells := p.get_cell_count()
	# A band 0.4 m tall across the whole width at mid-height: the lower half stays
	# on the floor, the upper half is left floating.
	p.break_hole(p.global_position + Vector3(0, 0.1, 0), Vector3(-3, 0, 0), Rect2(-1.6, -0.1, 3.2, 0.4))
	var floating0 := p.get_floating_cell_count()
	var alive0 := p.get_alive_count()
	var creak := _collapses.filter(func(c: Dictionary) -> bool: return c["node"] == p and c["kind"] == &"panel")
	var g0 := _game
	var still_mid := -1
	var gone_at := -1.0
	while _game - g0 < 0.6:
		await get_tree().physics_frame
		if still_mid < 0 and _game - g0 >= Tuning.COLLAPSE_DELAY * 0.5:
			still_mid = p.get_alive_count()
		if gone_at < 0.0 and p.get_floating_cell_count() == 0:
			gone_at = _game - g0
	var ok := floating0 > 0 and creak.size() == 1 and still_mid == alive0 and gone_at > 0.0 \
		and gone_at <= Tuning.COLLAPSE_DELAY + 1.0 / 60.0 and p.get_floating_cell_count() == 0
	_line("partition band cut: %d cells, %d left floating, creak events %d, at half the delay %d still stand, floating gone %.3f s (game) after the cut (COLLAPSE_DELAY %.2f), %d cells left" % [
		cells, floating0, creak.size(), still_mid, gone_at, Tuning.COLLAPSE_DELAY, p.get_alive_count()], ok)
	p.queue_free()
	WorldTestUtil.cleanup()

func _random_holes() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 6
	var panels: Array[Destructible] = []
	var surfaces: Array[StringName] = [&"drywall", &"brick", &"concrete", &"wood"]
	for i in 10:
		var support := PanelFracture.SUPPORT_SIDES if i < 7 else PanelFracture.SIDE_BOTTOM
		panels.append(_panel(surfaces[i % surfaces.size()], Vector3(0, 0, 10.0 + i * 5.0), Vector3(3.0, 3.0, 0.25), support))
	await get_tree().physics_frame
	var worst := 0
	var collapses := 0
	var worst_wait := 0.0
	var holes := 0
	for k in 40:
		var p := panels[k % panels.size()]
		if p.is_broken:
			continue
		var at := p.global_transform * Vector3(rng.randf_range(-1.2, 1.2), rng.randf_range(-1.2, 1.2), 0.0)
		var lp := p.to_local2(at)
		var n0 := _collapses.size()
		p.break_hole(at, Vector3(-6, 0, 0), Rect2(lp - Vector2(0.4, 0.8), Vector2(0.8, 1.6)))
		holes += 1
		var r := await _settle(panels, n0)
		worst = maxi(worst, int(r[0]))
		worst_wait = maxf(worst_wait, float(r[1]))
		collapses += int(r[2])
	var strikes := 0
	for k in 60:
		var p := panels[(k * 3) % panels.size()]
		if p.is_broken:
			continue
		var at := p.global_transform * Vector3(rng.randf_range(-1.3, 1.3), rng.randf_range(-1.3, 1.3), p.size.z * 0.5)
		var n0 := _collapses.size()
		p.receive_strike(null, at, Vector3(-1, 0, 0), 180.0)
		strikes += 1
		var r := await _settle(panels, n0)
		worst = maxi(worst, int(r[0]))
		worst_wait = maxf(worst_wait, float(r[1]))
		collapses += int(r[2])
	_line("%d random body-sized holes and %d level-3 kicks on 10 panels: %d collapses, the longest wait for floating cells to fall %.3f s (game, COLLAPSE_DELAY %.2f), floating cells left after it: %d" % [
		holes, strikes, collapses, worst_wait, Tuning.COLLAPSE_DELAY, worst],
		worst == 0 and worst_wait <= Tuning.COLLAPSE_DELAY + 1.0 / 60.0 and collapses > 0)
	for p in panels:
		p.queue_free()
	WorldTestUtil.cleanup()

## Wait until no panel has floating cells (at most 0.5 s). Returns
## [floating cells left after COLLAPSE_DELAY + 2 ticks, s waited, collapses seen].
func _settle(panels: Array[Destructible], n0: int) -> Array:
	var g0 := _game
	var waited := 0.0
	var left := 0
	while true:
		var floating := 0
		for p in panels:
			floating += p.get_floating_cell_count()
		if floating == 0:
			break
		if _game - g0 > Tuning.COLLAPSE_DELAY + 2.0 / 120.0:
			left = floating
			break
		await get_tree().physics_frame
		waited = _game - g0
	return [left, waited, _collapses.size() - n0]
