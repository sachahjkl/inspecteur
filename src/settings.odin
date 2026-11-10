package inspecteur

// The preferences: one registry (gt:config). The user's file is $XDG_CONFIG_HOME/inspecteur/prefs; `--pref name=value`
// overrides a preference for one run. Each one has its line in docs/configuration.md (settings_test.odin checks it).

import "core:fmt"
import "core:strings"
import config "gt:config"
import "gt:platform"
import "gt:ui"

APP_NAME :: "inspecteur"

// The index of processes.columns in PREF_DEFS (its default is the columns shown by default: processes.odin).
PREF_COLUMNS :: 0

PREF_DEFS := [?]config.Def{
	{name = "processes.columns", category = "processes", description = "The columns of the Processes table besides the name, apart by commas: pid, ppid, user, state, nice, cpu, cpu_graph (the CPU of the last 30 seconds), memory (private memory), resident, gpu_memory, read, write, threads, started, command, executable. A right click on the table's header (or Ctrl+Shift+C) changes them.", kind = .String, default = {s = "pid,user,cpu,cpu_graph,memory,read,write,threads"}},
	{name = "processes.widths", category = "processes", description = "The widths of the columns that were resized, in ems, apart by commas (pid=6,command=30). Dragging the line before a column's title changes them.", kind = .String, default = {s = ""}},
	{name = "processes.sort", category = "processes", description = "The column the processes are sorted by (one of processes.columns, or name).", kind = .String, default = {s = "name"}},
	{name = "processes.descending", category = "processes", description = "Sort from the largest (or from Z) down.", kind = .Bool, default = {b = false}},
	{name = "processes.refresh_ms", category = "processes", description = "How often the processes and the machine are read again, in milliseconds: a point of the Performance section's graphs each time. The title bar's refresh menu (Ctrl+Shift+R) changes it.", kind = .Int, default = {i = 1000}, min = 250, max = 10_000, bounded = true, unit = "ms"},
	{name = "processes.view", category = "processes", description = "How the processes are listed: apps, the apps' groups and the background processes; tree, every process under its parent. Ctrl+T switches them.", kind = .String, default = {s = "apps"}, choices = {"apps", "tree"}},
	{name = "processes.summary", category = "processes", description = "Show the summary of the machine over the Processes table: CPU, memory, disks, network, GPU, temperature and pressure, each with its last minute. Ctrl+B shows or hides it.", kind = .Bool, default = {b = true}},
	{name = "services.manager", category = "services", description = "The services the Services section lists: the system's (system) or the user's (user). Its System and User buttons change it.", kind = .String, default = {s = "system"}, choices = {"system", "user"}},
	{name = "services.widths", category = "services", description = "The widths of the Services table's columns that were resized, in ems (description=30). Dragging the line before a column's title changes them.", kind = .String, default = {s = ""}},
	{name = "services.sort", category = "services", description = "The column the services are sorted by (name, description, state, startup, load, pid, memory), a - before it for the largest (or Z) first. A click on a title changes it.", kind = .String, default = {s = "name"}},
	{name = "services.details", category = "services", description = "Show the selected service's details and its journal's last lines under the table (Ctrl+I).", kind = .Bool, default = {b = true}},
	{name = "startup.widths", category = "startup", description = "The widths of the Startup table's columns that were resized, in ems (command=24).", kind = .String, default = {s = ""}},
	{name = "startup.sort", category = "startup", description = "The column the startup items are sorted by (name, command, type, status, file), a - before it for Z first.", kind = .String, default = {s = "name"}},
	{name = "connections.widths", category = "connections", description = "The widths of the Connections table's columns that were resized, in ems (remote_address=20).", kind = .String, default = {s = ""}},
	{name = "connections.sort", category = "connections", description = "The column the sockets are sorted by (process, pid, protocol, local_address, remote_address, state), a - before it for the largest (or Z) first.", kind = .String, default = {s = "process"}},
	{name = "services.refresh_ms", category = "services", description = "How often the services are read again while their section is shown, in milliseconds.", kind = .Int, default = {i = 3000}, min = 1000, max = 60_000, bounded = true, unit = "ms"},
	{name = "view.theme", category = "appearance", description = "The window's colours: a theme of the toolkit by its name (Graphite, Midnight, Nord, Gruvbox, Tokyo Night, Catppuccin...).", kind = .String, default = {s = "Graphite"}},
	{name = "view.mode", category = "appearance", description = "The theme's version: the system's (light or dark, followed as it changes), dark, or light.", kind = .String, default = {s = "system"}, choices = {"system", "dark", "light"}},
	{name = "view.finish", category = "appearance", description = "How surfaces are drawn. Flat: plain surfaces and thin lines. Machined: bevelled buttons, sunken fields. Gradient: surfaces shaded top to bottom. Glass: surfaces that let the page show through.", kind = .String, default = {s = "flat"}, choices = {"flat", "machined", "gradient", "glass"}},
	{name = "view.zebra", category = "appearance", description = "Shade every second row of the tables: a line of numbers reads across.", kind = .Bool, default = {b = true}},
	{name = "view.rules", category = "appearance", description = "Draw a thin line under each row of the tables.", kind = .Bool, default = {b = true}},
	{name = "view.font_size", category = "appearance", description = "The text size, in logical pixels. Ctrl+= and Ctrl+- change it, Ctrl+0 sets it back.", kind = .Float, default = {f = FONT_SIZE_DEFAULT}, min = FONT_SIZE_MIN, max = FONT_SIZE_MAX, bounded = true},
	{name = "view.width", category = "window", description = "The window's width at start, in logical pixels.", kind = .Int, default = {i = 1100}, min = 480, max = 8000, bounded = true},
	{name = "view.height", category = "window", description = "The window's height at start, in logical pixels.", kind = .Int, default = {i = 720}, min = 320, max = 8000, bounded = true},
	{name = "setup.welcome", category = "setup", description = "Show the welcome page at the next start (it puts Inspecteur in the application menu). Closing the page sets it to false.", kind = .Bool, default = {b = true}},
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
	manager:    Manager,    // services.manager
	details:    bool,       // services.details
	services_ms: int,       // services.refresh_ms
	columns:    string,   // owned: processes.columns, .widths, .sort as written
	widths:     string,
	sort:       string,
	descending: bool,
	theme:      string,   // owned
	mode:       ui.Theme_Mode,
	finish:     ui.Finish,
	font_size:  f32,
	zebra:      bool,     // view.zebra
	rules:      bool,     // view.rules
	size:       [2]int,
	welcome:    bool,     // setup.welcome
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
	s.details = config.bool_of(p, "services.details")
	s.manager = config.string_of(p, "services.manager") == "user" ? .User : .System
	s.services_ms = int(config.int_of(p, "services.refresh_ms"))
	s.columns = strings.clone(config.string_of(p, "processes.columns"), allocator)
	s.widths = strings.clone(config.string_of(p, "processes.widths"), allocator)
	s.sort = strings.clone(config.string_of(p, "processes.sort"), allocator)
	s.descending = config.bool_of(p, "processes.descending")
	s.theme = strings.clone(config.string_of(p, "view.theme"), allocator)
	s.mode = ui.theme_mode_of(config.string_of(p, "view.mode"))
	s.finish = ui.finish_of(config.string_of(p, "view.finish"))
	s.font_size = f32(config.float_of(p, "view.font_size"))
	s.zebra = config.bool_of(p, "view.zebra")
	s.rules = config.bool_of(p, "view.rules")
	s.size = {int(config.int_of(p, "view.width")), int(config.int_of(p, "view.height"))}
	s.welcome = config.bool_of(p, "setup.welcome")
	return
}

