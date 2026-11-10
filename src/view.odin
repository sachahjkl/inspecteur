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
//
//   typing                    filters (name, command line, pid)
//   Up / Down, Page Up / Page Down, Ctrl+Home / Ctrl+End    move
//   Right / Left, Enter       open / close an app's group (Right and Left when the filter is empty)
//   Delete                    End task (SIGTERM)
//   Shift+Delete              Kill (SIGKILL), after a confirmation
//   Alt+Enter, a double click Properties (props_view.odin)
//   a right click, Menu, Shift+F10    the row's menu (menu.odin)
//   Ctrl+Tab, Ctrl+Shift+Tab  the next, the previous section
//   Escape                    clear the filter

import "core:fmt"
import "core:strings"
import "gt:draw"
import "gt:host"
import "gt:platform"
import lucide "gt:lucide"
import "gt:ui"

// Heights in ems: the title bar, a section's bar, the header, a row, a line of the sidebar, the footer.
TITLE_EM   :: 2.6
BAR_EM     :: 2.6
HEADER_EM  :: 2.2
ROW_EM     :: 1.9
SIDE_ROW_EM :: 2.2
FOOTER_EM  :: 2.1
SIDEBAR_EM :: 15   // the sidebar's width
// Rows Page Up / Page Down move by.
PAGE_ROWS :: 15
// Builds a selected row is pulled into view for (as the list's own keys do).
REVEAL_BUILDS :: 3
// A meter's bar is drawn in the theme's red past this share.
METER_FULL :: 0.9

view_build :: proc(h: ^host.Host, size: host.Vec2) {
	app := (^App)(h.user)
	em := ui.font_size()
	// typing anywhere filters: a character typed gives the filter the keyboard (app_input)
	if app.typed && !app.menu.kill_open && !app.props.open && app.search_key != 0 { ui.set_focus(app.search_key) }
	app.typed = false
	if !app.menu.kill_open && !app.props.open && !ui.ctx_menu_any_open() { view_keys(app) }
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	page := ui.build_box({.Draw_Background}, "###page")
	if ui.parent(page) {
		build_title(app, em)
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.row(id = "###body") {
			build_sidebar(app, em)
			ui.next({width = ui.fill(), height = ui.pct(1), axis = .Y})
			if ui.column(id = "###main") {
				ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
				if ui.column(id = "###section") {
					#partial switch app.tab {
					case .Processes:   build_processes(app, em)
					case .Performance: build_performance(app, em)
					case .Connections: build_connections(app, em)
					case .Information: build_information(app, em)
					case .Services:    build_services(app, em)
					case:              build_placeholder(app, em)
					}
				}
				build_footer(app, em)
			}
		}
	}
	props_build(app, em)
	row_menu_build(app, em)   // (after the Properties: the kill's confirmation goes over them)
	ui.wake_within(&app.main.state, min(until_sample(app), services_due_ms(app)))
}

