package inspecteur

// What can be done to a process: its menu (a right click on its row, the Menu key, Shift+F10), the toolbar, the keys
// (commands.odin), the Properties dialog.
//
//   End task            Delete        the process is asked to end (SIGTERM): it may save, or refuse
//   Kill…               Shift+Delete  it ends at once (SIGKILL), after a confirmation
//   Suspend or resume   Ctrl+P        it stops running until it is resumed (SIGSTOP, SIGCONT)
//   Raise, lower the priority   Ctrl+Up, Ctrl+Down
//   Open file location  Ctrl+O        the executable's folder in the file manager
//   Copy command line   Ctrl+C
//   Properties          Alt+Enter     its details, threads, files, modules and environment (props_view.odin)
//
// On an app's row, End task asks the app's processes to end (group_roots: each instance's first process): the
// processes under them end with them, as when the app's windows are closed. Kill ends every process of the group.
//
// A signal goes only to the processes that were chosen: the toolkit pins each pid with a pidfd and reads its start time
// again before it signals (a pid given to another process since the sample is not signalled). Inspecteur, the
// processes it runs under and the display server are never suspended: nothing could resume them from here. Ending the
// display server ends the session: it is asked first.

import "core:fmt"
import "core:os"
import "core:strings"
import process "gt:process"
import "core:time"
import "gt:platform"
import "gt:ui"

CONFIRM_WIDTH_EM :: 29
// After a signal, the next sample comes this soon: the row goes as the process ends.
SAMPLE_AFTER_SIGNAL :: 300 * time.Millisecond

// A process chosen: its pid and its start time (its identity).
Target :: struct { pid: i32, start: u64 }

// What a menu or a confirmation acts on: the processes, and the name it says (owned).
Chosen :: struct {
	targets: [dynamic]Target,
	name:    string,
}

Row_Menu :: struct {
	key:          ui.Key,
	confirm_open: bool,           // the confirmation of a kill (or of the end of the display server)
	confirm:      Chosen,
	confirm_sig:  process.Signal,
	confirm_note: string,         // owned: why it is asked
}

chosen_free :: proc(c: ^Chosen) {
	delete(c.targets)
	delete(c.name)
	c^ = {}
}

row_menu_destroy :: proc(m: ^Row_Menu) {
	chosen_free(&m.confirm)
	delete(m.confirm_note)
}

// The process the selected row stands for: its own, or a group's first app process; nil when none.
selected_proc :: proc(app: ^App) -> ^Proc {
	r, ok := selected_row(app)
	if !ok { return nil }
	p, has := row_process(app, r)
	return has ? p : nil
}

// Whether the selected row is a process's (not an app's group).
selected_is_process :: proc(app: ^App) -> bool {
	r, ok := selected_row(app)
	return ok && r.kind == .Process
}

// What the selected row stands for: its process, or an app's processes (`whole`: every process of the group; else the
// app's own, whose children end with them).
@(private = "file")
chosen_of_selection :: proc(app: ^App, whole: bool) -> (c: Chosen, ok: bool) {
	r, has := selected_row(app)
	if !has { return }
	#partial switch r.kind {
	case .Process:
		p := app.sampler.procs[r.index]
		append(&c.targets, Target{p.pid, p.start})
		c.name = strings.clone(fmt.tprintf("%s (PID %d)", p.name, p.pid))
	case .App:
		g := app.table.groups[r.index]
		members := whole ? app.table.members[g.first:][:g.count] : group_roots(&app.table, g)
		for i in members { append(&c.targets, Target{app.sampler.procs[i].pid, app.sampler.procs[i].start}) }
		name := app.catalog.entries[g.entry].name
		switch {
		case len(members) == 1: c.name = strings.clone(fmt.tprintf("%s (PID %d)", name, app.sampler.procs[members[0]].pid))
		case whole:             c.name = strings.clone(fmt.tprintf("%s (%d processes)", name, len(members)))
		case:                   c.name = strings.clone(fmt.tprintf("%s (%d instances)", name, len(members)))
		}
	case:
		return
	}
	return c, len(c.targets) > 0
}

