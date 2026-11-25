package inspecteur

// The machine on Linux: /proc/stat (the processors' times, the boot time), /proc/meminfo, /proc/loadavg, /proc/uptime,
// /proc/sys/fs/file-nr, /proc/diskstats and /proc/net/dev at each sample; the disks from /sys/block and their mounts
// from /proc/self/mountinfo, the interfaces from /sys/class/net and their addresses (getifaddrs) when they are listed;
// the CPU's details from /proc/cpuinfo and /sys/devices/system/cpu; the processor's temperatures from its hwmon driver
// (k10temp, zenpower, coretemp), what waits on the CPU, the memory and the disks from /proc/pressure.
//
// Fixed /proc and /sys files stay open across samples: small single-record files use pread at offset 0, while
// potentially multi-page seq_files (/proc/stat, /proc/diskstats, /proc/net/dev) use lseek(0) + read loop.

import "core:fmt"
import "core:net"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "gt:platform"
import i18n "gt:i18n"

// A disk's sector, as /proc/diskstats counts them (always 512 bytes, whatever the disk's own).
SECTOR_BYTES :: 512
// The interfaces left out: the loopback (its type), and the virtual links of containers and bridges.
NET_SKIPPED :: [?]string{"veth", "docker", "br-", "virbr"}

// The hwmon drivers of a processor's sensors, and the labels of its package's temperature, the first shown.
CPU_HWMON := [?]string{"k10temp", "zenpower", "coretemp", "cpu_thermal", "soc_thermal"}
PACKAGE_LABELS := [?]string{"Tdie", "Tctl", "Package id 0"}

Machine_Reader :: struct {
	buf:          []u8,
	fds_init:     bool,
	stat_fd:      linux.Fd,
	meminfo_fd:   linux.Fd,
	loadavg_fd:   linux.Fd,
	uptime_fd:    linux.Fd,
	filenr_fd:    linux.Fd,
	diskstats_fd: linux.Fd,
	netdev_fd:    linux.Fd,
	pressure_fds: [Pressure_Kind]linux.Fd,
	pm_fd:        linux.Fd,
	throttle_fd:  linux.Fd,
	temps_listed: bool,
	temp_files:   [TEMPS_MAX]Temp_File,      // the package's first
	temp_n:       int,
	// the cores' temperatures, by core_id: coretemp's "Core <id>" files (Intel), else ryzen_smu's power table (AMD)
	core_files:   [CORES_TOLD_MAX]Temp_File, // path_len 0: none for that core
	core_file_n:  int,
	pm:           Pm_Table,                  // cores 0: no table read
	pm_failures:  int,                       // reads of the table that failed in a row
	core_of:      [dynamic]i32,              // each logical processor's core_id (-1: not told)
	no_throttle, no_pressure: bool,          // the files are not there: not looked for again
}

// The core_ids a temperature is kept for.
CORES_TOLD_MAX :: 64

// ryzen_smu (github.com/amkillam/ryzen_smu, a driver of its own): the SMU's power table of AMD's processors, the
// temperature of each core in it. Without the driver, or with a version of the table not known here, no core has one.
RYZEN_SMU :: "/sys/kernel/ryzen_smu_drv"

// Where a version of the power table holds its cores' temperatures: the index of the first (32-bit floats, one per
// core in a row) and how many cores it has room for. From ryzen_monitor_ng (src/pm_tables.c).
Pm_Table :: struct { version: u32, first, cores: int }

@(rodata)
PM_TABLES := [?]Pm_Table{
	{0x1E0004, 108, 4},    // Zen (Raven Ridge)
	{0x240803, 179, 16},   // Zen 2 (Matisse, two CCDs)
	{0x240903, 163, 8},    // Zen 2 (Matisse)
	{0x370003, 208, 8},    // Zen 2 (Renoir)
	{0x370005, 208, 8},
	{0x380804, 201, 16},   // Zen 3 (Vermeer)
	{0x380805, 204, 16},
	{0x380904, 185, 8},
	{0x380905, 188, 8},
	{0x400005, 216, 8},    // Zen 3 (Cezanne)
}

