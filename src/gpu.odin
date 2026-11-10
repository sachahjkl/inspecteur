package inspecteur

// The GPUs, read on a thread of their own every GPU_PERIOD: a GPU's driver can take milliseconds to answer, and its
// library a second to start; the window's thread never waits for them. The window takes the last reading at each sample
// (gpus_sample).
//
// - NVIDIA: NVML (libnvidia-ml.so.1, the library nvidia-smi is made on), opened with dlopen: the utilisation, the video
//   memory, the temperature, the power, the clock, and the video memory of each process. No process is started.
// - AMD: amdgpu's files in /sys/class/drm/card*/device: gpu_busy_percent, mem_info_vram_used and _total.
// - Intel: its name only (i915 and xe tell no utilisation without root).
// No GPU readable: the Performance section lists none.

import "core:dynlib"
import "core:fmt"
import "core:strconv"
import "core:sync"
import "core:thread"
import "core:time"
import "gt:ui"

GPU_PERIOD :: 2 * time.Second
GPU_MAX :: 4
// The processes whose video memory is kept, at most.
GPU_PROCS_MAX :: 256
// Where NixOS puts the driver's libraries (dlopen looks there after the usual places).
NIXOS_DRIVER_LIB :: "/run/opengl-driver/lib/libnvidia-ml.so.1"

// One reading of a GPU. Fixed size: it is copied from the GPU thread to the window's under the lock.
Gpu_Read :: struct {
	name:        [96]u8,
	name_len:    int,
	vendor:      string,   // a literal: NVIDIA, AMD, Intel
	driver:      [32]u8,
	driver_len:  int,
	has_util, has_mem, has_temp, has_power, has_clock: bool,
	util:        f32,   // percent
	mem_used, mem_total: u64,
	temp_c:      f32,
	power_w:     f32,
	clock_mhz:   f32,
}

Gpu_Proc_Mem :: struct { pid: i32, bytes: u64 }

Gpu_Snapshot :: struct {
	gpus:      [GPU_MAX]Gpu_Read,
	count:     int,
	procs:     [GPU_PROCS_MAX]Gpu_Proc_Mem,
	proc_count: int,
	readings:  int,   // how many readings have been made (0: none yet)
}

Gpu_Watch :: struct {
	thread: ^thread.Thread,
	mutex:  sync.Mutex,
	cond:   sync.Cond,
	stop:   bool,
	snap:   Gpu_Snapshot,   // the last reading, under the mutex
}

// A GPU as the window has it: its last reading and its graphs.
Gpu :: struct {
	read:      Gpu_Read,
	util_hist: History,
	mem_hist:  History,   // percent of its memory in use
}

gpu_name :: proc(g: ^Gpu_Read) -> string { return string(g.name[:g.name_len]) }
gpu_driver :: proc(g: ^Gpu_Read) -> string { return string(g.driver[:g.driver_len]) }

gpu_start :: proc(w: ^Gpu_Watch) {
	w.thread = thread.create_and_start_with_data(w, gpu_run, context)
}

gpu_stop :: proc(w: ^Gpu_Watch) {
	if w.thread == nil { return }
	sync.mutex_lock(&w.mutex)
	w.stop = true
	sync.cond_signal(&w.cond)
	sync.mutex_unlock(&w.mutex)
	thread.join(w.thread)
	thread.destroy(w.thread)
	w.thread = nil
}

// The GPUs' last reading into the machine, and a point of each graph. The processes' video memory: gpu_proc_mem.
gpus_sample :: proc(m: ^Machine) {
	w := &m.gpu
	sync.mutex_lock(&w.mutex)
	snap := w.snap
	sync.mutex_unlock(&w.mutex)
	if snap.readings == 0 { return }
	if len(m.gpus) != snap.count { resize(&m.gpus, snap.count) }
	for &g, i in m.gpus {
		g.read = snap.gpus[i]
		ui.value_history_push(&g.util_hist, g.read.util)
		ui.value_history_push(&g.mem_hist, g.read.mem_total > 0 ? 100 * f32(f64(g.read.mem_used) / f64(g.read.mem_total)) : 0)
	}
}

// The video memory each process holds, by pid (temporary allocator; empty when no GPU tells it).
gpu_proc_mem :: proc(m: ^Machine) -> map[i32]u64 {
	out := make(map[i32]u64, 16, context.temp_allocator)
	w := &m.gpu
	sync.mutex_lock(&w.mutex)
	for p in w.snap.procs[:w.snap.proc_count] { out[p.pid] += p.bytes }
	sync.mutex_unlock(&w.mutex)
	return out
}

