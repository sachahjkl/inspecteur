package inspecteur

// The machine as a whole, for the Performance section: the CPU (all of it and each logical processor), the memory, each
// disk, each network interface (the GPUs: gpu.odin). A sample takes the system's counters (machine_linux.odin:
// machine_read) and makes rates of them, and keeps the last HISTORY_POINTS values of each graph whatever section is
// shown: the graphs are full when it is opened.
//
// The disks and the interfaces are listed again every DEVICES_EVERY samples (disks_list, nets_list): one plugged in
// since comes, one taken away goes, and those that stay keep their history. The CPU's details are read the first time
// the Performance section shows the CPU.

import "core:slice"
import "core:strings"
import "gt:ui"

// The points of a graph: one per sample (60 s at the default period).
HISTORY_POINTS :: 60
// Samples between two lists of the disks and the interfaces (and their addresses, their speed, whether they are up).
DEVICES_EVERY :: 10

// The last HISTORY_POINTS values of a graph (the toolkit's ring).
History :: ui.Value_History(HISTORY_POINTS)

Cpu_Info :: struct {
	model:            string,   // owned
	sockets, cores, logical: int,
	base_mhz, max_mhz: f32,     // 0: not told by the system
	cache:            [4]u64,   // bytes of each level, all of its copies (L1: data and instructions)
}

Mem_Fields :: struct {
	total, free, available, buffers, cached, reclaimable, shared, dirty: u64,
	swap_total, swap_free, committed, commit_limit: u64,
}

// What the system says of the machine at one moment: counters since it started, amounts now. The platform's reader
// fills it; its lists are in the temporary allocator.
Machine_Counters :: struct {
	cpu_total_ns, cpu_idle_ns:   u64,            // all processors' time, and the part they were idle (or waiting on I/O)
	core_total_ns, core_idle_ns: [dynamic]u64,   // each logical processor's
	boot_time: i64,                              // unix seconds
	load:      [3]f32,                           // the load average over 1, 5 and 15 minutes (0: the system has none)
	uptime:    f64,                              // seconds
	handles:   u64,                              // the open file handles of the whole system
	mem:       Mem_Fields,
	disks:     [dynamic]Disk_Counters,
	nets:      [dynamic]Net_Counters,
}

Disk_Counters :: struct { name: string, read_bytes, written_bytes, busy_ms: u64 }
Net_Counters :: struct { name: string, rx, tx: u64 }

// A disk as the system lists it (disks_list; texts in the temporary allocator).
Disk_Info :: struct {
	name, model, kind: string,   // nvme0n1, "Samsung SSD 970 EVO Plus 1TB", "NVMe SSD" (SSD, HDD, Removable)
	capacity:          u64,
	mounts:            []string,  // where its file systems are
}

// A network interface as the system lists it (nets_list; texts in the temporary allocator).
Net_Info :: struct {
	name, kind, mac: string,   // "enp5s0", "Ethernet" (Wi-Fi, Tunnel, Virtual), "aa:bb:..."
	up:              bool,
	speed_mbps:      int,      // 0: unknown (down, virtual)
	addrs:           []string, // IPv4 then IPv6
}

Disk :: struct {
	name, model, kind: string,   // owned
	capacity:    u64,
	mounts:      [dynamic]string,   // owned
	read_bytes, written_bytes, busy_ms: u64,
	seen:        bool,              // its counters were read once (a rate needs two readings)
	read_rate, write_rate: f64,     // bytes per second
	active:      f32,               // percent of the time it was busy
	listed:      bool,              // in the last list of the disks
	read_hist, write_hist, active_hist: History,
}

Net :: struct {
	name, kind, mac: string,   // owned
	speed_mbps:  int,
	up:          bool,
	addrs:       [dynamic]string,   // owned
	rx, tx:      u64,
	seen:        bool,
	rx_rate, tx_rate: f64,     // bytes per second
	listed:      bool,
	rx_hist, tx_hist: History,
}

Machine :: struct {
	reader:     Machine_Reader,    // the system's (machine_linux.odin)
	demo:       ^Demo,             // not nil: the machine is the demo's (demo.odin)
	// the CPU
	total_ns, idle_ns: u64,        // all processors' time at the last sample
	d_total_ns: u64,               // since the sample before (the processes' CPU % is their share of it)
	core_total, core_idle: [dynamic]u64,
	cpu:        f32,
	core_cpu:   [dynamic]f32,
	cpu_hist:   History,
	core_hist:  [dynamic]History,
	boot_time:  i64,
	load:       [3]f32,
	uptime:     f64,
	handles:    u64,
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
	gpu_readings: int,             // the GPUs' reading the graphs have a point of
	last_ns:    i64,
	samples:    int,
}

