# muon-pdf Implementation Spec

## 1. Goal and scope

`muon-pdf` is a lightweight GTK4 + MuPDF PDF viewer written in Zig.

Current implementation covers:
- open file from `argv[1]`
- open file/fullscreen/rotate/quit from menu button UI
- auto-fit and centered rendering
- zoom in/out with bounded zoom range
- pan controls for zoomed pages
- tap/click and swipe page navigation
- keyboard pan/page/zoom/quit controls
- persisted state per file (`page`, `zoom`, `pan_x`, `pan_y`)
- overlay controls with dim/active behavior
- boundary feedback toast for blocked page/pan actions
- bottom-left page indicator overlay (`current/total`)

## 2. High-level architecture

Core source file:
- `src/main.zig`

Main subsystems:
- **App state**: `AppState` struct stores GTK widgets, MuPDF handles, runtime view state, and persistence paths.
- **Document lifecycle**: open/drop document, page count, page selection.
- **Render pipeline**: fit-scale computation + MuPDF rasterization + GTK texture upload.
- **Input handling**: tap, swipe, keyboard, and button callbacks.
- **Persistence**: JSON state load/save in cache keyed by hash of absolute file path.
- **Resize adaptation**: viewport size change detection with periodic polling.

## 3. Build and packaging

Files:
- `build.zig`
- `Makefile`

Build properties:
- default optimize mode: `ReleaseSmall`
- strip enabled
- links to system GTK4 and MuPDF
- `Makefile` defaults to dynamic linking (`STATIC=false`)
- multi-arch target switch in Makefile:
  - `ARCH=native`
  - `ARCH=amd64` (`x86_64-linux-musl`)
  - `ARCH=aarch64` (`aarch64-linux-musl`)

Why dynamic by default:
- static GTK4 stack is usually unavailable in distro setups
- dynamic build is the practical and reliable default on this environment

## 4. App startup flow

Entry:
- `main()` creates allocator, parses args, and starts `GtkApplication`.

Activation:
- `onActivate()` builds UI, then:
  - if `argv[1]` exists: attempts `openDocumentAtPath()`
  - if no arg: does not auto-open dialog; waits for user menu `☰` -> `Open`

## 5. UI structure (overlay design)

Top-level:
- `GtkApplicationWindow`
- `GtkOverlay` as window child
- `GtkScrolledWindow` as base overlay child
- `GtkPicture` inside scroller for rendered page texture

Overlay controls:
- top-left: menu button `☰` with `Open`, `Fullscreen`, `Rotate`, `Quit`
- top-right: zoom `-` and `+`
- bottom-right: directional 2x2-style arrow cluster
- bottom-left: page indicator label (`current/total`)
- bottom-center: short feedback toast (`First page`, `Last page`, `Edge reached`)

Directional buttons:
- all labels use `<`
- direction indicated via CSS rotation classes:
  - `.arrow-left`, `.arrow-right`, `.arrow-up`, `.arrow-down`
- each direction button fixed size request `36x36`

Opacity behavior:
- `.overlay-control` default opacity `0.3`
- hover/active or `controls-active` class makes control fully opaque
- each button interaction only affects that specific button
- button interactions keep that button in `controls-active` state for 500ms
- if no document is loaded, menu button remains active/opaque
- edge-disabled pan buttons are non-interactive and do not receive hover brightening

Overlay visibility rules:
- zoom buttons hidden when no document is loaded
- pan buttons are edge-aware:
  - left/right buttons enabled only when movement in that direction is possible
  - up/down buttons enabled only when movement in that direction is possible
  - disabled arrows stay in place to preserve grid layout
- page indicator hidden when no document is loaded

## 6. Rendering pipeline

Render entry:
- `queueRender()` -> `renderCurrentPage()`

Process:
1. Compute viewport fit via `computeFitScale()` from current scroller dimensions.
2. Compute effective scale: `fit_scale * zoom`.
3. Rasterize page through MuPDF:
   - `fz_new_pixmap_from_page_number(...)`
4. Convert pixmap to GTK texture:
   - `g_bytes_new(...)`
   - `gdk_memory_texture_new(...)`
5. Set texture on `GtkPicture`.
6. Update title and pan visibility.
7. Clamp/apply pan adjustments.

Centering:
- picture widget aligned center (`halign/valign CENTER`)
- scroller provides clipping and viewport behavior

