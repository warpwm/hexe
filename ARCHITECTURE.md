# Hexe Architecture

## Components

| Component | Role | Lifetime | Socket |
|-----------|------|----------|--------|
| **MUX** | Terminal UI, renders panes, handles input | User session | `mux-<UUID>.sock` (server) |
| **SES** | Session daemon, spawns pods, crash recovery | Persistent | `ses.sock` (server) |
| **POD** | Per-pane PTY worker, buffers output | Until shell exits | `pod-<UUID>.sock` (server) |
| **SHP** | Shell hooks, renders prompt | Per-command | Connects to `mux-<UUID>.sock` |

All sockets live under `${XDG_RUNTIME_DIR:-/tmp}/hexe/`.

---

## Current Architecture: Who Talks to Who

```
┌──────────────────────────────────────────────────────────────────────────┐
│                              TERMINAL                                    │
│                         (stdin/stdout/pty)                                │
└──────────────────────────────────────────────────────────────────────────┘
                                   │
                                   │ raw terminal I/O
                                   │
┌──────────────────────────────────▼───────────────────────────────────────┐
│                              MUX                                         │
│                                                                          │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐                │
│  │  Tab 0   │  │  Tab 1   │  │ Float A  │  │ Float B  │                │
│  │ ┌──┬──┐  │  │ ┌──────┐ │  │          │  │          │                │
│  │ │P0│P1│  │  │ │  P3  │ │  │   P4     │  │   P5     │                │
│  │ ├──┴──┤  │  │ └──────┘ │  │          │  │          │                │
│  │ │ P2  │  │  │          │  │          │  │          │                │
│  │ └─────┘  │  └──────────┘  └──────────┘  └──────────┘                │
│                                                                          │
│  Server: /tmp/hexe/mux-<UUID>.sock                                       │
└───────┬──────────────────────────────────────────────┬───────────────────┘
        │                                              │
        │ JSON-lines                                   │ Binary frames
        │ (control)                                    │ (PTY I/O)
        │                                              │
        ▼                                              ▼
┌───────────────────────┐              ┌─────────────────────────────────┐
│         SES           │              │     POD (one per pane)          │
│                       │──spawns──▶   │                                 │
│  - Registry of panes  │              │  - PTY master/slave             │
│  - Session store      │              │  - 4MB output backlog           │
│  - Spawns pods        │              │  - Binary frame protocol        │
│  - Crash recovery     │              │                                 │
│                       │              │  Server: pod-<UUID>.sock        │
│  Server: ses.sock     │              └────────────────┬────────────────┘
└───────────────────────┘                               │
                                                        │ PTY
                                                        ▼
                                               ┌────────────────┐
                                               │  SHELL / CMD   │
                                               │  (bash, vim..) │
                                               └───────┬────────┘
                                                       │
                                                       │ exec
                                                       ▼
                                               ┌────────────────┐
                                               │      SHP       │
                                               │  (shell hooks) │
                                               │                │
                                               │ Connects to:   │
                                               │ MUX socket ────┼───▶ MUX
                                               └────────────────┘
```

---

## Connection Matrix

```
          ┌─────────┬─────────┬─────────┬─────────┐
          │   MUX   │   SES   │   POD   │   SHP   │
┌─────────┼─────────┼─────────┼─────────┼─────────┤
│   MUX   │    -    │ CLIENT  │ CLIENT  │ SERVER  │
│         │         │(control)│(frames) │(events) │
├─────────┼─────────┼─────────┼─────────┼─────────┤
│   SES   │(accepts)│    -    │ PARENT  │    -    │
│         │         │         │(spawns) │         │
├─────────┼─────────┼─────────┼─────────┼─────────┤
│   POD   │(accepts)│(child)  │    -    │    -    │
│         │         │         │         │         │
├─────────┼─────────┼─────────┼─────────┼─────────┤
│   SHP   │ CLIENT  │    -    │    -    │    -    │
│         │(events) │         │         │         │
└─────────┴─────────┴─────────┴─────────┴─────────┘

Legend:
  CLIENT  = initiates connection to the other's server socket
  SERVER  = listens, accepts connections
  PARENT  = fork/exec spawner
  (child) = spawned by parent
```

