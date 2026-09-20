# Window Buttons

Windows-style **minimize / move / close** buttons in every window's top-right
corner. Hover the corner and the row fades in.

Derived from [axel.window-close-buttons](https://github.com/axelfontaine/omarchy-window-close-buttons)
(MIT), which established the per-toplevel hover-corner overlay; this extends
its single close circle into a three-button row.

Requires [Omarchy](https://omarchy.org). Tested on Omarchy 4.0.4 /
Hyprland 0.56.2.

## Install

```bash
omarchy plugin add https://github.com/nichovski/omarchy-window-buttons.git --enable
```

## Uninstall

```bash
omarchy plugin remove nichovski.window-buttons
```

## Buttons

| Button | Action |
|--------|--------|
| **─** Minimize | Sends the window to the `scratchpad` special workspace. Press `SUPER + S` to bring it back. |
| **✥** Move | Press and drag. The window follows the pointer, across monitors. A tiled window is floated first, and a fullscreen one leaves fullscreen, since neither has a free position. |
| **✕** Close | Closes the window. |

## Why minimize works the way it does

Hyprland has no minimize. The `scratchpad` special workspace is the closest
equivalent, and it's already part of Omarchy's defaults — `SUPER + S` is bound
to `hl.dsp.workspace.toggle_special("scratchpad")`, so restore works with no
extra configuration. A minimized window is not lost, just parked.

Note that the scratchpad is shared: minimizing several windows parks them all
in the same place, and `SUPER + S` reveals that workspace rather than one
specific window.

## Apps that already have their own buttons

Browsers, Electron apps and GTK/libadwaita apps draw their own titlebar
buttons (client-side decorations). Stacking a second set on top of those is
just clutter, so those windows are skipped and keep using their own controls.

This has to be a class list. There is no way to detect CSD from a shell
plugin: Hyprland's client JSON carries no decoration field, and `xdgTag` /
`xdgDescription` are empty for every client. The built-in list covers the
Chromium/Electron, Firefox, GTK and KDE families — see `defaultSkipClasses`
at the top of `Service.qml`.

### Changing the list

Create `~/.config/omarchy/window-buttons.json`:

```json
{ "skipClasses": ["brave-browser", "org.gnome.*", "slack"] }
```

It is watched, so edits apply immediately — no restart. Matching is
case-insensitive and `*` is a wildcard.

**`skipClasses` replaces the built-in list, it does not extend it.** To add one
app while keeping the defaults, copy `defaultSkipClasses` out of `Service.qml`
and append to it. To get the buttons on *every* window, use `[]`. Deleting the
file or writing invalid JSON falls back to the built-in defaults.

To find a window's class, focus it and run:

```bash
hyprctl activewindow -j | jq -r .class
```

## Implementation notes

One layer-shell `PanelWindow` is pinned to each toplevel's top-right corner,
revealed on hover. Actions go through `Hyprland.dispatch` over the shell's
existing IPC socket rather than spawning `hyprctl`, which matters for the move
button — it dispatches on every drag update (coalesced to ~60/s).

Omarchy's Hyprland build routes dispatches through a Lua eval, so the classic
`closewindow address:0x..` string form does not apply. Verified against
Hyprland 0.56.2:

```lua
hl.dsp.window.close({ address = "0x.." })
hl.dsp.window.move({ window = "address:0x..", workspace = "special:scratchpad", follow = false })
hl.dsp.window.move({ window = "address:0x..", x = N, y = N })
hl.dsp.window.float({ window = "address:0x..", action = "toggle" })
```

`close` takes `address` while the others take `window` — that asymmetry is the
dispatchers' own.

While a drag is in progress the overlay is frozen and the button row is
hidden, and only the window moves. An earlier version bound the overlay's
margins to the live drag translation, which cost one layer-surface
reconfigure per pointer event — on a 1000Hz mouse that is a thousand
compositor round-trips a second, and dragging crawled. The window position is
dispatched on a 16ms tick instead, and the geometry poll stands down for the
duration of a drag.

Two cases the compositor will not do on its own:

- **Fullscreen.** `hl.dsp.window.move({ x, y })` is silently ignored on a
  fullscreen window, so a drag exits fullscreen first and re-reads the
  geometry after it settles. If the window drops back to tiled it is then
  floated, which is why the settle runs in two passes.
- **Crossing monitors.** A bare pixel move into another monitor's area leaves
  the window on its old monitor's *workspace*, drawn outside that monitor's
  viewport — visible nowhere. Crossing an output boundary therefore dispatches
  `monitor = "<name>"` once, which reassigns the workspace too.

The geometry poll deliberately keeps running through a drag. An earlier
version stood it down via a counter shared across overlays, but a delegate
destroyed mid-drag — which a cross-monitor move can cause — never ran its
decrement, so the counter stuck above zero and the poll never resumed.
`lastIpcObject` only updates from that refresh, so every overlay then froze at
stale coordinates, which looked like the buttons disappearing after dragging
to another monitor. The poll cannot disturb a drag anyway, because margins are
frozen for its duration.

The overlay's `screen` is pinned for the duration of a drag. A layer surface
belongs to a single output, so letting it follow the window across monitors
would destroy and recreate the surface mid-drag and drop the pointer grab.

`hl.dsp.window.drag()` — Hyprland's own interactive move, bound to
`SUPER + LMB` — is deliberately not used: it needs a physically held mouse
button and is a no-op when dispatched over IPC.

## Developing this plugin

**Editing `Service.qml` does nothing until you run `omarchy restart shell`.**

Omarchy's generic plugin docs say saved changes under
`~/.config/omarchy/plugins/` reload automatically. That is true for bar
widgets, but not for `kind: "service"` plugins like this one. From
`shell.qml`'s `_syncServices()`:

```js
} else {
  // A kept instance outlives the rescan; hand it the fresh manifest.
  var kept = _services[id]
  ...
  continue
}
```

The running service instance outlives the rescan and is only handed a fresh
manifest, so new QML is never instantiated. The `Local plugin changed,
reloading` line in the log refers to the registry rescan, not to your service,
which makes it look like the edit applied when it did not.

Two related traps:

- Heavy file churn inside the plugin directory — a `git` checkout or commit,
  for example — can momentarily make the registry treat the plugin as removed
  and drop the service, leaving no buttons until a restart.
- Restarting twice in quick succession can race: the second instance prints
  `An instance of this configuration is already running` and exits, then the
  first exits on the IPC request, leaving nothing running and no bar. Run
  `omarchy restart shell` once more to recover.

## Tuning

Sizes are at the top of `Service.qml`: `btnSize`, `btnGap`, `rowPad`, `inset`
(distance from the window corner) and `overhang` (hover slop). Colors follow
the active theme via the `hyprland.active-border` token; close uses its own
red, matching a Windows titlebar.

## Conflicts

Don't enable this alongside `axel.window-close-buttons` — both draw in the
same corner.

## Credits

Built on [axel.window-close-buttons](https://github.com/axelfontaine/omarchy-window-close-buttons)
by Axel Fontaine, which established the per-toplevel hover-corner overlay that
this extends.

## License

MIT — see [LICENSE](LICENSE) and [NOTICE](NOTICE). The upstream copyright
notice is retained.
