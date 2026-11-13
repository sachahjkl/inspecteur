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
import "core:slice"
import "core:strings"
import process "gt:process"
import "core:time"
import "gt:platform"
import "gt:ui"

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
	key:     ui.Key,
	confirm: Confirm,   // the confirmation of a kill, of an end that would end Inspecteur or the session, of a service's stop
}

// What a confirmation does when it is confirmed: send a signal to processes, or ask the service manager to act.
Confirm_Act :: enum u8 { Signal, Service, Dump }

Confirm :: struct {
	open:    bool,
	act:     Confirm_Act,
	chosen:  Chosen,            // Signal: the processes
	sig:     process.Signal,
	action:  Service_Action,    // Service: the action on `unit`, of the manager shown
	unit:    string,            // owned
	title:   string,            // owned: "Kill sleep (PID 1234)?"
	note:    string,            // owned: what comes of it
	lines:   [dynamic]string,   // owned: the processes it acts on, a line each ("sleep, PID 1234"; the dialog shows the first)
	verb:    string,            // the confirming button's label
	enter_confirms: bool,       // Enter confirms; else Enter cancels (a kill, the end of the session or of Inspecteur)
}

chosen_free :: proc(c: ^Chosen) {
	delete(c.targets)
	delete(c.name)
	c^ = {}
}

confirm_free :: proc(c: ^Confirm) {
	chosen_free(&c.chosen)
	delete(c.unit)
	delete(c.title)
	delete(c.note)
	for l in c.lines { delete(l) }
	delete(c.lines)
	c^ = {}
}

row_menu_destroy :: proc(m: ^Row_Menu) { confirm_free(&m.confirm) }

// The process the selected row stands for: its own, or a group's first app process; nil when none.
selected_proc :: proc(app: ^App) -> ^Proc {
	r, ok := selected_row(app)
	if !ok { return nil }
	p, has := row_process(app, r)
	// (a process that ended keeps its row a moment, fading: nothing acts on it)
	return has && !p.ended ? p : nil
}

// Whether the selected row is a process's (not an app's group).
selected_is_process :: proc(app: ^App) -> bool {
	r, ok := selected_row(app)
	return ok && r.kind == .Process
}

// What the selection stands for: the rows marked (Ctrl and Shift clicks, Ctrl+A), else the selected row. A process's row
// is that process; an app's row is its processes (`whole`: every process of the group; else the app's own, whose
// children end with them). A process met twice (its own row and its group's) is chosen once.
@(private = "file")
chosen_of_selection :: proc(app: ^App, whole: bool) -> (c: Chosen, ok: bool) {
	rows := make([dynamic]Row, context.temp_allocator)
	if ui.list_mark_count(&app.vl) > 0 {
		for r, i in app.table.rows { if r.kind != .Section && ui.list_is_marked(&app.vl, i) { append(&rows, r) } }
	} else if r, has := selected_row(app); has && r.kind != .Section {
		append(&rows, r)
	}
	seen := make(map[i32]bool, 16, context.temp_allocator)
	add :: proc(c: ^Chosen, seen: ^map[i32]bool, p: Proc) {
		if p.pid in seen^ { return }
		seen[p.pid] = true
		append(&c.targets, Target{p.pid, p.start})
	}
	for r in rows {
		#partial switch r.kind {
		case .Process:
			add(&c, &seen, app.sampler.procs[r.index])
		case .App:
			g := app.table.groups[r.index]
			members := whole ? app.table.members[g.first:][:g.count] : group_roots(&app.table, g)
			for i in members { add(&c, &seen, app.sampler.procs[i]) }
		}
	}
	switch {
	case len(c.targets) == 0:
	case len(rows) == 1 && rows[0].kind == .App:
		g := app.table.groups[rows[0].index]
		name := app.catalog.entries[g.entry].name
		switch {
		case len(c.targets) == 1: c.name = strings.clone(fmt.tprintf("%s (PID %d)", name, c.targets[0].pid))
		case whole:               c.name = strings.clone(fmt.tprintf("%s (%d processes)", name, len(c.targets)))
		case:                     c.name = strings.clone(fmt.tprintf("%s (%d instances)", name, len(c.targets)))
		}
	case len(c.targets) == 1:
		p := find_proc(&app.sampler, c.targets[0].pid, c.targets[0].start)
		c.name = strings.clone(fmt.tprintf("%s (PID %d)", p != nil ? p.name : "?", c.targets[0].pid))
	case:
		c.name = strings.clone(fmt.tprintf("%d processes", len(c.targets)))
	}
	return c, len(c.targets) > 0
}

