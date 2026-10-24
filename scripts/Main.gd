extends Node2D
## Scene assembly, object pools, feedback ("juice") and the ad/leaderboard
## policy.
##
## Entities live in `world` and hold world coordinates. The camera follows the
## drone, so `world` is offset by `Layout.world_offset()` every frame and the
## drone reads as centred while the ground scrolls endlessly under it. Screen
## shake is added to that same offset, which is why entity math never mentions
## either.

## Expanding ring used by the bomb blast.
class BlastRing extends Node2D:
	var radius := 120.0
	var life := 0.35
	const DURATION := 0.35

	func _process(delta: float) -> void:
		life -= delta
		if life <= 0.0:
			queue_free()
		queue_redraw()

	func _draw() -> void:
		var t := 1.0 - clampf(life / DURATION, 0.0, 1.0)
		draw_arc(Vector2.ZERO, radius * (0.25 + 0.75 * t), 0.0, TAU, 48,
			Color(0.5, 1.0, 1.0, 1.0 - t), 5.0 * (1.0 - t) + 1.0)

## Pooled types are preloaded: `Bullet.new` taken as a bare Callable parses in the
## editor and in every headless run, but fails in the web export with "Cannot find
## member new in base Bullet". Calling `.new()` inside a method is fine, so the
## factories below are methods and the pool receives those.
const BulletScript := preload("res://scripts/Bullet.gd")
const DroidFireScript := preload("res://scripts/DroidFire.gd")
const PickupScript := preload("res://scripts/Pickup.gd")

const GroundScript := preload("res://scripts/Ground.gd")

const MAX_BULLETS := 96
const MAX_FIRES := 32
const MAX_PICKUPS := 8
const SHAKE_TIME := 5.0
const SHAKE_AMP := 9.0
const REVIVE_INVULN := 1.6
const RETRY_DELAY := 0.6
## Camera easing: 1.0 would weld the drone to the screen centre.
const CAM_FOLLOW := 5.5
## Camera lead, in seconds of drone velocity. Looking a little further along the
## direction of travel puts more of what is coming onto the screen. It has to be
## more than 1/CAM_FOLLOW (0.18 s) or the follower's own lag cancels it exactly.
const CAM_LEAD := 0.35
## Slow drift of the camera around the drone while it hovers, so a still frame is
## never quite still.
const CAM_BREATH := 3.0

var world: Node2D
var ground: Node2D
var decals: Node2D
var traffic: Traffic
var wildlife: Wildlife
var drone: Drone
var spawner: Spawner
var hud: Hud
var view: View3D
var grade: Grade
var debug_label: Label

var bullets: Array = []
var fires: Array = []
var pickups: Array = []

var shake := 0.0
var fx_clock := 0.0
var dead_time := 0.0
var pending_revive := false
var debug := false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	debug = "--debug" in OS.get_cmdline_user_args()

	world = Node2D.new()
	add_child(world)
	# First child, so it draws behind every entity.
	ground = GroundScript.new()
	world.add_child(ground)
	# Scorch decals sit between the ground and everything standing on it, so a
	# mark never paints over a bot parked on top of it.
	decals = Node2D.new()
	world.add_child(decals)
	world.move_child(decals, 1)
	# Traffic and wildlife are scenery layers: added before any entity, so they
	# draw underneath the bots, rounds and pickups that come later.
	traffic = Traffic.new()
	world.add_child(traffic)
	wildlife = Wildlife.new()
	world.add_child(wildlife)

	drone = Drone.new()
	world.add_child(drone)
	spawner = Spawner.new()
	add_child(spawner)
	spawner.setup(world, drone)
	hud = Hud.new()
	add_child(hud)
	# Grade goes in behind every HUD control: it is atmosphere laid over the
	# world, not over the score readout the player has to read.
	grade = Grade.new()
	hud.add_child(grade)
	hud.move_child(grade, 0)
	if Game.view_3d:
		view = View3D.new()
		add_child(view)
		view.setup(self, drone)

	drone.fired.connect(_shoot)
	drone.collected.connect(_on_collected)
	drone.hit_taken.connect(_on_player_hit)
	drone.lock_changed.connect(_on_lock_changed)
	spawner.droid_spawned.connect(_wire_droid)
	hud.start_pressed.connect(_begin_run)
	hud.retry_pressed.connect(_begin_run)
	hud.resume_pressed.connect(_resume)
	hud.bomb_pressed.connect(_use_bomb)
	hud.leaderboard_pressed.connect(_show_scores)
	hud.revive_pressed.connect(_request_revive)

	Game.state_changed.connect(_on_state_changed)
	Game.near_missed.connect(_on_near_miss)
	Y8Api.ad_finished.connect(_on_ad_finished)

	if debug:
		debug_label = Label.new()
		debug_label.add_theme_font_size_override("font_size", 14)
		debug_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.7))
		hud.add_child(debug_label)
		debug_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
		debug_label.offset_left = -430
		debug_label.offset_top = -26
		debug_label.offset_right = -8
		debug_label.offset_bottom = -6

	Y8Api.boot()
	_reposition_drone()
	queue_redraw()

