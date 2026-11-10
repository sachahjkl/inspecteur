package inspecteur

// The processes, read from /proc and nothing else. A sample reads the whole machine's CPU time and memory, then each
// process's stat (and io when the user may read it). What does not change in a process's life (its name, command line,
// executable, owner, app) is read once, when the process is first seen: a process is the pair (pid, start time), so a
// pid used again is a new process.
//
// CPU % is a share of the whole machine (top's Irix mode off, as Windows' Task Manager): the process's CPU time over the
// machine's, both since the last sample. 100 % is every core busy; a process that keeps one core of eight busy shows
// 12.5 %.

import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import ascii "gt:ascii"

// Bytes read of a file of /proc, at most: /proc/stat on a machine of many cores, a long command line.
PROC_READ_MAX :: 64 * 1024
// The flag of a kernel thread in the stat's flags (PF_KTHREAD): not a program, not shown.
PF_KTHREAD :: 0x00200000
// Bytes of a memory page (x86-64 and arm64's usual size; the stat's RSS is in pages).
PAGE_BYTES :: 4096
// The unit of the CPU times and start times of /proc (USER_HZ, the same on every Linux).
CLOCK_TICKS :: 100
// The command line kept of a process, at most.
CMDLINE_MAX :: 4096

Proc :: struct {
	pid, ppid:  i32,
	start:      u64,      // start time in clock ticks after boot: with the pid, the process's identity
	uid:        u32,
	name:       string,   // owned
	cmdline:    string,   // owned: the arguments, apart by spaces
	exe:        string,   // owned: the executable's path; "" when it cannot be read (another user's process)
	search:     string,   // owned: the name and the command line in lower case (the filter reads it)
	entry:      int,      // the desktop entry the process itself matches (apps.odin), -1: none
	ticks:      u64,      // user + system CPU time, clock ticks, at the last sample
	cpu:        f32,      // percent of the machine since the last sample
	rss:        u64,      // resident memory, bytes
	gpu_mem:    u64,      // video memory, bytes (gpu.odin; 0: none, or no GPU tells it)
	threads:    i32,
	state:      u8,       // R running, S sleeping, D disk wait, T stopped, Z zombie...
	nice:       i8,       // -20 (first served) to 19 (last)
	io_read, io_write: u64,   // bytes read from and written to the disk, since the start
	read_rate, write_rate: f64,   // bytes per second since the last sample
	io_denied:  bool,     // /proc/<pid>/io is not ours to read: never asked again
}

Sampler :: struct {
	procs:      [dynamic]Proc,   // sorted by pid
	proc_dir:   linux.Fd,
	buf:        []u8,            // PROC_READ_MAX bytes: what each read fills
	users:      map[u32]string,  // uid -> login name (/etc/passwd), owned
	last_ns:    i64,             // when the last sample was taken (monotonic)
	samples:    int,
}

sampler_init :: proc(s: ^Sampler) -> bool {
	fd, err := linux.open("/proc", {.DIRECTORY, .CLOEXEC})
	if err != .NONE { return false }
	s.proc_dir = fd
	s.buf = make([]u8, PROC_READ_MAX)
	users_read(s)
	return true
}

sampler_destroy :: proc(s: ^Sampler) {
	for &p in s.procs { proc_free(&p) }
	delete(s.procs)
	for _, name in s.users { delete(name) }
	delete(s.users)
	delete(s.buf)
	if s.proc_dir > 0 { linux.close(s.proc_dir) }
	s^ = {}
}

proc_free :: proc(p: ^Proc) {
	delete(p.name)
	delete(p.cmdline)
	delete(p.exe)
	delete(p.search)
}

user_name :: proc(s: ^Sampler, uid: u32) -> string {
	if name, ok := s.users[uid]; ok { return name }
	return "?"
}

