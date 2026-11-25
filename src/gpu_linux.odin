package inspecteur

// The GPUs on Linux:
//
// - NVIDIA: NVML (libnvidia-ml.so.1, the library nvidia-smi is made on), opened with dlopen: the utilization, the video
//   memory, the temperature, the power, the clock, and (when it is asked) each process's video memory and
//   share of the GPU's time (nvmlDeviceGetProcessUtilization). No process is started.
// - AMD: amdgpu's files in /sys/class/drm/card*/device: gpu_busy_percent, mem_info_vram_used and _total.
// - Intel: its name only (i915 and xe tell no utilization without root).
//
// A GPU the kernel puts to sleep (runtime power management: power/control is "auto", a laptop's second GPU) sleeps
// while nothing uses it. NVML wakes it, and keeps it awake while it is open. So NVML is opened only while the GPUs'
// numbers are wanted and no NVIDIA GPU sleeps (power/runtime_status "suspended"), and closed when they are no longer
// wanted; a GPU that sleeps is listed asleep. A GPU that is always on (power/control "on", a desktop's) keeps NVML open,
// but asks it of each process only when that is shown: those calls cost most of a reading's time.
// NVML's handles and names are asked once per opening; the DRM cards are listed again every DRM_LIST_EVERY readings (a
// card can be plugged in, or its driver loaded later).

import "core:dynlib"
import "core:fmt"
import "core:strconv"
import "core:strings"
import i18n "gt:i18n"

// Where NixOS puts the driver's libraries (dlopen looks there after the usual places).
NIXOS_DRIVER_LIB :: "/run/opengl-driver/lib/libnvidia-ml.so.1"
PCI_DEVICES :: "/sys/bus/pci/devices"
PCI_VENDOR_NVIDIA :: "0x10de"

@(private = "file")
Drm_Card :: struct {
	card:     int,
	vendor:   string,    // "AMD" or "Intel"
	name:     [96]u8,
	name_len: int,
}

Gpu_Reader :: struct {
	nv:          Nvml,
	seen_us:     [GPU_MAX]u64,       // each GPU's newest process sample read (NVML's clock, microseconds)
	tried:       bool,               // NVML's library was looked for (once: it is there or not)
	nvidia:      [GPU_MAX][16]u8,    // the PCI slots of the NVIDIA display controllers (0000:01:00.0)
	nvidia_n:    int,
	listed:      bool,
	names:       [GPU_MAX]Gpu_Read,  // what NVML last said of each NVIDIA GPU: its name and driver, shown while it sleeps
	// cached NVML handles and static strings (valid while nv.ok && nv_cached)
	nv_cached:   bool,
	nv_count:    int,
	nv_handles:  [GPU_MAX]Nvml_Device,
	nv_driver:   [32]u8,
	nv_driver_n: int,
	nv_names:    [GPU_MAX][96]u8,
	nv_name_n:   [GPU_MAX]int,
	// the AMD and Intel DRM cards, as last listed
	drm_age:     int,                // readings since
	drm_cards:   [GPU_MAX]Drm_Card,
	drm_n:       int,
}

gpu_reader_close :: proc(r: ^Gpu_Reader) {
	nvml_close(&r.nv)
	r.nv_cached = false
	if r.nv.lib != nil { dynlib.unload_library(r.nv.lib) }
	r.nv = {}
}

// One reading of the GPUs. `wanted`: the window shows their numbers (NVML can be opened, see above).
gpu_read :: proc(r: ^Gpu_Reader, snap: ^Gpu_Snapshot, wanted: bool) {
	if !r.listed { nvidia_list(r) }
	asleep, always_on := false, true
	for i in 0 ..< r.nvidia_n {
		slot := cstr_of(r.nvidia[i][:])
		if pci_asleep(slot) { asleep = true }
		if read_text(fmt.tprintf("%s/%s/power/control", PCI_DEVICES, slot)) == "auto" { always_on = false }
	}
	open := r.nvidia_n > 0 && !asleep && (wanted || always_on)
	if open && !r.nv.ok {
		if !r.tried {
			r.tried = true
			nvml_load(&r.nv)
		}
		nvml_init(&r.nv)
		r.nv_cached = false
	} else if !open && r.nv.ok {
		nvml_close(&r.nv)
		r.nv_cached = false
	}
	if r.nv.ok {
		nvml_read(r, snap)
		for i in 0 ..< min(snap.count, GPU_MAX) { r.names[i] = snap.gpus[i]; r.names[i].has_util = false }
	} else {
		// (not read: each NVIDIA GPU as NVML last named it, asleep when it sleeps, else with no numbers)
		for i in 0 ..< min(r.nvidia_n, GPU_MAX - snap.count) {
			g := r.names[i]
			g = Gpu_Read{name = g.name, name_len = g.name_len, driver = g.driver, driver_len = g.driver_len}
			g.vendor = "NVIDIA"
			if g.name_len == 0 { g.name_len = copy(g.name[:], "NVIDIA GPU") }
			g.asleep = pci_asleep(cstr_of(r.nvidia[i][:]))
			snap.gpus[snap.count] = g
			snap.count += 1
		}
	}
	drm_read(r, snap)
}

