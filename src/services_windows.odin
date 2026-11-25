package inspecteur

// Windows Service Control Manager (SCM) and Windows Event Log (wevtapi.dll) model.
// - Direct advapi32.dll SCM calls (no WMI, no sc.exe/powershell subprocesses).
// - Supports all Win32 services, shared svchost groups, kernel/file-system drivers,
//   Pause/Continue, 4 startup types (Automatic, Automatic Delayed, Manual, Disabled),
//   service dependencies/dependents, and PPL protection status (SERVICE_CONFIG_LAUNCH_PROTECTED).
// - Event Log pane queries System and Application channels via wevtapi.dll on a worker thread.

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import win "core:sys/windows"
import i18n "gt:i18n"
import lucide "gt:lucide"
import tasks "gt:tasks"
import "gt:ui"
import winapi "winapi"

WIN_SC_MANAGER_CONNECT           :: win.DWORD(0x0001)
WIN_SC_MANAGER_ENUMERATE_SERVICE :: win.DWORD(0x0004)

WIN_SERVICE_QUERY_CONFIG         :: win.DWORD(0x0001)
WIN_SERVICE_CHANGE_CONFIG        :: win.DWORD(0x0002)
WIN_SERVICE_QUERY_STATUS         :: win.DWORD(0x0004)
WIN_SERVICE_ENUMERATE_DEPENDENTS :: win.DWORD(0x0008)
WIN_SERVICE_START                :: win.DWORD(0x0010)
WIN_SERVICE_STOP                 :: win.DWORD(0x0020)
WIN_SERVICE_PAUSE_CONTINUE       :: win.DWORD(0x0040)

WIN_SERVICE_KERNEL_DRIVER        :: win.DWORD(0x00000001)
WIN_SERVICE_FILE_SYSTEM_DRIVER   :: win.DWORD(0x00000002)
WIN_SERVICE_WIN32_OWN_PROCESS    :: win.DWORD(0x00000010)
WIN_SERVICE_WIN32_SHARE_PROCESS  :: win.DWORD(0x00000020)
WIN_SERVICE_WIN32                :: WIN_SERVICE_WIN32_OWN_PROCESS | WIN_SERVICE_WIN32_SHARE_PROCESS
WIN_SERVICE_DRIVER               :: WIN_SERVICE_KERNEL_DRIVER | WIN_SERVICE_FILE_SYSTEM_DRIVER

WIN_SERVICE_ACTIVE               :: win.DWORD(0x00000001)
WIN_SERVICE_STATE_ALL            :: win.DWORD(0x00000003)

@(private = "file") SERVICE_CONTROL_STOP     :: win.DWORD(0x00000001)
@(private = "file") SERVICE_CONTROL_PAUSE    :: win.DWORD(0x00000002)
@(private = "file") SERVICE_CONTROL_CONTINUE :: win.DWORD(0x00000003)

@(private = "file") SERVICE_ACCEPT_STOP           :: u32(0x00000001)
@(private = "file") SERVICE_ACCEPT_PAUSE_CONTINUE :: u32(0x00000002)

@(private = "file") SERVICE_CONFIG_DESCRIPTION              :: win.DWORD(1)
@(private = "file") SERVICE_CONFIG_DELAYED_AUTO_START_INFO  :: win.DWORD(3)
@(private = "file") SERVICE_CONFIG_LAUNCH_PROTECTED         :: win.DWORD(12)
@(private = "file") SERVICE_NO_CHANGE                       :: win.DWORD(0xFFFFFFFF)

@(private = "file") ERROR_DEPENDENT_SERVICES_RUNNING :: win.DWORD(1051)
@(private = "file") ERROR_SERVICE_ALREADY_RUNNING    :: win.DWORD(1056)
@(private = "file") ERROR_PROC_NOT_FOUND             :: win.DWORD(127)
@(private = "file") ERROR_SERVICE_NOT_ACTIVE         :: win.DWORD(1062)

@(private = "file")
Win_Scm_Procs :: struct {
	OpenSCManagerW:          proc "system" (machine, db: win.LPCWSTR, access: win.DWORD) -> win.HANDLE,
	CloseServiceHandle:      proc "system" (h: win.HANDLE) -> win.BOOL,
	EnumServicesStatusExW:   proc "system" (scm: win.HANDLE, info_level: win.DWORD, svc_type, state: win.DWORD, buf: rawptr, buf_size: win.DWORD, needed, count, resume: ^win.DWORD, group: win.LPCWSTR) -> win.BOOL,
	OpenServiceW:            proc "system" (scm: win.HANDLE, name: win.LPCWSTR, access: win.DWORD) -> win.HANDLE,
	QueryServiceConfigW:     proc "system" (svc: win.HANDLE, buf: rawptr, buf_size: win.DWORD, needed: ^win.DWORD) -> win.BOOL,
	QueryServiceConfig2W:    proc "system" (svc: win.HANDLE, info_level: win.DWORD, buf: rawptr, buf_size: win.DWORD, needed: ^win.DWORD) -> win.BOOL,
	QueryServiceStatusEx:    proc "system" (svc: win.HANDLE, info_level: win.DWORD, buf: rawptr, buf_size: win.DWORD, needed: ^win.DWORD) -> win.BOOL,
	EnumDependentServicesW:  proc "system" (svc: win.HANDLE, state: win.DWORD, buf: rawptr, buf_size: win.DWORD, needed, count: ^win.DWORD) -> win.BOOL,
	StartServiceW:           proc "system" (svc: win.HANDLE, num_args: win.DWORD, args: ^win.LPCWSTR) -> win.BOOL,
	ControlService:          proc "system" (svc: win.HANDLE, control: win.DWORD, status: rawptr) -> win.BOOL,
	ChangeServiceConfigW:    proc "system" (svc: win.HANDLE, svc_type, start_type, err_ctrl: win.DWORD, bin, load_grp: win.LPCWSTR, tag_id: ^win.DWORD, deps, start_name, pass, disp: win.LPCWSTR) -> win.BOOL,
	ChangeServiceConfig2W:   proc "system" (svc: win.HANDLE, info_level: win.DWORD, info: rawptr) -> win.BOOL,
}

@(private = "file")
Win_Evt_Procs :: struct {
	EvtQuery:                 proc "system" (session: win.HANDLE, path, query: win.LPCWSTR, flags: win.DWORD) -> win.HANDLE,
	EvtNext:                  proc "system" (res_set: win.HANDLE, count: win.DWORD, events: [^]win.HANDLE, timeout, flags: win.DWORD, returned: ^win.DWORD) -> win.BOOL,
	EvtRender:                proc "system" (ctx, fragment: win.HANDLE, flags, buf_size: win.DWORD, buf: rawptr, buf_used, prop_count: ^win.DWORD) -> win.BOOL,
	EvtOpenPublisherMetadata: proc "system" (session: win.HANDLE, pub_id, log_file: win.LPCWSTR, locale, flags: win.DWORD) -> win.HANDLE,
	EvtFormatMessage:         proc "system" (pub_meta, event: win.HANDLE, msg_id, val_count: win.DWORD, values: rawptr, flags, buf_size: win.DWORD, buf: [^]u16, buf_used: ^win.DWORD) -> win.BOOL,
	EvtClose:                 proc "system" (h: win.HANDLE) -> win.BOOL,
}

