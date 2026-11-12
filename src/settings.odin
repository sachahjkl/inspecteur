package inspecteur

// The preferences: one registry (gt:config). The user's file is $XDG_CONFIG_HOME/inspecteur/prefs; `--pref name=value`
// overrides a preference for one run. Each one has its line in docs/configuration.md (settings_test.odin checks it).

import "core:fmt"
import "core:strconv"
import "core:strings"
import config "gt:config"
import "gt:platform"
import "gt:ui"

APP_NAME :: "inspecteur"

// The index of processes.columns in PREF_DEFS (its default is the columns shown by default: processes.odin).
PREF_COLUMNS :: 0

PREF_DEFS := [?]config.Def{
	{name = "processes.columns", category = "processes", description = "The columns of the Processes table besides the name, apart by commas: pid, ppid, user, state, nice, cpu, cpu_graph (the CPU of the last 30 seconds), memory (private memory), resident, gpu (the share of a GPU's time: NVIDIA's), gpu_memory, read, write, threads, started, command, executable. A right click on the table's header (or Ctrl+Shift+C) changes them.", kind = .String, default = {s = "pid,user,cpu,cpu_graph,memory,read,write,threads"}, hidden = true},
	{name = "processes.widths", category = "processes", description = "The widths of the columns that were resized, in ems, apart by commas (pid=6,command=30). Dragging the line before a column's title changes them.", kind = .String, default = {s = ""}, hidden = true},
	{name = "processes.order", category = "processes", description = "The order of the Processes table's columns after the name, apart by commas (cpu,pid,user). Dragging a column's title sideways changes it.", kind = .String, default = {s = ""}, hidden = true},
	{name = "processes.sort", category = "processes", description = "The column the processes are sorted by (one of processes.columns, or name; none: by PID, as they are read). A click on a title sorts by it, a second the other way, a third gives none.", kind = .String, default = {s = "name"}, hidden = true},
	{name = "processes.descending", category = "processes", description = "Sort from the largest (or from Z) down.", kind = .Bool, default = {b = false}, hidden = true},
	{name = "processes.refresh_ms", category = "processes", description = "How often the processes and the machine are read again, in milliseconds: a point of the Performance section's graphs each time. The title bar's refresh menu (Ctrl+Shift+R) changes it.", kind = .Int, default = {i = 1000}, min = 250, max = 10_000, bounded = true, unit = "ms", tags = {"speed", "interval", "update", "period"}},
	{name = "processes.view", category = "processes", description = "How the processes are listed: apps, the apps' groups and the background processes; tree, every process under its parent. Ctrl+T switches them.", kind = .String, default = {s = "apps"}, choices = {"apps", "tree"}, tags = {"tree", "apps", "group"}},
	{name = "processes.pinned", category = "processes", description = "The apps and processes pinned over the others, by name, apart by commas. Alt+P pins or unpins the selected row.", kind = .String, default = {s = ""}, hidden = true},
	{name = "processes.summary", category = "processes", description = "Show the summary of the machine over the Processes table: CPU, memory, disks, network, GPU, temperature and pressure, each with its last minute. Ctrl+B shows or hides it.", kind = .Bool, default = {b = true}, tags = {"header", "overview"}},
	{name = "services.manager", category = "services", description = "The services the Services section lists: the system's (system) or the user's (user). Its System and User buttons change it.", kind = .String, default = {s = "system"}, choices = {"system", "user"}, tags = {"system", "user", "systemd"}},
	{name = "services.widths", category = "services", description = "The widths of the Services table's columns that were resized, in ems (description=30). Dragging the line before a column's title changes them.", kind = .String, default = {s = ""}, hidden = true},
	{name = "services.order", category = "services", description = "The order of the Services table's columns, apart by commas (name,state,description). Dragging a column's title sideways changes it.", kind = .String, default = {s = ""}, hidden = true},
	{name = "services.sort", category = "services", description = "The column the services are sorted by (name, description, state, startup, load, pid, memory), a - before it for the largest (or Z) first. A click on a title changes it.", kind = .String, default = {s = "name"}, hidden = true},
	{name = "services.details", category = "services", description = "Show the selected service's details and its journal's last lines under the table (Ctrl+I).", kind = .Bool, default = {b = true}},
	{name = "services.journal_boot", category = "services", description = "The details' journal shows this boot's entries alone; off: its last entries, from any boot. Alt+B switches it.", kind = .Bool, default = {b = true}},
	{name = "services.journal_level", category = "services", description = "The entries of the details' journal shown: all, warnings (and worse), errors (and worse). Alt+L goes through them.", kind = .String, default = {s = "all"}, choices = {"all", "warnings", "errors"}},
	{name = "services.journal_follow", category = "services", description = "Read the details' journal again every 2 seconds while it is shown: new entries come in at the end. Alt+F switches it.", kind = .Bool, default = {b = true}},
	{name = "services.details_height", category = "services", description = "The height of the details' pane, in ems. Dragging the line above it changes it.", kind = .Float, default = {f = 16}, min = 6, max = 80, bounded = true, hidden = true},
	{name = "startup.widths", category = "startup", description = "The widths of the Startup table's columns that were resized, in ems (command=24).", kind = .String, default = {s = ""}, hidden = true},
	{name = "startup.order", category = "startup", description = "The order of the Startup table's columns, apart by commas (name,status,command).", kind = .String, default = {s = ""}, hidden = true},
	{name = "startup.sort", category = "startup", description = "The column the startup items are sorted by (name, command, type, status, file), a - before it for Z first.", kind = .String, default = {s = "name"}, hidden = true},
	{name = "connections.widths", category = "connections", description = "The widths of the Connections table's columns that were resized, in ems (remote_address=20).", kind = .String, default = {s = ""}, hidden = true},
	{name = "connections.order", category = "connections", description = "The order of the Connections table's columns, apart by commas (process,state,remote_address).", kind = .String, default = {s = ""}, hidden = true},
	{name = "connections.sort", category = "connections", description = "The column the sockets are sorted by (process, pid, protocol, local_address, remote_address, state), a - before it for the largest (or Z) first.", kind = .String, default = {s = "process"}, hidden = true},
	{name = "connections.refresh_ms", category = "connections", description = "How often the sockets are read again while Connections or Mission Control is shown, in milliseconds. A reading goes through every process's open files: a longer period costs less.", kind = .Int, default = {i = 3000}, min = 1000, max = 60_000, bounded = true, unit = "ms", tags = {"network", "sockets", "speed", "interval"}},
	{name = "services.refresh_ms", category = "services", description = "How often the services are read again while their section is shown, in milliseconds.", kind = .Int, default = {i = 3000}, min = 1000, max = 60_000, bounded = true, unit = "ms"},
	{name = "mission.layout", category = "mission", description = "Mission Control's panels: where each one is docked, its stacks and their sizes, those closed left out (the dock's text). Its panels' menu brings one back; Mission Control: the layout as at first sets it back.", kind = .String, default = {s = ""}, hidden = true},
	{name = "mission.windows", category = "mission", description = "Mission Control's panels in windows of their own, apart by commas (health,network): they open again at the start. A panel's menu opens one; closed, it goes back to Mission Control.", kind = .String, default = {s = ""}, hidden = true},
	{name = "view.theme", category = "appearance", description = "The window's colours: a theme of the toolkit by its name (Graphite, Midnight, Nord, Gruvbox, Tokyo Night, Catppuccin...).", kind = .String, default = {s = "Graphite"}, tags = {"colours", "colors", "palette", "look"}},
	{name = "view.mode", category = "appearance", description = "The theme's version: the system's (light or dark, followed as it changes), dark, or light.", kind = .String, default = {s = "system"}, choices = {"system", "dark", "light"}, tags = {"dark", "light", "night"}},
	{name = "view.finish", category = "appearance", description = "How surfaces are drawn. Machined: raised buttons and panels, sunken fields, graphs and meters (a light theme is drawn flat). Flat: plain surfaces and thin lines. Gradient: surfaces shaded top to bottom. Glass: surfaces that let the page show through. Edged: the machined reliefs crisp, nothing blurred (the Console theme's).", kind = .String, default = {s = "machined"}, choices = {"machined", "flat", "gradient", "glass", "edged"}, tags = {"look", "style", "relief"}},
	{name = "view.zebra", category = "appearance", description = "Shade every second row of the tables: a line of numbers reads across.", kind = .Bool, default = {b = true}, tags = {"stripes", "rows"}},
	{name = "view.rules", category = "appearance", description = "Draw a thin line under each row of the tables.", kind = .Bool, default = {b = true}, tags = {"lines", "rows"}},
	{name = "view.font_size", category = "appearance", description = "The text size at a zoom of 100 %, in logical pixels: every size of the window follows it.", kind = .Float, default = {f = FONT_SIZE_DEFAULT}, min = FONT_SIZE_MIN, max = FONT_SIZE_MAX, bounded = true, tags = {"text size", "bigger", "smaller"}},
	{name = "view.zoom", category = "appearance", description = "The zoom of the window: 1 is 100 %. Ctrl+wheel, Ctrl+= and Ctrl+- change it, Ctrl+0 sets it back.", kind = .Float, default = {f = 1}, min = 0.5, max = 3, bounded = true, hidden = true, tags = {"scale", "bigger", "smaller"}},
	{name = "view.system_title", category = "window", description = "The window's title bar drawn by the system (its buttons, its snapping) in place of Inspecteur's own.", kind = .Bool, default = {b = false}, tags = {"decorations", "native", "frame", "title bar"}},
	{name = "view.placement", category = "window", description = "Where the window was left and its size, in physical pixels, and whether it was maximized (\"120 80 1400 900 maximized\"; empty: the first start's size). Written when it closes; Wayland lets a program set the size alone.", kind = .String, default = {s = ""}, hidden = true},
	{name = "view.palette_size", category = "window", description = "The command palette's size, in logical pixels: its width and its height (empty: the default). Dragging its edges or its corner changes it.", kind = .String, default = {s = ""}, hidden = true},
	{name = "view.section", category = "window", description = "The section shown at the start: the one shown last (mission control, processes, performance, services, startup, connections, information). --section shows another.", kind = .String, default = {s = "processes"}, hidden = true},
	{name = "performance.cpu_view", category = "window", description = "The CPU's page in Performance: one graph for all the processors (overall), or one per logical processor (logical). Ctrl+G switches them.", kind = .String, default = {s = "overall"}, choices = {"overall", "logical"}, hidden = true},
	{name = "update.auto", category = "updates", description = "Check for a new version a while after the start and then every day, download it and put it in place: it runs at the next start. Only the installed copy updates itself (a copy of the Nix store is Nix's to update).", kind = .Bool, default = {b = true}, tags = {"upgrade", "version", "new version"}},
	{name = "setup.choice", category = "setup", description = "What was answered to the install's dialog: installed, standalone (this copy runs on its own: not offered again), or dismissed for a version.", kind = .String, default = {s = ""}, hidden = true},
}

