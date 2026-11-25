package inspecteur

// Windows Services section view (Service Control Manager + Windows Event Log details pane
// and detachable Event Log windows). Written natively for Windows SCM concepts: Services /
// Shared (svchost) / Drivers filter, Pause/Continue, 4 startup types, PPL protection,
// dependencies/dependents, and Event Log filtering.

import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:time"
import i18n "gt:i18n"
import lucide "gt:lucide"
import "gt:platform"
import tasks "gt:tasks"
import "gt:ui"
import winapi "winapi"

DETAILS_EM :: 16

SERVICES_MENU       :: "inspecteur_win_service_menu"
STARTUP_TYPE_MENU   :: "inspecteur_win_startup_type_menu"

build_services :: proc(app: ^App, em: f32) {
	s := &app.services
	if s.rows.table.query != app.query { ui.table_apply(&s.rows.table, &s.rows.data, app.query) }
	note := i18n.tr("Reading…")
	if s.pending != .None {
		note = i18n.tr("Waiting for Service Control Manager…")
	} else if s.list != nil && s.list.filter == s.filter {
		note = fmt.tprintf(i18n.tr(len(s.list.units), "%d service, %d running", "%d services, %d running"), len(s.list.units), s.list.running)
	}
	section_bar(app, i18n.tr("Services"), note, em, win_services_actions, win_services_filter_choice)

	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.views_dock(&app.views, SERVICES_SPACE, {content = true}) {
		empty := ""
		if s.list != nil && s.list.filter == s.filter { empty = s.list.problem != "" ? s.list.problem : i18n.tr("No service.") }
		ev := section_table_build(&s.rows, empty)
		if ev.sorted { ui.table_apply(&s.rows.table, &s.rows.data, app.query) }
		if ev.sorted || ev.resized || ev.moved { section_layout_save(&s.rows, &app.prefs, "services") }
		section_header_menu(&s.rows, ev, "services", em)
		if ev.activated && cmd_can(app, .Service_Open) { service_reveal(app) }
		if ev.menu { services_menu_open(app, ev.menu_at) }
	}

	u, selected := selected_service(app)
	id := selected ? name_id(u.name) : 0
	if service_details_shown(app) && id != s.details_for {
		s.details_for = id
		if selected { win_details_ask(app, u.name) }
	}
	win_services_menu(app, em)
	win_startup_type_menu(app)
}

service_register :: proc(app: ^App) {
	ui.view_register(&app.views, SERVICE_VIEW, win_service_view, ui.View_Options{
		title = i18n.later("Details and Event Log"), icon = lucide.SCROLL_TEXT,
		home = .Panel, home_place = {space = SERVICES_SPACE, edge = .Bottom},
		extent_em = DETAILS_EM, width_em = 64, height_em = 40,
	})
}

journal_register :: proc(app: ^App) {
	ui.view_register(&app.views, JOURNAL_VIEW, win_event_window_view, ui.View_Options{
		title = i18n.later("Event Log"), icon = lucide.SCROLL_TEXT,
		home = .Panel, home_place = {space = SERVICES_SPACE, edge = .Bottom},
		extent_em = DETAILS_EM, width_em = 66, height_em = 42,
	})
}

// The Event Logs on their own that the kept layout has, opened again.
journals_restore :: proc(app: ^App) {
	for name in ui.view_restored_instances(&app.views, JOURNAL_VIEW, context.temp_allocator) { eventlog_window_show(app, name) }
}

journals_tick :: proc(app: ^App) {
	now := time.tick_now()
	closed: [8]string   // (a map is not changed while it is walked; the others at the next turn)
	n := 0
	for k, w in app.services.windows {
		if tasks.job_busy(ui.chores(), &w.job) { continue }
		if !ui.view_is_open(&app.views, JOURNAL_VIEW, w.name) {
			if n < len(closed) { closed[n] = k; n += 1 }
			continue
		}
		if w.follow && !app.paused && time.tick_diff(w.next, now) >= 0 {
			tasks.job_ask(ui.chores(), &w.job)
			w.next = time.tick_add(now, EVENTLOG_FOLLOW_MS * time.Millisecond)
		}
	}
	// (a reading posted and not taken yet goes by the service's name, and is freed when the window is gone)
	for k in closed[:n] {
		w := app.services.windows[k]
		_, _ = ui.view_ended(&app.views, JOURNAL_VIEW, w.name)   // (how it ended says nothing to do)
		delete_key(&app.services.windows, k)
		event_window_free(w)
	}
}

