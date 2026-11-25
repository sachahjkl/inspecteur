package inspecteur

// Windows Startup model:
// - Registry Run keys: HKCU's, and HKLM's 64-bit (KEY_WOW64_64KEY) and 32-bit (KEY_WOW64_32KEY) views.
// - User and Common Startup folders (FOLDERID_Startup / FOLDERID_CommonStartup), decoding .lnk targets.
// - Task Scheduler logon tasks (%SystemRoot%\System32\Tasks XML files with LogonTrigger).
// - Full StartupApproved integration (Explorer\StartupApproved\Run, Run32, StartupFolder):
//   reads and writes Windows Task Manager's 12-byte REG_BINARY format so disabling an item stays
//   synchronized with Task Manager without deleting the underlying Run value or shortcut.

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import win "core:sys/windows"
import i18n "gt:i18n"
import lucide "gt:lucide"
import tasks "gt:tasks"
import "gt:ui"
import winapi "winapi"

@(private = "file") KEY_WOW64_64KEY :: win.DWORD(0x0100)
@(private = "file") KEY_WOW64_32KEY :: win.DWORD(0x0200)
@(private = "file") RUN_SUBKEY      :: "Software\\Microsoft\\Windows\\CurrentVersion\\Run"
@(private = "file") APPROVED_RUN    :: "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run"
@(private = "file") APPROVED_RUN32  :: "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run32"
@(private = "file") APPROVED_FOLDER :: "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\StartupFolder"

Win_Startup_Source :: enum u8 {
	HKCU_Run,
	HKLM_Run,
	HKLM_Run_32,
	User_Folder,
	Common_Folder,
	Task_Scheduler,
}

WIN_STARTUP_SOURCE_LABELS := [Win_Startup_Source]string{
	.HKCU_Run       = i18n.later("Registry (HKCU Run)"),
	.HKLM_Run       = i18n.later("Registry (HKLM Run)"),
	.HKLM_Run_32    = i18n.later("Registry (HKLM Run 32-bit)"),
	.User_Folder    = i18n.later("User Startup folder"),
	.Common_Folder  = i18n.later("Common Startup folder"),
	.Task_Scheduler = i18n.later("Task Scheduler"),
}

Win_Startup_Item :: struct {
	source:     Win_Startup_Source,
	id:         string,   // registry value name, file name, or task path
	name:       string,
	command:    string,
	location:   string,   // registry key or file path
	target_path: string,  // executable or file to reveal in Explorer
	enabled:    bool,
	status:     string,
	can_toggle: bool,
	needs_admin: bool,
}

Win_Startup_List :: struct {
	arena:    virtual.Arena,
	items:    [dynamic]Win_Startup_Item,
	problem:  string,
	changed:  bool,
	on:       bool,
	names:    []string,
	failure:  string,
	failures: int,
	on_count: int,
}

Win_Startup_Change :: struct {
	source: Win_Startup_Source,
	id:     string,
	name:   string,
}

@(private = "file")
Win_Startup_Ask :: struct {
	change: bool,
	on:     bool,
	items:  [dynamic]Win_Startup_Change,
}

Startup :: struct {
	job:     tasks.Job,
	demo:    ^Demo,
	state:   ^ui.State,
	mutex:   sync.Mutex,
	ask:     Win_Startup_Ask,
	list:    ^Win_Startup_List,
	rows:    Section_Table,
	pending: bool,
	asked:   bool,
}

WIN_STARTUP_COLUMNS := [?]ui.Table_Column{
	{title = i18n.later("Name"), width = 18},
	{title = i18n.later("Status"), width = 10},
	{title = i18n.later("Source"), width = 18, weak = true},
	{title = i18n.later("Command"), width = 0, weak = true},
	{title = i18n.later("Location"), width = 20, weak = true},
}

startup_init :: proc(s: ^Startup, app: ^App) {
	section_table_init(&s.rows, app, WIN_STARTUP_COLUMNS[:])
	section_layout_load(&s.rows, &app.prefs, "startup")
	s.demo  = app.demo
	s.state = &app.main.state
	s.job   = {work = win_startup_work, data = s}
}

startup_destroy :: proc(s: ^Startup) {
	win_startup_ask_free(&s.ask.items)
	win_startup_list_free(s.list)
	section_table_destroy(&s.rows)
}

