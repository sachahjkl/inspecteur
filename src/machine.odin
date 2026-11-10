package inspecteur

// The machine as a whole, for the Performance section: the CPU (all of it and each logical processor), the memory, each
// disk, each network interface (the GPUs: gpu.odin). A sample reads a few files of /proc and /sys and keeps the last
// HISTORY_POINTS values of each graph, whatever section is shown: the graphs are full when it is opened.
//
// What does not change while the program runs (the CPU's model and caches, the disks and their mounts, the interfaces)
// is read once; the CPU's details the first time the Performance section is shown, the rest at the start.

import "core:fmt"
import "core:net"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "gt:platform"
import "gt:ui"

// The points of a graph: one per sample (60 s at the default period).
HISTORY_POINTS :: 60
// Samples between two readings of what seldom changes: an interface's addresses, its speed, whether it is up.
NET_STATIC_SAMPLES :: 10
// A disk's sector, as /proc/diskstats counts them (always 512 bytes, whatever the disk's own).
SECTOR_BYTES :: 512

// The last HISTORY_POINTS values of a graph (the toolkit's ring).
History :: ui.Value_History(HISTORY_POINTS)

Cpu_Info :: struct {
	model:            string,   // owned
	sockets, cores, logical: int,
	base_mhz, max_mhz: f32,     // 0: not told by the system
	cache:            [4]u64,   // bytes of each level, all of its copies (L1: data and instructions)
}

Disk :: struct {
	name, model: string,   // owned (nvme0n1, "Samsung SSD 970 EVO Plus 1TB")
	kind:        string,   // NVMe, SSD, HDD, Removable
	capacity:    u64,
	mounts:      [dynamic]string,   // owned: where its file systems are, through partitions and mapped devices
	sectors_read, sectors_written, io_ms: u64,
	read_rate, write_rate: f64,   // bytes per second
	active:      f32,             // percent of the time it was busy
	read_hist, write_hist, active_hist: History,
}

Net :: struct {
	name, kind, mac: string,   // owned name and mac
	speed_mbps:  int,          // 0: unknown (down, virtual)
	up:          bool,
	addrs:       [dynamic]string,   // owned: IPv4 then IPv6
	rx, tx:      u64,
	rx_rate, tx_rate: f64,     // bytes per second
	rx_hist, tx_hist: History,
}

Machine :: struct {
	buf:        []u8,
	// the CPU
	total, idle: u64,              // all processors' ticks at the last sample
	d_total:    u64,               // since the sample before (the processes' CPU % is their share of it)
	core_total, core_idle: [dynamic]u64,
	cpu:        f32,
	core_cpu:   [dynamic]f32,
	cpu_hist:   History,
	core_hist:  [dynamic]History,
	boot_time:  i64,               // unix seconds (btime): a process's start is its ticks after it
	load:       [3]f32,
	uptime:     f64,               // seconds
	handles:    u64,               // the open file handles of the whole system
	mhz:        f32,               // the processors' mean frequency now (read while the CPU is shown)
	info:       Cpu_Info,
	info_read:  bool,
	// the memory
	mem:        Mem_Fields,
	mem_hist:   History,           // percent in use
	// the devices
	disks:      [dynamic]Disk,
	nets:       [dynamic]Net,
	gpu:        Gpu_Watch,
	gpus:       [dynamic]Gpu,
	last_ns:    i64,
	samples:    int,
}

machine_init :: proc(m: ^Machine) {
	m.buf = make([]u8, PROC_READ_MAX)
	disks_find(m)
	nets_find(m)
	gpu_start(&m.gpu)
}

machine_destroy :: proc(m: ^Machine) {
	gpu_stop(&m.gpu)
	delete(m.buf)
	delete(m.core_total)
	delete(m.core_idle)
	delete(m.core_cpu)
	delete(m.core_hist)
	delete(m.info.model)
	for &d in m.disks {
		delete(d.name)
		delete(d.model)
		for s in d.mounts { delete(s) }
		delete(d.mounts)
	}
	delete(m.disks)
	for &n in m.nets {
		delete(n.name)
		delete(n.mac)
		for s in n.addrs { delete(s) }
		delete(n.addrs)
	}
	delete(m.nets)
	delete(m.gpus)
}

