package inspecteur

// The processes on Linux, from /proc and nothing else, read with system calls (openat, pread, read, getdents) into
// reusable buffers. A reading takes, for each user process, its stat (parent, CPU time, threads, state, nice, start
// time), its statm (resident and shared pages: the private memory is their difference) and its io (bytes read from and
// written to the storage), when the user can read it. What does not change in a process's life (proc_facts: its command
// line, its executable, its owner, its systemd unit) is read once through a pinned /proc/<pid> descriptor, when the
// sampler first sees the process.
//
// Kernel threads (PF_KTHREAD) are not programs: they are left out. Their flag alone says it: in a pid namespace (a
// container) pid 2 and its children are programs, and the kernel's threads are not listed at all. On real /proc, known
// kernel threads are watched through pidfd_open + epoll so live kernel threads cost zero syscalls per sample. Live
// user processes keep their stat, statm and io descriptors open (pread at offset 0) up to a budget derived from
// RLIMIT_NOFILE, falling back to openat + read + close beyond the budget.

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

// Headroom left in RLIMIT_NOFILE for the window, renderer, D-Bus, Properties and other readers, and the upper cap on
// kept descriptors even when RLIMIT_NOFILE is very large: each one keeps a page of the kernel's memory (its seq_file's
// buffer), which no figure of this process shows. 16 MB at most.
PROC_FD_RESERVE    :: 512
PROC_FD_BUDGET_MAX :: 4096
// A single-record procfs file smaller than one 4 KB page finishes in one read; files at or above this threshold loop
// until EOF so multi-page seq_files or long command lines are never cut.
PROC_ONE_READ_CAP  :: 3584

// Syscall counts for the last procs_read (diagnostics and regression tests).
Proc_Read_Stats :: struct {
	opens:       int,
	reads:       int,
	preads:      int,
	closes:      int,
	getdents:    int,
	epoll_waits: int,
	pidfds:      int,
	fstats:      int,
}

Proc_Reader :: struct {
	proc_dir:   linux.Fd,
	real_proc:  bool,                 // true when reading "/proc" (enables pidfd kthread watch)
	buf:        []u8,                 // PROC_READ_MAX bytes: what each read fills
	dents:      []u8,                 // 64 KB getdents buffer, reused across samples
	users:      map[u32]string,       // uid -> login name (/etc/passwd), or the uid's number when it has none; owned
	io_denied:  map[i32]Io_Denied,    // the processes whose io is not ours to read: never asked again
	kept:       map[i32]Kept_Proc,    // open stat/statm/io descriptors for live user processes
	kthreads:   map[i32]Kept_Kthread, // pidfds of live kernel threads watched by kthread_ep
	kthread_ep: linux.Fd,             // epoll fd watching kthreads (-1 when unused)
	kept_fds:   int,                  // open descriptors held in kept and kthreads
	fd_budget:  int,                  // upper bound on kept_fds (from RLIMIT_NOFILE)
	pids:       [dynamic]Pid_Entry,   // reused across samples
	gone:       [dynamic]i32,         // reused eviction list
	comm_buf:   [dynamic]u8,          // reused flat buffer for comm bytes during one sample
	comm_offs:  [dynamic]Comm_Span,   // offsets into comm_buf for each appended Proc_Counters
	readings:   int,
	boot_time:  i64,                  // unix seconds (btime of /proc/stat): a process's start is its ticks after it
	page_bytes: u64,                  // the system's memory page (page_size)
	stats:      Proc_Read_Stats,      // syscall counts of the last procs_read
}

@(private = "file")
Io_Denied :: struct { start: u64, reading: int }

@(private = "file")
Pid_Entry :: struct { pid: i32, ino: u64 }

@(private = "file")
Comm_Span :: struct { off, len: int }

@(private = "file")
Kept_Proc :: struct {
	stat_fd:  linux.Fd,
	statm_fd: linux.Fd,
	io_fd:    linux.Fd,
	start:    u64,
	dir_ino:  u64,
	seen:     int,
}

@(private = "file")
Kept_Kthread :: struct {
	pidfd: linux.Fd,
	seen:  int,
}

proc_reader_init :: proc(r: ^Proc_Reader) -> bool {
	return proc_reader_init_root(r, "/proc")
}