// The look of a table's rows (view.zebra, view.rules): every list of the window takes it at each build.
rows_look :: proc(app: ^App, vl: ^ui.Virtual_List) {
	vl.zebra, vl.rules = app.settings.zebra, app.settings.rules
}

// The text size (view.font_size): its default and its bounds, in logical pixels.
FONT_SIZE_DEFAULT :: 13
FONT_SIZE_MIN :: 8
FONT_SIZE_MAX :: 40

// The values the program reads, copied out of the registry (prefs_read).
Settings :: struct {
	refresh_ms: int,
	tree:       bool,       // processes.view = tree
	summary:    bool,       // processes.summary
	pinned:     string,     // owned: processes.pinned as written
	manager:    Manager,    // services.manager
	details:    bool,       // services.details
	journal_boot: bool,     // services.journal_boot
	journal_level: Journal_Level,   // services.journal_level
	journal_follow: bool,   // services.journal_follow
	details_em: f32,        // services.details_height
	services_ms: int,       // services.refresh_ms
	connections_ms: int,    // connections.refresh_ms
	columns:    string,   // owned: processes.columns, .widths, .order, .sort as written
	order:      string,
	widths:     string,
	sort:       string,
	descending: bool,
	theme:      string,   // owned
	mode:       ui.Theme_Mode,
	finish:     ui.Finish,
	system_title: bool,     // view.system_title
	font_size:  f32,
	zoom:       f32,        // view.zoom
	mission_layout: string, // owned: mission.layout
	zebra:      bool,     // view.zebra
	rules:      bool,     // view.rules
	palette_size: [2]f32,   // view.palette_size ({}: the default)
	setup_choice: string, // owned: setup.choice
	update_auto: bool,    // update.auto
}

