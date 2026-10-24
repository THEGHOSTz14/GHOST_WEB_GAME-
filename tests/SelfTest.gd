extends Node
## Automated gameplay check. Instantiates the real scene, drives it through the
## normal input path and asserts the rules in GAME.md. Exits non-zero on any
## FAIL, and tools/run_tests.sh additionally fails the run on any engine error
## in the log -- a passing assertion list with a flushed-query error in it means
## a collision callback silently skipped work.
##
##   godot --headless --path . res://tests/SelfTest.tscn
##
## Waits are in SECONDS. A headless run is not capped at 60 fps, so counting
## frames would make every timing assertion depend on machine speed.

var failures := 0
var checks := 0
var main: Node
var drone: Node
var steps: Array = []
var cursor := 0
var wait_left := 0.0

var peak_droids := 0
var locked_seen := false
var followed := false
var roam_y := 0.0
var y_span := {}
var observed_score := 0
var near_droid: Node
var far_droid: Node
var stress_shielder: Node
var collected: Array = []
var bombs_before := 0
var death_seen := false
var _collect_wired := false
var roster: Array = []
var _car_watch := Vector2.ZERO
var _car_watch_on_road := false
var _animal_watch_dist := 0.0
var _spin_at_boot := 0.0

# Physics watch: sampled every frame while a flight or steering test is armed.
var flight_watch := false
var peak_speed := 0.0
var bank_peak := 0.0
var bob_peak := 0.0
var inertia_bot: Node = null
var turn_bot: Node = null
var turn_from := Vector2.RIGHT
var split_at := Vector2.ZERO
var shove_bot: Node = null

func _ready() -> void:
	get_tree().paused = false
	main = load("res://scenes/Main.tscn").instantiate()
	add_child(main)
	drone = main.get("drone")
	build_script()
	report("scene instantiated", main != null and drone != null)

func build_script() -> void:
	steps = [
		_wait(0.8), _layout_checks, _view3d_checks,
		_press("start"), _wait(0.06), _assert_playing, _assert_guns_idle_without_target,
		_seed_pair, _wait(0.5), _assert_lock_prefers_nearest,
		_tap_far, _wait(0.5), _assert_tap_overrides,
		# Hold the lock by chasing it, the way a player does, then let the guns run.
		# Fire is a button now, so the test has to hold it like a player would.
		_follow_lock, _hold(true), _wait(7.0), _hold(false), _assert_lock_firing_scores,
		_note_roster,
		_wait(0.2), _assert_rigs_track_sim,
		_stress_setup, _wait(3.0), _assert_stress, _world_life_checks,
		_wait(0.3), _assert_cars_moved, _assert_animal_flees,
		_combat_checks,
		_note_bombs, _press("bomb"), _wait(0.15), _assert_bomb_spent,
		_resize(Vector2(430, 900)), _wait(0.25), _assert_portrait, _ground_checks,
		_resize(Vector2(2560, 1000)), _wait(0.25), _assert_ultrawide,
		_resize(Vector2(1280, 720)), _wait(0.25),
		# Flight and steering physics (GAME.md §4, §5). Each step is a slice of
		# simulated time, so the whole block reads like the ramp curve it tests.
		_flight_setup, _hold_key("move_right", true), _wait(0.30),
		_assert_ramp_is_not_a_snapping,
		_wait(1.3), _assert_terminal_speed, _assert_camera_leads,
		_hold_key("move_right", false), _hold_key("move_up", true), _wait(0.16),
		_assert_banks_into_the_turn,
		_hold_key("move_up", false), _wait(0.7), _assert_settles_when_released,
		_press("dash"), _wait(0.06), _assert_dash_breaks_cruise,
		_release("dash"), _wait(0.7), _assert_dash_fades_back,
		_wait(0.5), _assert_hover_bob,
		_flight_teardown,
		_bot_inertia_setup, _wait(0.12), _assert_bots_ramp_to_speed,
		_wait(0.8), _assert_bots_reach_their_pace,
		_knockback_setup, _wait(0.15), _assert_turn_is_rate_limited,
		_wait(1.25), _assert_turn_completes,
		_splitter_setup, _wait(0.15), _assert_splitter_halves_scatter,
		_assert_death_leaves_marks, _assert_grade_sits_behind_hud,
		_cleanup_bots,
		_kill_player, _wait(0.4), _assert_dead,
		# RETRY_DELAY is 0.6 s by design, so wait it out before asking to retry
		_wait(1.2), _press("start"), _wait(0.15), _assert_restarted,
		_finish,
	]

func _wait(seconds: float) -> Callable:
	return func() -> void: wait_left = seconds

