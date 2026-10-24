class_name Hud
extends CanvasLayer
## Anchored overlay -- nothing here assumes an aspect ratio (GAME.md §2).
## Panels use mouse_filter IGNORE so a tap anywhere still reaches the game,
## while the buttons themselves consume input.

signal start_pressed
signal retry_pressed
signal resume_pressed
signal bomb_pressed
signal leaderboard_pressed
signal revive_pressed

const PAD := 20.0

var root: Control
var score_label: Label
var best_label: Label
var time_label: Label
var lock_label: Label
var name_label: Label
var mult_fill: ColorRect
var mult_label: Label
var cells: Array[ColorRect] = []
var bomb_label: Label
var bomb_button: Button
var pause_button: Button
var menu_panel: Control
var pause_panel: Control
var dead_panel: Control
var dead_title: Label
var dead_score: Label
var dead_best: Label
var revive_button: Button
var hint_label: Label

func _ready() -> void:
	layer = 5
	root = Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_build_hud()
	_build_panels()
	Game.score_changed.connect(_on_score)
	Game.hp_changed.connect(_on_hp)
	Game.time_changed.connect(_on_time)
	Game.combo_changed.connect(_on_combo)
	Game.bomb_changed.connect(_on_bombs)
	Game.state_changed.connect(_on_state)
	Y8Api.auth_changed.connect(_on_auth)
	_on_score(Game.score, Game.best)
	_on_hp(Game.hp)
	_on_time(Game.elapsed)
	_on_combo(0, 1.0)
	_on_bombs(Game.bombs)
	_on_state(Game.state)

const INK := Color(0.82, 0.94, 1.0)
const GOLD := Color(1.0, 0.86, 0.4)
const SHADOW := Color(0.02, 0.05, 0.09)

## `at` is always an inset from the anchored edge, so a control pinned
## BOTTOM_RIGHT sits the same distance from the corner on a phone and a monitor.
func _pin(n: Control, preset: int, at: Vector2, wide: float, tall: float) -> void:
	n.set_anchors_and_offsets_preset(preset)
	match preset:
		Control.PRESET_TOP_RIGHT:
			n.offset_left = -at.x - wide
			n.offset_right = -at.x
			n.offset_top = at.y
			n.offset_bottom = at.y + tall
		Control.PRESET_BOTTOM_RIGHT:
			n.offset_left = -at.x - wide
			n.offset_right = -at.x
			n.offset_top = -at.y - tall
			n.offset_bottom = -at.y
		Control.PRESET_BOTTOM_LEFT:
			n.offset_left = at.x
			n.offset_right = at.x + wide
			n.offset_top = -at.y - tall
			n.offset_bottom = -at.y
		Control.PRESET_TOP_WIDE:
			n.offset_left = at.x
			n.offset_right = -at.x
			n.offset_top = at.y
			n.offset_bottom = at.y + tall
		_:
			n.offset_left = at.x
			n.offset_right = at.x + wide
			n.offset_top = at.y
			n.offset_bottom = at.y + tall

func _mk_label(text: String, px: int, color: Color = INK,
		halign: int = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", px)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", SHADOW)
	l.add_theme_constant_override("outline_size", 6)
	l.horizontal_alignment = halign
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(l)
	return l

