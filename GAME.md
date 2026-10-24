# GAME.md — Drone vs Droids

Design + rules document. This is the contract the code follows. If the code and
this file disagree, fix the code or update this file — never leave both.

> **2026-10-24 pivot:** the game is now **bird's-eye top-down**. The whole screen
> is the factory floor seen from above. The drone and the droids both move in the
> X/Y plane, and the drone only shoots a target it has **locked**. The old
> side-view sky-lane design is gone; nothing in this file assumes one.

## 1. One-line pitch

You hover a scout drone over a hostile factory floor, lock onto the robots that
roam below and destroy them before their flak brings you down.

| | |
|---|---|
| Genre | Arcade top-down shooter, endless score attack |
| View | Bird's-eye, camera fixed, no rotation |
| Platform | Browser (y8.com), PC + mobile |
| Session | 2–5 minutes per run |
| Controls | Move in 2D + choose your lock. Firing is automatic once locked |
| Loop | Roam → lock → kill chain → combo multiplier → die → submit score → retry |
| Engine | Godot 4.7, GDScript, GL Compatibility renderer |

## 2. World and camera (responsive contract)

The map is **endless**. The simulation runs in unbounded world coordinates and
the camera eases after the drone, so the drone reads as centred while the ground
scrolls under it forever. There is no play-field rectangle to bounce off.

```
 logical units, base 1280 x 720, stretch = canvas_items / expand

 screen (what the player sees)          world (what the sim stores)
 ┌──────────────────────────┐              ·  ·  ▓  ·        ·
 │  ▓  ·   ▓     ⊙    ·  ▓  │   camera     ·  ⊙───follow───►  ·
 │      ~~~~river~~~~   ·   │   ────────►  ▓      ·   ▓   ·
 │  ·   ▓     ·    ·  ▓     │              ·  ·  ▓  ·  ·   ·
 └──────────────────────────┘              ▓   ·      ·  ▓
```

- `Layout.view` = the visible world rect, centred on `Layout.camera`; it equals
  the logical viewport size, so a taller window simply sees more world.
- `unit = clamp(viewport height, 720, 1250) / 720` scales every speed and size,
  so a 9:16 phone plays identically to a 16:9 desktop instead of feeling three
  times slower.
- Screen and world convert through `Layout.screen_to_world()` /
  `world_to_screen()`. Every tap, click and drag is converted before it means
  anything to the drone.
- Bots enter from just outside the view (`Layout.rand_edge_entry()`) and roam the
  world. One that wanders more than `RECALL_MARGIN` (900) outside the view is
  teleported back to a fresh edge rather than being left alive off-screen or
  deleted mid-flight.
- Bullets, mines and pickups expire when they leave the view plus their own
  margin, so nothing accumulates in the parts of the world nobody is looking at.
- HUD anchors to the viewport, so it is unaffected by where the drone flies.

A 16:9 desktop and a 9:16 phone must both be playable with no clipped UI and no
unreachable input, and the world must still be populated 40 000 units from where
it started. All four are asserted in `tests/SelfTest.gd`.

## 3. Controls

| Action | Keyboard / mouse | Touch |
|---|---|---|
| Move | `W A S D` or arrows | drag anywhere, drone eases to finger |
| Lock | automatic on the nearest bot in range; click a bot to pick it | tap a bot to pick it |
| Lock (manual) | left-click **on** a droid | tap **on** a droid |
| Fire | **hold left click** (also fires at whatever the click lands on) | tap |
| Dash | `Shift` — 0.18 s burst, 1.4 s cooldown, brief i-frames | second finger tap |
| Bomb | **right click** or `E` | on-screen bomb button |
| Pause | `Esc` / `P` | pause button |

The mouse is the weapon and the keyboard is the steering wheel: a pointer that both
aims and steers fights itself, so hover no longer moves the drone. On a phone the
thumb drags to fly and taps to shoot, which keeps it one-handed. Firing without a
lock works but sprays ±24 degrees of spread; a lock collapses that to ±8 and adds
steering, so the lock is worth having without being a precondition for shooting.
shooter work on one thumb: the drone steers, the lock selects, the guns fire
themselves. Manual lock exists so a player can pick a priority target — the
shielder, or the turret about to shoot — instead of whatever is closest.

