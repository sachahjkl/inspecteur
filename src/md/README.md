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
- Each section has a neutral model, a Linux reader (`*_linux.odin`) and a view. The demo (`--demo`) is a third source
  behind the same procs.
- Every action is a command of `COMMANDS` (`src/commands.odin`); every dialog and panel is a toolkit view
  (`src/views.odin`).

## State machines

- The sample: asked, then taken; the next one is asked only once the window took the last. The first frame waits for
  the first sample, two seconds at most.
- A section's reader: idle while the section is hidden, reading while it is shown.
- A followed service: its details and journal read again every 2 s while it is selected.
- NVML: closed while no GPU number is wanted or an NVIDIA GPU sleeps, open otherwise
  ([features/gpus.md](features/gpus.md)).
- An act on a process: asked (for a kill, a tree, the desktop's processes), then sent through a pidfd only if the
  process is still the same.

## Subtleties

- A process is the pair (pid, start time), never a pid alone: the selection, the marks, the signals, the Properties'
  reads all check it.
- Readers give counters, not rates: the neutral side computes the rates, so the arithmetic is the same on every system
  and is tested with no system.
- At rest, one frame per sample. In a window the user is not in, the filter's caret does not blink.
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
- [features/connections.md](features/connections.md): a socket's process, the scan of descriptors skipped when every
  socket is known
