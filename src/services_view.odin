package inspecteur

// The Services section (services.odin): a table of the services of the system's manager or of the user's (System and
// User at the right of its bar, Ctrl+U). Its bar, a row's menu and the keys (commands.odin) act on the services
// selected: Start, Stop, Restart, Enable (it starts by itself, at boot or with the user's session), Disable (each on
// those it means something for), Copy name; and on the cursor's: Open in Processes (its main process, selected there).
//
// The selected service's details and journal are a view ("service": views.odin), docked at first under the table, in
// the section's dock space: the user resizes it by the line above it, floats it, puts it in a window of its own or
// docks it elsewhere. A journal on its own docks there too, a tab beside it.

import "core:fmt"
import "core:strings"
import "core:time"
import lucide "gt:lucide"
import "gt:platform"
import "gt:ui"
import i18n "gt:i18n"

// The details' height under the table at first, in ems (then the views' memory).
DETAILS_EM :: 16

build_services :: proc(app: ^App, em: f32) {
	s := &app.services
	if s.rows.table.query != app.query { ui.table_apply(&s.rows.table, &s.rows.data, app.query) }
	note := i18n.tr("Reading…")
	if s.pending != .None {
		note = i18n.tr("Waiting for the service manager…")
	} else if s.list != nil && s.list.manager == s.manager {
		running := 0
		for u in s.list.units { if u.active == "active" && u.sub == "running" { running += 1 } }
		note = fmt.tprintf(i18n.tr(len(s.list.units), "%d service, %d running", "%d services, %d running"), len(s.list.units), running)
	}
	section_bar(app, i18n.tr("Services"), note, em, services_actions, services_manager_choice)
	// (the table is the space's centre; the details and the journals dock around it)
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.views_dock(&app.views, SERVICES_SPACE, {content = true}) {
		empty := ""
		if s.list != nil && s.list.manager == s.manager { empty = s.list.problem != "" ? s.list.problem : i18n.tr("No service.") }
		ev := section_table_build(&s.rows, empty)
		if ev.sorted { ui.table_apply(&s.rows.table, &s.rows.data, app.query) }
		if ev.sorted || ev.resized || ev.moved { section_layout_save(&s.rows, &app.prefs, "services") }
		section_header_menu(&s.rows, ev, "services", em)
		if ev.activated && cmd_can(app, .Service_Open) { service_reveal(app) }
		if ev.menu { services_menu_open(app, ev.menu_at) }
	}
	// (the details follow the selection: another service selected is read at once)
	u, selected := selected_service(app)
	id := selected ? name_id(u.name) : 0
	if service_details_shown(app) && id != s.details_for {
		s.details_for = id
		if selected { details_ask(app, u.name) }
	}
	services_menu(app, em)
}

service_register :: proc(app: ^App) {
	ui.view_register(&app.views, SERVICE_VIEW, service_view, ui.View_Options{
		title = i18n.later("Details and journal"), icon = lucide.SCROLL_TEXT,
		home = .Panel, home_place = {space = SERVICES_SPACE, edge = .Bottom},
		extent_em = DETAILS_EM, width_em = 64, height_em = 40,
	})
}

// Whether the details are open, wherever they are.
service_details_shown :: proc(app: ^App) -> bool { return ui.view_is_open(&app.views, SERVICE_VIEW) }

// Whether the details can be seen now: open, and the Services section shown, unless they are out of it (floating, in a
// window of their own).
service_details_seen :: proc(app: ^App) -> bool {
	if !service_details_shown(app) { return false }
	return app.tab == .Services || ui.view_presentation(&app.views, SERVICE_VIEW) != .Panel
}

// The details' view: the selected service's unit file, since when it is in its state, its tasks, CPU time and restarts,
// and its journal's last lines.
@(private = "file")
service_view :: proc(v: ^ui.View, app: ^App) {
	em := ui.font_size()
	if v.shown { journal_keys(app, &app.services.pane) }
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y, bg = surface("well")})
	pane := ui.build_box({.Clip, .Draw_Background}, "###svc_pane")
	if ui.parent(pane) { service_details_body(app, v, em) }
}

