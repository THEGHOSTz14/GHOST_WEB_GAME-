# Drone vs Droids

A responsive 2D arcade game built in Godot 4.7 for the browser, targeting
[y8.com](https://y8.com). Fly a scout drone over a factory floor and destroy the
robots patrolling below before their anti-air rockets hit you.

- Design + rules: [GAME.md](GAME.md)
- Plan to submission: [ROADMAP.md](ROADMAP.md)

## Two views, one game

`dvd/view_3d` in [project.godot](project.godot) selects the presentation. It is
currently **false** — the flat 2D bird's-eye view, which is what ships. Set it to
`true` for the optional 3D layer (procedural meshes, perspective camera,
animated rig). Gameplay, collision and every rule are identical in both, and
`tools/run_tests.sh` passes in each mode.

## Layout

```
project.godot              web-first settings, input map, autoloads, view mode
export_presets.cfg         the only preset: Web, thread_support = false
scenes/Main.tscn           entry scene

data/Bots.gd               THE BOT FILE -- every enemy: name, hp, speed, mass,
                           score, size, colour, when it appears, fire rate,
                           volley type, roam behaviour, spawn weight
data/GroundDef.gd          THE GROUND RECIPE -- seed, cell size, palette, river
                           shape, road spacing, per-prop density and on/off
                           switches, hand-placed prop list

scripts/autoload/Layout.gd endless world camera: view rect, unit scaling,
                           screen <-> world conversion
scripts/autoload/Game.gd   run state, score rules, difficulty curve
scripts/autoload/Y8Api.gd  portal bridge facade (no-op off-web)
scripts/Drone.gd           THE PLAYER -- thrust/drag flight, lock state machine, guns
scripts/Ground.gd          draws the endless map, edits props, persists layout
scripts/Art.gd             one shared sun, wind and shadow language for every layer
scripts/Grade.gd           vignette and warm/cool wash, drawn under the HUD
scripts/Traffic.gd         cars driving the curved roads (scenery)
scripts/Wildlife.gd        grazing, fleeing animals (scenery)
scripts/Droid.gd           one bot script, driven entirely by data/Bots.gd
scripts/Bullet.gd  scripts/DroidFire.gd  scripts/Pickup.gd   pooled entities
scripts/Spawner.gd         when to place the next bot, recycling off-screen ones
scripts/Hud.gd             anchored overlay: score, combo, shield, lock, panels
scripts/Main.gd            assembly, pools, juice, ad policy, camera follow
scripts/v3/View3D.gd       optional 3D presentation layer over the same sim

platform/html_shell.html   exported page: y8 SDK + bridge + engine bootstrap
platform/y8_bridge.js      window.DvDY8 -- the JS half of Y8Api
tests/SelfTest.tscn        115 headless gameplay assertions
assets/drone/              drone body + prop sprites (see assets/CREDITS.md)
tools/                     build, serve, test, template-fetch, art prep
builds/web/                exported page        builds/y8/*.zip  portal upload
```

## Editing the world and the roster

| Want to | File | How |
|---|---|---|
| Add a bot | `data/Bots.gd` | one new CATALOG entry; `Droid.gd` reads `roam`/`volley`/`arc`/`splits` |
| Retune a bot | `data/Bots.gd` | edit hp / speed / fire / weight |
| Remove a bot | `data/Bots.gd` | delete the entry, or set `weight: 0.0` to park it |
| Re-roll the map | `data/GroundDef.gd` | change `SEED` |
| Add a prop type | `data/GroundDef.gd` | new `PROPS` entry + a `shape` case in `Ground._draw_prop()` |
| Remove a prop type | `data/GroundDef.gd` | `ENABLED: {"house": false}` |
| Place one prop by hand | at runtime | `Ground.add_prop("tree", pos)`, saved to `user://ground_props.json` |
| Delete a prop by hand | at runtime | `Ground.remove_prop_near(pos, radius)` |
| Change the feel of flight | `scripts/Drone.gd` | `MAX_SPEED` (the drag balance point), `ACCEL`, `BRAKE`, `DRIFT` |
| Ease the drone onto the finger harder/softer | `scripts/Drone.gd` | `ARRIVE_GAIN` (1.0 = arrives at the braking limit) |
| Dash distance | `scripts/Drone.gd` | `DASH_SPEED`, `DASH_TIME`, `DASH_COOLDOWN` |
| Hover look | `scripts/Drone.gd` | `BOB` (drawn offset), `BANK_SQUASH`, `ALTITUDE` (shadow parallax) |
| Make the bots heavier on their tracks | `data/Bots.gd` | `mass` per bot; the limits are `Droid.REACT`, `TURN_RATE`, `KNOCKBACK` |
| Back to hands-free guns | `scripts/Drone.gd` | `AUTO_FIRE = true` |
| More or fewer cars | `data/GroundDef.gd` | `CARS.count`, `speed_min/max` |
| Add an animal species | `data/GroundDef.gd` | new `ANIMALS` entry + a `match` arm in `Wildlife._draw` |
| Add a shooting bot | `data/Bots.gd` | new entry; `volley` picks the gun (`flak3`, `mine`, `rocket`), `roam` picks the movement. `Droid.gd` has no per-bot branches, but `tests/SelfTest.gd` validates the vocabulary, so a new mode has to be acknowledged there too |
| Rocket or flak tuning | `scripts/DroidFire.gd` | `ROCKET_SPEED`, `ROCKET_TURN` (turn radius = speed / rate), `RK_START`, `FLAK_SPEED`, `MINE_SPEED` |
| Turret slew rate | `scripts/Droid.gd` | `TURRET_RATE` (hull turning is `TURN_RATE`, deliberately faster) |
| Bend the roads more | `data/GroundDef.gd` | `BEND_A`, `BEND_B`, their periods |
| Drone size / spin / hubs | `scripts/Drone.gd` | `SPRITE_SPAN`, `PROP_BASE_RATE`, `ROTOR_HUBS`, `BODY_FORWARD` |
| Re-run the artwork import | `tools/prep_drone_art.py` | `python tools/prep_drone_art.py <body.png> <prop.png>` |
| Change camera lag | `scripts/Main.gd` | `CAM_FOLLOW` (1.0 = welded to the drone) |
| Change camera look-ahead | `scripts/Main.gd` | `CAM_LEAD` -- must stay above `1/CAM_FOLLOW` or the follower's lag cancels it |
| Relight the whole map | `scripts/Art.gd` | `SUN`, `SUN_ELEV`, `WIND`, palette constants |
| Turn the ground detail animation off | `scripts/Ground.gd` | `ANIM_FPS`, `MAX_DETAIL_CELLS`, or `set_animated(false)` |
| How far the drone's wind reaches | `scripts/Ground.gd` | `DOWNWASH` (radius), `gust()` (the fall-off curve) |
| Canopy shape and how busy it looks | `scripts/Ground.gd` | `BLOB_STEPS` (outline vertices), the three `_blob()` bands in `_draw_tree()`, `WIND_HZ` (redraw cap) |
| See what a redraw actually costs | run with `-- --debug` | prints `ground_draw`, redraws per second, and a cells/roads/props/river phase split |
| Vignette / colour wash | `scripts/Grade.gd` | `VIGNETTE`, `INNER`, `WASH`, `WARM`, `COOL` |

Gameplay objects are created by script, not dragged into a scene: `Main.tscn` is
one root node. Editing visuals means editing `_draw()` in
[scripts/Drone.gd](scripts/Drone.gd), [scripts/Droid.gd](scripts/Droid.gd) and
[scripts/Ground.gd](scripts/Ground.gd) -- all three ask
[scripts/Art.gd](scripts/Art.gd) where the sun and the wind are, so a shadow
never ends up falling one way for a bot and the other way for a tree -- or
replacing them with `Sprite2D` + real art in Phase 6.

## One-time setup

Already done on this machine; repeat here for a new one.

Godot 4.7.2 lives at `C:\Users\Asus\AppData\Local\Programs\Godot\`
(`winget install GodotEngine.GodotEngine` aborts on this connection, so the zip
was fetched directly and unpacked with Python).

Web export templates do not ship with the editor, and the official
`export_templates.tpz` is 1.22 GB while the web templates inside it are only
~40 MB. [tools/fetch_web_templates.py](tools/fetch_web_templates.py) reads the
zip's central directory over HTTP range requests and downloads just those
members, with per-chunk resume:

```bash
python tools/fetch_web_templates.py --list          # inspect the archive
python tools/fetch_web_templates.py                # web_* templates -> %APPDATA%
python tools/fetch_web_templates.py --pattern "web_(nothreads_)?(release|debug)\.zip$"
```

Templates land in `%APPDATA%\Godot\export_templates\4.7.2.stable\`. Godot needs
them named exactly as they are inside the tpz.

If the shell cannot find the editor, export the path:

```bash
export GODOT_BIN="/c/Users/Asus/AppData/Local/Programs/Godot/Godot_v4.7.2-stable_win64_console.exe"
```

## Day-to-day

| Command | What it does |
|---|---|
| `"$GODOT_BIN" --editor --path .` | open the project in the editor |
| `"$GODOT_BIN" --path .` | run it as a desktop window |
| `bash tools/run_tests.sh` | 115 assertions; fails on any engine error in the log |
| `bash tools/build_web.sh` | headless release export → `builds/web/` + zip |
| `bash tools/build_web.sh --debug` | same with debug templates (verbose console) |
| `bash tools/build_web.sh --gz` | also emit `.gz` siblings for hosts that need them |
| `python tools/serve_web.py` | serve at http://127.0.0.1:8060/ like a portal would |
| `"$GODOT_BIN" --headless --path . --quit-after 5` | fast parse/boot check |

`serve_web.py` deliberately sends **no** COOP/COEP headers. y8 sends none
either, so a build that only runs through `--isolate` is a build that will
white-screen on the portal.

`--debug` as a *game* argument (`index.html?--debug`) turns on the HUD overlay
showing fps, field size, `unit`, live droid count and web-ness.

## What the build is checked for

`tools/build_web.sh` fails rather than shipping:

- `index.html` absent, or any of `index.js` / `index.wasm` / `index.pck` missing
- `GODOT_THREADS_ENABLED = true` in the page — a threaded build requires
  cross-origin isolation the portal will not provide
- total transfer size over the Phase 4 budget

## y8 integration state

Bridge contract is verified in a browser: `boot()` emits `ready` + `auth`,
`ad('reward')` resolves to exactly one `ad` event, `save`/`score`/`leaderboard`
degrade to `"skip"` when no SDK session exists, and a missing SDK never blocks
the game. The revive offer also self-grants outside the portal so the flow stays
testable.

Before submission, put the real IDs in [platform/html_shell.html](platform/html_shell.html)
(`DVD_Y8_CONFIG`): `appId` from <https://account.y8.com/applications/> and
`gameId` assigned by y8 once the game is approved. Leaderboard table is
`best-score`.

## Verified on

- Godot 4.7.2.stable, single-threaded web export, WebGL 2.0 / GL Compatibility
- Chrome (in-app browser) at desktop size: boots clean, no console errors,
  `crossOriginIsolated = false`, no `SharedArrayBuffer`
- headless self-test across 16:9, 9:16 portrait and 21:9 ultrawide

## Not done yet

Hauler boss, audio, real art, all Phase 2 input polish, and anything requiring
portal credentials — see the unchecked boxes in [ROADMAP.md](ROADMAP.md).