// Reads every process again. `now_ns`: a monotonic clock. `d_total`: the machine's CPU ticks since the last sample
// (machine.odin): a process's CPU % is its share. `catalog`: matches each new process to an
// app (nil: none).
sample :: proc(s: ^Sampler, now_ns: i64, d_total: u64, catalog: ^Catalog) {
	dt := s.last_ns > 0 ? f64(now_ns - s.last_ns) / 1e9 : 0
	s.last_ns = now_ns
	s.samples += 1

	// the pids, in order
	pids := make([dynamic]i32, 0, len(s.procs) + 64, context.temp_allocator)
	list_pids(&pids)
	slice.sort(pids[:])

	next := make([dynamic]Proc, 0, len(pids))
	old := 0
	for pid in pids {
		for old < len(s.procs) && s.procs[old].pid < pid {
			proc_free(&s.procs[old])
			old += 1
		}
		text, ok := read_at(s, path_of(pid, "stat"))
		if !ok { continue }   // (it ended in between)
		st, parsed := parse_stat(string(text))
		if !parsed || st.flags & PF_KTHREAD != 0 || pid == 2 || st.ppid == 2 { continue }
		p: Proc
		known := old < len(s.procs) && s.procs[old].pid == pid && s.procs[old].start == st.start
		if known {
			p = s.procs[old]
			old += 1
		} else {
			if old < len(s.procs) && s.procs[old].pid == pid {   // (the pid of a process that ended, used again)
				proc_free(&s.procs[old])
				old += 1
			}
			proc_learn(s, &p, pid, st, catalog)
		}
		p.ppid = st.ppid
		p.threads = st.threads
		p.state, p.nice = st.state, st.nice
		p.rss = st.rss_pages * PAGE_BYTES
		p.cpu = known && d_total > 0 ? 100 * f32(st.ticks - min(p.ticks, st.ticks)) / f32(d_total) : 0
		p.ticks = st.ticks
		if !p.io_denied {
			io, readable, denied := read_io(s, pid)
			if denied { p.io_denied = true }
			if readable {
				if known && dt > 0 {
					p.read_rate = f64(io.read - min(p.io_read, io.read)) / dt
					p.write_rate = f64(io.write - min(p.io_write, io.write)) / dt
				}
				p.io_read, p.io_write = io.read, io.write
			}
		}
		append(&next, p)
	}
	for ; old < len(s.procs); old += 1 { proc_free(&s.procs[old]) }
	delete(s.procs)
	s.procs = next
}

// What does not change in a process's life, read once.
@(private = "file")
proc_learn :: proc(s: ^Sampler, p: ^Proc, pid: i32, st: Stat_Fields, catalog: ^Catalog) {
	p.pid, p.start = pid, st.start
	p.entry = -1
	comm := strings.clone(st.comm, context.temp_allocator)   // (it is in the buffer the next read fills)
	argv0 := ""
	if text, ok := read_at(s, path_of(pid, "cmdline")); ok {
		raw := string(text[:min(len(text), CMDLINE_MAX)])
		raw = strings.trim_right(raw, "\x00")
		if i := strings.index_byte(raw, 0); i >= 0 { argv0 = raw[:i] } else { argv0 = raw }
		cmd, _ := strings.replace_all(raw, "\x00", " ", context.temp_allocator)
		p.cmdline = strings.clone(cmd)
	} else {
		p.cmdline = strings.clone("")
	}
	link: [4096]u8   // (PATH_MAX)
	exe_path := path_of(pid, "exe")
	if n, err := linux.readlinkat(s.proc_dir, strings.clone_to_cstring(exe_path, context.temp_allocator), link[:]); err == .NONE && n > 0 {
		p.exe = strings.clone(strings.trim_suffix(string(link[:n]), " (deleted)"))
	} else {
		p.exe = strings.clone("")
	}
	p.name = strings.clone(display_name(comm, argv0, p.exe))
	stat: linux.Stat
	if linux.fstatat(s.proc_dir, strings.clone_to_cstring(path_of(pid, ""), context.temp_allocator), &stat, {}) == .NONE { p.uid = u32(stat.uid) }
	p.search = strings.to_lower(strings.concatenate({p.name, " ", p.cmdline}, context.temp_allocator))
	if catalog != nil {
		scope := ""
		if text, ok := read_at(s, path_of(pid, "cgroup")); ok { scope = cgroup_scope(string(text)) }
		p.entry = catalog_match(catalog, p.name, p.exe, scope)
	}
}

// Whether the process (pid, start) runs now, read again from /proc (not from the last sample).
proc_alive :: proc(s: ^Sampler, pid: i32, start: u64) -> bool {
	text, ok := read_at(s, path_of(pid, "stat"))
	if !ok { return false }
	st, parsed := parse_stat(string(text))
	return parsed && st.start == start
}

