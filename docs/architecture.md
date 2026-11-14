# Architecture

Inspecteur is one program in [Odin](https://odin-lang.org) on [gui_toolkit](https://github.com/sachahjkl/gui_toolkit)
(the `ext/gui_toolkit` submodule, the collection `gt`). This page says how its parts fit. The reasons behind them (the
decisions, the refused alternatives, the subtle points) are in [src/md](../src/md/README.md).

## The window's thread, and the readers' threads

```
inspecteur ─ the window's thread (app.odin): no system call
               sleeps in the toolkit's wait until input, the next sample, or a reading posted to it
               a reading taken: the machine (machine.odin) -> the processes (sampler.odin) -> groups (processes.odin)
               -> rows, and the busiest processes ranked (diagnosis.odin)
           ─ the toolkit's chores (gt:tasks, ui.chores): the sample (sample.odin), every reader of a section
             (Services, Startup, Connections, Information, a service's details and journal), the Properties' reads,
             the acts on processes (acts.odin), a dump file, the apps' icons, the setup's facts
           ─ the GPUs' thread (gpu.odin): every 2 s
```

Nothing that touches the system runs on the window's thread: a file of `/proc` of a process stuck in the kernel, a call
to systemd that waits for polkit, a file system on a network that does not answer would freeze the window. A reader is a
`tasks.Job` on the toolkit's chores (or a `ui.task` for a single act): its work reads into a new reading of its own and
posts it (`ui.post`), and the window takes it at the start of its next build. The sample (sample.odin) asks one reading
at a time: the window asks the next once it took the last. The first is asked before the window opens and read while
it opens; the first frame waits for it, two seconds at most. A section reads only while it is shown (Information: when
it is first shown, and on F5): the other sections cost nothing.

What a frame shows is made when its data changes, not at each frame: the journal's entries a level and a search keep,
the Properties' rows a filter keeps, the busiest processes, the counts of Mission Control. Between two samples, with no
input, nothing runs. In a window the user is not in, the filter's caret neither shows nor blinks
(`Build_Params.inactive`): at rest, one frame per sample.

## The system and the views

Every reading of the system is in a `*_linux.odin` file, behind plain structs and procs; the models, the views and the
commands hold no path of `/proc` or `/sys`, no system call. Why, and what a Windows port writes:
[src/md/infrastructure/porting.md](../src/md/infrastructure/porting.md).

| Section | Model (neutral) | Reader (Linux) | View | Its reasons |
|---|---|---|---|---|
| Processes | `sampler.odin`, `processes.odin`, `apps.odin` | `processes_linux.odin`, `apps_linux.odin` | `table_view.odin`, `menu.odin` | [processes.md](../src/md/features/processes.md), [apps.md](../src/md/features/apps.md) |
| Properties | `props.odin` | `props_linux.odin` | `props_view.odin` | [processes.md](../src/md/features/processes.md) |
| Performance | `machine.odin`, `gpu.odin` | `machine_linux.odin`, `gpu_linux.odin` | `perf_view.odin` | [gpus.md](../src/md/features/gpus.md) |
| Services | `services.odin` | `services_linux.odin` | `services_view.odin` | [services.md](../src/md/features/services.md) |
| Startup | `startup.odin` | `startup_linux.odin` | `startup_view.odin` | [services.md](../src/md/features/services.md) |
| Connections | `connections.odin` | `connections_linux.odin` | `connections_view.odin` | [connections.md](../src/md/features/connections.md) |
| Information | `information.odin` | `information_linux.odin` | `information_view.odin` | |
| the session | `menu.odin` (the guards) | `session_linux.odin`, `desktop_linux.odin` | `setup_view.odin` | |
| a dump file | `dump.odin` | `dump_linux.odin` | | [processes.md](../src/md/features/processes.md) |
| the system's words | `props.odin` (`Priority`) | `system_linux.odin` | | |

The demo (`demo.odin`, `inspecteur --demo`) is a third source behind the same procs. The pictures of the documentation
are made with it (see [development.md](development.md)).

## Information

What does not change while the program runs (`/etc/os-release`, `uname`, `/sys/class/dmi/id`, `/proc/cpuinfo`, the PCI
display controllers with their names from `pci.ids` when the system has it, the file systems and `statfs`, the screens'
EDID, the batteries) is read on its thread; what changes (the uptime, the memory, the network interfaces) comes from the
last sample of Performance.

## The window (view.odin, table_view.odin, commands.odin)

The interface is built again at each frame (immediate mode). The table is the toolkit's virtual list: it builds the rows
in view only. The selection is kept by the row's identity (pid and start time; an app's entry) across samples, sorts
and filters. Every colour comes from the theme: its page, bars and wells for the surfaces, its border for the lines, its
warning hue for the tint of busy cells. Corners are nearly square (`ui.set_rounding`).

