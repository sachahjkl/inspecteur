package inspecteur

// Windows Process Properties model (7 native Windows tabs):
// - General: UWP package, WOW64, svchost group & services, CWD via PEB, affinity, commit/peak/faults.
// - History: CPU, memory, and disk graphs.
// - Security: Integrity, Elevation, PPL protection, Critical flag, EcoQoS, GDI/USER objects + peaks,
//   paged/non-paged pools, and Token Privileges.
// - Threads: NT SystemProcessInformation threads (wait reasons, context switches, start address) +
//   Windows Wait Chain Traversal (OpenThreadWaitChainSession / GetThreadWaitChain) for deadlock detection.
// - Handles: SystemExtendedHandleInformation filtered to PID + NtQueryObject with safe named-pipe timeout guard.
// - Modules: EnumProcessModulesEx(LIST_MODULES_ALL) so both 64-bit and 32-bit WOW64 modules appear.
// - Environment: Remote PEB reader supporting both 64-bit (PEB64) and 32-bit WOW64 (PEB32) processes.
// Every refusal returns Read_State.Denied or .Gone; never crashes.

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import win "core:sys/windows"
import i18n "gt:i18n"
import process "gt:process"
import "gt:ui"
import winapi "winapi"

Props_Tab :: enum u8 { General, History, Security, Threads, Handles, Modules, Environment }

PROPS_TAB_LABELS := [Props_Tab]string{
	.General     = i18n.later("General"),
	.History     = i18n.later("History"),
	.Security    = i18n.later("Security & Resources"),
	.Threads     = i18n.later("Threads"),
	.Handles     = i18n.later("Handles"),
	.Modules     = i18n.later("Modules"),
	.Environment = i18n.later("Environment"),
}

props_tab_listed :: proc(tab: Props_Tab) -> bool {
	return tab != .General && tab != .History
}

PROPS_REFRESH_MS :: 3000
HANDLES_MAX_SHOW :: 1024

Priority :: struct { name: string, nice: i8 }

Read_State :: enum u8 { Read, Denied, Gone }

Win_Privilege_Row :: struct {
	name:  string,
	state: string,
}

Win_Thread_Row :: struct {
	tid:              i32,
	state:            string,
	wait_reason:      string,
	cpu_ns:           u64,
	priority:         i32,
	context_switches: u32,
	start_address:    u64,
	wait_chain:       string,
	deadlock:         bool,
}

Win_Handle_Row :: struct {
	handle: u64,
	type:   string,
	access: u32,
	name:   string,
}

Win_Module_Row :: struct {
	path: string,
	base: u64,
	size: u64,
}

Props_Data :: struct {
	arena:          virtual.Arena,
	read_tab:       Props_Tab,
	cwd:            string,
	cwd_read:       Read_State,
	cpus:           string,
	// Security & Resources
	gdi_objects:    u32,
	gdi_peak:       u32,
	user_objects:   u32,
	user_peak:      u32,
	privileges:     [dynamic]Win_Privilege_Row,
	sec_read:       Read_State,
	// Lists
	threads:        [dynamic]Win_Thread_Row,
	has_deadlock:   bool,
	handles:        [dynamic]Win_Handle_Row,
	handles_total:  int,
	modules:        [dynamic]Win_Module_Row,
	env:            [dynamic]string,
	list_read:      Read_State,
}

Props :: struct {
	pid:         i32,
	start:       u64,
	tab:         Props_Tab,
	data:        ^Props_Data,
	serial:      int,
	read_at:     time.Tick,
	reading:     bool,
	gone:        bool,
	nice_sel:    int,
	filter:      ui.Line_Edit,
	filter_key:  ui.Key,
	shown:       [dynamic]int,
	shown_ids:   [dynamic]u64,
	shown_of:    int,
	shown_tab:   Props_Tab,
	shown_query: string,
}

props_destroy :: proc(p: ^Props) {
	props_data_free(p.data)
	ui.line_edit_destroy(&p.filter)
	delete(p.shown)
	delete(p.shown_ids)
	delete(p.shown_query)
}

@(private = "file")
props_data_free :: proc(d: ^Props_Data) {
	if d == nil { return }
	virtual.arena_destroy(&d.arena)
	free(d)
}

props_open :: proc(app: ^App, pid: i32, start: u64) {
	props_open_tab(app, pid, start, .General)
}

