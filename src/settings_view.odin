package inspecteur

// The settings: gui_toolkit's page of the preferences (gt:prefs_page), in place of the sidebar and the section. The title
// bar's button, Ctrl+, or the palette opens it; Escape or Ctrl+, again goes back. Each change is applied at once: the
// toolkit's standard settings by prefs_page.standard_watch (the main window) and window_standard (the others),
// inspecteur's by settings_changed. The loop's writer saves the file off this thread.

import "core:time"
import "gt:host"
import "gt:platform"
import prefs_page "gt:prefs_page"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"

settings_toggle :: proc(app: ^App) {
	app.settings_open = !app.settings_open
	if app.settings_open { prefs_page.focus_search(&app.settings_page) }
}

// The keys of the settings: Ctrl+F gives the search the keyboard; Ctrl+, and Escape go back, unless an editor of a preference has the keyboard (Escape gives
// it back to the page first).
settings_keys :: proc(app: ^App) {
	if ui.key_press(.Comma, {.Ctrl}) { settings_toggle(app); return }
	if ui.key_press(.F, {.Ctrl}) { prefs_page.focus_search(&app.settings_page) }   // (as the window's filter)
	if prefs_page.escape_leaves(&app.settings_page) { app.settings_open = false }
}

// The General page shows where inspecteur says what it did and its language, then the licence (its page_foot):
// general.menu and general.autostart are the installation's (the install puts the menu entry in place, and inspecteur has
// no reason to start with the session), so no page shows them: the Installation page says where it is.
@(private = "file")
GENERAL_NAMES := [?]string{prefs_page.MESSAGES_PREF, prefs_page.LANGUAGE_PREF}

// The pages, their order and their icons: each a group of the registry (the first segment of a name). The tables' look
// (view.zebra, view.rules) has a page of its own: the other view.* preferences are hidden. (Not rodata: it slices
// GENERAL_NAMES, set when the program starts.)
@(private = "file")
SETTINGS_PAGES := [?]prefs_page.Page_Info{
	{category = "general",     title = i18n.later("General"),          icon = lucide.SLIDERS_HORIZONTAL, names = GENERAL_NAMES[:]},
	{category = "appearance",  title = i18n.later("Appearance"),       icon = lucide.PALETTE},
	{category = "window",      title = i18n.later("Window"),           icon = lucide.APP_WINDOW},
	{category = "view",        title = i18n.later("Tables"),           icon = lucide.TABLE},
	{category = "processes",   title = i18n.later("Processes"),        icon = lucide.LAYOUT_LIST},
	{category = "services",    title = i18n.later("Services"),         icon = lucide.SETTINGS},
	{category = "connections", title = i18n.later("Connections"),      icon = lucide.GLOBE},
	{category = "scrolling",   title = i18n.later("Scrolling"),        icon = lucide.MOUSE},
	{category = "input",       title = i18n.later("Input"),            icon = lucide.KEYBOARD},
	{category = "timing",      title = i18n.later("Delays and menus"), icon = lucide.TIMER},
	{category = "update",      title = i18n.later("Updates"),          icon = lucide.DOWNLOAD},
	{category = "rendering",   title = i18n.later("Rendering"),        icon = lucide.MONITOR},
}

// The page, as large as the body.
settings_build :: proc(app: ^App) {
	ui.next({width = ui.fill(), height = ui.fill()})
	prefs_page.build(&app.settings_page, &app.prefs, settings_options(app))
}

// What the page is given: its pages, the themes (the toolkit's and the user's), the updater, the file; the palette lists
// the settings by the same (palette_build).
settings_options :: proc(app: ^App) -> prefs_page.Page_Options {
	return {
		user = app, changed = settings_changed, preview = settings_preview, problem = settings_problem,
		page_foot = settings_page_foot,
		updater = app.updater, restart = proc(user: rawptr) { updates_restart((^App)(user)) },
		pages = SETTINGS_PAGES[:], icon_font = app.icons, search_icon = lucide.SEARCH, reset_icon = lucide.ROTATE_CCW,
		version = "Inspecteur " + APP_VERSION,
		file = prefs_file(),
		themes = app.themes_file.all[:], themes_light = app.theme_shown.light, themes_file = &app.themes_file,
		install = &app.install, diagnostics = &app.main,
	}
}

// What Inspecteur has to say under a preference's line: a title bar the desktop cannot draw.
@(private = "file")
settings_problem :: proc(user: rawptr, name: string) -> string {
	app := (^App)(user)
	if name == prefs_page.SYSTEM_TITLE_PREF && app.settings.system_title && !platform.system_title_available(app.main.win) {
		return i18n.tr("This desktop draws no title bar for Inspecteur's window (GNOME): Inspecteur keeps its own.")
	}
	return ""
}

// Under the General page's preferences: the licence.
@(private = "file")
settings_page_foot :: proc(user: rawptr, category: string, em: f32) {
	if category == "general" { licence_section((^App)(user), em) }
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

// A window of its own (a journal's, a Mission Control panel's) takes the standard settings as the main window does. The
// renderer and the fonts are shared: the main window's watch sets them.
window_standard :: proc(app: ^App, h: ^host.Host) {
	prefs_page.standard_apply(&app.prefs, &h.state, {partial_redraw = &h.partial_redraw})
}

// A preference was set or reset: read again, and what it changes applied; the standard ones are applied to the main
// window by standard_watch already, and here to the other windows (the loop writes the file).
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
	case prefs_page.SYSTEM_TITLE_PREF:
		// (inspecteur's window changes its title bar at once, where the desktop lets it)
		platform.set_integrated_title(app.main.win, !app.settings.system_title)
	}
	for w in app.journal_windows { window_standard(app, &w.window) }
	for w in app.mission_windows { window_standard(app, &w.window) }
	settings_free(&old)
	updates_auto(app)
}
