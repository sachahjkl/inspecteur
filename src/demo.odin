package inspecteur

// The demo: made-up readings in place of the system's, behind the same procedures (`inspecteur --demo`). The pictures of
// the documentation are made with it (inspecteurtool shots): they show no data of the machine they are made on: no
// host or user name, no home folder, no address, no MAC, no service or app of its own. The addresses are of the ranges
// kept for documentation (RFC 5737: 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24; RFC 3849: 2001:db8::/32; RFC 7042:
// the MACs 00:00:5e:00:53:xx).
//
// The demo acts on nothing: a signal, a priority, a service's or a startup item's change is refused (send_signal,
// set_priority, DEMO_REFUSED). Its numbers move with the time (sines of their own periods), so that its graphs are
// drawn. The procedures that run on the readers' threads (GPUs, services, startup, sockets, information) read only
// constants and the clock.

import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import "core:time"
import lucide "gt:lucide"
import "gt:ui"

// What an action of the demo answers.
DEMO_REFUSED :: "this is the demo: nothing was changed"

DEMO_LOGICAL :: 16
DEMO_MEMORY :: u64(32) * 1024 * 1024 * 1024
DEMO_BOOT_AGO :: 3 * 86400 + 5 * 3600 + 17 * 60   // seconds the demo machine has been up at the start
DEMO_USER :: "alex"

Demo :: struct {
	start:   time.Time,      // when the demo started: its clock
	shift:   f64,            // seconds added to its clock (demo_preroll: the minute before the start)
	machine_ns: i64,         // the machine's last reading
	last_ns: i64,
	cpu_ns:  [len(DEMO_PROCS)]u64,   // each process's CPU time so far
	io:      [len(DEMO_PROCS)][2]u64,
	total_ns, idle_ns: u64,
	core_total, core_idle: [DEMO_LOGICAL]u64,
	disk:    [2][3]u64,      // read, written, busy ms
	net:     [2][2]u64,      // received, sent
}

@(private = "file")
Demo_Proc :: struct {
	pid, ppid: i32,
	name:      string,
	user:      string,
	cmd:       string,
	load:      f32,    // its CPU, in logical processors (0.5: half of one), at the middle of its swing
	mem_mb:    u64,    // its private memory
	threads:   i32,
	io_kb:     u64,    // kilobytes per second it reads (and writes half of)
	gpu_mb:    u64,
}

