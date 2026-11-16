# The command palette

inspecteur's palette is gui_toolkit's, the one every program has (its intent: gui_toolkit's
`src/md/features/palette.md`; its API: `docs/palette.md`). inspecteur gives it sources and acts on the choices of its
own. The code is `src/commands.odin` (the commands) and `src/go_to.odin` (Go to).

## The sources

| Prefix | Source | Whose | What choosing does |
|---|---|---|---|
| `>` | the commands of the window, of the sections and of the section shown | the toolkit's commands source, inspecteur's table | `cmd_run_with`: a command with arguments opens its form first |
| `>` | the views' moves (float, dock, a window of its own, re-attach, close) | the toolkit's | the toolkit runs it |
| `:` | the settings | the toolkit's settings source (`prefs_page.palette_settings_add`) | a switch flips, another setting opens the settings on it |
| `@` | the processes of the last sample | inspecteur's | selects its row in Processes (the filter cleared, its group open) |
| `@` | the services of the last reading | inspecteur's | selects its row in Services, its manager's |

All of them are in the plain search too. With nothing typed: Recent, then the commands.

## Commands with arguments

A command that asks one value before it acts takes it in the palette's form (`ui.Command.arguments`): Enter opens the
form, Enter on its value runs it.

| Command | Its argument | Its list | What it does |
|---|---|---|---|
| Send a signal | `signal` | `SIGNAL_ITEMS` (menu.odin) | `signal_selected`: the rows selected, with the guards of the row's menu |
| Set the priority | `priority` | `PRIORITIES` (system_linux.odin) | `set_priority` on the process selected (not an app's row) |
| Refresh speed | `period` | `REFRESH_SPEEDS` (view.odin) | `refresh_speed_set`: the period, written; the refresh resumes |

- **Each list is the program's table, given by `Palette_Commands_Options.choices`** (`command_choices`), not copied
  into `config.Def.choices`: the menus and the form read one table, and PRIORITIES is the system's file's. An
  argument's name is unique among the commands, so `command_choices` goes by the name, not by the table's index (the
  table is made again with the section).
- **A choice is checked against the selection when it runs** (`cmd_run_with` calls `cmd_can` first), as a key is: the
  form may stay open while a sample moves the rows. A value that is not in its list does nothing.
- **Without a value the command runs as before.** A key that the person gives Send a signal or Set the priority has no
  form: Send a signal opens the row's menu (its Send a signal list), Set the priority the Properties (their foot holds
  the priority), Refresh speed (Ctrl+Shift+R) its menu.
- **Refused: a form's value from the setting.** Refresh speed could take the `processes.refresh_ms` setting's Def (any
  period from 250 ms to 10 s). The setting is in the palette already (`:`); the command offers the four periods of its
  menu, and resumes a paused refresh, as the menu does.
- **The dialogs kept.** Set affinity asks several processors at once: a set, not one value, so its dialog stays. Kill,
  End process tree, Create dump file, Stop and Restart a service ask a question (what ends with it), not a value: their
  confirmations stay. Columns and Mission Control's panels are several switches: their menus stay.

## Go to a command's button

Shift+Enter on a command goes to the element that runs it: each one states `command:<id>` at its build
(`ui.act_command`). The rule: an element names a command only when its click runs that very command on what the command
acts on.

- `cmd_button` names every section's tool; `tool_button` names a command given to it (Mission Control's two, Read again
  in Information, the journal's). The title bar's Keyboard shortcuts, Settings and refresh button (Refresh speed's
  menu), the sidebar's sections (Show …) and the Properties' foot (`props_button`) name theirs.
- Not named: a journal in its own window (the journal commands act on the details' journal), the details' close button
  (the bar's Details and journal names that command), a row's window button (it acts on its row, not on the selection),
  the journal's level and boot choices (they set a value; the commands step through them), the theme button (it opens a
  menu, not Light or dark).
- The Properties' commands are not in the palette's table (they act in their view); their buttons name them all the
  same, so a table that lists them later reaches them.

## Decisions

- **The choice is read at the top of the main window's build** (`palette_build`, before `ui.views_frame` and the
  content): the run mode's writes are made in `ui.palette_chosen`, so a value changed in the palette shows on the page
  in the same frame. The main window alone has a palette: a view's window opens the same palette, and its choices come
  out in the main window's build.

