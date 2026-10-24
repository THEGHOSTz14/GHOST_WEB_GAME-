class_name Drone
extends Area2D
## The player drone, drawn from the supplied artwork: a static airframe with the
## four propellers as separate sprites spinning over their hubs.
## Player drone seen from above. Moves in the X/Y plane, aims at whatever it has
## locked, and shoots on the fire button (GAME.md §3, §4). Left click fires and
## right click bombs; on a phone, drag steers and a tap fires at what you touched.

# target is deliberately untyped: the guns now fire without a lock, and a
# typed signal argument cannot marshal null through the engine marshaller.
signal fired(origin: Vector2, direction: Vector2, speed: float, target)
signal dashed
signal collected(pickup_id: String)
signal hit_taken
signal lock_changed(target)

const BODY := Vector2(34.0, 34.0)
## Movement is a force model, not a teleport-to-cursor model. The rotors push at
## ACCEL, air drag opposes with the square of speed, and the two balance exactly
## at MAX_SPEED -- so top speed is an asymptote the drone converges on rather
## than a clamp it slams into. That tail is what reads as mass.
const MAX_SPEED := 460.0
const ACCEL := 1900.0
const BRAKE := 2000.0
## Derived, never tuned on its own: drag that equals thrust at MAX_SPEED.
const DRAG := ACCEL / (MAX_SPEED * MAX_SPEED)
## How fast the sideways slide left by a turn is bled off. Air alone is far too
## patient -- a real quad points its lift vector into the corner to kill the skid.
const DRIFT := 7.0
## Hull travel of the hover bob, in logical units. The collision body stays put;
## only the drawing bobs, or the hitbox would jitter under the crosshair.
const BOB := 3.4
## Fraction of the hull the sprite squashes sideways at full bank.
const BANK_SQUASH := 0.16
## AUTO_FIRE=true returns the old hands-free behaviour; false (shipped) means the
## guns only run while the fire action is held.
const AUTO_FIRE := false
## Length of the aim arrow drawn ahead of the hull, in logical units.
const AIM_ARROW := 58.0
## How long a shot's muzzle light and hull kick stay visible.
const MUZZLE_TIME := 0.07
## Pointer follow: the drone closes on the finger at the fastest speed it can
## still brake away from, so it arrives at zero velocity instead of orbiting the
## cursor. Below 1.0 it errs toward stopping short, which reads as control.
const ARRIVE_GAIN := 0.5
const STOP_DEADZONE := 9.0
const DASH_TIME := 0.16
const DASH_SPEED := 1500.0
const DASH_COOLDOWN := 1.6
## How long the dash pressure wave stays visible after the shove.
const DASH_RING := 0.34
const BULLET_SPEED := 700.0
const AIM_SPREAD := deg_to_rad(8.0)
## Tap vs drag discrimination on touch: slop in logical units.
const TAP_SLOP := 16.0
## How far from a tapped point a droid still counts as "the one you meant".
const TAP_PICK_RADIUS := 70.0

const BodyTexture := preload("res://assets/drone/drone_body.png")
const PropTexture := preload("res://assets/drone/drone_prop.png")
## Quad width in logical units at unit=1. The sprite keeps its own aspect.
const SPRITE_SPAN := 118.0
## How far the hull sits above its own shadow, in logical units. Height is all a
## top-down view has to work with: the shadow's offset and spread are what tell
## the eye the drone is airborne and not a decal on the grass.
const ALTITUDE := 9.0
const BODY_ASPECT := 337.0 / 384.0
## Prop blade length as a fraction of the quad width: wide enough to sweep past
## the orange hub ring, which is what sells that it is actually turning.
const PROP_RATIO := 0.31
## Rotor hub positions in the sprite's 0..1 space, measured from the artwork by
## tools/prep_drone_art.py -- not eyeballed, so the blades sit on the bearings.
const ROTOR_HUBS := [Vector2(0.14, 0.14), Vector2(0.86, 0.14),
	Vector2(0.14, 0.86), Vector2(0.86, 0.86)]
## Counter-rotating pairs, like a real quad, so the silhouette never looks like
## all four blades are frozen in the same position.
const ROTOR_DIRS := [1.0, -1.0, -1.0, 1.0]
const PROP_BASE_RATE := 26.0
const PROP_THRUST_RATE := 22.0
## The artwork's nose is the pointed end carrying the triangle marker, which is
## the bottom of the image. Set to 0.0 if it ends up flying backwards.
const BODY_FORWARD := PI

