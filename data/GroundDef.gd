class_name GroundDef
extends RefCounted
## The ground recipe, in one editable file (GAME.md §13).
##
## What scatters the map, how thick, how big, in which colours -- all here. The
## renderer (scripts/Ground.gd) knows nothing about specific prop types: it reads
## this file, so adding a plant or a ruin is a new entry in PROPS plus a
## `shape` string, and removing one is a `false` in ENABLED.
##
## Change SEED and the whole world re-rolls. Anything in PLACED -- or added at
## runtime with Ground.add_prop() -- is drawn on top of the scatter and survives
## re-seeding, so you can curate landmarks without losing the random map.

const SEED := 20261024
## Scatter cell in logical units. Smaller cells pack props in tighter and cost
## more draw calls.
const CELL := 196.0

# ------------------------------------------------------------------ palette --
const GRASS := Color(0.443, 0.639, 0.325)
const GRASS_ALT := Color(0.408, 0.608, 0.302)
const GRASS_PATCH := Color(0.494, 0.678, 0.365)
const DIRT := Color(0.737, 0.639, 0.451)
const ROAD := Color(0.416, 0.424, 0.447)
const ROAD_EDGE := Color(0.337, 0.345, 0.365)
const ROAD_LINE := Color(0.925, 0.918, 0.855)
const WATER := Color(0.263, 0.506, 0.769)
const WATER_DEEP := Color(0.204, 0.416, 0.667)
const BANK := Color(0.565, 0.620, 0.404)
const WALL := Color(0.898, 0.847, 0.741)
const ROOF := Color(0.769, 0.373, 0.255)

# -------------------------------------------------------------------- water --
const RIVER_WIDTH := 96.0
const RIVER_AMPLITUDE := 170.0
const RIVER_PERIOD := 1500.0
## World Y of the river centre at x = 0.
const RIVER_BASE_Y := 0.0

# -------------------------------------------------------------------- roads --
## Roads are not a grid. Each one is a centreline that wanders as it runs, so the
## map reads as a road network rather than a hash of straight corridors.
## road_x() is the x of vertical road k at world y; road_y() the y of horizontal
## road k at world x. Two summed sines per axis: uneven, kinked, and identical
## every time you fly back over the same ground.
const ROAD_WIDTH := 70.0
const ROAD_SPACING := 1700.0
const BEND_A := 190.0
const BEND_A_PERIOD := 900.0
const BEND_B := 46.0
const BEND_B_PERIOD := 260.0

static func road_x(y: float, k: int) -> float:
	var f := float(k)
	# Half-step offset: no road runs through the world origin, where the
	# drone spawns and animals need open ground to run across.
	return (f + 0.5) * ROAD_SPACING + sin(y / BEND_A_PERIOD + f * 1.7) * BEND_A 		+ sin(y / BEND_B_PERIOD + f) * BEND_B

static func road_y(x: float, k: int) -> float:
	var f := float(k)
	return (f + 0.5) * ROAD_SPACING + sin(x / (BEND_A_PERIOD * 1.15) + f * 2.3) * BEND_A * 1.1 		+ sin(x / (BEND_B_PERIOD * 0.8) + f * 1.4) * BEND_B

# --------------------------------------------------------------------- props --
## density  : chance a cell holds this prop at all
## r_min/r_max: canopy radius range in logical units
## shape    : "blob" (round tree) | "pine" | "rock" | "bush" | "house"
## order    : draw order; houses and rocks sit above grass patches
const PROPS := {
	"tree": {"density": 0.26, "r_min": 30.0, "r_max": 46.0, "shape": "blob",
		"leaf": Color(0.322, 0.565, 0.243), "leaf_lit": Color(0.451, 0.690, 0.310),
		"trunk": Color(0.420, 0.294, 0.184), "order": 20},
	"pine": {"density": 0.11, "r_min": 26.0, "r_max": 38.0, "shape": "pine",
		"leaf": Color(0.227, 0.439, 0.278), "leaf_lit": Color(0.302, 0.533, 0.325),
		"trunk": Color(0.373, 0.263, 0.173), "order": 21},
	"bush": {"density": 0.16, "r_min": 13.0, "r_max": 21.0, "shape": "bush",
		"leaf": Color(0.365, 0.584, 0.282), "leaf_lit": Color(0.467, 0.682, 0.341),
		"trunk": Color(0.365, 0.584, 0.282), "order": 22},
	"rock": {"density": 0.10, "r_min": 14.0, "r_max": 26.0, "shape": "rock",
		"leaf": Color(0.620, 0.624, 0.635), "leaf_lit": Color(0.753, 0.757, 0.765),
		"trunk": Color(0.475, 0.478, 0.490), "order": 23},
	"house": {"density": 0.035, "r_min": 46.0, "r_max": 66.0, "shape": "house",
		"leaf": ROOF, "leaf_lit": WALL, "trunk": Color(0.475, 0.345, 0.235), "order": 30},
}

## Flip one to false to remove that thing from the whole map. Runtime-editable
## through Ground.set_enabled(), which is why this is a static var and not a const.
static var ENABLED := {
	"tree": true, "pine": true, "bush": true, "rock": true, "house": true,
	"river": true, "road": true,
}

