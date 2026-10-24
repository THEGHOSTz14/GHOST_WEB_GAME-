# ROADMAP.md — from empty folder to live on y8.com

> **2026-10-24, two pivots:** the game is a **bird's-eye top-down shooter with
> lock-on firing** on an **endless scrolling map** (GAME.md §2, §10). A 3D
> presentation layer was built and is kept behind `dvd/view_3d=false`; the flat
> 2D view is what ships. Phase 0–1 boxes below reflect the current design; the
> phase boundaries and the submission path are unchanged.

Working agreement: finish a phase only when every acceptance box is ticked.
Estimates assume one person, evenings. Phases are ordered so that a buildable,
testable web page exists in week 1 — do not build 3 weeks of gameplay and then
discover the browser does not run it.

Status legend: `[ ]` todo · `[~]` in progress · `[x]` done

---

## Phase 0 — Toolchain (this session)

- [x] Godot 4.7.2 stable editor (winget `GodotEngine.GodotEngine`)
- [x] Web export templates: official `*_export_templates.tpz` (1.28 GB), extract
      **only** the `web_*` entries into
      `%APPDATA%\Godot\export_templates\4.7.2.stable\`
- [x] `project.godot` configured for web: GL Compatibility renderer,
      `stretch/canvas_items` + `aspect/expand`, 1280×720 base
- [x] `export_presets.cfg` with **Thread Support OFF** (blocking: y8 does not
      serve COOP/COEP headers, so a threaded build white-screens there)
- [x] `tools/serve_web.py` — local server with correct MIME, optional gzip and
      **no** COOP/COEP by default, so localhost behaves like the portal
- [x] Repo hygiene: `.gitignore` for `.import`, `.cache`, `builds/`

**Acceptance**
- [x] `godot --headless --path . --quit` opens the project with 0 errors
- [x] A blank `Main.tscn` exports to `builds/web/index.html` and boots in Chrome

---

## Phase 1 — Vertical slice: shoot one robot (≈ 2 evenings)

The smallest loop that proves the game is fun: fly, auto-fire, kill a Walker,
see a score, die, restart.

- [x] `Layout` autoload: endless camera view, resize signal, unit scaling,
      screen/world conversion
- [x] `Drone` — 2D pointer + keyboard flight with easing, lock-on state machine
- [x] `Bullet` — pooled, intercept-aimed with light steering, off-screen cull
- [x] `Walker` — waypoint roam, off-screen recycle, hit flash, death
- [x] `Spawner` — time-based pressure, off-screen bot recycling, no wave system
- [ ] Collision layers + `Area2D` hit registration
- [x] `Score` autoload per GAME.md §6 (kills × multiplier, combo decay)
- [x] HUD: score, run timer, multiplier bar, shield cells
- [x] Title → play → game over → restart, `Esc` pause
- [x] Placeholder art only (Polygon2D / `_draw()`), no imports

**Acceptance**
- [ ] 60 fps in Chrome at 1280×720 on an integrated-GPU laptop
- [x] Playable start-to-death-to-restart with no editor intervention
- [ ] Mouse, keyboard and touch drag all move the drone

---

## Phase 2 — Responsive + input feel (≈ 2 evenings)

- [ ] Portrait 9:16, landscape 16:9, 4:3 and a 320 px-wide phone all pass the
      §2 contract: no clipped HUD, no unreachable input, no stretched art
- [x] Pointer grabbing: finger offset so the drone is visible above the thumb
- [x] Dash (i-frames + cooldown + trail) and Bomb, mouse/touch/keys
- [ ] Pause on tab blur; `AudioServer` mute on blur; resume without a frame spike
- [ ] On-screen buttons ≥ 88 px hit area, thumb-reachable bottom band
- [x] `prevent_default` for touch scroll / pinch / context menu in the HTML shell

**Acceptance**
- [ ] Recorded 30 s of touch play on a real Android phone, no missed input
- [ ] Layout survives dragging the browser window from 4:3 to 21:9 without restart

---

## Phase 3 — Full rules (≈ 4 evenings)

Everything in GAME.md that Phase 1 stubs out.

- [x] Runner, Turret (telegraph → rocket), Splitter, Shielder
- [ ] Hauler boss (appears at 180 s, weight 0.0 until built): spread volley, mines, exposed core
- [x] Pickups: Wrench, Overcharge, Core
- [x] Near-miss bonus, wave-clear bonus
- [x] Pressure curve from GAME.md §7 as named MIN/MAX pairs in `Game.gd`
- [ ] Juice: screen shake, hit-stop 0.05 s, damage numbers, death freeze-frame
      -- done: muzzle flash and recoil, spark/debris/shard particles, rising
      smoke, scorch decals, dash shockwave, hover bob, bank-into-turn
- [ ] Audio: 45 s loop + 8 SFX (shoot, hit, kill, pickup, rocket warn, dash,
      bomb, death) — CC0 or self-made, licence noted per file in `assets/CREDITS.md`

**Acceptance**
- [ ] Average death lands between 90 s and 200 s (5 measured runs)
- [ ] Every killable object has a readable death and a readable threat warning
- [ ] 60 fps with 14 droids + 40 bullets on a mid-range phone

---

## Phase 4 — Web build pipeline (≈ 2 evenings)

- [x] `tools/build_web.sh` — headless export, deterministic output, clean log
- [x] Custom HTML shell (`platform/html_shell.html`): dark background, centred
      canvas, loading bar, no engine logo spam, y8 SDK script tag
- [x] Ship with gzip or brotli pre-compression and a `.htaccess`/`_headers` file
      so the wasm is served with `Content-Encoding`
- [x] Bundle budget: **≤ 20 MB compressed**, ≤ 8 MB pck
- [x] Release page checked in a real browser after every build: zero console
      errors and `startGame()` resolved. A source-only headless run cannot catch
      export-only bugs -- `Class.new` taken as a Callable parses fine in the
      editor and fails in the web runtime, which is how a broken build nearly
      shipped. Keep this box ticked; it is the last gate before y8.

**Acceptance**
- [~] `builds/y8/*.zip` boots on a local static host (visual 60 fps check needs a
      visible browser surface -- run `python tools/serve_web.py` and play it)
- [ ] Total download ≤ 20 MB, first playable frame ≤ 8 s on a 4G throttle
- [x] No console errors, no 404s, no mixed-content warnings

---

## Phase 5 — y8 SDK + monetisation (≈ 3 evenings)

Reference: `https://cdn.y8.com/minimal-sdk/2-0/y8.min.js` — init, `onAuth`,
`showAd`, `saveLeaderboardScore`, `showLeaderboard`, `saveData`, `loadData`,
`submitImage`, `openProfile`, `getPlatformLocale`, `isBlacklisted`.
App ID from `https://account.y8.com/applications/`, Game ID assigned by y8 after
approval.

- [x] `platform/y8_bridge.js` — wraps the SDK, queues calls made before
      `y8sdk.ready`, no-ops with a warning when the SDK is absent (local dev)
- [x] `scripts/autoload/Y8Api.gd` — `JavaScriptBridge` facade; must be a safe
      no-op in the desktop editor build
- [ ] Init on boot, `onAuth` → player name on the HUD, `autoLogin` on
- [ ] Interstitial on game-over retry + every 3rd run (§9)
- [ ] Rewarded revive, once per run, `adDismissed` path handled
- [ ] Leaderboard submit only on personal best; leaderboard modal from menu
- [ ] `saveData`/`loadData` for PB, sound, control scheme
- [ ] Consent/GDPR path left to the SDK — do not add a second cookie banner
- [ ] Everything above tested against y8's staging IDs, not only in production

**Acceptance**
- [ ] A full run with sound on: 1 interstitial, 1 rewarded offer, score visible
      on the y8 leaderboard within a minute
- [ ] Ad failure (blocked network) never blocks or soft-locks gameplay
- [ ] Same zip runs with the SDK URL 404ing — the game must still boot

---

## Phase 6 — Storefront assets (≈ 1 evening)

- [ ] Replace all placeholder art; keep §2 silhouettes readable at 480 px
- [ ] y8 thumbnail 1280×720, no text overlay, in-game action visible
- [ ] Title + 2–3 sentence description + tags (arcade, shooter, 2D, one button)
- [ ] 3 extra screenshots, 1 vertical crop for the mobile shelf
- [ ] `assets/CREDITS.md` complete — every file has a licence line
- [ ] Nothing resembling another studio's IP in art, names, sound or text

**Acceptance**
- [ ] A stranger understands what the game is from the thumbnail alone
- [ ] `grep` over the project finds no TODO in art or copy

---

## Phase 7 — Submit to y8 (≈ 1 evening + review wait)

- [ ] Create the game in `developer.y8.com`, note App ID / Game ID
- [ ] Zip: `index.html` at the archive **root** (not inside a folder), wasm/js/pck
      beside it, no build junk, no `.git`
- [ ] Pre-submit checklist below
- [ ] Submit, then re-test on the y8 preview URL — portal hosting differs from
      `localhost` (headers, referrer, autoplay policy)
- [ ] Reply to reviewer feedback in the portal thread, not over chat

**Pre-submit checklist**
- [ ] Thread Support OFF; runs in Chrome, Firefox, Edge, Safari, Android Chrome
- [ ] No `console.log` spam, no external CDN calls except the y8 SDK
- [ ] Pointer-locked, fullscreen and download prompts unused
- [ ] Game pauses correctly when the tab is hidden; no audio leak
- [ ] Works with cookies blocked (offline guest mode)
- [ ] Loads in ≤ 8 s on throttled 4G; no black screen while loading
- [ ] Version + build date printed in the debug overlay only

---

## Phase 8 — After launch

- [ ] Watch y8 analytics weekly: play-time-per-session is the metric that moves
      revenue, not click-through
- [ ] Tune §7 curve from real death-wave distribution; PB-vs-average gap tells
      you whether the leaderboard is sketched by one player
- [ ] A/B the thumbnail monthly
- [ ] v1.1 candidates: endless "hard mode" board, daily seed, achievements
- [ ] v2 candidates: shop/meta progression, localisation via
      `getPlatformLocale()`, second game on the same pipeline

---

## Risks

| Risk | Mitigation |
|---|---|
| Threaded export white-screens on y8 | single-thread preset is the only preset; CI asserts it |
| 1.28 GB template download fails | `.tpz` cached in `.cache/`, extraction is resumable |
| wasm bundle too big for the portal | GL Compatibility + module trimming, budget gate in Phase 4 |
| iPhone Safari WebGL2 quirks | device test in Phase 2, keep shaders trivial |
| y8 review rejection on unclear licence | `assets/CREDITS.md` enforced from Phase 3 |
| Ads gate-loop a player | every ad callback has a timeout that resumes the game |
| Scope creep (Phase 3 is where projects die) | §10 out-of-scope list is binding; v2 only |

## Definition of done, project-wide

A stranger on y8 can start a run within 8 seconds of page open, understand the
goal without reading text, die wanting to retry, and see their score ranked —
at 60 fps, on a phone, with the ads paying.