props_open_tab :: proc(app: ^App, pid: i32, start: u64, tab: Props_Tab) {
	p := &app.props
	p.pid, p.start, p.tab, p.gone = pid, start, tab, false
	props_data_free(p.data)
	p.data = nil
	p.serial += 1
	ui.line_edit_clear(&p.filter)
	ui.view_open(&app.views, PROPS_VIEW, app)
	props_read(app)
}

props_shown :: proc(app: ^App) -> bool { return ui.view_is_open(&app.views, PROPS_VIEW) }

props_tick :: proc(app: ^App, alive: bool) {
	p := &app.props
	if !props_shown(app) || p.gone { return }
	if !alive { p.gone = true; return }
	if p.data == nil || p.tab != p.data.read_tab || time.duration_milliseconds(time.tick_since(p.read_at)) >= PROPS_REFRESH_MS {
		props_read(app)
	}
}

priority_index :: proc(nice: i8) -> int {
	at := 0
	for p, i in PRIORITIES { if p.nice <= nice { at = i } }
	return at
}

@(private = "file")
Props_Reading :: struct {
	pid:   i32,
	start: u64,
	tab:   Props_Tab,
	demo:  ^Demo,
	data:  ^Props_Data,
}

props_read :: proc(app: ^App) {
	p := &app.props
	if p.reading { return }
	p.reading = true
	p.read_at = time.tick_now()
	r := new(Props_Reading)
	r^ = {pid = p.pid, start = p.start, tab = p.tab, demo = app.demo, data = new(Props_Data)}
	ui.task(&app.main.state, props_work, props_done, r, props_lost)
}

@(private = "file")
props_work :: proc(data: rawptr) {
	r := (^Props_Reading)(data)
	d := r.data
	d.read_tab = r.tab
	a := virtual.arena_allocator(&d.arena)
	d.privileges = make([dynamic]Win_Privilege_Row, a)
	d.threads    = make([dynamic]Win_Thread_Row, a)
	d.handles    = make([dynamic]Win_Handle_Row, a)
	d.modules    = make([dynamic]Win_Module_Row, a)
	d.env        = make([dynamic]string, a)
	if r.demo != nil {
		demo_props_read(r.demo, r.pid, d, a)
		return
	}
	switch r.tab {
	case .General:
		d.cwd, d.cwd_read = win_proc_cwd(r.pid, r.start, a)
		if set, res, _ := win_act_affinity_read(r.pid, r.start); res == .Done {
			cpus := make([dynamic]bool, context.temp_allocator)
			for i in 0 ..< process.CPU_SET_MAX { append(&cpus, process.cpu_set_has(set, i)) }
			d.cpus = strings.clone(cpu_list_text(cpus[:]), a)
		}
	case .History:
	case .Security:
		d.sec_read = win_proc_security(r.pid, r.start, d, a)
		d.list_read = d.sec_read
	case .Threads:
		d.list_read = win_proc_threads(r.pid, r.start, &d.threads, &d.has_deadlock, a)
	case .Handles:
		d.list_read = win_proc_handles(r.pid, r.start, &d.handles, &d.handles_total, a)
	case .Modules:
		d.list_read = win_proc_modules(r.pid, r.start, &d.modules, a)
	case .Environment:
		d.list_read = win_proc_environment(r.pid, r.start, &d.env, a)
	}
}

@(private = "file")
props_done :: proc(data: rawptr, _: u64) {
	r := (^Props_Reading)(data)
	defer free(r)
	app := the_app
	if app == nil { props_data_free(r.data); return }
	p := &app.props
	p.reading = false
	if !props_shown(app) || p.pid != r.pid || p.start != r.start { props_data_free(r.data); return }
	props_data_free(p.data)
	p.data = r.data
	p.serial += 1
	if p.tab != p.data.read_tab && !p.gone { props_read(app) }
}

@(private = "file")
props_lost :: proc(data: rawptr) {
	r := (^Props_Reading)(data)
	props_data_free(r.data)
	free(r)
}

////////////////////////////////
// Dynamic Win32 loaders for Properties

