package inspecteur

// The window: the title bar (the window's own), then the sidebar beside the section shown, and a footer under it.
//
//   ┌ title bar ──────────────────────────────────────────────┐
//   │ sidebar: the filter   │ the section (table_view.odin)    │
//   │ the sections          │                                  │
//   │ CPU, memory meters    ├──────────────────────────────────┤
//   │                       │ footer: a message │ the counters │
//   └───────────────────────┴──────────────────────────────────┘
//
// Every colour is the theme's: the surfaces are its page, its bars and its wells (surface), the lines its border.
// Typing anywhere filters the section shown; every other key is a command's (commands.odin), or the table's: Up, Down,
// Page Up, Page Down, Home, End move in it.

import "core:fmt"
import "core:strings"
import "core:time"
import "gt:host"
import lucide "gt:lucide"
import prefs_page "gt:prefs_page"
import "gt:ui"

// Heights in ems: the title bar, a section's bar, the header, a row, a line of the sidebar, the footer.
TITLE_EM   :: 2.6
BAR_EM     :: 2.6
HEADER_EM  :: 2.2
ROW_EM     :: 1.9
SIDE_ROW_EM :: 2.2
FOOTER_EM  :: 2.1
SIDEBAR_EM :: 15   // the sidebar's width
// Builds a selected row is pulled into view for (as the list's own keys do).
REVEAL_BUILDS :: 3
// A meter's bar is drawn in the theme's red past this share.
METER_FULL :: 0.9

view_build :: proc(h: ^host.Host, size: host.Vec2) {
	app := (^App)(h.user)
	em := ui.font_size()
	// Ctrl held: the rows stand still under the pointer (a key pressed before the window had the keyboard is not held:
	// the compositor's Ctrl+Shift+Escape that opened it)
	app.held = ui.key_held(.Ctrl)
	// (the user's themes file: a task looks at it now and then and reads it when it changed; window_params shows it)
	if prefs_page.themes_file_poll(&app.themes_file, &h.state) { h.settle = max(h.settle, FRAMES_AFTER_INPUT) }
	free_keys := !app.menu.confirm.open && !app.props.open && !app.affinity.open && !app.shortcuts_open && !app.setup.open && !app.diagnosis_open && !app.palette.open && !ui.ctx_menu_any_open()
	if free_keys && app.settings_open {
		settings_keys(app)   // (the page's own: its search takes what is typed)
	} else if free_keys {
		// typing anywhere filters: a character typed gives the filter the keyboard (an open menu searches its own items)
		ui.type_to_field(app.search_key)
		view_keys(app)
	}
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	page := ui.build_box({.Draw_Background}, "###page")
	if ui.parent(page) {
		build_title(app, em)
		ui.next({width = ui.fill(), height = ui.fill()})
		if app.settings_open {
			settings_build(app)
		} else if ui.row(id = "###body") {
			build_sidebar(app, em)
			ui.next({width = ui.fill(), height = ui.pct(1), axis = .Y})
			if ui.column(id = "###main") {
				ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
				if ui.column(id = "###section") {
					switch app.tab {
					case .Mission_Control: build_mission(app, em)
					case .Processes:   build_processes(app, em)
					case .Performance: build_performance(app, em)
					case .Services:    build_services(app, em)
					case .Startup:     build_startup(app, em)
					case .Connections: build_connections(app, em)
					case .Information: build_information(app, em)
					}
				}
				build_footer(app, em)
			}
		}
	}
	props_build(app, em)
	affinity_build(app, em)   // (after the Properties: it opens from them)
	row_menu_build(app, em)   // (after the Properties: the kill's confirmation goes over them)
	palette_build(app)
	shortcuts_build(app)
	setup_build(app, em)
	diagnosis_build(app, em)
	ui.wake_within(&app.main.state, min(until_sample(app), services_due_ms(app), connections_due_ms(app)))
}

