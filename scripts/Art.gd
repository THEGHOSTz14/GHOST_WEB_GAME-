class_name Art
extends RefCounted
## One lighting and weather agreement shared by every drawn layer.
##
## Before this, each file picked its own shadow offset -- the drone's fell down
## right, a bot's down left, a car's nowhere -- and the eye reads that instantly
## as "fake" even when nothing looks wrong on its own. Everything now asks Art
## where the sun and wind are, so a single change here relights the whole map.

## Direction shadows fall, in screen space (y grows downward). Written already
## normalised because Vector2.normalized() is not a constant expression.
const SUN := Vector2(0.5822, 0.813)
## 0 = light on the horizon (long shadows), 1 = overhead (short, hard shadows).
const SUN_ELEV := 0.68
const SHADOW_ALPHA := 0.30
## Prevailing wind, used by grass, reeds and tree canopies. Pre-normalised.
const WIND := Vector2(0.9724, 0.2334)

const GRASS := Color(0.443, 0.639, 0.325)
const GRASS_ALT := Color(0.408, 0.608, 0.302)
const GRASS_LIT := Color(0.510, 0.694, 0.376)
const GRASS_SHADE := Color(0.337, 0.529, 0.263)
const DIRT := Color(0.737, 0.639, 0.451)
const DIRT_DARK := Color(0.565, 0.478, 0.337)
const STONE := Color(0.620, 0.624, 0.635)
const WET_SAND := Color(0.475, 0.455, 0.357)


static func shadow_offset(height: float) -> Vector2:
	return SUN * height / maxf(0.2, SUN_ELEV)


## Three overlapping discs: a dark contact patch under the object and two softer
## outer rings. A single hard circle is what makes a 2D prop look pasted on.
static func soft_shadow(item: CanvasItem, at: Vector2, radius: float,
		height: float, strength := 1.0) -> void:
	var off := shadow_offset(height)
	var a := SHADOW_ALPHA * strength
	item.draw_circle(at + off * 1.20, radius * 1.22, Color(0.01, 0.015, 0.02, a * 0.30))
	item.draw_circle(at + off * 0.80, radius * 1.04, Color(0.01, 0.015, 0.02, a * 0.45))
	item.draw_circle(at + off * 0.34, radius * 0.80, Color(0.01, 0.015, 0.02, a * 0.70))


## Ambient occlusion: the crevice where an object meets the ground.
static func contact(item: CanvasItem, at: Vector2, radius: float,
		strength := 1.0) -> void:
	item.draw_circle(at, radius, Color(0.03, 0.05, 0.03, 0.20 * strength))


## Two summed sines so nothing oscillates like a metronome. `phase` should be a
## stable per-object value, otherwise the whole forest sways in lockstep.
static func sway(t: float, phase: float, amount: float) -> float:
	return (sin(t * 1.7 + phase) * 0.62 + sin(t * 0.83 + phase * 1.9) * 0.38) * amount


static func sunlit(color: Color, amount := 1.0) -> Color:
	return color.lightened(0.11 * amount).lerp(Color(1.0, 0.96, 0.86), 0.07 * amount)


static func shaded(color: Color, amount := 1.0) -> Color:
	return color.darkened(0.24 * amount).lerp(Color(0.28, 0.34, 0.46), 0.10 * amount)


## Which side of a round object catches the light.
static func lit_offset(radius: float) -> Vector2:
	return -SUN * radius * 0.34