@(private = "file")
Win_Props_Procs :: struct {
	LookupPrivilegeNameW:        proc "system" (sys_name: win.LPCWSTR, luid: ^win.LUID, name: [^]u16, cch: ^win.DWORD) -> win.BOOL,
	OpenThreadWaitChainSession:  proc "system" (flags: win.DWORD, cb: rawptr) -> win.HANDLE,
	CloseThreadWaitChainSession: proc "system" (h: win.HANDLE),
	GetThreadWaitChain:          proc "system" (h: win.HANDLE, ctx: uintptr, flags, tid: win.DWORD, count: ^win.DWORD, nodes: [^]winapi.WAITCHAIN_NODE_INFO, is_cycle: ^win.BOOL) -> win.BOOL,
	EnumProcessModulesEx:        proc "system" (h: win.HANDLE, mods: [^]win.HMODULE, cb: win.DWORD, needed: ^win.DWORD, filter_flag: win.DWORD) -> win.BOOL,
	GetModuleFileNameExW:        proc "system" (h: win.HANDLE, mod: win.HMODULE, buf: [^]u16, size: win.DWORD) -> win.DWORD,
	GetModuleInformation:        proc "system" (h: win.HANDLE, mod: win.HMODULE, info: ^Win_Module_Info, cb: win.DWORD) -> win.BOOL,
}

@(private = "file")
Win_Module_Info :: struct {
	lpBaseOfDll: rawptr,
	SizeOfImage: win.DWORD,
	_pad:        u32,
	EntryPoint:  rawptr,
}

@(private = "file") win_props_once: sync.Once
@(private = "file") win_props_procs: Win_Props_Procs

@(private = "file")
win_props :: proc() -> ^Win_Props_Procs {
	sync.once_do(&win_props_once, proc() {
		if adv := win_system_library("advapi32.dll"); adv != nil {
			win_props_procs.LookupPrivilegeNameW        = auto_cast win.GetProcAddress(adv, "LookupPrivilegeNameW")
			win_props_procs.OpenThreadWaitChainSession  = auto_cast win.GetProcAddress(adv, "OpenThreadWaitChainSession")
			win_props_procs.CloseThreadWaitChainSession = auto_cast win.GetProcAddress(adv, "CloseThreadWaitChainSession")
			win_props_procs.GetThreadWaitChain          = auto_cast win.GetProcAddress(adv, "GetThreadWaitChain")
		}
		k32 := win.GetModuleHandleW(win.L("kernel32.dll"))
		ps  := win_system_library("psapi.dll")
		if k32 != nil {
			win_props_procs.EnumProcessModulesEx = auto_cast win.GetProcAddress(k32, "K32EnumProcessModulesEx")
			win_props_procs.GetModuleFileNameExW = auto_cast win.GetProcAddress(k32, "K32GetModuleFileNameExW")
			win_props_procs.GetModuleInformation = auto_cast win.GetProcAddress(k32, "K32GetModuleInformation")
		}
		if ps != nil {
			if win_props_procs.EnumProcessModulesEx == nil { win_props_procs.EnumProcessModulesEx = auto_cast win.GetProcAddress(ps, "EnumProcessModulesEx") }
			if win_props_procs.GetModuleFileNameExW == nil { win_props_procs.GetModuleFileNameExW = auto_cast win.GetProcAddress(ps, "GetModuleFileNameExW") }
			if win_props_procs.GetModuleInformation == nil { win_props_procs.GetModuleInformation = auto_cast win.GetProcAddress(ps, "GetModuleInformation") }
		}
	})
	return &win_props_procs
}

////////////////////////////////
// PEB reader (same-bitness 64-bit AND WOW64 32-bit)

@(private = "file")
win_read_peb_params :: proc(h: win.HANDLE) -> (params: winapi.Decoded_Peb_Params, state: Read_State) {
	d := win_dyn()
	if d.NtQueryInformationProcess == nil { return {}, .Denied }

	// Detect WOW64 32-bit target first via ProcessWow64Information (returns 32-bit PEB address if WOW64, 0 if native 64-bit).
	wow64_peb: u64
	ret: u32
	if d.NtQueryInformationProcess(h, WIN_NT_PROC_WOW64_INFO, &wow64_peb, size_of(wow64_peb), &ret) == winapi.STATUS_SUCCESS && wow64_peb != 0 {
		peb32: winapi.PEB32_HEAD
		got: uint
		if !win.ReadProcessMemory(h, rawptr(uintptr(wow64_peb)), &peb32, size_of(peb32), &got) || got < size_of(peb32) || peb32.ProcessParameters == 0 {
			return {}, .Denied
		}
		raw_params: [size_of(winapi.RTL_USER_PROCESS_PARAMETERS32)]u8
		if !win.ReadProcessMemory(h, rawptr(uintptr(peb32.ProcessParameters)), &raw_params[0], len(raw_params), &got) || got < len(raw_params) {
			return {}, .Denied
		}
		if p, ok := winapi.decode_peb_params_32(raw_params[:]); ok { return p, .Read }
		return {}, .Denied
	}

	// Native 64-bit PEB via ProcessBasicInformation.
	pbi: winapi.PROCESS_BASIC_INFORMATION64
	st := d.NtQueryInformationProcess(h, WIN_NT_PROC_BASIC_INFO, &pbi, size_of(pbi), &ret)
	if st != winapi.STATUS_SUCCESS || pbi.PebBaseAddress == 0 {
		return {}, .Denied
	}
	peb64: winapi.PEB64_HEAD
	got: uint
	if !win.ReadProcessMemory(h, rawptr(uintptr(pbi.PebBaseAddress)), &peb64, size_of(peb64), &got) || got < size_of(peb64) || peb64.ProcessParameters == 0 {
		return {}, .Denied
	}
	raw_params: [size_of(winapi.RTL_USER_PROCESS_PARAMETERS64)]u8
	if !win.ReadProcessMemory(h, rawptr(uintptr(peb64.ProcessParameters)), &raw_params[0], len(raw_params), &got) || got < len(raw_params) {
		return {}, .Denied
	}
	if p, ok := winapi.decode_peb_params_64(raw_params[:]); ok { return p, .Read }
	return {}, .Denied
}

