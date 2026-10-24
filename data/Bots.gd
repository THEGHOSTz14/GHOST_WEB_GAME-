class_name Bots
extends RefCounted
## The bot roster, in one editable file (GAME.md §5).
##
## Everything about an enemy -- its name, toughness, speed, what it shoots, how
## it moves, when it appears and what it is worth -- lives in CATALOG below.
## Adding a bot is one new entry; nothing else in the codebase needs to change as
## long as `roam` and `volley` use one of the documented values.
##
## Read by: Game (scoring, unlocks), Droid (stats and behaviour), Spawner
## (selection weights), tests/SelfTest.gd.
##
##   hp        hit points before it dies
##   speed     logical units per second at the start of a run. The pressure curve
##             in Game.gd multiplies this by up to 1.35 over five minutes --
##             nothing is tuned per bot here, so the whole game slows or speeds up
##             by changing two constants there. (GAME.md §7)
##   score     base points, multiplied by combo and the lock bonus
##   w, h      chassis size in logical units (hitbox and body)
##   appears_at  seconds of run time before it can spawn (no waves)
##   fire      seconds between attacks; 0.0 = never shoots
##   volley    "none" | "flak3" (three-shell fan) | "mine" (steering)
##   roam      "waypoint" (wanders) | "charge" (sprints at the drone)
##             | "crawl" (slow wander, stops to aim)
##   splits    how many of itself spawn where it dies (0 = none)
##   arc       true = a rotating shield arc blocks incoming rounds
##   mass      chassis heft in Walker units. One knob drives three things: how
##             long the bot takes to reach full speed, how far a round throws it,
##             and how much of a shove it shrugs off. See Droid.gd.
##   weight    relative spawn chance once unlocked; 0.0 keeps it out of rotation

const CATALOG := {
	"walker": {
		"name": "Walker", "hp": 1, "speed": 68.0, "score": 100,
		"w": 36.0, "h": 36.0, "appears_at": 0.0, "fire": 0.0, "volley": "none",
		"roam": "waypoint", "splits": 0, "arc": false, "weight": 6.0,
		"mass": 1.0,
		"color": Color(0.86, 0.42, 0.34),
		"desc": "Patrol chassis. Wanders between waypoints, harmless on its own.",
	},
	"runner": {
		"name": "Runner", "hp": 1, "speed": 165.0, "score": 150,
		"w": 30.0, "h": 30.0, "appears_at": 25.0, "fire": 0.0, "volley": "none",
		"roam": "charge", "splits": 0, "arc": false, "weight": 4.0,
		"mass": 0.7,
		"color": Color(0.98, 0.76, 0.28),
		"desc": "Sprints straight at where you were, pauses, re-aims.",
	},
	"turret": {
		"name": "Turret", "hp": 2, "speed": 44.0, "score": 200,
		"w": 42.0, "h": 42.0, "appears_at": 55.0, "fire": 4.2, "volley": "flak3",
		"roam": "crawl", "splits": 0, "arc": false, "weight": 3.0,
		"mass": 1.6,
		"color": Color(0.55, 0.72, 0.98),
		"desc": "Stops, telegraphs for 0.7 s, fires a three-shell flak fan.",
	},
	"splitter": {
		"name": "Splitter", "hp": 3, "speed": 56.0, "score": 300,
		"w": 48.0, "h": 48.0, "appears_at": 100.0, "fire": 0.0, "volley": "none",
		"roam": "waypoint", "splits": 2, "arc": false, "weight": 2.0,
		"mass": 1.3,
		"color": Color(0.72, 0.45, 0.92),
		"desc": "Breaks into two Walkers where it dies.",
	},
	"shielder": {
		"name": "Shielder", "hp": 4, "speed": 62.0, "score": 400,
		"w": 44.0, "h": 44.0, "appears_at": 150.0, "fire": 5.5, "volley": "mine",
		"roam": "waypoint", "splits": 0, "arc": true, "weight": 2.0,
		"mass": 1.5,
		"color": Color(0.42, 0.86, 0.62),
		"desc": "Rotating arc eats rounds arriving within 55 degrees of it.",
	},
	# Reserved for Phase 3. Listed so the roster, the docs and the boss agree
	# before its scene exists; weight 0.0 keeps it out of the normal rotation.
	"hauler": {
		"name": "Hauler", "hp": 22, "speed": 40.0, "score": 2000,
		"w": 96.0, "h": 96.0, "appears_at": 180.0, "fire": 3.0, "volley": "flak3",
		"roam": "crawl", "splits": 0, "arc": false, "weight": 0.0,
		"mass": 6.0,
		"color": Color(0.95, 0.35, 0.35),
		"desc": "Boss. Not spawned yet (ROADMAP Phase 3).",
	},
}

static func ids() -> Array:
	return CATALOG.keys()

## Bots the spawner may actually pick.
static func spawnable() -> Array:
	var out: Array = []
	for id in CATALOG:
		if float(CATALOG[id].weight) > 0.0:
			out.append(id)
	return out

static func def(id: String) -> Dictionary:
	return CATALOG.get(id, {})

static func available_at(seconds: float, id: String) -> bool:
	return seconds >= float(CATALOG[id].appears_at)

## Total spawn weight available at a point in the run; 0.0 means nothing can
## spawn yet (the first half second, in practice).
static func total_weight(seconds: float) -> float:
	var total := 0.0
	for id in spawnable():
		if available_at(seconds, id):
			total += float(CATALOG[id].weight)
	return total

## Weighted pick for a point in the run, given a roll in [0,1).
static func pick(seconds: float, roll: float) -> String:
	var acc := 0.0
	var target := roll * maxf(0.0001, total_weight(seconds))
	for id in spawnable():
		if not available_at(seconds, id):
			continue
		acc += float(CATALOG[id].weight)
		if target <= acc:
			return id
	return "walker"

static func display_name(id: String) -> String:
	return String(def(id).get("name", id))
