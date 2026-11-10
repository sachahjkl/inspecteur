package inspecteur

// The Startup section's model: what starts with the user's session, whether it is on, and turning it on or off. The
// system's side is startup_linux.odin (the XDG autostart entries and the user's systemd services that the session's
// targets want): startup_read lists, startup_set_enabled turns one on or off. Both run on a thread of their own
// (the toolkit's ui.Worker): they read files and ask the user's service manager. The list is read when the section is shown, on F5
// and after a change.

import "core:mem/virtual"
import "core:strings"
import lucide "gt:lucide"
import "gt:ui"

Startup_Kind :: enum u8 { Autostart, User_Service }

STARTUP_KIND_TEXT := [Startup_Kind]string{.Autostart = "Autostart entry", .User_Service = "User service"}

// The longest id a change carries.
STARTUP_ID_MAX :: 512

Startup_Item :: struct {
	kind:       Startup_Kind,
	id:         string,   // the entry's file name (foo.desktop), the service's name (foo.service)
	name:       string,
	command:    string,
	icon:       string,   // an icon's name (an autostart entry's Icon=), "" for none
	path:       string,   // the file it comes from
	enabled:    bool,
	status:     string,   // what the Status column says: Enabled, Disabled, Not in this desktop, Static...
	can_toggle: bool,     // it can be turned on and off from here
}

// A reading: all of its texts in its arena.
Startup_List :: struct {
	arena:   virtual.Arena,
	items:   [dynamic]Startup_Item,
	problem: string,   // what could not be read (the user's service manager), "" when all was
	// the change this reading follows, and what came of it
	changed: bool,
	on:      bool,
	name:    string,
	failure: string,
}

// What the window asks the thread (under the worker's mutex).
@(private = "file")
Startup_Ask :: struct {
	change: bool,
	on:     bool,
	kind:   Startup_Kind,
	id:     [STARTUP_ID_MAX]u8,
	id_len: int,
	name:   [STARTUP_ID_MAX]u8,
	name_len: int,
}

Startup :: struct {
	worker:  ui.Worker,
	bus:     Startup_Bus,      // the thread's own (startup_linux.odin)
	demo:    ^Demo,            // not nil: the items are the demo's
	ask:     Startup_Ask,      // under the worker's mutex
	shared:  ^Startup_List,
	list:    ^Startup_List,    // the window's
	rows:    Section_Table,
	menu:    ui.Key,
	pending: bool,             // a change asked and not answered yet
	asked:   bool,
}

STARTUP_COLUMNS := [?]ui.Table_Column{
	{title = "Name", width = 0},
	{title = "Command", width = 18, weak = true},
	{title = "Type", width = 9},
	{title = "Status", width = 10},
	{title = "File", width = 18, weak = true},
}

startup_init :: proc(s: ^Startup, app: ^App) {
	section_table_init(&s.rows, app, STARTUP_COLUMNS[:])
	section_layout_load(&s.rows.table, &app.prefs, "startup")
	s.demo = app.demo
	ui.worker_start(&s.worker, startup_job, s, app.main.win)
}

startup_destroy :: proc(s: ^Startup) {
	ui.worker_stop(&s.worker)
	startup_bus_close(&s.bus)
	startup_list_free(s.shared)
	startup_list_free(s.list)
	section_table_destroy(&s.rows)
}

@(private = "file")
startup_list_free :: proc(l: ^Startup_List) {
	if l == nil { return }
	virtual.arena_destroy(&l.arena)
	free(l)
}

// Asks for a reading, after turning `item` on or off when `change` is set.
startup_ask :: proc(app: ^App, change := false, item := Startup_Item{}, on := false) {
	s := &app.startup
	s.asked = true
	ui.worker_lock(&s.worker)
	if change {
		s.ask.change, s.ask.on, s.ask.kind = true, on, item.kind
		s.ask.id_len = copy(s.ask.id[:], item.id)
		s.ask.name_len = copy(s.ask.name[:], item.name)
	}
	ui.worker_unlock(&s.worker)
	ui.worker_ask(&s.worker)
}

