package inspecteur

// Every action of the window, in one table (the toolkit's ui.Command): its name, its group and its keys. The keys are
// read here (commands_keys), and the same table gives the menus' and the tooltips' key texts (cmd_tip, cmd_item), the
// command palette (Ctrl+K, Ctrl+Shift+P: every action of the section shown and of the window, searched as you type) and
// the sheet of the keys (F1).
//
// A command of a section acts in that section only; one of the Window or Sections groups, wherever the window is. A
// command of the Properties group acts while the Properties dialog is open (props_view.odin reads its keys).

import "core:fmt"
import "core:strings"
import lucide "gt:lucide"
import "gt:ui"
import update "gt:update"

Cmd :: enum u8 {
	// Window
	Palette, Shortcuts, Filter, Clear_Filter, Read_Again, Pause_Refresh, Refresh_Speed, Zoom_In, Zoom_Out, Zoom_Reset,
	Light_Dark, Setup, Settings, Check_Updates, Diagnose,
	// Sections
	Show_Processes, Show_Performance, Show_Services, Show_Startup, Show_Connections, Show_Information, Next_Section, Previous_Section,
	// Processes
	End_Task, Kill, End_Tree, Select_All, Suspend, Properties, Open_Location, Copy_Command, Default_Action, Open_Group,
	Close_Group, Raise_Priority, Lower_Priority, Affinity, Go_To_Service, Dump, Search_Online, Tree_View, Columns, Summary, Pin,
	// Performance
	Cpu_Grid, Next_Device, Previous_Device,
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
	.Palette          = {icon = lucide.COMMAND, label = "Command palette", group = "Window", keys = {{.K, {.Ctrl}}, {.P, {.Ctrl, .Shift}}}},
	.Shortcuts        = {icon = lucide.KEYBOARD, label = "Keyboard shortcuts", group = "Window", keys = {{.F1, {}}, {}}},
	.Filter           = {icon = lucide.FILTER, label = "Filter", group = "Window", keys = {{.F, {.Ctrl}}, {}}},
	.Clear_Filter     = {icon = lucide.X, label = "Clear the filter", group = "Window", keys = {{.Escape, {}}, {}}},
	.Read_Again       = {icon = lucide.REFRESH_CW, label = "Read again", group = "Window", keys = {{.F5, {}}, {}}},
	.Pause_Refresh    = {icon = lucide.PAUSE, label = "Pause or resume the refresh", group = "Window", keys = {{.Space, {.Ctrl}}, {}}},
	.Refresh_Speed    = {icon = lucide.GAUGE, label = "Refresh speed…", group = "Window", keys = {{.R, {.Ctrl, .Shift}}, {}}},
	.Zoom_In          = {icon = lucide.ZOOM_IN, label = "Zoom in", group = "Window", keys = {{.Equal, {.Ctrl}}, {.Num_Add, {.Ctrl}}}},
	.Zoom_Out         = {icon = lucide.ZOOM_OUT, label = "Zoom out", group = "Window", keys = {{.Minus, {.Ctrl}}, {.Num_Subtract, {.Ctrl}}}},
	.Zoom_Reset       = {icon = lucide.SEARCH, label = "Zoom: 100 %", group = "Window", keys = {{.N0, {.Ctrl}}, {}}},
	.Light_Dark       = {icon = lucide.SUN_MOON, label = "Light or dark", group = "Window", keys = {{.L, {.Ctrl, .Shift}}, {}}},
	.Setup            = {icon = lucide.DOWNLOAD, label = "Install…", group = "Window", keys = {{.I, {.Ctrl, .Shift}}, {}}},
	.Settings         = {icon = lucide.SLIDERS_HORIZONTAL, label = "Settings", group = "Window", keys = {{.Comma, {.Ctrl}}, {}}},
	.Check_Updates    = {icon = lucide.HARD_DRIVE_DOWNLOAD, label = "Check for updates", group = "Window"},
	.Diagnose         = {icon = lucide.LIGHTBULB, label = "Why is it slow?", group = "Window", keys = {{.F2, {}}, {}}},

	.Show_Processes   = {icon = lucide.LAYOUT_LIST, label = "Processes", group = "Sections", keys = {{.N1, {.Ctrl}}, {}}},
	.Show_Performance = {icon = lucide.GAUGE, label = "Performance", group = "Sections", keys = {{.N2, {.Ctrl}}, {}}},
	.Show_Services    = {icon = lucide.SETTINGS, label = "Services", group = "Sections", keys = {{.N3, {.Ctrl}}, {}}},
	.Show_Startup     = {icon = lucide.POWER, label = "Startup", group = "Sections", keys = {{.N4, {.Ctrl}}, {}}},
	.Show_Connections = {icon = lucide.GLOBE, label = "Connections", group = "Sections", keys = {{.N5, {.Ctrl}}, {}}},
	.Show_Information = {icon = lucide.INFO, label = "Information", group = "Sections", keys = {{.N6, {.Ctrl}}, {}}},
	.Next_Section     = {icon = lucide.ARROW_RIGHT, label = "Next section", group = "Sections", keys = {{.Tab, {.Ctrl}}, {}}},
	.Previous_Section = {icon = lucide.ARROW_LEFT, label = "Previous section", group = "Sections", keys = {{.Tab, {.Ctrl, .Shift}}, {}}},

	.End_Task         = {icon = lucide.X, label = "End task", group = "Processes", keys = {{.Delete, {}}, {}}},
	.Kill             = {icon = lucide.ZAP, label = "Kill…", group = "Processes", keys = {{.Delete, {.Shift}}, {}}},
	.End_Tree         = {icon = lucide.LIST_TREE, label = "End process tree…", group = "Processes", keys = {{.Delete, {.Ctrl}}, {}}},
	.Select_All       = {icon = lucide.LIST_CHECKS, label = "Select all", group = "Processes", keys = {{.A, {.Ctrl}}, {}}},
	.Suspend          = {icon = lucide.PAUSE, label = "Suspend or resume", group = "Processes", keys = {{.P, {.Ctrl}}, {}}},
	.Properties       = {icon = lucide.INFO, label = "Properties", group = "Processes", keys = {{.Return, {.Alt}}, {}}},
	.Open_Location    = {icon = lucide.FOLDER_OPEN, label = "Open file location", group = "Processes", keys = {{.O, {.Ctrl}}, {}}},
	.Copy_Command     = {icon = lucide.COPY, label = "Copy command line", group = "Processes", keys = {{.C, {.Ctrl}}, {}}},
	.Default_Action   = {icon = lucide.PLAY, label = "Open the group, or Properties", group = "Processes", keys = {{.Return, {}}, {}}},
	.Open_Group       = {icon = lucide.CHEVRON_DOWN, label = "Open the group", group = "Processes", keys = {{.Right, {}}, {}}},
	.Close_Group      = {icon = lucide.CHEVRON_UP, label = "Close the group", group = "Processes", keys = {{.Left, {}}, {}}},
	.Raise_Priority   = {icon = lucide.ARROW_UP, label = "Raise the priority", group = "Processes", keys = {{.Up, {.Ctrl}}, {}}},
	.Lower_Priority   = {icon = lucide.ARROW_DOWN, label = "Lower the priority", group = "Processes", keys = {{.Down, {.Ctrl}}, {}}},
	.Affinity         = {icon = lucide.MICROCHIP, label = "Set affinity…", group = "Processes", keys = {{.A, {.Ctrl, .Shift}}, {}}},
	.Go_To_Service    = {icon = lucide.SERVER, label = "Go to service", group = "Processes", keys = {{.S, {.Ctrl, .Shift}}, {}}},
	.Dump             = {icon = lucide.SAVE, label = "Create dump file…", group = "Processes", keys = {{.D, {.Ctrl, .Shift}}, {}}},
	.Search_Online    = {icon = lucide.SEARCH, label = "Search online", group = "Processes", keys = {{.F, {.Ctrl, .Shift}}, {}}},
	.Tree_View        = {icon = lucide.FOLDER_TREE, label = "Process tree or apps", group = "Processes", keys = {{.T, {.Ctrl}}, {}}},
	.Columns          = {icon = lucide.COLUMNS_2, label = "Columns…", group = "Processes", keys = {{.C, {.Ctrl, .Shift}}, {}}},
	.Summary          = {icon = lucide.LAYOUT_GRID, label = "Show or hide the summary of the machine", group = "Processes", keys = {{.B, {.Ctrl}}, {}}},
	.Pin              = {icon = lucide.PIN, label = "Pin or unpin", group = "Processes", keys = {{.P, {.Alt}}, {}}},

	.Cpu_Grid         = {icon = lucide.LAYOUT_GRID, label = "One graph per logical processor", group = "Performance", keys = {{.G, {.Ctrl}}, {}}},
	.Next_Device      = {icon = lucide.ARROW_DOWN, label = "Next device", group = "Performance", keys = {{.Down, {}}, {}}},
	.Previous_Device  = {icon = lucide.ARROW_UP, label = "Previous device", group = "Performance", keys = {{.Up, {}}, {}}},

	.Service_Start    = {icon = lucide.PLAY, label = "Start", group = "Services", keys = {{.S, {.Ctrl}}, {}}},
	.Service_Stop     = {icon = lucide.SQUARE, label = "Stop", group = "Services", keys = {{.Delete, {}}, {}}},
	.Service_Restart  = {icon = lucide.ROTATE_CCW, label = "Restart", group = "Services", keys = {{.R, {.Ctrl}}, {}}},
	.Service_Enable   = {icon = lucide.CHECK, label = "Enable", group = "Services", keys = {{.E, {.Ctrl}}, {}}},
	.Service_Disable  = {icon = lucide.X, label = "Disable", group = "Services", keys = {{.D, {.Ctrl}}, {}}},
	.Service_Open     = {icon = lucide.LAYOUT_LIST, label = "Open in Processes", group = "Services", keys = {{.Return, {}}, {}}},
	.Service_Copy     = {icon = lucide.COPY, label = "Copy name", group = "Services", keys = {{.C, {.Ctrl}}, {}}},
	.Service_Details  = {icon = lucide.PANEL_BOTTOM, label = "Details and journal", group = "Services", keys = {{.I, {.Ctrl}}, {}}},
	.Service_Open_File = {icon = lucide.FILE_TEXT, label = "Open unit file", group = "Services", keys = {{.O, {.Ctrl}}, {}}},
	.Service_Manager  = {icon = lucide.USER, label = "System or user services", group = "Services", keys = {{.U, {.Ctrl}}, {}}},
	.Journal_Search   = {icon = lucide.SEARCH, label = "Search the journal", group = "Services", keys = {{.J, {.Ctrl}}, {}}},
	.Journal_Level    = {icon = lucide.FILTER, label = "Journal: all, warnings, errors", group = "Services", keys = {{.L, {.Alt}}, {}}},
	.Journal_Boot     = {icon = lucide.POWER, label = "Journal: this boot or every boot", group = "Services", keys = {{.B, {.Alt}}, {}}},
	.Journal_Follow   = {icon = lucide.ARROW_DOWN, label = "Follow the journal", group = "Services", keys = {{.F, {.Alt}}, {}}},
	.Journal_Copy     = {icon = lucide.COPY, label = "Copy the journal's entries shown", group = "Services", keys = {{.C, {.Alt}}, {}}},
	.Journal_Copy_Entry = {icon = lucide.CLIPBOARD_COPY, label = "Copy the journal's entry", group = "Services", keys = {{.C, {.Alt, .Shift}}, {}}},
	.Journal_Window   = {icon = lucide.EXTERNAL_LINK, label = "The journal in its own window", group = "Services", keys = {{.J, {.Ctrl, .Shift}}, {}}},

	.Startup_Enable   = {icon = lucide.CHECK, label = "Enable", group = "Startup", keys = {{.E, {.Ctrl}}, {}}},
	.Startup_Disable  = {icon = lucide.X, label = "Disable", group = "Startup", keys = {{.D, {.Ctrl}}, {}}},
	.Startup_Toggle   = {icon = lucide.ARROW_UP_DOWN, label = "Enable or disable", group = "Startup", keys = {{.Space, {}}, {}}},
	.Startup_Open     = {icon = lucide.FOLDER_OPEN, label = "Open file location", group = "Startup", keys = {{.Return, {}}, {}}},
	.Startup_Copy     = {icon = lucide.COPY, label = "Copy command", group = "Startup", keys = {{.C, {.Ctrl}}, {}}},

	.Socket_End_Task  = {icon = lucide.X, label = "End task", group = "Connections", keys = {{.Delete, {}}, {}}},
	.Socket_Kill      = {icon = lucide.ZAP, label = "Kill…", group = "Connections", keys = {{.Delete, {.Shift}}, {}}},
	.Socket_Open      = {icon = lucide.LAYOUT_LIST, label = "Open in Processes", group = "Connections", keys = {{.Return, {}}, {}}},
	.Socket_Copy      = {icon = lucide.COPY, label = "Copy address", group = "Connections", keys = {{.C, {.Ctrl}}, {}}},

	.Info_Copy        = {icon = lucide.COPY, label = "Copy all", group = "Information", keys = {{.C, {.Ctrl}}, {}}},

	.Props_Suspend        = {icon = lucide.PAUSE, label = "Suspend or resume", group = "Properties", keys = {{.P, {.Ctrl}}, {}}},
	.Props_End_Task       = {icon = lucide.X, label = "End task", group = "Properties", keys = {{.Delete, {}}, {}}},
	.Props_Kill           = {icon = lucide.ZAP, label = "Kill…", group = "Properties", keys = {{.Delete, {.Shift}}, {}}},
	.Props_Raise_Priority = {icon = lucide.ARROW_UP, label = "Raise the priority", group = "Properties", keys = {{.Up, {.Ctrl}}, {}}},
	.Props_Lower_Priority = {icon = lucide.ARROW_DOWN, label = "Lower the priority", group = "Properties", keys = {{.Down, {.Ctrl}}, {}}},
	.Props_Affinity       = {icon = lucide.MICROCHIP, label = "Set affinity…", group = "Properties", keys = {{.A, {.Ctrl, .Shift}}, {}}},
	.Props_Filter         = {icon = lucide.FILTER, label = "Filter the list", group = "Properties", keys = {{.F, {.Ctrl}}, {}}},
	.Props_Next_Tab       = {icon = lucide.ARROW_RIGHT, label = "Next tab", group = "Properties", keys = {{.Tab, {.Ctrl}}, {}}},
	.Props_Previous_Tab   = {icon = lucide.ARROW_LEFT, label = "Previous tab", group = "Properties", keys = {{.Tab, {.Ctrl, .Shift}}, {}}},
	.Props_Close          = {icon = lucide.X, label = "Close", group = "Properties", keys = {{.Escape, {}}, {}}},
}

