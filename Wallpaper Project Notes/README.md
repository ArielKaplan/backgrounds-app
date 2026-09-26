# Animated Pixel-Art Wallpapers — Project Notes for Claude

Hi Claude. This folder explains an ongoing project so you can pick it up in a new session.
Read this whole file before changing anything.

## What this project is

The user (Ariel) and Claude built a series of **animated, self-contained HTML wallpapers** for macOS.
Each one is a single `index.html` file (no external files, no network) that draws a living pixel-art
scene on a `<canvas>`, with ambient life, random events, and rare events.

They are shown as the desktop wallpaper with **Plash** (free Mac App Store app that displays a web page
as the wallpaper). Plash points at the local `index.html` file. After editing a file, the user reloads it
from Plash's menu bar icon.

The user's taste: charming, cozy, high-detail retro pixel art, lots of little stories and interactions,
"entertaining when I glance at the desktop", but light on CPU/battery. They like being able to test
events via URL options. They give direct feedback and expect it to be acted on; verify your work
before reporting it as done.

## Folder layout (all in ~/Pictures)

| Folder | File | What it is |
|---|---|---|
| `Wallpaper - Flow` | `index.html` | The first one: smooth WebGL flowing color ribbons (macOS Sonoma/Sequoia-style). Themes via `#sequoia`, `#sonoma`, `#dusk`, `#ocean`, `#aurora`, `#mono`; `#palette=ocean&speed=0.5`. |
| `Wallpaper - Space` | `index.html` (+ zip) | Retro pixel space: nebulae, rotating ringed planet, comets. Starship battles, chases, orbiting, fleets, asteroid physics, Borg-style cube; rare supernova, wormhole, black hole (gravity + lensing), space whale, armada. |
| `Wallpaper - Meadow` | `index.html` (+ zip) | Cute animals on a meadow: bunnies, prairie dogs in burrows, duck family on a pond, butterflies, bees, birds, hedgehogs, turtles. Duck parade, fox visit, windy apple drop, rain + frogs + rainbow, butterfly bloom, tortoise-and-hare race, nap time, bird murmuration; rare night + fireflies + owl, unicorn, UFO cow abduction, hot-air balloon cat, bison herd. |
| `Wallpaper - Dungeon` | `index.html` | Enter-the-Gungeon-style auto-playing dungeon crawler. Procedural grid of rooms, fog of war, hero AI (pathfinding, strafing, dodge-rolls, falls in pits, dies and respawns), weapons pickups, enemies, 5 bosses with patterns, floors with themes; rare mimic, merchant, rat thief, dog companion, gold chest. |
| `Wallpaper - Aquarium` | `index.html` | Side-view fish tank: schools (boids), clownfish + anemone, puffer, seahorse, crab, eel in rock, octopus in pot, jellies, decor. Feeding, eel ambush, puffer surprise, octopus prank, cleaning station, seahorse romance, pearl finder, treasure burst; rare shark, lights-out, sea turtle, toy submarine, whale. |
| `Wallpaper - Sheep` | `index.html` | Side-view pasture, inspired by the 90s "desktop sheep" (Screen Mate Poo / eSheep). A flock of cute, dumb sheep walk on ledges (cliff, boulder, haystack, fence, stump), fall off and tumble, sit dangling their legs, ride on each other's backs. Events: follow-the-leader off the cliff, sheep tower + sneeze, butterfly bonk, baa chorus (someone says MOO), sheepdog, nap pile + snore bubble, head stuck in hay, ball game, pronking, fainting frog gag; rare: fleece blown off, wolf in sheep's clothing, floating fluffy sheep, counting sheep over the fence at night, snow day with a sheep-collecting snowball. |
| `Wallpaper - Football` | `index.html` | Tecmo Bowl-style auto-playing football. Horizontal field with crowd, HUD scoreboard, refs. Two random made-up teams (16 in `TEAMS`), 4 quarters (`#quarter=` minutes), overtime, final + Gatorade bath, then a new game. Plays in `PLAYS` (dive, sweep, sneak, draw, slants, curls, outs, bomb, screen, flea flicker, reverse, halfback pass, hail mary, kneel) plus kickoffs/onside, punts/fake punts, field goals/PATs/two-point tries. AI: blocking engagements with shed timers, man coverage, QB reads by receiver openness, carrier picks the safest heading. Sideshows: animals on the field (dog/squirrel/goose/cat/pig with a security guard), penalties with flag + ref, injuries with a cart, TD celebrations, halftime marching band. Weather: rain, snow, fog, wind, night. Options `#teams=BAY-MTN #weather=snow #play=flea #event=animal|injury|penalty`. Built in marker-separated chunks (`// @@...@@` comments remain as section ends). |
| `Wallpaper - City` | `index.html` | The most complex: slow camera flyover (~10 min each way, then back) of a procedurally laid-out NYC-like grid. See the City section below. |
| (loose) | `Flowing Day.heic` | A time-of-day dynamic wallpaper made with Swift/ImageIO (8 frames + `apple_desktop:h24` metadata). Added via System Settings → Wallpaper → Add Photo → **From Files**. |

