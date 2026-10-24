class_name View3D
extends Node3D
## 3D animated presentation over the 2D simulation (GAME.md §12).
##
## The simulation stays the single source of truth: positions live in logical
## plane units and Area2D collision keeps working, which means every rule and
## every assertion in tests/SelfTest.gd still applies. This node mirrors those
## units into metres, renders them with a perspective camera, and adds the
## animation -- rotors, treads, hover bob, hit flash, death collapse.
##
## Doing it this way rather than porting the physics to Area3D keeps the web
## build cheap and the collision behaviour identical to the verified 2D game.

const M := 0.018                    # logical units -> metres
const CAM_FOV := 42.0
const CAM_PITCH := deg_to_rad(58.0) ## view direction below horizontal
const FRAME_ITERS := 5
const FRAME_MARGIN := 1.06          # keep a little empty space around the plane
const TRACER_CAP := 48
const SHADOW_Y := 0.015

var sim: Node2D
var drone: Node
var camera: Camera3D
var floor_plane: MeshInstance3D
var reticle: MeshInstance3D
var reticle_src: Node = null
var acquire_ring: MeshInstance3D

var drone_rig: DroneRig
var _entries: Array = []            # [{"src": Node, "rig": Node3D}]
var _dying: Array = []              # rigs playing a death animation
var _tracer_pool: Array = []
var _last_vp := Vector2.ZERO
var deaths_animated := 0   # rig retirements that played a death animation

func setup(source_sim: Node2D, source_drone: Node) -> void:
	sim = source_sim
	drone = source_drone

func _ready() -> void:
	_build_world()
	_build_reticle()
	drone_rig = DroneRig.new()
	add_child(drone_rig)
	_refit()
	Layout.resized.connect(_refit)

# ------------------------------------------------------------------ world --
func _build_world() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.03, 0.05)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.42, 0.52, 0.68)
	env.ambient_light_energy = 0.85
	env.fog_enabled = true
	env.fog_light_color = Color(0.03, 0.05, 0.08)
	env.fog_density = 0.012
	var settings := WorldEnvironment.new()
	settings.environment = env
	add_child(settings)

	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.15
	sun.light_color = Color(1.0, 0.96, 0.88)
	sun.shadow_enabled = false        # blob shadows are cheaper and read better here
	sun.rotation_degrees = Vector3(-54.0, 28.0, 0.0)
	add_child(sun)

	camera = Camera3D.new()
	camera.fov = CAM_FOV
	camera.near = 0.1
	camera.far = 300.0
	add_child(camera)
	camera.make_current()

	floor_plane = MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(400.0, 400.0)
	floor_plane.mesh = plane
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_texture = _grid_texture()
	floor_mat.uv1_scale = Vector3(60.0, 1.0, 60.0)
	floor_mat.roughness = 0.92
	floor_mat.metallic = 0.05
	floor_plane.material_override = floor_mat
	add_child(floor_plane)

func _grid_texture() -> ImageTexture:
	## Procedural floor plates: no image assets to download or license.
	var size := 256
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.075, 0.095, 0.125))
	for i in size:
		if i % 64 < 2:
			for j in size:
				img.set_pixel(j, i, Color(0.13, 0.17, 0.21))
		if i % 64 == 30:
			for j in size:
				if j % 128 < 64:
					img.set_pixel(j, i, Color(0.09, 0.115, 0.15))
	for i in 4:
		for j in 4:
			var c := Color(0.10, 0.13, 0.17)
			for x in range(j * 64 + 8, j * 64 + 56):
				for y in range(i * 64 + 8, i * 64 + 20):
					if (x + y) % 2 == 0:
						img.set_pixel(x, y, c)
	var tex := ImageTexture.create_from_image(img)
	tex.resource_name = "FloorPlates"
	return tex

func _shadow_texture() -> ImageTexture:
	var size := 64
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var half := size * 0.5
	for x in size:
		for y in size:
			var d := Vector2(x - half, y - half).length() / half
			var a := clampf(1.0 - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(0, 0, 0, a * a * 0.55))
	return ImageTexture.create_from_image(img)

