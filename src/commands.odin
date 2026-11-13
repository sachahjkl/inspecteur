package inspecteur

// Every action of the window, in one table (the toolkit's ui.Command): its name, its group and its keys. The keys are
// read here (commands_keys), and the same table gives the menus' and the tooltips' key texts (cmd_tip, cmd_item), the
// command palette (Ctrl+K, Ctrl+Shift+P: every action of the section shown and of the window, searched as you type) and
// the sheet of the keys (F1).
//
// A command of a section acts in that section only; one of the Window or Sections groups, wherever the window is. A
// command of the Properties group acts while the Properties dialog is open (props_view.odin reads its keys).

import "core:fmt"
import "core:mem/virtual"
import "core:reflect"
import "core:slice"
import "core:strings"
import i18n "gt:i18n"
import lucide "gt:lucide"
import "gt:platform"
import prefs_page "gt:prefs_page"
import "gt:ui"
import update "gt:update"

Cmd :: enum u8 {
	// Window
	Palette, Shortcuts, Filter, Clear_Filter, Read_Again, Pause_Refresh, Refresh_Speed, Zoom_In, Zoom_Out, Zoom_Reset,
	Light_Dark, Setup, Settings, Check_Updates, Diagnose,
	// Sections
	Show_Mission_Control, Show_Processes, Show_Performance, Show_Services, Show_Startup, Show_Connections, Show_Information, Next_Section, Previous_Section,
	// Processes
	End_Task, Kill, End_Tree, Select_All, Suspend, Properties, Open_Location, Copy_Command, Default_Action, Open_Group,
	Close_Group, Raise_Priority, Lower_Priority, Affinity, Send_Signal, Show_Window, Go_To_Service, Dump, Search_Online, Tree_View, Columns, Summary, Pin,
	// Performance
	Cpu_Grid, Next_Device, Previous_Device,
	// Mission Control
	Mission_Panels, Mission_Reset,
	// Services
	Service_Start, Service_Stop, Service_Restart, Service_Enable, Service_Disable, Service_Open, Service_Copy, Service_Details,
	Service_Open_File, Service_Manager, Journal_Search, Journal_Level, Journal_Boot, Journal_Follow, Journal_Copy, Journal_Copy_Entry, Journal_Window,
	// Startup
	Startup_Enable, Startup_Disable, Startup_Toggle, Startup_Open, Startup_Copy,
	// Connections
	Socket_End_Task, Socket_Kill, Socket_Open, Socket_Copy,
	// Information
	Info_Copy,
	// Properties (the dialog)
	Props_Suspend, Props_End_Task, Props_Kill, Props_Raise_Priority, Props_Lower_Priority, Props_Affinity, Props_Filter,
	Props_Next_Tab, Props_Previous_Tab, Props_Close,
}