var target := Vector2.ZERO
var pointer_active := false
var facing := Vector2.UP
var velocity := Vector2.ZERO
var fire_timer := 0.0
var i_frames := 0.0
var dash_left := 0.0
var dash_cd := 0.0
var dash_dir := Vector2.UP
var spin := 0.0
## Bank into the turn, -1 (left) .. 1 (right).
var bank := 0.0
## Hover state: the hull never sits perfectly still on a cushion of air.
var hover := 0.0
var bob := Vector2.ZERO
## 0..1 share of available thrust, used by the props and the downwash.
var throttle := 0.0
## Counts down from MUZZLE_TIME on every round away, so the nose lights and the
## hull is pushed back along its own gun line.
var muzzle := 0.0
var _clock := 0.0
var _dash_ring := DASH_RING
var _hitbox: CollisionShape2D

var locked: Droid = null
var acquiring: Droid = null
var acquire_t := 0.0
var picked: Droid = null   # hand-picked target; Area2D owns `priority`
var picked_t := 0.0

var _down_at := Vector2.INF
var _dragged := false

func _ready() -> void:
	add_to_group("drone")
	# The project defaults to nearest filtering for crisp vector-ish drawing, but
	# the drone is smooth artwork scaled down -- nearest would alias its curves.
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	collision_layer = 1
	collision_mask = 8 | 16
	monitoring = true
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = BODY.x * 0.42
	shape.shape = circle
	add_child(shape)
	_hitbox = shape
	area_entered.connect(_on_area_entered)

## Input arrives in viewport coords; entities use world-local coords. During a
## screen shake the two differ by a few pixels and the per-frame clamp absorbs it.
func _input(event: InputEvent) -> void:
	# The mouse is the weapon now, not the steering wheel: hover no longer drags
	# the drone around, because a pointer that both aims and steers fights itself.
	# Keyboard and touch drag steer; a left click fires and picks that bot.
	if event is InputEventMouseButton:
		if event.pressed and event.button_index == MOUSE_BUTTON_LEFT 				and Game.state == Game.State.PLAYING:
			request_lock_at(Layout.screen_to_world(event.position))
	elif event is InputEventScreenTouch:
		if event.pressed:
			_down_at = event.position
			_dragged = false
		else:
			_end_touch(event.position)
	elif event is InputEventScreenDrag:
		if not _dragged and event.position.distance_to(_down_at) > TAP_SLOP:
			_dragged = true
		if _dragged:
			_see(Layout.screen_to_world(event.position))

func _see(at: Vector2) -> void:
	target = at
	pointer_active = true

## A tap that barely moved selects a target; a drag steers. Without this split,
## tapping a droid to lock it would also fly the drone into it.
func _end_touch(released_at: Vector2) -> void:
	if Game.state == Game.State.PLAYING and not _dragged and _down_at != Vector2.INF \
			and released_at.distance_to(_down_at) < TAP_SLOP:
		request_lock_at(released_at)
	_down_at = Vector2.INF

func request_lock_at(at: Vector2) -> void:
	var best = null
	var best_d := TAP_PICK_RADIUS * Layout.unit
	for node in get_tree().get_nodes_in_group("droids"):
		var d := node as Droid
		if d == null:
			continue
		var dist := d.position.distance_to(at)
		if dist < best_d:
			best_d = dist
			best = d
	if best == null:
		return
	picked = best
	picked_t = Game.LOCK_PRIORITY
	if locked != best:
		locked = null
		acquiring = best
		acquire_t = 0.0

