package inspecteur

// The Services section's model: the services of the system's service manager or of the user's, their state, whether
// they start by themselves, their main process and memory. The system's side is services_linux.odin (systemd over
// D-Bus): services_read lists, service_act starts, stops, restarts, enables or disables. Both run on a thread of their
// own (worker.odin): a call to the manager can wait for an authorisation for seconds. The list is read while the
// section is shown, every services.refresh_ms, and at once after an action.

import "core:mem/virtual"
import "core:strings"
import "core:time"
import "gt:ui"

Manager :: enum u8 { System, User }

MANAGER_LABELS := [Manager]string{.System = "System", .User = "User"}
MANAGER_KEYS := [Manager]string{.System = "system", .User = "user"}

Service_Action :: enum u8 { None, Start, Stop, Restart, Enable, Disable }

SERVICE_ACTION_DOING := [Service_Action]string{.None = "", .Start = "Starting", .Stop = "Stopping", .Restart = "Restarting", .Enable = "Enabling", .Disable = "Disabling"}
SERVICE_ACTION_DONE := [Service_Action]string{.None = "", .Start = "Started", .Stop = "Stopped", .Restart = "Restarted", .Enable = "Enabled", .Disable = "Disabled"}

// No memory figure (the manager does not count it for this service).
MEMORY_UNKNOWN :: max(u64)
// After an action, the next reading comes this soon.
SERVICE_AFTER_ACTION :: 500 * time.Millisecond
// The longest service name an action carries.
SERVICE_NAME_MAX :: 256

Service :: struct {
	name, description: string,
	load:   string,   // loaded, not-found, masked; "not loaded": a unit file nothing has loaded
	active: string,   // active, inactive, failed, activating, deactivating
	sub:    string,   // running, exited, dead...
	file:   string,   // enabled, disabled, static, masked, transient... ("" when it has no file)
	pid:    i32,      // the main process, 0: none
	memory: u64,      // bytes, MEMORY_UNKNOWN: not counted
}

// A reading: all of its texts in its arena.
Service_List :: struct {
	arena:   virtual.Arena,
	manager: Manager,
	units:   [dynamic]Service,
	problem: string,   // the manager cannot be reached: why
	// the action this reading follows, and what came of it
	action:  Service_Action,
	unit:    string,
	failure: string,   // "" when it was done
}

// What the window asks the thread (under the worker's mutex).
@(private = "file")
Service_Ask :: struct {
	manager: Manager,
	action:  Service_Action,
	unit:    [SERVICE_NAME_MAX]u8,
	unit_len: int,
}

Services :: struct {
	worker:  ui.Worker,
	bus:     Service_Bus,      // the thread's own (services_linux.odin)
	ask:     Service_Ask,      // under the worker's mutex
	shared:  ^Service_List,    // the thread's last reading, under the worker's mutex
	list:    ^Service_List,    // the window's
	rows:    Section_Table,
	manager: Manager,          // the one shown
	menu:    ui.Key,
	next:    time.Tick,        // the next reading while the section is shown
	pending: Service_Action,   // an action asked and not answered yet
}

SERVICE_COLUMNS := [?]ui.Table_Column{
	{title = "Name", width = 0},
	{title = "Description", width = 22, weak = true},
	{title = "State", width = 11},
	{title = "Startup", width = 7.5},
	{title = "Load", width = 7, weak = true},
	{title = "PID", width = 5.5, number = true, weak = true},
	{title = "Memory", width = 7, number = true},
}

services_init :: proc(s: ^Services, app: ^App) {
	section_table_init(&s.rows, app, SERVICE_COLUMNS[:])
	s.manager = app.settings.manager
	ui.worker_start(&s.worker, services_job, s, app.main.win)
}

services_destroy :: proc(s: ^Services) {
	ui.worker_stop(&s.worker)
	service_bus_close(&s.bus)
	service_list_free(s.shared)
	service_list_free(s.list)
	section_table_destroy(&s.rows)
}

@(private = "file")
service_list_free :: proc(l: ^Service_List) {
	if l == nil { return }
	virtual.arena_destroy(&l.arena)
	free(l)
}

