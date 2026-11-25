#+build linux
package inspecteur

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import "core:thread"
import "gt:testkit/session"
import "gt:ui"

@(test)
stat_line_is_read :: proc(t: ^testing.T) {
	// a name with a space and parentheses: it ends at the last ')'
	line := "4242 (Web (Content) x) S 4100 4242 4100 0 -1 4194560 1 0 0 0 120 30 0 0 20 0 27 0 987654 1234567 5000 18446744073709551615 0 0 0 0 0 0 0 4096 0 0 0 0 17 3 0 0 0 0 0\n"
	f, ok := parse_stat(line)
	testing.expect(t, ok)
	testing.expect_value(t, f.comm, "Web (Content) x")
	testing.expect_value(t, f.ppid, i32(4100))
	testing.expect_value(t, f.ticks, u64(150))
	testing.expect_value(t, f.threads, i32(27))
	testing.expect_value(t, f.start, u64(987654))
	testing.expect_value(t, f.rss_pages, u64(5000))
	testing.expect(t, f.flags & PF_KTHREAD == 0)
	_, cut := parse_stat("12 (x) S 1 2 3")
	testing.expect(t, !cut, "a line cut short is refused")
}

@(test)
machine_times_are_read :: proc(t: ^testing.T) {
	text := "cpu  100 5 50 800 20 3 2 1 9 0\ncpu0 50 2 25 400 10 1 1 0 0 0\ncpu1 50 3 25 400 10 2 1 1 0 0\nintr 1 2 3\n"
	c := parse_cpu_times(text)
	testing.expect_value(t, c.total, u64(100 + 5 + 50 + 800 + 20 + 3 + 2 + 1))
	testing.expect_value(t, c.idle, u64(820))
	testing.expect_value(t, len(c.core_total), 2)
	testing.expect_value(t, c.core_idle[1], u64(410))
	testing.expect_value(t, parse_cpu_times("cpu  1 0 0 1 0 0 0 0\nbtime 1700000000\n").boot_time, i64(1700000000))
	m := parse_meminfo("MemTotal:       32000000 kB\nMemFree:  100 kB\nMemAvailable:   20000000 kB\n")
	testing.expect_value(t, m.total, u64(32000000) * 1024)
	testing.expect_value(t, m.available, u64(20000000) * 1024)
	io := parse_io("rchar: 10\nwchar: 20\nsyscr: 1\nsyscw: 2\nread_bytes: 4096\nwrite_bytes: 8192\ncancelled_write_bytes: 0\n")
	testing.expect_value(t, io.read, u64(4096))
	testing.expect_value(t, io.write, u64(8192))
}

@(test)
names_are_shown_whole_and_unwrapped :: proc(t: ^testing.T) {
	testing.expect_value(t, display_name(".firefox-wrappe", "/nix/store/abc-firefox/bin/.firefox-wrapped", ""), "firefox")
	testing.expect_value(t, display_name("gnome-terminal-", "/usr/bin/gnome-terminal-server", ""), "gnome-terminal-server")
	testing.expect_value(t, display_name("bash", "-bash", "/usr/bin/bash"), "bash")
	testing.expect_value(t, display_name("sleep", "sleep\x00300", ""), "sleep")
	testing.expect_value(t, display_name(".quickshell-wra", "qs", "/nix/store/x/bin/.quickshell-wrapped"), "quickshell")
	testing.expect_value(t, cgroup_scope("0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-firefox-1234.scope\n"), "app-firefox-1234.scope")
}

@(test)
processes_match_their_apps :: proc(t: ^testing.T) {
	c: Catalog
	defer catalog_destroy(&c)
	catalog_add(&c, "org.chromium.Chromium", "[Desktop Entry]\nType=Application\nName=Chromium\nExec=chromium %U\nIcon=chromium\n")
	catalog_add(&c, "com.mitchellh.ghostty", "[Desktop Entry]\nType=Application\nName=Ghostty\nExec=/nix/store/x-ghostty/bin/ghostty\nStartupWMClass=com.mitchellh.ghostty\n")
	catalog_add(&c, "htop", "[Desktop Entry]\nType=Application\nName=htop\nExec=htop\nTerminal=true\n")
	catalog_add(&c, "hidden", "[Desktop Entry]\nType=Application\nName=Hidden\nExec=hidden\nNoDisplay=true\n")
	testing.expect_value(t, len(c.entries), 2)
	testing.expect_value(t, catalog_match(&c, "chromium", "", ""), 0)
	testing.expect_value(t, catalog_match(&c, "ghostty", "", ""), 1)
	testing.expect_value(t, catalog_match(&c, "fish", "/usr/bin/fish", "app-ShojiWM-ghostty-d5e1a437.scope"), 1)
	testing.expect_value(t, catalog_match(&c, "x", "", "app-org.chromium.Chromium-56418.scope"), 0)
	testing.expect_value(t, catalog_match(&c, "htop", "/usr/bin/htop", "session-8.scope"), -1)
	testing.expect_value(t, catalog_match(&c, "hidden", "", ""), -1)
}

