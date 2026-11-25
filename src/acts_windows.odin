package inspecteur

// Verified-handle process acts on Windows, executed off the UI thread on the toolkit's chores:
// - Every act opens the process handle, verifies GetProcessTimes creation time against (pid, start),
//   and acts on that same handle so a recycled PID is never hit.
// - Critical processes (IsProcessCritical) and protected processes (PPL/PP) are refused with explicit reasons.
// - Inspecteur never self-elevates silently; access refusals state clearly when Administrator privileges are needed.
// - End Task posts WM_CLOSE to visible top-level windows (falling back to TerminateProcess if windowless).
// - Kill calls TerminateProcess; Suspend/Resume call NtSuspendProcess/NtResumeProcess;
//   Efficiency Mode toggles EcoQoS (SetProcessInformation ProcessPowerThrottling).

import "core:slice"
import "core:strings"
import win "core:sys/windows"
import i18n "gt:i18n"
import process "gt:process"
import "gt:ui"
import winapi "winapi"

Act_Kind :: enum u8 {
	Signal,          // Terminate (WM_CLOSE / TerminateProcess) or Kill (TerminateProcess)
	Suspend,         // NtSuspendProcess / NtResumeProcess
	Priority,        // SetPriorityClass
	Efficiency,      // EcoQoS (ProcessPowerThrottling)
	Affinity_Read,   // GetProcessAffinityMask / GetProcessDefaultCpuSets
	Affinity_Set,    // SetProcessAffinityMask / SetProcessDefaultCpuSets
}

Refusal_Kind :: enum u8 {
	None,
	Critical,
	Protected,
}

Act :: struct {
	kind:          Act_Kind,
	name:          string,            // owned
	targets:       [dynamic]Target,
	owners:        [dynamic]string,
	sig:           process.Signal,
	guard:         Guard,
	nice:          i8,
	efficiency_on: bool,
	set:           process.Cpu_Set,
	// outcomes
	result:        process.Act_Result,
	errno:         int,
	sent:          int,
	closed_window: bool,
	owner:         string,
	guarded:       bool,
	refusal:       Refusal_Kind,
	refusal_detail: string,           // owned: e.g. "PPL (Antimalware)"
}

act_start :: proc(app: ^App, a: ^Act) {
	ui.task(&app.main.state, act_work, act_done, a, act_lost)
}

act_new :: proc(kind: Act_Kind, name: string) -> ^Act {
	a := new(Act)
	a.kind, a.name = kind, strings.clone(name)
	return a
}

@(private = "file")
act_free :: proc(a: ^Act) {
	delete(a.name)
	delete(a.targets)
	delete(a.owners)
	delete(a.refusal_detail)
	free(a)
}

@(private = "file")
act_lost :: proc(data: rawptr) { act_free((^Act)(data)) }

@(private = "file")
Close_Enum_State :: struct {
	pid:  win.DWORD,
	seen: int,   // its visible windows
	sent: int,   // those that took WM_CLOSE
}

@(private = "file")
close_enum_cb :: proc "system" (hwnd: win.HWND, lparam: win.LPARAM) -> win.BOOL {
	st := (^Close_Enum_State)(uintptr(lparam))
	pid: win.DWORD
	win.GetWindowThreadProcessId(hwnd, &pid)
	if pid == st.pid && win.IsWindowVisible(hwnd) {
		st.seen += 1
		if win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0) { st.sent += 1 }
	}
	return true
}