## 4. Player rules

### Flight physics

Movement is a force model, not a teleport-to-cursor model. The rotors push along
the command at `ACCEL`, air drag opposes with the square of speed, and `DRAG` is
*derived* from the two so that drag equals thrust exactly at `MAX_SPEED`. Cruise
is therefore converged on, never clamped to: the drone reaches ~65% of it in the
first eighth of a second and the last few percent take a quarter second longer,
which is the tail that reads as mass.

```
cmd    = input_dir                                  keyboard
       = normalize(pointer - pos), limit = sqrt(2 a d)   mouse / touch
velocity += cmd * ACCEL * dt            # rotor thrust
velocity -= cmd * max(0, v·cmd - limit) * BRAKE authority   # only while easing in
velocity -= perpendicular(v, cmd) * DRIFT * dt    # the quad leans into the corner
velocity -= v_hat * DRAG * |v_before|² * dt       # quadratic drag
```

| | |
|---|---|
| `MAX_SPEED` | 460 units/s — the drag/thrust balance point, not a clip |
| `ACCEL` / `BRAKE` | 1900 / 2000 — it stops in a shorter, predictable distance than it starts |
| `DRAG` | derived: `ACCEL / MAX_SPEED²`. Change `ACCEL` and cruise does not move |
| `DRIFT` | 7/s — sideways slide after a turn; lower values make it skate, higher make it a cursor |
| `ARRIVE_GAIN` | 0.5 of the theoretical braking distance — the drone eases onto the finger and stops short rather than orbiting it |
| `STOP_DEADZONE` | 9 units — no jitter once it is on the pointer |
| Dash | an impulse to 1500 units/s that fades to cruise across 0.16 s, 1.6 s cooldown, i-frames for the burst + 0.08 s |
| `BANK_SQUASH` | hull foreshortens across the turn from this frame's sideways acceleration |
| `BOB` | 3.4 units of hover travel on two unrelated frequencies; drawn only, the hitbox never moves |
| Camera follow | eases at 5.5/s and aims `CAM_LEAD` (0.35 s) down the velocity — it has to exceed 1/5.5 = 0.18 s or the follower's own lag cancels the lead |

### Lock and guns

- 3 shield cells. Any hit = 1 cell + 1.2 s invulnerability (visible blink).
- No regen during a run; `Wrench` pickup is the only heal.
- **Lock**: the nearest bot inside `LOCK_RADIUS` (420) is acquired after **0.28 s**
  in range; the reticle closes over that window. A tap/click on a specific bot
  overrides the auto choice and holds for 2.0 s or until it dies or leaves range.
  The lock sticks to what it started acquiring — re-deciding every frame would
  let two equidistant bots cancel each other out forever.
- Locked kill bonus: **+20 %** score, so the mechanic pays for itself.
- **Guns**: 4.5 shots/s, damage 1, fire on the fire button. Locked rounds launch at the
  predicted intercept point with ±8° of spread and steer at 200°/s, so a locked
  target is hit reliably but a lateral dodge still reads as skill. Rounds live
  1.9 s or until they leave the view.
- Overcharge pickup: 7 shots/s for 6 s.
- Bomb: starts with 1 charge, max 2. Clears enemy projectiles within
  `BOMB_RADIUS = 320` and deals 2 damage to every bot in it.
- Death → game over screen (no continues except rewarded revive, §9).


## 5. Bots (ground units, moving in X and Y)

The authoritative numbers live in [data/Bots.gd](data/Bots.gd) — this table is the
summary. Adding a bot is one new entry there; `roam` and `volley` are read by
`Droid.gd`, which contains no per-bot `if id ==` branches.

Bots roam the plane. None of them can touch the drone — the drone is above them
— so the only damage source is their fire. Everything that can kill the player is
telegraphed for at least 0.5 s; unfair deaths are treated as bugs.

