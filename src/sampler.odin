package inspecteur

// The processes: a reading of the system's (processes_linux.odin: procs_read, proc_facts) made into the processes the
// window shows. A process is the pair (pid, start): a pid used again is a new process. What does not change in its life
// (its name, command line, executable, owner, app) is learnt once, when it is first seen; what moves (its CPU time, its
// memory, its disk bytes) is read at each sample, and its rates are the differences over the time between two samples.
//
// CPU % is a share of the whole machine (top's Irix mode off, as Windows' Task Manager): the process's CPU time over the
// machine's, both since the last sample. 100 % is every core busy; a process that keeps one core of eight busy shows
// 12.5 %.

import "core:strings"
import "gt:ui"

// The points of a process's history (its graphs in Properties: 5 minutes at the default period), and the last of them
// its CPU cell's graph shows (30 s).
PROC_HISTORY_POINTS :: 300
CPU_GRAPH_POINTS    :: 30

// A process's history since Inspecteur saw it start, bounded: it goes with the process (proc_free).
Proc_History :: struct {
	cpu:    ui.Value_History(PROC_HISTORY_POINTS),   // percent of the machine
	memory: ui.Value_History(PROC_HISTORY_POINTS),   // private bytes
	disk:   ui.Value_History(PROC_HISTORY_POINTS),   // bytes read and written per second
}

Proc_State :: enum u8 { Unknown, Running, Sleeping, Disk_Wait, Stopped, Traced, Zombie, Dead, Idle }

PROC_STATE_TEXT := [Proc_State]string{
	.Unknown = "?", .Running = "Running", .Sleeping = "Sleeping", .Disk_Wait = "Disk wait", .Stopped = "Suspended",
	.Traced = "Traced", .Zombie = "Zombie", .Dead = "Dead", .Idle = "Idle",
}

// What the system says of one process at a sample. The platform's reader fills it; `comm` is in the temporary allocator.
Proc_Counters :: struct {
	pid, ppid: i32,
	start:     u64,      // the system's start time of the process (Linux: clock ticks after boot): with the pid, its identity
	comm:      string,   // its short name (Linux: cut to 15 bytes)
	cpu_ns:    u64,      // its CPU time since it started (user and system), in nanoseconds
	threads:   i32,
	state:     Proc_State,
	nice:      i8,       // -20 (first served) to 19 (last)
	resident:  u64,      // bytes in memory, the pages shared with other processes too
	private:   u64,      // bytes in memory that are its own (not a file's, not shared)
	io_read, io_write: u64,   // bytes read from and written to the storage since it started
	io_known:  bool,     // false: the system does not tell them to this user
}

// What does not change in a process's life, read once (texts in the temporary allocator; `user` is the reader's).
Proc_Facts :: struct {
	name:    string,   // the name it is shown with (whole, a wrapper's marks taken away)
	cmdline: string,   // its arguments, apart by spaces ("" when it cannot be read)
	exe:     string,   // its executable's path ("" when it cannot be read: another user's process)
	user:    string,   // its owner's name
	scope:   string,   // the unit the service manager runs it in (Linux: its systemd unit, a scope or a service), "" none
	user_unit: bool,   // that unit is the user's service manager's, not the system's
	started: i64,      // when it started, unix seconds (0: unknown)
	read:    bool,     // the reader read them (a process it had not seen); false: none were read
}