func _process(delta: float) -> void:
	peak_droids = maxi(peak_droids, Game.live_droids)
	var view = main.get("view") if main != null else null
	if view != null and int(view.get("deaths_animated")) > 0:
		death_seen = true
	if drone != null and drone.get("locked") != null:
		locked_seen = true
	if flight_watch and drone != null:
		var sp: float = (drone.get("velocity") as Vector2).length()
		peak_speed = maxf(peak_speed, sp)
		bank_peak = maxf(bank_peak, absf(drone.get("bank")))
		bob_peak = maxf(bob_peak, (drone.get("bob") as Vector2).length())
	if followed:
		var t = drone.get("locked")
		if t != null:
			drone.set("pointer_active", true)
			drone.set("target", t.position)
		for d in get_tree().get_nodes_in_group("droids"):
			var rec: Dictionary = y_span.get(d, {"min": d.position.y, "max": d.position.y})
			rec["min"] = minf(rec["min"], d.position.y)
			rec["max"] = maxf(rec["max"], d.position.y)
			y_span[d] = rec
			roam_y = maxf(roam_y, rec["max"] - rec["min"])
	if wait_left > 0.0:
		wait_left -= delta
		return
	if cursor >= steps.size():
		return
	var entry: Variant = steps[cursor]
	cursor += 1
	if entry is Callable:
		(entry as Callable).call()

func _press(action: String) -> Callable:
	return func() -> void:
		# A parsed InputEventAction is what a real keypress becomes by the time it
		# reaches the tree. Input.action_press() alone does NOT deliver an event to
		# _unhandled_input in 4.7 -- parse_input_event is required.
		var ev := InputEventAction.new()
		ev.action = action
		ev.pressed = true
		Input.parse_input_event(ev)

func _resize(to: Vector2) -> Callable:
	return func() -> void: get_tree().root.size = to

func _action_uses_mouse_button(action: String, button: int) -> bool:
	if not InputMap.has_action(action):
		return false
	for ev in InputMap.action_get_events(action):
		if ev is InputEventMouseButton and ev.button_index == button:
			return true
	return false

## Held key rather than a parsed event: the flight model polls Input.get_vector in
## _physics_process, so it is the action state that has to change, not the queue.
func _hold_key(action: String, on: bool) -> Callable:
	return func() -> void:
		if on:
			Input.action_press(action)
		else:
			Input.action_release(action)

func _release(action: String) -> Callable:
	return _hold_key(action, false)

func _hold(on: bool) -> Callable:
	return func() -> void:
		if on:
			Input.action_press("fire")
		else:
			Input.action_release("fire")

func _world_life_checks() -> void:
	var traffic = main.get("traffic")
	var wildlife = main.get("wildlife")
	report("cars exist on the roads", traffic != null and traffic.count() > 0,
		"%d cars" % (traffic.count() if traffic != null else -1))
	if traffic != null and traffic.count() > 0:
		var car = traffic.cars[0]
		var was_on_road: bool = GroundDef.in_road(car.pos, 26.0)
		var before: Vector2 = car.pos
		wait_left = 0.6
		# position is sampled after the wait, in _assert_cars_moved
		_car_watch = before
		_car_watch_on_road = was_on_road
		report("cars sit in a lane, not on the kerb", was_on_road, str(car.pos.round()))
	if wildlife != null and wildlife.count() > 0:
		var critter = wildlife.animals[0]
		# Pick a direction with clear ground in it: an animal fleeing into a road
		# legitimately turns aside, and this test is about the bolt, not the terrain.
		var spot := Vector2.ZERO
		for attempt in 16:
			var off: Vector2 = Vector2.RIGHT.rotated(randf() * TAU) * 120.0
			spot = Layout.camera + off
			if not GroundDef.in_road(spot, 90.0) and not GroundDef.in_river(spot, 90.0):
				break
		critter.pos = spot
		critter.state = "graze"
		_animal_watch_dist = critter.pos.distance_to(Layout.camera)
		wait_left = 0.4
		report("animals exist", wildlife.count() >= 4, "%d animals" % wildlife.count())

func _assert_cars_moved() -> void:
	var traffic = main.get("traffic")
	if traffic == null or traffic.count() == 0:
		return
	var car = traffic.cars[0]
	var moved: float = car.pos.distance_to(_car_watch)
	report("cars drive along the road", moved > 5.0,
		"moved %.0f" % moved)
	report("cars stay on the road as it bends",
		GroundDef.in_road(car.pos, 26.0) or not _car_watch_on_road)

func _assert_animal_flees() -> void:
	var wildlife = main.get("wildlife")
	if wildlife == null or wildlife.count() == 0:
		report("animals exist to flee", false)
		return
	var critter = wildlife.animals[0]
	var dist: float = critter.pos.distance_to(Layout.camera)
	report("propellers are turning", drone.get("spin") > _spin_at_boot + 5.0,
		"spin %.0f from %.0f" % [drone.get("spin"), _spin_at_boot])
	report("a nearby animal bolts from the drone",
		critter.state == "flee" and dist > _animal_watch_dist + 20.0,
		"state=%s %.0f -> %.0f" % [critter.state, _animal_watch_dist, dist])
	report("a wounded bot shows a health bar", _health_bar_visible())

func _health_bar_visible() -> bool:
	# A 2-hp bot at 1 hp must report half health, which is what the bar draws.
	var spawner: Node = main.get("spawner")
	var d = spawner.call("spawn", "turret", Layout.camera + Vector2(600.0, 0.0))
	if d == null:
		return false
	d.call("hit_from", d.position + Vector2(0, -40.0), 1)
	var ratio: float = d.call("health_ratio")
	if is_instance_valid(d):
		d.queue_free()
	return is_equal_approx(ratio, 0.5)

