class_name DroidFire
extends Area2D
## Anti-drone round fired across the plane: a straight flak shell, a steering mine,
## or a tracking rocket from a Tank's turret (GAME.md §5). Pooled by Main.

signal despawned(node)

const FLAK_SPEED := 205.0
const MINE_SPEED := 120.0
const MINE_TURN := deg_to_rad(85.0)
const FLAK_LIFE := 3.0
const MINE_LIFE := 5.0
## A rocket leaves the tube at a crawl and builds up to ROCKET_SPEED. That boost
## phase is the read: you see it start, you see where it is going to be, and only
## then does it commit.
const RK_START := 70.0
const ROCKET_SPEED := 195.0
const ROCKET_ACCEL := 480.0
## 52 deg/s at 195 units/s is a turn radius of about 210 units -- wide enough that a
## hard arc or a dash beats it, which is the whole difference between a threat and an
## execution.
const ROCKET_TURN := deg_to_rad(52.0)
const ROCKET_LIFE := 4.5
## Trail puffs are sampled on fixed time steps, so they are evenly spaced no matter
## what the frame rate is doing.
const TRAIL_STEP := 0.04
const TRAIL_MAX := 9

var mode := "flak"
var velocity := Vector2.ZERO
var life := 0.0
var active := false
var counted_near_miss := false
var drone: Drone
var age := 0.0
## Where the rocket has been, in world coordinates: the smoke stays hanging in the
## air while the round keeps flying, which is what leaves a visible line back to the
## Tank that fired it.
var trail: Array[Vector2] = []
var _trail_timer := 0.0

func _ready() -> void:
	add_to_group("droid_fire")
	collision_layer = 8
	collision_mask = 1
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 9.0
	shape.shape = circle
	add_child(shape)
	visible = false
	set_physics_process(false)

func launch(at: Vector2, dir: Vector2, kind: String, target_drone: Drone,
		unit: float) -> void:
	mode = kind
	drone = target_drone
	position = at
	age = 0.0
	counted_near_miss = false
	trail.clear()
	_trail_timer = 0.0
	var speed := FLAK_SPEED
	life = FLAK_LIFE
	match kind:
		"mine":
			speed = MINE_SPEED
			life = MINE_LIFE
		"rocket":
			speed = RK_START
			life = ROCKET_LIFE
	velocity = dir * speed * unit
	rotation = dir.angle()
	visible = true
	active = true
	set_deferred("monitoring", true)
	set_physics_process(true)

func despawn() -> void:
	if not active:
		return
	active = false
	visible = false
	trail.clear()
	set_deferred("monitoring", false)
	set_physics_process(false)
	despawned.emit(self)

func _physics_process(delta: float) -> void:
	var unit := Layout.unit
	age += delta
	life -= delta
	if drone != null and is_instance_valid(drone):
		var want := (drone.position - position).angle()
		if mode == "mine":
			var step := clampf(wrapf(want - velocity.angle(), -PI, PI),
				-MINE_TURN * delta, MINE_TURN * delta)
			velocity = velocity.rotated(step).normalized() \
				* MINE_SPEED * unit
		elif mode == "rocket":
			var rstep := clampf(wrapf(want - velocity.angle(), -PI, PI),
				-ROCKET_TURN * delta, ROCKET_TURN * delta)
			velocity = velocity.rotated(rstep)
			var cap := ROCKET_SPEED * unit
			if velocity.length() < cap:
				velocity = velocity.normalized() \
					* minf(cap, velocity.length() + ROCKET_ACCEL * unit * delta)
	if mode == "rocket":
		_trail_timer -= delta
		if _trail_timer <= 0.0:
			_trail_timer = TRAIL_STEP
			trail.push_front(position)
			if trail.size() > TRAIL_MAX:
				trail.pop_back()
	position += velocity * delta
	rotation = velocity.angle()

	if drone != null and is_instance_valid(drone) and not counted_near_miss:
		if position.distance_to(drone.position) < Game.NEAR_MISS_RADIUS * unit:
			counted_near_miss = true
			Game.register_near_miss(position)

	if life <= 0.0 or not Layout.in_view(position, 80.0):
		despawn()
	queue_redraw()

func _draw() -> void:
	if Game.view_3d:
		return
	var unit := Layout.unit
	if mode == "rocket":
		# Smoke first, so the round draws over its own wake.
		for i in trail.size():
			var old := float(i) * TRAIL_STEP
			var puff := to_local(trail[i])
			draw_circle(puff, (2.2 + old * 46.0) * unit,
				Color(0.80, 0.78, 0.75, clampf(0.34 - old * 2.4, 0.0, 0.34)))
		# Boost flame only while the motor is still burning: after that the round is
		# a cold dart, and it keeps flying anyway.
		var boost := clampf(1.0 - age / 0.45, 0.0, 1.0)
		if boost > 0.0:
			draw_line(Vector2(-8.0 * unit, 0.0),
				Vector2(-(14.0 + 16.0 * boost) * unit, 0.0),
				Color(1.0, 0.72, 0.34, 0.5 + 0.45 * boost), (2.0 + 3.0 * boost) * unit)
		draw_rect(Rect2(Vector2(-7.0 * unit, -2.6 * unit), Vector2(12.0 * unit,
			5.2 * unit)), Color(0.86, 0.87, 0.83))
		draw_colored_polygon(PackedVector2Array([
			Vector2(5.0 * unit, -2.6 * unit), Vector2(9.6 * unit, 0.0),
			Vector2(5.0 * unit, 2.6 * unit)]), Color(0.92, 0.55, 0.3))
		for fin in [-1.0, 1.0]:
			draw_colored_polygon(PackedVector2Array([
				Vector2(-6.0 * unit, fin * 2.2 * unit),
				Vector2(-9.4 * unit, fin * 6.0 * unit),
				Vector2(-2.0 * unit, fin * 2.2 * unit)]), Color(0.7, 0.72, 0.68))
		draw_circle(Vector2(-7.0 * unit, 0.0), 2.0 * unit,
			Color(1.0, 0.85, 0.5, 0.6 + 0.4 * boost))
	elif mode == "mine":
		var pulse := 9.0 + sin(age * 12.0) * 2.5
		draw_arc(Vector2.ZERO, pulse * unit, 0.0, TAU, 18,
			Color(1.0, 0.85, 0.3, 0.6), 1.5 * unit)
		draw_circle(Vector2.ZERO, 6.0 * unit, Color(1.0, 0.72, 0.2))
		for spike in 4:
			var a := float(spike) * PI * 0.5 + age
			draw_line(Vector2.ZERO, Vector2.RIGHT.rotated(a) * 9.0 * unit,
				Color(1.0, 0.72, 0.2, 0.8), 2.0 * unit)
	else:
		draw_line(Vector2(-14.0 * unit, 0.0), Vector2.ZERO,
			Color(1.0, 0.6, 0.4, 0.45), 2.5 * unit)
		draw_circle(Vector2.ZERO, 5.0 * unit, Color(1.0, 0.42, 0.25))
		draw_circle(Vector2(3.0 * unit, 0.0), 2.4 * unit, Color(1.0, 0.8, 0.6))