// The section a command acts in (nil: everywhere).
cmd_tab :: proc(c: Cmd) -> Maybe(Tab) {
	switch {
	case c <= .Previous_Section:                   return nil
	case c <= .Pin:                                return .Processes   // (the last command of Processes)
	case c <= .Previous_Device:                    return .Performance
	case c <= .Journal_Window:                     return .Services
	case c <= .Startup_Copy:                       return .Startup
	case c <= .Socket_Copy:                        return .Connections
	case c == .Info_Copy:                          return .Information
	}
	return nil
}

cmd_is_props :: proc(c: Cmd) -> bool { return c >= .Props_Suspend }

// "Kill… (Shift+Delete)": a button's tooltip.
cmd_tip :: proc(c: Cmd) -> string { return ui.command_tip(COMMANDS[c]) }

// A menu's line of the command: its label, its key, greyed when it cannot act; clicked: it is run.
cmd_item :: proc(app: ^App, c: Cmd, label := "") {
	if ui.menu_item(label != "" ? label : COMMANDS[c].label, ui.command_shortcut(COMMANDS[c]), enabled = cmd_can(app, c)).clicked { cmd_run(app, c) }
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
			// (the filter keeps Space while it has the keyboard: a space in a name)
			for &ch in cmd.keys {
				if ch.key == .Space && ui.focus_key() == app.search_key { ch = {} }
				if field_keeps && editing_chord(ch) { ch = {} }
			}
		}
		if ui.command_pressed(cmd, cmd_can(app, c)) { cmd_run(app, c) }
	}
}