@(private = "file") win_scm_once: sync.Once
@(private = "file") win_scm_procs: Win_Scm_Procs
@(private = "file") win_evt_once: sync.Once
@(private = "file") win_evt_procs: Win_Evt_Procs

@(private = "file")
win_scm :: proc() -> ^Win_Scm_Procs {
	sync.once_do(&win_scm_once, proc() {
		if adv := win_system_library("advapi32.dll"); adv != nil {
			win_scm_procs.OpenSCManagerW         = auto_cast win.GetProcAddress(adv, "OpenSCManagerW")
			win_scm_procs.CloseServiceHandle     = auto_cast win.GetProcAddress(adv, "CloseServiceHandle")
			win_scm_procs.EnumServicesStatusExW  = auto_cast win.GetProcAddress(adv, "EnumServicesStatusExW")
			win_scm_procs.OpenServiceW           = auto_cast win.GetProcAddress(adv, "OpenServiceW")
			win_scm_procs.QueryServiceConfigW    = auto_cast win.GetProcAddress(adv, "QueryServiceConfigW")
			win_scm_procs.QueryServiceConfig2W   = auto_cast win.GetProcAddress(adv, "QueryServiceConfig2W")
			win_scm_procs.QueryServiceStatusEx   = auto_cast win.GetProcAddress(adv, "QueryServiceStatusEx")
			win_scm_procs.EnumDependentServicesW = auto_cast win.GetProcAddress(adv, "EnumDependentServicesW")
			win_scm_procs.StartServiceW          = auto_cast win.GetProcAddress(adv, "StartServiceW")
			win_scm_procs.ControlService         = auto_cast win.GetProcAddress(adv, "ControlService")
			win_scm_procs.ChangeServiceConfigW   = auto_cast win.GetProcAddress(adv, "ChangeServiceConfigW")
			win_scm_procs.ChangeServiceConfig2W  = auto_cast win.GetProcAddress(adv, "ChangeServiceConfig2W")
		}
	})
	return &win_scm_procs
}

@(private = "file")
win_evt :: proc() -> ^Win_Evt_Procs {
	sync.once_do(&win_evt_once, proc() {
		if w := win_system_library("wevtapi.dll"); w != nil {
			win_evt_procs.EvtQuery                 = auto_cast win.GetProcAddress(w, "EvtQuery")
			win_evt_procs.EvtNext                  = auto_cast win.GetProcAddress(w, "EvtNext")
			win_evt_procs.EvtRender                = auto_cast win.GetProcAddress(w, "EvtRender")
			win_evt_procs.EvtOpenPublisherMetadata = auto_cast win.GetProcAddress(w, "EvtOpenPublisherMetadata")
			win_evt_procs.EvtFormatMessage         = auto_cast win.GetProcAddress(w, "EvtFormatMessage")
			win_evt_procs.EvtClose                 = auto_cast win.GetProcAddress(w, "EvtClose")
		}
	})
	return &win_evt_procs
}

// Package-visible SCM wrappers shared with processes_windows.odin.
win_scm_open :: proc(access: win.DWORD) -> win.HANDLE {
	s := win_scm()
	if s.OpenSCManagerW == nil { return nil }
	return s.OpenSCManagerW(nil, nil, access)
}

win_scm_close :: proc(h: win.HANDLE) {
	if h == nil { return }
	if s := win_scm(); s.CloseServiceHandle != nil { s.CloseServiceHandle(h) }
}

// Calls `visit` with each service of the types and states asked; its texts live during the call alone. The SCM gives them
// in pages (256 KB at most each). 0, or the error.
win_scm_list :: proc(scm: win.HANDLE, svc_type, state: win.DWORD, data: rawptr, visit: proc(data: rawptr, entry: winapi.ENUM_SERVICE_STATUS_PROCESSW64)) -> win.DWORD {
	s := win_scm()
	if s.EnumServicesStatusExW == nil { return ERROR_PROC_NOT_FOUND }
	buf := win_bytes(128 * 1024)
	resume: win.DWORD
	for _ in 0 ..< 64 {
		needed, count: win.DWORD
		e := win.DWORD(0)
		if !s.EnumServicesStatusExW(scm, 0 /* SC_ENUM_PROCESS_INFO */, svc_type, state, raw_data(buf), win.DWORD(len(buf)), &needed, &count, &resume, nil) {
			e = win.GetLastError()
			if e != WIN_ERROR_MORE_DATA { return e }
		}
		entries := ([^]winapi.ENUM_SERVICE_STATUS_PROCESSW64)(raw_data(buf))[:min(int(count), len(buf) / size_of(winapi.ENUM_SERVICE_STATUS_PROCESSW64))]
		for entry in entries { visit(data, entry) }
		if e == 0 { return 0 }
		if count == 0 { return e }
	}
	return WIN_ERROR_MORE_DATA
}

////////////////////////////////
// Model types

Win_Service_Filter :: enum u8 { Services, Shared, Drivers }
WIN_SERVICE_FILTER_KEYS   := [Win_Service_Filter]string{.Services = "services", .Shared = "shared", .Drivers = "drivers"}
WIN_SERVICE_FILTER_LABELS := [Win_Service_Filter]string{.Services = i18n.later("Services"), .Shared = i18n.later("Shared (svchost)"), .Drivers = i18n.later("Drivers")}

Win_Service_Action :: enum u8 { None, Start, Stop, Restart, Pause, Continue, Set_Startup }

WIN_SERVICE_ACTION_DOING := [Win_Service_Action]string{
	.None        = "",
	.Start       = i18n.later("Starting %s…"),
	.Stop        = i18n.later("Stopping %s…"),
	.Restart     = i18n.later("Restarting %s…"),
	.Pause       = i18n.later("Pausing %s…"),
	.Continue    = i18n.later("Resuming %s…"),
	.Set_Startup = i18n.later("Changing startup type of %s…"),
}

WIN_SERVICE_ACTION_DONE := [Win_Service_Action]string{
	.None        = "",
	.Start       = i18n.later("Started %s"),
	.Stop        = i18n.later("Stopped %s"),
	.Restart     = i18n.later("Restarted %s"),
	.Pause       = i18n.later("Paused %s"),
	.Continue    = i18n.later("Resumed %s"),
	.Set_Startup = i18n.later("Changed startup type of %s"),
}

Win_Startup_Type :: enum u8 { Unknown, Boot, System, Automatic, Automatic_Delayed, Manual, Disabled }

WIN_STARTUP_TYPE_LABELS := [Win_Startup_Type]string{
	.Unknown           = "?",   // its configuration cannot be read by this user
	.Boot              = i18n.later("Boot"),
	.System            = i18n.later("System"),
	.Automatic         = i18n.later("Automatic"),
	.Automatic_Delayed = i18n.later("Automatic (Delayed)"),
	.Manual            = i18n.later("Manual"),
	.Disabled          = i18n.later("Disabled"),
}

