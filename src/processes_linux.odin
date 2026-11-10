package inspecteur

// The processes on Linux, from /proc and nothing else, read with system calls (openat, read, getdents) into one buffer.
// A reading takes, for each process, its stat (parent, CPU time, threads, state, nice, start time), its statm (resident
// and shared pages: the private memory is their difference) and its io (bytes read from and written to the storage),
// when the user may read it. What does not change in a process's life (proc_facts: its command line, its executable, its
// owner, its systemd unit) is read once, when the sampler first sees the process.
//
// Kernel threads (PF_KTHREAD, kthreadd and its children) are not programs: they are left out.

import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/linux"

// Bytes read of a file of /proc, at most: /proc/stat on a machine of many cores, a long command line.
PROC_READ_MAX :: 64 * 1024
// The flag of a kernel thread in the stat's flags (PF_KTHREAD): not a program, not shown.
PF_KTHREAD :: 0x00200000
// Bytes of a memory page when the system does not say (statm counts pages): x86-64's; arm64 may have 16 or 64 KB pages.
PAGE_BYTES_USUAL :: 4096
// The auxiliary vector's key of the page size (AT_PAGESZ, <elf.h>).
AT_PAGESZ :: 6
// The unit of the CPU times and start times of /proc (USER_HZ, the same on every Linux).
CLOCK_TICKS :: 100
// Nanoseconds of a clock tick.
TICK_NS :: 1_000_000_000 / CLOCK_TICKS
// The command line kept of a process, at most.
CMDLINE_MAX :: 4096

Proc_Reader :: struct {
	proc_dir:  linux.Fd,
	buf:       []u8,               // PROC_READ_MAX bytes: what each read fills
	users:     map[u32]string,     // uid -> login name (/etc/passwd), or the uid's number when it has none; owned
	io_denied: map[i32]Io_Denied,  // the processes whose io is not ours to read: never asked again
	readings:  int,
	boot_time: i64,                // unix seconds (btime of /proc/stat): a process's start is its ticks after it
	page_bytes: u64,               // the system's memory page (page_size)
}

@(private = "file")
Io_Denied :: struct { start: u64, reading: int }

proc_reader_init :: proc(r: ^Proc_Reader) -> bool {
	fd, err := linux.open("/proc", {.DIRECTORY, .CLOEXEC})
	if err != .NONE { return false }
	r.proc_dir = fd
	r.buf = make([]u8, PROC_READ_MAX)
	r.page_bytes = page_size(r.buf)
	users_read(r)
	if text, _, ok := read_file(r.buf, linux.AT_FDCWD, "/proc/stat"); ok { r.boot_time = parse_cpu_times(string(text)).boot_time }
	return true
}

proc_reader_destroy :: proc(r: ^Proc_Reader) {
	for _, name in r.users { delete(name) }
	delete(r.users)
	delete(r.io_denied)
	delete(r.buf)
	if r.proc_dir > 0 { linux.close(r.proc_dir) }
	r^ = {}
}

// Every process now, sorted by pid (its `comm` in the temporary allocator).
procs_read :: proc(r: ^Proc_Reader, out: ^[dynamic]Proc_Counters) {
	r.readings += 1
	pids := make([dynamic]i32, 0, 512, context.temp_allocator)
	list_pids(&pids)
	slice.sort(pids[:])
	for pid in pids {
		text, ok := read_at(r, path_of(pid, "stat"))
		if !ok { continue }   // (it ended in between)
		st, parsed := parse_stat(string(text))
		if !parsed || st.flags & PF_KTHREAD != 0 || pid == 2 || st.ppid == 2 { continue }
		c := Proc_Counters{
			pid = pid, ppid = st.ppid, start = st.start, comm = strings.clone(st.comm, context.temp_allocator),
			cpu_ns = st.ticks * TICK_NS, threads = st.threads, state = proc_state_of(st.state), nice = st.nice,
			resident = st.rss_pages * r.page_bytes,
		}
		if mtext, mok := read_at(r, path_of(pid, "statm")); mok {
			if m, pok := parse_statm(string(mtext)); pok {
				c.resident = m.resident * r.page_bytes
				c.private = (m.resident - min(m.shared, m.resident)) * r.page_bytes
			}
		}
		if d, denied := r.io_denied[pid]; denied && d.start == st.start {
			r.io_denied[pid] = {st.start, r.readings}
		} else {
			data, err, iok := read_file(r.buf, r.proc_dir, path_of(pid, "io"))
			if iok {
				io := parse_io(string(data))
				c.io_read, c.io_write, c.io_known = io.read, io.write, true
			} else if err == .EACCES || err == .EPERM {
				r.io_denied[pid] = {st.start, r.readings}
			}
		}
		append(out, c)
	}
	// (a pid that went, or was given to another process, is asked again)
	gone := make([dynamic]i32, context.temp_allocator)
	for pid, d in r.io_denied { if d.reading != r.readings { append(&gone, pid) } }
	for pid in gone { delete_key(&r.io_denied, pid) }
}

