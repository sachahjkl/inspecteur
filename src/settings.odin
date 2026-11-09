package inspecteur

// The preferences: one registry (gt:config). The user's file is $XDG_CONFIG_HOME/inspecteur/prefs; `--pref name=value`
// overrides a preference for one run. Each one has its line in docs/configuration.md (settings_test.odin checks it).

import "core:strings"
import config "gt:config"
import "gt:platform"
import "gt:ui"

APP_NAME :: "inspecteur"

PREF_DEFS := [?]config.Def{
	{name = "processes.refresh_ms", category = "processes", description = "How often the processes are read again, in milliseconds.", kind = .Int, default = {i = 1000}, min = 250, max = 10_000, bounded = true, unit = "ms"},
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
	s.theme = strings.clone(config.string_of(p, "view.theme"), allocator)
	s.mode = ui.theme_mode_of(config.string_of(p, "view.mode"))
	s.finish = ui.finish_of(config.string_of(p, "view.finish"))
	s.font_size = f32(config.float_of(p, "view.font_size"))
	s.size = {int(config.int_of(p, "view.width")), int(config.int_of(p, "view.height"))}
	return
}

settings_free :: proc(s: ^Settings) {
	delete(s.theme)
	s^ = {}
}
