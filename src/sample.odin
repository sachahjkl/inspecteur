package inspecteur

// A sample, read off the window's thread. A reading of the machine and of every process (/proc: a file of a process stuck
// in the kernel can make a read wait) is a tasks.Job on the toolkit's chores: its work reads into a Reading of its own,
// swaps it in under the mutex and posts sample_posted (ui.post), which wakes the window; the window applies it to the
// machine and the processes (machine_apply, sampler_apply) and makes its rows. One reading is asked at a time: the
// window asks the next one once it took the last, so the readers (which keep the counters of the last reading) and the
// window's processes never differ on which processes were seen.
//
// The first reading is asked before the window opens and runs while it opens; the first frame waits for it, at most
// FIRST_READING_WAIT, so that it shows the processes.

import "core:mem/virtual"
import "core:os"
import "core:sync"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"
import tasks "gt:tasks"
import "gt:ui"
import i18n "gt:i18n"

// How long the first frame waits for the first reading (a reading takes some milliseconds; a stuck one does not hold
// the window: its rows come when it ends).
FIRST_READING_WAIT :: 2 * time.Second

// What the window wants of the next reading.
Sample_Ask :: struct {
	history:   bool,   // a reading of the period: the graphs get a point of it (not one asked sooner, after a signal)
	cpu_shown: bool,   // the CPU's page is shown: its frequencies are read, and its details once
}

// One reading of the system. Its texts and lists are in its arena, but the CPU's model and the catalog, which the window
// keeps (heap).
Reading :: struct {
	arena:     virtual.Arena,
	ask:       Sample_Ask,
	failed:    bool,              // the processes cannot be read (/proc)
	now_ns:    i64,               // when it was read (monotonic)
	took:      time.Duration,     // what reading it cost
	machine:   Machine_Counters,
	listed:    bool,              // the disks and the interfaces were listed again (disks, nets)
	disks:     [dynamic]Disk_Info,
	nets:      [dynamic]Net_Info,
	info:      Cpu_Info,          // the CPU's details (info_read: read once, while its page shows)
	info_read: bool,
	mhz:       f32,               // the processors' frequencies (mhz_read: while the CPU's page shows)
	core_mhz:  [dynamic]f32,
	mhz_read:  bool,
	procs:     [dynamic]Proc_Counters,
	facts:     [dynamic]Proc_Facts,   // beside procs: what does not change of a process new to the reader (`read`)
	catalog:   ^Catalog,          // the first reading's: the desktop entries
	// the first reading's (session): what Inspecteur is in the session, which its guards read (menu.odin: guard_of)
	session:   bool,
	own_pid:   i32,
	display_server: i32,          // the compositor's pid (0: unknown)
	own_units: []string,          // heap: the units Inspecteur runs in (the window keeps them)
	tz:        ^datetime.TZ_Region,   // heap: the local time's zone (nil: UTC), which the window keeps
}

// The readers, which the job alone touches, and the reading handed to the window.
Sampling :: struct {
	job:      tasks.Job,
	demo:     ^Demo,              // not nil: every reading is the demo's
	// the job's
	opened:   bool,
	ok:       bool,               // /proc could be opened
	procs:    Proc_Reader,
	machine:  Machine_Reader,
	seen:     map[i32]u64,        // pid -> start of the last reading: their facts were read
	readings: int,
	info_read, catalog_read, session_read: bool,
	// shared, under the mutex
	mutex:    sync.Mutex,
	cond:     sync.Cond,          // `ready` was set (the first frame waits for the first reading)
	ask:      Sample_Ask,
	ready:    ^Reading,           // the last reading, not taken yet
	state:    ^ui.State,          // where a reading is posted (nil before the window)
	// the window's
	asked:    bool,               // a reading was asked and not taken
}

sampling_init :: proc(s: ^Sampling, demo: ^Demo) {
	s.demo = demo
	s.job = {work = sampling_work, data = s}
}