mem_used :: proc(m: ^Machine) -> u64 { return m.mem.total - min(m.mem.available, m.mem.total) }

// Reads the machine again. `cpu_shown`: the CPU's page is on the screen (its frequency is read, its details once).
machine_sample :: proc(m: ^Machine, now_ns: i64, cpu_shown: bool) {
	dt := m.last_ns > 0 ? f64(now_ns - m.last_ns) / 1e9 : 0
	m.last_ns = now_ns
	m.samples += 1

	if text, _, ok := read_file(m.buf, linux.AT_FDCWD, "/proc/stat"); ok {
		t := parse_cpu_times(string(text))
		m.d_total = m.total > 0 ? t.total - min(m.total, t.total) : 0
		if m.d_total > 0 { m.cpu = 100 * (1 - f32(t.idle - min(m.idle, t.idle)) / f32(m.d_total)) }
		m.total, m.idle = t.total, t.idle
		n := len(t.core_total)
		if len(m.core_total) != n {
			resize(&m.core_total, n)
			resize(&m.core_idle, n)
			resize(&m.core_cpu, n)
			resize(&m.core_hist, n)
		}
		for i in 0 ..< n {
			dt_core := t.core_total[i] - min(m.core_total[i], t.core_total[i])
			if m.core_total[i] > 0 && dt_core > 0 { m.core_cpu[i] = 100 * (1 - f32(t.core_idle[i] - min(m.core_idle[i], t.core_idle[i])) / f32(dt_core)) }
			m.core_total[i], m.core_idle[i] = t.core_total[i], t.core_idle[i]
			if m.samples > 1 { ui.value_history_push(&m.core_hist[i], m.core_cpu[i]) }
		}
		if m.samples > 1 { ui.value_history_push(&m.cpu_hist, m.cpu) }
		m.boot_time = t.boot_time
	}
	if text, _, ok := read_file(m.buf, linux.AT_FDCWD, "/proc/meminfo"); ok {
		m.mem = parse_meminfo(string(text))
		ui.value_history_push(&m.mem_hist, m.mem.total > 0 ? 100 * f32(f64(mem_used(m)) / f64(m.mem.total)) : 0)
	}
	if text, _, ok := read_file(m.buf, linux.AT_FDCWD, "/proc/loadavg"); ok { m.load = parse_loadavg(string(text)) }
	if text, _, ok := read_file(m.buf, linux.AT_FDCWD, "/proc/uptime"); ok { m.uptime = strconv.parse_f64(first_field(string(text))) or_else 0 }
	if text, _, ok := read_file(m.buf, linux.AT_FDCWD, "/proc/sys/fs/file-nr"); ok { m.handles = u64(strconv.parse_uint(first_field(string(text)), 10) or_else 0) }
	if text, _, ok := read_file(m.buf, linux.AT_FDCWD, "/proc/diskstats"); ok { disks_sample(m, string(text), dt) }
	if text, _, ok := read_file(m.buf, linux.AT_FDCWD, "/proc/net/dev"); ok { nets_sample(m, string(text), dt) }
	if m.samples % NET_STATIC_SAMPLES == 1 { nets_static(m) }
	gpus_sample(m)
	if cpu_shown {
		if !m.info_read { cpu_info_read(m) }
		m.mhz = cpu_mhz_now(len(m.core_total))
	}
}

@(private = "file")
first_field :: proc(text: string) -> string {
	t := strings.trim_left_space(text)
	if i := strings.index_any(t, " \t\n"); i >= 0 { return t[:i] }
	return t
}

////////////////////////////////
// The CPU's details (read once)