@(private = "file")
view_keys :: proc(app: ^App) {
	// (a filter with text and the keyboard keeps its editing keys: Delete erases a character there, not a process)
	// (the journal's search keeps them all, empty or not: Delete there is no Stop)
	jk := app.services.pane.search_key
	field_keeps := ui.focus_key() == app.search_key && app.search_key != 0 && len(app.search.buf) > 0 || jk != 0 && ui.focus_key() == jk
	if journal_search_escape(&app.services.pane) { return }
	commands_keys(app, field_keeps)
	#partial switch app.tab {
	case .Processes:   processes_keys(app, field_keeps)
	case .Services:    section_keys(app, &app.services.rows, field_keeps, .Service_Open, services_menu_open)
	case .Startup:     section_keys(app, &app.startup.rows, field_keeps, .Startup_Open, startup_menu_open)
	case .Connections: section_keys(app, &app.connections.rows, field_keeps, .Socket_Open, connections_menu_open)
	}
}

// The moves in a section's table (the toolkit's keys, and Home and End when the filter does not keep them), Enter, its
// row's menu.
@(private = "file")
section_keys :: proc(app: ^App, st: ^Section_Table, field_keeps: bool, enter: Cmd, menu_open: proc(app: ^App, pos: ui.Vec2, from_keyboard: bool)) {
	t := &st.table
	if !field_keeps && len(t.ids) > 0 {
		if ui.key_press(.Home) { ui.list_select(&t.vl, 0) }
		if ui.key_press(.End) { ui.list_select(&t.vl, len(t.ids) - 1) }
	}
	keys := ui.table_keys(t)
	if keys.activated && cmd_can(app, enter) { cmd_run(app, enter) }
	if keys.menu { menu_open(app, keys.menu_at, true) }
}

// The moves in the Processes table (over the sections' rows), its row's menu.
@(private = "file")
processes_keys :: proc(app: ^App, field_keeps: bool) {
	page := max(app.vl.page_rows - 1, 1)
	if ui.key_press(.Down) { select_step(app, app.vl.sel, 1, 1) }
	if ui.key_press(.Up) { select_step(app, app.vl.sel, -1, 1) }
	if ui.key_press(.Page_Down) { select_step(app, app.vl.sel, 1, page) }
	if ui.key_press(.Page_Up) { select_step(app, app.vl.sel, -1, page) }
	if ui.key_press(.Home, {.Ctrl}) || (!field_keeps && ui.key_press(.Home)) { select_step(app, -1, 1, 1) }
	if ui.key_press(.End, {.Ctrl}) || (!field_keeps && ui.key_press(.End)) { select_step(app, len(app.table.rows), -1, 1) }
	if ui.key_press(.Menu) || ui.key_press(.F10, {.Shift}) { row_menu_open(app, {app.sel_rect.min.x + 40, app.sel_rect.max.y}, from_keyboard = true) }
}

// Whether a row's children (an app's group's processes, a process's in the tree) are shown.
row_open :: proc(app: ^App, r: Row) -> bool {
	t := &app.table
	if r.kind == .App { return t.expanded[t.groups[r.index].key] }
	return r.branch && !t.collapsed[proc_key(app.sampler.procs[r.index])]
}

// Whether the selected row's group (or a process's children, in the tree) can be opened (`open`) or closed; Left on a
// process under another goes to that one.
group_can_toggle :: proc(app: ^App, open: bool) -> bool {
	r, ok := selected_row(app)
	if !ok || len(app.search.buf) > 0 { return false }
	if r.kind == .App || r.branch {
		if row_open(app, r) != open { return true }
	}
	return !open && r.kind == .Process && r.depth > 0
}

group_set :: proc(app: ^App, open: bool) {
	r, ok := selected_row(app)
	if !ok { return }
	if (r.kind == .App || r.branch) && row_open(app, r) != open {
		group_toggle(app, r)
		return
	}
	if !open && r.kind == .Process && r.depth > 0 {
		// (the row above it one level up: its group, or its parent in the tree)
		for i := app.vl.sel; i >= 0; i -= 1 {
			q := app.table.rows[i]
			if q.kind == .App || (q.kind == .Process && q.depth < r.depth) { select_row(app, i); break }
		}
	}
}

