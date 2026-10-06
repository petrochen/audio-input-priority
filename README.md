# Audio Priority

A small macOS menu bar app that keeps the **default microphone and sound output on the best
available device**, by a priority list you control. Plug a USB mic in and it becomes the mic; unplug it
and the next one in the list takes over. Put AirPods in and sound goes there; take them off and it
goes back to the monitor or the speakers. macOS itself has no notion of priority: it picks whatever was
connected last, and falls back to whatever it likes.

It also fixes the classic Bluetooth headphone problem: after a call, macOS often leaves the headset in
the low‑quality headset profile (16 kHz, mono) instead of stereo. Audio Priority notices and puts it back.

**Privacy:** the app never reads audio, never records, never uses the network. It only changes the
“default device” settings through public CoreAudio APIs, so there are no microphone permission prompts.

- One Swift file, no dependencies, ~15 MB of RAM, 0 % CPU when idle (event driven, no polling)
- macOS 13 Ventura or newer; Apple silicon and Intel
- MIT license

## Install

### Download

1. Get `AudioPriority-<version>.zip` from [Releases](https://github.com/petrochen/audio-input-priority/releases), unzip, move `AudioPriority.app` to `/Applications`.
2. The app is not notarized (no Apple developer subscription), so the first launch is blocked. Either
   open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**, or clear the
   quarantine flag once in Terminal:
   ```bash
   xattr -dr com.apple.quarantine /Applications/AudioPriority.app
   ```
3. Launch it. The microphone icon appears in the menu bar and the Priority window opens once.
   Tick **Start at login** in the menu to keep it running.

### Homebrew (builds from source, no Gatekeeper dialog)

```bash
brew install petrochen/tap/audio-priority
audio-priority --register        # start now and at login; --unregister to stop
```

### From source

```bash
git clone https://github.com/petrochen/audio-input-priority.git
cd audio-input-priority
make install        # builds ~/Applications/AudioPriority.app, enables start at login, starts it
```

Needs the Xcode command line tools (`xcode-select --install`).

## The menu bar

The icon shows the **type of the current microphone** (USB mic, laptop, AirPods, headphones, camera,
iPhone…). It turns **yellow** when something is wrong (headphones stuck in headset mode, built‑in mic
selected with the lid closed) and gets a small **dot** when the app is not fully automatic (automation
off, or holding a manual choice). Hover for the current mic and output.

The menu:

- **In use by: Zoom** — which apps are recording right now, or _Nobody is recording_.
- Yellow warnings, when any.
- **Microphone** / **Sound output**: every device with its icon and a checkmark on the current one,
  the Bluetooth sample rate (16 kHz = headset mode), `lid closed` and `not in list` markers. Click a
  device to select it by hand. The app keeps that choice, whatever the device, until something is
  plugged in / unplugged or the lid opens / closes.
- A status line: automatic, holding your manual choice, or off. **Back to automatic now** appears while
  a manual choice is held; **Fix headphones stereo now** appears while a headset is stuck.
- **Automatic priority** — untick to switch the automation off. **Notify on switch**, **Add new wired
  devices to the lists**, **Start at login**. All survive restarts.
- **Priority…** (⌘,) opens the editor. **Open config folder**, **Show log**, **Sound settings…**, **Quit**.

## The Priority window

Two lists, microphone and sound output, best first. **Drag rows to reorder.** `●` means the device is
connected now, `○` not connected. **+** offers devices connected now, devices seen before, and device
classes; **−** removes a rule. Every change is saved and applied immediately.

Rules are matched top to bottom against the devices present; the first match wins. A rule is:

| Rule                                 | Matches                                                                  |
| ------------------------------------ | ------------------------------------------------------------------------ |
| `MacBook Pro Microphone`             | that exact device name                                                   |
| `*Pods*`                             | a glob (`*`, `?`, case‑insensitive): any AirPods, however they are named |
| `@wired`                             | USB, Thunderbolt, PCI, FireWire devices                                  |
| `@usb`                               | USB only                                                                 |
| `@builtin`                           | the built‑in mic / speakers                                              |
| `@airpods`                           | any AirPods                                                              |
| `@bluetooth`                         | any Bluetooth device                                                     |
| `@display`                           | a monitor over DisplayPort / HDMI                                        |
| `@continuity`                        | an iPhone / iPad (Continuity)                                            |
| `@airplay`, `@aggregate`, `@virtual` | AirPlay, aggregate devices, software devices (Teams, Zoom, BlackHole…)   |

**Devices matching no rule are never selected automatically.** That is the safety net: a Bluetooth
headset you did not list will never become the microphone and get stuck in headset mode.

The defaults, created on first run:

```
# microphone               # sound output
@wired                     @airpods
@airpods                   @bluetooth
@builtin                   @wired
                           @display
                           @builtin
```

The lists live in `~/.config/audio-input-priority/devices` and `outputs`, one rule per line, and can be
edited by hand too; they are re‑read on every event. `audio-input-priority --list` prints every device
with its class.

## How it decides

| Situation                                             | Microphone                         | Output                                    |
| ----------------------------------------------------- | ---------------------------------- | ----------------------------------------- |
| Desk: USB mic or webcam, external monitor, lid closed | the USB mic (built‑in is skipped)  | headphones if connected, else the monitor |
| Desk, lid open                                        | the USB mic                        | headphones, else the monitor              |
| On the go with AirPods                                | AirPods                            | AirPods                                   |
| On the go, nothing connected                          | built‑in mic                       | speakers                                  |
| Bluetooth headset not in the list (default)           | never; the mic stays on a real one | the headset, in stereo                    |
| You picked a device by hand                           | your pick, until devices change    | same                                      |

Other rules:

- **Lid closed:** the built‑in mic and speakers are skipped (the mic is muffled, the speakers are
  inaudible). macOS keeps them in the device list, so without this they would get picked. Opening or
  closing the lid re‑evaluates the lists. Can be turned off in the Priority window.
- **Headset mode:** when a Bluetooth output is at ≤ 16 kHz and nobody is recording, its sample rate is
  raised back to the maximum, which flips the headset back to stereo. Never during a call.
- **New devices:** a wired device the app has never seen is appended to the end of the lists, with a
  notification. A new Bluetooth device only gets a notification; add it in the Priority window if you
  want it chosen automatically.
- **Manual picks:** choosing a _listed_ device in System Settings, Control Center or an app that sets the
  system default is respected until devices change. Unlisted devices picked that way are reverted,
  because that is exactly how headsets get stuck. A pick from the app’s own menu is always respected.

## Command line

The binary inside the bundle works as a CLI (`make install` symlinks it to `~/bin/audio-input-priority`,
Homebrew installs it as `audio-priority`):

```
--list          devices with class, sample rate, current default, who is recording, warnings
--once          apply the lists once and exit (for scripts)
--register      enable start at login and start the agent
--unregister    disable start at login and stop it
--quiet         no notifications
```

Log: `~/Library/Logs/audio-input-priority.log`. In the source checkout `make status`, `make log`,
`make stop`, `make start`, `make uninstall` do what they say.

## Limitations

- Per‑app routing (music to the headphones, calls to the speakers) is out of scope; macOS has no API
  for it short of capturing and replaying the audio. Most call and music apps choose their own device
  in their settings, and the app does not interfere with that.
- macOS does not expose whether AirPods are in your ears. Connected AirPods left in a pocket will be
  treated as present. Put them in the case, or pick another mic from the menu.
- “In use by” needs macOS 14 or newer; on 13 the line says nobody is recording.
- Not notarized. See _Download_ above.

## Uninstall

Untick **Start at login**, quit, delete `AudioPriority.app`. Settings live in
`~/.config/audio-input-priority/` and in the `com.apetrochenko.audio-input-priority` defaults domain.
From a source checkout, `make uninstall` does all of it.

## Development

Everything is in `audio-input-priority.swift` (CoreAudio rules, menu bar, Priority window). Other files:
`Info.plist`, `AppIcon.icns` (made by `scripts/make-icon.swift`), `devices.example` / `outputs.example`,
`Makefile`.

| Command | What it does |
| --- | --- |
| `make app` | build `AudioPriority.app` next to the sources (ad‑hoc signed) |
| `make install` | build to `~/Applications`, symlink the CLI to `~/bin`, enable start at login, (re)start |
| `make status` / `make log` | launchd state + `--list`; last 30 log lines |
| `make stop` / `make start` / `make uninstall` | stop until next login / start / remove everything |
| `make icon` | regenerate `AppIcon.icns` |
| `make release` | `dist/AudioPriority-<version>.zip` for GitHub Releases |

State: rules in `~/.config/audio-input-priority/`, toggles and the list of devices seen so far in the
`com.apetrochenko.audio-input-priority` defaults domain (`auto`, `notify`, `autoAdd`, `lidSkip`,
`seen`, `onboarded`), the LaunchAgent in `~/Library/LaunchAgents/com.apetrochenko.audio-input-priority.plist`,
the log in `~/Library/Logs/`.

Releasing a version: bump `CFBundleShortVersionString` in `Info.plist`, commit, tag `vX.Y.Z`, push,
`make release`, `gh release create vX.Y.Z dist/AudioPriority-X.Y.Z.zip --notes-file CHANGELOG.md`,
then update `url` and `sha256` in `Formula/audio-priority.rb` of
[petrochen/homebrew-tap](https://github.com/petrochen/homebrew-tap)
(`curl -sL <tarball url> | shasum -a 256`).

Why not a notarized build: it needs an Apple developer subscription. The same reason the app writes its
own LaunchAgent instead of using the system Login Items API, which pins the binary's code hash and
refuses to launch an ad‑hoc signed app after every rebuild.

## Contributing

Issues with the output of `--list` and the last lines of the log are the most useful. The whole app is
`audio-input-priority.swift`; `make app` builds it, `make icon` regenerates the icon.

MIT © Alexander Petrochenko
