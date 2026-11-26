package inspecteur

// Windows system constants, priority class mapping, verified handle opening, process safety checks
// (critical process, PPL protection, integrity, elevation), dynamic NT/Win32 loaders, and UTF-16 helpers.

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import win "core:sys/windows"
import i18n "gt:i18n"
import process "gt:process"
import timefmt "gt:timefmt"
import winapi "winapi"

// Priority classes offered on Windows, mapped onto Inspecteur's nice scale (-10..19).
// Realtime (-20) is intentionally omitted from the picker because a busy Realtime process starves input and DWM.
PRIORITIES := [?]Priority{
	{i18n.later("High"), -10},
	{i18n.later("Above normal"), -5},
	{i18n.later("Normal"), 0},
	{i18n.later("Below normal"), 5},
	{i18n.later("Idle"), 19},
}

PRIORITY_COLUMN    := i18n.later("Priority")
ADMIN              :: "an administrator"
PRIORITY_DENIED    := i18n.later("administrator privileges are required to change this process's priority")
PROCS_READ_FAILED  := i18n.later("The processes cannot be read")
HANDLES_LABEL      := i18n.later("Handles")
GPU_NVIDIA_MISSING := i18n.later("NVIDIA's driver library (nvml.dll) was not found or did not answer.")

priority_text :: proc(nice: i8) -> string {
	switch {
	case nice <= -15: return i18n.tr("Realtime")
	case nice <= -8:  return i18n.tr("High")
	case nice <= -3:  return i18n.tr("Above normal")
	case nice <= 2:   return i18n.tr("Normal")
	case nice <= 10:  return i18n.tr("Below normal")
	case:             return i18n.tr("Idle")
	}
}

// Memory page numbers in Windows terminology (Pagefile, System cache, Paged/Non-paged pool).
memory_page_stats :: proc(m: ^Machine, in_use: u64) -> (big, details: []Stat) {
	mm := m.mem
	pf_used := mm.swap_total - min(mm.swap_total, mm.swap_free)
	b := make([]Stat, 5, context.temp_allocator)
	b[0] = {i18n.tr("In use"), timefmt.size(i64(in_use))}
	b[1] = {i18n.tr("Available"), timefmt.size(i64(mm.available))}
	b[2] = {i18n.tr("Free"), timefmt.size(i64(mm.free))}
	b[3] = {i18n.tr("Committed"), fmt.tprintf("%s / %s", timefmt.size(i64(mm.committed)), timefmt.size(i64(mm.commit_limit)))}
	b[4] = {i18n.tr("Pagefile"), fmt.tprintf("%s / %s", timefmt.size(i64(pf_used)), timefmt.size(i64(mm.swap_total)))}
	d := make([]Stat, 4, context.temp_allocator)
	d[0] = {i18n.tr("Total"), timefmt.size(i64(mm.total))}
	d[1] = {i18n.tr("System cache"), timefmt.size(i64(mm.cached))}
	d[2] = {i18n.tr("Paged pool"), timefmt.size(i64(mm.reclaimable))}
	d[3] = {i18n.tr("Non-paged pool"), timefmt.size(i64(mm.buffers))}
	return b, d
}

////////////////////////////////
// Dynamic NT & Kernel32 loaders

// A library of the system, from its folder alone: the program's own folder is searched first otherwise, and most of these
// (iphlpapi, powrprof, pdh, wevtapi, dbghelp, nvml) are not KnownDLLs, so a file of that name beside the program would run.
win_system_library :: proc(name: cstring16) -> win.HMODULE {
	return win.LoadLibraryExW(win.LPCWSTR(name), nil, {.LOAD_LIBRARY_SEARCH_SYSTEM32})
}

// A buffer for a system call. Its start is aligned: the kernel refuses an unaligned one (STATUS_DATATYPE_MISALIGNMENT),
// and a slice of bytes has an alignment of 1.
win_bytes :: proc(n: int, allocator := context.temp_allocator) -> []u8 {
	return winapi.aligned_bytes(n, allocator)
}

