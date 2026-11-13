package inspecteur

// The Services section's model: the services of the system's service manager or of the user's, their state, whether
// they start by themselves, their main process and memory. The system's side is services_linux.odin (systemd over
// D-Bus): services_read lists, service_act starts, stops, restarts, enables or disables. Both run in a tasks.Job on the
// toolkit's chores, whose reading comes back to the window by ui.post: a call to the manager can wait for an
// authorization for seconds. The list is read while the section is shown, every services.refresh_ms, and at once after
// an action.

import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:time"
import lucide "gt:lucide"
import tasks "gt:tasks"
import i18n "gt:i18n"
import "gt:ui"

Manager :: enum u8 { System, User }

MANAGER_LABELS := [Manager]string{.System = i18n.later("System"), .User = i18n.later("User")}
MANAGER_KEYS := [Manager]string{.System = "system", .User = "user"}

Service_Action :: enum u8 { None, Start, Stop, Restart, Enable, Disable }

// (whole sentences, the unit's name their %s: a language puts it where it goes)
SERVICE_ACTION_DOING := [Service_Action]string{.None = "", .Start = i18n.later("Starting %s…"), .Stop = i18n.later("Stopping %s…"), .Restart = i18n.later("Restarting %s…"), .Enable = i18n.later("Enabling %s…"), .Disable = i18n.later("Disabling %s…")}
SERVICE_ACTION_DONE := [Service_Action]string{.None = "", .Start = i18n.later("Started %s"), .Stop = i18n.later("Stopped %s"), .Restart = i18n.later("Restarted %s"), .Enable = i18n.later("Enabled %s"), .Disable = i18n.later("Disabled %s")}

// No memory figure (the manager does not count it for this service).
MEMORY_UNKNOWN :: max(u64)
// After an action, the next reading comes this soon.
SERVICE_AFTER_ACTION :: 500 * time.Millisecond
// The longest service name an action carries.
SERVICE_NAME_MAX :: 256

Service :: struct {
	name, description: string,
	load:   string,   // loaded, not-found, masked; "not loaded": a unit file nothing has loaded
	active: string,   // active, inactive, failed, activating, deactivating
	sub:    string,   // running, exited, dead...
	file:   string,   // enabled, disabled, static, masked, transient... ("" when it has no file)
	pid:    i32,      // the main process, 0: none
	memory: u64,      // bytes, MEMORY_UNKNOWN: not counted
}

// A reading: all of its texts in its arena.
Service_List :: struct {
	arena:   virtual.Arena,
	manager: Manager,
	units:   [dynamic]Service,
	problem: string,   // the manager cannot be reached: why
	// the action this reading follows, and what came of it
	action:  Service_Action,
	unit:    string,
	failure: string,   // "" when it was done
	running, failed: int,   // the units that run, those that failed (counted when the window takes it)
}

// What the window asks the job (under the services' mutex).
@(private = "file")
Service_Ask :: struct {
	manager: Manager,
	action:  Service_Action,
	unit:    [SERVICE_NAME_MAX]u8,
	unit_len: int,
}

// The details of one service (the Services section's pane, Ctrl+I): its unit file, since when it is in its state, its
// tasks, its CPU time, its restarts, and its journal's last lines. All of its texts in its arena.
Unit_Details :: struct {
	arena:    virtual.Arena,
	manager:  Manager,
	name:     string,
	file:     string,     // its unit file ("" none)
	since:    i64,        // unix seconds: when it entered its state (0: unknown)
	tasks:    u64,        // its processes and threads now (DETAIL_UNKNOWN: not counted)
	cpu_ns:   u64,        // its CPU time (DETAIL_UNKNOWN: not counted)
	restarts: u32,        // the manager restarted it this many times
	journal:  [dynamic]Journal_Entry,   // its journal's last entries, the oldest first
	journal_problem: string,     // why there are none ("" when they were read)
	boot:     bool,       // the entries are of this boot alone (services.journal_boot)
}

// An entry of a service's journal: when, how grave (syslog's levels: 0 emergency .. 7 debug), from which process and
// program, and what it says (the texts in the details' arena).
Journal_Entry :: struct {
	usec:     i64,      // unix microseconds
	priority: u8,
	pid:      i32,      // 0: not said
	ident:    string,   // the program that wrote it (SYSLOG_IDENTIFIER, else _COMM)
	message:  string,
}

// The journal's levels a filter keeps: every entry, warnings and worse (4 and under), errors and worse (3 and under).
Journal_Level :: enum u8 { All, Warnings, Errors }
JOURNAL_LEVEL_KEYS := [Journal_Level]string{.All = "all", .Warnings = "warnings", .Errors = "errors"}
JOURNAL_LEVEL_LABELS := [Journal_Level]string{.All = i18n.later("All"), .Warnings = i18n.later("Warnings"), .Errors = i18n.later("Errors")}

