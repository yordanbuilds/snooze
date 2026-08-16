import QtQuick
import qs.Commons
import qs.Ui
import "Model.mjs" as Model

// The edit view: every group, the sites under it, and the fields that change
// them. Nothing is edited in place — each change deep-copies
// `service.groupsDoc`, applies itself to the copy, validates it with the same
// model the CLI reads the file back with, and hands it to `saveGroups`. The
// file on disk stays the truth: the watcher re-emits whatever actually landed
// there, and this view repaints from that.
//
// A session is a snapshot, so editing during an active snooze is allowed and
// changes nothing about the block already in /etc/hosts.
Item {
  id: root

  property var service: null
  property color foreground: Color.foreground
  // The kit has no `error` token; `urgent` is what it uses for destructive and
  // wrong-input states, and the panel passes the bar's own urgent color in.
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property bool hasDoc: root.service
    ? (root.service.groupsDoc !== null && root.service.groupsDoc !== undefined)
    : false
  readonly property var groups: root.hasDoc && root.service.groupsDoc.groups instanceof Array
    ? root.service.groupsDoc.groups
    : []

  // The group waiting on the delete confirm, "" when none. The dialog itself
  // lives in the panel so it covers the whole popout rather than the slice of
  // it this view happens to occupy.
  property string pendingDeleteId: ""

  // What the list actually draws. A save re-emits groupsDoc twice — once
  // optimistically, once when the watcher has re-read the file — and each one
  // would rebuild every delegate, throwing away half-typed input and the focus
  // that goes with it. Only a document that really differs gets through.
  readonly property string signature: JSON.stringify(root.groups)
  property var viewGroups: []
  onSignatureChanged: root.viewGroups = root.groups

  // Unsaved typing, keyed by group id, so the rebuilds that do happen (a real
  // edit here, a hand-edit of the file) leave it alone. Read once, when a
  // delegate is created; never bound to.
  //
  // Renames need this as much as new sites do: removing a site or deleting
  // another group commits through buttons that never take the keyboard, so a
  // half-typed name is still under the caret when its delegate is replaced.
  // A name draft only exists while it differs from the file, so a rename that
  // lands — or is reverted — drops it on the next keystroke it causes.
  property var nameDrafts: ({})
  property var siteDrafts: ({})
  property var siteErrors: ({})

  // The field holding the keyboard, and a stable name for it: the panel blocks
  // its key catcher while a field is focused (so "j" types a j), and focus
  // lands back in the same box after a rebuild.
  property Item focusedField: null
  property string focusKey: ""
  readonly property bool editorFocused: root.focusedField !== null

  // Escape inside a field hands the keyboard back to the panel.
  signal escaped()

  implicitHeight: content.implicitHeight

  Component.onCompleted: root.viewGroups = root.groups

  // ---- per-field state -----------------------------------------------------

  // null, not "", when there is nothing typed: a name the user emptied on
  // purpose is a draft too, and must not be read back as "use the file's name".
  function nameDraftFor(id) {
    var v = root.nameDrafts[id]
    return v === undefined ? null : String(v)
  }

  // Only a name that differs from the file is worth keeping. Storing every
  // keystroke would leave a stale copy of the old name behind, and that copy
  // would then overwrite a rename made outside the panel.
  function setNameDraft(id, value, saved) {
    if (String(value) === String(saved)) root.clearNameDraft(id)
    else root.nameDrafts[id] = String(value)
  }

  function clearNameDraft(id) {
    delete root.nameDrafts[id]
  }

  function draftFor(id) {
    var v = root.siteDrafts[id]
    return v === undefined ? "" : String(v)
  }

  function setDraft(id, value) {
    root.siteDrafts[id] = String(value)
  }

  function errorFor(id) {
    return root.siteErrors[id] === true
  }

  function setError(id, on) {
    root.siteErrors[id] = on === true
  }

  function noteFocus(item, key, on) {
    if (on) {
      root.focusedField = item
      root.focusKey = key
    } else if (root.focusedField === item) {
      root.focusedField = null
    }
  }

  function releaseFocus() {
    root.focusKey = ""
    root.focusedField = null
    root.escaped()
  }

  // Leaving the view (or closing the panel) drops everything unsaved: no
  // half-typed site, no error border, no focus claim carries into the next visit.
  function reset() {
    root.pendingDeleteId = ""
    root.nameDrafts = ({})
    root.siteDrafts = ({})
    root.siteErrors = ({})
    root.focusKey = ""
    root.focusedField = null
  }

  // ---- ids -----------------------------------------------------------------

  function hasGroup(id) {
    var wanted = String(id)
    for (var i = 0; i < root.groups.length; i++) {
      if (String(root.groups[i].id) === wanted) return true
    }
    return false
  }

  function slugify(name) {
    var s = String(name).toLowerCase().replace(/[^a-z0-9]+/g, "-")
    return s.replace(/^-+/, "").replace(/-+$/, "")
  }

  // A name a slug can keep nothing of — one written in another script, say —
  // still deserves a group, so it gets a plain id instead of a refusal.
  function fallbackId() {
    var candidate = "group"
    var n = 1
    while (root.hasGroup(candidate)) {
      n += 1
      candidate = "group-" + n
    }
    return candidate
  }

  function idForName(name) {
    var slug = root.slugify(name)
    return slug !== "" ? slug : root.fallbackId()
  }

  // ---- mutations -----------------------------------------------------------

  function cloneDoc() {
    if (!root.hasDoc) return null
    var copy = null
    try {
      copy = JSON.parse(JSON.stringify(root.service.groupsDoc))
    } catch (e) {
      copy = null
    }
    return copy && copy.groups instanceof Array ? copy : null
  }

  function commit(copy) {
    if (!copy || !Model.validateGroups(copy)) return false
    root.service.saveGroups(copy)
    return true
  }

  function indexIn(copy, id) {
    var wanted = String(id)
    for (var i = 0; i < copy.groups.length; i++) {
      if (String(copy.groups[i].id) === wanted) return i
    }
    return -1
  }

  function renameGroup(id, name) {
    var next = String(name).trim()
    if (next === "") return false
    var copy = root.cloneDoc()
    if (!copy) return false
    var i = root.indexIn(copy, id)
    if (i < 0 || copy.groups[i].name === next) return false
    copy.groups[i].name = next
    return root.commit(copy)
  }

  function deleteGroup(id) {
    var copy = root.cloneDoc()
    if (!copy) return false
    var wanted = String(id)
    var kept = []
    for (var i = 0; i < copy.groups.length; i++) {
      if (String(copy.groups[i].id) !== wanted) kept.push(copy.groups[i])
    }
    if (kept.length === copy.groups.length) return false
    copy.groups = kept
    return root.commit(copy)
  }

  function addSite(id, site) {
    if (!Model.isValidDomain(site)) return false
    var copy = root.cloneDoc()
    if (!copy) return false
    var i = root.indexIn(copy, id)
    if (i < 0) return false
    var sites = copy.groups[i].sites instanceof Array ? copy.groups[i].sites : []
    for (var j = 0; j < sites.length; j++) {
      // Already blocked by this group: the row is right there above the field.
      if (String(sites[j]) === site) return false
    }
    sites.push(site)
    copy.groups[i].sites = sites
    return root.commit(copy)
  }

  function removeSite(id, siteIndex) {
    var copy = root.cloneDoc()
    if (!copy) return false
    var i = root.indexIn(copy, id)
    if (i < 0 || !(copy.groups[i].sites instanceof Array)) return false
    var sites = copy.groups[i].sites
    if (siteIndex < 0 || siteIndex >= sites.length) return false
    var kept = []
    for (var j = 0; j < sites.length; j++) {
      if (j !== siteIndex) kept.push(sites[j])
    }
    copy.groups[i].sites = kept
    return root.commit(copy)
  }

  function addGroup(name, id) {
    var label = String(name).trim()
    if (label === "" || id === "") return false
    var copy = root.cloneDoc()
    if (!copy) return false
    if (root.indexIn(copy, id) >= 0) return false
    copy.groups.push({ "id": String(id), "name": label, "sites": [] })
    return root.commit(copy)
  }

  // ---- delete confirm, answered by the panel's dialog -----------------------

  function askDelete(id) {
    root.pendingDeleteId = String(id)
  }

  function cancelDelete() {
    root.pendingDeleteId = ""
  }

  function confirmDelete() {
    var id = root.pendingDeleteId
    root.pendingDeleteId = ""
    if (id === "") return
    // Off the signal handler's stack: committing here would rebuild the very
    // delegates the click came from while they are still on it.
    Qt.callLater(function() { root.deleteGroup(id) })
  }

  Column {
    id: content
    width: root.width
    spacing: Style.space(14)

    Text {
      visible: root.service && root.service.enabled === true
      width: parent.width
      text: "A session is a snapshot — edits apply to the next one."
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Text {
      visible: !root.hasDoc
      width: parent.width
      text: "No groups file to edit — ~/.config/snooze/groups.json is missing or unreadable."
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      wrapMode: Text.WordWrap
    }

    Repeater {
      model: root.viewGroups

      Column {
        id: groupSection
        required property var modelData
        required property int index

        readonly property string groupId: String(modelData.id)
        readonly property string groupName: String(modelData.name || "")
        readonly property var sites: modelData.sites instanceof Array ? modelData.sites : []

        property bool siteError: false

        width: content.width
        spacing: Style.space(6)

        Component.onCompleted: groupSection.siteError = root.errorFor(groupSection.groupId)

        PanelSeparator {
          visible: groupSection.index > 0
          foreground: root.foreground
        }

        Row {
          width: parent.width
          spacing: Style.space(6)

          TextField {
            id: nameField
            width: parent.width - deleteButton.width - parent.spacing
            foreground: root.foreground
            font.family: root.fontFamily
            onActiveFocusChanged: root.noteFocus(nameField, "name:" + groupSection.groupId, activeFocus)
            // Whatever was typed and not yet saved comes back with the delegate;
            // otherwise the field shows what the file holds.
            Component.onCompleted: {
              var draft = root.nameDraftFor(groupSection.groupId)
              nameField.text = draft === null ? groupSection.groupName : draft
              if (root.focusKey === "name:" + groupSection.groupId) nameField.forceActiveFocus()
            }
            Component.onDestruction: root.noteFocus(nameField, "", false)
            onTextChanged: root.setNameDraft(groupSection.groupId, nameField.text, groupSection.groupName)
            // Renaming to nothing is not a rename: the field goes back to the
            // name the file still holds.
            onEditingFinished: {
              var wanted = String(nameField.text).trim()
              if (wanted === "" || wanted === groupSection.groupName) {
                nameField.text = groupSection.groupName
                return
              }
              var id = groupSection.groupId
              // The typed text is on its way to the file, so it stops being a
              // draft here — otherwise the trimming would read back as one.
              root.clearNameDraft(id)
              Qt.callLater(function() { root.renameGroup(id, wanted) })
            }
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                nameField.text = groupSection.groupName
                root.releaseFocus()
                event.accepted = true
              }
            }
          }

          PanelActionButton {
            id: deleteButton
            iconText: "󰆴"
            tooltipText: "Delete group"
            size: nameField.implicitHeight
            foreground: root.foreground
            hoverColor: root.urgent
            fontFamily: root.fontFamily
            onClicked: root.askDelete(groupSection.groupId)
          }
        }

        Column {
          id: siteList
          x: Style.space(4)
          width: parent.width - x
          spacing: Style.space(2)

          Text {
            visible: groupSection.sites.length === 0
            width: parent.width
            text: "No sites yet."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            model: groupSection.sites

            Item {
              id: siteRow
              required property var modelData
              required property int index

              width: siteList.width
              height: Math.max(siteLabel.implicitHeight, removeButton.implicitHeight)

              Text {
                id: siteLabel
                anchors.left: parent.left
                anchors.right: removeButton.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                text: String(siteRow.modelData)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              PanelActionButton {
                id: removeButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅖"
                tooltipText: "Remove site"
                fontSize: Style.font.bodySmall
                foreground: root.dim
                hoverColor: root.urgent
                fontFamily: root.fontFamily
                onClicked: {
                  var id = groupSection.groupId
                  var at = siteRow.index
                  Qt.callLater(function() { root.removeSite(id, at) })
                }
              }
            }
          }
        }

        TextField {
          id: siteField
          width: parent.width
          placeholderText: "add a site…"
          foreground: root.foreground
          // Refused input reads urgent until the next keystroke, border and
          // text both — a hairline alone is easy to miss.
          color: groupSection.siteError ? root.urgent : root.foreground
          font.family: root.fontFamily
          Component.onCompleted: {
            siteField.text = root.draftFor(groupSection.groupId)
            if (root.focusKey === "site:" + groupSection.groupId) siteField.forceActiveFocus()
          }
          Component.onDestruction: root.noteFocus(siteField, "", false)
          onActiveFocusChanged: root.noteFocus(siteField, "site:" + groupSection.groupId, activeFocus)
          onTextChanged: {
            root.setDraft(groupSection.groupId, siteField.text)
            if (groupSection.siteError) {
              groupSection.siteError = false
              root.setError(groupSection.groupId, false)
            }
          }
          // `normalizeSite` can turn perfectly confident input into something
          // that is not a domain at all ("https://user:pw@x.com/p" → "user"),
          // so what it produced is what gets judged — and a rejection is shown
          // rather than swallowed.
          onAccepted: {
            var site = Model.normalizeSite(siteField.text)
            if (!Model.isValidDomain(site)) {
              groupSection.siteError = true
              root.setError(groupSection.groupId, true)
              siteField.forceActiveFocus()
              return
            }
            var id = groupSection.groupId
            siteField.text = ""
            root.setDraft(id, "")
            Qt.callLater(function() { root.addSite(id, site) })
          }
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
              root.releaseFocus()
              event.accepted = true
            }
          }

          // A refused entry has to paint its own border: the theme resolves a
          // focused control's border to a color of its own (grey, in the
          // default one), so tinting the ring the field already has would
          // change nothing.
          BorderSurface {
            anchors.fill: parent
            visible: groupSection.siteError
            color: "transparent"
            radius: Style.cornerRadius
            borderSpec: Border.flat(root.urgent, Math.max(1, Style.normalBorderWidth))
          }
        }
      }
    }

    PanelSeparator {
      visible: root.viewGroups.length > 0
      foreground: root.foreground
    }

    Row {
      id: newGroupRow
      width: parent.width
      spacing: Style.space(6)

      readonly property string wantedName: String(newGroupField.text).trim()
      readonly property string wantedId: newGroupRow.wantedName === "" ? "" : root.idForName(newGroupRow.wantedName)
      readonly property bool taken: newGroupRow.wantedId !== "" && root.hasGroup(newGroupRow.wantedId)

      // The id is the name, slugified — and it is what `snooze start --group`
      // takes, so two groups can never share one.
      function submit() {
        if (newGroupRow.wantedName === "" || newGroupRow.taken) {
          newGroupField.rejected = true
          newGroupField.forceActiveFocus()
          return
        }
        var name = newGroupRow.wantedName
        var id = newGroupRow.wantedId
        newGroupField.text = ""
        Qt.callLater(function() { root.addGroup(name, id) })
      }

      TextField {
        id: newGroupField
        property bool rejected: false

        width: parent.width - addButton.width - parent.spacing
        placeholderText: "New group"
        enabled: root.hasDoc
        foreground: root.foreground
        color: newGroupField.rejected ? root.urgent : root.foreground
        font.family: root.fontFamily
        onActiveFocusChanged: root.noteFocus(newGroupField, "new-group", activeFocus)
        Component.onDestruction: root.noteFocus(newGroupField, "", false)
        onTextChanged: newGroupField.rejected = false
        onAccepted: newGroupRow.submit()
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.releaseFocus()
            event.accepted = true
          }
        }

        BorderSurface {
          anchors.fill: parent
          visible: newGroupField.rejected
          color: "transparent"
          radius: Style.cornerRadius
          borderSpec: Border.flat(root.urgent, Math.max(1, Style.normalBorderWidth))
        }
      }

      PanelActionButton {
        id: addButton
        iconText: "󰐕"
        tooltipText: newGroupRow.taken ? "A group with that id already exists" : "Add group"
        size: newGroupField.implicitHeight
        enabled: root.hasDoc && newGroupRow.wantedName !== "" && !newGroupRow.taken
        foreground: root.foreground
        hoverColor: Color.accent
        fontFamily: root.fontFamily
        onClicked: newGroupRow.submit()
      }
    }
  }
}
