package inspecteur

// The machine on Linux: /proc/stat (the processors' times, the boot time), /proc/meminfo, /proc/loadavg, /proc/uptime,
// /proc/sys/fs/file-nr, /proc/diskstats and /proc/net/dev at each sample; the disks from /sys/block and their mounts
// from /proc/self/mountinfo, the interfaces from /sys/class/net and their addresses (getifaddrs) when they are listed;
// the CPU's details from /proc/cpuinfo and /sys/devices/system/cpu.

import "core:fmt"
import "core:net"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "gt:platform"

// A disk's sector, as /proc/diskstats counts them (always 512 bytes, whatever the disk's own).
SECTOR_BYTES :: 512
// The interfaces left out: the loopback (its type), and the virtual links of containers and bridges.
NET_SKIPPED :: [?]string{"veth", "docker", "br-", "virbr"}

Machine_Reader :: struct {
	buf: []u8,
}

machine_reader_init :: proc(r: ^Machine_Reader) { r.buf = make([]u8, PROC_READ_MAX) }
machine_reader_destroy :: proc(r: ^Machine_Reader) { delete(r.buf) }

machine_read :: proc(r: ^Machine_Reader, c: ^Machine_Counters) {
	c.core_total_ns = make([dynamic]u64, context.temp_allocator)
	c.core_idle_ns = make([dynamic]u64, context.temp_allocator)
	c.disks = make([dynamic]Disk_Counters, context.temp_allocator)
	c.nets = make([dynamic]Net_Counters, context.temp_allocator)
	if text, _, ok := read_file(r.buf, linux.AT_FDCWD, "/proc/stat"); ok {
		t := parse_cpu_times(string(text))
		c.cpu_total_ns, c.cpu_idle_ns = t.total * TICK_NS, t.idle * TICK_NS
		for v in t.core_total { append(&c.core_total_ns, v * TICK_NS) }
		for v in t.core_idle { append(&c.core_idle_ns, v * TICK_NS) }
		c.boot_time = t.boot_time
	}
	if text, _, ok := read_file(r.buf, linux.AT_FDCWD, "/proc/meminfo"); ok { c.mem = parse_meminfo(string(text)) }
	if text, _, ok := read_file(r.buf, linux.AT_FDCWD, "/proc/loadavg"); ok { c.load = parse_loadavg(string(text)) }
	if text, _, ok := read_file(r.buf, linux.AT_FDCWD, "/proc/uptime"); ok { c.uptime = strconv.parse_f64(first_field(string(text))) or_else 0 }
	if text, _, ok := read_file(r.buf, linux.AT_FDCWD, "/proc/sys/fs/file-nr"); ok { c.handles = u64(strconv.parse_uint(first_field(string(text)), 10) or_else 0) }
	if text, _, ok := read_file(r.buf, linux.AT_FDCWD, "/proc/diskstats"); ok {
		for s in parse_diskstats(string(text)) {
			append(&c.disks, Disk_Counters{s.name, s.sectors_read * SECTOR_BYTES, s.sectors_written * SECTOR_BYTES, s.io_ms})
		}
	}
	if text, _, ok := read_file(r.buf, linux.AT_FDCWD, "/proc/net/dev"); ok {
		for s in parse_net_dev(string(text)) { append(&c.nets, Net_Counters{s.name, s.rx, s.tx}) }
	}
}

@(private = "file")
first_field :: proc(text: string) -> string {
	t := strings.trim_left_space(text)
	if i := strings.index_any(t, " \t\n"); i >= 0 { return t[:i] }
	return t
}

////////////////////////////////
// The CPU's details

// The model, the topology, the frequencies and the caches (its model in context.allocator).
cpu_info_read :: proc() -> (info: Cpu_Info) {
	data, err := os.read_entire_file("/proc/cpuinfo", context.temp_allocator)
	if err == nil { info = parse_cpuinfo(string(data)) }
	// the frequencies of cpufreq, in kHz: the base when the driver tells it (intel_pstate), the most it may reach
	khz :: proc(path: string) -> f32 { return f32(strconv.parse_f64(read_text(path)) or_else 0) / 1000 }
	info.base_mhz = khz("/sys/devices/system/cpu/cpu0/cpufreq/base_frequency")
	info.max_mhz = khz("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq")
	// the caches: each copy once (a cache shared by several processors lists them all in shared_cpu_list)
	seen := make(map[string]bool, 64, context.temp_allocator)
	for cpu in 0 ..< info.logical {
		for index in 0 ..< 8 {
			dir := fmt.tprintf("/sys/devices/system/cpu/cpu%d/cache/index%d", cpu, index)
			level := strconv.parse_int(read_text(fmt.tprintf("%s/level", dir))) or_else 0
			if level < 1 || level > 4 { break }
			key := fmt.tprintf("%d %s %s", level, read_text(fmt.tprintf("%s/type", dir)), read_text(fmt.tprintf("%s/shared_cpu_list", dir)))
			if key in seen { continue }
			seen[key] = true
			info.cache[level - 1] += parse_size_k(read_text(fmt.tprintf("%s/size", dir)))
		}
	}
	return
}

