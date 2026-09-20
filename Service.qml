// Hover a window's top-right corner to reveal Windows-style
// minimize / move / close buttons.
//
// Derived from axel.window-close-buttons (MIT), which established the
// per-toplevel overlay approach: one layer-shell PanelWindow pinned to each
// window's top-right corner, revealed on hover. This extends that single
// close circle into a three-button row.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons

Item {
  id: service

  // Injected by omarchy-shell (the first-party service loader).
  property var shell: null

  // Apps that draw their own titlebar buttons (client-side decorations) would
  // otherwise get a second, redundant set stacked on top of their own.
  //
  // This has to be a class list: there is no way to detect CSD from here.
  // Hyprland's client JSON carries no decoration field, and xdgTag /
  // xdgDescription come back empty for every client on this machine.
  //
  // Override by creating ~/.config/omarchy/window-buttons.json:
  //   { "skipClasses": ["brave-browser", "org.gnome.*"] }
  // A "skipClasses" key REPLACES this list rather than extending it, so copy
  // what you want to keep. Matching is case-insensitive and "*" is a wildcard.
  readonly property var defaultSkipClasses: [
    // Chromium / Electron
    "brave-browser", "chromium", "google-chrome*", "vivaldi*", "microsoft-edge*",
    "slack", "discord", "code", "codium", "obsidian", "spotify", "signal",
    "notion*", "figma*", "postman",
    // Firefox family
    "firefox*", "zen*", "librewolf", "waterfox",
    // GTK / libadwaita
    "org.gnome.*", "gnome-*", "nautilus", "nemo", "thunar", "file-roller",
    "org.gtk.*", "gedit", "evince", "eog", "totem", "baobab", "seahorse",
    // KDE
    "org.kde.*"
  ]
  property var skipClasses: service.defaultSkipClasses

  FileView {
    path: Quickshell.env("HOME") + "/.config/omarchy/window-buttons.json"
    watchChanges: true
    // The config file is optional, so a missing one isn't worth a log line.
    printErrors: false
    onFileChanged: reload()
    onLoaded: service.applyConfig(text())
    // No config file is the normal case — fall back to the built-in list.
    onLoadFailed: service.skipClasses = service.defaultSkipClasses
  }

  function applyConfig(raw) {
    try {
      var cfg = JSON.parse(raw || "{}")
      service.skipClasses = Array.isArray(cfg.skipClasses)
        ? cfg.skipClasses : service.defaultSkipClasses
    } catch (e) {
      console.warn("window-buttons: window-buttons.json is not valid JSON; using defaults")
      service.skipClasses = service.defaultSkipClasses
    }
  }

  // Case-insensitive glob, "*" being the only metacharacter; everything else
  // is escaped so a class like "org.gnome.Nautilus" can't act as a regex.
  function classMatches(cls, pattern) {
    var c = String(cls || "").toLowerCase()
    var p = String(pattern || "").toLowerCase()
    if (!c || !p) return false
    if (p.indexOf("*") === -1) return c === p
    var parts = p.split("*")
    for (var i = 0; i < parts.length; i++) {
      parts[i] = parts[i].replace(/[.+?^${}()|[\]\\]/g, "\\$&")
    }
    return new RegExp("^" + parts.join(".*") + "$").test(c)
  }

  function isSkipped(cls) {
    var list = service.skipClasses || []
    for (var i = 0; i < list.length; i++) {
      if (service.classMatches(cls, list[i])) return true
    }
    return false
  }

  readonly property int btnSize: 22
  readonly property int btnGap: 4
  readonly property int rowPad: 5
  readonly property int rowW: 3 * service.btnSize + 2 * service.btnGap + 2 * service.rowPad
  readonly property int rowH: service.btnSize + 2 * service.rowPad
  // The row sits this far inside the window's top-right corner, matching how
  // a titlebar's buttons are inset from the frame edge.
  readonly property int inset: 6
  // The hit box overhangs the corner so the row is still reachable when the
  // window is flush against a screen edge, and extends left/down so the row
  // fades in slightly before the pointer reaches it.
  readonly property int overhang: 10
  readonly property int hitW: service.rowW + 70
  readonly property int hitH: service.rowH + 46

  // "general:border_size" is the theme's active-window border width — the
  // row's own outline is drawn at the same width for visual consistency.
  property int borderSize: 2

  Process {
    id: borderSizeProc
    command: ["hyprctl", "-j", "getoption", "general:border_size"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var json = JSON.parse(text || "{}")
          var n = Number(json.int)
          if (isFinite(n) && n >= 0) service.borderSize = n
        } catch (e) {
          // hyprctl missing / Hyprland not running — keep the previous value.
        }
      }
    }
  }

  Component.onCompleted: borderSizeProc.running = true

  // "hyprland.active-border" is the theme's own token for window-edge accent
  // colour; flatColor collapses a gradient string to its first stop, since a
  // single Rectangle can't render an angle. Both re-evaluate live on theme
  // switch because Color.shellValues is reassigned wholesale, not mutated.
  readonly property color accentColor: Color.flatColor(Color.pick("hyprland.active-border", Color.accent), Color.accent)
  readonly property color glyphColor: Color.flatColor(Color.pick("hyprland.active-border-foreground", Color.foreground), Color.foreground)
  // Close is the one destructive button here, so it gets its own hover tint
  // rather than the shared accent — same convention as a Windows titlebar.
  readonly property color closeColor: "#c42b1c"

  function mixColor(a, b, t) {
    return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1)
  }

  // HyprlandToplevel.address comes back as bare hex ("56538020a4f0"), unlike
  // lastIpcObject.address which is "0x"-prefixed — normalize before matching
  // or handing it to a dispatcher.
  function normalizedAddress(addr) {
    if (typeof addr !== "string") return null
    var hex = addr.indexOf("0x") === 0 ? addr.slice(2) : addr
    return /^[0-9a-fA-F]+$/.test(hex) ? "0x" + hex : null
  }

  // Omarchy's Hyprland build routes `dispatch <args>` through a Lua eval, so
  // the classic "closewindow address:0x.." string is not valid here —
  // dispatchers are Lua calls under hl.dsp.*. Hyprland.dispatch goes over the
  // shell's existing IPC socket rather than spawning hyprctl, which matters
  // for the move button: it fires on every drag update.
  //
  // Verified against this install (Hyprland 0.56.2):
  //   hl.dsp.window.close({ address = "0x.." })
  //   hl.dsp.window.move({ window = "address:0x..", workspace = "special:scratchpad", follow = false })
  //   hl.dsp.window.move({ window = "address:0x..", x = N, y = N })
  //   hl.dsp.window.float({ window = "address:0x..", action = "toggle" })
  // Note close takes "address" while the others take "window" — that
  // asymmetry is the dispatchers' own, not a typo.
  function closeWindow(addr) {
    var a = service.normalizedAddress(addr)
    if (!a) return
    Hyprland.dispatch('hl.dsp.window.close({ address = "' + a + '" })')
  }

  // Hyprland has no minimize. The scratchpad special workspace is the closest
  // equivalent and is already part of Omarchy's defaults, so SUPER+S (bound to
  // hl.dsp.workspace.toggle_special("scratchpad")) restores the window.
  function minimizeWindow(addr) {
    var a = service.normalizedAddress(addr)
    if (!a) return
    Hyprland.dispatch('hl.dsp.window.move({ window = "address:' + a + '", workspace = "special:scratchpad", follow = false })')
  }

  function floatWindow(addr) {
    var a = service.normalizedAddress(addr)
    if (!a) return
    Hyprland.dispatch('hl.dsp.window.float({ window = "address:' + a + '", action = "toggle" })')
  }

  function moveWindowTo(addr, x, y) {
    var a = service.normalizedAddress(addr)
    if (!a) return
    Hyprland.dispatch('hl.dsp.window.move({ window = "address:' + a + '", x = ' + Math.round(x) + ', y = ' + Math.round(y) + ' })')
  }

  // A fullscreen window ignores pixel moves outright, so a drag has to leave
  // fullscreen first — the same thing dragging a maximized window does on
  // Windows.
  function exitFullscreen(addr) {
    var a = service.normalizedAddress(addr)
    if (!a) return
    Hyprland.dispatch('hl.dsp.window.fullscreen({ window = "address:' + a + '" })')
  }

  // Crossing outputs needs an explicit handoff. A bare pixel move into another
  // monitor's area leaves the window on its old monitor's workspace, drawn
  // outside that monitor's viewport, i.e. invisible.
  function setWindowMonitor(addr, name) {
    var a = service.normalizedAddress(addr)
    if (!a || !name) return
    Hyprland.dispatch('hl.dsp.window.move({ window = "address:' + a + '", monitor = "' + name + '" })')
  }

  function screenAt(x, y) {
    var ss = Quickshell.screens
    for (var i = 0; i < ss.length; i++) {
      var sc = ss[i]
      if (x >= sc.x && x < sc.x + sc.width && y >= sc.y && y < sc.y + sc.height) return sc
    }
    return null
  }

  function screenForMonitor(monitor) {
    if (!monitor || !monitor.name) return null
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (screens[i].name === monitor.name) return screens[i]
    }
    return null
  }

  // Quickshell's Hyprland module keeps toplevel geometry current from IPC
  // events, but Hyprland has no discrete "resize finished" event to key a
  // refresh off of, so a light poll keeps the row glued to its window through
  // an edge-drag resize. This is an IPC round-trip, not a subprocess spawn.
  // Deliberately keeps running through a drag. An earlier version stood this
  // down via a shared counter, but a delegate destroyed mid-drag (which a
  // cross-monitor move can cause) never ran its decrement, so the counter
  // stuck above zero and the poll never resumed. lastIpcObject only updates
  // from this refresh, so every overlay then froze at stale coordinates —
  // which looked like the buttons vanishing after dragging to another
  // monitor. The poll cannot disturb a drag anyway: margins are frozen for
  // its duration.
  Timer {
    interval: 400
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: Hyprland.refreshToplevels()
  }

  Variants {
    model: Hyprland.toplevels.values

    PanelWindow {
      id: cornerWindow
      required property var modelData

      readonly property var info: modelData ? modelData.lastIpcObject : null
      readonly property var targetScreen: service.screenForMonitor(modelData ? modelData.monitor : null)
      // Pinned windows stay on screen across a workspace switch even though
      // their own workspace is no longer the active one.
      readonly property bool onActiveWorkspace: modelData !== null && modelData.workspace !== null
        && (modelData.workspace.active === true || (info !== null && info.pinned === true))
      // info's "at"/"size" arrive as QVariantList, which marshals into QML as
      // an array-like object (indexable, has .length) rather than a real JS
      // Array, so Array.isArray() on it is always false — check shape instead.
      // !! because the `info.at &&` links yield undefined (not false) when a
      // toplevel has no geometry yet, and undefined won't assign to a bool.
      readonly property string winClass: info ? String(info.class || info.initialClass || "") : ""
      readonly property bool skipped: service.isSkipped(winClass)
      readonly property bool showable: !!(!skipped && onActiveWorkspace
        && info !== null && info.mapped !== false && info.hidden !== true
        && info.at && info.at.length === 2 && info.size && info.size.length === 2
        && targetScreen !== null)
      readonly property bool isActiveWindow: modelData !== null && Hyprland.activeToplevel !== null
        && Hyprland.activeToplevel.address === modelData.address



      // Pressing a button and dragging off before releasing leaves
      // HoverHandler.hovered stuck at its pre-drag value — Qt only
      // re-evaluates hover on the next real pointer move, not on release — so
      // the row would otherwise stay visible until the mouse moves again.
      property bool forceHidden: false

      readonly property int liveLeft: showable
        ? Math.round(info.at[0] + info.size[0] - targetScreen.x + service.overhang - service.hitW) : 0
      readonly property int liveTop: showable
        ? Math.round(info.at[1] - targetScreen.y - service.overhang) : 0

      // While the move button is dragging, the overlay must stop tracking the
      // window: it is the thing moving the window, and following it would feed
      // each move back into the next translation and send the window skidding.
      property bool moving: false
      property int frozenLeft: 0
      property int frozenTop: 0
      property var frozenScreen: null
      // Name of the monitor the window was last handed to, so the handoff
      // fires once per crossing rather than on every tick.
      property string lastMonitorName: ""
      // Guards the settle retries below from looping if a window refuses to
      // float (some windows are not floatable).
      property int settlePass: 0

      // Pinned for the duration of a drag: a layer surface belongs to one
      // output, so letting this follow the window across monitors would
      // destroy and recreate the surface mid-drag and drop the pointer grab.
      screen: (moving && frozenScreen) ? frozenScreen : targetScreen
      visible: showable
      color: "transparent"

      WlrLayershell.namespace: "omarchy-window-buttons"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      implicitWidth: service.hitW
      implicitHeight: service.hitH

      anchors { left: true; top: true }
      // Frozen outright while dragging, and the row is hidden to match.
      // Binding these to the live translation meant one layer-surface
      // reconfigure per pointer event — at a 1000Hz mouse that is a thousand
      // compositor round-trips a second, which is what made dragging crawl.
      // The window itself still moves at 60Hz; that is the feedback.
      margins.left: moving ? frozenLeft : liveLeft
      margins.top: moving ? frozenTop : liveTop

      // --- move drag state -------------------------------------------------
      // Window position when the drag began, and the handler translation at
      // that same moment. Target is always origin + (translation - base), so a
      // late origin capture (see settleTimer) doesn't jump the window.
      property real originX: 0
      property real originY: 0
      property real baseTx: 0
      property real baseTy: 0
      property real lastTx: 0
      property real lastTy: 0
      property bool originReady: false

      function captureOrigin() {
        if (!info || !info.at || info.at.length !== 2) return
        originX = info.at[0]
        originY = info.at[1]
        baseTx = lastTx
        baseTy = lastTy
        // Seeded with the current monitor so the first tick doesn't fire a
        // pointless handoff, which would visibly jerk the window at grab time.
        lastMonitorName = (modelData && modelData.monitor && modelData.monitor.name)
          ? modelData.monitor.name : ""
        originReady = true
      }

      function beginMove() {
        if (!modelData || !info) return
        moving = true
        frozenScreen = targetScreen
        frozenLeft = liveLeft
        frozenTop = liveTop
        lastTx = 0
        lastTy = 0
        originReady = false
        settlePass = 0
        // Both of these change geometry asynchronously, so the origin is read
        // after a settle rather than from the stale rect. afterSettle() also
        // re-checks floating, which covers a fullscreen window that drops back
        // to tiled when it exits.
        if (info.fullscreen) {
          service.exitFullscreen(modelData.address)
          settleTimer.restart()
        } else if (info.floating === false) {
          settlePass = 1
          service.floatWindow(modelData.address)
          settleTimer.restart()
        } else {
          captureOrigin()
        }
      }

      function afterSettle() {
        if (!moving || !modelData || !info) return
        if (info.floating === false && settlePass < 2) {
          settlePass += 1
          service.floatWindow(modelData.address)
          settleTimer.restart()
          return
        }
        captureOrigin()
      }

      function updateMove(tx, ty) {
        lastTx = tx
        lastTy = ty
        if (!moving || !originReady) return
        pendingX = originX + (tx - baseTx)
        pendingY = originY + (ty - baseTy)
        pendingDirty = true
      }

      function endMove() {
        if (!moving) return
        moving = false
        originReady = false
        settleTimer.stop()
        if (pendingDirty) moveTick.flush()
      }

      property real pendingX: 0
      property real pendingY: 0
      property bool pendingDirty: false

      Timer {
        id: settleTimer
        interval: 120
        repeat: false
        onTriggered: {
          Hyprland.refreshToplevels()
          cornerWindow.afterSettle()
        }
      }

      // Coalesce drag updates: pointer moves arrive faster than Hyprland needs
      // to be told about them, and one dispatch per pixel is wasted IPC.
      Timer {
        id: moveTick
        interval: 16
        repeat: true
        running: cornerWindow.moving
        function flush() {
          if (!cornerWindow.pendingDirty || !cornerWindow.modelData) return
          cornerWindow.pendingDirty = false
          var addr = cornerWindow.modelData.address
          // The monitor is decided from the dragged window's top-right corner,
          // because that is where the grabbed button (and so the pointer) is.
          var w = (cornerWindow.info && cornerWindow.info.size && cornerWindow.info.size.length === 2)
            ? cornerWindow.info.size[0] : 0
          var sc = service.screenAt(cornerWindow.pendingX + w, cornerWindow.pendingY)
          if (sc && sc.name !== cornerWindow.lastMonitorName) {
            cornerWindow.lastMonitorName = sc.name
            service.setWindowMonitor(addr, sc.name)
          }
          service.moveWindowTo(addr, cornerWindow.pendingX, cornerWindow.pendingY)
        }
        onTriggered: flush()
      }

      // Safety net for the state that hides the row entirely. `moving` drives
      // the row's opacity, so if a drag ever ends without onActiveChanged
      // firing, the buttons would stay invisible for that window forever.
      Timer {
        interval: 500
        repeat: true
        running: cornerWindow.moving
        onTriggered: if (!moveDrag.active) cornerWindow.endMove()
      }

      HoverHandler {
        id: hover
        onHoveredChanged: if (hovered) cornerWindow.forceHidden = false
      }

      Rectangle {
        id: row
        // Right-aligned and top-aligned inside the window's corner, with the
        // hit box's own overhang backed out so `inset` is measured from the
        // real window edge.
        x: parent.width - service.overhang - service.inset - width
        y: service.overhang + service.inset
        width: service.rowW
        height: service.rowH
        radius: Math.round(height / 3)
        color: Color.background
        border.color: cornerWindow.isActiveWindow ? service.accentColor : Color.muted
        border.width: service.borderSize

        // Hidden while dragging: the overlay is frozen in place, so leaving it
        // visible would strand the row where the drag began.
        opacity: (!cornerWindow.moving && hover.hovered && !cornerWindow.forceHidden) ? 1 : 0
        scale: (!cornerWindow.moving && hover.hovered) ? 1 : 0.7
        transformOrigin: Item.TopRight

        Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }
        Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }

        Row {
          anchors.centerIn: parent
          spacing: service.btnGap

          // --- minimize ---
          Rectangle {
            width: service.btnSize
            height: service.btnSize
            radius: 3
            color: minTap.pressed
              ? service.mixColor(service.accentColor, Color.background, 0.4)
              : (minHover.hovered ? service.mixColor(service.accentColor, Color.background, 0.7) : "transparent")
            Behavior on color { ColorAnimation { duration: 80 } }

            HoverHandler { id: minHover; cursorShape: Qt.PointingHandCursor }
            TapHandler {
              id: minTap
              acceptedButtons: Qt.LeftButton
              gesturePolicy: TapHandler.ReleaseWithinBounds
              onTapped: service.minimizeWindow(cornerWindow.modelData.address)
            }

            // Glyphs are drawn rather than set as text so they render
            // identically regardless of which font `omarchy font set` picked.
            Rectangle {
              anchors.centerIn: parent
              width: Math.round(parent.width * 0.45)
              height: Math.max(1, service.borderSize - 1)
              color: service.glyphColor
            }
          }

          // --- move ---
          Rectangle {
            id: moveBtn
            width: service.btnSize
            height: service.btnSize
            radius: 3
            color: moveHover.hovered
              ? service.mixColor(service.accentColor, Color.background, 0.7) : "transparent"
            Behavior on color { ColorAnimation { duration: 80 } }

            HoverHandler { id: moveHover; cursorShape: Qt.SizeAllCursor }
            DragHandler {
              id: moveDrag
              // target: null keeps the handler from moving the button itself —
              // it only reports translation, and the window is what moves.
              target: null
              acceptedButtons: Qt.LeftButton
              onActiveChanged: {
                if (active) cornerWindow.beginMove()
                else {
                  cornerWindow.endMove()
                  cornerWindow.forceHidden = !moveHover.hovered
                }
              }
              onTranslationChanged: cornerWindow.updateMove(translation.x, translation.y)
            }

            // Four-way move arrow, drawn as two bars plus four arrowheads.
            Item {
              id: moveGlyph
              anchors.centerIn: parent
              width: Math.round(parent.width * 0.62)
              height: width
              readonly property int bar: Math.max(1, service.borderSize - 1)
              readonly property int head: Math.max(3, Math.round(width * 0.26))

              Rectangle {
                anchors.centerIn: parent
                width: parent.width
                height: moveGlyph.bar
                color: service.glyphColor
              }
              Rectangle {
                anchors.centerIn: parent
                width: moveGlyph.bar
                height: parent.height
                color: service.glyphColor
              }
              Repeater {
                model: [0, 90, 180, 270]
                Item {
                  anchors.fill: parent
                  rotation: modelData
                  Canvas {
                    anchors.fill: parent
                    onPaint: {
                      var ctx = getContext("2d")
                      ctx.reset()
                      var w = width, h = moveGlyph.head
                      ctx.fillStyle = service.glyphColor
                      ctx.beginPath()
                      ctx.moveTo(w / 2, 0)
                      ctx.lineTo(w / 2 - h / 2, h)
                      ctx.lineTo(w / 2 + h / 2, h)
                      ctx.closePath()
                      ctx.fill()
                    }
                  }
                }
              }
            }
          }

          // --- close ---
          Rectangle {
            width: service.btnSize
            height: service.btnSize
            radius: 3
            color: closeTap.pressed
              ? Qt.darker(service.closeColor, 1.3)
              : (closeHover.hovered ? service.closeColor : "transparent")
            Behavior on color { ColorAnimation { duration: 80 } }

            HoverHandler { id: closeHover; cursorShape: Qt.PointingHandCursor }
            TapHandler {
              id: closeTap
              acceptedButtons: Qt.LeftButton
              // Close on release, and only if the release still lands on the
              // button — pressing down then dragging off shouldn't close.
              gesturePolicy: TapHandler.ReleaseWithinBounds
              onTapped: service.closeWindow(cornerWindow.modelData.address)
            }

            Item {
              anchors.centerIn: parent
              width: Math.round(parent.width * 0.42)
              height: width
              Rectangle {
                anchors.centerIn: parent
                width: parent.width * 1.414
                height: Math.max(1, service.borderSize - 1)
                rotation: 45
                color: closeHover.hovered ? "#ffffff" : service.glyphColor
              }
              Rectangle {
                anchors.centerIn: parent
                width: parent.width * 1.414
                height: Math.max(1, service.borderSize - 1)
                rotation: -45
                color: closeHover.hovered ? "#ffffff" : service.glyphColor
              }
            }
          }
        }
      }
    }
  }
}