// What does not change in the life of the process `c`: its command line, its executable, its owner, its unit, when
// it started (texts in the temporary allocator; the user's name is the reader's).
proc_facts :: proc(r: ^Proc_Reader, c: Proc_Counters) -> (f: Proc_Facts) {
	argv0 := ""
	if text, ok := read_at(r, path_of(c.pid, "cmdline")); ok {
		raw := string(text[:min(len(text), CMDLINE_MAX)])
		raw = strings.trim_right(raw, "\x00")
		if i := strings.index_byte(raw, 0); i >= 0 { argv0 = raw[:i] } else { argv0 = raw }
		argv0 = strings.clone(argv0, context.temp_allocator)   // (the buffer is filled again below)
		f.cmdline, _ = strings.replace_all(raw, "\x00", " ", context.temp_allocator)
		if f.cmdline == raw { f.cmdline = strings.clone(raw, context.temp_allocator) }
	}
	link: [4096]u8   // (PATH_MAX)
	if n, err := linux.readlinkat(r.proc_dir, strings.clone_to_cstring(path_of(c.pid, "exe"), context.temp_allocator), link[:]); err == .NONE && n > 0 {
		f.exe = strings.clone(strings.trim_suffix(string(link[:n]), " (deleted)"), context.temp_allocator)
	}
	f.name = display_name(c.comm, argv0, f.exe)
	stat: linux.Stat
	if linux.fstatat(r.proc_dir, strings.clone_to_cstring(path_of(c.pid, ""), context.temp_allocator), &stat, {}) == .NONE {
		f.user = user_name_of(r, u32(stat.uid))
	}
	if text, ok := read_at(r, path_of(c.pid, "cgroup")); ok {
		f.scope = strings.clone(cgroup_scope(string(text)), context.temp_allocator)
		// (a unit of the user's manager is under its user@<uid>.service)
		f.user_unit = strings.contains(string(text), "/user@")
	}
	if r.boot_time > 0 { f.started = r.boot_time + i64(c.start / CLOCK_TICKS) }
	return
}

// The login name of `uid`: /etc/passwd's, read again once for a uid it did not have (a user added since), else the
// uid's number.
@(private = "file")
user_name_of :: proc(r: ^Proc_Reader, uid: u32) -> string {
	if name, ok := r.users[uid]; ok { return name }
	users_read(r)
	if name, ok := r.users[uid]; ok { return name }
	name := strings.clone(uint_text(u64(uid)))
	r.users[uid] = name
	return name
}

// The size of a memory page: AT_PAGESZ of the process's auxiliary vector (/proc/self/auxv: pairs of words, key and
// value, as the kernel gave them to the program), else the usual 4096.
@(private = "file")
page_size :: proc(buf: []u8) -> u64 {
	data, _, ok := read_file(buf, linux.AT_FDCWD, "/proc/self/auxv")
	if !ok { return PAGE_BYTES_USUAL }
	words := slice.reinterpret([]u64, data[:len(data) / 8 * 8])
	for i := 0; i + 1 < len(words); i += 2 {
		if words[i] == AT_PAGESZ && words[i + 1] > 0 { return words[i + 1] }
	}
	return PAGE_BYTES_USUAL
}

