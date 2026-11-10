package inspecteur

// What can be done to a process: its menu (a right click on its row, the Menu key, Shift+F10), the End task button,
// the keys.
//
//   End task            Delete        SIGTERM: the process is asked to end (it may save, or refuse)
//   Kill…               Shift+Delete  SIGKILL, after a confirmation: it ends at once
//   Open file location                the executable's folder in the file manager
//   Copy command line
//   Properties          Alt+Enter     the process's details, its threads, files, modules and environment (props_view.odin)
//
// On an app's row they act on the app's processes (group_roots: each instance's first process); the processes under
// them end with them, as when the app's windows are closed. A signal goes only to the processes that were chosen: each
// pid and its start time are checked again just before (a pid freed and given to a new process is not the one chosen).

import "core:fmt"
import "core:strings"
import "core:sys/linux"
import "core:time"
import "gt:platform"
import "gt:ui"

MENU_WIDTH_EM :: 15
KILL_WIDTH_EM :: 27
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
	key:       ui.Key,
	menu:      Chosen,   // what the menu was opened on
	kill_open: bool,     // the confirmation of a kill
	kill:      Chosen,
}

chosen_free :: proc(c: ^Chosen) {
	delete(c.targets)
	delete(c.name)
	c^ = {}
}

row_menu_destroy :: proc(m: ^Row_Menu) {
	chosen_free(&m.menu)
	chosen_free(&m.kill)
}

// What the selected row stands for: its process, or an app's processes.
@(private = "file")
chosen_of_selection :: proc(app: ^App) -> (c: Chosen, ok: bool) {
	r, has := selected_row(app)
	if !has { return }
	#partial switch r.kind {
	case .Process:
		p := app.sampler.procs[r.index]
		append(&c.targets, Target{p.pid, p.start})
		c.name = strings.clone(fmt.tprintf("%s (PID %d)", p.name, p.pid))
	case .App:
		g := app.table.groups[r.index]
		roots := group_roots(&app.table, g)
		for i in roots { append(&c.targets, Target{app.sampler.procs[i].pid, app.sampler.procs[i].start}) }
		name := app.catalog.entries[g.entry].name
		c.name = strings.clone(len(roots) == 1 ? fmt.tprintf("%s (PID %d)", name, app.sampler.procs[roots[0]].pid) : fmt.tprintf("%s (%d instances)", name, len(roots)))
	case:
		return
	}
	return c, len(c.targets) > 0
}

// Opens the menu of the selected row at `pos` (window pixels).
row_menu_open :: proc(app: ^App, pos: ui.Vec2, from_keyboard := false) {
	c, ok := chosen_of_selection(app)
	if !ok { return }
	m := &app.menu
	if m.key == 0 { m.key = ui.key_from_string(0, "inspecteur_row_menu") }
	chosen_free(&m.menu)
	m.menu = c
	ui.ctx_menu_open(m.key, pos, from_keyboard = from_keyboard)
}

// The menu and the kill's confirmation, when open (built at the end of the window's build).
row_menu_build :: proc(app: ^App, em: f32) {
	if app.menu.key != 0 { row_menu_items(app, em) }
	kill_build(app, em)
}

@(private = "file")
row_menu_items :: proc(app: ^App, em: f32) {
	m := &app.menu
	if ui.ctx_menu(m.key, em * MENU_WIDTH_EM) {
		// (the file and the command line are the first process's)
		p := len(m.menu.targets) > 0 ? find_proc(&app.sampler, m.menu.targets[0].pid, m.menu.targets[0].start) : nil
		if p == nil { ui.ctx_menu_close(); return }
		if ui.menu_item("End task", "Delete").clicked { send_signal(app, &m.menu, .SIGTERM) }
		if ui.menu_item("Kill…", "Shift+Del").clicked { kill_ask(app, m.menu) }
		ui.menu_separator()
		if ui.menu_item("Open file location", enabled = p.exe != "").clicked { open_location(app, p) }
		if ui.menu_item("Copy command line", enabled = p.cmdline != "").clicked { copy_command(app, p) }
		ui.menu_separator()
		if ui.menu_item("Properties", "Alt+Enter").clicked { props_open(&app.props, p.pid, p.start) }
	}
}

// The executable's folder in the file manager.
open_location :: proc(app: ^App, p: ^Proc) {
	if p.exe == "" { return }
	if !platform.reveal_in_folder(p.exe) { say(app, "No file manager opens %s", p.exe) }
}

copy_command :: proc(app: ^App, p: ^Proc) {
	if p.cmdline == "" { return }
	platform.set_clipboard(app.main.win, p.cmdline)
	say(app, "Copied the command line of %s", p.name)
}

// Asks the selected row's processes to end (SIGTERM).
end_selected :: proc(app: ^App) {
	c, ok := chosen_of_selection(app)
	defer chosen_free(&c)
	if ok { send_signal(app, &c, .SIGTERM) }
}