func _physics_process(delta: float) -> void:
	if Game.state != Game.State.PLAYING:
		_reset_lock()
		return
	var unit := Layout.unit
	var acc := ACCEL * unit
	var cap := MAX_SPEED * unit
	var v0 := velocity
	_clock += delta
	_dash_ring = maxf(0.0, _dash_ring - delta)

	var want := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var cmd := Vector2.ZERO
	var limit := cap
	var easing := false
	if want != Vector2.ZERO:
		pointer_active = false
		cmd = want.normalized()
	elif pointer_active:
		var to := target - position
		if to.length() > STOP_DEADZONE * unit:
			cmd = to.normalized()
			# Braking distance, v = sqrt(2 a d): the fastest speed the drone can
			# still shed before it reaches the finger.
			limit = minf(cap, sqrt(2.0 * acc
				* (to.length() - STOP_DEADZONE * unit) * ARRIVE_GAIN))
			easing = true

	# Drag is evaluated on this rather than on the speed after thrust; see below.
	var pre_thrust := velocity.length()

	dash_cd = maxf(0.0, dash_cd - delta)
	if Input.is_action_just_pressed("dash") and dash_cd <= 0.0:
		_begin_dash(want)
	if dash_left > 0.0:
		# A shove that fades, not a teleport: the burst decays to a little over
		# cruise across its window, so joining the normal flight model is seamless.
		dash_left -= delta
		velocity = dash_dir * lerpf(DASH_SPEED * unit, cap * 1.06,
			1.0 - clampf(dash_left / DASH_TIME, 0.0, 1.0))
	else:
		if cmd != Vector2.ZERO:
			velocity += cmd * acc * delta
			# The arrive profile is the only thing that has to brake below cruise;
			# drag already owns the top end, and clamping to cap here as well would
			# settle the drone a frame's worth of thrust under MAX_SPEED.
			if easing:
				var along := velocity.dot(cmd)
				if along > limit:
					velocity -= cmd * minf(along - limit, BRAKE * unit * delta)
			# Bleed the sideways slide off faster than air manages: this is the
			# quad leaning into the corner instead of drifting through it.
			var perp := velocity - cmd * velocity.dot(cmd)
			velocity -= perp * minf(1.0, DRIFT * delta)
		else:
			var coasting := velocity.length()
			velocity -= velocity.normalized() * minf(coasting, BRAKE * unit * delta)
		# Quadratic drag. DRAG is derived so this exactly balances thrust at
		# MAX_SPEED: cruise is converged on, never clamped to. Evaluated at the
		# speed held *before* this frame's thrust, which puts the discrete
		# equilibrium on MAX_SPEED rather than ACCEL*dt below it.
		if pre_thrust > 0.0:
			velocity -= velocity.normalized() * minf(velocity.length(),
				DRAG * pre_thrust * pre_thrust * delta / unit)

	if velocity.length_squared() > 400.0:
		facing = velocity.normalized()

	# Free flight: the camera follows the drone, so there is no screen edge to
	# bounce off and the world keeps going in every direction.
	position += velocity * delta

	i_frames = maxf(0.0, i_frames - delta)
	muzzle = maxf(0.0, muzzle - delta)
	if not is_equal_approx(_hitbox.scale.x, unit):
		_hitbox.scale = Vector2.ONE * unit
	throttle = clampf(velocity.length() / cap, 0.0, 1.0)
	_update_bank(v0, delta, acc)
	# Two unrelated frequencies summed, and the two axes not even in phase with
	# each other: a single sine pulses like a metronome and looks parked.
	hover = sin(_clock * 2.3) * 0.62 + sin(_clock * 0.87 + 1.9) * 0.38
	bob = Vector2(hover, cos(_clock * 1.7 + 0.4) * 0.6 + sin(_clock * 0.61) * 0.4) \
		* BOB * unit
	spin += delta * (PROP_BASE_RATE + PROP_THRUST_RATE * throttle)
	if picked != null:
		picked_t -= delta
		if picked_t <= 0.0:
			picked = null
	_update_lock(delta)

	if locked != null or acquiring != null:
		facing = aim_dir()
	if AUTO_FIRE or Input.is_action_pressed("fire"):
		fire_timer -= delta
		if fire_timer <= 0.0:
			fire_timer = Game.fire_interval()
			_shoot(unit)
	queue_redraw()

## Bank into the turn, signed by which way this frame's acceleration pushed
## sideways. A real airframe fights that same quantity with dihedral, so the lean
## needs no extra state -- and it is smoothed because a raw per-frame difference
## flickers at low frame rates.
func _update_bank(v0: Vector2, delta: float, acc: float) -> void:
	var side := 0.0
	var speed := velocity.length()
	if delta > 0.0 and speed > MAX_SPEED * Layout.unit * 0.15:
		var dir := velocity / speed
		side = clampf(dir.cross(velocity - v0) / (acc * delta), -1.0, 1.0)
	bank = lerpf(bank, side, minf(1.0, 9.0 * delta))