// Reads current working directory from the target process's PEB (supports both 64-bit and WOW64 32-bit).
win_proc_cwd :: proc(pid: i32, start: u64, a: mem.Allocator) -> (string, Read_State) {
	h, res, _ := win_open_verified(pid, start, WIN_PROCESS_QUERY_INFORMATION | WIN_PROCESS_VM_READ)
	if res == .Gone { return "", .Gone }
	if res != .Done || h == nil { return "", .Denied }
	defer win.CloseHandle(h)

	params, st := win_read_peb_params(h)
	if st != .Read || params.cwd_addr == 0 || params.cwd_len == 0 || params.cwd_len > 32768 {
		return "", st
	}
	buf := win_bytes(int(params.cwd_len))
	got: uint
	if !win.ReadProcessMemory(h, rawptr(uintptr(params.cwd_addr)), raw_data(buf), uint(len(buf)), &got) || got == 0 {
		return "", .Denied
	}
	return winapi.decode_utf16le(buf[:min(int(got), len(buf))], a), .Read
}

// Reads environment variables from the target process's PEB (supports both 64-bit and WOW64 32-bit).
win_proc_environment :: proc(pid: i32, start: u64, out: ^[dynamic]string, a: mem.Allocator) -> Read_State {
	h, res, _ := win_open_verified(pid, start, WIN_PROCESS_QUERY_INFORMATION | WIN_PROCESS_VM_READ)
	if res == .Gone { return .Gone }
	if res != .Done || h == nil { return .Denied }
	defer win.CloseHandle(h)

	params, st := win_read_peb_params(h)
	if st != .Read || params.env_addr == 0 { return .Denied }

	// Cap environment read at 512 KB to avoid huge allocations on corrupted remote pointers.
	env_bytes := int(params.env_size)
	if env_bytes <= 0 { env_bytes = 64 * 1024 }
	env_bytes = min(env_bytes, 512 * 1024)
	buf := win_bytes(env_bytes)
	got: uint
	if !win.ReadProcessMemory(h, rawptr(uintptr(params.env_addr)), raw_data(buf), uint(len(buf)), &got) || got < 2 {
		// (a read that crosses into what is not mapped reads nothing: up to the end of the first page then)

		small := min(4096 - int(params.env_addr & 4095), env_bytes)
		if !win.ReadProcessMemory(h, rawptr(uintptr(params.env_addr)), raw_data(buf), uint(small), &got) || got < 2 {
			return .Denied
		}
	}
	winapi.decode_utf16le_env_block(buf[:min(int(got), len(buf))], out, a)
	slice.sort(out[:])
	return .Read
}

////////////////////////////////
// Security, GDI/USER objects, and Token Privileges