COMMANDS := [Cmd]ui.Command{
	.Palette          = {icon = lucide.COMMAND, label = i18n.later("Command palette"), group = i18n.later("Window"), keys = {{.K, {.Ctrl}}, {.P, {.Ctrl, .Shift}}}},
	.Shortcuts        = {icon = lucide.KEYBOARD, label = i18n.later("Keyboard shortcuts"), group = i18n.later("Window"), keys = {{.F1, {}}}, tags = {"keys", "help", "keyboard"}},
	.Filter           = {icon = lucide.FILTER, label = i18n.later("Filter"), group = i18n.later("Window"), keys = {{.F, {.Ctrl}}}},
	.Clear_Filter     = {icon = lucide.X, label = i18n.later("Clear the filter"), group = i18n.later("Window"), keys = {{.Escape, {}}}},
	.Read_Again       = {icon = lucide.REFRESH_CW, label = i18n.later("Read again"), group = i18n.later("Window"), keys = {{.F5, {}}}, tags = {"refresh", "reload"}},
	.Pause_Refresh    = {icon = lucide.PAUSE, label = i18n.later("Pause or resume the refresh"), group = i18n.later("Window"), keys = {{.Space, {.Ctrl}}}, tags = {"freeze", "stop updating"}},
	.Refresh_Speed    = {icon = lucide.GAUGE, label = i18n.later("Refresh speed…"), group = i18n.later("Window"), keys = {{.R, {.Ctrl, .Shift}}}, tags = {"interval", "update", "period"}},
	.Zoom_In          = {icon = lucide.ZOOM_IN, label = i18n.later("Zoom in"), group = i18n.later("Window"), keys = {{.Equal, {.Ctrl}}, {.Num_Add, {.Ctrl}}}},
	.Zoom_Out         = {icon = lucide.ZOOM_OUT, label = i18n.later("Zoom out"), group = i18n.later("Window"), keys = {{.Minus, {.Ctrl}}, {.Num_Subtract, {.Ctrl}}}},
	.Zoom_Reset       = {icon = lucide.SEARCH, label = i18n.later("Zoom: 100 %"), group = i18n.later("Window"), keys = {{.N0, {.Ctrl}}}},
	.Light_Dark       = {icon = lucide.SUN_MOON, label = i18n.later("Light or dark"), group = i18n.later("Window"), keys = {{.L, {.Ctrl, .Shift}}}, tags = {"theme", "dark", "night", "colours"}},
	.Setup            = {icon = lucide.DOWNLOAD, label = i18n.later("Install…"), group = i18n.later("Window"), keys = {{.I, {.Ctrl, .Shift}}}},
	.Settings         = {icon = lucide.SLIDERS_HORIZONTAL, label = i18n.later("Settings"), group = i18n.later("Window"), keys = {{.Comma, {.Ctrl}}}, tags = {"preferences", "options", "configure"}},
	.Check_Updates    = {icon = lucide.HARD_DRIVE_DOWNLOAD, label = i18n.later("Check for updates"), group = i18n.later("Window")},
	.Diagnose         = {icon = lucide.LIGHTBULB, label = i18n.later("Why is it slow?"), group = i18n.later("Window"), keys = {{.F2, {}}}, tags = {"slow", "lag", "performance", "why"}},

	.Show_Mission_Control = {icon = lucide.LAYOUT_GRID, label = i18n.later("Mission Control"), group = i18n.later("Sections"), keys = {{.N1, {.Ctrl}}}},
	.Show_Processes   = {icon = lucide.LAYOUT_LIST, label = i18n.later("Processes"), group = i18n.later("Sections"), keys = {{.N2, {.Ctrl}}}},
	.Show_Performance = {icon = lucide.GAUGE, label = i18n.later("Performance"), group = i18n.later("Sections"), keys = {{.N3, {.Ctrl}}}},
	.Show_Services    = {icon = lucide.SETTINGS, label = i18n.later("Services"), group = i18n.later("Sections"), keys = {{.N4, {.Ctrl}}}},
	.Show_Startup     = {icon = lucide.POWER, label = i18n.later("Startup"), group = i18n.later("Sections"), keys = {{.N5, {.Ctrl}}}},
	.Show_Connections = {icon = lucide.GLOBE, label = i18n.later("Connections"), group = i18n.later("Sections"), keys = {{.N6, {.Ctrl}}}},
	.Show_Information = {icon = lucide.INFO, label = i18n.later("Information"), group = i18n.later("Sections"), keys = {{.N7, {.Ctrl}}}},
	.Next_Section     = {icon = lucide.ARROW_RIGHT, label = i18n.later("Next section"), group = i18n.later("Sections"), keys = {{.Tab, {.Ctrl}}}},
	.Previous_Section = {icon = lucide.ARROW_LEFT, label = i18n.later("Previous section"), group = i18n.later("Sections"), keys = {{.Tab, {.Ctrl, .Shift}}}},

	.End_Task         = {icon = lucide.X, label = i18n.later("End task"), group = i18n.later("Processes"), keys = {{.Delete, {}}}, tags = {"kill", "stop", "close", "quit", "terminate"}},
	.Kill             = {icon = lucide.ZAP, label = i18n.later("Kill…"), group = i18n.later("Processes"), keys = {{.Delete, {.Shift}}}, tags = {"force", "sigkill", "terminate"}},
	.End_Tree         = {icon = lucide.LIST_TREE, label = i18n.later("End process tree…"), group = i18n.later("Processes"), keys = {{.Delete, {.Ctrl}}}, tags = {"kill", "children"}},
	.Select_All       = {icon = lucide.LIST_CHECKS, label = i18n.later("Select all"), group = i18n.later("Processes"), keys = {{.A, {.Ctrl}}}},
	.Suspend          = {icon = lucide.PAUSE, label = i18n.later("Suspend or resume"), group = i18n.later("Processes"), keys = {{.P, {.Ctrl}}}, tags = {"pause", "freeze", "stop", "continue", "sigstop"}},
	.Properties       = {icon = lucide.INFO, label = i18n.later("Properties"), group = i18n.later("Processes"), keys = {{.Return, {.Alt}}}, tags = {"details", "info", "threads", "files", "environment"}},
	.Open_Location    = {icon = lucide.FOLDER_OPEN, label = i18n.later("Open file location"), group = i18n.later("Processes"), keys = {{.O, {.Ctrl}}}, tags = {"folder", "executable", "reveal"}},
	.Copy_Command     = {icon = lucide.COPY, label = i18n.later("Copy command line"), group = i18n.later("Processes"), keys = {{.C, {.Ctrl}}}},
	.Default_Action   = {icon = lucide.PLAY, label = i18n.later("Open the group, or Properties"), group = i18n.later("Processes"), keys = {{.Return, {}}}},
	.Open_Group       = {icon = lucide.CHEVRON_DOWN, label = i18n.later("Open the group"), group = i18n.later("Processes"), keys = {{.Right, {}}}},
	.Close_Group      = {icon = lucide.CHEVRON_UP, label = i18n.later("Close the group"), group = i18n.later("Processes"), keys = {{.Left, {}}}},
	.Raise_Priority   = {icon = lucide.ARROW_UP, label = i18n.later("Raise the priority"), group = i18n.later("Processes"), keys = {{.Up, {.Ctrl}}}, tags = {"nice", "renice"}},
	.Lower_Priority   = {icon = lucide.ARROW_DOWN, label = i18n.later("Lower the priority"), group = i18n.later("Processes"), keys = {{.Down, {.Ctrl}}}, tags = {"nice", "renice", "background"}},
	.Affinity         = {icon = lucide.MICROCHIP, label = i18n.later("Set affinity…"), group = i18n.later("Processes"), keys = {{.A, {.Ctrl, .Shift}}}, tags = {"cpu", "cores", "pin"}},
	.Send_Signal      = {icon = lucide.ZAP, label = i18n.later("Send a signal"), group = i18n.later("Processes"), tags = {"signal", "sighup", "sigusr1", "sigint", "reload", "hang up"}},
	.Show_Window      = {icon = lucide.APP_WINDOW, label = i18n.later("Show its window"), group = i18n.later("Processes"), keys = {{.W, {.Ctrl, .Shift}}}, tags = {"window", "focus", "switch", "raise", "front"}},
	.Go_To_Service    = {icon = lucide.SERVER, label = i18n.later("Go to service"), group = i18n.later("Processes"), keys = {{.S, {.Ctrl, .Shift}}}},
	.Dump             = {icon = lucide.SAVE, label = i18n.later("Create dump file…"), group = i18n.later("Processes"), keys = {{.D, {.Ctrl, .Shift}}}, tags = {"core", "gcore", "debug"}},
	.Search_Online    = {icon = lucide.SEARCH, label = i18n.later("Search online"), group = i18n.later("Processes"), keys = {{.F, {.Ctrl, .Shift}}}, tags = {"web", "google", "what is"}},
	.Tree_View        = {icon = lucide.FOLDER_TREE, label = i18n.later("Process tree or apps"), group = i18n.later("Processes"), keys = {{.T, {.Ctrl}}}, tags = {"parent", "hierarchy"}},
	.Columns          = {icon = lucide.COLUMNS_2, label = i18n.later("Columns…"), group = i18n.later("Processes"), keys = {{.C, {.Ctrl, .Shift}}}, tags = {"show", "hide", "fields"}},
	.Summary          = {icon = lucide.LAYOUT_GRID, label = i18n.later("Show or hide the summary of the machine"), group = i18n.later("Processes"), keys = {{.B, {.Ctrl}}}},
	.Pin              = {icon = lucide.PIN, label = i18n.later("Pin or unpin"), group = i18n.later("Processes"), keys = {{.P, {.Alt}}}, tags = {"favourite", "top", "keep"}},

	.Mission_Panels   = {icon = lucide.LAYOUT_GRID, label = i18n.later("Mission Control: panels…"), group = i18n.later("Mission Control")},
	.Mission_Reset    = {icon = lucide.ROTATE_CCW, label = i18n.later("Mission Control: the layout as at first"), group = i18n.later("Mission Control")},
	.Cpu_Grid         = {icon = lucide.LAYOUT_GRID, label = i18n.later("One graph per logical processor"), group = i18n.later("Performance"), keys = {{.G, {.Ctrl}}}},
	.Next_Device      = {icon = lucide.ARROW_DOWN, label = i18n.later("Next device"), group = i18n.later("Performance"), keys = {{.Down, {}}}},
	.Previous_Device  = {icon = lucide.ARROW_UP, label = i18n.later("Previous device"), group = i18n.later("Performance"), keys = {{.Up, {}}}},

	.Service_Start    = {icon = lucide.PLAY, label = i18n.later("Start"), group = i18n.later("Services"), keys = {{.S, {.Ctrl}}}, tags = {"run", "systemd"}},
	.Service_Stop     = {icon = lucide.SQUARE, label = i18n.later("Stop"), group = i18n.later("Services"), keys = {{.Delete, {}}}, tags = {"kill", "systemd"}},
	.Service_Restart  = {icon = lucide.ROTATE_CCW, label = i18n.later("Restart"), group = i18n.later("Services"), keys = {{.R, {.Ctrl}}}, tags = {"reload", "systemd"}},
	.Service_Enable   = {icon = lucide.CHECK, label = i18n.later("Enable"), group = i18n.later("Services"), keys = {{.E, {.Ctrl}}}, tags = {"boot", "autostart"}},
	.Service_Disable  = {icon = lucide.X, label = i18n.later("Disable"), group = i18n.later("Services"), keys = {{.D, {.Ctrl}}}, tags = {"boot", "autostart"}},
	.Service_Open     = {icon = lucide.LAYOUT_LIST, label = i18n.later("Open in Processes"), group = i18n.later("Services"), keys = {{.Return, {}}}},
	.Service_Copy     = {icon = lucide.COPY, label = i18n.later("Copy name"), group = i18n.later("Services"), keys = {{.C, {.Ctrl}}}},
	.Service_Details  = {icon = lucide.PANEL_BOTTOM, label = i18n.later("Details and journal"), group = i18n.later("Services"), keys = {{.I, {.Ctrl}}}, tags = {"log", "journal", "status"}},
	.Service_Open_File = {icon = lucide.FILE_TEXT, label = i18n.later("Open unit file"), group = i18n.later("Services"), keys = {{.O, {.Ctrl}}}},
	.Service_Manager  = {icon = lucide.USER, label = i18n.later("System or user services"), group = i18n.later("Services"), keys = {{.U, {.Ctrl}}}},
	.Journal_Search   = {icon = lucide.SEARCH, label = i18n.later("Search the journal"), group = i18n.later("Services"), keys = {{.J, {.Ctrl}}}},
	.Journal_Level    = {icon = lucide.FILTER, label = i18n.later("Journal: all, warnings, errors"), group = i18n.later("Services"), keys = {{.L, {.Alt}}}},
	.Journal_Boot     = {icon = lucide.POWER, label = i18n.later("Journal: this boot or every boot"), group = i18n.later("Services"), keys = {{.B, {.Alt}}}},
	.Journal_Follow   = {icon = lucide.ARROW_DOWN, label = i18n.later("Follow the journal"), group = i18n.later("Services"), keys = {{.F, {.Alt}}}},
	.Journal_Copy     = {icon = lucide.COPY, label = i18n.later("Copy the journal's entries shown"), group = i18n.later("Services"), keys = {{.C, {.Alt}}}},
	.Journal_Copy_Entry = {icon = lucide.CLIPBOARD_COPY, label = i18n.later("Copy the journal's entry"), group = i18n.later("Services"), keys = {{.C, {.Alt, .Shift}}}},
	.Journal_Window   = {icon = lucide.EXTERNAL_LINK, label = i18n.later("The journal in its own window"), group = i18n.later("Services"), keys = {{.J, {.Ctrl, .Shift}}}},

	.Startup_Enable   = {icon = lucide.CHECK, label = i18n.later("Enable"), group = i18n.later("Startup"), keys = {{.E, {.Ctrl}}}},
	.Startup_Disable  = {icon = lucide.X, label = i18n.later("Disable"), group = i18n.later("Startup"), keys = {{.D, {.Ctrl}}}},
	.Startup_Toggle   = {icon = lucide.ARROW_UP_DOWN, label = i18n.later("Enable or disable"), group = i18n.later("Startup"), keys = {{.Space, {}}}, tags = {"autostart", "login", "boot"}},
	.Startup_Open     = {icon = lucide.FOLDER_OPEN, label = i18n.later("Open file location"), group = i18n.later("Startup"), keys = {{.Return, {}}}},
	.Startup_Copy     = {icon = lucide.COPY, label = i18n.later("Copy command"), group = i18n.later("Startup"), keys = {{.C, {.Ctrl}}}},

	.Socket_End_Task  = {icon = lucide.X, label = i18n.later("End task"), group = i18n.later("Connections"), keys = {{.Delete, {}}}},
	.Socket_Kill      = {icon = lucide.ZAP, label = i18n.later("Kill…"), group = i18n.later("Connections"), keys = {{.Delete, {.Shift}}}},
	.Socket_Open      = {icon = lucide.LAYOUT_LIST, label = i18n.later("Open in Processes"), group = i18n.later("Connections"), keys = {{.Return, {}}}},
	.Socket_Copy      = {icon = lucide.COPY, label = i18n.later("Copy address"), group = i18n.later("Connections"), keys = {{.C, {.Ctrl}}}, tags = {"ip", "port"}},

	.Info_Copy        = {icon = lucide.COPY, label = i18n.later("Copy all"), group = i18n.later("Information"), keys = {{.C, {.Ctrl}}}, tags = {"report", "system", "specs"}},

	.Props_Suspend        = {icon = lucide.PAUSE, label = i18n.later("Suspend or resume"), group = i18n.later("Properties"), keys = {{.P, {.Ctrl}}}},
	.Props_End_Task       = {icon = lucide.X, label = i18n.later("End task"), group = i18n.later("Properties"), keys = {{.Delete, {}}}},
	.Props_Kill           = {icon = lucide.ZAP, label = i18n.later("Kill…"), group = i18n.later("Properties"), keys = {{.Delete, {.Shift}}}},
	.Props_Raise_Priority = {icon = lucide.ARROW_UP, label = i18n.later("Raise the priority"), group = i18n.later("Properties"), keys = {{.Up, {.Ctrl}}}},
	.Props_Lower_Priority = {icon = lucide.ARROW_DOWN, label = i18n.later("Lower the priority"), group = i18n.later("Properties"), keys = {{.Down, {.Ctrl}}}},
	.Props_Affinity       = {icon = lucide.MICROCHIP, label = i18n.later("Set affinity…"), group = i18n.later("Properties"), keys = {{.A, {.Ctrl, .Shift}}}},
	.Props_Filter         = {icon = lucide.FILTER, label = i18n.later("Filter the list"), group = i18n.later("Properties"), keys = {{.F, {.Ctrl}}}},
	.Props_Next_Tab       = {icon = lucide.ARROW_RIGHT, label = i18n.later("Next tab"), group = i18n.later("Properties"), keys = {{.Tab, {.Ctrl}}}},
	.Props_Previous_Tab   = {icon = lucide.ARROW_LEFT, label = i18n.later("Previous tab"), group = i18n.later("Properties"), keys = {{.Tab, {.Ctrl, .Shift}}}},
	.Props_Close          = {icon = lucide.X, label = i18n.later("Close"), group = i18n.later("Properties"), keys = {{.Escape, {}}}},
}