---

## Protocol Details

### MUX ↔ SES: JSON-Lines Control Protocol

```
MUX                                          SES
 │                                            │
 │──{"type":"register","keepalive":true}────▶│
 │◀─{"type":"registered"}───────────────────│
 │                                            │
 │──{"type":"create_pane","shell":"bash"}──▶│
 │                                     [SES spawns POD]
 │◀─{"type":"pane_created",                  │
 │    "uuid":"abc123",                        │
 │    "socket":"/tmp/hexe/pod-abc123.sock"}──│
 │                                            │
 │──{"type":"sync_state",                     │
 │    "mux_state":"<full layout JSON>"}─────▶│
 │◀─{"type":"ok"}───────────────────────────│
 │                                            │
 │──{"type":"update_pane_aux",                │
 │    "uuid":"abc123",                        │
 │    "cwd":"/home",                          │
 │    "fg_process":"vim"}───────────────────▶│
 │                                            │
 │◀─{"type":"notify","message":"..."}────────│  (server-push)
 │                                            │
```

### MUX ↔ POD: Binary Frame Protocol

```
Frame: [type:1B][length:4B big-endian][payload]

Types:
  0x01 = output    POD → MUX    Shell output data
  0x02 = input     MUX → POD    User keystrokes
  0x03 = resize    MUX → POD    [cols:2B][rows:2B]
  0x04 = backlog_end  POD → MUX  Backlog replay complete

MUX                                          POD
 │                                            │
 │────────[TCP/socket connect]───────────────▶│
 │                                            │
 │◀──[output][4MB backlog data]──────────────│  (replay)
 │◀──[backlog_end][0]───────────────────────│
 │                                            │
 │──[input]["ls -la\r"]─────────────────────▶│──▶ PTY
 │◀──[output]["file1  file2\n"]──────────────│◀── PTY
 │                                            │
 │──[resize][80][24]────────────────────────▶│──▶ TIOCSWINSZ
 │                                            │
```

### SHP → MUX: Shell Events

```
SHELL                    SHP                         MUX
  │                       │                           │
  │──PROMPT_COMMAND───▶  │                           │
  │                       │                           │
  │                       │──connect(MUX_SOCKET)────▶│
  │                       │──{"type":"shell_event",   │
  │                       │   "cmd":"git push",       │
  │                       │   "status":0,             │
  │                       │   "duration_ms":3400}───▶│
  │                       │                           │
  │◀──rendered prompt──  │                           │
  │                       │                           │
```

---

## Process Lifecycle

### Startup

```
User runs: hexe mux
            │
            ▼
    ┌───────────────┐
    │   MUX starts  │
    │               │
    │ 1. Init state │
    │ 2. Find SES   │
    └───────┬───────┘
            │
            │ Connect to ses.sock?
            │
     ┌──────┴──────┐
     │             │
  exists?       missing?
     │             │
     ▼             ▼
  connect     fork/exec
  to SES      "hexe-ses daemon"
     │             │
     │         SES daemonizes
     │         creates ses.sock
     │             │
     └──────┬──────┘
            │
            ▼
    ┌───────────────┐
    │ Register with │
    │     SES       │
    └───────┬───────┘
            │
            ▼
    ┌───────────────┐       ┌───────────────┐
    │ create_pane   │──────▶│  SES spawns   │
    │ request       │       │  POD process  │
    └───────┬───────┘       └───────┬───────┘
            │                       │
            │ socket path           │ fork/exec
            │ returned              │
            ▼                       ▼
    ┌───────────────┐       ┌───────────────┐
    │ MUX connects  │◀─────▶│  POD ready    │
    │ to POD socket │       │  (backlog)    │
    └───────────────┘       └───────────────┘
```

