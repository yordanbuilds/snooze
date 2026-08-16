import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Snooze in the bar: one glyph, the time left beside it while a snooze runs,
// and a dot on the icon while the helper still needs setting up. Left click
// opens the panel.
Panel {
  id: root
  moduleName: "yordanbuilds.snooze"
  ipcTarget: "yordanbuilds.snooze"
  // The base Panel owns this target when manageIpc is true, and snooze needs
  // `refresh` and `status` on the same one — `snooze` itself pokes the widget
  // with `omarchy-shell -q yordanbuilds.snooze refresh` after every change.
  manageIpc: false

  readonly property string glyph: "󰒲"
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical === true : false
  readonly property bool needsSetup: service.setupState !== "ok"
  // A vertical bar has no room beside the glyph, so it stays icon-only there.
  readonly property bool showRemaining: setting("showRemaining", true) === true
    && service.enabled && !vertical && service.remainingLabel !== ""
  readonly property string barText: showRemaining ? glyph + " " + service.remainingLabel : glyph

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    service.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: service
  }

  Connections {
    target: service
    // The panel grows a place for this in the next task; until then a failed
    // verb should at least be findable in the shell log.
    function onActionFailed(message) { console.warn("snooze:", message) }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { service.refresh(); return "ok" }
    function status(): string { return service.tooltip }
  }

  TextMetrics {
    id: barMetrics
    font.family: button.fontFamily
    font.pixelSize: button.fontSize
    text: root.barText
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    tooltipText: service.tooltip
    // The icon slot is cut for a single glyph. Widen it by exactly what the
    // countdown adds, so the bar stays tight whenever nothing is running.
    slotSize: root.showRemaining
      ? Math.max(Style.bar.iconSlot, Math.round(barMetrics.width) + Style.space(10))
      : Style.bar.iconSlot

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) service.refresh()
      else root.toggle()
    }

    // Needs-setup mark, pinned to the top-right of the painted text so it
    // tracks the glyph rather than the slot the countdown asks for.
    Rectangle {
      visible: root.needsSetup
      width: Math.max(4, Style.space(5))
      height: width
      radius: width / 2
      color: Color.accent
      x: Math.round(button.width / 2 + button.glyphPaintedWidth / 2 - width / 2)
      y: Math.round(button.height / 2 - Style.bar.iconCanvas / 2)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        PanelHero {
          title: "Snooze"
          meta: service.tooltip
          foreground: root.foreground
          fontFamily: root.fontFamily
        }
      }
    }
  }
}
