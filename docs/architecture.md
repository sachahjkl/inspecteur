# Architecture

Inspecteur is one program in [Odin](https://odin-lang.org) on [gui_toolkit](https://github.com/sachahjkl/gui_toolkit)
(the `ext/gui_toolkit` submodule, the collection `gt`). This page says how its parts fit, and why.

## The window's thread, and the readers' threads

```
inspecteur ─ the window's thread (app.odin)
               sleeps in the toolkit's wait until input, the next sample, or a reader's result
               a sample: /proc (procfs.odin) -> groups (processes.odin) -> rows -> a frame
           ─ the GPUs' thread (gpu.odin): NVML or amdgpu every 2 s
           ─ a thread per section that reads something slow (worker.odin): Services, Startup, Connections, Information
```

A sample reads about 200 processes in 6 to 7 ms. It runs on the window's thread: a second thread would cost more in
locks and copies than it saves. Between two samples, with no input, nothing runs. In a window the user is not in, the
filter's caret neither shows nor blinks (`Build_Params.inactive`): at rest, one frame per sample.

What can wait for a long time runs on a thread of its own, a `Worker`: a call to systemd that waits for polkit, a file
system on a network that does not answer, the scan of every process's descriptors. The window asks (`worker_ask`); the
thread reads into a new reading of its own, swaps it in under the worker's mutex, and wakes the window
(`platform.wake`), which takes it at its next turn. A section reads only while it is shown (Information: when it is first
shown, and on F5): the other sections cost nothing.

## The sections and the system

Each section is a model, its reader and its view:

| Section | Model | Reader (Linux) | View |
|---|---|---|---|
| Processes | `processes.odin` | `procfs.odin` | `table_view.odin`, `menu.odin`, `props_view.odin` |
| Performance | `machine.odin`, `gpu.odin` | the same files | `perf_view.odin`, `graph.odin` |
| Services | `services.odin` | `services_linux.odin` | `services_view.odin` |
| Startup | `startup.odin` | `startup_linux.odin` | `startup_view.odin` |
| Connections | `connections.odin` | `connections_linux.odin` | `connections_view.odin` |
| Information | `information.odin` | `information_linux.odin` | `information_view.odin` |

The readers of the new sections are in `*_linux.odin` files (Odin builds them on Linux only), behind plain structs
(`Service`, `Startup_Item`, `Socket`, `Info_Static`) and procs whose names would mean the same on another system
(`services_read`, `service_act`, `startup_read`, `startup_set_enabled`, `sockets_read`, `info_read`). The views read
the structs and call those procs: they have no Linux in them.

The Services, Startup and Connections tables are one generic table (`grid.odin`): a section fills a `Grid_Data` with its
cells' texts and the numbers a column sorts by when its reading changes; the grid filters and sorts row indices, keeps the
selection by the row's identity, and draws as the Processes table does.

## Services and Startup: systemd over D-Bus

The services come from systemd's managers over D-Bus, through the toolkit's own client (`gt:dbus`, no libdbus, no
`systemctl` started): `ListUnits` and `ListUnitFiles`, then `MainPID` and `MemoryCurrent` of each running service, all
asked before any answer is read. Start, Stop and Restart are `StartUnit`, `StopUnit` and `RestartUnit`; Enable and Disable
are `EnableUnitFiles` and `DisableUnitFiles`, then `Reload`, as `systemctl` does. A system service's change is the
manager's to allow: it asks polkit, and what polkit refuses is said in the footer. Inspecteur never runs `sudo`.

The Startup section reads the XDG autostart entries itself (the Desktop Application Autostart Specification) and asks the
user's manager which services the session's targets want (their `Wants` property). An autostart entry of the system is
turned off by the user's copy of it with `Hidden=true`, as the specification says; turned on again, the copy goes when
nothing else changed in it.

## Connections

`/proc/net/tcp`, `tcp6`, `udp` and `udp6` list the sockets; a socket's process is the one whose `/proc/<pid>/fd/<n>`
links to `socket:[<inode>]`. Only the processes the user may read can be told. That scan of every descriptor is what
costs (a few milliseconds): a reading whose sockets all have a known owner skips it, ten readings in a row at most.

## Information

What does not change while the program runs (`/etc/os-release`, `uname`, `/sys/class/dmi/id`, `/proc/cpuinfo`, the PCI
display controllers with their names from `pci.ids` when the system has it, the file systems and `statfs`, the screens'
EDID, the batteries) is read on its thread; what changes (the uptime, the memory, the network interfaces) comes from the
last sample of Performance.

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

- Unit tests (`src`): the formats of `/proc`, `/proc/net`, unit files, desktop entries, `os-release`, `pci.ids`, EDID and
  `mountinfo`; names, sizes, the match of processes to apps, the groups, the preferences' documentation.
- `inspecteurtool live`: the real program in a sway with no screen, driven over the DevTools protocol: rows, sort, the
  filter, the row's menu, End task and Kill on processes the test started; a transient user service it made (Start,
  Restart, Stop), an autostart entry it wrote (Disable, Enable), a socket it opened, the kernel's version. A key that
  changes something is pressed only once the selected row, as the accessibility tree says, is the test's own.
- `inspecteurtool bench`: the cold start and the cost at rest, on the GPU.
