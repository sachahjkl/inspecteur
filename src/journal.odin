package inspecteur

// A journal shown: the details and journal entries of one service, read on a thread of its own (journalctl and the
// manager's properties take a while), with its list, its selection and its search. The Services section's pane has one
// (it follows the selected service); each journal window has its own (journal_window.odin), for the service it was
// opened for.

import "core:mem/virtual"
import "core:strings"
import "core:time"
import "gt:platform"
import "gt:ui"

Journal_View :: struct {
	worker:     ui.Worker,
	bus:        Service_Bus,      // the thread's own
	demo:       ^Demo,            // not nil: the readings are the demo's
	ask:        struct { manager: Manager, name: [SERVICE_NAME_MAX]u8, name_len: int, boot: bool },   // under its mutex
	shared:     ^Unit_Details,    // the thread's last reading, under its mutex
	details:    ^Unit_Details,    // the window's
	next:       time.Tick,        // when the followed journal is read again
	vl:         ui.Virtual_List,  // the entries
	shown_for:  u64,              // the service the list was put at the end for
	last:       u64,              // the newest entry's id when the list was last built (a new one: back to the end)
	search:     ui.Text_Field,    // its own search (Ctrl+J)
	search_key: ui.Key,
}

// `win`: the window whose loop the thread wakes when a reading is in.
journal_view_init :: proc(v: ^Journal_View, demo: ^Demo, win: ^platform.Window) {
	v.demo = demo
	ui.worker_start(&v.worker, journal_view_job, v, win)
}

journal_view_destroy :: proc(v: ^Journal_View) {
	ui.worker_stop(&v.worker)
	service_bus_close(&v.bus)
	unit_details_free(v.shared)
	unit_details_free(v.details)
	ui.vlist_destroy(&v.vl)
	ui.field_destroy(&v.search)
	v^ = {}
}

// Asks for the details and the journal of the service `name` of `manager` (of this boot alone when `boot`).
journal_view_ask :: proc(v: ^Journal_View, manager: Manager, name: string, boot: bool) {
	ui.worker_lock(&v.worker)
	v.ask.manager = manager
	v.ask.name_len = copy(v.ask.name[:], name)
	v.ask.boot = boot
	ui.worker_unlock(&v.worker)
	ui.worker_ask(&v.worker)
}

// The window's turn: a reading that came in becomes the view's. True when one did.
journal_view_take :: proc(v: ^Journal_View) -> bool {
	if !ui.worker_take(&v.worker) { return false }
	ui.worker_lock(&v.worker)
	old := v.details
	v.details, v.shared = v.shared, nil
	ui.worker_unlock(&v.worker)
	unit_details_free(old)
	return true
}

@(private = "file")
journal_view_job :: proc(w: ^ui.Worker) {
	v := (^Journal_View)(w.user)
	ui.worker_lock(w)
	ask := v.ask
	ui.worker_unlock(w)
	d := new(Unit_Details)
	a := virtual.arena_allocator(&d.arena)
	d.journal = make([dynamic]Journal_Entry, a)
	d.manager = ask.manager
	d.boot = ask.boot
	d.name = strings.clone(string(ask.name[:ask.name_len]), a)
	d.tasks, d.cpu_ns = DETAIL_UNKNOWN, DETAIL_UNKNOWN
	if v.demo != nil { demo_unit_details(v.demo, d, a) } else { unit_details_read(&v.bus, d, a) }
	ui.worker_lock(w)
	old := v.shared
	v.shared = d
	ui.worker_unlock(w)
	unit_details_free(old)
	ui.worker_published(w)
}

@(private = "file")
unit_details_free :: proc(d: ^Unit_Details) {
	if d == nil { return }
	virtual.arena_destroy(&d.arena)
	free(d)
}