Proc :: struct {
	pid, ppid:  i32,
	start:      u64,
	started:    i64,
	user:       string,   // the reader's (not owned)
	name:       string,   // owned
	cmdline:    string,   // owned
	exe:        string,   // owned
	unit:       string,   // owned: the service it is a process of ("sshd.service"), "" none (Go to service)
	unit_user:  bool,     // that service is the user's service manager's
	search:     string,   // owned: the name and the command line in lower case (the filter reads it)
	entry:      int,      // the desktop entry the process itself matches (apps.odin), -1: none
	cpu_ns:     u64,      // at the last sample
	cpu:        f32,      // percent of the machine since the last sample
	resident:   u64,
	private:    u64,
	gpu_mem:    u64,      // video memory, bytes (gpu.odin; 0: none, or no GPU tells it)
	gpu:        f32,      // percent of a GPU's time it kept busy, summed over the GPUs (0: none, or no GPU tells it)
	threads:    i32,
	state:      Proc_State,
	nice:       i8,
	io_read, io_write: u64,
	read_rate, write_rate: f64,   // bytes per second since the last sample
	io_known:   bool,
	hist:       ^Proc_History,   // owned
	born_ns:    i64,      // when it was first seen, after the first sample (0: it was there when Inspecteur started)
	ended:      bool,     // missing from the last reading: it ended; kept ENDED_KEEP_NS so its row fades out
	ended_ns:   i64,      // when it was first missing
}

// The window's processes. The system's are read off its thread (sample.odin); a reading becomes these (sampler_apply).
Sampler :: struct {
	procs:   [dynamic]Proc,   // sorted by pid
	last_ns: i64,             // when the last sample was taken (monotonic)
	samples: int,
}

sampler_destroy :: proc(s: ^Sampler) {
	for &p in s.procs { proc_free(&p) }
	delete(s.procs)
	s^ = {}
}

proc_free :: proc(p: ^Proc) {
	delete(p.name)
	delete(p.cmdline)
	delete(p.exe)
	delete(p.unit)
	delete(p.search)
	free(p.hist)
}

// The processes of a reading (sample.odin). `d_total_ns`: the time of all the machine's processors since the last
// sample (machine.odin): a process's CPU % is its share. `catalog`: matches each new process to an app (nil: none).
// The reading's `ask.history`: the sample is one of the period's, which the processes' histories get a point of.
sampler_apply :: proc(s: ^Sampler, r: ^Reading, d_total_ns: u64, catalog: ^Catalog) {
	dt := s.last_ns > 0 ? f64(r.now_ns - s.last_ns) / 1e9 : 0
	s.last_ns = r.now_ns
	s.samples += 1
	procs_merge(s, r.procs[:], r.facts[:], dt, d_total_ns, catalog, r.ask.history, r.now_ns)
}

// How long a process that ended keeps its row (in red, fading: table_view.odin), its rates at 0.
ENDED_KEEP_NS :: 2 * 1_000_000_000

// Keeps a process that ended for ENDED_KEEP_NS (its rates at 0), or frees it after; true when it is kept.
@(private = "file")
proc_ended :: proc(p: ^Proc, now_ns: i64) -> bool {
	if !p.ended {
		p.ended, p.ended_ns = true, now_ns
		p.cpu, p.read_rate, p.write_rate = 0, 0, 0
	}
	if now_ns - p.ended_ns < ENDED_KEEP_NS { return true }
	proc_free(p)
	return false
}

// The processes from a reading (sorted by pid): those already known keep what was learnt of them and get their rates;
// a new one (a new pid, or a pid with another start) is learnt from its facts (`facts`, beside `counters`: those the
// reader read; none, or not read: its command name alone).
procs_merge :: proc(s: ^Sampler, counters: []Proc_Counters, facts: []Proc_Facts, dt: f64, d_total_ns: u64, catalog: ^Catalog, history := true, now_ns: i64 = 0) {
	next := make([dynamic]Proc, 0, len(counters))
	old := 0
	for c, i in counters {
		for old < len(s.procs) && s.procs[old].pid < c.pid {
			if proc_ended(&s.procs[old], now_ns) { append(&next, s.procs[old]) }
			old += 1
		}
		p: Proc
		known := old < len(s.procs) && s.procs[old].pid == c.pid && s.procs[old].start == c.start && !s.procs[old].ended
		if known {
			p = s.procs[old]
			old += 1
		} else {
			if old < len(s.procs) && s.procs[old].pid == c.pid {   // (the pid of a process that ended, used again)
				proc_free(&s.procs[old])
				old += 1
			}
			f := i < len(facts) && facts[i].read ? facts[i] : Proc_Facts{}
			proc_learn(&p, c, f, catalog)
			// (the processes of the first sample were there before: only those that come after are new)
			if s.samples > 1 { p.born_ns = now_ns }
		}
		proc_update(&p, c, known, dt, d_total_ns)
		// (a process seen for the first time has no rates yet: its first point is its second sample's)
		if history && known {
			ui.value_history_push(&p.hist.cpu, p.cpu)
			ui.value_history_push(&p.hist.memory, f32(p.private))
			ui.value_history_push(&p.hist.disk, f32(p.read_rate + p.write_rate))
		}
		append(&next, p)
	}
	for ; old < len(s.procs); old += 1 {
		if proc_ended(&s.procs[old], now_ns) { append(&next, s.procs[old]) }
	}
	delete(s.procs)
	s.procs = next
}

