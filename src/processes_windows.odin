package inspecteur

// Windows process reader:
// - Every sample reads all processes in ONE NtQuerySystemInformation(SystemProcessInformation) call
//   into a reused growing buffer (never one OpenProcess per process per sample).
// - Static per-process facts (exe, command line, user via cached SID map, integrity, elevation, PPL,
//   critical flag, WOW64, EcoQoS, UWP package, svchost group) are read ONCE per (pid, creation_time).

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import win "core:sys/windows"
import winapi "winapi"

Proc_Counters_Extra :: struct {
	handles:          u32,
	session_id:       u32,
	commit:           u64,
	page_faults:      u32,
	peak_working_set: u64,
	paged_pool:       u64,
	nonpaged_pool:    u64,
}

Proc_Facts_Extra :: struct {
	integrity:     winapi.Integrity_Level,
	protection:    u8,
	critical:      bool,
	elevated:      bool,
	efficiency:    bool,
	wow64:         bool,
	priority_ok:   bool,
	priority_nice: i8,
	uwp_package:   string,
	svchost_group: string,
	service_names: string,
}

Proc_Extra :: struct {
	handles:          u32,
	session_id:       u32,
	commit:           u64,
	page_faults:      u32,
	peak_working_set: u64,
	paged_pool:       u64,
	nonpaged_pool:    u64,
	integrity:        winapi.Integrity_Level,
	protection:       u8,
	critical:         bool,
	elevated:         bool,
	efficiency:       bool,
	wow64:            bool,
	uwp_package:      string,   // owned
	svchost_group:    string,   // owned
	service_names:    string,   // owned: comma-separated SCM service names hosted in this process
}

proc_learn_extra :: proc(p: ^Proc, c: Proc_Counters, f: Proc_Facts) {
	p.extra.integrity     = f.extra.integrity
	p.extra.protection    = f.extra.protection
	p.extra.critical      = f.extra.critical
	p.extra.elevated      = f.extra.elevated
	p.extra.efficiency    = f.extra.efficiency
	p.extra.wow64         = f.extra.wow64
	p.extra.uwp_package   = strings.clone(f.extra.uwp_package)
	p.extra.svchost_group = strings.clone(f.extra.svchost_group)
	p.extra.service_names = strings.clone(f.extra.service_names)
	if f.extra.priority_ok { p.nice = f.extra.priority_nice }
	if f.extra.service_names != "" {
		first := f.extra.service_names
		if comma := strings.index_byte(first, ','); comma >= 0 { first = first[:comma] }
		delete(p.unit)
		p.unit = strings.clone(first)
	}
}

proc_update_extra :: proc(p: ^Proc, c: Proc_Counters) {
	p.extra.handles          = c.extra.handles
	p.extra.session_id       = c.extra.session_id
	p.extra.commit           = c.extra.commit
	p.extra.page_faults      = c.extra.page_faults
	p.extra.peak_working_set = c.extra.peak_working_set
	p.extra.paged_pool       = c.extra.paged_pool
	p.extra.nonpaged_pool    = c.extra.nonpaged_pool
}

proc_free_extra :: proc(p: ^Proc) {
	delete(p.extra.uwp_package)
	delete(p.extra.svchost_group)
	delete(p.extra.service_names)
}

proc_has_service :: proc(p: ^Proc) -> bool {
	return p.unit != "" || p.extra.service_names != ""
}

// Reused reader state owned solely by the sampling job thread.
Proc_Reader :: struct {
	buf:          []u8,                 // reused growing buffer for SystemProcessInformation
	query:        Win_Nt_Query,         // what its last query answered
	sid_cache:    map[string]string,    // binary SID key -> owned "DOMAIN\User"
	svc_by_pid:   map[i32]string,       // PID -> owned comma-separated SCM service names
	suspended:    map[i32]u64,          // pid -> start: those known as suspended, checked at each reading
	audit:        int,                  // where the walk of the processes not known as such is
	svc_ticks:    int,                  // refreshes svc_by_pid periodically
}

@(private = "file") SID_CACHE_MAX :: 4096
@(private = "file") SVC_MAP_EVERY :: 10

proc_reader_init :: proc(r: ^Proc_Reader) -> bool {
	if win_dyn().NtQuerySystemInformation == nil { return false }
	r.buf = win_bytes(256 * 1024, context.allocator)
	r.sid_cache = make(map[string]string, 64)
	r.svc_by_pid = make(map[i32]string, 64)
	return true
}