func _build_reticle() -> void:
	reticle = MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.62
	torus.outer_radius = 0.72
	torus.rings = 24
	torus.ring_segments = 8
	reticle.mesh = torus
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.32, 0.32)
	reticle.material_override = mat
	reticle.visible = false
	add_child(reticle)

	acquire_ring = MeshInstance3D.new()
	var arc := TorusMesh.new()
	arc.inner_radius = 0.7
	arc.outer_radius = 0.78
	arc.rings = 24
	arc.ring_segments = 6
	acquire_ring.mesh = arc
	var amat := StandardMaterial3D.new()
	amat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	amat.albedo_color = Color(1.0, 0.85, 0.35)
	acquire_ring.material_override = amat
	acquire_ring.visible = false
	add_child(acquire_ring)

# ------------------------------------------------------------- camera frame --
func _plane_corners() -> Array:
	var hw := Layout.width() * 0.5 * M
	var hd := Layout.height() * 0.5 * M
	return [Vector3(-hw, 0, -hd), Vector3(hw, 0, -hd), Vector3(-hw, 0, hd), Vector3(hw, 0, hd)]

func _project(point: Vector3) -> Dictionary:
	## Screen position of a world point, computed by the engine so the headless
	## framing assertions test exactly what a frame would show. Points behind the
	## near plane are rejected rather than projected to nonsense.
	var local: Vector3 = camera.global_transform.affine_inverse() * point
	if local.z > -camera.near:
		return {}
	var vp := get_viewport().get_visible_rect().size
	return {"pos": camera.unproject_position(point), "vp": vp}

func _refit(_new_size: Vector2 = Vector2.INF) -> void:
	if camera == null:
		return
	var vp := get_viewport().get_visible_rect().size
	if vp.x < 2.0 or vp.y < 2.0:
		return
	var dist := 22.0
	var pan := 0.0
	for i in FRAME_ITERS:
		_place_camera(dist, pan)
		var box := _plane_bbox(vp)
		if box.size.x <= 0.0:
			dist *= 1.3
			continue
		# metres per screen pixel at the current distance, for the vertical pan
		var world_per_px := 2.0 * dist * tan(deg_to_rad(camera.fov * 0.5)) / vp.y
		pan -= (box.get_center().y - vp.y * 0.5) * world_per_px
		var need := maxf(box.size.x / vp.x, box.size.y / vp.y) * FRAME_MARGIN
		if absf(need - 1.0) < 0.02:
			break
		dist *= clampf(need, 0.55, 2.0)
	_place_camera(dist, pan)

## Bounding box of the plane's four corners in screen pixels, or a negative-size
## Rect2 when any corner is outside the frustum (the fit loop then backs off).
func _plane_bbox(vp: Vector2) -> Rect2:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for c in _plane_corners():
		var pr := _project(c)
		if pr.is_empty():
			return Rect2(0, 0, -1, -1)
		lo = lo.min(pr.pos)
		hi = hi.max(pr.pos)
	return Rect2(lo, hi - lo)

func _place_camera(dist: float, lift: float) -> void:
	var y := dist * sin(CAM_PITCH)
	var z := dist * cos(CAM_PITCH)
	camera.position = Vector3(0.0, y + lift, z)
	camera.look_at(Vector3(0.0, lift, 0.0), Vector3.UP)

# ------------------------------------------------------------------- sync ---
func _process(delta: float) -> void:
	var vp := get_viewport().get_visible_rect().size
	if vp != _last_vp and vp.x > 2.0:
		_last_vp = vp
		_refit()
	if drone == null or not is_instance_valid(drone):
		return
	drone_rig.sync(drone, delta)
	_sync_list("droids", true)
	_sync_list("drone_shots", false)
	_sync_list("droid_fire", false)
	_sync_list("pickups", false)
	_sync_reticle()
	_tick_dying(delta)

func _is_live(src) -> bool:
	## Droids have no `active` flag (they are freed on death); pooled shots, mines
	## and pickups do. Object.get() returns null for an absent property, which is
	## the only portable way to ask "does this node have one?" here -- the `in`
	## operator silently misjudges scripted properties.
	if not is_instance_valid(src):
		return false
	var flag = src.get("active")
	return flag == null or bool(flag)

