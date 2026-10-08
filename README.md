# Toons — Tern plugin

Cartoons of what the agent is doing, drawn natively in Tern while commands
run. A port of [claude-toons](https://github.com/achimala/claude-toons)
(MIT, © 2026 Anshu Chimala) from Claude Code's Ink renderer to Tern's
native UI: no terminal escape hacks for layout, no model calls, no cost.

## Install

```sh
tern plugin install github.com/you/tern-toons   # or:
tern plugin link /path/to/toons-tern            # while developing
```

Every window gets a cartoon tab when it starts. Reopen one with the
palette command "Toons: open the cartoon block" (`ctrl+alt+shift+h`), or
drag a `toons.cartoon` block into a layout.

## What you see

A block that animates a cartoon of the current agent phase — testing,
building, searching, editing, git, debugging, and so on. The phase comes
from the host hooks `command_started` / `command_finished`: the command
line is classified by keyword, a scene is picked from a library of 138
hand-authored scenes, and the block redraws at 10 fps while anything is
busy. A failed command switches the phase to `debugging`.

The window half adds that palette command and a status-line segment
(`▶ testing clawd runs the tests…`). The cartoon blocks publish the phase
through `tern.kv`; windows only read it, so the 50 ms window budget never
touches the scene engine.

## Keys (block focused)

| Key | Action |
| --- | --- |
| `n` | Next cartoon for this phase |
| `l` | Walk the whole 138-scene library |
| `s` | Style: color → pixel → ascii |
| `z` | Size: small → medium → large |
| `p` / `r` | Pause / resume |
| `q` | Close the block |

Style, size, fps and pause persist across restarts through the block's
`save` state.

Each block also writes its current frame to `data/latest.txt` in the plugin
data directory (header line `phase: key: concept style`, then the ANSI
frame). That is the debug surface: `tern plugin reload`, run a command,
then read the file to see exactly what the running block is drawing.

## How it is built

| File | Role |
| --- | --- |
| `host.luau` | Hooks, keyword→phase classify, scene pick, animation timer, block definition |
| `window.luau` | Palette command, auto-open on window start, status segment |
| `lib/scenes.luau` | The 138 scenes as data (each scene is a small program in the scene language) |
| `lib/engine.luau` | Interpreter for that language (port of claude-toons' `script.ts`) |
| `lib/scene.luau` | Scene API globals: `put`, `pixel`, `text`, `clawd`, `mesh3d`, … |
| `lib/engine` consumers | `raster.luau` (cell canvas + ANSI encode), `color.luau`, `clawd.luau` (the mascot), `render3d.luau` (software 3D), `palette.luau` (sizes/colors) |

Scenes run inside `pcall`; a scene that breaks shows `scene broke: …`
instead of taking the block down.

## Development

```sh
cd tools
bun bundle.ts host_check.luau host_run.luau color raster clawd render3d engine scene scenes palette host
luau.exe host_run.luau        # ALL CHECKS PASSED (24 checks)
bun bundle.ts render_check.luau render_run.luau color raster clawd render3d engine scene scenes
luau.exe render_run.luau      # rendered 138 scenes x 6 frames, 0 failures
luau-analyze.exe ../lib/*.luau   # 0 errors (host/window load inside Tern)
cd ..
tern plugin link . && tern plugin reload   # ready, or the first error line
tern capture toons.cartoon --ansi          # the frame a running block drew
```

`tools/bundle.ts` flattens the plugin into one chunk so the stock Luau CLI
(which has no `require`) can run the checks; the driver's mock `tern` is
passed to the host half as a parameter. `tools/luau.exe` and
`tools/luau-analyze.exe` are the Luau CLI binaries used for those checks.
`tern.d.luau` at the package root is the real definition file (`tern plugin
types .` writes it); this Luau CLI build cannot parse its `declare extern
type … with` syntax, so it type-checks only the `lib/` modules, which use
no Tern API.
