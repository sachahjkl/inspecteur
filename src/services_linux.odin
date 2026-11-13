package inspecteur

// The services on Linux: systemd's managers over D-Bus (org.freedesktop.systemd1), the system's on the system bus and
// the user's on the session bus, through the toolkit's dbus client (no systemctl is started). They run on the Services
// thread, which keeps its own connections (a connection is driven by one thread).
//
//   ListUnits             the units loaded: name, description, load, active and sub states, object path
//   ListUnitFiles         every unit file and whether it is enabled; a service's file that nothing loaded is listed too
//   Properties.Get        MainPID and MemoryCurrent of each running service, asked all at once (pipelined)
//   StartUnit, StopUnit, RestartUnit (mode "replace"); EnableUnitFiles, DisableUnitFiles, then Reload
//
// A system service's change is the manager's to allow: it asks polkit. The calls allow interactive authorization, so
// polkit can ask the user for a password; its answer, when it refuses, is shown as it is.

import "base:runtime"
import "core:fmt"
import "core:encoding/json"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:time"
import dbus "gt:dbus"
import i18n "gt:i18n"

SYSTEMD_DEST  :: "org.freedesktop.systemd1"
SYSTEMD_PATH  :: "/org/freedesktop/systemd1"
SYSTEMD_IFACE :: "org.freedesktop.systemd1.Manager"
// How long the properties of all the services may take to come.
PROPERTIES_WAIT :: 3 * time.Second
// How long an action may take: a start waits for its job to be queued, an authorization for the person to answer
// polkit's password dialog.
ACTION_TIMEOUT_MS :: 120_000

Service_Bus :: struct {
	conns:        [Manager]^dbus.Conn,
	descriptions: map[string]string,   // a unit file's Description=, by path (owned): read once
}

service_bus_close :: proc(b: ^Service_Bus) {
	for &c in b.conns {
		if c != nil { dbus.conn_close(c) }
		c = nil
	}
	for k, v in b.descriptions { delete(k, runtime.heap_allocator()); delete(v, runtime.heap_allocator()) }
	delete(b.descriptions)
}

// The manager's connection, made again when it was lost. nil: the bus cannot be reached.
@(private = "file")
service_conn :: proc(b: ^Service_Bus, m: Manager) -> ^dbus.Conn {
	c := b.conns[m]
	if c != nil && !dbus.conn_alive(c) {
		dbus.conn_close(c)
		c = nil
	}
	if c == nil {
		c = dbus.connect_bus(m == .System ? .System : .Session, runtime.heap_allocator())
		b.conns[m] = c
	}
	return c
}

// The services of manager `m` into `out`, their texts in `a`. Returns why they cannot be read (temporary).
services_read :: proc(b: ^Service_Bus, m: Manager, out: ^[dynamic]Service, a: runtime.Allocator) -> (problem: string) {
	c := service_conn(b, m)
	if c == nil { return m == .System ? i18n.tr("The system's service manager cannot be reached.") : i18n.tr("The user's service manager cannot be reached (no session bus).") }
	msg, ok := dbus.call(c, SYSTEMD_DEST, SYSTEMD_PATH, SYSTEMD_IFACE, "ListUnits", "", nil)
	if !ok { return call_failure(&msg, i18n.tr("systemd does not list its units")) }
	paths := make([dynamic]string, context.temp_allocator)   // each service's object path
	listed := make(map[string]bool, 256, context.temp_allocator)
	r := dbus.msg_reader(&msg)
	end := dbus.r_array_begin(&r, "(ssssssouso)")
	for r.pos < end && !r.err {
		dbus.r_align_entry(&r)
		name, description, load, active, sub := dbus.r_string(&r), dbus.r_string(&r), dbus.r_string(&r), dbus.r_string(&r), dbus.r_string(&r)
		_ = dbus.r_string(&r)   // following
		path := dbus.r_string(&r)
		_ = dbus.r_u32(&r)      // job id
		_ = dbus.r_string(&r)   // job type
		_ = dbus.r_string(&r)   // job path
		if !strings.has_suffix(name, ".service") { continue }
		append(out, Service{
			name = strings.clone(name, a), description = strings.clone(description, a), load = strings.clone(load, a),
			active = strings.clone(active, a), sub = strings.clone(sub, a), memory = MEMORY_UNKNOWN,
		})
		append(&paths, strings.clone(path, context.temp_allocator))
		listed[strings.clone(name, context.temp_allocator)] = true
	}
	// the unit files: whether each service starts by itself; a service's file that is not loaded is a row of its own
	files := make(map[string]string, 512, context.temp_allocator)   // name -> state
	file_paths := make(map[string]string, 512, context.temp_allocator)
	if fmsg, fok := dbus.call(c, SYSTEMD_DEST, SYSTEMD_PATH, SYSTEMD_IFACE, "ListUnitFiles", "", nil); fok {
		fr := dbus.msg_reader(&fmsg)
		fend := dbus.r_array_begin(&fr, "(ss)")
		for fr.pos < fend && !fr.err {
			dbus.r_align_entry(&fr)
			path, state := dbus.r_string(&fr), dbus.r_string(&fr)
			name := path[strings.last_index_byte(path, '/') + 1:]
			if !strings.has_suffix(name, ".service") { continue }
			key := strings.clone(name, context.temp_allocator)
			files[key] = strings.clone(state, context.temp_allocator)
			file_paths[key] = strings.clone(path, context.temp_allocator)
		}
	}
	for &u in out { if st, has := files[u.name]; has { u.file = strings.clone(st, a) } }
	for name, state in files {
		// (a template, foo@.service, is not a service until an instance of it is named; an alias is another name of a
		// service listed under its own)
		if name in listed || strings.has_suffix(name, "@.service") || state == "alias" { continue }
		append(out, Service{
			name = strings.clone(name, a), description = strings.clone(unit_description(b, file_paths[name]), a),
			load = "not loaded", active = "inactive", sub = "dead", file = strings.clone(state, a), memory = MEMORY_UNKNOWN,
		})
	}
	service_properties(c, out[:len(paths)], paths[:])
	return ""
}

