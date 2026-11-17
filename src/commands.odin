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

import "core:fmt"
import "core:slice"
import "core:strings"
import config "gt:config"
import i18n "gt:i18n"
import lucide "gt:lucide"
import "gt:platform"
import prefs_page "gt:prefs_page"
import "gt:ui"
import update "gt:update"

Cmd :: enum u8 {
	// Window
	Shortcuts, Filter, Clear_Filter, Read_Again, Pause_Refresh, Refresh_Speed, Zoom_In, Zoom_Out, Zoom_Reset,
	Light_Dark, Settings, Check_Updates, Diagnose,
	// Sections
	Show_Mission_Control, Show_Processes, Show_Performance, Show_Services, Show_Startup, Show_Connections, Show_Information, Next_Section, Previous_Section,
	// Processes
	End_Task, Kill, End_Tree, Select_All, Suspend, Properties, Open_Location, Copy_Command, Default_Action, Open_Group,
	Close_Group, Raise_Priority, Lower_Priority, Set_Priority, Affinity, Send_Signal, Show_Window, Go_To_Service, Dump, Search_Online, Tree_View, Columns, Summary, Pin,
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
	.Shortcuts        = {id = "shortcuts", icon = lucide.KEYBOARD, label = i18n.later("Keyboard shortcuts"), group = i18n.later("Window"), keys = {{.F1, {}}}, tags = {"keys", "help", "keyboard"}, scope = .Window},
	.Filter           = {id = "filter", icon = lucide.FILTER, label = i18n.later("Filter"), group = i18n.later("Window"), keys = {{.F, {.Ctrl}}}},
	.Clear_Filter     = {id = "clear_filter", icon = lucide.X, label = i18n.later("Clear the filter"), group = i18n.later("Window"), keys = {{.Escape, {}}}},
	.Read_Again       = {id = "read_again", icon = lucide.REFRESH_CW, label = i18n.later("Read again"), group = i18n.later("Window"), keys = {{.F5, {}}}, tags = {"refresh", "reload"}},
	.Pause_Refresh    = {id = "pause_refresh", icon = lucide.PAUSE, label = i18n.later("Pause or resume the refresh"), group = i18n.later("Window"), keys = {{.Space, {.Ctrl}}}, tags = {"freeze", "stop updating"}},
	.Refresh_Speed    = {id = "refresh_speed", icon = lucide.GAUGE, label = i18n.later("Refresh speed…"), group = i18n.later("Window"), keys = {{.R, {.Ctrl, .Shift}}}, tags = {"interval", "update", "period"}, arguments = REFRESH_ARGUMENTS[:]},
	.Zoom_In          = {id = "zoom_in", icon = lucide.ZOOM_IN, label = i18n.later("Zoom in"), group = i18n.later("Window"), keys = ui.ZOOM_IN_KEYS[:]},
	.Zoom_Out         = {id = "zoom_out", icon = lucide.ZOOM_OUT, label = i18n.later("Zoom out"), group = i18n.later("Window"), keys = ui.ZOOM_OUT_KEYS[:]},
	.Zoom_Reset       = {id = "zoom_reset", icon = lucide.SEARCH, label = i18n.later("Zoom: 100 %"), group = i18n.later("Window"), keys = ui.ZOOM_RESET_KEYS[:]},
	.Light_Dark       = {id = "light_dark", icon = lucide.SUN_MOON, label = i18n.later("Light or dark"), group = i18n.later("Window"), keys = {{.L, {.Ctrl, .Shift}}}, tags = {"theme", "dark", "night", "colours"}},
	.Settings         = {id = "settings", icon = lucide.SLIDERS_HORIZONTAL, label = i18n.later("Settings"), group = i18n.later("Window"), keys = {{.Comma, {.Ctrl}}}, tags = {"preferences", "options", "configure"}, scope = .Window},
	.Check_Updates    = {id = "check_updates", icon = lucide.HARD_DRIVE_DOWNLOAD, label = i18n.later("Check for updates"), group = i18n.later("Window")},
	.Diagnose         = {id = "diagnose", icon = lucide.LIGHTBULB, label = i18n.later("Why is it slow?"), group = i18n.later("Window"), keys = {{.F2, {}}}, tags = {"slow", "lag", "performance", "why"}},

	.Show_Mission_Control = {id = "show_mission_control", icon = lucide.LAYOUT_GRID, label = i18n.later("Mission Control"), group = i18n.later("Sections"), keys = {{.N1, {.Ctrl}}}},
	.Show_Processes   = {id = "show_processes", icon = lucide.LAYOUT_LIST, label = i18n.later("Processes"), group = i18n.later("Sections"), keys = {{.N2, {.Ctrl}}}},
	.Show_Performance = {id = "show_performance", icon = lucide.GAUGE, label = i18n.later("Performance"), group = i18n.later("Sections"), keys = {{.N3, {.Ctrl}}}},
	.Show_Services    = {id = "show_services", icon = lucide.SETTINGS, label = i18n.later("Services"), group = i18n.later("Sections"), keys = {{.N4, {.Ctrl}}}},
	.Show_Startup     = {id = "show_startup", icon = lucide.POWER, label = i18n.later("Startup"), group = i18n.later("Sections"), keys = {{.N5, {.Ctrl}}}},
	.Show_Connections = {id = "show_connections", icon = lucide.GLOBE, label = i18n.later("Connections"), group = i18n.later("Sections"), keys = {{.N6, {.Ctrl}}}},
	.Show_Information = {id = "show_information", icon = lucide.INFO, label = i18n.later("Information"), group = i18n.later("Sections"), keys = {{.N7, {.Ctrl}}}},
	.Next_Section     = {id = "next_section", icon = lucide.ARROW_RIGHT, label = i18n.later("Next section"), group = i18n.later("Sections"), keys = {{.Tab, {.Ctrl}}}},
	.Previous_Section = {id = "previous_section", icon = lucide.ARROW_LEFT, label = i18n.later("Previous section"), group = i18n.later("Sections"), keys = {{.Tab, {.Ctrl, .Shift}}}},

	.End_Task         = {id = "end_task", icon = lucide.X, label = i18n.later("End task"), group = i18n.later("Processes"), keys = {{.Delete, {}}}, tags = {"kill", "stop", "close", "quit", "terminate"}},
	.Kill             = {id = "kill", icon = lucide.ZAP, label = i18n.later("Kill…"), group = i18n.later("Processes"), keys = {{.Delete, {.Shift}}}, tags = {"force", "sigkill", "terminate"}},
	.End_Tree         = {id = "end_tree", icon = lucide.LIST_TREE, label = i18n.later("End process tree…"), group = i18n.later("Processes"), keys = {{.Delete, {.Ctrl}}}, tags = {"kill", "children"}},
	.Select_All       = {id = "select_all", icon = lucide.LIST_CHECKS, label = i18n.later("Select all"), group = i18n.later("Processes"), keys = {{.A, {.Ctrl}}}},
	.Suspend          = {id = "suspend", icon = lucide.PAUSE, label = i18n.later("Suspend or resume"), group = i18n.later("Processes"), keys = {{.P, {.Ctrl}}}, tags = {"pause", "freeze", "stop", "continue", "sigstop"}},
	.Properties       = {id = "properties", icon = lucide.INFO, label = i18n.later("Properties"), group = i18n.later("Processes"), keys = {{.Return, {.Alt}}}, tags = {"details", "info", "threads", "files", "environment"}},
	.Open_Location    = {id = "open_location", icon = lucide.FOLDER_OPEN, label = i18n.later("Open file location"), group = i18n.later("Processes"), keys = {{.O, {.Ctrl}}}, tags = {"folder", "executable", "reveal"}},
	.Copy_Command     = {id = "copy_command", icon = lucide.COPY, label = i18n.later("Copy command line"), group = i18n.later("Processes"), keys = {{.C, {.Ctrl}}}},
	.Default_Action   = {id = "default_action", icon = lucide.PLAY, label = i18n.later("Open the group, or Properties"), group = i18n.later("Processes"), keys = {{.Return, {}}}},
	.Open_Group       = {id = "open_group", icon = lucide.CHEVRON_DOWN, label = i18n.later("Open the group"), group = i18n.later("Processes"), keys = {{.Right, {}}}},
	.Close_Group      = {id = "close_group", icon = lucide.CHEVRON_UP, label = i18n.later("Close the group"), group = i18n.later("Processes"), keys = {{.Left, {}}}},
	.Raise_Priority   = {id = "raise_priority", icon = lucide.ARROW_UP, label = i18n.later("Raise the priority"), group = i18n.later("Processes"), keys = {{.Up, {.Ctrl}}}, tags = {"nice", "renice"}},
	.Lower_Priority   = {id = "lower_priority", icon = lucide.ARROW_DOWN, label = i18n.later("Lower the priority"), group = i18n.later("Processes"), keys = {{.Down, {.Ctrl}}}, tags = {"nice", "renice", "background"}},
	.Set_Priority     = {id = "set_priority", icon = lucide.ARROW_UP_DOWN, label = i18n.later("Set the priority"), group = i18n.later("Processes"), tags = {"nice", "renice", "high", "low", "idle"}, arguments = PRIORITY_ARGUMENTS[:]},
	.Affinity         = {id = "affinity", icon = lucide.MICROCHIP, label = i18n.later("Set affinity…"), group = i18n.later("Processes"), keys = {{.A, {.Ctrl, .Shift}}}, tags = {"cpu", "cores", "pin"}},
	.Send_Signal      = {id = "send_signal", icon = lucide.ZAP, label = i18n.later("Send a signal"), group = i18n.later("Processes"), tags = {"signal", "sighup", "sigusr1", "sigint", "reload", "hang up"}, arguments = SIGNAL_ARGUMENTS[:]},
	.Show_Window      = {id = "show_window", icon = lucide.APP_WINDOW, label = i18n.later("Show its window"), group = i18n.later("Processes"), keys = {{.W, {.Ctrl, .Shift}}}, tags = {"window", "focus", "switch", "raise", "front"}},
	.Go_To_Service    = {id = "go_to_service", icon = lucide.SERVER, label = i18n.later("Go to service"), group = i18n.later("Processes"), keys = {{.S, {.Ctrl, .Shift}}}},
	.Dump             = {id = "dump", icon = lucide.SAVE, label = i18n.later("Create dump file…"), group = i18n.later("Processes"), keys = {{.D, {.Ctrl, .Shift}}}, tags = {"core", "gcore", "debug"}},
	.Search_Online    = {id = "search_online", icon = lucide.SEARCH, label = i18n.later("Search online"), group = i18n.later("Processes"), keys = {{.F, {.Ctrl, .Shift}}}, tags = {"web", "google", "what is"}},
	.Tree_View        = {id = "tree_view", icon = lucide.FOLDER_TREE, label = i18n.later("Process tree or apps"), group = i18n.later("Processes"), keys = {{.T, {.Ctrl}}}, tags = {"parent", "hierarchy"}},
	.Columns          = {id = "columns", icon = lucide.COLUMNS_2, label = i18n.later("Columns…"), group = i18n.later("Processes"), keys = {{.C, {.Ctrl, .Shift}}}, tags = {"show", "hide", "fields"}},
	.Summary          = {id = "summary", icon = lucide.LAYOUT_GRID, label = i18n.later("Show or hide the summary of the machine"), group = i18n.later("Processes"), keys = {{.B, {.Ctrl}}}},
	.Pin              = {id = "pin", icon = lucide.PIN, label = i18n.later("Pin or unpin"), group = i18n.later("Processes"), keys = {{.P, {.Alt}}}, tags = {"favourite", "top", "keep"}},

	.Mission_Panels   = {id = "mission_panels", icon = lucide.LAYOUT_GRID, label = i18n.later("Mission Control: panels…"), group = i18n.later("Mission Control")},
	.Mission_Reset    = {id = "mission_reset", icon = lucide.ROTATE_CCW, label = i18n.later("Mission Control: the layout as at first"), group = i18n.later("Mission Control")},
	.Cpu_Grid         = {id = "cpu_grid", icon = lucide.LAYOUT_GRID, label = i18n.later("One graph per logical processor"), group = i18n.later("Performance"), keys = {{.G, {.Ctrl}}}},
	.Next_Device      = {id = "next_device", icon = lucide.ARROW_DOWN, label = i18n.later("Next device"), group = i18n.later("Performance"), keys = {{.Down, {}}}},
	.Previous_Device  = {id = "previous_device", icon = lucide.ARROW_UP, label = i18n.later("Previous device"), group = i18n.later("Performance"), keys = {{.Up, {}}}},

	.Service_Start    = {id = "service_start", icon = lucide.PLAY, label = i18n.later("Start"), group = i18n.later("Services"), keys = {{.S, {.Ctrl}}}, tags = {"run", "systemd"}},
	.Service_Stop     = {id = "service_stop", icon = lucide.SQUARE, label = i18n.later("Stop"), group = i18n.later("Services"), keys = {{.Delete, {}}}, tags = {"kill", "systemd"}},
	.Service_Restart  = {id = "service_restart", icon = lucide.ROTATE_CCW, label = i18n.later("Restart"), group = i18n.later("Services"), keys = {{.R, {.Ctrl}}}, tags = {"reload", "systemd"}},
	.Service_Enable   = {id = "service_enable", icon = lucide.CHECK, label = i18n.later("Enable"), group = i18n.later("Services"), keys = {{.E, {.Ctrl}}}, tags = {"boot", "autostart"}},
	.Service_Disable  = {id = "service_disable", icon = lucide.X, label = i18n.later("Disable"), group = i18n.later("Services"), keys = {{.D, {.Ctrl}}}, tags = {"boot", "autostart"}},
	.Service_Open     = {id = "service_open", icon = lucide.LAYOUT_LIST, label = i18n.later("Open in Processes"), group = i18n.later("Services"), keys = {{.Return, {}}}},
	.Service_Copy     = {id = "service_copy", icon = lucide.COPY, label = i18n.later("Copy name"), group = i18n.later("Services"), keys = {{.C, {.Ctrl}}}},
	.Service_Details  = {id = "service_details", icon = lucide.PANEL_BOTTOM, label = i18n.later("Details and journal"), group = i18n.later("Services"), keys = {{.I, {.Ctrl}}}, tags = {"log", "journal", "status"}},
	.Service_Open_File = {id = "service_open_file", icon = lucide.FILE_TEXT, label = i18n.later("Open unit file"), group = i18n.later("Services"), keys = {{.O, {.Ctrl}}}},
	.Service_Manager  = {id = "service_manager", icon = lucide.USER, label = i18n.later("System or user services"), group = i18n.later("Services"), keys = {{.U, {.Ctrl}}}},
	.Journal_Search   = {id = "journal_search", icon = lucide.SEARCH, label = i18n.later("Search the journal"), group = i18n.later("Services"), keys = {{.J, {.Ctrl}}}},
	.Journal_Level    = {id = "journal_level", icon = lucide.FILTER, label = i18n.later("Journal: all, warnings, errors"), group = i18n.later("Services"), keys = {{.L, {.Alt}}}},
	.Journal_Boot     = {id = "journal_boot", icon = lucide.POWER, label = i18n.later("Journal: this boot or every boot"), group = i18n.later("Services"), keys = {{.B, {.Alt}}}},
	.Journal_Follow   = {id = "journal_follow", icon = lucide.ARROW_DOWN, label = i18n.later("Follow the journal"), group = i18n.later("Services"), keys = {{.F, {.Alt}}}},
	.Journal_Copy     = {id = "journal_copy", icon = lucide.COPY, label = i18n.later("Copy the journal's entries shown"), group = i18n.later("Services"), keys = {{.C, {.Alt}}}},
	.Journal_Copy_Entry = {id = "journal_copy_entry", icon = lucide.CLIPBOARD_COPY, label = i18n.later("Copy the journal's entry"), group = i18n.later("Services"), keys = {{.C, {.Alt, .Shift}}}},
	.Journal_Window   = {id = "journal_window", icon = lucide.EXTERNAL_LINK, label = i18n.later("The journal in its own window"), group = i18n.later("Services"), keys = {{.J, {.Ctrl, .Shift}}}},

	.Startup_Enable   = {id = "startup_enable", icon = lucide.CHECK, label = i18n.later("Enable"), group = i18n.later("Startup"), keys = {{.E, {.Ctrl}}}},
	.Startup_Disable  = {id = "startup_disable", icon = lucide.X, label = i18n.later("Disable"), group = i18n.later("Startup"), keys = {{.D, {.Ctrl}}}},
	.Startup_Toggle   = {id = "startup_toggle", icon = lucide.ARROW_UP_DOWN, label = i18n.later("Enable or disable"), group = i18n.later("Startup"), keys = {{.Space, {}}}, tags = {"autostart", "login", "boot"}},
	.Startup_Open     = {id = "startup_open", icon = lucide.FOLDER_OPEN, label = i18n.later("Open file location"), group = i18n.later("Startup"), keys = {{.Return, {}}}},
	.Startup_Copy     = {id = "startup_copy", icon = lucide.COPY, label = i18n.later("Copy command"), group = i18n.later("Startup"), keys = {{.C, {.Ctrl}}}},

	.Socket_End_Task  = {id = "socket_end_task", icon = lucide.X, label = i18n.later("End task"), group = i18n.later("Connections"), keys = {{.Delete, {}}}},
	.Socket_Kill      = {id = "socket_kill", icon = lucide.ZAP, label = i18n.later("Kill…"), group = i18n.later("Connections"), keys = {{.Delete, {.Shift}}}},
	.Socket_Open      = {id = "socket_open", icon = lucide.LAYOUT_LIST, label = i18n.later("Open in Processes"), group = i18n.later("Connections"), keys = {{.Return, {}}}},
	.Socket_Copy      = {id = "socket_copy", icon = lucide.COPY, label = i18n.later("Copy address"), group = i18n.later("Connections"), keys = {{.C, {.Ctrl}}}, tags = {"ip", "port"}},

	.Info_Copy        = {id = "info_copy", icon = lucide.COPY, label = i18n.later("Copy all"), group = i18n.later("Information"), keys = {{.C, {.Ctrl}}}, tags = {"report", "system", "specs"}},

	.Props_Suspend        = {id = "props_suspend", icon = lucide.PAUSE, label = i18n.later("Suspend or resume"), group = i18n.later("Properties"), keys = {{.P, {.Ctrl}}}},
	.Props_End_Task       = {id = "props_end_task", icon = lucide.X, label = i18n.later("End task"), group = i18n.later("Properties"), keys = {{.Delete, {}}}},
	.Props_Kill           = {id = "props_kill", icon = lucide.ZAP, label = i18n.later("Kill…"), group = i18n.later("Properties"), keys = {{.Delete, {.Shift}}}},
	.Props_Raise_Priority = {id = "props_raise_priority", icon = lucide.ARROW_UP, label = i18n.later("Raise the priority"), group = i18n.later("Properties"), keys = {{.Up, {.Ctrl}}}},
	.Props_Lower_Priority = {id = "props_lower_priority", icon = lucide.ARROW_DOWN, label = i18n.later("Lower the priority"), group = i18n.later("Properties"), keys = {{.Down, {.Ctrl}}}},
	.Props_Affinity       = {id = "props_affinity", icon = lucide.MICROCHIP, label = i18n.later("Set affinity…"), group = i18n.later("Properties"), keys = {{.A, {.Ctrl, .Shift}}}},
	.Props_Filter         = {id = "props_filter", icon = lucide.FILTER, label = i18n.later("Filter the list"), group = i18n.later("Properties"), keys = {{.F, {.Ctrl}}}},
	.Props_Next_Tab       = {id = "props_next_tab", icon = lucide.ARROW_RIGHT, label = i18n.later("Next tab"), group = i18n.later("Properties"), keys = {{.Tab, {.Ctrl}}}},
	.Props_Previous_Tab   = {id = "props_previous_tab", icon = lucide.ARROW_LEFT, label = i18n.later("Previous tab"), group = i18n.later("Properties"), keys = {{.Tab, {.Ctrl, .Shift}}}},
	.Props_Close          = {id = "props_close", icon = lucide.X, label = i18n.later("Close"), group = i18n.later("Properties"), keys = {{.Escape, {}}}},
}