// After so many failed reads in a row, the table is not read again (the driver loaded, its SMU not answering).
@(private = "file") PM_FAILURES_MAX :: 5

// A temperature's file (temp<n>_input, millidegrees), its kept descriptor, and its label.
@(private = "file")
Temp_File :: struct { path: [64]u8, path_len: int, label: [24]u8, label_len: int, fd: linux.Fd }

@(private = "file")
machine_fds_reset :: proc(r: ^Machine_Reader) {
	r.fds_init = true
	r.stat_fd, r.meminfo_fd, r.loadavg_fd, r.uptime_fd, r.filenr_fd = -1, -1, -1, -1, -1
	r.diskstats_fd, r.netdev_fd, r.pm_fd, r.throttle_fd = -1, -1, -1, -1
	for k in Pressure_Kind { r.pressure_fds[k] = -1 }
	for &f in r.temp_files { f.fd = -1 }
	for &f in r.core_files { f.fd = -1 }
}

machine_reader_init :: proc(r: ^Machine_Reader) {
	r.buf = make([]u8, PROC_READ_MAX)
	machine_fds_reset(r)
}

@(private = "file")
close_fd :: proc(fd: ^linux.Fd) {
	if fd^ >= 0 { linux.close(fd^); fd^ = -1 }
}

machine_reader_destroy :: proc(r: ^Machine_Reader) {
	if r.fds_init {
		close_fd(&r.stat_fd)
		close_fd(&r.meminfo_fd)
		close_fd(&r.loadavg_fd)
		close_fd(&r.uptime_fd)
		close_fd(&r.filenr_fd)
		close_fd(&r.diskstats_fd)
		close_fd(&r.netdev_fd)
		close_fd(&r.pm_fd)
		close_fd(&r.throttle_fd)
		for k in Pressure_Kind { close_fd(&r.pressure_fds[k]) }
		for &f in r.temp_files[:r.temp_n] { close_fd(&f.fd) }
		for &f in r.core_files { close_fd(&f.fd) }
	}
	delete(r.buf)
	delete(r.core_of)
	r^ = {}
}

// Reads a kept multi-page seq_file from offset 0 with lseek + read loop (opens lazily on first call).
@(private = "file")
read_kept_seq :: proc(fd: ^linux.Fd, path: cstring, buf: []u8) -> (data: []u8, ok: bool) {
	for _ in 0 ..< 2 {
		if fd^ < 0 {
			f, err := linux.open(path, {.CLOEXEC})
			if err != .NONE { return nil, false }
			fd^ = f
		}
		if _, lerr := linux.lseek(fd^, 0, .SET); lerr == .NONE {
			n := 0
			good := true
			for n < len(buf) {
				k, re := linux.read(fd^, buf[n:])
				if re != .NONE { good = false; break }
				if k <= 0 { break }
				n += k
			}
			if good { return buf[:n], true }
		}
		close_fd(fd)
	}
	return nil, false
}

// Reads a kept small single-record procfs/sysfs file with pread at offset 0 (falls back to loop if near one page).
@(private = "file")
read_kept_small :: proc(fd: ^linux.Fd, path: cstring, buf: []u8) -> (data: []u8, ok: bool) {
	for _ in 0 ..< 2 {
		if fd^ < 0 {
			f, err := linux.open(path, {.CLOEXEC})
			if err != .NONE { return nil, false }
			fd^ = f
		}
		k, re := linux.pread(fd^, buf, 0)
		if re == .NONE && k >= 0 {
			n := k
			if n >= PROC_ONE_READ_CAP {
				good := true
				for n < len(buf) {
					m, e := linux.pread(fd^, buf[n:], i64(n))
					if e != .NONE { good = false; break }
					if m <= 0 { break }
					n += m
				}
				if !good { close_fd(fd); continue }
			}
			return buf[:n], true
		}
		close_fd(fd)
	}
	return nil, false
}