@(private = "file")
win_startup_list_free :: proc(l: ^Win_Startup_List) {
	if l == nil { return }
	virtual.arena_destroy(&l.arena)
	free(l)
}

@(private = "file")
win_startup_ask_free :: proc(items: ^[dynamic]Win_Startup_Change) {
	for it in items^ {
		delete(it.id, runtime.heap_allocator())
		delete(it.name, runtime.heap_allocator())
	}
	delete(items^)
	items^ = nil
}

startup_ask :: proc(app: ^App, change := false, items: []Win_Startup_Item = nil, on := false) {
	s := &app.startup
	s.asked = true
	sync.lock(&s.mutex)
	if change {
		s.ask.change, s.ask.on = true, on
		win_startup_ask_free(&s.ask.items)
		heap := runtime.heap_allocator()
		s.ask.items = make([dynamic]Win_Startup_Change, 0, len(items), heap)
		for it in items {
			append(&s.ask.items, Win_Startup_Change{it.source, strings.clone(it.id, heap), strings.clone(it.name, heap)})
		}
	}
	sync.unlock(&s.mutex)
	tasks.job_ask(ui.chores(), &s.job)
}

@(private = "file")
win_startup_work :: proc(data: rawptr) {
	s := (^Startup)(data)
	l := new(Win_Startup_List)
	a := virtual.arena_allocator(&l.arena)
	sync.lock(&s.mutex)
	change, on := s.ask.change, s.ask.on
	asked := make([]Win_Startup_Change, len(s.ask.items), a)
	for it, i in s.ask.items {
		asked[i] = {it.source, strings.clone(it.id, a), strings.clone(it.name, a)}
	}
	win_startup_ask_free(&s.ask.items)
	s.ask.change = false
	sync.unlock(&s.mutex)

	l.items = make([dynamic]Win_Startup_Item, 0, 32, a)
	if change {
		l.changed, l.on = true, on
		l.names = make([]string, len(asked), a)
		for it, i in asked {
			l.names[i] = it.name
			why := s.demo != nil ? DEMO_REFUSED : win_startup_set_enabled(it.source, it.id, on)
			if why == "" { continue }
			if l.failures == 0 { l.failure = strings.concatenate({it.name, ": ", why}, a) }
			l.failures += 1
		}
	}
	if s.demo != nil {
		l.problem = strings.clone(demo_startup_read(s.demo, &l.items, a), a)
	} else {
		l.problem = strings.clone(win_startup_read(&l.items, a), a)
	}
	if !ui.post(s.state, win_startup_posted, l) { win_startup_list_free(l) }
}

@(private = "file")
win_startup_posted :: proc(data: rawptr, _: u64) {
	l := (^Win_Startup_List)(data)
	app := the_app
	if app == nil { win_startup_list_free(l); return }
	s := &app.startup
	win_startup_list_free(s.list)
	s.list = l
	for it in l.items { if it.enabled { l.on_count += 1 } }
	if l.changed {
		s.pending = false
		n := len(l.names)
		switch {
		case l.failures == 0 && n == 1:
			say(app, l.on ? i18n.tr("Enabled %s in StartupApproved") : i18n.tr("Disabled %s in StartupApproved"), l.names[0])
		case l.failures == 0 && l.on:
			say(app, i18n.tr(n, "Enabled %d startup item", "Enabled %d startup items"), n)
		case l.failures == 0:
			say(app, i18n.tr(n, "Disabled %d startup item", "Disabled %d startup items"), n)
		case l.failures == 1:
			say(app, "%s", l.failure)
		case:
			say(app, i18n.tr(l.failures - 1, "%s (and %d other failed)", "%s (and %d others failed)"), l.failure, l.failures - 1)
		}
	}
	win_startup_rows(app)
}