func _reposition_drone() -> void:
	## The world has no centre to snap to any more: put the camera and the drone at
	## the origin and let the drone fly from there.
	Layout.set_camera(Vector2.ZERO)
	drone.position = Vector2.ZERO
	drone.target = Vector2.ZERO

# ---------------------------------------------------------------- input ----
func _unhandled_input(event: InputEvent) -> void:
	if event.is_echo():
		return
	# is_action_pressed() covers InputEventKey and InputEventAction, so
	# synthesised input (tests, gamepads) reaches the same handlers as keys.
	if event.is_action_pressed("pause"):
		Game.toggle_pause()
	elif event.is_action_pressed("bomb"):
		_use_bomb()
	elif _allows_tap() and (event.is_action_pressed("start") or _is_tap(event)):
		_begin_run()

func _is_tap(event: InputEvent) -> bool:
	if event is InputEventScreenTouch:
		return event.pressed
	if event is InputEventMouseButton:
		return event.pressed and event.button_index == MOUSE_BUTTON_LEFT
	return false

func _allows_tap() -> bool:
	match Game.state:
		Game.State.MENU:
			return true
		Game.State.DEAD:
			return dead_time > RETRY_DELAY
	return false

# ------------------------------------------------------------ lifecycle ---
func _begin_run() -> void:
	_clear_world()
	_reposition_drone()
	Game.start_run()
	Y8Api.game_started()

func _resume() -> void:
	Game.toggle_pause()

func _show_scores() -> void:
	Y8Api.show_leaderboard()

func _on_state_changed(state: int) -> void:
	match state:
		Game.State.PLAYING:
			get_tree().paused = false
		Game.State.PAUSED:
			get_tree().paused = true
		Game.State.DEAD:
			dead_time = 0.0
			_shake(0.5)
			if Game.wants_interstitial():
				Y8Api.interstitial()
		Game.State.MENU:
			_clear_world()
			_reposition_drone()

func _process(delta: float) -> void:
	if Game.state == Game.State.DEAD:
		dead_time += delta
	fx_clock += delta
	# Camera eases after the drone instead of locking to it, and aims a little
	# ahead of where it is going, so a fast direction change leaves the drone
	# off-centre with more world on screen in front of it.
	var lead := drone.velocity * CAM_LEAD
	lead += Vector2(sin(fx_clock * 0.7), cos(fx_clock * 0.53)) * CAM_BREATH * Layout.unit
	Layout.set_camera(Layout.camera.lerp(drone.position + lead,
		clampf(CAM_FOLLOW * delta, 0.0, 1.0)))
	var offset := Layout.world_offset()
	if shake > 0.0:
		shake = maxf(0.0, shake - delta * SHAKE_TIME)
		var amp := shake * SHAKE_AMP * Layout.unit
		offset += Vector2(randf_range(-amp, amp), randf_range(-amp, amp))
	world.position = offset
	if debug:
		var lock_id := "-" if drone.locked == null else drone.locked.id
		debug_label.text = "fps %d  view %dx%d  unit %.2f  droids %d  lock %s  props %d/%d" % [
			Engine.get_frames_per_second(), int(Layout.width()), int(Layout.height()),
			Layout.unit, Game.live_droids, lock_id, ground.props_in_view(),
			ground.cells_in_view()]