@(private = "file")
service_details_body :: proc(app: ^App, v: ^ui.View, em: f32) {
	s := &app.services
	u, selected := selected_service(app)
	d := s.pane.details
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.2))})
	if ui.row(.Center, {}, "###svc_details_head") {
		ui.view_drag_handle(v, ui.parent_box())
		ui.spacer(ui.px(em * 0.8))
		title := selected ? u.name : i18n.tr("No service selected")
		ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = 0})
		ui.label(fmt.tprintf("%s###svc_details_name", ui.text_shown(title)))
		ui.spacer(ui.px(em * 0.8))
		if ui.tags("weak") {
			info := ""
			if selected && d != nil && d.name == u.name && d.manager == s.manager {
				parts := make([dynamic]string, context.temp_allocator)
				if d.since > 0 { append(&parts, fmt.tprintf(i18n.tr("%s since %s"), unit_word(u.active), started_text(app, d.since))) }
				if d.tasks != DETAIL_UNKNOWN { append(&parts, fmt.tprintf(i18n.tr(int(d.tasks), "%d task", "%d tasks"), d.tasks)) }
				if d.cpu_ns != DETAIL_UNKNOWN { append(&parts, fmt.tprintf(i18n.tr("CPU time %s"), cpu_time_text(d.cpu_ns))) }
				if d.restarts > 0 { append(&parts, fmt.tprintf(i18n.tr(int(d.restarts), "restarted %d time", "restarted %d times"), d.restarts)) }
				if d.file != "" { append(&parts, d.file) }
				info = strings.join(parts[:], "  ·  ", context.temp_allocator)
			}
			ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
			ui.label_tip(fmt.tprintf("%s###svc_details_info", ui.text_shown(info)))
		}
		cmd_button(app, "svc_file", lucide.FILE_TEXT, .Service_Open_File, em)
		// (docked, its own way to close; elsewhere its header has one)
		if v.presentation == .Panel {
			tool := tool_button("svc_details_close", lucide.X, fmt.tprintf(i18n.tr("Hide the details (%s)"), ui.command_shortcut(COMMANDS[.Service_Details])), true, em)
			if tool { service_details_switch(app) }
		}
		ui.spacer(ui.px(em * 0.4))
	}
	journal_build(app, &s.pane, u.name, s.manager, selected, em)
}

// Shows or hides the details (the views' memory keeps whether they are open).
service_details_switch :: proc(app: ^App) {
	if service_details_shown(app) {
		ui.view_close(&app.views, SERVICE_VIEW)
	} else {
		ui.view_open(&app.views, SERVICE_VIEW, app, owner = &app.main.state)
	}
	app.services.details_for = 0
	tab_show(app, .Services)
	say(app, service_details_shown(app) ? i18n.tr("The selected service's details and journal") : i18n.tr("Details hidden"))
}

// The selected service's unit file, opened (the person's text editor).
service_open_file :: proc(app: ^App) {
	d := app.services.pane.details
	if d == nil || d.file == "" { return }
	ui.open(d.file, .Path)
	say(app, i18n.tr("Opened %s"), d.file)
}

// Each period while the section is shown (refresh calls it at each sample).
services_tick :: proc(app: ^App) {
	if app.tab == .Services && time.tick_diff(app.services.next, time.tick_now()) >= 0 && !services_busy(app) { services_ask(app) }
	journal_follow_tick(app)
}

// The milliseconds until the next reading of the services is due, while they are shown, or of the details' journal
// while it is followed (the window wakes for it).
services_due_ms :: proc(app: ^App) -> int {
	if app.paused { return max(int) }
	due := journal_due_ms(app)
	if app.tab == .Services { due = min(due, max(int(time.duration_milliseconds(time.tick_diff(time.tick_now(), app.services.next))) + 1, 1)) }
	return due
}

// Whether a command of the section can act now: an action of the manager on one of the services selected at least, the
// others on the cursor's.
service_can :: proc(app: ^App, c: Cmd) -> bool {
	u, ok := selected_service(app)
	if !ok { return false }
	// (what asks nothing of the manager acts while an action waits)
	if app.services.pending != .None && c != .Service_Open && c != .Service_Copy && c != .Service_Open_File { return false }
	#partial switch c {
	case .Service_Start, .Service_Stop, .Service_Restart, .Service_Enable, .Service_Disable:
		return len(service_targets(app, service_cmd_action(c))) > 0
	case .Service_Open:    return u.pid > 0
	case .Service_Copy:    return true
	case .Service_Open_File:
		d := app.services.pane.details
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
	labels := [2]string{i18n.tr(MANAGER_LABELS[.System]), i18n.tr(MANAGER_LABELS[.User])}
	sel := int(s.manager)
	key := ui.command_shortcut(COMMANDS[.Service_Manager])
	tips := [2]string{fmt.tprintf(i18n.tr("The system's services (%s)"), key), fmt.tprintf(i18n.tr("The user's services (%s)"), key)}
	ui.next({height = ui.px(ui.dense(em * 2))})   // (as wide as its labels: ui.segmented's own width)
	if ui.segmented("svc_manager", labels[:], &sel, tips[:]) { services_switch(app, Manager(sel)) }
}

