package inspecteur

// The window and its loop. The loop sleeps in the toolkit's wait until input or the next sample (processes.refresh_ms):
// a sample reads /proc (procfs.odin), groups the processes (processes.odin) and the window is built again. Between two
// samples, with no input, nothing runs.

import "core:fmt"
import "core:time"
import config "gt:config"
import "gt:devtools"
import "gt:font"
import "gt:host"
import lucide "gt:lucide"
import "gt:platform"
import "gt:render"
import "gt:ui"

// The corners: nearly square (a table of numbers, not cards): about a pixel on a button, none to see on a row.
ROUNDING :: 0.25
// Frames owed after an event (what it set off settles: the layout, the reveal of the selected row).
FRAMES_AFTER_INPUT :: 3

Tab :: enum u8 { Processes, Performance, Services, Startup, Connections, Information }

TAB_LABELS := [Tab]string{.Processes = "Processes", .Performance = "Performance", .Services = "Services", .Startup = "Startup", .Connections = "Connections", .Information = "Information"}
TAB_ICONS := [Tab]string{.Processes = lucide.LAYOUT_LIST, .Performance = lucide.GAUGE, .Services = lucide.SETTINGS, .Startup = lucide.POWER, .Connections = lucide.GLOBE, .Information = lucide.INFO}

App :: struct {
	shared:      host.Shared,
	main:        host.Host,
	icons:       font.Font_Id,      // Lucide
	prefs:       config.Prefs,
	settings:    Settings,
	devtools:    ^devtools.Server,  // TOOLKIT_DEVTOOLS=<port>: driven and captured over the Chrome DevTools Protocol
	theme_shown: ui.Theme_Shown,

	sampler:     Sampler,
	catalog:     Catalog,
	app_icons:   map[string]Icon,   // the apps' icons by name (apps.odin)
	table:       Table,
	next_sample: time.Tick,

	tab:         Tab,
	search:      ui.Text_Field,
	search_key:  ui.Key,
	vl:          ui.Virtual_List,   // the rows (vl.sel: the selected row)
	sel_rect:    ui.Rect,           // the selected row, as last built (where the Menu key opens the menu)
	menu:        Row_Menu,          // the row's menu, the confirmation of a kill (menu.odin)
	status:      string,            // a message for the status bar (owned), until status_until (ui clock, ms)
	status_until: f64,
}

app_run :: proc(prefs: ^config.Prefs, first_frame := false) -> int {
	app := new(App)
	defer free(app)
	app.prefs = prefs^
	prefs^ = {}
	app.settings = prefs_read(&app.prefs)

	// the processes before the window: its first frame shows them
	if !sampler_init(&app.sampler) {
		fmt.eprintln("inspecteur: /proc cannot be read")
		return 1
	}
	catalog_load(&app.catalog)
	app.table.sort = .Name
	refresh(app)

	platform.set_app_id(APP_NAME)
	if !host.host_open(&app.main, &app.shared, {title = "Inspecteur", size = app.settings.size, integrated_title = true}, view_build, app) {
		fmt.eprintln("inspecteur: no window")
		return 1
	}
	h := &app.main
	win := h.win
	app.icons, _ = font.load_embedded(&app.shared.fonts, lucide.DATA)
	h.state.icon_font = app.icons
	h.after_input = FRAMES_AFTER_INPUT
	h.partial_redraw = true   // (a sample changes some cells: only they are drawn again)
	ui.set_rounding(&h.state, ROUNDING)
	h.params = app_params
	app.devtools = devtools.start_from_env(win, "inspecteur")
	h.before_input = proc(h: ^host.Host) { app := (^App)(h.user); devtools.service(app.devtools, &h.state, &app.shared.r) }

	platform.show_window(win)
	host.host_frame(h)
	if first_frame { fmt.printfln("first-frame %d", time.now()._nsec) }
	for !platform.is_closed(win) {
		host.hosts_wait({h})
		if time.tick_diff(app.next_sample, time.tick_now()) >= 0 { refresh(app) }
		host.host_frame(h)
	}

	devtools.stop(app.devtools)
	icons_destroy(&app.app_icons, &app.shared.r)
	host.host_close(h)
	ui.field_destroy(&app.search)
	ui.vlist_destroy(&app.vl)
	table_destroy(&app.table)
	catalog_destroy(&app.catalog)
	sampler_destroy(&app.sampler)
	delete(app.status)
	row_menu_destroy(&app.menu)
	settings_free(&app.settings)
	config.prefs_destroy(&app.prefs)
	return 0
}

