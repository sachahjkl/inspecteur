package inspecteur

// The Properties of one process: its details, its threads, its open files, its modules, its environment (the system's:
// props_linux.odin). Only the tab shown is read: when the dialog opens, when another tab is shown, and again every
// PROPS_REFRESH_MS while the process lives (its threads, its files, its maps move). Once the process is gone, nothing is
// read: the dialog says it ended. A list the user may not read (another user's process) says "Access denied". A reading
// runs on the chores (a file of /proc can make a read wait) and comes back at a next build; its strings are in its
// arena, freed when the next one replaces it.

import "core:mem/virtual"
import "core:strings"
import "core:time"
import process "gt:process"
import "gt:ui"
import i18n "gt:i18n"

Props_Tab :: enum u8 { General, History, Threads, Files, Modules, Environment }

PROPS_TAB_LABELS := [Props_Tab]string{.General = i18n.later("General"), .History = i18n.later("History"), .Threads = i18n.later("Threads"), .Files = i18n.later("Open files"), .Modules = i18n.later("Modules"), .Environment = i18n.later("Environment")}

// The tabs with a list (and its filter): the others read no list.
props_tab_listed :: proc(tab: Props_Tab) -> bool { return tab != .General && tab != .History }

// How often the tab shown is read again while the dialog is open.
PROPS_REFRESH_MS :: 3000

Thread_Row :: struct {
	tid:    i32,
	name:   string,
	state:  Proc_State,
	cpu_ns: u64,   // CPU time since it started
	nice:   i8,
}

File_Row :: struct { fd: int, target: string }

Module_Row :: struct {
	path: string,
	size: u64,   // bytes mapped of it, all its mappings
}

// What came of reading a list: read, refused (another user's process), or the process is gone.
Read_State :: enum u8 { Read, Denied, Gone }

// A reading of one tab: its texts and its lists in its arena.
Props_Data :: struct {
	arena:     virtual.Arena,
	read_tab:  Props_Tab,      // the tab it is of
	cwd:       string,
	cwd_read:  Read_State,
	threads:   [dynamic]Thread_Row,
	files:     [dynamic]File_Row,
	modules:   [dynamic]Module_Row,
	env:       [dynamic]string,
	list_read: Read_State,     // what came of reading the list of the tab (Threads to Environment)
	cpus:      string,         // the General tab's: the processors it may run on ("0-3, 8"), "" unknown
}

Props :: struct {
	open:     bool,
	pid:      i32,
	start:    u64,
	tab:      Props_Tab,
	size:     [2]f32,   // the dialog's size, as the user left it, in ems (ui.modal)
	data:     ^Props_Data,   // the last reading (nil: none yet)
	serial:   int,           // counts the readings taken (the filter's rows follow it)
	read_at:  time.Tick,
	reading:  bool,        // a reading is under way (its result comes at a next build: props_done)
	gone:     bool,        // the process ended: nothing more is read
	nice_sel: int,         // the priority menu's choice (PRIORITIES)
	filter:   ui.Line_Edit,   // the filter of the lists (Ctrl+F)
	filter_key: ui.Key,
	// the rows the filter keeps, made again when the reading, the tab or the filter changes (props_view.odin)
	shown:      [dynamic]int,
	shown_ids:  [dynamic]u64,   // their ids in the list
	shown_of:   int,       // the reading they are of (serial)
	shown_tab:  Props_Tab,
	shown_query: string,   // owned
	title_bg:   ui.Color,  // the title strip's colour (ui.dialog_top_draw reads it while the frame is drawn)
}

// A priority offered (PRIORITIES, the system's: system_linux.odin): its name and its value as a nice value (-20 the
// highest, 19 the lowest).
Priority :: struct { name: string, nice: i8 }

props_destroy :: proc(p: ^Props) {
	props_data_free(p.data)
	ui.line_edit_destroy(&p.filter)
	delete(p.shown)
	delete(p.shown_ids)
	delete(p.shown_query)
}