func _begin_dash(want: Vector2) -> void:
	if want != Vector2.ZERO:
		dash_dir = want.normalized()
	elif pointer_active and (target - position).length_squared() > 4.0:
		dash_dir = (target - position).normalized()
	else:
		dash_dir = Vector2.UP
	dash_left = DASH_TIME
	dash_cd = DASH_COOLDOWN
	_dash_ring = DASH_RING
	i_frames = maxf(i_frames, DASH_TIME + 0.08)
	dashed.emit()

## Where the guns point: at the lock if there is one, at the target being
## acquired so the intent is visible, otherwise wherever the drone is heading.
func aim_dir() -> Vector2:
	var aim_at = locked if locked != null else acquiring
	if aim_at != null and is_instance_valid(aim_at):
		var to: Vector2 = aim_at.position - position
		if to.length_squared() > 1.0:
			return to.normalized()
	return facing

## Aim at where the target will be when the round arrives, not where it is.
## Unlocked shots go straight down the barrel with more spread, so a lock is
## worth having but a panic click still does something.
func _shoot(unit: float) -> void:
	var dir := aim_dir()
	if locked != null:
		var flight := position.distance_to(locked.position) / (BULLET_SPEED * unit)
		var anticipate := locked.position + locked.velocity * flight * 0.85
		dir = (anticipate - position).normalized()
	dir = dir.rotated(randf_range(-AIM_SPREAD, AIM_SPREAD) * (1.0 if locked != null else 3.0))
	muzzle = MUZZLE_TIME
	fired.emit(position + dir * BODY.x * 0.4 * unit, dir, BULLET_SPEED * unit, locked)

func _update_lock(delta: float) -> void:
	var reach := Game.LOCK_RADIUS * Layout.unit
	if locked != null and not _alive_in_range(locked, reach):
		_break_lock()
	if locked != null:
		return
	# A hand-pick beats whatever acquisition is already running.
	if picked != null and picked != acquiring and _alive_in_range(picked, reach):
		acquiring = picked
		acquire_t = 0.0
	if acquiring != null and not _alive_in_range(acquiring, reach):
		acquiring = null
		acquire_t = 0.0
	if acquiring == null:
		acquiring = _nearest(reach)
	if acquiring == null:
		return
	# Sticking with the target already being acquired is the point: re-deciding
	# every frame would let two equidistant droids cancel each other's lock out.
	acquire_t += delta
	if acquire_t >= Game.LOCK_TIME:
		locked = acquiring
		picked = null
		lock_changed.emit(locked)

## Untyped on purpose: a freed reference is not null, and binding one to a typed
## parameter is a cast the engine rejects with "Trying to cast a freed object".
func _alive_in_range(d, reach: float) -> bool:
	return d != null and is_instance_valid(d) and not d.is_queued_for_deletion() \
		and position.distance_to(d.position) <= reach

func _nearest(reach: float) -> Droid:
	var best = null
	var best_d := reach
	for node in get_tree().get_nodes_in_group("droids"):
		var d := node as Droid
		if d == null:
			continue
		var dist := position.distance_to(d.position)
		if dist <= best_d:
			best_d = dist
			best = d
	return best

## Called by Main the instant a bot dies, while the reference is still valid.
## Without it the drone keeps a freed target and every later check is a cast.
func forget(d) -> void:
	if d == null:
		return
	if locked == d:
		locked = null
		lock_changed.emit(null)
	if acquiring == d:
		acquiring = null
		acquire_t = 0.0
	if picked == d:
		picked = null

func _break_lock() -> void:
	locked = null
	acquiring = null
	acquire_t = 0.0
	lock_changed.emit(null)

func _reset_lock() -> void:
	if locked != null or acquiring != null:
		_break_lock()
	fire_timer = 0.0

func hit_by_fire() -> bool:
	if i_frames > 0.0:
		return false
	i_frames = Game.INVULN
	hit_taken.emit()
	Game.damage_player()
	return true

func grant_invuln(seconds: float) -> void:
	i_frames = maxf(i_frames, seconds)

func lock_progress() -> float:
	if locked != null:
		return 1.0
	if acquiring == null:
		return 0.0
	return clampf(acquire_t / Game.LOCK_TIME, 0.0, 1.0)