// After the chores stopped (no reading runs).
sampling_destroy :: proc(s: ^Sampling) {
	if s.ready != nil { reading_free(s.ready) }
	if s.opened && s.demo == nil {
		if s.ok { proc_reader_destroy(&s.procs) }
		machine_reader_destroy(&s.machine)
	}
	delete(s.seen)
	s^ = {}
}

// Asks for a reading; the next one is due a period later. None while one is under way: its result comes first.
sample_ask :: proc(app: ^App) {
	s := &app.sampling
	app.next_sample = time.tick_add(time.tick_now(), time.Duration(app.settings.refresh_ms) * time.Millisecond)
	if s.asked { return }
	sync.lock(&s.mutex)
	// (a reading sooner than the period, after an action, gives the graphs no point: their span stays the period's)
	s.ask = {history = !app.sample_extra, cpu_shown = app.tab == .Performance && app.device.kind == .Cpu}
	sync.unlock(&s.mutex)
	app.sample_extra = false
	s.asked = tasks.ask(ui.chores(), &s.job)
}

// Once the window is there: the readings are posted to it. Waits for the first reading (at most FIRST_READING_WAIT) and
// takes it, so that the first frame shows the processes.
sampling_attach :: proc(app: ^App, state: ^ui.State) {
	s := &app.sampling
	began := time.tick_now()
	sync.lock(&s.mutex)
	s.state = state
	for s.ready == nil && s.asked {
		left := FIRST_READING_WAIT - time.tick_since(began)
		if left <= 0 { break }
		_ = sync.cond_wait_with_timeout(&s.cond, &s.mutex, left)
	}
	sync.unlock(&s.mutex)
	sample_take(app)
}

// A reading was posted: the window takes it (at the start of its build). Not once the window closed: the reading waits
// in its slot, freed with the sampling.
@(private = "file")
sample_posted :: proc(data: rawptr, word: u64) {
	if the_app != nil && !the_app.closing { sample_take(the_app) }
}

// The last reading becomes the machine's, the processes', their groups and their rows.
sample_take :: proc(app: ^App) {
	s := &app.sampling
	sync.lock(&s.mutex)
	r := s.ready
	s.ready = nil
	sync.unlock(&s.mutex)
	if r == nil { return }
	defer reading_free(r)
	s.asked = false
	t0 := time.tick_now()
	if r.failed && app.sampler.samples == 0 { say(app, i18n.tr("The processes cannot be read (/proc)")) }
	reading_keep(app, r)
	machine_apply(&app.machine, r)
	sampler_apply(&app.sampler, r, app.machine.d_total_ns, &app.catalog)
	gpu := gpu_procs(&app.machine)
	for &p in app.sampler.procs {
		use := gpu[p.pid]
		p.gpu_mem, p.gpu = use.bytes, use.util
	}
	// (the GPUs' numbers are read while they are shown: a GPU that may sleep is let go otherwise. The summary's tile does
	// not ask for them: it would keep a laptop's GPU awake whenever Processes is shown; a GPU that is always on is read
	// anyway)
	gpu_want(&app.machine.gpu, app.tab == .Performance || app.table.layout.shown[int(Column.GPU_Memory)] || app.table.layout.shown[int(Column.GPU)])
	table_group(&app.table, app.sampler.procs[:])
	app_windows_read(app)
	rows_again(app)
	ranking_make(app)
	if app.props.open { props_tick(app, find_proc(&app.sampler, app.props.pid, app.props.start) != nil) }
	app.refresh_time += r.took + time.tick_since(t0)
	app.refreshes += 1
	app.main.settle = max(app.main.settle, 1)
}

// What a reading brings once, the catalog and the session's facts, becomes the window's.
reading_keep :: proc(app: ^App, r: ^Reading) {
	if r.catalog != nil {
		catalog_destroy(&app.catalog)
		app.catalog = r.catalog^
		free(r.catalog)
		r.catalog = nil
	}
	if r.session {
		app.own_pid, app.display_server = r.own_pid, r.display_server
		app.own_units, r.own_units = r.own_units, nil
		app.tz, r.tz = r.tz, nil
	}
}

