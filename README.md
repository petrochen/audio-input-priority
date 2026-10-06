# audio-input-priority

Tiny macOS background agent that keeps the **default input and output devices** on the best
available ones from your priority lists. Plug a USB mic in → it becomes the default. Unplug it →
the next one in the list takes over. Same for output (headphones → external display → speakers).

It also fixes the classic Bluetooth headphones problem: after a call macOS may leave the headset
in the low‑quality HFP profile (16 kHz mono) instead of A2DP. The agent moves input back to a
real microphone within ~1.5 s, and if the headset is still at 16 kHz while nobody records, bumps
its sample rate back up (checked every 10 s only while stuck). A macOS notification is shown on
every switch.

- Menu bar icon: pick the microphone / output by hand, pause the automation, open the config and log
- Swift, single file, no dependencies beyond CoreAudio / AppKit / Foundation
- Event‑driven (CoreAudio property listeners), no polling, ~14 MB RSS, 0 % CPU when idle
- No permissions or TCC prompts: it never reads audio, it only changes the "default input" setting

## Install

```bash
git clone https://github.com/petrochen/audio-input-priority.git
cd audio-input-priority
make install
```

`make install` builds `~/Applications/AudioPriority.app` (menu bar only, no Dock icon), symlinks the
CLI to `~/bin/audio-input-priority`, enables **Start at login** (the app writes its own LaunchAgent to
`~/Library/LaunchAgents/`, with restart after a crash) and starts it. The log is at `~/Library/Logs/audio-input-priority.log`.

## Menu bar

The icon shows the **type of the current microphone** (USB mic, laptop, AirPods, headphones, camera…),
turns **yellow** when something is wrong (headphones stuck in headset mode, built‑in mic selected with the
lid closed) and gets a small **dot** when the agent is not fully automatic (automation off, or holding a
manual choice). Hover for a tooltip with the current mic and output.

The menu:

- **In use by: Zoom** — which apps are recording right now, or *Nobody is recording*.
- Yellow warnings, when any.
- **Microphone** / **Sound output**: every device with its icon, a checkmark on the current one, the
  Bluetooth sample rate (16 kHz = headset mode), `lid closed` and `not in list` markers. Click a device
  to select it by hand: the agent keeps that choice, whatever the device, until something is plugged in /
  unplugged or the lid opens / closes.
- A status line says what is in charge right now: automatic, holding your manual choice, or off.
  **Back to automatic now** appears only while a manual choice is held; **Fix headphones stereo now**
  appears only while a Bluetooth headset is stuck in headset mode.
- **Automatic priority**: untick to switch the automation off entirely. **Notify on switch**: banners on
  every automatic switch (native notifications, shown as *Audio Priority*). **Start at login**: writes or
  removes the LaunchAgent (`--register` / `--unregister` do the same from the terminal). All three
  survive restarts.
- **Edit priority lists…**, **Show log**, **Sound settings…**, **Quit** (the agent stays quit until the
  next login; it only auto‑restarts after a crash).

## Configure priority

Edit `~/.config/audio-input-priority/devices` — one CoreAudio device name per line, best first.
Globs `*` and `?` are allowed (case-insensitive), handy for several AirPods with different names:

```
fifine Microphone
MX Brio
*Pods*
MacBook Pro Microphone
```

Rationale: a USB microphone at 48 kHz beats everything else, so wired mics come first. AirPods come
before the built-in mic: when they are in your ears you are usually on the go or in a noisy room,
and a mic next to your mouth with noise cancellation wins over the laptop array.

**Manual picks are respected.** If you choose another *listed* device by hand (System Settings → Sound,
Control Center, or an app that changes the system default), the agent keeps it until a device is
plugged/unplugged or the lid opens/closes; then the priority list applies again. Devices that are not
in the list (e.g. a Sony headset after a call) are always reverted.

Get exact device names (the `*` marks the current default):

```bash
audio-input-priority --list
```

The config is re‑read on every event, so changes apply without restarting.
Devices not in the list (e.g. Bluetooth headsets, iPhone Continuity mic) are never chosen.

**Lid detection:** the built‑in microphone is skipped while the MacBook lid is closed (clamshell
mode with an external display) — macOS keeps it in the device list, but it sounds muffled there.
Opening or closing the lid re‑evaluates the priority immediately. `--list` shows the skip.

> Note: because the agent enforces the list, picking a different microphone in
> **System Settings → Sound → Input** will be reverted. Per‑app selection inside Zoom / Meet /
> OBS is a separate setting and is not affected.

## Configure output priority

Same format in `~/.config/audio-input-priority/outputs`:

```
*Pods*
WH-1000XM3
LG UltraFine Display Audio
MacBook Pro Speakers
```

Built‑in speakers are skipped while the lid is closed, so with an external display the display's
audio wins over the (inaudible) MacBook speakers. Both "default output" and "system output"
(alert sounds) are set together.

## Notifications

Every switch posts a macOS notification ("Microphone: MX Brio", "Sound output: …",
"Headphones: … back to stereo"). They are sent through `osascript`, so they appear under
**Script Editor** in System Settings → Notifications; disable them there, or start the agent
with `--quiet` (edit `ProgramArguments` in the plist).

## Turn it off / on

Untick **Automatic priority** in the menu to stop the automation but keep the icon; untick **Start at
login** so it does not come back after a reboot; **Quit** closes it until the next login. Or from the
terminal:

```bash
make stop      # stop the agent (stays installed, will start again at next login)
make start     # start it again
make restart
make status    # running? + list of devices, who is recording, warnings
make log       # last 30 lines of ~/Library/Logs/audio-input-priority.log
```

## Uninstall

```bash
make uninstall   # stops the agent, removes binary and LaunchAgent
rm -rf ~/.config/audio-input-priority ~/Library/Logs/audio-input-priority.log   # optional
```

## One‑shot use

Without the agent, you can apply the priority once (e.g. from a hotkey or script):

```bash
audio-input-priority --once
```

## How to check headphone mode

```bash
system_profiler SPAudioDataType | grep -A7 "WH-1000XM3:" | grep -E "Channels|SampleRate"
```

`Current SampleRate: 16000` with `Output Channels: 1` = HFP (call mode).
`44100` / `48000` with `2` channels = A2DP (music mode). `audio-input-priority --list` shows the
current rate next to every Bluetooth device.

## License

MIT
