package inspecteur

// The Properties of one process: its details, its threads, its open files, its modules, its environment (the system's:
// props_linux.odin). Only the tab shown is read: when the dialog opens, when another tab is shown, and again every
// PROPS_REFRESH_MS while the process lives (its threads, its files, its maps move). Once the process is gone, nothing is
// read: the dialog says it ended. A list the user may not read (another user's process) says "Access denied". The
// strings of a reading are in an arena, emptied at the next.

import "core:mem/virtual"
import "core:strings"
import "core:time"
import process "gt:process"
import "gt:ui"

Props_Tab :: enum u8 { General, History, Threads, Files, Modules, Environment }

PROPS_TAB_LABELS := [Props_Tab]string{.General = "General", .History = "History", .Threads = "Threads", .Files = "Open files", .Modules = "Modules", .Environment = "Environment"}

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

Props :: struct {
	open:     bool,
	pid:      i32,
	start:    u64,
	tab:      Props_Tab,
	size:     [2]f32,   // the dialog's size, as the user left it (modal_sized)
	demo:     ^Demo,
	arena:    virtual.Arena,
	read_tab: Props_Tab,   // the tab of the last reading
	read_at:  time.Tick,
	gone:     bool,        // the process ended: nothing more is read
	cwd:      string,
	cwd_read: Read_State,
	threads:  [dynamic]Thread_Row,
	files:    [dynamic]File_Row,
	modules:  [dynamic]Module_Row,
	env:      [dynamic]string,
	list_read: Read_State,  // what came of reading the list of the tab read (Threads to Environment)
	nice_sel: int,          // the priority menu's choice (PRIORITIES)
	cpus:     string,       // the General tab's: the processors it may run on ("0-3, 8"), "" unknown (in the arena)
	filter:   ui.Text_Field,   // the filter of the lists (Ctrl+F)
	filter_key: ui.Key,
}

// A priority offered (PRIORITIES, the system's: system_linux.odin): its name and its value as a nice value (-20 the
// highest, 19 the lowest).
Priority :: struct { name: string, nice: i8 }

props_destroy :: proc(p: ^Props) {
	virtual.arena_destroy(&p.arena)
	ui.field_destroy(&p.filter)
	delete(p.threads)
	delete(p.files)
	delete(p.modules)
	delete(p.env)
}

props_open :: proc(p: ^Props, pid: i32, start: u64) {
	p.open, p.pid, p.start, p.tab, p.gone = true, pid, start, .General, false
	ui.field_clear(&p.filter)
	props_read(p)
}

// At each sample while the dialog is open: `alive` says whether the process is still there. The tab shown is read
// again when another tab is shown or every PROPS_REFRESH_MS.
props_tick :: proc(p: ^Props, alive: bool) {
	if !p.open || p.gone { return }
	if !alive { p.gone = true; return }
	if p.tab != p.read_tab || time.duration_milliseconds(time.tick_since(p.read_at)) >= PROPS_REFRESH_MS { props_read(p) }
}

// Reads the tab shown (the General tab's working folder, or a list).
props_read :: proc(p: ^Props) {
	free_all(virtual.arena_allocator(&p.arena))
	clear(&p.threads)
	clear(&p.files)
	clear(&p.modules)
	clear(&p.env)
	p.cwd, p.cpus = "", ""
	p.read_tab, p.read_at = p.tab, time.tick_now()
	a := virtual.arena_allocator(&p.arena)
	if p.demo != nil { demo_props_read(p.demo, p, a); return }
	switch p.tab {
	case .General:
		p.cwd, p.cwd_read = proc_cwd(p.pid, p.start, a)
		if set, r, _ := process.affinity(p.pid, p.start); r == .Done {
			cpus := make([dynamic]bool, context.temp_allocator)
			for i in 0 ..< process.CPU_SET_MAX { append(&cpus, process.cpu_set_has(set, i)) }
			p.cpus = strings.clone(cpu_list_text(cpus[:]), a)
		}
	case .History:     // (the sampler's: Proc.hist)
	case .Threads:     p.list_read = proc_threads(p.pid, p.start, &p.threads, a)
	case .Files:       p.list_read = proc_files(p.pid, p.start, &p.files, a)
	case .Modules:     p.list_read = proc_modules(p.pid, p.start, &p.modules, a)
	case .Environment: p.list_read = proc_environment(p.pid, p.start, &p.env, a)
	}
}

// The priority menu's line of a nice value: the one at or below it.
priority_index :: proc(nice: i8) -> int {
	at := 0
	for p, i in PRIORITIES { if p.nice <= nice { at = i } }
	return at
}
