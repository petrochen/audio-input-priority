# audio-input-priority

Tiny macOS background agent that keeps the **default input device** (microphone) on the best
available one from your priority list. Plug a USB mic in → it becomes the default. Unplug it →
the next one in the list takes over.

It also fixes the classic Bluetooth headphones problem: after a call macOS leaves the headset as
the input device, so it stays stuck in the low‑quality HFP profile (16 kHz mono) instead of A2DP.
Because Bluetooth headsets are not in the priority list, the agent moves input back to a real
microphone within ~1.5 s and the headphones return to stereo.

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
`~/Library/LaunchAgents/com.apetrochenko.audio-input-priority.plist`, creates the config file
(if missing) and starts the agent. It starts automatically at every login.

## Configure priority

Edit `~/.config/audio-input-priority/devices` — one CoreAudio device name per line, best first.
Globs `*` and `?` are allowed (case-insensitive), handy for several AirPods with different names:

```
*Pods*
fifine Microphone
MX Brio
MacBook Pro Microphone
```

Get exact device names (the `*` marks the current default):

```bash
audio-input-priority --list
```

The config is re‑read on every event, so changes apply without restarting.
Devices not in the list (e.g. Bluetooth headsets, iPhone Continuity mic) are never chosen.

> Note: because the agent enforces the list, picking a different microphone in
> **System Settings → Sound → Input** will be reverted. Per‑app selection inside Zoom / Meet /
> OBS is a separate setting and is not affected.

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
`44100` / `48000` with `2` channels = A2DP (music mode).

## License

MIT