## Rigs are created for live simulation nodes and released the frame they stop
## being live, so the 3D layer cannot drift out of step with the sim.
func _sync_list(group: String, animate_death: bool) -> void:
	var delta := get_process_delta_time()
	var current := {}
	for src in get_tree().get_nodes_in_group(group):
		if _is_live(src):
			current[src] = true
	var keep: Array = []
	for entry in _entries:
		if entry.group != group:
			# Owned by another group's pass; leaving it alone is the whole point
			# of keying entries by group -- otherwise each pass would retire the
			# others' rigs the same frame they were created.
			keep.append(entry)
			continue
		if current.has(entry.src):
			entry.rig.sync(entry.src, delta)
			keep.append(entry)
			current.erase(entry.src)
		else:
			_retire(entry, animate_death)
	_entries = keep
	for src in current:
		var rig := _make_rig(group, src)
		if rig == null:
			continue
		rig.sync(src, delta)
		_entries.append({"src": src, "rig": rig, "group": group})

func _entry_for(src) -> Dictionary:
	for entry in _entries:
		if entry.src == src:
			return entry
	return {}

func _make_rig(group: String, src) -> Node3D:
	match group:
		"droids":
			var d := DroidRig.new()
			d.shadow_map = _shadow_texture()
			add_child(d)
			return d
		"drone_shots":
			if not _tracer_pool.is_empty():
				var reused: Node3D = _tracer_pool.pop_back()
				reused.visible = true
				return reused
			if get_child_count() > 400:
				return null
			var t := TracerRig.new()
			add_child(t)
			return t
		"droid_fire":
			var f := FireRig.new()
			f.shadow_map = _shadow_texture()
			add_child(f)
			return f
		_:
			var p := PickupRig.new()
			add_child(p)
			return p

func _retire(entry: Dictionary, animate_death: bool) -> void:
	var rig: Node3D = entry.rig
	if animate_death and rig.has_method("play_death"):
		rig.play_death()
		deaths_animated += 1
		_dying.append({"rig": rig, "left": 0.75})
	elif rig.is_in_group("tracers"):
		rig.visible = false
		_tracer_pool.append(rig)
	else:
		rig.queue_free()

func _tick_dying(delta: float) -> void:
	var keep: Array = []
	for item in _dying:
		item.left -= delta
		if item.rig.has_method("tick_death"):
			item.rig.tick_death(delta)
		if item.left <= 0.0:
			item.rig.queue_free()
		else:
			keep.append(item)
	_dying = keep

func _sync_reticle() -> void:
	var locked = drone.locked
	var acquiring = drone.acquiring
	if locked != null and is_instance_valid(locked):
		reticle.visible = true
		reticle.position = _world(locked.position) + Vector3(0, 0.25, 0)
		var s := maxf(0.3, locked.size.x * M * 0.9)
		reticle.scale = Vector3(s, s, s)
		reticle.rotation.y += get_process_delta_time() * 1.6
		acquire_ring.visible = false
		reticle_src = locked
	else:
		reticle.visible = false
		reticle_src = null
		if acquiring != null and is_instance_valid(acquiring):
			acquire_ring.visible = true
			acquire_ring.position = _world(acquiring.position) + Vector3(0, 0.25, 0)
			var prog: float = drone.lock_progress()
			var s2 := maxf(0.3, acquiring.size.x * M * 0.9) * (1.6 - 0.6 * prog)
			acquire_ring.scale = Vector3(s2, s2, s2)
		else:
			acquire_ring.visible = false

func _world(p: Vector2) -> Vector3:
	var c := Layout.center()
	return Vector3((p.x - c.x) * M, 0.0, (p.y - c.y) * M)

func burst(at: Vector2, color: Color, amount: int, speed: float) -> void:
	var p := CPUParticles3D.new()
	p.position = _world(at) + Vector3(0, 0.3, 0)
	p.amount = amount
	p.lifetime = 0.6
	p.one_shot = true
	p.emitting = true
	p.direction = Vector3(0, 1, 0)
	p.spread = 74.0
	p.gravity = Vector3(0, -18.0, 0)
	p.initial_velocity_min = speed * M * 12.0
	p.initial_velocity_max = speed * M * 22.0
	p.scale_amount_min = 0.05
	p.scale_amount_max = 0.12
	p.color = color
	add_child(p)
	get_tree().create_timer(1.2).timeout.connect(p.queue_free)