proc_reader_destroy :: proc(r: ^Proc_Reader) {
	delete(r.buf)
	for k, v in r.sid_cache { delete(k); delete(v) }
	delete(r.sid_cache)
	for _, v in r.svc_by_pid { delete(v) }
	delete(r.svc_by_pid)
	delete(r.suspended)
	r^ = {}
}

// What the last query answered: its NTSTATUS, the bytes it was given, those it said it needs, the tries.
Win_Nt_Query :: struct { status, given, needed: u32, tries: int }

win_nt_query_text :: proc(q: Win_Nt_Query) -> string {
	return fmt.tprintf("NTSTATUS 0x%08X, %d bytes given, %d needed, %d tries", q.status, q.given, q.needed, q.tries)
}

// Queries SystemProcessInformation into `buf` (growing as needed; context.allocator's). A buffer too small is answered
// with STATUS_INFO_LENGTH_MISMATCH, or STATUS_BUFFER_TOO_SMALL on some builds: both grow it.
win_query_system_processes :: proc(buf: ^[]u8, q: ^Win_Nt_Query = nil) -> bool {
	d := win_dyn()
	local: Win_Nt_Query
	q := q != nil ? q : &local
	q^ = {}
	if d.NtQuerySystemInformation == nil { q.status = 0xC0000002; return false }   // (STATUS_NOT_IMPLEMENTED)
	if len(buf^) < 64 * 1024 || uintptr(raw_data(buf^)) % 16 != 0 {
		delete(buf^)
		buf^ = win_bytes(256 * 1024, context.allocator)
	}
	for q.tries < 8 {
		q.tries += 1
		q.given, q.needed = u32(len(buf^)), 0
		q.status = d.NtQuerySystemInformation(WIN_NT_SYSTEM_PROCESS_INFO, raw_data(buf^), q.given, &q.needed)
		if q.status == winapi.STATUS_SUCCESS { return true }
		if q.status != winapi.STATUS_INFO_LENGTH_MISMATCH && q.status != winapi.STATUS_BUFFER_TOO_SMALL { return false }
		next, ok := winapi.next_buffer_size(len(buf^), q.needed)
		if !ok { return false }
		delete(buf^)
		buf^ = win_bytes(next, context.allocator)
	}
	return false
}

// "" when the last reading of the processes was read; else why not (the window says it, and keeps the last list).
procs_read_problem :: proc(r: ^Proc_Reader) -> string {
	if r.query.status == winapi.STATUS_SUCCESS { return "" }
	return win_nt_query_text(r.query)
}

procs_read :: proc(r: ^Proc_Reader, out: ^[dynamic]Proc_Counters) {
	if !win_query_system_processes(&r.buf, &r.query) { return }
	if r.svc_ticks % SVC_MAP_EVERY == 0 {
		win_refresh_service_pid_map(&r.svc_by_pid)
	}
	r.svc_ticks += 1

	decoded := make([dynamic]winapi.Decoded_Process, 0, 256, context.temp_allocator)
	if !winapi.decode_system_processes(r.buf, u64(uintptr(raw_data(r.buf))), &decoded) { r.query.status = winapi.STATUS_DATA_ERROR; return }

	created := make(map[i32]u64, len(decoded), context.temp_allocator)
	for dp in decoded { created[dp.pid] = dp.create_time }
	suspended_check(r, decoded[:])
	for dp in decoded {
		// PID 0 is System Idle Process; skip so CPU % sums against real processes as on Linux.
		if dp.pid == 0 { continue }
		name := dp.name
		if name == "" && dp.pid == 4 { name = "System" }
		state := Proc_State.Sleeping
		if dp.all_suspended || dp.create_time != 0 && r.suspended[dp.pid] == dp.create_time { state = .Stopped } else if dp.any_running { state = .Running }
		append(out, Proc_Counters{
			pid      = dp.pid,
			ppid     = winapi.true_parent(dp.ppid, dp.create_time, created),
			start    = dp.create_time,
			comm     = name,
			cpu_ns   = dp.cpu_ns,
			threads  = dp.threads,
			state    = state,
			nice     = winapi.base_priority_to_nice(dp.base_priority),
			resident = dp.working_set,
			private  = dp.private_ws,
			io_read  = dp.io_read,
			io_write = dp.io_write,
			io_known = true,
			extra = {
				handles          = dp.handles,
				session_id       = dp.session_id,
				commit           = dp.commit,
				page_faults      = dp.page_faults,
				peak_working_set = dp.peak_working_set,
				paged_pool       = dp.paged_pool,
				nonpaged_pool    = dp.nonpaged_pool,
			},
		})
	}
	slice.sort_by(out[:], proc(a, b: Proc_Counters) -> bool { return a.pid < b.pid })
}