// Opens the menu of the selected row at `pos` (window pixels).
row_menu_open :: proc(app: ^App, pos: ui.Vec2, from_keyboard := false) {
	if selected_proc(app) == nil { return }
	m := &app.menu
	if m.key == 0 { m.key = ui.key_from_string(0, "inspecteur_row_menu") }
	ui.ctx_menu_open(m.key, pos, from_keyboard = from_keyboard)
}

// The menu and the confirmation, when open (built at the end of the window's build).
row_menu_build :: proc(app: ^App, em: f32) {
	if app.menu.key != 0 { row_menu_items(app) }
	confirm_build(app, em)
}

@(private = "file")
row_menu_items :: proc(app: ^App) {
	if ui.ctx_menu(app.menu.key) {
		if selected_proc(app) == nil { ui.ctx_menu_close(); return }
		cmd_item(app, .End_Task)
		cmd_item(app, .Kill)
		p := selected_proc(app)
		cmd_item(app, .Suspend, p != nil && p.state == .Stopped ? "Resume" : "Suspend")
		ui.menu_separator()
		cmd_item(app, .Raise_Priority)
		cmd_item(app, .Lower_Priority)
		ui.menu_separator()
		cmd_item(app, .Open_Location)
		cmd_item(app, .Copy_Command)
		ui.menu_separator()
		cmd_item(app, .Properties)
	}
}

// The executable's folder in the file manager.
open_location :: proc(app: ^App, p: ^Proc) {
	if p.exe == "" { return }
	if platform.reveal_in_folder(p.exe) { say(app, "Opened the folder of %s", p.exe) } else { say(app, "No file manager opens %s", p.exe) }
}

copy_command :: proc(app: ^App, p: ^Proc) {
	if p.cmdline == "" { return }
	platform.set_clipboard(app.main.win, p.cmdline)
	say(app, "Copied the command line of %s", p.name)
}

// Asks the selected row's processes to end (SIGTERM).
end_selected :: proc(app: ^App) {
	c, ok := chosen_of_selection(app, whole = false)
	defer chosen_free(&c)
	if ok { signal_or_confirm(app, &c, .Terminate) }
}

// Asks to confirm a kill of the selected row's processes (an app's: all of them).
kill_selected :: proc(app: ^App) {
	c, ok := chosen_of_selection(app, whole = true)
	defer chosen_free(&c)
	if ok { confirm_ask(app, c, .Kill) }
}

// Suspends the selected process, or resumes it when it is suspended.
suspend_selected :: proc(app: ^App) {
	p := selected_proc(app)
	if p == nil || !selected_is_process(app) { return }
	suspend_or_resume(app, p)
}

suspend_or_resume :: proc(app: ^App, p: ^Proc) {
	c := Chosen{name = fmt.tprintf("%s (PID %d)", p.name, p.pid)}
	append(&c.targets, Target{p.pid, p.start})
	defer delete(c.targets)
	// (the state now, not the last sample's: the process may have been resumed since)
	state := app.demo != nil ? p.state : proc_state_now(p.pid, p.start)
	if state == .Stopped { send_signal(app, &c, .Continue); return }
	switch guard_of(app, p.pid) {
	case .None:           send_signal(app, &c, .Stop)
	case .Self:           say(app, "Inspecteur does not suspend itself: nothing could resume it")
	case .Ancestor:       say(app, "%s runs Inspecteur: suspended, it would stop Inspecteur too", c.name)
	case .Display_Server: say(app, "%s draws the desktop: suspended, it would freeze every window, this one too", c.name)
	}
}

// What a process is to Inspecteur: itself, a process it runs under, the display server, or none of them.
Guard :: enum u8 { None, Self, Ancestor, Display_Server }

