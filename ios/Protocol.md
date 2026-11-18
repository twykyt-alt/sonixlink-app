# SonixLink BLE protocol

The SonixOS player advertises service `D54B0001-6B7D-4D13-A2F1-91F9B5D89001`.

- `D54B0002-6B7D-4D13-A2F1-91F9B5D89001`: read UTF-8 JSON playback state (`playing`, `paused`, `title`, `artist`, `position`, `duration`, `volume`).
- `D54B0003-6B7D-4D13-A2F1-91F9B5D89001`: write exactly one opcode byte plus a signed 32-bit little-endian argument.

Opcodes: `0` play, `1` pause, `2` toggle, `3` next, `4` previous, `5` seek in seconds, `6` set volume from 0 to 100. The app polls state every 1.5 seconds. BLE is local range only.