// The main process and the memory of each running service: two Properties.Get each, all sent before any answer is read.
@(private = "file")
service_properties :: proc(c: ^dbus.Conn, units: []Service, paths: []string) {
	Slot :: struct { unit: ^Service, memory: bool, done: ^int }
	done := 0
	sent := 0
	slots := make([dynamic]Slot, 0, 2 * len(units), context.temp_allocator)
	on_reply :: proc(user: rawptr, status: dbus.Call_Status, msg: ^dbus.Message) {
		s := (^Slot)(user)
		s.done^ += 1
		if status != .Ok || msg == nil { return }
		r := dbus.msg_reader(msg)
		sig := dbus.r_variant_sig(&r)
		switch {
		case s.memory && sig == "t": s.unit.memory = dbus.r_u64(&r)
		case !s.memory && sig == "u": s.unit.pid = i32(dbus.r_u32(&r))
		}
	}
	for &u, i in units {
		if u.active != "active" && u.active != "reloading" && u.active != "deactivating" { continue }
		for memory in ([]bool{false, true}) {
			append(&slots, Slot{&u, memory, &done})
			w := dbus.body_writer()
			dbus.w_string(&w, "org.freedesktop.systemd1.Service")
			dbus.w_string(&w, memory ? "MemoryCurrent" : "MainPID")
			if dbus.call_async(c, SYSTEMD_DEST, paths[i], "org.freedesktop.DBus.Properties", "Get", "ss", w.buf[:], on_reply, &slots[len(slots) - 1], int(PROPERTIES_WAIT / time.Millisecond)) { sent += 1 }
		}
	}
	// Every handler runs before the slots go: with its reply, at its deadline (PROPERTIES_WAIT, fired by dispatch), or
	// when the bus is lost (dispatch runs them all).
	for done < sent {
		if !dbus.conn_alive(c) { dbus.dispatch(c); break }
		fds := [1]linux.Poll_Fd{{fd = linux.Fd(dbus.conn_fd(c)), events = {.IN}}}
		_, _ = linux.poll(fds[:], 100)
		dbus.dispatch(c)
	}
}

// A unit file's Description= (read once per file).
@(private = "file")
unit_description :: proc(b: ^Service_Bus, path: string) -> string {
	if path == "" { return "" }
	if d, ok := b.descriptions[path]; ok { return d }
	text := ""
	if data, err := os.read_entire_file(path, context.temp_allocator); err == nil {
		text = unit_file_value(string(data), "Unit", "Description")
	}
	// (kept across readings: the heap's, not the reading's arena)
	heap := runtime.heap_allocator()
	if b.descriptions == nil { b.descriptions = make(map[string]string, 256, heap) }
	b.descriptions[strings.clone(path, heap)] = strings.clone(text, heap)
	return text
}