// What the commands with arguments take (ui.Command.arguments): in the palette, Enter on one of them opens its form,
// and the choice comes with the value (cmd_run_with). Each is a closed list that inspecteur fills (command_choices):
// its tables (SIGNAL_ITEMS, PRIORITIES, REFRESH_SPEEDS) stay the one place of their values, shared with the menus. A
// default is one of the list's values. Their names are unique among the commands: command_choices goes by the name.
// (Without a form, a key the person gave one of them, the command runs as before: its menu or its dialog.)
SIGNAL_ARGUMENTS := [?]config.Def{{name = "signal", title = i18n.later("Signal"), kind = .String, default = {s = "SIGHUP"}}}
PRIORITY_ARGUMENTS := [?]config.Def{{name = "priority", title = i18n.later("Priority"), kind = .String, default = {s = "0"}}}
REFRESH_ARGUMENTS := [?]config.Def{{name = "period", title = i18n.later("Refresh every"), kind = .String, default = {s = "1000"}}}

// The values an argument may take, and their labels (English, i18n.later: the palette translates them), for the
// palette's form (Palette_Commands_Options.choices). Temporary memory: the form reads them again at each build.
command_choices :: proc(user: rawptr, index: int, argument: string) -> (labels, values: []string) {
	switch argument {
	case "signal":
		labels, values = make([]string, len(SIGNAL_ITEMS), context.temp_allocator), make([]string, len(SIGNAL_ITEMS), context.temp_allocator)
		for s, i in SIGNAL_ITEMS { labels[i], values[i] = s.label, s.name }
	case "priority":
		labels, values = make([]string, len(PRIORITIES), context.temp_allocator), make([]string, len(PRIORITIES), context.temp_allocator)
		for q, i in PRIORITIES { labels[i], values[i] = q.name, fmt.tprintf("%d", q.nice) }
	case "period":
		labels, values = make([]string, len(REFRESH_SPEEDS), context.temp_allocator), make([]string, len(REFRESH_SPEEDS), context.temp_allocator)
		for sp, i in REFRESH_SPEEDS { labels[i], values[i] = sp.name, fmt.tprintf("%d", sp.ms) }
	}
	return
}

