# Changelog

## 1.0.0 — 2026-10-06

First public release.

- Menu bar app: icon shows the type of the current microphone, turns yellow on problems, a dot when not fully automatic.
- Priority window: drag to reorder input / output rules, add connected or previously seen devices or device classes.
- Rules: device names, globs, device classes (`@wired`, `@airpods`, `@builtin`, …).
- Manual picks (menu, System Settings, Control Center, apps) are kept until devices change.
- Bluetooth headsets stuck in the 16 kHz headset profile after a call are returned to stereo.
- Built-in mic and speakers are skipped while the lid is closed.
- "In use by": which apps are recording right now.
- New wired devices join the end of the lists; new Bluetooth devices only get a notification.
- Start at login, native notifications, `--list` / `--once` CLI.