// uid -> login name, from /etc/passwd (whole: a file of many users is longer than the buffer).
@(private = "file")
users_read :: proc(r: ^Proc_Reader) {
	data, err := os.read_entire_file("/etc/passwd", context.temp_allocator)
	if err != nil { return }
	for uid, name in parse_passwd(string(data)) {
		if uid in r.users { continue }
		r.users[uid] = strings.clone(name)
	}
}

// "1234/stat" in the temporary allocator (`file` "" is the process's folder).
@(private = "file")
path_of :: proc(pid: i32, file: string) -> string {
	buf: [16]u8
	n := strconv.write_int(buf[:], i64(pid), 10)
	if file == "" { return strings.clone(n, context.temp_allocator) }
	return strings.concatenate({n, "/", file}, context.temp_allocator)
}

// A file of /proc, whole up to PROC_READ_MAX, in the reader's buffer (valid until its next read).
@(private = "file")
read_at :: proc(r: ^Proc_Reader, path: string) -> (data: []u8, ok: bool) {
	data, _, ok = read_file(r.buf, r.proc_dir, path)
	return
}

// The state of the process (pid, start) now (Unknown when it is gone, or its pid is another process's).
proc_state_now :: proc(pid: i32, start: u64) -> Proc_State {
	buf: [1024]u8
	text, _, ok := read_file(buf[:], linux.AT_FDCWD, strings.concatenate({"/proc/", path_of(pid, "stat")}, context.temp_allocator))
	if !ok { return .Unknown }
	st, parsed := parse_stat(string(text))
	if !parsed || st.start != start { return .Unknown }
	return proc_state_of(st.state)
}

// The pids under /proc.
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

// The names in a folder, in order (temporary allocator; none when it cannot be read).
list_dir :: proc(path: string) -> []string {
	fis, err := os.read_all_directory_by_path(path, context.temp_allocator)
	if err != nil { return nil }
	out := make([]string, len(fis), context.temp_allocator)
	for fi, i in fis { out[i] = fi.name }
	slice.sort(out)
	return out
}

// A small file of /sys or /proc as text, trimmed ("" when it cannot be read), in the temporary allocator.
read_text :: proc(path: string) -> string {
	buf: [512]u8
	data, _, ok := read_file(buf[:], linux.AT_FDCWD, path)
	if !ok { return "" }
	return strings.clone(strings.trim_space(string(data)), context.temp_allocator)
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

// A state letter of /proc/<pid>/stat.
proc_state_of :: proc(letter: u8) -> Proc_State {
	switch letter {
	case 'R': return .Running
	case 'S': return .Sleeping
	case 'D': return .Disk_Wait
	case 'T': return .Stopped
	case 't': return .Traced
	case 'Z': return .Zombie
	case 'X', 'x': return .Dead
	case 'I': return .Idle
	}
	return .Unknown
}

Statm_Fields :: struct { size, resident, shared: u64 }

// /proc/<pid>/statm: the pages of the address space, resident, and resident and shared with others (a file's, or
// shared memory's).
parse_statm :: proc(text: string) -> (m: Statm_Fields, ok: bool) {
	rest := text
	i := 0
	for word in strings.fields_iterator(&rest) {
		v, vok := strconv.parse_u64(word, 10)
		if !vok { return }
		switch i {
		case 0: m.size = v
		case 1: m.resident = v
		case 2:
			m.shared = v
			return m, true
		}
		i += 1
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

// /etc/passwd: uid -> login name (temporary allocator; the first line of a uid wins).
parse_passwd :: proc(text: string) -> map[u32]string {
	out := make(map[u32]string, 64, context.temp_allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		f := strings.split_n(line, ":", 4, context.temp_allocator)
		if len(f) < 3 || f[0] == "" { continue }
		uid, ok := strconv.parse_uint(f[2], 10)
		if !ok || u32(uid) in out { continue }
		out[u32(uid)] = f[0]
	}
	return out
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
