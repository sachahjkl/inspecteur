# Changelog

All notable changes to inspecteur are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the versions follow [semantic versioning](https://semver.org/).

## [Unreleased]

### Added
- **Processes**: name with the app's icon, PID, user, CPU % (of the whole machine), memory, disk read and write rates,
  threads, read from `/proc` each second (`processes.refresh_ms`).
- **Apps and background processes**: a process the desktop's menu knows is an app; the processes under it are in its
  group, which opens and closes. Two windows of one app are one group.
- **Sort** by any column, **filter** as you type (name, command line, PID).
- **End task** (Delete, SIGTERM) and **Kill** (Shift+Delete, SIGKILL, after a confirmation), from the toolbar, the keys
  or the row's menu; the menu also opens the executable's folder and copies the command line.
- The machine's CPU and memory in the sidebar and the footer.
- **Performance**: CPU (one graph, or one per logical processor), memory, each disk, each network interface and each GPU,
  with a minute of history kept while another section is shown, and their numbers (frequency, caches, load, composition
  of the memory, throughput, active time, addresses, VRAM).
- **Columns**: a right click on the header shows or hides them (PPID, state, nice, start time, command line, executable
  and more); dragging a header's rule resizes one. Both are kept, with the sort.
- **Properties** of a process: general, threads, open files, modules, environment; set its priority, suspend and
  resume it, end or kill it. What the user may not read says "Access denied".
- **Light or dark**: from the title bar's menu, kept.
- **Connections**: every TCP and UDP socket, IPv4 and IPv6, with the process that holds it (its icon, name and PID),
  its local and remote addresses and its state; sort, filter, End task, Kill, Open in Processes, Copy address. Read on a
  thread of its own, only while the section is shown.
- **Services**: the services of systemd's system manager or of the user's (System and User, Ctrl+U; kept), with their
  description, state, whether they start by themselves, their load state, main process and memory; Start (Ctrl+S), Stop
  (Delete), Restart (Ctrl+R), Enable (Ctrl+E), Disable (Ctrl+D), Open in Processes (Enter), Copy name (Ctrl+C). Read over
  D-Bus on a thread of its own, every `services.refresh_ms` while shown and at once after an action; the footer says
  what came of it, the manager's own words when it refuses.
- **Startup**: what starts with the session: the XDG autostart entries (the user's and the system's, with Hidden=,
  OnlyShowIn=, NotShowIn= and X-GNOME-Autostart-enabled=) and the user's systemd services the session's targets want;
  their command, type, status and file. Enable (Ctrl+E), Disable (Ctrl+D), Space toggles, Open file location (Enter),
  Copy command (Ctrl+C). A system's autostart entry is turned off by the user's copy of it with Hidden=true, as the
  specification says; turned on again, the copy goes when nothing else changed in it.
- **Information**: the system (name, kernel, computer, motherboard, firmware, session, uptime), the processor, the memory,
  the GPUs (with their PCI ids and driver), the disks and file systems with their free room, the network interfaces with
  their MAC and addresses, the screens (their EDID's name and mode), the batteries. **Copy all** (Ctrl+C) copies it as text.
- A table's cell too narrow for its text shows the whole text when the pointer rests on it, in the Processes table too.
- **Keys**: Ctrl+F gives the filter the keyboard, Ctrl+1 to Ctrl+6 show a section, F5 reads again now; the filter
  filters the section shown, and Escape clears it in every section.
- Preferences: the services listed and how often (`services.manager`, `services.refresh_ms`), refresh period, theme, light or dark, finish, text size, window size (`docs/configuration.md`).

### Changed
- The tables, the graphs, the sidebar's bars, the readers' threads, typing to filter, the network interfaces' addresses
  and the names' order are gui_toolkit's now (`ui.table_build`, `ui.table_header`, `ui.line_graph`, `ui.sparkline`,
  `ui.meter_bar`, `ui.Worker`, `ui.type_to_field`, `platform.interface_addresses`, `ascii.compare_fold`), on gui_toolkit
  0.139.0.
- A signal and a priority go through a pidfd: the process's start time is read again while the pid is pinned, so a pid
  given to another process is never signalled. A priority is set on every thread of the process, not on its main thread
  alone.
- Start, Stop, Restart, Enable and Disable of a system service let polkit ask for a password (interactive
  authorization), and wait up to two minutes for it.
- The apps' icons come from the user's icon theme (and its SVG icons), not from hicolor alone.
- Typing while a menu is open no longer fills the filter.