// A new sample, its groups and its rows; the next one is due a period later.
refresh :: proc(app: ^App) {
	now := time.tick_now()
	sample(&app.sampler, now._nsec, &app.catalog)
	table_group(&app.table, app.sampler.procs[:])
	rows_again(app)
	app.next_sample = time.tick_add(now, time.Duration(app.settings.refresh_ms) * time.Millisecond)
	app.main.settle = max(app.main.settle, 1)
}

// The rows again (a sample, a sort, the filter, a group opened), the same process selected when it is still shown.
rows_again :: proc(app: ^App) {
	keep := selected_id(app)
	ui.vlist_invalidate(&app.vl)
	table_rows(&app.table, &app.sampler, &app.catalog)
	app.vl.sel = -1
	if keep != 0 { for id, i in app.table.ids { if id == keep { app.vl.sel = i; break } } }
	// a search with nothing selected selects its first process (a row of its own, not an app's): a process that came
	// after the search was typed gets selected when a sample brings it
	if app.vl.sel < 0 && app.table.query != "" {
		for r, i in app.table.rows { if r.kind == .Process { app.vl.sel = i; app.vl.reveal = REVEAL_BUILDS; break } }
	}
}

selected_id :: proc(app: ^App) -> u64 {
	if app.vl.sel < 0 || app.vl.sel >= len(app.table.ids) { return 0 }
	return app.table.ids[app.vl.sel]
}

// The selected row, when there is one.
selected_row :: proc(app: ^App) -> (r: Row, ok: bool) {
	if app.vl.sel < 0 || app.vl.sel >= len(app.table.rows) { return }
	return app.table.rows[app.vl.sel], true
}

// The process a row stands for: its own, or a group's app process.
row_process :: proc(app: ^App, r: Row) -> (p: ^Proc, ok: bool) {
	switch r.kind {
	case .Process: return &app.sampler.procs[r.index], true
	case .App:     return &app.sampler.procs[app.table.groups[r.index].root], true
	case .Section:
	}
	return
}

// The milliseconds until the next sample (at least 1).
until_sample :: proc(app: ^App) -> int {
	return max(int(time.duration_milliseconds(time.tick_diff(time.tick_now(), app.next_sample))) + 1, 1)
}

// What each build is given: the palette and the base style of the preferences.
@(private = "file")
app_params :: proc(h: ^host.Host, bp: ^ui.Build_Params) {
	app := (^App)(h.user)
	// (applied only when it changes, or the system goes light or dark: a palette applied starts a cross-fade)
	choice := ui.Theme_Choice{name = app.settings.theme, mode = app.settings.mode, finish = app.settings.finish}
	if ui.theme_show(&app.shared.theme, ui.THEMES[:], choice, &app.theme_shown, render.blend_space(&app.shared.r)) { platform.set_dark_title(h.win, !app.theme_shown.light) }
	bp.base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(26)}, font = app.shared.font, font_size = app.settings.font_size, text_pad = 6, cursor = .Arrow}
}

// Shows a message in the status bar for a few seconds.
say :: proc(app: ^App, format: string, args: ..any) {
	delete(app.status)
	app.status = fmt.aprintf(format, ..args)
	app.status_until = ui.now_ms() + STATUS_SHOWN_MS
	ui.wake_within(&app.main.state, STATUS_SHOWN_MS + 1)
}

STATUS_SHOWN_MS :: 4000