// The processes, by pid; a process's parent comes before it.
@(private = "file")
DEMO_PROCS := [?]Demo_Proc{
	{1, 0, "systemd", "root", "/usr/lib/systemd/systemd --system", 0.002, 12, 1, 0, 0},
	{312, 1, "systemd-journald", "root", "/usr/lib/systemd/systemd-journald", 0.004, 24, 1, 6, 0},
	{340, 1, "systemd-udevd", "root", "/usr/lib/systemd/systemd-udevd", 0.0, 9, 1, 0, 0},
	{598, 1, "systemd-resolved", "systemd-resolve", "/usr/lib/systemd/systemd-resolved", 0.001, 7, 1, 0, 0},
	{612, 1, "dbus-daemon", "messagebus", "/usr/bin/dbus-daemon --system --address=systemd: --nofork", 0.003, 4, 1, 0, 0},
	{640, 1, "NetworkManager", "root", "/usr/bin/NetworkManager --no-daemon", 0.002, 16, 3, 0, 0},
	{655, 1, "systemd-logind", "root", "/usr/lib/systemd/systemd-logind", 0.0, 5, 1, 0, 0},
	{671, 1, "polkitd", "polkitd", "/usr/lib/polkit-1/polkitd --no-debug", 0.0, 9, 3, 0, 0},
	{690, 1, "sshd", "root", "/usr/bin/sshd -D", 0.0, 6, 1, 0, 0},
	{702, 1, "cupsd", "root", "/usr/bin/cupsd -l", 0.0, 8, 1, 0, 0},
	{715, 1, "avahi-daemon", "avahi", "avahi-daemon: running [workstation.local]", 0.001, 3, 1, 0, 0},
	{733, 1, "postgres", "postgres", "/usr/lib/postgresql/16/bin/postgres -D /var/lib/postgresql/16/main", 0.012, 48, 1, 40, 0},
	{741, 733, "postgres", "postgres", "postgres: checkpointer", 0.0, 6, 1, 8, 0},
	{742, 733, "postgres", "postgres", "postgres: walwriter", 0.002, 5, 1, 12, 0},
	{760, 1, "upowerd", "root", "/usr/lib/upowerd", 0.0, 7, 3, 0, 0},
	{788, 1, "udisksd", "root", "/usr/lib/udisks2/udisksd", 0.0, 11, 5, 0, 0},
	{810, 1, "nix-daemon", "root", "nix-daemon --daemon", 0.0, 21, 2, 0, 0},
	{901, 1, "gdm", "root", "/usr/bin/gdm", 0.0, 9, 3, 0, 0},
	{1203, 1, "systemd", DEMO_USER, "/usr/lib/systemd/systemd --user", 0.001, 10, 1, 0, 0},
	{1220, 1203, "pipewire", DEMO_USER, "/usr/bin/pipewire", 0.018, 14, 3, 0, 0},
	{1221, 1203, "wireplumber", DEMO_USER, "/usr/bin/wireplumber", 0.004, 22, 5, 0, 0},
	{1224, 1203, "pipewire-pulse", DEMO_USER, "/usr/bin/pipewire-pulse", 0.006, 9, 3, 0, 0},
	{1230, 1203, "dbus-daemon", DEMO_USER, "/usr/bin/dbus-daemon --session --address=systemd: --nofork", 0.002, 4, 1, 0, 0},
	{1262, 901, "gnome-shell", DEMO_USER, "/usr/bin/gnome-shell", 0.090, 380, 24, 4, 210},
	{1290, 1203, "xdg-desktop-portal", DEMO_USER, "/usr/libexec/xdg-desktop-portal", 0.0, 18, 6, 0, 0},
	{1301, 1203, "syncthing", DEMO_USER, "/usr/bin/syncthing serve --no-browser", 0.022, 96, 18, 120, 0},
	{1410, 1262, "firefox", DEMO_USER, "/usr/lib/firefox/firefox", 0.210, 520, 92, 60, 180},
	{1452, 1410, "Web Content", DEMO_USER, "/usr/lib/firefox/firefox -contentproc -childID 1 tab", 0.320, 410, 31, 0, 0},
	{1460, 1410, "Web Content", DEMO_USER, "/usr/lib/firefox/firefox -contentproc -childID 2 tab", 0.040, 230, 27, 0, 0},
	{1471, 1410, "Web Content", DEMO_USER, "/usr/lib/firefox/firefox -contentproc -childID 3 tab", 0.012, 160, 24, 0, 0},
	{1480, 1410, "RDD Process", DEMO_USER, "/usr/lib/firefox/firefox -contentproc rdd", 0.030, 40, 9, 0, 0},
	{1486, 1410, "Socket Process", DEMO_USER, "/usr/lib/firefox/firefox -contentproc socket", 0.004, 24, 8, 0, 0},
	{1520, 1262, "thunderbird", DEMO_USER, "/usr/lib/thunderbird/thunderbird", 0.020, 380, 70, 20, 60},
	{1604, 1262, "kgx", DEMO_USER, "/usr/bin/kgx --gapplication-service", 0.014, 64, 9, 0, 22},
	{1640, 1604, "bash", DEMO_USER, "/bin/bash", 0.0, 4, 1, 0, 0},
	{1702, 1640, "make", DEMO_USER, "make -j8 all", 0.004, 6, 1, 30, 0},
	{1710, 1702, "cc1", DEMO_USER, "cc1 -O2 -o build/render.o src/render.c", 0.950, 210, 1, 300, 0},
	{1711, 1702, "cc1", DEMO_USER, "cc1 -O2 -o build/parse.o src/parse.c", 0.880, 180, 1, 260, 0},
	{1712, 1702, "ld", DEMO_USER, "ld -o build/app build/main.o build/render.o build/parse.o", 0.400, 96, 1, 900, 0},
	{1801, 1262, "gimp", DEMO_USER, "/usr/bin/gimp", 0.060, 640, 18, 10, 90},
	{1850, 1262, "nautilus", DEMO_USER, "/usr/bin/nautilus --gapplication-service", 0.004, 110, 12, 2, 18},
	{1903, 1262, "gnome-text-editor", DEMO_USER, "/usr/bin/gnome-text-editor", 0.002, 72, 8, 0, 14},
	{1955, 1262, "soffice.bin", DEMO_USER, "/usr/lib/libreoffice/program/soffice.bin --writer", 0.010, 290, 11, 4, 40},
	{2100, 1203, "inspecteur", DEMO_USER, "/usr/bin/inspecteur", 0.010, 46, 9, 0, 30},
}