@(private = "file")
cpu_info_read :: proc(m: ^Machine) {
	m.info_read = true
	data, err := os.read_entire_file("/proc/cpuinfo", context.temp_allocator)
	if err == nil { m.info = parse_cpuinfo(string(data)) }
	if m.info.logical == 0 { m.info.logical = len(m.core_total) }
	// the frequencies of cpufreq, in kHz: the base when the driver tells it (intel_pstate), the most it may reach
	khz :: proc(path: string) -> f32 { return f32(strconv.parse_f64(read_text(path)) or_else 0) / 1000 }
	m.info.base_mhz = khz("/sys/devices/system/cpu/cpu0/cpufreq/base_frequency")
	m.info.max_mhz = khz("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq")
	// the caches: each copy once (a cache shared by several processors lists them all in shared_cpu_list)
	seen := make(map[string]bool, 64, context.temp_allocator)
	for cpu in 0 ..< m.info.logical {
		for index in 0 ..< 8 {
			dir := fmt.tprintf("/sys/devices/system/cpu/cpu%d/cache/index%d", cpu, index)
			level := strconv.parse_int(read_text(fmt.tprintf("%s/level", dir))) or_else 0
			if level < 1 || level > 4 { break }
			key := fmt.tprintf("%d %s %s", level, read_text(fmt.tprintf("%s/type", dir)), read_text(fmt.tprintf("%s/shared_cpu_list", dir)))
			if key in seen { continue }
			seen[key] = true
			m.info.cache[level - 1] += parse_size_k(read_text(fmt.tprintf("%s/size", dir)))
		}
	}
}

// The processors' mean frequency now, in MHz (cpufreq's scaling_cur_freq; 0 without cpufreq).
@(private = "file")
cpu_mhz_now :: proc(logical: int) -> f32 {
	sum: f64
	n := 0
	for cpu in 0 ..< logical {
		v, ok := strconv.parse_f64(read_text(fmt.tprintf("/sys/devices/system/cpu/cpu%d/cpufreq/scaling_cur_freq", cpu)))
		if ok { sum += v; n += 1 }
	}
	return n > 0 ? f32(sum / f64(n) / 1000) : 0
}

////////////////////////////////
// Disks

// The disks: the block devices of a device (not loops, RAM disks or mapped devices), with their mounts.
@(private = "file")
disks_find :: proc(m: ^Machine) {
	fis, err := os.read_all_directory_by_path("/sys/block", context.temp_allocator)
	if err != nil { return }
	slice.sort_by(fis, proc(a, b: os.File_Info) -> bool { return a.name < b.name })
	for fi in fis {
		dir := fmt.tprintf("/sys/block/%s", fi.name)
		if !os.exists(fmt.tprintf("%s/device", dir)) { continue }
		sectors := u64(strconv.parse_uint(read_text(fmt.tprintf("%s/size", dir)), 10) or_else 0)
		if sectors == 0 { continue }
		d := Disk{name = strings.clone(fi.name), model = strings.clone(read_text(fmt.tprintf("%s/device/model", dir))), capacity = sectors * SECTOR_BYTES}
		switch {
		case read_text(fmt.tprintf("%s/removable", dir)) == "1":    d.kind = "Removable"
		case strings.has_prefix(fi.name, "nvme"):                    d.kind = "NVMe SSD"
		case read_text(fmt.tprintf("%s/queue/rotational", dir)) == "1": d.kind = "HDD"
		case:                                                         d.kind = "SSD"
		}
		append(&m.disks, d)
	}
	mounts_find(m)
}

// Each disk's mounts, from /proc/self/mountinfo: a file system's device (major:minor) leads to its disk through its
// partition or the devices it is mapped on (LUKS, LVM). A bind mount of a part of a file system is left out: the file
// system's own mount (its root, or a btrfs subvolume's) says where it is.
@(private = "file")
mounts_find :: proc(m: ^Machine) {
	data, err := os.read_entire_file("/proc/self/mountinfo", context.temp_allocator)
	if err != nil { return }
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		f := strings.fields(line, context.temp_allocator)
		dash := -1
		for w, i in f { if w == "-" { dash = i; break } }
		if dash < 0 || len(f) < dash + 4 || len(f) < 5 { continue }
		root, point, source, super := f[3], f[4], f[dash + 2], f[dash + 3]
		// (the source, not the device number: btrfs gives its mounts numbers of no device)
		if !strings.has_prefix(source, "/dev/") { continue }   // (no device: tmpfs, proc...)
		if root != "/" && !has_option(super, strings.concatenate({"subvol=", root}, context.temp_allocator)) { continue }
		device := source[strings.last_index_byte(source, '/') + 1:]
		link: [256]u8
		if n, lerr := linux.readlink(strings.clone_to_cstring(source, context.temp_allocator), link[:]); lerr == .NONE && n > 0 {
			target := string(link[:n])   // (/dev/mapper/cryptroot -> ../dm-0)
			device = target[strings.last_index_byte(target, '/') + 1:]
		}
		for name in disks_of(fmt.tprintf("/sys/class/block/%s", device), 0) {
			for &d in m.disks {
				if d.name != name { continue }
				point, _ = strings.replace_all(point, "\\040", " ", context.temp_allocator)
				already := false
				for p in d.mounts { if p == point { already = true } }
				if !already { append(&d.mounts, strings.clone(point)) }
			}
		}
	}
	for &d in m.disks { slice.sort(d.mounts[:]) }
}