@(test)
statm_passwd_and_maps_are_read :: proc(t: ^testing.T) {
	m, ok := parse_statm("1000 300 120 10 0 200 0\n")
	testing.expect(t, ok && m.resident == 300 && m.shared == 120, "statm: resident and shared pages")
	_, short := parse_statm("1000 300")
	testing.expect(t, !short, "a statm cut short is refused")
	users := parse_passwd("root:x:0:0::/root:/bin/sh\nalex:x:1000:100::/home/alex:/bin/bash\nbroken\nalex2:x:1000:100::/:/bin/sh\n")
	testing.expect_value(t, users[0], "root")
	testing.expect_value(t, users[1000], "alex")   // (the first line of a uid)
	mods := parse_maps("00400000-00452000 r-xp 00000000 08:02 173521 /usr/bin/a b\n00651000-00652000 rw-p 00051000 08:02 173521 /usr/bin/a b\n7f00-8f00 r--p 0 0 0 [heap]\n1000-2000 r-xp 0 08:02 9 /lib/libc.so\n")
	testing.expect_value(t, len(mods), 2)
	testing.expect_value(t, mods[0].path, "/usr/bin/a b")   // (a path may hold spaces)
	testing.expect_value(t, mods[0].size, u64(0x52000 + 0x1000))
	testing.expect_value(t, proc_state_of('T'), Proc_State.Stopped)
	testing.expect_value(t, proc_state_of('?'), Proc_State.Unknown)
}

// The paths of mountinfo are escaped: a space, a tab, a newline and a backslash.
@(test)
a_mount_point_is_unescaped :: proc(t: ^testing.T) {
	m, ok := parse_mountinfo_line("36 35 98:0 / /mnt/my\\040disk\\011x\\134y rw,noatime master:1 - ext4 /dev/sdb1 rw,errors=continue")
	testing.expect(t, ok)
	testing.expect_value(t, m.mount, "/mnt/my disk\tx\\y")
	testing.expect_value(t, m.kind, "ext4")
	testing.expect_value(t, m.device, "/dev/sdb1")
	testing.expect_value(t, m.options, "rw,errors=continue")
	testing.expect_value(t, mount_unescape("/plain"), "/plain")
	testing.expect_value(t, mount_unescape("/end\\04"), "/end\\04")   // (a cut escape stays as it is)
	testing.expect(t, storage_kind("btrfs") && !storage_kind("tmpfs") && !storage_kind("proc"))
}

