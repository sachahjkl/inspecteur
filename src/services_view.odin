package inspecteur

// The Services section (services.odin): a table of the services of the system's manager or of the user's (System and
// User at the right of its bar, Ctrl+U). Its bar, a row's menu and the keys (commands.odin) act on the selected service:
// Start, Stop, Restart, Enable (it starts by itself, at boot or with the user's session), Disable, Open in Processes
// (its main process, selected there), Copy name.

import "core:fmt"
import "core:strings"
import "core:time"
import lucide "gt:lucide"
import "gt:platform"
import "gt:ui"

build_services :: proc(app: ^App, em: f32) {
	s := &app.services
	if s.rows.table.query != app.query { ui.table_apply(&s.rows.table, &s.rows.data, app.query) }
	note := "Reading…"
	if s.pending != .None {
		note = "Waiting for the service manager…"
	} else if s.list != nil && s.list.manager == s.manager {
		running := 0
		for u in s.list.units { if u.active == "active" && u.sub == "running" { running += 1 } }
		note = fmt.tprintf("%s, %d running", count_text(len(s.list.units), "service", "services"), running)
	}
	section_bar(app, "Services", note, em, services_actions, services_manager_choice)
	empty := ""
	if s.list != nil && s.list.manager == s.manager { empty = s.list.problem != "" ? s.list.problem : "No service." }
	ev := section_table_build(&s.rows, empty)
	if ev.sorted { ui.table_apply(&s.rows.table, &s.rows.data, app.query) }
	if ev.sorted || ev.resized { section_layout_save(&s.rows.table, &app.prefs, "services") }
	if ev.activated && cmd_can(app, .Service_Open) { service_reveal(app) }
	if ev.menu { services_menu_open(app, ev.menu_at) }
	// (the pane follows the selection: another service selected is read at once)
	u, selected := selected_service(app)
	id := selected ? name_id(u.name) : 0
	if app.settings.details && id != s.details_for {
		s.details_for = id
		if selected { details_ask(app, u.name) }
	}
	if app.settings.details { service_details_build(app, em) }
	services_menu(app, em)
}

// The pane under the table: the selected service's unit file, since when it is in its state, its tasks, CPU time and
// restarts, and its journal's last lines.
@(private = "file")
service_details_build :: proc(app: ^App, em: f32) {
	s := &app.services
	u, selected := selected_service(app)
	d := s.details
	// (the line above the pane, dragged, sets its height: kept when let go)
	h := app.settings.details_em
	ui.next({width = ui.fill()})
	split := ui.splitter("###svc_split", .Y, &h, DETAILS_MIN_EM, DETAILS_MAX_EM, {after = true, unit = em, flush = true, line_at = .Start})
	if split.changed { app.settings.details_em = h }
	if split.finished { pref_save(&app.prefs, "services.details_height", fmt.tprintf("%.1f", h)) }
	ui.next({width = ui.fill(), height = ui.px(em * app.settings.details_em), axis = .Y, bg = surface("well")})
	pane := ui.build_box({.Clip, .Draw_Background, .Draw_Side_Top}, "###svc_pane")
	if ui.parent(pane) { service_details_body(app, u, selected, d, em) }
}

@(private = "file")
service_details_body :: proc(app: ^App, u: Service, selected: bool, d: ^Unit_Details, em: f32) {
	s := &app.services
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.2))})
	if ui.row(.Center, {}, "###svc_details_head") {
		ui.spacer(ui.px(em * 0.8))
		title := selected ? u.name : "No service selected"
		ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = 0})
		ui.label(fmt.tprintf("%s###svc_details_name", ui.text_shown(title)))
		ui.spacer(ui.px(em * 0.8))
		if ui.tags("weak") {
			info := ""
			if selected && d != nil && d.name == u.name && d.manager == s.manager {
				parts := make([dynamic]string, context.temp_allocator)
				if d.since > 0 { append(&parts, fmt.tprintf("%s since %s", u.active, started_text(app, d.since))) }
				if d.tasks != DETAIL_UNKNOWN { append(&parts, count_text(int(d.tasks), "task", "tasks")) }
				if d.cpu_ns != DETAIL_UNKNOWN { append(&parts, fmt.tprintf("CPU time %s", cpu_time_text(d.cpu_ns))) }
				if d.restarts > 0 { append(&parts, fmt.tprintf("restarted %s", count_text(int(d.restarts), "time", "times"))) }
				if d.file != "" { append(&parts, d.file) }
				info = strings.join(parts[:], "  ·  ", context.temp_allocator)
			}
			ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
			label_tip(fmt.tprintf("%s###svc_details_info", ui.text_shown(info)), info)
		}
		cmd_button(app, "svc_file", lucide.FILE_TEXT, .Service_Open_File, em)
		tool := tool_button(app, "svc_details_close", lucide.X, fmt.tprintf("Hide the details (%s)", ui.command_shortcut(COMMANDS[.Service_Details])), true, em)
		if tool { service_details_switch(app) }
		ui.spacer(ui.px(em * 0.4))
	}
	journal_build(app, u, selected, d, em)
}

