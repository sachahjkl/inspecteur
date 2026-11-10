package inspecteur

// The Properties of one process: what /proc tells of it, read when the dialog opens and again at each sample while it
// is open (its threads, its files, its maps move). Each list is read on its own: one the user may not read (another
// user's process) says "Access denied", the others are shown. Their strings are in an arena, emptied at each reading.

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/linux"

Props_Tab :: enum u8 { General, Threads, Files, Modules, Environment }

PROPS_TAB_LABELS := [Props_Tab]string{.General = "General", .Threads = "Threads", .Files = "Open files", .Modules = "Modules", .Environment = "Environment"}

Thread_Row :: struct {
	tid:   i32,
	name:  string,
	state: u8,
	ticks: u64,   // CPU time, clock ticks
	nice:  i8,
}

File_Row :: struct { fd: int, target: string }

Module_Row :: struct {
	path: string,
	size: u64,   // bytes mapped of it, all its mappings
}

// What was read: nil and `denied` when /proc refused it.
Read_State :: enum u8 { Read, Denied, Gone }

Props :: struct {
	open:     bool,
	pid:      i32,
	start:    u64,
	tab:      Props_Tab,
	size:     [2]f32,   // the dialog's size, as the user left it (modal_sized)
	arena:    virtual.Arena,
	cwd:      string,
	cwd_read: Read_State,
	threads:  [dynamic]Thread_Row,
	threads_read: Read_State,
	files:    [dynamic]File_Row,
	files_read: Read_State,
	modules:  [dynamic]Module_Row,
	modules_read: Read_State,
	env:      [dynamic]string,
	env_read: Read_State,
	nice_sel: int,     // the priority menu's choice (PRIORITIES)
}

// The priorities offered, as nice values. A user may only lower a process's priority (raise its nice) without
// CAP_SYS_NICE: the others are refused ("Access denied").
PRIORITIES := [?]struct { name: string, nice: i8 }{
	{"High (-10)", -10}, {"Above normal (-5)", -5}, {"Normal (0)", 0}, {"Below normal (5)", 5}, {"Low (10)", 10}, {"Idle (19)", 19},
}

props_destroy :: proc(p: ^Props) {
	virtual.arena_destroy(&p.arena)
	delete(p.threads)
	delete(p.files)
	delete(p.modules)
	delete(p.env)
}

props_open :: proc(p: ^Props, pid: i32, start: u64) {
	p.open, p.pid, p.start, p.tab = true, pid, start, .General
	props_read(p)
}

// Reads the process's details again (nothing when it is gone: the dialog says so).
props_read :: proc(p: ^Props) {
	free_all(virtual.arena_allocator(&p.arena))
	clear(&p.threads)
	clear(&p.files)
	clear(&p.modules)
	clear(&p.env)
	a := virtual.arena_allocator(&p.arena)
	base := fmt.tprintf("/proc/%d", p.pid)

	link: [4096]u8
	n, err := linux.readlink(strings.clone_to_cstring(fmt.tprintf("%s/cwd", base), context.temp_allocator), link[:])
	p.cwd_read = state_of(err)
	if err == .NONE { p.cwd = strings.clone(string(link[:n]), a) }

	// the threads: /proc/<pid>/task/<tid>/stat
	tasks, terr := os.read_all_directory_by_path(fmt.tprintf("%s/task", base), context.temp_allocator)
	p.threads_read = terr == nil ? .Read : .Gone
	for t in tasks {
		tid := strconv.parse_int(t.name, 10) or_else 0
		text, _, ok := read_file(make([]u8, 1024, context.temp_allocator), linux.AT_FDCWD, fmt.tprintf("%s/task/%d/stat", base, tid))
		if !ok { continue }
		st, parsed := parse_stat(string(text))
		if !parsed { continue }
		append(&p.threads, Thread_Row{tid = i32(tid), name = strings.clone(st.comm, a), state = st.state, ticks = st.ticks, nice = st.nice})
	}
	slice.sort_by(p.threads[:], proc(x, y: Thread_Row) -> bool { return x.tid < y.tid })

	// the open files: /proc/<pid>/fd/<n>, each a link to what it is
	fds, ferr := os.read_all_directory_by_path(fmt.tprintf("%s/fd", base), context.temp_allocator)
	p.files_read = ferr == nil ? .Read : (os.exists(base) ? .Denied : .Gone)
	for f in fds {
		fd := strconv.parse_int(f.name, 10) or_else -1
		k, lerr := linux.readlink(strings.clone_to_cstring(fmt.tprintf("%s/fd/%d", base, fd), context.temp_allocator), link[:])
		if lerr != .NONE { continue }
		append(&p.files, File_Row{fd = fd, target = strings.clone(string(link[:k]), a)})
	}
	slice.sort_by(p.files[:], proc(x, y: File_Row) -> bool { return x.fd < y.fd })

	// the modules: each file mapped (the executable, its libraries), with the bytes mapped of it
	if maps, merr := os.read_entire_file(fmt.tprintf("%s/maps", base), context.temp_allocator); merr == nil {
		p.modules_read = .Read
		for m in parse_maps(string(maps)) { append(&p.modules, Module_Row{strings.clone(m.path, a), m.size}) }
		// (an unreadable maps file reads as empty: another user's process)
		if len(maps) == 0 && len(p.threads) > 0 { p.modules_read = .Denied }
	} else {
		p.modules_read = os.exists(base) ? .Denied : .Gone
	}

	// the environment, as the process was started with it
	if env, eerr := os.read_entire_file(fmt.tprintf("%s/environ", base), context.temp_allocator); eerr == nil {
		p.env_read = .Read
		for v in strings.split(strings.trim_right(string(env), "\x00"), "\x00", context.temp_allocator) {
			if v != "" { append(&p.env, strings.clone(v, a)) }
		}
		slice.sort(p.env[:])
		if len(env) == 0 && len(p.threads) > 0 { p.env_read = .Denied }
	} else {
		p.env_read = os.exists(base) ? .Denied : .Gone
	}
}

@(private = "file")
state_of :: proc(err: linux.Errno) -> Read_State {
	#partial switch err {
	case .NONE:          return .Read
	case .EACCES, .EPERM: return .Denied
	}
	return .Gone
}

// /proc/<pid>/maps: the files mapped, each with the sum of its mappings' sizes, largest first (temporary allocator).
parse_maps :: proc(text: string) -> []Module_Row {
	sizes := make(map[string]u64, 64, context.temp_allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		// start-end perms offset dev inode path
		f := line
		rng, _ := strings.fields_iterator(&f)
		for _ in 0 ..< 4 { _, _ = strings.fields_iterator(&f) }
		path := strings.trim_space(f)
		if !strings.has_prefix(path, "/") { continue }   // ([heap], [stack], anonymous memory)
		dash := strings.index_byte(rng, '-')
		if dash < 0 { continue }
		lo := strconv.parse_u64(rng[:dash], 16) or_else 0
		hi := strconv.parse_u64(rng[dash + 1:], 16) or_else 0
		sizes[path] += hi - min(lo, hi)
	}
	out := make([dynamic]Module_Row, 0, len(sizes), context.temp_allocator)
	for path, size in sizes { append(&out, Module_Row{path, size}) }
	slice.sort_by(out[:], proc(x, y: Module_Row) -> bool { return x.size != y.size ? x.size > y.size : x.path < y.path })
	return out[:]
}

// The priority menu's line of a nice value: the one at or below it.
priority_index :: proc(nice: i8) -> int {
	at := 0
	for p, i in PRIORITIES { if p.nice <= nice { at = i } }
	return at
}
