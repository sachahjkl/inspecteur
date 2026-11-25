package inspecteur

// Every action of the window, in one table (the toolkit's ui.Command): its id, its name, its group and its keys. The keys
// are read here (commands_keys), and the same table gives the menus' and the tooltips' key texts (cmd_tip, cmd_item), the
// command palette (gui_toolkit's: Ctrl+K, Ctrl+Shift+P; every action of the section shown and of the window, the
// settings, the views' moves, and `@` the processes and the services, searched as you type) and the sheet of the keys
// (F1). The person's keys and aliases (app.keymap, set from the palette) take the place of a command's own keys in each.
//
// The id is the enum's name in lower case, written out: the palette's usage memory and the person's keys are stored
// under it, so it never follows a rename of the enum or of the label.
//
// A command of a section acts in that section only; one of the Window or Sections groups, wherever the window is. A
// command of the Properties group acts while the Properties are open (props_view.odin reads its keys).
//
// A button that runs a command states it at its build (ui.act_command, through cmd_button and tool_button): Shift+Enter
// on the command in the palette goes to that button.

//
// The actions of a system (Cmd, COMMANDS, the palette's values, cmd_can, cmd_run) are in commands_other.odin (Linux,
// macOS) and commands_windows.odin.

import "core:slice"
import "core:strings"
import i18n "gt:i18n"
import "gt:platform"
import prefs_page "gt:prefs_page"
import "gt:ui"

// The command's label as shown (COMMANDS keeps the English, the catalogue's keys: the toolkit translates the palette's,
// the sheet's and the tooltips' itself).
cmd_label :: proc(c: Cmd) -> string { return i18n.tr(COMMANDS[c].label) }

// "Kill… (Shift+Delete)": a button's tooltip.
cmd_tip :: proc(c: Cmd) -> string { return ui.command_tip(COMMANDS[c]) }

// A menu's line of the command: its label, its key, greyed when it cannot act; clicked: it is run.
cmd_item :: proc(app: ^App, c: Cmd, label := "") {
	if ui.menu_item(label != "" ? label : cmd_label(c), ui.command_shortcut(COMMANDS[c]), icon = COMMANDS[c].icon, disabled = !cmd_can(app, c), icon_font = app.icons).clicked { cmd_run(app, c) }
}

// The keys the filter keeps while it has the keyboard and some text: they edit it. (The keys that type text, Space and
// Backspace among them, are a focused field's already: ui.command_pressed leaves them to it.)
@(private = "file")
editing_chord :: proc(ch: ui.Chord) -> bool {
	// (Ctrl+C copies, Ctrl+A selects the text, Ctrl+Delete erases a word: the filter's while it has text)
	if ch.mods - {.Shift} != {} { return ch.mods == {.Ctrl} && (ch.key == .C || ch.key == .A || ch.key == .Delete) }
	#partial switch ch.key {
	case .Delete, .Left, .Right, .Home, .End: return true
	}
	return false
}

// The commands' keys of the frame, when no menu or dialog has the keyboard: those of the window and of the section
// shown (`window_only`: the window's alone, a view has the keyboard). `field_keeps`: the filter has the keyboard and
// some text: its editing keys are its own.
commands_keys :: proc(app: ^App, field_keeps: bool, window_only := false) {
	for c in Cmd {
		if cmd_is_props(c) || COMMANDS[c].scope == .Window { continue }
		if t, ok := cmd_tab(c).?; ok && (window_only || t != app.tab) { continue }
		cmd := COMMANDS[c]
		if field_keeps {
			// (the keys are a slice that COMMANDS shares: a copy is edited, never the table)
			cmd.keys = slice.clone(cmd.keys, context.temp_allocator)
			for &ch in cmd.keys { if editing_chord(ch) { ch = {} } }
		}
		if ui.command_pressed(cmd, !cmd_can(app, c)) { cmd_run(app, c) }
	}
}

// The keys of the window's commands (scope .Window: the keys, the settings), in every page and mode: the settings, a
// view with the keyboard, a dialog over the window. The toolkit takes their keys whatever has the focus. The palette's
// command is the toolkit's whole (ui.palette_keys reads its keys, the sheet lists it): COMMANDS has no line for it.
window_keys :: proc(app: ^App) {
	ui.palette_keys(&app.palette)
	for c in Cmd {
		if COMMANDS[c].scope != .Window { continue }
		if ui.command_pressed(COMMANDS[c], !cmd_can(app, c)) { cmd_run(app, c) }
	}
}

// Where the palette's choices are kept: <state>/FromentSoftware/Inspecteur/palette_choices.txt; none (in memory only) in the demo,
// whose pictures must not depend on what the user chose.
palette_choices_file :: proc(app: ^App) -> string {
	if app.demo != nil { return "" }
	return strings.concatenate({platform.user_dir(.State, APP_FOLDER, context.temp_allocator), "/palette_choices.txt"}, context.temp_allocator)
}

// The palette (gui_toolkit's, its docs/palette.md): its sources are the toolkit's commands source (inspecteur's
// commands: those of the window, of the sections and of the section shown) with the views' moves beside it, the
// toolkit's settings source, and inspecteur's Go to (`@`: the processes and the services, goto.odin).
//
// The commands source gets a table made again only when the section shown changes, and a `disabled` read again only
// when what cmd_can reads changes (Palette_Can: a few numbers of the state, compared at each build, never the commands
// one by one); each change is a new version, the one thing the palette compares.
Palette_List :: struct {
	cmds:     [dynamic]Cmd,          // the command of each line of the table
	table:    [dynamic]ui.Command,
	disabled: [dynamic]bool,
	tab:      Tab,                   // the section it was made for
	can:      Palette_Can,           // what `disabled` was read for
	version:  u64,                   // 0: not made
}