journals_due_ms :: proc(app: ^App) -> int {
	due := max(int)
	now := time.tick_now()
	for _, w in app.services.windows {
		if !ui.view_is_open(&app.views, JOURNAL_VIEW, w.name) { due = min(due, 50); continue }   // (freed at a next turn)
		if !w.follow || app.paused { continue }
		due = min(due, max(int(time.duration_milliseconds(time.tick_diff(now, w.next))) + 1, 1))
	}
	return due
}

@(private = "file")
event_window_free :: proc(w: ^Event_Window) {
	win_service_details_free(w.details)
	ui.line_edit_destroy(&w.search)
	ui.vlist_destroy(&w.vl)
	delete(w.shown)
	delete(w.shown_ids)
	delete(w.shown_query)
	delete(w.name)   // (the map's key too)
	free(w)
}

// At the end, once the chores stopped and the views were destroyed.
journals_destroy :: proc(app: ^App) {
	for _, w in app.services.windows { event_window_free(w) }
	delete(app.services.windows)
}

service_details_shown :: proc(app: ^App) -> bool { return ui.view_is_open(&app.views, SERVICE_VIEW) }

service_details_switch :: proc(app: ^App) {
	if service_details_shown(app) {
		ui.view_close(&app.views, SERVICE_VIEW)
	} else {
		ui.view_open(&app.views, SERVICE_VIEW, app, owner = &app.main.state)
	}
	app.services.details_for = 0
	tab_show(app, .Services)
	say(app, service_details_shown(app) ? i18n.tr("The selected service's details and Event Log") : i18n.tr("Details hidden"))
}

services_tick :: proc(app: ^App) {
	s := &app.services
	now := time.tick_now()
	if app.tab == .Services && time.tick_diff(s.next, now) >= 0 && !services_busy(app) {
		services_ask(app)
	}
	if service_details_shown(app) && s.event_follow && !app.paused && time.tick_diff(s.event_next, now) >= 0 && !tasks.job_busy(ui.chores(), &s.details_job) {
		if u, ok := selected_service(app); ok { win_details_ask(app, u.name) }
	}
}

services_due_ms :: proc(app: ^App) -> int {
	if app.paused { return max(int) }
	due := max(int)
	now := time.tick_now()
	if app.tab == .Services {
		due = min(due, max(int(time.duration_milliseconds(time.tick_diff(now, app.services.next))) + 1, 1))
	}
	if service_details_shown(app) && app.services.event_follow {
		due = min(due, max(int(time.duration_milliseconds(time.tick_diff(now, app.services.event_next))) + 1, 1))
	}
	return due
}

services_search_focused :: proc(app: ^App) -> bool {
	at := ui.focus_key()
	if at == 0 { return false }
	if at == app.services.event_search_key { return true }
	for _, w in app.services.windows { if at == w.search_key { return true } }
	return false
}

services_search_escape :: proc(app: ^App) -> bool {
	k := app.services.event_search_key
	if k == 0 || ui.focus_key() != k || !ui.key_press(.Escape) { return false }
	if len(app.services.event_search.buf) > 0 {
		ui.line_edit_clear(&app.services.event_search)
	} else {
		ui.set_focus(0)
	}
	return true
}

////////////////////////////////
// Details and Event Log pane

