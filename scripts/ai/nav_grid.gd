class_name AINavGrid
extends RefCounted
## Shared walkability grid for enemy navigation (round 2.5). CELL-sized cells
## over x/z in [-HALF, HALF]. A cell is solid when a body-sized capsule at
## waist height overlaps Layers.WORLD | Layers.DESTRUCTIBLE: exactly what a
## fighter capsule collides with (walls, pillars, intact wall cells, desks,
## crates). Debris, loose props and ragdolls never block a capsule, so they
## are ignored. AttackDirector owns one, builds it a few rows per physics
## tick at round start and refreshes the cells around broken walls and props.
## OWNER: agent C (AI).

const CELL := 0.4
const HALF := 18.6
const BODY_RADIUS := 0.28
const BODY_HEIGHT := 1.5
const BODY_CENTER := 0.95      ## m above the floor (bottom ~0.2 m up)
const FLOOR_Y := 0.0
const ROWS_PER_TICK := 10      ## build budget: 10 rows x 93 cells per physics tick
const NEAREST_FREE_RINGS := 4  ## cells searched round a solid start / end cell

var astar := AStarGrid2D.new()
var n := 0
var ready := false

# Cost stats (microseconds).
var build_usec := 0
var build_ticks := 0
var path_queries := 0
var path_usec := 0
var refresh_cells := 0
var refresh_usec := 0

var _next_row := 0
var _params := PhysicsShapeQueryParameters3D.new()
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
	var cap := CapsuleShape3D.new()
	cap.radius = BODY_RADIUS
	cap.height = BODY_HEIGHT
	_params.shape = cap
	_params.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE

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
	_params.transform = Transform3D(Basis(), Vector3(p.x, FLOOR_Y + BODY_CENTER, p.z))
	astar.set_point_solid(id, not _space.intersect_shape(_params, 1).is_empty())

func cell_of(p: Vector3) -> Vector2i:
	return Vector2i(int(floor((p.x + HALF) / CELL)), int(floor((p.z + HALF) / CELL)))

func cell_center(id: Vector2i) -> Vector3:
	return Vector3(-HALF + (id.x + 0.5) * CELL, 0.0, -HALF + (id.y + 0.5) * CELL)

func is_walkable(p: Vector3) -> bool:
	var id := cell_of(p)
	return astar.is_in_boundsv(id) and not astar.is_point_solid(id)

## Nearest free cell to `id` within NEAREST_FREE_RINGS rings (Vector2i(-1, -1) if none).
func free_cell_near(id: Vector2i) -> Vector2i:
	if astar.is_in_boundsv(id) and not astar.is_point_solid(id):
		return id
	for r in range(1, NEAREST_FREE_RINGS + 1):
		var best := Vector2i(-1, -1)
		var best_d := INF
		for j in range(id.y - r, id.y + r + 1):
			for i in range(id.x - r, id.x + r + 1):
				if absi(i - id.x) != r and absi(j - id.y) != r:
					continue
				var c := Vector2i(i, j)
				if astar.is_in_boundsv(c) and not astar.is_point_solid(c):
					var d := Vector2(c - id).length_squared()
					if d < best_d:
						best_d = d
						best = c
		if best.x >= 0:
			return best
	return Vector2i(-1, -1)

## Path from `from` to `to` as world points at from.y (partial when `to` is
## unreachable). Empty when either end has no free cell nearby.
func find_path(from: Vector3, to: Vector3) -> PackedVector3Array:
	var out := PackedVector3Array()
	if not ready:
		return out
	var t0 := Time.get_ticks_usec()
	var a := free_cell_near(cell_of(from))
	var b := free_cell_near(cell_of(to))
	if a.x >= 0 and b.x >= 0:
		var pts := astar.get_point_path(a, b, true)
		for p in pts:
			out.append(Vector3(p.x, from.y, p.y))
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
		"refresh_cells": refresh_cells, "refresh_ms": refresh_usec / 1000.0}