machine_init :: proc(m: ^Machine, demo: ^Demo) {
	m.demo = demo
	if demo == nil { machine_reader_init(&m.reader) }
	devices_list(m)
	gpu_start(&m.gpu, demo)
}

machine_destroy :: proc(m: ^Machine) {
	gpu_stop(&m.gpu)
	if m.demo == nil { machine_reader_destroy(&m.reader) }
	delete(m.core_total)
	delete(m.core_idle)
	delete(m.core_cpu)
	delete(m.core_hist)
	delete(m.info.model)
	for &d in m.disks { disk_free(&d) }
	delete(m.disks)
	for &n in m.nets { net_free(&n) }
	delete(m.nets)
	delete(m.gpus)
}

@(private = "file")
disk_free :: proc(d: ^Disk) {
	delete(d.name)
	delete(d.model)
	delete(d.kind)
	for s in d.mounts { delete(s) }
	delete(d.mounts)
}

@(private = "file")
net_free :: proc(n: ^Net) {
	delete(n.name)
	delete(n.kind)
	delete(n.mac)
	for s in n.addrs { delete(s) }
	delete(n.addrs)
}

mem_used :: proc(m: ^Machine) -> u64 { return m.mem.total - min(m.mem.available, m.mem.total) }

// Reads the machine again. `cpu_shown`: the CPU's page is on the screen (its frequency is read, its details once).
// `history`: the sample is one of the period's, which the graphs get a point of (not one made sooner, after a signal).
machine_sample :: proc(m: ^Machine, now_ns: i64, cpu_shown: bool, history := true) {
	dt := m.last_ns > 0 ? f64(now_ns - m.last_ns) / 1e9 : 0
	m.last_ns = now_ns
	m.samples += 1
	if m.samples % DEVICES_EVERY == 0 { devices_list(m) }
	c: Machine_Counters
	if m.demo != nil { demo_machine_read(m.demo, now_ns, &c) } else { machine_read(&m.reader, &c) }
	machine_take(m, c, dt, history)
	gpus_sample(m, history)
	if cpu_shown {
		if !m.info_read {
			m.info_read = true
			m.info = m.demo != nil ? demo_cpu_info() : cpu_info_read()
			if m.info.logical == 0 { m.info.logical = len(m.core_total) }
		}
		m.mhz = m.demo != nil ? demo_cpu_mhz(m.demo) : cpu_mhz_now(len(m.core_total))
	}
}

// The rates and the points of the graphs from a reading `dt` seconds after the last.
machine_take :: proc(m: ^Machine, c: Machine_Counters, dt: f64, history: bool) {
	first := m.total_ns == 0
	m.d_total_ns = first ? 0 : c.cpu_total_ns - min(m.total_ns, c.cpu_total_ns)
	if m.d_total_ns > 0 { m.cpu = busy_percent(m.total_ns, m.idle_ns, c.cpu_total_ns, c.cpu_idle_ns) }
	m.total_ns, m.idle_ns = c.cpu_total_ns, c.cpu_idle_ns
	n := len(c.core_total_ns)
	if len(m.core_total) != n {
		resize(&m.core_total, n)
		resize(&m.core_idle, n)
		resize(&m.core_cpu, n)
		resize(&m.core_hist, n)
	}
	for i in 0 ..< n {
		if m.core_total[i] > 0 { m.core_cpu[i] = busy_percent(m.core_total[i], m.core_idle[i], c.core_total_ns[i], c.core_idle_ns[i]) }
		m.core_total[i], m.core_idle[i] = c.core_total_ns[i], c.core_idle_ns[i]
		if !first && history { ui.value_history_push(&m.core_hist[i], m.core_cpu[i]) }
	}
	if !first && history { ui.value_history_push(&m.cpu_hist, m.cpu) }
	m.boot_time, m.load, m.uptime, m.handles, m.mem = c.boot_time, c.load, c.uptime, c.handles, c.mem
	if history { ui.value_history_push(&m.mem_hist, m.mem.total > 0 ? 100 * f32(f64(mem_used(m)) / f64(m.mem.total)) : 0) }

	for s in c.disks {
		for &d in m.disks {
			if d.name != s.name { continue }
			if d.seen && dt > 0 {
				d.read_rate = rate_of(d.read_bytes, s.read_bytes, dt)
				d.write_rate = rate_of(d.written_bytes, s.written_bytes, dt)
				d.active = min(100, f32(rate_of(d.busy_ms, s.busy_ms, dt) / 10))   // (ms busy per second, as a percent)
				if history {
					ui.value_history_push(&d.read_hist, f32(d.read_rate))
					ui.value_history_push(&d.write_hist, f32(d.write_rate))
					ui.value_history_push(&d.active_hist, d.active)
				}
			}
			d.read_bytes, d.written_bytes, d.busy_ms, d.seen = s.read_bytes, s.written_bytes, s.busy_ms, true
		}
	}
	for s in c.nets {
		for &n in m.nets {
			if n.name != s.name { continue }
			if n.seen && dt > 0 {
				n.rx_rate = rate_of(n.rx, s.rx, dt)
				n.tx_rate = rate_of(n.tx, s.tx, dt)
				if history {
					ui.value_history_push(&n.rx_hist, f32(n.rx_rate))
					ui.value_history_push(&n.tx_hist, f32(n.tx_rate))
				}
			}
			n.rx, n.tx, n.seen = s.rx, s.tx, true
		}
	}
}