// The pane's height at least and at most, in ems (services.details_height).
DETAILS_MIN_EM :: 6
DETAILS_MAX_EM :: 80

// Shows or hides the pane of the details (written to services.details).
service_details_switch :: proc(app: ^App) {
	app.settings.details = !app.settings.details
	pref_save(&app.prefs, "services.details", app.settings.details ? "true" : "false")
	app.services.details_for = 0
	tab_show(app, .Services)
	say(app, app.settings.details ? "The selected service's details and journal" : "Details hidden")
}

// The selected service's unit file, opened (the person's text editor).
service_open_file :: proc(app: ^App) {
	d := app.services.details
	if d == nil || d.file == "" { return }
	if platform.open_path(d.file) { say(app, "Opened %s", d.file) } else { say(app, "No program opens %s", d.file) }
}

// Each period while the section is shown (refresh calls it at each sample).
services_tick :: proc(app: ^App) {
	if app.tab == .Services && time.tick_diff(app.services.next, time.tick_now()) >= 0 && !ui.worker_busy(&app.services.worker) { services_ask(app) }
	journal_follow_tick(app)
}

// The milliseconds until the next reading of the services is due, while they are shown (the window wakes for it).
services_due_ms :: proc(app: ^App) -> int {
	if app.tab != .Services || app.paused { return max(int) }
	return min(max(int(time.duration_milliseconds(time.tick_diff(time.tick_now(), app.services.next))) + 1, 1), journal_due_ms(app))
}

// Whether a command of the section can act on the selected service now.
service_can :: proc(app: ^App, c: Cmd) -> bool {
	u, ok := selected_service(app)
	if !ok { return false }
	// (what asks nothing of the manager acts while an action waits)
	if app.services.pending != .None && c != .Service_Open && c != .Service_Copy && c != .Service_Open_File { return false }
	running := u.active == "active" || u.active == "activating" || u.active == "reloading"
	#partial switch c {
	case .Service_Start:   return !running && u.load != "masked"
	case .Service_Stop:    return running
	case .Service_Restart: return u.load != "masked" && u.load != "not-found"
	case .Service_Enable:  return u.file == "disabled"
	case .Service_Disable: return u.file == "enabled" || u.file == "enabled-runtime" || u.file == "linked"
	case .Service_Open:    return u.pid > 0
	case .Service_Copy:    return true
	case .Service_Open_File:
		d := app.services.details
		return d != nil && d.name == u.name && d.manager == app.services.manager && d.file != ""
	}
	return false
}

@(private = "file")
services_actions :: proc(app: ^App, em: f32) {
	cmd_button(app, "svc_start", lucide.PLAY, .Service_Start, em)
	cmd_button(app, "svc_stop", lucide.SQUARE, .Service_Stop, em)
	cmd_button(app, "svc_restart", lucide.ROTATE_CCW, .Service_Restart, em)
	vrule(em)
	cmd_button(app, "svc_enable", lucide.CHECK, .Service_Enable, em)
	cmd_button(app, "svc_disable", lucide.X, .Service_Disable, em)
	vrule(em)
	cmd_button(app, "svc_open", lucide.LAYOUT_LIST, .Service_Open, em)
	cmd_button(app, "svc_copy", lucide.COPY, .Service_Copy, em)
	vrule(em)
	cmd_button(app, "svc_details", lucide.SCROLL_TEXT, .Service_Details, em)
}