// The apps of the demo's menu: an id, a name, an icon of the theme, a program.
@(private = "file")
DEMO_APPS := [?][4]string{
	{"org.mozilla.firefox", "Firefox", "demo:browser", "firefox"},
	{"org.mozilla.Thunderbird", "Thunderbird", "demo:mail", "thunderbird"},
	{"org.gnome.Console", "Console", "demo:terminal", "kgx"},
	{"org.gimp.GIMP", "GNU Image Manipulation Program", "demo:image", "gimp"},
	{"org.gnome.Nautilus", "Files", "demo:files", "nautilus"},
	{"org.gnome.TextEditor", "Text Editor", "demo:text", "gnome-text-editor"},
	{"libreoffice-writer", "LibreOffice Writer", "demo:writer", "soffice.bin"},
	{"inspecteur", "Inspecteur", "inspecteur", "inspecteur"},
}

// The demo's icons: a glyph of Lucide on a tile of its colour, drawn the same on every machine (no icon theme is read:
// the pictures show nothing of the machine they are made on).
@(private = "file")
DEMO_ICONS := [?]struct { name, glyph: string, tint: [4]f32 }{
	{"demo:browser", lucide.GLOBE, {0.85, 0.42, 0.16, 1}},
	{"demo:mail", lucide.SEND_HORIZONTAL, {0.18, 0.47, 0.85, 1}},
	{"demo:terminal", lucide.TERMINAL, {0.22, 0.24, 0.27, 1}},
	{"demo:image", lucide.IMAGE, {0.45, 0.38, 0.30, 1}},
	{"demo:files", lucide.FOLDER, {0.24, 0.55, 0.85, 1}},
	{"demo:text", lucide.FILE_TEXT, {0.32, 0.62, 0.40, 1}},
	{"demo:writer", lucide.PENCIL, {0.16, 0.45, 0.75, 1}},
	{"demo:software", lucide.PACKAGE, {0.60, 0.35, 0.75, 1}},
	{"demo:sync", lucide.REFRESH_CW, {0.10, 0.55, 0.65, 1}},
	{"demo:alarm", lucide.BELL, {0.80, 0.55, 0.15, 1}},
}

// The demo's icon of `name` (none for a name it does not have).
demo_icon :: proc(name: string) -> Icon {
	for d in DEMO_ICONS { if d.name == name { return {ok = true, glyph = d.glyph, tint = d.tint} } }
	return {}
}

demo_init :: proc(d: ^Demo) { d.start = time.now() }
demo_destroy :: proc(d: ^Demo) {}

@(private = "file")
demo_seconds :: proc(d: ^Demo) -> f64 { return time.duration_seconds(time.since(d.start)) + d.shift }

// The minute before the start, read a second at a time: the Performance section's graphs are full at once (the
// pictures of the documentation are not a minute long to make).
demo_preroll :: proc(d: ^Demo, m: ^Machine, now_ns: i64) {
	for i in 0 ..< HISTORY_POINTS {
		back := HISTORY_POINTS - i
		d.shift = -f64(back)
		machine_sample(m, now_ns - i64(back) * 1_000_000_000, false)
		// (the GPUs: their thread reads every GPU_PERIOD; here a point every two seconds of the minute)
		if i % 2 == 0 {
			snap: Gpu_Snapshot
			demo_gpus_read(d, &snap)
			if len(m.gpus) != snap.count { resize(&m.gpus, snap.count) }
			for &g, k in m.gpus {
				g.read = snap.gpus[k]
				ui.value_history_push(&g.util_hist, g.read.util)
				ui.value_history_push(&g.mem_hist, 100 * f32(f64(g.read.mem_used) / f64(g.read.mem_total)))
			}
		}
	}
	d.shift = 0
}

// A value that swings around 1 with its own period (seconds) and phase: what makes the demo's numbers move.
@(private = "file")
swing :: proc(t: f64, period, phase: f64, depth: f64 = 0.6) -> f64 {
	return max(0, 1 + depth * math.sin(2 * math.PI * t / period + phase) + 0.25 * depth * math.sin(2 * math.PI * t / (period * 0.37) + phase * 3))
}

demo_catalog :: proc(c: ^Catalog) {
	for a in DEMO_APPS { catalog_add_entry(c, a[0], a[1], a[2], a[3], "") }
}