@(private = "file")
proc_learn :: proc(p: ^Proc, c: Proc_Counters, f: Proc_Facts, catalog: ^Catalog) {
	p.pid, p.start, p.started, p.user = c.pid, c.start, f.started, f.user
	p.hist = new(Proc_History)
	p.name = strings.clone(f.name != "" ? f.name : c.comm)
	p.cmdline = strings.clone(f.cmdline)
	p.exe = strings.clone(f.exe)
	if strings.has_suffix(f.scope, ".service") { p.unit, p.unit_user = strings.clone(f.scope), f.user_unit }
	p.search = strings.to_lower(strings.concatenate({p.name, " ", p.cmdline}, context.temp_allocator))
	p.entry = catalog != nil ? catalog_match(catalog, p.name, p.exe, f.scope, p.cmdline) : -1
}

// What moves: the counters of this sample, and the rates since the last one (none for a process seen for the first time).
proc_update :: proc(p: ^Proc, c: Proc_Counters, known: bool, dt: f64, d_total_ns: u64) {
	p.ppid, p.threads, p.state, p.nice = c.ppid, c.threads, c.state, c.nice
	p.resident, p.private = c.resident, c.private
	p.cpu = known && d_total_ns > 0 ? f32(100 * f64(c.cpu_ns - min(p.cpu_ns, c.cpu_ns)) / f64(d_total_ns)) : 0
	p.cpu_ns = c.cpu_ns
	was_known := known && p.io_known
	p.io_known = c.io_known
	p.read_rate, p.write_rate = 0, 0
	if c.io_known {
		if was_known {
			p.read_rate = rate_of(p.io_read, c.io_read, dt)
			p.write_rate = rate_of(p.io_write, c.io_write, dt)
		}
		p.io_read, p.io_write = c.io_read, c.io_write
	}
}

// The last `n` points of a history (fewer while it is young), oldest first, into `out`; returns how many.
history_tail :: proc(h: ^ui.Value_History(PROC_HISTORY_POINTS), out: []f32) -> int {
	n := min(len(out), h.count)
	for i in 0 ..< n { out[i] = ui.value_history_at(h, h.count - n + i) }
	return n
}

// The mean of the last CPU_GRAPH_POINTS points of a process's CPU (what the CPU graph column sorts by).
cpu_recent :: proc(p: ^Proc) -> f32 {
	if p.hist == nil { return 0 }
	buf: [CPU_GRAPH_POINTS]f32
	n := history_tail(&p.hist.cpu, buf[:])
	sum: f32
	for v in buf[:n] { sum += v }
	return n > 0 ? sum / f32(n) : 0
}

// A counter's rate per second between two readings `dt` seconds apart; 0 when the counter went back (it was reset).
rate_of :: proc(before, after: u64, dt: f64) -> f64 {
	if dt <= 0 || after < before { return 0 }
	return f64(after - before) / dt
}

// A process's state as words.
state_text :: proc(state: Proc_State) -> string { return PROC_STATE_TEXT[state] }

// The process (pid, start) of the last sample, nil when it is not there.
find_proc :: proc(s: ^Sampler, pid: i32, start: u64) -> ^Proc {
	p := find_pid(s, pid)
	if p != nil && p.start == start { return p }
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
