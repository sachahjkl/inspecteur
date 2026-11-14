package inspecteur

// The window and its loop. The loop sleeps in the toolkit's wait until input or the next sample (processes.refresh_ms):
// a sample reads the machine and the processes (machine.odin, sampler.odin), groups the processes (processes.odin) and
// the window is built again. Between two samples, with no input, nothing runs.

import "core:fmt"
import "core:log"
import "core:strings"
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
import prefs_page "gt:prefs_page"
import process "gt:process"
import setup "gt:setup"
import update "gt:update"
import crash_bar "gt:crash_bar"
import instance "gt:instance"
import identity "identity"
import i18n "gt:i18n"

// Frames owed after an event (what it set off settles: the layout, the reveal of the selected row).
FRAMES_AFTER_INPUT :: 3

// The window's size at its first start, in logical pixels (then view.placement's).
WINDOW_SIZE :: [2]int{1100, 720}

Tab :: enum u8 { Mission_Control, Processes, Performance, Services, Startup, Connections, Information }

// (English: a section's name in the preferences and on the command line too; i18n.tr where it is shown)
TAB_LABELS := [Tab]string{.Mission_Control = i18n.later("Mission Control"), .Processes = i18n.later("Processes"), .Performance = i18n.later("Performance"), .Services = i18n.later("Services"), .Startup = i18n.later("Startup"), .Connections = i18n.later("Connections"), .Information = i18n.later("Information")}
TAB_ICONS := [Tab]string{.Mission_Control = lucide.LAYOUT_GRID, .Processes = lucide.LAYOUT_LIST, .Performance = lucide.GAUGE, .Services = lucide.SETTINGS, .Startup = lucide.POWER, .Connections = lucide.GLOBE, .Information = lucide.INFO}