// Opens `root` as the /proc tree (`fd_budget` < 0 derives a budget from RLIMIT_NOFILE). Tests use a synthetic folder.
proc_reader_init_root :: proc(r: ^Proc_Reader, root: string, fd_budget := -1) -> bool {
	croot := strings.clone_to_cstring(root, context.temp_allocator)
	fd, err := linux.open(croot, {.DIRECTORY, .CLOEXEC})
	if err != .NONE { return false }
	r.proc_dir = fd
	r.real_proc = root == "/proc"
	r.kthread_ep = -1
	r.buf = make([]u8, PROC_READ_MAX)
	r.dents = make([]u8, 64 * 1024)
	r.page_bytes = page_size(r.buf)
	if fd_budget >= 0 {
		r.fd_budget = fd_budget
	} else {
		rl: linux.RLimit
		if linux.getrlimit(.NOFILE, &rl) == .NONE && rl.cur > PROC_FD_RESERVE {
			r.fd_budget = int(min(rl.cur - PROC_FD_RESERVE, PROC_FD_BUDGET_MAX))
		}
	}
	if r.real_proc && r.fd_budget > 0 {
		if ep, eperr := linux.epoll_create1({.FDCLOEXEC}); eperr == .NONE { r.kthread_ep = ep }
	}
	users_read(r)
	if text, _, ok := read_file(r.buf, r.proc_dir, "stat"); ok { r.boot_time = parse_cpu_times(string(text)).boot_time }
	return true
}

proc_reader_destroy :: proc(r: ^Proc_Reader) {
	for _, kp in r.kept {
		if kp.stat_fd >= 0 { linux.close(kp.stat_fd) }
		if kp.statm_fd >= 0 { linux.close(kp.statm_fd) }
		if kp.io_fd >= 0 { linux.close(kp.io_fd) }
	}
	delete(r.kept)
	for _, kt in r.kthreads {
		if kt.pidfd >= 0 { linux.close(kt.pidfd) }
	}
	delete(r.kthreads)
	if r.kthread_ep >= 0 { linux.close(r.kthread_ep) }
	for _, name in r.users { delete(name) }
	delete(r.users)
	delete(r.io_denied)
	delete(r.pids)
	delete(r.gone)
	delete(r.comm_buf)
	delete(r.comm_offs)
	delete(r.dents)
	delete(r.buf)
	if r.proc_dir >= 0 { linux.close(r.proc_dir) }
	r^ = {}
}

@(private = "file")
kept_close :: proc(r: ^Proc_Reader, kp: ^Kept_Proc) {
	if kp.stat_fd >= 0 { linux.close(kp.stat_fd); kp.stat_fd = -1; r.kept_fds -= 1; r.stats.closes += 1 }
	if kp.statm_fd >= 0 { linux.close(kp.statm_fd); kp.statm_fd = -1; r.kept_fds -= 1; r.stats.closes += 1 }
	if kp.io_fd >= 0 { linux.close(kp.io_fd); kp.io_fd = -1; r.kept_fds -= 1; r.stats.closes += 1 }
}

@(private = "file")
kept_drop :: proc(r: ^Proc_Reader, pid: i32) {
	if kp, ok := &r.kept[pid]; ok {
		kept_close(r, kp)
		delete_key(&r.kept, pid)
	}
}

// Formats "<pid>/<file>" (or "<pid>" when `file` is empty) as a NUL-terminated C string into `dst`.
@(private = "file")
pid_path :: proc(dst: []u8, pid: i32, file: string) -> cstring {
	tmp: [16]u8
	v := u32(pid)
	d := len(tmp)
	if v == 0 {
		d -= 1
		tmp[d] = '0'
	} else {
		for v > 0 {
			d -= 1
			tmp[d] = u8('0' + v % 10)
			v /= 10
		}
	}
	n := copy(dst, tmp[d:])
	if len(file) > 0 {
		dst[n] = '/'
		n += 1
		n += copy(dst[n:], file)
	}
	dst[n] = 0
	return cstring(&dst[0])
}

// Reads a small procfs file in one syscall when it fits below one kernel page; loops until EOF otherwise.
@(private = "file")
read_fd_once :: proc(fd: linux.Fd, buf: []u8, stats: ^Proc_Read_Stats) -> (n: int, err: linux.Errno) {
	k, re := linux.read(fd, buf)
	stats.reads += 1
	if re != .NONE || k <= 0 { return 0, re }
	n = k
	if n < PROC_ONE_READ_CAP { return n, .NONE }
	for n < len(buf) {
		m, e := linux.read(fd, buf[n:])
		stats.reads += 1
		if e != .NONE { return 0, e }
		if m <= 0 { break }
		n += m
	}
	return n, .NONE
}