Every action is a command of one table (`COMMANDS`, the toolkit's `ui.Command`): its label, its group, its keys. The
keys are read from it, the menus' lines and the buttons' tooltips say its key, the command palette (Ctrl+K) lists the
commands of the window and of the section shown, and the sheet of the keys (F1) lists them all. A test checks that no
key does two things in one place.

## Install, updates, settings (setup.odin, updates.odin, settings_view.odin, src/identity, src/update)

`src/identity` holds what Inspecteur is to the desktop: its names, the actions of its desktop entry (one per section:
`--section <name>`, and `StartupWMClass`, the window's class), its icons (`assets/logo_<n>.png`). `setup.odin` gives it to
the toolkit's `gt:setup` through `prefs_page.Install`: the install's dialog, offered at the start of a copy that is not
installed (once per version, `install.choice`), the settings' Installation page, and `--install`, `--uninstall`,
`--setup`. The updates start once that reading says which copy runs (`setup_follow`). On NixOS a classic install builds a profile of
`NIXOS_LIBRARIES` and points the copy at it; a copy from the Nix store is never offered an install. `inspecteurtool
desktop_files` writes the same entry and icons for the Nix package.

`updates.odin` runs the toolkit's `gt:update`: the installed copy checks the latest release's manifest, signed with the
key of `src/update/product.odin` (its private half is the release workflow's secret `UPDATE_SIGNING_KEY`, and
`secrets/production.yaml` with SOPS), downloads the program and puts it in place; it runs at the next start.
`settings_view.odin` shows the preferences' registry with the toolkit's `gt:prefs_page` (the layouts of the tables are
`hidden`: the tables set them). The look, the text, the scrolling, the input, the delays, the rendering, the updates and
the messages are the toolkit's standard settings (`prefs_page.standard_register` in `settings.odin`): `standard_watch`
applies them to the main window as they change, and the views' windows follow its style (the toolkit's
`style_follow`); the theme is shown by `app_params` from `appearance_read`, over the toolkit's themes and the user's own
(`themes.txt`, `prefs_page.Themes_File`).

## The views

`views.odin` declares inspecteur's views (gui_toolkit's views, its `docs/views.md`): Properties (`props`), the
affinity, "Why is it slow?", the service's details (`service`), a service's journal (`journal`, an instance per
service) and Mission Control's eight panels (`mission/<panel>`). Each is a build procedure on the App; the toolkit
builds it where the user puts it: a dialog, floating in the window, in a window of its own (a `host.Host` the toolkit
opens on the main window's `Shared`, framed after it), or docked in a dock space. The window's frame is one
(`ui.views_frame` around the whole page); the Services section has one around its table (`services`), Mission Control
one of panels only (`mission`: the top, the left, the centre, the right and the bottom zones, each a row of stacks).
One `ui.Views` holds them all, its memory in `$XDG_STATE_HOME/inspecteur/views.txt` (none in the demo): the
presentation the user chose, the sizes, the docks' layouts, which were open at the last quit (`view_restore` opens the
details and the panels again at the start). The palette lists the moves of each open view (`ui.View_Commands`). A
dialog holds the window's keys (`ui.views_hold_keys`); a floating or docked view with the keyboard leaves the window's
commands alone to the page (`focus_in_view`). The command palette, the sheet of the keys, the confirmations and the
install's dialog are the toolkit's own views, on the same `Views`.

`licence.odin` keeps the licence (gt:licence, the product in `src/licence/product.odin`): a store read and written by
tasks of the chores, shown under the settings' General page.

## Tests

- Unit tests (`src`; those of the Linux readers' formats in `*_linux_test.odin`): the formats of `/proc`, `/proc/net`, unit files, desktop entries, `os-release`, `pci.ids`, EDID and
  `mountinfo`; the rates, a pid used again, the devices that come and go, the rows' filter and sort, the columns kept,
  the priorities' steps, the apps of a scope, launchers and interpreters; names, sizes, durations; no key doing two things; the preferences'
  documentation.
- `inspecteurtool live`: the real program in a sway with no screen, driven over the DevTools protocol (see
  [development.md](development.md)). A key that changes something is pressed only once the selected row, as the
  accessibility tree says, is the test's own.
- `inspecteurtool bench`: the cold start and the cost at rest, on the GPU.