### Detach (Terminal Close)

```
Terminal closes
     │
     ▼
┌───────────────┐
│ MUX receives  │
│ SIGHUP/EOF    │
└───────┬───────┘
        │
        ▼
┌───────────────────────────┐
│ MUX.deinit():             │
│                           │
│ if keepalive:             │
│   syncStateToSes()        │  ←── full layout JSON sent to SES
│   disconnect cleanly      │
│   DO NOT kill panes       │
│                           │
│ if !keepalive:            │
│   kill all panes          │
│   shutdown                │
└───────────┬───────────────┘
            │
            ▼
┌───────────────────────────┐
│ SES detects disconnect:   │
│                           │
│ if keepalive:             │
│   store mux_state         │
│   mark panes "detached"   │
│   PODs keep running       │
│   session preserved       │
│                           │
│ if !keepalive:            │
│   SIGTERM all PODs        │
│   cleanup pane registry   │
└───────────────────────────┘
```

### Reattach

```
User runs: hexe mux attach pikachu
            │
            ▼
    ┌───────────────────────┐
    │  New MUX starts       │
    │  connects to SES      │
    │  sends: reattach      │
    └───────────┬───────────┘
                │
                ▼
    ┌───────────────────────┐
    │  SES returns:         │
    │  - mux_state JSON     │
    │  - list of pane UUIDs │
    └───────────┬───────────┘
                │
                ▼
    ┌───────────────────────┐
    │  MUX restores layout: │
    │  - Recreate tabs      │
    │  - Recreate splits    │
    │  - Recreate floats    │
    │  - Re-apply styles    │  ←── getFloatByKey() lookup
    │  - Restore pwd_dir    │
    └───────────┬───────────┘
                │
                ▼
    ┌───────────────────────┐       ┌───────────────┐
    │  For each pane UUID:  │       │               │
    │  connect to existing  │──────▶│  POD (alive!) │
    │  POD socket           │       │  sends 4MB    │
    │                       │◀──────│  backlog      │
    └───────────────────────┘       └───────────────┘
                │
                ▼
    ┌───────────────────────┐
    │  Recreate MUX IPC     │
    │  at same UUID path    │  ←── so SHP hooks still work
    │  (HEXE_MUX_SOCKET)    │
    └───────────────────────┘
```

---

## Environment Variable Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                         │
│  MUX sets:                                                              │
│    HEXE_MUX_SOCKET = /tmp/hexe/mux-<UUID>.sock                          │
│                                                                         │
│  SES inherits HEXE_MUX_SOCKET, passes to POD:                           │
│    HEXE_PANE_UUID = <pane-uuid>                                         │
│    HEXE_POD_NAME  = <star-name>                                         │
│    HEXE_INSTANCE  = <forced from SES>                                   │
│                                                                         │
│  POD inherits all, shell inherits all:                                  │
│    HEXE_MUX_SOCKET → shell uses for SHP hooks                           │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘

Flow:

  MUX ──HEXE_MUX_SOCKET──▶ SES ──▶ POD ──▶ SHELL ──▶ SHP
                            │
                            └──HEXE_PANE_UUID──▶ POD
                            └──HEXE_POD_NAME───▶ POD
```

---

## Current Problems with the Architecture

### 1. SHP Talks to MUX (Wrong Direction)

```
PROBLEM:
                         ┌─────────────────────────────────┐
                         │  Shell runs: hexe shp prompt    │
                         │                                 │
  MUX ◀───────────────── │  Connects to HEXE_MUX_SOCKET   │
       shell_event        │  (but MUX might be dead/new!)  │
                         └─────────────────────────────────┘

After reattach, MUX has a NEW UUID → NEW socket path.
But shell still has OLD HEXE_MUX_SOCKET in environment.
We had to hack: recreate IPC server at old UUID's socket path.
```

### 2. MUX Directly Connects to POD

```
PROBLEM:
  MUX must know every POD socket path.
  MUX must handle reconnection logic.
  MUX must handle backlog replay.
  MUX has N open sockets (one per pane).

  If MUX crashes mid-frame, POD's reader state corrupts.
  (We had to add reader.reset() as a fix.)
