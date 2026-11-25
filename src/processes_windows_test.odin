#+build windows
package inspecteur

// Live Windows integration tests: run on Windows against the test's own process
// and a CREATE_SUSPENDED child process created solely by the test (never touching
// any other process, service, or user setting).

import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import win "core:sys/windows"
import process "gt:process"
import winapi "winapi"

@(test)
win_procs_read_and_facts_find_self :: proc(t: ^testing.T) {
	r: Proc_Reader
	testing.expect(t, proc_reader_init(&r), "Proc_Reader initializes via ntdll")
	defer proc_reader_destroy(&r)

	procs := make([dynamic]Proc_Counters, 0, 256, context.temp_allocator)
	procs_read(&r, &procs)
	testing.expect(t, len(procs) > 0, "SystemProcessInformation returns live processes")

	own_pid := i32(os.get_pid())
	found := false
	own_c: Proc_Counters
	for c in procs {
		if c.pid == own_pid {
			own_c = c
			found = true
			break
		}
	}
	testing.expect(t, found, "own process appears in single-call SystemProcessInformation")
	testing.expect(t, own_c.start != 0, "own process has non-zero creation time")
	testing.expect(t, own_c.threads >= 1, "own process has at least one thread")
	testing.expect(t, own_c.resident > 0, "own process has positive working set")
	testing.expect(t, own_c.extra.handles > 0, "own process has open handles")

	f := proc_facts(&r, own_c)
	testing.expect(t, f.exe != "", "QueryFullProcessImageNameW returns executable path")
	testing.expect(t, f.user != "", "token SID lookup resolves user account")
	testing.expect(t, f.extra.integrity != .Unknown, "token integrity level is decoded")
}

@(test)
win_open_verified_rejects_recycled_pid :: proc(t: ^testing.T) {
	own_pid := i32(os.get_pid())
	ct, ok := win_proc_create_time(win.GetCurrentProcess())
	testing.expect(t, ok && ct != 0, "GetProcessTimes reads own creation time")

	h, res, _ := win_open_verified(own_pid, ct, WIN_PROCESS_QUERY_LIMITED_INFORMATION)
	testing.expect_value(t, res, process.Act_Result.Done)
	if h != nil { win.CloseHandle(h) }

	h_bad, res_bad, _ := win_open_verified(own_pid, ct + 1, WIN_PROCESS_QUERY_LIMITED_INFORMATION)
	testing.expect_value(t, res_bad, process.Act_Result.Gone)
	testing.expect(t, h_bad == nil, "mismatched creation time never returns a handle")
}

@(test)
win_own_process_properties_read :: proc(t: ^testing.T) {
	own_pid := i32(os.get_pid())
	ct, ok := win_proc_create_time(win.GetCurrentProcess())
	testing.expect(t, ok && ct != 0)

	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)

	cwd, cwd_st := win_proc_cwd(own_pid, ct, a)
	testing.expect_value(t, cwd_st, Read_State.Read)
	testing.expect(t, cwd != "", "PEB current working directory is non-empty")

	_, bad_cwd_st := win_proc_cwd(own_pid, ct + 1, a)
	testing.expect_value(t, bad_cwd_st, Read_State.Gone)

	threads := make([dynamic]Win_Thread_Row, a)
	deadlock := false
	testing.expect_value(t, win_proc_threads(own_pid, ct, &threads, &deadlock, a), Read_State.Read)
	testing.expect(t, len(threads) >= 1, "at least one thread is decoded")
	testing.expect(t, !deadlock, "test process has no deadlock")

	handles := make([dynamic]Win_Handle_Row, a)
	total := 0
	testing.expect_value(t, win_proc_handles(own_pid, ct, &handles, &total, a), Read_State.Read)
	testing.expect(t, total > 0 && len(handles) > 0, "own process handles are enumerated")

	mods := make([dynamic]Win_Module_Row, a)
	testing.expect_value(t, win_proc_modules(own_pid, ct, &mods, a), Read_State.Read)
	has_ntdll := false
	for m in mods {
		if strings.contains(strings.to_lower(m.path, context.temp_allocator), "ntdll.dll") { has_ntdll = true; break }
	}
	testing.expect(t, has_ntdll, "ntdll.dll appears in own modules")

	env := make([dynamic]string, a)
	testing.expect_value(t, win_proc_environment(own_pid, ct, &env, a), Read_State.Read)
	testing.expect(t, len(env) > 0, "PEB environment block is decoded")
}

