import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire

// Headless service for the audio-switcher plugin. Owns config, switching,
// persistence, and the managed Hyprland binding block. The bar widget (Panel.qml)
// is a thin view over this object, reached via bar.shell.serviceFor(...).
Item {
  id: root

  property var shell: null
  property string omarchyPath: ""

  readonly property string home: Quickshell.env("HOME")
  readonly property string moduleName: "io.github.solkkku.audio-switcher"
  readonly property string shellConfigPath: home + "/.config/omarchy/shell.json"
  readonly property string defaultCycleHotkey: ""
  readonly property string defaultPreviousHotkey: ""
  readonly property string defaultNotificationPosition: "off"

  // ---------------- input limits ----------------
  // Values arrive from shell.json (hand-editable) and from IPC, so every field
  // is bounded before it is retained or rendered into the managed Lua block.
  // Counts, per-field lengths, the hotkey grammar, and an aggregate budget over
  // the whole profile list all have hard ceilings.
  readonly property int maxProfiles: 32
  readonly property int maxNameLength: 64
  readonly property int maxDeviceLength: 256
  readonly property int maxHotkeyLength: 64
  readonly property int maxIconCodepoints: 8
  readonly property int maxTotalChars: 16384
  readonly property var hotkeyPattern: /^[A-Za-z0-9]+(?: \+ [A-Za-z0-9]+)*$/
  readonly property var notificationPositions: ["off", "top-right", "bottom-center"]

  // ---------------- trusted helper identities ----------------
  // Absolute paths only: helpers are never resolved through PATH. The Omarchy
  // bin directory comes from the shell (OMARCHY_PATH), and the bundled writer
  // resolves relative to this QML file so a relocated plugin still finds it.
  readonly property string omarchyBin: String(omarchyPath || Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy").replace(/\/+$/, "") + "/bin"
  readonly property string audioOutputHelper: omarchyBin + "/omarchy-audio-output-set-default"
  readonly property string audioInputHelper: omarchyBin + "/omarchy-audio-input-set-default"
  readonly property string notificationHelper: omarchyBin + "/omarchy-notification-send"
  readonly property string osdHelper: omarchyBin + "/omarchy-osd"
  readonly property string pythonInterpreter: "/usr/bin/python3"
  readonly property string bindingsWriter: decodeURIComponent(String(Qt.resolvedUrl("bin/write-managed-bindings.py")).replace(/^file:\/\//, ""))
  readonly property string setsidBinary: "/usr/bin/setsid"
  readonly property string killBinary: "/usr/bin/kill"

  // The environment handed to helpers is closed (clearEnvironment) and then
  // populated with only what they need: a fixed PATH for their own tool
  // lookups, HOME for user-scoped state, and XDG_RUNTIME_DIR for the PipeWire
  // and D-Bus sockets.
  readonly property var helperEnvironment: ({
    "PATH": "/usr/local/bin:/usr/bin:/bin",
    "HOME": home,
    "XDG_RUNTIME_DIR": String(Quickshell.env("XDG_RUNTIME_DIR") || "")
  })

  // ---------------- config (read from shell.json) ----------------
  property var profiles: []
  property string cycleHotkey: defaultCycleHotkey
  property string previousHotkey: defaultPreviousHotkey
  property string micMuteHotkey: ""
  property string outputMuteHotkey: ""
  property string notificationPosition: defaultNotificationPosition
  property string fallbackProfileName: ""
  property bool configLoaded: false

  // ---------------- persistence ----------------
  property bool persistedLoaded: false

  // ---------------- live pipewire state ----------------
  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []
  readonly property var defaultSink: Pipewire.defaultAudioSink
  readonly property var defaultSource: Pipewire.defaultAudioSource
  readonly property string defaultSinkName: defaultSink ? String(defaultSink.name || "") : ""

  // Bind the nodes so their audio interface is live and writes (volume/mute)
  // propagate back to PipeWire.
  PwObjectTracker {
    objects: root.nodes
  }
  readonly property string currentProfileName: {
    var i = currentProfileIndex()
    return (i >= 0 && profiles[i]) ? String(profiles[i].name || "") : ""
  }
  property string lastResult: "ok"

  // ---------------- device option lists (reactive) ----------------
  readonly property var outputOptions: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.isSink && !n.isStream)
        list.push({ value: String(n.name || ""), label: deviceLabel(n) })
    }
    return list
  }

  readonly property var inputOptions: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || n.isSink || n.isStream || !isAudioSource(n)) continue
      var name = String(n.name || "")
      if (name === "quickshell") continue
      if (name.indexOf(".monitor") !== -1) continue
      list.push({ value: name, label: deviceLabel(n) })
    }
    return list
  }

  PersistentProperties {
    id: persisted
    reloadableId: "io.github.solkkku.audio-switcher"
    // lastProfile: whatever profile is actually active right now, including
    // an automatic fallback switch. preferredProfile: the profile the user
    // last explicitly chose - untouched by fallback - so a device that comes
    // back can be switched back to on its own.
    property string lastProfile: ""
    property string preferredProfile: ""
    onLoaded: {
      root.persistedLoaded = true
      // Migrate existing installs: seed the preference from the old single
      // field so a device that's already back is restored immediately
      // rather than waiting for the next explicit profile switch.
      if (!preferredProfile && lastProfile) preferredProfile = lastProfile
      root.applyPersistedProfile()
    }
  }

  FileView {
    id: shellConfigFile
    path: root.shellConfigPath
    watchChanges: true
    printErrors: false
    onLoaded: root.readConfig()
    onLoadFailed: root.readConfig()
    onFileChanged: reload()
  }

  // ---------------- supervised helper execution ----------------
  // External helpers run one job at a time, by absolute path, with a closed
  // environment and inside a dedicated process group (setsid), so the deadline
  // reaps descendants that inherited the output pipes. A watchdog terminates
  // the whole group, then force-kills it. Output is consumed live (never
  // buffered) and counts against a hard aggregate byte ceiling that ends the
  // job immediately when exceeded.
  property var jobQueue: []
  property var activeJob: null
  readonly property int helperTimeoutMs: 8000
  readonly property int maxHelperOutputBytes: 65536
  readonly property int maxHelperStderrChars: 512

  // Live aggregate accounting over both stdout and stderr. The parsers below
  // discard what they read; only the byte count and a bounded stderr tail are
  // kept, so a helper (or its descendant) that floods output cannot grow the
  // shell's memory before the watchdog fires.
  property int helperOutputBytes: 0
  property string helperStderrTail: ""
  property bool helperOutputCapped: false
  // Process group id of the current helper (== its pid under setsid). Captured
  // on start because the QML Process clears its own pid before `exited` fires.
  property int helperGroupId: 0
  property bool helperTeardown: false

  function enqueueJob(job) {
    job.retries = job.retries || 0
    job.label = job.label || String(job.argv[0])
    jobQueue.push(job)
    pumpJobs()
  }

  function runHelper(argv, label) {
    enqueueJob({ argv: argv, label: label })
  }

  function resetHelperOutput() {
    helperOutputBytes = 0
    helperStderrTail = ""
    helperOutputCapped = false
  }

  function utf8Length(s) {
    var n = 0
    for (var i = 0; i < s.length; i++) {
      var c = s.charCodeAt(i)
      if (c <= 0x7f) n += 1
      else if (c <= 0x7ff) n += 2
      else if (c >= 0xd800 && c <= 0xdbff) { n += 4; i++ }
      else n += 3
    }
    return n
  }

  function accountStdout(data) {
    helperOutputBytes += utf8Length(data)
    if (helperOutputBytes > maxHelperOutputBytes) capHelperOutput()
  }

  function accountStderr(data) {
    helperOutputBytes += utf8Length(data)
    if (helperStderrTail.length < maxHelperStderrChars)
      helperStderrTail = (helperStderrTail + data).slice(0, maxHelperStderrChars)
    if (helperOutputBytes > maxHelperOutputBytes) capHelperOutput()
  }

  // A helper that floods output is misbehaving: end the group now rather than
  // letting the 8-second deadline race a runaway writer.
  function capHelperOutput() {
    if (helperOutputCapped) return
    helperOutputCapped = true
    helperTeardown = true
    helperWatchdog.stop()
    console.warn("audio-switcher: helper output exceeded " + maxHelperOutputBytes + " bytes; killing group")
    signalHelperGroup("KILL")
  }

  // Signal the helper's whole process group. The group id equals the helper's
  // pid because setsid makes it the session/group leader. A separate one-shot
  // process is used because the QML Process can only signal a single pid.
  function signalHelperGroup(sigName) {
    if (!helperGroupId) return
    groupSignal.command = [killBinary, "-" + sigName, "--", "-" + helperGroupId]
    groupSignal.running = true
  }

  function pumpJobs() {
    if (activeJob || jobQueue.length === 0) return
    activeJob = jobQueue.shift()
    helperTeardown = false
    helperGroupId = 0
    resetHelperOutput()
    helper.command = [setsidBinary].concat(activeJob.argv)
    helper.running = true
    helperWatchdog.restart()
  }

  Process {
    id: helper
    clearEnvironment: true
    environment: root.helperEnvironment
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(data) { root.accountStdout(data) }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(data) { root.accountStderr(data) }
    }

    onProcessIdChanged: {
      var pid = helper.processId
      if (pid) root.helperGroupId = pid
    }

    onExited: function(exitCode, exitStatus) {
      helperWatchdog.stop()
      helperKill.stop()
      // If a deadline or output cap ended this job, the direct child may be
      // gone while descendants still hold the inherited pipes. SIGKILL the
      // whole group to reap them before the next job starts.
      if (root.helperTeardown) root.signalHelperGroup("KILL")
      var job = root.activeJob
      root.activeJob = null
      if (!job) return
      // Exit 3 is the writer's "changed underneath us" signal; retry a bounded
      // number of times before giving up.
      if (exitCode === 3 && job.retries > 0) {
        job.retries -= 1
        root.jobQueue.unshift(job)
        helperRetry.restart()
        return
      }
      if (exitCode !== 0) {
        var detail = root.helperStderrTail ? (": " + root.helperStderrTail.trim()) : ""
        console.warn("audio-switcher: " + job.label + " exited " + exitCode + detail)
      }
      if (typeof job.onExit === "function") job.onExit(exitCode)
      root.pumpJobs()
    }
  }

  Process {
    id: groupSignal
    clearEnvironment: true
    environment: root.helperEnvironment
  }

  Timer {
    id: helperWatchdog
    interval: root.helperTimeoutMs
    repeat: false
    onTriggered: {
      if (!helper.running) return
      root.helperTeardown = true
      console.warn("audio-switcher: helper exceeded " + root.helperTimeoutMs + "ms; terminating group")
      root.signalHelperGroup("TERM")
      helperKill.restart()
    }
  }

  Timer {
    id: helperKill
    interval: 2000
    repeat: false
    onTriggered: {
      // Last resort: force-kill the whole group if it ignored the terminate
      // request, and make sure the queue can never stall behind a stuck child.
      if (helper.running) {
        console.warn("audio-switcher: helper group ignored termination; killing")
        root.signalHelperGroup("KILL")
      } else if (root.activeJob) {
        root.activeJob = null
        root.pumpJobs()
      }
    }
  }

  Timer {
    id: helperRetry
    interval: 250
    repeat: false
    onTriggered: root.pumpJobs()
  }

  function deviceLabel(node) {
    var label = String(node.nickname || node.description || node.name || "")
    label = label.replace(/^sof-soundwire\s+/i, "")
    label = label.replace(/^built-?in audio\s+/i, "")
    label = label.replace(/\s+Output$/i, "")
    label = label.replace(/\s+Input$/i, "")
    return label
  }

  function isAudioSource(node) {
    if (!node) return false
    if (node.audio) return true
    var mediaClass = String(node.type || "")
    return mediaClass.indexOf("Audio/Source") !== -1
      || mediaClass.indexOf("AudioSource") !== -1
      || mediaClass.indexOf("Source") !== -1
  }

  // ---------------- config read ----------------
  function readConfig() {
    var text = String(shellConfigFile.text() || "")
    if (!text.trim()) return
    var entry = null
    try {
      entry = findEntry(JSON.parse(text))
    } catch (e) {
      console.warn("audio-switcher: shell.json parse failed: " + e)
      return
    }
    if (!entry) {
      profiles = []
      cycleHotkey = defaultCycleHotkey
      previousHotkey = defaultPreviousHotkey
      micMuteHotkey = ""
      outputMuteHotkey = ""
      notificationPosition = defaultNotificationPosition
      fallbackProfileName = ""
    } else {
      profiles = sanitizeProfileList(entry.profiles)
      cycleHotkey = sanitizeHotkey(entry.cycleHotkey)
      previousHotkey = sanitizeHotkey(entry.previousHotkey)
      micMuteHotkey = sanitizeHotkey(entry.micMuteHotkey)
      outputMuteHotkey = sanitizeHotkey(entry.outputMuteHotkey)
      notificationPosition = sanitizeNotificationPosition(entry.notificationPosition)
      // Validated against the just-loaded profile list: a renamed or deleted
      // profile silently clears the setting instead of pointing at nothing.
      fallbackProfileName = sanitizeFallbackProfileName(entry.fallbackProfileName, profiles)
    }
    configLoaded = true
    syncBindings()
  }

  function findEntry(parsed) {
    if (!parsed) return null
    var sections = ["left", "center", "right"]
    if (parsed.bar && parsed.bar.layout) {
      for (var s = 0; s < sections.length; s++) {
        var entries = parsed.bar.layout[sections[s]]
        if (!Array.isArray(entries)) continue
        for (var i = 0; i < entries.length; i++)
          if (entries[i] && String(entries[i].id) === moduleName) return entries[i]
      }
    }
    if (Array.isArray(parsed.plugins)) {
      for (var j = 0; j < parsed.plugins.length; j++)
        if (parsed.plugins[j] && String(parsed.plugins[j].id) === moduleName) return parsed.plugins[j]
    }
    return null
  }

  // Strip control characters and cap length. Applied to every free-form string
  // before it is stored, compared, or interpolated into the managed Lua block.
  function sanitizeText(value, maxLength) {
    var text = String(value === undefined || value === null ? "" : value)
    text = text.replace(/[\u0000-\u001f\u007f-\u009f]/g, "")
    if (text.length > maxLength) text = text.slice(0, maxLength)
    return text.trim()
  }

  // Icons are glyphs, not arbitrary text: keep at most a few code points and
  // drop anything non-printable.
  function sanitizeIcon(value) {
    var text = String(value === undefined || value === null ? "" : value)
    text = text.replace(/[\u0000-\u001f\u007f-\u009f]/g, "")
    var points = Array.from(text)
    if (points.length > maxIconCodepoints) points = points.slice(0, maxIconCodepoints)
    return points.join("")
  }

  // Hotkeys must match a strict "TOKEN + TOKEN" grammar. Anything that could
  // escape a Lua string literal (quotes, backslashes, newlines) is rejected
  // rather than escaped.
  function sanitizeHotkey(value) {
    var text = sanitizeText(value, maxHotkeyLength)
    if (!text) return ""
    text = text.replace(/\s*\+\s*/g, " + ")
    if (text.length > maxHotkeyLength) return ""
    return hotkeyPattern.test(text) ? text : ""
  }

  function sanitizeNotificationPosition(value) {
    var position = String(value === undefined || value === null ? "" : value).trim().toLowerCase()
    return notificationPositions.indexOf(position) !== -1 ? position : defaultNotificationPosition
  }

  // A fallback profile is referenced by name (like persisted.lastProfile),
  // so it survives reordering and only needs revalidating on rename/delete.
  function sanitizeFallbackProfileName(value, profileList) {
    var text = sanitizeText(value, maxNameLength)
    if (!text) return ""
    var list = profileList || profiles
    for (var i = 0; i < list.length; i++)
      if (list[i].name === text) return text
    return ""
  }

  function profileChars(profile) {
    return profile.name.length + profile.output.length + profile.input.length
      + profile.hotkey.length + profile.icon.length
  }

  function profilesChars(list) {
    var total = 0
    for (var i = 0; i < list.length; i++) total += profileChars(list[i])
    return total
  }

  function sanitizeProfile(p) {
    p = p || {}
    return {
      name: sanitizeText(p.name, maxNameLength),
      output: sanitizeText(p.output, maxDeviceLength),
      input: sanitizeText(p.input, maxDeviceLength),
      hotkey: sanitizeHotkey(p.hotkey),
      icon: sanitizeIcon(p.icon)
    }
  }

  // Bound the whole list, not just each entry: cap the count and stop once the
  // aggregate character budget is spent.
  function sanitizeProfileList(raw) {
    if (!Array.isArray(raw)) return []
    var list = []
    var total = 0
    for (var i = 0; i < raw.length && list.length < maxProfiles; i++) {
      var profile = sanitizeProfile(raw[i])
      var size = profileChars(profile)
      if (total + size > maxTotalChars) break
      total += size
      list.push(profile)
    }
    return list
  }

  // ---------------- device lookup / switching ----------------
  function findSink(name) {
    if (!name) return null
    var target = String(name)
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || !n.isSink || n.isStream) continue
      if (String(n.name || "") === target) return n
    }
    var lower = target.toLowerCase()
    for (var j = 0; j < nodes.length; j++) {
      var m = nodes[j]
      if (!m || !m.isSink || m.isStream) continue
      if (String(m.name || "").toLowerCase().indexOf(lower) !== -1) return m
    }
    return null
  }

  function findSource(name) {
    if (!name) return null
    var target = String(name)
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || n.isSink || n.isStream || !isAudioSource(n)) continue
      if (String(n.name || "") === target) return n
    }
    var lower = target.toLowerCase()
    for (var j = 0; j < nodes.length; j++) {
      var m = nodes[j]
      if (!m || m.isSink || m.isStream || !isAudioSource(m)) continue
      if (String(m.name || "").toLowerCase().indexOf(lower) !== -1) return m
    }
    return null
  }

  function isInputMuted(name) {
    if (!name) return false
    var src = findSource(name)
    return !!(src && src.audio && src.audio.muted)
  }

  function isOutputMuted(name) {
    if (!name) return false
    var sink = findSink(name)
    return !!(sink && sink.audio && sink.audio.muted)
  }

  function sinkMatches(sinkName, configured) {
    if (!configured || !sinkName) return false
    var c = String(configured).toLowerCase()
    var n = String(sinkName).toLowerCase()
    return n === c || n.indexOf(c) !== -1
  }

  function currentProfileIndex() {
    // Prefer the last-activated profile when its output matches the current
    // sink. Profiles may share an output (and input); matching by sink alone
    // would always resolve to the first such profile, so a click on the second
    // one would highlight the wrong row.
    var last = String(persisted.lastProfile || "")
    if (last) {
      for (var k = 0; k < profiles.length; k++) {
        if (profiles[k].name === last && sinkMatches(defaultSinkName, profiles[k].output))
          return k
      }
    }
    for (var i = 0; i < profiles.length; i++)
      if (sinkMatches(defaultSinkName, profiles[i].output)) return i
    return -1
  }

  function setDefaultSink(node) {
    if (!node) return false
    // The Quickshell preference is the immediate switch; the Omarchy helper
    // additionally persists the default and moves active streams.
    Pipewire.preferredDefaultAudioSink = node
    if (node.id !== undefined && node.name)
      runHelper([audioOutputHelper, String(node.id), sanitizeText(node.name, maxDeviceLength)], "audio output helper")
    return true
  }

  function setDefaultSource(node) {
    if (!node) return false
    Pipewire.preferredDefaultAudioSource = node
    if (node.id !== undefined && node.name)
      runHelper([audioInputHelper, String(node.id), sanitizeText(node.name, maxDeviceLength)], "audio input helper")
    return true
  }

  // remember=false marks a switch as involuntary (an automatic fallback),
  // so it doesn't overwrite what the user actually asked for.
  function switchProfile(p, remember) {
    if (remember === undefined) remember = true
    if (!p) {
      lastResult = "unknown"
      return lastResult
    }
    var okOut = setDefaultSink(findSink(p.output))
    var okIn = setDefaultSource(findSource(p.input))
    if (!okOut && !okIn) {
      lastResult = "unavailable"
      return lastResult
    }
    persisted.lastProfile = String(p.name || "")
    if (remember) persisted.preferredProfile = String(p.name || "")
    lastResult = "ok"
    notifyProfile(p)
    return lastResult
  }

  function notifyProfile(p) {
    var icon = sanitizeIcon(p.icon) || "󰓃"
    var name = sanitizeText(p.name, maxNameLength) || "Unnamed"
    if (notificationPosition === "off") return
    if (notificationPosition === "top-right") {
      runHelper([notificationHelper, "-g", icon, "-u", "low", "Profile switched", name], "notify")
    } else if (shell && typeof shell.summon === "function") {
      shell.summon(moduleName, JSON.stringify({ icon: icon, title: "Profile switched", body: name }))
    } else {
      runHelper([osdHelper, "-i", icon, "-m", name], "osd")
    }
  }

  function toggleSourceNode(src) {
    if (!src || !src.audio) {
      lastResult = "unavailable"
      return lastResult
    }
    src.audio.muted = !src.audio.muted
    lastResult = "ok"
    notifyMicMute(src.audio.muted)
    return lastResult
  }

  function toggleMicMute() {
    return toggleSourceNode(sourceForActiveProfile())
  }

  function toggleSourceMute(name) {
    return toggleSourceNode(findSource(name))
  }

  function toggleSinkMute(name) {
    return toggleSinkNode(findSink(name))
  }

  function sourceForActiveProfile() {
    var idx = currentProfileIndex()
    if (idx >= 0 && profiles[idx]) {
      var inputName = String(profiles[idx].input || "")
      if (inputName) {
        var src = findSource(inputName)
        if (src) return src
      }
    }
    return defaultSource
  }

  function notifyMicMute(muted) {
    if (notificationPosition === "off") return
    var icon = muted ? "󰍭" : "󰍬"
    var title = muted ? "Microphone muted" : "Microphone active"
    if (notificationPosition === "top-right") {
      runHelper([notificationHelper, "-g", icon, "-u", "low", title], "notify")
    } else if (shell && typeof shell.summon === "function") {
      shell.summon(moduleName, JSON.stringify({ icon: icon, title: title, body: "" }))
    }
  }

  // Toggle a node's mute and notify. Best-effort: a sink owned by an external
  // software mixer (e.g. GoXLR/OpenXLR) can revert out-of-band mute changes.
  function toggleSinkNode(sink) {
    if (!sink || !sink.audio) {
      lastResult = "unavailable"
      return lastResult
    }
    sink.audio.muted = !sink.audio.muted
    lastResult = "ok"
    notifyOutputMute(sink.audio.muted)
    return lastResult
  }

  function toggleOutputMute() {
    return toggleSinkNode(sinkForActiveProfile())
  }

  function sinkForActiveProfile() {
    var idx = currentProfileIndex()
    if (idx >= 0 && profiles[idx]) {
      var outputName = String(profiles[idx].output || "")
      if (outputName) {
        var sink = findSink(outputName)
        if (sink) return sink
      }
    }
    return defaultSink
  }

  function notifyOutputMute(muted) {
    if (notificationPosition === "off") return
    var icon = muted ? "󰖁" : "󰕾"
    var title = muted ? "Output muted" : "Output active"
    if (notificationPosition === "top-right") {
      runHelper([notificationHelper, "-g", icon, "-u", "low", title], "notify")
    } else if (shell && typeof shell.summon === "function") {
      shell.summon(moduleName, JSON.stringify({ icon: icon, title: title, body: "" }))
    }
  }

  function activate(index) {
    var i = parseIndex(index)
    var p = profiles[i]
    if (!p) {
      lastResult = "unknown"
      return lastResult
    }
    return switchProfile(p)
  }

  function next() {
    var n = profiles.length
    if (n === 0) {
      lastResult = "none"
      return lastResult
    }
    var idx = currentProfileIndex()
    var nextIdx = idx === -1 ? 0 : (idx + 1) % n
    return switchProfile(profiles[nextIdx])
  }

  function previous() {
    var n = profiles.length
    if (n === 0) {
      lastResult = "none"
      return lastResult
    }
    var idx = currentProfileIndex()
    var prevIdx = idx === -1 ? n - 1 : (idx - 1 + n) % n
    return switchProfile(profiles[prevIdx])
  }

  function applyPersistedProfile() {
    if (!persistedLoaded || !configLoaded) return
    // Restore the user's actual preference, not just whatever was last
    // active - those differ when the session ended on an automatic
    // fallback (e.g. shut down with the Bluetooth earbuds disconnected).
    var last = String(persisted.preferredProfile || "")
    if (!last) {
      applyTimer.stop()
      return
    }
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].name !== last) continue
      if (currentProfileIndex() === i) {
        applyTimer.stop()
        return
      }
      if (!findSink(profiles[i].output)) return // device not present yet; keep polling
      switchProfile(profiles[i])
      applyTimer.stop()
      return
    }
    applyTimer.stop()
  }

  Timer {
    id: applyTimer
    interval: 4000
    repeat: true
    running: true
    onTriggered: root.applyPersistedProfile()
  }

  // ---------------- automatic fallback on disconnect ----------------
  // PipeWire/WirePlumber picks its own replacement default sink when the
  // active one disappears, based on ALSA/bluez priorities that don't know
  // about these profiles (e.g. an always-present headphone jack can outrank
  // a real speaker). If the user has configured a fallback profile, switch
  // to it explicitly the moment the currently active profile's output
  // device goes away, overriding whatever WirePlumber picked.
  readonly property string activeProfileOutput: {
    var last = String(persisted.lastProfile || "")
    for (var i = 0; i < profiles.length; i++)
      if (profiles[i].name === last) return String(profiles[i].output || "")
    return ""
  }
  readonly property bool activeDeviceAvailable: !activeProfileOutput || !!findSink(activeProfileOutput)

  onActiveDeviceAvailableChanged: {
    if (!activeDeviceAvailable) applyFallbackProfile()
  }

  function applyFallbackProfile() {
    if (!fallbackProfileName || fallbackProfileName === persisted.lastProfile) return
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].name !== fallbackProfileName) continue
      if (!findSink(profiles[i].output)) return // fallback device also unavailable
      switchProfile(profiles[i], false) // involuntary: don't overwrite the real preference
      return
    }
  }

  function setFallbackProfile(name) {
    fallbackProfileName = sanitizeFallbackProfileName(name, profiles)
    writeConfig()
    return "ok"
  }

  // ---------------- automatic restore when the preferred device returns ----
  // The counterpart to the fallback above: once the profile the user
  // actually chose has its device back, switch to it - e.g. the Bluetooth
  // earbuds reconnecting after having fallen back to the speakers.
  readonly property string preferredProfileOutput: {
    var pref = String(persisted.preferredProfile || "")
    for (var i = 0; i < profiles.length; i++)
      if (profiles[i].name === pref) return String(profiles[i].output || "")
    return ""
  }
  readonly property bool preferredDeviceAvailable: !preferredProfileOutput || !!findSink(preferredProfileOutput)

  onPreferredDeviceAvailableChanged: {
    if (preferredDeviceAvailable) restorePreferredProfile()
  }

  function restorePreferredProfile() {
    var pref = String(persisted.preferredProfile || "")
    if (!pref || pref === persisted.lastProfile) return // already active
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].name !== pref) continue
      if (!findSink(profiles[i].output)) return
      switchProfile(profiles[i])
      return
    }
  }

  // ---------------- config write ----------------
  function writeConfig() {
    if (shell && typeof shell.updateEntryInline === "function")
      shell.updateEntryInline(moduleName, {
        cycleHotkey: cycleHotkey,
        previousHotkey: previousHotkey,
        micMuteHotkey: micMuteHotkey,
        outputMuteHotkey: outputMuteHotkey,
        notificationPosition: notificationPosition,
        fallbackProfileName: fallbackProfileName,
        profiles: profiles
      })
    syncBindings()
  }

  function parseIndex(value) {
    var index = parseInt(value, 10)
    return isFinite(index) ? index : -1
  }

  // Human labels for the four global (non-profile) shortcuts, used when
  // reporting a hotkey that is already taken.
  readonly property var globalHotkeyLabels: ({
    "cycle": "Next profile",
    "previous": "Previous profile",
    "micmute": "Toggle mic mute",
    "outmute": "Toggle sound mute"
  })

  function globalHotkeyValue(id) {
    if (id === "cycle") return cycleHotkey
    if (id === "previous") return previousHotkey
    if (id === "micmute") return micMuteHotkey
    if (id === "outmute") return outputMuteHotkey
    return ""
  }

  // Owner of `combo`, or null when it is free. Profile hotkeys are matched
  // against every profile except `exceptProfileIndex` (so a profile never
  // conflicts with itself while editing); the global shortcuts are matched
  // except `exceptGlobal`. Callers render the returned {kind, name}.
  function hotkeyConflictOwner(combo, exceptProfileIndex, exceptGlobal) {
    var key = sanitizeHotkey(combo)
    if (!key) return null
    var skip = parseIndex(exceptProfileIndex)
    for (var i = 0; i < profiles.length; i++) {
      if (i === skip) continue
      if (sanitizeHotkey(profiles[i].hotkey) === key)
        return { kind: "profile", name: String(profiles[i].name || "") || "Unnamed profile" }
    }
    var ids = ["cycle", "previous", "micmute", "outmute"]
    for (var j = 0; j < ids.length; j++) {
      if (ids[j] === exceptGlobal) continue
      if (sanitizeHotkey(globalHotkeyValue(ids[j])) === key)
        return { kind: "global", name: globalHotkeyLabels[ids[j]] }
    }
    return null
  }

  // Ready-to-render warning for a conflicting combo, or "" when it is free.
  function hotkeyConflictMessage(combo, exceptProfileIndex, exceptGlobal) {
    var owner = hotkeyConflictOwner(combo, exceptProfileIndex, exceptGlobal)
    if (!owner) return ""
    if (owner.kind === "global") return 'Hotkey already used by the "' + owner.name + '" shortcut.'
    return 'Hotkey already used by "' + owner.name + '".'
  }

  function setCycleHotkey(combo) {
    if (hotkeyConflictOwner(combo, -1, "cycle")) return "duplicate"
    cycleHotkey = sanitizeHotkey(combo)
    writeConfig()
    return "ok"
  }

  function setPreviousHotkey(combo) {
    if (hotkeyConflictOwner(combo, -1, "previous")) return "duplicate"
    previousHotkey = sanitizeHotkey(combo)
    writeConfig()
    return "ok"
  }

  function setMicMuteHotkey(combo) {
    if (hotkeyConflictOwner(combo, -1, "micmute")) return "duplicate"
    micMuteHotkey = sanitizeHotkey(combo)
    writeConfig()
    return "ok"
  }

  function setOutputMuteHotkey(combo) {
    if (hotkeyConflictOwner(combo, -1, "outmute")) return "duplicate"
    outputMuteHotkey = sanitizeHotkey(combo)
    writeConfig()
    return "ok"
  }

  function setNotificationPosition(pos) {
    notificationPosition = sanitizeNotificationPosition(pos)
    writeConfig()
    return "ok"
  }

  function addProfile(name, output, input, hotkey, icon) {
    if (profiles.length >= maxProfiles) return "limit"
    var profile = sanitizeProfile({ name: name, output: output, input: input, hotkey: hotkey, icon: icon })
    if (hotkeyConflictOwner(profile.hotkey, -1, "")) return "duplicate"
    var list = profiles.map(cloneProfile)
    if (profilesChars(list) + profileChars(profile) > maxTotalChars) return "limit"
    list.push(profile)
    profiles = list
    writeConfig()
    return "ok"
  }

  function updateProfile(index, name, output, input, hotkey, icon) {
    var i = parseIndex(index)
    if (i < 0 || i >= profiles.length) return "unknown"
    var profile = sanitizeProfile({ name: name, output: output, input: input, hotkey: hotkey, icon: icon })
    // Exclude the profile being edited so keeping its own hotkey is allowed.
    if (hotkeyConflictOwner(profile.hotkey, i, "")) return "duplicate"
    var list = profiles.map(cloneProfile)
    var total = profilesChars(list) - profileChars(list[i]) + profileChars(profile)
    if (total > maxTotalChars) return "limit"
    list[i] = profile
    profiles = list
    writeConfig()
    return "ok"
  }

  function removeProfile(index) {
    var i = parseIndex(index)
    if (i < 0 || i >= profiles.length) return "unknown"
    var list = profiles.map(cloneProfile)
    list.splice(i, 1)
    profiles = list
    writeConfig()
    return "ok"
  }

  function moveProfile(from, to) {
    var f = parseIndex(from)
    var t = parseIndex(to)
    if (f < 0 || f >= profiles.length || t < 0 || t >= profiles.length) return "unknown"
    var list = profiles.map(cloneProfile)
    var item = list.splice(f, 1)[0]
    list.splice(t, 0, item)
    profiles = list
    writeConfig()
    return "ok"
  }

  function cloneProfile(p) {
    return { name: p.name, output: p.output, input: p.input, hotkey: p.hotkey, icon: p.icon }
  }

  function statusJson() {
    return JSON.stringify({
      currentProfile: currentProfileName,
      defaultSink: defaultSinkName,
      cycleHotkey: cycleHotkey,
      previousHotkey: previousHotkey,
      micMuteHotkey: micMuteHotkey,
      outputMuteHotkey: outputMuteHotkey,
      notificationPosition: notificationPosition,
      fallbackProfileName: fallbackProfileName,
      profiles: profiles
    })
  }

  // ---------------- hotkey sync (managed block in bindings.lua) ----------------
  function luaString(s) {
    return '"' + String(s || "").replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"'
  }

  function buildBindingsBlock() {
    var lines = []
    for (var i = 0; i < profiles.length; i++) {
      var p = profiles[i]
      var key = String(p.hotkey || "").trim()
      if (!key) continue
      lines.push("hl.unbind(" + luaString(key) + ")")
      lines.push("o.bind(" + luaString(key) + ", " + luaString("Profile: " + (p.name || "")) + ", "
        + luaString("omarchy-shell io.github.solkkku.audio-switcher activate " + i) + ", { locked = true })")
    }
    var prev = String(previousHotkey || "").trim()
    if (prev) {
      lines.push("hl.unbind(" + luaString(prev) + ")")
      lines.push("o.bind(" + luaString(prev) + ", " + luaString("Previous audio profile") + ", "
        + luaString("omarchy-shell io.github.solkkku.audio-switcher previous") + ", { locked = true })")
    }
    var cyc = String(cycleHotkey || "").trim()
    if (cyc) {
      lines.push("hl.unbind(" + luaString(cyc) + ")")
      lines.push("o.bind(" + luaString(cyc) + ", " + luaString("Next audio profile") + ", "
        + luaString("omarchy-shell io.github.solkkku.audio-switcher next") + ", { locked = true })")
    }
    var mic = String(micMuteHotkey || "").trim()
    if (mic) {
      lines.push("hl.unbind(" + luaString(mic) + ")")
      lines.push("o.bind(" + luaString(mic) + ", " + luaString("Toggle mic mute for selected profile") + ", "
        + luaString("omarchy-shell io.github.solkkku.audio-switcher toggleMicMute") + ", { locked = true })")
    }
    var out = String(outputMuteHotkey || "").trim()
    if (out) {
      lines.push("hl.unbind(" + luaString(out) + ")")
      lines.push("o.bind(" + luaString(out) + ", " + luaString("Toggle output mute for selected profile") + ", "
        + luaString("omarchy-shell io.github.solkkku.audio-switcher toggleOutputMute") + ", { locked = true })")
    }
    return lines.join("\n")
  }

  // The managed block is handed to a supervised helper that performs a
  // descriptor-bound, no-follow, ownership-validated transaction. The plugin
  // never rewrites bindings.lua itself, and unrelated content is preserved.
  property string syncedBindingsBlock: ""

  function syncBindings() {
    if (!configLoaded) return
    var block = buildBindingsBlock()
    if (block === syncedBindingsBlock) return
    enqueueJob({
      argv: [pythonInterpreter, bindingsWriter, block],
      retries: 4,
      label: "bindings writer",
      onExit: function(code) {
        root.syncedBindingsBlock = (code === 0) ? block : ""
      }
    })
  }

  Component.onCompleted: readConfig()

  IpcHandler {
    target: "io.github.solkkku.audio-switcher"

    function activate(index: string): string { return root.activate(index) }
    function next(): string { return root.next() }
    function previous(): string { return root.previous() }
    function toggleMicMute(): string { return root.toggleMicMute() }
    function toggleSourceMute(name: string): string { return root.toggleSourceMute(name) }
    function toggleSinkMute(name: string): string { return root.toggleSinkMute(name) }
    function toggleOutputMute(): string { return root.toggleOutputMute() }
    function status(): string { return root.statusJson() }
    function outputs(): string { return JSON.stringify(root.outputOptions) }
    function inputs(): string { return JSON.stringify(root.inputOptions) }
    function setCycleHotkey(combo: string): string { return root.setCycleHotkey(combo) }
    function setPreviousHotkey(combo: string): string { return root.setPreviousHotkey(combo) }
    function setMicMuteHotkey(combo: string): string { return root.setMicMuteHotkey(combo) }
    function setOutputMuteHotkey(combo: string): string { return root.setOutputMuteHotkey(combo) }
    function setNotificationPosition(pos: string): string { return root.setNotificationPosition(pos) }
    function setFallbackProfile(name: string): string { return root.setFallbackProfile(name) }
    function hotkeyConflict(combo: string, index: string, global: string): string { return root.hotkeyConflictMessage(combo, index, global) }
    function addProfile(name: string, output: string, input: string, hotkey: string, icon: string): string { return root.addProfile(name, output, input, hotkey, icon) }
    function updateProfile(index: string, name: string, output: string, input: string, hotkey: string, icon: string): string { return root.updateProfile(index, name, output, input, hotkey, icon) }
    function removeProfile(index: string): string { return root.removeProfile(index) }
    function moveProfile(from: string, to: string): string { return root.moveProfile(from, to) }
  }
}
