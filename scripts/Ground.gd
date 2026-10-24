extends Node2D
## Draws the endless ground (GAME.md §10) and owns the prop list you can edit.
##
## It is a child of Main's `world` node, so every coordinate here is a world
## coordinate and the camera offset is already handled. Nothing about the map is
## stored: cells are hashed from GroundDef.SEED, so the world is infinite,
## identical on every visit, and costs nothing to keep.
##
## Everything that moves -- grass, reeds, canopies, water glints -- is driven by
## one `_wind` clock and the shared Art.sway(), so the map breathes instead of
## individual props jittering. Animation switches itself off below ~45 fps,
## because a stuttering wind is far more noticeable than a still one.

const CELL: float = GroundDef.CELL
const _SAVE_PATH := "user://ground_props.json"
## Below this many cells in view the ground gets the full detail pass.
const MAX_DETAIL_CELLS := 320
const ANIM_FPS := 45.0
## How far the drone's downwash reaches across the map, in logical units. Foliage
## inside it bends away from the hull, so flying low over a wood is something you
## watch happen rather than something you only hear about.
const DOWNWASH := 210.0
## Vertices in a leaf mass outline. Enough to read as a scalloped crown, few
## enough that a whole wood costs less than one circle stack did.
const BLOB_STEPS := 22
## Foliage is redrawn at this rate rather than every frame: wind at 30 fps looks
## the same as wind at 60, and the ground is the most expensive item on screen.
const WIND_HZ := 30.0

var seed_value: int = GroundDef.SEED
var _placed: Array = []
var _quantized := Vector2(INF, INF)
var _wind := 0.0
var _wind_timer := 0.0
var _anim := true
var _manual := false
var _fps_timer := 0.0
var _cells_drawn := 0
var _props_drawn := 0
var _detailed := true
var _drone_at := Vector2.INF
## Cost accounting for the debug overlay: the whole map is one CanvasItem, so the
## only thing that matters is how long a full redraw takes and how often it runs.
var _draw_us := 0.0
var _draw_count := 0
## Temporary phase breakdown, printed only by the debug overlay. The whole map is
## one CanvasItem, so this is where a 28 ms redraw either gets explained or gets
## fixed.
var _us := {"cells": 0.0, "river": 0.0, "roads": 0.0, "props": 0.0}

func _ready() -> void:
	load_layout()
	Layout.camera_moved.connect(_on_view_changed)
	Layout.resized.connect(_on_view_changed)
	queue_redraw()

func _process(delta: float) -> void:
	_fps_timer += delta
	if _fps_timer >= 1.0:
		_fps_timer = 0.0
		# An explicit set_animated() is a decision, not a suggestion: without this
		# flag the fps controller silently overrules it a second later and the knob
		# documented in the README does nothing.
		if not _manual:
			var fps := Engine.get_frames_per_second()
			if fps > 0.0:
				# Small hysteresis so a single slow frame cannot toggle the effect off.
				_anim = fps >= ANIM_FPS if not _anim else fps >= ANIM_FPS - 5.0
	if _anim:
		_wind += delta
		_wind_timer += delta
		if _wind_timer >= 1.0 / WIND_HZ:
			_wind_timer = 0.0
			queue_redraw()
	else:
		_on_view_changed()

func _on_view_changed(_v: Vector2 = Vector2.INF) -> void:
	# Redrawing every pixel of camera travel is wasted work: the map is cell
	# based, so a half-cell of movement is the finest change anyone can see.
	var q := (Layout.camera / (CELL * 0.5)).round()
	if q != _quantized:
		_quantized = q
		queue_redraw()

## How hard the rotors are hitting a plant this far from the hull, 0..1. Squared
## so the edge of the cone is soft -- a linear fall-off has a visible ring round
## the drone where grass snaps from bent to straight in one step.
func gust(dist: float) -> float:
	if dist >= DOWNWASH:
		return 0.0
	var k := 1.0 - dist / DOWNWASH
	return k * k

## Which way and how far a crown of this radius is pushed by the downwash: away
## from the hull, because that is the direction the air is actually going.
func downwash(at: Vector2, hull: Vector2, radius: float) -> Vector2:
	if hull == Vector2.INF:
		return Vector2.ZERO
	var to_plant := at - hull
	var dist := to_plant.length()
	var g := gust(dist)
	if g <= 0.001:
		return Vector2.ZERO
	return (to_plant / maxf(1.0, dist)) * g * radius * 0.5

func downwash_radius() -> float:
	return DOWNWASH

