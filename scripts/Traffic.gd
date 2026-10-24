class_name Traffic
extends Node2D
## Cars that drive the curved roads (GAME.md §10). Pure scenery: no collision, no
## score, nothing to shoot. They exist because a road without traffic makes an
## endless map feel like wallpaper.
##
## Each car keeps a scalar distance `s` along its road and reads its world
## position from GroundDef.road_x()/road_y(), so it steers through the bends for
## free rather than needing a baked path. Cars too far behind the camera are
## re-placed near the player, which keeps the population constant on an unbounded
## map.

const RECALL := 2600.0
const CAR_LEN := 34.0
const CAR_WIDE := 17.0

class Car:
	extends RefCounted
	var vertical := true
	var lane_index := 0
	var s := 0.0
	var dir := 1.0
	var speed := 150.0
	var lane := 0.0
	var color := Color.WHITE
	var pos := Vector2.ZERO
	var ang := 0.0

var cars: Array = []

func _ready() -> void:
	_populate()

func _populate() -> void:
	while cars.size() < int(GroundDef.CARS.count):
		cars.append(_make_car(Layout.camera))

func _make_car(near: Vector2) -> Car:
	var c := Car.new()
	c.vertical = randf() < 0.5
	c.lane_index = int(round((near.x if c.vertical else near.y)
		/ GroundDef.ROAD_SPACING)) + randi_range(-2, 2)
	c.dir = 1.0 if randf() < 0.5 else -1.0
	c.s = (near.y if c.vertical else near.x) + randf_range(-1400.0, 1400.0)
	c.speed = randf_range(float(GroundDef.CARS.speed_min),
		float(GroundDef.CARS.speed_max))
	# Offset from the centreline is the lane, and it flips with the direction of
	# travel so oncoming cars pass on the correct side.
	c.lane = float(GroundDef.CARS.lane_offset) * c.dir
	var colors: Array = GroundDef.CARS.colors
	c.color = colors[randi() % colors.size()]
	c.pos = near
	return c

func _process(delta: float) -> void:
	for i in cars.size():
		var c := cars[i] as Car
		if c == null:
			continue
		c.s += c.speed * c.dir * delta
		if c.vertical:
			var cx := GroundDef.road_x(c.s, c.lane_index)
			c.pos = Vector2(cx + c.lane, c.s)
			c.ang = GroundDef.road_heading(Vector2(cx, c.s), true)
		else:
			var cy := GroundDef.road_y(c.s, c.lane_index)
			c.pos = Vector2(c.s, cy + c.lane)
			c.ang = GroundDef.road_heading(Vector2(c.s, cy), false)
		if c.pos.distance_to(Layout.camera) > RECALL:
			# Re-place rather than delete: the population stays constant, so an
			# endless map never fills with cars nobody will ever see again.
			cars[i] = _make_car(Layout.camera)
	if cars.size() < int(GroundDef.CARS.count):
		_populate()
	queue_redraw()

func count() -> int:
	return cars.size()

func _draw() -> void:
	if Game.view_3d:
		return
	var unit := Layout.unit
	for entry in cars:
		var c := entry as Car
		if c == null or not Layout.in_view(c.pos, 120.0):
			continue
		draw_set_transform(c.pos, c.ang, Vector2.ONE * unit)
		var l := CAR_LEN * 0.5
		var w := CAR_WIDE * 0.5
		draw_rect(Rect2(-l, -w, l * 2.0, w * 2.0), c.color.darkened(0.45))
		draw_rect(Rect2(-l * 0.25, -w * 0.82, l * 0.85, w * 1.64), c.color.lightened(0.12))
		draw_rect(Rect2(-l * 0.34, -w * 0.7, l * 0.2, w * 1.4), Color(0.12, 0.16, 0.2, 0.9))
		draw_rect(Rect2(l * 0.72, -w * 0.62, l * 0.2, w * 0.4), Color(1.0, 0.95, 0.75))
		draw_rect(Rect2(l * 0.72, w * 0.22, l * 0.2, w * 0.4), Color(1.0, 0.95, 0.75))
		draw_rect(Rect2(-l * 0.95, -w * 0.62, l * 0.16, w * 0.4), Color(0.9, 0.25, 0.2))
		draw_rect(Rect2(-l * 0.95, w * 0.22, l * 0.16, w * 0.4), Color(0.9, 0.25, 0.2))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