@(private = "file")
temp_file_read :: proc(f: ^Temp_File, buf: []u8) -> (celsius: f32, ok: bool) {
	if f.path_len == 0 || f.path_len >= len(f.path) { return 0, false }
	f.path[f.path_len] = 0
	data, rok := read_kept_small(&f.fd, cstring(&f.path[0]), buf)
	if !rok || len(data) == 0 { return 0, false }
	pos := 0
	w, has := next_token(string(data), &pos)
	if !has { return 0, false }
	if v, pok := parse_ascii_i64(w); pok { return f32(v) / 1000, true }
	v, fok := strconv.parse_f64(w)
	return f32(v / 1000), fok
}

machine_read :: proc(r: ^Machine_Reader, c: ^Machine_Counters) {
	if !r.fds_init { machine_fds_reset(r) }
	if r.buf == nil { r.buf = make([]u8, PROC_READ_MAX) }
	c.core_total_ns = make([dynamic]u64, 0, 32, context.temp_allocator)
	c.core_idle_ns = make([dynamic]u64, 0, 32, context.temp_allocator)
	c.disks = make([dynamic]Disk_Counters, 0, 16, context.temp_allocator)
	c.nets = make([dynamic]Net_Counters, 0, 8, context.temp_allocator)

	if text, ok := read_kept_seq(&r.stat_fd, "/proc/stat", r.buf); ok {
		parse_cpu_times_into(string(text), c)
	}
	if text, ok := read_kept_small(&r.meminfo_fd, "/proc/meminfo", r.buf); ok {
		c.mem = parse_meminfo(string(text))
	}
	if text, ok := read_kept_small(&r.loadavg_fd, "/proc/loadavg", r.buf); ok { c.load = parse_loadavg(string(text)) }
	if text, ok := read_kept_small(&r.filenr_fd, "/proc/sys/fs/file-nr", r.buf); ok {
		pos := 0
		if w, has := next_token(string(text), &pos); has { c.handles, _ = parse_ascii_u64(w) }
	}
	if text, ok := read_kept_small(&r.uptime_fd, "/proc/uptime", r.buf); ok {
		pos := 0
		if w, has := next_token(string(text), &pos); has { c.uptime = strconv.parse_f64(w) or_else 0 }
	}
	if text, ok := read_kept_seq(&r.diskstats_fd, "/proc/diskstats", r.buf); ok {
		parse_diskstats_into(string(text), &c.disks)
	}
	if text, ok := read_kept_seq(&r.netdev_fd, "/proc/net/dev", r.buf); ok {
		parse_net_dev_into(string(text), &c.nets)
	}
	sensors_read(r, c)
}

// The processor's temperatures, the pressure, the times it slowed for its heat: kept descriptors, zero-alloc parsing.
@(private = "file")
sensors_read :: proc(r: ^Machine_Reader, c: ^Machine_Counters) {
	if !r.temps_listed { temps_list(r) }
	for &f in r.temp_files[:r.temp_n] {
		v, ok := temp_file_read(&f, r.buf[:256])
		if !ok { continue }
		t := &c.temps[c.temp_count]
		t.label_len = copy(t.label[:], f.label[:f.label_len])
		t.celsius = v
		c.temp_count += 1
	}
	core_temps_read(r, c)
	if !r.no_pressure {
		names := [Pressure_Kind]cstring{.Cpu = "/proc/pressure/cpu", .Memory = "/proc/pressure/memory", .Io = "/proc/pressure/io"}
		for path, k in names {
			text, ok := read_kept_small(&r.pressure_fds[k], path, r.buf[:1024])
			if !ok { r.no_pressure = true; break }
			c.pressure[k] = parse_pressure(string(text))
		}
		c.has_pressure = !r.no_pressure
	}
	// (Intel's count of the package's slowdowns; AMD's processors tell none)
	if !r.no_throttle {
		data, ok := read_kept_small(&r.throttle_fd, "/sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_count", r.buf[:256])
		if !ok || len(data) == 0 {
			r.no_throttle = true
		} else {
			pos := 0
			if w, has := next_token(string(data), &pos); has { c.throttled, _ = parse_ascii_u64(w) }
		}
	}
}