// The values of the palette's form.
WIN_STARTUP_TYPE_KEYS := [Win_Startup_Type]string{
	.Unknown = "", .Boot = "boot", .System = "system", .Automatic = "automatic", .Automatic_Delayed = "delayed", .Manual = "manual", .Disabled = "disabled",
}

// Editable startup types shown in the picker / command palette.
WIN_EDITABLE_STARTUPS := [?]Win_Startup_Type{.Automatic, .Automatic_Delayed, .Manual, .Disabled}

Win_Service_State :: enum u8 { Unknown, Stopped, Start_Pending, Stop_Pending, Running, Continue_Pending, Pause_Pending, Paused }

WIN_SERVICE_STATE_LABELS := [Win_Service_State]string{
	.Unknown          = "?",
	.Stopped          = i18n.later("Stopped"),
	.Start_Pending    = i18n.later("Starting"),
	.Stop_Pending     = i18n.later("Stopping"),
	.Running          = i18n.later("Running"),
	.Continue_Pending = i18n.later("Resuming"),
	.Pause_Pending    = i18n.later("Pausing"),
	.Paused           = i18n.later("Paused"),
}

EventLog_Level :: enum u8 { All, Warnings, Errors }
EVENTLOG_LEVEL_KEYS   := [EventLog_Level]string{.All = "all", .Warnings = "warnings", .Errors = "errors"}
EVENTLOG_LEVEL_LABELS := [EventLog_Level]string{.All = i18n.later("All"), .Warnings = i18n.later("Warnings"), .Errors = i18n.later("Errors")}

eventlog_level_keeps :: proc(l: EventLog_Level, lvl: u8) -> bool {
	// Windows Event Log levels: 1 Critical, 2 Error, 3 Warning, 4 Info, 5 Verbose.
	switch l {
	case .All:      return true
	case .Warnings: return lvl >= 1 && lvl <= 3
	case .Errors:   return lvl == 1 || lvl == 2
	}
	return true
}

Win_Service :: struct {
	name:          string,
	display_name:  string,
	state:         Win_Service_State,
	startup_type:  Win_Startup_Type,
	service_type:  u32,
	pid:           i32,
	account:       string,
	binary_path:   string,
	svchost_group: string,
	protection:    u32,      // 0=None, 1=Windows, 2=Windows Light, 3=Antimalware Light
	can_stop:      bool,
	can_pause:     bool,
	is_driver:     bool,
}

Win_Service_List :: struct {
	arena:    virtual.Arena,
	filter:   Win_Service_Filter,
	units:    [dynamic]Win_Service,
	problem:  string,
	action:   Win_Service_Action,
	acted:    []string,
	failure:  string,
	failures: int,
	running:  int,
	stopped_auto: int,
}

Win_Event_Entry :: struct {
	timestamp: string,
	level:     u8,
	event_id:  u32,
	provider:  string,
	message:   string,
}

Win_Service_Details :: struct {
	arena:         virtual.Arena,
	name:          string,
	description:   string,
	binary_path:   string,
	account:       string,
	svchost_group: string,
	protection:    string,
	dependencies:  [dynamic]string,
	dependents:    [dynamic]string,
	events:        [dynamic]Win_Event_Entry,
	event_problem: string,
}

@(private = "file")
Win_Service_Ask :: struct {
	filter:       Win_Service_Filter,
	action:       Win_Service_Action,
	startup_type: Win_Startup_Type,
	names:        [dynamic]string,   // heap
}

@(private = "file")
Win_Details_Ask :: struct {
	name: string,   // heap
}

// Detached Event Log window instance (JOURNAL_VIEW "<service>").
Event_Window :: struct {
	name:         string,   // owned
	job:          tasks.Job,
	demo:         ^Demo,
	state:        ^ui.State,
	details:      ^Win_Service_Details,
	level:        EventLog_Level,
	follow:       bool,
	search:       ui.Line_Edit,
	search_key:   ui.Key,
	vl:           ui.Virtual_List,
	next:         time.Tick,
	serial:       int,
	shown:        [dynamic]int,
	shown_ids:    [dynamic]u64,
	shown_of:     int,
	shown_level:  EventLog_Level,
	shown_query:  string,
}

Services :: struct {
	job:              tasks.Job,
	details_job:      tasks.Job,
	demo:             ^Demo,
	state:            ^ui.State,
	mutex:            sync.Mutex,
	ask:              Win_Service_Ask,
	details_ask:      Win_Details_Ask,
	filter:           Win_Service_Filter,
	list:             ^Win_Service_List,
	details:          ^Win_Service_Details,
	rows:             Section_Table,
	readings:         u64,
	select_name:      string,   // owned: a service to select once a reading lists it (Go to service)
	pending:          Win_Service_Action,
	next:             time.Tick,
	details_for:      u64,
	// Event log viewer inside the details pane.
	event_level:      EventLog_Level,
	event_follow:     bool,
	event_search:     ui.Line_Edit,
	event_search_key: ui.Key,
	event_vl:         ui.Virtual_List,
	event_next:       time.Tick,
	event_serial:     int,
	event_shown:      [dynamic]int,
	event_shown_ids:  [dynamic]u64,
	event_shown_of:   int,
	event_shown_lvl:  EventLog_Level,
	event_shown_q:    string,
	windows:          map[string]^Event_Window,
}

WIN_SERVICE_COLUMNS := [?]ui.Table_Column{
	{title = i18n.later("Name"), width = 16},
	{title = i18n.later("Display name"), width = 0},
	{title = i18n.later("Status"), width = 9},
	{title = i18n.later("Startup type"), width = 13, weak = true},
	{title = i18n.later("PID"), width = 6, number = true, weak = true},
	{title = i18n.later("Group"), width = 13, weak = true},
	{title = i18n.later("Account"), width = 14, weak = true},
	{title = i18n.later("Protection"), width = 13, weak = true},
}

SERVICE_AFTER_ACTION :: 500 * time.Millisecond
EVENTLOG_FOLLOW_MS   :: 3000
EVENTLOG_MAX_ENTRIES :: 400
EVENTLOG_MAX_SCANNED :: 600

services_init :: proc(s: ^Services, app: ^App) {
	section_table_init(&s.rows, app, WIN_SERVICE_COLUMNS[:])
	section_layout_load(&s.rows, &app.prefs, "services")
	s.demo         = app.demo
	s.state        = &app.main.state
	s.filter       = app.settings.extra.service_filter
	s.event_level  = app.settings.extra.eventlog_level
	s.event_follow = app.settings.extra.eventlog_follow
	s.job          = {work = win_services_work, data = s}
	s.details_job  = {work = win_details_work, data = s}
}

services_destroy :: proc(s: ^Services) {
	ask_names_free(&s.ask.names)
	delete(s.details_ask.name, runtime.heap_allocator())
	win_service_list_free(s.list)
	win_service_details_free(s.details)
	section_table_destroy(&s.rows)
	ui.line_edit_destroy(&s.event_search)
	ui.vlist_destroy(&s.event_vl)
	delete(s.event_shown)
	delete(s.event_shown_ids)
	delete(s.event_shown_q)
	delete(s.select_name)
}