## Screen-space text placed by projecting the world point, so floating numbers
## line up with the 3D action instead of the 2D grid.
func project_to_screen(at: Vector2) -> Vector2:
	var p := _project(_world(at) + Vector3(0, 0.4, 0))
	if p.is_empty():
		return Vector2(-9999, -9999)
	return p.pos

# -------------------------------------------------------------------- rigs --
class RigBase extends Node3D:
	var elapsed := 0.0
	var shadow_map: ImageTexture

	func mat(color: Color, emis: float = 0.0) -> StandardMaterial3D:
		var m := StandardMaterial3D.new()
		m.albedo_color = color
		m.roughness = 0.62
		m.metallic = 0.25
		if emis > 0.0:
			m.emission_enabled = true
			m.emission = color
			m.emission_energy_multiplier = emis
		return m

	func add_shadow(width: float) -> void:
		if shadow_map == null:
			return
		var mi := MeshInstance3D.new()
		var pl := PlaneMesh.new()
		pl.size = Vector2(width, width)
		mi.mesh = pl
		mi.position = Vector3(0.05, View3D.SHADOW_Y, 0.05)
		var sm := StandardMaterial3D.new()
		sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		sm.albedo_texture = shadow_map
		sm.vertex_color_use_as_albedo = true
		mi.material_override = sm
		add_child(mi)

class DroneRig extends RigBase:
	var rotors: Array = []
	var hull: MeshInstance3D
	var boom: MeshInstance3D
	var tilt := Node3D.new()

	func _init() -> void:
		add_child(tilt)
		var tint := Color(0.34, 0.82, 0.95)
		hull = MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.55, 0.16, 0.62)
		hull.mesh = box
		hull.material_override = mat(tint.darkened(0.55))
		tilt.add_child(hull)
		boom = MeshInstance3D.new()
		var nose := BoxMesh.new()
		nose.size = Vector3(0.14, 0.1, 0.3)
		boom.mesh = nose
		boom.position = Vector3(0, 0, 0.34)
		boom.material_override = mat(tint, 0.9)
		tilt.add_child(boom)
		var sensor := MeshInstance3D.new()
		var ball := SphereMesh.new()
		ball.radius = 0.09
		ball.height = 0.18
		sensor.mesh = ball
		sensor.position = Vector3(0, -0.12, 0)
		sensor.material_override = mat(Color(0.98, 0.95, 0.7), 2.2)
		tilt.add_child(sensor)
		for arm in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
			var node := Node3D.new()
			node.position = Vector3(arm.x * 0.5, 0.02, arm.y * 0.5)
			tilt.add_child(node)
			var disc := MeshInstance3D.new()
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.26
			cyl.bottom_radius = 0.26
			cyl.height = 0.02
			disc.mesh = cyl
			var dm := StandardMaterial3D.new()
			dm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			dm.albedo_color = Color(0.6, 0.9, 1.0, 0.3)
			disc.material_override = dm
			node.add_child(disc)
			var spoke := MeshInstance3D.new()
			var arm_box := BoxMesh.new()
			arm_box.size = Vector3(1.0, 0.05, 0.09)
			spoke.mesh = arm_box
			spoke.position = Vector3(arm.x * -0.25, 0, arm.y * -0.25)
			spoke.rotation.y = atan2(arm.y, arm.x)
			spoke.material_override = mat(tint.darkened(0.3))
			tilt.add_child(spoke)
			rotors.append(node)
		add_shadow(1.1)

	func sync(src: Node, delta: float) -> void:
		elapsed += delta
		var unit: float = src.scale.x
		position = _w(src.position)
		rotation.y = atan2(-src.velocity.x, -src.velocity.y) if src.velocity.length_squared() > 4.0 else rotation.y
		var speed_norm: float = clampf(src.velocity.length() / (700.0 * unit), 0.0, 1.0)
		tilt.position.y = 0.62 + sin(elapsed * 5.2) * 0.045 + speed_norm * 0.1
		tilt.rotation.x = lerpf(tilt.rotation.x, speed_norm * 0.34, clampf(9.0 * delta, 0.0, 1.0))
		var spin_rate := 26.0 + speed_norm * 20.0
		for i in rotors.size():
			rotors[i].rotation.y += delta * spin_rate * (1.0 if i % 2 == 0 else -1.0)
		var flash: float = clampf(src.i_frames * 6.0, 0.0, 1.0)
		hull.material_override.albedo_color = Color(0.34, 0.82, 0.95).darkened(0.55).lerp(Color(1, 0.4, 0.45), flash)
		scale = Vector3.ONE * maxf(0.4, unit)

	func _w(p: Vector2) -> Vector3:
		var c := Layout.center()
		return Vector3((p.x - c.x) * View3D.M, 0.0, (p.y - c.y) * View3D.M)