App :: struct {
	shared:      host.Shared,
	main:        host.Host,
	icons:       font.Font_Id,      // Lucide
	prefs:       config.Prefs,
	prefs_writer: config.User_Writer,   // writes the user's file off the loop: each round saves what changed
	settings:    Settings,
	devtools:    ^devtools.Server,  // TOOLKIT_DEVTOOLS=<port>: driven and captured over the Chrome DevTools Protocol
	theme_shown: ui.Theme_Shown,
	themes_file: prefs_page.Themes_File,   // the toolkit's themes, then the user's own (themes.txt beside the preferences)
	standard:    prefs_page.Standard_Watch,   // the toolkit's standard settings, applied as they change
	licence:     prefs_page.Licence,   // who supports inspecteur (licence.odin): the settings' Licence page

	demo:        ^Demo,             // not nil: every reading is the demo's (--demo: the pictures of the documentation)
	own_pid:     i32,               // Inspecteur's (the first reading's, as the two below)
	display_server: i32,            // the pid of the compositor that shows the window (session_linux.odin), 0: unknown
	own_units:   []string,          // the units Inspecteur runs in, the outermost first (session_linux.odin; owned)
	sampling:    Sampling,          // the readings of the machine and the processes, off the window's thread (sample.odin)
	sampler:     Sampler,
	ranking:     Ranking,           // the busiest processes, made at each sample (diagnosis.odin)
	machine:     Machine,           // the CPU, the memory, the disks, the network, the GPUs (machine.odin, gpu.odin)
	catalog:     Catalog,
	app_icons:   map[string]Icon,   // the apps' icons by name (apps.odin)
	logo:        Icon,              // the title bar's (assets/logo_64.png)
	table:       Table,
	next_sample: time.Tick,
	paused:      bool,              // the refresh is paused (Ctrl+Space): nothing is read but on F5
	held:        bool,              // Ctrl is held: the refresh waits for its release, as in Windows' Task Manager (view_build)
	refresh_rect: ui.Rect,          // its button in the title bar, as last laid out (the menu opens under it)

	tab:         Tab,
	query:       string,            // the filter, in lower case (owned): each section with a table applies it
	connections: Connections,       // the sockets (connections.odin), read only while their section is shown
	services:    Services,          // systemd's services (services.odin), read every few seconds while shown
	startup:     Startup,           // what starts with the session (startup.odin), read when shown, on F5, after a change
	information: Information,       // what the system is (information.odin), read when first shown and on F5
	device:      Device,            // the Performance section's device shown (perf_view.odin)
	cpu_grid:    bool,              // the CPU's page shows a graph per logical processor
	bar_rect:    ui.Rect,           // the Processes section's bar, as last laid out (the columns' menu opens under it)
	palette:     ui.Command_Palette,   // the command palette (commands.odin)
	palette_table: Palette_Table,   // its list, made again only when it changes (commands.odin)
	palette_choices: ui.Choice_Memory,   // what the user chose in it before (palette_choices_file)
	sheet:       ui.Shortcuts_Sheet,   // the sheet of the keys (commands.odin)
	sheet_commands: [dynamic]ui.Command,   // its list, made at its first opening
	views:       ui.Views,          // the dialogs, the panels, the windows of their own, and how each was last shown (views.odin)
	mission:     Mission_Control,   // the Mission Control section: its panels (mission_control.odin)
	install:     prefs_page.Install,   // the install: its offer, its dialog, the settings' page (setup.odin)
	setup_due:   bool,              // --setup: the install's view opens in the first build
	updates_asked: bool,            // the updates started, once the install was read (setup_follow)
	crash_bar:   crash_bar.Bar,     // the last run's crash report, said at the top of the window
	settings_open: bool,            // the settings' page shows in place of the sections (settings_view.odin)
	settings_page: prefs_page.Page,
	updater:     ^update.Updater,   // the updates (updates.odin); nil in the demo
	update_serial: int,             // the updater's state last said
	installed_copy: bool,           // this copy is the installed one: it updates itself (update.auto)
	restart:     bool,              // at the end, the new program starts (an update in place)
	closing:     bool,              // the window closed: what the chores posted is freed, not shown
	journals:    [dynamic]^Journal_Window,   // the services' journals on their own, a view each (journal_window.odin)
	journals_closed: [dynamic]^Journal_Window,   // closed, freed once their reading is done
	windows:     [dynamic]App_Window,   // the apps' windows, read at each sample (window_list.odin)
	one_copy:    ^instance.Server,  // the name of the one Inspecteur that runs, served (one_copy.odin)
	tz:          ^datetime.TZ_Region,   // local time, for the processes' start (the first reading's; nil: UTC)
	search:      ui.Line_Edit,
	search_key:  ui.Key,
	vl:          ui.Virtual_List,   // the rows (vl.sel: the selected row)
	sel_rect:    ui.Rect,           // the selected row, as last built (where the Menu key opens the menu)
	menu:        Row_Menu,          // the row's menu, the confirmation of a kill (menu.odin)
	sample_extra: bool,             // the next sample comes sooner than the period (after an action): no point of the graphs
	props:       Props,             // the Properties dialog (props.odin, props_view.odin)
	affinity:    Affinity,          // the affinity dialog (affinity_view.odin)
	dump:        Dump,              // a dump file written by a task of the chores (dump.odin)
	props_lists: [Props_Tab]ui.Virtual_List,
	announcer:   ui.Announcer,      // what a finished act says (copied)
	status:      string,            // a message for the status bar (owned), until status_until (ui clock, ms)
	status_until: f64,
	// what the samples and the frames cost (--first-frame prints it at the end: the tools measure the program)
	refresh_time, frame_time: time.Duration,
	refreshes, frames: int,
}

// How the window starts: its first section, the first frame's times printed, the demo's readings.
Run_Options :: struct {
	first_frame: bool,
	tab:         Tab,
	demo:        bool,
	setup:       bool,   // --setup: the install's dialog open
	owner:       instance.Owner,   // the one Inspecteur's name, this start's (one_copy_acquire)
	owns:        bool,
	last_crash:  string,   // the report of the last run, which crashed or was killed ("": it ended cleanly): the crash bar
}

// The App of the process (a call posted from another thread finds it).
the_app: ^App