func report(label: String, ok: bool, detail := "") -> void:
	checks += 1
	if not ok:
		failures += 1
	print(("PASS  " if ok else "FAIL  ") + label + ("  " + detail if detail != "" else ""))

# ------------------------------------------------------------------ world ----
func _layout_checks() -> void:
	_spin_at_boot = drone.get("spin")
	var view: Rect2 = Layout.view
	report("view is centred on the camera",
		view.get_center().distance_to(Layout.camera) < 0.5,
		"cam %s" % str(Layout.camera.round()))
	report("view equals the logical viewport",
		absf(view.size.x - Layout.size.x) < 0.5 and absf(view.size.y - Layout.size.y) < 0.5,
		"%.0fx%.0f" % [view.size.x, view.size.y])
	var there := Vector2(1234.0, -567.0)
	var back := Layout.screen_to_world(Layout.world_to_screen(there))
	report("screen/world conversion round-trips", back.distance_to(there) < 0.01,
		"off by %.4f" % back.distance_to(there))
	report("unit is positive and aspect-independent", Layout.unit > 0.9, "%.2f" % Layout.unit)
	var inside := 0
	for i in 20:
		if Layout.in_view(Layout.rand_edge_entry(), -10.0):
			inside += 1
	report("bots enter from just outside the view", inside == 0, "%d landed inside" % inside)
	report("fire is bound to the left mouse button", _action_uses_mouse_button("fire",
		MOUSE_BUTTON_LEFT), str(InputMap.action_get_events("fire")))
	report("bomb is bound to the right mouse button",
		_action_uses_mouse_button("bomb", MOUSE_BUTTON_RIGHT))
	report("drone artwork imported", Drone.BodyTexture.get_width() > 0
		and Drone.PropTexture.get_width() > 0,
		"body %dx%d prop %dx%d" % [Drone.BodyTexture.get_width(),
			Drone.BodyTexture.get_height(), Drone.PropTexture.get_width(),
			Drone.PropTexture.get_height()])
	var hubs_ok := true
	for hub in Drone.ROTOR_HUBS:
		if not Rect2(0, 0, 1, 1).has_point(hub):
			hubs_ok = false
	report("rotor hubs sit inside the sprite", hubs_ok
		and Drone.ROTOR_HUBS.size() == Drone.ROTOR_DIRS.size())
	report("hitbox stays forgiving against the bigger sprite",
		Drone.BODY.x * 0.42 < Drone.SPRITE_SPAN * 0.3,
		"hit %.0f vs art %.0f" % [Drone.BODY.x * 0.42, Drone.SPRITE_SPAN])
	report("roads curve instead of forming a grid",
		absf(GroundDef.road_x(0.0, 1) - GroundDef.road_x(900.0, 1)) > 20.0
		and absf(GroundDef.road_y(0.0, 2) - GroundDef.road_y(1200.0, 2)) > 20.0,
		"x %.0f -> %.0f" % [GroundDef.road_x(0.0, 1), GroundDef.road_x(900.0, 1)])
	report("bot roster lists every spawnable type", Bots.spawnable().size() >= 5,
		str(Bots.spawnable()))
	report("every bot has valid roam and volley modes", _roster_sane(),
		str(Bots.CATALOG.keys()))
	report("turret appears no earlier than 55s",
		not Bots.available_at(30.0, "turret") and Bots.available_at(60.0, "turret"))
	report("pressure curve is smooth and bounded",
		Game.pressure() >= 0.0 and Game.pressure() <= 1.0
		and Game.speed_scale() >= 1.0 and Game.speed_scale() <= 1.36,
		"pressure %.2f speed %.2f spawn %.2fs" % [Game.pressure(), Game.speed_scale(),
			Game.spawn_interval()])
	report("nothing steps: spawn interval only ever shrinks",
		Game.spawn_interval() >= 0.9, "%.2f" % Game.spawn_interval())
	report("boss stays out of the rotation until Phase 3", not Bots.spawnable().has("hauler"))

func _roster_sane() -> bool:
	for id in Bots.CATALOG:
		var d: Dictionary = Bots.def(id)
		for key in ["hp", "speed", "score", "w", "h", "appears_at", "fire", "weight", "color"]:
			if not d.has(key):
				return false
		if not ["none", "flak3", "mine"].has(String(d.get("volley", ""))):
			return false
		if not ["waypoint", "charge", "crawl"].has(String(d.get("roam", ""))):
			return false
	return true