// Ends a process: its visible windows are asked to close; a process with none (or `force_kill`) is terminated. A process
// whose windows do not take the message (an elevated one's) is not terminated in its place: it was asked to close.
win_act_terminate :: proc(pid: i32, start: u64, force_kill: bool) -> (res: process.Act_Result, err: int, refusal: Refusal_Kind, detail: string, closed_window: bool) {
	// (the rights are asked first: a process that can be asked to close but not terminated still gets its WM_CLOSE)
	h: win.HANDLE
	h, res, err, refusal, detail = win_open_for_act(pid, start, force_kill ? WIN_PROCESS_TERMINATE : WIN_PROCESS_QUERY_LIMITED_INFORMATION)
	if res != .Done { return }
	defer win.CloseHandle(h)   // (held through the windows' walk: the PID stays this process's)
	if force_kill { return win_terminate_handle(h) }

	st := Close_Enum_State{pid = win.DWORD(pid)}
	win.EnumWindows(close_enum_cb, win.LPARAM(uintptr(&st)))
	if st.sent > 0 { return .Done, 0, .None, "", true }
	if st.seen > 0 { return .Denied, 0, .None, "", false }

	th: win.HANDLE
	th, res, err = win_open_verified(pid, start, WIN_PROCESS_TERMINATE)
	if res != .Done { return }
	defer win.CloseHandle(th)
	return win_terminate_handle(th)
}

@(private = "file")
win_terminate_handle :: proc(h: win.HANDLE) -> (res: process.Act_Result, err: int, refusal: Refusal_Kind, detail: string, closed_window: bool) {
	if win.TerminateProcess(h, 1) { return .Done, 0, .None, "", false }
	e := win.GetLastError()
	// (a process that is ending already answers ERROR_ACCESS_DENIED)
	if win.WaitForSingleObject(h, 0) == win.WAIT_OBJECT_0 { return .Gone, 0, .None, "", false }
	return e == win.ERROR_ACCESS_DENIED ? .Denied : .Failed, int(e), .None, "", false
}

win_act_suspend :: proc(pid: i32, start: u64, suspend: bool) -> (res: process.Act_Result, err: int, refusal: Refusal_Kind, detail: string) {
	d := win_dyn()
	fn := suspend ? d.NtSuspendProcess : d.NtResumeProcess
	if fn == nil { return .Unsupported, 0, .None, "" }
	h: win.HANDLE
	h, res, err, refusal, detail = win_open_for_act(pid, start, WIN_PROCESS_SUSPEND_RESUME)
	if res != .Done { return }
	defer win.CloseHandle(h)
	st := fn(h)
	if st == winapi.STATUS_SUCCESS { return .Done, 0, .None, "" }
	return st == winapi.STATUS_ACCESS_DENIED ? .Denied : .Failed, int(st), .None, ""
}

// The result of a call that failed.
@(private = "file")
win_failed :: proc() -> (process.Act_Result, int) {
	e := win.GetLastError()
	return e == win.ERROR_ACCESS_DENIED ? .Denied : .Failed, int(e)
}

win_act_priority :: proc(pid: i32, start: u64, nice: i8) -> (res: process.Act_Result, err: int, refusal: Refusal_Kind, detail: string) {
	d := win_dyn()
	if d.SetPriorityClass == nil { return .Unsupported, 0, .None, "" }
	h: win.HANDLE
	h, res, err, refusal, detail = win_open_for_act(pid, start, WIN_PROCESS_SET_INFORMATION)
	if res != .Done { return }
	defer win.CloseHandle(h)
	if !d.SetPriorityClass(h, win.DWORD(winapi.nice_to_priority_class(nice))) { res, err = win_failed() }
	return
}

win_act_efficiency :: proc(pid: i32, start: u64, enable: bool) -> (res: process.Act_Result, err: int, refusal: Refusal_Kind, detail: string) {
	d := win_dyn()
	if d.SetProcessInformation == nil || d.SetPriorityClass == nil { return .Unsupported, 0, .None, "" }
	h: win.HANDLE
	h, res, err, refusal, detail = win_open_for_act(pid, start, WIN_PROCESS_SET_INFORMATION)
	if res != .Done { return }
	defer win.CloseHandle(h)
	// Off gives the choice back to the system (no bit under control): a bit under control and not set would ask for the
	// highest speed for good, which the process had not before.
	on := enable ? winapi.PROCESS_POWER_THROTTLING_EXECUTION_SPEED : 0
	pt := winapi.PROCESS_POWER_THROTTLING_STATE{Version = winapi.PROCESS_POWER_THROTTLING_CURRENT_VERSION, ControlMask = on, StateMask = on}
	if !d.SetProcessInformation(h, WIN_PROC_INFO_POWER_THROTTLING, &pt, size_of(pt)) {
		res, err = win_failed()
		return
	}
	// Task Manager pairs EcoQoS with the Idle priority class, and gives Normal back with it.
	if !d.SetPriorityClass(h, win.DWORD(enable ? winapi.IDLE_PRIORITY_CLASS : winapi.NORMAL_PRIORITY_CLASS)) { res, err = win_failed() }
	return
}