@(private = "file")
win_service_view :: proc(v: ^ui.View, app: ^App) {
	em := ui.font_size()
	s := &app.services
	u, selected := selected_service(app)
	d := s.details
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y, bg = surface("well")})
	pane := ui.build_box({.Clip, .Draw_Background}, "###win_svc_pane")
	if ui.parent(pane) {
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.2))})
		if ui.row(.Center, {}, "###win_svc_details_head") {
			ui.view_drag_handle(v, ui.parent_box())
			ui.space(ui.SPACE_3)
			title := selected ? fmt.tprintf("%s (%s)", u.name, u.display_name) : i18n.tr("No service selected")
			ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = 0})
			ui.label(fmt.tprintf("%s###name", ui.text_shown(title)))
			ui.space(ui.SPACE_3)
			if ui.tags("weak") {
				info := ""
				if selected && d != nil && d.name == u.name {
					parts := make([dynamic]string, context.temp_allocator)
					if d.svchost_group != "" { append(&parts, fmt.tprintf("svchost -k %s", d.svchost_group)) }
					if d.account != "" { append(&parts, d.account) }
					if d.protection != "" { append(&parts, d.protection) }
					if len(d.dependencies) > 0 { append(&parts, fmt.tprintf(i18n.tr("Depends on: %s"), strings.join(d.dependencies[:], ", ", context.temp_allocator))) }
					if len(d.dependents) > 0 { append(&parts, fmt.tprintf(i18n.tr("Active dependents: %s"), strings.join(d.dependents[:], ", ", context.temp_allocator))) }
					if d.binary_path != "" { append(&parts, d.binary_path) }
					info = strings.join(parts[:], "  ·  ", context.temp_allocator)
				}
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
				ui.label_tip(fmt.tprintf("%s###info", ui.text_shown(info)))
			}
			cmd_button(app, "svc_bin", lucide.FOLDER_OPEN, .Service_Open_Binary, em)
			cmd_button(app, "evt_win", lucide.EXTERNAL_LINK, .EventLog_Window, em)
			if v.presentation == .Panel {
				if tool_button("svc_details_close", lucide.X, fmt.tprintf(i18n.tr("Hide the details (%s)"), ui.command_shortcut(COMMANDS[.Service_Details])), true, em) {
					service_details_switch(app)
				}
			}
			ui.space(ui.SPACE_2)
		}

		// Description line if present.
		if selected && d != nil && d.name == u.name && d.description != "" {
			ui.next({width = ui.fill(), height = ui.children_sum()})
			if ui.row(.Start, {}, "###win_svc_desc") {
				ui.space(ui.SPACE_3)
				if ui.tags("weak") {
					ui.next({width = ui.fill()})
					ui.paragraph(fmt.tprintf("%s###d", ui.text_shown(d.description)))
				}
				ui.space(ui.SPACE_3)
			}
		}

		// Event Log toolbar.
		win_eventlog_body(app, d, selected ? u.name : "", &s.event_level, &s.event_follow, &s.event_search, &s.event_search_key, &s.event_vl,
			&s.event_shown, &s.event_shown_ids, &s.event_shown_of, &s.event_shown_lvl, &s.event_shown_q, s.event_serial, true, em)
	}
}

