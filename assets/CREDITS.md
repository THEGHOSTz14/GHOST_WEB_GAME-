# Asset credits and licences

Every file in this project must appear here with a licence line. y8 reviewers
ask, and "we think it was free" is not an answer.

## Drone artwork

| File | Source | Licence | Notes |
|---|---|---|---|
| `assets/drone/drone_body.png` | Generated artwork supplied by the developer in the project chat on 2026-10-24 | Developer-owned | Keyed, trimmed and downscaled by `tools/prep_drone_art.py`; the baked-in transparency checkerboard is removed |
| `assets/drone/drone_prop.png` | Same, second image | Developer-owned | Two-blade prop drawn as a separate sprite so it can spin |

No third-party asset packs, fonts or audio are currently in the build. Everything
else — the ground, river, roads, trees, rocks, houses, cars, animals, bots and
the HUD — is drawn in code or uses Godot's built-in default font, so it carries
no external licence.

## Audio

Nothing yet. Phase 3 requires CC0 or self-made audio with a row added here per
file before submission.

## Engine

Godot 4.7.2 stable (MIT). Export templates from the official release, fetched by
`tools/fetch_web_templates.py`. The y8 SDK is loaded at runtime from
`https://cdn.y8.com/minimal-sdk/2-0/y8.min.js` and is not redistributed.