class DroidRig extends RigBase:
	var body: MeshInstance3D
	var treads: Array = []
	var eye: MeshInstance3D
	var arc_parts: Array = []
	var barrel: MeshInstance3D
	var dying := false
	var death_t := 0.0
	var kind := ""

	func build(src: Node) -> void:
		kind = src.id
		var s: float = src.size.x * View3D.M
		var color: Color = src.color
		body = MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(s, s * 0.6, s * 0.85)
		body.mesh = box
		body.position = Vector3(0, s * 0.42, 0)
		body.material_override = mat(color.darkened(0.45))
		add_child(body)
		for side in [-1.0, 1.0]:
			var tr := MeshInstance3D.new()
			var tb := BoxMesh.new()
			tb.size = Vector3(s * 0.22, s * 0.34, s * 0.95)
			tr.mesh = tb
			tr.position = Vector3(side * s * 0.52, s * 0.2, 0)
			tr.material_override = mat(color.darkened(0.7))
			add_child(tr)
			treads.append(tr)
		eye = MeshInstance3D.new()
		var ball := SphereMesh.new()
		ball.radius = s * 0.13
		ball.height = s * 0.26
		eye.mesh = ball
		eye.position = Vector3(0, s * 0.75, s * 0.3)
		eye.material_override = mat(Color(1.0, 0.3, 0.3) if src.fire_interval > 0.0 else Color(0.95, 0.9, 0.6), 1.6)
		add_child(eye)
		if src.fire_interval > 0.0:
			barrel = MeshInstance3D.new()
			var cyl := CylinderMesh.new()
			cyl.top_radius = s * 0.09
			cyl.bottom_radius = s * 0.11
			cyl.height = s * 0.8
			barrel.mesh = cyl
			barrel.material_override = mat(color.darkened(0.2))
			add_child(barrel)
		if kind == "shielder":
			for i in 3:
				var seg := MeshInstance3D.new()
				var sb := BoxMesh.new()
				sb.size = Vector3(s * 0.5, s * 0.16, s * 0.14)
				seg.mesh = sb
				seg.material_override = mat(Color(0.55, 1.0, 0.8), 1.8)
				add_child(seg)
				arc_parts.append(seg)
		if kind == "splitter":
			var seam := MeshInstance3D.new()
			var sq := BoxMesh.new()
			sq.size = Vector3(s * 1.02, s * 0.1, s * 0.1)
			seam.mesh = sq
			seam.position = Vector3(0, s * 0.42, 0)
			seam.material_override = mat(Color(0.9, 0.7, 1.0), 1.2)
			add_child(seam)
		add_shadow(s * 1.3)

	func sync(src: Node, delta: float) -> void:
		if body == null:
			build(src)
		elapsed += delta
		position = _w(src.position)
		rotation.y = atan2(-src.facing.x, -src.facing.y)
		var stride := sin(elapsed * 9.0 + src.phase)
		for i in treads.size():
			treads[i].position.z = cos(elapsed * 9.0 + float(i) * PI) * src.size.x * View3D.M * 0.08
		body.position.y = src.size.x * View3D.M * 0.42 + absf(stride) * 0.03
		var flash: float = clampf(src.hit_flash * 12.0, 0.0, 1.0)
		body.material_override.albedo_color = src.color.darkened(0.45).lerp(Color(1, 1, 1), flash)
		if src.fire_interval > 0.0 and src.is_charging():
			eye.material_override.emission_energy_multiplier = 3.5
		else:
			eye.material_override.emission_energy_multiplier = 1.4
		if barrel != null:
			barrel.position = Vector3(0, src.size.x * View3D.M * 0.6, 0)
			barrel.rotation.x = PI * 0.5
			barrel.rotation.y = 0.0
		for i in arc_parts.size():
			var a: float = src.shield_angle + (float(i) - 1.0) * 0.5
			var r: float = src.size.x * View3D.M * 0.85
			arc_parts[i].position = Vector3(cos(a) * r, src.size.x * View3D.M * 0.45, sin(a) * r)
			arc_parts[i].rotation.y = -a

	func play_death() -> void:
		dying = true
		death_t = 0.0
		if body != null:
			body.material_override.albedo_color = Color(1.0, 0.75, 0.35)

	func tick_death(delta: float) -> void:
		death_t += delta
		var t: float = clampf(death_t / 0.7, 0.0, 1.0)
		rotation.z = t * 1.4
		position.y -= t * 0.12
		scale = Vector3.ONE * (1.0 - t * 0.35)

	func _w(p: Vector2) -> Vector3:
		var c := Layout.center()
		return Vector3((p.x - c.x) * View3D.M, 0.0, (p.y - c.y) * View3D.M)

