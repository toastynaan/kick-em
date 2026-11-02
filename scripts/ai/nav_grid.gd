class_name AINavGrid
extends RefCounted
## Shared walkability grid for enemy navigation (round 2.5). CELL-sized cells
## over x/z in [-HALF, HALF]. A cell is solid when a body-sized capsule at
## waist height overlaps Layers.WORLD | Layers.DESTRUCTIBLE: exactly what a
## fighter capsule collides with (walls, pillars, intact wall cells, desks,
## crates, the Yard's low walls and raised platform: enemies walk round what
## the player vaults). Debris, loose props, ragdolls and dead bodies
## (Layers.DEAD_BODY) never block a capsule, so they are ignored: a pile of
## bodies is walkable. AttackDirector owns one, builds it a few rows per
## physics tick at round start, refreshes the cells around broken walls and
## sweeps the whole grid slowly in the background (sweep_step).
## OWNER: agent C (AI).

const CELL := 0.4
const HALF := 18.6
const BODY_RADIUS := 0.28
## The test body spans 0.08-1.82 m above the floor: Round 6 leaves low lips
## (the bottom of a hole knocked through a panel, low clutter parts) that a
## fighter's capsule catches on, so they count; the floor itself never does.
const BODY_HEIGHT := 1.74
const BODY_CENTER := 0.95      ## m above the floor (bottom 0.08 m up)
## Stall penalty: cells round a spot where an enemy wedged cost this much more
## to cross for PENALTY_TIME s (paths go round it when they can).
const PENALTY_WEIGHT := 6.0
const PENALTY_TIME := 10.0
## m: free_cell_near's line of sight runs at this height (over furniture).
const SEE_HEIGHT := 1.2
const SEE_RADIUS := 0.15
const FLOOR_Y := 0.0
const ROWS_PER_TICK := 10      ## build budget: 10 rows x 93 cells per physics tick
const NEAREST_FREE_RINGS := 4  ## cells searched round a solid start / end cell
## Round 6: a second, wide layer for bodies wider than a grunt (the heavy's
## capsule is 0.372 m): a cell is wide-walkable when a capsule of this radius
## fits. The clutter leaves gaps a grunt fits through and a heavy wedges in.
const WIDE_RADIUS := 0.42

var astar := AStarGrid2D.new()
var astar_wide := AStarGrid2D.new()
var n := 0
var ready := false

# Cost stats (microseconds).
var build_usec := 0
var build_ticks := 0
var path_queries := 0
var path_usec := 0
var refresh_cells := 0
var refresh_usec := 0
var sweep_cells := 0
var sweep_usec := 0
var _sweep_next := 0

## Whether the last find_path() reached the goal's cell (false: partial path
## to the closest reachable cell, or no path).
var last_path_complete := false
var _next_row := 0
var _params := PhysicsShapeQueryParameters3D.new()
var _params_wide := PhysicsShapeQueryParameters3D.new()
var _see_params := PhysicsShapeQueryParameters3D.new()
var _penalties: Array = []     ## [expiry (simulation s), cells (Array[Vector2i])]
var _space: PhysicsDirectSpaceState3D

func _init() -> void:
	n = int(ceil(HALF * 2.0 / CELL))
	astar.region = Rect2i(0, 0, n, n)
	astar.cell_size = Vector2(CELL, CELL)
	astar.offset = Vector2(-HALF + CELL * 0.5, -HALF + CELL * 0.5)
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.update()
	astar_wide.region = astar.region
	astar_wide.cell_size = astar.cell_size
	astar_wide.offset = astar.offset
	astar_wide.diagonal_mode = astar.diagonal_mode
	astar_wide.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar_wide.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar_wide.update()
	var cap := CapsuleShape3D.new()
	cap.radius = BODY_RADIUS
	cap.height = BODY_HEIGHT
	_params.shape = cap
	_params.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE
	var wide := CapsuleShape3D.new()
	wide.radius = WIDE_RADIUS
	wide.height = maxf(BODY_HEIGHT, WIDE_RADIUS * 2.0)
	_params_wide.shape = wide
	_params_wide.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE
	var see := SphereShape3D.new()
	see.radius = SEE_RADIUS
	_see_params.shape = see
	_see_params.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE

## Begin a (re)build against `space`; step_build() does the work.
func start_build(space: PhysicsDirectSpaceState3D) -> void:
	_space = space
	_next_row = 0
	ready = false
	build_usec = 0
	build_ticks = 0

## Test up to ROWS_PER_TICK rows. Returns true once the grid is complete.
func step_build() -> bool:
	if ready:
		return true
	if _space == null:
		return false
	var t0 := Time.get_ticks_usec()
	var end := mini(_next_row + ROWS_PER_TICK, n)
	for j in range(_next_row, end):
		for i in n:
			_test_cell(Vector2i(i, j))
	_next_row = end
	build_usec += Time.get_ticks_usec() - t0
	build_ticks += 1
	ready = _next_row >= n
	return ready

## Re-test the next `count` cells of a slow round-robin sweep over the whole
## grid, so geometry that changed without an event (a crate pushed or broken,
## a low wall or platform added) reaches the grid within a few seconds.
## Dead bodies, ragdolls, debris and props are never on the tested layers.
func sweep_step(count: int) -> void:
	if _space == null or not ready or count <= 0:
		return
	var t0 := Time.get_ticks_usec()
	for k in count:
		@warning_ignore("integer_division")
		var id := Vector2i(_sweep_next % n, _sweep_next / n)
		_test_cell(id)
		_sweep_next = (_sweep_next + 1) % (n * n)
	sweep_cells += count
	sweep_usec += Time.get_ticks_usec() - t0

## Re-test the cells within `radius` of `center` (a wall broke, a prop went).
func refresh(center: Vector3, radius: float) -> void:
	if _space == null or not ready:
		return
	var t0 := Time.get_ticks_usec()
	var c := cell_of(center)
	var r := int(ceil(radius / CELL))
	for j in range(c.y - r, c.y + r + 1):
		for i in range(c.x - r, c.x + r + 1):
			var id := Vector2i(i, j)
			if astar.is_in_boundsv(id) and cell_center(id).distance_to(Vector3(center.x, 0.0, center.z)) <= radius + CELL:
				_test_cell(id)
				refresh_cells += 1
	refresh_usec += Time.get_ticks_usec() - t0

func _test_cell(id: Vector2i) -> void:
	var p := cell_center(id)
	var xf := Transform3D(Basis(), Vector3(p.x, FLOOR_Y + BODY_CENTER, p.z))
	_params.transform = xf
	var solid := not _space.intersect_shape(_params, 1).is_empty()
	astar.set_point_solid(id, solid)
	var wide_solid := solid
	if not solid:
		_params_wide.transform = xf
		wide_solid = not _space.intersect_shape(_params_wide, 1).is_empty()
	astar_wide.set_point_solid(id, wide_solid)

## Cells within `radius` of `center` cost PENALTY_WEIGHT x to cross on both
## layers for PENALTY_TIME s (an enemy wedged there: route round if you can).
func penalize(center: Vector3, radius: float) -> void:
	if not ready:
		return
	var c := cell_of(center)
	var r := int(ceil(radius / CELL))
	var cells: Array[Vector2i] = []
	for j in range(c.y - r, c.y + r + 1):
		for i in range(c.x - r, c.x + r + 1):
			var id := Vector2i(i, j)
			if astar.is_in_boundsv(id) and cell_center(id).distance_to(Vector3(center.x, 0.0, center.z)) <= radius:
				astar.set_point_weight_scale(id, PENALTY_WEIGHT)
				astar_wide.set_point_weight_scale(id, PENALTY_WEIGHT)
				cells.append(id)
	_penalties.append([_sim_now() + PENALTY_TIME, cells])

## Lift expired penalties (AttackDirector calls this every tick).
func expire_penalties() -> void:
	if _penalties.is_empty():
		return
	var now := _sim_now()
	var keep: Array = []
	for pen: Array in _penalties:
		if now < float(pen[0]):
			keep.append(pen)
			continue
		for id: Vector2i in pen[1]:
			astar.set_point_weight_scale(id, 1.0)
			astar_wide.set_point_weight_scale(id, 1.0)
	_penalties = keep

