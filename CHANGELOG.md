# Changelog

All notable changes to inspecteur are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the versions follow [semantic versioning](https://semver.org/).

## [Unreleased]

### Added
- **Tables in stripes, with a rule under each row** (Processes, Services, Startup, Connections, the Properties' lists):
  `view.zebra` and `view.rules` turn them off.
- **A CPU graph in each row** (the `cpu_graph` column, shown by default): the last 30 samples of a process's or an
  app's CPU, a bar each in the colours of the load; its tooltip says the mean and the highest; sorted, it orders by the
  mean.
- **Temperatures and frequencies**: the processor's package and dies or cores (k10temp, zenpower, coretemp), with a
  graph on the CPU's page; each logical processor's frequency over its graph; the GPU's temperature graph; the times
  an Intel processor slowed for its heat.
- **Pressure** in Performance: the share of the time tasks waited for the CPU, the memory and the disks
  (`/proc/pressure`), over 10 and 60 seconds, with a graph.
- **A summary of the machine over the Processes table**: CPU, memory, disks, network, GPU, temperature and pressure,
  each its value, its last minute and a stripe in the colour of its load; a click shows the device in Performance.
  Ctrl+B (`processes.summary`) hides it.
- **History in Properties**: graphs of the process's CPU, private memory and disk since Inspecteur saw it start (5
  minutes at most at the default period).

### Changed
- **Busy cells go from green through yellow and orange to red** as the load grows, in full colours with a darker
  outline, deeper on a dark theme, with dark or light text, whichever reads on the colour (it was one orange tint).

## [0.1.0] - 2026-11-10

### Added
- **Processes**: name with the app's icon, PID, user, CPU % (of the whole machine), private memory, disk read and write
  rates, threads, read from `/proc` each second; more columns from the header's right click (Ctrl+Shift+C): parent,
  state, priority, resident memory, GPU memory, start time, command line, executable. Their widths, the sort and the
  columns shown are kept.
- **Apps and background processes**: a process the desktop's menu knows is an app, and the processes under it are in
  its group; a launcher (env, sudo, flatpak, systemd-run...) or an interpreter (Python, Node, a shell...) is never taken
  for an app. Or **every process under its parent** (Ctrl+T, `processes.view`).
- **Select many rows**: Ctrl and Shift clicks, Ctrl+A; End task and Kill act on all of them.
- **End task** (Delete), **Kill** (Shift+Delete) and **End process tree** (Ctrl+Delete): a kill and a tree are asked
  first, the confirmation lists each process by its name and PID, and says when Inspecteur or the session would end
  with them. Signals go through a pidfd, after the process's start time is read again: a PID given to another process
  is never signalled.
- **Suspend or resume** (Ctrl+P), **the priority** (Ctrl+Up, Ctrl+Down), **the affinity** (Ctrl+Shift+A: the logical
  processors a process may run on), **Go to service** (Ctrl+Shift+S), **Search online** (Ctrl+Shift+F), **Create dump
  file** (Ctrl+Shift+D, asked first: gdb's gcore), Open file location (Ctrl+O), Copy command line (Ctrl+C). Inspecteur
  does not suspend itself, what it runs under, or the desktop's compositor.
- **Properties** of a process (Alt+Enter): general, threads, open files, modules, environment, each list with a filter
  (Ctrl+F); its priority and affinity, suspend, resume, end, kill. What another user's process does not let you read
  says "Access denied".
- **Performance**: CPU (one graph, or one per logical processor: Ctrl+G), memory and its composition, each disk, each
  network interface and each GPU, with a minute of history and their numbers. A laptop's GPU that sleeps is not woken.
- **Services**: systemd's system or user services (Ctrl+U) over D-Bus: state, start at boot, load state, main process,
  memory. Start (Ctrl+S), Stop (Delete) and Restart (Ctrl+R, both asked first), Enable (Ctrl+E), Disable (Ctrl+D), Open
  in Processes (Enter), Copy name. A pane under the table shows the selected service's unit file, since when it is in
  its state, its tasks, CPU time, restarts and its journal's last lines (Ctrl+I); Open unit file (Ctrl+O). polkit may
  ask for a password, and the footer says what the manager answered.
- **Startup**: the XDG autostart entries and the user services the session wants, turned on or off as the
  specification says; Open file location, Copy command.
- **Connections**: every TCP and UDP socket, IPv4 and IPv6, with its process; End task, Kill, Open in Processes, Copy
  address.
- **Information**: the system, processor, memory, GPUs, disks and file systems, network interfaces, screens and
  batteries; Copy all (Ctrl+C).
- **The refresh**: paused and resumed (Ctrl+Space), its speed from the title bar (Ctrl+Shift+R, kept), said in the
  footer; F5 reads again now.
- **The text size**: Ctrl+=, Ctrl+-, Ctrl+0 (kept).
- **Every action has its key**, said in its menu line and its tooltip; the **command palette** (Ctrl+K, Ctrl+Shift+P)
  finds an action or a section by its words; **F1** lists every key.
- **Filter as you type** in any section; **sort** by any column; the Services, Startup and Connections tables keep their
  widths and sort.
- **The welcome page** and `inspecteur setup`: Inspecteur in the application menu, with its icon and an action per
  section; how the desktop shown opens it as its task manager (GNOME: the shortcut added in a click; KDE Plasma;
  shojiwm-win7). The Nix package installs the same entry and icons.
- **Themes**: every theme of gui_toolkit, light or dark (Ctrl+Shift+L).
- `inspecteur --demo`: a made-up machine in place of the real one: the pictures of the documentation are made with it.
- `inspecteur prefs` lists every preference; `--pref name=value` sets one for a run (`docs/configuration.md`).
[0.1.0]: https://github.com/sachahjkl/inspecteur/releases/tag/v0.1.0