// Opens the command palette.
palette_open :: proc(app: ^App) { ui.palette_open(&app.palette) }

// The palette while it is open: the commands of the window, of the sections, and of the section shown. Its size, when the
// user changes it, is kept (view.palette_size).
palette_build :: proc(app: ^App) {
	if !app.palette.open { return }
	list := make([dynamic]ui.Command, context.temp_allocator)
	cmds := make([dynamic]Cmd, context.temp_allocator)
	enabled := make([dynamic]bool, context.temp_allocator)
	for c in Cmd {
		if cmd_is_props(c) || c == .Palette { continue }
		if t, ok := cmd_tab(c).?; ok && t != app.tab { continue }
		append(&list, COMMANDS[c])
		append(&cmds, c)
		append(&enabled, cmd_can(app, c))
	}
	i, resized := ui.palette(&app.palette, list[:], enabled[:])
	if resized { pref_save(&app.prefs, "view.palette_size", fmt.tprintf("%.0f %.0f", app.palette.size.x, app.palette.size.y)) }
	if i >= 0 { cmd_run(app, cmds[i]) }
}

// The sheet of the keys while it is open: every command, its section's first.
shortcuts_build :: proc(app: ^App) {
	list := make([dynamic]ui.Command, context.temp_allocator)
	for c in Cmd { if cmd_tab(c) == nil && !cmd_is_props(c) { append(&list, COMMANDS[c]) } }
	for c in Cmd { if _, ok := cmd_tab(c).?; ok { append(&list, COMMANDS[c]) } }
	for c in Cmd { if cmd_is_props(c) { append(&list, COMMANDS[c]) } }
	ui.shortcuts_sheet("shortcuts", list[:], &app.shortcuts_open)
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
	case .Show_Processes, .Show_Performance, .Show_Services, .Show_Startup, .Show_Connections, .Show_Information, .Next_Section, .Previous_Section: return true
	case .End_Task, .Kill, .End_Tree: return p != nil || ui.list_mark_count(&app.vl) > 0
	case .Select_All: return len(app.table.rows) > 0
	case .Properties, .Search_Online: return p != nil
	case .Affinity: return p != nil && selected_is_process(app)
	case .Go_To_Service: return p != nil && selected_is_process(app) && p.unit != ""
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
	case .Shortcuts:        app.shortcuts_open = true
	// (its text selected: what is typed then replaces it, as in a browser's Ctrl+F)
	case .Filter:           if app.search_key != 0 { ui.set_focus(app.search_key); ui.field_select_all(&app.search) }
	case .Clear_Filter:     ui.field_clear(&app.search)
	case .Read_Again:       refresh_now(app)
	case .Pause_Refresh:    refresh_pause(app, !app.paused)
	case .Refresh_Speed:    refresh_menu_open(app)
	case .Zoom_In:          ui.set_zoom(&app.main.state, ui.zoom(&app.main.state) * ui.ZOOM_STEP)
	case .Zoom_Out:         ui.set_zoom(&app.main.state, ui.zoom(&app.main.state) / ui.ZOOM_STEP)
	case .Zoom_Reset:       ui.set_zoom(&app.main.state, 1)
	case .Light_Dark:       light_dark_switch(app)
	case .Setup:            setup_open(app)
	case .Settings:         settings_toggle(app)
	case .Check_Updates:    update.check_now(app.updater); say(app, "Checking for updates…")
	case .Diagnose:         app.diagnosis_open = true
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
	case .Dump:             if p := selected_proc(app); p != nil { dump_ask(app, p) }
	case .Search_Online:    search_online(app)
	case .Tree_View:        tree_view_switch(app)
	case .Columns:          columns_menu_open(app)
	case .Summary:          summary_switch(app)
	case .Pin:              pin_switch(app)
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
	switch app.settings.mode {
	case .Light:  mode = .Dark
	case .Dark:   mode = .Light
	case .System: mode = app.theme_shown.light ? .Dark : .Light
	}
	mode_set(app, mode)
}