# ------------------------------------------------------------------ ground ---
func _ground_checks() -> void:
	var ground = main.get("ground")
	if ground == null:
		report("ground layer exists", false)
		return
	# Fly far away: an endless map must still be populated out there.
	drone.position = Vector2(48000.0, -36000.0)
	wait_left = 1.5
	report("ground still scatters far from the origin", ground.props_in_view() > 0,
		"%d props over %d cells" % [ground.props_in_view(), ground.cells_in_view()])
	drone.position = Vector2.ZERO
	wait_left = 1.5
	var before: int = ground.placed().size()
	ground.call("add_prop", "tree", Vector2(240.0, 130.0), 34.0)
	report("add_prop places a prop", ground.placed().size() == before + 1,
		"%d -> %d" % [before, ground.placed().size()])
	var removed: bool = ground.call("remove_prop_near", Vector2(240.0, 130.0), 60.0)
	report("remove_prop_near deletes it",
		removed and ground.placed().size() == before, "%d left" % ground.placed().size())
	report("remove_prop_near reports a miss",
		not bool(ground.call("remove_prop_near", Vector2(9000.0, 9000.0), 40.0)))
	var h1: int = ground.call("_hash", 5, 9)
	ground.call("reseed", 4242)
	var h2: int = ground.call("_hash", 5, 9)
	report("reseed re-rolls the map", h1 != h2, "%d vs %d" % [h1, h2])
	ground.call("reseed", GroundDef.SEED)
	report("reseed is reversible", int(ground.call("_hash", 5, 9)) == h1)
	var houses: int = GroundDef.prop_ids().count("house")
	ground.call("set_enabled", "house", false)
	report("set_enabled removes a prop type everywhere",
		GroundDef.prop_ids().count("house") == houses - 1)
	ground.call("set_enabled", "house", true)
	# Two summed sines: the contract is "stays inside its band and actually
	# wanders", not one clean period.
	var lo := INF
	var hi := -INF
	for i in 200:
		var ry: float = GroundDef.river_y(float(i) * 97.0)
		lo = minf(lo, ry)
		hi = maxf(hi, ry)
	var band: float = GroundDef.RIVER_AMPLITUDE * 1.3
	report("river stays inside its band", lo > -band and hi < band,
		"range %.0f..%.0f band +/-%.0f" % [lo, hi, band])
	report("river meanders rather than running straight",
		hi - lo > GroundDef.RIVER_AMPLITUDE, "span %.0f" % (hi - lo))
	var channel: float = GroundDef.river_y(0.0)
	report("the river channel is where props refuse to grow",
		GroundDef.in_river(Vector2(0.0, channel)))
	var lane := Vector2(GroundDef.road_x(400.0, 1), 400.0)
	report("roads stay clear of scatter", GroundDef.in_road(lane), str(lane.round()))
	report("off-road ground is not mistaken for a road",
		not GroundDef.in_road(lane + Vector2(400.0, 0.0)))
	# Same cell, same result: the map must be identical on every visit.
	var again: int = ground.call("_hash", 11, -7)
	report("scatter is deterministic per cell",
		again == int(ground.call("_hash", 11, -7)))

# --------------------------------------------------------------------- 3D ----
func _view3d_checks() -> void:
	if not Game.view_3d:
		report("2D fallback active, 3D checks skipped", true, "dvd/view_3d=false")
		return
	var view = main.get("view")
	if view == null:
		report("view node exists", false)
		return
	var cam = view.get("camera")
	report("camera is current", cam != null and cam.is_current())
	report("drone rig exists", view.get("drone_rig") != null)
	_assert_camera_frames_plane("boot")

## The framing contract is the 3D equivalent of §2: whatever the aspect ratio,
## the whole play plane must be inside the viewport.
func _assert_camera_frames_plane(label: String) -> void:
	var view = main.get("view")
	if view == null or not Game.view_3d:
		return
	var off := 0
	for c in view.call("_plane_corners"):
		var pr: Dictionary = view.call("_project", c)
		if pr.is_empty():
			off += 1
			continue
		var pos: Vector2 = pr.pos
		var vp: Vector2 = pr.vp
		if pos.x < 0.0 or pos.y < 0.0 or pos.x > vp.x or pos.y > vp.y:
			off += 1
	report("plane corners on screen (%s)" % label, off == 0,
		"%d off view at %dx%d" % [off, Layout.size.x, Layout.size.y])

func _note_roster() -> void:
	roster = get_tree().get_nodes_in_group("droids").duplicate()

func _assert_rigs_track_sim() -> void:
	var view = main.get("view")
	if view == null or not Game.view_3d:
		return
	var entries: Array = view.get("_entries")
	var droids: Array = []
	for d in roster:
		if is_instance_valid(d) and not d.is_queued_for_deletion():
			droids.append(d)
	var matched := 0
	var misplaced := 0
	for d in droids:
		for e in entries:
			if e.src == d:
				matched += 1
				var want: Vector3 = view.call("_world", d.position)
				if not (e.rig.position - want).length_squared() < 0.05:
					misplaced += 1
	report("every live bot has a rig", matched == droids.size(),
		"%d of %d, entries=%d" % [matched, droids.size(), entries.size()])
	report("rigs sit where the sim says", misplaced == 0, "%d off" % misplaced)
	if drone.get("locked") != null:
		report("lock reticle is on screen", view.get("reticle").visible)

# -------------------------------------------------------------------- lock ---
func _assert_playing() -> void:
	report("start action launches a run", Game.state == Game.State.PLAYING,
		"state=%d" % Game.state)

func _assert_guns_idle_without_target() -> void:
	var pool: Array = main.get("bullets")
	report("no lock without a target in range", drone.get("locked") == null,
		"live=%d" % Game.live_droids)
	report("guns stay idle while unlocked", pool.is_empty(), "%d pooled" % pool.size())