// Reads once-per-process facts for a newly seen (pid, creation_time).
proc_facts :: proc(r: ^Proc_Reader, c: Proc_Counters) -> (f: Proc_Facts) {
	f.name = c.comm
	f.started = winapi.filetime_to_unix_sec(i64(c.start))
	if svcs, ok := r.svc_by_pid[c.pid]; ok {
		f.extra.service_names = strings.clone(svcs, context.temp_allocator)
	}
	if c.pid == 4 {
		f.user = "NT AUTHORITY\\SYSTEM"
		f.extra.integrity = .System
		f.extra.critical = true
		return
	}

	h, res, _ := win_open_verified(c.pid, c.start, WIN_PROCESS_QUERY_LIMITED_INFORMATION)
	if res != .Done || h == nil { return }
	defer win.CloseHandle(h)

	d := win_dyn()
	// Executable path (works with PROCESS_QUERY_LIMITED_INFORMATION).
	if d.QueryFullProcessImageNameW != nil {
		wbuf: [1024]u16
		sz := win.DWORD(len(wbuf))
		if d.QueryFullProcessImageNameW(h, 0, &wbuf[0], &sz) && sz > 0 {
			f.exe = win_utf16_to_utf8(wbuf[:int(sz)], context.temp_allocator)
		}
	}

	// Exact priority class.
	if d.GetPriorityClass != nil {
		if pc := d.GetPriorityClass(h); pc != 0 {
			f.extra.priority_ok = true
			f.extra.priority_nice = winapi.priority_class_to_nice(pc)
		}
	}

	// Command line via ProcessCommandLineInformation (works on Windows 8.1+ with QUERY_LIMITED_INFORMATION).
	if d.NtQueryInformationProcess != nil {
		// (a UNICODE_STRING, then its text: 32767 characters at most. Its size is asked first)
		small: [512]u64
		cmd_buf := mem.slice_to_bytes(small[:])
		ret: u32
		st := d.NtQueryInformationProcess(h, WIN_NT_PROC_CMDLINE_INFO, raw_data(cmd_buf), u32(len(cmd_buf)), &ret)
		if st != winapi.STATUS_SUCCESS && int(ret) > len(cmd_buf) && ret <= 1 << 17 {
			cmd_buf = win_bytes(int(ret))
			st = d.NtQueryInformationProcess(h, WIN_NT_PROC_CMDLINE_INFO, raw_data(cmd_buf), u32(len(cmd_buf)), &ret)
		}
		if st == winapi.STATUS_SUCCESS {
			f.cmdline = winapi.decode_unicode_string(cmd_buf, u64(uintptr(raw_data(cmd_buf))))
		}
	}

	// Safety & security flags.
	safety := win_query_process_safety(h)
	f.extra.integrity  = safety.integrity
	f.extra.protection = safety.protection
	f.extra.critical   = safety.critical
	f.extra.elevated   = safety.elevated
	f.extra.efficiency = safety.efficiency
	f.extra.wow64      = safety.wow64

	// UWP package full name if packaged.
	if d.GetPackageFullName != nil {
		plen := u32(256)
		pbuf: [256]u16
		if d.GetPackageFullName(h, &plen, &pbuf[0]) == 0 && plen > 1 {
			f.extra.uwp_package = win_utf16_to_utf8(pbuf[:int(plen) - 1], context.temp_allocator)
		}
	}

	// svchost service group name.
	if strings.equal_fold(f.name, "svchost.exe") && f.cmdline != "" {
		f.extra.svchost_group = winapi.parse_svchost_group(f.cmdline)
	}

	// User name from process token SID, cached in r.sid_cache so LookupAccountSidW runs once per SID.
	tok: win.HANDLE
	if win.OpenProcessToken(h, win.TOKEN_QUERY, &tok) {
		defer win.CloseHandle(tok)
		tbuf: [32]u64
		ret_len: win.DWORD
		if win.GetTokenInformation(tok, .TokenUser, &tbuf[0], size_of(tbuf), &ret_len) && ret_len >= size_of(win.TOKEN_USER) {
			tu := (^win.TOKEN_USER)(&tbuf[0])
			if tu.User.Sid != nil {
				f.user = win_sid_lookup_cached(r, tu.User.Sid)
			}
		}
	}
	return
}

