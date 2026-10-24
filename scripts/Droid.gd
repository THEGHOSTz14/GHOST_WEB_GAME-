class_name Droid
extends Area2D
## Ground robot roaming the plane in X and Y, seen from above. One script,
## behaviour switched by the id from Game.DROIDS (GAME.md §5). The Hauler boss
## is Phase 3 and gets its own scene.

signal destroyed(droid)
signal fire_requested(origin: Vector2, direction: Vector2, mode: String)
signal blocked(at: Vector2)
## Where a round landed and the direction it was travelling, so Main can throw
## sparks along the shot rather than in a decorative puff.
signal impacted(at: Vector2, direction: Vector2)

## Long enough to read and dodge at the slowed projectile speeds.
const TELEGRAPH := 0.9
const SHIELD_ARC := deg_to_rad(55.0)
const SHIELD_SPEED := PI / 2.6
## Distance at which a roam target counts as reached, in logical units.
const WAYPOINT_RADIUS := 24.0
const RUNNER_CHARGE := 0.9
const RUNNER_PAUSE := 0.85
## Turret fan spread, radians.
const FLAK_SPREAD := 0.22
## How far a round throws a Walker when it lands, before mass gets a say. The
## shove is free realism: it tells you the hit connected even when the health bar
## has barely moved.
const KNOCKBACK := 210.0
## Per-second decay of that shove. Treads on dirt, not a puck on air hockey.
const KNOCK_FRICTION := 6.5
## Seconds for a Walker to reach full speed; heavier chassis take proportionally
## longer, so a Hauler wind-up is readable and a Runner is not.
const REACT := 0.45
## Chassis heading slews at a limited rate. Treads have to slip to turn faster
## than this, and that slip is exactly what makes a bot look like it is turning.
const TURN_RATE := 3.2
## Barrel kick, in logical units, and how long the muzzle flash survives.
const RECOIL := 6.0
const FLASH_TIME := 0.09

var id := "walker"
var stats: Dictionary = {}
var hp := 1
var max_hp := 1
var size := Vector2(36.0, 36.0)
var color := Color.WHITE
var speed := 110.0
var mass := 1.0
var velocity := Vector2.ZERO
var facing := Vector2.RIGHT
var waypoint := Vector2.ZERO
var fire_interval := 0.0
var fire_timer := 0.0
var hit_flash := 0.0
var phase := 0.0
var shield_angle := 0.0
var roam := "waypoint"
var volley := "none"
var arc := false
var splits := 0
var charge_left := 0.0
var pause_left := RUNNER_PAUSE
var drone: Drone
## Left-over shove from the last hit, integrated into position and eaten by
## friction. Kept apart from velocity because steering must not chase it.
var knock := Vector2.ZERO
## -1..1 sideways slip, which leans the chassis and drags one tread behind.
var lean := 0.0
var recoil := 0.0
var flash := 0.0
## Tread pattern scroll, driven by distance travelled rather than by time, so the
## tracks stop the instant the bot does.
var roll := 0.0

func configure(kind: String, at: Vector2, target_drone: Drone) -> void:
	id = kind
	stats = Bots.def(kind)
	hp = int(stats.hp)
	max_hp = hp
	size = Vector2(float(stats.w), float(stats.h))
	color = stats.color
	speed = float(stats.speed)
	mass = float(stats.get("mass", 1.0))
	fire_interval = float(stats.fire)
	roam = String(stats.get("roam", "waypoint"))
	volley = String(stats.get("volley", "none"))
	arc = bool(stats.get("arc", false))
	splits = int(stats.get("splits", 0))
	drone = target_drone
	position = at
	waypoint = Layout.rand_interior()
	facing = (waypoint - at).normalized() if waypoint != at else Vector2.RIGHT
	charge_left = RUNNER_CHARGE
	pause_left = randf_range(0.2, RUNNER_PAUSE)
	fire_timer = fire_interval * randf_range(0.7, 1.5) if fire_interval > 0.0 else 0.0
	shield_angle = randf() * TAU

func _ready() -> void:
	add_to_group("droids")
	collision_layer = 4
	collision_mask = 0
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = size * 0.85
	shape.shape = rect
	add_child(shape)
	Game.note_spawn()

func _exit_tree() -> void:
	Game.note_despawn()