// The value of `key` in the group `[group]` of a unit file or a desktop entry ("" when it has none); the last one wins,
// as systemd reads them.
unit_file_value :: proc(text, group, key: string) -> string {
	value := ""
	in_group := false
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if len(l) == 0 || l[0] == '#' || l[0] == ';' { continue }
		if l[0] == '[' {
			in_group = l == strings.concatenate({"[", group, "]"}, context.temp_allocator)
			continue
		}
		if !in_group { continue }
		eq := strings.index_byte(l, '=')
		if eq < 0 { continue }
		if strings.trim_space(l[:eq]) == key { value = strings.trim_space(l[eq + 1:]) }
	}
	return value
}

// Starts, stops, restarts, enables or disables a service. Returns "" when it is done, else what the manager said
// (temporary).
service_act :: proc(b: ^Service_Bus, m: Manager, action: Service_Action, name: string) -> (failure: string) {
	c := service_conn(b, m)
	if c == nil { return i18n.tr("the service manager cannot be reached") }
	return unit_act(c, action, name)
}

// The action, asked of the manager on the connection `c`.
unit_act :: proc(c: ^dbus.Conn, action: Service_Action, name: string) -> (failure: string) {
	w := dbus.body_writer()
	member, sig: string
	switch action {
	case .None: return ""
	case .Start, .Stop, .Restart:
		member = action == .Start ? "StartUnit" : action == .Stop ? "StopUnit" : "RestartUnit"
		sig = "ss"
		dbus.w_string(&w, name)
		dbus.w_string(&w, "replace")
	case .Enable, .Disable:
		member = action == .Enable ? "EnableUnitFiles" : "DisableUnitFiles"
		sig = action == .Enable ? "asbb" : "asb"
		len_at, content_at := dbus.w_array_begin(&w, 4)
		dbus.w_string(&w, name)
		dbus.w_array_end(&w, len_at, content_at)
		dbus.w_bool(&w, false)   // runtime: no, for good
		if action == .Enable { dbus.w_bool(&w, false) }   // force: no
	}
	// (interactive: polkit may ask the user for a password before the system's manager acts)
	msg, ok := dbus.call(c, SYSTEMD_DEST, SYSTEMD_PATH, SYSTEMD_IFACE, member, sig, w.buf[:], ACTION_TIMEOUT_MS, interactive = true)
	if !ok { return call_failure(&msg, i18n.tr("the service manager did not answer")) }
	if action == .Enable || action == .Disable {
		// (systemctl does the same: the manager reads the links it was given)
		rmsg, rok := dbus.call(c, SYSTEMD_DEST, SYSTEMD_PATH, SYSTEMD_IFACE, "Reload", "", nil, ACTION_TIMEOUT_MS, interactive = true)
		if !rok { return call_failure(&rmsg, i18n.tr("the service manager did not reload")) }
	}
	return ""
}

// What a call that failed came to, in words: the manager's own message, and what an authorization refused means.
@(private = "file")
call_failure :: proc(msg: ^dbus.Message, silent: string) -> string {
	if msg.type != .Error { return silent }
	r := dbus.msg_reader(msg)
	// (the message lives until the next call: its text is copied)
	text := strings.has_prefix(msg.signature, "s") ? strings.clone(dbus.r_string(&r), context.temp_allocator) : ""
	switch msg.error_name {
	case "org.freedesktop.DBus.Error.InteractiveAuthorizationRequired", "org.freedesktop.DBus.Error.AccessDenied":
		return fmt.tprintf(i18n.tr("not allowed: %s (a system service needs an administrator's permission)"), text != "" ? text : i18n.tr("access denied"))
	}
	if text != "" { return text }
	return strings.clone(msg.error_name, context.temp_allocator)
}