## Two bots at known distances, so "nearest wins" is a real assertion rather than
## a coin flip. They are frozen because the lock rule is under test here, not the
## roam AI -- _assert_lock_firing_scores covers roaming.
func _seed_pair() -> void:
	var unit: float = Layout.unit
	var spawner: Node = main.get("spawner")
	near_droid = spawner.call("spawn", "walker", drone.position + Vector2(150.0 * unit, 0.0))
	far_droid = spawner.call("spawn", "walker", drone.position + Vector2(0.0, 380.0 * unit))
	near_droid.set("speed", 0.0)
	far_droid.set("speed", 0.0)
	# Frozen and tough: the drone would otherwise kill both inside the
	# acquisition window and leave nothing to lock.
	near_droid.set("hp", 99)
	far_droid.set("hp", 99)
	report("test seeds two bots", near_droid != null and far_droid != null)

func _nearest_by_distance() -> Node:
	var best: Node = null
	var best_d: float = Game.LOCK_RADIUS * Layout.unit
	for node in get_tree().get_nodes_in_group("droids"):
		var dist: float = drone.position.distance_to(node.position)
		if dist <= best_d:
			best_d = dist
			best = node
	return best

func _assert_lock_prefers_nearest() -> void:
	var want := _nearest_by_distance()
	report("auto-lock acquires a target", drone.get("locked") != null,
		"peak=%d" % peak_droids)
	report("auto-lock takes the nearest bot", drone.get("locked") == want,
		"got=%s" % _id_of(drone.get("locked")))

func _tap_far() -> void:
	if is_instance_valid(far_droid):
		drone.call("request_lock_at", far_droid.position)

func _assert_tap_overrides() -> void:
	report("tapping a bot overrides auto-lock", drone.get("locked") == far_droid,
		"got=%s" % _id_of(drone.get("locked")))

func _follow_lock() -> void:
	followed = true
	# Retire the immortal test fixtures: they are the nearest targets, so the drone
	# would spend the whole scoring window shooting them for nothing.
	for fixture in [near_droid, far_droid]:
		if fixture != null and is_instance_valid(fixture):
			fixture.queue_free()

func _assert_lock_firing_scores() -> void:
	var pool: Array = main.get("bullets")
	report("locked drone fires on its own", not pool.is_empty(), "%d pooled" % pool.size())
	report("kills score without any fire button", Game.score > 0,
		"score=%d t=%.0fs kills=%d" % [Game.score, Game.elapsed, Game.kills])
	report("bots roam in Y as well as X", roam_y > 20.0,
		"span=%.0f over %d bots" % [roam_y, y_span.size()])
	followed = false

func _id_of(d: Node) -> String:
	return "none" if d == null else "%s@%.0f,%.0f" % [d.get("id"), d.position.x, d.position.y]

# ------------------------------------------------------------------- stress ----
func _stress_setup() -> void:
	var unit: float = Layout.unit
	var spawner: Node = main.get("spawner")
	var world: Node = main.get("world")
	stress_shielder = spawner.call("spawn", "shielder",
		drone.position + Vector2(200.0 * unit, 0.0))
	stress_shielder.set("speed", 0.0)
	stress_shielder.set("hp", 99)      # the arc checks below need it alive
	spawner.call("spawn", "turret", drone.position + Vector2(-240.0 * unit, 60.0 * unit))
	# Rounds pushed in directly, so flak and mines are certainly in the pool
	# rather than waiting on a bot to decide to shoot.
	main.call("_spawn_fire", drone.position + Vector2(90.0 * unit, 0.0),
		Vector2.LEFT, "flak")
	main.call("_spawn_fire", drone.position + Vector2(0.0, 120.0 * unit),
		Vector2.UP, "mine")
	Game.hp = 1
	if not _collect_wired:
		_collect_wired = true
		drone.collected.connect(_note_collect)
	for kind in ["wrench", "overcharge"]:
		var p = main.call("_new_pickup")
		world.add_child(p)
		main.get("pickups").append(p)
		p.spawn(drone.position, kind, unit)
	# The rounds above are real and would otherwise eat the shield cells the
	# damage checks below count on; the hit path is covered deterministically.
	drone.call("grant_invuln", 3.5)

func _note_collect(kind) -> void:
	collected.append(kind)

func _assert_stress() -> void:
	var fires: Array = main.get("fires")
	report("hostile rounds exist in the pool", not fires.is_empty(),
		"%d pooled" % fires.size())
	report("wrench heals a shield cell", Game.hp >= 2,
		"hp=%d collected=%s" % [Game.hp, str(collected)])
	report("overcharge raises the fire rate", Game.overcharge > 0.0,
		"remaining=%.1f" % Game.overcharge)
	Game.hp = Game.START_HP
	drone.set("i_frames", 0.0)
	if stress_shielder != null and is_instance_valid(stress_shielder):
		var hp_before := int(stress_shielder.get("hp"))
		var arc: float = stress_shielder.get("shield_angle")
		var at: Vector2 = stress_shielder.position
		stress_shielder.call("hit_from", at + Vector2.RIGHT.rotated(arc) * 40.0, 1)
		report("shield arc eats a round arriving inside it",
			int(stress_shielder.get("hp")) == hp_before, "hp=%d" % hp_before)
		stress_shielder.call("hit_from", at + Vector2.RIGHT.rotated(arc + PI) * 40.0, 1)
		report("the gap behind the arc is open",
			int(stress_shielder.get("hp")) == hp_before - 1,
			"hp=%d expected=%d" % [int(stress_shielder.get("hp")), hp_before - 1])
	else:
		report("shielder survived the stress window", false, "freed early")

