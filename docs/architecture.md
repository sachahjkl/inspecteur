# Architecture

Inspecteur is one program in [Odin](https://odin-lang.org) on [gui_toolkit](https://github.com/sachahjkl/gui_toolkit)
(the `ext/gui_toolkit` submodule, the collection `gt`). This page says how its parts fit, and why.

## One thread, one loop

```
inspecteur ─ the window's thread (app.odin)
               sleeps in the toolkit's wait until input or the next sample
               a sample: /proc (procfs.odin) -> groups (processes.odin) -> rows -> a frame
```

A sample reads about 200 processes in 6 to 7 ms. It runs on the window's thread: a second thread would cost more in
locks and copies than it saves. Between two samples, with no input, nothing runs. In a window the user is not in, the
filter's caret neither shows nor blinks (`Build_Params.inactive`): at rest, one frame per sample.

## The processes (src/procfs.odin)

Everything comes from `/proc`, read with system calls (`openat`, `read`, `getdents`) into one buffer.

- **Each sample**: `/proc/stat` (the machine's CPU ticks), `/proc/meminfo` (total and available memory), the list of
  pids, then for each process `stat` (parent, CPU ticks, threads, start time, resident pages) and `io` (bytes read from
  and written to the storage).
- **Once per process**: its command line, its executable, its owner, its systemd unit (`cgroup`), its app. A process is
  the pair (pid, start time): a pid used again is a new process.
- **CPU %**: the process's ticks over the machine's, both since the last sample. It is a share of the whole machine (top's
  Irix mode off, as Windows' Task Manager): 100 % is every core busy.
- **Disk**: `read_bytes` and `write_bytes` of `io`, what reached the storage, per second. Another user's `io` cannot be
  read: its cells show a dash, and it is not asked again.
- **Kernel threads** (`PF_KTHREAD`) are not shown.
- **Names**: the kernel cuts a command name to 15 bytes; the first argument or the executable gives it whole. A Nix
  wrapper's `.firefox-wrapped` is shown as `firefox`.

The parsers are pure procedures, tested in `src/procfs_test.odin`.

## Apps (src/apps.odin, src/processes.odin)

Wayland does not let a program see the other programs' windows. So an app is what the desktop's menu knows: a desktop
entry under `applications/` of each XDG data folder (not hidden, not run in a terminal). A process matches an entry by
its name or its executable's name (the entry's program, its id, its window class), else by the systemd unit its launcher
made (`app-<launcher>-<desktop id>-<random>.scope`).

A group is one entry: every process of that app and the processes under it, unless one of them is another app (a browser
started from a terminal is the browser's). Two windows of one app are one group. End task on a group signals each of
the app's processes (`group_roots`); the processes under them end with them.

The app's icon is its entry's PNG in the hicolor theme or in `pixmaps`, made into a texture the first time it is shown.

## Signals (src/menu.odin)

End task sends SIGTERM, Kill sends SIGKILL after a confirmation. Just before a signal, the process's start time is read
again: a pid freed and given to another process is not signalled.

## The window (src/view.odin, src/table_view.odin)

The interface is built again at each frame (immediate mode). The table is the toolkit's virtual list: it builds the rows
in view only. The selection is kept by the row's identity (pid and start time; an app's entry) across samples, sorts
and filters. Every colour comes from the theme: its page, bars and wells for the surfaces, its border for the lines, its
warning hue for the tint of busy cells. Corners are nearly square (`ui.set_rounding`).

## Tests

- Unit tests (`src`): the formats of `/proc`, names, sizes, the match of processes to apps, the groups, the preferences'
  documentation.
- `inspecteurtool live`: the real program in a sway with no screen, driven over the DevTools protocol: rows, sort, the
  sections, the filter, the row's menu, End task and Kill on processes the test started.
- `inspecteurtool bench`: the cold start and the cost at rest, on the GPU.
