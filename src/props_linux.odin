package inspecteur

// A process's details on Linux, from /proc/<pid>: cwd (its working folder), task/<tid>/stat (its threads), fd/<n> (its
// open files, each a link to what it is), maps (the files it has mapped: its executable, its libraries), environ (the
// environment it was started with). Another user's process refuses most of them: EACCES, or an empty file.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/linux"

proc_cwd :: proc(pid: i32, allocator := context.allocator) -> (cwd: string, state: Read_State) {
	link: [4096]u8
	n, err := linux.readlink(strings.clone_to_cstring(fmt.tprintf("/proc/%d/cwd", pid), context.temp_allocator), link[:])
	if err != .NONE { return "", read_state_of(err, pid) }
	return strings.clone(string(link[:n]), allocator), .Read
}

proc_threads :: proc(pid: i32, out: ^[dynamic]Thread_Row, allocator := context.allocator) -> Read_State {
	base := fmt.tprintf("/proc/%d/task", pid)
	tasks, err := os.read_all_directory_by_path(base, context.temp_allocator)
	if err != nil { return proc_alive(pid) ? .Denied : .Gone }
	buf: [1024]u8
	for t in tasks {
		tid := strconv.parse_int(t.name, 10) or_else 0
		text, _, ok := read_file(buf[:], linux.AT_FDCWD, fmt.tprintf("%s/%d/stat", base, tid))
		if !ok { continue }
		st, parsed := parse_stat(string(text))
		if !parsed { continue }
		append(out, Thread_Row{tid = i32(tid), name = strings.clone(st.comm, allocator), state = proc_state_of(st.state), cpu_ns = st.ticks * TICK_NS, nice = st.nice})
	}
	slice.sort_by(out[:], proc(x, y: Thread_Row) -> bool { return x.tid < y.tid })
	return .Read
}

proc_files :: proc(pid: i32, out: ^[dynamic]File_Row, allocator := context.allocator) -> Read_State {
	base := fmt.tprintf("/proc/%d/fd", pid)
	fds, err := os.read_all_directory_by_path(base, context.temp_allocator)
	if err != nil { return proc_alive(pid) ? .Denied : .Gone }
	link: [4096]u8
	for f in fds {
		fd := strconv.parse_int(f.name, 10) or_else -1
		k, lerr := linux.readlink(strings.clone_to_cstring(fmt.tprintf("%s/%d", base, fd), context.temp_allocator), link[:])
		if lerr != .NONE { continue }
		append(out, File_Row{fd = fd, target = strings.clone(string(link[:k]), allocator)})
	}
	slice.sort_by(out[:], proc(x, y: File_Row) -> bool { return x.fd < y.fd })
	return .Read
}

proc_modules :: proc(pid: i32, out: ^[dynamic]Module_Row, allocator := context.allocator) -> Read_State {
	maps, err := os.read_entire_file(fmt.tprintf("/proc/%d/maps", pid), context.temp_allocator)
	if err != nil { return proc_alive(pid) ? .Denied : .Gone }
	// (another user's process: the file opens and reads as empty)
	if len(maps) == 0 { return proc_alive(pid) ? .Denied : .Gone }
	for m in parse_maps(string(maps)) { append(out, Module_Row{strings.clone(m.path, allocator), m.size}) }
	return .Read
}

proc_environment :: proc(pid: i32, out: ^[dynamic]string, allocator := context.allocator) -> Read_State {
	env, err := os.read_entire_file(fmt.tprintf("/proc/%d/environ", pid), context.temp_allocator)
	if err != nil { return proc_alive(pid) ? .Denied : .Gone }
	if len(env) == 0 { return proc_alive(pid) ? .Denied : .Gone }
	for v in strings.split(strings.trim_right(string(env), "\x00"), "\x00", context.temp_allocator) {
		if v != "" { append(out, strings.clone(v, allocator)) }
	}
	slice.sort(out[:])
	return .Read
}

@(private = "file")
proc_alive :: proc(pid: i32) -> bool { return os.exists(fmt.tprintf("/proc/%d", pid)) }

@(private = "file")
read_state_of :: proc(err: linux.Errno, pid: i32) -> Read_State {
	#partial switch err {
	case .EACCES, .EPERM: return .Denied
	}
	return proc_alive(pid) ? .Denied : .Gone
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