@(private = "file")
props_data_free :: proc(d: ^Props_Data) {
	if d == nil { return }
	virtual.arena_destroy(&d.arena)
	free(d)
}

props_open :: proc(app: ^App, pid: i32, start: u64) {
	p := &app.props
	p.open, p.pid, p.start, p.tab, p.gone = true, pid, start, .General, false
	props_data_free(p.data)
	p.data = nil
	p.serial += 1
	ui.line_edit_clear(&p.filter)
	props_read(app)
}

// At each sample while the dialog is open: `alive` says whether the process is still there. The tab shown is read
// again when another tab is shown or every PROPS_REFRESH_MS.
props_tick :: proc(app: ^App, alive: bool) {
	p := &app.props
	if !p.open || p.gone { return }
	if !alive { p.gone = true; return }
	if p.data == nil || p.tab != p.data.read_tab || time.duration_milliseconds(time.tick_since(p.read_at)) >= PROPS_REFRESH_MS { props_read(app) }
}

// What a reading is asked for, and what it read.
@(private = "file")
Props_Reading :: struct {
	pid:   i32,
	start: u64,
	tab:   Props_Tab,
	demo:  ^Demo,
	data:  ^Props_Data,
}

// Reads the tab shown (the General tab's working folder, or a list) on the chores; none while one is under way (the
// next tick asks again).
props_read :: proc(app: ^App) {
	p := &app.props
	if p.reading { return }
	p.reading = true
	p.read_at = time.tick_now()
	r := new(Props_Reading)
	r^ = {pid = p.pid, start = p.start, tab = p.tab, demo = app.demo, data = new(Props_Data)}
	ui.task(&app.main.state, props_work, props_done, r, props_lost)
}

@(private = "file")
props_work :: proc(data: rawptr) {
	r := (^Props_Reading)(data)
	d := r.data
	d.read_tab = r.tab
	a := virtual.arena_allocator(&d.arena)
	d.threads = make([dynamic]Thread_Row, a)
	d.files = make([dynamic]File_Row, a)
	d.modules = make([dynamic]Module_Row, a)
	d.env = make([dynamic]string, a)
	if r.demo != nil { demo_props_read(r.demo, r.pid, d, a); return }
	switch r.tab {
	case .General:
		d.cwd, d.cwd_read = proc_cwd(r.pid, r.start, a)
		if set, res, _ := process.affinity(r.pid, r.start); res == .Done {
			cpus := make([dynamic]bool, context.temp_allocator)
			for i in 0 ..< process.CPU_SET_MAX { append(&cpus, process.cpu_set_has(set, i)) }
			d.cpus = strings.clone(cpu_list_text(cpus[:]), a)
		}
	case .History:     // (the sampler's: Proc.hist)
	case .Threads:     d.list_read = proc_threads(r.pid, r.start, &d.threads, a)
	case .Files:       d.list_read = proc_files(r.pid, r.start, &d.files, a)
	case .Modules:     d.list_read = proc_modules(r.pid, r.start, &d.modules, a)
	case .Environment: d.list_read = proc_environment(r.pid, r.start, &d.env, a)
	}
}

// The reading becomes the dialog's, when it is still of the process shown.
@(private = "file")
props_done :: proc(data: rawptr, _: u64) {
	r := (^Props_Reading)(data)
	defer free(r)
	app := the_app
	if app == nil { props_data_free(r.data); return }
	p := &app.props
	p.reading = false
	if !p.open || p.pid != r.pid || p.start != r.start { props_data_free(r.data); return }
	props_data_free(p.data)
	p.data = r.data
	p.serial += 1
	// (the tab changed while it was read: the one shown now)
	if p.tab != p.data.read_tab && !p.gone { props_read(app) }
}

@(private = "file")
props_lost :: proc(data: rawptr) {
	r := (^Props_Reading)(data)
	props_data_free(r.data)
	free(r)
}

// The priority menu's line of a nice value: the one at or below it.
priority_index :: proc(nice: i8) -> int {
	at := 0
	for p, i in PRIORITIES { if p.nice <= nice { at = i } }
	return at
}