- **The commands' `disabled` follows a version, not a compare.** What can act depends on the selection and on the
  readings. The palette compares the commands source's version only. inspecteur makes a `Palette_Can` at each build:
  a few numbers that `cmd_can` reads (the section, the sample, the rows made again, each table's selection version and
  active row, the readings' pointers, the Properties, the zoom, the filter). A selection's version
  (`ui.Item_Selection.version`) moves with every change of it, one row for another at the same count and the active
  row too; the active row is in the key beside it because inspecteur sets it itself (`select_row`, `rows_again`). When
  one differs, `disabled` is read again and the version moves. Refused: comparing `disabled` command by command at each
  build (work in proportion to the table at each frame), the count of the selected rows (one row for another keeps it),
  and a counter bumped at every place that changes a selection (the toolkit's tables change theirs themselves: a place
  would be forgotten).
- **The table is made again with the section only.** A section's commands are in it while the section shows, as in
  the keys. A choice is run by its index (`palette_chosen_command`) and checked by its `Command.id`: a choice of a
  table made for another section is not run.
- **A command's id is its enum's name in lower case, written in `COMMANDS`.** The usage memory (`command:<id>`) and
  the person's keys and aliases (`keys.custom`, `keys.aliases`) are stored under it. Before, the palette took the enum's
  name by reflection (`Palette_Commands_Options.names`); the toolkit removed that option, and the explicit string makes
  a rename of the enum visible in the diff instead of a silent loss of stored data. The case changed once
  (`Show_Processes` became `show_processes`), as the id rule asks: the memory of choices made before starts again.
  `the_command_ids` (commands_test.odin) checks every id with `ui.command_ids_check`.
- **The person's keys: one `ui.Keymap` for the process** (`app.keymap`), read by the main window
  (`ui.keymap_use`), known from `COMMANDS` before the first frame, kept in the settings by `prefs_page.standard_watch`.
  Ctrl+Enter on a command in the palette sets a key, Alt+Enter an alias (gui_toolkit's `src/md/features/keymap.md`).
  The settings' Keys page shows the two texts and their reset.
- **The palette's own command is the toolkit's whole.** `COMMANDS` has no line for it: `ui.palette_keys` reads its
  keys, the sheet lists it, the title bar's button calls `ui.palette_toggle` with the tooltip of `ui.palette_command()`.
  A test checks that no command of inspecteur takes its keys.
- **Go to's ids are identities, not titles.** A process is `<pid>:<start>`: a pid used again is another process. A
  service is `<manager>/<name>`, the same name as a journal's view instance: a system service and a user service of one
  name are two items. The processes are not remembered (a pid means nothing at the next start); the services are.
- **Go to reads once per change, its items made on a chore.** The processes' source reads again when a sample brought
  a process or took one away (`Sampler.changes`), not at each sample; the services' at each reading
  (`Services.readings`). The interface's thread copies what a line needs (names, users, units, descriptions) into the
  answer's arena; a chore makes the items (their ids, details, tags) there, and the palette takes the arena whole.
  The copy stays on the interface's thread: the sampler and the readings are that thread's and change under a chore.
- **The settings source is added once and asks for the page's options.** They hold the themes and the updater, which
  change: the source calls `settings_options` each time it reads or acts, not inspecteur at each build.

## Subtle points

- The usage memory is the palette's (`palette_choices.txt` in the state folder; none in the demo): a choice's key is
  `<source>:<id>`, so a command chosen in English is first under Recent in French.
- An ended process (kept a moment, fading, in the table) is not offered.
- A Go to answer whose window went before it came (the end of the program) is freed (`ui.palette_answer_free`) and
  ends its question with no answer, on whichever thread finds it out: a question ends safely from any thread.
