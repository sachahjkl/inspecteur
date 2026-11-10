# Configuration

Inspecteur reads its preferences from `$XDG_CONFIG_HOME/inspecteur/prefs` (a line `name<TAB>value` each, after the
first line). `inspecteur prefs` lists them with their values. `--pref name=value` sets one for a single run:

```sh
inspecteur --pref view.mode=light --pref processes.refresh_ms=2000
```

| Name | Default | What it does |
|---|---|---|
| `processes.columns` | pid,user,cpu,memory,read,write,threads | The columns of the Processes table besides the name, apart by commas: `pid`, `ppid`, `user`, `state`, `nice`, `cpu`, `memory` (private memory), `resident`, `gpu_memory`, `read`, `write`, `threads`, `started`, `command`, `executable`. A right click on the table's header (or Ctrl+Shift+C) changes them. |
| `processes.widths` | (empty) | The widths of the columns that were resized, in ems, apart by commas (`pid=6,command=30`). Dragging the line before a column's title changes them. |
| `processes.sort` | name | The column the processes are sorted by (one of `processes.columns`, or `name`). |
| `processes.descending` | false | Sort from the largest (or from Z) down. |
| `processes.refresh_ms` | 1000 | How often the processes and the machine are read again, in milliseconds (250 to 10000): a point of the Performance section's graphs each time, so that their span is 60 times this period. The title bar's refresh menu (Ctrl+Shift+R) changes it; Ctrl+Space pauses the refresh and resumes it (a pause is not kept). |
| `processes.view` | apps | How the processes are listed: `apps` (the apps' groups, then the background processes) or `tree` (every process under its parent). Ctrl+T switches them. |
| `services.manager` | system | The services the Services section lists: the system's (`system`) or the user's (`user`). Its System and User buttons change it. |
| `services.widths` | (empty) | The widths of the Services table's columns that were resized, in ems (`description=30`). Dragging the line before a column's title changes them. |
| `services.sort` | name | The column the services are sorted by: `name`, `description`, `state`, `startup`, `load`, `pid` or `memory`; a `-` before it for the largest (or Z) first. A click on a title changes it. |
| `services.details` | true | Show the selected service's details (its unit file, since when it is in its state, its tasks, CPU time and restarts) and its journal's last lines under the table. Ctrl+I shows or hides them. |
| `startup.widths` | (empty) | The widths of the Startup table's columns that were resized, in ems (`command=24`). |
| `startup.sort` | name | The column the startup items are sorted by: `name`, `command`, `type`, `status` or `file`; a `-` before it for Z first. |
| `connections.widths` | (empty) | The widths of the Connections table's columns that were resized, in ems (`remote_address=20`). |
| `connections.sort` | process | The column the sockets are sorted by: `process`, `pid`, `protocol`, `local_address`, `remote_address` or `state`; a `-` before it for the largest (or Z) first. |
| `services.refresh_ms` | 3000 | How often the services are read again while their section is shown, in milliseconds (1000 to 60000). |
| `view.theme` | Graphite | The window's colours: a theme of gui_toolkit by its name (Graphite, Midnight, Nord, Gruvbox, Tokyo Night, Catppuccin...). |
| `view.mode` | system | The theme's version: `system` (light or dark, as the system), `dark` or `light`. Ctrl+Shift+L switches light and dark. A theme of one version (Graphite is dark only) gives way to Silver when the other version is chosen. |
| `view.finish` | flat | How surfaces are drawn: `flat` (plain surfaces, thin lines), `machined` (bevelled buttons, sunken fields), `gradient` (surfaces shaded top to bottom) or `glass` (surfaces that let the page show through). |
| `view.font_size` | 13 | The text size, in logical pixels (8 to 40). Ctrl+= and Ctrl+- change it, Ctrl+0 sets it back to 13. |
| `view.width` | 1100 | The window's width at start, in logical pixels. |
| `view.height` | 720 | The window's height at start, in logical pixels. |
| `setup.welcome` | true | Show the welcome page at the next start: it puts Inspecteur in the application menu and says how a desktop opens it as its task manager. Closing the page sets it to `false`; Ctrl+Shift+I shows the page again. |