// A child that finished starting and waits: cmd writes a prompt, then reads the pipe that the test holds. Only what the
// test made is acted on.
@(private = "file")
Test_Child :: struct { pi: win.PROCESS_INFORMATION, out, input: win.HANDLE }

@(private = "file")
test_child_start :: proc(t: ^testing.T) -> (c: Test_Child, ok: bool) {
	sa := win.SECURITY_ATTRIBUTES{nLength = size_of(win.SECURITY_ATTRIBUTES), bInheritHandle = true}
	child_in, child_out: win.HANDLE
	if !win.CreatePipe(&child_in, &c.input, &sa, 0) { testing.expectf(t, false, "CreatePipe (stdin): error %d", win.GetLastError()); return }
	defer win.CloseHandle(child_in)
	if !win.CreatePipe(&c.out, &child_out, &sa, 0) {
		testing.expectf(t, false, "CreatePipe (stdout): error %d", win.GetLastError())
		win.CloseHandle(c.input)
		return
	}
	defer win.CloseHandle(child_out)
	HANDLE_FLAG_INHERIT :: win.DWORD(1)
	win.SetHandleInformation(c.input, HANDLE_FLAG_INHERIT, 0)
	win.SetHandleInformation(c.out, HANDLE_FLAG_INHERIT, 0)

	exe := win_expand_env("%SystemRoot%\\System32\\cmd.exe")
	cmd_w := win.utf8_to_utf16(strings.concatenate({"\"", exe, "\" /d /q /c set /p x=ready"}, context.temp_allocator), context.temp_allocator)
	si := win.STARTUPINFOW{cb = size_of(win.STARTUPINFOW), dwFlags = win.STARTF_USESTDHANDLES, hStdInput = child_in, hStdOutput = child_out, hStdError = child_out}
	if !win.CreateProcessW(nil, cstring16(raw_data(cmd_w)), nil, nil, true, win.CREATE_NO_WINDOW, nil, nil, &si, &c.pi) {
		testing.expectf(t, false, "CreateProcessW: error %d", win.GetLastError())
		win.CloseHandle(c.input)
		win.CloseHandle(c.out)
		return
	}
	// It is started once its prompt came (10 s at most).
	avail: win.DWORD
	since := time.tick_now()
	for avail < 5 && time.tick_since(since) < 10 * time.Second {
		if !win.PeekNamedPipe(c.out, nil, 0, nil, &avail, nil) { break }
		if avail < 5 { time.sleep(5 * time.Millisecond) }
	}
	ok = avail >= 5
	if !ok {
		code: win.DWORD
		win.GetExitCodeProcess(c.pi.hProcess, &code)
		testing.expectf(t, false, "the child wrote %d bytes of its prompt (exit code %d, error %d)", avail, code, win.GetLastError())
		test_child_end(&c)
	}
	return
}

@(private = "file")
test_child_end :: proc(c: ^Test_Child) {
	_ = win.TerminateProcess(c.pi.hProcess, 1)
	_ = win.WaitForSingleObject(c.pi.hProcess, 5000)
	for h in ([]win.HANDLE{c.pi.hThread, c.pi.hProcess, c.input, c.out}) { win.CloseHandle(h) }
}

// The streams of a dump, by their types; nil for a file that is none.
@(private = "file")
dump_streams :: proc(path: string) -> (types: []u32) {
	raw, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil || len(raw) < 32 || string(raw[:4]) != "MDMP" { return nil }
	n, at := int((^u32)(&raw[8])^), int((^u32)(&raw[12])^)
	if n > 1024 || at + n * 12 > len(raw) { return nil }
	types = make([]u32, n, context.temp_allocator)
	for &v, i in types { mem.copy(&v, &raw[at + i * 12], 4) }
	return
}

