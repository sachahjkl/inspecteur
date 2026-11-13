package inspecteur

// A journal shown: the details and journal entries of one service, read in a tasks.Job on the toolkit's chores
// (journalctl and the manager's properties take a while), whose reading comes back to the window that shows it by
// ui.post, with its list, its selection and its search. The Services section's pane has one (it follows the selected
// service); each journal window has its own (journal_window.odin), for the service it was opened for.

import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:time"
import tasks "gt:tasks"
import "gt:ui"

Journal_View :: struct {
	job:        tasks.Job,
	bus:        Service_Bus,      // the job's own
	demo:       ^Demo,            // not nil: the readings are the demo's
	state:      ^ui.State,        // the window a reading is posted to (its build takes it)
	mutex:      sync.Mutex,
	ask:        struct { manager: Manager, name: [SERVICE_NAME_MAX]u8, name_len: int, boot: bool },   // under the mutex
	details:    ^Unit_Details,    // the window's
	serial:     int,              // counts the readings taken (what is shown follows it)
	taken:      bool,             // a reading came since the window last looked (journal_view_taken)
	// the entries the level and the search keep, and the counts of the levels: made again when the reading, the level
	// or the search changes (journal_shown), not at each frame
	shown:      [dynamic]int,
	shown_ids:  [dynamic]u64,     // their ids in the list (journal_entry_id)
	shown_of:   int,              // the reading they are of (serial; -1: none yet)
	shown_level: Journal_Level,
	shown_query: string,          // owned
	errors, warnings: int,
	next:       time.Tick,        // when the followed journal is read again
	vl:         ui.Virtual_List,  // the entries
	shown_for:  u64,              // the service the list was put at the end for
	last:       u64,              // the newest entry's id when the list was last built (a new one: back to the end)
	search:     ui.Text_Field,    // its own search (Ctrl+J)
	search_key: ui.Key,
}

// A reading, and the view it is for.
@(private = "file")
Journal_Reading :: struct {
	view:    ^Journal_View,
	details: ^Unit_Details,
}

// `state`: the window that shows the view (its build takes the readings).
journal_view_init :: proc(v: ^Journal_View, demo: ^Demo, state: ^ui.State) {
	v.demo, v.state = demo, state
	v.job = {work = journal_view_work, data = v}
	v.shown_of = -1
}

// Once no reading is under way (journal_view_busy): the window's posts were taken or dropped with it.
journal_view_destroy :: proc(v: ^Journal_View) {
	service_bus_close(&v.bus)
	unit_details_free(v.details)
	delete(v.shown)
	delete(v.shown_ids)
	delete(v.shown_query)
	ui.vlist_destroy(&v.vl)
	ui.field_destroy(&v.search)
	v^ = {}
}

// Asks for the details and the journal of the service `name` of `manager` (of this boot alone when `boot`).
journal_view_ask :: proc(v: ^Journal_View, manager: Manager, name: string, boot: bool) {
	sync.lock(&v.mutex)
	v.ask.manager = manager
	v.ask.name_len = copy(v.ask.name[:], name)
	v.ask.boot = boot
	sync.unlock(&v.mutex)
	tasks.ask(ui.chores(), &v.job)
}

// Whether a reading is asked or under way.
journal_view_busy :: proc(v: ^Journal_View) -> bool { return tasks.busy(ui.chores(), &v.job) }

// True once after a reading came in (the window settles its layout).
journal_view_taken :: proc(v: ^Journal_View) -> bool {
	defer v.taken = false
	return v.taken
}

@(private = "file")
journal_view_work :: proc(data: rawptr) {
	v := (^Journal_View)(data)
	sync.lock(&v.mutex)
	ask := v.ask
	sync.unlock(&v.mutex)
	d := new(Unit_Details)
	a := virtual.arena_allocator(&d.arena)
	d.journal = make([dynamic]Journal_Entry, a)
	d.manager = ask.manager
	d.boot = ask.boot
	d.name = strings.clone(string(ask.name[:ask.name_len]), a)
	d.tasks, d.cpu_ns = DETAIL_UNKNOWN, DETAIL_UNKNOWN
	if v.demo != nil { demo_unit_details(v.demo, d, a) } else { unit_details_read(&v.bus, d, a) }
	r := new(Journal_Reading)
	r^ = {view = v, details = d}
	if !ui.post(v.state, journal_view_posted, r) {
		unit_details_free(d)
		free(r)
	}
}

// On the window's thread: the reading becomes the view's.
@(private = "file")
journal_view_posted :: proc(data: rawptr, _: u64) {
	r := (^Journal_Reading)(data)
	v := r.view
	unit_details_free(v.details)
	v.details = r.details
	v.serial += 1
	v.taken = true
	free(r)
}

@(private = "file")
unit_details_free :: proc(d: ^Unit_Details) {
	if d == nil { return }
	virtual.arena_destroy(&d.arena)
	free(d)
}
