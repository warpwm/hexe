# Keybindings

Hexe mux keybindings are defined entirely in `mux.json` under `input.binds`.

This system is designed to:
- keep every bind explicit (no implicit defaults)
- allow context-sensitive behavior (split vs float focus)
- support advanced gestures (press/release/repeat/hold/double-tap)
- work across many terminals via progressive enhancement

## File locations

Hexe reads the mux config from:
- `$XDG_CONFIG_HOME/hexe/mux.json`
- or `~/.config/hexe/mux.json`

The repository also contains a template at `configs/hexa/mux.json`.

## Basic schema

```json
{
  "input": {
    "timing": {
      "hold_ms": 350,
      "double_tap_ms": 250
    },
    "binds": [
      {
        "when": "press",
        "mods": ["alt"],
        "key": "q",
        "context": {"focus": "any"},
        "action": {"type": "mux.quit"}
      }
    ]
  }
}
```

### `mods`

`mods` is an array of modifier names:
- `alt`
- `ctrl`
- `shift`
- `super`

### `key`

Supported key values:
- single characters like `"q"`, `"1"`, `"."`
- named keys: `"up"`, `"down"`, `"left"`, `"right"`, `"space"`

### `context`

`context` filters when a bind can fire.

Currently supported:
- `context.focus`: `any` | `split` | `float`

This enables "automatic context routing": the same key can do different things depending on whether a split or a float is focused.

### `action`

Actions are dispatchers that trigger mux operations.

Supported action types:
- `mux.quit`
- `mux.detach`
- `pane.disown`
- `pane.adopt`
- `split.h`
- `split.v`
- `tab.new`
- `tab.next`
- `tab.prev`
- `tab.close`
- `float.toggle` (requires `action.float`)
- `focus.move` (requires `action.dir`)

Action parameters:
- `float.toggle`: `{"type":"float.toggle","float":"p"}`
- `focus.move`: `{"type":"focus.move","dir":"left"}`

## Advanced gestures

These features are enabled by the kitty keyboard protocol when the terminal supports it.

### `when: press`

Runs when the key is pressed.

```json
{ "when": "press", "mods": ["alt"], "key": "t", "context": {"focus": "any"}, "action": {"type": "tab.new"} }
```

### `when: repeat`

Runs while the key is held and repeat events are generated.

Notes:
- If there is no `repeat` binding for the key, repeat events fall back to `press` behavior.
- Useful for repeating navigation actions.

```json
{ "when": "repeat", "mods": ["alt"], "key": "left", "context": {"focus": "any"}, "action": {"type": "focus.move", "dir": "left"} }
```

### `when: release`

Runs when the key is released.

Notes:
- Requires a terminal that supports kitty keyboard protocol event types.
- Release events are mux-only; they are not forwarded into panes.

```json
{ "when": "release", "mods": ["alt", "shift"], "key": "d", "context": {"focus": "any"}, "action": {"type": "mux.detach"} }
```

### `when: hold`

Runs once after the key has been held for a given duration.

Configuration:
- per-bind: `hold_ms`
- default: `input.timing.hold_ms`

Notes:
- Implemented as a mux timer.
- A key release cancels a pending hold.

```json
{ "when": "hold", "mods": ["alt"], "key": "q", "hold_ms": 600, "context": {"focus": "any"}, "action": {"type": "mux.quit"} }
```

### `when: double_tap`

Runs when the same key is pressed twice within a time window.

Configuration:
- per-bind: `double_tap_ms`
- default: `input.timing.double_tap_ms`

Notes:
- If a `double_tap` bind exists for a key chord, the normal `press` bind for that same chord is delayed until the double-tap window expires.
- If the second tap happens in time, the delayed single-press is cancelled.

```json
{ "when": "press", "mods": ["alt"], "key": "x", "context": {"focus": "any"}, "action": {"type": "tab.close"} }
{ "when": "double_tap", "mods": ["alt"], "key": "x", "context": {"focus": "any"}, "action": {"type": "mux.quit"} }
```

## Context-sensitive use cases

### Same key, different action depending on focus

```json
{ "mods": ["alt"], "key": "x", "when": "press", "context": {"focus": "float"}, "action": {"type": "tab.close"} }
{ "mods": ["alt"], "key": "x", "when": "press", "context": {"focus": "split"}, "action": {"type": "tab.close"} }
```

(Replace the actions with whatever you prefer. The important bit is `context.focus`.)

### Float toggles

Named floats are still configured under `floats[]` (command, size, style, attributes), and are triggered via binds:

```json
{ "mods": ["alt"], "key": "p", "when": "press", "context": {"focus": "any"}, "action": {"type": "float.toggle", "float": "p"} }
```

## Terminal support and fallback behavior

Hexe uses progressive enhancement:

- On mux start, Hexe enables kitty keyboard protocol (`CSI > ... u`).
- Terminals that support it will send CSI-u key events, including repeat/release if requested.
- Terminals that don't support it ignore the enable sequence and keep sending legacy escape sequences.
- For CSI-u key events that are not consumed by mux binds, Hexe translates them back into legacy bytes and forwards them into the focused pane.

Practical implications:
- Your binds work in many terminals (legacy parsing fallback).
- Release detection is best-effort and only active when the terminal reports release events.