// The theme a light or dark choice moves to when the theme shown has one version only: the nearest of those that have
// both (graphite, silver).
THEME_OF_BOTH :: "Silver"

// Sets the theme's version (written to the preferences). A theme that has no such version (Graphite is dark only) gives
// way to THEME_OF_BOTH: the choice is seen, and the footer says why the theme changed.
mode_set :: proc(app: ^App, mode: ui.Theme_Mode) {
	app.settings.mode = mode
	pref_save(&app.prefs, "view.mode", THEME_MODE_KEYS[mode])
	def, _, ok := ui.theme_find(ui.THEMES[:], app.settings.theme)
	lacks := ok && (def.versions == .Dark_Only && mode == .Light || def.versions == .Light_Only && mode == .Dark)
	if lacks {
		old := app.settings.theme
		app.settings.theme = strings.clone(THEME_OF_BOTH)
		pref_save(&app.prefs, "view.theme", THEME_OF_BOTH)
		say(app, "%s colours: %s has no %s version, %s has", mode == .Light ? "Light" : "Dark", old, mode == .Light ? "light" : "dark", THEME_OF_BOTH)
		delete(old)
		return
	}
	#partial switch mode {
	case .Light: say(app, "Light colours")
	case .Dark:  say(app, "Dark colours")
	case:        say(app, "Colours as the system's")
	}
}

// A tooltip after the pointer rests on `sig`: `text`.
tip_after :: proc(sig: ui.Signal, text: string) {
	if text == "" || !ui.hovered_for(sig, TIP_DELAY_S) { return }
	if ui.tooltip() {
		ui.next({width = ui.text_size(ui.font_size() * 0.6), height = ui.px(ui.dense(ui.font_size() * 1.8))})
		ui.label(fmt.tprintf("%s###tip", text))
	}
}

// How long the pointer rests on a control before its tooltip shows.
TIP_DELAY_S :: 0.4