// Moves the selection `count` rows from `from` in `dir`, over the section rows.
@(private = "file")
select_step :: proc(app: ^App, from, dir, count: int) {
	n := len(app.table.rows)
	at, left := from, count
	for k := from + dir; k >= 0 && k < n && left > 0; k += dir {
		if app.table.selectable[k] { at = k; left -= 1 }
	}
	if at >= 0 && at < n && at != from { select_row(app, at) }
}

// Makes `row` the selection (the rows marked, if any, are not: a move alone selects one row).
select_row :: proc(app: ^App, row: int) {
	app.vl.sel = row
	app.vl.reveal = REVEAL_BUILDS
	ui.list_marks_clear(&app.vl)
}

// Shows the process (pid, start) selected in the Processes section: the filter cleared, its app's group open. False
// when it is not in the last sample.
processes_reveal :: proc(app: ^App, pid: i32, start: u64) -> bool {
	p := find_proc(&app.sampler, pid, start)
	if p == nil { return false }
	at := -1
	for &q, i in app.sampler.procs { if &q == p { at = i; break } }
	ui.field_clear(&app.search)
	query_set(app, "")
	delete(app.table.query)
	app.table.query = ""
	if at >= 0 && at < len(app.table.owner) {
		if o := app.table.owner[at]; o >= 0 { app.table.expanded[u64(app.sampler.procs[o].entry) | APP_ID_MARK] = true }
	}
	// (in the tree: its line of parents opened)
	for q, steps := find_pid(&app.sampler, p.ppid), 0; q != nil && steps < 64; steps += 1 {
		delete_key(&app.table.collapsed, proc_key(q^))
		if q.ppid <= 0 || q.ppid == q.pid { break }
		q = find_pid(&app.sampler, q.ppid)
	}
	tab_show(app, .Processes)
	rows_again(app)
	key := proc_key(p^)
	for id, i in app.table.ids { if id == key { select_row(app, i); break } }
	return true
}

// The filter's text, in lower case (owned): each section with a table applies it when it differs from its own.
query_set :: proc(app: ^App, q: string) {
	delete(app.query)
	app.query = strings.clone(q)
}

// Opens or closes an app's group, or in the tree a process's children; the selection stays on it.
group_toggle :: proc(app: ^App, r: Row) {
	if r.kind == .App {
		key := app.table.groups[r.index].key
		if app.table.expanded[key] { delete_key(&app.table.expanded, key) } else { app.table.expanded[key] = true }
	} else if r.branch {
		key := proc_key(app.sampler.procs[r.index])
		if app.table.collapsed[key] { delete_key(&app.table.collapsed, key) } else { app.table.collapsed[key] = true }
	}
	rows_again(app)
	app.vl.reveal = REVEAL_BUILDS
}

// The processes as a tree, or as apps and background processes (written to processes.view).
tree_view_switch :: proc(app: ^App) {
	app.table.tree = !app.table.tree
	app.settings.tree = app.table.tree
	pref_set(&app.prefs, "processes.view", app.table.tree ? "tree" : "apps")
	tab_show(app, .Processes)
	rows_again(app)
	app.vl.reveal = REVEAL_BUILDS
	say(app, app.table.tree ? "Every process under its parent" : "Apps and background processes")
}

////////////////////////////////
// Pieces

// A thin vertical line between two things of a row (the columns' titles, the footer's counters).
vrule :: proc(em: f32, height: f32 = 1.2) {
	ui.spacer(ui.px(em * 0.35))
	ui.next({width = ui.px(max(1, ui.scale())), height = ui.px(em * height), bg = ui.color("border")})
	ui.build_box({.Draw_Background}, fmt.tprintf("###rule%d", ui.parent_box().child_count))
	ui.spacer(ui.px(em * 0.35))
}

// The colour of a surface of the theme: "bar" (the title bar, the headers, the footer), "well" (the sidebar).
surface :: proc(name: string) -> ui.Color {
	if name == "well" { return ui.color("well") }
	ui.push_tags(name)
	defer ui.pop_tags()
	return ui.color("background")
}

////////////////////////////////
// The title bar