// The selected process and every process under it (the last sample's line of parents), the deepest first.
@(private = "file")
chosen_tree :: proc(app: ^App) -> (c: Chosen, ok: bool) {
	roots, has := chosen_of_selection(app, whole = true)
	defer chosen_free(&roots)
	if !has { return }
	seen := make(map[i32]bool, 64, context.temp_allocator)
	for t in roots.targets { seen[t.pid] = true }
	// (each process whose line of parents meets a chosen one; the samples are sorted by pid, so a parent may come after)
	for changed := true; changed; {
		changed = false
		for p in app.sampler.procs {
			if p.pid in seen || p.ppid not_in seen { continue }
			seen[p.pid] = true
			changed = true
		}
	}
	for p in app.sampler.procs { if p.pid in seen { append(&c.targets, Target{p.pid, p.start}) } }
	// (the children first: a parent that ends first may take its children with it or let them be adopted)
	slice.reverse(c.targets[:])
	under := len(c.targets) - len(roots.targets)
	c.name = strings.clone(under > 0 ? fmt.tprintf("%s and %s under it", roots.name, count_text(under, "process", "processes")) : roots.name)
	return c, true
}

// The service the process belongs to, selected in the Services section (its manager's: the system's or the user's).
go_to_service :: proc(app: ^App, p: ^Proc) {
	if p.unit == "" { return }
	ui.field_clear(&app.search)
	query_set(app, "")
	services_switch(app, p.unit_user ? .User : .System)
	tab_show(app, .Services)
	service_select(app, p.unit)
}

// The process's name, searched for on the web (the person's browser).
search_online :: proc(app: ^App) {
	p := selected_proc(app)
	if p == nil { return }
	name := p.name
	if r, ok := selected_row(app); ok && r.kind == .App { name = app.catalog.entries[app.table.groups[r.index].entry].name }
	url := strings.concatenate({SEARCH_URL, url_query(fmt.tprintf("%s process", name))}, context.temp_allocator)
	ui.open(url, .Url)
	say(app, "Searched the web for %s", name)
}

// The search engine a search online asks (the query follows).
SEARCH_URL :: "https://duckduckgo.com/?q="

// A text as a URL's query: letters, digits and -._~ as they are, a space as '+', the rest %XX (UTF-8's bytes).
url_query :: proc(text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)text {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '.', '_', '~': strings.write_byte(&b, c)
		case ' ':                                                      strings.write_byte(&b, '+')
		case:                                                          fmt.sbprintf(&b, "%%%02X", c)
		}
	}
	return strings.to_string(b)
}

// Asks to confirm a dump of the process's memory to a file (it may be large, and it holds whatever the process had).
dump_ask :: proc(app: ^App, p: ^Proc) {
	m := &app.menu.confirm
	confirm_free(m)
	m.act = .Dump
	append(&m.chosen.targets, Target{p.pid, p.start})
	m.chosen.name = fmt.aprintf("%s (PID %d)", p.name, p.pid)
	m.verb = "Create"
	m.title = fmt.aprintf("Create a dump file of %s?", m.chosen.name)
	m.note = fmt.aprintf("Its memory is written to a file of %s at most: anything it held, passwords and documents too. %s", size_text(p.resident), DUMP_HOW)
	m.enter_confirms = true
	m.open = true
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
		cmd_item(app, .End_Tree)
		p := selected_proc(app)
		cmd_item(app, .Suspend, p != nil && p.state == .Stopped ? "Resume" : "Suspend")
		if ui.menu_submenu(COMMANDS[.Send_Signal].label) {
			for s in SIGNAL_ITEMS {
				if ui.menu_item(s.label, enabled = cmd_can(app, .Send_Signal)).clicked { signal_selected(app, s.sig) }
			}
		}
		ui.menu_separator()
		cmd_item(app, .Raise_Priority)
		cmd_item(app, .Lower_Priority)
		cmd_item(app, .Affinity)
		ui.menu_separator()
		cmd_item(app, .Show_Window)
		cmd_item(app, .Go_To_Service)
		cmd_item(app, .Open_Location)
		cmd_item(app, .Copy_Command)
		cmd_item(app, .Search_Online)
		cmd_item(app, .Dump)
		ui.menu_separator()
		cmd_item(app, .Pin, pin_name(app) != "" && app.table.pinned[pin_name(app)] ? "Unpin" : "Pin")
		cmd_item(app, .Select_All)
		cmd_item(app, .Properties)
	}
}