# ------------------------------------------------------------------- drawing --
func _draw() -> void:
	var t0 := Time.get_ticks_usec()
	var view: Rect2 = Layout.view.grow(CELL * 1.5)
	# One lookup per redraw: every prop asks this same point for its gust, so a
	# whole wood leans away from one hull rather than each tree inventing its own.
	var drone: Node = get_tree().get_first_node_in_group("drone")
	_drone_at = drone.position if drone != null else Vector2.INF
	var x0: int = int(floor(view.position.x / CELL))
	var x1: int = int(ceil(view.end.x / CELL))
	var y0: int = int(floor(view.position.y / CELL))
	var y1: int = int(ceil(view.end.y / CELL))
	_cells_drawn = (x1 - x0 + 1) * (y1 - y0 + 1)
	_detailed = _cells_drawn <= MAX_DETAIL_CELLS
	_cells_drawn = 0
	_props_drawn = 0
	var t1 := Time.get_ticks_usec()
	for cy in range(y0, y1 + 1):
		for cx in range(x0, x1 + 1):
			_cells_drawn += 1
			_draw_cell(cx, cy)
	_us["cells"] += float(Time.get_ticks_usec() - t1)
	if GroundDef.ENABLED.get("river", true):
		var t2 := Time.get_ticks_usec()
		_draw_river(view)
		_us["river"] += float(Time.get_ticks_usec() - t2)
	if GroundDef.ENABLED.get("road", true):
		var t3 := Time.get_ticks_usec()
		_draw_roads(view)
		_us["roads"] += float(Time.get_ticks_usec() - t3)
	var t4 := Time.get_ticks_usec()
	for prop in _placed:
		_draw_prop(String(prop.get("type", "tree")),
			Vector2(float(prop.get("x", 0.0)), float(prop.get("y", 0.0))),
			float(prop.get("r", 0.0)), 0.0)
		_props_drawn += 1
	_us["props"] += float(Time.get_ticks_usec() - t4)
	_draw_us += float(Time.get_ticks_usec() - t0)
	_draw_count += 1

## Microseconds of the last redraw averaged over all of them, and how many have
## run. Together they say whether the detail pass is affordable at the frame rate
## the phone is actually holding.
func avg_draw_us() -> float:
	return _draw_us / maxf(1.0, float(_draw_count))

func draw_count() -> int:
	return _draw_count

func phase_us() -> Dictionary:
	var n := maxf(1.0, float(_draw_count))
	var out := {}
	for k in _us:
		out[k] = _us[k] / n
	return out

func _draw_cell(cx: int, cy: int) -> void:
	var base := Vector2(cx * CELL, cy * CELL)
	var h := _hash(cx, cy)
	var tone: float = _n(h, 1)
	var tint: Color = Art.GRASS.lerp(Art.GRASS_ALT, tone * 0.9)
	draw_rect(Rect2(base, Vector2(CELL, CELL)), tint)
	# Large tonal patches break the cell grid up at a distance.
	if tone > 0.72:
		draw_circle(base + Vector2(CELL, CELL) * Vector2(_n(h, 3), _n(h, 4)),
			CELL * (0.16 + _n(h, 2) * 0.22), Art.GRASS_LIT)
	if _n(h, 5) > 0.88:
		var patch := Rect2(base + Vector2(CELL * 0.3, CELL * 0.4),
			Vector2(CELL * 0.34, CELL * 0.15))
		draw_rect(patch, Art.DIRT)
		draw_rect(patch.grow(-2.0), Art.DIRT_DARK, false, 1.0)
	if not _detailed:
		return
	# Grass tufts: three blades each, bent by the shared wind so a field ripples.
	for t in 5:
		var ht: float = _n(h, 20 + t)
		if ht < 0.45:
			continue
		var at := base + Vector2(CELL * _n(h, 30 + t), CELL * _n(h, 40 + t))
		if GroundDef.in_river(at, 6.0) or GroundDef.in_road(at, 6.0):
			continue
		var phase: float = at.x * 0.011 + at.y * 0.007
		var bend := Art.sway(_wind, phase, 2.6)
		# Grass flattens away from the hull as well: the whole field under the drone
		# parts, which is readable long before a single tree silhouette moves.
		var push := downwash(at, _drone_at, 12.0)
		var dark := ht > 0.75
		for k in 3:
			var off := (float(k) - 1.0) * 2.4
			draw_line(at + Vector2(off, 0),
				at + Vector2(off + bend * 0.6 + push.x, -5.5 - ht * 3.0 + push.y),
				Art.GRASS_SHADE if dark else Art.GRASS_LIT, 1.4)
	if _n(h, 6) > 0.93:
		var pebble := base + Vector2(CELL * _n(h, 7), CELL * _n(h, 8))
		if not GroundDef.in_river(pebble, 4.0) and not GroundDef.in_road(pebble, 4.0):
			Art.contact(self, pebble, 3.2 * _n(h, 9) + 1.6, 0.7)
			draw_circle(pebble - Vector2(0.6, 0.8), 2.6 * _n(h, 9) + 1.2, Art.STONE)
	if _n(h, 10) > 0.90:
		var flower := base + Vector2(CELL * _n(h, 11), CELL * _n(h, 12))
		if not GroundDef.in_river(flower, 6.0) and not GroundDef.in_road(flower, 6.0):
			var col := Color(0.95, 0.86, 0.35) if _n(h, 13) > 0.5 else Color(0.92, 0.55, 0.72)
			for k in 3:
				draw_circle(flower + Vector2.RIGHT.rotated(float(k) * 2.1) * 2.6,
					1.9, col)

	var kind: String = GroundDef.pick(_n(h, 14))
	if kind == "":
		return
	var def: Dictionary = GroundDef.def(kind)
	var jitter := Vector2(_n(h, 15) - 0.5, _n(h, 16) - 0.5) * CELL * 0.62
	var at2 := base + Vector2(CELL, CELL) * 0.5 + jitter
	# Props never grow in water or across a road.
	if GroundDef.in_river(at2, 18.0) or GroundDef.in_road(at2, 20.0):
		return
	var r: float = lerpf(float(def.r_min), float(def.r_max), _n(h, 17))
	if _n(h, 18) > 0.5:
		r *= 0.82                    # half the props are juveniles: breaks up tiling
	_draw_prop(kind, at2, r, _n(h, 19) * TAU)
	_props_drawn += 1