# ------------------------------------------------------------------ damage ----
func _combat_checks() -> void:
	var before := Game.multiplier()
	Game.register_kill("walker")
	Game.register_kill("walker")
	report("combo raises the multiplier", Game.multiplier() > before,
		"%.1f -> %.1f" % [before, Game.multiplier()])
	var cap := 1.0 + Game.COMBO_MAX_STACKS * Game.COMBO_PER_STACK
	var guard := 0
	while Game.multiplier() < cap and guard < 40:
		Game.register_kill("walker")
		guard += 1
	report("multiplier caps at x5", is_equal_approx(Game.multiplier(), cap),
		"%.1f" % Game.multiplier())

	# At the cap the multiplier is pinned, so these two kills differ only by the
	# lock bonus (GAME.md §6).
	var s0 := Game.score
	Game.register_kill("walker", false)
	var plain := Game.score - s0
	var s1 := Game.score
	Game.register_kill("walker", true)
	var bonus := Game.score - s1
	report("locked kill pays the 1.2x bonus", bonus >= plain * Game.LOCK_BONUS,
		"plain=%d locked=%d" % [plain, bonus])

	var hp_before := Game.hp
	drone.set("i_frames", 0.0)
	var landed: bool = drone.call("hit_by_fire")
	report("a hit costs one shield cell", landed and Game.hp == hp_before - 1,
		"landed=%s hp=%d" % [str(landed), Game.hp])
	report("invulnerability blocks the follow-up hit", not drone.call("hit_by_fire"),
		"hp=%d" % Game.hp)
	drone.set("i_frames", 0.0)
	Game.hp = Game.START_HP

func _note_bombs() -> void:
	bombs_before = Game.bombs

func _assert_bomb_spent() -> void:
	# Relative, because a Core pickup may legitimately have granted another
	# charge during the run (GAME.md §8).
	report("bomb consumes a charge", Game.bombs == bombs_before - 1,
		"%d -> %d" % [bombs_before, Game.bombs])

# --------------------------------------------------------------- responsive ---
func _assert_portrait() -> void:
	report("portrait grows the view", Layout.view.size.y > 2000.0,
		"view %.0fx%.0f" % [Layout.view.size.x, Layout.view.size.y])
	report("portrait scales gameplay units up", Layout.unit > 1.0, "%.2f" % Layout.unit)
	report("portrait keeps the camera centred",
		Layout.view.get_center().distance_to(Layout.camera) < 0.5)
	# The sprite multiplies by unit inside _draw, so the hull node itself has to
	# stay at 1.0 -- with unit on the node as well, the drone drew twice its size on
	# a phone while its hitbox stayed single-scaled.
	var hull_scale: Vector2 = drone.get("scale")
	var box = drone.get("_hitbox")
	report("hull node is not scaled as well as the sprite", hull_scale == Vector2.ONE,
		str(hull_scale))
	report("hitbox carries the unit scaling itself", box != null
		and absf((box as CollisionShape2D).scale.x - Layout.unit) < 0.02,
		"box=%s unit=%.2f" % [str((box as CollisionShape2D).scale), Layout.unit])
	report("lock reach scales with the view", Game.LOCK_RADIUS * Layout.unit > 400.0,
		"%.0f" % (Game.LOCK_RADIUS * Layout.unit))
	_assert_camera_frames_plane("portrait")

func _assert_ultrawide() -> void:
	report("ultrawide view is wider than tall",
		Layout.view.size.x > Layout.view.size.y,
		"%.0fx%.0f" % [Layout.view.size.x, Layout.view.size.y])
	report("unit floors at 1.0 on a short viewport", Layout.unit <= 1.01,
		"%.2f at %.0fx%.0f" % [Layout.unit, Layout.size.x, Layout.size.y])
	report("ultrawide keeps the camera centred",
		Layout.view.get_center().distance_to(Layout.camera) < 0.5)
	_assert_camera_frames_plane("ultrawide")

# ------------------------------------------------------------------- physics ----
func _cap_speed() -> float:
	return float(Drone.MAX_SPEED) * Layout.unit

func _flight_setup() -> void:
	Game.hp = Game.START_HP
	drone.set("i_frames", 40.0)
	drone.set("velocity", Vector2.ZERO)
	drone.set("pointer_active", false)
	drone.set("bank", 0.0)
	peak_speed = 0.0
	bank_peak = 0.0
	bob_peak = 0.0
	flight_watch = true

## A cursor jumps to full speed; a machine with rotors and mass converges on it.
## 0.30 s into a hard throttle a snapping model is already pinned at MAX_SPEED, so
## asking for under 98% of cruise is what separates the two.
func _assert_ramp_is_not_a_snapping() -> void:
	var cap := _cap_speed()
	var v: float = (drone.get("velocity") as Vector2).length()
	report("throttle ramps toward cruise instead of snapping to it",
		v > cap * 0.55 and v < cap * 0.98, "%.0f of %.0f" % [v, cap])

