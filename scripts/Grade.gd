class_name Grade
extends Control
## Screen-space colour grade: a vignette that pulls the eye toward the drone, and
## a warm-over-cool wash that gives the flat ground one sky to be lit by.
##
## Built from vertex-coloured triangles on purpose. A .gdshader would be a second
## language nobody edits on this project, and Compatibility mode plus a single
## threaded web export is exactly where shader failures hide until release day.
## Everything here is tunable in the constants below and nothing can fail to
## compile in a browser.

## Alpha at the very corner of the frame.
const VIGNETTE := 0.30
## Fraction of the half-diagonal left completely untouched, so the wash never
## darkens the middle of the screen where the drone sits.
const INNER := 0.46
const RINGS := 3
const SEGMENTS := 24
## Sky light comes from the sun side of the map, shade carries the cool of it.
const WARM := Color(1.0, 0.85, 0.63)
const COOL := Color(0.29, 0.43, 0.70)
const WASH := 0.05


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	Layout.resized.connect(_relaid_out)
	queue_redraw()

func _relaid_out(_size: Vector2) -> void:
	queue_redraw()

func _draw() -> void:
	if Game.view_3d:
		return
	var span := Layout.size
	var centre := span * 0.5
	var half_diag := span.length() * 0.5
	if half_diag <= 1.0:
		return
	_wash(span)
	_vignette(centre, half_diag)

## The four screen corners, each tinted by how far it sits along the sun line:
## warm where the light comes from, cool at the antipode. Five percent alpha is
## enough to make the two green tones of the ground read as one weather without
## washing the HUD text out with it.
func _wash(span: Vector2) -> void:
	# Corners listed in order round the frame: Vector2.UP is (0, -1), so multiplying
	# it by the span would lift the last corner off the screen and fold the quad
	# into a bowtie, which the triangulator refuses with an engine error.
	var pts := PackedVector2Array([Vector2.ZERO, Vector2(span.x, 0.0), span,
		Vector2(0.0, span.y)])
	var cols := PackedColorArray()
	var reach := maxf(1.0, span.length() * 0.5)
	for corner in pts:
		var k := clampf(0.5 + 0.5 * Art.SUN.dot((corner - span * 0.5) / reach), 0.0, 1.0)
		var c := COOL.lerp(WARM, k)
		c.a = WASH
		cols.append(c)
	draw_polygon(pts, cols)

## Concentric rings of quads, each filled with per-vertex alpha. The list is
## cached by the engine and only rebuilt on a resize, so the call count costs
## nothing per frame -- and a soft ring beats a shader nobody can tune.
func _vignette(centre: Vector2, half_diag: float) -> void:
	var tint := Color(0.015, 0.02, 0.035, 1.0)
	for k in RINGS:
		var f0 := float(k) / float(RINGS)
		var f1 := float(k + 1) / float(RINGS)
		var r0 := lerpf(half_diag * INNER, half_diag * 1.06, f0)
		var r1 := lerpf(half_diag * INNER, half_diag * 1.06, f1)
		var a0 := VIGNETTE * f0 * f0
		var a1 := VIGNETTE * f1 * f1
		for i in SEGMENTS:
			var t0 := TAU * float(i) / float(SEGMENTS)
			var t1 := TAU * float(i + 1) / float(SEGMENTS)
			draw_polygon(PackedVector2Array([
				centre + Vector2.RIGHT.rotated(t0) * r0,
				centre + Vector2.RIGHT.rotated(t1) * r0,
				centre + Vector2.RIGHT.rotated(t1) * r1,
				centre + Vector2.RIGHT.rotated(t0) * r1]),
				PackedColorArray([
					Color(tint.r, tint.g, tint.b, a0), Color(tint.r, tint.g, tint.b, a0),
					Color(tint.r, tint.g, tint.b, a1), Color(tint.r, tint.g, tint.b, a1)]))
