package inspecteur

// Windows commands, palette arguments, and dispatch:
// Native Windows operations (Efficiency Mode / EcoQoS, Wait Chain analysis, SCM Pause/Continue/Startup type,
// Windows Event Log, StartupApproved, Copy registry/file location) without POSIX signals or systemd commands.

import "core:fmt"
import config "gt:config"
import i18n "gt:i18n"
import lucide "gt:lucide"
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
	Close_Group, Raise_Priority, Lower_Priority, Set_Priority, Affinity, Efficiency_Mode, Wait_Chain, Show_Window, Go_To_Service, Dump, Search_Online, Tree_View, Columns, Summary, Pin,
	// Performance
	Cpu_Grid, Next_Device, Previous_Device,
	// Mission Control
	Mission_Panels, Mission_Reset,
	// Services (SCM + Event Log)
	Service_Start, Service_Stop, Service_Restart, Service_Pause, Service_Continue, Service_Startup_Type, Service_Filter,
	Service_Open, Service_Open_Binary, Service_Copy, Service_Details,
	EventLog_Search, EventLog_Level, EventLog_Follow, EventLog_Copy, EventLog_Window,
	// Startup
	Startup_Enable, Startup_Disable, Startup_Toggle, Startup_Open, Startup_Copy, Startup_Copy_Location,
	// Connections
	Socket_End_Task, Socket_Kill, Socket_Open, Socket_Copy,
	// Information
	Info_Copy,
	// Properties (the dialog)
	Props_Suspend, Props_End_Task, Props_Kill, Props_Raise_Priority, Props_Lower_Priority, Props_Affinity, Props_Efficiency, Props_Filter,
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
	.Kill             = {id = "kill", icon = lucide.ZAP, label = i18n.later("Kill…"), group = i18n.later("Processes"), keys = {{.Delete, {.Shift}}}, tags = {"force", "terminate"}},
	.End_Tree         = {id = "end_tree", icon = lucide.LIST_TREE, label = i18n.later("End process tree…"), group = i18n.later("Processes"), keys = {{.Delete, {.Ctrl}}}, tags = {"kill", "children"}},
	.Select_All       = {id = "select_all", icon = lucide.LIST_CHECKS, label = i18n.later("Select all"), group = i18n.later("Processes"), keys = {{.A, {.Ctrl}}}},
	.Suspend          = {id = "suspend", icon = lucide.PAUSE, label = i18n.later("Suspend or resume"), group = i18n.later("Processes"), keys = {{.P, {.Ctrl}}}, tags = {"pause", "freeze", "suspend", "resume"}},
	.Properties       = {id = "properties", icon = lucide.INFO, label = i18n.later("Properties"), group = i18n.later("Processes"), keys = {{.Return, {.Alt}}}, tags = {"details", "handles", "threads", "modules", "security"}},
	.Open_Location    = {id = "open_location", icon = lucide.FOLDER_OPEN, label = i18n.later("Open file location"), group = i18n.later("Processes"), keys = {{.O, {.Ctrl}}}, tags = {"folder", "executable", "explorer"}},
	.Copy_Command     = {id = "copy_command", icon = lucide.COPY, label = i18n.later("Copy command line"), group = i18n.later("Processes"), keys = {{.C, {.Ctrl}}}},
	.Default_Action   = {id = "default_action", icon = lucide.PLAY, label = i18n.later("Open the group, or Properties"), group = i18n.later("Processes"), keys = {{.Return, {}}}},
	.Open_Group       = {id = "open_group", icon = lucide.CHEVRON_DOWN, label = i18n.later("Open the group"), group = i18n.later("Processes"), keys = {{.Right, {}}}},
	.Close_Group      = {id = "close_group", icon = lucide.CHEVRON_UP, label = i18n.later("Close the group"), group = i18n.later("Processes"), keys = {{.Left, {}}}},
	.Raise_Priority   = {id = "raise_priority", icon = lucide.ARROW_UP, label = i18n.later("Raise the priority"), group = i18n.later("Processes"), keys = {{.Up, {.Ctrl}}}, tags = {"priority", "high"}},
	.Lower_Priority   = {id = "lower_priority", icon = lucide.ARROW_DOWN, label = i18n.later("Lower the priority"), group = i18n.later("Processes"), keys = {{.Down, {.Ctrl}}}, tags = {"priority", "idle", "background"}},
	.Set_Priority     = {id = "set_priority", icon = lucide.ARROW_UP_DOWN, label = i18n.later("Set the priority"), group = i18n.later("Processes"), tags = {"priority", "high", "normal", "idle"}, arguments = PRIORITY_ARGUMENTS[:]},
	.Affinity         = {id = "affinity", icon = lucide.MICROCHIP, label = i18n.later("Set affinity…"), group = i18n.later("Processes"), keys = {{.A, {.Ctrl, .Shift}}}, tags = {"cpu", "cores", "pin"}},
	.Efficiency_Mode  = {id = "efficiency_mode", icon = lucide.LEAF, label = i18n.later("Efficiency mode (EcoQoS)"), group = i18n.later("Processes"), keys = {{.E, {.Alt}}}, tags = {"ecoqos", "power", "throttle", "efficiency"}},
	.Wait_Chain       = {id = "wait_chain", icon = lucide.LINK, label = i18n.later("Analyze wait chain"), group = i18n.later("Processes"), keys = {{.W, {.Alt}}}, tags = {"deadlock", "hang", "threads", "wct"}},
	.Show_Window      = {id = "show_window", icon = lucide.APP_WINDOW, label = i18n.later("Show its window"), group = i18n.later("Processes"), keys = {{.W, {.Ctrl, .Shift}}}, tags = {"window", "focus", "switch", "front"}},
	.Go_To_Service    = {id = "go_to_service", icon = lucide.SERVER, label = i18n.later("Go to service"), group = i18n.later("Processes"), keys = {{.S, {.Ctrl, .Shift}}}},
	.Dump             = {id = "dump", icon = lucide.SAVE, label = i18n.later("Create dump file…"), group = i18n.later("Processes"), keys = {{.D, {.Ctrl, .Shift}}}, tags = {"minidump", "dmp", "debug"}},
	.Search_Online    = {id = "search_online", icon = lucide.SEARCH, label = i18n.later("Search online"), group = i18n.later("Processes"), keys = {{.F, {.Ctrl, .Shift}}}, tags = {"web", "what is"}},
	.Tree_View        = {id = "tree_view", icon = lucide.FOLDER_TREE, label = i18n.later("Process tree or apps"), group = i18n.later("Processes"), keys = {{.T, {.Ctrl}}}, tags = {"parent", "hierarchy"}},
	.Columns          = {id = "columns", icon = lucide.COLUMNS_2, label = i18n.later("Columns…"), group = i18n.later("Processes"), keys = {{.C, {.Ctrl, .Shift}}}, tags = {"show", "hide", "fields"}},
	.Summary          = {id = "summary", icon = lucide.LAYOUT_GRID, label = i18n.later("Show or hide the summary of the machine"), group = i18n.later("Processes"), keys = {{.B, {.Ctrl}}}},
	.Pin              = {id = "pin", icon = lucide.PIN, label = i18n.later("Pin or unpin"), group = i18n.later("Processes"), keys = {{.P, {.Alt}}}, tags = {"favourite", "top", "keep"}},

	.Mission_Panels   = {id = "mission_panels", icon = lucide.LAYOUT_GRID, label = i18n.later("Mission Control: panels…"), group = i18n.later("Mission Control")},
	.Mission_Reset    = {id = "mission_reset", icon = lucide.ROTATE_CCW, label = i18n.later("Mission Control: the layout as at first"), group = i18n.later("Mission Control")},
	.Cpu_Grid         = {id = "cpu_grid", icon = lucide.LAYOUT_GRID, label = i18n.later("One graph per logical processor"), group = i18n.later("Performance"), keys = {{.G, {.Ctrl}}}},
	.Next_Device      = {id = "next_device", icon = lucide.ARROW_DOWN, label = i18n.later("Next device"), group = i18n.later("Performance"), keys = {{.Down, {}}}},
	.Previous_Device  = {id = "previous_device", icon = lucide.ARROW_UP, label = i18n.later("Previous device"), group = i18n.later("Performance"), keys = {{.Up, {}}}},

	.Service_Start        = {id = "service_start", icon = lucide.PLAY, label = i18n.later("Start"), group = i18n.later("Services"), keys = {{.S, {.Ctrl}}}, tags = {"scm", "run"}},
	.Service_Stop         = {id = "service_stop", icon = lucide.SQUARE, label = i18n.later("Stop"), group = i18n.later("Services"), keys = {{.Delete, {}}}, tags = {"scm", "stop"}},
	.Service_Restart      = {id = "service_restart", icon = lucide.ROTATE_CCW, label = i18n.later("Restart"), group = i18n.later("Services"), keys = {{.R, {.Ctrl}}}, tags = {"scm", "restart"}},
	.Service_Pause        = {id = "service_pause", icon = lucide.PAUSE, label = i18n.later("Pause"), group = i18n.later("Services"), keys = {{.P, {.Ctrl}}}, tags = {"scm", "pause"}},
	.Service_Continue     = {id = "service_continue", icon = lucide.STEP_FORWARD, label = i18n.later("Continue"), group = i18n.later("Services"), keys = {{.P, {.Alt}}}, tags = {"scm", "resume"}},
	.Service_Startup_Type = {id = "service_startup_type", icon = lucide.SLIDERS_HORIZONTAL, label = i18n.later("Startup type…"), group = i18n.later("Services"), keys = {{.E, {.Ctrl}}}, tags = {"automatic", "manual", "disabled", "delayed"}, arguments = STARTUP_TYPE_ARGUMENTS[:]},
	.Service_Filter       = {id = "service_filter", icon = lucide.FILTER, label = i18n.later("Services, shared (svchost), or drivers"), group = i18n.later("Services"), keys = {{.U, {.Ctrl}}}, tags = {"svchost", "drivers"}},
	.Service_Open         = {id = "service_open", icon = lucide.LAYOUT_LIST, label = i18n.later("Open in Processes"), group = i18n.later("Services"), keys = {{.Return, {}}}},
	.Service_Open_Binary  = {id = "service_open_binary", icon = lucide.FOLDER_OPEN, label = i18n.later("Open binary location"), group = i18n.later("Services"), keys = {{.O, {.Ctrl}}}},
	.Service_Copy         = {id = "service_copy", icon = lucide.COPY, label = i18n.later("Copy name"), group = i18n.later("Services"), keys = {{.C, {.Ctrl}}}},
	.Service_Details      = {id = "service_details", icon = lucide.PANEL_BOTTOM, label = i18n.later("Details and Event Log"), group = i18n.later("Services"), keys = {{.I, {.Ctrl}}}, tags = {"eventlog", "dependencies"}},
	.EventLog_Search      = {id = "eventlog_search", icon = lucide.SEARCH, label = i18n.later("Search Event Log"), group = i18n.later("Services"), keys = {{.J, {.Ctrl}}}},
	.EventLog_Level       = {id = "eventlog_level", icon = lucide.FILTER, label = i18n.later("Event Log: all, warnings, errors"), group = i18n.later("Services"), keys = {{.L, {.Alt}}}},
	.EventLog_Follow      = {id = "eventlog_follow", icon = lucide.ARROW_DOWN, label = i18n.later("Follow Event Log"), group = i18n.later("Services"), keys = {{.F, {.Alt}}}},
	.EventLog_Copy        = {id = "eventlog_copy", icon = lucide.COPY, label = i18n.later("Copy Event Log entries shown"), group = i18n.later("Services"), keys = {{.C, {.Alt}}}},
	.EventLog_Window      = {id = "eventlog_window", icon = lucide.EXTERNAL_LINK, label = i18n.later("Event Log in its own window"), group = i18n.later("Services"), keys = {{.J, {.Ctrl, .Shift}}}},

	.Startup_Enable        = {id = "startup_enable", icon = lucide.CHECK, label = i18n.later("Enable"), group = i18n.later("Startup"), keys = {{.E, {.Ctrl}}}},
	.Startup_Disable       = {id = "startup_disable", icon = lucide.X, label = i18n.later("Disable"), group = i18n.later("Startup"), keys = {{.D, {.Ctrl}}}},
	.Startup_Toggle        = {id = "startup_toggle", icon = lucide.ARROW_UP_DOWN, label = i18n.later("Enable or disable"), group = i18n.later("Startup"), keys = {{.Space, {}}}, tags = {"startupapproved", "registry"}},
	.Startup_Open          = {id = "startup_open", icon = lucide.FOLDER_OPEN, label = i18n.later("Open file location"), group = i18n.later("Startup"), keys = {{.Return, {}}}},
	.Startup_Copy          = {id = "startup_copy", icon = lucide.COPY, label = i18n.later("Copy command"), group = i18n.later("Startup"), keys = {{.C, {.Ctrl}}}},
	.Startup_Copy_Location = {id = "startup_copy_location", icon = lucide.MAP_PIN, label = i18n.later("Copy location"), group = i18n.later("Startup"), keys = {{.L, {.Ctrl}}}},

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
	.Props_Efficiency     = {id = "props_efficiency", icon = lucide.LEAF, label = i18n.later("Efficiency mode (EcoQoS)"), group = i18n.later("Properties"), keys = {{.E, {.Alt}}}},
	.Props_Filter         = {id = "props_filter", icon = lucide.FILTER, label = i18n.later("Filter the list"), group = i18n.later("Properties"), keys = {{.F, {.Ctrl}}}},
	.Props_Next_Tab       = {id = "props_next_tab", icon = lucide.ARROW_RIGHT, label = i18n.later("Next tab"), group = i18n.later("Properties"), keys = {{.Tab, {.Ctrl}}}},
	.Props_Previous_Tab   = {id = "props_previous_tab", icon = lucide.ARROW_LEFT, label = i18n.later("Previous tab"), group = i18n.later("Properties"), keys = {{.Tab, {.Ctrl, .Shift}}}},
	.Props_Close          = {id = "props_close", icon = lucide.X, label = i18n.later("Close"), group = i18n.later("Properties"), keys = {{.Escape, {}}}},
}