// The PCI slots of the NVIDIA display controllers.
@(private = "file")
nvidia_list :: proc(r: ^Gpu_Reader) {
	r.listed = true
	for slot in pci_display_slots() {
		if r.nvidia_n >= GPU_MAX { break }
		if read_text(fmt.tprintf("%s/%s/vendor", PCI_DEVICES, slot)) != PCI_VENDOR_NVIDIA { continue }
		copy(r.nvidia[r.nvidia_n][:], slot)
		r.nvidia_n += 1
	}
}

// The PCI slots of the display controllers (class 0x03), in order (temporary allocator).
pci_display_slots :: proc() -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for name in list_dir(PCI_DEVICES) {
		class := strconv.parse_u64(strings.trim_prefix(read_text(fmt.tprintf("%s/%s/class", PCI_DEVICES, name)), "0x"), 16) or_else 0
		if class >> 16 == PCI_CLASS_DISPLAY { append(&out, name) }
	}
	return out[:]
}

// Whether the PCI device sleeps (runtime power management): reading it would wake it.
pci_asleep :: proc(slot: string) -> bool {
	return read_text(fmt.tprintf("%s/%s/power/runtime_status", PCI_DEVICES, slot)) == "suspended"
}

@(private = "file")
cstr_of :: proc(b: []u8) -> string {
	n := 0
	for n < len(b) && b[n] != 0 { n += 1 }
	return string(b[:n])
}

////////////////////////////////
// NVIDIA: NVML

@(private = "file")
NVML_SUCCESS :: 0
@(private = "file")
Nvml_Device :: distinct rawptr
@(private = "file")
Nvml_Utilization :: struct { gpu, memory: u32 }
@(private = "file")
Nvml_Memory :: struct { total, free, used: u64 }
// nvmlProcessUtilizationSample_t: a process's share of the GPU's engines over one of the driver's sample periods.
@(private = "file")
Nvml_Process_Sample :: struct { pid: u32, time_us: u64, sm, mem, enc, dec: u32 }
@(private = "file")
NVML_PROCESS_SAMPLES :: 256
// nvmlProcessInfo_t of the _v3 calls.
@(private = "file")
Nvml_Process :: struct { pid: u32, used_gpu_memory: u64, gpu_instance_id, compute_instance_id: u32 }
@(private = "file")
NVML_VALUE_NOT_AVAILABLE :: max(u64)

Nvml :: struct {
	lib:         dynlib.Library,
	ok:          bool,   // initialized (nvmlInit): it holds the GPUs awake until nvml_close
	init:        proc "c" () -> i32,
	shutdown:    proc "c" () -> i32,
	count:       proc "c" (n: ^u32) -> i32,
	handle:      proc "c" (index: u32, dev: ^Nvml_Device) -> i32,
	name:        proc "c" (dev: Nvml_Device, buf: [^]u8, len: u32) -> i32,
	utilization: proc "c" (dev: Nvml_Device, u: ^Nvml_Utilization) -> i32,
	memory:      proc "c" (dev: Nvml_Device, m: ^Nvml_Memory) -> i32,
	temperature: proc "c" (dev: Nvml_Device, sensor: u32, t: ^u32) -> i32,
	power:       proc "c" (dev: Nvml_Device, mw: ^u32) -> i32,
	clock:       proc "c" (dev: Nvml_Device, kind: u32, mhz: ^u32) -> i32,
	driver:      proc "c" (buf: [^]u8, len: u32) -> i32,
	graphics:    proc "c" (dev: Nvml_Device, n: ^u32, infos: [^]Nvml_Process) -> i32,
	compute:     proc "c" (dev: Nvml_Device, n: ^u32, infos: [^]Nvml_Process) -> i32,
	samples:     proc "c" (dev: Nvml_Device, out: [^]Nvml_Process_Sample, n: ^u32, since_us: u64) -> i32,
}