// Reference plain reader reproducing the original unoptimized /proc algorithm (open dir + openat/read-loop/close +
// strconv) against an arbitrary root folder, used to verify exact equivalence of the optimized reader.
@(private)
plain_procs_read :: proc(root: string, page_bytes: u64, out: ^[dynamic]Proc_Counters) -> (syscalls: int) {
	croot := strings.clone_to_cstring(root, context.temp_allocator)
	dir_fd, err := linux.open(croot, {.DIRECTORY, .CLOEXEC})
	syscalls += 1
	if err != .NONE { return }
	defer { linux.close(dir_fd); syscalls += 1 }

	pids := make([dynamic]i32, 0, 512, context.temp_allocator)
	dbuf: [16 * 1024]u8
	for {
		n, e := linux.getdents(dir_fd, dbuf[:])
		syscalls += 1
		if e != .NONE || n <= 0 { break }
		offs := 0
		for d in linux.dirent_iterate_buf(dbuf[:n], &offs) {
			name := linux.dirent_name(d)
			if len(name) == 0 || name[0] < '0' || name[0] > '9' { continue }
			if pid, ok := strconv.parse_int(name, 10); ok { append(&pids, i32(pid)) }
		}
	}
	slice.sort(pids[:])

	read_plain :: proc(buf: []u8, dir: linux.Fd, path: string, syscalls: ^int) -> (data: []u8, ok: bool) {
		cpath := strings.clone_to_cstring(path, context.temp_allocator)
		fd, e := linux.openat(dir, cpath, {.CLOEXEC})
		syscalls^ += 1
		if e != .NONE { return nil, false }
		defer { linux.close(fd); syscalls^ += 1 }
		n := 0
		for n < len(buf) {
			k, re := linux.read(fd, buf[n:])
			syscalls^ += 1
			if re != .NONE { return nil, false }
			if k <= 0 { break }
			n += k
		}
		return buf[:n], true
	}

	buf := make([]u8, PROC_READ_MAX, context.temp_allocator)
	for pid in pids {
		text, ok := read_plain(buf, dir_fd, fmt.tprintf("%d/stat", pid), &syscalls)
		if !ok { continue }
		open := strings.index_byte(string(text), '(')
		close := strings.last_index_byte(string(text), ')')
		if open < 0 || close < open { continue }
		comm := string(text)[open + 1:close]
		rest := string(text)[close + 1:]
		field := 3
		st_state: u8
		st_ppid, st_threads: i32
		st_flags: u32
		st_ticks, st_start, st_rss: u64
		st_nice: i8
		parsed := false
		for word in strings.fields_iterator(&rest) {
			switch field {
			case 3:  st_state = word[0]
			case 4:  st_ppid = i32(strconv.parse_int(word, 10) or_else 0)
			case 9:  st_flags = u32(strconv.parse_uint(word, 10) or_else 0)
			case 14, 15: st_ticks += u64(strconv.parse_uint(word, 10) or_else 0)
			case 19: st_nice = i8(strconv.parse_int(word, 10) or_else 0)
			case 20: st_threads = i32(strconv.parse_int(word, 10) or_else 0)
			case 22: st_start = u64(strconv.parse_uint(word, 10) or_else 0)
			case 24: st_rss = u64(strconv.parse_uint(word, 10) or_else 0); parsed = true
			}
			if parsed { break }
			field += 1
		}
		if !parsed || st_flags & PF_KTHREAD != 0 || pid == 2 || st_ppid == 2 { continue }
		c := Proc_Counters{
			pid = pid, ppid = st_ppid, start = st_start, comm = strings.clone(comm, context.temp_allocator),
			cpu_ns = st_ticks * TICK_NS, threads = st_threads, state = proc_state_of(st_state), nice = st_nice,
			resident = st_rss * page_bytes,
		}
		if mtext, mok := read_plain(buf, dir_fd, fmt.tprintf("%d/statm", pid), &syscalls); mok {
			mrest := string(mtext)
			vals: [3]u64
			mi := 0
			mvalid := true
			for word in strings.fields_iterator(&mrest) {
				if mi >= 3 { break }
				v, vok := strconv.parse_u64(word, 10)
				if !vok { mvalid = false; break }
				vals[mi] = v
				mi += 1
			}
			if mvalid && mi == 3 {
				c.resident = vals[1] * page_bytes
				c.private = (vals[1] - min(vals[2], vals[1])) * page_bytes
			}
		}
		if iodata, iok := read_plain(buf, dir_fd, fmt.tprintf("%d/io", pid), &syscalls); iok {
			irest := string(iodata)
			for line in strings.split_lines_iterator(&irest) {
				if strings.has_prefix(line, "read_bytes:") { c.io_read = u64(strconv.parse_uint(strings.trim_space(line[11:]), 10) or_else 0) }
				if strings.has_prefix(line, "write_bytes:") { c.io_write = u64(strconv.parse_uint(strings.trim_space(line[12:]), 10) or_else 0) }
			}
			c.io_known = true
		}
		append(out, c)
	}
	return
}

// Where the tests' synthetic /proc goes ($TMPDIR).
@(private)
synth_dir :: proc() -> string {
	dir := os.get_env("TMPDIR", context.temp_allocator)
	return dir != "" ? dir : "/tmp"
}

@(private)
synth_write_proc :: proc(root: string, pid, ppid: i32, comm: string, state: u8, flags: u32, utime, stime: u64, nice: i8, threads: i32, start, rss, shared, rbytes, wbytes: u64, write_statm := true, write_io := true, chmod_io_0 := false, cmdline := "", cgroup := "") {
	dir := fmt.tprintf("%s/%d", root, pid)
	_ = os.make_directory_all(dir)
	stat_line := fmt.tprintf("%d (%s) %c %d %d %d 0 -1 %d 0 0 0 0 %d %d 0 0 20 %d %d 0 %d 100000 %d 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n",
		pid, comm, state, ppid, pid, ppid, flags, utime, stime, nice, threads, start, rss)
	_ = os.write_entire_file(fmt.tprintf("%s/stat", dir), stat_line)
	if write_statm {
		_ = os.write_entire_file(fmt.tprintf("%s/statm", dir), fmt.tprintf("%d %d %d 0 0 0 0\n", rss + 100, rss, shared))
	}
	if write_io {
		io_path := fmt.tprintf("%s/io", dir)
		_ = os.chmod(io_path, {.Read_User, .Write_User})
		_ = os.write_entire_file(io_path, fmt.tprintf("rchar: 10\nwchar: 20\nsyscr: 1\nsyscw: 2\nread_bytes: %d\nwrite_bytes: %d\ncancelled_write_bytes: 0\n", rbytes, wbytes))
		if chmod_io_0 { _ = os.chmod(io_path, {}) }
	}
	if cmdline != "" { _ = os.write_entire_file(fmt.tprintf("%s/cmdline", dir), cmdline) }
	if cgroup != "" { _ = os.write_entire_file(fmt.tprintf("%s/cgroup", dir), cgroup) }
}

