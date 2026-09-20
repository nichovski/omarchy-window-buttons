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
| **✥** Move | Press and drag. The window follows the pointer. A tiled window is floated first, since a tiled window has no free position. |
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

While a drag is in progress the overlay rides the drag translation instead of
tracking the window's reported geometry. Tracking would feed each move back
into the next translation and send the window skidding; simply freezing would
leave the button row behind as the window slid away.

`hl.dsp.window.drag()` — Hyprland's own interactive move, bound to
`SUPER + LMB` — is deliberately not used: it needs a physically held mouse
button and is a no-op when dispatched over IPC.

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

MIT — see [LICENSE](LICENSE). Retains the upstream copyright notice.