@(test)
win_child_acts_and_minidump :: proc(t: ^testing.T) {
	child, started := test_child_start(t)
	if !started { return }
	defer test_child_end(&child)
	pi := child.pi

	child_pid := i32(pi.dwProcessId)
	child_start, ct_ok := win_proc_create_time(pi.hProcess)
	testing.expect(t, ct_ok && child_start != 0)

	// Priority change on verified child handle.
	pres, _, _, _ := win_act_priority(child_pid, child_start, 5)
	testing.expect_value(t, pres, process.Act_Result.Done)
	if d := win_dyn(); d.GetPriorityClass != nil {
		testing.expect_value(t, u32(d.GetPriorityClass(pi.hProcess)), winapi.BELOW_NORMAL_PRIORITY_CLASS)
	}

	// Wrong start time must refuse priority change.
	bad_pres, _, _, _ := win_act_priority(child_pid, child_start + 1, 0)
	testing.expect_value(t, bad_pres, process.Act_Result.Gone)

	// Efficiency mode on and off: what the process had is back (nothing under control).
	eres, _, _, _ := win_act_efficiency(child_pid, child_start, true)
	testing.expect_value(t, eres, process.Act_Result.Done)
	testing.expect(t, win_query_process_safety(pi.hProcess).efficiency, "EcoQoS reads back")
	eres, _, _, _ = win_act_efficiency(child_pid, child_start, false)
	testing.expect_value(t, eres, process.Act_Result.Done)
	testing.expect(t, !win_query_process_safety(pi.hProcess).efficiency, "EcoQoS is off again")

	// An unknown start proves nothing: no act.
	zres, _, _, _, _ := win_act_terminate(child_pid, 0, true)
	testing.expect_value(t, zres, process.Act_Result.Gone)
	zsus, _, _, _ := win_act_suspend(child_pid, child_start + 1, true)
	testing.expect_value(t, zsus, process.Act_Result.Gone)

	// Affinity read + pin to CPU 0.
	aset, ares, _ := win_act_affinity_read(child_pid, child_start)
	testing.expect_value(t, ares, process.Act_Result.Done)
	testing.expect(t, process.cpu_set_count(aset) > 0)
	cpu0: process.Cpu_Set
	process.cpu_set_put(&cpu0, 0)
	sres, _, _, _ := win_act_affinity_set(child_pid, child_start, cpu0)
	testing.expect_value(t, sres, process.Act_Result.Done)

	// Ctrl+P's act, twice: it suspends, then resumes, and never suspends twice. (The counts are the system's as soon as the
	// call returns; nothing is waited for. The raw values are logged.)
	reader: Proc_Reader
	testing.expect(t, proc_reader_init(&reader))
	defer proc_reader_destroy(&reader)
	table_state :: proc(r: ^Proc_Reader, pid: i32) -> Proc_State {
		procs := make([dynamic]Proc_Counters, context.temp_allocator)
		procs_read(r, &procs)
		for p in procs { if p.pid == pid { return p.state } }
		return .Unknown
	}
	look :: proc(t: ^testing.T, r: ^Proc_Reader, pid: i32, start: u64, when_: string, want: winapi.Suspension) {
		s, raw := win_suspension(pid, start)
		table := table_state(r, pid)
		log.infof("%s: %v, the table %v; %s", when_, s, table, raw)
		testing.expectf(t, s == want, "%s: %v, wanted %v; %s", when_, s, want, raw)
		testing.expectf(t, (table == .Stopped) == (want == .Suspended), "%s: the table says %v; %s", when_, table, raw)
		now := proc_state_now(pid, start)
		testing.expectf(t, (now == .Stopped) == (want == .Suspended) && now != .Unknown, "%s: the state now is %v", when_, now)
	}
	toggle :: proc(t: ^testing.T, pid: i32, start: u64, want: process.Signal) {
		sig, was, guarded, res, err, refusal, _ := win_act_suspend_toggle(pid, start, .None)
		testing.expectf(t, res == .Done && sig == want && !guarded, "toggle: %v, wanted %v; it was %v; %v, error 0x%08X, %v", sig, want, was, res, u32(err), refusal)
	}
	look(t, &reader, child_pid, child_start, "before", .Runs)
	toggle(t, child_pid, child_start, .Stop)
	look(t, &reader, child_pid, child_start, "suspended", .Suspended)
	toggle(t, child_pid, child_start, .Continue)
	look(t, &reader, child_pid, child_start, "resumed", .Runs)
	_, _, held, _, _, _, _ := win_act_suspend_toggle(child_pid, child_start, .Ancestor)
	testing.expect(t, held, "a guarded process is not suspended")
	look(t, &reader, child_pid, child_start, "guarded", .Runs)

	// The minidump of a running process has its modules and its whole memory.
	dmp_path, why := process_dump(child_pid, child_start, "inspecteur_test_child")
	testing.expectf(t, dmp_path != "" && why == "", "process_dump failed: %s", why)
	if dmp_path != "" {
		defer _ = os.remove(dmp_path)
		streams := dump_streams(dmp_path)
		// ModuleListStream 4, Memory64ListStream 9 (the whole memory, not the small dump).
		testing.expectf(t, slice.contains(streams, 4) && slice.contains(streams, 9), "streams: %v", streams)
	}

	// Terminate via verified handle.
	tres, _, _, _, _ := win_act_terminate(child_pid, child_start, true)
	testing.expect_value(t, tres, process.Act_Result.Done)
	testing.expect_value(t, win.WaitForSingleObject(pi.hProcess, 5000), win.WAIT_OBJECT_0)
}

