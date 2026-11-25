#+build !windows
package inspecteur

// Demo data for Linux and macOS sections (Services, Startup, Information, Properties, and journal details).

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:time"
import i18n "gt:i18n"

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
		Startup_Item{kind = .Autostart, id = "org.gnome.Software.desktop", name = "GNOME Software", command = "gnome-software --gapplication-service", icon = "demo:software", path = "/etc/xdg/autostart/org.gnome.Software.desktop", enabled = true, status = i18n.tr("Enabled"), can_toggle = true},
		Startup_Item{kind = .Autostart, id = "nextcloud.desktop", name = "Nextcloud", command = "nextcloud --background", icon = "demo:sync", path = "~/.config/autostart/nextcloud.desktop", enabled = false, status = i18n.tr("Disabled"), can_toggle = true},
		Startup_Item{kind = .Autostart, id = "org.gnome.Evolution-alarm-notify.desktop", name = "Evolution Alarm Notify", command = "/usr/libexec/evolution-data-server/evolution-alarm-notify", icon = "demo:alarm", path = "/etc/xdg/autostart/org.gnome.Evolution-alarm-notify.desktop", enabled = true, status = i18n.tr("Enabled"), can_toggle = true},
		Startup_Item{kind = .User_Service, id = "pipewire.service", name = "PipeWire Multimedia Service", command = "/usr/bin/pipewire", path = "/usr/lib/systemd/user/pipewire.service", enabled = true, status = i18n.tr("Enabled"), can_toggle = true},
		Startup_Item{kind = .User_Service, id = "syncthing.service", name = "Syncthing", command = "/usr/bin/syncthing serve --no-browser", path = "/usr/lib/systemd/user/syncthing.service", enabled = true, status = i18n.tr("Enabled"), can_toggle = true},
		Startup_Item{kind = .User_Service, id = "xdg-desktop-portal.service", name = "Portal service", command = "/usr/libexec/xdg-desktop-portal", path = "/usr/lib/systemd/user/xdg-desktop-portal.service", enabled = true, status = i18n.tr("Static"), can_toggle = false},
	)
	return ""
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

// (a task of the chores: the Properties of a demo process; constants alone)
demo_props_read :: proc(d: ^Demo, pid: i32, p: ^Props_Data, a: mem.Allocator) {
	q, ok := demo_proc_of(pid)
	if !ok { p.cwd_read, p.list_read = .Gone, .Gone; return }
	if q.user != DEMO_USER { p.cwd_read, p.list_read = .Denied, .Denied; return }
	p.cwd, p.cwd_read, p.list_read = "/home/alex", .Read, .Read
	p.cpus = fmt.aprintf("0-%d", DEMO_LOGICAL - 1, allocator = a)
	switch p.read_tab {
	case .General, .History:
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
		// (each line: its priority, then its text with the program's name for %s)
		Line :: struct { priority: u8, text: string }
		lines: []Line
		switch s.active {
		case "failed":
			lines = {{6, "Starting %s..."}, {5, "%s: reading /etc/%s.conf"}, {4, "%s: worker_connections exceed open file resource limit: 1024"},
				{3, "%s: bind() to 0.0.0.0:80 failed (98: Address already in use)"}, {3, "%s.service: Main process exited, code=exited, status=1/FAILURE"},
				{4, "%s.service: Failed with result 'exit-code'."}, {3, "Failed to start %s."}}
		case "active":
			lines = {{6, "Starting %s..."}, {7, "%s: loaded configuration from /etc/%s.conf"}, {5, "%s: listening on 127.0.0.1"}, {6, "Started %s."},
				{6, "%s: ready to accept connections"}, {4, "%s: slow request took 1.8 s"}, {6, "%s: client connected"}, {7, "%s: cache hit ratio 0.93"},
				{6, "%s: client disconnected"}, {4, "%s: certificate expires in 12 days"}, {6, "%s: checkpoint complete"}, {6, "%s: client connected"}}
		case:
			lines = {{6, "%s.service: Deactivated successfully."}, {6, "Stopped %s."}}
		}
		for l, i in lines {
			append(&u.journal, Journal_Entry{
				usec = (u.since + i64(i) * 47) * 1_000_000, priority = l.priority, pid = i32(max(s.pid, 1)), ident = strings.clone(base, a),
				message = strings.clone(strings.count(l.text, "%s") == 2 ? fmt.tprintf(l.text, base, base) : fmt.tprintf(l.text, base), a),
			})
		}
		return
	}
	u.journal_problem = i18n.tr("No line in the journal.")
}