// The temperatures of the processor's hwmon drivers, once: the package's first.
@(private = "file")
temps_list :: proc(r: ^Machine_Reader) {
	r.temps_listed = true
	for dir in list_dir("/sys/class/hwmon") {
		base := fmt.tprintf("/sys/class/hwmon/%s", dir)
		name := read_text(fmt.tprintf("%s/name", base))
		cpu := false
		for n in CPU_HWMON { if n == name { cpu = true } }
		if !cpu { continue }
		for i in 1 ..= TEMPS_MAX {
			if r.temp_n >= TEMPS_MAX { break }
			input := fmt.tprintf("%s/temp%d_input", base, i)
			if !os.exists(input) { continue }
			label := read_text(fmt.tprintf("%s/temp%d_label", base, i))
			if label == "" { label = fmt.tprintf("%s %d", name, i) }
			// (a core's: by its core_id, shown with its logical processors, not in the list)
			if id, is_core := core_label_id(label); is_core {
				if id < CORES_TOLD_MAX && r.core_files[id].path_len == 0 {
					r.core_files[id].path_len = copy(r.core_files[id].path[:len(r.core_files[id].path) - 1], input)
					r.core_files[id].fd = -1
					r.core_file_n += 1
				}
				continue
			}
			f := &r.temp_files[r.temp_n]
			f.path_len = copy(f.path[:len(f.path) - 1], input)
			f.label_len = copy(f.label[:], label)
			f.fd = -1
			r.temp_n += 1
		}
	}
	if r.core_file_n == 0 { pm_table_find(r) }
	// the package's first: the first of PACKAGE_LABELS found
	for want in PACKAGE_LABELS {
		for i in 0 ..< r.temp_n {
			if string(r.temp_files[i].label[:r.temp_files[i].label_len]) != want { continue }
			r.temp_files[0], r.temp_files[i] = r.temp_files[i], r.temp_files[0]
			return
		}
	}
}

// "Core 3" (coretemp's label of a core): 3.
core_label_id :: proc(label: string) -> (int, bool) {
	if !strings.has_prefix(label, "Core ") { return 0, false }
	id, ok := strconv.parse_int(label[len("Core "):], 10)
	return id, ok && id >= 0
}

// Each logical processor's core's temperature, when a source tells them; else none (no message: most machines have
// no such sensor). The sources are looked for once, with the package's sensors.
@(private = "file")
core_temps_read :: proc(r: ^Machine_Reader, c: ^Machine_Counters) {
	n := len(c.core_total_ns)
	if r.core_file_n == 0 && r.pm.cores == 0 { return }
	if len(r.core_of) != n { core_ids_list(r, n) }
	celsius: [CORES_TOLD_MAX]f32
	if r.core_file_n > 0 {
		for &f, id in r.core_files {
			if f.path_len == 0 { continue }
			if v, ok := temp_file_read(&f, r.buf[:256]); ok { celsius[id] = v }
		}
	} else {
		data, ok := read_kept_small(&r.pm_fd, RYZEN_SMU + "/pm_table", r.buf)
		if !ok || len(data) < (r.pm.first + r.pm.cores) * 4 {
			r.pm_failures += 1
			if r.pm_failures >= PM_FAILURES_MAX { r.pm = {}; close_fd(&r.pm_fd) }
			return
		}
		r.pm_failures = 0
		for k in 0 ..< min(r.pm.cores, CORES_TOLD_MAX) {
			o := (r.pm.first + k) * 4
			celsius[k] = transmute(f32)(u32(data[o]) | u32(data[o + 1]) << 8 | u32(data[o + 2]) << 16 | u32(data[o + 3]) << 24)
		}
	}
	c.core_celsius = make([dynamic]f32, n, context.temp_allocator)
	for id, i in r.core_of {
		if id < 0 || id >= CORES_TOLD_MAX { continue }
		v := celsius[id]
		// (a core switched off, or a slot of the table no core fills: nothing, or a value no core reaches)
		if v > 1 && v < 150 { c.core_celsius[i] = v }
	}
}