// The name a process is shown with: its command name, whole when the kernel cut it (15 bytes) and the first argument
// or the executable holds it, and without the dot and "-wrapped" of a Nix wrapper (.firefox-wrapped is firefox).
display_name :: proc(comm, argv0, exe: string) -> string {
	name := comm
	if len(comm) == 15 {
		for whole in ([]string{argv0, exe}) {
			base := whole
			if i := strings.index_byte(base, ' '); i >= 0 { base = base[:i] }   // (a program that rewrote its title)
			if i := strings.last_index_byte(base, '/'); i >= 0 { base = base[i + 1:] }
			if strings.has_prefix(base, comm) { name = base; break }
		}
	}
	return unwrapped(name)
}

// A name without a Nix wrapper's marks: ".firefox-wrapped" (or its cut ".firefox-wrappe") is "firefox".
unwrapped :: proc(name: string) -> string {
	n := name
	if strings.has_prefix(n, ".") && strings.contains(n, "-wrap") {
		n = n[1:]
		if i := strings.last_index(n, "-wrap"); i > 0 { n = n[:i] }
	}
	return n
}

// "1234/stat" in the temporary allocator (`file` "" is the process's folder).
@(private = "file")
path_of :: proc(pid: i32, file: string) -> string {
	buf: [16]u8
	n := strconv.write_int(buf[:], i64(pid), 10)
	if file == "" { return strings.clone(n, context.temp_allocator) }
	return strings.concatenate({n, "/", file}, context.temp_allocator)
}

// A file of /proc, whole up to PROC_READ_MAX, in the sampler's buffer (valid until the next read).
@(private = "file")
read_at :: proc(s: ^Sampler, path: string) -> (data: []u8, ok: bool) {
	data, _, ok = read_errno(s, path)
	return
}

@(private = "file")
read_errno :: proc(s: ^Sampler, path: string) -> (data: []u8, err: linux.Errno, ok: bool) {
	return read_file(s.buf, s.proc_dir, path)
}

// A file whole, up to the buffer's size, in `buf` (valid until its next read). `dir`: the folder a relative `path` is in
// (linux.AT_FDCWD: an absolute one). One open, reads, one close: no allocation.
read_file :: proc(buf: []u8, dir: linux.Fd, path: string) -> (data: []u8, err: linux.Errno, ok: bool) {
	name: [256]u8
	if len(path) >= len(name) { return nil, .ENAMETOOLONG, false }
	copy(name[:], path)
	fd, e := linux.openat(dir, cstring(&name[0]), {.CLOEXEC})
	if e != .NONE { return nil, e, false }
	defer linux.close(fd)
	n := 0
	for n < len(buf) {
		k, re := linux.read(fd, buf[n:])
		if re != .NONE { return nil, re, false }
		if k <= 0 { break }
		n += k
	}
	return buf[:n], .NONE, true
}

// A small file of /sys or /proc as text, trimmed ("" when it cannot be read), in the temporary allocator.
read_text :: proc(path: string) -> string {
	buf: [512]u8
	data, _, ok := read_file(buf[:], linux.AT_FDCWD, path)
	if !ok { return "" }
	return strings.clone(strings.trim_space(string(data)), context.temp_allocator)
}

@(private = "file")
read_io :: proc(s: ^Sampler, pid: i32) -> (io: Io_Fields, readable, denied: bool) {
	text, err, ok := read_errno(s, path_of(pid, "io"))
	if !ok { return {}, false, err == .EACCES || err == .EPERM }
	return parse_io(string(text)), true, false
}

// The pids under /proc.
@(private = "file")
list_pids :: proc(out: ^[dynamic]i32) {
	fd, err := linux.open("/proc", {.DIRECTORY, .CLOEXEC})
	if err != .NONE { return }
	defer linux.close(fd)
	buf: [16 * 1024]u8
	for {
		n, e := linux.getdents(fd, buf[:])
		if e != .NONE || n <= 0 { break }
		offs := 0
		for d in linux.dirent_iterate_buf(buf[:n], &offs) {
			name := linux.dirent_name(d)
			if len(name) == 0 || name[0] < '0' || name[0] > '9' { continue }
			if pid, ok := strconv.parse_int(name, 10); ok { append(out, i32(pid)) }
		}
	}
}

// uid -> login name, from /etc/passwd.
@(private = "file")
users_read :: proc(s: ^Sampler) {
	fd, err := linux.open("/etc/passwd", {.CLOEXEC})
	if err != .NONE { return }
	defer linux.close(fd)
	n, _ := linux.read(fd, s.buf)
	rest := string(s.buf[:max(n, 0)])
	for line in strings.split_lines_iterator(&rest) {
		f := strings.split_n(line, ":", 4, context.temp_allocator)
		if len(f) < 3 { continue }
		uid, ok := strconv.parse_uint(f[2], 10)
		if !ok || u32(uid) in s.users { continue }
		s.users[u32(uid)] = strings.clone(f[0])
	}
}