// Whether an entry of priority `p` passes the filter `l`.
journal_level_keeps :: proc(l: Journal_Level, p: u8) -> bool {
	switch l {
	case .All:      return true
	case .Warnings: return p <= 4
	case .Errors:   return p <= 3
	}
	return true
}

// A number of the details the manager does not count.
DETAIL_UNKNOWN :: max(u64)
// The journal's entries the pane reads, at most (the newest).
JOURNAL_LINES :: 1000
// While the pane follows the journal (services.journal_follow), it is read again this often.
JOURNAL_FOLLOW_MS :: 2000

Services :: struct {
	pane:         Journal_View,      // the details' pane: the selected service's details and journal (journal.odin)
	select_name:  string,            // owned: a service to select once a reading lists it (Go to service)
	details_for:  u64,               // the service the pane was asked for (its name's id)
	job:     tasks.Job,
	bus:     Service_Bus,      // the job's own (services_linux.odin)
	demo:    ^Demo,            // not nil: the services are the demo's
	state:   ^ui.State,        // the window a reading is posted to
	mutex:   sync.Mutex,
	ask:     Service_Ask,      // under the mutex
	list:    ^Service_List,    // the window's
	rows:    Section_Table,
	manager: Manager,          // the one shown
	next:    time.Tick,        // the next reading while the section is shown
	pending: Service_Action,   // an action asked and not answered yet
}

SERVICE_COLUMNS := [?]ui.Table_Column{
	{title = i18n.later("Name"), width = 0},
	{title = i18n.later("Description"), width = 22, weak = true},
	{title = i18n.later("State"), width = 11},
	{title = i18n.later("Startup"), width = 7.5},
	{title = i18n.later("Load"), width = 7, weak = true},
	{title = i18n.later("PID"), width = 5.5, number = true, weak = true},
	{title = i18n.later("Memory"), width = 7, number = true},
}

services_init :: proc(s: ^Services, app: ^App) {
	section_table_init(&s.rows, app, SERVICE_COLUMNS[:])
	section_layout_load(&s.rows, &app.prefs, "services")
	s.manager = app.settings.manager
	s.demo = app.demo
	s.state = &app.main.state
	s.job = {work = services_work, data = s}
	journal_view_init(&s.pane, app.demo, &app.main.state)
}

// After the chores stopped (no reading runs).
services_destroy :: proc(s: ^Services) {
	service_bus_close(&s.bus)
	journal_view_destroy(&s.pane)
	delete(s.select_name)
	service_list_free(s.list)
	section_table_destroy(&s.rows)
}

@(private = "file")
service_list_free :: proc(l: ^Service_List) {
	if l == nil { return }
	virtual.arena_destroy(&l.arena)
	free(l)
}

// Asks for a reading of the manager shown, after `action` on `unit` when there is one.
services_ask :: proc(app: ^App, action := Service_Action.None, unit := "") {
	s := &app.services
	sync.lock(&s.mutex)
	s.ask.manager = s.manager
	if action != .None {
		s.ask.action = action
		s.ask.unit_len = copy(s.ask.unit[:], unit)
	}
	sync.unlock(&s.mutex)
	tasks.job_ask(ui.chores(), &s.job)
	s.next = time.tick_add(time.tick_now(), time.Duration(app.settings.services_ms) * time.Millisecond)
}

// Whether a reading is asked or under way.
services_busy :: proc(app: ^App) -> bool { return tasks.job_busy(ui.chores(), &app.services.job) }

@(private = "file")
services_work :: proc(data: rawptr) {
	s := (^Services)(data)
	sync.lock(&s.mutex)
	ask := s.ask
	s.ask.action = .None
	sync.unlock(&s.mutex)
	l := new(Service_List)
	// (the reading's texts in its arena; the bus's connections keep the heap: they outlive the reading)
	a := virtual.arena_allocator(&l.arena)
	l.units = make([dynamic]Service, a)
	l.manager = ask.manager
	if ask.action != .None {
		l.action = ask.action
		l.unit = strings.clone(string(ask.unit[:ask.unit_len]), a)
		l.failure = strings.clone(s.demo != nil ? DEMO_REFUSED : service_act(&s.bus, ask.manager, ask.action, l.unit), a)
	}
	l.problem = strings.clone(s.demo != nil ? demo_services_read(s.demo, ask.manager, &l.units, a) : services_read(&s.bus, ask.manager, &l.units, a), a)
	if !ui.post(s.state, services_posted, l) { service_list_free(l) }
}