win_proc_security :: proc(pid: i32, start: u64, d: ^Props_Data, a: mem.Allocator) -> Read_State {
	h, res, _ := win_open_verified(pid, start, WIN_PROCESS_QUERY_LIMITED_INFORMATION)
	if res == .Gone { return .Gone }
	if res != .Done || h == nil { return .Denied }
	defer win.CloseHandle(h)

	dyn := win_dyn()
	if dyn.GetGuiResources != nil {
		// GR_GDIOBJECTS=0, GR_USEROBJECTS=1, GR_GDIOBJECTS_PEAK=2, GR_USEROBJECTS_PEAK=4
		d.gdi_objects  = dyn.GetGuiResources(h, 0)
		d.user_objects = dyn.GetGuiResources(h, 1)
		d.gdi_peak     = dyn.GetGuiResources(h, 2)
		d.user_peak    = dyn.GetGuiResources(h, 4)
	}

	tok: win.HANDLE
	if !win.OpenProcessToken(h, win.TOKEN_QUERY, &tok) { return .Read }
	defer win.CloseHandle(tok)

	need: win.DWORD
	_ = win.GetTokenInformation(tok, .TokenPrivileges, nil, 0, &need)
	if need == 0 || need > 256 * 1024 { return .Read }
	buf := win_bytes(int(need))
	if !win.GetTokenInformation(tok, .TokenPrivileges, raw_data(buf), need, &need) { return .Read }
	if need < 4 { return .Read }
	count: u32
	mem.copy(&count, raw_data(buf), 4)
	avail := (int(need) - 4) / size_of(win.LUID_AND_ATTRIBUTES)
	n := min(int(count), avail)
	wp := win_props()
	SE_PRIVILEGE_ENABLED_BY_DEFAULT :: u32(0x00000001)
	SE_PRIVILEGE_ENABLED            :: u32(0x00000002)

	for i in 0 ..< n {
		la: win.LUID_AND_ATTRIBUTES
		mem.copy(&la, &buf[4 + i * size_of(win.LUID_AND_ATTRIBUTES)], size_of(la))
		pname := fmt.tprintf("LUID %d:%d", la.Luid.HighPart, la.Luid.LowPart)
		if wp.LookupPrivilegeNameW != nil {
			wbuf: [128]u16
			wlen := win.DWORD(len(wbuf))
			luid := la.Luid
			if wp.LookupPrivilegeNameW(nil, &luid, &wbuf[0], &wlen) && wlen > 0 {
				pname = win_utf16_to_utf8(wbuf[:int(wlen)], context.temp_allocator)
			}
		}
		st_str := i18n.tr("Disabled")
		if (la.Attributes & SE_PRIVILEGE_ENABLED) != 0 {
			st_str = (la.Attributes & SE_PRIVILEGE_ENABLED_BY_DEFAULT) != 0 ? i18n.tr("Enabled (default)") : i18n.tr("Enabled")
		}
		append(&d.privileges, Win_Privilege_Row{
			name  = strings.clone(pname, a),
			state = strings.clone(st_str, a),
		})
	}
	slice.sort_by(d.privileges[:], proc(x, y: Win_Privilege_Row) -> bool { return x.name < y.name })
	return .Read
}

////////////////////////////////
// Threads + Windows Wait Chain Traversal (WCT)

win_proc_threads :: proc(pid: i32, start: u64, out: ^[dynamic]Win_Thread_Row, has_deadlock: ^bool, a: mem.Allocator) -> Read_State {
	buf := make([]u8, 256 * 1024)
	defer delete(buf)
	if !win_query_system_processes(&buf) { return .Denied }
	decoded := make([dynamic]winapi.Decoded_Process, 0, 256, context.temp_allocator)
	if !winapi.decode_system_processes(buf, u64(uintptr(raw_data(buf))), &decoded, want_threads = true) { return .Denied }

	found := false
	target_threads: []winapi.Decoded_Thread
	for dp in decoded {
		if dp.pid != pid { continue }
		if dp.create_time != start { return .Gone }
		found = true
		target_threads = dp.thread_slice
		break
	}
	if !found { return .Gone }

	// Open one synchronous Wait Chain Traversal session for all threads of this process.
	wp := win_props()
	wct: win.HANDLE
	if wp.OpenThreadWaitChainSession != nil && wp.GetThreadWaitChain != nil && wp.CloseThreadWaitChainSession != nil {
		wct = wp.OpenThreadWaitChainSession(0, nil)
	}
	// (WCT_OUT_OF_PROC_FLAG and WCT_OUT_OF_PROC_CS_FLAG: without them the chain of another process's threads ends at once)
	WCT_OUT_OF_PROC :: win.DWORD(0x1 | 0x4)
	defer if wct != nil && wp.CloseThreadWaitChainSession != nil { wp.CloseThreadWaitChainSession(wct) }

	for th in target_threads {
		chain_str := ""
		deadlock := false
		// Only query WCT for waiting threads (ThreadState == 5) to keep latency small.
		if wct != nil && th.thread_state == 5 && th.tid > 0 {
			nodes: [16]winapi.WAITCHAIN_NODE_INFO
			cnt := win.DWORD(len(nodes))
			cycle: win.BOOL
			if wp.GetThreadWaitChain(wct, 0, WCT_OUT_OF_PROC, win.DWORD(th.tid), &cnt, &nodes[0], &cycle) && cnt > 1 {
				deadlock = cycle != false
				if deadlock { has_deadlock^ = true }
				chain_str = format_wait_chain(nodes[:min(int(cnt), len(nodes))], deadlock, a)
			}
		}
		append(out, Win_Thread_Row{
			tid              = th.tid,
			state            = strings.clone(win_thread_state_name(th.thread_state), a),
			wait_reason      = strings.clone(th.thread_state == 5 ? win_wait_reason_name(th.wait_reason) : "", a),
			cpu_ns           = th.cpu_ns,
			priority         = th.priority,
			context_switches = th.context_switches,
			start_address    = th.start_address,
			wait_chain       = chain_str,
			deadlock         = deadlock,
		})
	}
	return .Read
}