// The executable's folder in the file manager.
open_location :: proc(app: ^App, p: ^Proc) {
	if p.exe == "" { return }
	ui.open(p.exe, .Reveal)
	say(app, "Opened the folder of %s", p.exe)
}

copy_command :: proc(app: ^App, p: ^Proc) {
	if p.cmdline == "" { return }
	platform.set_clipboard(app.main.win, p.cmdline)
	copied(app, fmt.tprintf("Copied the command line of %s", p.name))
}

// The signals the row's menu sends (Send a signal), each by its name and its number's.
@(rodata)
SIGNAL_ITEMS := [?]struct { sig: process.Signal, label: string }{
	{.Hangup, "Hang up (SIGHUP)"}, {.Interrupt, "Interrupt (SIGINT)"}, {.Quit, "Quit (SIGQUIT)"},
	{.Terminate, "Terminate (SIGTERM)"}, {.Kill, "Kill (SIGKILL)…"}, {.Stop, "Stop (SIGSTOP)"}, {.Continue, "Continue (SIGCONT)"},
	{.User1, "User 1 (SIGUSR1)"}, {.User2, "User 2 (SIGUSR2)"},
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
			if guard_of(app, t.pid) != .None { say(app, "Not stopped: it is Inspecteur, runs it or draws the desktop, and nothing could resume it"); return }
		}
		send_signal(app, &c, sig)
	case .Continue:
		send_signal(app, &c, sig)
	case:
		signal_or_confirm(app, &c, sig)
	}
}

// Asks the selected processes to end (SIGTERM).
end_selected :: proc(app: ^App) {
	c, ok := chosen_of_selection(app, whole = false)
	defer chosen_free(&c)
	if ok { signal_or_confirm(app, &c, .Terminate) }
}

// Asks to confirm a kill of the selected processes (an app's: all of them).
kill_selected :: proc(app: ^App) {
	c, ok := chosen_of_selection(app, whole = true)
	defer chosen_free(&c)
	if ok { confirm_ask(app, c, .Kill) }
}

// Asks to confirm the end of the selected processes and of every process under them.
end_tree_selected :: proc(app: ^App) {
	c, ok := chosen_tree(app)
	defer chosen_free(&c)
	if ok { confirm_ask(app, c, .Terminate, tree = true) }
}

// Suspends the selected process, or resumes it when it is suspended.
suspend_selected :: proc(app: ^App) {
	p := selected_proc(app)
	if p == nil || !selected_is_process(app) { return }
	suspend_or_resume(app, p)
}

// Its state is read when the act runs (acts.odin), not the last sample's: the process may have been resumed since.
suspend_or_resume :: proc(app: ^App, p: ^Proc) {
	if app.demo != nil { say(app, "The demo's processes are not the system's: nothing was sent"); return }
	a := act_new(.Suspend, fmt.tprintf("%s (PID %d)", p.name, p.pid))
	append(&a.targets, Target{p.pid, p.start})
	a.guard = guard_of(app, p.pid)
	act_start(app, a)
}

// What a process is to Inspecteur: itself, a process it runs under, the display server, or none of them.
Guard :: enum u8 { None, Self, Ancestor, Display_Server }

