package inspecteur

// The Services section (services.odin): a table of the services of the system's manager or of the user's (System and
// User at the right of its bar, Ctrl+U). Its bar, a row's menu and the keys (commands.odin) act on the selected service:
// Start, Stop, Restart, Enable (it starts by itself, at boot or with the user's session), Disable, Open in Processes
// (its main process, selected there), Copy name.

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
	if ev.activated && cmd_can(app, .Service_Open) { service_reveal(app) }
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

// Whether a command of the section can act on the selected service now.
service_can :: proc(app: ^App, c: Cmd) -> bool {
	u, ok := selected_service(app)
	if !ok || app.services.pending != .None { return false }
	running := u.active == "active" || u.active == "activating" || u.active == "reloading"
	#partial switch c {
	case .Service_Start:   return !running && u.load != "masked"
	case .Service_Stop:    return running
	case .Service_Restart: return u.load != "masked" && u.load != "not-found"
	case .Service_Enable:  return u.file == "disabled"
	case .Service_Disable: return u.file == "enabled" || u.file == "enabled-runtime" || u.file == "linked"
	case .Service_Open:    return u.pid > 0
	case .Service_Copy:    return true
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
	}
}

// Asks the manager to act on the selected service; the footer says it is asked, then what came of it (services_take).
service_do :: proc(app: ^App, action: Service_Action) {
	u, ok := selected_service(app)
	if !ok { return }
	app.services.pending = action
	say(app, "%s %s…", SERVICE_ACTION_DOING[action], u.name)
	services_ask(app, action, u.name)
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