@(private = "file")
startup_job :: proc(w: ^ui.Worker) {
	s := (^Startup)(w.user)
	ui.worker_lock(w)
	ask := s.ask
	s.ask.change = false
	ui.worker_unlock(w)
	l := new(Startup_List)
	// (the reading's texts in its arena; the bus's connection keeps the heap: it outlives the reading)
	a := virtual.arena_allocator(&l.arena)
	l.items = make([dynamic]Startup_Item, a)
	if ask.change {
		l.changed, l.on = true, ask.on
		l.name = strings.clone(string(ask.name[:ask.name_len]), a)
		l.failure = strings.clone(s.demo != nil ? DEMO_REFUSED : startup_set_enabled(&s.bus, ask.kind, string(ask.id[:ask.id_len]), ask.on), a)
	}
	l.problem = strings.clone(s.demo != nil ? demo_startup_read(s.demo, &l.items, a) : startup_read(&s.bus, &l.items, a), a)
	ui.worker_lock(w)
	old := s.shared
	s.shared = l
	ui.worker_unlock(w)
	startup_list_free(old)
	ui.worker_published(w)
}

// The window's turn: a new reading becomes the rows; what a change came to is said.
startup_take :: proc(app: ^App) {
	s := &app.startup
	if !ui.worker_take(&s.worker) { return }
	ui.worker_lock(&s.worker)
	old := s.list
	s.list, s.shared = s.shared, nil
	ui.worker_unlock(&s.worker)
	startup_list_free(old)
	l := s.list
	if l == nil { return }
	if l.changed {
		s.pending = false
		if l.failure == "" {
			say(app, "%s %s: %s", l.on ? "Enabled" : "Disabled", l.name, l.on ? "it starts with the session" : "it no longer starts with the session")
		} else {
			say(app, "%s: %s", l.name, l.failure)
		}
	}
	startup_rows(app)
}

startup_rows :: proc(app: ^App) {
	s := &app.startup
	st := &s.rows
	section_rows_reset(st, len(STARTUP_COLUMNS))
	if s.list != nil {
		for it in s.list.items {
			icon := Row_Icon{app = it.icon, glyph = it.kind == .Autostart ? lucide.POWER : lucide.SETTINGS}
			kind := STARTUP_KIND_TEXT[it.kind]
			section_row(st, name_id(strings.concatenate({kind, it.id}, context.temp_allocator)), strings.join({it.name, it.id, it.command, it.status, kind}, " ", context.temp_allocator), icon, it.enabled ? .Normal : .Dim)
			ui.table_data_cell(&st.data, it.name)
			ui.table_data_cell(&st.data, command_shown(it.command))
			ui.table_data_cell(&st.data, kind)
			ui.table_data_cell(&st.data, it.status)
			ui.table_data_cell(&st.data, it.path)
		}
	}
	ui.table_apply(&st.table, &st.data, app.query)
}

// A command as the table shows it: its program by its name when its path is long ("/nix/store/…-foo-1.2/bin/foo -x" is
// "foo -x"); the whole command is in the tooltip and Copy command.
command_shown :: proc(command: string) -> string {
	first, rest := command, ""
	if sp := strings.index_byte(command, ' '); sp >= 0 { first, rest = command[:sp], command[sp:] }
	slash := strings.last_index_byte(first, '/')
	if slash < 0 || !strings.has_prefix(first, "/nix/store/") { return command }
	return strings.concatenate({first[slash + 1:], rest}, context.temp_allocator)
}

selected_startup :: proc(app: ^App) -> (it: Startup_Item, ok: bool) {
	s := &app.startup
	i := ui.table_selected(&s.rows.table)
	if s.list == nil || i < 0 || i >= len(s.list.items) { return }
	return s.list.items[i], true
}