// The commands source's table and `disabled` as they are now, given to the palette (which compares the version only).
@(private = "file")
palette_list_keep :: proc(app: ^App) {
	l := &app.palette_list
	made := l.version == 0 || l.tab != app.tab
	if made {
		clear(&l.cmds)
		clear(&l.table)
		for c in Cmd {
			// (the Properties' commands act in their view)
			if cmd_is_props(c) { continue }
			if t, ok := cmd_tab(c).?; ok && t != app.tab { continue }
			append(&l.cmds, c)
			append(&l.table, COMMANDS[c])
		}
		resize(&l.disabled, len(l.cmds))
		l.tab = app.tab
	}
	if can := palette_can(app); made || can != l.can {
		l.can = can
		for c, i in l.cmds { l.disabled[i] = !cmd_can(app, c) }
		l.version += 1
	}
	ui.palette_commands(&app.palette, l.table[:], l.disabled[:], {version = l.version, choices = command_choices, user = app})
}

palette_list_destroy :: proc(l: ^Palette_List) {
	delete(l.cmds)
	delete(l.table)
	delete(l.disabled)
	l^ = {}
}

// Each build, at its top, before the content and the views: the commands source kept, and the choice of inspecteur's
// sources run (the toolkit's run their own: a setting, a view's move, Shift+Enter's go to). The run mode's writes are
// made in ui.palette_chosen too: called before the content, a value written in the palette shows on the page in the
// same frame.
palette_build :: proc(app: ^App) {
	l := &app.palette_list
	palette_list_keep(app)
	c, ok := ui.palette_chosen(&app.palette)
	if !ok { return }
	if i, is := ui.palette_chosen_command(&app.palette, c); is {
		// (by its id too: the table is made again with the section, a choice of the table before is not run)
		if i < len(l.cmds) && l.table[i].id == c.id { cmd_run_with(app, l.cmds[i], c.arguments) }
		return
	}
	go_to_chosen(app, c)
}

// The settings source, added once at the start: it asks for the page's options (the themes, the updater) each time it
// reads or acts.
palette_settings_add :: proc(app: ^App) {
	prefs_page.palette_settings_add(&app.palette, &app.palette_settings, &app.prefs, &app.settings_page,
		proc(user: rawptr) -> prefs_page.Page_Options { return settings_options((^App)(user)) },
		proc(user: rawptr) { (^App)(user).settings_open = true }, app)
}

// The sheet of the keys (F1): every command, its section's first. The list is made once, at the first opening: COMMANDS
// does not change, and the sheet translates the labels itself. Its address stays, so the sheet needs no version.
shortcuts_open :: proc(app: ^App) {
	if len(app.sheet_commands) == 0 {
		for c in Cmd { if cmd_tab(c) == nil && !cmd_is_props(c) { append(&app.sheet_commands, COMMANDS[c]) } }
		for c in Cmd { if _, ok := cmd_tab(c).?; ok { append(&app.sheet_commands, COMMANDS[c]) } }
		for c in Cmd { if cmd_is_props(c) { append(&app.sheet_commands, COMMANDS[c]) } }
	}
	ui.shortcuts_sheet_open(&app.sheet, app.sheet_commands[:])
}

// The theme's version: light after dark, dark after light; from the system's, the other one than the system's.
light_dark_switch :: proc(app: ^App) {
	mode: ui.Theme_Mode
	switch app.settings.look.mode {
	case .Light:  mode = .Dark
	case .Dark:   mode = .Light
	case .System: mode = app.theme_shown.light ? .Dark : .Light
	}
	mode_set(app, mode)
}

// Sets one preference of the look (appearance.theme, appearance.mode) and reads the look again: the next build shows it.
look_set :: proc(app: ^App, name, value: string) {
	pref_set(&app.prefs, name, value)
	prefs_page.appearance_destroy(&app.settings.look)
	app.settings.look = prefs_page.appearance_read(&app.prefs)
}

// The theme a light or dark choice moves to when the theme shown has one version only: the nearest of those that have
// both (graphite, silver).
THEME_OF_BOTH :: "Silver"

// Sets the theme's version (written to the preferences). A theme that has no such version (Graphite is dark only) gives
// way to THEME_OF_BOTH: the choice is seen, and the footer says why the theme changed.
mode_set :: proc(app: ^App, mode: ui.Theme_Mode) {
	look_set(app, prefs_page.MODE_PREF, THEME_MODE_KEYS[mode])
	def, _, ok := ui.theme_find(app.themes_file.all[:], app.settings.look.theme)
	lacks := ok && (def.versions == .Dark_Only && mode == .Light || def.versions == .Light_Only && mode == .Dark)
	if lacks {
		old := strings.clone(app.settings.look.theme, context.temp_allocator)
		look_set(app, prefs_page.THEME_PREF, THEME_OF_BOTH)
		say(app, mode == .Light ? i18n.tr("Light colours: %s has no light version, %s has") : i18n.tr("Dark colours: %s has no dark version, %s has"), old, THEME_OF_BOTH)
		return
	}
	#partial switch mode {
	case .Light: say(app, i18n.tr("Light colours"))
	case .Dark:  say(app, i18n.tr("Dark colours"))
	case:        say(app, i18n.tr("Colours as the system's"))
	}
}

// A tooltip after the pointer rests on `sig`: `text`.
tip_after :: proc(sig: ui.Signal, text: string) {
	if text == "" || !ui.hovered_for(sig) { return }
	if ui.tooltip() { ui.tooltip_text(text) }
}