// The section a command acts in (nil: everywhere).
cmd_tab :: proc(c: Cmd) -> Maybe(Tab) {
	switch {
	case c <= .Previous_Section:                   return nil
	case c <= .Pin:                                return .Processes   // (the last command of Processes)
	case c <= .Previous_Device:                    return .Performance
	case c <= .Mission_Reset:                      return .Mission_Control
	case c <= .Journal_Window:                     return .Services
	case c <= .Startup_Copy:                       return .Startup
	case c <= .Socket_Copy:                        return .Connections
	case c == .Info_Copy:                          return .Information
	}
	return nil
}

cmd_is_props :: proc(c: Cmd) -> bool { return c >= .Props_Suspend }

// The command's label as shown (COMMANDS keeps the English, the catalogue's keys: the toolkit translates the palette's,
// the sheet's and the tooltips' itself).
cmd_label :: proc(c: Cmd) -> string { return i18n.tr(COMMANDS[c].label) }

// "Kill… (Shift+Delete)": a button's tooltip.
cmd_tip :: proc(c: Cmd) -> string { return ui.command_tip(COMMANDS[c]) }

// A menu's line of the command: its label, its key, greyed when it cannot act; clicked: it is run.
cmd_item :: proc(app: ^App, c: Cmd, label := "") {
	if ui.menu_item(label != "" ? label : cmd_label(c), ui.command_shortcut(COMMANDS[c]), icon = COMMANDS[c].icon, disabled = !cmd_can(app, c), icon_font = app.icons).clicked { cmd_run(app, c) }
}