Zips (`Pixel Space Wallpaper.zip`, `Pixel Meadow Wallpaper.zip`) contain just that folder's `index.html`,
for moving to another computer. The user may ask for zips of the others.

## Shared conventions across the pixel wallpapers

- **One file, no dependencies.** Everything (sprites, fonts, sounds-none) is generated in code.
  Sprites are built procedurally with a small `SB` sprite-builder class (shaded ellipses/rects + auto outline)
  and baked to canvases.
- **Low internal resolution, CSS-scaled** with `image-rendering: pixelated`. Default ~200–270 rows of pixels.
- **30 FPS simulation cap** in a `requestAnimationFrame` loop; `dt` clamped.
- **Event system:** a `director` picks events on a cooldown. Events are **generator functions**
  (`function* name() { ... yield ... }`) — `yield` receives `dt` each frame. Helpers `wait(s)`, `until(fn, max)`.
  `COMMON` and `RARE` weight tables, ~14–15% rare chance, no repeating the same event twice in a row.
- **URL hash options** (every wallpaper): `#event=name` repeats one event (`#event=all` cycles), `#speed=3`
  runs time faster, `#debug` shows event name/counts, `#pixels=N` changes resolution. Some have extras
  (`#boss=`, `#floor=` in Dungeon; `#at=`, `#pan=`, `#time=` in City). The header comment at the top of each
  file lists that file's options and event names — keep it up to date when adding events.
- **Emotes/popups:** tiny pixel icons (heart, note, bang, q, z, sparkle/star…) float above characters.
- **Day/night** in several: a multiply overlay, then additive glow lights drawn afterwards.

## How to test changes (important — this is how the previous session verified work)

1. The in-app Browser pane **cannot open `file://` URLs**. Serve the folder instead. A launch config like:
   ```json
   { "version": "0.0.1", "configurations": [ { "name": "wallpaper", "runtimeExecutable": "python3",
     "runtimeArgs": ["-m", "http.server", "8765", "--directory", "/Users/arielkaplan/Pictures/Wallpaper - City"],
     "port": 8765 } ] }
   ```
   then open `http://localhost:8765/index.html`.
2. The preview pane is narrow and often hidden (rAF may be paused). For reliable checks, in the page's JS:
   override `innerWidth/innerHeight` to 1280×800 and call `resize()`; replace the live `update`/`render`
   with no-ops and drive the simulation manually (`realUpdate(1/30)` in a loop), then call render once and
   screenshot. Take a short wait before screenshots.
3. Headless checks that caught real bugs before: run every event start-to-finish and confirm no errors and
   that global state resets afterwards; run long simulated sessions (10–25 min) with the real director;
   measure render/update ms per frame; for City, count on-screen car disappearances, overlapping car pairs,
   red-light entries, and stuck/gridlocked cars.
4. Be honest in reports: say what was verified by numbers vs. by screenshot vs. not checked.

## Pitfalls already hit (don't repeat)