@(private = "file")
nvml_load :: proc(nv: ^Nvml) {
	lib, ok := dynlib.load_library("libnvidia-ml.so.1")
	if !ok { lib, ok = dynlib.load_library(NIXOS_DRIVER_LIB) }
	if !ok { return }
	nv.lib = lib
	sym :: proc(lib: dynlib.Library, name: string) -> rawptr { p, _ := dynlib.symbol_address(lib, name); return p }
	nv.init = auto_cast sym(lib, "nvmlInit_v2")
	nv.shutdown = auto_cast sym(lib, "nvmlShutdown")
	nv.count = auto_cast sym(lib, "nvmlDeviceGetCount_v2")
	nv.handle = auto_cast sym(lib, "nvmlDeviceGetHandleByIndex_v2")
	nv.name = auto_cast sym(lib, "nvmlDeviceGetName")
	nv.utilization = auto_cast sym(lib, "nvmlDeviceGetUtilizationRates")
	nv.memory = auto_cast sym(lib, "nvmlDeviceGetMemoryInfo")
	nv.temperature = auto_cast sym(lib, "nvmlDeviceGetTemperature")
	nv.power = auto_cast sym(lib, "nvmlDeviceGetPowerUsage")
	nv.clock = auto_cast sym(lib, "nvmlDeviceGetClockInfo")
	nv.driver = auto_cast sym(lib, "nvmlSystemGetDriverVersion")
	nv.graphics = auto_cast sym(lib, "nvmlDeviceGetGraphicsRunningProcesses_v3")
	nv.compute = auto_cast sym(lib, "nvmlDeviceGetComputeRunningProcesses_v3")
	nv.samples = auto_cast sym(lib, "nvmlDeviceGetProcessUtilization")
}

@(private = "file")
nvml_init :: proc(nv: ^Nvml) {
	if nv.lib == nil || nv.init == nil || nv.count == nil || nv.handle == nil { return }
	nv.ok = nv.init() == NVML_SUCCESS
}

@(private = "file")
nvml_close :: proc(nv: ^Nvml) {
	if nv.ok && nv.shutdown != nil { nv.shutdown() }
	nv.ok = false
}

@(private = "file")
nvml_cache_static :: proc(r: ^Gpu_Reader) {
	nv := &r.nv
	r.nv_count = 0
	r.nv_driver_n = 0
	n: u32
	if nv.count(&n) != NVML_SUCCESS { return }
	// (a GPU that gives no handle now is asked again at the next reading)
	r.nv_cached = true
	if nv.driver != nil && nv.driver(&r.nv_driver[0], len(r.nv_driver)) == NVML_SUCCESS {
		r.nv_driver_n = cstring_len(r.nv_driver[:])
	}
	for i in 0 ..< min(int(n), GPU_MAX) {
		dev: Nvml_Device
		if nv.handle(u32(i), &dev) != NVML_SUCCESS { r.nv_cached = false; continue }
		k := r.nv_count
		r.nv_handles[k] = dev
		r.nv_name_n[k] = 0
		if nv.name != nil && nv.name(dev, &r.nv_names[k][0], len(r.nv_names[k])) == NVML_SUCCESS {
			r.nv_name_n[k] = cstring_len(r.nv_names[k][:])
		}
		r.nv_count += 1
	}
}