func _assert_terminal_speed() -> void:
	var cap := _cap_speed()
	var v: float = (drone.get("velocity") as Vector2).length()
	report("drag caps cruise with no overshoot", peak_speed <= cap * 1.02,
		"peak=%.0f cap=%.0f" % [peak_speed, cap])
	report("held throttle ends up at full cruise", v >= cap * 0.96,
		"%.0f of %.0f" % [v, cap])

## The camera is told to aim CAM_LEAD seconds down the drone's own velocity, so a
## drone in steady flight does not sit on the middle of the frame.
func _assert_camera_leads() -> void:
	var off := Layout.view.get_center().distance_to(drone.position)
	report("camera looks ahead of where the drone is", off > 24.0,
		"%.0f units off centre" % off)
	report("the lead never pushes the drone off screen",
		off < Layout.height() * 0.30, "%.0f of %.0f" % [off, Layout.height()])

func _assert_banks_into_the_turn() -> void:
	report("hull leans into the turn", bank_peak > 0.2, "%.2f" % bank_peak)

func _assert_settles_when_released() -> void:
	var v: float = (drone.get("velocity") as Vector2).length()
	report("letting go of the stick stops it", v < _cap_speed() * 0.12,
		"%.0f left" % v)

func _assert_dash_breaks_cruise() -> void:
	var cap := _cap_speed()
	var v: float = (drone.get("velocity") as Vector2).length()
	report("dash shoves the drone past cruise", v > cap * 1.6,
		"%.0f vs %.0f" % [v, cap])

func _assert_dash_fades_back() -> void:
	var cap := _cap_speed()
	var v: float = (drone.get("velocity") as Vector2).length()
	report("the burst fades into the flight model instead of stopping dead",
		v <= cap * 1.05, "%.0f vs %.0f" % [v, cap])

## Two unrelated frequencies summed, so the hull never pulses like a metronome.
## Bounded, because a bob that grew would drift the drone off its own hitbox.
func _assert_hover_bob() -> void:
	var unit := Layout.unit
	report("the hull bobs on the air cushion", bob_peak > 1.0 * unit, "%.1f" % bob_peak)
	report("and never bobs past its own limit",
		bob_peak < float(Drone.BOB) * unit * 1.6, "%.1f of %.1f" % [bob_peak, Drone.BOB])

func _flight_teardown() -> void:
	flight_watch = false
	_hold_key("move_right", false).call()
	_hold_key("move_up", false).call()

func _bot_inertia_setup() -> void:
	var unit: float = Layout.unit
	inertia_bot = main.get("spawner").call("spawn", "walker",
		drone.position + Vector2(320.0 * unit, 0.0))
	if inertia_bot != null:
		inertia_bot.set("hp", 99)
		inertia_bot.set("velocity", Vector2.ZERO)
		inertia_bot.set("knock", Vector2.ZERO)

## Ground units spin their motors up too. A bot that appears already at full speed
## reads as a sprite being dragged around, not as a machine that is moving.
func _pace_of(b: Node) -> float:
	return float(b.get("speed")) * Game.speed_scale() * Layout.unit

func _assert_bots_ramp_to_speed() -> void:
	if inertia_bot == null or not is_instance_valid(inertia_bot):
		report("test bot survived long enough to measure", false)
		return
	var pace := _pace_of(inertia_bot)
	var v: float = (inertia_bot.get("velocity") as Vector2).length()
	report("a bot eases up to its own pace", v < pace * 0.65, "%.0f of %.0f" % [v, pace])

func _assert_bots_reach_their_pace() -> void:
	if inertia_bot == null or not is_instance_valid(inertia_bot):
		report("test bot survived long enough to measure", false)
		return
	var pace := _pace_of(inertia_bot)
	var v: float = (inertia_bot.get("velocity") as Vector2).length()
	report("and is at working speed within a second", v > pace * 0.60,
		"%.0f of %.0f" % [v, pace])

## Mass is a knob the roster already carries, so it has to show: the same round
## moves a Runner further than it moves a Turret.
func _knockback_setup() -> void:
	var unit: float = Layout.unit
	var spawner: Node = main.get("spawner")
	var light = spawner.call("spawn", "runner", drone.position + Vector2(70.0 * unit, 0.0))
	var heavy = spawner.call("spawn", "turret", drone.position + Vector2(-70.0 * unit, 0.0))
	light.set("hp", 99)
	heavy.set("hp", 99)
	light.call("hit_from", drone.position, 1)
	heavy.call("hit_from", drone.position, 1)
	var lk: float = (light.get("knock") as Vector2).length()
	var hk: float = (heavy.get("knock") as Vector2).length()
	report("a landed round shoves the chassis", hk > 10.0 * unit, "%.0f" % hk)
	report("mass decides how far it goes", lk > hk * 1.4,
		"runner=%.0f turret=%.0f" % [lk, hk])
	light.queue_free()
	heavy.queue_free()
	# Heading only: with speed zeroed there is no travel to confuse the slew.
	turn_bot = spawner.call("spawn", "walker", drone.position + Vector2(200.0 * unit, 0.0))
	turn_bot.set("hp", 99)
	turn_bot.set("speed", 0.0)
	turn_bot.set("facing", Vector2.RIGHT)
	turn_from = Vector2.RIGHT
	turn_bot.set("waypoint", turn_bot.position + Vector2(-400.0 * unit, 0.0))