func _build_hud() -> void:
	score_label = _mk_label("0", 40)
	_pin(score_label, Control.PRESET_TOP_LEFT, Vector2(PAD, 10), 330, 54)
	best_label = _mk_label("BEST 0", 18)
	_pin(best_label, Control.PRESET_TOP_LEFT, Vector2(PAD + 2, 66), 330, 26)
	mult_label = _mk_label("x1.0", 20, GOLD)
	_pin(mult_label, Control.PRESET_TOP_LEFT, Vector2(PAD, 96), 200, 30)
	# Run timer, not a wave counter: difficulty is a curve now (GAME.md §7).
	time_label = _mk_label("0:00", 22, INK, HORIZONTAL_ALIGNMENT_CENTER)
	_pin(time_label, Control.PRESET_TOP_WIDE, Vector2(PAD, 14), 0, 34)
	# Plain text: the default font has no reticle glyph, and tofu reads as a bug.
	lock_label = _mk_label("LOCK", 18, Color(1.0, 0.45, 0.45),
		HORIZONTAL_ALIGNMENT_CENTER)
	_pin(lock_label, Control.PRESET_TOP_WIDE, Vector2(PAD, 52), 0, 26)
	lock_label.visible = false
	name_label = _mk_label("Guest", 16, Color(0.6, 0.72, 0.8))
	_pin(name_label, Control.PRESET_BOTTOM_LEFT, Vector2(PAD, 12), 300, 24)
	bomb_label = _mk_label("BOMB 1", 18)
	_pin(bomb_label, Control.PRESET_BOTTOM_LEFT, Vector2(PAD, 40), 300, 26)

	var bar_bg := ColorRect.new()
	bar_bg.color = Color(0.1, 0.16, 0.22, 0.85)
	bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bar_bg)
	_pin(bar_bg, Control.PRESET_TOP_LEFT, Vector2(PAD, 128), 190, 9)
	mult_fill = ColorRect.new()
	mult_fill.color = GOLD
	mult_fill.position = Vector2(1, 1)
	mult_fill.size = Vector2(0, 7)
	mult_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_bg.add_child(mult_fill)

	var cells_box := HBoxContainer.new()
	cells_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(cells_box)
	_pin(cells_box, Control.PRESET_TOP_RIGHT, Vector2(PAD, 14), 120, 14)
	for i in Game.START_HP:
		var cell := ColorRect.new()
		cell.custom_minimum_size = Vector2(34, 12)
		cell.color = Color(0.35, 0.95, 1.0)
		cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cells_box.add_child(cell)
		cells.append(cell)

	pause_button = _mk_button("II")
	_pin(pause_button, Control.PRESET_TOP_RIGHT, Vector2(PAD, 40), 56, 46)
	pause_button.pressed.connect(func() -> void: Game.toggle_pause())

	bomb_button = _mk_button("BOMB")
	_pin(bomb_button, Control.PRESET_BOTTOM_RIGHT, Vector2(PAD, 18), 130, 88)
	bomb_button.pressed.connect(func() -> void: bomb_pressed.emit())
	bomb_button.visible = false

func _mk_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 20)
	root.add_child(b)
	return b

func _build_panels() -> void:
	menu_panel = _panel()
	var mb := _panel_box(menu_panel)
	_panel_title(mb, "DRONE  vs  DROIDS")
	_panel_line(mb, "You fly. The factory crawls. Hold the sky,")
	_panel_line(mb, "blast the droids below, dodge their rockets.")
	_panel_line(mb, "MOVE  WASD / arrows / drag    DASH  Shift")
	_panel_line(mb, "FIRE  left click or tap    BOMB  right click or E")
	_panel_line(mb, "Guns lead a LOCK automatically: nearest is chosen,")
	_panel_line(mb, "click or tap a bot to pick it instead. Chain for x5.")
	hint_label = _panel_line(mb, "tap anywhere to launch")
	var mrow := _panel_row(mb)
	var mstart := Button.new()
	mstart.text = "FLY"
	mstart.pressed.connect(func() -> void: start_pressed.emit())
	mrow.add_child(mstart)
	var mlead := Button.new()
	mlead.text = "Leaderboard"
	mlead.pressed.connect(func() -> void: leaderboard_pressed.emit())
	mrow.add_child(mlead)

	pause_panel = _panel()
	var pb := _panel_box(pause_panel)
	_panel_title(pb, "PAUSED")
	var prow := _panel_row(pb)
	var presume := Button.new()
	presume.text = "Resume"
	presume.pressed.connect(func() -> void: resume_pressed.emit())
	prow.add_child(presume)
	var pquit := Button.new()
	pquit.text = "Quit to title"
	pquit.pressed.connect(func() -> void: Game.to_menu())
	prow.add_child(pquit)

	dead_panel = _panel()
	var db := _panel_box(dead_panel)
	dead_title = _panel_title(db, "DRONE DOWN")
	dead_score = _panel_line(db, "SCORE 0")
	dead_best = _panel_line(db, "BEST 0")
	var drow := _panel_row(db)
	revive_button = Button.new()
	revive_button.text = "Revive (ad)"
	revive_button.pressed.connect(func() -> void: revive_pressed.emit())
	drow.add_child(revive_button)
	var dretry := Button.new()
	dretry.text = "Retry"
	dretry.pressed.connect(func() -> void: retry_pressed.emit())
	drow.add_child(dretry)
	var dlead := Button.new()
	dlead.text = "Scores"
	dlead.pressed.connect(func() -> void: leaderboard_pressed.emit())
	drow.add_child(dlead)