@(private = "file")
format_wait_chain :: proc(nodes: []winapi.WAITCHAIN_NODE_INFO, deadlock: bool, a: mem.Allocator) -> string {
	b := strings.builder_make(context.temp_allocator)
	if deadlock { strings.write_string(&b, i18n.tr("DEADLOCK: ")) }
	for node, i in nodes {
		if i == 0 { continue } // Node 0 is the queried thread itself.
		if i > 1 { strings.write_string(&b, " → ") }
		switch node.ObjectType {
		case 1: strings.write_string(&b, "CriticalSection")
		case 2: strings.write_string(&b, "SendMessage")
		case 3: strings.write_string(&b, "Mutex")
		case 4: strings.write_string(&b, "ALPC")
		case 5: strings.write_string(&b, "COM")
		case 6: strings.write_string(&b, "ThreadWait")
		case 7: strings.write_string(&b, "ProcessWait")
		case 8:
			t := node.Union.ThreadObject
			fmt.sbprintf(&b, "TID %d (PID %d)", t.ThreadId, t.ProcessId)
		case 9:  strings.write_string(&b, "COMActivation")
		case:    strings.write_string(&b, "Wait")
		}
	}
	return strings.clone(strings.to_string(b), a)
}

@(private = "file")
win_thread_state_name :: proc(st: u32) -> string {
	switch st {
	case 0: return i18n.tr("Initialized")
	case 1: return i18n.tr("Ready")
	case 2: return i18n.tr("Running")
	case 3: return i18n.tr("Standby")
	case 4: return i18n.tr("Terminated")
	case 5: return i18n.tr("Waiting")
	case 6: return i18n.tr("Transition")
	case 7: return i18n.tr("Deferred ready")
	}
	return "?"
}

@(private = "file")
win_wait_reason_name :: proc(r: u32) -> string {
	switch r {
	case 0:  return "Executive"
	case 1:  return "FreePage"
	case 2:  return "PageIn"
	case 3:  return "PoolAllocation"
	case 4:  return "DelayExecution"
	case 5:  return "Suspended"
	case 6:  return "UserRequest"
	case 7:  return "WrExecutive"
	case 8:  return "WrFreePage"
	case 9:  return "WrPageIn"
	case 10: return "WrPoolAllocation"
	case 11: return "WrDelayExecution"
	case 12: return "WrSuspended"
	case 13: return "WrUserRequest"
	case 15: return "WrQueue"
	case 16: return "WrLpcReceive"
	case 17: return "WrLpcReply"
	case 24: return "WrPushLock"
	case 25: return "WrMutex"
	case 31: return "WrFastMutex"
	case 33: return "WrAlertByThreadId"
	}
	return fmt.tprintf("#%d", r)
}

////////////////////////////////
// Handles (SystemExtendedHandleInformation + NtQueryObject with safe timeout guard)

// A query of a File's name on a thread of its own: the one of a synchronous pipe with a pending read answers when that
// read does, or never. The block is its thread's once it is abandoned: it frees it and closes the handle when it ends.
// (A raw thread: thread.destroy joins, and a join is the wait that this avoids.)
@(private = "file")
Handle_Name_Query :: struct {
	dup:   win.HANDLE,
	state: Handle_Query_State,   // atomic
	buf:   [256]u64,
	len:   int,
}