// Reads a kept procfs file from offset 0 in one pread syscall when it fits below one kernel page.
@(private = "file")
pread_fd_once :: proc(fd: linux.Fd, buf: []u8, stats: ^Proc_Read_Stats) -> (n: int, err: linux.Errno) {
	k, re := linux.pread(fd, buf, 0)
	stats.preads += 1
	if re != .NONE || k <= 0 { return 0, re }
	n = k
	if n < PROC_ONE_READ_CAP { return n, .NONE }
	for n < len(buf) {
		m, e := linux.pread(fd, buf[n:], i64(n))
		stats.preads += 1
		if e != .NONE { return 0, e }
		if m <= 0 { break }
		n += m
	}
	return n, .NONE
}

// Lists every numeric directory entry under `dir_fd` into `out` (reusing the open directory descriptor).
@(private = "file")
list_pids_at :: proc(dir_fd: linux.Fd, dents: []u8, out: ^[dynamic]Pid_Entry, stats: ^Proc_Read_Stats) {
	clear(out)
	if _, err := linux.lseek(dir_fd, 0, .SET); err != .NONE { return }
	for {
		n, e := linux.getdents(dir_fd, dents)
		stats.getdents += 1
		if e != .NONE || n <= 0 { break }
		offs := 0
		for d in linux.dirent_iterate_buf(dents[:n], &offs) {
			name := linux.dirent_name(d)
			if len(name) == 0 || name[0] < '0' || name[0] > '9' { continue }
			pid: i32
			valid := true
			for b in transmute([]u8)name {
				if b < '0' || b > '9' { valid = false; break }
				pid = pid * 10 + i32(b - '0')
			}
			if valid && pid > 0 { append(out, Pid_Entry{pid = pid, ino = u64(d.ino)}) }
		}
	}
}

// Evicts any kernel threads whose pidfd signalled exit since the last sample.
@(private = "file")
drain_exited_kthreads :: proc(r: ^Proc_Reader) {
	if !r.real_proc || r.kthread_ep < 0 || len(r.kthreads) == 0 { return }
	evs: [64]linux.EPoll_Event
	for {
		n, err := linux.epoll_wait(r.kthread_ep, raw_data(evs[:]), i32(len(evs)), 0)
		r.stats.epoll_waits += 1
		if err != .NONE || n <= 0 { break }
		for ev in evs[:n] {
			pid := i32(ev.data.u64)
			if kt, ok := r.kthreads[pid]; ok {
				linux.close(kt.pidfd)
				r.kept_fds -= 1
				r.stats.closes += 1
				delete_key(&r.kthreads, pid)
			}
		}
		if int(n) < len(evs) { break }
	}
}

// Every process now, sorted by pid (its `comm` in the temporary allocator).
// "" when the last reading of the processes was read; else why not (Windows: a query can fail and be said).
procs_read_problem :: proc(r: ^Proc_Reader) -> string { return "" }

