class_name DroidFire
extends Area2D
## Anti-drone round fired across the plane: a straight flak shell or a steering
## mine (GAME.md §5). Pooled by Main.

signal despawned(node)

const FLAK_SPEED := 205.0
const MINE_SPEED := 120.0
const MINE_TURN := deg_to_rad(85.0)
const FLAK_LIFE := 3.0
const MINE_LIFE := 5.0

var mode := "flak"
var velocity := Vector2.ZERO
var life := 0.0
var active := false
var counted_near_miss := false
var drone: Drone
var age := 0.0

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
	var speed := (MINE_SPEED if kind == "mine" else FLAK_SPEED) * unit
	velocity = dir * speed
	life = MINE_LIFE if kind == "mine" else FLAK_LIFE
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
	set_deferred("monitoring", false)
	set_physics_process(false)
	despawned.emit(self)

func _physics_process(delta: float) -> void:
	var unit := Layout.unit
	age += delta
	life -= delta
	if mode == "mine" and drone != null and is_instance_valid(drone):
		var want := (drone.position - position).angle()
		var step := clampf(wrapf(want - velocity.angle(), -PI, PI),
			-MINE_TURN * delta, MINE_TURN * delta)
		velocity = velocity.rotated(step).normalized() \
			* MINE_SPEED * unit
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
	if mode == "mine":
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