## A SEE_RADIUS sphere swept at SEE_HEIGHT (over desks and low clutter, under
## wall tops) from `a` to `b` misses walls and pillars: a line with margin, so
## a path never starts round a corner it only grazes.
func _sees(a: Vector3, b: Vector3) -> bool:
	if _space == null:
		return true
	var motion := Vector3(b.x - a.x, 0.0, b.z - a.z)
	if motion.length() < 0.01:
		return true
	_see_params.transform = Transform3D(Basis(), Vector3(a.x, FLOOR_Y + SEE_HEIGHT, a.z))
	_see_params.motion = motion
	var r := _space.cast_motion(_see_params)
	return r.size() == 0 or r[0] >= 1.0

## Simulation clock (physics ticks): in step with the game under --fixed-fps.
static func _sim_now() -> float:
	return Engine.get_physics_frames() / float(Engine.physics_ticks_per_second)

func cell_of(p: Vector3) -> Vector2i:
	return Vector2i(int(floor((p.x + HALF) / CELL)), int(floor((p.z + HALF) / CELL)))

func cell_center(id: Vector2i) -> Vector3:
	return Vector3(-HALF + (id.x + 0.5) * CELL, 0.0, -HALF + (id.y + 0.5) * CELL)

func is_walkable(p: Vector3, wide := false) -> bool:
	var id := cell_of(p)
	var g := astar_wide if wide else astar
	return g.is_in_boundsv(id) and not g.is_point_solid(id)

## Nearest free cell to `id` within NEAREST_FREE_RINGS rings (Vector2i(-1, -1)
## if none). With `seen_from` (the body's position) only cells it can see over
## the furniture count: a body standing in a solid cell (against a desk in an
## office) must not start its path on the far side of a wall.
func free_cell_near(id: Vector2i, wide := false, seen_from := Vector3.INF) -> Vector2i:
	var g := astar_wide if wide else astar
	if g.is_in_boundsv(id) and not g.is_point_solid(id):
		return id
	for r in range(1, NEAREST_FREE_RINGS + 1):
		var best := Vector2i(-1, -1)
		var best_d := INF
		for j in range(id.y - r, id.y + r + 1):
			for i in range(id.x - r, id.x + r + 1):
				if absi(i - id.x) != r and absi(j - id.y) != r:
					continue
				var c := Vector2i(i, j)
				if g.is_in_boundsv(c) and not g.is_point_solid(c):
					var d := Vector2(c - id).length_squared()
					if d < best_d and (seen_from == Vector3.INF or _sees(seen_from, cell_center(c))):
						best_d = d
						best = c
		if best.x >= 0:
			return best
	return Vector2i(-1, -1)

## Path from `from` to `to` as world points at from.y (partial when `to` is
## unreachable). Empty when either end has no free cell nearby. `wide`: on
## the wide layer (bodies wider than BODY_RADIUS).
func find_path(from: Vector3, to: Vector3, wide := false) -> PackedVector3Array:
	var out := PackedVector3Array()
	if not ready:
		return out
	var g := astar_wide if wide else astar
	var t0 := Time.get_ticks_usec()
	var a := free_cell_near(cell_of(from), wide, from)
	var b := free_cell_near(cell_of(to), wide, to)
	last_path_complete = false
	if a.x >= 0 and b.x >= 0:
		var pts := g.get_point_path(a, b, true)
		for p in pts:
			out.append(Vector3(p.x, from.y, p.y))
		last_path_complete = not pts.is_empty() and pts[-1].distance_to(g.get_point_position(b)) < CELL * 0.5
	path_queries += 1
	path_usec += Time.get_ticks_usec() - t0
	return out

static func path_length(from: Vector3, path: PackedVector3Array) -> float:
	var total := 0.0
	var prev := from
	for p in path:
		total += Vector2(p.x - prev.x, p.z - prev.z).length()
		prev = p
	return total

func get_stats() -> Dictionary:
	return {"cells": n * n, "build_ms": build_usec / 1000.0, "build_ticks": build_ticks,
		"build_ms_per_tick": build_usec / 1000.0 / maxf(build_ticks, 1),
		"path_queries": path_queries, "path_us_avg": path_usec / float(maxi(path_queries, 1)),
		"refresh_cells": refresh_cells, "refresh_ms": refresh_usec / 1000.0,
		"sweep_cells": sweep_cells, "sweep_us_per_cell": sweep_usec / float(maxi(sweep_cells, 1))}