func _draw_prop(kind: String, at: Vector2, r: float, phase: float) -> void:
	var def: Dictionary = GroundDef.def(kind)
	if def.is_empty():
		return
	var radius: float = r if r > 0.0 else float(def.r_min)
	var leaf: Color = def.leaf
	var lit: Color = def.leaf_lit
	var trunk: Color = def.trunk
	match String(def.shape):
		"rock":
			Art.soft_shadow(self, at, radius * 0.9, radius * 0.5)
			var pts := PackedVector2Array()
			for i in 7:
				var a := float(i) / 7.0 * TAU
				var k := 0.74 + 0.26 * cos(a * 3.0 + radius + phase)
				pts.append(at + Vector2.RIGHT.rotated(a) * radius * k)
			draw_colored_polygon(pts, Art.shaded(leaf))
			# Sun hits the far side from the light, which is what gives a rock mass.
			draw_colored_polygon(PackedVector2Array([
				at + Vector2.RIGHT.rotated(-2.3) * radius * 0.62,
				at + Vector2.RIGHT.rotated(-1.1) * radius * 0.7,
				at + Vector2.RIGHT.rotated(0.1) * radius * 0.5,
				at + Vector2(0, -radius * 0.18)]), Art.sunlit(leaf))
			draw_polyline(pts, Art.shaded(leaf, 1.6), 1.6)
		"bush":
			_draw_bush(at, radius, leaf, lit, trunk)
		"pine":
			_draw_pine(at, radius, leaf, lit, trunk)
		"house":
			_draw_house(at, radius, def)
		_:
			# "blob": the broadleaf tree
			_draw_tree(at, radius, leaf, lit, trunk)

