# audio-input-priority

Tiny macOS background agent that keeps the **default input and output devices** on the best
available ones from your priority lists. Plug a USB mic in → it becomes the default. Unplug it →
the next one in the list takes over. Same for output (headphones → external display → speakers).

It also fixes the classic Bluetooth headphones problem: after a call macOS may leave the headset
in the low‑quality HFP profile (16 kHz mono) instead of A2DP. The agent moves input back to a
real microphone within ~1.5 s, and if the headset is still at 16 kHz while nobody records, bumps
its sample rate back up (checked every 10 s only while stuck). A macOS notification is shown on
every switch.

- Swift, single file, ~100 lines, no dependencies beyond CoreAudio / Foundation
- Event‑driven (CoreAudio property listeners), no polling, ~14 MB RSS, 0 % CPU when idle
- No permissions or TCC prompts: it never reads audio, it only changes the "default input" setting

## Install

```bash
git clone https://github.com/petrochen/audio-input-priority.git
cd audio-input-priority
make install
```

`make install` builds the binary to `~/bin/audio-input-priority`, writes the LaunchAgent to
`~/Library/LaunchAgents/com.apetrochenko.audio-input-priority.plist`, creates the config files
(if missing) and starts the agent. It starts automatically at every login.

## Configure priority

Edit `~/.config/audio-input-priority/devices` — one CoreAudio device name per line, best first.
Globs `*` and `?` are allowed (case-insensitive), handy for several AirPods with different names:

```
fifine Microphone
MX Brio
MacBook Pro Microphone
*Pods*
```

Rationale: any USB / built‑in microphone at 48 kHz beats a Bluetooth headset, whose mic runs over
HFP at 16 kHz mono. AirPods therefore come last — they win only on the go, when nothing else is
plugged in and the lid is closed.

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

```bash
make stop      # stop the agent (stays installed, will start again at next login)
make start     # start it again
make restart
make status    # running? + list of input devices
make log       # last 30 lines of ~/Library/Logs/audio-input-priority.log
```

To disable it permanently but keep the files:

```bash
launchctl bootout gui/$(id -u)/com.apetrochenko.audio-input-priority
mv ~/Library/LaunchAgents/com.apetrochenko.audio-input-priority.plist ~/Library/LaunchAgents/com.apetrochenko.audio-input-priority.plist.disabled
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
