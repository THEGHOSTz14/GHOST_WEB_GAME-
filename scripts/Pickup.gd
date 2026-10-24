class_name Pickup
extends Area2D
## Wrench / Overcharge / Core (GAME.md §8). Drifts in-plane, collected by
## flying over it. Pooled by Main.

signal despawned(node)

const SIZE := 22.0

var kind := "core"
var color := Color.WHITE
var life := 0.0
var active := false
var phase := 0.0
var drift := Vector2.ZERO

func _ready() -> void:
	add_to_group("pickups")
	collision_layer = 16
	collision_mask = 0
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(SIZE, SIZE) * 1.4
	shape.shape = rect
	add_child(shape)
	visible = false
	set_physics_process(false)

func spawn(at: Vector2, which: String, unit: float) -> void:
	kind = which
	color = Game.PICKUPS[which].color
	position = at
	life = Game.PICKUP_LIFE
	phase = randf() * TAU
	drift = Vector2.RIGHT.rotated(randf() * TAU) * Game.PICKUP_FALL * unit * 0.45
	visible = true
	active = true
	set_deferred("monitoring", true)
	set_physics_process(true)
	queue_redraw()

func despawn() -> void:
	if not active:
		return
	active = false
	visible = false
	set_deferred("monitoring", false)
	set_physics_process(false)
	despawned.emit(self)

func _physics_process(delta: float) -> void:
	phase += delta
	life -= delta
	position += drift * delta
	if life <= 0.0 or not Layout.in_view(position, 40.0):
		despawn()
	queue_redraw()

func _draw() -> void:
	if Game.view_3d:
		return
	var unit := Layout.unit
	var fade := 1.0 if life > 2.0 else (0.35 + 0.65 * absf(sin(life * 8.0)))
	var tint := Color(color.r, color.g, color.b, fade)
	var r := SIZE * 0.5 * unit
	draw_circle(Vector2(3.0, 4.0) * unit, r * 0.9, Color(0, 0, 0, 0.22 * fade))
	draw_rect(Rect2(-r, -r, r * 2.0, r * 2.0), tint.darkened(0.55))
	draw_rect(Rect2(-r, -r, r * 2.0, r * 2.0), tint, false, 2.0 * unit)
	match kind:
		"wrench":
			draw_line(Vector2(-r * 0.5, r * 0.5), Vector2(r * 0.5, -r * 0.5), tint, 4.0 * unit)
			draw_arc(Vector2(r * 0.45, -r * 0.45), r * 0.34, 0.4, TAU - 0.4, 10, tint, 3.0 * unit)
		"overcharge":
			var bolt := PackedVector2Array([Vector2(r * 0.1, -r * 0.8),
				Vector2(-r * 0.45, r * 0.1), Vector2(0.0, r * 0.1),
				Vector2(-r * 0.1, r * 0.8), Vector2(r * 0.45, -r * 0.1), Vector2(0.0, -r * 0.1)])
			draw_colored_polygon(bolt, tint)
		_:
			draw_circle(Vector2.ZERO, r * 0.45, tint)
			draw_arc(Vector2.ZERO, r * 0.72, phase, phase + PI * 1.2, 12, tint, 2.0 * unit)