guard_of :: proc(app: ^App, pid: i32) -> Guard {
	own := i32(os.get_pid())
	if pid == own { return .Self }
	if app.display_server > 0 && pid == app.display_server { return .Display_Server }
	// (the line of parents, as the last sample has it)
	q := find_pid(&app.sampler, own)
	for steps := 0; q != nil && steps < 64; steps += 1 {
		if q.ppid == pid { return .Ancestor }
		if q.ppid <= 1 { break }
		q = find_pid(&app.sampler, q.ppid)
	}
	return .None
}

// Sends `sig`, but asks first when it would end the display server (the session ends with it).
signal_or_confirm :: proc(app: ^App, c: ^Chosen, sig: process.Signal) {
	for t in c.targets {
		if guard_of(app, t.pid) == .Display_Server { confirm_ask(app, c^, sig); return }
	}
	send_signal(app, c, sig)
}

confirm_ask :: proc(app: ^App, c: Chosen, sig: process.Signal) {
	m := &app.menu
	chosen_free(&m.confirm)
	for t in c.targets { append(&m.confirm.targets, t) }
	m.confirm.name = strings.clone(c.name)
	m.confirm_sig = sig
	delete(m.confirm_note)
	server := false
	for t in c.targets { if guard_of(app, t.pid) == .Display_Server { server = true } }
	switch {
	case server:
		m.confirm_note = strings.clone("It draws the desktop: the session ends with it, and every program of the session with it.")
	case sig == .Kill:
		m.confirm_note = strings.clone("It ends at once, without the chance to save its work. End task asks it to end on its own.")
	case:
		m.confirm_note = strings.clone("It is asked to end.")
	}
	m.confirm_open = true
}

@(private = "file")
confirm_build :: proc(app: ^App, em: f32) {
	m := &app.menu
	w := em * CONFIRM_WIDTH_EM
	verb := m.confirm_sig == .Kill ? "Kill" : "End"
	if ui.modal("kill", w, &m.confirm_open) {
		pad := em * 1.2
		if ui.style({width = ui.px(w)}) {
			ui.spacer(ui.px(pad))
			ui.next({width = ui.px(w), height = ui.children_sum()})
			if ui.row() {
				ui.spacer(ui.px(pad))
				ui.next({width = ui.px(w - 2 * pad), height = ui.children_sum(), axis = .Y})
				if ui.column() {
					ui.next({width = ui.fill(), font_size = em * 1.15})
					ui.paragraph(fmt.tprintf("%s %s?###kill_title", verb, ui.text_shown(m.confirm.name)))
					ui.spacer(ui.px(em * 0.4))
					if ui.tags("weak") {
						ui.next({width = ui.fill()})
						ui.paragraph(fmt.tprintf("%s###kill_text", m.confirm_note))
					}
					ui.spacer(ui.px(em * 1.1))
					ui.next({width = ui.fill(), height = ui.children_sum()})
					if ui.row() {
						ui.spacer(ui.fill())
						ui.next({width = ui.text_size(em * 1.2), height = ui.px(ui.dense(em * 2.2))})
						if ui.button("Cancel###kill_cancel").clicked { m.confirm_open = false }
						ui.spacer(ui.px(em * 0.6))
						ui.next({width = ui.text_size(em * 1.2), height = ui.px(ui.dense(em * 2.2))})
						if ui.tags("danger_button") {
							if ui.button(fmt.tprintf("%s###kill_confirm", verb)).clicked || ui.key_press(.Return) {
								send_signal(app, &m.confirm, m.confirm_sig)
								m.confirm_open = false
							}
						}
					}
				}
			}
			ui.spacer(ui.px(pad))
		}
	}
}