```

### 3. SES is a Dumb Registry

```
PROBLEM:
  SES spawns PODs but doesn't talk to them after.
  SES stores metadata but gets it from MUX (not POD).
  SES doesn't know actual pane state (only what MUX reports).

  MUX ──update_pane_aux──▶ SES    (MUX tells SES what POD is doing)

  But MUX can only know what it observed through the VT stream.
  POD knows MUCH more (actual PTY state, child PIDs, cwd).
```

### 4. State Sync is Lossy

```
PROBLEM:
  MUX serializes its view of the world to SES.
  But float_style, border_color, float_title are lost.
  pwd_dir was lost (now fixed).

  On reattach, we have to re-derive from config.
  If config changed between sessions → wrong styles.
```

---

## Proposed Architecture: POD-Centric

The core insight: **POD owns the PTY, so POD knows the truth.**

POD knows:
- Current working directory (readlink /proc/pid/cwd)
- Foreground process (readlink /proc/pid/exe, /proc/pid/comm)
- Shell state (via direct SHP communication)
- Terminal dimensions
- Output history (4MB backlog)
- Whether the shell is idle or busy

### New Connection Topology

```
┌──────────────────────────────────────────────────────────────────────────┐
│                              TERMINAL                                    │
└──────────────────────────────────────────────────────────────────────────┘
                                   │
                                   │ raw terminal I/O
                                   ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                              MUX                                         │
│                                                                          │
│  Pure UI renderer. No direct pod connections.                            │
│  Receives pre-processed VT state from SES.                               │
│                                                                          │
│  Connects to: SES only (multiplexed binary stream)                       │
└──────────────────────────────────────┬───────────────────────────────────┘
                                       │
                                       │ Single connection
                                       │ (multiplexed frames, tagged by pane UUID)
                                       │
                                       ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                              SES                                         │
│                                                                          │
│  Router & session manager.                                               │
│  Muxes POD streams to/from MUX.                                          │
│  Holds pod connections persistently.                                     │
│                                                                          │
│  Connects to: each POD socket (persistent)                               │
└──────────┬────────────────┬────────────────┬─────────────────────────────┘
           │                │                │
           ▼                ▼                ▼
┌────────────────┐  ┌────────────────┐  ┌────────────────┐
│    POD (P0)    │  │    POD (P1)    │  │    POD (P2)    │
│                │  │                │  │                │
│  - PTY owner   │  │  - PTY owner   │  │  - PTY owner   │
│  - SHP server  │  │  - SHP server  │  │  - SHP server  │
│  - CWD tracker │  │  - CWD tracker │  │  - CWD tracker │
│  - Process mon │  │  - Process mon │  │  - Process mon │
│                │  │                │  │                │
│  Server: pod-  │  │  Server: pod-  │  │  Server: pod-  │
│  <UUID>.sock   │  │  <UUID>.sock   │  │  <UUID>.sock   │
└───────┬────────┘  └───────┬────────┘  └───────┬────────┘
        │                   │                    │
        ▼                   ▼                    ▼
      SHELL               SHELL                SHELL
        │                   │                    │
        ▼                   ▼                    ▼
       SHP ──▶ POD         SHP ──▶ POD         SHP ──▶ POD
    (direct!)           (direct!)            (direct!)
```

### Key Changes

```
CURRENT                              PROPOSED
─────────────────────────────────    ─────────────────────────────────
SHP ──▶ MUX (shell events)          SHP ──▶ POD (shell events)
MUX ──▶ POD (N connections)         MUX ──▶ SES (1 connection)
MUX ──▶ SES (control)               SES ──▶ POD (N connections)
SES spawns POD (fire & forget)       SES ◀──▶ POD (persistent link)
MUX reports pane state to SES        POD reports own state to SES
```

### New Connection Matrix

```
          ┌─────────┬─────────┬─────────┬─────────┐
          │   MUX   │   SES   │   POD   │   SHP   │