Speeds are base values at the start of a run; the pressure curve (§7) multiplies
them by up to 1.35. "Appears at" is seconds of run time — there are no waves.

Nothing here moves instantly. A bot creeps to its pace over `REACT * mass`
seconds and its chassis slews at `TURN_RATE`, so a waypoint change is a readable
arc and a turret has to traverse its gun to follow you. `mass` is the one number
behind all three: it sets the spin-up, the turn and how far a round throws the
chassis when it lands.

| Id | Name | HP | Speed | Mass | Score | Plane behaviour | Appears at |
|---|---|---|---|---|---|---|---|
| 1 | Walker | 1 | 68 | 1.0 | 100 | drifts between random waypoints | 0 s |
| 2 | Runner | 1 | 165 | 0.7 | 150 | charges in a straight line at the drone, pauses 0.85 s, re-aims | 25 s |
| 3 | Turret | 2 | 44 | 1.6 | 200 | crawls, stops, traverses, 0.9 s telegraph, fires a **3-round fan** of flak | 55 s |
| 4 | Tank | 4 | 38 | 2.6 | 350 | rolls, halts, **traverses its turret on its own ring**, then launches one tracking rocket | 70 s |
| 5 | Splitter | 3 | 56 | 1.3 | 300 | wanders; on death spawns 2 Walkers thrown out of the wreck | 100 s |
| 6 | Shielder | 4 | 62 | 1.5 | 400 | arc orbits at ~69°/s and eats rounds arriving within ±55° of it; drops a homing mine every 5.5 s | 150 s |
| 7 | Hauler (boss) | 22 | 40 | 6.0 | 2000 | crosses the plane, spread volley + mines, weak core exposed after each volley | 180 s — **Phase 3**, weight 0.0 so it never spawns yet |


Flak travels 205 units/s against a drone doing 460, mines 120 units/s turning no
faster than 85°/s and expire after 5 s. A rocket leaves the tube at 70 units/s and
boosts to 195 over about a quarter second, steering at 52°/s -- which is a turn
radius of ~210 units, the number that makes it dodgeable rather than a verdict. Its
smoke trail is drawn from where it has actually been, so you can trace the shot back
to the Tank that fired it even after the round is gone. Rounds leave the drone at 700 units/s,
steer at 200°/s and live 1.9 s. All of it is tuned so a lateral dodge beats a
reaction check: the player has time to decide, but not time to idle.

The Shielder is the lock mechanic's exam: you must hold lock long enough for the
gap in its rotating arc to face you, or tap-lock a softer target first.

## 6. Scoring

```
score += droid_score × multiplier × (1.2 if that droid was locked)
multiplier = 1 + min(combo_stacks, 20) × 0.2      # cap ×5.0
combo_stacks += 1 on each kill
combo decays: 1 stack per 0.35 s, fully gone 2.5 s after last kill
```

| Source | Points |
|---|---|
| Locked kill | droid score × multiplier × 1.2 |
| Unlocked kill (bomb, splitter chain) | droid score × multiplier |
| Near miss (a round passes within 40 units) | +25, no combo |
| `Core` pickup | +300 × multiplier |
| ~~Wave clear bonus~~ | removed with the wave system (§7) |
| Lock broken by moving out of range | no penalty — retarget is instant |

Displayed as a live multiplier bar plus the running score; a floating number
pops on every kill. Score is integer, no decimals shown.

## 7. Pressure curve (time, no waves)

There is no wave system: no wave counter, no wave timer, no wave-clear bonus,
nothing that steps. Difficulty is one continuous curve over run time, so the
player never hits a visible wall and can drop in at any moment.

```
pressure       = clamp(elapsed / 300 s, 0, 1)     # full strength after 5 min
spawn_interval = lerp(2.20, 0.90, pressure)   seconds
droid_speed    = base × lerp(1.00, 1.35, pressure)
fire_rate      = base × lerp(1.00, 1.30, pressure)
```

