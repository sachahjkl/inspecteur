package inspecteur

// The Services section (services.odin): a table of the services of the system's manager or of the user's (System and
// User at the right of its bar, Ctrl+U). Its bar and a row's menu act on the selected service:
//
//   Start              Ctrl+S
//   Stop               Delete
//   Restart            Ctrl+R
//   Enable             Ctrl+E        it starts by itself (at boot, or with the user's session)
//   Disable            Ctrl+D
//   Open in Processes  Enter         its main process, selected in the Processes section
//   Copy name          Ctrl+C

import "core:fmt"
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
	if ev.activated { service_reveal(app) }
	if ev.menu { services_menu_open(app, ev.menu_at) }
	services_menu(app, em)
}

// Each period while the section is shown (refresh calls it at each sample).
services_tick :: proc(app: ^App) {
	if app.tab == .Services && time.tick_diff(app.services.next, time.tick_now()) >= 0 && !ui.worker_busy(&app.services.worker) { services_ask(app) }
}

// The milliseconds until the next reading of the services is due, while they are shown (the window wakes for it).
services_due_ms :: proc(app: ^App) -> int {
	if app.tab != .Services { return max(int) }
	return max(int(time.duration_milliseconds(time.tick_diff(time.tick_now(), app.services.next))) + 1, 1)
}

// What can be done to the selected service now.
@(private = "file")
Service_Can :: struct { start, stop, restart, enable, disable, open, any: bool }

@(private = "file")
service_can :: proc(app: ^App) -> (can: Service_Can) {
	u, ok := selected_service(app)
	if !ok || app.services.pending != .None { return }
	running := u.active == "active" || u.active == "activating" || u.active == "reloading"
	can.any = true
	can.start = !running && u.load != "masked"
	can.stop = running
	can.restart = u.load != "masked" && u.load != "not-found"
	can.enable = u.file == "disabled"
	can.disable = u.file == "enabled" || u.file == "enabled-runtime" || u.file == "linked"
	can.open = u.pid > 0
	return
}

@(private = "file")
services_actions :: proc(app: ^App, em: f32) {
	can := service_can(app)
	if tool_button(app, "svc_start", lucide.PLAY, "Start (Ctrl+S)", can.start, em) { service_do(app, .Start) }
	if tool_button(app, "svc_stop", lucide.SQUARE, "Stop (Delete)", can.stop, em) { service_do(app, .Stop) }
	if tool_button(app, "svc_restart", lucide.ROTATE_CCW, "Restart (Ctrl+R)", can.restart, em) { service_do(app, .Restart) }
	vrule(em)
	if tool_button(app, "svc_enable", lucide.CHECK, "Enable: it starts by itself (Ctrl+E)", can.enable, em) { service_do(app, .Enable) }
	if tool_button(app, "svc_disable", lucide.X, "Disable: it does not start by itself (Ctrl+D)", can.disable, em) { service_do(app, .Disable) }
	vrule(em)
	if tool_button(app, "svc_open", lucide.LAYOUT_LIST, "Open in Processes (Enter)", can.open, em) { service_reveal(app) }
	if tool_button(app, "svc_copy", lucide.COPY, "Copy name (Ctrl+C)", can.any, em) { service_copy(app) }
}

// System or User, at the right of the bar.
@(private = "file")
services_manager_choice :: proc(app: ^App, em: f32) {
	s := &app.services
	labels := [2]string{MANAGER_LABELS[.System], MANAGER_LABELS[.User]}
	sel := int(s.manager)
	ui.next({width = ui.px(em * 10), height = ui.px(ui.dense(em * 2))})
	if ui.segmented("svc_manager", labels[:], &sel) { services_switch(app, Manager(sel)) }
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

// The keys of the section (view_keys calls it when no menu or dialog is open). `field_keeps`: the filter keeps Delete.
services_keys :: proc(app: ^App, field_keeps: bool) {
	s := &app.services
	keys := ui.table_keys(&s.rows.table)
	can := service_can(app)
	if ui.key_press(.U, {.Ctrl}) { services_switch(app, s.manager == .System ? .User : .System) }
	if ui.key_press(.S, {.Ctrl}) && can.start { service_do(app, .Start) }
	if ui.key_press(.R, {.Ctrl}) && can.restart { service_do(app, .Restart) }
	if ui.key_press(.E, {.Ctrl}) && can.enable { service_do(app, .Enable) }
	if ui.key_press(.D, {.Ctrl}) && can.disable { service_do(app, .Disable) }
	if !field_keeps {
		if ui.key_press(.Delete) && can.stop { service_do(app, .Stop) }
		if ui.key_press(.C, {.Ctrl}) && can.any { service_copy(app) }
	}
	if keys.activated && can.open { service_reveal(app) }
	if keys.menu { services_menu_open(app, keys.menu_at, true) }
}

@(private = "file")
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
	if ui.ctx_menu(s.menu, em * MENU_WIDTH_EM) {
		if _, ok := selected_service(app); !ok { ui.ctx_menu_close(); return }
		can := service_can(app)
		if ui.menu_item("Start", "Ctrl+S", enabled = can.start).clicked { service_do(app, .Start) }
		if ui.menu_item("Stop", "Delete", enabled = can.stop).clicked { service_do(app, .Stop) }
		if ui.menu_item("Restart", "Ctrl+R", enabled = can.restart).clicked { service_do(app, .Restart) }
		ui.menu_separator()
		if ui.menu_item("Enable", "Ctrl+E", enabled = can.enable).clicked { service_do(app, .Enable) }
		if ui.menu_item("Disable", "Ctrl+D", enabled = can.disable).clicked { service_do(app, .Disable) }
		ui.menu_separator()
		if ui.menu_item("Open in Processes", "Enter", enabled = can.open).clicked { service_reveal(app) }
		if ui.menu_item("Copy name", "Ctrl+C").clicked { service_copy(app) }
	}
}

// Asks the manager to act on the selected service; the footer says it is asked, then what came of it (services_take).
@(private = "file")
service_do :: proc(app: ^App, action: Service_Action) {
	u, ok := selected_service(app)
	if !ok { return }
	app.services.pending = action
	say(app, "%s %s…", SERVICE_ACTION_DOING[action], u.name)
	services_ask(app, action, u.name)
}

@(private = "file")
service_reveal :: proc(app: ^App) {
	u, ok := selected_service(app)
	if !ok || u.pid <= 0 { return }
	p := find_pid(&app.sampler, u.pid)
	if p == nil || !processes_reveal(app, p.pid, p.start) { say(app, "PID %d is not in the processes' last sample", u.pid) }
}

@(private = "file")
service_copy :: proc(app: ^App) {
	u, ok := selected_service(app)
	if !ok { return }
	platform.set_clipboard(app.main.win, u.name)
	say(app, "Copied %s", u.name)
}