// Asks for a reading of the manager shown, after `action` on `unit` when there is one.
services_ask :: proc(app: ^App, action := Service_Action.None, unit := "") {
	s := &app.services
	ui.worker_lock(&s.worker)
	s.ask.manager = s.manager
	if action != .None {
		s.ask.action = action
		s.ask.unit_len = copy(s.ask.unit[:], unit)
	}
	ui.worker_unlock(&s.worker)
	ui.worker_ask(&s.worker)
	s.next = time.tick_add(time.tick_now(), time.Duration(app.settings.services_ms) * time.Millisecond)
}

@(private = "file")
services_job :: proc(w: ^ui.Worker) {
	s := (^Services)(w.user)
	ui.worker_lock(w)
	ask := s.ask
	s.ask.action = .None
	ui.worker_unlock(w)
	l := new(Service_List)
	// (the reading's texts in its arena; the bus's connections keep the heap: they outlive the reading)
	a := virtual.arena_allocator(&l.arena)
	l.units = make([dynamic]Service, a)
	l.manager = ask.manager
	if ask.action != .None {
		l.action = ask.action
		l.unit = strings.clone(string(ask.unit[:ask.unit_len]), a)
		l.failure = strings.clone(service_act(&s.bus, ask.manager, ask.action, l.unit), a)
	}
	l.problem = strings.clone(services_read(&s.bus, ask.manager, &l.units, a), a)
	ui.worker_lock(w)
	old := s.shared
	s.shared = l
	ui.worker_unlock(w)
	service_list_free(old)
	ui.worker_published(w)
}

// The window's turn: a new reading becomes the rows; what an action came to is said.
services_take :: proc(app: ^App) {
	s := &app.services
	if !ui.worker_take(&s.worker) { return }
	ui.worker_lock(&s.worker)
	old := s.list
	s.list, s.shared = s.shared, nil
	ui.worker_unlock(&s.worker)
	service_list_free(old)
	l := s.list
	if l == nil { return }
	if l.action != .None {
		s.pending = .None
		// (the manager queued a job, which takes some time: its outcome shows at a reading soon after)
		s.next = time.tick_add(time.tick_now(), SERVICE_AFTER_ACTION)
		if l.failure == "" {
			say(app, "%s %s", SERVICE_ACTION_DONE[l.action], l.unit)
		} else {
			say(app, "%s: %s", l.unit, l.failure)
		}
	}
	services_rows(app)
}

// The rows again from the reading (of the manager shown only: a reading of the other one, asked before a switch, is not
// shown).
services_rows :: proc(app: ^App) {
	s := &app.services
	st := &s.rows
	section_rows_reset(st, len(SERVICE_COLUMNS))
	if s.list != nil && s.list.manager == s.manager {
		for u in s.list.units {
			state := u.sub != "" && u.sub != u.active ? strings.concatenate({u.active, " (", u.sub, ")"}, context.temp_allocator) : u.active
			tone := ui.Table_Tone.Normal
			if u.active == "failed" { tone = .Bad } else if u.active != "active" && u.active != "activating" && u.active != "reloading" { tone = .Dim }
			pid := u.pid > 0 ? uint_text(u64(u.pid)) : ""
			memory := u.memory != MEMORY_UNKNOWN && u.memory > 0 ? size_text(u.memory) : ""
			section_row(st, name_id(u.name), strings.join({u.name, u.description, state, u.file, pid}, " ", context.temp_allocator), {}, tone)
			ui.table_data_cell(&st.data, u.name)
			ui.table_data_cell(&st.data, u.description)
			ui.table_data_cell(&st.data, state)
			ui.table_data_cell(&st.data, u.file)
			ui.table_data_cell(&st.data, u.load)
			ui.table_data_cell(&st.data, pid, f64(u.pid))
			ui.table_data_cell(&st.data, memory, u.memory == MEMORY_UNKNOWN ? -1 : f64(u.memory))
		}
	}
	ui.table_apply(&st.table, &st.data, app.query)
}

// The selected service, when there is one.
selected_service :: proc(app: ^App) -> (u: Service, ok: bool) {
	s := &app.services
	i := ui.table_selected(&s.rows.table)
	if s.list == nil || s.list.manager != s.manager || i < 0 || i >= len(s.list.units) { return }
	return s.list.units[i], true
}

// A name's identity (FNV-1a): a row stays selected across readings.
name_id :: proc(name: string) -> u64 {
	h: u64 = 14695981039346656037
	for i in 0 ..< len(name) { h = (h ~ u64(name[i])) * 1099511628211 }
	return h
}