@(private)
expect_counters_equal :: proc(t: ^testing.T, got, want: []Proc_Counters, label: string) {
	testing.expectf(t, len(got) == len(want), "%s: len got=%d want=%d", label, len(got), len(want))
	if len(got) != len(want) { return }
	for g, i in got {
		w := want[i]
		testing.expectf(t, g == w, "%s [%d]: got=%v want=%v", label, i, g, w)
	}
}

// Every reading has every number of the machine, whatever section is shown (the window can be paused on this one and
// show another section next), and the time of change of the user's themes file.
@(test)
a_reading_is_whole_and_tells_the_themes_file :: proc(t: ^testing.T) {
	path := fmt.aprintf("%s/inspecteur-themes-%d.txt", synth_dir(), os.get_pid())
	defer delete(path)
	_ = os.remove(path)
	s: Sampling
	defer sampling_destroy(&s)
	s.opened, s.catalog_read, s.session_read = true, true, true
	s.readings = 1   // (no list of the devices)
	s.ok = proc_reader_init(&s.procs)
	machine_reader_init(&s.machine)
	s.themes = path
	first, second: Reading
	defer virtual.arena_destroy(&first.arena)
	defer virtual.arena_destroy(&second.arena)
	// (on a thread of its own, as the chores': it touches the disk)
	read :: proc(s: ^Sampling, r: ^Reading, now_ns: i64) {
		job := struct { s: ^Sampling, r: ^Reading, now_ns: i64 }{s, r, now_ns}
		th := thread.create_and_start_with_poly_data(&job, proc(j: ^struct { s: ^Sampling, r: ^Reading, now_ns: i64 }) { reading_make(j.s, j.r, {}, j.now_ns) }, context)
		thread.join(th)
		thread.destroy(th)
	}
	read(&s, &first, 1)
	testing.expect_value(t, first.themes_stamp, 0)
	_ = os.write_entire_file(path, "[Mine]\n")
	defer _ = os.remove(path)
	read(&s, &second, 2)
	testing.expect(t, second.themes_stamp != 0, "the themes file is seen")
	for r in ([]^Reading{&first, &second}) {
		testing.expect(t, r.machine.uptime > 0 && r.machine.handles > 0 && r.machine.mem.total > 0)
	}
	testing.expect_value(t, second.machine.temp_count, first.machine.temp_count)
	testing.expect(t, len(second.procs) > 0)
}

// The Properties show what their process uses of the GPUs: the GPUs' thread is asked for it with no GPU column shown.
@(test)
the_properties_ask_for_the_processes_of_the_gpus :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	defer table_destroy(&app.table)
	table_columns_init(&app.table)
	gpus_want(app)
	testing.expect(t, !app.machine.gpu.want_procs)
	s := session.start(t, {size = {400, 300}, user = app, no_renderer = true, build = proc(s: ^session.Session) {}})
	defer ui.views_destroy(&app.views)
	ui.views_init(&app.views, {})
	ui.set_views(s.state, &app.views)
	ui.view_register(&app.views, PROPS_VIEW, proc(v: ^ui.View, app: ^App) {}, ui.View_Options{title = "Properties"})
	ui.view_open(&app.views, PROPS_VIEW, app, owner = s.state)
	gpus_want(app)
	testing.expect(t, app.machine.gpu.want_procs)
	testing.expect(t, !app.machine.gpu.wanted, "a GPU that sleeps is not woken for them")
}