@(private = "file")
win_service_list_free :: proc(l: ^Win_Service_List) {
	if l == nil { return }
	virtual.arena_destroy(&l.arena)
	free(l)
}

win_service_details_free :: proc(d: ^Win_Service_Details) {
	if d == nil { return }
	virtual.arena_destroy(&d.arena)
	free(d)
}

@(private = "file")
ask_names_free :: proc(names: ^[dynamic]string) {
	for n in names^ { delete(n, runtime.heap_allocator()) }
	delete(names^)
	names^ = nil
}

services_busy :: proc(app: ^App) -> bool {
	return tasks.job_busy(ui.chores(), &app.services.job)
}

services_ask :: proc(app: ^App, action := Win_Service_Action.None, names: []string = nil, startup := Win_Startup_Type.Manual) {
	s := &app.services
	sync.lock(&s.mutex)
	s.ask.filter = s.filter
	if action != .None {
		s.ask.action = action
		s.ask.startup_type = startup
		ask_names_free(&s.ask.names)
		heap := runtime.heap_allocator()
		s.ask.names = make([dynamic]string, 0, len(names), heap)
		for n in names { append(&s.ask.names, strings.clone(n, heap)) }
	}
	sync.unlock(&s.mutex)
	tasks.job_ask(ui.chores(), &s.job)
	s.next = time.tick_add(time.tick_now(), time.Duration(app.settings.services_ms) * time.Millisecond)
}

win_details_ask :: proc(app: ^App, name: string) {
	s := &app.services
	sync.lock(&s.mutex)
	delete(s.details_ask.name, runtime.heap_allocator())
	s.details_ask.name = strings.clone(name, runtime.heap_allocator())
	sync.unlock(&s.mutex)
	tasks.job_ask(ui.chores(), &s.details_job)
	s.event_next = time.tick_add(time.tick_now(), EVENTLOG_FOLLOW_MS * time.Millisecond)
}

@(private = "file")
win_services_work :: proc(data: rawptr) {
	s := (^Services)(data)
	l := new(Win_Service_List)
	a := virtual.arena_allocator(&l.arena)
	sync.lock(&s.mutex)
	filter := s.ask.filter
	action := s.ask.action
	startup := s.ask.startup_type
	asked := make([]string, len(s.ask.names), a)
	for n, i in s.ask.names { asked[i] = strings.clone(n, a) }
	ask_names_free(&s.ask.names)
	s.ask.action = .None
	sync.unlock(&s.mutex)

	l.filter = filter
	l.units = make([dynamic]Win_Service, 0, 128, a)

	if action != .None {
		l.action = action
		l.acted = asked
		for name in asked {
			why := s.demo != nil ? DEMO_REFUSED : win_service_act(name, action, startup)
			if why == "" { continue }
			if l.failures == 0 { l.failure = strings.concatenate({name, ": ", why}, a) }
			l.failures += 1
		}
	}

	if s.demo != nil {
		l.problem = strings.clone(demo_services_read(s.demo, filter, &l.units, a), a)
	} else {
		l.problem = strings.clone(win_services_read(filter, &l.units, a), a)
	}
	if !ui.post(s.state, win_services_posted, l) { win_service_list_free(l) }
}

@(private = "file")
win_services_posted :: proc(data: rawptr, _: u64) {
	l := (^Win_Service_List)(data)
	app := the_app
	if app == nil { win_service_list_free(l); return }
	s := &app.services
	win_service_list_free(s.list)
	s.list = l
	s.readings += 1
	for u in l.units {
		if u.state == .Running { l.running += 1 }
		if u.state == .Stopped && (u.startup_type == .Automatic || u.startup_type == .Automatic_Delayed) {
			l.stopped_auto += 1
		}
	}
	if l.action != .None {
		s.pending = .None
		n := len(l.acted)
		switch {
		case l.failures == 0 && n == 1:
			say(app, i18n.tr(WIN_SERVICE_ACTION_DONE[l.action]), l.acted[0])
		case l.failures == 0:
			say(app, i18n.tr(WIN_SERVICE_ACTION_DONE[l.action]), fmt.tprintf(i18n.tr(n, "%d service", "%d services"), n))
		case l.failures == 1:
			say(app, "%s", l.failure)
		case:
			say(app, i18n.tr(l.failures - 1, "%s (and %d other failed)", "%s (and %d others failed)"), l.failure, l.failures - 1)
		}
		s.next = time.tick_add(time.tick_now(), SERVICE_AFTER_ACTION)
	}
	win_services_rows(app)
}

@(private = "file")
win_details_work :: proc(data: rawptr) {
	s := (^Services)(data)
	d := new(Win_Service_Details)
	a := virtual.arena_allocator(&d.arena)
	sync.lock(&s.mutex)
	d.name = strings.clone(s.details_ask.name, a)
	sync.unlock(&s.mutex)
	d.dependencies = make([dynamic]string, a)
	d.dependents   = make([dynamic]string, a)
	d.events       = make([dynamic]Win_Event_Entry, a)
	if d.name != "" {
		if s.demo != nil {
			demo_service_details(s.demo, d, a)
		} else {
			win_service_details_read(d, a)
		}
	}
	if !ui.post(s.state, win_details_posted, d) { win_service_details_free(d) }
}

@(private = "file")
win_details_posted :: proc(data: rawptr, _: u64) {
	d := (^Win_Service_Details)(data)
	app := the_app
	if app == nil { win_service_details_free(d); return }
	s := &app.services
	win_service_details_free(s.details)
	s.details = d
	s.event_serial += 1
}

win_services_rows :: proc(app: ^App) {
	s := &app.services
	st := &s.rows
	section_rows_reset(st, len(WIN_SERVICE_COLUMNS))
	if s.list != nil && s.list.filter == s.filter {
		for u in s.list.units {
			status := i18n.tr(WIN_SERVICE_STATE_LABELS[u.state])
			startup := i18n.tr(WIN_STARTUP_TYPE_LABELS[u.startup_type])
			pid_s := u.pid > 0 ? fmt.tprintf("%d", u.pid) : ""
			prot := win_service_protection_label(u.protection)
			tone := ui.Table_Tone.Normal
			if u.state == .Stopped { tone = .Dim }
			if u.state == .Stopped && (u.startup_type == .Automatic || u.startup_type == .Automatic_Delayed) { tone = .Bad }
			icon := Row_Icon{glyph = u.is_driver ? lucide.CPU : lucide.SETTINGS}
			hay := strings.join({u.name, u.display_name, status, startup, pid_s, u.svchost_group, u.account, prot}, " ", context.temp_allocator)
			section_row(st, name_id(u.name), hay, icon, tone)
			ui.table_data_cell(&st.data, u.name)
			ui.table_data_cell(&st.data, u.display_name)
			ui.table_data_cell(&st.data, status)
			ui.table_data_cell(&st.data, startup)
			ui.table_data_cell(&st.data, pid_s, f64(u.pid))
			ui.table_data_cell(&st.data, u.svchost_group)
			ui.table_data_cell(&st.data, u.account)
			ui.table_data_cell(&st.data, prot)
		}
	}
	ui.table_apply(&st.table, &st.data, app.query)
	if s.select_name != "" && s.list != nil && s.list.filter == s.filter {
		if !ui.table_select_id(&st.table, name_id(s.select_name)) { say(app, i18n.tr("%s is not among the services listed"), s.select_name) }
		delete(s.select_name)
		s.select_name = ""
	}
}