@(private = "file")
has_option :: proc(options, option: string) -> bool {
	for o in strings.split(options, ",", context.temp_allocator) { if o == option { return true } }
	return false
}

// The disks under a block device of /sys: itself, the disk of a partition, the disks of what a mapped device is made of.
@(private = "file")
disks_of :: proc(sys_path: string, depth: int) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	if depth > 4 { return out[:] }
	link: [4096]u8
	n, err := linux.readlink(strings.clone_to_cstring(sys_path, context.temp_allocator), link[:])
	if err != .NONE || n <= 0 { return out[:] }
	parts := strings.split(string(link[:n]), "/", context.temp_allocator)
	name := parts[len(parts) - 1]
	switch {
	case os.exists(fmt.tprintf("/sys/class/block/%s/partition", name)) && len(parts) >= 2:
		append(&out, strings.clone(parts[len(parts) - 2], context.temp_allocator))
	case os.exists(fmt.tprintf("/sys/block/%s/slaves", name)):
		slaves, _ := os.read_all_directory_by_path(fmt.tprintf("/sys/block/%s/slaves", name), context.temp_allocator)
		for s in slaves { append(&out, ..disks_of(fmt.tprintf("/sys/class/block/%s", s.name), depth + 1)) }
		if len(slaves) == 0 { append(&out, strings.clone(name, context.temp_allocator)) }
	case:
		append(&out, strings.clone(name, context.temp_allocator))
	}
	return out[:]
}

@(private = "file")
disks_sample :: proc(m: ^Machine, text: string, dt: f64) {
	for s in parse_diskstats(text) {
		for &d in m.disks {
			if d.name != s.name { continue }
			if dt > 0 && d.io_ms > 0 {
				d.read_rate = f64(s.sectors_read - min(d.sectors_read, s.sectors_read)) * SECTOR_BYTES / dt
				d.write_rate = f64(s.sectors_written - min(d.sectors_written, s.sectors_written)) * SECTOR_BYTES / dt
				d.active = min(100, f32(f64(s.io_ms - min(d.io_ms, s.io_ms)) / (dt * 10)))
				ui.value_history_push(&d.read_hist, f32(d.read_rate))
				ui.value_history_push(&d.write_hist, f32(d.write_rate))
				ui.value_history_push(&d.active_hist, d.active)
			}
			d.sectors_read, d.sectors_written, d.io_ms = s.sectors_read, s.sectors_written, max(s.io_ms, 1)
		}
	}
}

////////////////////////////////
// Network interfaces

// The interfaces: every one but the loopback and the virtual links of containers and bridges.
@(private = "file")
nets_find :: proc(m: ^Machine) {
	fis, err := os.read_all_directory_by_path("/sys/class/net", context.temp_allocator)
	if err != nil { return }
	slice.sort_by(fis, proc(a, b: os.File_Info) -> bool { return a.name < b.name })
	for fi in fis {
		dir := fmt.tprintf("/sys/class/net/%s", fi.name)
		kind := read_text(fmt.tprintf("%s/type", dir))
		if kind == "772" { continue }   // (the loopback)
		skip := false
		for prefix in ([]string{"veth", "docker", "br-", "virbr"}) { if strings.has_prefix(fi.name, prefix) { skip = true } }
		if skip { continue }
		n := Net{name = strings.clone(fi.name), mac = strings.clone(read_text(fmt.tprintf("%s/address", dir)))}
		switch {
		case os.exists(fmt.tprintf("%s/wireless", dir)) || os.exists(fmt.tprintf("%s/phy80211", dir)): n.kind = "Wi-Fi"
		case kind == "1" && os.exists(fmt.tprintf("%s/device", dir)):                                   n.kind = "Ethernet"
		case kind == "65534":                                                                           n.kind = "Tunnel"
		case:                                                                                            n.kind = "Virtual"
		}
		append(&m.nets, n)
	}
}