@(private = "file")
win_eventlog_body :: proc(
	app: ^App,
	d: ^Win_Service_Details,
	svc_name: string,
	level: ^EventLog_Level,
	follow: ^bool,
	search: ^ui.Line_Edit,
	search_key: ^ui.Key,
	vl: ^ui.Virtual_List,
	shown: ^[dynamic]int,
	shown_ids: ^[dynamic]u64,
	shown_of: ^int,
	shown_lvl: ^EventLog_Level,
	shown_q: ^string,
	serial: int,
	save_prefs: bool,
	em: f32,
) {
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.2)), bg = surface("bar")})
	if ui.row(.Center, {.Draw_Background, .Draw_Side_Top, .Draw_Side_Bottom}, "###evt_bar") {
		ui.space(ui.SPACE_2)
		labels := [3]string{i18n.tr(EVENTLOG_LEVEL_LABELS[.All]), i18n.tr(EVENTLOG_LEVEL_LABELS[.Warnings]), i18n.tr(EVENTLOG_LEVEL_LABELS[.Errors])}
		sel := int(level^)
		ui.next({height = ui.px(ui.dense(em * 1.8))})
		if ui.segmented("evt_lvl", labels[:], &sel) {
			level^ = EventLog_Level(sel)
			if save_prefs {
				app.settings.extra.eventlog_level = level^
				pref_set(&app.prefs, "services.eventlog_level", EVENTLOG_LEVEL_KEYS[level^])
			}
		}
		ui.space(ui.SPACE_2)
		ui.next({width = ui.px(em * 15), height = ui.px(ui.dense(em * 1.8))})
		res := ui.line_edit("###evt_search", search, {placeholder = i18n.tr("Search Event Log…")})
		search_key^ = res.box.key
		ui.spacer(ui.fill())
		if tool_button("evt_follow", follow^ ? lucide.PAUSE : lucide.PLAY, i18n.tr("Follow Event Log (Alt+F)"), true, em) {
			follow^ = !follow^
			if save_prefs {
				app.settings.extra.eventlog_follow = follow^
				pref_set(&app.prefs, "services.eventlog_follow", follow^ ? "true" : "false")
			}
		}
		if tool_button("evt_copy", lucide.COPY, i18n.tr("Copy Event Log entries shown"), d != nil && len(shown^) > 0, em) {
			win_eventlog_copy(app, d, shown^)
		}
		ui.space(ui.SPACE_2)
	}

	if svc_name == "" {
		return
	}
	if d == nil || d.name != svc_name {
		ui.space(ui.SPACE_3)
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.px(em * 2)})
			if ui.style({text_align = .Center}) { ui.label(fmt.tprintf("%s###wait", i18n.tr("Reading Event Log…"))) }
		}
		return
	}
	if len(d.events) == 0 {
		ui.space(ui.SPACE_3)
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.px(em * 2)})
			if ui.style({text_align = .Center}) {
				ui.label(fmt.tprintf("%s###empty", d.event_problem != "" ? d.event_problem : i18n.tr("No Event Log entries.")))
			}
		}
		return
	}

	q := strings.to_lower(ui.line_edit_string(search), context.temp_allocator)
	if shown_of^ != serial || shown_lvl^ != level^ || shown_q^ != q {
		shown_of^ = serial
		shown_lvl^ = level^
		delete(shown_q^)
		shown_q^ = strings.clone(q)
		clear(shown)
		clear(shown_ids)
		for ev, i in d.events {
			if !eventlog_level_keeps(level^, ev.level) { continue }
			if q != "" && !strings.contains(strings.to_lower(ev.message, context.temp_allocator), q) &&
				!strings.contains(strings.to_lower(ev.provider, context.temp_allocator), q) { continue }
			append(shown, i)
			append(shown_ids, u64(i) + 1)
		}
	}

	rows_look(app, vl)
	ui.next({width = ui.fill(), height = ui.fill()})
	rows, ok := ui.vlist("###evt_list", vl, shown_ids[:])
	if !ok { return }
	for i in rows.first ..< rows.last {
		ev := d.events[shown^[i]]
		ui.next({height = ui.px(ui.dense(em * 1.8))})
		row := ui.list_row(vl, i, "")
		if ui.parent(row.box) {
			ui.space(ui.SPACE_2)
			tag := ev.level == 1 || ev.level == 2 ? "bad" : ev.level == 3 ? "warn" : "weak"
			if ui.tags("weak") {
				ui.next({width = ui.px(em * 11), height = ui.pct(1), text_pad = 0, font_size = em * 0.9})
				ui.label(fmt.tprintf("%s###t", ev.timestamp))
			}
			ui.space(ui.SPACE_1)
			if ui.tags(tag) {
				ui.next({width = ui.px(em * 5), height = ui.pct(1), text_pad = 0, font_size = em * 0.9})
				ui.label(fmt.tprintf("#%d###id", ev.event_id))
			}
			ui.space(ui.SPACE_1)
			ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0, font_size = em * 0.92})
			b := ui.build_box({.Draw_Text, .Clip}, fmt.tprintf("%s###m", ui.text_shown(ev.message)))
			if text_cut(b, ev.message) { ui.table_cell_tip(row, ev.message) }
		}
	}
}

@(private = "file")
win_eventlog_copy :: proc(app: ^App, d: ^Win_Service_Details, indices: [dynamic]int) {
	if d == nil || len(indices) == 0 { return }
	b := strings.builder_make(context.temp_allocator)
	for idx in indices {
		ev := d.events[idx]
		fmt.sbprintf(&b, "%s  [#%d %s]  %s\n", ev.timestamp, ev.event_id, ev.provider, ev.message)
	}
	platform.set_clipboard(app.main.win, strings.to_string(b))
	announce(app, i18n.tr("Copied Event Log"), fmt.tprintf(i18n.tr(len(indices), "%d entry", "%d entries"), len(indices)))
}