Win_Dyn_Procs :: struct {
	NtQuerySystemInformation:    proc "system" (info_class: u32, buf: rawptr, buf_len: u32, ret_len: ^u32) -> u32,
	NtQuerySystemInformationEx:  proc "system" (info_class: u32, input_buf: rawptr, input_len: u32, out_buf: rawptr, out_len: u32, ret_len: ^u32) -> u32,
	NtQueryInformationProcess:   proc "system" (h: win.HANDLE, info_class: u32, buf: rawptr, buf_len: u32, ret_len: ^u32) -> u32,
	NtQueryObject:               proc "system" (h: win.HANDLE, info_class: u32, buf: rawptr, buf_len: u32, ret_len: ^u32) -> u32,
	NtQueryInformationThread:    proc "system" (h: win.HANDLE, info_class: u32, buf: rawptr, buf_len: u32, ret_len: ^u32) -> u32,
	GetProcessIdOfThread:        proc "system" (h: win.HANDLE) -> win.DWORD,
	NtSuspendProcess:            proc "system" (h: win.HANDLE) -> u32,
	NtResumeProcess:             proc "system" (h: win.HANDLE) -> u32,
	IsProcessCritical:           proc "system" (h: win.HANDLE, critical: ^win.BOOL) -> win.BOOL,
	GetProcessInformation:       proc "system" (h: win.HANDLE, info_class: u32, buf: rawptr, size: win.DWORD) -> win.BOOL,
	SetProcessInformation:       proc "system" (h: win.HANDLE, info_class: u32, buf: rawptr, size: win.DWORD) -> win.BOOL,
	GetPackageFullName:          proc "system" (h: win.HANDLE, length: ^u32, full_name: [^]u16) -> i32,
	GetProcessDefaultCpuSets:    proc "system" (h: win.HANDLE, ids: [^]u32, count: u32, req: ^u32) -> win.BOOL,
	SetProcessDefaultCpuSets:    proc "system" (h: win.HANDLE, ids: [^]u32, count: u32) -> win.BOOL,
	GetSystemCpuSetInformation:  proc "system" (info: rawptr, buf_len: u32, ret_len: ^u32, proc_h: win.HANDLE, flags: u32) -> win.BOOL,
	IsWow64Process:              proc "system" (h: win.HANDLE, wow64: ^win.BOOL) -> win.BOOL,
	ProcessIdToSessionId:        proc "system" (pid: win.DWORD, session_id: ^win.DWORD) -> win.BOOL,
	GetPriorityClass:            proc "system" (h: win.HANDLE) -> win.DWORD,
	SetPriorityClass:            proc "system" (h: win.HANDLE, class: win.DWORD) -> win.BOOL,
	GetProcessAffinityMask:      proc "system" (h: win.HANDLE, proc_mask: ^uintptr, sys_mask: ^uintptr) -> win.BOOL,
	SetProcessAffinityMask:      proc "system" (h: win.HANDLE, proc_mask: uintptr) -> win.BOOL,
	QueryFullProcessImageNameW:  proc "system" (h: win.HANDLE, flags: win.DWORD, buf: [^]u16, size: ^win.DWORD) -> win.BOOL,
	GetSystemFirmwareTable:      proc "system" (sig: u32, table_id: u32, buf: rawptr, size: u32) -> u32,
	GetActiveProcessorGroupCount: proc "system" () -> u16,
	GetActiveProcessorCount:     proc "system" (group: u16) -> u32,
	GetGuiResources:             proc "system" (h: win.HANDLE, flags: win.DWORD) -> win.DWORD,
}

@(private = "file")
win_dyn_once: sync.Once
// (made by win_dyn; read as it is by a thread without a context)
win_dyn_table: Win_Dyn_Procs