// On the real /proc: what moves in a process whose descriptors are kept is read anew (its name, with the bytes stat does
// not escape), a process that ended goes with its descriptors, and no child inherits one of them.
@(test)
the_real_proc_is_read_through_kept_descriptors :: proc(t: ^testing.T) {
	r: Proc_Reader
	if !testing.expect(t, proc_reader_init(&r)) { return }
	defer proc_reader_destroy(&r)
	out := make([dynamic]Proc_Counters, context.temp_allocator)
	find :: proc(r: ^Proc_Reader, out: ^[dynamic]Proc_Counters, pid: int) -> (c: Proc_Counters, ok: bool) {
		clear(out)
		procs_read(r, out)
		for x in out { if int(x.pid) == pid { return x, true } }
		return
	}

	child, err := os.process_start({command = {"sleep", "60"}})
	if !testing.expect(t, err == nil, "sleep starts") { return }
	killed := false
	defer if !killed { _ = os.process_kill(child); _, _ = os.process_wait(child) }
	first, seen := find(&r, &out, child.pid)
	testing.expect(t, seen && first.start > 0 && int(first.ppid) == os.get_pid(), "the child is read")

	before := os.read_entire_file("/proc/self/comm", context.temp_allocator) or_else nil
	defer _ = os.write_entire_file("/proc/self/comm", strings.trim_right(string(before), "\n"))
	own, _ := find(&r, &out, os.get_pid())
	NAME :: "a) R 1 (b\n c"
	_ = os.write_entire_file("/proc/self/comm", NAME)
	again, _ := find(&r, &out, os.get_pid())
	testing.expect_value(t, again.comm, NAME)
	testing.expect(t, again.start == own.start && again.ppid == own.ppid && again.threads > 0, "the fields after the name")
	testing.expect(t, again.cpu_ns >= own.cpu_ns && again.resident > 0 && again.io_known, "its numbers")

	// (every descriptor of the reader closes at an exec)
	if r.fd_budget > 0 {
		kp, kept := r.kept[i32(child.pid)]
		testing.expect(t, kept && kp.stat_fd >= 0)
		fds := make([dynamic]linux.Fd, context.temp_allocator)
		append(&fds, r.proc_dir)
		if r.kthread_ep >= 0 { append(&fds, r.kthread_ep) }
		for _, k in r.kept { append(&fds, k.stat_fd, k.statm_fd, k.io_fd) }
		for _, k in r.kthreads { append(&fds, k.pidfd) }
		for fd in fds {
			if fd < 0 { continue }
			flags, ferr := linux.fcntl_getfd(fd, .GETFD)
			testing.expectf(t, ferr == .NONE && flags & 1 != 0, "descriptor %d: %v, flags %d", fd, ferr, flags)
		}
	}

	testing.expect(t, os.process_kill(child) == nil)
	_, _ = os.process_wait(child)   // (reaped: its pid is free)
	killed = true
	if c, there := find(&r, &out, child.pid); there { testing.expect(t, c.start != first.start, "the child is gone") }
	if kp, kept := r.kept[i32(child.pid)]; kept { testing.expect(t, kp.start != first.start, "its descriptors too") }
	held := len(r.kthreads)
	for _, k in r.kept { held += int(k.stat_fd >= 0) + int(k.statm_fd >= 0) + int(k.io_fd >= 0) }
	testing.expect_value(t, r.kept_fds, held)
}

// A descriptor kept on a pid used again by another process reads the new one's numbers, not the old one's: forks until
// the pid comes again cost too much, so the old one's descriptors are put in its place.
@(test)
a_kept_descriptor_of_a_process_gone_is_opened_again :: proc(t: ^testing.T) {
	r: Proc_Reader
	if !testing.expect(t, proc_reader_init(&r)) || r.fd_budget == 0 { return }
	defer proc_reader_destroy(&r)
	child, err := os.process_start({command = {"sleep", "60"}})
	if !testing.expect(t, err == nil) { return }
	out := make([dynamic]Proc_Counters, context.temp_allocator)
	procs_read(&r, &out)
	gone, kept := r.kept[i32(child.pid)]
	_ = os.process_kill(child)
	_, _ = os.process_wait(child)
	if !testing.expect(t, kept) { return }
	own := i32(os.get_pid())
	mine := r.kept[own]
	r.kept[own], r.kept[i32(child.pid)] = gone, mine   // (the descriptors of the one gone under a pid that lives)
	clear(&out)
	procs_read(&r, &out)
	found := false
	for c in out {
		if c.pid != own { continue }
		found = true
		testing.expect(t, c.start == mine.start && c.cpu_ns > 0 && c.resident > 0)
	}
	testing.expect(t, found, "read again by its path")
	testing.expect(t, r.kept[own].start == mine.start && r.kept[own].stat_fd >= 0)
}