func _shake(seconds: float) -> void:
	shake = maxf(shake, seconds)

# ------------------------------------------------------------------ pools --
## Free-list semantics: every pooled object keeps an `active` flag, so a full
## pool costs one short scan instead of an allocation.
func _take(pool: Array, cap: int, factory: Callable) -> Object:
	for entry in pool:
		if not entry.active:
			return entry
	if pool.size() < cap:
		var fresh: Object = factory.call()
		world.add_child(fresh)
		pool.append(fresh)
		return fresh
	return null

func _new_bullet() -> Bullet:
	return BulletScript.new() as Bullet

func _new_fire() -> DroidFire:
	return DroidFireScript.new() as DroidFire

func _new_pickup() -> Pickup:
	return PickupScript.new() as Pickup

## target arrives untyped on purpose: the signal marshaller refuses a null in a
## typed object slot, and unlocked shots legitimately have no target.
func _shoot(origin: Vector2, dir: Vector2, speed: float, target) -> void:
	var b := _take(bullets, MAX_BULLETS, _new_bullet) as Bullet
	if b == null:
		return
	var aim_target = null
	if target != null and is_instance_valid(target):
		aim_target = target
	b.launch(origin, dir, speed, aim_target)

func _spawn_fire(at: Vector2, dir: Vector2, mode: String) -> void:
	var f := _take(fires, MAX_FIRES, _new_fire) as DroidFire
	if f != null:
		f.launch(at, dir, mode, drone, Layout.unit)

func _drop_pickup(at: Vector2) -> void:
	var roll := randf()
	var acc := 0.0
	var chosen := ""
	for kind in Game.PICKUPS:
		acc += float(Game.PICKUPS[kind].chance)
		if roll <= acc:
			chosen = kind
			break
	if chosen == "":
		return
	if chosen == "wrench" and Game.hp >= Game.START_HP:
		chosen = "core"
	var p := _take(pickups, MAX_PICKUPS, _new_pickup) as Pickup
	if p != null:
		p.spawn(at, chosen, Layout.unit)

# ---------------------------------------------------------------- droids ---
func _wire_droid(d: Droid) -> void:
	d.destroyed.connect(_on_droid_destroyed)
	d.fire_requested.connect(_spawn_fire)
	d.blocked.connect(_on_shield_blocked)
	d.impacted.connect(_on_impact)

## Sparks along the round's own direction of travel. A decorative radial puff says
## "something happened"; a cone along the shot says "that round hit".
func _on_impact(at: Vector2, direction: Vector2) -> void:
	_sparks(at, direction)

func _on_droid_destroyed(d: Droid) -> void:
	# This runs inside the bullet's area_entered flush. Spawning droids or
	# pickups from here would create collision nodes mid-query, which Godot
	# rejects ("Can't change this state while flushing queries"), so the death is
	# resolved next frame with the values captured now.
	var was_locked := drone.locked == d
	# Drop the reference now, while it is still alive: a pooled round can still be
	# in flight with this bot as its homing target.
	drone.forget(d)
	_finish_death.call_deferred(d.id, d.position, was_locked, d.color)