// The keys the filter keeps while it has the keyboard and some text: they edit it.
@(private = "file")
editing_chord :: proc(ch: ui.Chord) -> bool {
	// (Ctrl+C copies, Ctrl+A selects the text, Ctrl+Delete erases a word: the filter's while it has text)
	if ch.mods - {.Shift} != {} { return ch.mods == {.Ctrl} && (ch.key == .C || ch.key == .A || ch.key == .Delete) }
	#partial switch ch.key {
	case .Delete, .Backspace, .Space, .Left, .Right, .Home, .End: return true
	}
	return false
}

// The commands' keys of the frame, when no menu or dialog has the keyboard: those of the window and of the section
// shown. `field_keeps`: the filter has the keyboard and some text: its editing keys are its own.
commands_keys :: proc(app: ^App, field_keeps: bool) {
	for c in Cmd {
		if cmd_is_props(c) { continue }
		if t, ok := cmd_tab(c).?; ok && t != app.tab { continue }
		cmd := COMMANDS[c]
		if field_keeps || ui.focus_key() == app.search_key && app.search_key != 0 {
			// (the filter keeps Space while it has the keyboard: a space in a name; the keys are a slice that COMMANDS
			// shares: a copy is edited, never the table)
			cmd.keys = slice.clone(cmd.keys, context.temp_allocator)
			for &ch in cmd.keys {
				if ch.key == .Space && ui.focus_key() == app.search_key { ch = {} }
				if field_keeps && editing_chord(ch) { ch = {} }
			}
		}
		if ui.command_pressed(cmd, !cmd_can(app, c)) { cmd_run(app, c) }
	}
}