win_dyn :: proc() -> ^Win_Dyn_Procs {
	sync.once_do(&win_dyn_once, proc() {
		nt := win.GetModuleHandleW(win.L("ntdll.dll"))
		if nt != nil {
			win_dyn_table.NtQuerySystemInformation   = auto_cast win.GetProcAddress(nt, "NtQuerySystemInformation")
			win_dyn_table.NtQuerySystemInformationEx = auto_cast win.GetProcAddress(nt, "NtQuerySystemInformationEx")
			win_dyn_table.NtQueryInformationProcess  = auto_cast win.GetProcAddress(nt, "NtQueryInformationProcess")
			win_dyn_table.NtQueryObject              = auto_cast win.GetProcAddress(nt, "NtQueryObject")
			win_dyn_table.NtQueryInformationThread   = auto_cast win.GetProcAddress(nt, "NtQueryInformationThread")
			win_dyn_table.NtSuspendProcess           = auto_cast win.GetProcAddress(nt, "NtSuspendProcess")
			win_dyn_table.NtResumeProcess            = auto_cast win.GetProcAddress(nt, "NtResumeProcess")
		}
		k32 := win.GetModuleHandleW(win.L("kernel32.dll"))
		if k32 != nil {
			win_dyn_table.IsProcessCritical            = auto_cast win.GetProcAddress(k32, "IsProcessCritical")
			win_dyn_table.GetProcessInformation        = auto_cast win.GetProcAddress(k32, "GetProcessInformation")
			win_dyn_table.SetProcessInformation        = auto_cast win.GetProcAddress(k32, "SetProcessInformation")
			win_dyn_table.GetPackageFullName           = auto_cast win.GetProcAddress(k32, "GetPackageFullName")
			win_dyn_table.GetProcessDefaultCpuSets     = auto_cast win.GetProcAddress(k32, "GetProcessDefaultCpuSets")
			win_dyn_table.SetProcessDefaultCpuSets     = auto_cast win.GetProcAddress(k32, "SetProcessDefaultCpuSets")
			win_dyn_table.GetSystemCpuSetInformation   = auto_cast win.GetProcAddress(k32, "GetSystemCpuSetInformation")
			win_dyn_table.GetProcessIdOfThread         = auto_cast win.GetProcAddress(k32, "GetProcessIdOfThread")
			win_dyn_table.IsWow64Process               = auto_cast win.GetProcAddress(k32, "IsWow64Process")
			win_dyn_table.ProcessIdToSessionId         = auto_cast win.GetProcAddress(k32, "ProcessIdToSessionId")
			win_dyn_table.GetPriorityClass             = auto_cast win.GetProcAddress(k32, "GetPriorityClass")
			win_dyn_table.SetPriorityClass             = auto_cast win.GetProcAddress(k32, "SetPriorityClass")
			win_dyn_table.GetProcessAffinityMask       = auto_cast win.GetProcAddress(k32, "GetProcessAffinityMask")
			win_dyn_table.SetProcessAffinityMask       = auto_cast win.GetProcAddress(k32, "SetProcessAffinityMask")
			win_dyn_table.QueryFullProcessImageNameW   = auto_cast win.GetProcAddress(k32, "QueryFullProcessImageNameW")
			win_dyn_table.GetSystemFirmwareTable       = auto_cast win.GetProcAddress(k32, "GetSystemFirmwareTable")
			win_dyn_table.GetActiveProcessorGroupCount = auto_cast win.GetProcAddress(k32, "GetActiveProcessorGroupCount")
			win_dyn_table.GetActiveProcessorCount      = auto_cast win.GetProcAddress(k32, "GetActiveProcessorCount")
		}
		u32_mod := win.GetModuleHandleW(win.L("user32.dll"))
		if u32_mod == nil { u32_mod = win_system_library("user32.dll") }
		if u32_mod != nil {
			win_dyn_table.GetGuiResources = auto_cast win.GetProcAddress(u32_mod, "GetGuiResources")
		}
	})
	return &win_dyn_table
}

////////////////////////////////
// Process identity & safety

WIN_PROCESS_TERMINATE                 :: win.DWORD(0x0001)
WIN_PROCESS_VM_READ                   :: win.DWORD(0x0010)
WIN_PROCESS_DUP_HANDLE                :: win.DWORD(0x0040)
WIN_PROCESS_SET_INFORMATION           :: win.DWORD(0x0200)
WIN_PROCESS_QUERY_INFORMATION         :: win.DWORD(0x0400)
WIN_PROCESS_SUSPEND_RESUME            :: win.DWORD(0x0800)
WIN_PROCESS_QUERY_LIMITED_INFORMATION :: win.DWORD(0x1000)

WIN_NT_SYSTEM_PROCESS_INFO   :: u32(5)
WIN_NT_SYSTEM_TIMEOFDAY_INFO :: u32(3)
WIN_NT_SYSTEM_PERF_INFO      :: u32(8)
WIN_NT_SYSTEM_EXT_HANDLES    :: u32(64)