@(private = "file")
Handle_Query_State :: enum u32 { Asked, Answered, Abandoned }

@(private = "file") HANDLE_NAME_WAIT_MS     :: win.DWORD(50)
@(private = "file") HANDLE_STUCK_PER_READ   :: 4    // a reading asks no more File names after these
@(private = "file") HANDLE_STUCK_MAX        :: 16   // nor any, while these threads still wait
@(private = "file") handle_stuck: int               // atomic: abandoned threads that still wait

@(private = "file")
handle_name_thread :: proc "system" (data: rawptr) -> win.DWORD {
	q := (^Handle_Name_Query)(data)
	ret: u32
	if win_dyn_table.NtQueryObject(q.dup, 1 /* ObjectNameInformation */, &q.buf[0], size_of(q.buf), &ret) == winapi.STATUS_SUCCESS { q.len = min(int(ret), size_of(q.buf)) }
	win.CloseHandle(q.dup)
	if _, ok := intrinsics.atomic_compare_exchange_strong(&q.state, .Asked, .Answered); !ok {
		win.HeapFree(win.GetProcessHeap(), 0, q)
		intrinsics.atomic_sub(&handle_stuck, 1)
	}
	return 0
}

// The name of a File, within HANDLE_NAME_WAIT_MS. `dup` is the query's from here.
@(private = "file")
file_handle_name :: proc(dup: win.HANDLE, stuck: ^int, a: mem.Allocator) -> string {
	if stuck^ >= HANDLE_STUCK_PER_READ || intrinsics.atomic_load(&handle_stuck) >= HANDLE_STUCK_MAX { win.CloseHandle(dup); return "" }
	q := (^Handle_Name_Query)(win.HeapAlloc(win.GetProcessHeap(), win.HEAP_ZERO_MEMORY, size_of(Handle_Name_Query)))
	if q == nil { win.CloseHandle(dup); return "" }
	q.dup = dup
	th := win.CreateThread(nil, 64 * 1024, handle_name_thread, q, 0, nil)
	if th == nil {
		win.CloseHandle(dup)
		win.HeapFree(win.GetProcessHeap(), 0, q)
		return ""
	}
	defer win.CloseHandle(th)
	if win.WaitForSingleObject(th, HANDLE_NAME_WAIT_MS) != win.WAIT_OBJECT_0 {
		intrinsics.atomic_add(&handle_stuck, 1)
		if _, ok := intrinsics.atomic_compare_exchange_strong(&q.state, .Asked, .Abandoned); ok { stuck^ += 1; return "" }
		intrinsics.atomic_sub(&handle_stuck, 1)   // (it answered in between)
		// (it has nothing left to do with the block, but its thread may still run)
	}
	name := winapi.decode_unicode_string(mem.slice_to_bytes(q.buf[:])[:q.len], u64(uintptr(&q.buf[0])), a)
	win.HeapFree(win.GetProcessHeap(), 0, q)
	return name
}

// Queries a duplicated handle's NT object type and name without hanging on synchronous named pipes. Closes `dup`.
@(private = "file")
query_handle_info :: proc(dup: win.HANDLE, access: u32, stuck: ^int, a: mem.Allocator) -> (type_name, obj_name: string) {
	d := win_dyn()
	buf: [256]u64
	bytes := mem.slice_to_bytes(buf[:])
	ret: u32
	// ObjectTypeInformation = 2 (never blocks).
	if d.NtQueryObject != nil && d.NtQueryObject(dup, 2, raw_data(bytes), u32(len(bytes)), &ret) == winapi.STATUS_SUCCESS {
		type_name = winapi.decode_unicode_string(bytes, u64(uintptr(raw_data(bytes))), a)
	}
	switch {
	case type_name == "", type_name == "File" && winapi.handle_name_may_hang(access):
		win.CloseHandle(dup)
	case type_name == "File":
		obj_name = file_handle_name(dup, stuck, a)
	case:
		// The other kernel objects (Key, Mutant, Event, Section, Directory...) answer at once.
		if d.NtQueryObject(dup, 1, raw_data(bytes), u32(len(bytes)), &ret) == winapi.STATUS_SUCCESS {
			obj_name = winapi.decode_unicode_string(bytes, u64(uintptr(raw_data(bytes))), a)
		}
		win.CloseHandle(dup)
	}
	return
}

