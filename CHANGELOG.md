# Changelog

All notable changes to inspecteur are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the versions follow [semantic versioning](https://semver.org/).

## [Unreleased]

### Added
- **Ctrl held pauses the refresh**, as in Windows' Task Manager: the rows stand still under the pointer, and the footer
  says "Paused while Ctrl is held" until it is let go (gui_toolkit 0.189.0, `ui.key_held`).
- **Columns moved by their titles**: a title dragged sideways moves its column, in Processes, Services, Startup and
  Connections; the order is kept (`processes.order`, `services.order`, `startup.order`, `connections.order`).
- **A third click on a title leaves the rows unsorted**: as they are read (the processes by PID); kept as
  `processes.sort = none` (gui_toolkit 0.188.0).
- **The window opens as it was left**: on the section shown last (`view.section`; `--section` shows another), the CPU's
  page overall or per logical processor (`performance.cpu_view`).
- **Each core's temperature**, in the logical processors' view (Ctrl+G) and, coolest to hottest, in the CPU's
  details: from coretemp's "Core N" sensors (Intel), else from the SMU's power table of the ryzen_smu driver (AMD, Zen
  to Zen 3; NixOS: `hardware.cpu.amd.ryzen-smu.enable`). Without either, nothing is shown.
- **Mission Control: a menu on each line** (a right click): its section, and what is related to it. A process: its
  properties, its service, its connections, its folder, its command line. A failed service: its process, its details and
  journal.
- **The settings in the command palette** (Ctrl+K): each preference is a line under "Settings · <page>"; chosen, the
  settings open on it alone.
- **Commands and settings found by other words**: "kill" finds End task, "dark" the theme's version, "slow" Why is it
  slow?; the matched letters are lit.
- **The edged finish** (`view.finish = edged`, the Console theme's): the machined reliefs crisp, nothing blurred.
- **The system's title bar, by choice** (`view.system_title`), where the desktop draws one.
- The settings' pages say Inspecteur's version at their bottom.
- **Mission Control** (Ctrl+1; the other sections Ctrl+2 to Ctrl+7): the whole machine on one page, in panels of
  gui_toolkit's dock that the user moves, stacks, resizes, floats, closes and brings back; the layout as at first; the
  layout kept (`mission.layout`). A click on a line goes to its section. Its Health panel: the state in a word and its
  colour, a trace as a heart monitor's (a beat per sample, as high as the CPU was busy), an (i) whose tooltip says each
  finding.
- **A horizontal scroll bar** under the tables wider than their room.
- **One Inspecteur at a time**: a second start (Ctrl+Shift+Escape again, a launcher, `--section`) shows its section in
  the one that runs, which comes to the front.
- **Zoom** as every program of gui_toolkit: Ctrl+wheel, Ctrl+=, Ctrl+-, Ctrl+0 (`view.zoom`, kept).
- **The palette resizable** from its edges and its corner, its size kept (`view.palette_size`); each command with its
  icon.
- **The tables scroll sideways** when the window is narrower than their columns (Shift+wheel, a touchpad); the titles
  follow.
- The refresh's sliders in the settings apply as they move; Ctrl+F gives the settings' search the keyboard.
- **The services' journal, in depth**: each entry's time, level in its colour, program and process, message; all,
  warnings or errors with their counts (Alt+L); this boot or every boot (Alt+B); followed live, new entries at the end
  (Alt+F); a search of its own (Ctrl+J); the selected entry whole, its message wrapped; Copy the entries shown (Alt+C) or
  the entry (Alt+Shift+C); the pane's height dragged from the line above it. Up to 1000 entries.
- **A service's journal in a window of its own** (Ctrl+Shift+J, or the pane's button): it keeps its service while the
  pane follows the selection, with the same keys; several at once, one per service; Ctrl+W closes it.

### Fixed
- Mission Control: a click anywhere on a line goes to its section; its name took the click before, only its right part
  answered.
- Performance: the key that switches the CPU's view (Ctrl+G) is in its segments' tooltips, not beside them.

- **Resizing a column** resizes the column at the left of the line, as in a file manager: the columns after it move,
  none before. **A third click on a title** comes back to the table's own sort.
- **The palette's field** is flush with its edges; the keys stay clear of its scroll bar.
- **The palette no longer crashes on a search that keeps nothing** (gui_toolkit 0.176.1).
- **Resizing a column moves no other column a frame late** (gui_toolkit 0.169.0: the fill column is resolved in the same
  build); the stripes of the tables are fainter.


## [0.2.0] - 2026-11-10

### Added

- **Install and updates as every program of gui_toolkit**: a copy that is not installed offers to install itself for the
  user (the program, its menu entry with an action per section, its icons); `inspecteur install`, `uninstall`, `status`,
  `--setup`. The installed copy checks the signed releases every day and puts a new version in place (`update.auto`).
  On NixOS a classic install runs by itself; the Nix package is left to Nix.
- **Settings** (Ctrl+, or the title bar's button): every preference on a page, searched, applied at once; the themes as
  cards; Check for updates.
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
- **GPU use per process** (the `gpu` column): the share of a GPU's time a process keeps busy, as NVIDIA's driver tells
  it; read only while a GPU column or Performance is shown, so a sleeping GPU is not woken.
- **Pinned apps and processes** (Alt+P, `processes.pinned`): a section of their own above the others, whatever the
  sort, kept by name across starts.
- **What changes shows**: a process that comes flashes green and fades; one that ends stays a moment in red, fading
  out, and nothing acts on it any more. With the animations off they keep their colour, still.
- **Why is it slow?** (F2): what the last sample says, in sentences, the worst first: the processors and who keeps
  them busy, the time tasks waited, the memory and the swap, the disks, the GPU, the heat.
- **History in Properties**: graphs of the process's CPU, private memory and disk since Inspecteur saw it start (5
  minutes at most at the default period).

### Changed

- **Fainter stripes**: every second row of the tables is half as far from the page (gui_toolkit 0.165.1).
- **Machined by default** (`view.finish`): raised buttons and dialogs, sunken fields, graphs and meters. `flat` gives
  back the plain look.
- **Ctrl+F selects the filter's text**: what is typed then replaces it.
- **The Properties' actions in colour**: Suspend in the accent, End task in amber, Kill in red.
- **A narrow window keeps the names readable**: the name column keeps its width and cuts what does not fit; the last
  columns go past the edge.
- **Busy cells go from green through yellow and orange to red** as the load grows, in full colours with a darker
  outline, deeper on a dark theme, with dark or light text, whichever reads on the colour (it was one orange tint).

### Removed

- The welcome page, `inspecteur setup` and the steps per desktop for the task manager's key: the install's dialog and
  `inspecteur install` replace them.

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
[0.2.0]: https://github.com/sachahjkl/inspecteur/releases/tag/v0.2.0