// The details of the service `d.name` of manager `d.manager`: its unit's properties over D-Bus (LoadUnit, then
// FragmentPath, StateChangeTimestamp, TasksCurrent, CPUUsageNSec, NRestarts) and its journal's last entries from
// journalctl -o json (of this boot alone when `d.boot`) (the journal's own program: its files' format is journald's to read). Runs on the details' thread.
unit_details_read :: proc(b: ^Service_Bus, d: ^Unit_Details, a: runtime.Allocator) {
	if c := service_conn(b, d.manager); c != nil {
		w := dbus.body_writer()
		dbus.w_string(&w, d.name)
		if msg, ok := dbus.call(c, SYSTEMD_DEST, SYSTEMD_PATH, SYSTEMD_IFACE, "LoadUnit", "s", w.buf[:]); ok {
			r := dbus.msg_reader(&msg)
			path := strings.clone(dbus.r_string(&r), context.temp_allocator)
			UNIT :: "org.freedesktop.systemd1.Unit"
			SERVICE :: "org.freedesktop.systemd1.Service"
			if v, has := unit_property(c, path, UNIT, "FragmentPath"); has { d.file = strings.clone(v.text, a) }
			if v, has := unit_property(c, path, UNIT, "StateChangeTimestamp"); has && v.number > 0 { d.since = i64(v.number / 1_000_000) }
			if v, has := unit_property(c, path, SERVICE, "TasksCurrent"); has { d.tasks = v.number }
			if v, has := unit_property(c, path, SERVICE, "CPUUsageNSec"); has { d.cpu_ns = v.number }
			if v, has := unit_property(c, path, SERVICE, "NRestarts"); has { d.restarts = u32(v.number) }
		}
	}
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "journalctl")
	if d.manager == .User { append(&args, "--user") }
	append(&args, "-u", d.name, "-n", fmt.tprintf("%d", JOURNAL_LINES), "--no-pager", "-q", "-o", "json",
		"--output-fields=PRIORITY,MESSAGE,_PID,SYSLOG_IDENTIFIER,_COMM")
	if d.boot { append(&args, "-b") }
	state, stdout, stderr, err := os.process_exec({command = args[:]}, context.temp_allocator)
	switch {
	case err != nil:
		d.journal_problem = i18n.tr("journalctl cannot be run: the journal is not read")
	case !state.exited || state.exit_code != 0:
		text := strings.trim_space(string(stderr))
		d.journal_problem = strings.clone(text != "" ? text : i18n.tr("journalctl failed"), a)
	case:
		rest := string(stdout)
		for line in strings.split_lines_iterator(&rest) {
			if e, ok := journal_entry_parse(line, a); ok { append(&d.journal, e) }
		}
		// (a user that is not in the systemd-journal group or adm reads its own units' lines alone)
		if len(d.journal) == 0 { d.journal_problem = d.boot ? i18n.tr("No entry of this boot that this user may read.") : i18n.tr("No entry in the journal that this user may read.") }
	}
}

// A property's value: a number (a 't' or a 'u') or a text (an 's' or an 'o').
@(private = "file")
Property :: struct { number: u64, text: string }

@(private = "file")
unit_property :: proc(c: ^dbus.Conn, path, iface, name: string) -> (v: Property, ok: bool) {
	w := dbus.body_writer()
	dbus.w_string(&w, iface)
	dbus.w_string(&w, name)
	msg, called := dbus.call(c, SYSTEMD_DEST, path, "org.freedesktop.DBus.Properties", "Get", "ss", w.buf[:])
	if !called { return }
	r := dbus.msg_reader(&msg)
	switch dbus.r_variant_sig(&r) {
	case "t":      v.number = dbus.r_u64(&r)
	case "u":      v.number = u64(dbus.r_u32(&r))
	case "s", "o": v.text = strings.clone(dbus.r_string(&r), context.temp_allocator)
	case:          return
	}
	return v, !r.err
}

// An entry of `journalctl -o json`: one object a line, its fields strings (__REALTIME_TIMESTAMP in microseconds,
// PRIORITY 0..7). A MESSAGE that is not UTF-8 comes as an array of bytes. The texts in `a`.
journal_entry_parse :: proc(line: string, a: runtime.Allocator) -> (e: Journal_Entry, ok: bool) {
	v, err := json.parse_string(line, allocator = context.temp_allocator)
	if err != nil { return }
	obj := v.(json.Object) or_return
	text :: proc(obj: json.Object, key: string) -> string {
		#partial switch x in obj[key] {
		case json.String: return x
		case json.Array:
			b := make([dynamic]u8, 0, len(x), context.temp_allocator)
			for n in x { if f, is := n.(json.Float); is { append(&b, u8(f)) } else if i, ii := n.(json.Integer); ii { append(&b, u8(i)) } }
			return string(b[:])
		}
		return ""
	}
	e.usec = i64(strconv.parse_i64(text(obj, "__REALTIME_TIMESTAMP")) or_else 0)
	e.priority = 6
	if p, has := strconv.parse_uint(text(obj, "PRIORITY")); has && p <= 7 { e.priority = u8(p) }
	if pid, has := strconv.parse_int(text(obj, "_PID")); has { e.pid = i32(pid) }
	ident := text(obj, "SYSLOG_IDENTIFIER")
	if ident == "" { ident = text(obj, "_COMM") }
	e.ident = strings.clone(ident, a)
	e.message = strings.clone(strings.trim_right_space(text(obj, "MESSAGE")), a)
	return e, true
}