- 0–25 s: Walkers only, no hostile fire. Learn flight and the lock.
- 25 s: Runners teach that a lock is a choice, not a courtesy.
- 55 s: Turrets, first flak, the dash earns its place.
- 100 s / 150 s: Splitters, then Shielders.
- At most `MAX_DROIDS = 9` alive, spawning just outside the view and recycled if
  they wander 1200 units off-screen, so the action follows the player anywhere in
  the endless world.
- Target: an average player dies between 90 s and 200 s; a good run passes 5 min
  and is then a survival test at full pressure, not a numbers wall.

Every constant is a named MIN/MAX pair in `Game.gd` plus one `PRESSURE_TIME`. To
make the game flat-difficulty, set each MAX equal to its MIN — no code change.


## 8. Pickups

Drop on death at the droid's position, chance-weighted, drift slowly in-plane,
live 8 s, collect by flying over them.

| Pickup | Chance | Effect |
|---|---|---|
| Wrench | 6% (only when HP < 3, else converted to Core) | +1 shield cell |
| Overcharge | 10% | 6 s double fire rate |
| Core | 14% | +300 × mult, +1 bomb if below max |

## 9. y8 platform hooks

| Hook | When |
|---|---|
| `y8Sdk.init()` | page load, before the engine boots |
| interstitial `showAd({type:"start"})` | on Game Over tap-to-retry, and every 3rd run |
| rewarded `showAd({type:"reward"})` | "Revive ×1" button — once per run, clears projectiles, restores 1 cell |
| `saveLeaderboardScore({table:"best-score"})` | on run end, only if score beats the personal best |
| `showLeaderboard({table:"best-score"})` | Leaderboard button on menu + game over |
| `saveData` / `loadData` | personal best, sound setting, last used control scheme |
| `submitImage` | optional: screenshot at max combo |

Revive is offered at most once per run and never auto-shown — an unskippable ad
before a run the player did not ask for is the fastest way to lose a y8 player.

## 10. Ground and props (endless map)

The ground is not stored anywhere. [scripts/Ground.gd](scripts/Ground.gd) walks
the cells covering the visible rect and derives each one from
`hash(cell + GroundDef.SEED)`, so the world is infinite, identical every time you
fly back over it, and costs nothing to keep. Redraws are quantised to half a
cell because a finer camera move changes nothing a human can see.

- `data/GroundDef.gd` is the recipe you edit: seed, cell size, palette, river
  amplitude and period, road spacing, and one entry per prop type (density,
  radius range, shape, colours). `ENABLED` flips a prop type off the whole map.
- `GroundDef.pick()`, `river_y()`, `in_river()` and `in_road()` are pure statics,
  which is why the tests can assert "props never grow in water or on asphalt"
  without instantiating a renderer.
- Hand-placed props live in `GroundDef.PLACED` for the versioned starting set and
  in `user://ground_props.json` for anything placed at runtime. The API is
  `add_prop(type, pos, radius)`, `remove_prop_near(pos, radius)`,
  `clear_placed()`, `set_enabled(type, bool)` and `reseed(int)`.
- Scatter refuses to grow inside the river band or on a road, and half the props
  in a cell are juveniles so a repeated grid never reads as tiling.
- Roads curve. Each one is a centreline that wanders with two summed sines
  (`GroundDef.road_x/road_y`), and the lattice is offset half a step so no road
  runs through the world origin where the drone spawns.
- Traffic drives those curves: cars keep a scalar position along their road and
  read their world position from the same function, so they steer through bends
  for free and sit in a lane that flips with their direction of travel.
- Wildlife grazes, wanders and bolts from the drone: deer, rabbits, boars and
  herons, the last of which keeps to the waterline while the others stay out of
  the river and off the roads.
- Both are scenery with a fixed population: anything that drifts more than
  `RECALL` from the camera is re-placed near it, which is what keeps an endless
  map populated without an unbounded list.
- **The drone's rotors blow the map around.** `Ground.DOWNWASH` (210 units) is the
  radius the downwash reaches; `Ground.gust(dist)` falls off as the square so the
  edge of the cone is soft, and `Ground.downwash()` returns the direction a plant
  is shoved — away from the hull, because that is where the air is going. Grass
  parts, crowns slide, a high-frequency rustle appears only under the drone, and
  past 0.2 of the curve leaves come loose and tumble downwind.
