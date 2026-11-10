package inspecteur

// A process's details on Linux, from its folder /proc/<pid>, opened once per reading: its start time is read through
// it and must be the process's, then every file is read relative to it (openat, readlinkat). Once the process ends,
// every read through that folder fails, even when the pid names a new process: a reading is the process's or nothing.
//
//   cwd            its working folder
//   task/<tid>/stat its threads
//   fd/<n>         its open files, each a link to what it is
//   maps           the files it has mapped: its executable, its libraries
//   environ        the environment it was started with
//
// Another user's process refuses most of them: EACCES, or an empty file.

import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/linux"

// The bytes of maps and environ read at most (a process with many mappings).
PROPS_FILE_MAX :: 16 * 1024 * 1024

// The process's folder, when it is still the process (pid, start).
@(private = "file")
proc_dir_open :: proc(pid: i32, start: u64) -> (dir: linux.Fd, state: Read_State) {
	path: [32]u8
	b := strings.builder_from_bytes(path[:len(path) - 1])
	strings.write_string(&b, "/proc/")
	strings.write_int(&b, int(pid))
	d, err := linux.open(cstring(&path[0]), {.DIRECTORY, .CLOEXEC})
	if err != .NONE { return -1, .Gone }
	buf: [1024]u8
	text, _, ok := read_file(buf[:], d, "stat")
	st, parsed := parse_stat(string(text))
	if !ok || !parsed || st.start != start {
		linux.close(d)
		return -1, .Gone
	}
	return d, .Read
}

@(private = "file")
state_of :: proc(err: linux.Errno) -> Read_State {
	#partial switch err {
	case .EACCES, .EPERM: return .Denied
	}
	return .Gone
}

proc_cwd :: proc(pid: i32, start: u64, allocator := context.allocator) -> (cwd: string, state: Read_State) {
	dir, st := proc_dir_open(pid, start)
	if st != .Read { return "", st }
	defer linux.close(dir)
	link: [4096]u8
	n, err := linux.readlinkat(dir, "cwd", link[:])
	if err != .NONE { return "", state_of(err) }
	return strings.clone(string(link[:n]), allocator), .Read
}

proc_threads :: proc(pid: i32, start: u64, out: ^[dynamic]Thread_Row, allocator := context.allocator) -> Read_State {
	dir, st := proc_dir_open(pid, start)
	if st != .Read { return st }
	defer linux.close(dir)
	tasks, err := linux.openat(dir, "task", {.DIRECTORY, .CLOEXEC})
	if err != .NONE { return state_of(err) }
	defer linux.close(tasks)
	for name in dir_names(tasks) {
		tid, is_num := strconv.parse_int(name, 10)
		if !is_num { continue }
		buf: [1024]u8
		text, _, ok := read_file(buf[:], tasks, strings.concatenate({name, "/stat"}, context.temp_allocator))
		if !ok { continue }   // (a thread that ended)
		t, parsed := parse_stat(string(text))
		if !parsed { continue }
		append(out, Thread_Row{tid = i32(tid), name = strings.clone(t.comm, allocator), state = proc_state_of(t.state), cpu_ns = t.ticks * TICK_NS, nice = t.nice})
	}
	slice.sort_by(out[:], proc(x, y: Thread_Row) -> bool { return x.tid < y.tid })
	return .Read
}

proc_files :: proc(pid: i32, start: u64, out: ^[dynamic]File_Row, allocator := context.allocator) -> Read_State {
	dir, st := proc_dir_open(pid, start)
	if st != .Read { return st }
	defer linux.close(dir)
	fds, err := linux.openat(dir, "fd", {.DIRECTORY, .CLOEXEC})
	if err != .NONE { return state_of(err) }
	defer linux.close(fds)
	link: [4096]u8
	for name in dir_names(fds) {
		fd, is_num := strconv.parse_int(name, 10)
		if !is_num { continue }
		k, lerr := linux.readlinkat(fds, strings.clone_to_cstring(name, context.temp_allocator), link[:])
		if lerr != .NONE { continue }   // (closed in between)
		append(out, File_Row{fd = fd, target = strings.clone(string(link[:k]), allocator)})
	}
	slice.sort_by(out[:], proc(x, y: File_Row) -> bool { return x.fd < y.fd })
	return .Read
}

proc_modules :: proc(pid: i32, start: u64, out: ^[dynamic]Module_Row, allocator := context.allocator) -> Read_State {
	maps, st := read_whole(pid, start, "maps")
	if st != .Read { return st }
	for m in parse_maps(maps) { append(out, Module_Row{strings.clone(m.path, allocator), m.size}) }
	return .Read
}

proc_environment :: proc(pid: i32, start: u64, out: ^[dynamic]string, allocator := context.allocator) -> Read_State {
	env, st := read_whole(pid, start, "environ")
	if st != .Read { return st }
	for v in strings.split(strings.trim_right(env, "\x00"), "\x00", context.temp_allocator) {
		if v != "" { append(out, strings.clone(v, allocator)) }
	}
	slice.sort(out[:])
	return .Read
}

// A file of the process's folder, whole (temporary allocator). Another user's maps and environ open, and read empty.
@(private = "file")
read_whole :: proc(pid: i32, start: u64, name: string) -> (text: string, state: Read_State) {
	dir, st := proc_dir_open(pid, start)
	if st != .Read { return "", st }
	defer linux.close(dir)
	fd, err := linux.openat(dir, strings.clone_to_cstring(name, context.temp_allocator), {.CLOEXEC})
	if err != .NONE { return "", state_of(err) }
	defer linux.close(fd)
	data := make([dynamic]u8, 0, 64 * 1024, context.temp_allocator)
	chunk: [64 * 1024]u8
	for len(data) < PROPS_FILE_MAX {
		n, rerr := linux.read(fd, chunk[:])
		if rerr != .NONE { return "", state_of(rerr) }
		if n <= 0 { break }
		append(&data, ..chunk[:n])
	}
	if len(data) == 0 { return "", .Denied }
	return string(data[:]), .Read
}

// The names of an open folder (temporary allocator).
@(private = "file")
dir_names :: proc(dir: linux.Fd) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	buf: [16 * 1024]u8
	for {
		n, err := linux.getdents(dir, buf[:])
		if err != .NONE || n <= 0 { break }
		off := 0
		for d in linux.dirent_iterate_buf(buf[:n], &off) {
			name := linux.dirent_name(d)
			if name != "." && name != ".." { append(&out, strings.clone(name, context.temp_allocator)) }
		}
	}
	return out[:]
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