WIN_NT_PROC_BASIC_INFO       :: u32(0)
WIN_NT_PROC_WOW64_INFO       :: u32(26)
WIN_NT_PROC_CMDLINE_INFO     :: u32(60)
WIN_NT_PROC_PROTECTION_INFO  :: u32(61)

WIN_PROC_INFO_POWER_THROTTLING :: u32(4)

win_filetime_u64 :: proc(ft: win.FILETIME) -> u64 {
	return u64(ft.dwLowDateTime) | (u64(ft.dwHighDateTime) << 32)
}

win_proc_create_time :: proc(h: win.HANDLE) -> (u64, bool) {
	c, e, k, u: win.FILETIME
	if !win.GetProcessTimes(h, &c, &e, &k, &u) { return 0, false }
	return win_filetime_u64(c), true
}

// Opens a process handle and immediately verifies GetProcessTimes creation time against `start`.
// If the PID was recycled or ended, closes the handle and returns .Gone so the wrong process is never touched. An unknown
// start (0) proves nothing: it is .Gone too. While a handle on a process is open, its PID is not given to another one.
win_open_verified :: proc(pid: i32, start: u64, access: win.DWORD) -> (h: win.HANDLE, res: process.Act_Result, err: int) {
	if pid <= 0 || start == 0 { return nil, .Gone, 0 }
	want := access | WIN_PROCESS_QUERY_LIMITED_INFORMATION
	h = win.OpenProcess(want, false, win.DWORD(pid))
	if h == nil {
		e := win.GetLastError()
		switch e {
		case win.ERROR_ACCESS_DENIED:     return nil, .Denied, int(e)
		case win.ERROR_INVALID_PARAMETER: return nil, .Gone, int(e)
		case:                             return nil, .Failed, int(e)
		}
	}
	ct, ok := win_proc_create_time(h)
	if !ok || ct != start {
		win.CloseHandle(h)
		return nil, .Gone, 0
	}
	return h, .Done, 0
}

// Opens a process to act on it with `access`: the same process, neither critical nor protected. The query handle stays
// open until the other one is there, so both are of one process.
win_open_for_act :: proc(pid: i32, start: u64, access: win.DWORD) -> (h: win.HANDLE, res: process.Act_Result, err: int, refusal: Refusal_Kind, detail: string) {
	qh: win.HANDLE
	qh, res, err = win_open_verified(pid, start, WIN_PROCESS_QUERY_LIMITED_INFORMATION)
	if res != .Done { return nil, res, err, .None, "" }
	defer win.CloseHandle(qh)
	s := win_query_process_safety(qh)
	if s.critical { return nil, .Denied, 0, .Critical, "" }
	if label, prot := winapi.decode_protection_level(s.protection); prot { return nil, .Denied, 0, .Protected, label }
	// (whether it is critical or protected could not be read: nothing says that acting on it is safe)
	if !s.known { return nil, .Failed, 0, .None, "" }
	h, res, err = win_open_verified(pid, start, access)
	return h, res, err, .None, ""
}

Win_Process_Safety :: struct {
	known:      bool,   // critical and protection were both read
	critical:   bool,
	protection: u8,
	elevated:   bool,
	integrity:  winapi.Integrity_Level,
	wow64:      bool,
	efficiency: bool,
}