PRIORITY_ARGUMENTS     := [?]config.Def{{name = "priority", title = i18n.later("Priority"), kind = .String, default = {s = "0"}}}
REFRESH_ARGUMENTS      := [?]config.Def{{name = "period", title = i18n.later("Refresh every"), kind = .String, default = {s = "1000"}}}
STARTUP_TYPE_ARGUMENTS := [?]config.Def{{name = "startup_type", title = i18n.later("Startup type"), kind = .String, default = {s = "manual"}}}

command_choices :: proc(user: rawptr, index: int, argument: string) -> (labels, values: []string) {
	switch argument {
	case "priority":
		labels, values = make([]string, len(PRIORITIES), context.temp_allocator), make([]string, len(PRIORITIES), context.temp_allocator)
		for q, i in PRIORITIES { labels[i], values[i] = q.name, fmt.tprintf("%d", q.nice) }
	case "period":
		labels, values = make([]string, len(REFRESH_SPEEDS), context.temp_allocator), make([]string, len(REFRESH_SPEEDS), context.temp_allocator)
		for sp, i in REFRESH_SPEEDS { labels[i], values[i] = sp.name, fmt.tprintf("%d", sp.ms) }
	case "startup_type":
		labels, values = make([]string, len(WIN_EDITABLE_STARTUPS), context.temp_allocator), make([]string, len(WIN_EDITABLE_STARTUPS), context.temp_allocator)
		for st, i in WIN_EDITABLE_STARTUPS {
			labels[i] = WIN_STARTUP_TYPE_LABELS[st]
			values[i] = WIN_STARTUP_TYPE_KEYS[st]
		}
	}
	return
}