prefs_file :: proc(allocator := context.temp_allocator) -> string {
	return strings.concatenate({platform.config_dir(context.temp_allocator), "/", APP_NAME, "/prefs"}, allocator)
}

// The registry with the user's file and `args`' --pref read in. Returns the arguments that are not preferences.
prefs_open :: proc(p: ^config.Prefs, args: []string) -> (rest: [dynamic]string, problems: [dynamic]string) {
	p^ = config.prefs_make()
	config.register(p, PREF_DEFS[:])
	_, file_problems := config.load_file(p, prefs_file(), .User)
	rest, problems = config.apply_args(p, args, context.temp_allocator)
	append(&problems, ..file_problems[:])
	return
}

prefs_read :: proc(p: ^config.Prefs, allocator := context.allocator) -> (s: Settings) {
	s.refresh_ms = int(config.int_of(p, "processes.refresh_ms"))
	s.tree = config.string_of(p, "processes.view") == "tree"
	s.summary = config.bool_of(p, "processes.summary")
	s.pinned = strings.clone(config.string_of(p, "processes.pinned"), allocator)
	s.details = config.bool_of(p, "services.details")
	s.journal_boot = config.bool_of(p, "services.journal_boot")
	for l in Journal_Level { if JOURNAL_LEVEL_KEYS[l] == config.string_of(p, "services.journal_level") { s.journal_level = l } }
	s.journal_follow = config.bool_of(p, "services.journal_follow")
	s.details_em = f32(config.float_of(p, "services.details_height"))
	s.manager = config.string_of(p, "services.manager") == "user" ? .User : .System
	s.services_ms = int(config.int_of(p, "services.refresh_ms"))
	s.connections_ms = int(config.int_of(p, "connections.refresh_ms"))
	s.columns = strings.clone(config.string_of(p, "processes.columns"), allocator)
	s.widths = strings.clone(config.string_of(p, "processes.widths"), allocator)
	s.sort = strings.clone(config.string_of(p, "processes.sort"), allocator)
	s.order = strings.clone(config.string_of(p, "processes.order"), allocator)
	s.descending = config.bool_of(p, "processes.descending")
	s.theme = strings.clone(config.string_of(p, "view.theme"), allocator)
	s.mode = ui.theme_mode_of(config.string_of(p, "view.mode"))
	s.finish = ui.finish_of(config.string_of(p, "view.finish"))
	s.system_title = config.bool_of(p, "view.system_title")
	s.font_size = f32(config.float_of(p, "view.font_size"))
	s.zoom = f32(config.float_of(p, "view.zoom"))
	s.mission_layout = strings.clone(config.string_of(p, "mission.layout"), allocator)
	s.zebra = config.bool_of(p, "view.zebra")
	s.rules = config.bool_of(p, "view.rules")
	if parts := strings.fields(config.string_of(p, "view.palette_size"), context.temp_allocator); len(parts) == 2 {
		w, wok := strconv.parse_f32(parts[0])
		h, hok := strconv.parse_f32(parts[1])
		if wok && hok { s.palette_size = {w, h} }
	}
	s.setup_choice = strings.clone(config.string_of(p, "setup.choice"), allocator)
	s.update_auto = config.bool_of(p, "update.auto")
	return
}

