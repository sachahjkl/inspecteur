package inspecteur

// The Startup section's model: what starts with the user's session, whether it is on, and turning it on or off. The
// system's side is startup_linux.odin (the XDG autostart entries and the user's systemd services that the session's
// targets want): startup_read lists, startup_set_enabled turns one on or off. Both run in a tasks.Job on the toolkit's
// chores, whose reading comes back to the window by ui.post: they read files and ask the user's service manager. The list
// is read when the section is shown, on F5 and after a change.

import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import lucide "gt:lucide"
import tasks "gt:tasks"
import i18n "gt:i18n"
import "gt:ui"

Startup_Kind :: enum u8 { Autostart, User_Service }

STARTUP_KIND_TEXT := [Startup_Kind]string{.Autostart = i18n.later("Autostart entry"), .User_Service = i18n.later("User service")}

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
	names:   []string,   // the items it was asked for
	failure: string,     // the first that failed, "name: why"; "" when all were done
	failures: int,
	on_count: int,     // the items on (counted when the window takes it)
}

// An item to turn on or off: the heap's strings while the window asks, the reading's arena's once the worker takes it.
Startup_Change :: struct {
	kind: Startup_Kind,
	id, name: string,
}

// What the window asks the job (under the startup's mutex).
@(private = "file")
Startup_Ask :: struct {
	change: bool,
	on:     bool,
	items:  [dynamic]Startup_Change,   // the heap's
}

Startup :: struct {
	job:     tasks.Job,
	bus:     Startup_Bus,      // the job's own (startup_linux.odin)
	demo:    ^Demo,            // not nil: the items are the demo's
	state:   ^ui.State,        // the window a reading is posted to
	mutex:   sync.Mutex,
	ask:     Startup_Ask,      // under the mutex
	list:    ^Startup_List,    // the window's
	rows:    Section_Table,
	pending: bool,             // a change asked and not answered yet
	asked:   bool,
}

STARTUP_COLUMNS := [?]ui.Table_Column{
	{title = i18n.later("Name"), width = 0},
	{title = i18n.later("Command"), width = 18, weak = true},
	{title = i18n.later("Type"), width = 11},   // (its longest kind whole, in French too)
	{title = i18n.later("Status"), width = 10},
	{title = i18n.later("File"), width = 18, weak = true},
}

startup_init :: proc(s: ^Startup, app: ^App) {
	section_table_init(&s.rows, app, STARTUP_COLUMNS[:])
	section_layout_load(&s.rows, &app.prefs, "startup")
	s.demo = app.demo
	s.state = &app.main.state
	s.job = {work = startup_work, data = s}
}

// After the chores stopped (no reading runs).
startup_destroy :: proc(s: ^Startup) {
	ask_changes_free(&s.ask.items)
	startup_bus_close(&s.bus)
	startup_list_free(s.list)
	section_table_destroy(&s.rows)
}

@(private = "file")
startup_list_free :: proc(l: ^Startup_List) {
	if l == nil { return }
	virtual.arena_destroy(&l.arena)
	free(l)
}

// Asks for a reading, after turning each of `items` on or off when `change` is set.
startup_ask :: proc(app: ^App, change := false, items: []Startup_Item = nil, on := false) {
	s := &app.startup
	s.asked = true
	sync.lock(&s.mutex)
	if change {
		s.ask.change, s.ask.on = true, on
		ask_changes_free(&s.ask.items)
		heap := runtime.heap_allocator()
		s.ask.items = make([dynamic]Startup_Change, 0, len(items), heap)
		for it in items { append(&s.ask.items, Startup_Change{it.kind, strings.clone(it.id, heap), strings.clone(it.name, heap)}) }
	}
	sync.unlock(&s.mutex)
	tasks.job_ask(ui.chores(), &s.job)
}

@(private = "file")
ask_changes_free :: proc(items: ^[dynamic]Startup_Change) {
	for it in items^ {
		delete(it.id, runtime.heap_allocator())
		delete(it.name, runtime.heap_allocator())
	}
	delete(items^)
	items^ = nil
}

@(private = "file")
startup_work :: proc(data: rawptr) {
	s := (^Startup)(data)
	l := new(Startup_List)
	// (the reading's texts in its arena; the bus's connection keeps the heap: it outlives the reading)
	a := virtual.arena_allocator(&l.arena)
	sync.lock(&s.mutex)
	change, on := s.ask.change, s.ask.on
	asked := make([]Startup_Change, len(s.ask.items), a)
	for it, i in s.ask.items { asked[i] = {it.kind, strings.clone(it.id, a), strings.clone(it.name, a)} }
	ask_changes_free(&s.ask.items)
	s.ask.change = false
	sync.unlock(&s.mutex)
	l.items = make([dynamic]Startup_Item, a)
	if change {
		l.changed, l.on = true, on
		l.names = make([]string, len(asked), a)
		for it, i in asked {
			l.names[i] = it.name
			why := s.demo != nil ? DEMO_REFUSED : startup_set_enabled(&s.bus, it.kind, it.id, on)
			if why == "" { continue }
			if l.failures == 0 { l.failure = strings.concatenate({it.name, ": ", why}, a) }
			l.failures += 1
		}
	}
	l.problem = strings.clone(s.demo != nil ? demo_startup_read(s.demo, &l.items, a) : startup_read(&s.bus, &l.items, a), a)
	if !ui.post(s.state, startup_posted, l) { startup_list_free(l) }
}

// On the window's thread: a new reading becomes the rows; what a change came to is said.
@(private = "file")
startup_posted :: proc(data: rawptr, _: u64) {
	l := (^Startup_List)(data)
	app := the_app
	if app == nil { startup_list_free(l); return }
	s := &app.startup
	startup_list_free(s.list)
	s.list = l
	for it in l.items { if it.enabled { l.on_count += 1 } }
	if l.changed {
		s.pending = false
		n := len(l.names)
		switch {
		case l.failures == 0 && n == 1: say(app, l.on ? i18n.tr("Enabled %s: it starts with the session") : i18n.tr("Disabled %s: it no longer starts with the session"), l.names[0])
		case l.failures == 0 && l.on:   say(app, i18n.tr(n, "Enabled %d item: it starts with the session", "Enabled %d items: they start with the session"), n)
		case l.failures == 0:           say(app, i18n.tr(n, "Disabled %d item: it no longer starts with the session", "Disabled %d items: they no longer start with the session"), n)
		case l.failures == 1:           say(app, "%s", l.failure)
		case:                           say(app, i18n.tr(l.failures - 1, "%s (and %d other failed)", "%s (and %d others failed)"), l.failure, l.failures - 1)
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
			kind := i18n.tr(STARTUP_KIND_TEXT[it.kind])
			// (the row's identity from the English: the selection is kept whatever the language)
			section_row(st, name_id(strings.concatenate({STARTUP_KIND_TEXT[it.kind], it.id}, context.temp_allocator)), strings.join({it.name, it.id, it.command, it.status, kind}, " ", context.temp_allocator), icon, it.enabled ? .Normal : .Dim)
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