demo_procs_read :: proc(d: ^Demo, now_ns: i64, out: ^[dynamic]Proc_Counters) {
	dt := d.last_ns > 0 ? f64(now_ns - d.last_ns) / 1e9 : 0
	d.last_ns = now_ns
	t := demo_seconds(d)
	for p, i in DEMO_PROCS {
		load := f64(p.load) * swing(t, 7 + f64(i % 5) * 3, f64(i))
		d.cpu_ns[i] += u64(load * dt * 1e9)
		d.io[i][0] += u64(f64(p.io_kb) * 1024 * dt * swing(t, 5 + f64(i % 3), f64(i) * 0.7))
		d.io[i][1] += d.io[i][0] / 2 - min(d.io[i][1], d.io[i][0] / 2)
		mem := p.mem_mb * 1024 * 1024
		append(out, Proc_Counters{
			pid = p.pid, ppid = p.ppid, start = u64(p.pid) * 7, comm = p.name, cpu_ns = d.cpu_ns[i], threads = p.threads,
			state = load > 0.2 ? .Running : .Sleeping, resident = mem + mem / 3, private = mem,
			io_read = d.io[i][0], io_write = d.io[i][1], io_known = p.user == DEMO_USER,
		})
	}
}

demo_proc_facts :: proc(d: ^Demo, c: Proc_Counters) -> Proc_Facts {
	for p in DEMO_PROCS {
		if p.pid != c.pid { continue }
		exe := p.cmd
		if i := strings.index_byte(exe, ' '); i >= 0 { exe = exe[:i] }
		if !strings.has_prefix(exe, "/") { exe = strings.concatenate({"/usr/bin/", p.name}, context.temp_allocator) }
		return {name = p.name, cmdline = p.cmd, exe = p.user == DEMO_USER ? exe : "", user = p.user,
			started = time.to_unix_seconds(d.start) - DEMO_BOOT_AGO + i64(p.pid) * 9}
	}
	return {name = c.comm}
}

demo_machine_read :: proc(d: ^Demo, now_ns: i64, c: ^Machine_Counters) {
	// (the counters grow with the time since the last reading: a reading sooner than the period gives the same rates)
	dt := d.machine_ns > 0 ? max(f64(now_ns - d.machine_ns) / 1e9, 0.001) : 1
	d.machine_ns = now_ns
	t := demo_seconds(d)
	// the processors: each its own swing, three busier (the compilers of the demo)
	c.core_total_ns = make([dynamic]u64, context.temp_allocator)
	c.core_idle_ns = make([dynamic]u64, context.temp_allocator)
	step := u64(dt * 1e9)
	for i in 0 ..< DEMO_LOGICAL {
		busy := clamp(0.06 + 0.22 * swing(t, 9 + f64(i), f64(i) * 1.3, 0.9) + (i < 3 ? 0.35 : 0), 0, 1)
		d.core_total[i] += step
		d.core_idle[i] += u64((1 - busy) * f64(step))
		append(&c.core_total_ns, d.core_total[i])
		append(&c.core_idle_ns, d.core_idle[i])
	}
	d.total_ns, d.idle_ns = 0, 0
	for i in 0 ..< DEMO_LOGICAL { d.total_ns += d.core_total[i]; d.idle_ns += d.core_idle[i] }
	c.cpu_total_ns, c.cpu_idle_ns = d.total_ns, d.idle_ns
	c.boot_time = time.to_unix_seconds(d.start) - DEMO_BOOT_AGO
	c.uptime = f64(DEMO_BOOT_AGO) + t
	c.load = {f32(2.1 + 0.4 * math.sin(t / 30)), 1.8, 1.5}
	c.handles = 14_208
	used := u64(f64(DEMO_MEMORY) * (0.38 + 0.03 * math.sin(t / 20)))
	cached := DEMO_MEMORY / 4
	c.mem = {
		total = DEMO_MEMORY, free = DEMO_MEMORY - used - cached, available = DEMO_MEMORY - used, buffers = 410 * 1024 * 1024,
		cached = cached, reclaimable = 900 * 1024 * 1024, shared = 1100 * 1024 * 1024, dirty = 12 * 1024 * 1024,
		swap_total = 8 * 1024 * 1024 * 1024, swap_free = 8 * 1024 * 1024 * 1024 - 64 * 1024 * 1024,
		committed = used + used / 2, commit_limit = DEMO_MEMORY / 2 + 8 * 1024 * 1024 * 1024,
	}
	c.disks = make([dynamic]Disk_Counters, context.temp_allocator)
	for k in 0 ..< 2 {
		rate := (k == 0 ? 6.0 : 0.6) * 1024 * 1024 * swing(t, 11 + f64(k) * 7, f64(k), 0.95)
		d.disk[k][0] += u64(rate * dt)
		d.disk[k][1] += u64(rate * 0.6 * dt)
		d.disk[k][2] += u64(min(1000, rate / (k == 0 ? 120_000 : 40_000)) * dt)
		append(&c.disks, Disk_Counters{k == 0 ? "nvme0n1" : "sda", d.disk[k][0], d.disk[k][1], d.disk[k][2]})
	}
	c.nets = make([dynamic]Net_Counters, context.temp_allocator)
	for k in 0 ..< 2 {
		if k == 1 { append(&c.nets, Net_Counters{"wlp4s0", 0, 0}); continue }
		rx := 2.4e6 * swing(t, 13, 0.5, 0.9)
		d.net[k][0] += u64(rx * dt)
		d.net[k][1] += u64(rx * 0.12 * dt)
		append(&c.nets, Net_Counters{"enp5s0", d.net[k][0], d.net[k][1]})
	}
}

