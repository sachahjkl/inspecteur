# Configuration

Inspecteur reads its preferences from `$XDG_CONFIG_HOME/inspecteur/prefs` (a line `name<TAB>value` each, after the
first line). The settings (Ctrl+, or the title bar's button) show them on a page, searched as you type, each change
applied at once; the layouts of the tables are not there (the tables set them). `inspecteur prefs` lists them all with their
values. `--pref name=value` sets one for a single run:

```sh
inspecteur --pref appearance.mode=light --pref processes.refresh_ms=2000
```

## The common settings

The look, the text and its fonts, the scrolling, the input, the delays and menus, the rendering, the updates and where
messages show are the settings every program of gui_toolkit has, with the same names: its
[docs/settings.md](https://github.com/sachahjkl/gui_toolkit/blob/main/docs/settings.md) lists them with their defaults.
Inspecteur gives some of them its own defaults:

| Name | Inspecteur's default | What it does here |
|---|---|---|
| `appearance.theme` | Graphite | The window's colours: a theme of gui_toolkit by its name (Graphite, Midnight, Nord, Gruvbox, Tokyo Night, Catppuccin...), or one of the user's own themes (below). The title bar's colours button lists them too. |
| `appearance.mode` | system | The theme's version: `system`, `dark` or `light`. Ctrl+Shift+L switches light and dark. A theme of one version (Graphite is dark only) gives way to Silver when the other version is chosen. |
| `appearance.finish` | machined | How surfaces are drawn: `machined`, `edged`, `flat`, `gradient` or `glass`. |
| `appearance.glow` | 0 | No halos around the machined finish's buttons and fields: a table of numbers reads best plain. |
| `appearance.font_size` | 13 | The text size at a zoom of 100 %, in logical pixels (10 to 24): every size of the window follows it. |
| `appearance.zoom` | 1 | The zoom of the window. Ctrl+wheel, Ctrl+= and Ctrl+- change it, Ctrl+0 sets it back; Inspecteur keeps it for the next start. |
| `window.system_title` | false | The window's title bar drawn by the system in place of Inspecteur's own; changed at once where the desktop lets it. A desktop that draws none (GNOME) keeps Inspecteur's. |
| `update.auto` | true | Check for a new version a while after the start and then every day, download it and put it in place: it runs at the next start. Only the installed copy updates itself; a copy of the Nix store is Nix's to update. |
| `update.base_url` | the latest GitHub release | Where the updates' manifest and program are downloaded from. Read at the start. |
| `general.messages` | system | Where Inspecteur says what it did (copied, a licence registered): the system's notifications, the window, or nowhere. |

`general.menu` and `general.autostart` are registered but no page shows them: the install (`inspecteur install`, the
Setup's dialog) puts the menu entry in place, and Inspecteur does not start with the session.

The user's own themes are in `$XDG_CONFIG_HOME/inspecteur/themes.txt`: the settings' Appearance page shows its path
under the themes' cards; a click makes it (with its instructions in comments) and opens it. A change to it is shown in
the next two seconds.

## Inspecteur's settings

| Name | Default | What it does |
|---|---|---|
| `processes.columns` | pid,user,cpu,cpu_graph,memory,read,write,threads | The columns of the Processes table besides the name, apart by commas: `pid`, `ppid`, `user`, `state`, `nice`, `cpu`, `cpu_graph` (the CPU of the last 30 seconds, a bar per sample in the colours of the load), `memory` (private memory), `resident`, `gpu` (the share of a GPU's time it keeps busy: NVIDIA's GPUs tell it), `gpu_memory`, `read`, `write`, `threads`, `started`, `command`, `executable`. A right click on the table's header (or Ctrl+Shift+C) changes them. |
| `processes.widths` | (empty) | The widths of the columns that were resized, in ems, apart by commas (`pid=6,command=30`). Dragging the line before a column's title changes them. |
| `processes.order` | (empty) | The order of the Processes table's columns after the name, apart by commas (`cpu,pid,user`). Dragging a column's title sideways changes it. |
| `processes.sort` | name | The column the processes are sorted by (one of `processes.columns`, or `name`; `none`: by PID, as they are read). A click on a title sorts by it, a second the other way, a third gives `none`. |
| `processes.descending` | false | Sort from the largest (or from Z) down. |
| `processes.refresh_ms` | 1000 | How often the processes and the machine are read again, in milliseconds (250 to 10000): a point of the Performance section's graphs each time, so that their span is 60 times this period. The title bar's refresh menu (Ctrl+Shift+R) changes it; Ctrl+Space pauses the refresh and resumes it (a pause is not kept). |
| `processes.view` | apps | How the processes are listed: `apps` (the apps' groups, then the background processes) or `tree` (every process under its parent). Ctrl+T switches them. |
| `processes.pinned` | (empty) | The apps and processes pinned over the others, by name, apart by commas. Alt+P pins or unpins the selected row. |
| `processes.summary` | true | Show the summary of the machine over the Processes table: CPU, memory, disks, network, the first GPU, the processor's temperature and the pressure (the share of the time tasks waited), each with its last minute; a click shows the device in Performance. Ctrl+B shows or hides it. |
| `services.manager` | system | The services the Services section lists: the system's (`system`) or the user's (`user`). Its System and User buttons change it. |
| `services.widths` | (empty) | The widths of the Services table's columns that were resized, in ems (`description=30`). Dragging the line before a column's title changes them. |
| `services.order` | (empty) | The order of the Services table's columns, apart by commas (`name,state,description`). Dragging a column's title sideways changes it. |
| `services.sort` | name | The column the services are sorted by: `name`, `description`, `state`, `startup`, `load`, `pid` or `memory`; a `-` before it for the largest (or Z) first. A click on a title changes it. |
| `services.details` | true | Show the selected service's details (its unit file, since when it is in its state, its tasks, CPU time and restarts) and its journal's last lines under the table. Ctrl+I shows or hides them. |
| `services.journal_boot` | true | The details' journal shows this boot's entries alone; `false`: its last entries, from any boot. Alt+B switches it. |
| `services.journal_level` | all | The entries of the details' journal shown: `all`, `warnings` (and worse) or `errors` (and worse). Alt+L goes through them. |
| `services.journal_follow` | true | Read the details' journal again every 2 seconds while it is shown: new entries come in at the end. Alt+F switches it. |
| `services.details_height` | 16 | The height of the details' pane, in ems (6 to 80). Dragging the line above it changes it. |
| `startup.widths` | (empty) | The widths of the Startup table's columns that were resized, in ems (`command=24`). |
| `startup.order` | (empty) | The order of the Startup table's columns, apart by commas (`name,status,command`). |
| `startup.sort` | name | The column the startup items are sorted by: `name`, `command`, `type`, `status` or `file`; a `-` before it for Z first. |
| `connections.widths` | (empty) | The widths of the Connections table's columns that were resized, in ems (`remote_address=20`). |
| `connections.order` | (empty) | The order of the Connections table's columns, apart by commas (`process,state,remote_address`). |
| `connections.sort` | process | The column the sockets are sorted by: `process`, `pid`, `protocol`, `local_address`, `remote_address` or `state`; a `-` before it for the largest (or Z) first. |
| `connections.refresh_ms` | 3000 | How often the sockets are read again while Connections or Mission Control is shown, in milliseconds (1000 to 60000). A reading goes through every process's open files: a longer period costs less. |
| `services.refresh_ms` | 3000 | How often the services are read again while their section is shown, in milliseconds (1000 to 60000). |
| `mission.layout` | (empty) | Mission Control's panels: where each one is docked, its stacks and their sizes, those closed left out. Its panels' menu brings one back; *Mission Control: the layout as at first* sets it back. |
| `mission.windows` | (empty) | Mission Control's panels in windows of their own, apart by commas (`health,network`): they open again at the start. A panel's menu opens one; closed, it goes back to Mission Control. |
| `view.zebra` | true | Shade every second row of the tables (Processes, Services, Startup, Connections, the Properties' lists): a line of numbers reads across. |
| `view.rules` | true | Draw a thin line under each row of the tables. |
| `view.placement` | (empty) | Where the window was left and its size, in physical pixels, and whether it was maximized (`120 80 1400 900 maximized`; empty: the first start's size). Written when it closes; Wayland lets a program set the size alone. |
| `view.palette_size` | (empty) | The command palette's size, in logical pixels: its width and its height. Dragging its edges or its corner changes it. |
| `view.section` | processes | The section shown at the start: the one shown last (`mission control`, `processes`, `performance`, `services`, `startup`, `connections`, `information`). `--section` shows another. |
| `performance.cpu_view` | overall | The CPU's page in Performance: one graph for all the processors (`overall`), or one per logical processor (`logical`). Ctrl+G switches them. |
| `setup.choice` | (empty) | What was answered to the install's dialog: `installed`, `standalone` (this copy runs on its own: not offered again), or dismissed for a version. |

## The licence

Inspecteur is free. A licence says that its holder supports its work; it changes nothing of what Inspecteur does. The
settings' General page shows it: who it is registered to, or a link to buy one, a field to paste the key, **Choose a
file…** and **Remove the licence**. The key is checked on the computer, with no network, and kept in
`$XDG_CONFIG_HOME/inspecteur/licence.inspecteurlicence`. The shop is not open yet.