// The logical processors as the machine's page numbers them (the groups one after the other), each with its CPU set's id.
@(private = "file")
win_cpu_sets :: proc() -> []winapi.Decoded_Cpu_Set {
	d := win_dyn()
	if d.GetSystemCpuSetInformation == nil || d.GetActiveProcessorCount == nil || d.GetActiveProcessorGroupCount == nil { return nil }
	need: u32
	_ = d.GetSystemCpuSetInformation(nil, 0, &need, win.GetCurrentProcess(), 0)
	if need == 0 || need > 1 << 20 { return nil }
	buf := win_bytes(int(need))
	if !d.GetSystemCpuSetInformation(raw_data(buf), need, &need, win.GetCurrentProcess(), 0) { return nil }
	sizes := make([]int, int(d.GetActiveProcessorGroupCount()), context.temp_allocator)
	for &s, g in sizes { s = int(d.GetActiveProcessorCount(u16(g))) }
	out := make([dynamic]winapi.Decoded_Cpu_Set, context.temp_allocator)
	winapi.decode_cpu_sets(buf[:min(int(need), len(buf))], sizes, &out)
	return out[:]
}

@(private = "file")
win_groups :: proc() -> int {
	d := win_dyn()
	return d.GetActiveProcessorGroupCount != nil ? int(d.GetActiveProcessorGroupCount()) : 1
}

// With several processor groups a mask says nothing of the other groups: the process's default CPU sets do (none: every
// processor).
win_act_affinity_read :: proc(pid: i32, start: u64) -> (set: process.Cpu_Set, res: process.Act_Result, err: int) {
	d := win_dyn()
	if d.GetProcessAffinityMask == nil { return {}, .Unsupported, 0 }
	h, hres, herr := win_open_verified(pid, start, WIN_PROCESS_QUERY_LIMITED_INFORMATION)
	if hres != .Done { return {}, hres, herr }
	defer win.CloseHandle(h)

	if win_groups() > 1 {
		if d.GetProcessDefaultCpuSets == nil { return {}, .Unsupported, 0 }
		all := win_cpu_sets()
		if len(all) == 0 { return {}, .Failed, 0 }
		ids: []u32
		req: u32
		if !d.GetProcessDefaultCpuSets(h, nil, 0, &req) && req > 0 {
			ids = make([]u32, int(req), context.temp_allocator)
			if !d.GetProcessDefaultCpuSets(h, raw_data(ids), req, &req) {
				res, err = win_failed()
				return {}, res, err
			}
		}
		for c in all {
			if c.index < process.CPU_SET_MAX && (len(ids) == 0 || slice.contains(ids, c.id)) { process.cpu_set_put(&set, c.index) }
		}
		return set, .Done, 0
	}

	pmask, smask: uintptr
	if !d.GetProcessAffinityMask(h, &pmask, &smask) {
		res, err = win_failed()
		return {}, res, err
	}
	for i in 0 ..< min(64, process.CPU_SET_MAX) {
		if (pmask & (uintptr(1) << uint(i))) != 0 { process.cpu_set_put(&set, i) }
	}
	return set, .Done, 0
}