selected_service :: proc(app: ^App) -> (u: Win_Service, ok: bool) {
	s := &app.services
	i := ui.table_selected(&s.rows.table)
	if s.list == nil || s.list.filter != s.filter || i < 0 || i >= len(s.list.units) { return }
	return s.list.units[i], true
}

// Selects the service `name` once a reading of the filter shown lists it.
service_select :: proc(app: ^App, name: string) {
	s := &app.services
	delete(s.select_name)
	s.select_name = strings.clone(name)
	win_services_rows(app)
}

win_service_protection_label :: proc(prot: u32) -> string {
	switch prot {
	case 1: return i18n.tr("Protected (Windows)")
	case 2: return i18n.tr("Protected (Windows Light)")
	case 3: return i18n.tr("Protected (Antimalware)")
	}
	return ""
}

////////////////////////////////
// Direct SCM reader and actions

@(private = "file")
win_service_state_of :: proc(code: u32) -> Win_Service_State {
	switch code {
	case 1: return .Stopped
	case 2: return .Start_Pending
	case 3: return .Stop_Pending
	case 4: return .Running
	case 5: return .Continue_Pending
	case 6: return .Pause_Pending
	case 7: return .Paused
	}
	return .Unknown
}

@(private = "file")
win_startup_type_of :: proc(code: u32, delayed: bool) -> Win_Startup_Type {
	switch code {
	case 0: return .Boot
	case 1: return .System
	case 2: return delayed ? .Automatic_Delayed : .Automatic
	case 3: return .Manual
	case 4: return .Disabled
	}
	return .Unknown
}

// How a service's process is protected (PPL): 0 for none. `sh` is open with SERVICE_QUERY_CONFIG.
@(private = "file")
win_service_protection :: proc(sh: win.HANDLE) -> (prot: u32) {
	sc := win_scm()
	need: win.DWORD
	if sc.QueryServiceConfig2W == nil || !sc.QueryServiceConfig2W(sh, SERVICE_CONFIG_LAUNCH_PROTECTED, &prot, size_of(prot), &need) { return 0 }
	return prot
}

// Lists Windows services or drivers directly from SCM.
win_services_read :: proc(filter: Win_Service_Filter, out: ^[dynamic]Win_Service, a: mem.Allocator) -> string {
	sc := win_scm()
	if sc.OpenSCManagerW == nil { return i18n.tr("Service Control Manager is not available.") }
	scm := sc.OpenSCManagerW(nil, nil, WIN_SC_MANAGER_CONNECT | WIN_SC_MANAGER_ENUMERATE_SERVICE)
	if scm == nil {
		return fmt.tprintf(i18n.tr("Cannot open Service Control Manager (error %d)."), int(win.GetLastError()))
	}
	defer sc.CloseServiceHandle(scm)

	Reading :: struct { sc: ^Win_Scm_Procs, scm: win.HANDLE, filter: Win_Service_Filter, out: ^[dynamic]Win_Service, a: mem.Allocator, cfg_buf: []u8 }
	r := Reading{sc, scm, filter, out, a, win_bytes(8192)}
	svc_type := filter == .Drivers ? WIN_SERVICE_DRIVER : WIN_SERVICE_WIN32
	e := win_scm_list(scm, svc_type, WIN_SERVICE_STATE_ALL, &r, proc(data: rawptr, entry: winapi.ENUM_SERVICE_STATUS_PROCESSW64) {
		r := (^Reading)(data)
		sc, a := r.sc, r.a
		stype := entry.ServiceStatusProcess.dwServiceType
		if r.filter == .Shared && (stype & u32(WIN_SERVICE_WIN32_SHARE_PROCESS)) == 0 { return }

		name := win_wstr_to_utf8(([^]u16)(uintptr(entry.lpServiceName)), 256, a)
		disp := win_wstr_to_utf8(([^]u16)(uintptr(entry.lpDisplayName)), 256, a)
		if name == "" { return }

		u := Win_Service{
			name         = name,
			display_name = disp != "" ? disp : name,
			state        = win_service_state_of(entry.ServiceStatusProcess.dwCurrentState),
			service_type = stype,
			pid          = i32(entry.ServiceStatusProcess.dwProcessId),
			can_stop     = (entry.ServiceStatusProcess.dwControlsAccepted & SERVICE_ACCEPT_STOP) != 0,
			can_pause    = (entry.ServiceStatusProcess.dwControlsAccepted & SERVICE_ACCEPT_PAUSE_CONTINUE) != 0,
			is_driver    = (stype & u32(WIN_SERVICE_DRIVER)) != 0,
		}

		// Query startup type, binary path, account, svchost group, and PPL launch protection.
		if sc.OpenServiceW != nil {
			wname := win.utf8_to_wstring(name, context.temp_allocator)
			sh := sc.OpenServiceW(r.scm, wname, WIN_SERVICE_QUERY_CONFIG)
			if sh != nil {
				defer sc.CloseServiceHandle(sh)
				cneed: win.DWORD
				if sc.QueryServiceConfigW != nil && sc.QueryServiceConfigW(sh, raw_data(r.cfg_buf), win.DWORD(len(r.cfg_buf)), &cneed) {
					cfg: winapi.QUERY_SERVICE_CONFIGW64
					mem.copy(&cfg, raw_data(r.cfg_buf), size_of(cfg))
					delayed := false
					if cfg.dwStartType == 2 && sc.QueryServiceConfig2W != nil {
						dinfo: win.BOOL
						dneed: win.DWORD
						if sc.QueryServiceConfig2W(sh, SERVICE_CONFIG_DELAYED_AUTO_START_INFO, &dinfo, size_of(dinfo), &dneed) && dinfo != false {
							delayed = true
						}
					}
					u.startup_type = win_startup_type_of(cfg.dwStartType, delayed)
					u.binary_path = win_wstr_to_utf8(([^]u16)(uintptr(cfg.lpBinaryPathName)), 1024, a)
					u.account     = win_wstr_to_utf8(([^]u16)(uintptr(cfg.lpServiceStartName)), 256, a)
					if u.binary_path != "" && strings.contains(strings.to_lower(u.binary_path, context.temp_allocator), "svchost") {
						grp := winapi.parse_svchost_group(u.binary_path)
						if grp != "" { u.svchost_group = strings.clone(grp, a) }
					}
				}
				u.protection = win_service_protection(sh)
			}
		}
		if r.filter == .Shared && u.svchost_group == "" { return }
		append(r.out, u)
	})
	if e != 0 { return fmt.tprintf(i18n.tr("Cannot list Windows services (error %d)."), int(e)) }
	slice.sort_by(out[:], proc(x, y: Win_Service) -> bool { return strings.to_lower(x.name, context.temp_allocator) < strings.to_lower(y.name, context.temp_allocator) })
	return ""
}

