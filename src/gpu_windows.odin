package inspecteur

// Windows GPU reader:
// - DXGI (CreateDXGIFactory1 / EnumAdapters1) discovers every hardware GPU across AMD, Intel, and NVIDIA
//   (skipping the Microsoft Basic Render Driver) with adapter name, vendor, LUID, and dedicated VRAM total.
// - PDH English GPU counters (pdh.dll, loaded dynamically) read per-adapter utilization, dedicated VRAM usage,
//   and per-process GPU utilization + VRAM for ALL vendors (AMD, Intel, NVIDIA) on Windows 10 1709+ / 11.
// - Optional NVML (nvml.dll, loaded dynamically) enriches NVIDIA GPUs with temperature, power, graphics clock,
//   driver version, and fallback per-process memory/utilization as on Linux.

import win "core:sys/windows"
import "vendor:directx/dxgi"
import winapi "winapi"

@(private = "file") PDH_FMT_DOUBLE :: u32(0x00000200)
// (a value is good when its status is PDH_CSTATUS_VALID_DATA, 0, or PDH_CSTATUS_NEW_DATA)
@(private = "file") PDH_CSTATUS_NEW_DATA :: u32(1)
@(private = "file") PDH_MORE_DATA  :: u32(0x800007D2)

@(private = "file")
Pdh_Fmt_Countervalue_Item_W :: struct {
	szName:   [^]u16,
	FmtValue: struct {
		CStatus: u32,
		_pad:    u32,
		Value:   f64,
	},
}

@(private = "file")
Pdh_State :: struct {
	lib:            win.HMODULE,
	open_query:     proc "system" (data_source: [^]u16, user_data: uintptr, query: ^rawptr) -> u32,
	add_counter:    proc "system" (query: rawptr, path: [^]u16, user_data: uintptr, counter: ^rawptr) -> u32,
	collect:        proc "system" (query: rawptr) -> u32,
	get_array:      proc "system" (counter: rawptr, format: u32, buf_size: ^u32, item_count: ^u32, items: rawptr) -> u32,
	close_query:    proc "system" (query: rawptr) -> u32,
	query:          rawptr,
	eng_counter:    rawptr,   // \GPU Engine(*)\Utilization Percentage
	mem_counter:    rawptr,   // \GPU Adapter Memory(*)\Dedicated Usage
	proc_counter:   rawptr,   // \GPU Process Memory(*)\Dedicated Usage
	buf:            []u8,     // reused growing buffer for formatted counter arrays
	primed:         bool,     // rate counters require two PdhCollectQueryData calls
	tried:          bool,
	ok:             bool,
}

@(private = "file")
Dxgi_Adapter_Info :: struct {
	name:       [96]u8,
	name_len:   int,
	vendor:     string,
	vendor_id:  u32,
	luid_high:  i32,
	luid_low:   u32,
	vram_total: u64,
}

@(private = "file") NVML_SUCCESS             :: 0
@(private = "file") NVML_VALUE_NOT_AVAILABLE :: max(u64)
@(private = "file") Nvml_Device              :: distinct rawptr
@(private = "file") Nvml_Utilization         :: struct { gpu, memory: u32 }
@(private = "file") Nvml_Memory              :: struct { total, free, used: u64 }
@(private = "file") Nvml_Process             :: struct { pid: u32, used_gpu_memory: u64, gpu_instance_id, compute_instance_id: u32 }