@(test)
win_readonly_system_readers :: proc(t: ^testing.T) {
	mr: Machine_Reader
	machine_reader_init(&mr)
	defer machine_reader_destroy(&mr)

	mc: Machine_Counters
	machine_read(&mr, &mc)
	testing.expect(t, mc.cpu_total_ns > 0, "GetSystemTimes reports CPU time")
	groups := win_dyn().GetActiveProcessorGroupCount != nil ? int(win_dyn().GetActiveProcessorGroupCount()) : -1
	testing.expectf(t, len(mc.core_total_ns) > 0, "processors: none; status 0x%08X, %d bytes asked, %d given, %d groups", mr.perf_status, mr.perf_asked, mr.perf_given, groups)
	testing.expectf(t, mc.boot_time > 0, "boot time: %d", mc.boot_time)
	testing.expectf(t, mc.handles > 0, "handles: %d", mc.handles)
	mhz := make([]f32, len(mc.core_total_ns), context.temp_allocator)
	log.infof("%d processors in %d groups, %.0f MHz; memory %d, page files %d of which %d free; %d disks and %d interfaces counted", len(mc.core_total_ns), groups, cpu_mhz_now(mhz), mc.mem.total, mc.mem.swap_total, mc.mem.swap_free, len(mc.disks), len(mc.nets))
	testing.expect(t, mc.mem.total > 0, "GlobalMemoryStatusEx / GetPerformanceInfo report total RAM")
	testing.expect(t, mc.uptime > 0, "GetTickCount64 reports uptime")
	testing.expect(t, !mc.has_load, "Windows does not report POSIX load average")

	ci := cpu_info_read()
	defer delete(ci.model)
	testing.expectf(t, ci.logical == len(mc.core_total_ns), "%d logical processors, %d counted", ci.logical, len(mc.core_total_ns))
	testing.expectf(t, ci.cores > 0 && ci.sockets > 0, "%d cores, %d sockets", ci.cores, ci.sockets)

	sr: Socket_Reader
	defer socket_reader_destroy(&sr)
	socks := make([dynamic]Socket, context.temp_allocator)
	sockets_read(&sr, &socks)
	testing.expect(t, len(socks) > 0, "a Windows system listens somewhere (RPC)")
	disks := make([dynamic]Disk_Info, context.temp_allocator)
	disks_list(&disks)
	for d in disks { testing.expectf(t, d.capacity > 0, "%s tells its capacity", d.name) }
	nets := make([dynamic]Net_Info, context.temp_allocator)
	nets_list(&nets)
	counted := 0
	for n in nets { for k in mc.nets { if k.name == n.name { counted += 1; break } } }
	testing.expectf(t, len(nets) == 0 || counted > 0, "%d interfaces, none of them among the %d counted", len(nets), len(mc.nets))
	for d in disks { log.infof("%s: %s, %s, %d bytes, mounts %v", d.name, d.model, d.kind, d.capacity, d.mounts) }
	for n in nets { log.infof("%s: %s, up %v", n.name, n.kind, n.up) }

	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)

	svcs := make([dynamic]Win_Service, a)
	prob := win_services_read(.Services, &svcs, a)
	testing.expectf(t, prob == "" && len(svcs) > 0, "SCM lists services (prob=%q, n=%d)", prob, len(svcs))

	startup := make([dynamic]Win_Startup_Item, a)
	_ = win_startup_read(&startup, a)

	info: Info_Static
	{
		context.allocator = a
		win_info_read(&info)
	}
	testing.expect(t, info.os_name != "", "Windows OS name read from registry")
}