func _physics_process(delta: float) -> void:
	if Game.state != Game.State.PLAYING:
		return
	var unit := Layout.unit
	phase += delta
	hit_flash = maxf(0.0, hit_flash - delta)
	flash = maxf(0.0, flash - delta)
	recoil = maxf(0.0, recoil - delta * 6.5)
	var pace := speed * Game.speed_scale() * unit
	var heading := Vector2.ZERO

	match id:
		"runner":
			heading = _runner(delta)
		"turret":
			# Traversing on the gun means the drone can break the aim by moving
			# while it charges; an instant snap would make the telegraph a lie.
			if is_charging():
				_aim_at_drone(delta)
			else:
				heading = _wander()
		"shielder":
			heading = _wander()
			shield_angle += SHIELD_SPEED * delta
		_:
			heading = _wander()

	_steer(heading, pace, delta)
	_lean_into(pace, delta)
	# One integration point for every behaviour, which is what lets a knockback
	# shove still move a bot that is busy steering toward a waypoint.
	position += (velocity + knock) * delta
	knock = knock.lerp(Vector2.ZERO, minf(1.0, KNOCK_FRICTION * delta))
	roll += (velocity + knock).length() * delta / maxf(4.0, size.x * unit * 0.3)

	if fire_interval > 0.0:
		fire_timer -= delta
		if fire_timer <= 0.0:
			fire_timer = fire_interval / Game.fire_scale()
			_fire_volley(unit)

	queue_redraw()

## Anywhere in view that a wanderer can head for next.
func _wander() -> Vector2:
	var to := waypoint - position
	if to.length() < WAYPOINT_RADIUS * Layout.unit:
		waypoint = Layout.rand_interior()
		to = waypoint - position
	return to.normalized() if to.length_squared() > 0.01 else Vector2.ZERO

## Mass is a bot's only steering input. Velocity creeps toward the command instead
## of snapping to it, so a waypoint change is a readable arc rather than a jig,
## and a turret that decides to stop actually brakes.
func _steer(heading: Vector2, pace: float, delta: float) -> void:
	velocity += (heading * pace - velocity) * minf(1.0, delta / (REACT * mass))
	if heading != Vector2.ZERO:
		_turn_toward(heading, delta)

func _turn_toward(dir: Vector2, delta: float) -> void:
	var step := clampf(wrapf(dir.angle() - facing.angle(), -PI, PI),
		-TURN_RATE * delta, TURN_RATE * delta)
	facing = Vector2.RIGHT.rotated(facing.angle() + step)

## Sideways slip: the part of velocity the treads are not pointing along. Drawn as
## a lean with one track dragging, which is the only honest way to show a tracked
## chassis changing direction.
func _lean_into(pace: float, delta: float) -> void:
	var slip := velocity - facing * velocity.dot(facing)
	var wanted := clampf(slip.dot(facing.orthogonal()) / maxf(1.0, pace), -1.0, 1.0)
	lean = lerpf(lean, wanted, minf(1.0, 8.0 * delta))

## Charge, freeze, re-aim. Returns the direction it wants, or none while it sits.
func _runner(delta: float) -> Vector2:
	if pause_left > 0.0:
		pause_left -= delta
		_aim_at_drone(delta)
		if pause_left <= 0.0:
			charge_left = RUNNER_CHARGE
			return facing
	if charge_left > 0.0:
		charge_left -= delta
		if charge_left <= 0.0:
			pause_left = RUNNER_PAUSE
			return Vector2.ZERO
		return facing
	return Vector2.ZERO

func is_charging() -> bool:
	return fire_interval > 0.0 and fire_timer < TELEGRAPH

## Traversing the gun takes time. Aiming instantly would make the telegraph a lie,
## because the drone could step aside and still get hit by something that had
## already committed to its old position.
func _aim_at_drone(delta: float) -> void:
	if drone != null and is_instance_valid(drone):
		var to := drone.position - position
		if to.length_squared() > 0.01:
			_turn_toward(to.normalized(), delta)

func _dir_to_drone() -> Vector2:
	if drone == null or not is_instance_valid(drone):
		return facing
	var to := drone.position - position
	return to.normalized() if to.length_squared() > 0.01 else facing