demo_cpu_info :: proc() -> Cpu_Info {
	return {model = strings.clone("AMD Ryzen 7 7700X 8-Core Processor"), sockets = 1, cores = 8, logical = DEMO_LOGICAL,
		base_mhz = 4500, max_mhz = 5400, cache = {512 * 1024, 8 * 1024 * 1024, 32 * 1024 * 1024, 0}}
}

demo_cpu_mhz :: proc(d: ^Demo) -> f32 { return f32(4700 + 300 * math.sin(demo_seconds(d) / 4)) }

demo_devices :: proc(d: ^Demo, disks: ^[dynamic]Disk_Info, nets: ^[dynamic]Net_Info) {
	@(static) root := [?]string{"/", "/boot", "/home"}
	@(static) data := [?]string{"/mnt/data"}
	@(static) wired := [?]string{"192.0.2.10", "2001:db8::10", "fe80::200:5eff:fe00:5301"}
	append(disks, Disk_Info{name = "nvme0n1", model = "Samsung SSD 980 PRO 1TB", kind = "NVMe SSD", capacity = 1_000_204_886_016, mounts = root[:]})
	append(disks, Disk_Info{name = "sda", model = "WDC WD40EFRX-68N32N0", kind = "HDD", capacity = 4_000_787_030_016, mounts = data[:]})
	append(nets, Net_Info{name = "enp5s0", kind = "Ethernet", mac = "00:00:5e:00:53:01", up = true, speed_mbps = 1000, addrs = wired[:]})
	append(nets, Net_Info{name = "wlp4s0", kind = "Wi-Fi", mac = "00:00:5e:00:53:02", up = false})
}

// (the GPU thread's: constants and the clock only)
demo_gpus_read :: proc(d: ^Demo, snap: ^Gpu_Snapshot) {
	t := demo_seconds(d)
	g := &snap.gpus[0]
	g.name_len = copy(g.name[:], "NVIDIA GeForce RTX 4070")
	g.driver_len = copy(g.driver[:], "560.35.03")
	g.vendor = "NVIDIA"
	g.has_util, g.has_mem, g.has_temp, g.has_power, g.has_clock = true, true, true, true, true
	g.util = f32(18 * swing(t, 10, 0.3, 0.8))
	g.mem_total = 12 * 1024 * 1024 * 1024
	g.mem_used = u64(f64(g.mem_total) * (0.21 + 0.02 * math.sin(t / 9)))
	g.temp_c, g.power_w, g.clock_mhz = 47, f32(38 + 10 * math.sin(t / 7)), 2475
	snap.count = 1
	for p in DEMO_PROCS {
		if p.gpu_mb > 0 { gpu_proc_add(snap, 0, p.pid, p.gpu_mb * 1024 * 1024) }
	}
}

@(private = "file")
Demo_Service :: struct { name, description, active, sub, file: string, pid: i32, mem_mb: u64 }

