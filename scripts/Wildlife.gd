class_name Wildlife
extends Node2D
## Animals on the map (GAME.md §10). They graze, wander and bolt when the drone
## comes near. Harmless, unkillable, worth no points -- they exist because a
## top-down map with nothing alive on it reads as a texture, not a place.
##
## Recycling works the same way as Traffic: an animal too far behind the camera is
## re-placed near it, so the population is constant while the world is endless.

const RECALL := 2400.0
const TURN_RATE := 5.0

class Critter:
	extends RefCounted
	var type := "rabbit"
	var pos := Vector2.ZERO
	var heading := Vector2.RIGHT
	var speed := 100.0
	var flee_speed := 250.0
	var flee_radius := 200.0
	var graze_time := 0.5
	var timer := 0.0
	var state := "graze"
	var goal := Vector2.ZERO
	var hop := 0.0
	var body := Color.WHITE
	var head := Color.WHITE
	var size := 10.0
	var water_edge := false

	func configure(def: Dictionary, at: Vector2) -> void:
		speed = float(def.speed)
		flee_speed = float(def.flee_speed)
		flee_radius = float(def.flee)
		graze_time = float(def.graze)
		body = def.body
		head = def.head
		size = float(def.size)
		timer = randf_range(0.3, 2.2)
		pos = at
		hop = randf() * TAU
		heading = Vector2.RIGHT.rotated(randf() * TAU)

## Typed fields, not Dictionaries: variant member access defeats GDScript's type
## inference and quietly turns every operation into a runtime lookup.
var animals: Array = []

func _ready() -> void:
	_populate()

func _populate() -> void:
	for type in GroundDef.ANIMALS:
		var def: Dictionary = GroundDef.ANIMALS[type]
		while _count_of(type) < int(def.count):
			animals.append(_make(type, Layout.camera))

func _count_of(type: String) -> int:
	var n := 0
	for a in animals:
		if a.type == type:
			n += 1
	return n

func _make(type: String, near: Vector2) -> Critter:
	var def: Dictionary = GroundDef.ANIMALS[type]
	var a := Critter.new()
	a.type = type
	a.configure(def, _find_spot(type, near))
	a.water_edge = GroundDef.WATER_EDGE.has(type)
	return a

## A spot that suits the animal: herons on the waterline, everything else out of
## the river and off the roads.
func _find_spot(type: String, near: Vector2) -> Vector2:
	var wants_water: bool = GroundDef.WATER_EDGE.has(type)
	for attempt in 14:
		var p := near + Vector2.RIGHT.rotated(randf() * TAU) * randf_range(200.0, 1900.0)
		if GroundDef.in_road(p, 30.0):
			continue
		var in_water := GroundDef.in_river(p, 10.0)
		if wants_water != in_water:
			continue
		return p
	return near + Vector2(randf_range(-600.0, 600.0), randf_range(-600.0, 600.0))

func _process(delta: float) -> void:
	for i in animals.size():
		var a := animals[i] as Critter
		if a == null:
			continue
		var to_drone := a.pos - Layout.camera
		var dist := to_drone.length()
		var move_speed := a.speed
		if dist < a.flee_radius:
			# Bolt directly away, then keep running for a beat after safety.
			a.state = "flee"
			a.timer = 0.9
			var away := to_drone.normalized() if dist > 1.0 else Vector2.RIGHT
			a.heading = (a.heading * 0.75 + away * 0.25).normalized()
			move_speed = a.flee_speed
		else:
			a.timer -= delta
			if a.timer <= 0.0:
				a.state = "walk"
				a.goal = _find_spot(a.type, a.pos)
				a.timer = randf_range(1.0, 3.0)
			if a.state == "walk":
				var to_goal := a.goal - a.pos
				if to_goal.length() < 34.0:
					a.state = "graze"
					a.timer = randf_range(0.6, a.graze_time * 3.0)
				else:
					a.heading = a.heading.lerp(to_goal.normalized(),
						clampf(TURN_RATE * delta, 0.0, 1.0)).normalized()
			elif a.state == "graze":
				move_speed = 0.0
		a.hop += delta * (6.0 + move_speed * 0.02)
		var next := a.pos + a.heading * move_speed * delta
		# Never wade into the river or stroll down a carriageway (herons aside).
		var blocked := GroundDef.in_road(next, 26.0) \
			or (a.water_edge != GroundDef.in_river(next, 12.0))
		if blocked:
			# Turn aside and slide along the obstacle. Rotating in place would pin an
			# animal that happens to flee straight into a road and leave it stuck.
			a.heading = a.heading.rotated(randf_range(0.9, 1.9))
			a.pos += a.heading * move_speed * delta * 0.5
		else:
			a.pos = next
		if a.pos.distance_to(Layout.camera) > RECALL:
			animals[i] = _make(a.type, Layout.camera)
	queue_redraw()

func count() -> int:
	return animals.size()

func _draw() -> void:
	if Game.view_3d:
		return
	var unit := Layout.unit
	for entry in animals:
		var a := entry as Critter
		if a == null or not Layout.in_view(a.pos, 60.0):
			continue
		var s := a.size * unit
		var lift := 0.0
		if a.state != "graze":
			lift = absf(sin(a.hop)) * s * 0.16
		draw_set_transform(a.pos + Vector2(2.5, 4.0) * unit, 0.0, Vector2.ONE)
		draw_circle(Vector2.ZERO, s * 1.05, Color(0, 0, 0, 0.2))
		draw_set_transform(a.pos - Vector2(0, lift), a.heading.angle() + PI * 0.5,
			Vector2.ONE * unit)
		match a.type:
			"deer":
				draw_rect(Rect2(-s * 0.34, -s, s * 0.68, s * 2.0), a.body)
				draw_circle(Vector2(0, -s * 1.25), s * 0.34, a.head)
				draw_line(Vector2(-s * 0.2, -s * 1.5), Vector2(-s * 0.62, -s * 2.1), a.head, 2.0)
				draw_line(Vector2(s * 0.2, -s * 1.5), Vector2(s * 0.62, -s * 2.1), a.head, 2.0)
			"rabbit":
				draw_circle(Vector2.ZERO, s * 0.85, a.body)
				draw_circle(Vector2(0, -s * 0.8), s * 0.42, a.head)
				draw_line(Vector2(-s * 0.16, -s * 1.1), Vector2(-s * 0.26, -s * 1.8), a.head, 2.0)
				draw_line(Vector2(s * 0.16, -s * 1.1), Vector2(s * 0.26, -s * 1.8), a.head, 2.0)
			"boar":
				draw_rect(Rect2(-s * 0.5, -s * 0.85, s, s * 1.7), a.body)
				draw_circle(Vector2(0, -s * 0.95), s * 0.42, a.head)
			_:
				draw_rect(Rect2(-s * 0.2, -s * 0.7, s * 0.4, s * 1.6), a.body)
				draw_circle(Vector2(0, -s * 1.1), s * 0.3, a.head)
				draw_line(Vector2(0, -s * 1.3), Vector2(0, -s * 2.0),
					Color(0.95, 0.7, 0.25), 2.0)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