## A fan rather than a single shot: the fan is what makes a telegraphed burst
## dodgeable in a top-down plane. The gun kicks back along its own axis and lights
## the muzzle, so the burst is audible in the picture even with the sound off.
func _fire_volley(unit: float) -> void:
	if drone == null or not is_instance_valid(drone):
		return
	var base := _dir_to_drone()
	var origin := position + base * size.x * 0.55 * unit
	recoil = 1.0
	flash = FLASH_TIME
	match volley:
		"flak3":
			# A fan, not a single shot: three telegraphed shells are dodgeable in a
			# top-down plane where one would just be unfair.
			for offset in [-FLAK_SPREAD, 0.0, FLAK_SPREAD]:
				fire_requested.emit(origin, base.rotated(offset), "flak")
		"mine":
			fire_requested.emit(origin, base, "mine")

## The shielder's arc orbits it, so whether a round lands depends on where it
## arrived from -- hold the lock and take the shot when the gap faces you.
func shielded(from: Vector2) -> bool:
	if not arc:
		return false
	var incoming := (from - position).angle()
	return absf(wrapf(incoming - shield_angle, -PI, PI)) < SHIELD_ARC

## Damage, plus the shove that comes with it. Mass decides how far the bot goes,
## so a Runner skips and a Hauler barely flinches. A blocked round still nudges:
## a shield that eats a hit without moving at all reads as nothing having happened.
func hit_from(from: Vector2, damage: int) -> void:
	var away := (position - from).normalized()
	var gain := KNOCKBACK * Layout.unit / mass
	if shielded(from):
		knock += away * gain * 0.22
		blocked.emit(from)
		return
	impacted.emit(position, -away)
	hp -= damage
	hit_flash = 0.08
	knock += away * gain * randf_range(0.75, 1.0)
	if hp <= 0:
		destroyed.emit(self)
		queue_free()

## Shove from outside: the bomb and a splitter's two halves both use it, so an
## explosion moves things instead of only deleting them.
func impulse(v: Vector2) -> void:
	knock += v / mass

func health_ratio() -> float:
	return clampf(float(hp) / float(max_hp), 0.0, 1.0)

func _health_color() -> Color:
	var ratio := health_ratio()
	if ratio > 0.66:
		return Color(0.36, 0.86, 0.42)
	if ratio > 0.33:
		return Color(0.95, 0.78, 0.25)
	return Color(0.95, 0.35, 0.3)

func is_locked_on() -> bool:
	return drone != null and is_instance_valid(drone) and drone.locked == self

## True once this bot is far enough outside the visible rect that the Spawner
## should recycle it back around the player instead of letting the population
## drift off into empty world.
func out_of_range(margin: float) -> bool:
	return not Layout.in_view(position, margin)

## Step back into play just outside the visible rect with a fresh roam target.
## The world is endless, so a bot that wanders off is recycled rather than left
## alive forever or deleted into thin air.
func recall_near() -> void:
	position = Layout.rand_edge_entry()
	waypoint = Layout.rand_interior()
	velocity = Vector2.ZERO
	knock = Vector2.ZERO
	lean = 0.0
	pause_left = randf_range(0.1, RUNNER_PAUSE)

