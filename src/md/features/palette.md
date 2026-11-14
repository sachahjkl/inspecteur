# The command palette

inspecteur's palette is gui_toolkit's, the one every program has (its intent: gui_toolkit's
`src/md/features/palette.md`; its API: `docs/palette.md`). inspecteur gives it sources and acts on the choices of its
own. The code is `src/commands.odin` (the commands) and `src/go_to.odin` (Go to).

## The sources

| Prefix | Source | Whose | What choosing does |
|---|---|---|---|
| `>` | the commands of the window, of the sections and of the section shown | the toolkit's commands source, inspecteur's table | `cmd_run` |
| `>` | the views' moves (float, dock, a window of its own, re-attach, close) | the toolkit's | the toolkit runs it |
| `:` | the settings | the toolkit's settings source (`prefs_page.palette_settings_add`) | a switch flips, another setting opens the settings on it |
| `@` | the processes of the last sample | inspecteur's | selects its row in Processes (the filter cleared, its group open) |
| `@` | the services of the last reading | inspecteur's | selects its row in Services, its manager's |

All of them are in the plain search too. With nothing typed: Recent, then the commands.

## Decisions

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
  the keys. A choice is run by its index (`palette_chosen_command`) and checked by its id (the command's enum name): a
  choice of a table made for another section is not run.
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
