# Configuration

Inspecteur reads its preferences from `$XDG_CONFIG_HOME/inspecteur/prefs` (a line `name<TAB>value` each, after the
first line). `inspecteur prefs` lists them with their values. `--pref name=value` sets one for a single run:

```sh
inspecteur --pref view.mode=light --pref processes.refresh_ms=2000
```

| Name | Default | What it does |
|---|---|---|
| `processes.columns` | pid,user,cpu,memory,read,write,threads | The columns of the Processes table besides the name, apart by commas: `pid`, `ppid`, `user`, `state`, `nice`, `cpu`, `memory`, `gpu_memory`, `read`, `write`, `threads`, `started`, `command`, `executable`. A right click on the table's header changes them. |
| `processes.widths` | (empty) | The widths of the columns that were resized, in ems, apart by commas (`pid=6,command=30`). Dragging the line before a column's title changes them. |
| `processes.sort` | name | The column the processes are sorted by (one of `processes.columns`, or `name`). |
| `processes.descending` | false | Sort from the largest (or from Z) down. |
| `processes.refresh_ms` | 1000 | How often the processes are read again, in milliseconds (250 to 10000). |
| `view.theme` | Graphite | The window's colours: a theme of gui_toolkit by its name (Graphite, Midnight, Nord, Gruvbox, Tokyo Night, Catppuccin...). |
| `view.mode` | system | The theme's version: `system` (light or dark, as the system), `dark` or `light`. |
| `view.finish` | flat | How surfaces are drawn: `flat`, `machined`, `gradient` or `glass`. |
| `view.font_size` | 13 | The text size, in logical pixels (8 to 40). |
| `view.width` | 1100 | The window's width at start, in logical pixels. |
| `view.height` | 720 | The window's height at start, in logical pixels. |