- **Trees are painted, not drawn.** Each leaf mass is a scalloped outline —
  `Ground._blob()`, one 22-vertex polygon — and a crown is three of them nested:
  underside shadow, leaf body, sunlit outer mass, each with a different scallop
  twist so the edges never line up into one contour. Then dapples of lighter leaf
  clusters on the lit side. Trunks are a wide line plus a shaded and a lit
  narrower line (a four-point trunk quad folds when the crown slides sideways,
  and the triangulator rejects that with an engine error). Pines get tiers with a
  zig-zag lower edge, because needles hang in clumps and a straight line reads as
  a paper cut-out.
- **Blobs, not circle stacks, because the numbers said so.** Building the same
  three tones from overlapping circles doubled the cost of a full map redraw:
  129 k primitives and 35 ms of command recording, against 60 k and 21 ms for the
  flat discs it replaced (measured on an RTX 3050 laptop GPU, desktop window).
  Every polygon is triangulated on the CPU each time the map redraws, so the win
  is fewer *submissions*, not fewer pixels. The scalloped version costs 68 k and
  27 ms and looks better than either. `WIND_HZ` then caps wind redraws at 30/s,
  because wind at 30 fps looks the same as wind at 60.
- **Quality is two switches, not one.** The dapple and loose-leaf pass needs
  `_detailed` (few enough cells in view), and the wind clock needs `_anim`, which
  the fps controller turns off below ~45. An explicit `set_animated()` pins the
  second one: it is a decision, not a suggestion.
- **What is left on the table.** The debug overlay's phase timers say a redraw is
  ~14 ms of props, ~6 ms of roads, ~5.5 ms of terrain tint and ~0.4 ms of river.
  Roads and most prop geometry never change between frames, so the next win is
  caching them as textures drawn once, not re-triangulating the map thirty times
  a second.

## 11. Art direction

One lighting agreement lives in [scripts/Art.gd](scripts/Art.gd): a sun
direction, a sun elevation and a wind vector, which every drawn layer asks
before it places a shadow. Before it, the drone's shadow fell down-right, a
bot's fell down-left and a car's fell nowhere, and the eye reads that as fake
even though no single object looks wrong on its own. Editing `Art.SUN` relights
the whole map.

- **Buildings are roofs.** From directly above, a house is a roof and nothing else:
  an eave overhanging the wall plate, hip faces meeting a centre ridge (or two gable
  slopes on some plans), each face toned by how its normal faces the sun, shingle
  courses, a ridge cap, a chimney with its own shadow and a skylight on the lit
  slope. The first version had a door and a window on it, which is a front elevation:
  every wall of the building faces the ground from this camera.
- **Ground** takes the detail pass: two-tone grass with dirt patches, per-cell
  tufts bent by the wind, pebbles and flowers sitting in their own contact
  shadow, faceted rocks with a lit face and a shaded one, pines in tiers,
  broadleaf crowns that sway and houses that throw one solid directional shadow
  under a highlighted roof ridge. The river has wet-sand banks, a deep-water
  thread, drifting glints and reeds at the waterline; roads get a graded
  shoulder, wheel tracks and asphalt speckle.
- **Quality adapts**: tufts, glints and sway switch themselves off below ~45 fps
  (`Ground.MAX_DETAIL_CELLS`, `Ground.set_animated()`), because a phone that is
  already struggling should lose the animation, not the frame rate.
