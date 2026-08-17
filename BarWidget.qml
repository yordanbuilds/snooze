import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Commons
import qs.Ui

// Snooze in the bar: one glyph, the time left beside it while a snooze runs,
// and a dot on the icon while the helper still needs setting up. Left click
// opens the panel, which is one of three views — setup, idle (pick groups and
// a duration), or active (what is blocked, and how to end it).
Panel {
  id: root
  moduleName: "yordanbuilds.snooze"
  ipcTarget: "yordanbuilds.snooze"
  // The base Panel owns this target when manageIpc is true, and snooze needs
  // `refresh` and `status` on the same one — `snooze` itself pokes the widget
  // with `omarchy-shell -q yordanbuilds.snooze refresh` after every change.
  manageIpc: false

  readonly property string glyph: "󱅻"
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical === true : false
  readonly property bool needsSetup: service.setupState !== "ok"
  // A vertical bar has no room beside the glyph, so it stays icon-only there.
  readonly property bool showRemaining: setting("showRemaining", true) === true
    && service.enabled && !vertical && service.remainingLabel !== ""
  readonly property string barText: showRemaining ? glyph + " " + service.remainingLabel : glyph

  // ---- panel state ---------------------------------------------------------

  // Groups that will take part in the next session. Every group is in it the
  // first time groups.json loads; after that the choice survives a reload, and
  // a group that appears later joins by default (see syncSelection).
  property var selectedIds: []
  property var _knownIds: []
  // Minutes for the next session; 0 is the CLI's "until I stop it".
  property int durationMinutes: 60
  property bool stopConfirmOpen: false
  // The edit view takes the place of the idle and active views. It is reachable
  // from both: a session is a snapshot, so edits land on the next one.
  property bool editing: false
  readonly property bool deleteConfirmOpen: editView.pendingDeleteId !== ""
  // Last failure from the CLI, shown for a few seconds under the hero.
  property string actionMessage: ""

  readonly property bool showSetup: service.setupState !== "ok"
  readonly property bool showIdle: service.setupState === "ok" && !service.enabled
  readonly property bool showActive: service.setupState === "ok" && service.enabled

  readonly property var groups: service.groupsDoc && service.groupsDoc.groups instanceof Array
    ? service.groupsDoc.groups
    : []
  readonly property string blockedNames: root.namesFor(service.sessionGroups)
  readonly property string stateLine: {
    if (service.setupState !== "ok") return "Needs a one-time setup"
    if (!service.enabled) return "Nothing snoozed"
    return service.until === 0 ? "Until you stop it" : service.remainingLabel + " left"
  }
  readonly property string setupLine: service.setupState === "outdated"
    ? "The helper is older than the plugin — run setup again."
    : "Snooze needs a small root helper to edit /etc/hosts."
  readonly property var durations: [
    { "label": "30m", "minutes": 30 },
    { "label": "1h", "minutes": 60 },
    { "label": "2h", "minutes": 120 },
    { "label": "4h", "minutes": 240 },
    { "label": "∞", "minutes": 0 }
  ]

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (!opened) {
      // Never leave a confirm hanging over a panel nobody is looking at, and
      // open the next time on the view the panel is actually about.
      root.stopConfirmOpen = false
      root.editing = false
      return
    }
    service.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Whichever way the edit view is entered or left, it starts clean and the
  // keyboard goes back to the panel — a text field must not keep it.
  onEditingChanged: {
    editView.reset()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Keep the selection honest across a groups.json reload: drop ids that are
  // gone, keep the ones the user picked, and opt new groups in — a group added
  // while the panel is open should not be silently left out of the session.
  function syncSelection() {
    var ids = []
    for (var i = 0; i < root.groups.length; i++) ids.push(String(root.groups[i].id))
    var next = []
    for (var j = 0; j < ids.length; j++) {
      var isNew = root._knownIds.indexOf(ids[j]) < 0
      if (isNew || root.selectedIds.indexOf(ids[j]) >= 0) next.push(ids[j])
    }
    root.selectedIds = next
    root._knownIds = ids
  }

  function toggleGroup(id) {
    var wanted = String(id)
    var next = []
    var found = false
    for (var i = 0; i < root.selectedIds.length; i++) {
      if (root.selectedIds[i] === wanted) { found = true; continue }
      next.push(root.selectedIds[i])
    }
    if (!found) next.push(wanted)
    root.selectedIds = next
  }

  function nameFor(id) {
    var wanted = String(id)
    for (var i = 0; i < root.groups.length; i++) {
      if (String(root.groups[i].id) !== wanted) continue
      var name = String(root.groups[i].name || "")
      return name !== "" ? name : wanted
    }
    // A session can outlive the group it was started from — show the id rather
    // than nothing at all.
    return wanted
  }

  function namesFor(ids) {
    var list = ids instanceof Array ? ids : []
    var out = []
    for (var i = 0; i < list.length; i++) out.push(root.nameFor(list[i]))
    return out.join(", ")
  }

  function stepDuration(dx) {
    var index = 0
    for (var i = 0; i < root.durations.length; i++) {
      if (root.durations[i].minutes === root.durationMinutes) index = i
    }
    index = Math.max(0, Math.min(root.durations.length - 1, index + (dx > 0 ? 1 : -1)))
    root.durationMinutes = root.durations[index].minutes
  }

  // Enter/Space runs the view's one obvious action. The active view has none:
  // between "+30 min" and "Stop" there is no obvious answer, and Stop is behind
  // a confirm on purpose.
  function activatePrimary() {
    // The edit view is all typing and small buttons; there is nothing here for
    // Enter to mean, and starting a session from it would be a surprise.
    if (root.editing) return
    if (root.showSetup) { root.runSetup(); return }
    if (root.showIdle && root.selectedIds.length > 0) service.start(root.selectedIds, root.durationMinutes)
  }

  function runSetup() {
    service.openSetupTerminal()
    // Setup happens in a terminal that takes the focus; leaving the panel open
    // behind it just parks a stale view on screen.
    root.close()
  }

  Service {
    id: service
  }

  Connections {
    target: service
    function onActionFailed(message) {
      // The bar has nowhere to show this, so it stays in the log too — the
      // caption below is gone four seconds later.
      console.warn("snooze:", message)
      root.actionMessage = message
      actionMessageTimer.restart()
    }
    function onGroupsDocChanged() { root.syncSelection() }
  }

  Timer {
    id: actionMessageTimer
    interval: 4000
    repeat: false
    onTriggered: root.actionMessage = ""
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
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // A focused text field owns every key, including the ones this catcher
      // would otherwise read as commands ("j", "x", Space).
      blocked: root.editing && editView.editorFocused
      // The confirm is modal for the keyboard as well as the mouse: while it is
      // up every key it understands is answered by it, not by the panel.
      onCloseRequested: {
        if (root.stopConfirmOpen) stopConfirm.canceled()
        else if (root.deleteConfirmOpen) deleteConfirm.canceled()
        // Escape backs out of editing before it closes the panel — the same
        // step the hero's back button takes.
        else if (root.editing) root.editing = false
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (root.stopConfirmOpen) {
          if (dx !== 0) stopConfirm.selectedIndex = stopConfirm.selectedIndex === 0 ? 1 : 0
          return
        }
        if (root.deleteConfirmOpen) {
          if (dx !== 0) deleteConfirm.selectedIndex = deleteConfirm.selectedIndex === 0 ? 1 : 0
          return
        }
        if (dx !== 0 && root.showIdle && !root.editing) root.stepDuration(dx)
      }
      onActivateRequested: {
        if (root.stopConfirmOpen) {
          if (stopConfirm.selectedIndex === 0) stopConfirm.canceled()
          else stopConfirm.confirmed()
          return
        }
        if (root.deleteConfirmOpen) {
          if (deleteConfirm.selectedIndex === 0) deleteConfirm.canceled()
          else deleteConfirm.confirmed()
          return
        }
        root.activatePrimary()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          // A hairline inside the Flickable's clip edge, not flush with it. A
          // control paints its border on its own boundary, and the panel card
          // can land on half a device pixel (a 1.25x output scale puts it
          // there every fourth logical pixel); the scissor rect snaps to whole
          // device pixels and then eats a border sitting exactly on the edge —
          // "+30 min" lost its left one that way. Everything in here shifts
          // together, so the column still reads as one flush edge.
          x: Style.spacing.hairline
          width: panelFlick.width - Style.spacing.hairline * 2
          spacing: Style.space(12)

          // The hero's trailing control resolves `root` to PanelHero, not to
          // this panel, so the edit toggle reaches panel state through `header`.
          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight

            readonly property bool editing: root.editing
            // Nothing to edit before setup has written a groups file.
            readonly property bool canEdit: !root.showSetup

            function toggleEditing() { root.editing = !root.editing }

            PanelHero {
              id: hero
              title: "Snooze"
              meta: root.stateLine
              foreground: root.foreground
              fontFamily: root.fontFamily

              trailingControl: Component {
                PanelActionButton {
                  visible: header.canEdit
                  iconText: header.editing ? "󰌍" : "󰏫"
                  tooltipText: header.editing ? "Back" : "Edit groups and sites"
                  foreground: hero.foreground
                  fontFamily: hero.fontFamily
                  onClicked: header.toggleEditing()
                }
              }
            }
          }

          // Whatever the CLI said when a verb failed, wherever it was raised —
          // start, stop and extend all land here.
          Text {
            visible: root.actionMessage !== ""
            width: parent.width
            text: root.actionMessage
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // ---- setup view --------------------------------------------------

          Column {
            visible: root.showSetup
            width: parent.width
            spacing: Style.space(10)

            Text {
              width: parent.width
              text: root.setupLine
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Button {
              width: parent.width
              text: "Run setup"
              bordered: true
              foreground: Color.accent
              fontFamily: root.fontFamily
              onClicked: root.runSetup()
            }
          }

          // ---- idle view ---------------------------------------------------

          Column {
            visible: root.showIdle && !root.editing
            width: parent.width
            spacing: Style.space(8)

            Text {
              visible: root.groups.length === 0
              width: parent.width
              text: "No groups to snooze — check ~/.config/snooze/groups.json."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: root.groups

              Toggle {
                required property var modelData

                readonly property int siteCount: modelData.sites instanceof Array ? modelData.sites.length : 0

                width: parent.width
                label: (modelData.icon ? String(modelData.icon) + "  " : "") + String(modelData.name)
                description: siteCount === 1 ? "1 site" : siteCount + " sites"
                checked: root.selectedIds.indexOf(String(modelData.id)) >= 0
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.toggleGroup(modelData.id)
              }
            }

            Item { width: parent.width; height: Style.space(2) }

            // Five equal slots — the whole duration vocabulary at a glance,
            // with the chosen one carrying the accent.
            Row {
              id: durationRow
              width: parent.width
              spacing: Style.space(6)

              readonly property int slot: Math.floor(
                (width - spacing * (root.durations.length - 1)) / root.durations.length)

              Repeater {
                model: root.durations

                // Painted here rather than through Ui.Button's `selected`
                // state: that state is a theme token (often a plain grey), and
                // the chosen duration has to read as the accent it is.
                BorderSurface {
                  id: durationButton
                  required property var modelData

                  readonly property bool chosen: root.durationMinutes === modelData.minutes

                  width: durationRow.slot
                  implicitHeight: Style.spacing.controlHeight
                  radius: Style.cornerRadius
                  color: durationMouse.containsMouse && !chosen
                    ? Style.hoverFillFor(root.foreground, Color.accent)
                    : "transparent"
                  borderSpec: Border.flat(
                    chosen ? Color.accent : Util.alpha(root.foreground, 0.38),
                    Math.max(1, Style.normalBorderWidth))

                  Behavior on color { ColorAnimation { duration: 100 } }

                  Text {
                    anchors.centerIn: parent
                    text: String(durationButton.modelData.label)
                    color: durationButton.chosen ? Color.accent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: durationButton.chosen
                  }

                  MouseArea {
                    id: durationMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.durationMinutes = durationButton.modelData.minutes
                  }
                }
              }
            }

            Item { width: parent.width; height: Style.space(2) }

            Button {
              width: parent.width
              text: "Snooze"
              bordered: true
              enabled: root.selectedIds.length > 0
              foreground: enabled ? Color.accent : Qt.darker(root.foreground, 2.0)
              fontFamily: root.fontFamily
              onClicked: service.start(root.selectedIds, root.durationMinutes)
            }
          }

          // ---- active view -------------------------------------------------

          Column {
            visible: root.showActive && !root.editing
            width: parent.width
            spacing: Style.space(10)

            Text {
              width: parent.width
              text: service.remainingLabel
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              font.bold: true
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              visible: root.blockedNames !== ""
              width: parent.width
              text: "Blocking " + root.blockedNames
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              horizontalAlignment: Text.AlignHCenter
            }

            // Closes the status half of the view: above it is what is blocked
            // and for how long, below it what can be done about that.
            PanelSeparator {
              foreground: root.foreground
            }

            Text {
              width: parent.width
              text: "Snooze is friction, not a wall — anything can be unblocked."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              // Centered like the countdown and the caption above it: one axis
              // down the middle of everything the rule closes off.
              horizontalAlignment: Text.AlignHCenter
            }

            Row {
              id: activeActions
              width: parent.width
              spacing: Style.space(10)

              // A Row gives an invisible child no space, so Stop takes the
              // whole width once there is no deadline left to push out.
              readonly property int slot: extendButton.visible
                ? Math.floor((width - spacing) / 2)
                : width

              Button {
                id: extendButton
                // Nothing to extend when the session runs until it is stopped.
                visible: service.until !== 0
                width: activeActions.slot
                text: "+30 min"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: service.extend(30)
              }

              Button {
                width: activeActions.slot
                text: "Stop"
                bordered: true
                foreground: root.urgent
                fontFamily: root.fontFamily
                onClicked: root.stopConfirmOpen = true
              }
            }
          }

          // ---- edit view ---------------------------------------------------

          EditView {
            id: editView
            visible: root.editing && !root.showSetup
            width: parent.width
            service: service
            foreground: root.foreground
            urgent: root.urgent
            fontFamily: root.fontFamily
            // Escape out of a field gives the keyboard back to the panel, so
            // the next Escape can leave the view.
            onEscaped: keyCatcher.forceActiveFocus()
          }
        }
      }

      // Stopping early is allowed, but never on one click.
      ConfirmDialog {
        id: stopConfirm
        anchors.fill: parent
        z: 10
        opened: root.stopConfirmOpen
        message: "Stop snoozing early?"
        confirmText: "Stop"
        background: Color.popups.background
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.stopConfirmOpen = false
        onConfirmed: {
          root.stopConfirmOpen = false
          service.stop()
        }
      }

      // Deleting a group takes its sites with it, and the file is the only copy
      // — so it asks. The dialog lives here rather than in the edit view so it
      // covers the whole panel, however far down the list the group sits.
      ConfirmDialog {
        id: deleteConfirm
        anchors.fill: parent
        z: 10
        opened: root.deleteConfirmOpen
        message: "Delete group and its sites?"
        confirmText: "Delete"
        background: Color.popups.background
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: editView.cancelDelete()
        onConfirmed: editView.confirmDelete()
      }
    }
  }
}