app_run :: proc(prefs: ^config.Prefs, opts: Run_Options) -> int {
	app := new(App)
	defer free(app)
	the_app = app
	defer the_app = nil
	app.prefs = prefs^
	prefs^ = {}
	app.settings = prefs_read(&app.prefs)
	prefs_page.install_init(&app.install, &app.prefs, setup_options())
	// (the language before anything is formatted for display: the first build, the window's toasts, the demo's texts)
	prefs_page.language_start(&app.prefs, PROGRAM_CATALOGUES)
	// (no file read here: the user's themes come at the first builds, read by a task)
	prefs_page.themes_file_init(&app.themes_file, themes_file(), ui.THEMES[:])
	demo: Demo
	if opts.demo {
		demo_init(&demo)
		app.demo = &demo
	}
	defer if opts.demo { demo_destroy(&demo) }

	// the processes are read while the window opens: its first frame shows them (sampling_attach)
	t_main := time.tick_now()
	machine_init(&app.machine, app.demo)
	sampling_init(&app.sampling, app.demo)
	if app.demo != nil { demo_preroll(app.demo, app, time.tick_now()._nsec) }
	table_layout_load(&app.table, app.settings)
	app.table.tree = app.settings.tree
	pins_load(&app.table, app.settings.pinned)
	app.vl.multi = true   // (Ctrl and Shift clicks, Ctrl+A: End task and Kill act on every row marked)
	app.tab = opts.tab
	app.cpu_grid = config.string_of(&app.prefs, "performance.cpu_view") == "logical"
	sample_ask(app)

	t_read := time.tick_now()
	platform.set_app_id(APP_NAME)
	if !host.host_open(&app.main, &app.shared, {title = "inspecteur", size = WINDOW_SIZE, integrated_title = !app.settings.system_title}, view_build, app) {
		log.error("no window")
		return 1
	}
	// (from here the program ends through the loop's end, which stops the writer)
	config.user_writer_start(&app.prefs_writer, &app.prefs, prefs_file())
	h := &app.main
	win := h.win
	app.announcer.window = win
	app.announcer.state = &app.main.state   // (a command runs between builds too: its toast goes to this window)
	if opts.last_crash != "" {
		log.warnf("the last run ended without its clean end: %s", opts.last_crash)
		crash_bar.init(&app.crash_bar, opts.last_crash)
	}
	sampling_attach(app, &h.state)
	app.icons, _ = font.load_embedded(&app.shared.fonts, lucide.DATA)
	if img, ok := platform.clipboard_image_decode("image/png", identity.ICONS[4].png, context.temp_allocator); ok {
		app.logo.tex = render.create_texture_rgba(&app.shared.r, img.size.x, img.size.y)
		render.update_texture_rgba(&app.shared.r, app.logo.tex, 0, 0, img.size.x, img.size.y, img.rgba)
		app.logo.ok = true
		app.install.logo = setup.Logo{app.logo.tex, {f32(img.size.x), f32(img.size.y)}}
	}
	h.state.icon_font = app.icons
	// (the file is read by a task: the window's state is made, its chores run it)
	ui.choice_memory_open(&app.palette_choices, &h.state, palette_choices_file(app))
	h.after_input = FRAMES_AFTER_INPUT
	// (the zoom, the rounding, the scrolling, the delays, partial redraw...: applied now, then each as it changes)
	prefs_page.standard_watch(&app.standard, &app.prefs, &h.state, {renderer = &app.shared.r, fonts = &app.shared.fonts, partial_redraw = &h.partial_redraw})
	licence_init(app)
	h.params = app_params
	app.devtools = devtools.start_from_env(win, "inspecteur")
	h.before_input = proc(h: ^host.Host) { app := (^App)(h.user); devtools.service(app.devtools, &h.state, &app.shared.r) }
	connections_init(&app.connections, app)
	information_init(&app.information, app)
	services_init(&app.services, app)
	startup_init(&app.startup, app)
	mission_init(app)
	section_first_show(app)
	// (the views' memory read, the panels open again as they were: before the first frame)
	views_start(app)
	// (the install is read on a task; the updates start once it says which copy runs: setup_follow. Never offered in the demo)
	prefs_page.install_offer(&app.install, &h.state, offer = !opts.setup && app.demo == nil)
	app.setup_due = opts.setup
	if opts.owns { one_copy_serve(app, opts.owner) }

	t_window := time.tick_now()
	// (the window as it was left: its size, maximized or not; its place too where the system lets a program set it)
	if pl, ok := platform.placement_parse(config.string_of(&app.prefs, "view.placement")); ok { platform.set_placement(win, pl) }
	platform.show_window(win)
	host.host_frame(h)
	if opts.first_frame {
		// (a tool reads it: the end of the first frame, then where the time went since main)
		ms :: proc(a, b: time.Tick) -> f64 { return time.duration_milliseconds(time.tick_diff(a, b)) }
		fmt.printfln("first-frame %d read %.1f window %.1f frame %.1f (draw %.1f, present %.1f)", time.now()._nsec, ms(t_main, t_read), ms(t_read, t_window), ms(t_window, time.tick_now()), time.duration_milliseconds(h.times.draw), time.duration_milliseconds(h.times.present))
	}
	// (the views' windows are the main window's: host_frame builds them right after each of its frames, so they show
	// what that frame took; hosts_wait counts them)
	hosts := [1]^host.Host{h}
	for !platform.is_closed(win) {
		host.hosts_wait(hosts[:])
		if !app.paused && !app.held && time.tick_diff(app.next_sample, time.tick_now()) >= 0 { sample_ask(app) }
		if !app.paused && !app.held {
			services_tick(app)
			connections_tick(app)
		}
		journals_tick(app)
		setup_follow(app)
		updates_follow(app)
		t_frame := time.tick_now()
		host.host_frame(h)
		zoom_follow(app)
		app.frame_time += time.tick_since(t_frame)
		app.frames += 1
		// (what this round changed in the preferences: the writer's thread writes the file)
		config.user_writer_save(&app.prefs_writer, &app.prefs)
		if config.user_writer_failed(&app.prefs_writer) { say(app, i18n.tr("The preferences cannot be written")) }
	}

	if opts.first_frame {
		mean :: proc(d: time.Duration, n: int) -> f64 { return n > 0 ? time.duration_milliseconds(d) / f64(n) : 0 }
		fmt.printfln("costs: %d samples, %.2f ms each; %d frames, %.2f ms each", app.refreshes, mean(app.refresh_time, app.refreshes), app.frames, mean(app.frame_time, app.frames))
	}
	if app.demo == nil { pref_set(&app.prefs, "view.placement", platform.placement_text(platform.get_placement(win))) }
	if !config.user_writer_stop(&app.prefs_writer, &app.prefs) { log.error("the preferences cannot be written") }
	// (what the chores still run ends first: their work reads and writes what is freed below; what they posted is taken,
	// so that it is freed with the rest)
	app.closing = true
	ui.chores_stop()
	ui.drain_posts(&h.state)
	devtools.stop(app.devtools)
	one_copy_stop(app)
	app_windows_clear(app)
	delete(app.windows)
	updates_stop(app)
	// (the chores have stopped: no task of theirs holds the themes file or the licence's store)
	prefs_page.themes_file_destroy(&app.themes_file)
	licence_destroy(app)
	prefs_page.destroy(&app.settings_page)
	mission_destroy(app)
	connections_destroy(&app.connections)
	information_destroy(&app.information)
	services_destroy(&app.services)
	startup_destroy(&app.startup)
	delete(app.query)
	icons_destroy(&app.app_icons, &app.shared.r)
	if app.logo.ok { render.destroy_texture(&app.shared.r, app.logo.tex) }
	prefs_page.install_end(&app.install)
	crash_bar.destroy(&app.crash_bar)
	// (after the last build, while the window's State is there: which views were open is written, their windows close;
	// then their data goes)
	ui.views_destroy(&app.views)
	journals_destroy(app)
	host.host_close(h)
	ui.line_edit_destroy(&app.search)
	ui.vlist_destroy(&app.vl)
	table_destroy(&app.table)
	catalog_destroy(&app.catalog)
	sampler_destroy(&app.sampler)
	ranking_destroy(&app.ranking)
	sampling_destroy(&app.sampling)
	machine_destroy(&app.machine)
	if app.tz != nil { timezone.region_destroy(app.tz) }
	delete(app.status)
	row_menu_destroy(&app.menu)
	for u in app.own_units { delete(u) }
	delete(app.own_units)
	props_destroy(&app.props)
	for &vl in app.props_lists { ui.vlist_destroy(&vl) }
	ui.palette_destroy(&app.palette)
	ui.shortcuts_sheet_destroy(&app.sheet)
	delete(app.sheet_commands)
	palette_table_destroy(&app.palette_table)
	// (it writes what changed and waits for its writer's thread: the window is closed by now)
	ui.choice_memory_close(&app.palette_choices)
	settings_free(&app.settings)
	prefs_page.standard_unwatch(&app.standard)
	config.prefs_destroy(&app.prefs)
	// (an update in place: the new program, once this one has let go of the window)
	if app.restart && !setup.launch(process.executable_path(), nil) { log.error("the new program does not start") }
	prefs_page.install_launch(&app.install)   // (the installed copy the install's dialog opened, likewise)
	return 0
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

// Shows a section; one that reads off the window's thread is read now.
tab_show :: proc(app: ^App, tab: Tab) {
	if app.tab == tab { return }
	app.tab = tab
	pref_set(&app.prefs, "view.section", strings.to_lower(TAB_LABELS[tab], context.temp_allocator))
	section_first_show(app)
	if tab == .Performance { gpu_want(&app.machine.gpu, true) }
}

// What the section shown reads when it is shown.
@(private = "file")
section_first_show :: proc(app: ^App) {
	#partial switch app.tab {
	case .Connections: connections_ask(app)
	case .Information: if !app.information.asked { information_ask(&app.information) }
	case .Services:    services_ask(app)
	case .Startup:     startup_ask(app)
	case .Mission_Control: mission_read(app)   // (it sums up every section: each one is read)
	}
}