win_startup_rows :: proc(app: ^App) {
	s := &app.startup
	st := &s.rows
	section_rows_reset(st, len(WIN_STARTUP_COLUMNS))
	if s.list != nil {
		for it in s.list.items {
			src := i18n.tr(WIN_STARTUP_SOURCE_LABELS[it.source])
			glyph := lucide.POWER
			if it.source == .Task_Scheduler { glyph = lucide.CLOCK_2 } else if it.source == .User_Folder || it.source == .Common_Folder { glyph = lucide.FOLDER }
			key_str := fmt.tprintf("%d:%s", int(it.source), it.id)
			hay := strings.join({it.name, it.status, src, it.command, it.location}, " ", context.temp_allocator)
			section_row(st, name_id(key_str), hay, Row_Icon{glyph = glyph}, it.enabled ? .Normal : .Dim)
			ui.table_data_cell(&st.data, it.name)
			ui.table_data_cell(&st.data, it.status)
			ui.table_data_cell(&st.data, src)
			ui.table_data_cell(&st.data, it.command)
			ui.table_data_cell(&st.data, it.location)
		}
	}
	ui.table_apply(&st.table, &st.data, app.query)
}

selected_startup :: proc(app: ^App) -> (it: Win_Startup_Item, ok: bool) {
	s := &app.startup
	i := ui.table_selected(&s.rows.table)
	if s.list == nil || i < 0 || i >= len(s.list.items) { return }
	return s.list.items[i], true
}

////////////////////////////////
// Direct Windows Startup readers & StartupApproved writer

win_startup_read :: proc(out: ^[dynamic]Win_Startup_Item, a: mem.Allocator) -> string {
	read_run_key(win.HKEY_CURRENT_USER, KEY_WOW64_64KEY, .HKCU_Run, APPROVED_RUN, "HKCU\\" + RUN_SUBKEY, false, out, a)
	// (a user's Software has one view: the 32-bit one is the same key)
	read_run_key(win.HKEY_LOCAL_MACHINE, KEY_WOW64_64KEY, .HKLM_Run, APPROVED_RUN, "HKLM\\" + RUN_SUBKEY, true, out, a)
	read_run_key(win.HKEY_LOCAL_MACHINE, KEY_WOW64_32KEY, .HKLM_Run_32, APPROVED_RUN32, "HKLM\\Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Run", true, out, a)

	if dir := win_known_folder(win.FOLDERID_Startup); dir != "" {
		read_startup_folder(dir, .User_Folder, win.HKEY_CURRENT_USER, false, out, a)
	}
	if dir := win_known_folder(win.FOLDERID_CommonStartup); dir != "" {
		read_startup_folder(dir, .Common_Folder, win.HKEY_LOCAL_MACHINE, true, out, a)
	}

	tasks_read := read_logon_tasks(out, a)

	slice.sort_by(out[:], proc(x, y: Win_Startup_Item) -> bool {
		return strings.to_lower(x.name, context.temp_allocator) < strings.to_lower(y.name, context.temp_allocator)
	})
	if !tasks_read { return i18n.tr("The tasks that start at logon are listed to an administrator alone.") }
	return ""
}

@(private = "file")
read_run_key :: proc(root: win.HKEY, wow_flag: win.DWORD, source: Win_Startup_Source, approved_subkey, loc_label: string, needs_admin: bool, out: ^[dynamic]Win_Startup_Item, a: mem.Allocator) {
	hk: win.HKEY
	if win.RegOpenKeyExW(root, win.utf8_to_wstring(RUN_SUBKEY, context.temp_allocator), 0, win.KEY_READ | wow_flag, &hk) != 0 { return }
	defer win.RegCloseKey(hk)

	name_buf := make([]u16, 16384, context.temp_allocator)   // (the longest name of a value)
	data_buf := win_bytes(64 * 1024)
	for idx := win.DWORD(0); ; idx += 1 {
		nlen := win.DWORD(len(name_buf))
		dlen := win.DWORD(len(data_buf))
		typ: win.DWORD
		rc := win.RegEnumValueW(hk, idx, &name_buf[0], &nlen, nil, &typ, (^win.BYTE)(raw_data(data_buf)), &dlen)
		if rc == i32(WIN_ERROR_MORE_DATA) { continue }   // (a command longer than any Windows runs)
		if rc != 0 { break }   // (no more items; or the key went, which every index would say again)
		if typ != win.REG_SZ && typ != win.REG_EXPAND_SZ { continue }
		vname := win_utf16_to_utf8(name_buf[:int(nlen)], a)
		if vname == "" { continue }
		cmd := winapi.decode_utf16le(data_buf[:min(int(dlen), len(data_buf))], a)
		enabled := true
		if raw, ok := win_reg_read_binary(root, approved_subkey, vname, KEY_WOW64_64KEY); ok {
			if en, _, valid := winapi.decode_startup_approved(raw); valid { enabled = en }
		}
		target := strings.clone(win_extract_exe_path(cmd), a)
		append(out, Win_Startup_Item{
			source      = source,
			id          = vname,
			name        = vname,
			command     = cmd,
			location    = strings.clone(loc_label, a),
			target_path = target,
			enabled     = enabled,
			status      = strings.clone(enabled ? i18n.tr("Enabled") : i18n.tr("Disabled"), a),
			can_toggle  = true,
			needs_admin = needs_admin,
		})
	}
}