┌─────────┼─────────┼─────────┼─────────┼─────────┤
│   MUX   │    -    │ CLIENT  │    -    │    -    │
│         │         │(muxed)  │ (none!) │         │
├─────────┼─────────┼─────────┼─────────┼─────────┤
│   SES   │(accepts)│    -    │ CLIENT  │    -    │
│         │         │         │(persist)│         │
├─────────┼─────────┼─────────┼─────────┼─────────┤
│   POD   │    -    │(accepts)│    -    │ SERVER  │
│         │ (none!) │(reports)│         │(events) │
├─────────┼─────────┼─────────┼─────────┼─────────┤
│   SHP   │    -    │    -    │ CLIENT  │    -    │
│         │ (none!) │         │(events) │         │
└─────────┴─────────┴─────────┴─────────┴─────────┘
```

### Multiplexed Protocol (MUX ↔ SES)

```
New frame format for MUX ↔ SES:
  [pane_uuid:16B][type:1B][length:4B][payload]

  type=0x01: output (SES → MUX, from specific pane)
  type=0x02: input  (MUX → SES, to specific pane)
  type=0x03: resize (MUX → SES, to specific pane)
  type=0x04: backlog_end (SES → MUX)
  type=0x10: pane_meta (SES → MUX, cwd/process/state changes)
  type=0x11: shell_event (SES → MUX, forwarded from POD)
  type=0x20: control (bidirectional, JSON payload)

Single socket carries ALL pane I/O + control messages.
No more N pod connections from MUX.
```

### POD as Source of Truth

```
┌──────────────────────────────────────────────────────┐
│                     POD Process                       │
│                                                      │
│  OWNS:                                               │
│  ┌────────────────────────────────────────────────┐  │
│  │  PTY master fd                                 │  │
│  │  4MB output ring buffer (backlog)              │  │
│  │  Child process PID                             │  │
│  │  Current working directory (from /proc)        │  │
│  │  Foreground process name + PID (from /proc)    │  │
│  │  Shell integration state (from SHP)            │  │
│  │    - Last command                              │  │
│  │    - Exit status                               │  │
│  │    - Duration                                  │  │
│  │    - Job count                                 │  │
│  │  Terminal dimensions (cols × rows)             │  │
│  │  Alt-screen state                              │  │
│  └────────────────────────────────────────────────┘  │
│                                                      │
│  REPORTS TO SES:                                     │
│  ┌────────────────────────────────────────────────┐  │
│  │  Meta-events (pushed when state changes):      │  │
│  │    {"type":"cwd_changed","cwd":"/home/user"}   │  │
│  │    {"type":"fg_changed","name":"vim","pid":99}  │  │
│  │    {"type":"shell_event","cmd":"ls","status":0} │  │
│  │    {"type":"bell"}                             │  │
│  │    {"type":"title_changed","title":"vim foo"}   │  │
│  │    {"type":"exited","status":0}                │  │
│  └────────────────────────────────────────────────┘  │
│                                                      │
│  ACCEPTS FROM SES:                                   │
│  ┌────────────────────────────────────────────────┐  │
│  │  Input frames (user keystrokes)                │  │
│  │  Resize frames (terminal size change)          │  │
│  │  Query requests (get backlog, get state)       │  │
│  └────────────────────────────────────────────────┘  │
│                                                      │
│  ACCEPTS FROM SHP (direct, same-host):               │
│  ┌────────────────────────────────────────────────┐  │
│  │  Shell events (command, status, duration)      │  │
│  │  Prompt requests (render prompt)               │  │
│  └────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────┘
```

### SHP → POD (Direct Communication)

```
CURRENT:
  Shell ──exec──▶ hexe-shp ──connect──▶ MUX socket
                                          │
                                     MUX forwards
                                     to SES as
                                     update_pane_shell