// Queries active dependent services for Stop confirmation warnings (safe read-only call).
win_service_active_dependents :: proc(name: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	sc := win_scm()
	if sc.OpenSCManagerW == nil || sc.OpenServiceW == nil || sc.EnumDependentServicesW == nil { return out[:] }
	scm := sc.OpenSCManagerW(nil, nil, WIN_SC_MANAGER_CONNECT)
	if scm == nil { return out[:] }
	defer sc.CloseServiceHandle(scm)
	sh := sc.OpenServiceW(scm, win.utf8_to_wstring(name, context.temp_allocator), WIN_SERVICE_ENUMERATE_DEPENDENTS)
	if sh == nil { return out[:] }
	defer sc.CloseServiceHandle(sh)
	needed, count: win.DWORD
	buf := win_bytes(16 * 1024)
	if !sc.EnumDependentServicesW(sh, WIN_SERVICE_ACTIVE, raw_data(buf), win.DWORD(len(buf)), &needed, &count) {
		if win.GetLastError() == WIN_ERROR_MORE_DATA && needed > 0 {
			buf = win_bytes(int(needed) + 1024)
			if !sc.EnumDependentServicesW(sh, WIN_SERVICE_ACTIVE, raw_data(buf), win.DWORD(len(buf)), &needed, &count) { return out[:] }
		} else {
			return out[:]
		}
	}
	// ENUM_SERVICE_STATUSW: lpServiceName(8), lpDisplayName(8), SERVICE_STATUS(28), pad(4) = 48 bytes on 64-bit.
	Enum_Service_Status_W64 :: struct {
		lpServiceName: u64,
		lpDisplayName: u64,
		Status:        [7]u32,
		_pad:          u32,
	}
	n := min(int(count), len(buf) / size_of(Enum_Service_Status_W64))
	for i in 0 ..< n {
		e: Enum_Service_Status_W64
		mem.copy(&e, &buf[i * size_of(Enum_Service_Status_W64)], size_of(e))
		if dn := win_wstr_to_utf8(([^]u16)(uintptr(e.lpServiceName)), 256, context.temp_allocator); dn != "" {
			append(&out, dn)
		}
	}
	return out[:]
}

// How long an act waits for a service to be in the state it asked for (the SCM's own limit for a start or a stop).
@(private = "file") SERVICE_WAIT :: 30 * time.Second

// Waits (bounded) until the service is in the state `want`. "", or why it is not.
@(private = "file")
win_service_wait :: proc(sh: win.HANDLE, want: Win_Service_State) -> string {
	sc := win_scm()
	if sc.QueryServiceStatusEx == nil { return "" }
	since := time.tick_now()
	for {
		ssp: winapi.SERVICE_STATUS_PROCESS
		need: win.DWORD
		if !sc.QueryServiceStatusEx(sh, 0 /* SC_STATUS_PROCESS_INFO */, &ssp, size_of(ssp), &need) {
			return fmt.tprintf(i18n.tr("error %d"), int(win.GetLastError()))
		}
		state := win_service_state_of(ssp.dwCurrentState)
		if state == want { return "" }
		// (a service that was to run and stopped says why)
		if want == .Running && state == .Stopped { return fmt.tprintf(i18n.tr("it stopped again (error %d)"), int(ssp.dwWin32ExitCode)) }
		if time.tick_since(since) >= SERVICE_WAIT { return fmt.tprintf(i18n.tr("it is still in this state: %s"), i18n.tr(WIN_SERVICE_STATE_LABELS[state])) }
		time.sleep(100 * time.Millisecond)
	}
}

// Why a control was refused.
@(private = "file")
win_service_refused :: proc(name, what: string, e: win.DWORD) -> string {
	switch e {
	case win.ERROR_ACCESS_DENIED: return i18n.tr("administrator privileges required")
	case ERROR_DEPENDENT_SERVICES_RUNNING:
		if deps := win_service_active_dependents(name); len(deps) > 0 {
			return fmt.tprintf(i18n.tr("these services need it and run: %s"), strings.join(deps, ", ", context.temp_allocator))
		}
		return i18n.tr("dependent services are still running")
	}
	return fmt.tprintf(what, int(e))
}

// Performs an SCM action on one service. Returns "" on success or an explicit error message.
win_service_act :: proc(name: string, action: Win_Service_Action, startup: Win_Startup_Type) -> string {
	sc := win_scm()
	if sc.OpenSCManagerW == nil || sc.OpenServiceW == nil { return i18n.tr("Service Control Manager is unavailable") }
	scm := sc.OpenSCManagerW(nil, nil, WIN_SC_MANAGER_CONNECT)
	if scm == nil {
		if win.GetLastError() == win.ERROR_ACCESS_DENIED { return i18n.tr("administrator privileges required") }
		return fmt.tprintf(i18n.tr("error %d"), int(win.GetLastError()))
	}
	defer sc.CloseServiceHandle(scm)

	access: win.DWORD
	#partial switch action {
	case .Start:       access = WIN_SERVICE_START | WIN_SERVICE_QUERY_STATUS
	case .Stop:        access = WIN_SERVICE_STOP | WIN_SERVICE_QUERY_STATUS
	case .Restart:     access = WIN_SERVICE_STOP | WIN_SERVICE_START | WIN_SERVICE_QUERY_STATUS
	case .Pause:       access = WIN_SERVICE_PAUSE_CONTINUE | WIN_SERVICE_QUERY_STATUS
	case .Continue:    access = WIN_SERVICE_PAUSE_CONTINUE | WIN_SERVICE_QUERY_STATUS
	case .Set_Startup: access = WIN_SERVICE_CHANGE_CONFIG
	}

	// (the configuration too: its protection is read on this same handle)
	sh := sc.OpenServiceW(scm, win.utf8_to_wstring(name, context.temp_allocator), access | WIN_SERVICE_QUERY_CONFIG)
	if sh == nil {
		e := win.GetLastError()
		if e == win.ERROR_ACCESS_DENIED {
			return i18n.tr("access denied: run Inspecteur as an administrator (protected services remain blocked)")
		}
		return fmt.tprintf(i18n.tr("cannot open service (error %d)"), int(e))
	}
	defer sc.CloseServiceHandle(sh)

	if prot := win_service_protection(sh); prot != 0 {
		return fmt.tprintf(i18n.tr("protected service (%s) cannot be modified"), win_service_protection_label(prot))
	}

	status_buf: [7]u32   // SERVICE_STATUS
	#partial switch action {
	case .Start:
		if !sc.StartServiceW(sh, 0, nil) {
			e := win.GetLastError()
			if e != ERROR_SERVICE_ALREADY_RUNNING { return win_service_refused(name, i18n.tr("start failed (error %d)"), e) }
		}
		return win_service_wait(sh, .Running)
	case .Stop, .Restart:
		// (a service that others need and that run is not stopped: the SCM refuses, and they are named)
		if !sc.ControlService(sh, SERVICE_CONTROL_STOP, &status_buf[0]) {
			e := win.GetLastError()
			if e != ERROR_SERVICE_NOT_ACTIVE { return win_service_refused(name, i18n.tr("stop failed (error %d)"), e) }
		}
		if why := win_service_wait(sh, .Stopped); why != "" { return why }
		if action == .Stop { return "" }
		if !sc.StartServiceW(sh, 0, nil) {
			e := win.GetLastError()
			// (its trigger started it first)
			if e != ERROR_SERVICE_ALREADY_RUNNING { return win_service_refused(name, i18n.tr("start failed (error %d)"), e) }
		}
		return win_service_wait(sh, .Running)
	case .Pause:
		if !sc.ControlService(sh, SERVICE_CONTROL_PAUSE, &status_buf[0]) { return win_service_refused(name, i18n.tr("pause failed (error %d)"), win.GetLastError()) }
		return win_service_wait(sh, .Paused)
	case .Continue:
		if !sc.ControlService(sh, SERVICE_CONTROL_CONTINUE, &status_buf[0]) { return win_service_refused(name, i18n.tr("resume failed (error %d)"), win.GetLastError()) }
		return win_service_wait(sh, .Running)
	case .Set_Startup:
		st_code: win.DWORD
		delayed := false
		switch startup {
		case .Unknown, .Boot, .System: return fmt.tprintf(i18n.tr("cannot change startup type (error %d)"), int(win.ERROR_INVALID_PARAMETER))
		case .Automatic:         st_code = 2
		case .Automatic_Delayed: st_code = 2; delayed = true
		case .Manual:            st_code = 3
		case .Disabled:          st_code = 4
		}
		if sc.ChangeServiceConfigW == nil || !sc.ChangeServiceConfigW(sh, SERVICE_NO_CHANGE, st_code, SERVICE_NO_CHANGE, nil, nil, nil, nil, nil, nil, nil) {
			e := win.GetLastError()
			if e == win.ERROR_ACCESS_DENIED { return i18n.tr("administrator privileges required") }
			return fmt.tprintf(i18n.tr("cannot change startup type (error %d)"), int(e))
		}
		if st_code == 2 && sc.ChangeServiceConfig2W != nil {
			dflag: win.BOOL = delayed ? true : false
			if !sc.ChangeServiceConfig2W(sh, SERVICE_CONFIG_DELAYED_AUTO_START_INFO, &dflag) {
				return win_service_refused(name, i18n.tr("cannot change startup type (error %d)"), win.GetLastError())
			}
		}
	}
	return ""
}