procs_read :: proc(r: ^Proc_Reader, out: ^[dynamic]Proc_Counters) {
	r.readings += 1
	r.stats = {}
	list_pids_at(r.proc_dir, r.dents, &r.pids, &r.stats)
	slice.sort_by(r.pids[:], proc(a, b: Pid_Entry) -> bool { return a.pid < b.pid })
	drain_exited_kthreads(r)
	// (the descriptors of the processes gone go first: else, near the budget, the new processes of this sample would find
	// it held by the dead ones and wait a sample for theirs)
	for e in r.pids { if kp, ok := &r.kept[e.pid]; ok { kp.seen = r.readings } }
	clear(&r.gone)
	for pid, kp in r.kept { if kp.seen != r.readings { append(&r.gone, pid) } }
	for pid in r.gone { kept_drop(r, pid) }

	base_out := len(out^)
	clear(&r.comm_buf)
	clear(&r.comm_offs)
	if cap(r.comm_buf) < len(r.pids) * 20 { reserve(&r.comm_buf, len(r.pids) * 20) }
	if cap(r.comm_offs) < len(r.pids) { reserve(&r.comm_offs, len(r.pids)) }
	pb: [32]u8

	for entry in r.pids {
		pid := entry.pid
		if r.real_proc {
			if kt, is_kt := &r.kthreads[pid]; is_kt {
				kt.seen = r.readings
				continue
			}
		}

		kp, has_kp := &r.kept[pid]
		// On synthetic regular files (tests), unlink+recreate of a pid folder or stat file leaves a kept fd pointing to
		// the old unlinked inode; check directory inode and link count so pid reuse is detected immediately.
		if has_kp && !r.real_proc {
			stale := kp.dir_ino != entry.ino
			if !stale && kp.stat_fd >= 0 {
				st_info: linux.Stat
				r.stats.fstats += 1
				if linux.fstat(kp.stat_fd, &st_info) != .NONE || st_info.nlink == 0 { stale = true }
			}
			if stale {
				kept_drop(r, pid)
				has_kp, kp = false, nil
			}
		}

		stat_text: []u8
		stat_ok := false
		opened_stat_fd: linux.Fd = -1
		if has_kp && kp.stat_fd >= 0 {
			n, perr := pread_fd_once(kp.stat_fd, r.buf, &r.stats)
			if perr == .NONE && n > 0 {
				stat_text, stat_ok = r.buf[:n], true
			} else {
				// Process exited or pid was reused: drop old kept fds and reopen below.
				kept_drop(r, pid)
				has_kp, kp = false, nil
			}
		}
		if !stat_ok {
			fd, oerr := linux.openat(r.proc_dir, pid_path(pb[:], pid, "stat"), {.CLOEXEC})
			r.stats.opens += 1
			if oerr != .NONE { continue }   // (it ended in between)
			n, rerr := read_fd_once(fd, r.buf, &r.stats)
			if rerr != .NONE || n <= 0 {
				linux.close(fd)
				r.stats.closes += 1
				continue
			}
			stat_text, stat_ok, opened_stat_fd = r.buf[:n], true, fd
		}

		st, parsed := parse_stat(string(stat_text))
		if !parsed || st.flags & PF_KTHREAD != 0 {
			// Watch newly discovered kernel threads via pidfd + epoll so future samples cost zero syscalls.
			if parsed && r.real_proc && r.kthread_ep >= 0 && r.kept_fds < r.fd_budget && opened_stat_fd >= 0 {
				if pfd, perr := linux.pidfd_open(linux.Pid(pid), {}); perr == .NONE {
					r.stats.pidfds += 1
					// Re-verify stat on the pinned stat fd so pidfd is guaranteed to bind the same (pid, start).
					vn, verr := pread_fd_once(opened_stat_fd, r.buf, &r.stats)
					vst, vparsed := parse_stat(string(r.buf[:vn]))
					ev := linux.EPoll_Event{events = {.IN}, data = {u64 = u64(pid)}}
					if verr == .NONE && vparsed && vst.start == st.start && linux.epoll_ctl(r.kthread_ep, .ADD, linux.Fd(pfd), &ev) == .NONE {
						r.kthreads[pid] = {pidfd = linux.Fd(pfd), seen = r.readings}
						r.kept_fds += 1
					} else {
						linux.close(linux.Fd(pfd))
						r.stats.closes += 1
					}
				}
			}
			if opened_stat_fd >= 0 { linux.close(opened_stat_fd); r.stats.closes += 1 }
			if has_kp { kept_drop(r, pid) }
			continue
		}

		// In-place pid reuse (same kept stat_fd on a synthetic file overwritten with a new start time).
		if has_kp && kp.start != st.start {
			if kp.statm_fd >= 0 { linux.close(kp.statm_fd); kp.statm_fd = -1; r.kept_fds -= 1; r.stats.closes += 1 }
			if kp.io_fd >= 0 { linux.close(kp.io_fd); kp.io_fd = -1; r.kept_fds -= 1; r.stats.closes += 1 }
			kp.start, kp.dir_ino = st.start, entry.ino
		}
		if opened_stat_fd >= 0 {
			if r.kept_fds < r.fd_budget {
				r.kept[pid] = Kept_Proc{stat_fd = opened_stat_fd, statm_fd = -1, io_fd = -1, start = st.start, dir_ino = entry.ino, seen = r.readings}
				r.kept_fds += 1
				kp = &r.kept[pid]
				has_kp = true
			} else {
				linux.close(opened_stat_fd)
				r.stats.closes += 1
			}
		} else if has_kp {
			kp.seen = r.readings
		}

		comm_off := len(r.comm_buf)
		append(&r.comm_buf, ..transmute([]u8)st.comm)
		append(&r.comm_offs, Comm_Span{off = comm_off, len = len(st.comm)})

		c := Proc_Counters{
			pid = pid, ppid = st.ppid, start = st.start,
			cpu_ns = st.ticks * TICK_NS, threads = st.threads, state = proc_state_of(st.state), nice = st.nice,
			resident = st.rss_pages * r.page_bytes,
		}

		// statm
		statm_done := false
		if has_kp && kp.statm_fd >= 0 {
			if n, perr := pread_fd_once(kp.statm_fd, r.buf, &r.stats); perr == .NONE && n > 0 {
				if m, pok := parse_statm(string(r.buf[:n])); pok {
					c.resident = m.resident * r.page_bytes
					c.private = (m.resident - min(m.shared, m.resident)) * r.page_bytes
				}
				statm_done = true
			} else {
				linux.close(kp.statm_fd); kp.statm_fd = -1; r.kept_fds -= 1; r.stats.closes += 1
			}
		}
		if !statm_done {
			if mfd, merr := linux.openat(r.proc_dir, pid_path(pb[:], pid, "statm"), {.CLOEXEC}); merr == .NONE {
				r.stats.opens += 1
				if n, rerr := read_fd_once(mfd, r.buf, &r.stats); rerr == .NONE && n > 0 {
					if m, pok := parse_statm(string(r.buf[:n])); pok {
						c.resident = m.resident * r.page_bytes
						c.private = (m.resident - min(m.shared, m.resident)) * r.page_bytes
					}
					if has_kp && r.kept_fds < r.fd_budget {
						kp.statm_fd = mfd
						r.kept_fds += 1
					} else {
						linux.close(mfd)
						r.stats.closes += 1
					}
				} else {
					linux.close(mfd)
					r.stats.closes += 1
				}
			} else {
				r.stats.opens += 1
			}
		}

		// io
		if d, denied := r.io_denied[pid]; denied && d.start == st.start {
			r.io_denied[pid] = {st.start, r.readings}
		} else {
			io_done := false
			if has_kp && kp.io_fd >= 0 {
				if n, perr := pread_fd_once(kp.io_fd, r.buf, &r.stats); perr == .NONE && n > 0 {
					io := parse_io(string(r.buf[:n]))
					c.io_read, c.io_write, c.io_known = io.read, io.write, true
					io_done = true
				} else {
					linux.close(kp.io_fd); kp.io_fd = -1; r.kept_fds -= 1; r.stats.closes += 1
					if perr == .EACCES || perr == .EPERM {
						r.io_denied[pid] = {st.start, r.readings}
						io_done = true
					}
				}
			}
			if !io_done {
				ifd, ierr := linux.openat(r.proc_dir, pid_path(pb[:], pid, "io"), {.CLOEXEC})
				r.stats.opens += 1
				if ierr == .NONE {
					if n, rerr := read_fd_once(ifd, r.buf, &r.stats); rerr == .NONE {
						io := parse_io(string(r.buf[:n]))
						c.io_read, c.io_write, c.io_known = io.read, io.write, true
						if has_kp && r.kept_fds < r.fd_budget {
							kp.io_fd = ifd
							r.kept_fds += 1
						} else {
							linux.close(ifd)
							r.stats.closes += 1
						}
					} else {
						linux.close(ifd)
						r.stats.closes += 1
						if rerr == .EACCES || rerr == .EPERM { r.io_denied[pid] = {st.start, r.readings} }
					}
				} else if ierr == .EACCES || ierr == .EPERM {
					r.io_denied[pid] = {st.start, r.readings}
				}
			}
		}

		append(out, c)
	}

	// Copy all comm strings into one temp allocation so callers keep valid slices across readings.
	if len(r.comm_buf) > 0 {
		comms := make([]u8, len(r.comm_buf), context.temp_allocator)
		copy(comms, r.comm_buf[:])
		for span, i in r.comm_offs {
			out[base_out + i].comm = string(comms[span.off:span.off + span.len])
		}
	}

	// Evict kernel threads that vanished since the last sample so kept fds stay bounded.
	clear(&r.gone)
	for pid, kt in r.kthreads { if kt.seen != r.readings { append(&r.gone, pid) } }
	for pid in r.gone {
		if kt, ok := r.kthreads[pid]; ok {
			linux.close(kt.pidfd)
			r.kept_fds -= 1
			r.stats.closes += 1
			delete_key(&r.kthreads, pid)
		}
	}

	clear(&r.gone)
	for pid, d in r.io_denied { if d.reading != r.readings { append(&r.gone, pid) } }
	for pid in r.gone { delete_key(&r.io_denied, pid) }
}