win_proc_handles :: proc(pid: i32, start: u64, out: ^[dynamic]Win_Handle_Row, total_out: ^int, a: mem.Allocator) -> Read_State {
	d := win_dyn()
	if d.NtQuerySystemInformation == nil { return .Denied }
	h, res, _ := win_open_verified(pid, start, WIN_PROCESS_DUP_HANDLE | WIN_PROCESS_QUERY_LIMITED_INFORMATION)
	if res == .Gone { return .Gone }
	if res != .Done || h == nil { return .Denied }
	defer win.CloseHandle(h)

	buf := make([]u8, 4 * 1024 * 1024)
	defer delete(buf)
	ok := false
	for _ in 0 ..< 6 {
		ret: u32
		st := d.NtQuerySystemInformation(WIN_NT_SYSTEM_EXT_HANDLES, raw_data(buf), u32(len(buf)), &ret)
		if st == winapi.STATUS_SUCCESS { ok = true; break }
		if st != winapi.STATUS_INFO_LENGTH_MISMATCH { break }
		next, gok := winapi.next_buffer_size(len(buf), ret)
		if !gok { break }
		delete(buf)
		buf = make([]u8, next)
	}
	if !ok { return .Denied }

	decoded := make([dynamic]winapi.Decoded_Handle, 0, 256, context.temp_allocator)
	if !winapi.decode_extended_handles(buf, pid, &decoded) { return .Denied }
	total_out^ = len(decoded)

	cur_proc := win.GetCurrentProcess()
	stuck := 0
	type_cache := make(map[u16]string, 64, context.temp_allocator)
	limit := min(len(decoded), HANDLES_MAX_SHOW)
	for dh in decoded[:limit] {
		tname := type_cache[dh.type_index]
		oname := ""
		dup: win.HANDLE
		if win.DuplicateHandle(h, win.HANDLE(uintptr(dh.handle)), cur_proc, &dup, 0, false, 0) {
			qt, qn := query_handle_info(dup, dh.access, &stuck, a)
			if qt != "" {
				tname = qt
				type_cache[dh.type_index] = qt
			}
			oname = qn
		}
		if tname == "" { tname = fmt.aprintf("Type #%d", dh.type_index, allocator = a) }
		append(out, Win_Handle_Row{
			handle = dh.handle,
			type   = tname,
			access = dh.access,
			name   = oname,
		})
	}
	return .Read
}

////////////////////////////////
// Modules (64-bit + WOW64 32-bit via EnumProcessModulesEx LIST_MODULES_ALL)

win_proc_modules :: proc(pid: i32, start: u64, out: ^[dynamic]Win_Module_Row, a: mem.Allocator) -> Read_State {
	wp := win_props()
	if wp.EnumProcessModulesEx == nil || wp.GetModuleFileNameExW == nil { return .Denied }
	h, res, _ := win_open_verified(pid, start, WIN_PROCESS_QUERY_INFORMATION | WIN_PROCESS_VM_READ)
	if res == .Gone { return .Gone }
	if res != .Done || h == nil { return .Denied }
	defer win.CloseHandle(h)

	LIST_MODULES_ALL :: win.DWORD(0x03)
	mods := make([]win.HMODULE, 512, context.temp_allocator)
	needed: win.DWORD
	if !wp.EnumProcessModulesEx(h, raw_data(mods), win.DWORD(len(mods) * size_of(win.HMODULE)), &needed, LIST_MODULES_ALL) {
		return .Denied
	}
	if int(needed) > len(mods) * size_of(win.HMODULE) {
		count := min(int(needed) / size_of(win.HMODULE) + 16, 4096)
		mods = make([]win.HMODULE, count, context.temp_allocator)
		if !wp.EnumProcessModulesEx(h, raw_data(mods), win.DWORD(len(mods) * size_of(win.HMODULE)), &needed, LIST_MODULES_ALL) {
			return .Denied
		}
	}
	n := min(int(needed) / size_of(win.HMODULE), len(mods))
	wbuf: [1024]u16
	for m in mods[:n] {
		plen := wp.GetModuleFileNameExW(h, m, &wbuf[0], len(wbuf))
		path := plen > 0 ? win_utf16_to_utf8(wbuf[:int(plen)], a) : ""
		info: Win_Module_Info
		if wp.GetModuleInformation != nil {
			_ = wp.GetModuleInformation(h, m, &info, size_of(info))
		}
		append(out, Win_Module_Row{
			path = path,
			base = u64(uintptr(info.lpBaseOfDll)),
			size = u64(info.SizeOfImage),
		})
	}
	return .Read
}