// Reads detailed SCM configuration, dependencies, active dependents, and Windows Event Log entries for one service.
win_service_details_read :: proc(d: ^Win_Service_Details, a: mem.Allocator) {
	display := ""
	sc := win_scm()
	if sc.OpenSCManagerW != nil && sc.OpenServiceW != nil {
		scm := sc.OpenSCManagerW(nil, nil, WIN_SC_MANAGER_CONNECT)
		if scm != nil {
			defer sc.CloseServiceHandle(scm)
			sh := sc.OpenServiceW(scm, win.utf8_to_wstring(d.name, context.temp_allocator), WIN_SERVICE_QUERY_CONFIG | WIN_SERVICE_ENUMERATE_DEPENDENTS)
			if sh != nil {
				defer sc.CloseServiceHandle(sh)
				cfg_buf := win_bytes(8192)
				need: win.DWORD
				if sc.QueryServiceConfigW != nil && sc.QueryServiceConfigW(sh, raw_data(cfg_buf), win.DWORD(len(cfg_buf)), &need) {
					cfg: winapi.QUERY_SERVICE_CONFIGW64
					mem.copy(&cfg, raw_data(cfg_buf), size_of(cfg))
					d.binary_path = win_wstr_to_utf8(([^]u16)(uintptr(cfg.lpBinaryPathName)), 1024, a)
					d.account     = win_wstr_to_utf8(([^]u16)(uintptr(cfg.lpServiceStartName)), 256, a)
					display = win_wstr_to_utf8(([^]u16)(uintptr(cfg.lpDisplayName)), 256, context.temp_allocator)
					if grp := winapi.parse_svchost_group(d.binary_path); grp != "" {
						d.svchost_group = strings.clone(grp, a)
					}
					if cfg.lpDependencies != 0 {
						// Walk NUL-separated UTF-16LE multi-string directly.
						p := ([^]u16)(uintptr(cfg.lpDependencies))
						idx := 0
						for idx < 4096 && p[idx] != 0 {
							start := idx
							for idx < 4096 && p[idx] != 0 { idx += 1 }
							if dep := win_utf16_to_utf8(p[start:idx], a); dep != "" { append(&d.dependencies, dep) }
							idx += 1
						}
					}
				}
				if sc.QueryServiceConfig2W != nil {
					dbuf := win_bytes(8192)
					dneed: win.DWORD
					if sc.QueryServiceConfig2W(sh, SERVICE_CONFIG_DESCRIPTION, raw_data(dbuf), win.DWORD(len(dbuf)), &dneed) && dneed >= size_of(u64) {
						ptr: u64
						mem.copy(&ptr, raw_data(dbuf), 8)
						if ptr != 0 { d.description = win_wstr_to_utf8(([^]u16)(uintptr(ptr)), 1024, a) }
					}
					d.protection = strings.clone(win_service_protection_label(win_service_protection(sh)), a)
				}
			}
		}
	}
	for dep in win_service_active_dependents(d.name) {
		append(&d.dependents, strings.clone(dep, a))
	}
	win_eventlog_read(d.name, display, &d.events, &d.event_problem, a)
}

