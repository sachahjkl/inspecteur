# Architecture

Inspecteur is one program in [Odin](https://odin-lang.org) on [gui_toolkit](https://github.com/sachahjkl/gui_toolkit)
(the `ext/gui_toolkit` submodule, the collection `gt`). This page says how its parts fit, and why.

## The window's thread, and the readers' threads

```
inspecteur ─ the window's thread (app.odin)
               sleeps in the toolkit's wait until input, the next sample, or a reader's result
               a sample: the machine (machine.odin) -> the processes (sampler.odin) -> groups (processes.odin) -> rows
           ─ the GPUs' thread (gpu.odin): every 2 s
           ─ a thread per section that reads something slow (ui.Worker): Services, Startup, Connections, Information,
             a service's details and journal, a dump file
```

A sample reads about 200 processes in 7 to 8 ms. It runs on the window's thread: a second thread would cost more in
locks and copies than it saves. Between two samples, with no input, nothing runs. In a window the user is not in, the
filter's caret neither shows nor blinks (`Build_Params.inactive`): at rest, one frame per sample.

What can wait for a long time runs on a thread of its own, the toolkit's `ui.Worker`: a call to systemd that waits for
polkit, a file system on a network that does not answer, the scan of every process's descriptors. The window asks
(`ui.worker_ask`); the thread reads into a new reading of its own, swaps it in under the worker's mutex, and wakes the
window (`platform.wake`), which takes it at its next turn. A section reads only while it is shown (Information: when it
is first shown, and on F5): the other sections cost nothing.

## The system and the views

Every reading of the system is in a `*_linux.odin` file (Odin builds them on Linux only), behind plain structs and procs
whose names would mean the same on another system. The other files (the models, the views, the commands) hold no path
of `/proc` or `/sys`, no system call: they read the structs and call those procs.

| Section | Model (neutral) | Reader (Linux) | View |
|---|---|---|---|
| Processes | `sampler.odin`, `processes.odin`, `apps.odin` | `processes_linux.odin`, `apps_linux.odin` | `table_view.odin`, `menu.odin` |
| Properties | `props.odin` | `props_linux.odin` | `props_view.odin` |
| Performance | `machine.odin`, `gpu.odin` | `machine_linux.odin`, `gpu_linux.odin` | `perf_view.odin` |
| Services | `services.odin` | `services_linux.odin` | `services_view.odin` |
| Startup | `startup.odin` | `startup_linux.odin` | `startup_view.odin` |
| Connections | `connections.odin` | `connections_linux.odin` | `connections_view.odin` |
| Information | `information.odin` | `information_linux.odin` | `information_view.odin` |
| the session | `menu.odin` (the guards) | `session_linux.odin`, `desktop_linux.odin` | `setup_view.odin` |
| a dump file | `dump.odin` | `dump_linux.odin` | |
| the system's words | `props.odin` (`Priority`) | `system_linux.odin` | |

A reader gives counters, not rates: a process's CPU time since it started, a disk's bytes since boot. The neutral side
makes the rates (`rate_of`, `busy_percent`), the CPU % and the graphs' points, and keeps what it learnt of each process
and device. So the arithmetic is the same on every system, and its tests need no system.

The demo (`demo.odin`, `inspecteur --demo`) is a third source behind the same procs: made-up processes, devices,
services, sockets and details. The pictures of the documentation are made with it (see [development.md](development.md)).

## Porting to Windows

A port writes `*_windows.odin` files beside the `*_linux.odin` ones, with the same procs and the same structs filled. No
view, model or command changes. What each file gives:

| File | Procs | Fills |
|---|---|---|
| `processes_windows.odin` | `Proc_Reader`, `proc_reader_init`, `proc_reader_destroy`, `procs_read`, `proc_facts`, `proc_state_now` | `Proc_Counters` (pid, parent, a start time that with the pid names the process, CPU time in ns, threads, state, priority as a nice value, resident and private bytes, disk bytes read and written) and `Proc_Facts` (name, command line, executable, owner, the launcher's unit (`""`), when it started) |
| `apps_windows.odin` | `catalog_load` | the `Catalog`'s entries (`catalog_add_entry`): the Start menu's apps, their names and icons |
| `machine_windows.odin` | `Machine_Reader`, `machine_reader_init`, `machine_reader_destroy`, `machine_read`, `cpu_info_read`, `cpu_mhz_now`, `disks_list`, `nets_list` | `Machine_Counters` (each processor's total and idle time in ns, boot time, uptime, handles, `Mem_Fields`, each disk's bytes and busy ms, each interface's bytes), `Cpu_Info`, `Disk_Info`, `Net_Info` |
| `gpu_windows.odin` | `Gpu_Reader`, `gpu_reader_close`, `gpu_read` | `Gpu_Snapshot`: each GPU's `Gpu_Read`, and each process's video memory (`gpu_proc_add`) |
| `props_windows.odin` | `proc_cwd`, `proc_threads`, `proc_files`, `proc_modules`, `proc_environment` (each by pid and start time) | `Thread_Row`, `File_Row`, `Module_Row`, the environment's lines; `Read_State` says what was refused |
| `services_windows.odin` | `Service_Bus`, `service_bus_close`, `services_read`, `service_act`, `unit_details_read` | `Service` (the Service Control Manager's services; `Manager.User` lists none), `Unit_Details` (its file, since when, the event log's last lines) |
| `startup_windows.odin` | `Startup_Bus`, `startup_bus_close`, `startup_read`, `startup_set_enabled` | `Startup_Item` (the Run keys and the Startup folder) |
| `connections_windows.odin` | `Socket_Reader`, `socket_reader_destroy`, `sockets_read` | `Socket` (GetExtendedTcpTable, GetExtendedUdpTable: each with its pid) |
| `information_windows.odin` | `info_read` | `Info_Static` |
| `session_windows.odin` | `display_server_pid`, `own_units` | the pid of the process Inspecteur must not suspend besides itself (dwm.exe), or 0; the services Inspecteur runs in (none) |
| `desktop_windows.odin` | `current_desktop`, `task_manager_hint`, `task_manager_bind` | how Windows opens Inspecteur as its task manager (the Task Manager's replacement key) |
| `dump_windows.odin` | `process_dump`, `DUMP_HOW` | a minidump of the process (MiniDumpWriteDump) |
| `system_windows.odin` | `PRIORITIES`, `PRIORITY_COLUMN`, `PRIORITY_DENIED`, `ADMIN`, `priority_text` | the priority classes offered, as nice values (Idle 19 ... High -10), "an administrator" |

What the toolkit does is already portable: signals, priorities and affinities (`process.signal_process`,
`process.set_priority`, `process.set_affinity`: a Windows port of the toolkit maps End task to WM_CLOSE, Kill to
TerminateProcess), the desktop entry (`gt:desktop`: the Start menu's shortcut), the clipboard, the file manager, a web
page. In the neutral files a priority is a nice value (-20 the highest, 19 the lowest): `system_<os>.odin` gives the
priorities offered and their words; a state is `Proc_State`.

## Services and Startup: systemd over D-Bus

The services come from systemd's managers over D-Bus, through the toolkit's own client (`gt:dbus`, no libdbus, no
`systemctl` started): `ListUnits` and `ListUnitFiles`, then `MainPID` and `MemoryCurrent` of each running service, all
asked before any answer is read. Start, Stop and Restart are `StartUnit`, `StopUnit` and `RestartUnit`; Enable and Disable
are `EnableUnitFiles` and `DisableUnitFiles`, then `Reload`, as `systemctl` does. A system service's change is the
manager's to allow: it asks polkit. The call allows interactive authorization (`interactive` of `dbus.call`), so polkit
can ask the user for a password; what it refuses is said in the footer. Inspecteur never runs `sudo`.

The Startup section reads the XDG autostart entries itself (the Desktop Application Autostart Specification) and asks the
user's manager which services the session's targets want (their `Wants` property). An autostart entry of the system is
turned off by the user's copy of it with `Hidden=true`, as the specification says; turned on again, the copy goes when
nothing else changed in it.

A service's details (the pane under the table) come from its unit's properties over the same bus (`LoadUnit`, then
`FragmentPath`, `StateChangeTimestamp`, `TasksCurrent`, `CPUUsageNSec`, `NRestarts`) and its journal's last lines from
`journalctl -u <unit> -n 50` (the journal's own program reads journald's files), on a thread of their own: when another
service is selected, and after each reading of the list. Stop and Restart are asked first: the question says when the
service runs the desktop or Inspecteur (its main process is the display server or one Inspecteur runs under, or
Inspecteur's own cgroup is under that unit).

## Connections

`/proc/net/tcp`, `tcp6`, `udp` and `udp6` list the sockets; a socket's process is the one whose `/proc/<pid>/fd/<n>`
links to `socket:[<inode>]`, its start time read before and after its descriptors. Only the processes the user may read
can be told. That scan of every descriptor is what costs (a few milliseconds): a reading whose sockets are all known (an
owner, or none at the last scan: another user's, one in TIME_WAIT) skips it, ten readings in a row at most.

## Information

What does not change while the program runs (`/etc/os-release`, `uname`, `/sys/class/dmi/id`, `/proc/cpuinfo`, the PCI
display controllers with their names from `pci.ids` when the system has it, the file systems and `statfs`, the screens'
EDID, the batteries) is read on its thread; what changes (the uptime, the memory, the network interfaces) comes from the
last sample of Performance.

## The processes

On Linux everything comes from `/proc`, read with system calls (`openat`, `read`, `getdents`) into one buffer.

- **Each sample**: `/proc/stat` (the machine's CPU time), `/proc/meminfo`, the list of pids, then for each process
  `stat` (parent, CPU time, threads, state, nice, start time), `statm` (resident and shared pages) and `io` (bytes read
  from and written to the storage).
- **Once per process**: its command line, its executable, its owner, its systemd unit (`cgroup`), its app. A process is
  the pair (pid, start time): a pid used again is a new process.
- **CPU %**: the process's CPU time over the machine's, both since the last sample. It is a share of the whole machine
  (top's Irix mode off, as Windows' Task Manager): 100 % is every core busy.
- **Memory**: a process's private memory, its resident pages less those it shares (a file's, shared memory): what it
  costs on its own. A group sums its processes' private memory; their resident memory would count each shared library
  once per process. The Resident column and the Properties show the resident memory too.
- **Disk**: `read_bytes` and `write_bytes` of `io`, what reached the storage, per second. Another user's `io` cannot be
  read: its cells show a dash, and it is not asked again while that process lives.
- **Users**: `/etc/passwd`, read again once for a uid it does not have; a uid with no name is shown as its number.
- **Kernel threads** (`PF_KTHREAD`) are not shown.
- **Names**: the kernel cuts a command name to 15 bytes; the first argument or the executable gives it whole. A Nix
  wrapper's `.firefox-wrapped` is shown as `firefox`.
- **Memory pages**: the page size is the kernel's (`AT_PAGESZ` of `/proc/self/auxv`), not a constant: arm64 may have 16
  or 64 KB pages.
- **The tree** (`processes.view = tree`): each process under its parent, the siblings sorted by the sort's column; a
  filter shows the processes it finds and their lines of parents.

## Apps (apps.odin, processes.odin)

Wayland does not let a program see the other programs' windows. So an app is what the desktop's menu knows: a desktop
entry under `applications/` of each XDG data folder (not hidden, not run in a terminal). A process matches an entry by
its name or its executable's name (the entry's program, its id, its window class), an interpreter's process by its
script, else by the systemd unit its launcher made (`app-<launcher>-<desktop id>-<random>.scope`; a `-` of the id is
escaped `\x2d`). An entry's program is found past its launchers (`env`, `sudo`, `flatpak run`, `systemd-run`, `uwsm app`
and the like: `program_of`), and an interpreter's (Python, Perl, Ruby, Node, Java, Electron, Wine, a shell) is the
script it runs: `python3`, `bash` or `sh` would make every Python program or shell that app.

A group is one entry: every process of that app and the processes under it, unless one of them is another app (a browser
started from a terminal is the browser's). Two windows of one app are one group. End task on a group asks each of the
app's processes to end (`group_roots`): the processes under them end with them, as when the app's windows are closed.
Kill on a group ends every process of it.

The app's icon is its entry's, from the user's icon theme (`desktop.theme_icon`: the theme, what it inherits, hicolor,
then `pixmaps`; PNG or SVG), made into a texture the first time it is shown.

## Actions on processes (menu.odin)

End task sends SIGTERM, Kill sends SIGKILL after a confirmation, End process tree SIGTERM to a process and every
process under it (the last sample's parents) after a confirmation, Suspend and Resume SIGSTOP and SIGCONT. With rows
marked (Ctrl and Shift clicks, Ctrl+A: the toolkit's list marks rows by their identity), End task and Kill act on all
of them; the confirmation lists each process by its name and PID. The toolkit's
`process.signal_process` pins the pid with a pidfd, reads the process's start time again, and signals through the pidfd
only when it is the same: a pid freed and given to another process is not signalled, even between the check and the
signal. A priority and an affinity are set through a descriptor of the process's own `/proc/<pid>` folder, whose start
time is checked, on every thread of the process; the pidfd says afterwards whether the process still ran
(`process.set_priority`, `process.set_affinity`).

Inspecteur does not suspend itself, the processes it runs under (its line of parents), or the display server (on
Wayland the compositor, the peer of `$WAYLAND_DISPLAY`'s socket: `SO_PEERCRED`): nothing could resume them from its
window. Ending the display server, Inspecteur or what it runs under is asked first, and Enter cancels the question of a
kill. Suspend or resume reads the process's state at that moment, not the last sample's.

A dump file (`dump_linux.odin`) is gdb's `gcore` of the process, written on a thread of its own into
`$XDG_CACHE_HOME/inspecteur/dumps`, asked first: it holds whatever the process had in memory. Without gcore, or when the
kernel does not let a user read another process's memory (`kernel.yama.ptrace_scope`), the footer says so.

## Properties (props.odin)

The dialog reads only the tab shown: when it opens, when another tab is shown, and every 3 seconds while the process
lives. A reading opens the process's `/proc/<pid>` folder once, checks the start time through it, and reads every file
relative to it: a pid given to another process meanwhile reads nothing. Once the process is gone it reads nothing and
says so.

## The GPUs (gpu.odin, gpu_linux.odin)

NVML (NVIDIA's library) for NVIDIA, amdgpu's files for AMD, the name for Intel. A GPU that the kernel may put to sleep
(runtime power management, a laptop's second GPU) must not be woken to be watched: NVML wakes it and keeps it awake.
NVML is opened only while the GPUs' numbers are wanted (the Performance section or the GPU memory column shown) and no
NVIDIA GPU sleeps, and closed when they are no longer wanted; a GPU that sleeps is listed "asleep". A GPU that is always
on keeps NVML open. The graphs of a GPU get a point per reading (every 2 s): their span is twice the others'.

## The window (view.odin, table_view.odin, commands.odin)

The interface is built again at each frame (immediate mode). The table is the toolkit's virtual list: it builds the rows
in view only. The selection is kept by the row's identity (pid and start time; an app's entry) across samples, sorts
and filters. Every colour comes from the theme: its page, bars and wells for the surfaces, its border for the lines, its
warning hue for the tint of busy cells. Corners are nearly square (`ui.set_rounding`).

Every action is a command of one table (`COMMANDS`, the toolkit's `ui.Command`): its label, its group, its keys. The
keys are read from it, the menus' lines and the buttons' tooltips say its key, the command palette (Ctrl+K) lists the
commands of the window and of the section shown, and the sheet of the keys (F1) lists them all. A test checks that no
key does two things in one place.

## The desktop (integration.odin, setup_view.odin, src/identity)

`src/identity` holds what Inspecteur is to the desktop: its names, the actions of its desktop entry (one per section:
`--section <name>`, and `StartupWMClass`, the window's class), its icons (`assets/logo_<n>.png`).
`desktop_linux.odin` reads `$XDG_CURRENT_DESKTOP` and says how that desktop opens Inspecteur as its task manager; on
GNOME, the welcome page's button adds the custom shortcut with `gsettings`. `inspecteur setup` and the welcome page write the entry and the
icons for the running executable through the toolkit's `gt:desktop`; `inspecteurtool desktop_files` writes the same for
the Nix package.

## Tests

- Unit tests (`src`; those of the Linux readers' formats in `*_linux_test.odin`): the formats of `/proc`, `/proc/net`, unit files, desktop entries, `os-release`, `pci.ids`, EDID and
  `mountinfo`; the rates, a pid used again, the devices that come and go, the rows' filter and sort, the columns kept,
  the priorities' steps, the apps of a scope, launchers and interpreters; names, sizes, durations; no key doing two things; the preferences'
  documentation.
- `inspecteurtool live`: the real program in a sway with no screen, driven over the DevTools protocol (see
  [development.md](development.md)). A key that changes something is pressed only once the selected row, as the
  accessibility tree says, is the test's own.
- `inspecteurtool bench`: the cold start and the cost at rest, on the GPU.