@(private = "file")
nvml_read :: proc(r: ^Gpu_Reader, snap: ^Gpu_Snapshot) {
	nv := &r.nv
	if !r.nv_cached { nvml_cache_static(r) }
	for i in 0 ..< min(r.nv_count, GPU_MAX - snap.count) {
		dev := r.nv_handles[i]
		g := &snap.gpus[snap.count]
		snap.count += 1
		g.vendor = "NVIDIA"
		g.driver, g.driver_len = r.nv_driver, r.nv_driver_n
		g.name, g.name_len = r.nv_names[i], r.nv_name_n[i]
		u: Nvml_Utilization
		if nv.utilization != nil && nv.utilization(dev, &u) == NVML_SUCCESS { g.util, g.has_util = f32(u.gpu), true }
		mem: Nvml_Memory
		if nv.memory != nil && nv.memory(dev, &mem) == NVML_SUCCESS { g.mem_used, g.mem_total, g.has_mem = mem.used, mem.total, true }
		v: u32
		if nv.temperature != nil && nv.temperature(dev, 0, &v) == NVML_SUCCESS { g.temp_c, g.has_temp = f32(v), true }   // (0: the GPU's sensor)
		if nv.power != nil && nv.power(dev, &v) == NVML_SUCCESS { g.power_w, g.has_power = f32(v) / 1000, true }
		if nv.clock != nil && nv.clock(dev, 0, &v) == NVML_SUCCESS { g.clock_mhz, g.has_clock = f32(v), true }   // (0: the graphics clock)
		if !snap.want_procs { continue }
		// the processes: those that draw, then those that compute
		first := snap.proc_count
		infos: [GPU_PROCS_MAX]Nvml_Process
		for call in ([]proc "c" (dev: Nvml_Device, n: ^u32, infos: [^]Nvml_Process) -> i32{nv.graphics, nv.compute}) {
			if call == nil { continue }
			count := u32(len(infos))
			if call(dev, &count, &infos[0]) != NVML_SUCCESS { continue }
			for p in infos[:min(int(count), len(infos))] {
				if p.used_gpu_memory != NVML_VALUE_NOT_AVAILABLE { gpu_proc_add(snap, first, i32(p.pid), p.used_gpu_memory) }
			}
		}
		// each process's share of the GPU's time: the samples since the last reading, the newest of each process
		if nv.samples != nil {
			samples: [NVML_PROCESS_SAMPLES]Nvml_Process_Sample
			count := u32(len(samples))
			if nv.samples(dev, &samples[0], &count, r.seen_us[i]) == NVML_SUCCESS {
				newest := r.seen_us[i]
				for q in samples[:min(int(count), len(samples))] {
					gpu_proc_util(snap, first, i32(q.pid), f32(q.sm))
					newest = max(newest, q.time_us)
				}
				r.seen_us[i] = newest
			}
		}
	}
}

@(private = "file")
cstring_len :: proc(b: []u8) -> int {
	for c, i in b { if c == 0 { return i } }
	return len(b)
}

////////////////////////////////
// AMD and Intel: the DRM files

// Readings between two lists of the DRM cards (as the machine's other devices).
@(private = "file")
DRM_LIST_EVERY :: DEVICES_EVERY

@(private = "file")
drm_list :: proc(r: ^Gpu_Reader) {
	r.drm_n = 0
	for card in 0 ..< 8 {
		if r.drm_n >= GPU_MAX { return }
		dir := fmt.tprintf("/sys/class/drm/card%d/device", card)
		vendor := read_text(fmt.tprintf("%s/vendor", dir))
		if vendor == "" { continue }
		vname: string
		switch vendor {
		case "0x1002": vname = "AMD"
		case "0x8086": vname = "Intel"
		case:          continue   // (NVIDIA: NVML's; another: nothing to read)
		}
		c := &r.drm_cards[r.drm_n]
		c.card = card
		c.vendor = vname
		name := read_text(fmt.tprintf("%s/product_name", dir))
		if name == "" { name = fmt.tprintf(i18n.tr("%s GPU (card%d)"), vname, card) }
		c.name_len = copy(c.name[:], name)
		r.drm_n += 1
	}
}

@(private = "file")
drm_read :: proc(r: ^Gpu_Reader, snap: ^Gpu_Snapshot) {
	if r.drm_age == 0 { drm_list(r) }
	r.drm_age = (r.drm_age + 1) % DRM_LIST_EVERY
	for &c in r.drm_cards[:r.drm_n] {
		if snap.count >= GPU_MAX { return }
		dir := fmt.tprintf("/sys/class/drm/card%d/device", c.card)
		g := Gpu_Read{vendor = c.vendor, name = c.name, name_len = c.name_len}
		if c.vendor == "AMD" {
			g.asleep = read_text(fmt.tprintf("%s/power/runtime_status", dir)) == "suspended"
			if !g.asleep {
				if v, ok := strconv.parse_f64(read_text(fmt.tprintf("%s/gpu_busy_percent", dir))); ok { g.util, g.has_util = f32(v), true }
				used, uok := strconv.parse_u64(read_text(fmt.tprintf("%s/mem_info_vram_used", dir)), 10)
				total, tok := strconv.parse_u64(read_text(fmt.tprintf("%s/mem_info_vram_total", dir)), 10)
				if uok && tok { g.mem_used, g.mem_total, g.has_mem = used, total, true }
			}
		}
		snap.gpus[snap.count] = g
		snap.count += 1
	}
}