// Queries recent Windows System Event Log entries for `service_name` (provider match or Service Control Manager messages).
@(private = "file")
win_eventlog_read :: proc(service_name, display_name: string, out: ^[dynamic]Win_Event_Entry, problem: ^string, a: mem.Allocator) {
	ev := win_evt()
	if ev.EvtQuery == nil || ev.EvtNext == nil || ev.EvtRender == nil || ev.EvtClose == nil {
		problem^ = strings.clone(i18n.tr("Windows Event Log API (wevtapi.dll) is unavailable."), a)
		return
	}
	EvtQueryChannelPath      :: win.DWORD(0x1)
	EvtQueryReverseDirection :: win.DWORD(0x200)
	EvtRenderEventXml        :: win.DWORD(1)
	EvtFormatMessageEvent    :: win.DWORD(1)

	// Query the newest System channel events from Service Control Manager or the service's own provider.
	// (a name with a quote would end the query's text: the Service Control Manager's events alone then)
	xpath := "*[System[Provider[@Name='Service Control Manager']]]"
	if strings.index_any(service_name, "'\"<>&") < 0 { xpath = fmt.tprintf("*[System[Provider[@Name='%s'] or Provider[@Name='Service Control Manager']]]", service_name) }
	q := ev.EvtQuery(nil, win.L("System"), win.utf8_to_wstring(xpath, context.temp_allocator), EvtQueryChannelPath | EvtQueryReverseDirection)
	if q == nil {
		e := win.GetLastError()
		if e == win.ERROR_ACCESS_DENIED {
			problem^ = strings.clone(i18n.tr("Access denied reading the System Event Log."), a)
		} else {
			problem^ = strings.clone(i18n.tr("No entries in the System Event Log."), a)
		}
		return
	}
	defer ev.EvtClose(q)

	// (the Service Control Manager names a service by its display name, its name in some events; as a value alone: "Power"
	// is not in "PowerShell")
	lower_name := strings.to_lower(fmt.tprintf(">%s<", service_name), context.temp_allocator)
	lower_display := display_name != "" ? strings.to_lower(fmt.tprintf(">%s<", winapi.xml_escape(display_name)), context.temp_allocator) : lower_name
	// (a publisher's metadata takes milliseconds to open: once each)
	publishers := make(map[string]win.HANDLE, 8, context.temp_allocator)
	defer for _, pm in publishers { if pm != nil { ev.EvtClose(pm) } }
	xml_buf := win_bytes(16 * 1024)
	msg_buf := make([]u16, 4096, context.temp_allocator)
	handles: [32]win.HANDLE
	scanned := 0
	for len(out) < EVENTLOG_MAX_ENTRIES && scanned < EVENTLOG_MAX_SCANNED {
		returned: win.DWORD
		if !ev.EvtNext(q, len(handles), &handles[0], 1000, 0, &returned) || returned == 0 { break }
		for i in 0 ..< int(returned) {
			h := handles[i]
			defer ev.EvtClose(h)
			scanned += 1
			if len(out) >= EVENTLOG_MAX_ENTRIES { continue }
			used, props: win.DWORD
			if !ev.EvtRender(nil, h, EvtRenderEventXml, win.DWORD(len(xml_buf)), raw_data(xml_buf), &used, &props) {
				if win.GetLastError() == win.ERROR_INSUFFICIENT_BUFFER && used > 0 && used < 256 * 1024 {
					xml_buf = win_bytes(int(used) + 16)
					if !ev.EvtRender(nil, h, EvtRenderEventXml, win.DWORD(len(xml_buf)), raw_data(xml_buf), &used, &props) { continue }
				} else {
					continue
				}
			}
			xml := winapi.decode_utf16le(xml_buf[:min(int(used), len(xml_buf))], context.temp_allocator)
			prov := xml_attr(xml, "Provider", "Name")
			// Keep all events from the service's own provider; filter Service Control Manager events to those naming this service.
			if !strings.equal_fold(prov, service_name) {
				low := strings.to_lower(xml, context.temp_allocator)
				if !strings.contains(low, lower_name) && !strings.contains(low, lower_display) { continue }
			}

			msg := ""
			if prov != "" && ev.EvtOpenPublisherMetadata != nil && ev.EvtFormatMessage != nil {
				pm, opened := publishers[prov]
				if !opened {
					pm = ev.EvtOpenPublisherMetadata(nil, win.utf8_to_wstring(prov, context.temp_allocator), nil, 0, 0)
					publishers[prov] = pm
				}
				if pm != nil {
					mused: win.DWORD
					if ev.EvtFormatMessage(pm, h, 0, 0, nil, EvtFormatMessageEvent, win.DWORD(len(msg_buf)), raw_data(msg_buf), &mused) && mused > 0 {
						msg = win_utf16_to_utf8(msg_buf[:min(int(mused), len(msg_buf))], context.temp_allocator)
					}
				}
			}
			if msg == "" {
				msg = xml_event_data_summary(xml)
			}
			msg, _ = strings.replace_all(strings.trim_space(msg), "\r\n", " ", context.temp_allocator)
			msg, _ = strings.replace_all(msg, "\n", " ", context.temp_allocator)

			ts := xml_attr(xml, "TimeCreated", "SystemTime")
			ts = win_event_local_time(ts)
			lvl := u8(parse_u32_simple(xml_elem(xml, "Level")))
			eid := parse_u32_simple(xml_elem(xml, "EventID"))

			append(out, Win_Event_Entry{
				timestamp = strings.clone(ts, a),
				level     = lvl,
				event_id  = eid,
				provider  = strings.clone(prov, a),
				message   = strings.clone(msg, a),
			})
		}
	}
	if len(out) == 0 {
		problem^ = strings.clone(i18n.tr("No recent entries for this service in the System Event Log."), a)
	}
}

// An event's time (UTC: "2026-11-25T08:01:12.1234567Z") as the local time of that day.
@(private = "file")
win_event_local_time :: proc(utc: string) -> string {
	t, ok := winapi.parse_event_time(utc)
	if !ok { return utc }
	st := win.SYSTEMTIME{year = u16(t[0]), month = u16(t[1]), day = u16(t[2]), hour = u16(t[3]), minute = u16(t[4]), second = u16(t[5])}
	local: win.SYSTEMTIME
	if !win.SystemTimeToTzSpecificLocalTime(nil, &st, &local) { return utc }
	return fmt.tprintf("%04d-%02d-%02d %02d:%02d:%02d", local.year, local.month, local.day, local.hour, local.minute, local.second)
}

@(private = "file")
xml_attr :: proc(xml, tag, attr: string) -> string {
	needle := fmt.tprintf("<%s ", tag)
	start := strings.index(xml, needle)
	if start < 0 { return "" }
	rest := xml[start:]
	gt := strings.index_byte(rest, '>')
	if gt > 0 { rest = rest[:gt] }
	akey := fmt.tprintf("%s='", attr)
	quote := byte('\'')
	pos := strings.index(rest, akey)
	if pos < 0 {
		akey = fmt.tprintf("%s=\"", attr)
		quote = '"'
		pos = strings.index(rest, akey)
	}
	if pos < 0 { return "" }
	val := rest[pos + len(akey):]
	end := strings.index_byte(val, quote)
	return end >= 0 ? val[:end] : val
}

@(private = "file")
xml_elem :: proc(xml, tag: string) -> string {
	open := fmt.tprintf("<%s", tag)
	start := strings.index(xml, open)
	if start < 0 { return "" }
	rest := xml[start + len(open):]
	gt := strings.index_byte(rest, '>')
	if gt < 0 { return "" }
	rest = rest[gt + 1:]
	close := fmt.tprintf("</%s>", tag)
	end := strings.index(rest, close)
	return end >= 0 ? strings.trim_space(rest[:end]) : ""
}

@(private = "file")
xml_event_data_summary :: proc(xml: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	rest := xml
	for {
		i := strings.index(rest, "<Data")
		if i < 0 { break }
		rest = rest[i + 5:]
		gt := strings.index_byte(rest, '>')
		if gt < 0 { break }
		rest = rest[gt + 1:]
		end := strings.index(rest, "</Data>")
		if end < 0 { break }
		piece := strings.trim_space(rest[:end])
		if piece != "" {
			if strings.builder_len(b) > 0 { strings.write_string(&b, " · ") }
			strings.write_string(&b, piece)
		}
		rest = rest[end + 7:]
	}
	return strings.to_string(b)
}

@(private = "file")
parse_u32_simple :: proc(s: string) -> u32 {
	v: u32
	for c in s {
		if c < '0' || c > '9' { break }
		v = v * 10 + u32(c - '0')
	}
	return v
}