// Asks to confirm a kill of the selected row's processes.
kill_selected :: proc(app: ^App) {
	c, ok := chosen_of_selection(app)
	defer chosen_free(&c)
	if ok { kill_ask(app, c) }
}

kill_ask :: proc(app: ^App, c: Chosen) {
	m := &app.menu
	chosen_free(&m.kill)
	for t in c.targets { append(&m.kill.targets, t) }
	m.kill.name = strings.clone(c.name)
	m.kill_open = true
}

@(private = "file")
kill_build :: proc(app: ^App, em: f32) {
	m := &app.menu
	w := em * KILL_WIDTH_EM
	if ui.modal("kill", w, &m.kill_open) {
		pad := em * 1.2
		if ui.style({width = ui.px(w)}) {
			ui.spacer(ui.px(pad))
			ui.next({width = ui.px(w), height = ui.children_sum()})
			if ui.row() {
				ui.spacer(ui.px(pad))
				ui.next({width = ui.px(w - 2 * pad), height = ui.children_sum(), axis = .Y})
				if ui.column() {
					ui.next({width = ui.fill(), font_size = em * 1.15})
					ui.label(fmt.tprintf("Kill %s?###kill_title", shown_text(m.kill.name)))
					ui.spacer(ui.px(em * 0.4))
					if ui.tags("weak") {
						ui.next({width = ui.fill()})
						ui.paragraph("It ends at once, without the chance to save its work. End task asks it to end on its own.###kill_text")
					}
					ui.spacer(ui.px(em * 1.1))
					ui.next({width = ui.fill(), height = ui.children_sum()})
					if ui.row() {
						ui.spacer(ui.fill())
						ui.next({width = ui.text_size(em * 1.2), height = ui.px(ui.dense(em * 2.2))})
						if ui.button("Cancel###kill_cancel").clicked { m.kill_open = false }
						ui.spacer(ui.px(em * 0.6))
						ui.next({width = ui.text_size(em * 1.2), height = ui.px(ui.dense(em * 2.2))})
						if ui.tags("danger_button") {
							if ui.button("Kill###kill_confirm").clicked || ui.key_press(.Return) {
								send_signal(app, &m.kill, .SIGKILL)
								m.kill_open = false
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
send_signal :: proc(app: ^App, c: ^Chosen, sig: linux.Signal) {
	sent := 0
	refused: linux.Errno
	owner := ""
	for t in c.targets {
		p := find_proc(&app.sampler, t.pid, t.start)
		if p == nil || !proc_alive(&app.sampler, t.pid, t.start) { continue }
		#partial switch e := linux.kill(linux.Pid(t.pid), sig); e {
		case .NONE:  sent += 1
		case .ESRCH:   // (it ended in between)
		case:
			refused = e
			owner = user_name(&app.sampler, p.uid)
		}
	}
	switch {
	case refused == .EPERM:
		say(app, "%s is %s's: Inspecteur may not end it", c.name, owner)
	case refused != .NONE:
		say(app, "%s cannot be ended (%v)", c.name, refused)
	case sent > 0:
		#partial switch sig {
		case .SIGKILL: say(app, "Killed %s", c.name)
		case .SIGSTOP: say(app, "Suspended %s", c.name)
		case .SIGCONT: say(app, "Resumed %s", c.name)
		case:          say(app, "Asked %s to end", c.name)
		}
	case:
		say(app, "%s has ended already", c.name)
	}
	if sent > 0 { app.next_sample = time.tick_add(time.tick_now(), SAMPLE_AFTER_SIGNAL) }
}

// The process (pid, start) of the last sample, nil when it is not there.
find_proc :: proc(s: ^Sampler, pid: i32, start: u64) -> ^Proc {
	lo, hi := 0, len(s.procs)
	for lo < hi {
		mid := (lo + hi) / 2
		if s.procs[mid].pid < pid { lo = mid + 1 } else { hi = mid }
	}
	if lo < len(s.procs) && s.procs[lo].pid == pid && s.procs[lo].start == start { return &s.procs[lo] }
	return nil
}

// The process `pid` of the last sample, whatever its start; nil when it is not there.
find_pid :: proc(s: ^Sampler, pid: i32) -> ^Proc {
	lo, hi := 0, len(s.procs)
	for lo < hi {
		mid := (lo + hi) / 2
		if s.procs[mid].pid < pid { lo = mid + 1 } else { hi = mid }
	}
	if lo < len(s.procs) && s.procs[lo].pid == pid { return &s.procs[lo] }
	return nil
}

// Opens the Properties of the selected row's process (an app's: its first process).
props_selected :: proc(app: ^App) {
	r, ok := selected_row(app)
	if !ok { return }
	if p, has := row_process(app, r); has { props_open(&app.props, p.pid, p.start) }
}
