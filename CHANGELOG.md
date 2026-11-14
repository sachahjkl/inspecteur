# Changelog

All notable changes to inspecteur are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the versions follow [semantic versioning](https://semver.org/).

## [0.5.1] - 2026-11-14

### Fixed
- **Dialogs open without a jump**: a dialog shows at its final size and place from its first frame, and the shade behind it fades in with it.

## [0.5.0] - 2026-11-13

### Added
- **A Diagnostics page in the settings, with a Copy button.** It shows the versions, the system, the graphics adapter (and whether a software rasterizer draws), the window's size and scale, the last frames' times and how much partial redraw drew. If inspecteur is slow, copy it and send it.

### Changed
- **The licence has its own page in the settings, worded as in the other programs.** It says whether inspecteur is registered. It offers Buy a licence, a field to paste a key, Choose a licence file… and Remove the licence.
- **A crash of the last run shows in a bar at the top of the window**, in place of a message with the report's path. The bar says what happened and offers Open the report, Copy and Report on GitHub (a new issue with the report in it). Its cross dismisses it.
- **The install is in the settings: an Installation page.** It says where the installed copy is, its version, and whether this copy is the installed one. It shows the menu entry and the PATH, with Install, Repair, Upgrade and Uninstall. The palette finds the page ("install").
The command line is `--install`, `--uninstall`, `--status` and `--setup`, as in the other programs. `--status` says what is installed and whether inspecteur runs. `inspecteur install`, `uninstall`, `status` and the Install… command (Ctrl+Shift+I) are gone.
- **A change of language shows at once**: the windows, the settings and the titles of the journal's and Mission Control's windows take the new language without a restart.
- **inspecteur has the same settings and look as the other programs of Froment Software.** Only its theme, Graphite, is its own. It now starts with 14 px text (was 13), the machined finish's glow and the usual rounded corners (they were nearly square). A setting that you changed keeps your value; Reset in the settings gives the new defaults.

### Fixed
- **Narrow windows and longer words cut no text.** In a narrow window, the Performance page puts its table of details under the big numbers instead of over them. The journal's bar wraps onto a second line, and the startup problem wraps under the bar. A process's name ends with "…" where it is cut. The journal's level and boot, the System and User choice and the CPU view's choice are as wide as their longest word in every language.
- **French done right.** The services' states (active, running, enabled, static, loaded…) are in the language in use, in Services, their details and Mission Control. The settings' choices of the process view, the manager and the journal level are translated. Keys have the names that a French keyboard prints, and numbers use the French decimal mark and spacing. Some words are clearer ("Actualiser", "Fils", "État", "Carte graphique", "Fermeture en attente"), and the program writes its name "inspecteur" everywhere.

## [0.4.2] - 2026-11-13

### Changed
- **One licence at one price, and a new pricing page**: the inspecteur licence is now one edition at 15 €, paid once, taxes included; the Patron edition is gone. The pricing page shows inspecteur's icon and name, one card with the price, what the licence gives as a list, one button, then "Before you buy". The licence is named "inspecteur licence" on the site, at checkout and in the licence file.

## [0.4.1] - 2026-11-13

### Fixed
- **The Windows download is there again**: 0.4.0 had no Windows archive (its build stopped on a check that read the files with Windows line endings). This version has it.

## [0.4.0] - 2026-11-13

### Added
- **The palette remembers what you choose**: its Recent group holds the commands you choose often and lately. A command chosen often stays near the top for weeks, and while you type it comes before an equal match.
- **A report when Inspecteur crashes**: a crash writes a report and the log's last lines in Inspecteur's state folder (`~/.local/state/inspecteur`). The next start says where the report is. Nothing is sent anywhere.
- **Each service has an icon**: its process's app when it has one, else your icon theme's icon for the service's name or its family (network, sound, Bluetooth, printing, disks, time, security, session...), else a glyph of that family.
- **Send a signal**: a process's menu, and the palette, send SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGKILL, SIGSTOP, SIGCONT, SIGUSR1 or SIGUSR2 to the selected processes. A kill asks first. Inspecteur, what runs it and the display server are guarded as for End task and Suspend.
- **Show its window**: an app's row, and a process of an app, has a window button that brings its window to the front. Its tooltip names the window; with several, each click shows the next one. The row's menu, the palette and Ctrl+Shift+W do it too. It works where the compositor lists the session's windows (wlr-foreign-toplevel: sway, Hyprland, niri...).
- **A licence to support Inspecteur**: the settings' General page says to whom Inspecteur is registered, or links to buy a licence. It takes a key pasted or a licence file chosen, and checks it on the computer, with no network. A licence changes nothing of what Inspecteur does. The shop is not open yet.
- **Settings exported and imported**: the settings' sidebar has Export… (JSON, TOML, INI or Inspecteur's own format) and Import…, to carry them to another computer.
- **Your own themes**: the settings' Appearance page links to `themes.txt`, beside the preferences. A click makes the file, with its instructions, and opens it. A theme written there shows among the themes' cards and in the title bar's colours menu. A change to the file shows within two seconds.
- **Inspecteur in French**: its sections, menus, buttons, tooltips, the command palette, the dialogs, the settings and the messages are in French, with a space before ":", ";", "?" and "!". The Language setting, on the settings' General page, chooses System, English or Français; System follows the system's language. A change takes effect at the next start. The settings' search finds a setting by its French words and by its English ones.