func _turned_so_far() -> float:
	var f: Vector2 = turn_bot.get("facing")
	return absf(wrapf(f.angle() - turn_from.angle(), -PI, PI))

## Treads have to slip to swivel faster than this, so a bot cannot face a new
## direction in the frame it is told to -- which is what makes the turn dodgeable.
func _assert_turn_is_rate_limited() -> void:
	if turn_bot == null or not is_instance_valid(turn_bot):
		report("turn test bot survived", false)
		return
	report("a chassis cannot swivel in one frame", _turned_so_far() < 0.9,
		"%.2f rad in 0.15 s" % _turned_so_far())

func _assert_turn_completes() -> void:
	if turn_bot == null or not is_instance_valid(turn_bot):
		report("turn test bot survived", false)
		return
	var f: Vector2 = turn_bot.get("facing")
	var short_by := absf(wrapf(f.angle() - PI, -PI, PI))
	report("the limited turn still gets there", short_by < 0.4, "%.2f rad short" % short_by)

func _splitter_setup() -> void:
	var unit: float = Layout.unit
	split_at = drone.position + Vector2(240.0 * unit, 0.0)
	var s = main.get("spawner").call("spawn", "splitter", split_at)
	s.set("speed", 0.0)
	s.call("hit_from", drone.position, 99)

## A wreck does not vanish and leave two identical bots standing in its footprint:
## the halves come out of it carrying the momentum of the round that opened it.
func _assert_splitter_halves_scatter() -> void:
	var unit: float = Layout.unit
	var shoved := 0
	for node in get_tree().get_nodes_in_group("droids"):
		if String(node.get("id")) != "walker":
			continue
		if node.position.distance_to(split_at) > 220.0 * unit:
			continue
		if (node.get("knock") as Vector2).length() > 40.0 * unit:
			shoved += 1
	report("a splitter's halves leave the wreck at speed", shoved >= 2,
		"%d shoved walkers" % shoved)

func _assert_death_leaves_marks() -> void:
	var decals: Node = main.get("decals")
	report("a kill scorches the ground and throws debris",
		decals.get_child_count() >= 5, "%d nodes on the decal layer" % decals.get_child_count())
	# Same-frame check: sparks live 0.18 s, so this has to be measured the instant
	# the hit lands rather than by a step that runs later.
	var unit: float = Layout.unit
	var b = main.get("spawner").call("spawn", "walker",
		drone.position + Vector2(120.0 * unit, 0.0))
	b.set("hp", 9)
	b.call("hit_from", drone.position, 1)
	var streaks := 0
	for child in main.get("world").get_children():
		if child.get("streaks") != null:
			streaks += 1
	report("a hit throws sparks along the round's own line", streaks > 0,
		"%d spark nodes" % streaks)
	b.queue_free()

func _assert_grade_sits_behind_hud() -> void:
	var g = main.get("grade")
	report("screen grade exists", g is Control)
	if g is Control:
		report("grade is layered under the HUD", (g as Node).get_index() == 0,
			"index=%d" % (g as Node).get_index())

func _cleanup_bots() -> void:
	for b in [inertia_bot, turn_bot]:
		if b != null and is_instance_valid(b):
			b.queue_free()
	flight_watch = false

# --------------------------------------------------------------------- end ----
func _kill_player() -> void:
	var guard := 0
	while Game.state == Game.State.PLAYING and guard < 12:
		drone.set("i_frames", 0.0)
		drone.call("hit_by_fire")
		guard += 1

func _assert_dead() -> void:
	report("shield exhaustion ends the run", Game.state == Game.State.DEAD,
		"state=%d" % Game.state)
	report("death releases the lock", drone.get("locked") == null
		and drone.get("acquiring") == null)
	report("death updates the personal best", Game.best >= Game.score and Game.score > 0,
		"best=%d score=%d" % [Game.best, Game.score])
	var cfg := ConfigFile.new()
	var err := cfg.load(Game.SAVE_PATH)
	report("personal best persisted", err == OK and int(cfg.get_value("run", "best", 0)) > 0,
		str(cfg.get_value("run", "best", 0)))

func _assert_restarted() -> void:
	report("retry returns to play with a clean slate",
		Game.state == Game.State.PLAYING and Game.score == 0
		and Game.hp == Game.START_HP and Game.elapsed < 1.0,
		"score=%d hp=%d t=%.1f" % [Game.score, Game.hp, Game.elapsed])

func _finish() -> void:
	_assert_camera_frames_plane("desktop")
	report("the drone held a lock during the run", locked_seen)
	if Game.view_3d:
		report("a death animation retired a rig", death_seen)
	print("SELFTEST %s  (%d checks, %d failures)" % [
		"OK" if failures == 0 else "FAILED", checks, failures])
	get_tree().quit(1 if failures > 0 else 0)