// Sends `sig` to each process chosen that is still that process; says what came of it.
send_signal :: proc(app: ^App, c: ^Chosen, sig: process.Signal) {
	if app.demo != nil { say(app, "The demo's processes are not the system's: nothing was sent"); return }
	sent := 0
	refused: process.Act_Result
	errno := 0
	owner := ""
	for t in c.targets {
		p := find_proc(&app.sampler, t.pid, t.start)
		if p == nil { continue }
		#partial switch r, e := process.signal_process(t.pid, t.start, sig); r {
		case .Done: sent += 1
		case .Gone:   // (it ended in between)
		case:
			refused, errno = r, e
			owner = p.user
		}
	}
	verb := "end"
	#partial switch sig {
	case .Stop:     verb = "suspend"
	case .Continue: verb = "resume"
	}
	switch {
	case refused == .Denied:
		say(app, "%s is %s's: Inspecteur may not %s it (only its owner, or root, may)", c.name, owner, verb)
	case refused != .Done:
		say(app, "%s cannot be %s (error %d)", c.name, verb == "end" ? "ended" : fmt.tprintf("%sed", verb), errno)
	case sent > 0:
		#partial switch sig {
		case .Kill:     say(app, "Killed %s", c.name)
		case .Stop:     say(app, "Suspended %s", c.name)
		case .Continue: say(app, "Resumed %s", c.name)
		case:           say(app, "Asked %s to end", c.name)
		}
	case:
		say(app, "%s has ended already", c.name)
	}
	if sent > 0 {
		// (the rows say it at once: a suspended process is shown suspended before the next sample)
		#partial switch sig {
		case .Stop, .Continue:
			for t in c.targets { if p := find_proc(&app.sampler, t.pid, t.start); p != nil { p.state = sig == .Stop ? .Stopped : .Sleeping } }
		}
		sample_soon(app)
	}
}

// The next sample comes soon: the rows show what an action did.
sample_soon :: proc(app: ^App) {
	app.next_sample = time.tick_add(time.tick_now(), SAMPLE_AFTER_SIGNAL)
	app.sample_extra = true
}

// Opens the Properties of the selected row's process (an app's: its first process).
props_selected :: proc(app: ^App) {
	if p := selected_proc(app); p != nil {
		app.props.demo = app.demo
		props_open(&app.props, p.pid, p.start)
	}
}

// Enter: an app's group opens or closes; a process shows its Properties.
default_action :: proc(app: ^App) {
	r, ok := selected_row(app)
	if !ok { return }
	if r.kind == .App { group_toggle(app, r) } else { props_selected(app) }
}

// Sets a process's nice value, on each of its threads. A user may only lower a priority (raise the nice value): a
// higher one needs root.
set_priority :: proc(app: ^App, p: ^Proc, nice: i8) {
	if app.demo != nil { say(app, "The demo's processes are not the system's: nothing was changed"); return }
	#partial switch r, _ := process.set_priority(p.pid, p.start, int(nice)); r {
	case .Gone:
		say(app, "%s has ended already", p.name)
	case .Done:
		say(app, "%s (PID %d) now runs at nice %d", p.name, p.pid, nice)
		p.nice = nice
		sample_soon(app)
	case .Denied:
		say(app, "Access denied: only root may raise a priority, or change another user's process")
	case:
		say(app, "The priority of %s cannot be changed", p.name)
	}
}

// One step of PRIORITIES up (-1: a higher priority) or down (+1) from the process's nice value.
priority_step :: proc(app: ^App, p: ^Proc, dir: int) {
	i, ok := priority_next(p.nice, dir)
	if !ok { say(app, "%s runs at the %s priority offered already", p.name, dir < 0 ? "highest" : "lowest"); return }
	set_priority(app, p, PRIORITIES[i].nice)
}

// The line of PRIORITIES one step from `nice`: the nearest higher priority (a lower nice value) for `dir` -1, the
// nearest lower one for +1. False: there is none.
priority_next :: proc(nice: i8, dir: int) -> (i: int, ok: bool) {
	if dir < 0 {
		for k := len(PRIORITIES) - 1; k >= 0; k -= 1 { if PRIORITIES[k].nice < nice { return k, true } }
		return
	}
	for q, k in PRIORITIES { if q.nice > nice { return k, true } }
	return
}