- **Top-level name clashes** break the whole file with a SyntaxError (e.g. a sprite function named `fox`
  clashing with an event `fox`; a new `SY` variable clashing with the City's `SY()` street function).
  Sprite builders are suffixed `...Spr`.
- `yield* x = null` style typos throw inside generators; the director catches errors and silently ends the event,
  so always check console/instrumented errors.
- In the Aquarium, a Swimmer brain yielding `'hold'` suppresses default steering; `'move'` keeps it.

## The City wallpaper in detail (most likely to get more work)

**Layout:** avenues (vertical, 3 one-way lanes, alternating direction) and streets (horizontal, 2 one-way
lanes) on a fixed grid (`AW, SW, BW, BH`, `AX(i)`, `SY(j)`, `blockX(c)`, `blockY(r)`). Districts by row:
uptown (brick brownstones, street trees), a big park (lake, rowboats, lawn picnics, ball fields, fountain,
path life, horse carriages), midtown with a neon plaza ("Neon Square") and billboards, downtown, financial
district. Rivers on both sides with piers, boats, gulls; a lit bridge on the east. Construction sites with cranes.
Area name fades in bottom-left.

**Camera:** Catmull-Rom route through waypoints (`ROUTE_PTS`), speed `cam.total / 600` px/s (~10 min per
direction) × `#pan`. The camera updates every display frame and the canvas is drawn 2px oversized and moved
with a sub-pixel CSS transform for smooth panning, while the sim/redraw runs at 30fps.

**Static vs dynamic:** ground (roads, sidewalks, crosswalks, park, water, ground shadows, trees) is baked into
256px chunks lazily. **Buildings are drawn dynamically in fake 3D**: each lot is a stack of 1px floor slices
(edge pixels carry windows/floor lines/awnings), offset by a constant three-quarter `TILT` plus a perspective
term `(dx, dy)/FOCAL` so faces shift as the camera pans; tiers/setbacks, water towers, spires, crowns, helipads.
Landmarks are in `LANDMARKS` (Empire-style, Chrysler-style, WTC-style, helipad tower). Each building is cached to
its own canvas and repainted only when its quantized perspective changes; caches are purged when far away.
Buildings, cars and pedestrians are drawn together sorted north→south (`drawCity`) so things tuck behind buildings.
Current perf while panning: ~3–5 ms/frame day, ~8 ms night.

**Traffic model:** per-lane car lists; signals with 19s cycle and 1.5s all-red; cars check the nearest crossing
ahead (sorted by travel direction — an earlier bug checked the far one and caused red-light running), only enter
the box if it's clear and there's exit room, look ahead for any car footprint (spatial hash `OCC`), turn only
from the edge lane on the turning side, merge toward that lane before dead ends (river edges, park), never change
lanes while stopped except to pass a held/double-parked vehicle. Avenues run off the map top/bottom (off-screen).
Cars never despawn on-screen. Density is intentionally modest.

**Pedestrians** walk sidewalk rings around blocks and cross on walk signals. **Events:** taxi hail, fire truck,
street performer, pigeons, delivery double-park, dog walker, ice cream truck, park frisbee, ferry docking,
helicopter; rare parade (closes an avenue, giant balloons), marathon, snow day (plow, snowman), police chase
with helicopter searchlight, fireworks. 24-minute day/night cycle with lit windows, streetlights, headlights.

**Open notes from the user's last feedback round:** pan speed was raised twice (now ~10 min per direction) —
they may still want faster. Buildings were made much more 3D; they may want further styling. Traffic realism
was the other focus. A remaining minor issue: cars can wait ~25s to turn near the park's southern edge at busy times.

## Getting started in a new session

1. Ask the user which wallpaper they want to work on (or what new one to make).
2. Read that wallpaper's `index.html` (they are large: 70–125 KB; read in chunks).
3. Make changes, then verify with the testing approach above before reporting.
4. For a **new** wallpaper, create `~/Pictures/Wallpaper - <Name>/index.html` following the shared conventions,
   with the same quality bar: ambient life, ~8–10 common events, ~5 rare events, interactions between characters,
   URL test options, and a header comment listing them.