////////////////////////////////
// The files' formats (pure: unit tests read them)

Stat_Fields :: struct {
	comm:      string,
	ppid:      i32,
	flags:     u32,
	ticks:     u64,   // utime + stime
	threads:   i32,
	state:     u8,
	nice:      i8,
	start:     u64,
	rss_pages: u64,
}

// /proc/<pid>/stat. The command name is between the first '(' and the last ')': it may hold spaces and parentheses.
parse_stat :: proc(text: string) -> (f: Stat_Fields, ok: bool) {
	open := strings.index_byte(text, '(')
	close := strings.last_index_byte(text, ')')
	if open < 0 || close < open { return }
	f.comm = text[open + 1:close]
	rest := text[close + 1:]
	field := 3   // (the state, after the name)
	for word in strings.fields_iterator(&rest) {
		switch field {
		case 3:  f.state = word[0]
		case 4:  f.ppid = i32(strconv.parse_int(word, 10) or_else 0)
		case 9:  f.flags = u32(strconv.parse_uint(word, 10) or_else 0)
		case 14, 15: f.ticks += u64(strconv.parse_uint(word, 10) or_else 0)
		case 19: f.nice = i8(strconv.parse_int(word, 10) or_else 0)
		case 20: f.threads = i32(strconv.parse_int(word, 10) or_else 0)
		case 22: f.start = u64(strconv.parse_uint(word, 10) or_else 0)
		case 24:
			f.rss_pages = u64(strconv.parse_uint(word, 10) or_else 0)
			return f, true
		}
		field += 1
	}
	return
}

Io_Fields :: struct { read, write: u64 }

// /proc/<pid>/io: the bytes that went to the storage (read_bytes, write_bytes), not those of the page cache.
parse_io :: proc(text: string) -> (io: Io_Fields) {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(line, "read_bytes:") { io.read = u64(strconv.parse_uint(strings.trim_space(line[11:]), 10) or_else 0) }
		if strings.has_prefix(line, "write_bytes:") { io.write = u64(strconv.parse_uint(strings.trim_space(line[12:]), 10) or_else 0) }
	}
	return
}

// The systemd unit of a process, from /proc/<pid>/cgroup ("0::/user.slice/.../app-firefox-1234.scope" gives
// "app-firefox-1234.scope"): the launcher put an app's id in it.
cgroup_scope :: proc(text: string) -> string {
	line := text
	if i := strings.index_byte(line, '\n'); i >= 0 { line = line[:i] }
	if i := strings.last_index_byte(line, '/'); i >= 0 { line = line[i + 1:] }
	return line
}

// "1.5 GB", "320 MB", "12 KB", "0 B": a size in powers of 1024, as most system monitors show it.
size_text :: proc(n: u64, allocator := context.temp_allocator) -> string {
	UNITS :: [?]string{"B", "KB", "MB", "GB", "TB"}
	v := f64(n)
	u := 0
	for v >= 1024 && u < len(UNITS) - 1 { v /= 1024; u += 1 }
	units := UNITS
	if u == 0 { return strings.concatenate({uint_text(n), " B"}, allocator) }
	buf: [32]u8
	digits := v < 10 ? 1 : 0
	s := strconv.write_float(buf[:], v, 'f', digits, 64)
	if len(s) > 0 && s[0] == '+' { s = s[1:] }
	return strings.concatenate({s, " ", units[u]}, allocator)
}

// A rate in bytes per second: "" when nothing moves (an empty cell reads faster than a column of zeros).
rate_text :: proc(bytes_per_s: f64, allocator := context.temp_allocator) -> string {
	if bytes_per_s < 1 { return "" }
	return strings.concatenate({size_text(u64(bytes_per_s), context.temp_allocator), "/s"}, allocator)
}

uint_text :: proc(n: u64, allocator := context.temp_allocator) -> string {
	buf: [24]u8
	return strings.clone(strconv.write_uint(buf[:], n, 10), allocator)
}

// A name in lower case for the catalog's keys (ASCII: names and ids, not prose).
key_of :: proc(name: string, allocator := context.temp_allocator) -> string { return ascii.lower(name, allocator) }