class TracerRig extends Node3D:
	var mesh_node: MeshInstance3D

	func _init() -> void:
		add_to_group("tracers")
		mesh_node = MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.09, 0.09, 0.7)
		mesh_node.mesh = box
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = Color(1.0, 0.98, 0.7)
		m.emission_enabled = true
		m.emission = Color(1.0, 0.95, 0.6)
		m.emission_energy_multiplier = 2.6
		mesh_node.material_override = m
		add_child(mesh_node)
		visible = false

	func sync(src: Node, _delta: float) -> void:
		visible = true
		var c := Layout.center()
		position = Vector3((src.position.x - c.x) * View3D.M, 0.55,
			(src.position.y - c.y) * View3D.M)
		rotation.y = atan2(-src.velocity.x, -src.velocity.y)

class FireRig extends RigBase:
	var core: MeshInstance3D
	var fins: Array = []

	func _init() -> void:
		core = MeshInstance3D.new()
		var ball := SphereMesh.new()
		ball.radius = 0.16
		ball.height = 0.32
		core.mesh = ball
		core.material_override = mat(Color(1.0, 0.42, 0.25), 2.4)
		add_child(core)
		add_shadow(0.5)

	func sync(src: Node, delta: float) -> void:
		elapsed += delta
		var c := Layout.center()
		position = Vector3((src.position.x - c.x) * View3D.M, 0.5,
			(src.position.y - c.y) * View3D.M)
		rotation.y = atan2(-src.velocity.x, -src.velocity.y)
		var mine: bool = src.mode == "mine"
		var col := Color(1.0, 0.72, 0.2) if mine else Color(1.0, 0.42, 0.25)
		core.material_override.albedo_color = col
		core.material_override.emission = col
		core.material_override.emission_energy_multiplier = 2.4 + sin(elapsed * 14.0) * 0.6
		scale = Vector3.ONE * (1.0 + (0.18 if mine else 0.0) * sin(elapsed * 10.0))

class PickupRig extends RigBase:
	var cube: MeshInstance3D

	func _init() -> void:
		cube = MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.4, 0.4, 0.4)
		cube.mesh = box
		cube.material_override = mat(Color(0.98, 0.86, 0.35), 1.8)
		add_child(cube)
		add_shadow(0.55)

	func sync(src: Node, delta: float) -> void:
		elapsed += delta
		var c := Layout.center()
		position = Vector3((src.position.x - c.x) * View3D.M,
			0.35 + sin(elapsed * 3.4) * 0.1, (src.position.y - c.y) * View3D.M)
		cube.rotation.y = elapsed * 2.2
		cube.rotation.x = elapsed * 1.1
		var fade: float = 1.0 if src.life > 2.0 else 0.4 + 0.6 * absf(sin(src.life * 8.0))
		cube.material_override.albedo_color = src.color
		cube.material_override.emission_energy_multiplier = 1.8 * fade
		cube.visible = fade > 0.5 or fmod(elapsed * 8.0, 1.0) < 0.6