@(private = "file")
services_posted :: proc(data: rawptr, _: u64) {
	l := (^Service_List)(data)
	if the_app == nil { service_list_free(l); return }
	services_take(the_app, l)
}

// Asks for the details of the service `name` of the manager shown (its unit, its journal), for the pane.
details_ask :: proc(app: ^App, name: string) {
	journal_view_ask(&app.services.pane, app.services.manager, name, app.settings.journal_boot)
}

// A new reading becomes the rows; what an action came to is said.
@(private = "file")
services_take :: proc(app: ^App, l: ^Service_List) {
	s := &app.services
	service_list_free(s.list)
	s.list = l
	for u in l.units {
		if u.active == "active" && u.sub == "running" { l.running += 1 }
		if u.active == "failed" { l.failed += 1 }
	}
	if l.action != .None {
		s.pending = .None
		// (the manager queued a job, which takes some time: its outcome shows at a reading soon after)
		s.next = time.tick_add(time.tick_now(), SERVICE_AFTER_ACTION)
		if l.failure == "" {
			say(app, i18n.tr(SERVICE_ACTION_DONE[l.action]), l.unit)
		} else {
			say(app, "%s: %s", l.unit, l.failure)
		}
	}
	services_rows(app)
}

// The rows again from the reading (of the manager shown only: a reading of the other one, asked before a switch, is not
// shown).
services_rows :: proc(app: ^App) {
	s := &app.services
	st := &s.rows
	section_rows_reset(st, len(SERVICE_COLUMNS))
	if s.list != nil && s.list.manager == s.manager {
		for u in s.list.units {
			state := u.sub != "" && u.sub != u.active ? strings.concatenate({u.active, " (", u.sub, ")"}, context.temp_allocator) : u.active
			tone := ui.Table_Tone.Normal
			if u.active == "failed" { tone = .Bad } else if u.active != "active" && u.active != "activating" && u.active != "reloading" { tone = .Dim }
			pid := u.pid > 0 ? uint_text(u64(u.pid)) : ""
			memory := u.memory != MEMORY_UNKNOWN && u.memory > 0 ? size_text(u.memory) : ""
			section_row(st, name_id(u.name), strings.join({u.name, u.description, state, u.file, pid}, " ", context.temp_allocator), service_icon(app, u), tone)
			ui.table_data_cell(&st.data, u.name)
			ui.table_data_cell(&st.data, u.description)
			ui.table_data_cell(&st.data, state)
			ui.table_data_cell(&st.data, u.file)
			ui.table_data_cell(&st.data, u.load)
			ui.table_data_cell(&st.data, pid, f64(u.pid))
			ui.table_data_cell(&st.data, memory, u.memory == MEMORY_UNKNOWN ? -1 : f64(u.memory))
		}
	}
	ui.table_apply(&st.table, &st.data, app.query)
	if s.select_name != "" && s.list != nil && s.list.manager == s.manager {
		if !ui.table_select_id(&st.table, name_id(s.select_name)) { say(app, s.manager == .System ? i18n.tr("%s is not among the system services") : i18n.tr("%s is not among the user services"), s.select_name) }
		delete(s.select_name)
		s.select_name = ""
	}
	// (the pane follows the selection, and each reading: the journal moves)
	if app.settings.details { if u, ok := selected_service(app); ok { details_ask(app, u.name) } }
}

// Selects the service `name` once a reading of the manager shown lists it.
service_select :: proc(app: ^App, name: string) {
	s := &app.services
	delete(s.select_name)
	s.select_name = strings.clone(name)
	services_rows(app)
}

// The selected service, when there is one.
selected_service :: proc(app: ^App) -> (u: Service, ok: bool) {
	s := &app.services
	i := ui.table_selected(&s.rows.table)
	if s.list == nil || s.list.manager != s.manager || i < 0 || i >= len(s.list.units) { return }
	return s.list.units[i], true
}

// A name's identity (FNV-1a): a row stays selected across readings.
name_id :: proc(name: string) -> u64 {
	h: u64 = 14695981039346656037
	for i in 0 ..< len(name) { h = (h ~ u64(name[i])) * 1099511628211 }
	return h
}

////////////////////////////////
// A service's icon

// A family of services, known by words of their names: an icon of the person's theme that stands for it (a freedesktop
// name), and Lucide's glyph when the theme has none.
Service_Family :: struct {
	words: []string,
	theme: string,
	glyph: string,
}