### Changed
- **Copied, as a notification**: a copy (a command line, a service, an address, the journal, the system's information) is confirmed by a desktop notification, or in the window where the desktop shows none.
- **Dialogs and confirmations**: the affinity dialog and "Why is it slow?" open in the middle of the window. A dialog opens at its size and place, with no jump. A kill, the end of a process tree, a service's stop and a dump file are asked in one confirmation: a title strip with a close button, and the act's button in red, or in green when the act is safe and Enter confirms it.
- **One look for every search**: the filter at the top of the sidebar is a band in a field's colour, as the command palette's search and the menus' are. Its hint stays while it has the keyboard. The theme's and the refresh's menus also filter their lines as you type, as the other menus do.
- **More settings, on more pages**: besides the look (theme, density, rounding, animations, glow) and Inspecteur's own, the settings have pages for the text and its fonts, scrolling, input, delays and menus, rendering and where messages show. A technical setting is under a folded Advanced part; the search finds it. The text size goes from 10 to 24 pixels. The tables' stripes and lines are on a Tables page. The settings' sidebar can be resized, and keeps its width. The system's title bar is switched at once, with no restart. The look's settings have new names (`appearance.theme`, `appearance.mode`, `appearance.finish`, `appearance.font_size`, `appearance.zoom`, `window.system_title`): a theme, a text size or a zoom chosen before must be chosen again.

### Fixed
- **A name the filter finds is aligned with its row**: the lit name of an app or a process sat higher than the rest of its row.
- **A scrollbar at the window's edge is easy to grab**: on Wayland the resize bands are around the window, not inside it, so a list's scrollbar at the right edge takes the pointer on its whole width.
- **Clean edges and corners**: a box in a rounded corner (a title, a header, a menu's first line) takes that corner, and a corner too small to round is square. The Properties' title no longer covers the dialog's corner and rim, and a tab's line no longer runs into the rim. A menu is as wide as its widest line, and a tooltip in a menu shows over it.
- **Pinning a process of an app pins its app**: Alt+P on a process listed under an app (a tab of a browser, a shell in a terminal) said it was pinned but showed it nowhere. It now pins the app, which the Pinned section shows.
- **Inspecteur keeps reading while its window is hidden**: on another workspace, its samples and their history go on. They stopped until the window showed again.
- **The window no longer freezes**: the processes and the machine each second, the Properties' lists, a signal, a priority or an affinity, the apps' icons, the install's state and the saved settings are read or written in the background. A process stuck in the kernel or a slow disk cannot stop the window, a column drag or a theme change. On Wayland with NVIDIA's driver, the window no longer freezes when the compositor holds back its frames.

## [0.3.0] - 2026-11-11

### Added
- **The command palette forgives a slip**: a word typed with a letter missing, one too many or two swapped still finds its command or setting, after the exact matches (gui_toolkit 0.193.0).
- **The filter lit in the tables**: what it finds is highlighted in the processes' names and cells, and in the Services, Startup and Connections tables.
- **A menu on every table's header** (a right click): reset the column under the pointer (its width, its sort), unsorted, the columns shown, the default columns. Services, Startup and Connections have it too.
- **Icons in the menus**: each command of a right click menu has its icon, as in the command palette.
- **The window opens as it was left**: its size and whether it was maximized (`view.placement`, written when it closes). `view.width` and `view.height` are gone.
- **A Mission Control panel in a window of its own**: its tab's menu, *Open in a window*, for a second screen or to keep it in view while another section is shown. A click on one of its lines shows that section in the main window. Closed, the panel goes back to Mission Control; the windows open come back at the next start.
- **Ctrl held pauses the refresh**, as in Windows' Task Manager: the rows stand still under the pointer, and the footer says "Paused while Ctrl is held" until it is let go (gui_toolkit 0.189.0, `ui.key_held`).
- **Columns moved by their titles**: a title dragged sideways moves its column, in Processes, Services, Startup and Connections; the order is kept (`processes.order`, `services.order`, `startup.order`, `connections.order`).
- **A third click on a title leaves the rows unsorted**: as they are read (the processes by PID); kept as `processes.sort = none` (gui_toolkit 0.188.0).
- **The window opens as it was left**: on the section shown last (`view.section`; `--section` shows another), the CPU's page overall or per logical processor (`performance.cpu_view`).
- **Each core's temperature**, in the logical processors' view (Ctrl+G) and, coolest to hottest, in the CPU's details: from coretemp's "Core N" sensors (Intel), else from the SMU's power table of the ryzen_smu driver (AMD, Zen to Zen 3; NixOS: `hardware.cpu.amd.ryzen-smu.enable`). Without either, nothing is shown.
- **Mission Control: a menu on each line** (a right click): its section, and what is related to it. A process: its properties, its service, its connections, its folder, its command line. A failed service: its process, its details and journal.
- **The settings in the command palette** (Ctrl+K): each preference is a line under "Settings · <page>"; chosen, the settings open on it alone.
- **Commands and settings found by other words**: "kill" finds End task, "dark" the theme's version, "slow" Why is it slow?; the matched letters are lit.
- **The edged finish** (`view.finish = edged`, the Console theme's): the machined reliefs crisp, nothing blurred.
- **The system's title bar, by choice** (`view.system_title`), where the desktop draws one.
- **The version on the settings' pages**: Inspecteur's version at their bottom.
- **Mission Control** (Ctrl+1; the other sections Ctrl+2 to Ctrl+7): the whole machine on one page, in panels of gui_toolkit's dock that the user moves, stacks, resizes, floats, closes and brings back; the layout as at first; the layout kept (`mission.layout`). A click on a line goes to its section. Its Health panel: the state in a word and its colour, a trace as a heart monitor's (a beat per sample, as high as the CPU was busy), an (i) whose tooltip says each finding.
- **A horizontal scroll bar** under the tables wider than their room.
- **One Inspecteur at a time**: a second start (Ctrl+Shift+Escape again, a launcher, `--section`) shows its section in the one that runs, which comes to the front.
- **Zoom** as every program of gui_toolkit: Ctrl+wheel, Ctrl+=, Ctrl+-, Ctrl+0 (`view.zoom`, kept).
- **The palette resizable** from its edges and its corner, its size kept (`view.palette_size`); each command with its icon.
- **The tables scroll sideways** when the window is narrower than their columns (Shift+wheel, a touchpad); the titles follow.
- **The settings apply as their sliders move**: the refresh's sliders act at once; Ctrl+F gives the settings' search the keyboard.
- **The services' journal, in depth**: each entry's time, level in its colour, program and process, message; all, warnings or errors with their counts (Alt+L); this boot or every boot (Alt+B); followed live, new entries at the end (Alt+F); a search of its own (Ctrl+J); the selected entry whole, its message wrapped; Copy the entries shown (Alt+C) or the entry (Alt+Shift+C); the pane's height dragged from the line above it. Up to 1000 entries.
- **A service's journal in a window of its own** (Ctrl+Shift+J, or the pane's button): it keeps its service while the pane follows the selection, with the same keys; several at once, one per service; Ctrl+W closes it.

### Changed
- **The sockets are read on their own period** (`connections.refresh_ms`, 3 s by default, in the settings' Connections page), not at each refresh of the processes: a reading goes through every process's open files, and Connections or Mission Control shown cost a core's share each second.
- **The Properties dialog's title on a darker bar**: the process's name and facts on the bars' surface, a line under them, apart from the tabs.
- **Square rows**: a selected row of a list, a table or a menu fills its whole width with square corners, and a table's tinted cell is square too. The Console theme is named Kernel (gui_toolkit 0.191.1).

### Fixed
- **The command palette's field has the dialog's corners**: no second, rounder corner inside the dialog's own (gui_toolkit 0.196.2).
- **Inspecteur no longer freezes when another of its windows covers it**: a journal's or a panel's window over the main window whole stopped it answering (gui_toolkit 0.196.0).
- **Inspecteur at rest no longer draws without a pause**: a process that came or went faded at the screen's rate, and a busy machine always has one, so Processes drew about ten frames a second; the fade now steps with the samples.
- **The panels' menu of Mission Control shows its last line whole**, and the command palette's field, flush with its edges, is on a darker field's background (gui_toolkit 0.192.1).
- **Connections scrolls up**: each new reading brought the selected socket back into view, so the list jumped back down every second.
- **Mission Control: a click anywhere on a line** goes to its section; its name took the click before, only its right part answered.
- **Performance: Ctrl+G in the tooltips**: the key that switches the CPU's view is in its segments' tooltips, not beside them.
- **Resizing a column** resizes the column at the left of the line, as in a file manager: the columns after it move, none before.
- **The palette's field** is flush with its edges; the keys stay clear of its scroll bar.
- **The palette no longer crashes on a search that keeps nothing** (gui_toolkit 0.176.1).
- **Resizing a column moves no other column a frame late** (gui_toolkit 0.169.0: the fill column is resolved in the same build); the stripes of the tables are fainter.

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
[0.5.1]: https://github.com/sachahjkl/inspecteur/releases/tag/v0.5.1
[0.5.0]: https://github.com/sachahjkl/inspecteur/releases/tag/v0.5.0
[0.4.2]: https://github.com/sachahjkl/inspecteur/releases/tag/v0.4.2
[0.4.1]: https://github.com/sachahjkl/inspecteur/releases/tag/v0.4.1
[0.4.0]: https://github.com/sachahjkl/inspecteur/releases/tag/v0.4.0
[0.3.0]: https://github.com/sachahjkl/inspecteur/releases/tag/v0.3.0
[0.1.0]: https://github.com/sachahjkl/inspecteur/releases/tag/v0.1.0
[0.2.0]: https://github.com/sachahjkl/inspecteur/releases/tag/v0.2.0