// Runs `c` with the values of its form, in the order of its arguments (the palette's choice). No value: the command as
// its key runs it. A value that is not one of its list's does nothing. The command is checked against the selection
// first, as a key is: between the choice and this build the selection may have moved.
cmd_run_with :: proc(app: ^App, c: Cmd, arguments: []string) {
	if len(arguments) == 0 || len(COMMANDS[c].arguments) == 0 { cmd_run(app, c); return }
	if !cmd_can(app, c) { return }
	value := arguments[0]
	#partial switch c {
	case .Send_Signal:
		for s in SIGNAL_ITEMS { if s.name == value { signal_selected(app, s.sig); return } }
	case .Set_Priority:
		p := selected_proc(app)
		if p == nil || !selected_is_process(app) { return }
		for q in PRIORITIES { if fmt.tprintf("%d", q.nice) == value { set_priority(app, p, q.nice); return } }
	case .Refresh_Speed:
		for sp in REFRESH_SPEEDS { if fmt.tprintf("%d", sp.ms) == value { refresh_speed_set(app, sp.ms); return } }
	case:
		cmd_run(app, c)
	}
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

// What cmd_can reads, in a few numbers: when one changes, what can act is read again. (The selection of each table: its
// version, which moves with every change of it, the active row too, and the active row inspecteur sets itself; a new
// sample, the rows made again, the readings of the services, the startup items and the sockets, the details' reading,
// the Properties, the zoom, the filter.)
Palette_Can :: struct {
	tab:        Tab,
	refreshes:  int,
	rows:       int,
	selection:  [2]u64,    // the processes': the active row, the selection's version
	tree, filtered, paused, updater: bool,
	zoom:       f32,
	services:   [3]u64,    // the active row, the selection's version, an action pending
	services_list: rawptr,
	details:    bool,
	pane:       int,       // the details' readings
	startup:    [3]u64,
	startup_list: rawptr,
	sockets:    [3]u64,    // the active row, the selection's version, how many sockets
	props:      bool,
	props_pid:  i32,
	props_start: u64,
	props_tab:  Props_Tab,
	props_gone: bool,
}