// Detached Event Log view for a single service.
eventlog_window_open :: proc(app: ^App) {
	if u, ok := selected_service(app); ok { eventlog_window_show(app, u.name) }
}

@(private = "file")
eventlog_window_show :: proc(app: ^App, name: string) {
	w, exists := app.services.windows[name]
	if !exists {
		w = new(Event_Window)
		w.name   = strings.clone(name)
		w.demo   = app.demo
		w.state  = &app.main.state
		w.level  = app.services.event_level
		w.follow = app.services.event_follow
		w.job    = {work = win_event_window_work, data = w}
		app.services.windows[w.name] = w
	}
	tasks.job_ask(ui.chores(), &w.job)
	w.next = time.tick_add(time.tick_now(), EVENTLOG_FOLLOW_MS * time.Millisecond)
	ui.view_open(&app.views, JOURNAL_VIEW, app, instance = w.name, owner = &app.main.state)
}

@(private = "file")
win_event_window_work :: proc(data: rawptr) {
	w := (^Event_Window)(data)
	d := new(Win_Service_Details)
	a := virtual.arena_allocator(&d.arena)
	d.name         = strings.clone(w.name, a)
	d.dependencies = make([dynamic]string, a)
	d.dependents   = make([dynamic]string, a)
	d.events       = make([dynamic]Win_Event_Entry, a)
	if w.demo != nil {
		demo_service_details(w.demo, d, a)
	} else {
		win_service_details_read(d, a)
	}
	if !ui.post(w.state, win_event_window_posted, d) { win_service_details_free(d) }
}

@(private = "file")
win_event_window_posted :: proc(data: rawptr, _: u64) {
	d := (^Win_Service_Details)(data)
	app := the_app
	if app == nil { win_service_details_free(d); return }
	w, ok := app.services.windows[d.name]
	if !ok { win_service_details_free(d); return }
	win_service_details_free(w.details)
	w.details = d
	w.serial += 1
}

@(private = "file")
win_event_window_view :: proc(v: ^ui.View, app: ^App) {
	em := ui.font_size()
	w, ok := app.services.windows[v.instance]
	if !ok { return }
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y, bg = surface("well")})
	pane := ui.build_box({.Clip, .Draw_Background}, "###evt_win_pane")
	if ui.parent(pane) {
		win_eventlog_body(app, w.details, w.name, &w.level, &w.follow, &w.search, &w.search_key, &w.vl,
			&w.shown, &w.shown_ids, &w.shown_of, &w.shown_level, &w.shown_query, w.serial, false, em)
	}
}

////////////////////////////////
// Section bar, menus, commands

@(private = "file")
win_services_actions :: proc(app: ^App, em: f32) {
	cmd_button(app, "svc_start", lucide.PLAY, .Service_Start, em)
	cmd_button(app, "svc_stop", lucide.SQUARE, .Service_Stop, em)
	cmd_button(app, "svc_restart", lucide.ROTATE_CCW, .Service_Restart, em)
	cmd_button(app, "svc_pause", lucide.PAUSE, .Service_Pause, em)
	cmd_button(app, "svc_continue", lucide.STEP_FORWARD, .Service_Continue, em)
	vrule(em)
	if tool_button("svc_startup", lucide.SLIDERS_HORIZONTAL, cmd_tip(.Service_Startup_Type), service_can(app, .Service_Startup_Type), em, Cmd.Service_Startup_Type) {
		ui.menu_open(STARTUP_TYPE_MENU, ui.mouse_pos())
	}
	vrule(em)
	cmd_button(app, "svc_open", lucide.LAYOUT_LIST, .Service_Open, em)
	cmd_button(app, "svc_copy", lucide.COPY, .Service_Copy, em)
	vrule(em)
	cmd_button(app, "svc_details", lucide.SCROLL_TEXT, .Service_Details, em)
}