// Reads critical, PPL protection, elevation, integrity, WOW64, and EcoQoS state from an open handle
// (requires only PROCESS_QUERY_LIMITED_INFORMATION).
win_query_process_safety :: proc(h: win.HANDLE) -> (s: Win_Process_Safety) {
	d := win_dyn()
	known := 0
	if d.IsProcessCritical != nil {
		crit: win.BOOL
		if d.IsProcessCritical(h, &crit) {
			known += 1
			s.critical = bool(crit)
		}
	}
	if d.NtQueryInformationProcess != nil {
		prot: winapi.PS_PROTECTION
		ret: u32
		if d.NtQueryInformationProcess(h, WIN_NT_PROC_PROTECTION_INFO, &prot, size_of(prot), &ret) == winapi.STATUS_SUCCESS {
			known += 1
			s.protection = prot.Level
		}
	}
	s.known = known == 2
	if d.IsWow64Process != nil {
		w: win.BOOL
		if d.IsWow64Process(h, &w) && w != false { s.wow64 = true }
	}
	if d.GetProcessInformation != nil {
		pt := winapi.PROCESS_POWER_THROTTLING_STATE{Version = winapi.PROCESS_POWER_THROTTLING_CURRENT_VERSION}
		if d.GetProcessInformation(h, WIN_PROC_INFO_POWER_THROTTLING, &pt, size_of(pt)) {
			if (pt.ControlMask & winapi.PROCESS_POWER_THROTTLING_EXECUTION_SPEED) != 0 &&
				(pt.StateMask & winapi.PROCESS_POWER_THROTTLING_EXECUTION_SPEED) != 0 {
				s.efficiency = true
			}
		}
	}
	tok: win.HANDLE
	if win.OpenProcessToken(h, win.TOKEN_QUERY, &tok) {
		defer win.CloseHandle(tok)
		// TokenElevation (class 20)
		elev: u32
		ret_len: win.DWORD
		if win.GetTokenInformation(tok, win.TOKEN_INFORMATION_CLASS(20), &elev, size_of(elev), &ret_len) {
			s.elevated = elev != 0
		}
		// TokenIntegrityLevel (class 25)
		buf: [16]u64
		if win.GetTokenInformation(tok, win.TOKEN_INFORMATION_CLASS(25), &buf[0], size_of(buf), &ret_len) && ret_len >= size_of(win.SID_AND_ATTRIBUTES) {
			sa := (^win.SID_AND_ATTRIBUTES)(&buf[0])
			if sa.Sid != nil {
				s.integrity = win_sid_integrity(sa.Sid)
			}
		}
	}
	return
}

// Extracts the final sub-authority RID of a mandatory integrity SID without extra advapi32 bindings.
win_sid_integrity :: proc(sid: win.PSID) -> winapi.Integrity_Level {
	raw := ([^]u8)(sid)
	sub_count := raw[1]
	if sub_count == 0 || sub_count > 15 { return .Unknown }
	// SID binary layout: Revision(1), SubAuthorityCount(1), IdentifierAuthority(6), SubAuthority[count](u32 each).
	off := 8 + int(sub_count - 1) * 4
	rid: u32
	mem.copy(&rid, raw[off:], 4)
	return winapi.decode_integrity_rid(rid)
}

// Whether Inspecteur itself is currently running with an elevated administrator token.
win_is_elevated :: proc() -> bool {
	tok: win.HANDLE
	if !win.OpenProcessToken(win.GetCurrentProcess(), win.TOKEN_QUERY, &tok) { return false }
	defer win.CloseHandle(tok)
	elev: u32
	ret_len: win.DWORD
	if !win.GetTokenInformation(tok, win.TOKEN_INFORMATION_CLASS(20), &elev, size_of(elev), &ret_len) { return false }
	return elev != 0
}

integrity_label :: proc(lvl: winapi.Integrity_Level) -> string {
	switch lvl {
	case .Unknown:     return ""
	case .Untrusted:   return i18n.tr("Untrusted")
	case .Low:         return i18n.tr("Low")
	case .Medium:      return i18n.tr("Medium")
	case .Medium_Plus: return i18n.tr("Medium high")
	case .High:        return i18n.tr("High")
	case .System:      return i18n.tr("System")
	case .Protected:   return i18n.tr("Protected")
	}
	return ""
}

////////////////////////////////
// Suspension

// ThreadSuspendCount (Windows 8.1)
WIN_NT_THREAD_SUSPEND_COUNT :: u32(35)