func _draw() -> void:
	if Game.view_3d:
		return
	var unit := Layout.unit
	var s := size.x
	var body := color if hit_flash <= 0.0 else Color(1, 1, 1)
	# Grounded the same way everything else on the plane is: one sun, one shadow
	# direction, shared with the drone and every prop through Art.
	Art.soft_shadow(self, Vector2.ZERO, s * 0.46 * unit, 7.0 * unit, 0.9)
	Art.contact(self, Vector2.ZERO, s * 0.30 * unit, 0.9)
	# A turn puts the chassis off its own velocity: the nose slews in ahead of the
	# tracks, which is how a tracked vehicle really changes heading.
	var heading := facing.angle() + lean * 0.18
	draw_set_transform(Vector2.ZERO, heading, Vector2.ONE * unit)
	var tread_y := s * 0.43
	for side in [-1.0, 1.0]:
		# The track on the outside of a pivot stretches and pales as it slips.
		var slip := clampf(-lean * side, 0.0, 1.0)
		var tl := s * (1.16 + slip * 0.12)
		draw_rect(Rect2(-tl * 0.5, side * tread_y - s * 0.07, tl, s * 0.14),
			body.darkened(0.62 + slip * 0.06))
		_draw_cleats(tl, side * tread_y, s)
	# Base plate, then the top face lifted a few pixels toward the sun. That
	# offset is measured in screen space, so the lit side does not rotate with the
	# chassis -- which is the difference between a box and a body.
	draw_rect(Rect2(-s * 0.5, -s * 0.42, s, s * 0.84), Art.shaded(body, 0.85))
	var face := Rect2((-Art.SUN).rotated(-heading) * s * 0.07
		+ Vector2(-s * 0.42, -s * 0.34), Vector2(s * 0.84, s * 0.62))
	draw_rect(face, Art.sunlit(body, 0.75))
	draw_rect(face, body.darkened(0.7), false, 1.5)

	if fire_interval > 0.0:
		# The barrel sits in the slot the kick left it in and the flash is a hot
		# wedge at its mouth: a burst you can hear with the sound off.
		var back := Vector2(-RECOIL * recoil, 0.0)
		draw_rect(Rect2(Vector2(s * 0.16, -s * 0.065) + back, Vector2(s * 0.42, s * 0.13)),
			body.darkened(0.75))
		draw_circle(Vector2(s * 0.26, 0.0) + back, s * 0.10, Color(1.0, 0.25, 0.25))
		if flash > 0.0:
			_flash(Vector2(s * 0.60, 0.0) + back, s * (0.26 + 0.34 * flash / FLASH_TIME))
	else:
		draw_circle(Vector2(s * 0.22, 0.0), s * 0.11, Color(0.95, 0.9, 0.6))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	if is_charging():
		var aim := (_dir_to_drone() * s * 4.0) * unit
		draw_line(Vector2.ZERO, aim, Color(1.0, 0.35, 0.2,
			0.3 + 0.6 * (1.0 - fire_timer / TELEGRAPH)), 3.0 * unit)
	if arc:
		draw_arc(Vector2.ZERO, s * 0.85 * unit, shield_angle - SHIELD_ARC,
			shield_angle + SHIELD_ARC, 20, Color(0.55, 1.0, 0.8, 0.85), 4.0 * unit)
	# Health bar over anything that survives more than one hit, so the player can
	# see a Shielder is nearly dead and spend the last shots elsewhere.
	if max_hp > 1:
		var bw := s * 1.15 * unit
		var bh := 6.0 * unit
		var top := Vector2(-bw * 0.5, -s * 0.78 * unit - bh)
		draw_rect(Rect2(top - Vector2(1.5, 1.5) * unit, Vector2(bw + 3.0, bh + 3.0) * unit),
			Color(0.02, 0.03, 0.05, 0.75))
		draw_rect(Rect2(top, Vector2(bw, bh)), Color(0.16, 0.19, 0.23))
		draw_rect(Rect2(top, Vector2(bw * health_ratio(), bh)), _health_color())

## Track cleats scrolling along the tread at the bot's real ground speed. The
## pattern stopping the instant the bot stops is a small thing that a moving
## picture lives on: without it the chassis slides like a decal.
func _draw_cleats(length: float, y: float, s: float) -> void:
	var pitch := s * 0.15
	var shift := fmod(roll, 1.0) * pitch - pitch
	for i in 14:
		var x := -length * 0.5 + shift + float(i) * pitch
		if x > -length * 0.5 and x + s * 0.05 < length * 0.5:
			draw_rect(Rect2(x, y - s * 0.07, s * 0.05, s * 0.14), Color(0, 0, 0, 0.24))

## Muzzle flash: a blown-out star with a white core. A big soft blob would read as
## smoke rather than as a shot, so it stays small and hard-edged.
func _flash(at: Vector2, r: float) -> void:
	var k := clampf(flash / FLASH_TIME, 0.0, 1.0)
	var pts := PackedVector2Array()
	for i in 8:
		var a := float(i) * PI * 0.25
		pts.append(at + Vector2.RIGHT.rotated(a) * r * (1.0 if i % 2 == 0 else 0.35))
	draw_polygon(pts, PackedColorArray([Color(1.0, 0.82, 0.42, 0.9 * k)]))
	draw_circle(at, r * 0.32, Color(1.0, 1.0, 0.86, 0.95 * k))