// Opens the command palette.
palette_open :: proc(app: ^App) { ui.palette_open(&app.palette) }

// Where the palette's choices are kept: <state>/inspecteur/palette_choices; none (in memory only) in the demo, whose
// pictures must not depend on what the user chose.
palette_choices_file :: proc(app: ^App) -> string {
	if app.demo != nil { return "" }
	return strings.concatenate({platform.user_dir(.State, APP_NAME, context.temp_allocator), "/palette_choices"}, context.temp_allocator)
}

// The palette's list: the commands of the window, of the sections and of the section shown, then one line per
// preference (prefs_page.palette_commands). It is made again only when what it holds can change: the section shown, the
// preferences (their version) or the language (the settings' group is translated text), never at each frame. Its
// own arena holds it.
Palette_Table :: struct {
	arena:    virtual.Arena,
	commands: []ui.Command,
	cmds:     []Cmd,        // the command of each line before the settings'
	settings: []string,     // the preferences' names, the lines after `cmds`
	names:    []string,     // line -> its key in the memory of choices (a command's enum name, stable across languages; "" for a setting: not remembered)
	disabled: [dynamic]bool,   // per line, filled at each frame: what can act depends on the selection
	tab:      Tab,          // what it was made for
	prefs:    u64,
	language: ^i18n.Language,
	version:  u64,          // bumped at each making (0: not made); the palette's version
}