@(private = "file")
read_startup_folder :: proc(dir: string, source: Win_Startup_Source, root: win.HKEY, needs_admin: bool, out: ^[dynamic]Win_Startup_Item, a: mem.Allocator) {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return }
	for e in entries {
		if e.type == .Directory { continue }
		fname := e.name
		if strings.equal_fold(fname, "desktop.ini") { continue }
		full := fmt.tprintf("%s\\%s", strings.trim_right(dir, "\\/"), fname)
		display := fname
		cmd := full
		target := full
		if strings.has_suffix(strings.to_lower(fname, context.temp_allocator), ".lnk") {
			display = fname[:len(fname) - 4]
			if raw, rerr := os.read_entire_file(full, context.temp_allocator); rerr == nil {
				if lnk, ok := winapi.decode_lnk(raw, context.temp_allocator); ok && lnk.target != "" {
					target = lnk.target
					cmd = lnk.arguments != "" ? fmt.tprintf("%s %s", lnk.target, lnk.arguments) : lnk.target
				}
			}
		}
		enabled := true
		if raw, ok := win_reg_read_binary(root, APPROVED_FOLDER, fname, KEY_WOW64_64KEY); ok {
			if en, _, valid := winapi.decode_startup_approved(raw); valid { enabled = en }
		}
		append(out, Win_Startup_Item{
			source      = source,
			id          = strings.clone(fname, a),
			name        = strings.clone(display, a),
			command     = strings.clone(cmd, a),
			location    = strings.clone(full, a),
			target_path = strings.clone(target, a),
			enabled     = enabled,
			status      = strings.clone(enabled ? i18n.tr("Enabled") : i18n.tr("Disabled"), a),
			can_toggle  = true,
			needs_admin = needs_admin,
		})
	}
}

// Walks %SystemRoot%\System32\Tasks XML files (bounded) and adds tasks that have a LogonTrigger. False: this user may not
// read the folder.
@(private = "file")
read_logon_tasks :: proc(out: ^[dynamic]Win_Startup_Item, a: mem.Allocator) -> bool {
	sysroot := os.get_env("SystemRoot", context.temp_allocator)
	if sysroot == "" { sysroot = "C:\\Windows" }
	root_dir := fmt.tprintf("%s\\System32\\Tasks", strings.trim_right(sysroot, "\\/"))
	budget := 400
	return walk_tasks_dir(root_dir, "", 0, &budget, out, a)
}

@(private = "file")
walk_tasks_dir :: proc(dir, rel_prefix: string, depth: int, budget: ^int, out: ^[dynamic]Win_Startup_Item, a: mem.Allocator) -> bool {
	if depth > 4 || budget^ <= 0 { return true }
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return false }
	for e in entries {
		if budget^ <= 0 { return true }
		budget^ -= 1
		rel := rel_prefix != "" ? fmt.tprintf("%s\\%s", rel_prefix, e.name) : e.name
		full := fmt.tprintf("%s\\%s", strings.trim_right(dir, "\\/"), e.name)
		if e.type == .Directory {
			// Skip massive built-in Microsoft system maintenance subtrees unless top-level or user-defined.
			if depth == 0 && strings.equal_fold(e.name, "Microsoft") { continue }
			_ = walk_tasks_dir(full, rel, depth + 1, budget, out, a)   // (a folder of another user's)
			continue
		}
		if e.size > 256 * 1024 { continue }
		raw, rerr := os.read_entire_file(full, context.temp_allocator)
		if rerr != nil || len(raw) == 0 { continue }
		task, ok := winapi.parse_task_xml(raw, context.temp_allocator)
		if !ok || !task.has_logon_trigger || task.command == "" { continue }
		cmd := task.arguments != "" ? fmt.tprintf("%s %s", task.command, task.arguments) : task.command
		append(out, Win_Startup_Item{
			source      = .Task_Scheduler,
			id          = strings.clone(rel, a),
			name        = strings.clone(e.name, a),
			command     = strings.clone(cmd, a),
			location    = strings.clone(full, a),
			target_path = strings.clone(win_extract_exe_path(task.command), a),
			enabled     = task.enabled,
			status      = strings.clone(task.enabled ? i18n.tr("Enabled") : i18n.tr("Disabled"), a),
			can_toggle  = false,
			needs_admin = true,
		})
	}
	return true
}