// The processors' mean frequency now, in MHz (cpufreq's scaling_cur_freq; 0 without cpufreq).
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
disks_list :: proc(out: ^[dynamic]Disk_Info) {
	fis, err := os.read_all_directory_by_path("/sys/block", context.temp_allocator)
	if err != nil { return }
	slice.sort_by(fis, proc(a, b: os.File_Info) -> bool { return a.name < b.name })
	mounts := mounts_by_disk()
	for fi in fis {
		dir := fmt.tprintf("/sys/block/%s", fi.name)
		if !os.exists(fmt.tprintf("%s/device", dir)) { continue }
		sectors := u64(strconv.parse_uint(read_text(fmt.tprintf("%s/size", dir)), 10) or_else 0)
		if sectors == 0 { continue }
		d := Disk_Info{name = strings.clone(fi.name, context.temp_allocator), model = read_text(fmt.tprintf("%s/device/model", dir)), capacity = sectors * SECTOR_BYTES}
		switch {
		case read_text(fmt.tprintf("%s/removable", dir)) == "1":       d.kind = "Removable"
		case strings.has_prefix(fi.name, "nvme"):                        d.kind = "NVMe SSD"
		case read_text(fmt.tprintf("%s/queue/rotational", dir)) == "1": d.kind = "HDD"
		case:                                                             d.kind = "SSD"
		}
		if list, ok := mounts[d.name]; ok {
			slice.sort(list[:])
			d.mounts = list[:]
		}
		append(out, d)
	}
}

// Each disk's mounts, from /proc/self/mountinfo: a file system's device leads to its disk through its partition or the
// devices it is mapped on (LUKS, LVM). A bind mount of a part of a file system is left out: the file system's own mount
// (its root, or a btrfs subvolume's) says where it is.
@(private = "file")
mounts_by_disk :: proc() -> map[string][dynamic]string {
	out := make(map[string][dynamic]string, 8, context.temp_allocator)
	data, err := os.read_entire_file("/proc/self/mountinfo", context.temp_allocator)
	if err != nil { return out }
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		m, ok := parse_mountinfo_line(line)
		if !ok || !strings.has_prefix(m.device, "/dev/") { continue }   // (no device: tmpfs, proc...)
		// (the source, not the device number: btrfs gives its mounts numbers of no device)
		if m.root != "/" && !has_option(m.options, strings.concatenate({"subvol=", m.root}, context.temp_allocator)) { continue }
		device := m.device[strings.last_index_byte(m.device, '/') + 1:]
		link: [256]u8
		if n, lerr := linux.readlink(strings.clone_to_cstring(m.device, context.temp_allocator), link[:]); lerr == .NONE && n > 0 {
			target := string(link[:n])   // (/dev/mapper/cryptroot -> ../dm-0)
			device = strings.clone(target[strings.last_index_byte(target, '/') + 1:], context.temp_allocator)
		}
		for name in disks_of(fmt.tprintf("/sys/class/block/%s", device), 0) {
			list := out[name] or_else make([dynamic]string, context.temp_allocator)
			already := false
			for p in list { if p == m.mount { already = true } }
			if !already { append(&list, m.mount) }
			out[name] = list
		}
	}
	return out
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
	parts := strings.split(strings.clone(string(link[:n]), context.temp_allocator), "/", context.temp_allocator)
	name := parts[len(parts) - 1]
	switch {
	case os.exists(fmt.tprintf("/sys/class/block/%s/partition", name)) && len(parts) >= 2:
		append(&out, parts[len(parts) - 2])
	case os.exists(fmt.tprintf("/sys/block/%s/slaves", name)):
		slaves, _ := os.read_all_directory_by_path(fmt.tprintf("/sys/block/%s/slaves", name), context.temp_allocator)
		for s in slaves { append(&out, ..disks_of(fmt.tprintf("/sys/class/block/%s", s.name), depth + 1)) }
		if len(slaves) == 0 { append(&out, name) }
	case:
		append(&out, name)
	}
	return out[:]
}