palette_table_make :: proc(table: ^Palette_Table, app: ^App) {
	virtual.arena_destroy(&table.arena)
	table.arena = {}
	a := virtual.arena_allocator(&table.arena)
	commands := make([dynamic]ui.Command, a)
	cmds := make([dynamic]Cmd, a)
	names := make([dynamic]string, a)
	for c in Cmd {
		if cmd_is_props(c) || c == .Palette { continue }
		if t, ok := cmd_tab(c).?; ok && t != app.tab { continue }
		append(&commands, COMMANDS[c])
		append(&cmds, c)
		// (the enum's name: static text, the same in every language and every section)
		append(&names, reflect.enum_string(c))
	}
	// the settings too, each a line under "Settings · <page>": chosen, the page opens on it alone
	settings, setting_names := prefs_page.palette_commands(&app.prefs, settings_options(app), a)
	append(&commands, ..settings)
	for _ in settings { append(&names, "") }
	table.commands, table.cmds, table.names = commands[:], cmds[:], names[:]
	table.settings = make([]string, len(setting_names), a)
	for n, i in setting_names { table.settings[i] = strings.clone(n, a) }
	resize(&table.disabled, len(table.commands))
	table.tab, table.prefs, table.language = app.tab, app.prefs.version, i18n.current()
	table.version += 1
}

palette_table_destroy :: proc(table: ^Palette_Table) {
	virtual.arena_destroy(&table.arena)
	delete(table.disabled)
	table^ = {}
}

// The palette while it is open. Its size, when the user changes it, is kept (view.palette_size).
palette_build :: proc(app: ^App) {
	if !app.palette.open { return }
	table := &app.palette_table
	if table.version == 0 || table.tab != app.tab || table.prefs != app.prefs.version || table.language != i18n.current() {
		palette_table_make(table, app)
	}
	for c, i in table.cmds { table.disabled[i] = !cmd_can(app, c) }
	// (the memory's own version counts its changes: the palette reads it beside the table's)
	i, resized := ui.palette(&app.palette, table.commands, table.disabled[:], {memory = &app.palette_choices, names = table.names, version = table.version})
	if resized { pref_set(&app.prefs, "view.palette_size", fmt.tprintf("%.0f %.0f", app.palette.size.x, app.palette.size.y)) }
	commands := len(table.cmds)
	switch {
	case i >= commands:
		app.settings_open = true
		prefs_page.show(&app.settings_page, &app.prefs, settings_options(app), table.settings[i - commands])
	case i >= 0:
		ui.choice_note(&app.palette_choices, table.names[i])
		cmd_run(app, table.cmds[i])
	}
}

// The sheet of the keys while it is open: every command, its section's first. The list is made once, at the first
// opening: COMMANDS does not change, and the sheet translates the labels itself. Its address stays, so the sheet needs
// no version.
shortcuts_build :: proc(app: ^App) {
	if app.sheet.open && len(app.sheet_commands) == 0 {
		for c in Cmd { if cmd_tab(c) == nil && !cmd_is_props(c) { append(&app.sheet_commands, COMMANDS[c]) } }
		for c in Cmd { if _, ok := cmd_tab(c).?; ok { append(&app.sheet_commands, COMMANDS[c]) } }
		for c in Cmd { if cmd_is_props(c) { append(&app.sheet_commands, COMMANDS[c]) } }
	}
	// (called while closed too: the modal's Escape and its closing are its own)
	ui.shortcuts_sheet(&app.sheet, "shortcuts", app.sheet_commands[:])
}