PROPOSED:
  Shell ──exec──▶ hexe-shp ──connect──▶ POD socket (same host!)
                                          │
                                     POD stores locally
                                     POD pushes meta to SES
                                     SES forwards to MUX

Why better:
  - POD is ALWAYS alive (even without MUX)
  - No stale HEXE_MUX_SOCKET problem
  - SHP data stays with its owner
  - POD can use shell state for its own decisions
    (e.g., ring bell on long command completion)
```

### Env Variable Change

```
CURRENT:
  HEXE_MUX_SOCKET=/tmp/hexe/mux-<mux-uuid>.sock

PROPOSED:
  HEXE_POD_SOCKET=/tmp/hexe/pod-<pane-uuid>.sock

  The pane UUID never changes across reattach.
  The POD socket is always valid while the shell lives.
  No more stale socket problem.
```

---

## Detach/Reattach with POD-Centric Design

### Detach

```
Terminal closes
     │
     ▼
┌───────────────┐
│ MUX gets EOF  │
│               │
│ Sends to SES: │
│ "detaching"   │
│ + layout JSON │
│               │
│ MUX exits.    │
└───────┬───────┘
        │
        ▼
┌───────────────────────────────────┐
│ SES:                              │
│                                   │
│ - Stores layout JSON              │
│ - Marks session "detached"        │
│ - POD connections stay alive!     │
│ - PODs keep buffering output      │
│ - SHP keeps working (→ POD)       │
│                                   │
│ Nothing breaks. No socket issues. │
└───────────────────────────────────┘
```

### Reattach

```
User runs: hexe mux attach pikachu
     │
     ▼
┌───────────────┐
│ New MUX       │
│ connects SES  │
│               │
│ SES returns:  │
│ - layout JSON │
│ - pane list   │
└───────┬───────┘
        │
        ▼
