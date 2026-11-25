package inspecteur

// Windows top-level window enumeration and activation:
// - Enumeration runs inside reading_make on the sampling worker thread (zero syscalls on the UI thread).
// - Filters out invisible, tool, and DWM-cloaked windows (suspended UWP frames / other virtual desktops).
// - Window activation runs on a chore task via ShowWindowAsync + SetForegroundWindow.

import "base:runtime"
import "core:strings"
import win "core:sys/windows"
import i18n "gt:i18n"
import "gt:ui"

Win_Top_Window :: struct {
	hwnd:   u64,
	pid:    i32,
	title:  string,   // in the reading's arena
	active: bool,
}

Reading_Windows :: struct {
	list: [dynamic]Win_Top_Window,
}

foreign import win_list_user32 "system:User32.lib"

@(private = "file", default_calling_convention = "system")
foreign win_list_user32 {
	InternalGetWindowText :: proc(hwnd: win.HWND, buf: [^]u16, max: i32) -> i32 ---
	ShowWindowAsync       :: proc(hwnd: win.HWND, show: i32) -> win.BOOL ---
}

@(private = "file")
Win_Enum_Ctx :: struct {
	out: ^[dynamic]Win_Top_Window,
	fg:  win.HWND,
}

@(private = "file")
win_enum_proc :: proc "system" (hwnd: win.HWND, lparam: win.LPARAM) -> win.BOOL {
	ctx := (^Win_Enum_Ctx)(uintptr(lparam))
	if !win.IsWindowVisible(hwnd) { return true }
	if win.GetWindow(hwnd, win.GW_OWNER) != nil { return true }
	ex := win.GetWindowLongW(hwnd, win.GWL_EXSTYLE)
	if (ex & win.LONG(win.WS_EX_TOOLWINDOW)) != 0 { return true }
	// Skip DWM-cloaked windows (suspended UWP apps and windows on inactive virtual desktops).
	cloaked: win.DWORD
	if win.DwmGetWindowAttribute(hwnd, u32(win.DWMWINDOWATTRIBUTE.DWMWA_CLOAKED), &cloaked, size_of(cloaked)) == 0 && cloaked != 0 {
		return true
	}
	// (not GetWindowText: for a window of Inspecteur it sends a message to the interface's thread and waits for it, which
	// may wait for this thread at the end. This one reads the title the system keeps)
	buf: [256]u16
	got := InternalGetWindowText(hwnd, &buf[0], len(buf))
	if got <= 0 { return true }
	context = runtime.default_context()
	pid: win.DWORD
	win.GetWindowThreadProcessId(hwnd, &pid)
	if pid == 0 { return true }
	// Allocate title in the caller's dynamic array allocator (reading arena).
	title := win_utf16_to_utf8(buf[:int(got)], ctx.out.allocator)
	if title == "" { return true }
	append(ctx.out, Win_Top_Window{
		hwnd   = u64(uintptr(hwnd)),
		pid    = i32(pid),
		title  = title,
		active = hwnd == ctx.fg,
	})
	return true
}

// Runs on the sampling worker thread (context.temp_allocator is the reading's arena).
reading_windows_read :: proc(w: ^Reading_Windows, demo: bool) {
	if demo { return }
	w.list = make([dynamic]Win_Top_Window, 0, 32, context.temp_allocator)
	ctx := Win_Enum_Ctx{out = &w.list, fg = win.GetForegroundWindow()}
	win.EnumWindows(win_enum_proc, win.LPARAM(uintptr(&ctx)))
}

reading_windows_free :: proc(w: ^Reading_Windows) {}

// Runs on the UI thread with zero syscalls: maps enumerated HWNDs to app catalog entries via PIDs.
app_windows_apply :: proc(app: ^App, rw: ^Reading_Windows) {
	app_windows_clear(app)
	if app.demo != nil {
		for e, i in app.catalog.entries[:min(len(app.catalog.entries), DEMO_WINDOWS)] {
			append(&app.windows, App_Window{entry = i, title = strings.clone(e.name), active = i == 0})
		}
		return
	}
	for tw in rw.list {
		p := find_pid(&app.sampler, tw.pid)
		if p == nil || p.ended { continue }
		e := p.entry
		if e < 0 {
			// Check whether the process belongs to an app group via its parent chain.
			for q, i in app.sampler.procs {
				if q.pid == tw.pid && i < len(app.table.owner) {
					if o := app.table.owner[i]; o >= 0 { e = app.sampler.procs[o].entry }
					break
				}
			}
		}
		if e < 0 { continue }
		append(&app.windows, App_Window{entry = e, id = tw.hwnd, title = strings.clone(tw.title), active = tw.active})
	}
}

@(private = "file")
Win_Activate_Task :: struct {
	hwnd: u64,
	ok:   bool,
}

@(private = "file")
win_activate_work :: proc(data: rawptr) {
	t := (^Win_Activate_Task)(data)
	h := win.HWND(uintptr(t.hwnd))
	if !win.IsWindow(h) { return }
	// (Async: ShowWindow waits for the thread of the window, which may be stuck)
	if win.IsIconic(h) { _ = ShowWindowAsync(h, win.SW_RESTORE) }
	win.SetForegroundWindow(h)
	t.ok = true
}

@(private = "file")
win_activate_done :: proc(data: rawptr, _: u64) {
	t := (^Win_Activate_Task)(data)
	defer free(t)
	if the_app != nil && !t.ok { say(the_app, i18n.tr("That window has closed")) }
}

@(private = "file")
win_activate_lost :: proc(data: rawptr) { free((^Win_Activate_Task)(data)) }

window_show :: proc(app: ^App, entry: int) -> bool {
	list := windows_of(app, entry)
	if len(list) == 0 { return false }
	pick := list[0]
	for w, i in list {
		if w.active { pick = list[(i + 1) % len(list)]; break }
	}
	if app.demo != nil {
		say(app, i18n.tr("The window of %s comes to the front"), pick.title)
		return true
	}
	t := new(Win_Activate_Task)
	t.hwnd = pick.id
	ui.task(&app.main.state, win_activate_work, win_activate_done, t, win_activate_lost)
	return true
}