// Each logical processor's core_id (the topology's), -1 where it is not told.
@(private = "file")
core_ids_list :: proc(r: ^Machine_Reader, n: int) {
	resize(&r.core_of, n)
	for i in 0 ..< n {
		id, ok := strconv.parse_int(read_text(fmt.tprintf("/sys/devices/system/cpu/cpu%d/topology/core_id", i)), 10)
		r.core_of[i] = ok ? i32(id) : -1
	}
}

// The power table of ryzen_smu, when the driver is there and its version is known here.
@(private = "file")
pm_table_find :: proc(r: ^Machine_Reader) {
	buf: [8]u8
	data, _, ok := read_file(buf[:], linux.AT_FDCWD, RYZEN_SMU + "/pm_table_version")
	if !ok || len(data) < 4 { return }
	version := u32(data[0]) | u32(data[1]) << 8 | u32(data[2]) << 16 | u32(data[3]) << 24
	for t in PM_TABLES { if t.version == version { r.pm = t; return } }
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

// The processors' mean frequency now, in MHz, and each one's in `cores` (cpufreq's scaling_cur_freq; 0 without cpufreq).
cpu_mhz_now :: proc(cores: []f32) -> f32 {
	sum: f64
	n := 0
	for &mhz, cpu in cores {
		v, ok := strconv.parse_f64(read_text(fmt.tprintf("/sys/devices/system/cpu/cpu%d/cpufreq/scaling_cur_freq", cpu)))
		mhz = ok ? f32(v / 1000) : 0
		if ok { sum += v; n += 1 }
	}
	return n > 0 ? f32(sum / f64(n) / 1000) : 0
}

// A file of /proc/pressure: "some avg10=0.23 avg60=1.59 avg300=1.89 total=..." and the same for "full".
parse_pressure :: proc(text: string) -> (p: Pressure) {
	avg :: proc(field, key: string) -> f32 {
		if !strings.has_prefix(field, key) { return 0 }
		return f32(strconv.parse_f64(field[len(key):]) or_else 0)
	}
	i := 0
	n := len(text)
	for i < n {
		start := i
		for i < n && text[i] != '\n' { i += 1 }
		line := text[start:i]
		if i < n { i += 1 }
		pos := 0
		f0, ok0 := next_token(line, &pos)
		f1, ok1 := next_token(line, &pos)
		f2, ok2 := next_token(line, &pos)
		if !ok0 || !ok1 || !ok2 { continue }
		switch f0 {
		case "some": p.some10, p.some60 = avg(f1, "avg10="), avg(f2, "avg60=")
		case "full": p.full10, p.full60 = avg(f1, "avg10="), avg(f2, "avg60=")
		}
	}
	return
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
		case read_text(fmt.tprintf("%s/removable", dir)) == "1":       d.kind = i18n.later("Removable")
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
		case kind == "65534":                                                                           n.kind = i18n.later("Tunnel")
		case:                                                                                            n.kind = i18n.later("Virtual")
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

// Parses /proc/stat directly into Machine_Counters without intermediate core slices.
@(private = "file")
parse_cpu_times_into :: proc(text: string, c: ^Machine_Counters) {
	i := 0
	n := len(text)
	for i < n {
		start := i
		for i < n && text[i] != '\n' { i += 1 }
		line := text[start:i]
		if i < n { i += 1 }
		if len(line) < 4 { continue }
		if line[0] == 'b' && strings.has_prefix(line, "btime ") {
			pos := 6
			if w, ok := next_token(line, &pos); ok { v, _ := parse_ascii_i64(w); c.boot_time = v }
			continue
		}
		if line[0] != 'c' || line[1] != 'p' || line[2] != 'u' { continue }
		pos := 3
		whole := line[3] == ' '
		if !whole { for pos < len(line) && !is_ascii_space(line[pos]) { pos += 1 } }
		total, idle: u64
		for field in 0 ..< 8 {
			w, ok := next_token(line, &pos)
			if !ok { break }
			v, _ := parse_ascii_u64(w)
			total += v
			if field == 3 || field == 4 { idle += v }
		}
		if whole {
			c.cpu_total_ns, c.cpu_idle_ns = total * TICK_NS, idle * TICK_NS
		} else {
			append(&c.core_total_ns, total * TICK_NS)
			append(&c.core_idle_ns, idle * TICK_NS)
		}
	}
}

// /proc/stat: the ticks of all processors and of each (user, nice, system, idle, iowait, irq, softirq, steal; the guest
// time is in the user time already), idle + iowait as idle; the boot time.
parse_cpu_times :: proc(text: string) -> (t: Cpu_Times) {
	t.core_total = make([dynamic]u64, 0, 32, context.temp_allocator)
	t.core_idle = make([dynamic]u64, 0, 32, context.temp_allocator)
	i := 0
	n := len(text)
	for i < n {
		start := i
		for i < n && text[i] != '\n' { i += 1 }
		line := text[start:i]
		if i < n { i += 1 }
		if len(line) < 4 { continue }
		if line[0] == 'b' && strings.has_prefix(line, "btime ") {
			pos := 6
			if w, ok := next_token(line, &pos); ok { v, _ := parse_ascii_i64(w); t.boot_time = v }
			continue
		}
		if line[0] != 'c' || line[1] != 'p' || line[2] != 'u' { continue }
		pos := 3
		whole := line[3] == ' '
		if !whole { for pos < len(line) && !is_ascii_space(line[pos]) { pos += 1 } }
		total, idle: u64
		for field in 0 ..< 8 {
			w, ok := next_token(line, &pos)
			if !ok { break }
			v, _ := parse_ascii_u64(w)
			total += v
			if field == 3 || field == 4 { idle += v }
		}
		if whole {
			t.total, t.idle = total, idle
		} else {
			append(&t.core_total, total)
			append(&t.core_idle, idle)
		}
	}
	return
}

// /proc/meminfo, in bytes. Only keys Inspecteur displays are parsed into integers.
parse_meminfo :: proc(text: string) -> (m: Mem_Fields) {
	val :: proc(line: string, after_colon: int) -> u64 {
		pos := after_colon
		if w, ok := next_token(line, &pos); ok { v, _ := parse_ascii_u64(w); return v * 1024 }
		return 0
	}
	i := 0
	n := len(text)
	for i < n {
		start := i
		for i < n && text[i] != '\n' { i += 1 }
		line := text[start:i]
		if i < n { i += 1 }
		colon := strings.index_byte(line, ':')
		if colon < 0 { continue }
		switch line[:colon] {
		case "MemTotal":     m.total = val(line, colon + 1)
		case "MemFree":      m.free = val(line, colon + 1)
		case "MemAvailable": m.available = val(line, colon + 1)
		case "Buffers":      m.buffers = val(line, colon + 1)
		case "Cached":       m.cached = val(line, colon + 1)
		case "SReclaimable": m.reclaimable = val(line, colon + 1)
		case "Shmem":        m.shared = val(line, colon + 1)
		case "Dirty":        m.dirty = val(line, colon + 1)
		case "SwapTotal":    m.swap_total = val(line, colon + 1)
		case "SwapFree":     m.swap_free = val(line, colon + 1)
		case "Committed_AS": m.committed = val(line, colon + 1)
		case "CommitLimit":  m.commit_limit = val(line, colon + 1)
		}
	}
	return
}

parse_loadavg :: proc(text: string) -> (load: [3]f32) {
	pos := 0
	for i in 0 ..< 3 {
		w, ok := next_token(text, &pos)
		if !ok { break }
		load[i] = f32(strconv.parse_f64(w) or_else 0)
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

@(private = "file")
parse_diskstats_into :: proc(text: string, out: ^[dynamic]Disk_Counters) {
	i := 0
	n := len(text)
	for i < n {
		start := i
		for i < n && text[i] != '\n' { i += 1 }
		line := text[start:i]
		if i < n { i += 1 }
		pos := 0
		name: string
		s_read, s_write, io_ms: u64
		count := 0
		for count < 13 {
			w, ok := next_token(line, &pos)
			if !ok { break }
			switch count {
			case 2:  name = w
			case 5:  s_read, _ = parse_ascii_u64(w)
			case 9:  s_write, _ = parse_ascii_u64(w)
			case 12: io_ms, _ = parse_ascii_u64(w)
			}
			count += 1
		}
		if count < 13 { continue }
		append(out, Disk_Counters{name = strings.clone(name, context.temp_allocator), read_bytes = s_read * SECTOR_BYTES, written_bytes = s_write * SECTOR_BYTES, busy_ms = io_ms})
	}
}

// /proc/diskstats: per device, the sectors read and written and the milliseconds spent doing I/O (in the temporary
// allocator).
parse_diskstats :: proc(text: string) -> []Disk_Stat {
	out := make([dynamic]Disk_Stat, 0, 16, context.temp_allocator)
	i := 0
	n := len(text)
	for i < n {
		start := i
		for i < n && text[i] != '\n' { i += 1 }
		line := text[start:i]
		if i < n { i += 1 }
		pos := 0
		d: Disk_Stat
		count := 0
		for count < 13 {
			w, ok := next_token(line, &pos)
			if !ok { break }
			switch count {
			case 2:  d.name = w
			case 5:  d.sectors_read, _ = parse_ascii_u64(w)
			case 9:  d.sectors_written, _ = parse_ascii_u64(w)
			case 12: d.io_ms, _ = parse_ascii_u64(w)
			}
			count += 1
		}
		if count < 13 { continue }
		append(&out, d)
	}
	return out[:]
}

Net_Stat :: struct { name: string, rx, tx: u64 }

@(private = "file")
parse_net_dev_into :: proc(text: string, out: ^[dynamic]Net_Counters) {
	i := 0
	n := len(text)
	for i < n {
		start := i
		for i < n && text[i] != '\n' { i += 1 }
		line := text[start:i]
		if i < n { i += 1 }
		colon := strings.index_byte(line, ':')
		if colon < 0 { continue }
		pos := colon + 1
		rx, tx: u64
		count := 0
		for count < 9 {
			w, ok := next_token(line, &pos)
			if !ok { break }
			if count == 0 { rx, _ = parse_ascii_u64(w) } else if count == 8 { tx, _ = parse_ascii_u64(w) }
			count += 1
		}
		if count < 9 { continue }
		append(out, Net_Counters{name = strings.clone(strings.trim_space(line[:colon]), context.temp_allocator), rx = rx, tx = tx})
	}
}

// /proc/net/dev: per interface, the bytes received and sent.
parse_net_dev :: proc(text: string) -> []Net_Stat {
	out := make([dynamic]Net_Stat, 0, 8, context.temp_allocator)
	i := 0
	n := len(text)
	for i < n {
		start := i
		for i < n && text[i] != '\n' { i += 1 }
		line := text[start:i]
		if i < n { i += 1 }
		colon := strings.index_byte(line, ':')
		if colon < 0 { continue }
		pos := colon + 1
		rx, tx: u64
		count := 0
		for count < 9 {
			w, ok := next_token(line, &pos)
			if !ok { break }
			if count == 0 { rx, _ = parse_ascii_u64(w) } else if count == 8 { tx, _ = parse_ascii_u64(w) }
			count += 1
		}
		if count < 9 { continue }
		append(&out, Net_Stat{name = strings.trim_space(line[:colon]), rx = rx, tx = tx})
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