## Buildings seen from directly above show a roof and nothing else. The old version
## drew a door and a window, which are on walls that face the ground from here:
## every side of the building is invisible at this camera angle. So: an eave that
## overhangs the wall it protects, hip faces meeting a centre ridge (or two gable
## slopes on some plans), each face toned by how it faces the sun, shingle
## courses, a ridge cap, and a chimney throwing its own short shadow.
func _draw_house(at: Vector2, radius: float, def: Dictionary) -> void:
	var salt := _plant_salt(at)
	var hw := radius * 0.75
	var hd := radius * 0.575
	var eave := radius * 0.11
	var rx := hw + eave
	var ry := hd + eave
	# The wall plate, inset under the overhang: what little of it shows reads as a
	# shadow line under the eaves, which is the only clue that the building has
	# thickness rather than being a decal.
	draw_rect(Rect2(at - Vector2(hw, hd), Vector2(hw, hd) * 2.0),
		Art.shaded(def.leaf_lit, 0.75))
	# A roof sits high enough to throw a whole offset shape, not a contact blob.
	draw_rect(Rect2(at - Vector2(rx, ry) + Art.shadow_offset(radius * 1.15),
		Vector2(rx, ry) * 2.0), Color(0.02, 0.03, 0.04, 0.34))
	Art.contact(self, at, radius * 0.72, 0.6)

	var gable := _n(salt, 1) > 0.5
	var hr: float = maxf(radius * 0.08, rx - ry * 0.75)
	var polys: Array[PackedVector2Array] = []
	var normals: Array[Vector2] = []
	if gable:
		polys.append(PackedVector2Array([at + Vector2(-rx, -ry), at + Vector2(rx, -ry),
			at + Vector2(rx, 0.0), at + Vector2(-rx, 0.0)]))
		normals.append(Vector2.UP)
		polys.append(PackedVector2Array([at + Vector2(-rx, ry), at + Vector2(rx, ry),
			at + Vector2(rx, 0.0), at + Vector2(-rx, 0.0)]))
		normals.append(Vector2.DOWN)
	else:
		# Hip: two trapezoids and two triangles, all convex, all sharing one ridge.
		polys.append(PackedVector2Array([at + Vector2(-rx, -ry), at + Vector2(rx, -ry),
			at + Vector2(hr, 0.0), at + Vector2(-hr, 0.0)]))
		normals.append(Vector2.UP)
		polys.append(PackedVector2Array([at + Vector2(-rx, ry), at + Vector2(rx, ry),
			at + Vector2(hr, 0.0), at + Vector2(-hr, 0.0)]))
		normals.append(Vector2.DOWN)
		polys.append(PackedVector2Array([at + Vector2(rx, -ry), at + Vector2(rx, ry),
			at + Vector2(hr, 0.0)]))
		normals.append(Vector2.RIGHT)
		polys.append(PackedVector2Array([at + Vector2(-rx, -ry), at + Vector2(-rx, ry),
			at + Vector2(-hr, 0.0)]))
		normals.append(Vector2.LEFT)
	var base_dark := Art.shaded(def.leaf, 1.2)
	var base_lit := Art.sunlit(def.leaf, 1.25)
	for i in polys.size():
		var nrm: Vector2 = normals[i]
		# One slope, one tone: the face whose normal points at the light is bright,
		# the one pointing away is nearly black, and that contrast is what makes the
		# roof read as solid instead of flat.
		var t := clampf(0.5 + 0.62 * nrm.dot(-Art.SUN), 0.0, 1.0)
		var face := base_dark.lerp(base_lit, t)
		draw_colored_polygon(polys[i], face)
		if _detailed:
			# Shingle courses, one step darker each way up the slope.
			var pts: PackedVector2Array = polys[i]
			for k in range(1, 3):
				var f := float(k) / 3.0
				draw_line(pts[0].lerp(pts[pts.size() - 1], f),
					pts[1].lerp(pts[pts.size() - 1], f),
					Color(face.r, face.g, face.b, 0.35), maxf(1.0, radius * 0.022))
	# Ridge and hip seams: the joints between faces are darker lines, not gaps.
	draw_line(at + Vector2(-hr, 0.0), at + Vector2(hr, 0.0),
		Art.sunlit(def.leaf, 1.6), maxf(1.4, radius * 0.05))
	if not gable:
		for corner in [Vector2(-rx, -ry), Vector2(rx, -ry), Vector2(rx, ry), Vector2(-rx, ry)]:
			draw_line(at + corner, at + Vector2(signf(corner.x) * hr, 0.0),
				Color(0.05, 0.06, 0.07, 0.35), maxf(1.0, radius * 0.026))
	draw_polyline(PackedVector2Array([at + Vector2(-rx, -ry), at + Vector2(rx, -ry),
		at + Vector2(rx, ry), at + Vector2(-rx, ry), at + Vector2(-rx, -ry)]),
		Art.shaded(def.leaf, 1.5), maxf(1.2, radius * 0.03))

	# Chimney: a small block on the cool side of the ridge with its own shadow and
	# a soot stain down the slope, because nothing on a roof is flush with it.
	var stack := at + Vector2(-hr * 0.45, -ry * 0.34)
	var sh := Art.shadow_offset(radius * 0.5)
	draw_rect(Rect2(stack + sh - Vector2(radius * 0.09, radius * 0.09),
		Vector2(radius * 0.18, radius * 0.18)), Color(0.02, 0.03, 0.04, 0.3))
	draw_rect(Rect2(stack - Vector2(radius * 0.11, radius * 0.11),
		Vector2(radius * 0.22, radius * 0.22)), Art.shaded(def.trunk, 0.6))
	draw_rect(Rect2(stack - Vector2(radius * 0.07, radius * 0.07),
		Vector2(radius * 0.14, radius * 0.14)), def.trunk)
	# A skylight on the lit slope, the one thing on a roof that is obviously glass.
	if _n(salt, 7) > 0.35:
		var sky := at + (-Art.SUN) * ry * 0.42 + Vector2(hr * 0.3, 0.0)
		draw_rect(Rect2(sky - Vector2(radius * 0.1, radius * 0.06),
			Vector2(radius * 0.2, radius * 0.12)), Color(0.74, 0.85, 0.9, 0.9))
		draw_line(sky + Vector2(-radius * 0.1, 0.0), sky + Vector2(radius * 0.1, 0.0),
			Color(0.2, 0.28, 0.34, 0.6), 1.0)