guard_of :: proc(app: ^App, pid: i32) -> Guard {
	own := app.own_pid
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

// Sends `sig`, but asks first when it would end the display server (the session ends with it) or Inspecteur.
signal_or_confirm :: proc(app: ^App, c: ^Chosen, sig: process.Signal) {
	for t in c.targets {
		if guard_of(app, t.pid) != .None { confirm_ask(app, c^, sig); return }
	}
	send_signal(app, c, sig)
}

// Asks to confirm `sig` to the processes of `c` (`tree`: a process and those under it): each one is listed by its name
// and pid, and the note says what comes of it.
confirm_ask :: proc(app: ^App, c: Chosen, sig: process.Signal, tree := false) {
	m := &app.menu.confirm
	confirm_free(m)
	m.act, m.sig = .Signal, sig
	for t in c.targets { append(&m.chosen.targets, t) }
	m.chosen.name = strings.clone(c.name)
	server, inspecteur := false, false
	for t in c.targets {
		switch guard_of(app, t.pid) {
		case .Display_Server:  server = true
		case .Self, .Ancestor: inspecteur = true
		case .None:
		}
		p := find_proc(&app.sampler, t.pid, t.start)
		append(&m.lines, p != nil ? fmt.aprintf("%s, PID %d", p.name, p.pid) : fmt.aprintf("PID %d", t.pid))
	}
	many := len(c.targets) > 1
	verb := sig == .Kill ? "Kill" : "End"
	m.verb = tree ? "End tree" : verb
	m.title = fmt.aprintf("%s %s?", verb, c.name)
	note := strings.builder_make(context.temp_allocator)
	switch {
	case server:     strings.write_string(&note, "It draws the desktop: the session ends with it, and every program of the session with it. ")
	case inspecteur: strings.write_string(&note, "Inspecteur ends with it: it runs under it. ")
	}
	switch {
	case sig == .Kill && many: strings.write_string(&note, "They end at once, without the chance to save their work. End task asks them to end on their own.")
	case sig == .Kill:         strings.write_string(&note, "It ends at once, without the chance to save its work. End task asks it to end on its own.")
	case many:                 strings.write_string(&note, "Each is asked to end.")
	case:                      strings.write_string(&note, "It is asked to end.")
	}
	m.note = strings.clone(strings.to_string(note))
	// (Enter confirms only what is asked and safe: a kill, the session's end and Inspecteur's own are a click)
	m.enter_confirms = sig != .Kill && !server && !inspecteur
	m.open = true
}

// Asks to confirm a service's stop or restart. `danger`: what else ends with it ("" none): Enter cancels then.
confirm_service :: proc(app: ^App, action: Service_Action, unit, danger: string) {
	m := &app.menu.confirm
	confirm_free(m)
	m.act, m.action = .Service, action
	m.unit = strings.clone(unit)
	m.verb = action == .Stop ? "Stop" : "Restart"
	m.title = fmt.aprintf("%s %s?", m.verb, unit)
	what := action == .Stop ? "It stops, and its processes end; what needs it may stop too." : "It stops, its processes end, and it starts again."
	m.note = danger != "" ? fmt.aprintf("%s %s", danger, what) : strings.clone(what)
	m.enter_confirms = danger == ""
	m.open = true
}

// The toolkit's confirmation: each process by its name and pid (what Kill acts on is seen before it acts).
@(private = "file")
confirm_build :: proc(app: ^App, em: f32) {
	m := &app.menu.confirm
	answer := ui.confirm("kill", &m.open, {title = m.title, note = m.note, lines = m.lines[:], act = m.verb, enter_confirms = m.enter_confirms})
	if answer == .Confirmed { confirm_act(app) }
}

// What the confirmation was asked for, done.
@(private = "file")
confirm_act :: proc(app: ^App) {
	m := &app.menu.confirm
	switch m.act {
	case .Signal:  send_signal(app, &m.chosen, m.sig)
	case .Service: service_act_now(app, m.action, m.unit)
	case .Dump:    dump_start(app, m.chosen.targets[0], m.chosen.name)
	}
}

// Sends `sig` to each process chosen that is still that process (acts.odin); what came of it is said when it is done.
send_signal :: proc(app: ^App, c: ^Chosen, sig: process.Signal) {
	if app.demo != nil { say(app, "The demo's processes are not the system's: nothing was sent"); return }
	a := act_new(.Signal, c.name)
	a.sig = sig
	for t in c.targets {
		p := find_proc(&app.sampler, t.pid, t.start)
		if p == nil { continue }
		append(&a.targets, t)
		append(&a.owners, p.user)
	}
	act_start(app, a)
}

// The next sample comes soon: the rows show what an action did.
sample_soon :: proc(app: ^App) {
	app.next_sample = time.tick_add(time.tick_now(), SAMPLE_AFTER_SIGNAL)
	app.sample_extra = true
}

// Opens the Properties of the selected row's process (an app's: its first process).
props_selected :: proc(app: ^App) {
	if p := selected_proc(app); p != nil {
		props_open(app, p.pid, p.start)
	}
}

// Enter: an app's group opens or closes; a process shows its Properties.
default_action :: proc(app: ^App) {
	r, ok := selected_row(app)
	if !ok { return }
	if r.kind == .App { group_toggle(app, r) } else { props_selected(app) }
}

// Sets a process's priority (a nice value), on each of its threads. A user may only lower a priority: a higher one
// needs the administrator (PRIORITY_DENIED).
set_priority :: proc(app: ^App, p: ^Proc, nice: i8) {
	if app.demo != nil { say(app, "The demo's processes are not the system's: nothing was changed"); return }
	a := act_new(.Priority, fmt.tprintf("%s (PID %d)", p.name, p.pid))
	append(&a.targets, Target{p.pid, p.start})
	a.nice = nice
	act_start(app, a)
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