@(private = "file")
win_services_filter_choice :: proc(app: ^App, em: f32) {
	s := &app.services
	labels := [3]string{
		i18n.tr(WIN_SERVICE_FILTER_LABELS[.Services]),
		i18n.tr(WIN_SERVICE_FILTER_LABELS[.Shared]),
		i18n.tr(WIN_SERVICE_FILTER_LABELS[.Drivers]),
	}
	sel := int(s.filter)
	ui.next({height = ui.px(ui.dense(em * 2))})
	if ui.segmented("svc_filter", labels[:], &sel) {
		services_filter_switch(app, Win_Service_Filter(sel))
	}
}

services_filter_switch :: proc(app: ^App, f: Win_Service_Filter) {
	s := &app.services
	if s.filter == f { return }
	s.filter = f
	app.settings.extra.service_filter = f
	pref_set(&app.prefs, "services.filter", WIN_SERVICE_FILTER_KEYS[f])
	s.rows.table.vl.sel = -1
	win_services_rows(app)
	services_ask(app)
}

services_menu_open :: proc(app: ^App, pos: ui.Vec2, from_keyboard := false) {
	if _, ok := selected_service(app); !ok { return }
	ui.menu_open(SERVICES_MENU, pos, from_keyboard = from_keyboard)
}

@(private = "file")
win_services_menu :: proc(app: ^App, em: f32) {
	if ui.menu(SERVICES_MENU) {
		u, ok := selected_service(app)
		if !ok { ui.menu_close(); return }
		cmd_item(app, .Service_Start)
		cmd_item(app, .Service_Stop)
		cmd_item(app, .Service_Restart)
		cmd_item(app, .Service_Pause)
		cmd_item(app, .Service_Continue)
		ui.menu_separator()
		if ui.menu_submenu(i18n.tr("Startup type")) {
			for st in WIN_EDITABLE_STARTUPS {
				if ui.menu_item(i18n.tr(WIN_STARTUP_TYPE_LABELS[st]), checked = u.startup_type == st, disabled = app.services.pending != .None || u.protection != 0).clicked {
					service_set_startup_selected(app, st)
				}
			}
		}
		ui.menu_separator()
		cmd_item(app, .Service_Open)
		cmd_item(app, .Service_Open_Binary)
		cmd_item(app, .Service_Copy)
		ui.menu_separator()
		cmd_item(app, .Service_Details, service_details_shown(app) ? i18n.tr("Hide the details") : i18n.tr("Details and Event Log"))
		cmd_item(app, .EventLog_Window)
	}
}

@(private = "file")
win_startup_type_menu :: proc(app: ^App) {
	if ui.menu(STARTUP_TYPE_MENU) {
		u, ok := selected_service(app)
		if !ok { ui.menu_close(); return }
		for st in WIN_EDITABLE_STARTUPS {
			if ui.menu_item(i18n.tr(WIN_STARTUP_TYPE_LABELS[st]), checked = u.startup_type == st).clicked {
				service_set_startup_selected(app, st)
			}
		}
	}
}

service_can :: proc(app: ^App, c: Cmd) -> bool {
	u, ok := selected_service(app)
	if !ok { return false }
	if app.services.pending != .None && c != .Service_Open && c != .Service_Copy && c != .Service_Open_Binary { return false }
	#partial switch c {
	case .Service_Start:        return u.state == .Stopped && u.startup_type != .Disabled && u.protection == 0
	case .Service_Stop:         return (u.state == .Running || u.state == .Paused) && u.can_stop && u.protection == 0
	case .Service_Restart:      return u.state == .Running && u.can_stop && u.protection == 0
	case .Service_Pause:        return u.state == .Running && u.can_pause && u.protection == 0
	case .Service_Continue:     return u.state == .Paused && u.can_pause && u.protection == 0
	case .Service_Startup_Type: return !u.is_driver && u.protection == 0
	case .Service_Open:         return u.pid > 0
	case .Service_Open_Binary:  return u.binary_path != ""
	case .Service_Copy:         return true
	}
	return false
}