settings_free :: proc(s: ^Settings) {
	delete(s.theme)
	delete(s.columns)
	delete(s.widths)
	delete(s.sort)
	delete(s.order)
	delete(s.pinned)
	delete(s.setup_choice)
	delete(s.mission_layout)
	s^ = {}
}

// Sets a preference to `value`: what the window changes (the columns, the theme's version) is there at the next start
// (the loop's writer writes the user's file: config.user_writer_save). False: the value is refused.
pref_set :: proc(p: ^config.Prefs, name, value: string) -> bool {
	return config.set_from_string(p, name, value, .User) == .None
}

// The table's columns from the settings: those shown, their widths, the sort.
table_layout_load :: proc(t: ^Table, s: Settings) {
	table_columns_init(t)
	shown := columns_of(s.columns)
	for c in Column { t.layout.shown[int(c)] = c == .Name || c in shown }
	ui.table_widths_apply(&t.layout, column_keys(), s.widths)
	ui.table_order_apply(&t.layout, column_keys(), s.order)
	t.layout.sort = int(Column.Name)
	if c, ok := column_of(s.sort); ok && t.layout.shown[int(c)] { t.layout.sort = int(c) }
	t.layout.descending = s.descending
	if s.sort == "none" { t.layout.sort, t.layout.descending = ui.TABLE_UNSORTED, false }
}