@(private = "file")
Win_Nvml :: struct {
	lib:         win.HMODULE,
	tried:       bool,
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

Gpu_Reader :: struct {
	adapters:      [GPU_MAX]Dxgi_Adapter_Info,
	adapter_count: int,
	listed:        bool,
	pdh:           Pdh_State,
	nv:            Win_Nvml,
}

gpu_reader_close :: proc(r: ^Gpu_Reader) {
	if r.pdh.query != nil && r.pdh.close_query != nil {
		r.pdh.close_query(r.pdh.query)
	}
	delete(r.pdh.buf)
	if r.pdh.lib != nil { win.FreeLibrary(r.pdh.lib) }
	if r.nv.ok && r.nv.shutdown != nil { r.nv.shutdown() }
	if r.nv.lib != nil { win.FreeLibrary(r.nv.lib) }
	r^ = {}
}

gpu_read :: proc(r: ^Gpu_Reader, snap: ^Gpu_Snapshot, wanted: bool) {
	if !r.listed {
		r.listed = true
		dxgi_list_adapters(r)
	}
	for i in 0 ..< min(r.adapter_count, GPU_MAX) {
		a := &r.adapters[i]
		g := &snap.gpus[snap.count]
		snap.count += 1
		g.name      = a.name
		g.name_len  = a.name_len
		g.vendor    = a.vendor
		g.mem_total = a.vram_total
		g.has_mem   = a.vram_total > 0
	}

	if !wanted { return }

	// All-vendor utilization & VRAM via PDH GPU counters.
	if !r.pdh.tried { pdh_init(&r.pdh) }
	if r.pdh.ok { pdh_sample(r, snap) }

	// Optional NVIDIA NVML enrichment (temperature, power, graphics clock, driver version, VRAM).
	has_nvidia := false
	for i in 0 ..< r.adapter_count { if r.adapters[i].vendor_id == 0x10DE { has_nvidia = true; break } }
	if has_nvidia || r.adapter_count == 0 {
		if !r.nv.tried { win_nvml_init(&r.nv) }
		if r.nv.ok { win_nvml_enrich(r, snap) }
	}
}

@(private = "file")
dxgi_list_adapters :: proc(r: ^Gpu_Reader) {
	factory_ptr: rawptr
	if dxgi.CreateDXGIFactory1(dxgi.IFactory1_UUID, &factory_ptr) < 0 || factory_ptr == nil { return }
	factory := (^dxgi.IFactory1)(factory_ptr)
	defer factory->Release()

	for idx := u32(0); r.adapter_count < GPU_MAX; idx += 1 {
		adapter: ^dxgi.IAdapter1
		if factory->EnumAdapters1(idx, &adapter) < 0 || adapter == nil { break }
		desc: dxgi.ADAPTER_DESC1
		ok := adapter->GetDesc1(&desc) >= 0
		adapter->Release()
		if !ok { continue }
		// Skip software renderers (Microsoft Basic Render Driver).
		if .SOFTWARE in desc.Flags || (desc.VendorId == 0x1414 && desc.DeviceId == 0x008C) { continue }

		a := &r.adapters[r.adapter_count]
		r.adapter_count += 1
		name := win_utf16_to_utf8(desc.Description[:], context.temp_allocator)
		a.name_len   = copy(a.name[:], name)
		a.vendor_id  = desc.VendorId
		a.luid_high  = desc.AdapterLuid.HighPart
		a.luid_low   = desc.AdapterLuid.LowPart
		a.vram_total = u64(desc.DedicatedVideoMemory)
		switch desc.VendorId {
		case 0x10DE: a.vendor = "NVIDIA"
		case 0x1002: a.vendor = "AMD"
		case 0x8086: a.vendor = "Intel"
		case:        a.vendor = "GPU"
		}
	}
}

@(private = "file")
pdh_init :: proc(p: ^Pdh_State) {
	p.tried = true
	p.lib = win_system_library("pdh.dll")
	if p.lib == nil { return }
	p.open_query  = auto_cast win.GetProcAddress(p.lib, "PdhOpenQueryW")
	p.add_counter = auto_cast win.GetProcAddress(p.lib, "PdhAddEnglishCounterW")
	p.collect     = auto_cast win.GetProcAddress(p.lib, "PdhCollectQueryData")
	p.get_array   = auto_cast win.GetProcAddress(p.lib, "PdhGetFormattedCounterArrayW")
	p.close_query = auto_cast win.GetProcAddress(p.lib, "PdhCloseQuery")
	if p.open_query == nil || p.add_counter == nil || p.collect == nil || p.get_array == nil { return }

	if p.open_query(nil, 0, &p.query) != 0 || p.query == nil { return }
	_ = p.add_counter(p.query, raw_data(win.utf8_to_utf16("\\GPU Engine(*)\\Utilization Percentage", context.temp_allocator)), 0, &p.eng_counter)
	_ = p.add_counter(p.query, raw_data(win.utf8_to_utf16("\\GPU Adapter Memory(*)\\Dedicated Usage", context.temp_allocator)), 0, &p.mem_counter)
	_ = p.add_counter(p.query, raw_data(win.utf8_to_utf16("\\GPU Process Memory(*)\\Dedicated Usage", context.temp_allocator)), 0, &p.proc_counter)
	p.buf = make([]u8, 64 * 1024)
	p.ok = p.eng_counter != nil || p.mem_counter != nil || p.proc_counter != nil
}

@(private = "file")
pdh_read_array :: proc(p: ^Pdh_State, counter: rawptr) -> []Pdh_Fmt_Countervalue_Item_W {
	if counter == nil { return nil }
	for _ in 0 ..< 4 {
		sz := u32(len(p.buf))
		count: u32
		st := p.get_array(counter, PDH_FMT_DOUBLE, &sz, &count, raw_data(p.buf))
		if st == 0 {
			n := min(int(count), len(p.buf) / size_of(Pdh_Fmt_Countervalue_Item_W))
			return ([^]Pdh_Fmt_Countervalue_Item_W)(raw_data(p.buf))[:n]
		}
		if st != PDH_MORE_DATA { return nil }
		next, ok := winapi.next_buffer_size(len(p.buf), sz)
		if !ok { return nil }
		delete(p.buf)
		p.buf = make([]u8, next)
	}
	return nil
}

@(private = "file")
find_adapter_by_luid :: proc(r: ^Gpu_Reader, hi: i32, lo: u32) -> int {
	for i in 0 ..< r.adapter_count {
		if r.adapters[i].luid_high == hi && r.adapters[i].luid_low == lo { return i }
	}
	return -1
}

// A process's memory on one GPU, added to what it has on the others.
@(private = "file")
pdh_proc_add :: proc(snap: ^Gpu_Snapshot, pid: i32, bytes: u64) {
	for &q in snap.procs[:snap.proc_count] { if q.pid == pid { q.bytes += bytes; return } }
	gpu_proc_add(snap, 0, pid, bytes)
}

@(private = "file")
pdh_sample :: proc(r: ^Gpu_Reader, snap: ^Gpu_Snapshot) {
	if r.pdh.collect(r.pdh.query) != 0 { return }
	if !r.pdh.primed {
		// PDH utilization is a delta counter; prime once so the next tick yields valid percentages.
		r.pdh.primed = true
		return
	}

	// 1. Adapter dedicated VRAM usage.
	if items := pdh_read_array(&r.pdh, r.pdh.mem_counter); len(items) > 0 {
		for item in items {
			if item.FmtValue.CStatus > PDH_CSTATUS_NEW_DATA || item.szName == nil { continue }
			inst := win_wstr_to_utf8(item.szName, 256, context.temp_allocator)
			hi, lo, ok := winapi.parse_pdh_adapter_luid(inst)
			if !ok { continue }
			if ai := find_adapter_by_luid(r, hi, lo); ai >= 0 && ai < snap.count {
				snap.gpus[ai].mem_used = u64(max(item.FmtValue.Value, 0))
				snap.gpus[ai].has_mem = true
			}
		}
	}

	// 2. Per-process dedicated VRAM usage.
	if items := pdh_read_array(&r.pdh, r.pdh.proc_counter); len(items) > 0 {
		for item in items {
			if item.FmtValue.CStatus > PDH_CSTATUS_NEW_DATA || item.szName == nil { continue }
			bytes := u64(max(item.FmtValue.Value, 0))
			if bytes == 0 { continue }
			inst := win_wstr_to_utf8(item.szName, 256, context.temp_allocator)
			parsed, ok := winapi.parse_pdh_gpu_instance(inst)
			if !ok { continue }
			pdh_proc_add(snap, parsed.pid, bytes)
		}
	}

	// 3. Per-engine utilization -> adapter max across engines (matches Windows Task Manager) and per-PID utilization.
	if items := pdh_read_array(&r.pdh, r.pdh.eng_counter); len(items) > 0 {
		Eng_Key :: struct { adapter: int, engine: int }
		eng_sum := make(map[Eng_Key]f64, 32, context.temp_allocator)
		for item in items {
			if item.FmtValue.CStatus > PDH_CSTATUS_NEW_DATA || item.szName == nil { continue }
			val := item.FmtValue.Value
			if val <= 0 { continue }
			inst := win_wstr_to_utf8(item.szName, 256, context.temp_allocator)
			parsed, ok := winapi.parse_pdh_gpu_instance(inst)
			if !ok { continue }
			if ai := find_adapter_by_luid(r, parsed.luid_high, parsed.luid_low); ai >= 0 && ai < snap.count {
				k := Eng_Key{ai, parsed.engine_idx}
				eng_sum[k] = eng_sum[k] + val
			}
			gpu_proc_util(snap, 0, parsed.pid, f32(min(val, 100)))
		}
		for i in 0 ..< snap.count {
			snap.gpus[i].has_util = true
		}
		for k, sum in eng_sum {
			if k.adapter >= 0 && k.adapter < snap.count {
				u := f32(min(sum, 100))
				if u > snap.gpus[k.adapter].util { snap.gpus[k.adapter].util = u }
			}
		}
	}
}

@(private = "file")
win_nvml_init :: proc(nv: ^Win_Nvml) {
	nv.tried = true
	lib := win_system_library("nvml.dll")   // (the driver puts it in System32)
	if lib == nil { return }
	nv.lib = lib
	sym :: proc(lib: win.HMODULE, name: cstring) -> rawptr { return rawptr(win.GetProcAddress(lib, name)) }
	nv.init        = auto_cast sym(lib, "nvmlInit_v2")
	nv.shutdown    = auto_cast sym(lib, "nvmlShutdown")
	nv.count       = auto_cast sym(lib, "nvmlDeviceGetCount_v2")
	nv.handle      = auto_cast sym(lib, "nvmlDeviceGetHandleByIndex_v2")
	nv.name        = auto_cast sym(lib, "nvmlDeviceGetName")
	nv.utilization = auto_cast sym(lib, "nvmlDeviceGetUtilizationRates")
	nv.memory      = auto_cast sym(lib, "nvmlDeviceGetMemoryInfo")
	nv.temperature = auto_cast sym(lib, "nvmlDeviceGetTemperature")
	nv.power       = auto_cast sym(lib, "nvmlDeviceGetPowerUsage")
	nv.clock       = auto_cast sym(lib, "nvmlDeviceGetClockInfo")
	nv.driver      = auto_cast sym(lib, "nvmlSystemGetDriverVersion")
	nv.graphics    = auto_cast sym(lib, "nvmlDeviceGetGraphicsRunningProcesses_v3")
	nv.compute     = auto_cast sym(lib, "nvmlDeviceGetComputeRunningProcesses_v3")
	if nv.init != nil && nv.count != nil && nv.handle != nil {
		nv.ok = nv.init() == NVML_SUCCESS
	}
}

@(private = "file")
win_nvml_enrich :: proc(r: ^Gpu_Reader, snap: ^Gpu_Snapshot) {
	nv := &r.nv
	n: u32
	if nv.count(&n) != NVML_SUCCESS || n == 0 { return }
	driver: [32]u8
	driver_len := 0
	if nv.driver != nil && nv.driver(&driver[0], len(driver)) == NVML_SUCCESS {
		for b, i in driver { if b == 0 { driver_len = i; break } }
	}
	nv_idx := 0
	for i in 0 ..< min(int(n), GPU_MAX) {
		dev: Nvml_Device
		if nv.handle(u32(i), &dev) != NVML_SUCCESS { continue }
		// Match against the nth NVIDIA DXGI adapter, or append if DXGI had none.
		target := -1
		seen := 0
		for j in 0 ..< snap.count {
			if snap.gpus[j].vendor == "NVIDIA" {
				if seen == nv_idx { target = j; break }
				seen += 1
			}
		}
		nv_idx += 1
		if target < 0 {
			if snap.count >= GPU_MAX { break }
			target = snap.count
			snap.count += 1
			snap.gpus[target].vendor = "NVIDIA"
			if nv.name != nil && nv.name(dev, &snap.gpus[target].name[0], len(snap.gpus[target].name)) == NVML_SUCCESS {
				for b, k in snap.gpus[target].name { if b == 0 { snap.gpus[target].name_len = k; break } }
			}
		}
		g := &snap.gpus[target]
		g.driver, g.driver_len = driver, driver_len
		u: Nvml_Utilization
		if !g.has_util && nv.utilization != nil && nv.utilization(dev, &u) == NVML_SUCCESS {
			g.util, g.has_util = f32(u.gpu), true
		}
		m: Nvml_Memory
		if nv.memory != nil && nv.memory(dev, &m) == NVML_SUCCESS {
			g.mem_used, g.mem_total, g.has_mem = m.used, m.total, true
		}
		v: u32
		if nv.temperature != nil && nv.temperature(dev, 0, &v) == NVML_SUCCESS { g.temp_c, g.has_temp = f32(v), true }
		if nv.power != nil && nv.power(dev, &v) == NVML_SUCCESS { g.power_w, g.has_power = f32(v) / 1000.0, true }
		if nv.clock != nil && nv.clock(dev, 0, &v) == NVML_SUCCESS { g.clock_mhz, g.has_clock = f32(v), true }

		// Fill per-process VRAM from NVML when PDH did not report any processes.
		if snap.proc_count == 0 {
			infos: [GPU_PROCS_MAX]Nvml_Process
			for call in ([]proc "c" (dev: Nvml_Device, n: ^u32, infos: [^]Nvml_Process) -> i32{nv.graphics, nv.compute}) {
				if call == nil { continue }
				cnt := u32(len(infos))
				if call(dev, &cnt, &infos[0]) != NVML_SUCCESS { continue }
				for p in infos[:min(int(cnt), len(infos))] {
					if p.used_gpu_memory != NVML_VALUE_NOT_AVAILABLE {
						gpu_proc_add(snap, 0, i32(p.pid), p.used_gpu_memory)
					}
				}
			}
		}
	}
}