// The share of the time a processor was busy between two readings of its total and idle times, in percent.
busy_percent :: proc(total0, idle0, total1, idle1: u64) -> f32 {
	d := total1 - min(total0, total1)
	if d == 0 { return 0 }
	idle := idle1 - min(idle0, idle1)
	return 100 * (1 - f32(f64(min(idle, d)) / f64(d)))
}

// The disks and the interfaces listed again: those listed before keep their history and their counters.
devices_list :: proc(m: ^Machine) {
	disks := make([dynamic]Disk_Info, context.temp_allocator)
	nets := make([dynamic]Net_Info, context.temp_allocator)
	if m.demo != nil { demo_devices(m.demo, &disks, &nets) } else { disks_list(&disks); nets_list(&nets) }
	devices_merge(m, disks[:], nets[:])
}

devices_merge :: proc(m: ^Machine, disks: []Disk_Info, nets: []Net_Info) {
	for &d in m.disks { d.listed = false }
	for info in disks {
		at := -1
		for d, i in m.disks { if d.name == info.name { at = i } }
		if at < 0 {
			append(&m.disks, Disk{name = strings.clone(info.name)})
			at = len(m.disks) - 1
		}
		d := &m.disks[at]
		d.listed = true
		delete(d.model)
		delete(d.kind)
		d.model, d.kind, d.capacity = strings.clone(info.model), strings.clone(info.kind), info.capacity
		for s in d.mounts { delete(s) }
		clear(&d.mounts)
		for s in info.mounts { append(&d.mounts, strings.clone(s)) }
	}
	for i := len(m.disks) - 1; i >= 0; i -= 1 {
		if !m.disks[i].listed { disk_free(&m.disks[i]); ordered_remove(&m.disks, i) }
	}
	slice.sort_by(m.disks[:], proc(a, b: Disk) -> bool { return a.name < b.name })

	for &n in m.nets { n.listed = false }
	for info in nets {
		at := -1
		for n, i in m.nets { if n.name == info.name { at = i } }
		if at < 0 {
			append(&m.nets, Net{name = strings.clone(info.name)})
			at = len(m.nets) - 1
		}
		n := &m.nets[at]
		n.listed = true
		delete(n.kind)
		delete(n.mac)
		n.kind, n.mac, n.up, n.speed_mbps = strings.clone(info.kind), strings.clone(info.mac), info.up, info.speed_mbps
		for s in n.addrs { delete(s) }
		clear(&n.addrs)
		for s in info.addrs { append(&n.addrs, strings.clone(s)) }
	}
	for i := len(m.nets) - 1; i >= 0; i -= 1 {
		if !m.nets[i].listed { net_free(&m.nets[i]); ordered_remove(&m.nets, i) }
	}
	slice.sort_by(m.nets[:], proc(a, b: Net) -> bool { return a.name < b.name })
}