func _finish_death(kind: String, at: Vector2, was_locked: bool, tint: Color) -> void:
	var gain := int(float(Game.bot_score(kind)) * Game.multiplier()
		* (Game.LOCK_BONUS if was_locked else 1.0))
	var wreck := float(Bots.def(kind).w)
	Game.register_kill(kind, was_locked)
	_burst(at, tint, 14)
	_shards(at, tint, wreck)
	_smoke(at, wreck)
	_scorch(at, wreck)
	_text(at, "+%s" % Hud._fmt(gain), Color(1.0, 0.86, 0.4))
	_shake(0.14)
	if kind == "splitter":
		for offset in [Vector2(-42, -22), Vector2(42, 22)]:
			var half := spawner.spawn("walker", at + offset * Layout.unit)
			# The halves leave the wreck carrying the momentum of the round that
			# opened it, so a splitter death scatters instead of parking two new
			# bots exactly where the old one stood.
			if half != null:
				half.impulse(offset.normalized() * 240.0 * Layout.unit)
	_drop_pickup(at)

func _on_shield_blocked(at: Vector2) -> void:
	_burst(at, Color(0.65, 1.0, 0.85), 4, 90.0)

func _on_player_hit() -> void:
	_burst(drone.position, Color(1.0, 0.4, 0.35), 18, 240.0)
	_shake(0.45)

func _on_near_miss(at: Vector2) -> void:
	_text(at, "+%d NEAR" % Game.NEAR_MISS_POINTS, Color(0.55, 0.95, 1.0))

func _on_collected(kind: String) -> void:
	# apply_pickup carries the effect; without this the whole pickup system was
	# cosmetics only, which no amount of watching the game would have shown.
	Game.apply_pickup(kind)
	var tint: Color = Game.PICKUPS[kind].color
	_text(drone.position + Vector2(0, 26), kind.to_upper(), tint)
	_burst(drone.position, tint, 10, 140.0)

# ------------------------------------------------------------------- ads ---
func _request_revive() -> void:
	if not Game.can_revive():
		return
	pending_revive = true
	Y8Api.request_reward()

func _on_ad_finished(kind: String, granted: bool) -> void:
	if kind != "reward" or not pending_revive:
		return
	pending_revive = false
	if not granted:
		_text(drone.position, "NO BONUS", Color(0.8, 0.6, 0.6))
		return
	Game.revive()
	drone.grant_invuln(REVIVE_INVULN)
	for f in fires:
		if f.active:
			f.despawn()
	_text(drone.position, "REVIVED", Color(0.4, 1.0, 0.7))
	_shake(0.3)

func _use_bomb() -> void:
	if not Game.use_bomb():
		return
	var radius := Game.BOMB_RADIUS * Layout.unit
	for f in fires:
		if f.active and f.position.distance_to(drone.position) <= radius:
			f.despawn()
	for child in world.get_children():
		if child is Droid and child.position.distance_to(drone.position) <= radius:
			child.hit_from(drone.position, 2)
	_burst(drone.position, Color(0.5, 1.0, 1.0), 40, 520.0)
	_ring(drone.position, radius)
	_scorch(drone.position, Game.BOMB_RADIUS * 1.6)
	_shake(0.6)

func _clear_world() -> void:
	for b in bullets:
		if b.active:
			b.despawn()
	for f in fires:
		if f.active:
			f.despawn()
	for p in pickups:
		if p.active:
			p.despawn()
	for child in world.get_children():
		if child is Droid or child is Label or child is CPUParticles2D:
			child.queue_free()
	for d in decals.get_children():
		d.queue_free()
	world.position = Vector2.ZERO
	shake = 0.0

# -------------------------------------------------------------------- fx ---
func _burst(at: Vector2, color: Color, amount: int, velocity := 220.0) -> void:
	if Game.view_3d:
		view.burst(at, color, amount, velocity)
		return
	var unit := Layout.unit
	var p := CPUParticles2D.new()
	p.position = at
	p.amount = amount
	p.lifetime = 0.55
	p.one_shot = true
	p.emitting = true
	p.direction = Vector2(0, -1)
	p.spread = 180.0
	p.gravity = Vector2(0, 900.0 * unit)
	p.initial_velocity_min = velocity * 0.4 * unit
	p.initial_velocity_max = velocity * unit
	p.scale_amount_min = 1.8 * unit
	p.scale_amount_max = 4.2 * unit
	p.color = color
	world.add_child(p)
	get_tree().create_timer(1.1).timeout.connect(p.queue_free)