cmd_run_with :: proc(app: ^App, c: Cmd, arguments: []string) {
	if len(arguments) == 0 || len(COMMANDS[c].arguments) == 0 { cmd_run(app, c); return }
	if !cmd_can(app, c) { return }
	value := arguments[0]
	#partial switch c {
	case .Set_Priority:
		p := selected_proc(app)
		if p == nil || !selected_is_process(app) { return }
		for q in PRIORITIES { if fmt.tprintf("%d", q.nice) == value { set_priority(app, p, q.nice); return } }
	case .Refresh_Speed:
		for sp in REFRESH_SPEEDS { if fmt.tprintf("%d", sp.ms) == value { refresh_speed_set(app, sp.ms); return } }
	case .Service_Startup_Type:
		for st in WIN_EDITABLE_STARTUPS {
			if WIN_STARTUP_TYPE_KEYS[st] == value { service_set_startup_selected(app, st); return }
		}
	case:
		cmd_run(app, c)
	}
}

cmd_tab :: proc(c: Cmd) -> Maybe(Tab) {
	switch {
	case c <= .Previous_Section:      return nil
	case c <= .Pin:                   return .Processes
	case c <= .Previous_Device:       return .Performance
	case c <= .Mission_Reset:         return .Mission_Control
	case c <= .EventLog_Window:       return .Services
	case c <= .Startup_Copy_Location: return .Startup
	case c <= .Socket_Copy:           return .Connections
	case c == .Info_Copy:             return .Information
	}
	return nil
}

