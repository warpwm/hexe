# Hexa

A terminal multiplexer, session manager, and shell prompt renderer jammed into one.

Hexa is built around a flipped architecture: the UI is disposable, your shells are not.
Crash the UI, restart it, reattach, keep going.

---

## What you get

- A fast terminal multiplexer (`hexa mux`) with tabs, splits, floats, popups, and notifications.
- A session daemon (`hexa ses`) that tracks sessions, panes, and layouts.
- Per-pane pods (`hexa pod`) that own PTYs, keep processes alive, and buffer output.
- A prompt renderer (`hexa shp`) that can power your shell prompt and mux status bar.

---

## Architecture (the cool part)

Traditional multiplexers often tie UI and process ownership together.
If the UI dies at the wrong time, you lose state or your PTYs get stuck.

Hexa splits responsibilities on purpose:

- hexa-mux (UI)
  - Rendering, tabs/splits layout, keybinds, mouse handling
  - Runs Ghostty VT state per pane
  - Safe to restart

- hexa-pod (one per pane)
  - Owns the PTY master file descriptor
  - Spawns/holds the shell process
  - Continuously drains PTY output so processes do not block
  - Buffers scrollback so detach/reattach does not lose history

- hexa-ses (registry)
  - Knows what panes exist and where their pods are
  - Stores detached session layouts
  - Periodically persists state so a daemon crash is survivable

This is the foundation for:

- Persistent scrollback
- Surviving mux crashes
- Detach/reattach without killing your shell processes

---

## Features

### Multiplexer (mux)

- Tabs
- Splits
- Floating panes
  - Includes sticky floats that survive mux restarts
- Pane adoption
  - Adopt an orphaned pane into the current mux
  - Swap panes or destroy the current pane during adopt
- Detach and reattach sessions
- Notifications and popup UI
  - Confirm dialogs
  - Picker/choose dialogs
  - Pane-level and mux-level notifications

### Persistent scrollback

Hexa keeps scrollback even across detach/reattach.

How:

- Pods continuously record PTY output into a ring buffer.
- On reattach, mux reconnects to the pod and replays backlog.
- Ghostty VT rebuilds the terminal history from the replayed stream.

Result: detach, do work, reattach, and your output is still there.

### Clipboard and OSC

Hexa runs a VT inside mux, which means control sequences like OSC are not automatically visible to the host terminal.

Hexa forwards important OSC sequences to the host terminal, including:

- OSC 52 clipboard
- OSC 4 / 10-19 / 104 / 110-119 color palette sequences (pywal-friendly)
- OSC 0/1/2 title/icon
- OSC 7 cwd URL

Color queries:

- If an app inside a pane asks the terminal for colors (OSC color queries), Hexa forwards the query to the host terminal and routes the reply back into the correct pane.

### Colors (pywal-friendly)

Hexa preserves 256-color palette indices (SGR 38;5 / 48;5).
This matters because tools like pywal update the host terminal palette and then expect applications to keep using palette indices.

If you use scripts that emit OSC 4/10/11 etc (pywal and friends), Hexa forwards those sequences so the host terminal palette updates live.

### Shell prompt renderer (shp)

Hexa includes a prompt renderer you can use for bash, zsh, and fish.

- Left and right prompt rendering
- Segment system (git, directory, time, cpu, memory, battery, jobs, duration, etc.)
- Used by the mux status bar too

---

## Getting started

### Build

Hexa is a Zig project.

Always build with ReleaseFast:

- zig build -Doptimize=ReleaseFast

### Run

Start the session daemon:

- hexa ses daemon

Start a mux:

- hexa mux new

Detach (keeps panes alive), then reattach:

- hexa mux --attach <session-uuid-or-prefix>

List what is available to attach:

- hexa mux --list

---

## Configuration

Config is read from:

- ~/.config/hexa/

State is stored under XDG state home (by default):

- ~/.local/state/hexa/

---

## Project status

This is a new project and it moves fast.

- Backwards compatibility is not a goal.
- The architecture is intentionally aggressive.
- If something feels like it should be simpler, it probably should be.

---

## History (or: How We Got Here)

This thing has been in the making for a few years now, but always as a stupid personal project that I kept coming back to.

It started as bash and Python hacks wrapped around tmux. Absolutely cursed code. Shell scripts spawning tmux sessions, Python daemons talking to tmux through tmux send-keys, config files that were basically just more shell scripts. It was crazy. But it worked, and it was amazing - I could finally have the workflow I wanted.

At some point I decided to write a real version. Picked Rust, found the tmux-rs crate. Great experience, learned a lot about terminal internals, got pretty far with it. But that crate is basically all unsafe rust - you're still fundamentally building on top of tmux's architecture, not escaping it.

Then Ghostty came out and I saw what Mitchell was doing with Zig for terminal emulation. Said ok, full rewrite and rebuilt everything from scratch. Zero regrets. Zig is a joy to work with, Ghostty's VT implementation is rock solid, and I finally got to build the architecture I actually wanted instead of fighting someone else's.

Also - real talk - having AI assistants that can help convert concepts between languages has been a game changer. Half of the tricky bits in here started as: here is how this worked in Rust, how do I do it idiomatically in Zig?

---

## Credits

- Zig
- ghostty-vt (terminal emulation)

---

## Notes

- Clipboard: OSC 52 is forwarded to the host terminal. Hexa also attempts to set the system clipboard via wl-copy (Wayland) or xclip/xsel (X11) when available.
- Hyperlinks (OSC 8): full hyperlink rendering requires renderer-level support because Hexa renders from cells rather than passing through the raw byte stream.