// What does not change in the life of the process `c`: its command line, its executable, its owner, its unit, when
// it started (texts in the temporary allocator; the user's name is the reader's).
proc_facts :: proc(r: ^Proc_Reader, c: Proc_Counters) -> (f: Proc_Facts) {
	pb: [32]u8
	argv0 := ""
	// Pin /proc/<pid> once so cmdline, exe, owner (fstat) and cgroup read the same process without repeated path walks.
	if pdir, derr := linux.openat(r.proc_dir, pid_path(pb[:], c.pid, ""), {.DIRECTORY, .CLOEXEC}); derr == .NONE {
		defer linux.close(pdir)
		dummy: Proc_Read_Stats
		if fd, err := linux.openat(pdir, "cmdline", {.CLOEXEC}); err == .NONE {
			n, rerr := read_fd_once(fd, r.buf, &dummy)
			linux.close(fd)
			if rerr == .NONE {
				raw := string(r.buf[:min(n, CMDLINE_MAX)])
				raw = strings.trim_right(raw, "\x00")
				if i := strings.index_byte(raw, 0); i >= 0 { argv0 = raw[:i] } else { argv0 = raw }
				argv0 = strings.clone(argv0, context.temp_allocator)   // (the buffer is filled again below)
				f.cmdline, _ = strings.replace_all(raw, "\x00", " ", context.temp_allocator)
				if f.cmdline == raw { f.cmdline = strings.clone(raw, context.temp_allocator) }
			}
		}
		link: [4096]u8   // (PATH_MAX)
		if n, err := linux.readlinkat(pdir, "exe", link[:]); err == .NONE && n > 0 {
			f.exe = strings.clone(strings.trim_suffix(string(link[:n]), " (deleted)"), context.temp_allocator)
		}
		stat: linux.Stat
		if linux.fstat(pdir, &stat) == .NONE {
			f.user = user_name_of(r, u32(stat.uid))
		}
		if fd, err := linux.openat(pdir, "cgroup", {.CLOEXEC}); err == .NONE {
			n, rerr := read_fd_once(fd, r.buf, &dummy)
			linux.close(fd)
			if rerr == .NONE {
				text := string(r.buf[:n])
				f.scope = strings.clone(cgroup_scope(text), context.temp_allocator)
				// (a unit of the user's manager is under its user@<uid>.service)
				f.user_unit = strings.contains(text, "/user@")
			}
		}
	}
	f.name = display_name(c.comm, argv0, f.exe)
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

// The state of the process (pid, start) now (Unknown when it is gone, or its pid is another process's).
proc_state_now :: proc(pid: i32, start: u64) -> Proc_State {
	buf: [1024]u8
	pb: [32]u8
	prefix := copy(pb[:], "/proc/")
	_ = pid_path(pb[prefix:], pid, "stat")
	fd, err := linux.open(cstring(&pb[0]), {.CLOEXEC})
	if err != .NONE { return .Unknown }
	defer linux.close(fd)
	dummy: Proc_Read_Stats
	n, rerr := read_fd_once(fd, buf[:], &dummy)
	if rerr != .NONE || n <= 0 { return .Unknown }
	st, parsed := parse_stat(string(buf[:n]))
	if !parsed || st.start != start { return .Unknown }
	return proc_state_of(st.state)
}

// The pids under /proc.
list_pids :: proc(out: ^[dynamic]i32) {
	fd, err := linux.open("/proc", {.DIRECTORY, .CLOEXEC})
	if err != .NONE { return }
	defer linux.close(fd)
	buf: [64 * 1024]u8
	for {
		n, e := linux.getdents(fd, buf[:])
		if e != .NONE || n <= 0 { break }
		offs := 0
		for d in linux.dirent_iterate_buf(buf[:n], &offs) {
			name := linux.dirent_name(d)
			if len(name) == 0 || name[0] < '0' || name[0] > '9' { continue }
			pid: i32
			valid := true
			for b in transmute([]u8)name {
				if b < '0' || b > '9' { valid = false; break }
				pid = pid * 10 + i32(b - '0')
			}
			if valid && pid > 0 { append(out, pid) }
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

@(private)
is_ascii_space :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

// Parses a non-empty ASCII unsigned decimal integer from `s`.
@(private)
parse_ascii_u64 :: proc(s: string) -> (v: u64, ok: bool) {
	if len(s) == 0 { return 0, false }
	for i in 0 ..< len(s) {
		c := s[i]
		if c < '0' || c > '9' { return 0, false }
		v = v * 10 + u64(c - '0')
	}
	return v, true
}

// Parses a non-empty ASCII signed decimal integer from `s`.
@(private)
parse_ascii_i64 :: proc(s: string) -> (v: i64, ok: bool) {
	if len(s) == 0 { return 0, false }
	i := 0
	neg := false
	if s[0] == '-' {
		neg = true
		i = 1
	} else if s[0] == '+' {
		i = 1
	}
	if i >= len(s) { return 0, false }
	acc: u64
	for ; i < len(s); i += 1 {
		c := s[i]
		if c < '0' || c > '9' { return 0, false }
		acc = acc * 10 + u64(c - '0')
	}
	return neg ? -i64(acc) : i64(acc), true
}

// Returns the next ASCII whitespace-delimited token in `s` starting at `pos^`, advancing `pos^`.
@(private)
next_token :: proc(s: string, pos: ^int) -> (tok: string, ok: bool) {
	i := pos^
	n := len(s)
	for i < n && is_ascii_space(s[i]) { i += 1 }
	if i >= n { pos^ = i; return "", false }
	start := i
	for i < n && !is_ascii_space(s[i]) { i += 1 }
	pos^ = i
	return s[start:i], true
}

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

// /proc/<pid>/stat. The command name is between the first '(' and the last ')': it may hold spaces, parentheses and newlines.
parse_stat :: proc(text: string) -> (f: Stat_Fields, ok: bool) {
	open := strings.index_byte(text, '(')
	close := strings.last_index_byte(text, ')')
	if open < 0 || close < open { return }
	f.comm = text[open + 1:close]
	pos := close + 1
	field := 3   // (the state, after the name)
	for {
		word, has := next_token(text, &pos)
		if !has { break }
		switch field {
		case 3:  f.state = word[0]
		case 4:  v, _ := parse_ascii_i64(word); f.ppid = i32(v)
		case 9:  v, _ := parse_ascii_u64(word); f.flags = u32(v)
		case 14, 15: v, _ := parse_ascii_u64(word); f.ticks += v
		case 19: v, _ := parse_ascii_i64(word); f.nice = i8(v)
		case 20: v, _ := parse_ascii_i64(word); f.threads = i32(v)
		case 22: v, _ := parse_ascii_u64(word); f.start = v
		case 24:
			v, _ := parse_ascii_u64(word)
			f.rss_pages = v
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
	pos := 0
	w0, ok0 := next_token(text, &pos)
	w1, ok1 := next_token(text, &pos)
	w2, ok2 := next_token(text, &pos)
	if !ok0 || !ok1 || !ok2 { return }
	v0, p0 := parse_ascii_u64(w0)
	v1, p1 := parse_ascii_u64(w1)
	v2, p2 := parse_ascii_u64(w2)
	if !p0 || !p1 || !p2 { return }
	return {size = v0, resident = v1, shared = v2}, true
}

Io_Fields :: struct { read, write: u64 }

// /proc/<pid>/io: the bytes that went to the storage (read_bytes, write_bytes), not those of the page cache.
parse_io :: proc(text: string) -> (io: Io_Fields) {
	i := 0
	n := len(text)
	for i < n {
		start := i
		for i < n && text[i] != '\n' { i += 1 }
		line := text[start:i]
		if i < n { i += 1 }
		if len(line) > 11 && line[0] == 'r' && strings.has_prefix(line, "read_bytes:") {
			pos := 11
			if w, ok := next_token(line, &pos); ok { v, _ := parse_ascii_u64(w); io.read = v }
		} else if len(line) > 12 && line[0] == 'w' && strings.has_prefix(line, "write_bytes:") {
			pos := 12
			if w, ok := next_token(line, &pos); ok { v, _ := parse_ascii_u64(w); io.write = v }
		}
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