// F5: the processes and the section shown, read again now.
refresh_now :: proc(app: ^App) {
	sample_ask(app)
	#partial switch app.tab {
	case .Information: information_ask(&app.information)
	case .Services:    services_ask(app)
	case .Startup:     startup_ask(app)
	}
	say(app, i18n.tr("Read again"))
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

// The process a row stands for: its own, or a group's first app process.
row_process :: proc(app: ^App, r: Row) -> (p: ^Proc, ok: bool) {
	switch r.kind {
	case .Process: return &app.sampler.procs[r.index], true
	case .App:     return &app.sampler.procs[app.table.groups[r.index].root], true
	case .Section:
	}
	return
}

// The milliseconds until the next sample (at least 1; max(int) while the refresh is paused or Ctrl is held, or while a
// reading is under way: it wakes the window when it is in).
until_sample :: proc(app: ^App) -> int {
	if app.paused || app.held || app.sampling.asked { return max(int) }   // (Ctrl's release wakes the window)
	return max(int(time.duration_milliseconds(time.tick_diff(time.tick_now(), app.next_sample))) + 1, 1)
}

// What each build of the window is given: the theme, the base style of the preferences. (The views' windows follow the
// main window's style: the toolkit's style_follow.)
@(private = "file")
app_params :: proc(h: ^host.Host, bp: ^ui.Build_Params) {
	app := (^App)(h.user)
	// (applied only when it changes, or the system goes light or dark: a palette applied starts a cross-fade)
	choice := prefs_page.appearance_choice(app.settings.look)
	if ui.theme_show(&app.shared.theme, app.themes_file.all[:], choice, &app.theme_shown, render.blend_space(&app.shared.r)) { platform.set_dark_title(h.win, !app.theme_shown.light) }
	// (in a window the user is not in, the search's caret neither shows nor blinks: at rest, one frame per sample)
	bp.inactive = !h.win.active
	// (the toolkit's zoom: Ctrl+wheel, Ctrl+=, Ctrl+-, Ctrl+0; zoom_follow keeps it)
	bp.base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(26)}, font = app.shared.font, font_size = app.settings.look.font_size, text_pad = 6, cursor = .Arrow}
}

// Says that an act is done (copied, a licence registered): the toolkit's announcement, where general.messages says (the
// system's notifications by default, a toast of the window where the system shows none). What is under way stays in
// the status bar (say).
announce :: proc(app: ^App, title: string, body := "") {
	app.announcer.mode = prefs_page.announce_mode(&app.prefs)
	ui.announce(&app.announcer, .Good, title, body)
}

// Shows a message in the status bar for a few seconds.
say :: proc(app: ^App, format: string, args: ..any) {
	delete(app.status)
	app.status = fmt.aprintf(format, ..args)
	app.status_until = ui.now_ms() + STATUS_SHOWN_MS
	ui.wake_within(&app.main.state, STATUS_SHOWN_MS + 1)
}

STATUS_SHOWN_MS :: 4000