@(private = "file")
build_title :: proc(app: ^App, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * TITLE_EM)), bg = surface("bar")})
	if ui.title_bar("###titlebar", {.Draw_Background, .Draw_Side_Bottom}) {
		ui.spacer(ui.px(em * 0.6))
		if app.logo.ok { icon_box(app.logo, em * 1.7) } else { ui.icon(lucide.EYE, em * 1.7, ui.color("accent")) }
		ui.next({width = ui.text_size(em * 0.4), height = ui.pct(1)})
		ui.label("Inspecteur###apptitle")
		ui.spacer(ui.fill())
		refresh_button(app, em)
		ui.next({width = ui.px(em * 2.4), height = ui.px(em * 2.1)})
		if ui.icon_button("palette_button", lucide.COMMAND, tip = cmd_tip(.Palette)).clicked { palette_open(app) }
		ui.next({width = ui.px(em * 2.4), height = ui.px(em * 2.1)})
		if ui.icon_button("help_button", lucide.KEYBOARD, tip = cmd_tip(.Shortcuts)).clicked { app.shortcuts_open = true }
		theme_button(app, em)
		ui.next({width = ui.px(em * 2.4), height = ui.px(em * 2.1)})
		// (the settings shown: the button is held down)
		if ui.icon_button("settings_button", lucide.SLIDERS_HORIZONTAL, tip = cmd_tip(.Settings), face = app.settings_open ? .Toggled : .Ghost).clicked { settings_toggle(app) }
		ui.spacer(ui.px(em * 0.4))
		_, _ = ui.window_buttons()
	}
}

////////////////////////////////
// The sidebar: the filter, the sections, the meters

@(private = "file")
build_sidebar :: proc(app: ^App, em: f32) {
	ui.next({width = ui.px(em * SIDEBAR_EM), height = ui.pct(1), axis = .Y, bg = surface("well")})
	side := ui.build_box({.Clip, .Draw_Background, .Draw_Side_Right}, "###sidebar")
	if ui.parent(side) {
		build_filter(app, em)
		ui.spacer(ui.px(em * 0.3))
		for tab in Tab {
			on := app.tab == tab
			flags := ui.Box_Flags{.Clickable, .Draw_Hot_Effects, .Hot_Within}
			if on { flags += {.Draw_Background} }
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * SIDE_ROW_EM)), bg = on ? ui.color("border") : nil})
			sig: ui.Signal
			if ui.row(.Center, flags, fmt.tprintf("###side_%d", int(tab))) {
				sig = ui.signal(ui.parent_box())
				ui.spacer(ui.px(em * 0.6))
				if !on { ui.push_tags("weak") }
				ui.icon(TAB_ICONS[tab], em * 1.6, on ? ui.color("accent") : nil)
				ui.spacer(ui.px(em * 0.4))
				ui.next({width = ui.fill(), height = ui.pct(1)})
				ui.label(fmt.tprintf("%s###t", TAB_LABELS[tab]))
				if !on { ui.pop_tags() }
			}
			if sig.clicked { tab_show(app, tab) }
			tip_after(sig, cmd_tip(Cmd(int(Cmd.Show_Mission_Control) + int(tab))))
		}
		ui.spacer(ui.fill())
		build_meters(app, em)
	}
}

// The filter, at the top of the sidebar. Typing anywhere goes to it.
@(private = "file")
build_filter :: proc(app: ^App, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * BAR_EM))})
	if ui.row(.Center, {.Draw_Side_Bottom}, "###filter") {
		ui.spacer(ui.px(em * 0.5))
		if ui.tags("weak") { ui.icon(lucide.SEARCH, em * 1.6) }
		ui.next({width = ui.fill(), height = ui.pct(1)})
		if ui.tags("bare") {
			res := ui.line_edit("###search", &app.search, FILTER_HINTS[tab_listed(app.tab) ? app.tab : .Processes])
			app.search_key = res.box.key
			tip_after(res, "Filter: type anywhere (Ctrl+F); Escape clears it")
		}
		ui.spacer(ui.px(em * 0.4))
	}
	if q := strings.to_lower(ui.field_string(&app.search), context.temp_allocator); q != app.query {
		query_set(app, q)
		// (a section with no table: the filter is for the processes)
		if !tab_listed(app.tab) { tab_show(app, .Processes) }
	}
}