// On a thread of the chores: a reading, swapped in, posted.
@(private = "file")
sampling_work :: proc(data: rawptr) {
	s := (^Sampling)(data)
	sync.lock(&s.mutex)
	ask := s.ask
	sync.unlock(&s.mutex)
	t0 := time.tick_now()
	r := new(Reading)
	if !s.opened {
		s.opened = true
		s.ok = s.demo != nil || proc_reader_init(&s.procs)
		if s.demo == nil { machine_reader_init(&s.machine) }
	}
	r.failed = !s.ok
	if s.ok { reading_make(s, r, ask, time.tick_now()._nsec) }
	r.took = time.tick_since(t0)
	sync.lock(&s.mutex)
	old := s.ready
	s.ready = r
	state := s.state
	sync.cond_broadcast(&s.cond)
	sync.unlock(&s.mutex)
	// (none waits: the window asks the next reading once it took the last)
	if old != nil { reading_free(old) }
	if state != nil { ui.post(state, sample_posted) }
}

// Reads the system (or the demo) into `r`, at `now_ns`. On the job's thread, or before it starts (the demo's preroll).
reading_make :: proc(s: ^Sampling, r: ^Reading, ask: Sample_Ask, now_ns: i64) {
	// (the readers' temporary texts are the reading's: they outlive this thread's turn)
	context.temp_allocator = virtual.arena_allocator(&r.arena)
	a := context.temp_allocator
	r.ask, r.now_ns = ask, now_ns
	if !s.catalog_read {
		s.catalog_read = true
		r.catalog = new(Catalog)
		if s.demo != nil { demo_catalog(r.catalog) } else { catalog_load(r.catalog) }
	}
	if !s.session_read {
		s.session_read, r.session = true, true
		r.own_pid = i32(os.get_pid())
		r.tz, _ = timezone.region_load("local")
		if s.demo == nil {
			r.display_server = display_server_pid()
			r.own_units = own_units()
		}
	}
	// (the disks and the interfaces at the first reading, then every DEVICES_EVERY)
	if s.readings % DEVICES_EVERY == 0 {
		r.listed = true
		r.disks = make([dynamic]Disk_Info, a)
		r.nets = make([dynamic]Net_Info, a)
		if s.demo != nil { demo_devices(s.demo, &r.disks, &r.nets) } else { disks_list(&r.disks); nets_list(&r.nets) }
	}
	s.readings += 1
	if s.demo != nil { demo_machine_read(s.demo, now_ns, &r.machine) } else { machine_read(&s.machine, &r.machine) }
	if ask.cpu_shown {
		if !s.info_read {
			s.info_read, r.info_read = true, true
			r.info = s.demo != nil ? demo_cpu_info() : cpu_info_read()
		}
		r.core_mhz = make([dynamic]f32, len(r.machine.core_total_ns), a)
		r.mhz = s.demo != nil ? demo_cpu_mhz(s.demo, r.core_mhz[:]) : cpu_mhz_now(r.core_mhz[:])
		r.mhz_read = true
	}
	r.procs = make([dynamic]Proc_Counters, 0, len(s.seen) + 64, a)
	if s.demo != nil { demo_procs_read(s.demo, now_ns, &r.procs) } else { procs_read(&s.procs, &r.procs) }
	// (what does not change in a process's life is read once, for a process this reader has not seen)
	r.facts = make([dynamic]Proc_Facts, len(r.procs), a)
	for c, i in r.procs {
		if start, ok := s.seen[c.pid]; ok && start == c.start { continue }
		r.facts[i] = s.demo != nil ? demo_proc_facts(s.demo, c) : proc_facts(&s.procs, c)
		r.facts[i].read = true
	}
	clear(&s.seen)
	for c in r.procs { s.seen[c.pid] = c.start }
}

reading_free :: proc(r: ^Reading) {
	if r.catalog != nil { catalog_destroy(r.catalog); free(r.catalog) }
	for u in r.own_units { delete(u) }
	if r.tz != nil { timezone.region_destroy(r.tz) }
	delete(r.own_units)
	delete(r.info.model)
	virtual.arena_destroy(&r.arena)
	free(r)
}
