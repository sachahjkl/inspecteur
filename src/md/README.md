# inspecteur: intent

inspecteur is a system monitor: the processes grouped by app, the performance, the services, what starts with the
session, the connections, what the machine is. This folder follows <https://srcmd.org>: it records why the code has its
shape, the decisions, the refused alternatives, the subtle points. The map of the code (threads, the files of each
section, the views, the tests) is [docs/architecture.md](../../docs/architecture.md); building and testing is
[docs/development.md](../../docs/development.md); the preferences are [docs/configuration.md](../../docs/configuration.md).

## Overview

- One window's thread that makes no system call. It sleeps in the toolkit's wait until input, the next sample, or a
  reading posted to it.
- Every reader is a `tasks.Job` on the toolkit's chores; its reading is new memory of its own, posted with `ui.post` and
  taken at the next build. The GPUs have a thread of their own (every 2 s).
- Each section has a model, an OS reader (`*_linux.odin` or `*_windows.odin`), and a view. Platform-divergent sections (Services, Startup, Properties, Information, process commands and columns) use dedicated per-OS model and view files rather than forcing one system into the shape of another ([infrastructure/porting.md](infrastructure/porting.md)). The demo (`--demo`) is a third source behind the same procedures.
- Every action is a command of `COMMANDS` (`src/commands.odin`); every dialog and panel is a toolkit view
  (`src/views.odin`). A command that asks one value takes it in the palette's form; a button names the command it runs
  ([features/palette.md](features/palette.md)).

## State machines

- The sample: asked, then taken; the next one is asked only once the window took the last. The first frame waits for
  the first sample, two seconds at most.
- A section's reader: idle while the section is hidden, reading while it is shown.
- A followed service: its details and journal read again every 2 s while it is selected.
- NVML: closed while no GPU number is wanted or an NVIDIA GPU sleeps, open otherwise
  ([features/gpus.md](features/gpus.md)).
- An act on a process: asked (for a kill, a tree, the desktop's processes), then sent through a pidfd only if the
  process is still the same.
- The updates: started with the window (never in the demo), checking nothing by themselves until the install's reading
  says this copy is the installed one and update.auto is on; the toolkit's `prefs_page.updates_follow` applies it at
  each turn of the loop. Starting them only once the install was read, as before, kept a state of the program's own
  for what the toolkit now decides.

## Subtleties

- A process is the pair (pid, start time), never a pid alone: the selection, the signals, the Properties'
  reads all check it.
- Readers give counters, not rates: the neutral side computes the rates, so the arithmetic is the same on every system
  and is tested with no system.
- At rest, one frame per sample. The time of a reading (samples, services, connections, journals) wakes the loop to
  start its job and makes no frame: the frame comes when the reading posts. Only a wake by that time alone makes none;
  input, a post, another thread's wake, a view's own timer keep theirs. In a window the user is not in, the filter's
  caret does not blink.
- A window hidden or covered makes the frames the toolkit's host makes of it. A path of its own that applied the
  readings with no frame was refused: a compositor can keep its word for a window it shows (the host gives it up after
  a time), and a frame owed and not made kept the loop awake. The toolkit must tell a suspended window first.
- The user's themes file is looked at by each sample (one stat, on the sample's thread): the window asks the toolkit to
  read it only when its time changed, or while paused. The toolkit's own poll posts its answer, changed or not: a
  second frame per two samples.
- A test sends a signal only to a process it started itself, and acts on a service, an autostart entry or an app's
  group only when it made it itself.

## File Index

- [infrastructure/porting.md](infrastructure/porting.md): the readers behind neutral structs, counters not rates, the
  demo as a third source, what a Windows port writes
- [features/processes.md](features/processes.md): what is read from `/proc` and when, the decisions on CPU %, memory,
  disk and names, the acts on a process (pidfd, what is never suspended), the Properties' reads
- [features/apps.md](features/apps.md): an app as a desktop entry, how a process finds its app past launchers and
  interpreters, the groups
- [features/services.md](features/services.md): systemd over the toolkit's D-Bus client, polkit and no sudo, Startup's
  autostart entries, a service's details and journal, the questions before Stop and Restart
- [features/gpus.md](features/gpus.md): why a sleeping GPU is not woken, when NVML is open
- [features/install.md](features/install.md): the install's boxes (the PATH, Task Manager on Windows), a start from
  Task Manager handed over to the person's install, why no install is offered then
- [features/connections.md](features/connections.md): a socket's process, the scan of descriptors skipped when every
  socket is known
- [features/palette.md](features/palette.md): the palette's sources (the toolkit's commands and settings, Go to: the
  processes and the services), the commands with arguments and the dialogs kept, the buttons that name their command
  for Shift+Enter, what can act as a version, Go to's ids and its answers made on a chore