cmd_is_props :: proc(c: Cmd) -> bool { return c >= .Props_Suspend }

Palette_Can :: struct {
	tab:           Tab,
	refreshes:     int,
	rows:          int,
	selection:     [2]u64,
	tree, filtered, paused, updater: bool,
	zoom:          f32,
	services:      [3]u64,
	services_list: rawptr,
	details:       bool,
	event_serial:  int,
	startup:       [3]u64,
	startup_list:  rawptr,
	sockets:       [3]u64,
	props:         bool,
	props_pid:     i32,
	props_start:   u64,
	props_tab:     Props_Tab,
	props_gone:    bool,
}

palette_can :: proc(app: ^App) -> Palette_Can {
	s, st, sk := &app.services, &app.startup, &app.connections.rows.table.vl
	sv, tv := &s.rows.table.vl, &st.rows.table.vl
	return {
		tab = app.tab, refreshes = app.refreshes, rows = app.rows_made, selection = {u64(app.vl.sel), app.vl.version},
		tree = app.table.tree, filtered = len(app.search.buf) > 0, paused = app.paused, updater = app.updates.updater != nil,
		zoom = ui.zoom(&app.main.state),
		services = {u64(sv.sel), sv.version, u64(s.pending)}, services_list = s.list,
		details = service_details_shown(app), event_serial = s.event_serial,
		startup = {u64(tv.sel), tv.version, st.pending ? 1 : 0}, startup_list = st.list,
		sockets = {u64(sk.sel), sk.version, u64(len(app.connections.sockets))},
		props = props_shown(app), props_pid = app.props.pid, props_start = app.props.start, props_tab = app.props.tab, props_gone = app.props.gone,
	}
}

