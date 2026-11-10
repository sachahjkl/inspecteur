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

PREF_DEFS := [?]config.Def{
	{name = "processes.columns", category = "processes", description = "The columns of the Processes table besides the name, apart by commas: pid, ppid, user, state, nice, cpu, memory, gpu_memory, read, write, threads, started, command, executable. A right click on the table's header changes them.", kind = .String, default = {s = "pid,user,cpu,memory,read,write,threads"}},
	{name = "processes.widths", category = "processes", description = "The widths of the columns that were resized, in ems, apart by commas (pid=6,command=30). Dragging the line before a column's title changes them.", kind = .String, default = {s = ""}},
	{name = "processes.sort", category = "processes", description = "The column the processes are sorted by (one of processes.columns, or name).", kind = .String, default = {s = "name"}},
	{name = "processes.descending", category = "processes", description = "Sort from the largest (or from Z) down.", kind = .Bool, default = {b = false}},
	{name = "processes.refresh_ms", category = "processes", description = "How often the processes are read again, in milliseconds.", kind = .Int, default = {i = 1000}, min = 250, max = 10_000, bounded = true, unit = "ms"},
	{name = "services.manager", category = "services", description = "The services the Services section lists: the system's (system) or the user's (user). Its System and User buttons change it.", kind = .String, default = {s = "system"}, choices = {"system", "user"}},
	{name = "services.refresh_ms", category = "services", description = "How often the services are read again while their section is shown, in milliseconds.", kind = .Int, default = {i = 3000}, min = 1000, max = 60_000, bounded = true, unit = "ms"},
	{name = "view.theme", category = "appearance", description = "The window's colours: a theme of the toolkit by its name (Graphite, Midnight, Nord, Gruvbox, Tokyo Night, Catppuccin...).", kind = .String, default = {s = "Graphite"}},
	{name = "view.mode", category = "appearance", description = "The theme's version: the system's (light or dark, followed as it changes), dark, or light.", kind = .String, default = {s = "system"}, choices = {"system", "dark", "light"}},
	{name = "view.finish", category = "appearance", description = "How surfaces are drawn. Flat: plain surfaces and thin lines. Machined: bevelled buttons, sunken fields.", kind = .String, default = {s = "flat"}, choices = {"flat", "machined", "gradient", "glass"}},
	{name = "view.font_size", category = "appearance", description = "The text size, in logical pixels.", kind = .Float, default = {f = 13}, min = 8, max = 40, bounded = true},
	{name = "view.width", category = "window", description = "The window's width at start, in logical pixels.", kind = .Int, default = {i = 1100}, min = 480, max = 8000, bounded = true},
	{name = "view.height", category = "window", description = "The window's height at start, in logical pixels.", kind = .Int, default = {i = 720}, min = 320, max = 8000, bounded = true},
}

// The values the program reads, copied out of the registry (prefs_read).
Settings :: struct {
	refresh_ms: int,
	manager:    Manager,    // services.manager
	services_ms: int,       // services.refresh_ms
	columns:    string,   // owned: processes.columns, .widths, .sort as written
	widths:     string,
	sort:       string,
	descending: bool,
	theme:      string,   // owned
	mode:       ui.Theme_Mode,
	finish:     ui.Finish,
	font_size:  f32,
	size:       [2]int,
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
	s.size = {int(config.int_of(p, "view.width")), int(config.int_of(p, "view.height"))}
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
	for c in Column { t.shown[c], t.width[c] = c == .Name, COLUMN_DEFAULT_EM[c] }
	for key in strings.split(s.columns, ",", context.temp_allocator) {
		if c, ok := column_of(strings.trim_space(key)); ok { t.shown[c] = true }
	}
	for pair in strings.split(s.widths, ",", context.temp_allocator) {
		eq := strings.index_byte(pair, '=')
		if eq < 0 { continue }
		c, ok := column_of(strings.trim_space(pair[:eq]))
		w, wok := strconv.parse_f32(strings.trim_space(pair[eq + 1:]))
		if ok && wok && c != .Name { t.width[c] = clamp(w, COLUMN_MIN_EM, COLUMN_MAX_EM) }
	}
	t.sort = .Name
	if c, ok := column_of(s.sort); ok { t.sort = c }
	t.descending = s.descending
}

// The table's columns into the preferences, written.
table_layout_save :: proc(t: ^Table, p: ^config.Prefs) {
	shown := make([dynamic]string, context.temp_allocator)
	widths := make([dynamic]string, context.temp_allocator)
	for c in Column {
		if c == .Name { continue }
		if t.shown[c] { append(&shown, COLUMN_KEYS[c]) }
		if t.width[c] != COLUMN_DEFAULT_EM[c] { append(&widths, fmt.tprintf("%s=%.1f", COLUMN_KEYS[c], t.width[c])) }
	}
	config.set_from_string(p, "processes.columns", strings.join(shown[:], ",", context.temp_allocator), .User)
	config.set_from_string(p, "processes.widths", strings.join(widths[:], ",", context.temp_allocator), .User)
	config.set_from_string(p, "processes.sort", COLUMN_KEYS[t.sort], .User)
	config.set_from_string(p, "processes.descending", t.descending ? "true" : "false", .User)
	config.save_user(p, prefs_file())
}