service_do :: proc(app: ^App, action: Win_Service_Action) {
	s := &app.services
	if s.list == nil || s.list.filter != s.filter { return }
	names := make([dynamic]string, context.temp_allocator)
	danger := ""
	for r in selected_rows(&s.rows.table) {
		if r >= len(s.list.units) { continue }
		u := s.list.units[r]
		if u.protection != 0 { continue }
		#partial switch action {
		case .Start:    if u.state != .Stopped || u.startup_type == .Disabled { continue }
		case .Stop:     if (u.state != .Running && u.state != .Paused) || !u.can_stop { continue }
		case .Restart:  if u.state != .Running || !u.can_stop { continue }
		case .Pause:    if u.state != .Running || !u.can_pause { continue }
		case .Continue: if u.state != .Paused || !u.can_pause { continue }
		}
		append(&names, u.name)
		if danger == "" && (action == .Stop || action == .Restart) {
			if u.pid > 0 {
				switch guard_of(app, u.pid) {
				case .Display_Server:  danger = i18n.tr("It hosts the desktop compositor.")
				case .Self, .Ancestor: danger = i18n.tr("Inspecteur runs under this service.")
				case .None:
				}
			}
			// Include active dependent services from the details cache if already read for this service.
			if danger == "" && s.details != nil && s.details.name == u.name && len(s.details.dependents) > 0 {
				danger = fmt.tprintf(i18n.tr("Active dependent services: %s."), strings.join(s.details.dependents[:], ", ", context.temp_allocator))
			}
		}
	}
	if len(names) == 0 { return }
	if action == .Stop || action == .Restart {
		confirm_service(app, action, names[:], danger)
		return
	}
	service_act_now(app, action, names[:])
}

service_act_now :: proc(app: ^App, action: Win_Service_Action, names: []string) {
	if app.services.pending != .None || len(names) == 0 { return }
	app.services.pending = action
	if len(names) == 1 {
		say(app, i18n.tr(WIN_SERVICE_ACTION_DOING[action]), names[0])
	} else {
		say(app, i18n.tr(WIN_SERVICE_ACTION_DOING[action]), fmt.tprintf(i18n.tr(len(names), "%d service", "%d services"), len(names)))
	}
	services_ask(app, action, names)
}

service_set_startup_selected :: proc(app: ^App, st: Win_Startup_Type) {
	s := &app.services
	if s.pending != .None || s.list == nil { return }
	names := make([dynamic]string, context.temp_allocator)
	for r in selected_rows(&s.rows.table) {
		if r < len(s.list.units) && s.list.units[r].protection == 0 && !s.list.units[r].is_driver {
			append(&names, s.list.units[r].name)
		}
	}
	if len(names) == 0 { return }
	s.pending = .Set_Startup
	say(app, i18n.tr(WIN_SERVICE_ACTION_DOING[.Set_Startup]), len(names) == 1 ? names[0] : fmt.tprintf(i18n.tr(len(names), "%d service", "%d services"), len(names)))
	services_ask(app, .Set_Startup, names[:], st)
}

service_reveal :: proc(app: ^App) {
	u, ok := selected_service(app)
	if !ok || u.pid <= 0 { return }
	p := find_pid(&app.sampler, u.pid)
	if p == nil || !processes_reveal(app, p.pid, p.start) { say(app, i18n.tr("PID %d is not in the processes' last sample"), u.pid) }
}

service_open_binary :: proc(app: ^App) {
	u, ok := selected_service(app)
	if !ok || u.binary_path == "" { return }
	exe := win_extract_exe_path(u.binary_path)
	if exe == "" { return }
	ui.open(exe, .Reveal)
	say(app, i18n.tr("Opened the folder of %s"), exe)
}

service_copy :: proc(app: ^App) {
	s := &app.services
	if s.list == nil { return }
	names := make([dynamic]string, context.temp_allocator)
	for r in selected_rows(&s.rows.table) { if r < len(s.list.units) { append(&names, s.list.units[r].name) } }
	if len(names) == 0 { return }
	text := strings.join(names[:], "\n", context.temp_allocator)
	platform.set_clipboard(app.main.win, text)
	announce(app, i18n.tr("Copied"), len(names) == 1 ? text : fmt.tprintf(i18n.tr(len(names), "%d name", "%d names"), len(names)))
}