win_act_affinity_set :: proc(pid: i32, start: u64, set: process.Cpu_Set) -> (res: process.Act_Result, err: int, refusal: Refusal_Kind, detail: string) {
	d := win_dyn()
	if d.SetProcessAffinityMask == nil { return .Unsupported, 0, .None, "" }
	h: win.HANDLE
	h, res, err, refusal, detail = win_open_for_act(pid, start, WIN_PROCESS_SET_INFORMATION)
	if res != .Done { return }
	defer win.CloseHandle(h)

	if win_groups() > 1 {
		if d.SetProcessDefaultCpuSets == nil { return .Unsupported, 0, .None, "" }
		ids := make([dynamic]u32, 0, 64, context.temp_allocator)
		all := win_cpu_sets()
		for c in all {
			if c.index < process.CPU_SET_MAX && process.cpu_set_has(set, c.index) { append(&ids, c.id) }
		}
		if len(ids) == 0 { return .Failed, 0, .None, "" }
		// (every processor: no default set, as a process that was never limited)
		if len(ids) == len(all) { clear(&ids) }
		if !d.SetProcessDefaultCpuSets(h, len(ids) > 0 ? raw_data(ids) : nil, u32(len(ids))) { res, err = win_failed() }
		return
	}

	mask: uintptr
	for i in 0 ..< 64 {
		if process.cpu_set_has(set, i) { mask |= uintptr(1) << uint(i) }
	}
	if mask == 0 { return .Failed, 0, .None, "" }
	if !d.SetProcessAffinityMask(h, mask) { res, err = win_failed() }
	return
}

@(private = "file")
act_work :: proc(data: rawptr) {
	a := (^Act)(data)
	switch a.kind {
	case .Signal:
		force := a.sig == .Kill
		for t, i in a.targets {
			r, e, ref, det, closed := win_act_terminate(t.pid, t.start, force)
			if r == .Done {
				a.sent += 1
				if closed { a.closed_window = true }
			} else if r != .Gone {
				a.result, a.errno, a.refusal = r, e, ref
				if det != "" {
					delete(a.refusal_detail)
					a.refusal_detail = strings.clone(det)
				}
				if i < len(a.owners) { a.owner = a.owners[i] }
			}
		}
	case .Suspend:
		t := a.targets[0]
		if proc_state_now(t.pid, t.start) == .Stopped {
			a.sig = .Continue
		} else if a.guard != .None {
			a.sig, a.guarded = .Stop, true
			return
		} else {
			a.sig = .Stop
		}
		r, e, ref, det := win_act_suspend(t.pid, t.start, a.sig == .Stop)
		if r == .Done {
			a.sent = 1
		} else if r != .Gone {
			a.result, a.errno, a.refusal = r, e, ref
			if det != "" { a.refusal_detail = strings.clone(det) }
		}
	case .Priority:
		r, e, ref, det := win_act_priority(a.targets[0].pid, a.targets[0].start, a.nice)
		act_keep(a, r, e, ref, det)
	case .Efficiency:
		r, e, ref, det := win_act_efficiency(a.targets[0].pid, a.targets[0].start, a.efficiency_on)
		act_keep(a, r, e, ref, det)
	case .Affinity_Read:
		a.set, a.result, a.errno = win_act_affinity_read(a.targets[0].pid, a.targets[0].start)
	case .Affinity_Set:
		r, e, ref, det := win_act_affinity_set(a.targets[0].pid, a.targets[0].start, a.set)
		act_keep(a, r, e, ref, det)
	}
}

@(private = "file")
act_keep :: proc(a: ^Act, r: process.Act_Result, e: int, refusal: Refusal_Kind, detail: string) {
	a.result, a.errno, a.refusal = r, e, refusal
	delete(a.refusal_detail)
	a.refusal_detail = strings.clone(detail)
}

// Says why Windows' own processes are not touched. False: nothing was refused.
@(private = "file")
refusal_said :: proc(app: ^App, a: ^Act) -> bool {
	switch a.refusal {
	case .None:      return false
	case .Critical:  say(app, i18n.tr("Refused: %s is a critical Windows process (ending it crashes the system)"), a.name)
	case .Protected: say(app, i18n.tr("Refused: %s is a protected process (%s)"), a.name, a.refusal_detail)
	}
	return true
}