cmd_can :: proc(app: ^App, c: Cmd) -> bool {
	p := selected_proc(app)
	switch c {
	case .Shortcuts, .Filter, .Read_Again, .Light_Dark, .Settings, .Pause_Refresh, .Refresh_Speed, .Diagnose: return true
	case .Check_Updates: return app.updates.updater != nil
	case .Zoom_In:       return ui.zoom(&app.main.state) < ui.ZOOM_MAX
	case .Zoom_Out:      return ui.zoom(&app.main.state) > ui.ZOOM_MIN
	case .Zoom_Reset:    return ui.zoom(&app.main.state) != 1
	case .Clear_Filter:  return len(app.search.buf) > 0
	case .Show_Mission_Control, .Show_Processes, .Show_Performance, .Show_Services, .Show_Startup, .Show_Connections, .Show_Information, .Next_Section, .Previous_Section: return true
	case .End_Task, .Kill, .End_Tree: return p != nil || len(app.vl.selected) > 0
	case .Select_All:    return len(app.table.rows) > 0
	case .Properties, .Search_Online: return p != nil
	case .Affinity, .Efficiency_Mode, .Wait_Chain, .Dump, .Suspend, .Raise_Priority, .Lower_Priority, .Set_Priority:
		return p != nil && selected_is_process(app)
	case .Go_To_Service: return p != nil && selected_is_process(app) && proc_has_service(p)
	case .Show_Window:   r, ok := selected_row(app); return ok && len(windows_of(app, row_entry(app, r))) > 0
	case .Tree_View:     return true
	case .Pin:           return pin_name(app) != "" && !app.table.tree
	case .Open_Location: return p != nil && p.exe != ""
	case .Copy_Command:  return p != nil && p.cmdline != ""
	case .Default_Action: return p != nil
	case .Open_Group, .Close_Group: return group_can_toggle(app, c == .Open_Group)
	case .Columns, .Summary: return true
	case .Cpu_Grid, .Next_Device, .Previous_Device: return true
	case .Mission_Panels, .Mission_Reset: return true
	case .Service_Start, .Service_Stop, .Service_Restart, .Service_Pause, .Service_Continue, .Service_Startup_Type, .Service_Open, .Service_Open_Binary, .Service_Copy:
		return service_can(app, c)
	case .Service_Details, .Service_Filter: return true
	case .EventLog_Search, .EventLog_Level, .EventLog_Follow, .EventLog_Copy, .EventLog_Window:
		return eventlog_can(app, c)
	case .Startup_Enable, .Startup_Disable, .Startup_Toggle, .Startup_Open, .Startup_Copy, .Startup_Copy_Location:
		return startup_can(app, c)
	case .Socket_End_Task, .Socket_Kill, .Socket_Open:
		s, ok := selected_socket(app)
		return ok && s.pid > 0
	case .Socket_Copy:
		_, ok := selected_socket(app)
		return ok
	case .Info_Copy: return true
	case .Props_Suspend, .Props_End_Task, .Props_Kill, .Props_Raise_Priority, .Props_Lower_Priority, .Props_Affinity, .Props_Efficiency:
		return props_shown(app) && find_proc(&app.sampler, app.props.pid, app.props.start) != nil
	case .Props_Filter: return props_shown(app) && props_tab_listed(app.props.tab)
	case .Props_Next_Tab, .Props_Previous_Tab, .Props_Close: return props_shown(app)
	}
	return false
}

