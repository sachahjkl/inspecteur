package inspecteur

// Windows process context menu extensions (Efficiency mode, Analyze wait chain) and SCM service confirmation.

import "core:fmt"
import "core:strings"
import i18n "gt:i18n"
import process "gt:process"
import "gt:ui"

Confirm_Service :: struct {
	action: Win_Service_Action,
	names:  [dynamic]string,   // owned
}

confirm_service_free :: proc(s: ^Confirm_Service) {
	for n in s.names { delete(n) }
	delete(s.names)
	s^ = {}
}

confirm_service_run :: proc(app: ^App, s: ^Confirm_Service) {
	service_act_now(app, s.action, s.names[:])
}

signal_name :: proc(sig: process.Signal) -> string {
	#partial switch sig {
	case .Terminate: return "WM_CLOSE / TerminateProcess"
	case .Kill:      return "TerminateProcess"
	case .Stop:      return "NtSuspendProcess"
	case .Continue:  return "NtResumeProcess"
	}
	return ""
}

// Jumps from a process hosting Windows services to its first service in the Services section.
go_to_service :: proc(app: ^App, p: ^Proc) {
	name := p.unit
	if name == "" { name = p.extra.service_names }
	if name == "" { return }
	if comma := strings.index_byte(name, ','); comma >= 0 { name = name[:comma] }
	go_to_service_named(app, strings.trim_space(name))
}

row_menu_os_items :: proc(app: ^App) {
	cmd_item(app, .Wait_Chain)
}

row_menu_os_tuning :: proc(app: ^App) {
	p := selected_proc(app)
	label := p != nil && p.extra.efficiency ? i18n.tr("Disable efficiency mode") : i18n.tr("Enable efficiency mode")
	cmd_item(app, .Efficiency_Mode, label)
}

// Toggles Windows 11 Efficiency Mode (EcoQoS) on the given process.
efficiency_toggle :: proc(app: ^App, p: ^Proc) {
	name := fmt.tprintf(i18n.tr("%s (PID %d)"), p.name, p.pid)
	want := !p.extra.efficiency
	if app.demo != nil {
		say(app, i18n.tr("The demo's processes are not the system's: Efficiency mode was not changed for %s"), name)
		return
	}
	a := act_new(.Efficiency, name)
	append(&a.targets, Target{p.pid, p.start})
	a.efficiency_on = want
	act_start(app, a)
}

// Opens Properties directly on the Threads & Wait Chain tab and triggers wait-chain analysis.
wait_chain_open :: proc(app: ^App, p: ^Proc) {
	props_open_tab(app, p.pid, p.start, .Threads)
}

// Asks confirmation before stopping or restarting Windows services, naming active dependents if any.
confirm_service :: proc(app: ^App, action: Win_Service_Action, names: []string, danger: string) {
	m := &app.menu.confirm
	confirm_free(m)
	m.act = .Service
	m.service.action = action
	for n in names { append(&m.service.names, strings.clone(n)) }
	many := len(names) > 1
	what: string
	switch {
	case action == .Stop && many: what = i18n.tr("They stop. One that running services need is not stopped: the footer names them.")
	case action == .Stop:         what = i18n.tr("It stops. If running services need it, it is not stopped: the footer names them.")
	case many:                    what = i18n.tr("They stop and start again.")
	case:                         what = i18n.tr("It stops and starts again.")
	}
	title: string
	switch {
	case action == .Stop && many: title = fmt.tprintf(i18n.tr(len(names), "Stop %d service?", "Stop %d services?"), len(names))
	case action == .Stop:         title = fmt.tprintf(i18n.tr("Stop %s?"), names[0])
	case many:                    title = fmt.tprintf(i18n.tr(len(names), "Restart %d service?", "Restart %d services?"), len(names))
	case:                         title = fmt.tprintf(i18n.tr("Restart %s?"), names[0])
	}
	ui.confirm_open(CONFIRM_VIEW, {
		title = title,
		note = danger != "" ? fmt.tprintf("%s %s", danger, what) : what,
		lines = many ? names : nil,
		act = action == .Stop ? i18n.tr("Stop") : i18n.tr("Restart"),
		enter_confirms = danger == "",
	})
}
