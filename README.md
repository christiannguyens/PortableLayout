# PortableDash

A native macOS dashboard for your portable monitor: Messages, Claude and Spotify in one
window, with draggable dividers, themes and decor.

## Build & run

```sh
./build.sh            # builds build/PortableDash.app
open build/PortableDash.app
./build.sh install    # optional: copies it to ~/Applications
```

## App icon

```sh
./make_icon.sh              # the built-in design (Tools/draw_icon.swift)
./make_icon.sh my-pic.png   # or any square image of your own
./build.sh
```

The menu bar icon (top right) has Show/Hide, Privacy Mode, Lock Layout, Fill/Move Display,
Customize and Quit.

## One-time permissions

| Panel    | What macOS asks for | Why |
|----------|--------------------|-----|
| Messages | **Full Disk Access** (System Settings → Privacy & Security) — add PortableDash, then relaunch | message history lives in `~/Library/Messages/chat.db` |
| Messages | Contacts | show names instead of phone numbers |
| Messages / Spotify | Automation prompts ("control Messages / Spotify") | sending replies, play/pause/skip |
| Claude   | none — just sign in once; it stays logged in | |
| Header   | Calendars | next event; add Google under System Settings → Internet Accounts so its events sync to the Mac |

Note: the app is ad-hoc signed, so after a **rebuild** macOS may forget Full Disk Access.
If Messages asks again, remove PortableDash from the Full Disk Access list and re-add it.

## Using it

- **+** in the header adds a panel: quick picks (YouTube, Canvas, Calendar, Notion, Discord…),
  any URL, or a hidden panel. Each panel's ⋯ menu has Edit / Hide / Remove.
- **Photo gallery** (also under **+**): a slideshow of a folder or of photos you pick. Folders are
  rescanned every few minutes, so new photos join the rotation. For Google Drive, install
  [Google Drive for desktop](https://www.google.com/drive/download/) and pick a folder from it.
  ⋯ → Edit sets the interval (3 sec – 1 hour), transition (fade / slide / zoom / Ken Burns),
  fill vs. whole photo, and shuffle. Hover the photo for previous / pause / next.
- Drag the gaps between panels to resize; double-click a gap to reset it.
- ⚙︎ (top-right) or ⌘, opens Customize: layouts, panel order, themes, accent color,
  wallpaper, ambient effects (orbs / stars / aurora), glass/frosted/solid panels, stickers.
- `⌃⌥⌘D` show/hide from anywhere · `⇧⌘P` privacy mode (blurs Messages & Claude until you
  hover — good for the library) · `⇧⌘L` lock layout · `⇧⌘M` move to next display.
- Plug the monitor in and the dashboard jumps to it automatically. Rotate it (portrait) and the
  dashboard refills the screen and switches to its portrait layout; portrait and landscape each
  remember their own layout and divider sizes. Narrow screens get a two-row header.

## Files

`Sources/` — `main.swift` (window, menus, hotkey), `Dashboard.swift` (header, panels, decor),
`Layout.swift` (split layout + dividers), `Customize.swift`, `AddPanel.swift` (+ button),
`Messages.swift`, `Spotify.swift`, `Web.swift` (Claude and every web panel), `Photos.swift` (photo galleries). `PortableLayout.swift` is the old window-snapping script, left untouched.