func _panel() -> Control:
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.04, 0.07, 0.78)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim.visible = false
	root.add_child(dim)
	return dim

func _panel_box(panel: Control) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)
	return box

func _panel_title(box: VBoxContainer, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 52)
	l.add_theme_color_override("font_color", Color(0.45, 0.92, 1.0))
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(l)
	return l

func _panel_line(box: VBoxContainer, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 22)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(l)
	return l

func _panel_row(box: VBoxContainer) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 12)
	box.add_child(row)
	return row

func _on_state(state: int) -> void:
	menu_panel.visible = state == Game.State.MENU
	pause_panel.visible = state == Game.State.PAUSED
	dead_panel.visible = state == Game.State.DEAD
	bomb_button.visible = state == Game.State.PLAYING
	pause_button.visible = state != Game.State.MENU
	match state:
		Game.State.MENU:
			hint_label.visible = true
		Game.State.DEAD:
			dead_score.text = "SCORE  %s" % _fmt(Game.score)
			dead_best.text = "BEST %s   %s aloft   %d kills" % [
				_fmt(Game.best), _clock(Game.elapsed), Game.kills]
			revive_button.visible = Game.can_revive()
			dead_title.text = "NEW RECORD" if Game.record else "DRONE DOWN"
		Game.State.PLAYING:
			if hint_label != null:
				hint_label.visible = false
		_:
			if lock_label != null:
				lock_label.visible = false

func _on_score(score: int, best: int) -> void:
	score_label.text = _fmt(score)
	best_label.text = "BEST " + _fmt(best)

func _on_hp(hp: int) -> void:
	for i in cells.size():
		cells[i].color = Color(0.35, 0.95, 1.0) if i < hp else Color(0.22, 0.28, 0.34)

func _on_time(seconds: float) -> void:
	time_label.text = _clock(seconds)

static func _clock(seconds: float) -> String:
	return "%d:%02d" % [int(seconds) / 60, int(seconds) % 60]

func _on_combo(_stacks: int, mult: float) -> void:
	mult_label.text = "x%.1f" % mult
	var ratio := clampf((mult - 1.0) / (Game.COMBO_PER_STACK * Game.COMBO_MAX_STACKS),
		0.0, 1.0)
	mult_fill.size = Vector2(188.0 * ratio, 7.0)

func _on_bombs(bombs: int) -> void:
	bomb_label.text = "BOMB %d" % bombs
	bomb_button.text = "BOMB %d" % bombs
	bomb_button.disabled = bombs <= 0

func set_lock(on: bool) -> void:
	lock_label.visible = on and Game.state == Game.State.PLAYING

func _on_auth(player: String) -> void:
	name_label.text = player

static func _fmt(v: int) -> String:
	var s := str(v)
	var out := ""
	var n := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		n += 1
		if n % 3 == 0 and i > 0:
			out = "," + out
	return out