┌───────────────────────────────────┐
│ SES:                              │
│                                   │
│ For each POD in session:          │
│   - Replay backlog through SES    │
│   - Forward new output to MUX     │
│                                   │
│ MUX never connects to POD.        │
│ MUX only talks to SES.            │
│                                   │
│ POD doesn't know MUX changed.     │
│ POD doesn't care.                 │
└───────────────────────────────────┘
```

---

## Comparison: Current vs Proposed

```
┌─────────────────────────────────┬─────────────────────────────────────┐
│           CURRENT               │            PROPOSED                 │
├─────────────────────────────────┼─────────────────────────────────────┤
│                                 │                                     │
│  Connections from MUX: N+1      │  Connections from MUX: 1            │
│  (1 SES + N PODs)               │  (just SES)                         │
│                                 │                                     │
│  SHP connects to: MUX           │  SHP connects to: POD              │
│  (stale after reattach!)        │  (always valid!)                    │
│                                 │                                     │
│  Who knows CWD: MUX parses VT   │  Who knows CWD: POD reads /proc    │
│  (unreliable, async)            │  (authoritative, instant)           │
│                                 │                                     │
│  Who knows fg process: MUX       │  Who knows fg process: POD          │
│  (via SES query)                │  (direct /proc access)              │
│                                 │                                     │
│  State on detach: MUX must sync  │  State on detach: POD has it all    │
│  before dying                   │  (survives without MUX)             │
│                                 │                                     │
│  Backlog replay: POD → MUX      │  Backlog replay: POD → SES → MUX   │
│  (direct, fast)                 │  (one extra hop)                    │
│                                 │                                     │
│  POD reader corruption:         │  POD reader corruption:             │
│  MUX crash = partial frame      │  SES handles reconnect cleanly     │
│  (needed reader.reset() fix)    │  (single persistent connection)     │
│                                 │                                     │
│  N file descriptors in MUX      │  N file descriptors in SES          │
│  (UI process, latency matters)  │  (daemon, doesn't render)           │
│                                 │                                     │
└─────────────────────────────────┴─────────────────────────────────────┘
```

---

## Migration Path

A full rewrite isn't needed. The transition can happen incrementally:

### Phase 1: SHP → POD

```
1. Add SHP handler to POD's socket server
2. POD accepts {"type":"shell_event",...} on its socket
3. POD pushes shell state to SES via new uplink
4. Change HEXE_MUX_SOCKET → HEXE_POD_SOCKET in env
5. SHP connects to POD instead of MUX
6. Remove shell_event handler from MUX IPC

   Effort: POD gets a JSON handler + SES uplink
   Risk: Low (additive, backward compatible with fallback)
```

### Phase 2: POD → SES Persistent Link

```
1. After POD starts, POD connects BACK to SES socket
2. POD sends periodic metadata (cwd, fg_process, shell state)
3. SES maintains per-pane state from POD reports
4. Remove update_pane_aux from MUX → SES protocol
5. MUX gets pane metadata from SES (already routed)

   Effort: New "pod uplink" connection + meta protocol
   Risk: Medium (changes state ownership)
```

### Phase 3: SES Multiplexes PTY I/O

```
1. SES connects to each POD socket (persistent)
2. SES receives output frames from PODs
3. SES forwards to MUX with pane UUID prefix
4. MUX sends input to SES with pane UUID prefix
5. SES routes input to correct POD
6. Remove direct MUX → POD connections

   Effort: Multiplexed frame protocol in SES
   Risk: High (adds latency, SES becomes bottleneck)
```

### Phase 4: MUX Simplification

```
1. MUX only connects to SES
2. MUX only renders + handles input
3. All pane state comes from SES (which gets from POD)
4. No more state serialization in MUX
5. SES owns the layout (PODs report, SES organizes)

   Effort: Major refactor of MUX state management
   Risk: High (architectural change)
```

---

## Trade-offs of POD-Centric Design

### Advantages

```
+ SHP always works (POD socket never goes stale)
+ No reader.reset() hacks needed
+ POD is source of truth for pane state
+ MUX is thin UI client (easier to replace/rewrite)
+ Detach is trivial (MUX just disconnects from SES)
+ Multiple MUXes can view same session (SES multiplexes)
+ POD can do smart things (notify on long command, auto-title)
+ Clean separation: POD=data, SES=routing, MUX=rendering
```

### Disadvantages

```
- Extra hop for PTY I/O (POD → SES → MUX adds latency)
  Mitigation: SES uses splice()/zero-copy forwarding
  Mitigation: SES and POD are same host (unix socket = ~5μs)

- SES becomes single point of failure for I/O
  Mitigation: If SES dies, PODs still have shells alive
  Mitigation: MUX could fall back to direct POD connection

- More complexity in SES (frame routing, backlog management)
  Mitigation: SES already manages pane registry
  Mitigation: Multiplexing is well-understood pattern

- POD needs JSON handler (currently binary-only)
  Mitigation: Small addition, only for SHP events
  Mitigation: Could use separate socket for control vs data
```

---

## Recommended Approach

Start with **Phase 1** (SHP → POD). It solves the most painful current bug
(stale `HEXE_MUX_SOCKET` after reattach) with minimal risk:

```
                    BEFORE                          AFTER PHASE 1
                    ──────                          ─────────────
Shell event flow:                          Shell event flow:
  SHP → MUX → SES                           SHP → POD → SES → MUX
  (breaks on reattach)                       (always works)

Env variable:                              Env variable:
  HEXE_MUX_SOCKET (changes!)                 HEXE_POD_SOCKET (stable!)

What changes:                              What stays same:
  - POD gets IPC handler                     - MUX ↔ POD binary frames
  - SHP target changes                      - MUX ↔ SES JSON control
  - Env var name changes                     - SES spawns PODs
                                            - Backlog mechanism
                                            - Session persistence
```

Phase 2 (POD reports to SES) can follow naturally once Phase 1 is stable.
Phases 3-4 (full multiplexing) are optional and only needed if the direct
MUX→POD connections prove problematic in practice.