FILTER_HINTS := [Tab]string{
	.Mission_Control = "", .Processes = "Filter processes...", .Performance = "", .Services = "Filter services...", .Startup = "Filter startup...",
	.Connections = "Filter connections...", .Information = "",
}

// Whether the section has a table that the filter filters.
tab_listed :: proc(tab: Tab) -> bool { return tab != .Performance && tab != .Information }

// The machine's CPU and memory: a line each, its value, a bar of how full.
@(private = "file")
build_meters :: proc(app: ^App, em: f32) {
	ui.hline(ui.fill())
	ui.spacer(ui.px(em * 0.5))
	// (the share of every logical processor, as the CPU % of the processes: "of 16 CPUs" as Linux counts them)
	meter(app, "cpu", lucide.CPU, "CPU", fmt.tprintf("%.0f%% of %d CPUs", app.machine.cpu, len(app.machine.core_total)), app.machine.cpu / 100, em)
	mem := app.machine.mem.total > 0 ? f32(f64(mem_used(&app.machine)) / f64(app.machine.mem.total)) : 0
	meter(app, "memory", lucide.LAYERS_2, "Memory", fmt.tprintf("%s of %s", size_text(mem_used(&app.machine)), size_text(app.machine.mem.total)), mem, em)
	ui.spacer(ui.px(em * 0.7))
}

@(private = "file")
meter :: proc(app: ^App, id, icon, title, value: string, used: f32, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.7))})
	if ui.row(.Center, {}, fmt.tprintf("###meter_%s", id)) {
		ui.spacer(ui.px(em * 0.6))
		if ui.tags("weak") { ui.icon(icon, em * 1.6) }
		ui.spacer(ui.px(em * 0.4))
		ui.next({width = ui.fill(), height = ui.pct(1), axis = .Y})
		if ui.column() {
			ui.spacer(ui.fill())
			ui.next({width = ui.fill(), height = ui.px(em * 1.4)})
			if ui.row(.Center) {
				ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = 0})
				ui.label(fmt.tprintf("%s###t", title))
				ui.spacer(ui.fill())
				if ui.tags("weak") {
					ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = 0, font_size = em * 0.88})
					ui.label(fmt.tprintf("%s###v", value))
				}
			}
			ui.spacer(ui.px(em * 0.2))
			ui.next({width = ui.fill(), height = ui.px(max(3, em * 0.25))})
			ui.meter_bar("###bar", used, METER_FULL)
			ui.spacer(ui.fill())
		}
		ui.spacer(ui.px(em * 0.8))
	}
}

////////////////////////////////
// The footer

// A message (what a command did, else the selection) at the left; the machine's counters at the right.
@(private = "file")
build_footer :: proc(app: ^App, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * FOOTER_EM)), bg = surface("bar")})
	if ui.row(.Center, {.Draw_Background, .Draw_Side_Top}, "###footer") {
		ui.spacer(ui.px(em * 0.8))
		if ui.style({font_size = em * 0.92}) {
			msg := app.status
			if msg == "" || ui.now_ms() > app.status_until {
				msg = ""
				if r, ok := selected_row(app); ok && app.tab == .Processes {
					#partial switch r.kind {
					case .Process:
						p := app.sampler.procs[r.index]
						msg = fmt.tprintf("Selected: %s, PID %d", p.name, p.pid)
						if n := ui.list_mark_count(&app.vl); n > 1 { msg = fmt.tprintf("Selected: %d rows", n) }
					case .App:
						g := app.table.groups[r.index]
						msg = fmt.tprintf("Selected: %s, %s", app.catalog.entries[g.entry].name, count_text(g.count, "process", "processes"))
						if n := ui.list_mark_count(&app.vl); n > 1 { msg = fmt.tprintf("Selected: %d rows", n) }
					}
				}
			}
			if ui.tags("weak") {
				ui.next({width = ui.fill(), height = ui.pct(1)})
				ui.label_tip(fmt.tprintf("%s###msg", ui.text_shown(msg)))
			}
			counter(app, "f_cpu", lucide.CPU, fmt.tprintf("%.0f%%", app.machine.cpu), em)
			counter(app, "f_mem", lucide.LAYERS_2, fmt.tprintf("%.0f%%", app.machine.mem.total > 0 ? 100 * f64(mem_used(&app.machine)) / f64(app.machine.mem.total) : 0), em)
			counter(app, "f_procs", lucide.LAYOUT_LIST, fmt.tprintf("%d", len(app.sampler.procs)), em)
			counter(app, "f_refresh", app.paused || app.held ? lucide.PAUSE : lucide.REFRESH_CW, refresh_text(app), em)
		}
		ui.spacer(ui.px(em * 0.6))
	}
}

