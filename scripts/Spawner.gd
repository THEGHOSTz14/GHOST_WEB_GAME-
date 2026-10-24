class_name Spawner
extends Node2D
## Wave pacing and bot selection (GAME.md §5, §7). The roster itself lives in
## data/Bots.gd; this file only decides when to place the next one. Main wires
## the signals and owns the pools.

signal droid_spawned(droid)

## How far outside the visible rect a bot may wander before it is pulled back.
const RECALL_MARGIN := 1200.0

var host: Node
var drone: Drone
var timer := 1.0

func setup(into: Node, target_drone: Drone) -> void:
	host = into
	drone = target_drone
	timer = 0.8

func _physics_process(delta: float) -> void:
	if Game.state != Game.State.PLAYING or host == null:
		return
	timer -= delta
	if timer > 0.0:
		return
	timer = Game.spawn_interval()
	_recycle_far_bots()
	var kind := pick_kind()
	if kind != "" and Game.live_droids < Game.MAX_DROIDS:
		spawn(kind)

func pick_kind() -> String:
	## Who appears, when and how often all lives in data/Bots.gd.
	if Bots.total_weight(Game.elapsed) <= 0.0:
		return ""
	return Bots.pick(Game.elapsed, randf())

## The world is endless, so a bot that wanders off screen is moved back into play
## rather than left alive forever or deleted into thin air.
func _recycle_far_bots() -> void:
	for node in get_tree().get_nodes_in_group("droids"):
		var d := node as Droid
		if d != null and d.out_of_range(RECALL_MARGIN):
			d.recall_near()

## Bots walk in from just outside a random edge of the view, so nothing pops into
## existence in front of the player.
func spawn(kind: String, at := Vector2.INF) -> Droid:
	var d := Droid.new()
	var pos := at if at != Vector2.INF else Layout.rand_edge_entry()
	d.configure(kind, pos, drone)
	host.add_child(d)
	droid_spawned.emit(d)
	return d

## The Hauler boss every 5th wave is Phase 3 (ROADMAP). It is already in
## data/Bots.gd with weight 0.0, so it stays out of the rotation until its scene
## exists rather than pretending here.