// The families, the first whose word is in the name wins (the more particular first); the last is any service's.
@(rodata)
SERVICE_FAMILIES := [?]Service_Family{
	{words = []string{"bluetooth"}, theme = "bluetooth", glyph = lucide.NETWORK},
	{words = []string{"pipewire", "pulseaudio", "wireplumber", "alsa", "sound", "audio", "mpd"}, theme = "audio-card", glyph = lucide.VOLUME_2},
	{words = []string{"cups", "print", "ipp"}, theme = "printer", glyph = lucide.FILE_TEXT},
	{words = []string{"docker", "podman", "containerd", "libvirt", "lxd", "incus", "qemu", "virt"}, theme = "application-x-executable", glyph = lucide.PACKAGE},
	{words = []string{"postgres", "mysql", "mariadb", "redis", "mongo", "sqlite", "elasticsearch"}, theme = "", glyph = lucide.DATABASE},
	{words = []string{"nginx", "apache", "httpd", "caddy", "traefik", "nix-serve", "server"}, theme = "network-server", glyph = lucide.SERVER},
	{words = []string{"ssh", "telnet", "mosh"}, theme = "utilities-terminal", glyph = lucide.TERMINAL},
	{words = []string{"network", "wpa_supplicant", "iwd", "dhcp", "resolved", "avahi", "modem", "tailscale", "wireguard", "openvpn", "nscd"}, theme = "network-wired", glyph = lucide.NETWORK},
	{words = []string{"udisks", "smartd", "fstrim", "zfs", "btrfs", "lvm", "mdmonitor", "mount", "swap", "nfs", "samba", "smb", "disk"}, theme = "drive-harddisk", glyph = lucide.HARD_DRIVE},
	{words = []string{"timesync", "chrony", "ntp", "time"}, theme = "preferences-system-time", glyph = lucide.CALENDAR_CLOCK},
	{words = []string{"cron", "atd", "timer"}, theme = "", glyph = lucide.CALENDAR_CLOCK},
	{words = []string{"polkit", "firewall", "apparmor", "audit", "fail2ban", "keyring", "gpg", "pcscd", "fprint", "security"}, theme = "security-high", glyph = lucide.SHIELD},
	{words = []string{"user@", "logind", "accounts", "session", "getty", "autovt", "greetd", "gdm", "sddm", "lightdm", "login", "display-manager"}, theme = "system-users", glyph = lucide.USER},
	{words = []string{"nvidia", "display", "xorg", "wayland", "colord"}, theme = "video-display", glyph = lucide.MONITOR},
	{words = []string{"thermal", "fan", "sensor"}, theme = "", glyph = lucide.THERMOMETER},
	{words = []string{"upower", "power", "tlp", "acpid", "battery"}, theme = "battery", glyph = lucide.ZAP},
	{words = []string{"journal", "syslog", "logrotate", "log"}, theme = "", glyph = lucide.SCROLL_TEXT},
	{words = []string{"nix", "flatpak", "packagekit", "fwupd", "update"}, theme = "system-software-update", glyph = lucide.PACKAGE},
	{words = []string{"udev", "usb"}, theme = "", glyph = lucide.USB},
	{words = []string{"input", "keyboard", "keyd", "kmonad"}, theme = "input-keyboard", glyph = lucide.KEYBOARD},
	{words = []string{"notif", "dunst", "mako"}, theme = "", glyph = lucide.BELL},
	{words = []string{"dbus", "bus"}, theme = "", glyph = lucide.MESSAGE_SQUARE},
	{words = []string{}, theme = "", glyph = lucide.SETTINGS},
}

// "getty@tty1.service": "getty"; "NetworkManager.service": "NetworkManager" (an icon of the theme by its own name).
service_stem :: proc(unit: string) -> string {
	name := unit
	if i := strings.last_index_byte(name, '.'); i > 0 { name = name[:i] }
	if i := strings.index_byte(name, '@'); i > 0 { name = name[:i] }
	return name
}

// The family of a service's unit, by the words of its name (in lower case).
service_family :: proc(unit: string) -> Service_Family {
	low := strings.to_lower(unit, context.temp_allocator)
	for f in SERVICE_FAMILIES {
		for w in f.words { if strings.contains(low, w) { return f } }
	}
	return SERVICE_FAMILIES[len(SERVICE_FAMILIES) - 1]
}

// A service's icon: its main process's app (as in Processes), else the person's theme's icon of the service's own name
// ("bluetooth", "cups"), else of its family's, else its family's glyph (the row tries them when it is drawn).
service_icon :: proc(app: ^App, u: Service) -> Row_Icon {
	f := service_family(u.name)
	entry := ""
	if u.pid > 0 {
		if p := find_pid(&app.sampler, u.pid); p != nil && p.entry >= 0 { entry = app.catalog.entries[p.entry].icon }
	}
	return {app = entry, alts = {service_stem(u.name), f.theme}, glyph = f.glyph}
}