## 7. Resize handling strategy

Goal:
- refit page on viewport size changes and keep zoom ratio relative to new fit.

Implementation:
- size notifications are connected, but wlroots/labwc behavior can be inconsistent
- robust path uses polling:
  - `g_timeout_add(350, onViewportPoll, state)`
  - compares current scroller width/height with last seen dimensions
  - on change, triggers `queueRender()`

State fields:
- `last_view_w`
- `last_view_h`

## 8. Input behavior

Tap/click:
- left 40%: previous page
- right 40%: next page
- double tap/double click: toggle fullscreen
- corner exclusion zones (`20% x 20%` on all four corners): ignore tap/click page turn

Swipe:
- swipe is implemented with touch drag detection (`GtkGestureDrag`) instead of native scroller drag
- touch drag is claimed early to disable touch panning and prefer swipe-to-page behavior
- page turn requires threshold + dominant-direction check
- left swipe -> next page
- right swipe -> previous page
- up swipe -> next page (natural scroll)
- down swipe -> previous page (natural scroll)
- a short post-swipe tap suppression window prevents a trailing tap from double-triggering page turns

Keyboard:
- `Left` -> pan left (2% viewport)
- `Right` -> pan right (2% viewport)
- `Up` -> pan up (2% viewport)
- `Down` -> pan down (2% viewport)
- `h/j/k/l` -> pan left/down/up/right
- `Space` -> next page
- `Shift+Space` -> previous page
- `>` or `.` -> next page
- `<` or `,` -> previous page
- `+`/`=` -> zoom in
- `-`/`_` -> zoom out
- `q` -> quit application
- `f`/`F11` -> toggle fullscreen
- `r`/`R` -> rotate 90° clockwise

Buttons:
- Menu `Open` -> file chooser
- Menu `Fullscreen` -> toggle fullscreen
- Menu `Rotate` -> rotate 90° clockwise
- Menu `Quit` -> quit app
- Zoom +/- -> adjust zoom and rerender
- Pan arrows -> move by 2% of viewport per press

## 9. Zoom and pan rules

Zoom:
- step: `0.05` (5%)
- range: `0.5` to `2.5` (50% to 250%)

Rotate:
- rotate action applies +90° clockwise per trigger
- rotation cycles in 4 steps and returns to normal orientation

Pan:
- applied via scrolled window adjustments
- stored as `pan_x`, `pan_y`
- clamped to valid adjustment ranges each render
- left/right pan buttons enabled only when not at horizontal edge
- up/down pan buttons enabled only when not at vertical edge

## 10. Document and state persistence

Cache directory:
- `~/.cache/muon-pdf/`

Cache key:
- SHA-256 hash of absolute PDF path
- file name: `<hash>.json`

Persisted schema:
- `page_index`
- `zoom`
- `pan_x`
- `pan_y`
- `rotate_turns` (`0..3`)

Load:
- on document open, state is loaded (if present), clamped to valid ranges/pages.

Save:
- on page changes
- on zoom/pan changes
- on close/deinit

## 11. Error handling

Common behavior:
- failures in open/render paths surface via GTK message dialog (`showErrorDialog`)
- deferred rendering retries when viewport is not ready (`g_idle_add` path)
- blocked actions show short overlay feedback text:
  - `First page`
  - `Last page`
  - `Edge reached`

Known environmental noise:
- portal warnings from desktop/session integration (e.g., Inhibit portal mismatch) do not necessarily indicate app failure.

## 12. Key runtime constants

- `MinZoom = 0.5`
- `MaxZoom = 2.5`
- `ZoomStep = 0.05`
- pan step: `2%` viewport per button press
- per-button controls active timeout: `500ms`
- page navigation cooldown: `135ms`
- viewport poll interval: `350ms`
- swipe-drag claim threshold (disable touch drag-panning): `6px`
- swipe page-turn trigger threshold: `220px`
- swipe dominant-axis ratio: `1.25`
- post-swipe tap suppression window: `160ms`

## 13. Current trade-offs

- Polling-based resize detection is used for robustness on compositor behavior (e.g. labwc).
- Dynamic linking is default for practical compatibility with distro GTK4 installations.
- Implementation is intentionally single-file (`main.zig`) for simplicity; further modularization is possible if feature surface grows.