// Whether the command can act now.
cmd_can :: proc(app: ^App, c: Cmd) -> bool {
	p := selected_proc(app)
	switch c {
	case .Palette, .Shortcuts, .Filter, .Read_Again, .Light_Dark, .Setup, .Settings, .Pause_Refresh, .Refresh_Speed, .Diagnose: return true
	case .Check_Updates: return app.updater != nil
	case .Zoom_In:    return ui.zoom(&app.main.state) < ui.ZOOM_MAX
	case .Zoom_Out:   return ui.zoom(&app.main.state) > ui.ZOOM_MIN
	case .Zoom_Reset: return ui.zoom(&app.main.state) != 1
	case .Clear_Filter: return len(app.search.buf) > 0
	case .Show_Mission_Control, .Show_Processes, .Show_Performance, .Show_Services, .Show_Startup, .Show_Connections, .Show_Information, .Next_Section, .Previous_Section: return true
	case .End_Task, .Kill, .End_Tree: return p != nil || ui.list_mark_count(&app.vl) > 0
	case .Select_All: return len(app.table.rows) > 0
	case .Properties, .Search_Online: return p != nil
	case .Affinity: return p != nil && selected_is_process(app)
	case .Go_To_Service: return p != nil && selected_is_process(app) && p.unit != ""
	case .Send_Signal:   return p != nil
	case .Show_Window:   r, ok := selected_row(app); return ok && len(windows_of(app, row_entry(app, r))) > 0
	case .Dump: return p != nil && selected_is_process(app)
	case .Tree_View: return true
	case .Pin: return pin_name(app) != "" && !app.table.tree
	case .Suspend: return p != nil && selected_is_process(app)
	case .Open_Location: return p != nil && p.exe != ""
	case .Copy_Command: return p != nil && p.cmdline != ""
	case .Default_Action: return p != nil
	case .Open_Group, .Close_Group: return group_can_toggle(app, c == .Open_Group)
	case .Raise_Priority, .Lower_Priority: return p != nil && selected_is_process(app)
	case .Columns, .Summary: return true
	case .Cpu_Grid, .Next_Device, .Previous_Device: return true
	case .Mission_Panels, .Mission_Reset: return true
	case .Service_Start, .Service_Stop, .Service_Restart, .Service_Enable, .Service_Disable, .Service_Open, .Service_Copy, .Service_Open_File: return service_can(app, c)
	case .Service_Details: return true
	case .Service_Manager: return true
	case .Journal_Search, .Journal_Level, .Journal_Boot, .Journal_Follow, .Journal_Copy, .Journal_Copy_Entry, .Journal_Window: return journal_can(app, c)
	case .Startup_Enable, .Startup_Disable, .Startup_Toggle, .Startup_Open, .Startup_Copy: return startup_can(app, c)
	case .Socket_End_Task, .Socket_Kill, .Socket_Open:
		s, ok := selected_socket(app)
		return ok && s.pid > 0
	case .Socket_Copy:
		_, ok := selected_socket(app)
		return ok
	case .Info_Copy: return true
	case .Props_Suspend, .Props_End_Task, .Props_Kill, .Props_Raise_Priority, .Props_Lower_Priority, .Props_Affinity:
		return app.props.open && find_proc(&app.sampler, app.props.pid, app.props.start) != nil
	case .Props_Filter: return app.props.open && props_tab_listed(app.props.tab)
	case .Props_Next_Tab, .Props_Previous_Tab, .Props_Close: return app.props.open
	}
	return false
}