@(private = "file")
nets_sample :: proc(m: ^Machine, text: string, dt: f64) {
	for s in parse_net_dev(text) {
		for &n in m.nets {
			if n.name != s.name { continue }
			if dt > 0 && (n.rx > 0 || n.tx > 0) {
				n.rx_rate = f64(s.rx - min(n.rx, s.rx)) / dt
				n.tx_rate = f64(s.tx - min(n.tx, s.tx)) / dt
				ui.value_history_push(&n.rx_hist, f32(n.rx_rate))
				ui.value_history_push(&n.tx_hist, f32(n.tx_rate))
			}
			n.rx, n.tx = max(s.rx, 1), max(s.tx, 1)
		}
	}
}

// What seldom changes: up or down, the link's speed, the addresses (getifaddrs).
@(private = "file")
nets_static :: proc(m: ^Machine) {
	for &n in m.nets {
		dir := fmt.tprintf("/sys/class/net/%s", n.name)
		state := read_text(fmt.tprintf("%s/operstate", dir))
		n.up = state == "up" || state == "unknown"
		n.speed_mbps = max(0, strconv.parse_int(read_text(fmt.tprintf("%s/speed", dir))) or_else 0)
		for a in n.addrs { delete(a) }
		clear(&n.addrs)
	}
	addrs := platform.interface_addresses(context.temp_allocator)
	for family in ([]platform.Address_Family{.IP4, .IP6}) {
		for a in addrs {
			if a.family != family { continue }
			for &n in m.nets {
				if n.name != a.name { continue }
				text: string
				if family == .IP4 {
					text = net.address_to_string(net.IP4_Address{a.addr[0], a.addr[1], a.addr[2], a.addr[3]}, context.temp_allocator)
				} else {
					text = net.address_to_string(net.IP6_Address(transmute([8]u16be)a.addr), context.temp_allocator)
				}
				append(&n.addrs, strings.clone(text))
			}
		}
	}
}

////////////////////////////////
// The files' formats (pure: unit tests read them)

Cpu_Times :: struct {
	total, idle: u64,
	core_total, core_idle: [dynamic]u64,   // temporary allocator
	boot_time:   i64,
}

// /proc/stat: the ticks of all processors and of each (user, nice, system, idle, iowait, irq, softirq, steal; the guest
// time is in the user time already), idle + iowait as idle; the boot time.
parse_cpu_times :: proc(text: string) -> (t: Cpu_Times) {
	t.core_total = make([dynamic]u64, context.temp_allocator)
	t.core_idle = make([dynamic]u64, context.temp_allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(line, "btime ") { t.boot_time = i64(strconv.parse_i64(strings.trim_space(line[6:]), 10) or_else 0); continue }
		if !strings.has_prefix(line, "cpu") { continue }
		total, idle: u64
		fields := line
		_, _ = strings.fields_iterator(&fields)   // (the line's name)
		i := 0
		for word in strings.fields_iterator(&fields) {
			if i >= 8 { break }
			v := u64(strconv.parse_uint(word, 10) or_else 0)
			total += v
			if i == 3 || i == 4 { idle += v }
			i += 1
		}
		if strings.has_prefix(line, "cpu ") {
			t.total, t.idle = total, idle
		} else {
			append(&t.core_total, total)
			append(&t.core_idle, idle)
		}
	}
	return
}

Mem_Fields :: struct {
	total, free, available, buffers, cached, reclaimable, shared, dirty: u64,
	swap_total, swap_free, committed, commit_limit: u64,
}