eventlog_can :: proc(app: ^App, c: Cmd) -> bool {
	if !service_details_shown(app) && c != .EventLog_Window { return false }
	_, ok := selected_service(app)
	#partial switch c {
	case .EventLog_Window: return ok
	case .EventLog_Copy:   return ok && app.services.details != nil && len(app.services.event_shown) > 0
	case .EventLog_Search, .EventLog_Level, .EventLog_Follow: return true
	}
	return false
}

eventlog_run :: proc(app: ^App, c: Cmd) {
	s := &app.services
	#partial switch c {
	case .EventLog_Search:
		if !service_details_shown(app) { service_details_switch(app) }
		if s.event_search_key != 0 { ui.set_focus(s.event_search_key); ui.line_edit_select_all(&s.event_search) }
	case .EventLog_Level:
		s.event_level = EventLog_Level((int(s.event_level) + 1) % len(EventLog_Level))
		app.settings.extra.eventlog_level = s.event_level
		pref_set(&app.prefs, "services.eventlog_level", EVENTLOG_LEVEL_KEYS[s.event_level])
		say(app, i18n.tr("Event Log: %s"), i18n.tr(EVENTLOG_LEVEL_LABELS[s.event_level]))
	case .EventLog_Follow:
		s.event_follow = !s.event_follow
		app.settings.extra.eventlog_follow = s.event_follow
		pref_set(&app.prefs, "services.eventlog_follow", s.event_follow ? "true" : "false")
		say(app, s.event_follow ? i18n.tr("Following the Event Log") : i18n.tr("Event Log paused"))
	case .EventLog_Copy:
		win_eventlog_copy(app, s.details, s.event_shown)
	case .EventLog_Window:
		eventlog_window_open(app)
	}
}

// Extracts the executable path from a Windows command string (`"C:\Program Files\App\svc.exe" -k foo` -> `C:\Program Files\App\svc.exe`).
win_extract_exe_path :: proc(cmd: string) -> string {
	return win_expand_env(winapi.exe_of_command(cmd), context.temp_allocator)
}

////////////////////////////////
// Mission Control Services panel

mission_services :: proc(app: ^App, em: f32) {
	s := &app.services
	if s.list == nil || s.list.filter != s.filter { mission_note(i18n.tr("Reading…"), em); return }
	if s.list.problem != "" { mission_note(s.list.problem, em); return }
	n := len(s.list.units)
	mission_note(fmt.tprintf(i18n.tr(n, "%d Windows service: %d running, %d automatic stopped", "%d Windows services: %d running, %d automatic stopped"), n, s.list.running, s.list.stopped_auto), em)
	k := 0
	for u in s.list.units {
		if u.state != .Stopped || (u.startup_type != .Automatic && u.startup_type != .Automatic_Delayed) { continue }
		if mission_line(app, fmt.tprintf("mc_svc_%d", k), u.name, u.display_name, i18n.tr("Stopped"), -1, "warn", em, {kind = .Service, name = u.name}) {
			tab_show(app, .Services)
			service_select(app, u.name)
		}
		k += 1
		if k >= MISSION_TOP { break }
	}
	if k == 0 { mission_note(i18n.tr("All automatic services are running."), em) }
}

mission_service_menu_items :: proc(app: ^App, name: string) {
	s := &app.services
	u: Win_Service
	found := false
	if s.list != nil {
		for item in s.list.units { if item.name == name { u, found = item, true; break } }
	}
	if !found { ui.menu_close(); return }
	if ui.menu_item(i18n.tr("Show in Services"), icon = lucide.SETTINGS, icon_font = app.icons).clicked { tab_show(app, .Services); service_select(app, name) }
	q := u.pid > 0 ? find_pid(&app.sampler, u.pid) : nil
	if ui.menu_item(i18n.tr("Show its process"), icon = lucide.LAYOUT_LIST, disabled = q == nil, icon_font = app.icons).clicked { processes_reveal(app, q.pid, q.start) }
	if ui.menu_item(cmd_label(.Service_Details), icon = COMMANDS[.Service_Details].icon, icon_font = app.icons).clicked {
		tab_show(app, .Services)
		service_select(app, name)
		if !service_details_shown(app) { service_details_switch(app) }
	}
}