cmd_run :: proc(app: ^App, c: Cmd) {
	switch c {
	case .Palette:          palette_open(app)
	case .Shortcuts:        app.sheet.open = true
	// (its text selected: what is typed then replaces it, as in a browser's Ctrl+F)
	case .Filter:           if app.search_key != 0 { ui.set_focus(app.search_key); ui.line_edit_select_all(&app.search) }
	case .Clear_Filter:     ui.line_edit_clear(&app.search)
	case .Read_Again:       refresh_now(app)
	case .Pause_Refresh:    refresh_pause(app, !app.paused)
	case .Refresh_Speed:    refresh_menu_open(app)
	case .Zoom_In:          ui.set_zoom(&app.main.state, ui.zoom(&app.main.state) * ui.feel(&app.main.state).zoom_step)
	case .Zoom_Out:         ui.set_zoom(&app.main.state, ui.zoom(&app.main.state) / ui.feel(&app.main.state).zoom_step)
	case .Zoom_Reset:       ui.set_zoom(&app.main.state, 1)
	case .Light_Dark:       light_dark_switch(app)
	case .Setup:            setup_open(app)
	case .Settings:         settings_toggle(app)
	case .Check_Updates:    update.check_now(app.updater); say(app, i18n.tr("Checking for updates…"))
	case .Diagnose:         app.diagnosis_open = true
	case .Show_Mission_Control: tab_show(app, .Mission_Control)
	case .Show_Processes:   tab_show(app, .Processes)
	case .Show_Performance: tab_show(app, .Performance)
	case .Show_Services:    tab_show(app, .Services)
	case .Show_Startup:     tab_show(app, .Startup)
	case .Show_Connections: tab_show(app, .Connections)
	case .Show_Information: tab_show(app, .Information)
	case .Next_Section:     tab_show(app, Tab((int(app.tab) + 1) % len(Tab)))
	case .Previous_Section: tab_show(app, Tab((int(app.tab) + len(Tab) - 1) % len(Tab)))
	case .End_Task:         end_selected(app)
	case .Kill:             kill_selected(app)
	case .End_Tree:         end_tree_selected(app)
	case .Select_All:       ui.list_mark_all(&app.vl)
	case .Suspend:          suspend_selected(app)
	case .Properties:       props_selected(app)
	case .Open_Location:    if p := selected_proc(app); p != nil { open_location(app, p) }
	case .Copy_Command:     if p := selected_proc(app); p != nil { copy_command(app, p) }
	case .Default_Action:   default_action(app)
	case .Open_Group:       group_set(app, true)
	case .Close_Group:      group_set(app, false)
	case .Raise_Priority:   if p := selected_proc(app); p != nil { priority_step(app, p, -1) }
	case .Lower_Priority:   if p := selected_proc(app); p != nil { priority_step(app, p, 1) }
	case .Affinity:         if p := selected_proc(app); p != nil { affinity_open(app, p) }
	case .Go_To_Service:    if p := selected_proc(app); p != nil { go_to_service(app, p) }
	case .Show_Window:      if r, ok := selected_row(app); ok { window_show(app, row_entry(app, r)) }
	case .Send_Signal:      tab_show(app, .Processes); row_menu_open(app, {app.sel_rect.min.x + ui.font_size() * 2.5, app.sel_rect.max.y}, from_keyboard = true)
	case .Dump:             if p := selected_proc(app); p != nil { dump_ask(app, p) }
	case .Search_Online:    search_online(app)
	case .Tree_View:        tree_view_switch(app)
	case .Columns:          columns_menu_open(app)
	case .Summary:          summary_switch(app)
	case .Pin:              pin_switch(app)
	case .Mission_Panels:   mission_panels_open(app)
	case .Mission_Reset:    mission_reset(app)
	case .Cpu_Grid:         cpu_grid_switch(app)
	case .Next_Device:      device_step(app, 1)
	case .Previous_Device:  device_step(app, -1)
	case .Service_Start:    service_do(app, .Start)
	case .Service_Stop:     service_do(app, .Stop)
	case .Service_Restart:  service_do(app, .Restart)
	case .Service_Enable:   service_do(app, .Enable)
	case .Service_Disable:  service_do(app, .Disable)
	case .Service_Open:     service_reveal(app)
	case .Service_Copy:     service_copy(app)
	case .Service_Details:  service_details_switch(app)
	case .Service_Open_File: service_open_file(app)
	case .Service_Manager:  services_switch(app, app.services.manager == .System ? .User : .System)
	case .Journal_Search, .Journal_Level, .Journal_Boot, .Journal_Follow, .Journal_Copy, .Journal_Copy_Entry, .Journal_Window: journal_run(app, c)
	case .Startup_Enable:   startup_toggle(app, true)
	case .Startup_Disable:  startup_toggle(app, false)
	case .Startup_Toggle:   if it, ok := selected_startup(app); ok { startup_toggle(app, !it.enabled) }
	case .Startup_Open:     startup_open(app)
	case .Startup_Copy:     startup_copy(app)
	case .Socket_End_Task:  connection_signal(app, false)
	case .Socket_Kill:      connection_signal(app, true)
	case .Socket_Open:      connection_reveal(app)
	case .Socket_Copy:      connection_copy(app)
	case .Info_Copy:        info_copy(app)
	case .Props_Suspend:        props_suspend(app)
	case .Props_End_Task:       props_signal(app, false)
	case .Props_Kill:           props_signal(app, true)
	case .Props_Raise_Priority: if p := find_proc(&app.sampler, app.props.pid, app.props.start); p != nil { priority_step(app, p, -1) }
	case .Props_Lower_Priority: if p := find_proc(&app.sampler, app.props.pid, app.props.start); p != nil { priority_step(app, p, 1) }
	case .Props_Affinity:       if p := find_proc(&app.sampler, app.props.pid, app.props.start); p != nil { affinity_open(app, p) }
	case .Props_Filter:         props_filter_focus(app)
	case .Props_Next_Tab:       app.props.tab = Props_Tab((int(app.props.tab) + 1) % len(Props_Tab))
	case .Props_Previous_Tab:   app.props.tab = Props_Tab((int(app.props.tab) + len(Props_Tab) - 1) % len(Props_Tab))
	case .Props_Close:          app.props.open = false
	}
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
