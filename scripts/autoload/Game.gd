extends Node
## Run state, score rules and every tunable number from GAME.md.
## Balance edits belong here and nowhere else.

enum State { MENU, PLAYING, PAUSED, DEAD }

# ---- rules (GAME.md §6, §7) ----
## Difficulty is one smooth curve over run time. There are no waves: no wave
## counter, no wave timer, no wave bonus, nothing that steps.
const PRESSURE_TIME := 300.0
const MAX_DROIDS := 9
const SPAWN_BASE := 2.20
const SPAWN_MIN := 0.90
const SPEED_MIN := 1.00
const SPEED_MAX := 1.35
const FIRE_MIN := 1.00
const FIRE_MAX := 1.30
const COMBO_GRACE := 2.5
const COMBO_STEP := 0.35
const COMBO_MAX_STACKS := 20
const COMBO_PER_STACK := 0.2
const NEAR_MISS_POINTS := 25
const NEAR_MISS_RADIUS := 40.0

# ---- player (GAME.md §4) ----
const START_HP := 3
const INVULN := 1.2
const FIRE_INTERVAL := 1.0 / 4.5
const OVERCHARGE_INTERVAL := 1.0 / 7.0
const OVERCHARGE_TIME := 6.0
const START_BOMBS := 1
const MAX_BOMBS := 2
const REVIVE_LIMIT := 1

# ---- lock-on (GAME.md §4, §6) ----
## Acquisition range from the drone, in logical units.
const LOCK_RADIUS := 420.0
## Time the target must stay in range before the guns unlock.
const LOCK_TIME := 0.28
## How long a hand-picked target outranks the nearest one.
const LOCK_PRIORITY := 2.0
## Score multiplier for killing the droid you had locked.
const LOCK_BONUS := 1.2
## Bomb blast radius around the drone.
const BOMB_RADIUS := 320.0

# ---- bot stats live in data/Bots.gd, not here ----
# A `const DROIDS := Bots.CATALOG` alias does not resolve at parse time across
# class_name scripts, so lookups go through the accessor below instead.

# ---- pickups (GAME.md §8) ----
const PICKUPS := {
	"wrench": {"chance": 0.06, "color": Color(0.98, 0.35, 0.55)},
	"overcharge": {"chance": 0.10, "color": Color(0.35, 0.95, 1.0)},
	"core": {"chance": 0.14, "color": Color(0.98, 0.86, 0.35)},
}
const CORE_POINTS := 300
const PICKUP_FALL := 120.0
const PICKUP_LIFE := 8.0

const SAVE_PATH := "user://progress.cfg"
const RUNS_PER_INTERSTITIAL := 3

signal state_changed(state)
signal score_changed(score, best)
signal hp_changed(hp)
signal combo_changed(stacks, multiplier)
signal time_changed(seconds)
signal bomb_changed(bombs)
signal died(score, seconds)
signal near_missed(at)

var state: int = State.MENU
var score := 0
var best := 0
var hp := START_HP
var elapsed := 0.0
var bombs := START_BOMBS
var overcharge := 0.0
var kills := 0
var near_misses := 0
var revives_used := 0
var runs := 0
var live_droids := 0
var record := false
## 3D presentation on or off (project setting dvd/view_3d).
var view_3d := false

var _time_emit := 0.0
var _combo := 0
var _combo_hold := 0.0
var _combo_decay := 0.0

func _ready() -> void:
	view_3d = bool(ProjectSettings.get_setting("dvd/view_3d", false))
	load_progress()

func _process(delta: float) -> void:
	if state != State.PLAYING:
		return
	elapsed += delta
	_time_emit += delta
	if _time_emit >= 0.25:
		_time_emit = 0.0
		time_changed.emit(elapsed)
	if overcharge > 0.0:
		overcharge = maxf(0.0, overcharge - delta)
	if _combo > 0:
		if _combo_hold > 0.0:
			_combo_hold = maxf(0.0, _combo_hold - delta)
		else:
			_combo_decay += delta
			if _combo_decay >= COMBO_STEP:
				_combo_decay = 0.0
				_combo -= 1
				combo_changed.emit(_combo, multiplier())

# ---- derived difficulty ----
func multiplier() -> float:
	return 1.0 + minf(_combo, COMBO_MAX_STACKS) * COMBO_PER_STACK