func _ring(at: Vector2, radius: float) -> void:
	var r := BlastRing.new()
	r.position = at
	r.radius = radius
	world.add_child(r)

func _on_lock_changed(target: Droid) -> void:
	hud.set_lock(target != null)

func _text(at: Vector2, value: String, color: Color) -> void:
	var l := Label.new()
	l.text = value
	l.add_theme_font_size_override("font_size", 20)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0.02, 0.05, 0.09))
	l.add_theme_constant_override("outline_size", 5)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if Game.view_3d:
		# Screen space, projected from the 3D world, so numbers line up with the
		# meshes instead of the logical grid underneath them.
		l.position = view.project_to_screen(at)
		hud.add_child(l)
	else:
		l.position = at
		world.add_child(l)
	var t := l.create_tween()
	t.tween_property(l, "position", at + Vector2(0, -64.0 * Layout.unit), 0.85)
	t.parallel().tween_property(l, "modulate:a", 0.0, 0.85)
	t.tween_callback(l.queue_free)

# ------------------------------------------------------------------- effects --
## Torn chassis thrown by a kill. A bird's-eye plane has no "down" to fall in, so
## debris skids across the ground under friction and stops. Chunks that drifted to
## the bottom of the screen would be telling you the map is a wall.
class Shard extends Node2D:
	var velocity := Vector2.ZERO
	var spin := 0.0
	var angle := 0.0
	var life := 0.0
	var size := 5.0
	var tint := Color.WHITE
	const FRICTION := 3.4
	const LIFE := 1.15

	func launch(at: Vector2, vel: Vector2, s: float, c: Color) -> void:
		position = at
		velocity = vel
		spin = randf_range(-9.0, 9.0)
		angle = randf() * TAU
		size = s
		tint = c
		life = LIFE * randf_range(0.7, 1.0)

	func _process(delta: float) -> void:
		life -= delta
		if life <= 0.0:
			queue_free()
			return
		position += velocity * delta
		velocity = velocity.lerp(Vector2.ZERO, minf(1.0, FRICTION * delta))
		angle += spin * delta
		spin = lerpf(spin, 0.0, minf(1.0, FRICTION * delta))
		queue_redraw()

	func _draw() -> void:
		if Game.view_3d:
			return
		var unit := Layout.unit
		var k := clampf(life / LIFE, 0.0, 1.0)
		Art.contact(self, Vector2.ZERO, size * 0.9 * unit, k * 0.5)
		var c := Art.shaded(tint, 0.45)
		c.a = k
		draw_set_transform(Vector2.ZERO, angle, Vector2.ONE)
		draw_colored_polygon(PackedVector2Array([
			Vector2(-size, -size * 0.5), Vector2(size * 0.8, -size * 0.25),
			Vector2(size * 0.15, size * 0.7)]), c)

## Burn mark left on the ground, on its own layer under everything standing on it,
## so a scorch goes beneath a bot parked on top of it and wears out rather than
## stacking up into a black mat.
class Scorch extends Node2D:
	var blotches: Array = []
	var radius := 40.0
	var life := 0.0
	const LIFE := 7.0

	func launch(at: Vector2, r: float) -> void:
		position = at
		radius = r
		life = LIFE * randf_range(0.8, 1.0)
		for i in 7:
			blotches.append(Vector2.RIGHT.rotated(randf() * TAU)
				* randf_range(0.1, 0.8))

	func _process(delta: float) -> void:
		life -= delta
		if life <= 0.0:
			queue_free()
			return
		queue_redraw()

	func _draw() -> void:
		if Game.view_3d:
			return
		var unit := Layout.unit
		var a := 0.28 * clampf(life / LIFE, 0.0, 1.0)
		draw_circle(Vector2.ZERO, radius * unit, Color(0.07, 0.055, 0.045, a))
		for b in blotches:
			var at: Vector2 = b
			draw_circle(at * radius * unit, radius * 0.28 * unit,
				Color(0.05, 0.04, 0.03, a * 0.85))