// Verifies the optimized Proc_Reader (kept fds, stack paths, zero-alloc parsers, fd budget fallback) matches the plain
// reference reader byte-for-byte on a synthetic /proc tree with edge cases: spaces/parens/newlines in comm, kthreads,
// vanishing processes, unreadable files, and both unlink+recreate and in-place PID reuse.
@(test)
synthetic_proc_matches_plain_reader :: proc(t: ^testing.T) {
	root := fmt.tprintf("%s/inspecteur-synth-test-%d", synth_dir(), os.get_pid())
	_ = os.remove_all(root)
	_ = os.make_directory_all(root)
	defer {
		// Restore permissions on chmod-000 test files so remove_all cleans up cleanly.
		_ = os.chmod(fmt.tprintf("%s/104/io", root), {.Read_User, .Write_User})
		_ = os.chmod(fmt.tprintf("%s/106/stat", root), {.Read_User, .Write_User})
		_ = os.remove_all(root)
	}
	_ = os.write_entire_file(fmt.tprintf("%s/stat", root), "cpu  100 0 50 850 0 0 0 0 0 0\nbtime 1700000000\n")

	// Kernel threads (must be omitted)
	synth_write_proc(root, 2, 0, "kthreadd", 'S', PF_KTHREAD, 1, 2, 0, 1, 10, 0, 0, 0, 0)
	synth_write_proc(root, 3, 2, "kworker/0:0", 'I', PF_KTHREAD, 5, 5, 0, 1, 11, 0, 0, 0, 0)
	synth_write_proc(root, 4, 2, "kchild-noflag", 'S', 0, 1, 1, 0, 1, 12, 0, 0, 0, 0)

	// User processes covering edge cases
	synth_write_proc(root, 100, 1, "systemd", 'S', 0, 10, 20, -20, 1, 50, 200, 50, 4096, 8192, cmdline = "/sbin/init\x00--system\x00", cgroup = "0::/init.scope\n")
	synth_write_proc(root, 101, 100, "Web (Content)\n2", 'R', 0, 120, 30, 19, 12, 500, 1000, 250, 12345, 67890, cmdline = "firefox\x00-contentproc\x00", cgroup = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-firefox-99.scope\n")
	synth_write_proc(root, 102, 100, "no-statm", 'D', 0, 5, 0, 0, 2, 600, 300, 0, 100, 200, write_statm = false)
	synth_write_proc(root, 103, 100, "no-io", 'T', 0, 0, 0, 0, 1, 700, 100, 40, 0, 0, write_io = false)
	synth_write_proc(root, 104, 100, "denied-io", 'S', 0, 2, 3, 0, 3, 800, 400, 100, 999, 888, chmod_io_0 = true)
	// Vanished mid-read: directory exists during readdir, has no stat file
	_ = os.make_directory_all(fmt.tprintf("%s/105", root))
	// Unreadable stat
	synth_write_proc(root, 106, 100, "unreadable", 'S', 0, 1, 1, 0, 1, 900, 10, 0, 0, 0)
	_ = os.chmod(fmt.tprintf("%s/106/stat", root), {})

	// Test across three fd budgets: 0 (fallback only), 4 (tight cap), and 1024 (full kept pool).
	for budget in ([3]int{0, 4, 1024}) {
		pr: Proc_Reader
		testing.expect(t, proc_reader_init_root(&pr, root, fd_budget = budget))
		defer proc_reader_destroy(&pr)

		got := make([dynamic]Proc_Counters, context.temp_allocator)
		want := make([dynamic]Proc_Counters, context.temp_allocator)
		procs_read(&pr, &got)
		_ = plain_procs_read(root, pr.page_bytes, &want)
		expect_counters_equal(t, got[:], want[:], fmt.tprintf("sample1 budget=%d", budget))
		testing.expectf(t, pr.kept_fds <= budget, "kept_fds=%d exceeded budget=%d", pr.kept_fds, budget)
		testing.expect_value(t, len(got), 5)

		// Verify proc_facts on pid 101 (newline+parens comm, user cgroup scope, cmdline, boot_time)
		f101 := proc_facts(&pr, got[1])
		testing.expect_value(t, f101.name, "Web (Content)\n2")
		testing.expect_value(t, f101.cmdline, "firefox -contentproc")
		testing.expect_value(t, f101.scope, "app-firefox-99.scope")
		testing.expect(t, f101.user_unit)
		testing.expect_value(t, f101.started, i64(1700000005))

		// Sample 2: steady counters updated in place
		synth_write_proc(root, 101, 100, "Web (Content)\n2", 'S', 0, 200, 40, 19, 14, 500, 1200, 200, 55555, 77777)
		clear(&got); clear(&want)
		procs_read(&pr, &got)
		_ = plain_procs_read(root, pr.page_bytes, &want)
		expect_counters_equal(t, got[:], want[:], fmt.tprintf("sample2 budget=%d", budget))
		if budget == 1024 {
			// Steady sample with full budget must use pread for all kept user files and zero opens for them.
			testing.expect(t, pr.stats.preads >= 10, "kept fds should be read via pread")
		}

		// Sample 3: PID reuse (101 unlink+recreate with new start; 104 reused with readable io; 102 deleted; 103 in-place reuse as kthread)
		_ = os.remove_all(fmt.tprintf("%s/101", root))
		synth_write_proc(root, 101, 100, "reused-dir", 'R', 0, 7, 8, 0, 1, 9999, 50, 10, 111, 222)
		_ = os.chmod(fmt.tprintf("%s/104/io", root), {.Read_User, .Write_User})
		_ = os.remove_all(fmt.tprintf("%s/104", root))
		synth_write_proc(root, 104, 100, "reused-io-ok", 'S', 0, 3, 4, 0, 1, 8888, 60, 20, 333, 444)
		_ = os.remove_all(fmt.tprintf("%s/102", root))
		synth_write_proc(root, 103, 2, "now-kthread", 'I', PF_KTHREAD, 0, 0, 0, 1, 7777, 0, 0, 0, 0)

		clear(&got); clear(&want)
		procs_read(&pr, &got)
		_ = plain_procs_read(root, pr.page_bytes, &want)
		expect_counters_equal(t, got[:], want[:], fmt.tprintf("sample3 reuse budget=%d", budget))
		testing.expectf(t, pr.kept_fds <= budget, "kept_fds=%d exceeded budget=%d after reuse", pr.kept_fds, budget)

		// Restore tree for next budget iteration
		_ = os.remove_all(fmt.tprintf("%s/101", root))
		_ = os.remove_all(fmt.tprintf("%s/104", root))
		synth_write_proc(root, 101, 100, "Web (Content)\n2", 'R', 0, 120, 30, 19, 12, 500, 1000, 250, 12345, 67890, cmdline = "firefox\x00-contentproc\x00", cgroup = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-firefox-99.scope\n")
		synth_write_proc(root, 102, 100, "no-statm", 'D', 0, 5, 0, 0, 2, 600, 300, 0, 100, 200, write_statm = false)
		synth_write_proc(root, 103, 100, "no-io", 'T', 0, 0, 0, 0, 1, 700, 100, 40, 0, 0, write_io = false)
		synth_write_proc(root, 104, 100, "denied-io", 'S', 0, 2, 3, 0, 3, 800, 400, 100, 999, 888, chmod_io_0 = true)
	}
}

// Verifies O(N) top-K ranking matches full sorting, lazy Proc_History allocates only on the 2nd sample,
// Table.collapsed prunes dead keys, and memory + kept descriptors remain bounded under thousands of short-lived processes.
@(test)
ranking_and_churn_memory_stay_exact_and_bounded :: proc(t: ^testing.T) {
	// 1. O(N) ranking_make vs reference full sort (with ties, zeros and ended processes)
	app := new(App)
	defer free(app)
	defer sampler_destroy(&app.sampler)
	defer ranking_destroy(&app.ranking)

	for i in 0 ..< 250 {
		append(&app.sampler.procs, Proc{
			pid = i32(i + 1), start = u64(i + 1),
			cpu = f32((i * 37) % 100) / 10,
			private = u64(((i * 53) % 40) * 1024),
			read_rate = f64((i * 19) % 25),
			write_rate = f64((i * 7) % 15),
			threads = i32(1 + i % 5),
			ended = i % 11 == 0,
		})
	}
	ranking_make(app)
	ref_threads: i32
	for p in app.sampler.procs { ref_threads += p.threads }
	testing.expect_value(t, app.ranking.threads, ref_threads)
	for by in Busy_By {
		ref := make([dynamic]int, 0, len(app.sampler.procs), context.temp_allocator)
		for &p, i in app.sampler.procs { if !p.ended { append(&ref, i) } }
		context.user_index, context.user_ptr = int(by), app
		slice.sort_by(ref[:], proc(a, b: int) -> bool {
			m, procs := Busy_By(context.user_index), (^App)(context.user_ptr).sampler.procs[:]
			va, vb := busy_value(&procs[a], m), busy_value(&procs[b], m)
			if va != vb { return va > vb }
			return a < b
		})
		want := ref[:min(len(ref), BUSIEST_KEEP)]
		testing.expect_value(t, len(app.ranking.busiest[by]), len(want))
		for idx, k in app.ranking.busiest[by] {
			testing.expect_value(t, idx, want[k])
		}
	}

	// 2. Bounded memory, lazy Proc_History, and Table.collapsed pruning across 8,000 short-lived processes
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		old_a := context.allocator
		context.allocator = mem.tracking_allocator(&track)
		defer context.allocator = old_a

		cs: Sampler
		defer sampler_destroy(&cs)
		ct: Table
		defer table_destroy(&ct)
		table_columns_init(&ct)
		ct.tree = true
		cat: Catalog
		defer catalog_destroy(&cat)

		batch := make([dynamic]Proc_Counters, 0, 250)
		defer delete(batch)
		bfacts := make([dynamic]Proc_Facts, 0, 250)
		defer delete(bfacts)

		mem_at_10 := 0
		for step in 0 ..< 40 {
			free_all(context.temp_allocator)
			clear(&batch); clear(&bfacts)
			for p in 0 ..< 50 {
				append(&batch, Proc_Counters{pid = i32(p + 1), ppid = 1, start = 1, comm = "steady", cpu_ns = u64(step) * 1000, threads = 1, private = 1024 * 1024})
				append(&bfacts, Proc_Facts{name = "steady", cmdline = "steady", user = "alex", read = step == 0})
			}
			base_pid := i32(1000 + (step % 5) * 200)
			for p in 0 ..< 200 {
				pid := base_pid + i32(p)
				start := u64(100 + step * 1000 + p)
				append(&batch, Proc_Counters{pid = pid, ppid = 1, start = start, comm = "short", cpu_ns = 100, threads = 1, private = 4096})
				append(&bfacts, Proc_Facts{name = "short", cmdline = "short", user = "alex", read = true})
				// Mark short-lived processes collapsed to prove dead keys are pruned automatically.
				ct.collapsed[u64(u32(pid)) << 32 | (start & 0xffff_ffff)] = true
			}
			procs_merge(&cs, batch[:], bfacts[:], 1.0, 16_000_000_000, &cat, true, i64(step + 1) * 1_000_000_000)
			table_group(&ct, cs.procs[:])
			table_rows(&ct, &cs, &cat)
			if step == 10 {
				mem_at_10 = int(track.current_memory_allocated)
				// Short-lived processes seen only once must never allocate Proc_History.
				for p in cs.procs {
					if p.pid >= 1000 { testing.expect(t, p.hist == nil, "short-lived process must not allocate Proc_History") }
				}
			}
		}
		mem_at_end := int(track.current_memory_allocated)
		testing.expectf(t, mem_at_end <= mem_at_10 + 16 * 1024, "live memory grew under churn: step10=%d end=%d", mem_at_10, mem_at_end)
		testing.expectf(t, len(ct.collapsed) <= len(cs.procs), "dead collapsed keys leaked: collapsed=%d procs=%d", len(ct.collapsed), len(cs.procs))
	}
}

// Verifies Proc_Reader evicts kept descriptors and io_denied entries and keeps memory bounded when short-lived
// processes appear and vanish across samples on a synthetic /proc tree.
@(test)
synthetic_proc_churn_bounds_fds_and_memory :: proc(t: ^testing.T) {
	root := fmt.aprintf("%s/inspecteur-synth-churn-%d", synth_dir(), os.get_pid())
	defer delete(root)
	_ = os.remove_all(root)
	_ = os.make_directory_all(root)
	defer _ = os.remove_all(root)
	_ = os.write_entire_file(fmt.tprintf("%s/stat", root), "cpu  100 0 50 850 0 0 0 0 0 0\nbtime 1700000000\n")

	// 10 steady processes kept across all rounds
	for p in 0 ..< 10 {
		synth_write_proc(root, i32(100 + p), 1, "steady", 'S', 0, 10, 5, 0, 1, u64(50 + p), 200, 50, 1024, 512)
	}

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		old_a := context.allocator
		context.allocator = mem.tracking_allocator(&track)
		defer context.allocator = old_a

		pr: Proc_Reader
		testing.expect(t, proc_reader_init_root(&pr, root, fd_budget = 256))
		defer proc_reader_destroy(&pr)
		cs: Sampler
		defer sampler_destroy(&cs)
		ct: Table
		defer table_destroy(&ct)
		table_columns_init(&ct)

		out := make([dynamic]Proc_Counters, 0, 128)
		defer delete(out)
		facts := make([dynamic]Proc_Facts, 0, 128)
		defer delete(facts)

		mem_at_3 := 0
		for round in 0 ..< 12 {
			free_all(context.temp_allocator)
			// Remove previous round's 40 short-lived processes
			if round > 0 {
				prev_base := 1000 + (round - 1) * 100
				for k in 0 ..< 40 {
					dir := fmt.tprintf("%s/%d", root, prev_base + k)
					if k % 5 == 0 { _ = os.chmod(fmt.tprintf("%s/io", dir), {.Read_User, .Write_User}) }
					_ = os.remove_all(dir)
				}
			}
			// Spawn 40 new short-lived processes (some with unreadable io)
			base := 1000 + round * 100
			for k in 0 ..< 40 {
				synth_write_proc(root, i32(base + k), 1, "short", 'S', 0, 1, 1, 0, 1, u64(1000 + round * 100 + k), 40, 10, 0, 0, chmod_io_0 = (k % 5 == 0))
			}

			clear(&out); clear(&facts)
			procs_read(&pr, &out)
			testing.expect_value(t, len(out), 50)
			for c in out {
				f := proc_facts(&pr, c)
				f.read = true
				append(&facts, f)
			}
			procs_merge(&cs, out[:], facts[:], 1.0, 16_000_000_000, nil, true, i64(round + 1) * 1_000_000_000)
			table_group(&ct, cs.procs[:])
			table_rows(&ct, &cs, nil)

			// Only the 50 live processes' kept entries and 8 io_denied entries may exist after each reading.
			testing.expect_value(t, len(pr.kept), 50)
			testing.expect_value(t, len(pr.io_denied), 8)
			testing.expectf(t, pr.kept_fds <= 142, "kept_fds leaked: got %d", pr.kept_fds)
			if round == 3 { mem_at_3 = int(track.current_memory_allocated) }
		}
		// Clean up the final round's short-lived processes and read once more: only the 10 steady processes remain.
		last_base := 1000 + 11 * 100
		for k in 0 ..< 40 {
			dir := fmt.tprintf("%s/%d", root, last_base + k)
			if k % 5 == 0 { _ = os.chmod(fmt.tprintf("%s/io", dir), {.Read_User, .Write_User}) }
			_ = os.remove_all(dir)
		}
		free_all(context.temp_allocator)
		clear(&out)
		procs_read(&pr, &out)
		testing.expect_value(t, len(out), 10)
		testing.expect_value(t, len(pr.kept), 10)
		testing.expect_value(t, len(pr.io_denied), 0)
		testing.expect_value(t, pr.kept_fds, 30)
		mem_at_end := int(track.current_memory_allocated)
		testing.expectf(t, mem_at_end <= mem_at_3 + 32 * 1024, "live memory grew under /proc churn: round3=%d end=%d", mem_at_3, mem_at_end)
	}
}