# --------------------------------------------------------------------- water --
func _draw_river(view: Rect2) -> void:
	var step := 42.0
	var x: float = view.position.x
	var centre := PackedVector2Array()
	while x <= view.end.x:
		centre.append(Vector2(x, GroundDef.river_y(x)))
		x += step
	if centre.size() < 2:
		return
	var half := GroundDef.RIVER_WIDTH * 0.5
	# Wet sand reads as a gradient, so two stacked bands do what a shader would.
	draw_polyline(_offset(centre, -half * 1.5), Art.WET_SAND.lightened(0.12),
		GroundDef.RIVER_WIDTH * 1.9)
	draw_polyline(_offset(centre, -half * 1.12), Art.WET_SAND, GroundDef.RIVER_WIDTH * 1.24)
	draw_polyline(centre, GroundDef.WATER, GroundDef.RIVER_WIDTH)
	draw_polyline(_offset(centre, half * 0.22), GroundDef.WATER_DEEP,
		GroundDef.RIVER_WIDTH * 0.5)
	# Glints: short bright dashes that drift downstream.
	for i in centre.size():
		var p: Vector2 = centre[i]
		var t := _n(int(p.x * 7.0), 3)
		if t < 0.62:
			continue
		var drift := fmod(_wind * 26.0 + t * 400.0, 90.0) - 45.0
		var wide := 9.0 + t * 12.0
		var y := p.y + (t - 0.8) * half * 0.9
		draw_line(Vector2(p.x + drift - wide * 0.5, y), Vector2(p.x + drift + wide * 0.5, y),
			Color(0.72, 0.87, 0.96, 0.30 + 0.2 * sin(_wind * 2.0 + t * 9.0)), 2.0)
	if _detailed:
		_draw_reeds(view, centre, half)

func _draw_reeds(view: Rect2, centre: PackedVector2Array, half: float) -> void:
	for i in range(0, centre.size(), 2):
		var p: Vector2 = centre[i]
		for side in [-1.0, 1.0]:
			var at := Vector2(p.x + sin(p.x * 0.05) * 8.0, p.y + side * half * 1.18)
			if GroundDef.in_road(at, 12.0):
				continue
			var bend := Art.sway(_wind, at.x * 0.05, 5.0)
			for k in 3:
				var off := (float(k) - 1.0) * 3.0
				draw_line(at + Vector2(off, 0), at + Vector2(off + bend, -13.0 - k * 2.0),
					Color(0.30, 0.45, 0.24, 0.9), 1.6)