services_switch :: proc(app: ^App, m: Manager) {
	s := &app.services
	if s.manager == m { return }
	s.manager = m
	app.settings.manager = m
	pref_set(&app.prefs, "services.manager", MANAGER_KEYS[m])
	s.rows.table.vl.sel = -1
	services_rows(app)
	services_ask(app)
}

SERVICES_MENU :: "inspecteur_service_menu"

services_menu_open :: proc(app: ^App, pos: ui.Vec2, from_keyboard := false) {
	if _, ok := selected_service(app); !ok { return }
	ui.menu_open(SERVICES_MENU, pos, from_keyboard = from_keyboard)
}

@(private = "file")
services_menu :: proc(app: ^App, em: f32) {
	if ui.menu(SERVICES_MENU) {
		if _, ok := selected_service(app); !ok { ui.menu_close(); return }
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
		cmd_item(app, .Service_Details, service_details_shown(app) ? i18n.tr("Hide the details") : i18n.tr("Details and journal"))
	}
}

// The action of a command of the manager (.None: the command is not one).
service_cmd_action :: proc(c: Cmd) -> Service_Action {
	#partial switch c {
	case .Service_Start:   return .Start
	case .Service_Stop:    return .Stop
	case .Service_Restart: return .Restart
	case .Service_Enable:  return .Enable
	case .Service_Disable: return .Disable
	}
	return .None
}

// Whether `action` means something for the service `u` (a running one is not started, a disabled one not disabled).
service_takes :: proc(u: Service, action: Service_Action) -> bool {
	running := u.active == "active" || u.active == "activating" || u.active == "reloading"
	#partial switch action {
	case .Start:   return !running && u.load != "masked"
	case .Stop:    return running
	case .Restart: return u.load != "masked" && u.load != "not-found"
	case .Enable:  return u.file == "disabled"
	case .Disable: return u.file == "enabled" || u.file == "enabled-runtime" || u.file == "linked"
	}
	return false
}

// The services selected that `action` means something for, in the order shown.
service_targets :: proc(app: ^App, action: Service_Action) -> []Service {
	s := &app.services
	out := make([dynamic]Service, context.temp_allocator)
	if s.list == nil || s.list.manager != s.manager { return out[:] }
	for r in selected_rows(&s.rows.table) {
		if r < len(s.list.units) && service_takes(s.list.units[r], action) { append(&out, s.list.units[r]) }
	}
	return out[:]
}

// Asks the manager to act on the services selected that the action means something for. Stop and Restart are asked
// first, once for all of them: they end the services' processes.
service_do :: proc(app: ^App, action: Service_Action) {
	targets := service_targets(app, action)
	if len(targets) == 0 { return }
	names := make([]string, len(targets), context.temp_allocator)
	danger := ""
	for u, i in targets {
		names[i] = u.name
		if danger == "" { danger = service_danger(app, u) }
	}
	if action == .Stop || action == .Restart {
		confirm_service(app, action, names, danger)
		return
	}
	service_act_now(app, action, names)
}

// The manager asked to act on `units`; the footer says it is asked, then what came of it (services_take).
service_act_now :: proc(app: ^App, action: Service_Action, units: []string) {
	if app.services.pending != .None || len(units) == 0 { return }
	app.services.pending = action
	if len(units) == 1 {
		say(app, i18n.tr(SERVICE_ACTION_DOING[action]), units[0])
	} else {
		say(app, i18n.tr(SERVICE_ACTION_DOING[action]), fmt.tprintf(i18n.tr(len(units), "%d service", "%d services"), len(units)))
	}
	services_ask(app, action, units)
}

// What else ends when the service `u` stops: the desktop (its main process is the display server), or Inspecteur (its
// main process is one Inspecteur runs under, or Inspecteur runs in that unit). "" when nothing.
service_danger :: proc(app: ^App, u: Service) -> string {
	if u.pid > 0 {
		switch guard_of(app, u.pid) {
		case .Display_Server:  return i18n.tr("It runs the desktop: the session ends with it.")
		case .Self, .Ancestor: return i18n.tr("inspecteur runs under it: inspecteur ends with it.")
		case .None:
		}
	}
	for unit in app.own_units { if unit == u.name { return i18n.tr("inspecteur runs in it: inspecteur ends with it.") } }
	return ""
}

service_reveal :: proc(app: ^App) {
	u, ok := selected_service(app)
	if !ok || u.pid <= 0 { return }
	p := find_pid(&app.sampler, u.pid)
	if p == nil || !processes_reveal(app, p.pid, p.start) { say(app, i18n.tr("PID %d is not in the processes' last sample"), u.pid) }
}

// The names of the services selected, a line each.
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