@(private = "file")
win_sid_lookup_cached :: proc(r: ^Proc_Reader, sid: win.PSID) -> string {
	raw := ([^]u8)(sid)
	sub_count := int(raw[1])
	if sub_count < 0 || sub_count > 15 { return "" }
	sid_len := 8 + sub_count * 4
	key := string(raw[:sid_len])
	if cached, ok := r.sid_cache[key]; ok { return cached }

	name_buf: [256]u16
	dom_buf: [256]u16
	name_len := win.DWORD(len(name_buf))
	dom_len := win.DWORD(len(dom_buf))
	use: win.SID_NAME_USE
	resolved := ""
	if win.LookupAccountSidW(nil, sid, &name_buf[0], &name_len, &dom_buf[0], &dom_len, &use) {
		n := win_utf16_to_utf8(name_buf[:int(name_len)], context.temp_allocator)
		dom := win_utf16_to_utf8(dom_buf[:int(dom_len)], context.temp_allocator)
		if dom != "" && n != "" {
			resolved = fmt.tprintf("%s\\%s", dom, n)
		} else {
			resolved = n
		}
	}
	if resolved == "" { return "" }
	// (a process keeps the text as its user for its whole life: nothing leaves the cache before the end)
	if len(r.sid_cache) >= SID_CACHE_MAX { return "" }
	owned_val := strings.clone(resolved)
	r.sid_cache[strings.clone(key)] = owned_val
	return owned_val
}

// How many processes a reading asks the suspension of, besides those known as suspended.
@(private = "file") SUSPEND_AUDIT :: 8

// Keeps r.suspended: those this program suspended (at once), those another program did (a few processes at each reading),
// each by its first thread's count. The acts ask every thread (win_suspension): this is what the table shows.
@(private = "file")
suspended_check :: proc(r: ^Proc_Reader, procs: []winapi.Decoded_Process) {
	win_suspended_take(&r.suspended)
	gone := make([dynamic]i32, context.temp_allocator)
	for pid, start in r.suspended {
		keep := false
		for &p in procs {
			if p.pid != pid || p.create_time != start { continue }
			count, _, ok, _ := win_thread_suspend_count(pid, p.first_tid)
			keep = ok && count > 0
			break
		}
		if !keep { append(&gone, pid) }
	}
	for pid in gone { delete_key(&r.suspended, pid) }
	for _ in 0 ..< min(SUSPEND_AUDIT, len(procs)) {
		r.audit = (r.audit + 1) % len(procs)
		p := procs[r.audit]
		if p.pid <= 4 || p.first_tid == 0 || p.any_running || p.create_time == 0 { continue }
		if count, _, ok, _ := win_thread_suspend_count(p.pid, p.first_tid); ok && count > 0 { r.suspended[p.pid] = p.create_time }
	}
}

// The state of (pid, start) now.
proc_state_now :: proc(pid: i32, start: u64) -> Proc_State {
	s, _ := win_suspension(pid, start)
	switch s {
	case .Unknown:            return .Unknown
	case .Runs:               return .Sleeping
	case .Suspended, .Frozen: return .Stopped
	}
	return .Unknown
}

// Populates PID -> comma-separated running SCM service names using one EnumServicesStatusExW call.
@(private = "file")
win_refresh_service_pid_map :: proc(out: ^map[i32]string) {
	for _, v in out^ { delete(v) }
	clear(out)
	scm := win_scm_open(WIN_SC_MANAGER_ENUMERATE_SERVICE)
	if scm == nil { return }
	defer win_scm_close(scm)

	builders := make(map[i32]strings.Builder, 64, context.temp_allocator)
	win_scm_list(scm, WIN_SERVICE_WIN32, WIN_SERVICE_ACTIVE, &builders, proc(data: rawptr, entry: winapi.ENUM_SERVICE_STATUS_PROCESSW64) {
		builders := (^map[i32]strings.Builder)(data)
		pid := i32(entry.ServiceStatusProcess.dwProcessId)
		if pid <= 0 { return }
		sname := win_wstr_to_utf8(([^]u16)(uintptr(entry.lpServiceName)), 256, context.temp_allocator)
		if sname == "" { return }
		b, exists := builders[pid]
		if !exists { b = strings.builder_make(context.temp_allocator) }
		if strings.builder_len(b) > 0 { strings.write_string(&b, ", ") }
		strings.write_string(&b, sname)
		builders[pid] = b
	})
	for pid, b in builders {
		out[pid] = strings.clone(strings.to_string(b))
	}
}
