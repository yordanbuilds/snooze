import QtQuick
import Quickshell
import Quickshell.Io
import "Model.mjs" as Model

// The widget's whole view of snooze, and the only place it shells out.
// `snooze status --json` never escalates and is cheap, so this polls it; every
// state-changing verb leaves through one queued action process, which keeps a
// double-click from racing two blocks against each other. Nothing here runs
// sudo — the CLI owns that, behind `snooze setup`.
Item {
  id: root

  // The plugin can be loaded from anywhere (a symlinked checkout, say), but
  // the CLI the user set up is the one at the installed plugin path.
  readonly property string cliPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/yordanbuilds.snooze/bin/snooze"
  readonly property string groupsDir: Quickshell.env("HOME") + "/.config/snooze"
  readonly property string groupsPath: groupsDir + "/groups.json"

  // ---- status, straight from `snooze status --json` ------------------------
  property bool statusLoaded: false
  property string setupState: "missing" // "ok" | "missing" | "outdated"
  // `final` because Item already has an `enabled`: this one is snooze's state,
  // deliberately shadowing a property no invisible service item ever uses.
  final property bool enabled: false
  property int until: 0                 // epoch seconds; 0 means indefinite
  property int remainingSeconds: -1     // -1 stands in for the CLI's null
  property var sessionGroups: []
  property string tooltip: "Snooze"
  // Parsed ~/.config/snooze/groups.json, or null when it is missing or unusable.
  property var groupsDoc: null

  readonly property string remainingLabel: enabled ? (until === 0 ? "∞" : Model.formatRemaining(remainingSeconds)) : ""
  readonly property bool busy: statusProc.running || actionProc.running

  // Whatever the CLI printed on stderr when a verb failed. The panel decides
  // how to show it; the bar only logs it.
  signal actionFailed(string message)

  property bool _refreshQueued: false
  // Set the moment the expiry sweep goes out, so a block that expired but
  // could not be removed does not sweep once a second forever.
  property bool _expired: false
  property var _actionQueue: []
  property var _pendingGroups: null

  function refresh() {
    // A running Process ignores a new command, so a poll that lands mid-probe
    // would be dropped silently. Remember it and run it on the way out.
    if (statusProc.running) {
      root._refreshQueued = true
      return
    }
    root._refreshQueued = false
    statusProc.command = [root.cliPath, "status", "--json"]
    statusProc.running = true
    if (!pollWatchdog.running) pollWatchdog.start()
  }

  function applyStatus(raw) {
    var parsed = null
    try {
      parsed = JSON.parse(String(raw || ""))
    } catch (e) {
      parsed = null
    }
    if (!parsed || typeof parsed !== "object") {
      applyUnavailable("Snooze — status unreadable")
      return
    }

    root.setupState = parsed.setup === "ok" || parsed.setup === "outdated" ? String(parsed.setup) : "missing"
    root.enabled = parsed.enabled === true
    root.until = Math.max(0, Math.floor(Number(parsed.until) || 0))
    root.remainingSeconds = parsed.remaining === null || parsed.remaining === undefined
      ? -1
      : Math.max(0, Math.floor(Number(parsed.remaining) || 0))
    root.sessionGroups = parsed.groups instanceof Array ? parsed.groups : []
    root.tooltip = typeof parsed.tooltip === "string" && parsed.tooltip !== "" ? parsed.tooltip : "Snooze"
    // Re-arm the expiry sweep only once there is time left to run down again.
    if (root.remainingSeconds > 0) root._expired = false
    root.statusLoaded = true
  }

  function applyUnavailable(message) {
    // A CLI that cannot even report its status is, as far as the UI goes, not
    // set up — which is exactly where the user needs to end up either way.
    root.setupState = "missing"
    root.enabled = false
    root.until = 0
    root.remainingSeconds = -1
    root.sessionGroups = []
    root.tooltip = message || "Snooze — status unavailable"
    root.statusLoaded = true
  }

  // The block outlived its timer — a suspend, a wake unit that never fired, or
  // a shell that was not running at the deadline. Removing it is the CLI's job;
  // the poll right after picks up whatever it managed to do.
  function sweepAndRefresh() {
    root._expired = true
    Quickshell.execDetached([root.cliPath, "sweep"])
    delayedRefresh.restart()
  }

  function runAction(argv) {
    if (actionProc.running) {
      var queued = root._actionQueue.slice()
      queued.push(argv)
      root._actionQueue = queued
      return
    }
    actionProc.command = argv
    actionProc.running = true
  }

  // minutes === 0 means "until I stop it"; an empty groupIds lets the CLI
  // decide, which is every group it knows about.
  function start(groupIds, minutes) {
    var argv = [root.cliPath, "start"]
    var ids = groupIds instanceof Array ? groupIds : []
    for (var i = 0; i < ids.length; i++) {
      argv.push("--group")
      argv.push(String(ids[i]))
    }
    var m = Math.max(0, Math.round(Number(minutes) || 0))
    if (m === 0) argv.push("--forever")
    else {
      argv.push("--for")
      argv.push(m + "m")
    }
    runAction(argv)
  }

  function stop() {
    runAction([root.cliPath, "stop"])
  }

  function extend(minutes) {
    var m = Math.max(0, Math.round(Number(minutes) || 0))
    if (m === 0) return
    runAction([root.cliPath, "extend", m + "m"])
  }

  function applyGroups(raw) {
    var parsed = null
    try {
      parsed = JSON.parse(String(raw || ""))
    } catch (e) {
      parsed = null
    }
    root.groupsDoc = Model.validateGroups(parsed) ? parsed : null
  }

  function saveGroups(doc) {
    if (!Model.validateGroups(doc)) {
      root.actionFailed("Could not save groups — the file would be invalid")
      return
    }
    // Show the edit now; the debounced write follows, and the watcher brings
    // back whatever actually landed on disk.
    root.groupsDoc = doc
    root._pendingGroups = doc
    groupsSaveTimer.restart()
  }

  function flushGroups() {
    if (!root._pendingGroups) return
    var doc = root._pendingGroups
    root._pendingGroups = null
    groupsFile.setText(JSON.stringify(doc, null, 2) + "\n")
  }

  function openSetupTerminal() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", root.cliPath + " setup"])
  }

  Timer {
    id: refreshTimer
    interval: 30000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: delayedRefresh
    interval: 800
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    // Every poll is skipped while its own process is still running, so one that
    // never exits silently stops the widget refreshing at all, and it stays
    // stopped. Reap anything still running well inside the refresh interval so
    // the next tick starts clean.
    id: pollWatchdog
    interval: 15000
    repeat: false
    onTriggered: if (statusProc.running) statusProc.running = false
  }

  Timer {
    // Local countdown so the bar ticks between polls. It only runs against a
    // real deadline: an indefinite snooze has nothing to count down.
    id: countdown
    interval: 1000
    repeat: true
    running: root.enabled && root.until > 0 && !root._expired
    onTriggered: {
      if (root.remainingSeconds > 0) {
        root.remainingSeconds -= 1
        return
      }
      root.sweepAndRefresh()
    }
  }

  Timer {
    id: groupsSaveTimer
    interval: 200
    repeat: false
    // ~/.config/snooze may not exist yet (nothing has run `snooze setup`), and
    // a write into a missing directory just fails.
    onTriggered: if (!groupsDirProc.running) groupsDirProc.running = true
  }

  Process {
    id: groupsDirProc
    command: ["mkdir", "-p", root.groupsDir]
    onExited: root.flushGroups()
  }

  Process {
    id: statusProc
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true }
    onExited: function(exitCode) {
      pollWatchdog.stop()
      if (exitCode === 0) root.applyStatus(String(statusStdout.text || ""))
      else root.applyUnavailable(String(statusStderr.text || "").trim() || "Snooze — status unavailable")
      if (root._refreshQueued) Qt.callLater(root.refresh)
    }
  }

  Process {
    id: actionProc
    running: false
    command: []
    stdout: StdioCollector { id: actionStdout; waitForEnd: true }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        var message = String(actionStderr.text || "").replace(/\s+/g, " ").trim()
        if (message === "") message = String(actionStdout.text || "").replace(/\s+/g, " ").trim()
        root.actionFailed(message !== "" ? message : "Snooze command failed")
      }
      if (root._actionQueue.length > 0) {
        var queued = root._actionQueue.slice()
        var next = queued.shift()
        root._actionQueue = queued
        actionProc.command = next
        actionProc.running = true
        return
      }
      root.refresh()
    }
  }

  FileView {
    id: groupsFile
    path: root.groupsPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyGroups(text())
    // No file yet, or an unreadable one: the panel offers setup instead of an
    // empty group list.
    onLoadFailed: root.groupsDoc = null
    onFileChanged: reload()
    onSaveFailed: root.actionFailed("Could not save " + root.groupsPath)
  }

  Component.onCompleted: {
    // Self-heal after a reboot: the wake unit cannot fire while the machine is
    // off, so a block whose deadline passed overnight is still in /etc/hosts.
    Quickshell.execDetached([root.cliPath, "sweep"])
    root.refresh()
  }
}