@(private = "file")
DEMO_SYSTEM_SERVICES := [?]Demo_Service{
	{"avahi-daemon.service", "Avahi mDNS/DNS-SD Stack", "active", "running", "enabled", 715, 3},
	{"bluetooth.service", "Bluetooth service", "inactive", "dead", "disabled", 0, 0},
	{"cups.service", "CUPS Scheduler", "active", "running", "enabled", 702, 8},
	{"dbus.service", "D-Bus System Message Bus", "active", "running", "static", 612, 4},
	{"docker.service", "Docker Application Container Engine", "inactive", "dead", "disabled", 0, 0},
	{"fwupd.service", "Firmware update daemon", "inactive", "dead", "static", 0, 0},
	{"gdm.service", "GNOME Display Manager", "active", "running", "enabled", 901, 9},
	{"getty@tty1.service", "Getty on tty1", "active", "running", "enabled", 0, 1},
	{"nginx.service", "A high performance web server", "failed", "failed", "enabled", 0, 0},
	{"NetworkManager.service", "Network Manager", "active", "running", "enabled", 640, 16},
	{"nix-daemon.service", "Nix Daemon", "active", "running", "enabled", 810, 21},
	{"polkit.service", "Authorization Manager", "active", "running", "static", 671, 9},
	{"postgresql.service", "PostgreSQL database server", "active", "running", "enabled", 733, 59},
	{"sshd.service", "OpenSSH Daemon", "active", "running", "enabled", 690, 6},
	{"systemd-journald.service", "Journal Service", "active", "running", "static", 312, 24},
	{"systemd-logind.service", "User Login Management", "active", "running", "static", 655, 5},
	{"systemd-resolved.service", "Network Name Resolution", "active", "running", "enabled", 598, 7},
	{"systemd-timesyncd.service", "Network Time Synchronization", "active", "running", "enabled", 0, 3},
	{"systemd-udevd.service", "Rule-based Manager for Device Events and Files", "active", "running", "static", 340, 9},
	{"udisks2.service", "Disk Manager", "active", "running", "enabled", 788, 11},
	{"upower.service", "Daemon for power management", "active", "running", "enabled", 760, 7},
}

@(private = "file")
DEMO_USER_SERVICES := [?]Demo_Service{
	{"dbus.service", "D-Bus User Message Bus", "active", "running", "static", 1230, 4},
	{"pipewire.service", "PipeWire Multimedia Service", "active", "running", "enabled", 1220, 14},
	{"pipewire-pulse.service", "PipeWire PulseAudio", "active", "running", "enabled", 1224, 9},
	{"syncthing.service", "Syncthing - Open Source Continuous File Synchronization", "active", "running", "enabled", 1301, 96},
	{"wireplumber.service", "Multimedia Service Session Manager", "active", "running", "enabled", 1221, 22},
	{"xdg-desktop-portal.service", "Portal service", "active", "running", "static", 1290, 18},
}

// (a reader thread's: constants only)
demo_services_read :: proc(d: ^Demo, manager: Manager, out: ^[dynamic]Service, allocator: mem.Allocator) -> string {
	list := manager == .System ? DEMO_SYSTEM_SERVICES[:] : DEMO_USER_SERVICES[:]
	for s in list {
		append(out, Service{name = s.name, description = s.description, load = "loaded", active = s.active, sub = s.sub, file = s.file,
			pid = s.pid, memory = s.mem_mb > 0 ? s.mem_mb * 1024 * 1024 : MEMORY_UNKNOWN})
	}
	return ""
}

demo_startup_read :: proc(d: ^Demo, out: ^[dynamic]Startup_Item, allocator: mem.Allocator) -> string {
	append(out,
		Startup_Item{kind = .Autostart, id = "org.gnome.Software.desktop", name = "GNOME Software", command = "gnome-software --gapplication-service", icon = "demo:software", path = "/etc/xdg/autostart/org.gnome.Software.desktop", enabled = true, status = "Enabled", can_toggle = true},
		Startup_Item{kind = .Autostart, id = "nextcloud.desktop", name = "Nextcloud", command = "nextcloud --background", icon = "demo:sync", path = "~/.config/autostart/nextcloud.desktop", enabled = false, status = "Disabled", can_toggle = true},
		Startup_Item{kind = .Autostart, id = "org.gnome.Evolution-alarm-notify.desktop", name = "Evolution Alarm Notify", command = "/usr/libexec/evolution-data-server/evolution-alarm-notify", icon = "demo:alarm", path = "/etc/xdg/autostart/org.gnome.Evolution-alarm-notify.desktop", enabled = true, status = "Enabled", can_toggle = true},
		Startup_Item{kind = .User_Service, id = "pipewire.service", name = "PipeWire Multimedia Service", command = "/usr/bin/pipewire", path = "/usr/lib/systemd/user/pipewire.service", enabled = true, status = "Enabled", can_toggle = true},
		Startup_Item{kind = .User_Service, id = "syncthing.service", name = "Syncthing", command = "/usr/bin/syncthing serve --no-browser", path = "/usr/lib/systemd/user/syncthing.service", enabled = true, status = "Enabled", can_toggle = true},
		Startup_Item{kind = .User_Service, id = "xdg-desktop-portal.service", name = "Portal service", command = "/usr/libexec/xdg-desktop-portal", path = "/usr/lib/systemd/user/xdg-desktop-portal.service", enabled = true, status = "Static", can_toggle = false},
	)
	return ""
}

