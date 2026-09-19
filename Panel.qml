import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Bar widget for the audio-switcher plugin. Left click opens the settings
// panel; right click cycles to the next profile. All logic lives in
// Service.qml, reached through the scoped shell facade.
Panel {
  id: root
  moduleName: "io.github.solkkku.audio-switcher"
  // The service already registers the "io.github.solkkku.audio-switcher" IPC target; the
  // panel must not register a second handler on the same name.
  manageIpc: false

  property var service: null

  readonly property var profiles: service ? service.profiles : []
  readonly property string cycleHotkey: service ? service.cycleHotkey : ""
  readonly property string previousHotkey: service ? service.previousHotkey : ""
  readonly property string micMuteHotkey: service ? service.micMuteHotkey : ""
  readonly property string outputMuteHotkey: service ? service.outputMuteHotkey : ""
  readonly property string notificationPosition: service ? service.notificationPosition : "bottom-center"
  readonly property string fallbackProfileName: service ? service.fallbackProfileName : ""
  readonly property var outputOptions: service ? service.outputOptions : []
  readonly property var inputOptions: service ? service.inputOptions : []
  readonly property string currentProfileName: service ? service.currentProfileName : ""

  // ---- view state: "browse" | "settings" | "form" | "confirmDelete" ----
  property string view: "browse"
  property int editingIndex: -1
  property int deleteIndex: -1
  property string formName: ""
  property string formOutput: ""
  property string formInput: ""
  property string formHotkey: ""
  property string formIcon: ""

  // ---- hotkey capture state ----
  property bool capturing: false
  property string captureTarget: ""

  // ---- long-press drag reorder state ----
  property int draggingIndex: -1
  property int dropTargetIndex: -1

  readonly property string defaultIcon: "󰓃"
  readonly property var iconOptions: [
    { value: "󰓃", label: "Speaker" },
    { value: "󰋋", label: "Headphones" },
    { value: "󰋎", label: "Headset" },
    { value: "󰊗", label: "Gamepad" },
    { value: "󰂯", label: "Bluetooth" },
    { value: "󰍹", label: "Monitor" }
  ]

  readonly property bool nameDuplicate: {
    var n = formName.trim().toLowerCase()
    if (!n) return false
    for (var i = 0; i < profiles.length; i++) {
      if (i === editingIndex) continue
      if (String(profiles[i].name || "").toLowerCase() === n) return true
    }
    return false
  }

  readonly property bool formComplete: formName.trim() !== ""
    && formOutput !== "" && formHotkey !== "" && formIcon !== "" && !nameDuplicate

  function resolveService() {
    if (!service && bar && bar.shell) service = bar.shell.serviceFor("io.github.solkkku.audio-switcher")
    return service
  }

  onOpenedChanged: {
    if (!opened) {
      dismissResetTimer.restart()
    } else {
      dismissResetTimer.stop()
    }
  }

  Timer {
    id: dismissResetTimer
    interval: 160
    repeat: false
    onTriggered: {
      view = "browse"
      editingIndex = -1
      deleteIndex = -1
      resetForm()
      cancelCapture()
    }
  }

  function resetForm() {
    formName = ""
    formOutput = ""
    formInput = ""
    formHotkey = ""
    formIcon = defaultIcon
    nameField.text = ""
    outputDropdown.value = ""
    inputDropdown.value = ""
  }

  function openAdd() {
    editingIndex = -1
    resetForm()
    view = "form"
    cancelCapture()
  }

  function openEdit(index) {
    var p = profiles[index]
    if (!p) return
    editingIndex = index
    formName = String(p.name || "")
    formOutput = String(p.output || "")
    formInput = String(p.input || "")
    formHotkey = String(p.hotkey || "")
    formIcon = String(p.icon || defaultIcon)
    nameField.text = String(p.name || "")
    outputDropdown.value = String(p.output || "")
    inputDropdown.value = String(p.input || "")
    view = "form"
    cancelCapture()
  }

  function closeForm() {
    goBack()
  }

  function openSettings() {
    view = "settings"
    cancelCapture()
  }

  function openDelete(index) {
    deleteIndex = index
    view = "confirmDelete"
    cancelCapture()
  }

  function confirmDelete() {
    var svc = resolveService()
    if (deleteIndex >= 0 && svc) svc.removeProfile(deleteIndex)
    deleteIndex = -1
    goBack()
  }

  function goBack() {
    view = "browse"
    editingIndex = -1
    deleteIndex = -1
    resetForm()
    cancelCapture()
  }

  function headerSubtitle() {
    if (view === "browse")
      return currentProfileName ? ("Active profile: " + currentProfileName) : "Active profile: None"
    if (view === "settings") return "Options"
    if (view === "form") return editingIndex >= 0 ? "Edit profile" : "New profile"
    if (view === "confirmDelete") return "Delete profile"
    return ""
  }

  function saveForm() {
    if (!formComplete) return
    var svc = resolveService()
    if (!svc) return
    if (editingIndex >= 0)
      svc.updateProfile(editingIndex, formName.trim(), formOutput, formInput, formHotkey, formIcon)
    else
      svc.addProfile(formName.trim(), formOutput, formInput, formHotkey, formIcon)
    closeForm()
  }

  function activateProfile(index) {
    var svc = resolveService()
    if (svc) svc.activate(index)
  }

  function beginDrag(index) {
    draggingIndex = index
    dropTargetIndex = index
  }

  function updateDropTarget(pointerY) {
    var idx = -1
    var bestDist = Number.MAX_VALUE
    for (var j = 0; j < profilesRepeater.count; j++) {
      var it = profilesRepeater.itemAt(j)
      if (!it) continue
      var center = it.y + it.height / 2
      var d = Math.abs(pointerY - center)
      if (d < bestDist) { bestDist = d; idx = j }
    }
    dropTargetIndex = idx
  }

  function finishDrag() {
    var from = draggingIndex
    var to = dropTargetIndex
    draggingIndex = -1
    dropTargetIndex = -1
    if (from >= 0 && to >= 0 && from !== to) {
      Qt.callLater(function() {
        var svc = resolveService()
        if (svc) svc.moveProfile(from, to)
      })
    }
  }

  function rowHeight(j) {
    var it = profilesRepeater.itemAt(j)
    return it ? it.height : 0
  }

  // Live visual offset for row `i` while a drag is in progress: the dragged
  // row slides to the drop slot, and the rows in between move aside by the
  // dragged row's height to open that slot.
  function rowOffset(i) {
    var from = draggingIndex
    var to = dropTargetIndex
    if (from < 0 || to < 0 || from === to) return 0
    var gap = rowHeight(from) + profilesColumn.spacing
    if (i === from) {
      var off = 0
      if (from < to) {
        for (var k = from + 1; k <= to; k++) off += rowHeight(k) + profilesColumn.spacing
      } else {
        for (var k2 = to; k2 < from; k2++) off -= rowHeight(k2) + profilesColumn.spacing
      }
      return off
    }
    if (from < to && i > from && i <= to) return -gap
    if (from > to && i >= to && i < from) return gap
    return 0
  }

  function inputMutedFor(profile) {
    if (!profile || !profile.input || !service) return false
    return service.isInputMuted(profile.input)
  }

  function outputMutedFor(profile) {
    if (!profile || !profile.output || !service) return false
    return service.isOutputMuted(profile.output)
  }

  // ---- hotkey capture ----
  function startCapture(target) {
    capturing = true
    captureTarget = target
  }

  function cancelCapture() {
    capturing = false
    captureTarget = ""
  }

  function applyCaptured(combo) {
    if (captureTarget === "cycle") {
      var svc = resolveService()
      if (svc) svc.setCycleHotkey(combo)
    } else if (captureTarget === "previous") {
      var svc2 = resolveService()
      if (svc2) svc2.setPreviousHotkey(combo)
    } else if (captureTarget === "micmute") {
      var svc3 = resolveService()
      if (svc3) svc3.setMicMuteHotkey(combo)
    } else if (captureTarget === "outmute") {
      var svc4 = resolveService()
      if (svc4) svc4.setOutputMuteHotkey(combo)
    } else if (captureTarget === "form") {
      formHotkey = combo
    }
    cancelCapture()
  }

  function clearHotkey(target) {
    var svc = resolveService()
    if (target === "cycle") {
      if (svc) svc.setCycleHotkey("")
    } else if (target === "previous") {
      if (svc) svc.setPreviousHotkey("")
    } else if (target === "micmute") {
      if (svc) svc.setMicMuteHotkey("")
    } else if (target === "outmute") {
      if (svc) svc.setOutputMuteHotkey("")
    } else if (target === "form") {
      formHotkey = ""
    }
    cancelCapture()
  }

  function hotkeyValueFor(target) {
    if (target === "cycle") return cycleHotkey
    if (target === "previous") return previousHotkey
    if (target === "micmute") return micMuteHotkey
    if (target === "outmute") return outputMuteHotkey
    if (target === "form") return formHotkey
    return ""
  }

  function captureHintText() {
    if (!capturing) return ""
    return hotkeyValueFor(captureTarget) ? "DEL to unassign" : "ESC to cancel"
  }

  function isModifierKey(key) {
    return key === Qt.Key_Shift || key === Qt.Key_Control || key === Qt.Key_Alt
      || key === Qt.Key_Meta || key === Qt.Key_AltGr
      || key === Qt.Key_Super_L || key === Qt.Key_Super_R
      || key === Qt.Key_Hyper_L || key === Qt.Key_Hyper_R
  }

  function modifierParts(modifiers) {
    var parts = []
    if (modifiers & Qt.MetaModifier) parts.push("SUPER")
    if (modifiers & Qt.ControlModifier) parts.push("CTRL")
    if (modifiers & Qt.AltModifier) parts.push("ALT")
    if (modifiers & Qt.ShiftModifier) parts.push("SHIFT")
    return parts
  }

  function keyName(key) {
    if (key >= Qt.Key_A && key <= Qt.Key_Z) return String.fromCharCode(key)
    if (key >= Qt.Key_0 && key <= Qt.Key_9) return String.fromCharCode(key)
    if (key >= Qt.Key_F1 && key <= Qt.Key_F35) return "F" + (key - Qt.Key_F1 + 1)
    var map = [
      [Qt.Key_Space, "SPACE"], [Qt.Key_Return, "RETURN"], [Qt.Key_Enter, "RETURN"],
      [Qt.Key_Tab, "TAB"], [Qt.Key_Backtab, "TAB"], [Qt.Key_Backspace, "BACKSPACE"],
      [Qt.Key_Escape, "ESCAPE"], [Qt.Key_Insert, "INSERT"], [Qt.Key_Delete, "DELETE"],
      [Qt.Key_Home, "HOME"], [Qt.Key_End, "END"], [Qt.Key_PageUp, "PAGEUP"], [Qt.Key_PageDown, "PAGEDOWN"],
      [Qt.Key_Up, "UP"], [Qt.Key_Down, "DOWN"], [Qt.Key_Left, "LEFT"], [Qt.Key_Right, "RIGHT"],
      [Qt.Key_Period, "PERIOD"], [Qt.Key_Comma, "COMMA"], [Qt.Key_Slash, "SLASH"],
      [Qt.Key_Semicolon, "SEMICOLON"], [Qt.Key_Apostrophe, "APOSTROPHE"],
      [Qt.Key_BracketLeft, "BRACKETLEFT"], [Qt.Key_BracketRight, "BRACKETRIGHT"],
      [Qt.Key_Backslash, "BACKSLASH"], [Qt.Key_Minus, "MINUS"], [Qt.Key_Equal, "EQUAL"],
      [Qt.Key_Grave, "GRAVE"], [Qt.Key_QuoteLeft, "GRAVE"]
    ]
    for (var i = 0; i < map.length; i++)
      if (map[i][0] === key) return map[i][1]
    return ""
  }

  function composeCombo(modifiers, key) {
    var kn = keyName(key)
    if (!kn) return ""
    var parts = modifierParts(modifiers)
    parts.push(kn)
    return parts.join(" + ")
  }

  function handleCaptureKey(event) {
    if (event.key === Qt.Key_Escape) {
      cancelCapture()
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Delete) {
      clearHotkey(captureTarget)
      event.accepted = true
      return
    }
    if (isModifierKey(event.key)) return // wait for a real key
    var combo = composeCombo(event.modifiers, event.key)
    if (!combo) {
      cancelCapture()
      return
    }
    applyCaptured(combo)
    event.accepted = true
  }

  // ---- bar glyph ----
  // Use the active profile's own configured icon rather than guessing from
  // the raw PipeWire node name (which rarely contains words like
  // "headphone"/"bluetooth"/"hdmi" and left the bar icon mismatched with
  // the icon picked in the profile editor).
  function outputGlyph() {
    if (!service) return defaultIcon
    var idx = service.currentProfileIndex()
    if (idx >= 0 && profiles[idx] && profiles[idx].icon) return profiles[idx].icon
    return defaultIcon
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: Qt.callLater(resolveService)

  Timer {
    interval: 1000
    repeat: true
    running: true
    onTriggered: if (!root.service) root.resolveService()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.outputGlyph()
    tooltipText: root.currentProfileName ? ("Audio: " + root.currentProfileName) : "Sound Switcher"

    onPressed: function(b) {
      if (b === Qt.RightButton) {
        var svc = root.resolveService()
        if (svc) svc.next()
      } else {
        root.toggle()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyHandler
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(560))

    Item {
      id: keyHandler
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (root.capturing) {
          root.handleCaptureKey(event)
          return
        }
        if (event.key === Qt.Key_Escape) {
          if (outputDropdown.popupOpen || inputDropdown.popupOpen) return
          root.close()
          event.accepted = true
        }
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: contentColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Column {
          id: contentColumn
          width: scrollArea.availableWidth
          spacing: Style.space(10)

          // ---- unified header ----
          Item {
            width: parent.width
            implicitHeight: Math.max(titleColumn.implicitHeight, Style.space(28))

            PanelActionButton {
              id: headerBackButton
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              visible: root.view !== "browse"
              iconText: "←"
              tooltipText: "Back"
              foreground: root.bar.foreground
              size: Style.space(28)
              fontSize: Style.font.iconLarge
              onClicked: root.goBack()
            }

            Text {
              id: headerIcon
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              visible: root.view === "browse"
              textFormat: Text.PlainText
              text: "󰓃"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.iconLarge
              width: Style.space(28)
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              id: titleColumn
              anchors.left: parent.left
              anchors.leftMargin: Style.space(28) + Style.space(8)
              anchors.right: headerAddButton.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: "Sound Switcher"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.headerSubtitle()
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
            }

            PanelActionButton {
              id: headerAddButton
              anchors.right: headerSettingsButton.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              visible: root.view === "browse"
              iconText: "󰐕"
              tooltipText: "New profile"
              foreground: root.bar.foreground
              size: Style.space(28)
              fontSize: Style.font.iconLarge
              onClicked: root.openAdd()
            }

            PanelActionButton {
              id: headerSettingsButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: root.view === "browse"
              iconText: "󰒓"
              tooltipText: "Options"
              foreground: root.bar.foreground
              size: Style.space(28)
              fontSize: Style.font.iconLarge
              onClicked: root.openSettings()
            }
          }

          PanelSeparator { foreground: root.bar.foreground }

          // ---- browse view ----
          Column {
            visible: root.view === "browse"
            width: parent.width
            spacing: Style.space(10)

          // ---- profiles ----
          PanelSectionHeader {
            text: "󱕂 PROFILES"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.body
          }

          Column {
            id: profilesColumn
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              id: profilesRepeater
              model: root.profiles

              ProfileRow {
                required property var modelData
                required property int index
                profile: modelData
                rowIndex: index
                width: parent.width
              }
            }

            Item {
              width: parent.width
              implicitHeight: emptyColumn.implicitHeight + Style.space(60)
              visible: root.profiles.length === 0

              Column {
                id: emptyColumn
                width: parent.width
                anchors.centerIn: parent
                spacing: Style.space(8)

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: "No profiles yet"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                  horizontalAlignment: Text.AlignHCenter
                }

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: "Click the + button to add a profile"
                  color: Qt.darker(root.bar.foreground, 1.6)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  horizontalAlignment: Text.AlignHCenter
                  wrapMode: Text.WordWrap
                }
              }
            }
          }
          }

          // ---- settings view ----
          Column {
            visible: root.view === "settings"
            width: parent.width
            spacing: Style.space(10)

            SectionHeader {
              iconGlyph: "󰇧"
              title: "GLOBAL KEYBINDS"
              hintVisible: root.capturing && (root.captureTarget === "previous" || root.captureTarget === "cycle")
              hintText: root.captureHintText()
            }

            HotkeyAssignRow {
              labelText: "Previous profile"
              value: root.previousHotkey
              captureId: "previous"
            }

            HotkeyAssignRow {
              labelText: "Next profile"
              value: root.cycleHotkey
              captureId: "cycle"
            }

            PanelSeparator { foreground: root.bar.foreground }

            SectionHeader {
              iconGlyph: "󰕾"
              title: "SOUND MUTING"
              hintVisible: root.capturing && root.captureTarget === "outmute"
              hintText: root.captureHintText()
            }

            HotkeyAssignRow {
              labelText: "Toggle mute (active profile)"
              value: root.outputMuteHotkey
              captureId: "outmute"
            }

            PanelSeparator { foreground: root.bar.foreground }

            SectionHeader {
              iconGlyph: "󰍬"
              title: "MICROPHONE MUTING"
              hintVisible: root.capturing && root.captureTarget === "micmute"
              hintText: root.captureHintText()
            }

            HotkeyAssignRow {
              labelText: "Toggle mute (active profile)"
              value: root.micMuteHotkey
              captureId: "micmute"
            }

            PanelSeparator { foreground: root.bar.foreground }

            SectionHeader {
              iconGlyph: "󰂚"
              title: "NOTIFICATION POSITION"
            }

            Row {
              width: parent.width
              spacing: Style.space(6)

              Button {
                text: "Off"
                foreground: root.bar.foreground
                selected: root.notificationPosition === "off"
                onClicked: {
                  var svc = root.resolveService()
                  if (svc) svc.setNotificationPosition("off")
                }
              }

              Button {
                text: "Top right"
                foreground: root.bar.foreground
                selected: root.notificationPosition === "top-right"
                onClicked: {
                  var svc = root.resolveService()
                  if (svc) svc.setNotificationPosition("top-right")
                }
              }

              Button {
                text: "Bottom center"
                foreground: root.bar.foreground
                selected: root.notificationPosition === "bottom-center"
                onClicked: {
                  var svc = root.resolveService()
                  if (svc) svc.setNotificationPosition("bottom-center")
                }
              }
            }

            PanelSeparator { foreground: root.bar.foreground }

            SectionHeader {
              iconGlyph: "󰑖"
              title: "FALLBACK PROFILE"
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: "Switched to automatically if the active profile's device disconnects."
              color: Qt.darker(root.bar.foreground, 1.6)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Flow {
              width: parent.width
              spacing: Style.space(6)

              Button {
                text: "None"
                foreground: root.bar.foreground
                selected: root.fallbackProfileName === ""
                onClicked: {
                  var svc = root.resolveService()
                  if (svc) svc.setFallbackProfile("")
                }
              }

              Repeater {
                model: root.profiles

                Button {
                  required property var modelData
                  text: String(modelData.name || "")
                  foreground: root.bar.foreground
                  selected: root.fallbackProfileName === modelData.name
                  onClicked: {
                    var svc = root.resolveService()
                    if (svc) svc.setFallbackProfile(modelData.name)
                  }
                }
              }
            }
          }

          // ---- add / edit form ----
          Column {
            visible: root.view === "form"
            width: parent.width
            spacing: Style.space(10)

            Flow {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.iconOptions

                Button {
                  required property var modelData
                  width: Style.space(40)
                  height: Style.space(40)
                  iconText: modelData.value
                  selected: root.formIcon === modelData.value
                  foreground: root.bar.foreground
                  iconSize: Style.font.iconLarge
                  onClicked: root.formIcon = modelData.value
                }
              }
            }

            TextField {
              id: nameField
              width: parent.width
              placeholderText: "Name"
              onTextChanged: root.formName = text
            }

            Column {
              width: parent.width
              spacing: Style.spacing.labelGap

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: "Output source"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
              }

              SearchableDropdown {
                id: outputDropdown
                width: parent.width
                options: root.outputOptions
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                onChanged: function(v) { root.formOutput = v }
              }
            }

            Column {
              width: parent.width
              spacing: Style.spacing.labelGap

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: "Input source"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
              }

              SearchableDropdown {
                id: inputDropdown
                width: parent.width
                options: root.inputOptions
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                onChanged: function(v) { root.formInput = v }
              }
            }

            HotkeyAssignRow {
              labelText: "Hotkey"
              value: root.formHotkey
              captureId: "form"
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              visible: root.nameDuplicate
              text: "A profile with this name already exists."
              color: root.bar ? root.bar.urgent : "#ff5555"
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Row {
              spacing: Style.space(8)

              Button {
                text: "Save"
                foreground: root.bar.foreground
                enabled: root.formComplete
                onClicked: root.saveForm()
              }
            }
          }

          // ---- confirm delete ----
          Column {
            visible: root.view === "confirmDelete"
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "󰆴 DELETING: " + (root.deleteIndex >= 0 && root.profiles[root.deleteIndex]
                ? root.profiles[root.deleteIndex].name : "Profile")
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.body
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: "Are you sure you want to delete this profile?"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Row {
              spacing: Style.space(8)

              Button {
                text: "Delete"
                foreground: root.bar.foreground
                onClicked: root.confirmDelete()
              }

              Button {
                text: "Cancel"
                foreground: root.bar.foreground
                onClicked: root.goBack()
              }
            }
          }
        }
      }
    }
  }

  // ---- inline components ----

  // Section header with a bright leading icon and a dimmed title (matching the
  // built-in PanelSectionHeader), plus an optional right-aligned hint.
  component SectionHeader: Item {
    property string iconGlyph: ""
    property string title: ""
    property bool hintVisible: false
    property string hintText: ""

    width: parent.width
    implicitHeight: Math.max(headerIcon.implicitHeight, headerTitle.implicitHeight)

    Text {
      id: headerIcon
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: iconGlyph
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
    }

    PanelSectionHeader {
      id: headerTitle
      anchors.left: headerIcon.right
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      text: title
      foreground: root.bar.foreground
      fontFamily: root.bar.fontFamily
      fontSize: Style.font.body
    }

    Text {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: hintVisible
      textFormat: Text.PlainText
      text: hintText
      color: Qt.darker(root.bar.foreground, 1.6)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  component HotkeyAssignRow: Item {
    property string labelText: ""
    property string value: ""
    property string captureId: ""
    property color rowForeground: root.bar.foreground

    width: parent.width
    implicitHeight: Math.max(infoColumn.implicitHeight, actionButton.implicitHeight) + Style.space(4)

    Column {
      id: infoColumn
      anchors.left: parent.left
      anchors.right: actionButton.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: labelText
        color: rowForeground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: value || "UNASSIGNED"
        color: Qt.darker(rowForeground, 1.6)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Button {
      id: actionButton
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      foreground: rowForeground
      text: (root.capturing && root.captureTarget === captureId)
        ? "Press keys…"
        : (value ? "Reassign" : "Assign")
      onClicked: {
        if (root.capturing && root.captureTarget === captureId) root.cancelCapture()
        else root.startCapture(captureId)
      }
    }
  }

  component ProfileRow: BorderSurface {
    id: row
    required property var profile
    required property int rowIndex

    property color foreground: root.bar.foreground
    readonly property bool isActive: root.currentProfileName === profile.name
    property bool suppressClick: false
    property real dragOffset: root.rowOffset(rowIndex)

    width: parent.width
    implicitHeight: Math.max(infoColumn.implicitHeight, actionsRow.implicitHeight) + Style.space(20)
    radius: Style.cornerRadius
    color: isActive ? Util.alpha(foreground, 0.14) : Util.alpha(foreground, 0.05)
    z: root.draggingIndex === rowIndex ? 2 : 0
    transform: Translate { y: row.dragOffset }

    Behavior on color { ColorAnimation { duration: 90 } }
    Behavior on dragOffset { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

    Timer {
      id: longPressTimer
      interval: 400
      repeat: false
      onTriggered: {
        row.suppressClick = true
        root.beginDrag(rowIndex)
      }
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor

      onPressed: {
        row.suppressClick = false
        longPressTimer.restart()
      }
      onPositionChanged: function(mouse) {
        if (root.draggingIndex === rowIndex) {
          var p = rowMouse.mapToItem(profilesColumn, mouse.x, mouse.y)
          root.updateDropTarget(p.y)
        }
      }
      onReleased: {
        longPressTimer.stop()
        if (root.draggingIndex === rowIndex) root.finishDrag()
      }
      onCanceled: {
        longPressTimer.stop()
        if (root.draggingIndex === rowIndex) root.finishDrag()
      }
      onClicked: {
        if (!row.suppressClick) root.activateProfile(rowIndex)
        row.suppressClick = false
      }
    }

    Row {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      Text {
        id: iconGlyph
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: profile.icon || root.defaultIcon
        color: foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.iconLarge
        width: Style.space(28)
        horizontalAlignment: Text.AlignHCenter
      }

      Column {
        id: infoColumn
        width: parent.width - actionsRow.width - iconGlyph.width - Style.space(16)
        spacing: Style.space(2)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: profile.name
          color: foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
          font.bold: root.currentProfileName === profile.name
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          visible: profile.hotkey !== ""
          text: profile.hotkey
          color: Qt.darker(foreground, 1.6)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Row {
        id: actionsRow
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        PanelActionButton {
          visible: profile.output !== ""
          iconText: root.outputMutedFor(profile) ? "󰖁" : "󰕾"
          tooltipText: root.outputMutedFor(profile) ? "Muted" : "Active"
          foreground: root.outputMutedFor(profile) ? root.bar.urgent : root.bar.foreground
          size: Style.space(28)
          fontSize: Style.font.iconLarge
          onClicked: {
            var svc = root.resolveService()
            if (svc) svc.toggleSinkMute(profile.output)
          }
        }

        PanelActionButton {
          visible: profile.input !== ""
          iconText: root.inputMutedFor(profile) ? "󰍭" : "󰍬"
          tooltipText: root.inputMutedFor(profile) ? "Muted" : "Active"
          foreground: root.inputMutedFor(profile) ? root.bar.urgent : root.bar.foreground
          size: Style.space(28)
          fontSize: Style.font.iconLarge
          onClicked: {
            var svc = root.resolveService()
            if (svc) svc.toggleSourceMute(profile.input)
          }
        }

        PanelActionButton {
          iconText: "󰏫"
          tooltipText: "Edit"
          foreground: root.bar.foreground
          size: Style.space(28)
          fontSize: Style.font.iconLarge
          onClicked: root.openEdit(rowIndex)
        }

        PanelActionButton {
          iconText: "✕"
          tooltipText: "Delete"
          foreground: root.bar.foreground
          hoverColor: root.bar.urgent
          size: Style.space(28)
          fontSize: Style.font.iconLarge
          onClicked: root.openDelete(rowIndex)
        }
      }
    }
  }
}