func _offset(pts: PackedVector2Array, dy: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in pts:
		out.append(p + Vector2(0, dy))
	return out

# --------------------------------------------------------------------- roads --
func _draw_roads(view: Rect2) -> void:
	var step := 44.0
	var reach := GroundDef.BEND_A * 1.2 + GroundDef.BEND_B + GroundDef.ROAD_WIDTH
	var k_lo: int = int(floor((view.position.x - reach) / GroundDef.ROAD_SPACING)) - 1
	var k_hi: int = int(ceil((view.end.x + reach) / GroundDef.ROAD_SPACING)) + 1
	for k in range(k_lo, k_hi + 1):
		var pts := PackedVector2Array()
		var y: float = view.position.y - step
		while y <= view.end.y + step:
			pts.append(Vector2(GroundDef.road_x(y, k), y))
			y += step
		_draw_road(pts, step)
	k_lo = int(floor((view.position.y - reach) / GroundDef.ROAD_SPACING)) - 1
	k_hi = int(ceil((view.end.y + reach) / GroundDef.ROAD_SPACING)) + 1
	for k in range(k_lo, k_hi + 1):
		var pts2 := PackedVector2Array()
		var x2: float = view.position.x - step
		while x2 <= view.end.x + step:
			pts2.append(Vector2(x2, GroundDef.road_y(x2, k)))
			x2 += step
		_draw_road(pts2, step)

func _draw_road(pts: PackedVector2Array, step: float) -> void:
	if pts.size() < 2:
		return
	var w := GroundDef.ROAD_WIDTH
	# Graded shoulder, then asphalt, then the sun-faded wheel tracks that make a
	# road look used rather than freshly painted.
	draw_polyline(pts, GroundDef.ROAD_EDGE.darkened(0.35), w + 20.0)
	draw_polyline(pts, GroundDef.ROAD_EDGE, w + 8.0)
	draw_polyline(pts, GroundDef.ROAD, w)
	draw_polyline(_perp(pts, -w * 0.24), GroundDef.ROAD.darkened(0.16), w * 0.2)
	draw_polyline(_perp(pts, w * 0.24), GroundDef.ROAD.darkened(0.16), w * 0.2)
	if _detailed:
		for i in pts.size():
			if i % 2:
				continue
			var p: Vector2 = pts[i]
			var seed_i := int(p.x * 3.1 + p.y * 7.7)
			for s in 3:
				if _n(seed_i, s) < 0.55:
					continue
				var off := (_n(seed_i, 10 + s) - 0.5) * w * 0.8
				draw_circle(_perp_at(pts, i, off) + Vector2(0, _n(seed_i, 20 + s) * 6.0),
					1.3, Color(0, 0, 0, 0.13))
	_draw_dashes(pts, step)

func _draw_dashes(pts: PackedVector2Array, step: float) -> void:
	var dash := PackedVector2Array()
	for i in pts.size():
		if int(floor(float(i) * step / 70.0)) % 2 == 0:
			dash.append(pts[i])
		elif dash.size() > 1:
			draw_polyline(dash, GroundDef.ROAD_LINE, 5.0)
			dash = PackedVector2Array()
			dash.append(pts[i])
	if dash.size() > 1:
		draw_polyline(dash, GroundDef.ROAD_LINE, 5.0)

## Offset a sampled path sideways, used for shoulders and wheel tracks.
func _perp(pts: PackedVector2Array, dist: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in pts.size():
		out.append(_perp_at(pts, i, dist))
	return out

func _perp_at(pts: PackedVector2Array, i: int, dist: float) -> Vector2:
	var a: Vector2 = pts[maxi(0, i - 1)]
	var b: Vector2 = pts[mini(pts.size() - 1, i + 1)]
	var n := (b - a).orthogonal().normalized()
	return pts[i] + n * dist

# ------------------------------------------------------------------- editing --
func add_prop(type: String, at: Vector2, radius := 0.0) -> bool:
	if not GroundDef.PROPS.has(type):
		push_warning("unknown ground prop type: " + type)
		return false
	_placed.append({"type": type, "x": at.x, "y": at.y, "r": radius})
	save_layout()
	queue_redraw()
	return true

## Removes the closest hand-placed prop within `radius`. Returns false when
## nothing was near enough, so callers can tell a miss from a delete.
func remove_prop_near(at: Vector2, radius := 90.0) -> bool:
	var best := -1
	var best_d := radius
	for i in _placed.size():
		var d := Vector2(float(_placed[i].x), float(_placed[i].y)).distance_to(at)
		if d < best_d:
			best_d = d
			best = i
	if best < 0:
		return false
	_placed.remove_at(best)
	save_layout()
	queue_redraw()
	return true

func clear_placed() -> void:
	_placed.clear()
	save_layout()
	queue_redraw()

func placed() -> Array:
	return _placed.duplicate()

func set_enabled(type: String, on: bool) -> void:
	GroundDef.ENABLED[type] = on
	queue_redraw()

func reseed(value: int) -> void:
	seed_value = value
	queue_redraw()

func set_animated(on: bool) -> void:
	_anim = on
	_manual = true

func animated() -> bool:
	return _anim

func cells_in_view() -> int:
	return _cells_drawn

func props_in_view() -> int:
	return _props_drawn

func save_layout() -> void:
	var f := FileAccess.open(_SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("could not write " + _SAVE_PATH)
		return
	f.store_string(JSON.stringify(_placed))

func load_layout() -> void:
	_placed = GroundDef.PLACED.duplicate(true)
	if not FileAccess.file_exists(_SAVE_PATH):
		return
	var f := FileAccess.open(_SAVE_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) == TYPE_ARRAY:
		for entry in parsed:
			if typeof(entry) == TYPE_DICTIONARY and GroundDef.PROPS.has(String(entry.get("type", ""))):
				_placed.append(entry)

# -------------------------------------------------------------- deterministic --
func _hash(cx: int, cy: int) -> int:
	return hash(Vector2i(cx, cy) + Vector2i(seed_value, -seed_value))

## Deterministic 0..1 from a cell hash. Cheap integer mix, so the same cell always
## grows the same tree no matter when or how often it is drawn.
func _n(v: int, salt: int) -> float:
	var x := int(v * 374761393 + salt * 668265263)
	x = (x ^ (x >> 13)) * 1274126177
	x = x ^ (x >> 16)
	return float(x & 0xFFFF) / 65535.0

# ------------------------------------------------------------------ planting --
## One scalloped blob, used for every leaf mass on the map. A Ghibli canopy reads
## as a single volume with a bumpy edge rather than as stacked circles, and it
## costs BLOB_STEPS triangles where a stack of lobes cost hundreds. The radius
## only ever wobbles around the centre, so the outline is star-shaped and cannot
## fold over itself -- which is what the triangulator refuses, with an error.
func _blob(at: Vector2, radius: float, wobble: float, scallops: float,
		tone: Color, twist: float = 0.0) -> void:
	var pts := PackedVector2Array()
	for i in BLOB_STEPS:
		var a := TAU * float(i) / float(BLOB_STEPS)
		var r := radius * (1.0 - wobble * 0.5 * (1.0 - cos(a * scallops + twist)))
		pts.append(at + Vector2.RIGHT.rotated(a) * r)
	draw_colored_polygon(pts, tone)
## A per-plant noise stream. Keyed on position rather than on the cell hash so a
## hand-placed tree gets the same irregular crown as a scattered one.
func _plant_salt(at: Vector2) -> int:
	return int(at.x * 127.1 + at.y * 311.7)

## Broadleaf tree: three nested scalloped masses -- underside shadow, leaf body,
## sunlit outer mass -- then dapples of lighter leaf clusters on the lit side.
## Layered tone bands are what the eye reads as a volume of leaves; a circle with
## a highlight on it is a green disc. Measured cost decided the method: the same
## three tones built from overlapping circles doubled the ground's redraw time.
func _draw_tree(at: Vector2, radius: float, leaf: Color, lit: Color,
		trunk: Color) -> void:
	var salt := _plant_salt(at)
	var push := downwash(at, _drone_at, radius)
	var g := 0.0
	if _drone_at != Vector2.INF:
		g = gust(at.distance_to(_drone_at))
	# The weather sways slowly; the rustle below is high-frequency and only ever
	# appears under the hull, which is what makes the drone's passage visible on
	# the ground rather than implied by it.
	var lean := Art.sway(_wind, at.x * 0.008 + at.y * 0.005, radius * 0.11)
	var rustle := sin(_wind * 19.0 + float(salt % 17)) * radius * 0.10 * g
	var crown := at + Vector2(lean + rustle, -radius * 0.66) + push
	Art.soft_shadow(self, at + push * 0.5, radius * 1.0, radius * 1.9)

	# Trunk: drawn as stacked lines rather than a quad, because the crown slides
	# sideways under the downwash and a four-point trunk built from two moving
	# points folds over itself -- the triangulator refuses that and logs an error.
	# A wide base line plus a shaded and a lit narrower line reads as a cylinder.
	var spread := radius * 0.17
	var top := crown + Vector2(0.0, radius * 0.55)
	draw_line(at, top, trunk, maxf(1.8, radius * 0.24))
	draw_line(at + Vector2(-spread * 0.3, 0.0), top,
		Art.shaded(trunk, 0.75), maxf(1.0, radius * 0.1))
	draw_line(at + Vector2(spread * 0.35, 0.0), top,
		Art.sunlit(trunk, 0.9), maxf(0.8, radius * 0.07))
	for k in 3:
		var out := (float(k) - 1.0) * spread * 1.7
		draw_line(at + Vector2(out * 0.35, spread * 0.2), at + Vector2(out, spread * 1.3),
			Art.shaded(trunk, 0.9), maxf(1.0, radius * 0.075))
	Art.contact(self, at, radius * 0.32, 0.85)

	var shade := Art.shaded(leaf, 1.2)
	var sun := Art.sunlit(lit)
	var scallops: float = 5.0 + floor(_n(salt, 4) * 3.0)
	# Three nested bands, each one higher and lighter than the last, twisted
	# differently so their scalloped edges never line up into one contour.
	_blob(crown + Vector2(0.0, radius * 0.10), radius, 0.26, scallops, shade)
	_blob(crown - Vector2(0.0, radius * 0.05), radius * 0.93, 0.24, scallops, leaf, 1.05)
	_blob(crown + Art.lit_offset(radius * 0.3) - Vector2(0.0, radius * 0.08),
		radius * 0.66, 0.22, scallops, sun, 2.15)
	if not _detailed:
		return
	for i in 5:
		# Dapples: leaf clusters catching the light inside the lit mass.
		var a2 := _n(salt, 40 + i) * TAU
		var dir := Vector2.RIGHT.rotated(a2)
		var lit_side := dir.dot(-Art.SUN) > 0.15
		var spot := crown + dir * radius * ((0.1 + _n(salt, 50 + i) * 0.58)
			if lit_side else (0.06 + _n(salt, 50 + i) * 0.3))
		var tone := sun if lit_side else shade
		draw_circle(spot, radius * (0.05 + _n(salt, 60 + i) * 0.06),
			Color(tone.r, tone.g, tone.b, 0.8))
	if g > 0.2:
		# Leaves shaken loose, tumbling down and away on the same air the hull pushes.
		for i in 4:
			var t := fmod(_wind * 1.5 + _n(salt, 70 + i) * 3.0, 1.0)
			var drift := Vector2.RIGHT.rotated(_n(salt, 80 + i) * TAU) * radius * 0.9 * t \
				+ Art.WIND * radius * 1.6 * t
			var leaf_at := crown + drift + Vector2(0.0, t * radius * 1.5)
			draw_circle(leaf_at, radius * 0.05 * (1.0 - t) + 0.9,
				Color(sun.r, sun.g, sun.b, (1.0 - t) * g * 0.8))

## Conifer: tiers with a zig-zag lower edge, because needles hang in clumps and a
## straight line reads as a paper cut-out. Each tier is dark on the whole and
## lighter on the sun side, and the top tier keeps the lean of the wind.
func _draw_pine(at: Vector2, radius: float, leaf: Color, lit: Color,
		trunk: Color) -> void:
	var salt := _plant_salt(at)
	var push := downwash(at, _drone_at, radius) * 0.7
	Art.soft_shadow(self, at + push * 0.4, radius * 0.8, radius * 1.8)
	draw_rect(Rect2(at + Vector2(-radius * 0.09, radius * 0.12),
		Vector2(radius * 0.18, radius * 0.55)), Art.shaded(trunk, 0.8))
	Art.contact(self, at, radius * 0.26, 0.8)
	var lit_side := 1.0 if -Art.SUN.x >= 0.0 else -1.0
	for i in 3:
		var tier := radius * (1.0 - float(i) * 0.23)
		var y := at.y + radius * 0.2 - float(i) * radius * 0.55
		var bend := Art.sway(_wind, at.x * 0.01 + float(i), tier * 0.07) \
			+ push.x * (0.35 + float(i) * 0.3)
		var apex := Vector2(at.x + bend, y - tier * 1.2)
		var steps := 6 if _detailed else 3
		var pts := PackedVector2Array()
		pts.append(apex)
		for s in steps + 1:
			var f := float(s) / float(steps)
			pts.append(Vector2(at.x + bend - tier * 0.8 + f * tier * 1.6,
				y - (tier * 0.18 if int(s) % 2 == 0 else 0.0)))
		draw_colored_polygon(pts, Art.shaded(leaf, 0.65 + float(i) * 0.25))
		# The lit flank: one wedge per tier, always on the same side as every other
		# shadow on the map, which is what lets the eye read the light at all.
		draw_colored_polygon(PackedVector2Array([
			apex, Vector2(at.x + bend + lit_side * tier * 0.78, y - tier * 0.06),
			Vector2(at.x + bend, y)]), Art.sunlit(lit, 0.5 + float(i) * 0.2))

## Shrubs get the same three-tone canopy as a tree, just low and in one cluster.
func _draw_bush(at: Vector2, radius: float, leaf: Color, lit: Color,
		trunk: Color) -> void:
	var salt := _plant_salt(at)
	var push := downwash(at, _drone_at, radius * 0.8)
	Art.soft_shadow(self, at + push * 0.4, radius * 0.95, radius * 0.6)
	var drift := Vector2(Art.sway(_wind, at.x * 0.02, radius * 0.12) + push.x,
		-radius * 0.08)
	var scallops: float = 4.0 + floor(_n(salt, 6) * 2.0)
	_blob(at + drift + Vector2(0.0, radius * 0.14), radius * 1.05, 0.3, scallops,
		Art.shaded(leaf, 1.15))
	_blob(at + drift, radius * 0.9, 0.28, scallops, leaf, 1.2)
	_blob(at + drift + Art.lit_offset(radius * 0.26), radius * 0.56, 0.24, scallops,
		Art.sunlit(lit), 2.4)
	Art.contact(self, at, radius * 0.4, 0.7)