@(private = "file")
counter :: proc(app: ^App, id, icon, value: string, em: f32) {
	ui.next({width = ui.children_sum(), height = ui.pct(1)})
	if ui.row(.Center, {}, fmt.tprintf("###%s", id)) {
		vrule(em)
		ui.spacer(ui.px(em * 0.3))
		if ui.tags("weak") { ui.icon(icon, em * 1.5) }
		ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = em * 0.3})
		ui.label(fmt.tprintf("%s###v", value))
		ui.spacer(ui.px(em * 0.4))
	}
}

// Whether `text` is wider than the box shows it (as the last layout made the box).
text_cut :: proc(b: ^ui.Box, text: string) -> bool {
	if b == nil || text == "" { return false }
	return ui.text_width(b.font, b.font_size, text) + 2 * b.text_pad > b.rect.max.x - b.rect.min.x + 0.5
}

////////////////////////////////
// The theme's menu (the title bar's button)

THEME_MODE_LABELS := [ui.Theme_Mode]string{.System = "As the system", .Dark = "Dark", .Light = "Light"}
THEME_MODE_KEYS := [ui.Theme_Mode]string{.System = "system", .Dark = "dark", .Light = "light"}

// The theme's version (the system's, dark, light) and the theme, chosen from a menu and written to the preferences.
@(private = "file")
theme_button :: proc(app: ^App, em: f32) {
	if app.theme_menu == 0 { app.theme_menu = ui.key_from_string(0, "inspecteur_theme") }
	ui.next({width = ui.px(em * 2.4), height = ui.px(em * 2.1)})
	sig := ui.icon_button("theme", lucide.SUN_MOON, tip = fmt.tprintf("Colours: light or dark (%s), the theme", ui.command_shortcut(COMMANDS[.Light_Dark])), lit = ui.ctx_menu_is_open(app.theme_menu))
	if sig.clicked { ui.ctx_menu_open_rect(app.theme_menu, sig.box.rect) }
	if ui.ctx_menu(app.theme_menu) {
		ui.menu_heading("Version")
		for mode in ui.Theme_Mode {
			if ui.menu_item(THEME_MODE_LABELS[mode], checked = app.settings.look.mode == mode).clicked { mode_set(app, mode) }
		}
		ui.menu_separator()
		cmd_item(app, .Light_Dark, "Switch light and dark")
		ui.menu_separator()
		if ui.menu_submenu("Theme") {
			// (the toolkit's themes, then the user's own: the themes file)
			for t in app.themes_file.all {
				if ui.menu_item(t.name, checked = app.settings.look.theme == t.name).clicked { look_set(app, prefs_page.THEME_PREF, t.name) }
			}
		}
	}
}

////////////////////////////////
// The refresh: paused, or its period (the title bar's button, the footer, Ctrl+Space, Ctrl+Shift+R)

// The periods the refresh menu offers, in milliseconds (processes.refresh_ms takes any from 250 to 10000).
REFRESH_SPEEDS := [?]struct { name: string, ms: int }{{"High: 0.5 s", 500}, {"Normal: 1 s", 1000}, {"Low: 2 s", 2000}, {"Very low: 5 s", 5000}}

