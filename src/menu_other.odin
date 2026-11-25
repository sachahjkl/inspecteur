#+build !windows
package inspecteur

// Linux and POSIX process menu items, POSIX signals, and systemd service confirmation.

import "core:fmt"
import "core:strings"
import i18n "gt:i18n"
import process "gt:process"
import "gt:ui"

Confirm_Service :: struct {
	action: Service_Action,
	units:  [dynamic]string,   // owned
}

confirm_service_free :: proc(s: ^Confirm_Service) {
	for u in s.units { delete(u) }
	delete(s.units)
	s^ = {}
}

confirm_service_run :: proc(app: ^App, s: ^Confirm_Service) {
	service_act_now(app, s.action, s.units[:])
}

// The service the process belongs to, selected in the Services section (its manager's: the system's or the user's).
go_to_service :: proc(app: ^App, p: ^Proc) {
	if p.unit == "" { return }
	go_to_service_named(app, p.unit_user ? .User : .System, p.unit)
}

row_menu_os_items :: proc(app: ^App) {
	if ui.menu_submenu(cmd_label(.Send_Signal)) {
		for s in SIGNAL_ITEMS {
			if ui.menu_item(i18n.tr(s.label), disabled = !cmd_can(app, .Send_Signal)).clicked { signal_selected(app, s.sig) }
		}
	}
}

row_menu_os_tuning :: proc(app: ^App) {}

// The signals that Send a signal sends (the row's menu, the palette's form), each by its words and its name. The name is
// the value of the palette's form (SIGNAL_ARGUMENTS) and what the demo says it did not send.
SIGNAL_ITEMS := [?]struct { sig: process.Signal, label: string, name: string }{
	{.Hangup, i18n.later("Hang up (SIGHUP)"), "SIGHUP"}, {.Interrupt, i18n.later("Interrupt (SIGINT)"), "SIGINT"}, {.Quit, i18n.later("Quit (SIGQUIT)"), "SIGQUIT"},
	{.Terminate, i18n.later("Terminate (SIGTERM)"), "SIGTERM"}, {.Kill, i18n.later("Kill (SIGKILL)…"), "SIGKILL"}, {.Stop, i18n.later("Stop (SIGSTOP)"), "SIGSTOP"},
	{.Continue, i18n.later("Continue (SIGCONT)"), "SIGCONT"}, {.User1, i18n.later("User 1 (SIGUSR1)"), "SIGUSR1"}, {.User2, i18n.later("User 2 (SIGUSR2)"), "SIGUSR2"},
}

// A signal's name ("SIGHUP"); "" for a signal Send a signal does not offer.
signal_name :: proc(sig: process.Signal) -> string {
	for s in SIGNAL_ITEMS { if s.sig == sig { return s.name } }
	return ""
}

// Sends `sig` to the selected processes (an app's row: its first processes, as End task), with the guards of the others:
// a kill is confirmed; a stop is not sent to Inspecteur, what it runs under or the display server (nothing could resume
// them); a signal that may end them asks first.
signal_selected :: proc(app: ^App, sig: process.Signal) {
	#partial switch sig {
	case .Kill:      kill_selected(app); return
	case .Terminate: end_selected(app); return
	}
	c, ok := chosen_of_selection(app, whole = false)
	defer chosen_free(&c)
	if !ok { return }
	#partial switch sig {
	case .Stop:
		for t in c.targets {
			if guard_of(app, t.pid) != .None { say(app, i18n.tr("Not stopped: it is Inspecteur, runs it or draws the desktop, and nothing could resume it")); return }
		}
		send_signal(app, &c, sig)
	case .Continue:
		send_signal(app, &c, sig)
	case:
		signal_or_confirm(app, &c, sig)
	}
}

// Asks to confirm the stop or the restart of services: one is named, several are counted and listed. `danger`: what
// else ends with them ("" none): Enter cancels then.
confirm_service :: proc(app: ^App, action: Service_Action, units: []string, danger: string) {
	m := &app.menu.confirm
	confirm_free(m)
	m.act = .Service
	m.service.action = action
	for u in units { append(&m.service.units, strings.clone(u)) }
	many := len(units) > 1
	what: string
	switch {
	case action == .Stop && many: what = i18n.tr("They stop, and their processes end; what needs them may stop too.")
	case action == .Stop:         what = i18n.tr("It stops, and its processes end; what needs it may stop too.")
	case many:                    what = i18n.tr("They stop, their processes end, and they start again.")
	case:                         what = i18n.tr("It stops, its processes end, and it starts again.")
	}
	title: string
	switch {
	case action == .Stop && many: title = fmt.tprintf(i18n.tr(len(units), "Stop %d service?", "Stop %d services?"), len(units))
	case action == .Stop:         title = fmt.tprintf(i18n.tr("Stop %s?"), units[0])
	case many:                    title = fmt.tprintf(i18n.tr(len(units), "Restart %d service?", "Restart %d services?"), len(units))
	case:                         title = fmt.tprintf(i18n.tr("Restart %s?"), units[0])
	}
	ui.confirm_open(CONFIRM_VIEW, {
		title = title,
		note = danger != "" ? fmt.tprintf("%s %s", danger, what) : what,
		lines = many ? units : nil,
		act = action == .Stop ? i18n.tr("Stop") : i18n.tr("Restart"),
		enter_confirms = danger == "",
	})
}
