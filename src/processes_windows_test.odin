#+build windows
package inspecteur

// Live Windows integration tests: run on Windows against the test's own process
// and a CREATE_SUSPENDED child process created solely by the test (never touching
// any other process, service, or user setting).

import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"
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

@(test)
win_child_acts_and_minidump :: proc(t: ^testing.T) {
	// Spawn a CREATE_SUSPENDED child owned solely by this test; it never executes code before termination.
	cmd_str := strings.clone("C:\\Windows\\System32\\cmd.exe /c exit 0", context.temp_allocator)
	cmd_w := win.utf8_to_utf16(cmd_str, context.temp_allocator)
	si := win.STARTUPINFOW{cb = size_of(win.STARTUPINFOW)}
	pi: win.PROCESS_INFORMATION
	CREATE_SUSPENDED :: win.DWORD(0x00000004)
	CREATE_NO_WINDOW :: win.DWORD(0x08000000)
	if !win.CreateProcessW(nil, cstring16(raw_data(cmd_w)), nil, nil, false, CREATE_SUSPENDED | CREATE_NO_WINDOW, nil, nil, &si, &pi) {
		testing.fail_now(t, "CreateProcessW failed to spawn test child")
	}
	defer {
		_ = win.TerminateProcess(pi.hProcess, 1)
		_ = win.WaitForSingleObject(pi.hProcess, 5000)
		win.CloseHandle(pi.hThread)
		win.CloseHandle(pi.hProcess)
	}

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

	// Suspend and resume on verified handle.
	sus_res, _, _, _ := win_act_suspend(child_pid, child_start, true)
	testing.expect_value(t, sus_res, process.Act_Result.Done)
	res_res, _, _, _ := win_act_suspend(child_pid, child_start, false)
	testing.expect_value(t, res_res, process.Act_Result.Done)

	// Minidump writes a valid MDMP file and cleans up.
	dmp_path, why := process_dump(child_pid, child_start, "inspecteur_test_child")
	testing.expectf(t, dmp_path != "" && why == "", "process_dump failed: %s", why)
	if dmp_path != "" {
		defer _ = os.remove(dmp_path)
		raw, rerr := os.read_entire_file(dmp_path, context.temp_allocator)
		testing.expect(t, rerr == nil && len(raw) >= 4 && string(raw[:4]) == "MDMP", "minidump header begins with MDMP")
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
	testing.expect(t, len(mc.core_total_ns) > 0, "per-core performance counters populated")
	testing.expect(t, mc.mem.total > 0, "GlobalMemoryStatusEx / GetPerformanceInfo report total RAM")
	testing.expect(t, mc.uptime > 0, "GetTickCount64 reports uptime")
	testing.expect(t, !mc.has_load, "Windows does not report POSIX load average")

	ci := cpu_info_read()
	defer delete(ci.model)
	testing.expect(t, ci.logical > 0, "logical processor count > 0")

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