// "1 s", "0.5 s", "Paused": the footer's.
refresh_text :: proc(app: ^App) -> string {
	if app.paused { return "Paused" }
	if app.held { return "Paused while Ctrl is held" }
	return app.settings.refresh_ms % 1000 == 0 ? fmt.tprintf("%d s", app.settings.refresh_ms / 1000) : fmt.tprintf("%.1f s", f64(app.settings.refresh_ms) / 1000)
}

// Pauses the refresh, or resumes it (then a sample at once).
refresh_pause :: proc(app: ^App, pause: bool) {
	app.paused = pause
	if pause {
		say(app, "Refresh paused: F5 reads again, Ctrl+Space resumes")
	} else {
		app.sample_extra = true
		sample_ask(app)
		say(app, "Refresh every %s", refresh_text(app))
	}
}

// Sets the refresh's period (written to processes.refresh_ms); the refresh resumes.
refresh_speed_set :: proc(app: ^App, ms: int) {
	app.settings.refresh_ms = ms
	pref_set(&app.prefs, "processes.refresh_ms", fmt.tprintf("%d", ms))
	app.paused = false
	app.next_sample = time.tick_add(time.tick_now(), time.Duration(ms) * time.Millisecond)
	say(app, "Refresh every %s: the graphs span %s", refresh_text(app), span_text(HISTORY_POINTS, ms))
}

refresh_menu_open :: proc(app: ^App) {
	if app.refresh_menu == 0 { app.refresh_menu = ui.key_from_string(0, "inspecteur_refresh") }
	r := app.refresh_rect
	ui.ctx_menu_open_rect(app.refresh_menu, r)
}

@(private = "file")
refresh_button :: proc(app: ^App, em: f32) {
	ui.next({width = ui.px(em * 2.4), height = ui.px(em * 2.1)})
	tip := fmt.tprintf("Refresh: %s. %s (%s), %s (%s)", app.paused ? "paused" : fmt.tprintf("every %s", refresh_text(app)),
		COMMANDS[.Refresh_Speed].label, ui.command_shortcut(COMMANDS[.Refresh_Speed]), app.paused ? "Resume" : "Pause", ui.command_shortcut(COMMANDS[.Pause_Refresh]))
	sig := ui.icon_button("refresh", app.paused ? lucide.PAUSE : lucide.REFRESH_CW, tip = tip, lit = app.refresh_menu != 0 && ui.ctx_menu_is_open(app.refresh_menu))
	app.refresh_rect = sig.box.rect
	if sig.clicked { refresh_menu_open(app) }
	if app.refresh_menu == 0 { return }
	if ui.ctx_menu(app.refresh_menu) {
		if ui.menu_item(app.paused ? "Resume" : "Pause", ui.command_shortcut(COMMANDS[.Pause_Refresh]), checked = app.paused).clicked { refresh_pause(app, !app.paused) }
		cmd_item(app, .Read_Again, "Read again now")
		ui.menu_separator()
		ui.menu_heading("Refresh every")
		for sp in REFRESH_SPEEDS {
			if ui.menu_item(sp.name, checked = !app.paused && app.settings.refresh_ms == sp.ms).clicked { refresh_speed_set(app, sp.ms) }
		}
	}
}

////////////////////////////////
// The zoom (Ctrl+wheel, Ctrl+=, Ctrl+-, Ctrl+0)

// The zoom (the toolkit's: Ctrl+wheel, Ctrl+=, Ctrl+-, Ctrl+0, and the commands), after a frame: kept when it changed
// (appearance.zoom: inspecteur opens as it was left), said in the footer, and the journals' windows zoomed alike. The
// standard settings' watch sets the same zoom again when the preference is written: nothing moves.
zoom_follow :: proc(app: ^App) {
	z := ui.zoom(&app.main.state)
	for w in app.journal_windows { ui.set_zoom(&w.state, z) }
	if abs(z - app.settings.zoom) < 0.001 { return }
	app.settings.zoom = z
	pref_set(&app.prefs, ZOOM_PREF, fmt.tprintf("%.3f", z))
	say(app, "Zoom %.0f %%%s", z * 100, abs(z - 1) < 0.001 ? "" : " (Ctrl+0: 100 %)")
}