// /proc/meminfo, in bytes.
parse_meminfo :: proc(text: string) -> (m: Mem_Fields) {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		colon := strings.index_byte(line, ':')
		if colon < 0 { continue }
		v := strings.trim_suffix(strings.trim_space(line[colon + 1:]), " kB")
		bytes := u64(strconv.parse_uint(v, 10) or_else 0) * 1024
		switch line[:colon] {
		case "MemTotal":     m.total = bytes
		case "MemFree":      m.free = bytes
		case "MemAvailable": m.available = bytes
		case "Buffers":      m.buffers = bytes
		case "Cached":       m.cached = bytes
		case "SReclaimable": m.reclaimable = bytes
		case "Shmem":        m.shared = bytes
		case "Dirty":        m.dirty = bytes
		case "SwapTotal":    m.swap_total = bytes
		case "SwapFree":     m.swap_free = bytes
		case "Committed_AS": m.committed = bytes
		case "CommitLimit":  m.commit_limit = bytes
		}
	}
	return
}

parse_loadavg :: proc(text: string) -> (load: [3]f32) {
	rest := text
	i := 0
	for word in strings.fields_iterator(&rest) {
		if i >= 3 { break }
		load[i] = f32(strconv.parse_f64(word) or_else 0)
		i += 1
	}
	return
}

// /proc/cpuinfo: the model, the sockets (physical ids), the cores (physical id and core id), the logical processors.
parse_cpuinfo :: proc(text: string) -> (c: Cpu_Info) {
	sockets := make(map[string]bool, 4, context.temp_allocator)
	cores := make(map[string]bool, 64, context.temp_allocator)
	socket := ""
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		colon := strings.index_byte(line, ':')
		if colon < 0 { continue }
		key, value := strings.trim_space(line[:colon]), strings.trim_space(line[colon + 1:])
		switch key {
		case "processor":   c.logical += 1
		case "model name":  if c.model == "" { c.model = strings.clone(value) }
		case "physical id": socket = value; sockets[strings.clone(value, context.temp_allocator)] = true
		case "core id":     cores[strings.concatenate({socket, "/", value}, context.temp_allocator)] = true
		}
	}
	c.sockets, c.cores = max(len(sockets), 1), len(cores) > 0 ? len(cores) : c.logical
	return
}

// "32K", "512K", "32768K", "1M" (a cache's size in /sys), in bytes.
parse_size_k :: proc(s: string) -> u64 {
	unit: u64 = 1
	v := s
	if strings.has_suffix(v, "K") { unit, v = 1024, v[:len(v) - 1] }
	if strings.has_suffix(v, "M") { unit, v = 1024 * 1024, v[:len(v) - 1] }
	return u64(strconv.parse_uint(v, 10) or_else 0) * unit
}

Disk_Stat :: struct { name: string, sectors_read, sectors_written, io_ms: u64 }

// /proc/diskstats: per device, the sectors read and written and the milliseconds spent doing I/O (in the temporary
// allocator).
parse_diskstats :: proc(text: string) -> []Disk_Stat {
	out := make([dynamic]Disk_Stat, context.temp_allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) < 13 { continue }
		num :: proc(s: string) -> u64 { return u64(strconv.parse_uint(s, 10) or_else 0) }
		append(&out, Disk_Stat{name = f[2], sectors_read = num(f[5]), sectors_written = num(f[9]), io_ms = num(f[12])})
	}
	return out[:]
}

Net_Stat :: struct { name: string, rx, tx: u64 }

// /proc/net/dev: per interface, the bytes received and sent.
parse_net_dev :: proc(text: string) -> []Net_Stat {
	out := make([dynamic]Net_Stat, context.temp_allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		colon := strings.index_byte(line, ':')
		if colon < 0 { continue }
		f := strings.fields(line[colon + 1:], context.temp_allocator)
		if len(f) < 9 { continue }
		append(&out, Net_Stat{name = strings.trim_space(line[:colon]), rx = u64(strconv.parse_uint(f[0], 10) or_else 0), tx = u64(strconv.parse_uint(f[8], 10) or_else 0)})
	}
	return out[:]
}
