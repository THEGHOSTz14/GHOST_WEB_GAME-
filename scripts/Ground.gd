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

var seed_value: int = GroundDef.SEED
var _placed: Array = []
var _quantized := Vector2(INF, INF)
var _wind := 0.0
var _anim := true
var _fps_timer := 0.0
var _cells_drawn := 0
var _props_drawn := 0
var _detailed := true

func _ready() -> void:
	load_layout()
	Layout.camera_moved.connect(_on_view_changed)
	Layout.resized.connect(_on_view_changed)
	queue_redraw()

func _process(delta: float) -> void:
	_fps_timer += delta
	if _fps_timer >= 1.0:
		_fps_timer = 0.0
		var fps := Engine.get_frames_per_second()
		# Small hysteresis so a single slow frame cannot toggle the effect off.
		if fps > 0.0:
			_anim = fps >= ANIM_FPS if not _anim else fps >= ANIM_FPS - 5.0
	if _anim:
		_wind += delta
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

# ------------------------------------------------------------------- drawing --
func _draw() -> void:
	var view: Rect2 = Layout.view.grow(CELL * 1.5)
	var x0: int = int(floor(view.position.x / CELL))
	var x1: int = int(ceil(view.end.x / CELL))
	var y0: int = int(floor(view.position.y / CELL))
	var y1: int = int(ceil(view.end.y / CELL))
	_cells_drawn = (x1 - x0 + 1) * (y1 - y0 + 1)
	_detailed = _cells_drawn <= MAX_DETAIL_CELLS
	_cells_drawn = 0
	_props_drawn = 0
	for cy in range(y0, y1 + 1):
		for cx in range(x0, x1 + 1):
			_cells_drawn += 1
			_draw_cell(cx, cy)
	if GroundDef.ENABLED.get("river", true):
		_draw_river(view)
	if GroundDef.ENABLED.get("road", true):
		_draw_roads(view)
	for prop in _placed:
		_draw_prop(String(prop.get("type", "tree")),
			Vector2(float(prop.get("x", 0.0)), float(prop.get("y", 0.0))),
			float(prop.get("r", 0.0)), 0.0)
		_props_drawn += 1

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
		var dark := ht > 0.75
		for k in 3:
			var off := (float(k) - 1.0) * 2.4
			draw_line(at + Vector2(off, 0), at + Vector2(off + bend * 0.6, -5.5 - ht * 3.0),
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
			Art.soft_shadow(self, at, radius * 1.05, radius * 0.7)
			for i in 3:
				var off := Vector2.RIGHT.rotated(float(i) * 2.1 + phase) * radius * 0.5
				var bend := Art.sway(_wind, at.x * 0.02 + float(i), radius * 0.09)
				draw_circle(at + off + Vector2(bend, -radius * 0.15), radius * 0.72,
					Art.shaded(leaf, 0.8))
			draw_circle(at + Vector2(Art.sway(_wind, at.x * 0.02, radius * 0.12),
				-radius * 0.45), radius * 0.5, Art.sunlit(lit))
		"pine":
			Art.soft_shadow(self, at, radius * 0.95, radius * 1.5)
			draw_rect(Rect2(at + Vector2(-radius * 0.11, radius * 0.2),
				Vector2(radius * 0.22, radius * 0.5)), trunk)
			for i in 3:
				var tier := radius * (1.0 - float(i) * 0.24)
				var y := at.y + radius * 0.3 - float(i) * radius * 0.5
				var bend := Art.sway(_wind, at.x * 0.01 + float(i), tier * 0.06)
				draw_colored_polygon(PackedVector2Array([
					Vector2(at.x + bend, y - tier * 1.05),
					Vector2(at.x - tier * 0.72, y), Vector2(at.x + tier * 0.72, y)]),
					Art.shaded(leaf, 0.7 + float(i) * 0.2))
			draw_colored_polygon(PackedVector2Array([
				Vector2(at.x - radius * 0.1, at.y - radius * 1.45),
				Vector2(at.x - radius * 0.3, at.y - radius * 0.6),
				Vector2(at.x + radius * 0.24, at.y - radius * 0.6)]), Art.sunlit(lit, 0.8))
		"house":
			var w := radius * 1.5
			var d := radius * 1.15
			var body := Rect2(at - Vector2(w, d) * 0.5, Vector2(w, d))
			# A building throws one solid shadow in the sun direction, not a blob.
			draw_rect(Rect2(body.position + Art.shadow_offset(radius * 1.1), body.size),
				Color(0.01, 0.015, 0.02, 0.3))
			Art.contact(self, body.get_center() + Vector2(0, d * 0.5), w * 0.6, 0.8)
			draw_rect(body, Art.shaded(def.leaf_lit, 0.5))
			var roof := Rect2(body.position + Vector2(0, -d * 0.16), Vector2(w, d * 0.52))
			draw_rect(roof, def.leaf)
			# Ridge and eave shading give the roof a pitch instead of a flat quad.
			draw_line(Vector2(roof.position.x, roof.position.y + roof.size.y * 0.5),
				Vector2(roof.end.x, roof.position.y + roof.size.y * 0.5),
				Art.sunlit(def.leaf, 1.4), 2.5)
			draw_rect(body, Art.shaded(def.leaf, 1.4), false, 2.0)
			draw_rect(Rect2(at + Vector2(-w * 0.1, d * 0.12), Vector2(w * 0.2, d * 0.38)),
				trunk)
			draw_rect(Rect2(body.position + Vector2(w * 0.12, d * 0.2),
				Vector2(w * 0.16, d * 0.16)), Color(0.72, 0.84, 0.9, 0.85))
		_:
			# "blob": the rounded broadleaf tree
			Art.soft_shadow(self, at, radius * 1.05, radius * 1.9)
			draw_rect(Rect2(at + Vector2(-radius * 0.13, radius * 0.1),
				Vector2(radius * 0.26, radius * 0.55)), trunk)
			var bend := Art.sway(_wind, at.x * 0.008 + at.y * 0.005, radius * 0.14)
			var crown := at + Vector2(bend, -radius * 0.35)
			draw_circle(crown, radius, Art.shaded(leaf, 0.7))
			draw_circle(crown + Art.lit_offset(radius), radius * 0.62, Art.sunlit(lit))
			draw_circle(crown + Art.lit_offset(radius) * 1.4, radius * 0.34,
				Art.sunlit(lit, 1.7))

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