settings_free :: proc(s: ^Settings) {
	delete(s.theme)
	delete(s.columns)
	delete(s.widths)
	delete(s.sort)
	s^ = {}
}

// Sets a preference to `value` and writes the user's file: what the window changes (the columns, the theme's version)
// is there at the next start. False: the value is refused, or the file cannot be written.
pref_save :: proc(p: ^config.Prefs, name, value: string) -> bool {
	if config.set_from_string(p, name, value, .User) != .None { return false }
	return config.save_user(p, prefs_file())
}

// The table's columns from the settings: those shown, their widths, the sort.
table_layout_load :: proc(t: ^Table, s: Settings) {
	table_columns_init(t)
	shown := columns_of(s.columns)
	for c in Column { t.layout.shown[int(c)] = c == .Name || c in shown }
	ui.table_widths_apply(&t.layout, column_keys(), s.widths)
	t.layout.sort = int(Column.Name)
	if c, ok := column_of(s.sort); ok && t.layout.shown[int(c)] { t.layout.sort = int(c) }
	t.layout.descending = s.descending
}

// The table's columns as the preferences write them: those shown, the widths that were changed, the sort.
Layout_Values :: struct { columns, widths, sort: string, descending: bool }

table_layout_values :: proc(t: ^Table) -> (v: Layout_Values) {
	shown := make([dynamic]string, context.temp_allocator)
	for c in Column {
		if c != .Name && t.layout.shown[int(c)] { append(&shown, COLUMN_KEYS[c]) }
	}
	return {strings.join(shown[:], ",", context.temp_allocator), ui.table_widths_text(&t.layout, column_keys()), COLUMN_KEYS[table_sort(t)], t.layout.descending}
}

// The columns' names in the preferences, in the order of Column (temporary allocator).
column_keys :: proc() -> []string {
	out := make([]string, len(Column), context.temp_allocator)
	for c in Column { out[int(c)] = COLUMN_KEYS[c] }
	return out
}

// A section's table (Services, Startup, Connections): its widths and its sort from `<section>.widths` and
// `<section>.sort`. Its columns' names are their titles in lower case, spaces as '_' (section_column_keys).
section_layout_load :: proc(t: ^ui.Table, p: ^config.Prefs, section: string) {
	keys := section_column_keys(t.columns)
	ui.table_widths_apply(&t.layout, keys, config.string_of(p, fmt.tprintf("%s.widths", section)))
	ui.table_sort_apply(&t.layout, keys, config.string_of(p, fmt.tprintf("%s.sort", section)))
}

// A section's table's widths and sort, written to the preferences.
section_layout_save :: proc(t: ^ui.Table, p: ^config.Prefs, section: string) {
	keys := section_column_keys(t.columns)
	config.set_from_string(p, fmt.tprintf("%s.widths", section), ui.table_widths_text(&t.layout, keys), .User)
	config.set_from_string(p, fmt.tprintf("%s.sort", section), ui.table_sort_text(&t.layout, keys), .User)
	config.save_user(p, prefs_file())
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

// The table's columns into the preferences, written.
table_layout_save :: proc(t: ^Table, p: ^config.Prefs) {
	v := table_layout_values(t)
	config.set_from_string(p, "processes.columns", v.columns, .User)
	config.set_from_string(p, "processes.widths", v.widths, .User)
	config.set_from_string(p, "processes.sort", v.sort, .User)
	config.set_from_string(p, "processes.descending", v.descending ? "true" : "false", .User)
	config.save_user(p, prefs_file())
}