@(private = "file")
view_keys :: proc(app: ^App) {
	if ui.key_press(.Tab, {.Ctrl}) { tab_show(app, Tab((int(app.tab) + 1) % len(Tab))) }
	if ui.key_press(.Tab, {.Ctrl, .Shift}) { tab_show(app, Tab((int(app.tab) + len(Tab) - 1) % len(Tab))) }
	DIGITS :: [len(Tab)]platform.Key{.N1, .N2, .N3, .N4, .N5, .N6}
	for k, i in DIGITS { if ui.key_press(k, {.Ctrl}) { tab_show(app, Tab(i)) } }
	if ui.key_press(.F, {.Ctrl}) && app.search_key != 0 { ui.set_focus(app.search_key) }
	if ui.key_press(.F5) { refresh_now(app) }
	if ui.key_press(.Escape) { ui.field_clear(&app.search) }
	// (a filter with text and the keyboard keeps Delete: it erases a character there, not a process)
	field_keeps := ui.focus_key() == app.search_key && app.search_key != 0 && len(app.search.buf) > 0
	#partial switch app.tab {
	case .Connections: connections_keys(app, field_keeps)
	case .Information: information_keys(app)
	case .Services:    services_keys(app, field_keeps)
	}
	if app.tab != .Processes { return }
	if ui.key_press(.Down) { select_step(app, app.vl.sel, 1, 1) }
	if ui.key_press(.Up) { select_step(app, app.vl.sel, -1, 1) }
	if ui.key_press(.Page_Down) { select_step(app, app.vl.sel, 1, PAGE_ROWS) }
	if ui.key_press(.Page_Up) { select_step(app, app.vl.sel, -1, PAGE_ROWS) }
	if ui.key_press(.Home, {.Ctrl}) { select_step(app, -1, 1, 1) }
	if ui.key_press(.End, {.Ctrl}) { select_step(app, len(app.table.rows), -1, 1) }
	if !field_keeps {
		if ui.key_press(.Delete) { end_selected(app) }
		if ui.key_press(.Delete, {.Shift}) { kill_selected(app) }
	}
	if ui.key_press(.Menu) || ui.key_press(.F10, {.Shift}) { row_menu_open(app, {app.sel_rect.min.x + 40, app.sel_rect.max.y}, from_keyboard = true) }
	if ui.key_press(.Return, {.Alt}) { props_selected(app) }
	r, ok := selected_row(app)
	if !ok { return }
	if ui.key_press(.Return) && r.kind == .App { group_toggle(app, r) }
	if len(app.search.buf) == 0 {
		if r.kind == .App && ui.key_press(.Right) && !app.table.expanded[app.table.groups[r.index].key] { group_toggle(app, r) }
		if ui.key_press(.Left) {
			if r.kind == .App && app.table.expanded[app.table.groups[r.index].key] { group_toggle(app, r) }
			if r.kind == .Process && r.depth > 0 { for i := app.vl.sel; i >= 0; i -= 1 { if app.table.rows[i].kind == .App { select_row(app, i); break } } }
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

select_row :: proc(app: ^App, row: int) {
	app.vl.sel = row
	app.vl.reveal = REVEAL_BUILDS
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

// Opens or closes an app's group; the selection stays on it.
group_toggle :: proc(app: ^App, r: Row) {
	key := app.table.groups[r.index].key
	if app.table.expanded[key] { delete_key(&app.table.expanded, key) } else { app.table.expanded[key] = true }
	rows_again(app)
	app.vl.reveal = REVEAL_BUILDS
}

////////////////////////////////
// Pieces

// An icon of Lucide, `width` wide.
glyph :: proc(app: ^App, g: string, width: f32, fg: Maybe(ui.Color) = nil) {
	ui.next({width = ui.px(width), height = ui.pct(1), font = app.icons, text_align = .Center, fg = fg})
	ui.build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###g%d", g, ui.parent_box().child_count))
}

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
		glyph(app, lucide.EYE, em * 1.7, ui.color("accent"))
		ui.next({width = ui.text_size(em * 0.4), height = ui.pct(1)})
		ui.label("Inspecteur###apptitle")
		ui.spacer(ui.fill())
		theme_button(app, em)
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
				glyph(app, TAB_ICONS[tab], em * 1.6, on ? ui.color("accent") : nil)
				ui.spacer(ui.px(em * 0.4))
				ui.next({width = ui.fill(), height = ui.pct(1)})
				ui.label(fmt.tprintf("%s###t", TAB_LABELS[tab]))
				if !on { ui.pop_tags() }
			}
			if sig.clicked { tab_show(app, tab) }
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
		if ui.tags("weak") { glyph(app, lucide.SEARCH, em * 1.6) }
		ui.next({width = ui.fill(), height = ui.pct(1)})
		if ui.tags("bare") {
			res := ui.line_edit("###search", &app.search, FILTER_HINTS[tab_listed(app.tab) ? app.tab : .Processes])
			app.search_key = res.box.key
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
	.Processes = "Filter processes...", .Performance = "", .Services = "Filter services...", .Startup = "Filter startup...",
	.Connections = "Filter connections...", .Information = "",
}

// Whether the section has a table that the filter filters.
tab_listed :: proc(tab: Tab) -> bool { return tab != .Performance && tab != .Information }

// The machine's CPU and memory: a line each, its value, a bar of how full.
@(private = "file")
build_meters :: proc(app: ^App, em: f32) {
	ui.hline(ui.fill())
	ui.spacer(ui.px(em * 0.5))
	meter(app, "cpu", lucide.CPU, "CPU", fmt.tprintf("%.0f%% of %d cores", app.machine.cpu, len(app.machine.core_total)), app.machine.cpu / 100, em)
	mem := app.machine.mem.total > 0 ? f32(f64(mem_used(&app.machine)) / f64(app.machine.mem.total)) : 0
	meter(app, "memory", lucide.LAYERS_2, "Memory", fmt.tprintf("%s of %s", size_text(mem_used(&app.machine)), size_text(app.machine.mem.total)), mem, em)
	ui.spacer(ui.px(em * 0.7))
}

@(private = "file")
Bar_Draw :: struct { used: f32, bar, track: ui.Color }

@(private = "file")
bar_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Bar_Draw)(user)
	r := b.rect
	draw.rect(dc, r, d.track)
	draw.rect(dc, {r.min, {r.min.x + (r.max.x - r.min.x) * clamp(d.used, 0, 1), r.max.y}}, d.bar)
}