// The table's columns as the preferences write them: those shown, the widths that were changed, their order, the sort.
Layout_Values :: struct { columns, widths, order, sort: string, descending: bool }

table_layout_values :: proc(t: ^Table) -> (v: Layout_Values) {
	shown := make([dynamic]string, context.temp_allocator)
	for c in Column {
		if c != .Name && t.layout.shown[int(c)] { append(&shown, COLUMN_KEYS[c]) }
	}
	sort := "none"
	if c, sorted := table_sort(t); sorted { sort = COLUMN_KEYS[c] }
	return {strings.join(shown[:], ",", context.temp_allocator), ui.table_widths_text(&t.layout, column_keys()), ui.table_order_text(&t.layout, column_keys()), sort, t.layout.descending}
}

// The columns' names in the preferences, in the order of Column (temporary allocator).
column_keys :: proc() -> []string {
	out := make([]string, len(Column), context.temp_allocator)
	for c in Column { out[int(c)] = COLUMN_KEYS[c] }
	return out
}

// A section's table (Services, Startup, Connections): its widths, its columns' order and its sort from
// `<section>.widths`, `<section>.order` and `<section>.sort`. Its columns' names are their titles in lower case, spaces
// as '_' (section_column_keys).
section_layout_load :: proc(t: ^ui.Table, p: ^config.Prefs, section: string) {
	keys := section_column_keys(t.columns)
	ui.table_widths_apply(&t.layout, keys, config.string_of(p, fmt.tprintf("%s.widths", section)))
	ui.table_order_apply(&t.layout, keys, config.string_of(p, fmt.tprintf("%s.order", section)))
	ui.table_sort_apply(&t.layout, keys, config.string_of(p, fmt.tprintf("%s.sort", section)))
}

// A section's table's widths, columns' order and sort, into the preferences.
section_layout_save :: proc(t: ^ui.Table, p: ^config.Prefs, section: string) {
	keys := section_column_keys(t.columns)
	config.set_from_string(p, fmt.tprintf("%s.widths", section), ui.table_widths_text(&t.layout, keys), .User)
	config.set_from_string(p, fmt.tprintf("%s.order", section), ui.table_order_text(&t.layout, keys), .User)
	config.set_from_string(p, fmt.tprintf("%s.sort", section), ui.table_sort_text(&t.layout, keys), .User)
}

// "Remote address" is remote_address (temporary allocator).
section_column_keys :: proc(columns: []ui.Table_Column) -> []string {
	out := make([]string, len(columns), context.temp_allocator)
	for c, i in columns {
		low := strings.to_lower(c.title, context.temp_allocator)
		out[i], _ = strings.replace_all(low, " ", "_", context.temp_allocator)
	}
	return out
}

// The table's columns into the preferences.
table_layout_save :: proc(t: ^Table, p: ^config.Prefs) {
	v := table_layout_values(t)
	config.set_from_string(p, "processes.columns", v.columns, .User)
	config.set_from_string(p, "processes.widths", v.widths, .User)
	config.set_from_string(p, "processes.order", v.order, .User)
	config.set_from_string(p, "processes.sort", v.sort, .User)
	config.set_from_string(p, "processes.descending", v.descending ? "true" : "false", .User)
}