// The suspend count of a thread of the process `pid`. `gone`: it ended, or its id is another process's thread now.
win_thread_suspend_count :: proc(pid, tid: i32) -> (count: u32, gone, ok: bool, status: u32) {
	d := win_dyn()
	if d.NtQueryInformationThread == nil || d.GetProcessIdOfThread == nil { return }
	h := win.OpenThread(win.THREAD_QUERY_INFORMATION, false, win.DWORD(tid))
	if h == nil && win.GetLastError() == win.ERROR_ACCESS_DENIED { h = win.OpenThread(win.THREAD_QUERY_LIMITED_INFORMATION, false, win.DWORD(tid)) }
	if h == nil {
		e := win.GetLastError()
		return 0, e == win.ERROR_INVALID_PARAMETER, false, u32(e)
	}
	defer win.CloseHandle(h)
	if d.GetProcessIdOfThread(h) != win.DWORD(pid) { return 0, true, false, 0 }
	status = d.NtQueryInformationThread(h, WIN_NT_THREAD_SUSPEND_COUNT, &count, size_of(count), nil)
	if status == winapi.STATUS_SUCCESS { return count, false, true, status }
	STATUS_THREAD_IS_TERMINATING :: u32(0xC000004B)
	return 0, status == STATUS_THREAD_IS_TERMINATING, false, status
}

// Whether the process is suspended, now, by its threads' counts. The caller holds a verified handle on it when it acts on
// the answer. `raw` (temporary): each thread's state, wait reason and count, or why it was not read.
win_suspension :: proc(pid: i32, start: u64) -> (s: winapi.Suspension, raw: string) {
	buf := win_bytes(256 * 1024, context.allocator)
	defer delete(buf)
	q: Win_Nt_Query
	if !win_query_system_processes(&buf, &q) { return .Unknown, fmt.tprintf("the processes cannot be read: %s", win_nt_query_text(q)) }
	decoded := make([dynamic]winapi.Decoded_Process, 0, 256, context.temp_allocator)
	if !winapi.decode_system_processes(buf, u64(uintptr(raw_data(buf))), &decoded, want_threads = true) { return .Unknown, "not decoded" }
	for dp in decoded {
		if dp.pid != pid || dp.create_time != start { continue }
		counts := make([dynamic]u32, 0, len(dp.thread_slice), context.temp_allocator)
		read := true
		b := strings.builder_make(context.temp_allocator)
		for th in dp.thread_slice {
			count, gone, ok, status := win_thread_suspend_count(pid, th.tid)
			fmt.sbprintf(&b, "[%d: state %d, reason %d, count %d%s] ", th.tid, th.thread_state, th.wait_reason, count, ok ? "" : fmt.tprintf(", not read 0x%08X", status))
			if ok { append(&counts, count) } else if !gone { read = false }
		}
		return winapi.suspension_of(counts[:], read, dp.all_suspended), strings.to_string(b)
	}
	return .Unknown, "not among the processes"
}

// The processes this program suspended, for the reader of the table (Proc_Reader.suspended): a hint that it checks.
@(private = "file") win_suspended_lock: sync.Mutex
@(private = "file") win_suspended_new:  [dynamic]Target

win_suspended_note :: proc(pid: i32, start: u64) {
	sync.lock(&win_suspended_lock)
	defer sync.unlock(&win_suspended_lock)
	// (the process's own list, never the caller's allocator: a test's tracking allocator would call it a leak)
	if win_suspended_new.allocator.procedure == nil { win_suspended_new.allocator = runtime.heap_allocator() }
	if len(win_suspended_new) < 1024 { append(&win_suspended_new, Target{pid, start}) }
}

win_suspended_take :: proc(out: ^map[i32]u64) {
	sync.lock(&win_suspended_lock)
	defer sync.unlock(&win_suspended_lock)
	for t in win_suspended_new { out[t.pid] = t.start }
	clear(&win_suspended_new)
}

////////////////////////////////
// UTF-16 and Registry helpers

win_utf16_to_utf8 :: proc(w: []u16, allocator := context.temp_allocator) -> string {
	end := len(w)
	for c, i in w { if c == 0 { end = i; break } }
	if end == 0 { return "" }
	res, err := win.utf16_to_utf8(w[:end], allocator)
	if err != nil { return "" }
	return res
}

win_wstr_to_utf8 :: proc(p: [^]u16, max_chars := 32768, allocator := context.temp_allocator) -> string {
	if p == nil { return "" }
	n := 0
	for n < max_chars && p[n] != 0 { n += 1 }
	if n == 0 { return "" }
	res, err := win.utf16_to_utf8(p[:n], allocator)
	if err != nil { return "" }
	return res
}

WIN_ERROR_BUFFER_OVERFLOW :: win.DWORD(111)
WIN_ERROR_MORE_DATA       :: win.DWORD(234)
WIN_ERROR_NO_MORE_ITEMS   :: win.DWORD(259)