@(private = "file")
meter :: proc(app: ^App, id, icon, title, value: string, used: f32, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.7))})
	if ui.row(.Center, {}, fmt.tprintf("###meter_%s", id)) {
		ui.spacer(ui.px(em * 0.6))
		if ui.tags("weak") { glyph(app, icon, em * 1.6) }
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
			d := ui.frame_new(Bar_Draw)
			full: ui.Color
			if ui.tags("bad") { full = ui.color("text") }
			d^ = {used, used > METER_FULL ? full : ui.color("accent"), ui.color("border")}
			ui.next({width = ui.fill(), height = ui.px(max(3, em * 0.25))})
			ui.custom("###bar", bar_draw, d)
			ui.spacer(ui.fill())
		}
		ui.spacer(ui.px(em * 0.8))
	}
}

////////////////////////////////
// The other sections, the footer

@(private = "file")
build_placeholder :: proc(app: ^App, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * BAR_EM))})
	if ui.row(.Center, {.Draw_Side_Bottom}, "###bar") {
		ui.spacer(ui.px(em * 0.8))
		ui.next({width = ui.text_size(), height = ui.pct(1), font_size = em * 1.08, text_pad = 0})
		ui.label(fmt.tprintf("%s###bar_title", TAB_LABELS[app.tab]))
	}
	ui.spacer(ui.px(em * 4))
	if ui.tags("weak") {
		ui.next({width = ui.fill(), height = ui.px(em * 2)})
		if ui.style({text_align = .Center}) { ui.label(fmt.tprintf("%s comes in a later version of Inspecteur.###placeholder", TAB_LABELS[app.tab])) }
	}
}

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
					if p, has := row_process(app, r); has { msg = fmt.tprintf("Selected: %s, PID %d", shown_text(p.name), p.pid) }
				}
			}
			if ui.tags("weak") {
				ui.next({width = ui.fill(), height = ui.pct(1)})
				ui.label(fmt.tprintf("%s###msg", msg))
			}
			counter(app, "f_cpu", lucide.CPU, fmt.tprintf("%.0f%%", app.machine.cpu), em)
			counter(app, "f_mem", lucide.LAYERS_2, fmt.tprintf("%.0f%%", app.machine.mem.total > 0 ? 100 * f64(mem_used(&app.machine)) / f64(app.machine.mem.total) : 0), em)
			counter(app, "f_procs", lucide.LAYOUT_LIST, fmt.tprintf("%d", len(app.sampler.procs)), em)
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
		if ui.tags("weak") { glyph(app, icon, em * 1.5) }
		ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = em * 0.3})
		ui.label(fmt.tprintf("%s###v", value))
		ui.spacer(ui.px(em * 0.4))
	}
}

// Text to show as it is: a "##" in it would end the shown part of a box's id string (ui's key rules), so a zero-width
// space goes between the two signs.
shown_text :: proc(text: string, allocator := context.temp_allocator) -> string {
	if !strings.contains(text, "##") { return text }
	out, _ := strings.replace_all(text, "##", "#​#", allocator)
	return out
}

// "1 app", "3 apps".
count_text :: proc(n: int, one, many: string) -> string { return fmt.tprintf("%d %s", n, n == 1 ? one : many) }

////////////////////////////////
// The theme's menu (the title bar's button)

THEME_MODE_LABELS := [ui.Theme_Mode]string{.System = "As the system", .Dark = "Dark", .Light = "Light"}
THEME_MODE_KEYS := [ui.Theme_Mode]string{.System = "system", .Dark = "dark", .Light = "light"}

// The theme's version (the system's, dark, light) and the theme, chosen from a menu and written to the preferences.
@(private = "file")
theme_button :: proc(app: ^App, em: f32) {
	if app.theme_menu == 0 { app.theme_menu = ui.key_from_string(0, "inspecteur_theme") }
	ui.next({width = ui.px(em * 2.4), height = ui.px(em * 2.1), font = app.icons})
	sig: ui.Signal
	if ui.tags("ghost_button") { sig = ui.button(fmt.tprintf("%s###theme", lucide.SUN_MOON)) }
	if sig.clicked { ui.ctx_menu_open_rect(app.theme_menu, sig.box.rect) }
	if ui.ctx_menu(app.theme_menu, em * 13) {
		ui.menu_heading("Version")
		for mode in ui.Theme_Mode {
			if ui.menu_item(THEME_MODE_LABELS[mode], checked = app.settings.mode == mode).clicked {
				app.settings.mode = mode
				pref_save(&app.prefs, "view.mode", THEME_MODE_KEYS[mode])
			}
		}
		ui.menu_separator()
		if ui.menu_submenu("Theme") {
			for t in ui.THEMES {
				if ui.menu_item(t.name, checked = app.settings.theme == t.name).clicked {
					delete(app.settings.theme)
					app.settings.theme = strings.clone(t.name)
					pref_save(&app.prefs, "view.theme", t.name)
				}
			}
		}
	}
}