@(private = "file")
palette_can :: proc(app: ^App) -> Palette_Can {
	s, st, sk := &app.services, &app.startup, &app.connections.rows.table.vl
	sv, tv := &s.rows.table.vl, &st.rows.table.vl
	return {
		tab = app.tab, refreshes = app.refreshes, rows = app.rows_made, selection = {u64(app.vl.sel), app.vl.version},
		tree = app.table.tree, filtered = len(app.search.buf) > 0, paused = app.paused, updater = app.updater != nil,
		zoom = ui.zoom(&app.main.state),
		services = {u64(sv.sel), sv.version, u64(s.pending)}, services_list = s.list,
		details = service_details_shown(app), pane = s.pane.serial,
		startup = {u64(tv.sel), tv.version, st.pending ? 1 : 0}, startup_list = st.list,
		sockets = {u64(sk.sel), sk.version, u64(len(app.connections.sockets))},
		props = props_shown(app), props_pid = app.props.pid, props_start = app.props.start, props_tab = app.props.tab, props_gone = app.props.gone,
	}
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

// Whether the command can act now.
cmd_can :: proc(app: ^App, c: Cmd) -> bool {
	p := selected_proc(app)
	switch c {
	case .Shortcuts, .Filter, .Read_Again, .Light_Dark, .Settings, .Pause_Refresh, .Refresh_Speed, .Diagnose: return true
	case .Check_Updates: return app.updater != nil
	case .Zoom_In:    return ui.zoom(&app.main.state) < ui.ZOOM_MAX
	case .Zoom_Out:   return ui.zoom(&app.main.state) > ui.ZOOM_MIN
	case .Zoom_Reset: return ui.zoom(&app.main.state) != 1
	case .Clear_Filter: return len(app.search.buf) > 0
	case .Show_Mission_Control, .Show_Processes, .Show_Performance, .Show_Services, .Show_Startup, .Show_Connections, .Show_Information, .Next_Section, .Previous_Section: return true
	case .End_Task, .Kill, .End_Tree: return p != nil || len(app.vl.selected) > 0
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
	case .Raise_Priority, .Lower_Priority, .Set_Priority: return p != nil && selected_is_process(app)
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
		return props_shown(app) && find_proc(&app.sampler, app.props.pid, app.props.start) != nil
	case .Props_Filter: return props_shown(app) && props_tab_listed(app.props.tab)
	case .Props_Next_Tab, .Props_Previous_Tab, .Props_Close: return props_shown(app)
	}
	return false
}

cmd_run :: proc(app: ^App, c: Cmd) {
	switch c {
	case .Shortcuts:        shortcuts_open(app)
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
	case .Settings:         settings_toggle(app)
	case .Check_Updates:    update.check_now(app.updater); say(app, i18n.tr("Checking for updates…"))
	case .Diagnose:         diagnosis_open(app)
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
	case .Select_All:       select_all(app)
	case .Suspend:          suspend_selected(app)
	case .Properties:       props_selected(app)
	case .Open_Location:    if p := selected_proc(app); p != nil { open_location(app, p) }
	case .Copy_Command:     if p := selected_proc(app); p != nil { copy_command(app, p) }
	case .Default_Action:   default_action(app)
	case .Open_Group:       group_set(app, true)
	case .Close_Group:      group_set(app, false)
	case .Raise_Priority:   if p := selected_proc(app); p != nil { priority_step(app, p, -1) }
	case .Lower_Priority:   if p := selected_proc(app); p != nil { priority_step(app, p, 1) }
	// (without its form's value: the Properties, whose foot chooses the priority)
	case .Set_Priority:     props_selected(app)
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
	case .Props_Close:          ui.view_close(&app.views, PROPS_VIEW)
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