@(private = "file") RRF_RT_ANY :: win.DWORD(0x0000FFFF)

win_reg_read_string :: proc(root: win.HKEY, subkey, value_name: string, wow64_flags: win.DWORD = 0, allocator := context.temp_allocator) -> (string, bool) {
	hk: win.HKEY
	sk := win.utf8_to_wstring(subkey, context.temp_allocator)
	if win.RegOpenKeyExW(root, sk, 0, win.KEY_READ | wow64_flags, &hk) != 0 { return "", false }
	defer win.RegCloseKey(hk)
	return win_reg_query_string_handle(hk, value_name, allocator)
}

win_reg_query_string_handle :: proc(hk: win.HKEY, value_name: string, allocator := context.temp_allocator) -> (string, bool) {
	vn := value_name != "" ? win.utf8_to_wstring(value_name, context.temp_allocator) : nil
	typ: win.DWORD
	size: win.DWORD
	if win.RegGetValueW(hk, nil, vn, RRF_RT_ANY, &typ, nil, &size) != 0 || size == 0 { return "", false }
	if typ != win.REG_SZ && typ != win.REG_EXPAND_SZ { return "", false }
	buf := win_bytes(int(size) + 2)
	if win.RegGetValueW(hk, nil, vn, RRF_RT_ANY, &typ, &buf[0], &size) != 0 { return "", false }
	return winapi.decode_utf16le(buf[:min(int(size), len(buf))], allocator), true
}

win_reg_read_dword :: proc(root: win.HKEY, subkey, value_name: string, wow64_flags: win.DWORD = 0) -> (u32, bool) {
	hk: win.HKEY
	sk := win.utf8_to_wstring(subkey, context.temp_allocator)
	if win.RegOpenKeyExW(root, sk, 0, win.KEY_READ | wow64_flags, &hk) != 0 { return 0, false }
	defer win.RegCloseKey(hk)
	vn := win.utf8_to_wstring(value_name, context.temp_allocator)
	typ: win.DWORD
	val: u32
	size := win.DWORD(size_of(val))
	if win.RegGetValueW(hk, nil, vn, RRF_RT_ANY, &typ, &val, &size) != 0 || typ != win.REG_DWORD { return 0, false }
	return val, true
}

win_reg_read_binary :: proc(root: win.HKEY, subkey, value_name: string, wow64_flags: win.DWORD = 0, allocator := context.temp_allocator) -> ([]u8, bool) {
	hk: win.HKEY
	sk := win.utf8_to_wstring(subkey, context.temp_allocator)
	if win.RegOpenKeyExW(root, sk, 0, win.KEY_READ | wow64_flags, &hk) != 0 { return nil, false }
	defer win.RegCloseKey(hk)
	vn := win.utf8_to_wstring(value_name, context.temp_allocator)
	typ: win.DWORD
	size: win.DWORD
	if win.RegGetValueW(hk, nil, vn, RRF_RT_ANY, &typ, nil, &size) != 0 || size == 0 { return nil, false }
	if typ != win.REG_BINARY { return nil, false }
	buf := win_bytes(int(size), allocator)
	if win.RegGetValueW(hk, nil, vn, RRF_RT_ANY, &typ, &buf[0], &size) != 0 { return nil, false }
	return buf[:min(int(size), len(buf))], true
}

win_expand_env :: proc(path: string, allocator := context.temp_allocator) -> string {
	if strings.index_byte(path, '%') < 0 { return strings.clone(path, allocator) }
	w := win.utf8_to_wstring(path, context.temp_allocator)
	n := win.ExpandEnvironmentStringsW(w, nil, 0)
	if n == 0 { return strings.clone(path, allocator) }
	buf := make([]u16, int(n), context.temp_allocator)
	got := win.ExpandEnvironmentStringsW(w, raw_data(buf), n)
	if got == 0 || got > n { return strings.clone(path, allocator) }
	return win_utf16_to_utf8(buf, allocator)
}

win_now_filetime :: proc() -> i64 {
	ft: win.FILETIME
	win.GetSystemTimeAsFileTime(&ft)
	return i64(win_filetime_u64(ft))
}
