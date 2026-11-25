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

Every reading of the system is in a `*_linux.odin` or `*_windows.odin` file (with `*_other.odin` stubs for macOS).
Sections whose meaning is the same across operating systems share their model and view; sections whose model differs by
system (Services, Startup, Properties, Information, process columns, commands, and acts) have whole per-system files
selected by Odin build suffixes, with no `when ODIN_OS` in `src/`. Pure Windows binary layouts and bounds-checked
decoders live in `src/winapi` so they compile and run unit tests on any host OS. Why:
[src/md/infrastructure/porting.md](../src/md/infrastructure/porting.md).

| Section | Shared | Linux | Windows | Its reasons |
|---|---|---|---|---|
| Processes | `sampler.odin`, `processes.odin`, `apps.odin`, `table_view.odin`, `menu.odin` | `processes_linux.odin`, `apps_linux.odin`, `columns_other.odin`, `acts.odin`, `menu_other.odin` | `processes_windows.odin`, `apps_windows.odin`, `columns_windows.odin`, `acts_windows.odin`, `menu_windows.odin` | [processes.md](../src/md/features/processes.md), [apps.md](../src/md/features/apps.md) |
| Properties | — | `props.odin`, `props_linux.odin`, `props_view.odin` | `props_windows.odin`, `props_view_windows.odin` | [processes.md](../src/md/features/processes.md) |
| Performance | `machine.odin`, `gpu.odin`, `perf_view.odin` | `machine_linux.odin`, `gpu_linux.odin` | `machine_windows.odin`, `gpu_windows.odin` | [gpus.md](../src/md/features/gpus.md) |
| Services | — | `services.odin`, `services_linux.odin`, `services_view.odin`, `journal*.odin` | `services_windows.odin`, `services_view_windows.odin` | [services.md](../src/md/features/services.md) |
| Startup | — | `startup.odin`, `startup_linux.odin`, `startup_view.odin` | `startup_windows.odin`, `startup_view_windows.odin` | [services.md](../src/md/features/services.md) |
| Connections | `connections.odin`, `connections_view.odin` | `connections_linux.odin` | `connections_windows.odin` | [connections.md](../src/md/features/connections.md) |
| Information | — | `information.odin`, `information_linux.odin`, `information_view.odin` | `information_windows.odin`, `information_view_windows.odin` | |
| Session & windows | `window_list.odin` | `session_linux.odin`, `window_list_other.odin` | `session_windows.odin`, `window_list_windows.odin` | |
| Process dump | `dump.odin` | `dump_linux.odin` | `dump_windows.odin` | [processes.md](../src/md/features/processes.md) |
| Commands & settings | `commands.odin`, `settings.odin`, `goto.odin` | `commands_other.odin`, `settings_other.odin`, `goto_other.odin`, `system_linux.odin` | `commands_windows.odin`, `settings_windows.odin`, `goto_windows.odin`, `system_windows.odin` | |

The demo (`demo.odin`, plus `demo_other.odin` and `demo_windows.odin`, `inspecteur --demo`) provides deterministic sample
data for documentation screenshots and UI tests.

## Information

What does not change while the program runs is read on a worker thread: on Linux from `/etc/os-release`, `uname`,
`/sys/class/dmi/id`, `/proc/cpuinfo`, PCI display controllers (`pci.ids`), file systems, DRM EDID, and batteries; on
Windows from the CurrentVersion registry, SMBIOS (`GetSystemFirmwareTable`), `GetLogicalProcessorInformationEx`, DXGI,
NTFS/ReFS volumes, `EnumDisplayDevicesW`/EDID, and `IOCTL_BATTERY_QUERY_*`. Live figures (uptime, memory, network
interfaces) come from the last sample of Performance.

## The window (view.odin, table_view.odin, commands.odin)