func _on_area_entered(area: Area2D) -> void:
	if Game.state != Game.State.PLAYING:
		return
	if area.is_in_group("pickups"):
		collected.emit(area.get("kind"))
		area.despawn()
	elif area.is_in_group("droid_fire"):
		if hit_by_fire():
			area.despawn()

func _draw() -> void:
	if Game.view_3d:
		return
	var unit := Layout.unit
	var span := SPRITE_SPAN * unit
	var body_size := Vector2(span, span * BODY_ASPECT)
	var blink := i_frames > 0.0 and fmod(spin, 0.4) < 0.2
	var shade := Color(1.0, 0.42, 0.42) if blink else Color.WHITE

	# The shadow belongs to the ground, not to the hull: it stays where the drone
	# flies over, spread and pale, while the hull bobs above it. Sharing Art's sun
	# is what puts it on the same side as every bot, tree and car shadow.
	var lift := 1.0 + hover * 0.12
	Art.soft_shadow(self, bob * 0.2, span * 0.30, ALTITUDE * unit * lift, 0.85)
	_draw_downwash(unit, span)
	_draw_speed_lines(unit, span)

	var nose := aim_dir()
	var heading := nose.angle() - PI * 0.5 + BODY_FORWARD
	# Bank foreshortens the airframe across the turn and slides it a few pixels
	# into the corner. The rotors share the same squash, so hull and blades still
	# read as one rigid body tilting rather than two layers sliding apart.
	var squash := Vector2(1.0 - absf(bank) * BANK_SQUASH, 1.0 + absf(bank) * 0.05)
	# The hull is shoved back along its own gun line by the round that just left.
	var kick := -nose * span * 0.03 * clampf(muzzle / MUZZLE_TIME, 0.0, 1.0)
	draw_set_transform(bob + kick, heading, squash)
	draw_texture_rect(BodyTexture, Rect2(-body_size * 0.5, body_size), false, shade)
	_draw_props(span, shade, heading, squash, bob + kick)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	_draw_gunflash(span)
	_draw_dash_ring(unit, span)
	_draw_aim_arrow(unit)
	if Game.overcharge > 0.0:
		draw_arc(Vector2.ZERO, span * 0.5, 0.0, TAU, 28,
			Color(0.35, 0.95, 1.0, 0.5), 1.5 * unit)
	_draw_reticle(unit)

## Blades spin over the hub rings. Rate rises with thrust so a hard start visibly
## kicks the props up, and each rotor is phased differently so the four never
## freeze into one symmetrical shape.
##
## Each blade transform is composed by hand. draw_set_transform replaces the
## current transform instead of stacking on it, so nesting one inside a rotated
## body drops the body's heading and parks the blades off their bearings.
func _draw_props(span: float, shade: Color, heading: float,
		squash: Vector2, at: Vector2) -> void:
	var prop_len := span * PROP_RATIO
	var prop_thick := prop_len * (float(PropTexture.get_height())
		/ float(PropTexture.get_width()))
	var body_size := Vector2(span, span * BODY_ASPECT)
	for i in ROTOR_HUBS.size():
		# Const arrays hand back Variant, so every element needs an explicit type.
		var hub: Vector2 = (ROTOR_HUBS[i] as Vector2 - Vector2(0.5, 0.5)) * body_size
		var angle: float = spin * float(ROTOR_DIRS[i]) + float(i) * 0.8
		draw_set_transform(at + (hub * squash).rotated(heading), heading + angle, squash)
		draw_texture_rect(PropTexture,
			Rect2(-prop_len * 0.5, -prop_thick * 0.5, prop_len, prop_thick), false, shade)

## Rotor downwash: dust that was already lying on the ground, lifted off the
## rotors and pushed downwind. Fades in with thrust, so at a true hover the air
## under the drone is calm and the player can read that it is not working.
func _draw_downwash(unit: float, span: float) -> void:
	var strength := 0.35 + 0.65 * throttle
	for i in 9:
		var n := float(i)
		var t := fmod(_clock * 0.85 + n * 0.31, 1.0)
		var ang := n * TAU / 9.0 + sin(n * 2.7)
		var push := Vector2.RIGHT.rotated(ang) * span * (0.22 + t * 0.66)
		draw_circle(push + Art.WIND * span * 0.55 * t,
			span * 0.03 * (1.0 - t) + 1.0 * unit,
			Color(0.80, 0.76, 0.63, (1.0 - t) * 0.26 * strength))

