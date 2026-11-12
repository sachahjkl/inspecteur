package inspecteur

// The settings: gui_toolkit's page of the preferences (gt:prefs_page), in place of the sidebar and the section. The title
// bar's button, Ctrl+, or the palette opens it; Escape or Ctrl+, again goes back. Each change is saved to the preferences
// file and applied at once.

import "core:time"
import config "gt:config"
import "gt:platform"
import prefs_page "gt:prefs_page"
import "gt:ui"
import lucide "gt:lucide"

settings_toggle :: proc(app: ^App) {
	app.settings_open = !app.settings_open
	if app.settings_open { prefs_page.focus_search(&app.settings_page) }
}

// The keys of the settings: Ctrl+F gives the search the keyboard; Ctrl+, and Escape go back, unless an editor of a preference has the keyboard (Escape gives
// it back to the page first).
settings_keys :: proc(app: ^App) {
	if ui.key_press(.Comma, {.Ctrl}) { settings_toggle(app); return }
	if ui.key_press(.F, {.Ctrl}) { prefs_page.focus_search(&app.settings_page) }   // (as the window's filter)
	if ui.key_press(.Escape) && !prefs_page.editing(&app.settings_page) { app.settings_open = false }
}

// The pages: the categories of the preferences (settings.odin), their order and their icons.
@(private = "file", rodata)
SETTINGS_PAGES := [?]prefs_page.Page_Info{
	{category = "appearance", title = "Appearance", icon = lucide.PALETTE},
	{category = "processes",  title = "Processes",  icon = lucide.LAYOUT_LIST},
	{category = "services",   title = "Services",   icon = lucide.SETTINGS},
	{category = "connections", title = "Connections", icon = lucide.GLOBE},
	{category = "window",     title = "Window",     icon = lucide.APP_WINDOW},
	{category = "updates",    title = "Updates",    icon = lucide.DOWNLOAD},
}

@(private = "file", rodata)
CUSTOM := [?]string{"view.theme"}

// The page, as large as the body.
settings_build :: proc(app: ^App) {
	ui.next({width = ui.fill(), height = ui.fill()})
	prefs_page.build(&app.settings_page, &app.prefs, settings_options(app))
}

// What the page is given; the palette lists the settings by the same (palette_build).
settings_options :: proc(app: ^App) -> prefs_page.Options {
	return {
		user = app, changed = settings_changed, choices = settings_choices, preview = settings_preview,
		custom_names = CUSTOM[:], custom = settings_custom, problem = settings_problem,
		updater = app.updater, update_pref = "update.auto", restart = proc(user: rawptr) { updates_restart((^App)(user)) },
		pages = SETTINGS_PAGES[:], icon_font = app.icons, search_icon = lucide.SEARCH, reset_icon = lucide.ROTATE_CCW,
		version = "Inspecteur " + APP_VERSION,
		foot = "prefs: ~/.config/inspecteur/prefs",
	}
}

// What Inspecteur has to say under a preference's line: a title bar the desktop cannot draw.
@(private = "file")
settings_problem :: proc(user: rawptr, name: string) -> string {
	app := (^App)(user)
	if name == "view.system_title" && app.settings.system_title && !platform.system_title_available(app.main.win) {
		return "This desktop draws no title bar for Inspecteur's window (GNOME): Inspecteur keeps its own."
	}
	return ""
}

// The themes as cards, each in its own colours.
@(private = "file")
settings_custom :: proc(user: rawptr, name: string, em: f32) {
	app := (^App)(user)
	if at := prefs_page.theme_cards(ui.THEMES[:], app.settings.theme, app.theme_shown.light, em); at >= 0 {
		if config.set_from_string(&app.prefs, "view.theme", ui.THEMES[at].name, .User) == .None { settings_changed(app, "view.theme") }
	}
}

// The choices of a preference known at run time: the themes.
@(private = "file")
settings_choices :: proc(user: rawptr, name: string) -> (labels, values: []string) {
	if name != "view.theme" { return }
	out := make([]string, len(ui.THEMES), context.temp_allocator)
	for t, i in ui.THEMES { out[i] = t.name }
	return out, out
}

// While a slider is held: what can follow it at once does (the refresh's period); the text size waits for the release
// (every size of the window would move under the pointer).
@(private = "file")
settings_preview :: proc(user: rawptr, name: string, value: f64) {
	app := (^App)(user)
	switch name {
	case "processes.refresh_ms":
		app.settings.refresh_ms = int(value)
		app.next_sample = time.tick_add(time.tick_now(), time.Duration(app.settings.refresh_ms) * time.Millisecond)
	case "services.refresh_ms":
		app.settings.services_ms = int(value)
	}
}

// A preference was set or reset: read again, and what it changes applied (the loop writes the file).
@(private = "file")
settings_changed :: proc(user: rawptr, name: string) {
	app := (^App)(user)
	old := app.settings
	app.settings = prefs_read(&app.prefs)
	switch name {
	case "processes.view":
		app.table.tree = app.settings.tree
		rows_again(app)
	case "processes.refresh_ms":
		app.next_sample = time.tick_add(time.tick_now(), time.Duration(app.settings.refresh_ms) * time.Millisecond)
	case "services.manager":
		services_switch(app, app.settings.manager)
	case "view.system_title":
		platform.set_integrated_title(app.main.win, !app.settings.system_title)
	}
	settings_free(&old)
	updates_auto(app)
}
