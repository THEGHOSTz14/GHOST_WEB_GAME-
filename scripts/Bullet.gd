class_name Bullet
extends Area2D
## Drone round. Fires only while a target is locked, then steers gently toward it
## (GAME.md §4). Pooled by Main.

signal despawned(node)

const RADIUS := 5.0
const TURN_RATE := deg_to_rad(200.0)
const LIFE := 1.9

var velocity := Vector2.ZERO
var homing: Droid = null
var life := 0.0
var active := false

func _ready() -> void:
	collision_layer = 2
	collision_mask = 4
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = RADIUS
	shape.shape = circle
	add_child(shape)
	area_entered.connect(_on_area_entered)
	visible = false
	set_physics_process(false)

func launch(at: Vector2, dir: Vector2, speed: float, target) -> void:
	position = at
	velocity = dir * speed
	homing = target as Droid
	life = LIFE
	rotation = velocity.angle()
	visible = true
	active = true
	set_deferred("monitoring", true)
	set_physics_process(true)

func despawn() -> void:
	if not active:
		return
	active = false
	visible = false
	homing = null
	set_deferred("monitoring", false)
	set_physics_process(false)
	despawned.emit(self)

func _physics_process(delta: float) -> void:
	var speed := velocity.length()
	if homing != null and is_instance_valid(homing) and not homing.is_queued_for_deletion():
		var want := (homing.position - position).angle()
		var step := clampf(wrapf(want - velocity.angle(), -PI, PI),
			-TURN_RATE * delta, TURN_RATE * delta)
		velocity = velocity.rotated(step)
		if velocity.length() != speed:
			velocity = velocity.normalized() * speed
	position += velocity * delta
	rotation = velocity.angle()
	life -= delta
	if life <= 0.0 or not Layout.in_view(position, 60.0):
		despawn()

func _on_area_entered(area: Area2D) -> void:
	if not area.is_in_group("droids"):
		return
	area.hit_from(position, 1)
	# A round stopped by the shield is spent all the same.
	despawn()

func _draw() -> void:
	if Game.view_3d:
		return
	var body := Color(0.98, 0.96, 0.7)
	draw_circle(Vector2.ZERO, RADIUS * 0.7, body)
	draw_line(Vector2(-RADIUS * 2.2, 0.0), Vector2(RADIUS, 0.0),
		Color(1.0, 1.0, 0.85, 0.55), 2.0)
