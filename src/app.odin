package inspecteur

// The window and its loop. The loop sleeps in the toolkit's wait until input or the next sample (processes.refresh_ms):
// a sample reads /proc (procfs.odin), groups the processes (processes.odin) and the window is built again. Between two
// samples, with no input, nothing runs.

import "core:fmt"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"
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
	machine:     Machine,           // the CPU, the memory, the disks, the network, the GPUs (machine.odin, gpu.odin)
	catalog:     Catalog,
	app_icons:   map[string]Icon,   // the apps' icons by name (apps.odin)
	table:       Table,
	next_sample: time.Tick,

	tab:         Tab,
	query:       string,            // the filter, in lower case (owned): each section with a table applies it
	connections: Connections,       // the sockets (connections.odin), read only while their section is shown
	information: Information,       // what the system is (information.odin), read when first shown and on F5
	device:      Device,            // the Performance section's device shown (perf_view.odin)
	cpu_grid:    bool,              // the CPU's page shows a graph per logical processor
	columns_menu: ui.Key,           // the menu of the table's columns (table_view.odin)
	theme_menu:  ui.Key,            // the menu of the theme (view.odin)
	tz:          ^datetime.TZ_Region,   // local time, for the processes' start (loaded when first needed)
	tz_tried:    bool,
	search:      ui.Text_Field,
	search_key:  ui.Key,
	typed:       bool,              // a character was typed this frame: the filter takes the keyboard (app_input)
	vl:          ui.Virtual_List,   // the rows (vl.sel: the selected row)
	sel_rect:    ui.Rect,           // the selected row, as last built (where the Menu key opens the menu)
	menu:        Row_Menu,          // the row's menu, the confirmation of a kill (menu.odin)
	props:       Props,             // the Properties dialog (props.odin, props_view.odin)
	props_lists: [Props_Tab]ui.Virtual_List,
	status:      string,            // a message for the status bar (owned), until status_until (ui clock, ms)
	status_until: f64,
	// what the samples and the frames cost (--first-frame prints it at the end: the tools measure the program)
	refresh_time, frame_time: time.Duration,
	refreshes, frames: int,
}

app_run :: proc(prefs: ^config.Prefs, first_frame := false) -> int {
	app := new(App)
	defer free(app)
	app.prefs = prefs^
	prefs^ = {}
	app.settings = prefs_read(&app.prefs)

	// the processes before the window: its first frame shows them
	t_main := time.tick_now()
	if !sampler_init(&app.sampler) {
		fmt.eprintln("inspecteur: /proc cannot be read")
		return 1
	}
	catalog_load(&app.catalog)
	machine_init(&app.machine)
	table_layout_load(&app.table, app.settings)
	refresh(app)

	t_read := time.tick_now()
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
	h.input = app_input
	app.devtools = devtools.start_from_env(win, "inspecteur")
	h.before_input = proc(h: ^host.Host) { app := (^App)(h.user); devtools.service(app.devtools, &h.state, &app.shared.r) }
	connections_init(&app.connections, app)
	information_init(&app.information, app)

	t_window := time.tick_now()
	platform.show_window(win)
	host.host_frame(h)
	if first_frame {
		// (a tool reads it: the end of the first frame, then where the time went since main)
		ms :: proc(a, b: time.Tick) -> f64 { return time.duration_milliseconds(time.tick_diff(a, b)) }
		fmt.printfln("first-frame %d read %.1f window %.1f frame %.1f (draw %.1f, present %.1f)", time.now()._nsec, ms(t_main, t_read), ms(t_read, t_window), ms(t_window, time.tick_now()), time.duration_milliseconds(h.times.draw), time.duration_milliseconds(h.times.present))
	}
	for !platform.is_closed(win) {
		host.hosts_wait({h})
		if time.tick_diff(app.next_sample, time.tick_now()) >= 0 { refresh(app) }
		sections_take(app)
		t_frame := time.tick_now()
		host.host_frame(h)
		app.frame_time += time.tick_since(t_frame)
		app.frames += 1
	}

	if first_frame {
		mean :: proc(d: time.Duration, n: int) -> f64 { return n > 0 ? time.duration_milliseconds(d) / f64(n) : 0 }
		fmt.printfln("costs: %d samples, %.2f ms each; %d frames, %.2f ms each", app.refreshes, mean(app.refresh_time, app.refreshes), app.frames, mean(app.frame_time, app.frames))
	}
	devtools.stop(app.devtools)
	connections_destroy(&app.connections)
	information_destroy(&app.information)
	delete(app.query)
	icons_destroy(&app.app_icons, &app.shared.r)
	host.host_close(h)
	ui.field_destroy(&app.search)
	ui.vlist_destroy(&app.vl)
	table_destroy(&app.table)
	catalog_destroy(&app.catalog)
	sampler_destroy(&app.sampler)
	machine_destroy(&app.machine)
	if app.tz != nil { timezone.region_destroy(app.tz) }
	delete(app.status)
	row_menu_destroy(&app.menu)
	props_destroy(&app.props)
	for &vl in app.props_lists { ui.vlist_destroy(&vl) }
	settings_free(&app.settings)
	config.prefs_destroy(&app.prefs)
	return 0
}

// A new sample, its groups and its rows; the next one is due a period later.
refresh :: proc(app: ^App) {
	now := time.tick_now()
	machine_sample(&app.machine, now._nsec, app.tab == .Performance && app.device.kind == .Cpu)
	sample(&app.sampler, now._nsec, app.machine.d_total, &app.catalog)
	gpu_mem := gpu_proc_mem(&app.machine)
	for &p in app.sampler.procs { p.gpu_mem = gpu_mem[p.pid] }
	table_group(&app.table, app.sampler.procs[:])
	rows_again(app)
	app.next_sample = time.tick_add(now, time.Duration(app.settings.refresh_ms) * time.Millisecond)
	if app.props.open { props_read(&app.props) }
	// (a section that reads on a thread of its own reads only while it is shown)
	if app.tab == .Connections { worker_ask(&app.connections.worker) }
	app.refresh_time += time.tick_since(now)
	app.refreshes += 1
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

// Shows a section; one that reads on a thread of its own is read now.
tab_show :: proc(app: ^App, tab: Tab) {
	if app.tab == tab { return }
	app.tab = tab
	#partial switch tab {
	case .Connections: worker_ask(&app.connections.worker)
	case .Information: if !app.information.asked { information_ask(&app.information) }
	}
}

// F5: the processes and the section shown, read again now.
refresh_now :: proc(app: ^App) {
	refresh(app)
	#partial switch app.tab {
	case .Information: information_ask(&app.information)
	}
	say(app, "Read again")
}

// What the sections' threads have published since the last frame becomes their rows.
sections_take :: proc(app: ^App) {
	connections_take(app)
	information_take(&app.information)
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
	// (in a window the user is not in, the search's caret neither shows nor blinks: at rest, one frame per sample)
	bp.inactive = !h.win.active
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

// The input before the interface sees it: a character typed, wherever the keyboard is, is for the filter.
@(private = "file")
app_input :: proc(h: ^host.Host, events: []platform.Event) -> []platform.Event {
	app := (^App)(h.user)
	for e in events { if e.kind == .Text && e.text >= ' ' { app.typed = true } }
	return events
}
