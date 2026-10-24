extends Node
## World-space view math for the endless bird's-eye plane (GAME.md §2).
##
## The simulation lives in unbounded world coordinates. The camera follows the
## drone, so the drone reads as centred and the ground scrolls under it forever.
## Screen and world are related by one offset, which is all a CanvasItem needs:
## Main shifts the `world` node by `center - camera` and every entity keeps
## working in world units untouched.
##
## Godot's canvas_items+expand stretch grows the logical viewport on the
## unconstrained axis (a 9:16 phone reports roughly 1280 x 2560), so speeds and
## sizes are multiplied by `unit` -- without it the same drag would feel three
## times slower in portrait than on a desktop.

signal resized(size: Vector2)
signal camera_moved(camera: Vector2)

const MIN_VIEW_HEIGHT := 720.0
const MAX_VIEW_HEIGHT := 1250.0
const BASE_VIEW_HEIGHT := 720.0
## Keep spawned things this far inside the visible rect so they do not appear or
## vanish right at the screen edge.
const EDGE_INSET := 110.0

## Logical viewport size in Godot units, after stretch.
var size := Vector2(1280.0, BASE_VIEW_HEIGHT)
## Speed/size multiplier, identical gameplay feel at every aspect ratio.
var unit := 1.0
## World point that sits at the centre of the screen.
var camera := Vector2.ZERO
## The visible world rect, derived from camera + size.
var view := Rect2(Vector2(-640, -360), Vector2(1280, 720))

func _ready() -> void:
	# The root viewport can still report 0 during autoload boot; _process picks
	# the real size up on the first frame.
	_update_size(_logical_size())

func _process(_delta: float) -> void:
	var s := _logical_size()
	if s != size and s.x > 1.0:
		_update_size(s)
		resized.emit(size)

## Node has no get_viewport_rect(); the stretched logical size lives on the root
## viewport's visible rect.
func _logical_size() -> Vector2:
	var vp := get_viewport()
	return vp.get_visible_rect().size if vp != null else Vector2.ZERO

func _update_size(s: Vector2) -> void:
	size = s
	unit = clampf(s.y, MIN_VIEW_HEIGHT, MAX_VIEW_HEIGHT) / BASE_VIEW_HEIGHT
	_refresh_view()

func set_camera(p: Vector2) -> void:
	if p == camera:
		return
	camera = p
	_refresh_view()
	camera_moved.emit(p)

func _refresh_view() -> void:
	view = Rect2(camera - size * 0.5, size)

# ------------------------------------------------------------- conversions --
## Screen (logical viewport) point -> world point. Input events arrive in screen
## units, so every tap has to pass through here before it means anything.
func screen_to_world(p: Vector2) -> Vector2:
	return p + camera - size * 0.5

func world_to_screen(p: Vector2) -> Vector2:
	return p - camera + size * 0.5

func width() -> float:
	return size.x

func height() -> float:
	return size.y

func center() -> Vector2:
	return size * 0.5

## Offset Main applies to the world container; equals the camera sitting at the
## screen centre.
func world_offset() -> Vector2:
	return center() - camera

# ------------------------------------------------------------------- checks --
func in_view(p: Vector2, pad := 0.0) -> bool:
	return Rect2(view.position - Vector2.ONE * pad,
		view.size + Vector2.ONE * 2 * pad).has_point(p)

## Half the view diagonal: how far nothing on screen can be from the camera.
func view_radius() -> float:
	return view.size.length() * 0.5

# ------------------------------------------------------------------- places --
## Anywhere in the world, comfortably inside the visible rect.
func rand_interior(margin := EDGE_INSET) -> Vector2:
	var m := margin * unit
	return Vector2(randf_range(view.position.x + m, view.end.x - m),
		randf_range(view.position.y + m, view.end.y - m))

## Just outside a random edge of the visible rect, so bots walk into view rather
## than popping into existence in front of the player.
func rand_edge_entry() -> Vector2:
	var m := EDGE_INSET * unit
	match randi() % 4:
		0:
			return Vector2(randf_range(view.position.x, view.end.x), view.position.y - m)
		1:
			return Vector2(randf_range(view.position.x, view.end.x), view.end.y + m)
		2:
			return Vector2(view.position.x - m, randf_range(view.position.y, view.end.y))
		_:
			return Vector2(view.end.x + m, randf_range(view.position.y, view.end.y))

## Nearest world point that is on screen -- used to pull stray bots back.
func recall(p: Vector2) -> Vector2:
	if in_view(p, -40.0):
		return p
	return rand_edge_entry()