@(private = "file")
act_done :: proc(data: rawptr, _: u64) {
	a := (^Act)(data)
	defer act_free(a)
	app := the_app
	if app == nil { return }
	if a.kind != .Signal && a.kind != .Suspend && refusal_said(app, a) { return }
	switch a.kind {
	case .Signal, .Suspend: signal_said(app, a)
	case .Priority:
		#partial switch a.result {
		case .Gone:
			say(app, i18n.tr("%s has ended already"), a.name)
		case .Done:
			say(app, i18n.tr("%s now runs at %s"), a.name, priority_text(a.nice))
			if p := find_proc(&app.sampler, a.targets[0].pid, a.targets[0].start); p != nil { p.nice = a.nice }
			sample_soon(app)
		case .Denied:
			say(app, i18n.tr("Access denied: %s"), i18n.tr(PRIORITY_DENIED))
		case:
			say(app, i18n.tr("The priority of %s cannot be changed"), a.name)
		}
	case .Efficiency:
		#partial switch a.result {
		case .Gone:
			say(app, i18n.tr("%s has ended already"), a.name)
		case .Done:
			if p := find_proc(&app.sampler, a.targets[0].pid, a.targets[0].start); p != nil {
				p.extra.efficiency = a.efficiency_on
				p.nice = a.efficiency_on ? 19 : 0
			}
			say(app, a.efficiency_on ? i18n.tr("Efficiency mode enabled for %s") : i18n.tr("Efficiency mode disabled for %s"), a.name)
			sample_soon(app)
		case .Denied:
			say(app, i18n.tr("Access denied: run Inspecteur as an administrator to change Efficiency mode for %s"), a.name)
		case:
			say(app, i18n.tr("Efficiency mode cannot be changed for %s"), a.name)
		}
	case .Affinity_Read:
		#partial switch a.result {
		case .Done:   affinity_show(app, a.targets[0], a.name, a.set)
		case .Gone:   say(app, i18n.tr("%s has ended already"), a.name)
		case .Denied: say(app, i18n.tr("Access denied: run Inspecteur as an administrator to read the affinity of %s"), a.name)
		case:         say(app, i18n.tr("The affinity of %s cannot be read"), a.name)
		}
	case .Affinity_Set:
		#partial switch a.result {
		case .Done:   say(app, i18n.tr("%s runs on %s now"), a.name, cpu_set_text(a.set, min(len(app.machine.core_total), process.CPU_SET_MAX)))
		case .Gone:   say(app, i18n.tr("%s has ended already"), a.name)
		case .Denied: say(app, i18n.tr("Access denied: only its owner, or %s, may change the affinity of %s"), ADMIN, a.name)
		case:         say(app, i18n.tr("The affinity of %s cannot be changed"), a.name)
		}
	}
}

@(private = "file")
signal_said :: proc(app: ^App, a: ^Act) {
	if a.guarded {
		switch a.guard {
		case .None:
		case .Self:           say(app, i18n.tr("Inspecteur does not suspend itself: nothing could resume it"))
		case .Ancestor:       say(app, i18n.tr("%s runs Inspecteur: suspended, it would stop Inspecteur too"), a.name)
		case .Display_Server: say(app, i18n.tr("%s draws the desktop: suspended, it would freeze every window, this one too"), a.name)
		}
		return
	}
	if refusal_said(app, a) {
		if a.sent > 0 { sample_soon(app) }
		return
	}
	switch {
	case a.result == .Denied:
		say(app, i18n.tr("Access denied for %s: run Inspecteur as an administrator (protected system processes remain blocked)"), a.name)
	case a.result != .Done:
		say(app, i18n.tr("%s cannot be changed (error %d)"), a.name, a.errno)
	case a.sent > 0:
		#partial switch a.sig {
		case .Kill:     say(app, i18n.tr("Killed %s"), a.name)
		case .Stop:     say(app, i18n.tr("Suspended %s"), a.name)
		case .Continue: say(app, i18n.tr("Resumed %s"), a.name)
		case:           say(app, a.closed_window ? i18n.tr("Asked %s to close its window") : i18n.tr("Ended %s"), a.name)
		}
	case:
		say(app, i18n.tr("%s has ended already"), a.name)
	}
	if a.sent == 0 { return }
	#partial switch a.sig {
	case .Stop, .Continue:
		for t in a.targets {
			if p := find_proc(&app.sampler, t.pid, t.start); p != nil { p.state = a.sig == .Stop ? .Stopped : .Sleeping }
		}
	}
	sample_soon(app)
}
