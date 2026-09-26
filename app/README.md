# Backgrounds

A small app that shows the HTML wallpapers in this repository as your desktop background, on **macOS**
(like Plash) and on **Windows** (no Wallpaper Engine). The wallpapers stay plain HTML files you can edit;
only the thin native wrapper differs per platform.

```
Wallpaper - */index.html   the wallpapers (unchanged, plus a settings block — see below)
app/shared/settings.html   the Settings window, shared by both apps
app/mac/                   macOS wrapper (Swift + WKWebView)          → Backgrounds.app
app/windows/               Windows wrapper (C# .NET 4.8 + WebView2)   → Backgrounds.exe
app/tests/                 settings/wallpaper tests + CI smoke tests
```

## Getting the apps

Every push builds both apps on GitHub Actions (**Actions → Build apps → the latest run → Artifacts**):
`Backgrounds-mac` and `Backgrounds-windows`. Or build them yourself (below).

### macOS (13 Ventura or newer, Apple silicon or Intel)

1. Unzip `Backgrounds-mac.zip`, move **Backgrounds.app** to Applications.
2. The app isn't signed with an Apple Developer ID, so the first time: open it, click **Done** on the
   warning, then **System Settings → Privacy & Security → Open Anyway**. (macOS 14 and older: right-click the
   app → **Open**.) After that it opens normally.
3. A picture icon appears in the menu bar; Settings opens on the first launch.

If you were using Plash, quit it (or remove its website) so the two don't draw on top of each other.

### Windows (10 or 11)

1. Unzip `Backgrounds-windows.zip` somewhere permanent, for example `C:\Users\<you>\Apps\Backgrounds`.
2. Run **Backgrounds.exe**. SmartScreen may warn about an unknown publisher: **More info → Run anyway**.
3. The icon appears in the tray (it may be under the **^** overflow arrow; drag it onto the taskbar to keep it
   visible). Left-click it for Settings, right-click for the menu. Running the exe again also opens Settings.

It needs the Microsoft Edge WebView2 Runtime, which Windows 11 and up-to-date Windows 10 already have
(the app offers the download link if it's missing).

## Using it

- **Menu bar / tray menu:** pick a wallpaper, Pause/Resume, Reload, Settings, Open wallpapers folder, Quit.
- **Settings → Wallpapers:** choose a wallpaper and adjust its options (sliders, menus, switches). Changes
  show on the desktop straight away. **Reset to defaults** clears them. Options for testing
  (repeat an event, time speed, debug) are under *Testing options*.
- **Settings → General:**
  - *Show wallpapers on:* all screens (same wallpaper), each screen separately, or the main screen only.
  - *Start at login*, *Pause when covered* (stops animating while a maximized/full-screen window hides it),
    *Pause on battery* (freezes on the last frame while unplugged). Pause also happens while the screen is
    locked. macOS additionally throttles any wallpaper it knows is hidden.
  - *Wallpapers folder* (default **Pictures/Backgrounds**): open it, change it, restore the built-in
    wallpapers, reload.

## Adding and editing wallpapers

On first launch the built-in wallpapers are copied to **Pictures/Backgrounds** — one folder per wallpaper,
each with an `index.html`. Edit them there (or drop a new folder/`.html` file in), then **Reload wallpapers**.
The app never overwrites your copies; *Restore built-in wallpapers* only adds missing ones.

A wallpaper is any page that fills the window. Options are read from the URL hash, e.g. `#pixels=200&hud=off`
(`new URLSearchParams(location.hash.slice(1))`). To give a wallpaper a proper settings panel, add a block
like this to its `<head>`:

```html
<script type="application/json" id="wallpaper-settings">
{
 "name": "Aquarium",
 "description": "A cozy retro fish tank.",
 "params": [
  {"key": "pixels", "label": "Pixel size", "type": "range", "min": 100, "max": 400, "step": 10, "default": 240},
  {"key": "theme", "label": "Theme", "type": "select", "default": "", "options": [["", "Random"], ["warm", "Warm"]]},
  {"key": "home", "label": "Home", "type": "text", "default": "", "placeholder": "lat,lon"},
  {"key": "offline", "label": "Offline mode", "type": "toggle", "default": false},
  {"key": "event", "label": "Repeat one event", "type": "select", "group": "testing", "default": "", "options": [["", "Off"], ["shark", "shark"]]}
 ]
}
</script>
```

Types: `range` (slider), `number`, `select`, `toggle` (adds a bare `#key`), `text`, `time` (`HH:MM`), and
`action` (a button that reloads the page once with `#key`, e.g. the Ant Farm's "Start a new colony").
`"group": "testing"` puts an option under *Testing options*. Only values that differ from `default` are
written into the hash, so *Reset to defaults* simply clears them. Without a block, the settings panel falls
back to the `#key=value   description` lines of the page's header comment.

## Building

- **macOS:** `app/mac/build.sh` (needs only the Xcode command line tools: `xcode-select --install`).
  Output: `app/mac/build/Backgrounds.app` and `Backgrounds-mac.zip`.
- **Windows:** `app/windows/build.ps1` (needs the .NET SDK). Output: `app/windows/build/Backgrounds/` and
  `Backgrounds-windows.zip`. The project also compiles with `dotnet build` on macOS/Linux.
- **Tests:** `node app/tests/settings.test.mjs` and `node app/tests/wallpapers.test.mjs` (need Playwright).
- The version is in `app/VERSION`; the icon is drawn by `app/icons/make_icons.py`.

## How it works

- **macOS:** one borderless, click-through window per screen at the desktop window level (below the Finder's
  icons), on all Spaces, with a `WKWebView` loading `file:///…/index.html#options`. Settings are in
  `~/Library/Application Support/Backgrounds/config.json`.
- **Windows:** one window per screen attached behind the desktop icons using Explorer's WorkerW layer (the
  technique Lively Wallpaper uses, including Windows 11 24H2's "raised desktop", where the window is a layered
  child of Progman under the icons). Pages are served from the wallpapers folder at
  `https://wallpapers.backgrounds.example/` inside WebView2 (not a real site: WebView2 maps it to the folder).
  A 1-second watchdog re-attaches the wallpaper if Explorer restarts. Settings are in
  `%APPDATA%\Backgrounds\config.json`, a log in `%LOCALAPPDATA%\Backgrounds\log.txt`.
- **Settings window:** `app/shared/settings.html` in the platform's web view; it talks to the native side with
  small JSON messages (`getState`, `setSettings`, `chooseFolder`, …) and owns the settings format.