cmd_run :: proc(app: ^App, c: Cmd) {
	switch c {
	case .Shortcuts:        shortcuts_open(app)
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
	case .Check_Updates:    update.check_now(app.updates.updater); say(app, i18n.tr("Checking for updates…"))
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
	case .Set_Priority:     props_selected(app)
	case .Affinity:         if p := selected_proc(app); p != nil { affinity_open(app, p) }
	case .Efficiency_Mode:  if p := selected_proc(app); p != nil { efficiency_toggle(app, p) }
	case .Wait_Chain:       if p := selected_proc(app); p != nil { wait_chain_open(app, p) }
	case .Go_To_Service:    if p := selected_proc(app); p != nil { go_to_service(app, p) }
	case .Show_Window:      if r, ok := selected_row(app); ok { window_show(app, row_entry(app, r)) }
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
	case .Service_Pause:    service_do(app, .Pause)
	case .Service_Continue: service_do(app, .Continue)
	case .Service_Startup_Type: ui.menu_open(STARTUP_TYPE_MENU, ui.mouse_pos())
	case .Service_Filter:   services_filter_switch(app, Win_Service_Filter((int(app.services.filter) + 1) % len(Win_Service_Filter)))
	case .Service_Open:     service_reveal(app)
	case .Service_Open_Binary: service_open_binary(app)
	case .Service_Copy:     service_copy(app)
	case .Service_Details:  service_details_switch(app)
	case .EventLog_Search, .EventLog_Level, .EventLog_Follow, .EventLog_Copy, .EventLog_Window:
		eventlog_run(app, c)
	case .Startup_Enable:   startup_toggle(app, true)
	case .Startup_Disable:  startup_toggle(app, false)
	case .Startup_Toggle:   if it, ok := selected_startup(app); ok { startup_toggle(app, !it.enabled) }
	case .Startup_Open:     startup_open(app)
	case .Startup_Copy:     startup_copy(app)
	case .Startup_Copy_Location: startup_copy_location(app)
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
	case .Props_Efficiency:     if p := find_proc(&app.sampler, app.props.pid, app.props.start); p != nil { efficiency_toggle(app, p) }
	case .Props_Filter:         props_filter_focus(app)
	case .Props_Next_Tab:       app.props.tab = Props_Tab((int(app.props.tab) + 1) % len(Props_Tab))
	case .Props_Previous_Tab:   app.props.tab = Props_Tab((int(app.props.tab) + len(Props_Tab) - 1) % len(Props_Tab))
	case .Props_Close:          ui.view_close(&app.views, PROPS_VIEW)
	}
}