////////////////////////////////
// Network interfaces

// The interfaces: every one but the loopback and the virtual links of containers and bridges, with what seldom changes:
// up or down, the link's speed, the addresses.
nets_list :: proc(out: ^[dynamic]Net_Info) {
	fis, err := os.read_all_directory_by_path("/sys/class/net", context.temp_allocator)
	if err != nil { return }
	slice.sort_by(fis, proc(a, b: os.File_Info) -> bool { return a.name < b.name })
	addrs := platform.interface_addresses(context.temp_allocator)
	for fi in fis {
		dir := fmt.tprintf("/sys/class/net/%s", fi.name)
		kind := read_text(fmt.tprintf("%s/type", dir))
		if kind == "772" { continue }   // (the loopback)
		skip := false
		for prefix in NET_SKIPPED { if strings.has_prefix(fi.name, prefix) { skip = true } }
		if skip { continue }
		n := Net_Info{name = strings.clone(fi.name, context.temp_allocator), mac = read_text(fmt.tprintf("%s/address", dir))}
		switch {
		case os.exists(fmt.tprintf("%s/wireless", dir)) || os.exists(fmt.tprintf("%s/phy80211", dir)): n.kind = "Wi-Fi"
		case kind == "1" && os.exists(fmt.tprintf("%s/device", dir)):                                   n.kind = "Ethernet"
		case kind == "65534":                                                                           n.kind = "Tunnel"
		case:                                                                                            n.kind = "Virtual"
		}
		state := read_text(fmt.tprintf("%s/operstate", dir))
		n.up = state == "up" || state == "unknown"
		n.speed_mbps = max(0, strconv.parse_int(read_text(fmt.tprintf("%s/speed", dir))) or_else 0)
		list := make([dynamic]string, context.temp_allocator)
		for family in ([]platform.Address_Family{.IP4, .IP6}) {
			for a in addrs {
				if a.family != family || a.name != n.name { continue }
				if family == .IP4 {
					append(&list, net.address_to_string(net.IP4_Address{a.addr[0], a.addr[1], a.addr[2], a.addr[3]}, context.temp_allocator))
				} else {
					append(&list, net.address_to_string(net.IP6_Address(transmute([8]u16be)a.addr), context.temp_allocator))
				}
			}
		}
		n.addrs = list[:]
		append(out, n)
	}
}

////////////////////////////////
// The files' formats (pure: unit tests read them)

Cpu_Times :: struct {
	total, idle: u64,   // clock ticks
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

Mount_Line :: struct { mount, kind, device, root, options: string }

// A line of /proc/self/mountinfo: "36 35 98:0 /mnt1 /mnt/parent rw,noatime master:1 - ext3 /dev/root rw,errors=continue".
// The root and the mount point are the fourth and fifth fields (escaped: mount_unescape); after " - ": the type, the
// device and the file system's options.
parse_mountinfo_line :: proc(line: string) -> (m: Mount_Line, ok: bool) {
	dash := strings.index(line, " - ")
	if dash < 0 { return }
	head := strings.fields(line[:dash], context.temp_allocator)
	tail := strings.fields(line[dash + 3:], context.temp_allocator)
	if len(head) < 5 || len(tail) < 2 { return }
	return {mount = mount_unescape(head[4]), root = mount_unescape(head[3]), kind = tail[0], device = mount_unescape(tail[1]), options = len(tail) > 2 ? tail[2] : ""}, true
}

// A path as the kernel writes it in mountinfo: a space, a tab, a newline and a backslash are "\040", "\011", "\012" and
// "\134" (octal) (temporary allocator).
mount_unescape :: proc(s: string) -> string {
	if strings.index_byte(s, '\\') < 0 { return s }
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 4 <= len(s) {
			v, ok := strconv.parse_uint(s[i + 1:i + 4], 8)
			if ok && v < 256 {
				strings.write_byte(&b, u8(v))
				i += 3
				continue
			}
		}
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
}

// The file systems that hold files on a disk (or a network's); not the kernel's own (proc, sysfs, tmpfs...).
storage_kind :: proc(kind: string) -> bool {
	switch kind {
	case "ext2", "ext3", "ext4", "btrfs", "xfs", "zfs", "f2fs", "vfat", "exfat", "ntfs", "ntfs3", "fuseblk", "bcachefs", "jfs", "reiserfs", "nfs", "nfs4", "cifs", "smb3", "iso9660", "udf":
		return true
	}
	return false
}
