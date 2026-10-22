import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// TaskNotes tasks from an Obsidian vault, filtered/sorted by whichever
// TaskNotes view the user picks -- read straight off the vault's markdown.
//
// The vault is the only state this widget has. Nothing is cached beyond one
// scan's results, so a task added on a phone appears as soon as the next
// scan lands, and a task ticked here is a rewritten frontmatter field on
// disk that sync carries back out. Every read and write goes through
// bin/omatasknotes; this file only decides what to show.
Panel {
  id: root
  moduleName: "doghouse-mike.omatasknotes"
  ipcTarget: "doghouse-mike.omatasknotes"

  readonly property string glyphBar: String.fromCodePoint(0xF0135)
  readonly property string glyphOpen: String.fromCodePoint(0xF0131)
  readonly property string glyphDone: String.fromCodePoint(0xF0132)
  readonly property string glyphCog: String.fromCodePoint(0xF0493)

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string vaultHint: String(setting("vaultPath", ""))
  property string vaultPath: ""
  property string vaultSource: "none"
  property bool vaultExists: false
  readonly property bool vaultUnconfigured: root.vaultHint === ""
  readonly property bool vaultActive: !root.vaultUnconfigured && root.vaultExists
  readonly property string displayVault: vaultPath === "" ? "" : vaultPath.replace(root.home, "~")

  readonly property string viewIdSetting: String(setting("viewId", ""))
  property var views: []
  property bool viewsLoaded: false
  property bool noTaskNotes: false
  readonly property var currentView: {
    for (var i = 0; i < root.views.length; i++)
      if (root.views[i].id === root.viewIdSetting) return root.views[i]
    return null
  }
  // Unsupported views stay in `views` (so a picked view that later becomes
  // unsupported -- e.g. a .base file edited to add a construct we don't
  // evaluate -- is still correctly detected), but there's no point offering
  // someone a picker row they can't click.
  readonly property var supportedViews: root.views.filter(function (v) { return v.supported === true })
  readonly property bool viewReady: root.currentView !== null && root.currentView.supported === true
  readonly property bool viewNeeded: root.vaultActive && !root.noTaskNotes && !root.viewReady

  property bool settingsOpen: false
  readonly property bool settingsRowVisible: root.vaultUnconfigured || root.viewNeeded || root.settingsOpen

  readonly property bool readOnly: setting("readOnly", true) !== false
  readonly property string countMode: String(setting("countMode", "all"))
  readonly property int refreshIntervalSec: Math.max(10, Number(setting("refreshIntervalSec", 60)))
  readonly property string helper: Qt.resolvedUrl("bin/omatasknotes").toString().replace("file://", "")

  property var tasks: []
  property bool everScanned: false
  property string scanError: ""
  // Tasks ticked within the fade window: written to disk already, still drawn
  // so the tick is visible and still reversible.
  property var justDone: []

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string today: isoDate(new Date())

  readonly property var openTasks: (tasks || []).filter(function (t) { return !t.isCompleted })
  readonly property var dueTasks: openTasks.filter(function (t) { return t.due !== "" && t.due <= root.today })
  readonly property int badgeCount: countMode === "due" ? dueTasks.length : openTasks.length

  // The helper already applies the chosen Base view's sort order.
  readonly property var rows: openTasks.concat(justDone)

  readonly property string summary: {
    if (root.vaultUnconfigured) return "No vault set"
    if (!root.vaultExists) return "Vault not found"
    if (root.noTaskNotes) return "TaskNotes not set up in this vault"
    if (root.viewNeeded) return "No view chosen"
    if (!root.everScanned) return "Reading vault…"
    if (root.scanError !== "") return root.scanError
    if (openTasks.length === 0) return "Nothing open"
    var line = openTasks.length + (openTasks.length === 1 ? " open task" : " open tasks")
    return dueTasks.length > 0 ? line + " · " + dueTasks.length + " due" : line
  }

  function expand(path) {
    return path.indexOf("~") === 0 ? root.home + path.substring(1) : path
  }

  function isoDate(d) {
    return d.getFullYear() + "-" + ("0" + (d.getMonth() + 1)).slice(-2) + "-" + ("0" + d.getDate()).slice(-2)
  }

  function dueLabel(due) {
    if (due === "") return ""
    if (due < root.today) return "overdue"
    if (due === root.today) return "today"
    var t = new Date()
    t.setDate(t.getDate() + 1)
    return due === isoDate(t) ? "tomorrow" : due
  }

  function refreshViews() {
    if (!root.vaultActive || viewsProc.running) return
    viewsProc.command = [root.helper, "views", root.vaultPath]
    viewsProc.running = true
  }

  function refresh() {
    if (!root.vaultActive || !root.viewReady) {
      root.tasks = []
      root.everScanned = true
      return
    }
    if (!scanProc.running) scanProc.running = true
  }

  function resolveVault() {
    if (vaultProc.running) return
    vaultProc.ranWith = root.vaultHint
    vaultProc.command = [root.helper, "vault", root.vaultHint]
    vaultProc.running = true
  }

  function chooseVault(input) {
    var path = root.expand(String(input || "").replace(/^file:\/\//, "").trim())
    if (path === "") return
    setVaultProc.command = ["omarchy", "bar", "set", root.moduleName, "vaultPath", path]
    setVaultProc.running = true
  }

  function chooseView(view) {
    if (!view || !view.supported) return
    root.settingsOpen = false
    setViewProc.command = ["omarchy", "bar", "set", root.moduleName, "viewId", view.id]
    setViewProc.running = true
  }

  function completeTask(task) {
    if (root.readOnly) { root.openInObsidian(task); return }
    if (!task || editProc.running) return
    editProc.mode = "complete"
    editProc.subject = task
    editProc.command = [root.helper, "complete", root.vaultPath, task.file, task.hash]
    editProc.running = true
  }

  function openInObsidian(task) {
    // Obsidian's own core "open" URI action, not the Advanced URI plugin --
    // `path=<absolute path>` needs no vault name/id, Obsidian resolves which
    // vault contains it. xdg-open dispatches to whatever's registered for
    // the obsidian:// scheme, same as clicking a link.
    if (!task || !task.file || root.vaultPath === "") return
    var absPath = root.vaultPath + "/" + task.file
    var uri = "obsidian://open?path=" + encodeURIComponent(absPath)
    openNoteProc.command = ["xdg-open", uri]
    openNoteProc.running = true
  }

  function undoTask(entry) {
    if (root.readOnly || !entry || editProc.running) return
    root.justDone = root.justDone.filter(function (e) { return e.file !== entry.file })
    editProc.mode = "uncomplete"
    editProc.subject = null
    editProc.command = [root.helper, "uncomplete", root.vaultPath, entry.file, entry.newHash,
      entry.restoreMode || "", String(entry.restoreValue === undefined ? "" : entry.restoreValue)]
    editProc.running = true
  }

  function markJustDone(task, newHash, restoreMode, restoreValue) {
    var entry = {}
    for (var key in task) entry[key] = task[key]
    entry.isCompleted = true
    entry.newHash = newHash
    entry.restoreMode = restoreMode
    entry.restoreValue = restoreValue
    entry.retireAt = Date.now() + 1800
    root.justDone = root.justDone.concat([entry])
  }

  function addTask(text) {
    if (root.readOnly || !root.vaultActive || editProc.running || String(text).trim() === "") return
    editProc.mode = "add"
    editProc.subject = null
    editProc.command = [root.helper, "create", root.vaultPath, String(text).trim()]
    editProc.running = true
  }

  onOpenedChanged: {
    if (opened) {
      justDone = []
      settingsOpen = false
      scanError = ""
      refreshViews()
      refresh()
    }
  }

  Process {
    id: vaultProc
    property string ranWith: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var found = JSON.parse(String(text || "{}"))
          root.vaultPath = String(found.path || "")
          root.vaultSource = String(found.source || "none")
          root.vaultExists = found.exists === true
        } catch (e) {
          console.warn("omatasknotes: could not resolve vault", e)
          root.vaultExists = false
        }
        if (vaultProc.ranWith !== root.vaultHint) Qt.callLater(root.resolveVault)
        else { root.refreshViews(); root.refresh() }
      }
    }
  }

  Process {
    id: setVaultProc
    onExited: root.resolveVault()
  }

  Process {
    id: openNoteProc
  }

  Process {
    id: setViewProc
    onExited: root.refresh()
  }

  onVaultHintChanged: root.resolveVault()
  Component.onCompleted: root.resolveVault()

  Process {
    id: viewsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(String(text || "{}"))
          if (parsed.ok === false && parsed.error === "no-tasknotes") {
            root.noTaskNotes = true
            root.views = []
          } else {
            root.noTaskNotes = false
            root.views = Array.isArray(parsed.views) ? parsed.views : []
          }
        } catch (e) {
          console.warn("omatasknotes: could not parse views output", e)
          root.views = []
        }
        root.viewsLoaded = true
      }
    }
  }

  Process {
    id: scanProc
    command: [root.helper, "scan", root.vaultPath, root.viewIdSetting]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(String(text || "{}"))
          if (parsed.ok === false) {
            root.tasks = []
            root.scanError = String(parsed.message || parsed.error || "scan failed")
          } else {
            root.tasks = Array.isArray(parsed.rows) ? parsed.rows : []
            root.scanError = parsed.truncated ? ("showing first " + parsed.rows.length + " of " + parsed.total) : ""
          }
        } catch (e) {
          console.warn("omatasknotes: could not parse scan output", e)
          root.tasks = []
          root.scanError = "scan failed"
        }
        root.everScanned = true
      }
    }
  }

  Process {
    id: editProc
    property string mode: ""
    property var subject: null
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(String(text || "{}"))
          if (editProc.mode === "complete" && parsed.ok === true && editProc.subject) {
            root.markJustDone(editProc.subject, parsed.hash, parsed.restoreMode, parsed.restoreValue)
          }
        } catch (e) {
          console.warn("omatasknotes: edit failed to parse", e)
        }
        editProc.subject = null
      }
    }
    onExited: root.refresh()
  }

  Timer {
    interval: 300
    running: root.justDone.length > 0
    repeat: true
    onTriggered: {
      var now = Date.now()
      var live = root.justDone.filter(function (e) { return e.retireAt > now })
      if (live.length !== root.justDone.length) root.justDone = live
    }
  }

  // Backstop for the helper's own 20s deadline (e.g. stuck on a dead network
  // mount, where its alarm can't fire): stop any run still going at 30s so a
  // hung helper can't leave the widget waiting forever.
  Timer {
    interval: 30000
    running: vaultProc.running || viewsProc.running || scanProc.running || editProc.running
    onTriggered: {
      for (const proc of [vaultProc, viewsProc, scanProc, editProc])
        if (proc.running) proc.running = false
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: { root.refreshViews(); root.refresh() }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyphBar
    dimmed: root.badgeCount === 0
    tooltipText: root.summary
    onPressed: function (code) {
      if (code === Qt.RightButton) { root.refreshViews(); root.refresh() }
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: addField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (t) {
        if (t === "a" || t === "A") { if (root.vaultActive) addField.forceActiveFocus() }
        else if (t === "r" || t === "R") { root.refreshViews(); root.refresh() }
      }

      Flickable {
        id: flick
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
          width: flick.width
          spacing: Style.space(8)

          Item {
            id: hero
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight,
              Math.max(heroLabels.implicitHeight, gearButton.implicitHeight))

            Text {
              textFormat: Text.PlainText
              id: heroIcon
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.glyphBar
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              opacity: root.openTasks.length === 0 ? 0.5 : 1.0
            }

            PanelActionButton {
              id: gearButton
              visible: !root.vaultUnconfigured
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: root.glyphCog
              tooltipText: root.settingsOpen ? "Hide settings" : "Change vault / view"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.settingsOpen = !root.settingsOpen
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.rightMargin: gearButton.visible ? gearButton.width + Style.space(12) : 0
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                id: titleText
                width: parent.width
                text: "TaskNotes" + (root.currentView ? " · " + root.currentView.name : "")
                  + (titleMouse.enabled ? "  ▾" : "")
                color: titleMouse.containsMouse ? root.accent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight

                MouseArea {
                  id: titleMouse
                  anchors.fill: parent
                  enabled: !root.vaultUnconfigured
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.settingsOpen = !root.settingsOpen
                  ToolTip.visible: containsMouse
                  ToolTip.text: root.settingsOpen ? "Hide view picker" : "Choose a different view"
                }
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: root.summary.toUpperCase()
                color: Qt.darker(root.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
              }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.foreground
          }

          Column {
            width: parent.width
            visible: root.settingsRowVisible
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: !root.vaultUnconfigured
                ? "Vault — Enter to change it."
                : (root.vaultPath === ""
                   ? "Where's your vault?"
                   : "Found Obsidian's vault. Enter to use it.")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            TextField {
              id: vaultField
              width: parent.width
              foreground: root.foreground
              accent: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              placeholderText: "Path to your vault, e.g. ~/Documents/Notes"
              onAccepted: root.chooseVault(text)
              Component.onCompleted: text = root.displayVault
              Connections {
                target: root
                function onDisplayVaultChanged() {
                  if (!vaultField.activeFocus) vaultField.text = root.displayVault
                }
                function onOpenedChanged() {
                  if (root.opened) vaultField.text = root.displayVault
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: root.vaultActive && root.noTaskNotes
              text: "TaskNotes isn't configured in this vault (no .obsidian/plugins/tasknotes/data.json)."
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: root.vaultActive && !root.noTaskNotes
              text: root.viewsLoaded
                ? (root.supportedViews.length === 0 ? "No views this widget can show (see README)." : "Pick a view:")
                : "Reading TaskNotes views…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: root.vaultActive && !root.noTaskNotes ? root.supportedViews : []

              Item {
                id: viewRow
                required property var modelData
                width: column.width
                implicitHeight: viewRowLabel.implicitHeight + Style.space(6)

                readonly property bool isCurrent: modelData.id === root.viewIdSetting

                Rectangle {
                  anchors.fill: parent
                  anchors.leftMargin: -Style.space(6)
                  anchors.rightMargin: -Style.space(6)
                  radius: Style.cornerRadius
                  color: viewRow.isCurrent ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16)
                    : (viewMouse.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08) : "transparent")
                }

                Text {
                  textFormat: Text.PlainText
                  id: viewRowLabel
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.name
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: viewRow.isCurrent
                  elide: Text.ElideRight
                }

                MouseArea {
                  id: viewMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.chooseView(viewRow.modelData)
                }
              }
            }

            PanelSeparator {
              width: parent.width
              foreground: root.foreground
            }
          }

          Repeater {
            model: root.rows

            Item {
              id: row
              required property var modelData
              width: column.width
              implicitHeight: Math.max(rowLabel.implicitHeight, Style.space(24))

              readonly property bool done: modelData.isCompleted === true
              readonly property bool overdue: !done && modelData.due !== "" && modelData.due < root.today
              readonly property bool hot: boxMouse.containsMouse || labelMouse.containsMouse

              Behavior on opacity { NumberAnimation { duration: 260 } }
              opacity: done ? 0.45 : 1.0

              Rectangle {
                anchors.fill: parent
                anchors.leftMargin: -Style.space(6)
                anchors.rightMargin: -Style.space(6)
                radius: Style.cornerRadius
                color: row.hot ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08) : "transparent"
              }

              Text {
                textFormat: Text.PlainText
                id: box
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: row.done ? root.glyphDone : root.glyphOpen
                color: row.done ? root.accent : (boxMouse.containsMouse ? root.accent : root.dim)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body

                MouseArea {
                  id: boxMouse
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: row.done ? root.undoTask(row.modelData) : root.completeTask(row.modelData)
                  ToolTip.visible: containsMouse
                  ToolTip.text: root.readOnly ? "Open in Obsidian to complete or edit" : "Complete task"
                }
              }

              Text {
                textFormat: Text.PlainText
                id: rowLabel
                anchors.left: box.right
                anchors.leftMargin: Style.space(8)
                anchors.right: dueBadge.visible ? dueBadge.left : parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: row.modelData.title
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.strikeout: row.done
                elide: Text.ElideRight
                wrapMode: Text.NoWrap

                MouseArea {
                  id: labelMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  acceptedButtons: root.readOnly ? (Qt.LeftButton | Qt.RightButton) : Qt.RightButton
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openInObsidian(row.modelData)
                  ToolTip.visible: containsMouse
                  ToolTip.text: root.readOnly ? "Open in Obsidian" : "Right-click: open in Obsidian"
                }
              }

              Text {
                textFormat: Text.PlainText
                id: dueBadge
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: row.modelData.due !== ""
                text: root.dueLabel(row.modelData.due)
                color: row.overdue ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: root.viewReady && root.everScanned && root.rows.length === 0 && root.scanError === ""
            text: "Nothing in " + (root.currentView ? root.currentView.name : "this view")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: root.scanError !== "" && root.viewReady
            text: root.scanError
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          PanelSeparator {
            width: parent.width
            visible: root.viewReady
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: root.viewReady && root.readOnly
            text: "Read-only · click a task to edit in Obsidian"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          TextField {
            id: addField
            visible: root.viewReady && !root.readOnly
            width: parent.width
            foreground: root.foreground
            accent: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            placeholderText: "Add a task…"
            onAccepted: {
              root.addTask(text)
              text = ""
            }
            Keys.onEscapePressed: {
              text = ""
              keyCatcher.forceActiveFocus()
            }
          }
        }
      }
    }
  }
}