// Writes Task Manager's 12-byte StartupApproved REG_BINARY state for a Run key or Startup folder item.
win_startup_set_enabled :: proc(source: Win_Startup_Source, id: string, enable: bool) -> string {
	root: win.HKEY
	subkey: string
	switch source {
	case .HKCU_Run:      root, subkey = win.HKEY_CURRENT_USER, APPROVED_RUN
	case .HKLM_Run:      root, subkey = win.HKEY_LOCAL_MACHINE, APPROVED_RUN
	case .HKLM_Run_32:   root, subkey = win.HKEY_LOCAL_MACHINE, APPROVED_RUN32
	case .User_Folder:   root, subkey = win.HKEY_CURRENT_USER, APPROVED_FOLDER
	case .Common_Folder: root, subkey = win.HKEY_LOCAL_MACHINE, APPROVED_FOLDER
	case .Task_Scheduler:
		return i18n.tr("Task Scheduler items are changed in Task Scheduler")
	}

	hk: win.HKEY
	disp: win.DWORD
	rc := win.RegCreateKeyExW(root, win.utf8_to_wstring(subkey, context.temp_allocator), 0, nil, 0, win.KEY_SET_VALUE | KEY_WOW64_64KEY, nil, &hk, &disp)
	if rc != 0 {
		if rc == i32(win.ERROR_ACCESS_DENIED) {
			return i18n.tr("administrator privileges required for system-wide startup entries")
		}
		return fmt.tprintf(i18n.tr("cannot open StartupApproved key (error %d)"), int(rc))
	}
	defer win.RegCloseKey(hk)

	blob := winapi.encode_startup_approved(enable, win_now_filetime())
	wrc := win.RegSetValueExW(hk, win.utf8_to_wstring(id, context.temp_allocator), 0, win.REG_BINARY, (^win.BYTE)(&blob[0]), win.DWORD(len(blob)))
	if wrc != 0 {
		if wrc == i32(win.ERROR_ACCESS_DENIED) {
			return i18n.tr("administrator privileges required for system-wide startup entries")
		}
		return fmt.tprintf(i18n.tr("cannot write StartupApproved value (error %d)"), int(wrc))
	}
	return ""
}

@(private = "file")
win_known_folder :: proc(folder_id: win.GUID) -> string {
	sh32 := win_system_library("shell32.dll")
	ole32 := win_system_library("ole32.dll")
	if sh32 == nil || ole32 == nil { return "" }
	defer win.FreeLibrary(sh32)
	defer win.FreeLibrary(ole32)
	SHGetKnownFolderPath := (proc "system" (rfid: ^win.GUID, flags: u32, tok: win.HANDLE, path: ^[^]u16) -> win.HRESULT)(win.GetProcAddress(sh32, "SHGetKnownFolderPath"))
	CoTaskMemFree := (proc "system" (p: rawptr))(win.GetProcAddress(ole32, "CoTaskMemFree"))
	if SHGetKnownFolderPath == nil || CoTaskMemFree == nil { return "" }
	id := folder_id
	wpath: [^]u16
	if SHGetKnownFolderPath(&id, 0, nil, &wpath) < 0 || wpath == nil { return "" }
	defer CoTaskMemFree(wpath)
	return win_wstr_to_utf8(wpath, 1024, context.temp_allocator)
}
