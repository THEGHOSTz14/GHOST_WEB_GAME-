extends Node
## GDScript facade over the y8 minimal SDK v2, which is driven from
## platform/y8_bridge.js in the exported page.
##
## Design notes:
## - Calls are one-way into `window.DvDY8`; async results come back through a
##   polled event queue. Godot 4's JavaScriptBridge callback registration has
##   changed shape across point releases, and polling sidesteps that entirely.
## - Outside a web export every call is a no-op, so the editor and desktop
##   builds behave identically. `request_reward()` fakes a granted reward so the
##   revive flow stays testable without the portal.
## - App ID / Game ID live in the JS layer, never in the shipped pck.

signal sdk_ready
signal auth_changed(name)
signal ad_finished(kind, granted)
signal score_saved(ok)
signal value_loaded(key, value)

const POLL_SECONDS := 0.15
const FAKE_REWARD_SECONDS := 0.4

var enabled := false
var bridge_ready := false
var player_name := "Guest"

var _poll_acc := 0.0

func _ready() -> void:
	# Engine.has_singleton("JavaScriptBridge") is also true in the desktop
	# editor -- only a web export can actually evaluate JS.
	enabled = OS.has_feature("web")
	set_process(enabled)

func boot() -> void:
	if not enabled:
		return
	_eval("DvDY8.boot()")
	_eval("DvDY8.load('best')")

func game_started() -> void:
	_eval("DvDY8.started()")

func interstitial() -> void:
	_eval("DvDY8.ad('start')")

func request_reward() -> void:
	if not enabled:
		get_tree().create_timer(FAKE_REWARD_SECONDS).timeout.connect(_fake_reward)
		return
	_eval("DvDY8.ad('reward')")

func submit_score(score: int) -> void:
	_eval("DvDY8.score(%d)" % score)

func show_leaderboard() -> void:
	_eval("DvDY8.leaderboard()")

func save_value(key: String, value: String) -> void:
	_eval("DvDY8.save(%s, %s)" % [JSON.stringify(key), JSON.stringify(value)])

func load_value(key: String) -> void:
	_eval("DvDY8.load(%s)" % JSON.stringify(key))

func open_profile() -> void:
	_eval("DvDY8.profile()")

func _fake_reward() -> void:
	ad_finished.emit("reward", true)

func _eval(expr: String) -> String:
	if not enabled or expr == "":
		return ""
	var js := Engine.get_singleton("JavaScriptBridge")
	if js == null:
		push_warning("JavaScriptBridge missing; skipping " + expr.get_slice("(", 0))
		return ""
	return String(js.call("eval", expr))

func _process(delta: float) -> void:
	_poll_acc += delta
	if _poll_acc < POLL_SECONDS:
		return
	_poll_acc = 0.0
	var raw := _eval("DvDY8.poll()")
	if raw == "" or raw == "null":
		return
	var parsed = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_ARRAY:
		return
	for event in parsed:
		if typeof(event) == TYPE_DICTIONARY:
			_handle(event)

func _handle(e: Dictionary) -> void:
	match String(e.get("t", "")):
		"ready":
			bridge_ready = true
			sdk_ready.emit()
		"auth":
			player_name = String(e.get("name", "Guest"))
			auth_changed.emit(player_name)
		"ad":
			ad_finished.emit(String(e.get("kind", "")), bool(e.get("granted", false)))
		"score":
			score_saved.emit(bool(e.get("ok", false)))
		"value":
			var key := String(e.get("key", ""))
			var value := String(e.get("value", ""))
			if key == "best" and value.is_valid_int() and int(value) > Game.best:
				Game.best = int(value)
			value_loaded.emit(key, value)
		_:
			push_warning("unknown y8 bridge event: " + str(e))
