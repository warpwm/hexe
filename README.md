# Hexa

A terminal multiplexer, session manager, and shell prompt renderer jammed into one.


---

## History (or: How We Got Here)

This thing has been in the making for a few years now, but always as a stupid personal project that I kept coming back to.

It started as bash and Python hacks wrapped around tmux. Absolutely cursed code. Shell scripts spawning tmux sessions, Python daemons talking to tmux through `tmux send-keys`, config files that were basically just more shell scripts. It was crazy. But it worked, and it was *amazing* - I could finally have the workflow I wanted.

At some point I decided to write a "real" version. Picked Rust, found the `tmux-rs` crate. Great experience, learned a lot about terminal internals, got pretty far with it. But that crate is basically all `unsafe` rust - you're still fundamentally building on top of tmux's architecture, not escaping it.

Then Ghostty came out and I saw what Mitchell was doing with Zig for terminal emulation. Said "fuck it" and rewrote everything from scratch. Zero regrets. Zig is a joy to work with, Ghostty's VT implementation is rock solid, and I finally got to build the architecture I actually wanted instead of fighting someone else's.

Also - real talk - having AI assistants that can help convert concepts between languages has been a game changer. Half of the tricky bits in here started as "here's how this worked in Rust, how do I do it idiomatically in Zig?" Getting unstuck in minutes instead of hours is wild.

Anywayzzzzzzzzzzzzzzzzzzz.

---