- **The drone** is real artwork, not a placeholder: a top-down quadcopter body
  plus a separate two-blade prop sprite, so the four props spin over their hub
  rings while the airframe stays rigid.
  - Sources are keyed, trimmed and downscaled by
    [tools/prep_drone_art.py](tools/prep_drone_art.py). The supplied PNGs had the
    transparency checkerboard baked into the pixels, so it is flood-filled out
    from the border rather than colour-keyed -- a luminance key would punch holes
    in the hull's light grey highlights.
  - Rotor hub anchors are measured from the artwork's orange rings, not
    eyeballed, and live as `Drone.ROTOR_HUBS` in sprite 0..1 space.
    Counter-rotation is `Drone.ROTOR_DIRS`; each blade transform is composed by
    hand because `draw_set_transform` replaces the current transform instead of
    stacking on it.
  - Spin rate rises with thrust, so a hard start kicks the props up and a hover
    settles them. Each rotor is phased differently so the silhouette never
    freezes into one symmetrical shape.
  - The airframe rotates to point at the lock, or along the flight path when
    nothing is locked. `Drone.BODY_FORWARD` flips the artwork if it turns out to
    fly backwards.
- **Airborne, not parked**: the hull bobs on two unrelated frequencies, its
  shadow stays on the ground and spreads as it rises, the airframe
  foreshortens into a turn, downwash dust is pushed out under the rotors, and
  past cruise the frame grows speed lines. All of it is drawing; none of it
  moves the hitbox, which is the difference between looking airborne and being
  impossible to aim.
- **Bots** are tracked chassis seen from above: a base plate, a top face lifted
  toward the sun, two tracks whose cleats scroll at real ground speed, a barrel
  that sits in the slot its recoil left it in, and a lean that puts the nose off
  the turn. Every round that lands shoves one, by its mass.
- **Grade** ([scripts/Grade.gd](scripts/Grade.gd)) is a vertex-coloured vignette
  plus a warm-over-cool wash, drawn behind every HUD control. No shaders:
  Compatibility mode on a single-threaded web export is where shader failures
  hide until release day, and a constant in a script is tunable by whoever
  plays it next.
- The drawn sprite is ~3.5x wider than the hitbox on purpose: getting shot at
  should feel fair, and a big readable drone with a small hitbox reads as
  skillful rather than lucky.

Everything except the drone is code-drawn geometry, so the project has no
external asset dependencies beyond it and nothing to licence-check beyond
[assets/CREDITS.md](assets/CREDITS.md). Phase 6 replaces the rest with real art.

## 12. 3D presentation layer (optional)

The game is played in 3D: [scripts/v3/View3D.gd](scripts/v3/View3D.gd) mirrors
the 2D simulation into metres (`M = 0.018` logical units per metre) and renders
it with a perspective camera pitched 58° above the floor.

- The simulation stays 2D. Positions, Area2D collision, lock range and every
  rule in this document are unchanged, so the headless suite tests real gameplay
  rather than a parallel 3D reimplementation. `dvd/view_3d=false` in
  [project.godot](project.godot) puts the flat view back in one line.
- All geometry is procedural (boxes, cylinders, spheres, a generated floor
  texture): no model files to download, host or license, and the pck stays under
  0.4 MB.
- Animation is code-driven from simulation state: rotor spin and hull tilt from
  drone velocity, hover bob, droid tread stride, hit flash from `hit_flash`,
  turret aim line while charging, shield arc segments at `shield_angle`, and a
  tip-over-and-sink death on the rig while the logic node is already gone.
- Lighting is one directional light with **no** shadow maps; each rig drops a
  generated radial blob shadow instead. That choice is deliberate: real shadow
  maps are the most expensive thing a low-end phone does on WebGL 2, and a blob
  reads just as well from this angle.
- The camera re-frames every resize by projecting the plane's four corners and
  iterating distance plus a vertical pan until the whole plane sits inside the
  viewport. The self-test asserts that at 16:9, 9:16 and 21:9, so "the play area
  fits the screen" is a checked property, not a hope.
- Skeletal/character animation is not in scope: it needs rigged glTF assets, and
  the same low-poly read is available for free from animating primitives.


## 13. Out of scope for v1

No power-up shop, no meta progression, no unlocks to buy, no level select, no
multiplayer, no physics, no tilemap, no camera rotation or zoom, no scrolling
camera (the plane fits the screen), no localisation beyond English, no music
loop longer than 45 s. Each is a v2 candidate in ROADMAP.md.