## Smoke off a burnt-out chassis. On a bird's-eye plane "up" is toward the camera,
## so smoke cannot rise on screen: it spreads, thins, and the wind drags it
## sideways. Puffs rather than CPUParticles2D, which needs a texture to not be a
## crowd of little squares.
class Smoke extends Node2D:
	var puffs: Array = []
	var base := 20.0
	var life := 0.0
	const LIFE := 1.6

	func launch(at: Vector2, r: float) -> void:
		position = at
		base = r
		life = LIFE
		for i in 6:
			puffs.append([Vector2.RIGHT.rotated(randf() * TAU) * randf_range(0.0, 0.55),
				randf_range(0.45, 1.0)])

	func _process(delta: float) -> void:
		life -= delta
		if life <= 0.0:
			queue_free()
			return
		position += Art.WIND * 24.0 * Layout.unit * delta
		queue_redraw()

	func _draw() -> void:
		if Game.view_3d:
			return
		var unit := Layout.unit
		var t := 1.0 - clampf(life / LIFE, 0.0, 1.0)
		for puff in puffs:
			var drift: Vector2 = puff[0]
			var w: float = puff[1]
			var at := drift * base * unit + Art.WIND * base * t * 1.4 * unit
			var c := Color(0.32, 0.32, 0.34, 0.34 * (1.0 - t) * w)
			draw_circle(at, base * unit * (0.35 + 1.25 * t) * w, c)

## Sparks along the shot's own line, for the frames a round is spent on armour.
## Hard slivers read as metal hitting metal; a soft puff would read as nothing in
## particular having happened.
class Spark extends Node2D:
	var dir := Vector2.RIGHT
	var streaks: Array = []
	var life := 0.0
	const LIFE := 0.18
	const CONE := 0.5

	func launch(at: Vector2, d: Vector2) -> void:
		position = at
		dir = d
		life = LIFE
		for i in 6:
			streaks.append([randf_range(-CONE, CONE), randf_range(0.5, 1.0)])

	func _process(delta: float) -> void:
		life -= delta
		if life <= 0.0:
			queue_free()
			return
		queue_redraw()

	func _draw() -> void:
		if Game.view_3d:
			return
		var unit := Layout.unit
		var t := clampf(life / LIFE, 0.0, 1.0)
		for s in streaks:
			var a: float = s[0]
			var w: float = s[1]
			var d := dir.rotated(a)
			var reach := (13.0 + 26.0 * (1.0 - t)) * unit * w
			draw_line(d * reach * 0.25, d * reach,
				Color(1.0, 0.9, 0.62, t * 0.9), 1.6 * unit)

func _shards(at: Vector2, tint: Color, wreck: float) -> void:
	if Game.view_3d:
		return
	var unit := Layout.unit
	for i in 5:
		var s := Shard.new()
		decals.add_child(s)
		var off := Vector2.RIGHT.rotated(randf() * TAU) * wreck * 0.3 * unit
		s.launch(at + off, Vector2.RIGHT.rotated(randf() * TAU)
			* randf_range(130.0, 320.0) * unit,
			randf_range(3.4, 6.5) * unit * clampf(wreck / 36.0, 0.8, 1.6), tint)

func _smoke(at: Vector2, wreck: float) -> void:
	if Game.view_3d:
		return
	var s := Smoke.new()
	decals.add_child(s)
	s.launch(at, wreck * 0.34 * Layout.unit)

func _scorch(at: Vector2, wreck: float) -> void:
	if Game.view_3d:
		return
	var d := Scorch.new()
	decals.add_child(d)
	d.launch(at, wreck * 0.6 * Layout.unit)

func _sparks(at: Vector2, direction: Vector2) -> void:
	if Game.view_3d:
		return
	var s := Spark.new()
	world.add_child(s)
	s.launch(at, direction)
