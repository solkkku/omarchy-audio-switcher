# Sound Switcher

An [Omarchy](https://omarchy.org/) Quattro shell plugin that switches between **audio profiles**. Each profile selects an output sink and an input source, and can be activated with its own hotkey. The bar icon cycles through profiles on right-click.

## Features

- **Profiles** — each has a name, an icon, an output sink, an optional input source, and a hotkey.
- **Bar widget** — left-click opens the panel; right-click cycles to the next profile.
- **Global keybinds** — assign *Previous profile*, *Next profile*, *Toggle sound mute*, and *Toggle mic mute*.
- **Per-profile hotkeys** — jump straight to a profile.
- **Mute indicators** — profile rows show sound and microphone mute state; click to toggle.
- **Notifications** — optional; bottom-center, top-right, or off.
- **Persistence** — the last active profile is restored after a reboot.
- **Fallback profile** — optionally switch to a chosen profile automatically when the active profile's output device disconnects, instead of leaving it to PipeWire/WirePlumber's own priority-based routing.

## Requirements

- Omarchy Quattro (the Quickshell-based shell).
- PipeWire + WirePlumber (the standard Omarchy audio stack).
- Python 3 (`/usr/bin/python3`) for the bundled hotkey-writer helper.
- util-linux `setsid` (`/usr/bin/setsid`) and `kill` (`/usr/bin/kill`), used to run helpers in their own process group and to enforce the execution deadline.
- Uses Omarchy-provided helpers: `omarchy-audio-output-set-default`, `omarchy-audio-input-set-default`, `omarchy-osd`, and `omarchy-notification-send`.

## Install

```sh
omarchy plugin add https://github.com/solkkku/omarchy-audio-switcher.git --enable
```

Optionally move the widget in the bar:

```sh
omarchy bar move io.github.solkkku.audio-switcher --section right
```

## Usage

Left-click the bar icon to open the panel.

- **Add a profile** — click the **+** in the header and fill in name, icon, output source, input source (optional), and hotkey.
- **Edit / delete** — use the pencil and X buttons on a row; deletion asks for confirmation.
- **Reorder** — click and hold a row, then drag it to a new position.
- **Global keybinds** — open the **Options** (cog) page and assign key combos. While capturing a key, press `Esc` to cancel or `Del` to clear it.
- **Notifications** — choose off, top-right, or bottom-center on the Options page.
- **Fallback profile** — on the Options page, pick a profile (or "None") to switch to automatically when the active profile's output device disconnects.

Hotkeys are written to a managed block in `~/.config/hypr/bindings.lua` and applied automatically.

## Configuration

Settings are stored inline on the plugin's entry in `~/.config/omarchy/shell.json`:

```json
{
  "id": "io.github.solkkku.audio-switcher",
  "cycleHotkey": "SUPER + F11",
  "previousHotkey": "SUPER + F10",
  "micMuteHotkey": "",
  "outputMuteHotkey": "",
  "notificationPosition": "off",
  "fallbackProfileName": "",
  "profiles": [
    {
      "name": "Headphones",
      "output": "alsa_output.pci-0000_00_1f.3.analog-stereo",
      "input": "alsa_input.pci-0000_00_1f.3.analog-stereo",
      "hotkey": "SUPER + F9",
      "icon": "󰋋"
    }
  ]
}
```

## Security

- **Bounded input.** Every value read from `shell.json` or received over IPC is
  sanitized before it is stored or rendered: control characters are stripped,
  each field has a length cap, the profile list is capped at 32 entries and an
  aggregate character budget, and hotkeys must match a strict `TOKEN + TOKEN`
  grammar. Notification positions are constrained to a fixed set.
- **No PATH lookups.** Omarchy helpers are invoked by absolute path with a
  closed, minimal environment (`PATH`, `HOME`, `XDG_RUNTIME_DIR` only), so the
  inherited shell environment cannot substitute a different binary.
- **Supervised helpers.** Each helper runs one job at a time in a dedicated
  process group (`setsid`) with a deadline: the watchdog terminates the whole
  group (so descendants that inherited the output pipes are reaped), then
  force-kills it. Output is consumed live and never buffered, and counts
  against a hard aggregate byte ceiling that ends the job immediately if
  exceeded.
- **Safe bindings writes.** `bindings.lua` is updated by a bundled helper that
  performs a descriptor-bound, no-follow, ownership-validated transaction:
  every path component is opened with `O_NOFOLLOW`; the target and its ancestors
  must be owned by the user and not group/other-writable; the existing file and
  the rendered result are both bounded before they are read or written; the
  result is written to an `O_EXCL` temp file and fsynced; and the file identity
  is re-checked immediately before an atomic rename, so a concurrent edit aborts
  (and is retried) instead of being overwritten. Unrelated content is preserved.

## Notes

- Silencing a sink owned by an external software mixer (e.g. GoXLR/OpenXLR) can be reverted by that mixer, so muting such a sink is best-effort. This affects any tool on the system, including Omarchy's own volume keys.
- The plugin is a `service` (logic, persistence, hotkey sync), a `bar-widget` (the panel), and a `panel` (the notification toast).

## Remove

```sh
omarchy plugin remove io.github.solkkku.audio-switcher
```

## License

MIT