demo_sockets_read :: proc(d: ^Demo, out: ^[dynamic]Socket) {
	v4 :: proc(a, b, c, e: u8) -> (r: [16]u8) { r[0], r[1], r[2], r[3] = a, b, c, e; return }
	v6_local :: proc() -> (r: [16]u8) { r[15] = 1; return }
	start :: proc(pid: i32) -> u64 { return u64(pid) * 7 }
	host := v4(192, 0, 2, 10)
	append(out,
		Socket{proto = .TCP, local = v4(127, 0, 0, 1), lport = 631, state = .Listening, key = 9001, pid = 702, start = start(702)},
		Socket{proto = .TCP, lport = 22, state = .Listening, key = 9002, pid = 690, start = start(690)},
		Socket{proto = .TCP, v6 = true, lport = 22, state = .Listening, key = 9003, pid = 690, start = start(690)},
		Socket{proto = .TCP, local = v4(127, 0, 0, 1), lport = 5432, state = .Listening, key = 9004, pid = 733, start = start(733)},
		Socket{proto = .TCP, lport = 22000, state = .Listening, key = 9005, pid = 1301, start = start(1301)},
		Socket{proto = .TCP, local = host, lport = 51844, remote = v4(198, 51, 100, 23), rport = 443, state = .Established, key = 9006, pid = 1486, start = start(1486)},
		Socket{proto = .TCP, local = host, lport = 51850, remote = v4(198, 51, 100, 40), rport = 443, state = .Established, key = 9007, pid = 1486, start = start(1486)},
		Socket{proto = .TCP, local = host, lport = 51862, remote = v4(203, 0, 113, 7), rport = 443, state = .Established, key = 9008, pid = 1486, start = start(1486)},
		Socket{proto = .TCP, local = host, lport = 40122, remote = v4(203, 0, 113, 80), rport = 993, state = .Established, key = 9009, pid = 1520, start = start(1520)},
		Socket{proto = .TCP, local = host, lport = 22000, remote = v4(198, 51, 100, 77), rport = 41820, state = .Established, key = 9010, pid = 1301, start = start(1301)},
		Socket{proto = .TCP, local = host, lport = 51700, remote = v4(198, 51, 100, 23), rport = 443, state = .Time_Wait},
		Socket{proto = .UDP, lport = 5353, state = .Open, key = 9011},
		Socket{proto = .UDP, local = v4(127, 0, 0, 53), lport = 53, state = .Open, key = 9012},
		Socket{proto = .UDP, local = host, lport = 21027, state = .Open, key = 9013, pid = 1301, start = start(1301)},
		Socket{proto = .UDP, v6 = true, local = v6_local(), lport = 323, state = .Open, key = 9014},
	)
}

// (the Information thread's: its texts in context.allocator, the reading's arena)
demo_info_read :: proc(s: ^Info_Static) {
	a := context.allocator
	s.os_name = "NixOS 26.05 (Yarara)"
	s.kernel = "Linux 6.12.8 (#1-NixOS SMP PREEMPT_DYNAMIC)"
	s.arch = "x86_64"
	s.hostname = "workstation"
	s.computer = "ASUS System Product"
	s.board = "ASUSTeK COMPUTER INC. TUF GAMING B650-PLUS"
	s.firmware = "American Megatrends Inc. 1813 10/14/2024"
	s.desktop = "GNOME"
	s.session = "wayland"
	s.display = "Wayland (wayland-0)"
	s.cpu = demo_cpu_info()
	append(&s.gpus, Info_Gpu{name = "NVIDIA Corporation AD104 [GeForce RTX 4070]", vendor = "NVIDIA Corporation", ids = "10de:2786", driver = "nvidia", slot = "0000:01:00.0", named = true})
	append(&s.fss,
		Info_Fs{mount = "/", device = "/dev/nvme0n1p2", kind = "ext4", size = 980 * 1024 * 1024 * 1024, free = 512 * 1024 * 1024 * 1024},
		Info_Fs{mount = "/boot", device = "/dev/nvme0n1p1", kind = "vfat", size = 1024 * 1024 * 1024, free = 820 * 1024 * 1024},
		Info_Fs{mount = "/mnt/data", device = "/dev/sda1", kind = "btrfs", size = 3700 * 1024 * 1024 * 1024, free = 2100 * 1024 * 1024 * 1024},
	)
	append(&s.screens, Info_Screen{connector = "DP-1", name = "DELL U2723QE", mode = "3840x2160"})
	_ = a
}