The interface is built again at each frame (immediate mode). The table is the toolkit's virtual list: it builds the rows
in view only. The selection is kept by the row's identity (pid and start time; an app's entry) across samples, sorts
and filters. Every colour comes from the theme: its page, bars and wells for the surfaces, its border for the lines, its
warning hue for the tint of busy cells. Corners are nearly square (`ui.set_rounding`).

Every action is a command of one table (`COMMANDS`, the toolkit's `ui.Command`): its label, its group, its keys. The
keys are read from it, the menus' lines and the buttons' tooltips say its key, the command palette (Ctrl+K, the
toolkit's) lists the commands of the window and of the section shown beside the settings, the views' moves and Go to
(`@`: the processes and the services, `goto.odin`; [src/md/features/palette.md](../src/md/features/palette.md)), and
the sheet of the keys (F1) lists them all. A test checks that no key does two things in one place.

## Install, updates, settings (setup.odin, updates.odin, settings_view.odin, src/identity, src/update)

`src/identity` holds what Inspecteur is to the desktop: its names, the actions of its desktop entry (one per section:
`--section <name>`, and `StartupWMClass`, the window's class), its icons (`assets/logo_<n>.png`). `setup.odin` gives it to
the toolkit's `gt:setup` through `prefs_page.Install`: the install's dialog, offered at the start of a copy that is not
installed (once per version, `install.choice`), the settings' Installation page, and `--install`, `--uninstall`,
`--setup`. The updates start with the window; they act by themselves only once that reading says this copy is the
installed one. On NixOS a classic install builds a profile of
`NIXOS_LIBRARIES` and points the copy at it; a copy from the Nix store is never offered an install. `inspecteurtool
desktop_files` writes the same entry and icons for the Nix package.

`updates.odin` runs the toolkit's updates (`prefs_page.updates_start`, over `gt:update`): the installed copy checks the latest release's manifest, signed with the
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
One `ui.Views` holds them all, its memory in `$XDG_STATE_HOME/FromentSoftware/Inspecteur/views.txt` (none in the demo): the
presentation the user chose, the sizes, the docks' layouts, which were open at the last quit (`view_restore` opens the
details and the panels again at the start). The palette lists the moves of each open view (the toolkit's moves source). A
dialog holds the window's keys (`ui.views_hold_keys`); a floating or docked view with the keyboard leaves the window's
commands alone to the page (`focus_in_view`). The command palette, the sheet of the keys, the confirmations and the
install's dialog are the toolkit's own views, on the same `Views`.

`licence.odin` keeps the licence (gt:licence, the product in `src/licence/product.odin`): a store read and written by
tasks of the chores, shown under the settings' General page.

## Tests

- Unit tests (`src` and `src/winapi`; Linux format tests in `*_linux_test.odin`; Windows live process/reader tests in
  `*_windows_test.odin`; pure Windows binary ABI layouts and hostile/truncated buffer decoders in `src/winapi/winapi_test.odin`
  verified across `amd64` and `arm64`): `/proc`, `/proc/net`, unit files, desktop entries, `os-release`, `pci.ids`, EDID,
  `mountinfo`, `SystemProcessInformation`, `SystemProcessorPerformanceInformation`, `SystemExtendedHandleInformation`,
  PEB64/PEB32 (WOW64), TCP/UDP v4/v6 extended tables, `StartupApproved`, SMBIOS, `MIB_IF_TABLE2`, `.lnk`, Task XML; rates,
  PID reuse rejection, devices, filter and sort, columns, priorities, no conflicting shortcuts, preference documentation,
  and zero `ODIN_OS` in `src/`.
- `inspecteurtool live`: the real program in a sway with no screen, driven over the DevTools protocol (see
  [development.md](development.md)). A key that changes something is pressed only once the selected row, as the
  accessibility tree says, is the test's own.
- `inspecteurtool bench`: the cold start and the cost at rest (with `--software` for pixman software rendering).
- `inspecteurtool bench_reader`: opt-in benchmark of the Linux readers on real `/proc` and on a 5,000-process synthetic `/proc` tree, plus the neutral pipeline and churn memory.