## 0 at the start of a run, 1 after PRESSURE_TIME, smooth in between.
func pressure() -> float:
	return clampf(elapsed / PRESSURE_TIME, 0.0, 1.0)

func spawn_interval() -> float:
	return lerpf(SPAWN_BASE, SPAWN_MIN, pressure())

func speed_scale() -> float:
	return lerpf(SPEED_MIN, SPEED_MAX, pressure())

func fire_scale() -> float:
	return lerpf(FIRE_MIN, FIRE_MAX, pressure())

func fire_interval() -> float:
	return OVERCHARGE_INTERVAL if overcharge > 0.0 else FIRE_INTERVAL

func is_available(id: String) -> bool:
	return Bots.available_at(elapsed, id)

# ---- run lifecycle ----
func start_run() -> void:
	get_tree().paused = false
	record = false
	score = 0
	hp = START_HP
	elapsed = 0.0
	_time_emit = 0.0
	bombs = START_BOMBS
	overcharge = 0.0
	kills = 0
	near_misses = 0
	revives_used = 0
	_combo = 0
	_combo_hold = 0.0
	_combo_decay = 0.0
	state = State.PLAYING
	score_changed.emit(score, best)
	hp_changed.emit(hp)
	combo_changed.emit(_combo, multiplier())
	time_changed.emit(elapsed)
	bomb_changed.emit(bombs)
	state_changed.emit(state)

func die() -> void:
	state = State.DEAD
	runs += 1
	record = score > best
	if record:
		best = score
		save_progress()
	score_changed.emit(score, best)
	died.emit(score, elapsed)
	state_changed.emit(state)
	if record:
		Y8Api.submit_score(score)

func to_menu() -> void:
	get_tree().paused = false
	state = State.MENU
	record = false
	state_changed.emit(state)

func can_revive() -> bool:
	return state == State.DEAD and revives_used < REVIVE_LIMIT

func revive() -> void:
	revives_used += 1
	hp = 1
	state = State.PLAYING
	hp_changed.emit(hp)
	state_changed.emit(state)

func toggle_pause() -> void:
	if state == State.PLAYING:
		state = State.PAUSED
	elif state == State.PAUSED:
		state = State.PLAYING
	else:
		return
	state_changed.emit(state)

func wants_interstitial() -> bool:
	return runs > 0 and runs % RUNS_PER_INTERSTITIAL == 0

# ---- scoring ----
func bot_score(id: String) -> int:
	return int(Bots.def(id).get("score", 100))

func register_kill(id: String, locked := false) -> void:
	kills += 1
	_combo += 1
	_combo_hold = COMBO_GRACE
	_combo_decay = 0.0
	var base := float(bot_score(id)) * multiplier()
	add_score(base * (LOCK_BONUS if locked else 1.0))
	combo_changed.emit(_combo, multiplier())

func add_score(amount: float) -> void:
	score = maxi(0, score + int(round(amount)))
	score_changed.emit(score, best)

func register_near_miss(at: Vector2) -> void:
	near_misses += 1
	add_score(NEAR_MISS_POINTS)
	near_missed.emit(at)

# ---- damage / pickups ----
func damage_player() -> bool:
	if state != State.PLAYING:
		return false
	hp = maxi(0, hp - 1)
	hp_changed.emit(hp)
	if hp == 0:
		die()
	return true

func heal() -> void:
	hp = mini(hp + 1, START_HP)
	hp_changed.emit(hp)

func apply_pickup(id: String) -> void:
	match id:
		"wrench":
			heal()
		"overcharge":
			overcharge = OVERCHARGE_TIME
		"core":
			add_score(CORE_POINTS * multiplier())
			if bombs < MAX_BOMBS:
				bombs += 1
				bomb_changed.emit(bombs)

func use_bomb() -> bool:
	if state != State.PLAYING or bombs <= 0:
		return false
	bombs -= 1
	bomb_changed.emit(bombs)
	return true

func note_spawn() -> void:
	live_droids += 1

func note_despawn() -> void:
	live_droids = maxi(0, live_droids - 1)

# ---- persistence ----
func save_progress() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SAVE_PATH)
	cfg.set_value("run", "best", best)
	cfg.set_value("run", "runs", runs)
	cfg.save(SAVE_PATH)
	Y8Api.save_value("best", str(best))

func load_progress() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	best = cfg.get_value("run", "best", 0)
	runs = cfg.get_value("run", "runs", 0)