// System or User, at the right of the bar.
@(private = "file")
services_manager_choice :: proc(app: ^App, em: f32) {
	s := &app.services
	labels := [2]string{MANAGER_LABELS[.System], MANAGER_LABELS[.User]}
	sel := int(s.manager)
	key := ui.command_shortcut(COMMANDS[.Service_Manager])
	tips := [2]string{fmt.tprintf("The system's services (%s)", key), fmt.tprintf("The user's services (%s)", key)}
	ui.next({width = ui.px(em * 10), height = ui.px(ui.dense(em * 2))})
	if ui.segmented("svc_manager", labels[:], &sel, tips[:]) { services_switch(app, Manager(sel)) }
}

services_switch :: proc(app: ^App, m: Manager) {
	s := &app.services
	if s.manager == m { return }
	s.manager = m
	app.settings.manager = m
	pref_save(&app.prefs, "services.manager", MANAGER_KEYS[m])
	s.rows.table.vl.sel = -1
	services_rows(app)
	services_ask(app)
}

services_menu_open :: proc(app: ^App, pos: ui.Vec2, from_keyboard := false) {
	s := &app.services
	if _, ok := selected_service(app); !ok { return }
	if s.menu == 0 { s.menu = ui.key_from_string(0, "inspecteur_service_menu") }
	ui.ctx_menu_open(s.menu, pos, from_keyboard = from_keyboard)
}

@(private = "file")
services_menu :: proc(app: ^App, em: f32) {
	s := &app.services
	if s.menu == 0 { return }
	if ui.ctx_menu(s.menu) {
		if _, ok := selected_service(app); !ok { ui.ctx_menu_close(); return }
		cmd_item(app, .Service_Start)
		cmd_item(app, .Service_Stop)
		cmd_item(app, .Service_Restart)
		ui.menu_separator()
		cmd_item(app, .Service_Enable)
		cmd_item(app, .Service_Disable)
		ui.menu_separator()
		cmd_item(app, .Service_Open)
		cmd_item(app, .Service_Copy)
		cmd_item(app, .Service_Open_File)
		ui.menu_separator()
		cmd_item(app, .Service_Details, app.settings.details ? "Hide the details" : "Details and journal")
	}
}

// Asks the manager to act on the selected service. Stop and Restart are asked first: they end the service's processes.
service_do :: proc(app: ^App, action: Service_Action) {
	u, ok := selected_service(app)
	if !ok { return }
	if action == .Stop || action == .Restart {
		confirm_service(app, action, u.name, service_danger(app, u))
		return
	}
	service_act_now(app, action, u.name)
}

// The manager asked to act on `unit`; the footer says it is asked, then what came of it (services_take).
service_act_now :: proc(app: ^App, action: Service_Action, unit: string) {
	if app.services.pending != .None { return }
	app.services.pending = action
	say(app, "%s %s…", SERVICE_ACTION_DOING[action], unit)
	services_ask(app, action, unit)
}

// What else ends when the service `u` stops: the desktop (its main process is the display server), or Inspecteur (its
// main process is one Inspecteur runs under, or Inspecteur runs in that unit). "" when nothing.
service_danger :: proc(app: ^App, u: Service) -> string {
	if u.pid > 0 {
		switch guard_of(app, u.pid) {
		case .Display_Server:  return "It runs the desktop: the session ends with it."
		case .Self, .Ancestor: return "Inspecteur runs under it: Inspecteur ends with it."
		case .None:
		}
	}
	for unit in app.own_units { if unit == u.name { return "Inspecteur runs in it: Inspecteur ends with it." } }
	return ""
}

service_reveal :: proc(app: ^App) {
	u, ok := selected_service(app)
	if !ok || u.pid <= 0 { return }
	p := find_pid(&app.sampler, u.pid)
	if p == nil || !processes_reveal(app, p.pid, p.start) { say(app, "PID %d is not in the processes' last sample", u.pid) }
}

service_copy :: proc(app: ^App) {
	u, ok := selected_service(app)
	if !ok { return }
	platform.set_clipboard(app.main.win, u.name)
	say(app, "Copied %s", u.name)
}
