Kitty Keyboard Protocol + Keybind Semantics

This project supports keybindings using the kitty keyboard protocol (CSI `... u`).
The main goal is to make "press", "hold", and "repeat" behavior depend on the
primary key (e.g. an arrow key), while treating modifiers (Alt/Ctrl/Shift/Super)
as a chord that stays logically attached to that key interaction.

Key Concepts

1) The primary key repeats, not the modifier

Example: `Alt+Up`
- The user is conceptually interacting with the `Up` key.
- `Alt` is a modifier that should remain logically part of the chord.

2) Tap/Press vs Hold vs Repeat

- PRESS: `Alt+Up` is pressed and released without exceeding the hold threshold.
  If both keys are released (even if the modifier is released first), this should
  resolve as a normal press/tap interaction.

- HOLD: the user keeps the chord held past the hold timeout.
  The hold binding fires once after `hold_ms`.

- REPEAT: the primary key repeats (either via terminal repeat events or via fast
  repeated presses of the same key), while the modifier set stays active.
  Repeat bindings should fire continuously.

3) Modifiers must be stable across press/repeat/release

Some terminals can report modifier state differently across the event stream.
In particular:
- The user might release the modifier before the primary key.
- The terminal might emit repeat/release events with modifier bits missing.

To keep keybind logic deterministic, the implementation should "latch" the
modifier set seen on the original press and reuse it for repeat/release
processing of the same key until the interaction is resolved.

Kitty Event Format (Minimal)

The kitty protocol can encode key events as:

  CSI <keycode> ; <mod> : <event> u

Where:
- <mod> is xterm-style (mod-1) mask encoded as a 1..16 value.
- <event> is optional:
  - 1 = press
  - 2 = repeat
  - 3 = release

Practical Guidance

- Treat repeat and release as belonging to the *original press* chord.
- If the modifier changes order (e.g. Alt released before Up), do NOT
  accidentally reinterpret the final release as a different chord.
- Only interpret HOLD/REPEAT behaviors when the key is still being held and
  the interaction has crossed the configured time thresholds.