// (the window's thread: the Properties of a demo process)
demo_props_read :: proc(d: ^Demo, p: ^Props, a: mem.Allocator) {
	proc_of :: proc(pid: i32) -> (Demo_Proc, bool) {
		for q in DEMO_PROCS { if q.pid == pid { return q, true } }
		return {}, false
	}
	q, ok := proc_of(p.pid)
	if !ok { p.cwd_read, p.list_read = .Gone, .Gone; return }
	if q.user != DEMO_USER { p.cwd_read, p.list_read = .Denied, .Denied; return }
	p.cwd, p.cwd_read, p.list_read = "/home/alex", .Read, .Read
	switch p.tab {
	case .General:
	case .Threads:
		for k in 0 ..< int(q.threads) {
			name := q.name
			if k > 0 { name = k % 3 == 1 ? "worker" : k % 3 == 2 ? "IPC I/O" : "timer" }
			append(&p.threads, Thread_Row{tid = q.pid + i32(k), name = name, state = .Sleeping, cpu_ns = u64(1 + k * 3) * 1_000_000_000 / u64(k + 1), nice = 0})
		}
	case .Files:
		append(&p.files, File_Row{0, "/dev/null"}, File_Row{1, "pipe:[48211]"}, File_Row{2, "pipe:[48211]"}, File_Row{3, "anon_inode:[eventfd]"},
			File_Row{4, "socket:[51002]"}, File_Row{5, "/home/alex/.cache/fontconfig/cache-file"}, File_Row{6, "/home/alex/Documents/notes.txt"})
	case .Modules:
		append(&p.modules, Module_Row{q.cmd[:strings.index_byte(q.cmd, ' ') >= 0 ? strings.index_byte(q.cmd, ' ') : len(q.cmd)], 14 * 1024 * 1024},
			Module_Row{"/usr/lib/libc.so.6", 2 * 1024 * 1024}, Module_Row{"/usr/lib/libm.so.6", 940 * 1024}, Module_Row{"/usr/lib/libwayland-client.so.0", 64 * 1024},
			Module_Row{"/usr/lib/locale/locale-archive", 3 * 1024 * 1024}, Module_Row{"/usr/lib/ld-linux-x86-64.so.2", 220 * 1024})
	case .Environment:
		append(&p.env, "HOME=/home/alex", "LANG=en_US.UTF-8", "PATH=/usr/local/bin:/usr/bin", "SHELL=/bin/bash", "USER=alex",
			"WAYLAND_DISPLAY=wayland-0", "XDG_CURRENT_DESKTOP=GNOME", "XDG_SESSION_TYPE=wayland")
	}
	_ = a
}

// (the details' thread's: constants and the clock only) A service's details and journal, made up.
demo_unit_details :: proc(d: ^Demo, u: ^Unit_Details, a: mem.Allocator) {
	list := u.manager == .System ? DEMO_SYSTEM_SERVICES[:] : DEMO_USER_SERVICES[:]
	for s in list {
		if s.name != u.name { continue }
		u.file = strings.concatenate({u.manager == .System ? "/usr/lib/systemd/system/" : "/usr/lib/systemd/user/", s.name}, a)
		now := time.to_unix_seconds(d.start)
		u.since = now - DEMO_BOOT_AGO + 12
		if s.active == "active" {
			u.tasks = u64(max(s.mem_mb / 4, 1))
			u.cpu_ns = s.mem_mb * 380_000_000
		}
		base := strings.trim_suffix(s.name, ".service")
		stamp :: proc(t: i64, a: mem.Allocator) -> string {
			dt, _ := time.time_to_datetime(time.unix(t, 0))
			return fmt.aprintf("%04d-%02d-%02dT%02d:%02d:%02d+00:00", dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second, allocator = a)
		}
		lines: []string
		switch s.active {
		case "failed":
			lines = {"Starting %s...", "%s: bind() to 0.0.0.0:80 failed (98: Address already in use)", "%s.service: Main process exited, code=exited, status=1/FAILURE", "%s.service: Failed with result 'exit-code'.", "Failed to start %s."}
		case "active":
			lines = {"Starting %s...", "Started %s.", "%s: ready to accept connections"}
		case:
			lines = {"%s.service: Deactivated successfully.", "Stopped %s."}
		}
		for l, i in lines {
			append(&u.journal, fmt.aprintf("%s workstation %s[%d]: %s", stamp(u.since + i64(i), a), base, max(s.pid, 1), fmt.tprintf(l, base), allocator = a))
		}
		return
	}
	u.journal_problem = "No line in the journal."
}