## Streaks along the direction of travel, and only once the drone is past cruise:
## they are a speedometer, not decoration, so they have to be invisible at hover
## or the player loses the one cue that says how fast the hull is actually moving.
func _draw_speed_lines(unit: float, span: float) -> void:
	var rush := clampf(velocity.length() / (MAX_SPEED * Layout.unit) - 0.95, 0.0, 1.0)
	if rush < 0.02:
		return
	var back := -velocity.normalized()
	var side := back.orthogonal()
	for i in 5:
		var n := float(i)
		var from := side * (n - 2.0) * 12.0 * unit + back * span * 0.55
		var len := (24.0 + 64.0 * rush) * unit * (0.55 + 0.45 * sin(_clock * 9.0 + n))
		draw_line(from, from + back * len, Color(1, 1, 1, 0.12 * rush), 1.5 * unit)

## A six-point star at the nose plus a hot core. Small and hard-edged on purpose:
## a big soft blob reads as smoke, and a drone that appears to be smoking between
## shots is a drone that looks broken.
func _draw_gunflash(span: float) -> void:
	if muzzle <= 0.0:
		return
	var k := clampf(muzzle / MUZZLE_TIME, 0.0, 1.0)
	var aim := aim_dir()
	var at := aim * span * 0.44 + bob
	var r := span * (0.06 + 0.05 * k)
	var pts := PackedVector2Array()
	for i in 6:
		var a := aim.angle() + float(i) * PI / 3.0
		pts.append(at + Vector2.RIGHT.rotated(a) * r * (1.0 if i % 2 == 0 else 0.4))
	draw_polygon(pts, PackedColorArray([Color(1.0, 0.88, 0.54, 0.85 * k)]))
	draw_circle(at, r * 0.34, Color(1.0, 1.0, 0.86, 0.9 * k))

## The pressure wave left by a dash: a ring that opens and thins over its window.
func _draw_dash_ring(unit: float, span: float) -> void:
	if _dash_ring <= 0.0:
		return
	var t := 1.0 - _dash_ring / DASH_RING
	draw_arc(Vector2.ZERO, span * (0.4 + 2.0 * t), 0.0, TAU, 40,
		Color(0.75, 0.95, 1.0, (1.0 - t) * 0.45), (3.0 - 2.2 * t) * unit)

## The arrow is the fire direction: red when locked, amber while acquiring, cyan
## when it is only pointing where the drone is flying. It shows what a click would
## actually do before the click, which is the whole point of an aim indicator.
func _draw_aim_arrow(unit: float) -> void:
	var aim := aim_dir()
	var tint := Color(1.0, 0.4, 0.4) if locked != null else (
		Color(1.0, 0.85, 0.35) if acquiring != null else Color(0.45, 0.92, 1.0))
	var tail := aim * BODY.x * 0.66 * unit
	var tip := aim * (BODY.x * 0.66 + AIM_ARROW) * unit
	var barb := aim.orthogonal() * 7.0 * unit
	var base := tip - aim * 11.0 * unit
	draw_line(tail, base, Color(tint.r, tint.g, tint.b, 0.55), 2.5 * unit)
	draw_line(tip, base + barb, tint, 3.0 * unit)
	draw_line(tip, base - barb, tint, 3.0 * unit)

## Drawn here rather than on the droid: the drone owns lock state, and offsetting
## by (target - position) keeps the reticle in this node's local space.
func _draw_reticle(unit: float) -> void:
	if locked != null:
		var at := locked.position - position
		var r := (locked.size.x * 0.5 + 12.0) * unit
		for corner in 4:
			var a := float(corner) * PI * 0.5 + PI * 0.25
			var p := Vector2.RIGHT.rotated(a) * r
			draw_line(p - Vector2(6.0, 0).rotated(a), p + Vector2(6.0, 0).rotated(a),
				Color(1.0, 0.35, 0.35, 0.95), 2.5 * unit)
	elif acquiring != null:
		var at2 := acquiring.position - position
		draw_arc(at2, (acquiring.size.x * 0.5 + 12.0) * unit, -PI * 0.5,
			-PI * 0.5 + TAU * lock_progress(), 24, Color(1.0, 0.85, 0.35, 0.9), 2.5 * unit)