# --------------------------------------------------------------------- cars --
## Traffic is scenery, not an enemy: it follows the road curves and cannot hurt
## you. Raise `count` for a busier map. A hostile vehicle would be a data/Bots.gd
## entry that rides a road, not a change here.
const CARS := {
	"count": 7,
	"speed_min": 120.0,
	"speed_max": 215.0,
	"lane_offset": 17.0,
	"colors": [Color(0.86, 0.30, 0.26), Color(0.24, 0.42, 0.78),
		Color(0.90, 0.86, 0.78), Color(0.30, 0.66, 0.44),
		Color(0.86, 0.68, 0.20), Color(0.42, 0.40, 0.46)],
}

# ----------------------------------------------------------------- wildlife --
## Animals graze, wander and bolt when the drone comes near. Harmless, worth no
## points, and there so the map feels lived-in. `flee` is the radius at which
## they break and run; `graze` is how long they stand feeding between hops.
const ANIMALS := {
	"deer": {"count": 5, "speed": 150.0, "graze": 0.55, "flee": 320.0,
		"flee_speed": 380.0, "body": Color(0.72, 0.53, 0.33),
		"head": Color(0.80, 0.64, 0.44), "size": 17.0},
	"rabbit": {"count": 8, "speed": 95.0, "graze": 0.30, "flee": 190.0,
		"flee_speed": 300.0, "body": Color(0.85, 0.82, 0.76),
		"head": Color(0.92, 0.90, 0.86), "size": 8.0},
	"boar": {"count": 4, "speed": 110.0, "graze": 0.70, "flee": 240.0,
		"flee_speed": 330.0, "body": Color(0.36, 0.30, 0.27),
		"head": Color(0.48, 0.40, 0.35), "size": 13.0},
	"heron": {"count": 4, "speed": 130.0, "graze": 0.80, "flee": 280.0,
		"flee_speed": 265.0, "body": Color(0.80, 0.84, 0.88),
		"head": Color(0.92, 0.94, 0.96), "size": 11.0},
}
## Herons keep to the waterline; everything else stays out of the river.
const WATER_EDGE := ["heron"]

## Hand-placed props that always render, in world coordinates:
##   {"type": "tree", "x": 1200.0, "y": -400.0, "r": 40.0}
## `r` is optional and falls back to the prop's own radius range. Ground.add_prop()
## appends the same shape at runtime and saves it to user://ground_props.json.
const PLACED := [
	{"type": "house", "x": 0.0, "y": 0.0, "r": 62.0},
]

static func prop_ids() -> Array:
	var ids: Array = []
	for id in PROPS:
		if bool(ENABLED.get(id, true)):
			ids.append(id)
	return ids

static func def(id: String) -> Dictionary:
	return PROPS.get(id, {})

## Total probability mass, used to pick a prop from a single roll.
static func total_density() -> float:
	var total := 0.0
	for id in prop_ids():
		total += float(PROPS[id].density)
	return total

static func pick(roll: float) -> String:
	var ids := prop_ids()
	if ids.is_empty():
		return ""
	var acc := 0.0
	var target := roll * maxf(0.0001, total_density())
	for id in ids:
		acc += float(PROPS[id].density)
		if target <= acc:
			return id
	# The roll can exceed the mass of the enabled props; that cell stays empty.
	return ""

## River centre line at a world x.
static func river_y(x: float) -> float:
	if not bool(ENABLED.get("river", true)):
		return INF
	return RIVER_BASE_Y + sin(x / RIVER_PERIOD * TAU) * RIVER_AMPLITUDE \
		+ sin(x / (RIVER_PERIOD * 0.37) * TAU) * RIVER_AMPLITUDE * 0.28

static func in_river(p: Vector2, pad := 0.0) -> bool:
	var ry := river_y(p.x)
	return ry != INF and absf(p.y - ry) < RIVER_WIDTH * 0.5 + pad

static func in_road(p: Vector2, pad := 0.0) -> bool:
	if not bool(ENABLED.get("road", true)):
		return false
	return on_road(p, pad) != Vector2.INF

## Which road is under this point: the road centreline coordinate when `p` is
## inside the carriageway (plus pad), otherwise Vector2.INF. Cars use it to stay
## in their lane and the scatter uses it to keep trees off the asphalt.
static func on_road(p: Vector2, pad := 0.0) -> Vector2:
	if not bool(ENABLED.get("road", true)):
		return Vector2.INF
	var half := ROAD_WIDTH * 0.5 + pad
	var k: int = int(round(p.x / ROAD_SPACING))
	for i in range(k - 1, k + 2):
		var cx: float = road_x(p.y, i)
		if absf(p.x - cx) < half:
			return Vector2(cx, p.y)
	k = int(round(p.y / ROAD_SPACING))
	for i in range(k - 1, k + 2):
		var cy: float = road_y(p.x, i)
		if absf(p.y - cy) < half:
			return Vector2(p.x, cy)
	return Vector2.INF

## Tangent along the road at a point, so cars turn with the curve instead of
## sliding down a straight line drawn on a bent road.
static func road_heading(p: Vector2, vertical: bool) -> float:
	var step := 24.0
	if vertical:
		var k: int = int(round(p.x / ROAD_SPACING))
		return Vector2(road_x(p.y + step, k) - p.x, step).angle()
	var k2: int = int(round(p.y / ROAD_SPACING))
	return Vector2(step, road_y(p.x + step, k2) - p.y).angle()