@(private = "file")
gpu_run :: proc(data: rawptr) {
	w := (^Gpu_Watch)(data)
	nv: Nvml
	nvml_open(&nv)
	defer nvml_close(&nv)
	for {
		snap: Gpu_Snapshot
		nvml_read(&nv, &snap)
		drm_read(&snap)
		sync.mutex_lock(&w.mutex)
		snap.readings = w.snap.readings + 1
		w.snap = snap
		if !w.stop { _ = sync.cond_wait_with_timeout(&w.cond, &w.mutex, GPU_PERIOD) }
		stop := w.stop
		sync.mutex_unlock(&w.mutex)
		free_all(context.temp_allocator)
		if stop { return }
	}
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
// nvmlProcessInfo_t of the _v3 calls.
@(private = "file")
Nvml_Process :: struct { pid: u32, used_gpu_memory: u64, gpu_instance_id, compute_instance_id: u32 }
@(private = "file")
NVML_VALUE_NOT_AVAILABLE :: max(u64)

@(private = "file")
Nvml :: struct {
	lib:         dynlib.Library,
	ok:          bool,
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
}

@(private = "file")
nvml_open :: proc(nv: ^Nvml) {
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
	if nv.init == nil || nv.count == nil || nv.handle == nil { return }
	nv.ok = nv.init() == NVML_SUCCESS
}

@(private = "file")
nvml_close :: proc(nv: ^Nvml) {
	if nv.ok && nv.shutdown != nil { nv.shutdown() }
	if nv.lib != nil { dynlib.unload_library(nv.lib) }
}

@(private = "file")
nvml_read :: proc(nv: ^Nvml, snap: ^Gpu_Snapshot) {
	if !nv.ok { return }
	n: u32
	if nv.count(&n) != NVML_SUCCESS { return }
	driver: [32]u8
	driver_len := 0
	if nv.driver != nil && nv.driver(&driver[0], len(driver)) == NVML_SUCCESS { driver_len = cstring_len(driver[:]) }
	for i in 0 ..< min(int(n), GPU_MAX - snap.count) {
		dev: Nvml_Device
		if nv.handle(u32(i), &dev) != NVML_SUCCESS { continue }
		g := &snap.gpus[snap.count]
		snap.count += 1
		g.vendor = "NVIDIA"
		g.driver, g.driver_len = driver, driver_len
		if nv.name != nil && nv.name(dev, &g.name[0], len(g.name)) == NVML_SUCCESS { g.name_len = cstring_len(g.name[:]) }
		u: Nvml_Utilization
		if nv.utilization != nil && nv.utilization(dev, &u) == NVML_SUCCESS { g.util, g.has_util = f32(u.gpu), true }
		mem: Nvml_Memory
		if nv.memory != nil && nv.memory(dev, &mem) == NVML_SUCCESS { g.mem_used, g.mem_total, g.has_mem = mem.used, mem.total, true }
		v: u32
		if nv.temperature != nil && nv.temperature(dev, 0, &v) == NVML_SUCCESS { g.temp_c, g.has_temp = f32(v), true }   // (0: the GPU's sensor)
		if nv.power != nil && nv.power(dev, &v) == NVML_SUCCESS { g.power_w, g.has_power = f32(v) / 1000, true }
		if nv.clock != nil && nv.clock(dev, 0, &v) == NVML_SUCCESS { g.clock_mhz, g.has_clock = f32(v), true }   // (0: the graphics clock)
		// the processes: those that draw, then those that compute (a process may be in both: counted once)
		infos: [GPU_PROCS_MAX]Nvml_Process
		for call in ([]proc "c" (dev: Nvml_Device, n: ^u32, infos: [^]Nvml_Process) -> i32{nv.graphics, nv.compute}) {
			if call == nil { continue }
			count := u32(len(infos))
			if call(dev, &count, &infos[0]) != NVML_SUCCESS { continue }
			outer: for p in infos[:min(int(count), len(infos))] {
				if p.used_gpu_memory == NVML_VALUE_NOT_AVAILABLE { continue }
				for q in snap.procs[:snap.proc_count] { if q.pid == i32(p.pid) { continue outer } }
				if snap.proc_count < GPU_PROCS_MAX {
					snap.procs[snap.proc_count] = {i32(p.pid), p.used_gpu_memory}
					snap.proc_count += 1
				}
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

@(private = "file")
drm_read :: proc(snap: ^Gpu_Snapshot) {
	for card in 0 ..< 8 {
		if snap.count >= GPU_MAX { return }
		dir := fmt.tprintf("/sys/class/drm/card%d/device", card)
		vendor := read_text(fmt.tprintf("%s/vendor", dir))
		if vendor == "" { continue }
		g: Gpu_Read
		switch vendor {
		case "0x1002":
			g.vendor = "AMD"
			if v, ok := strconv.parse_f64(read_text(fmt.tprintf("%s/gpu_busy_percent", dir))); ok { g.util, g.has_util = f32(v), true }
			used, uok := strconv.parse_u64(read_text(fmt.tprintf("%s/mem_info_vram_used", dir)), 10)
			total, tok := strconv.parse_u64(read_text(fmt.tprintf("%s/mem_info_vram_total", dir)), 10)
			if uok && tok { g.mem_used, g.mem_total, g.has_mem = used, total, true }
		case "0x8086":
			g.vendor = "Intel"
		case:
			continue   // (NVIDIA: NVML's; another: nothing to read)
		}
		name := read_text(fmt.tprintf("%s/product_name", dir))
		if name == "" { name = fmt.tprintf("%s GPU (card%d)", g.vendor, card) }
		g.name_len = copy(g.name[:], name)
		snap.gpus[snap.count] = g
		snap.count += 1
	}
}
