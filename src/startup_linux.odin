package inspecteur

// What starts with the session on Linux:
//
// - The XDG autostart entries (the Desktop Application Autostart Specification): the .desktop files of
//   $XDG_CONFIG_HOME/autostart, then of each $XDG_CONFIG_DIRS/autostart; a file of the user's folder hides the system's
//   of the same name. An entry is off with Hidden=true or X-GNOME-Autostart-enabled=false; OnlyShowIn and NotShowIn
//   name the desktops ($XDG_CURRENT_DESKTOP) it starts in. Turning a system's entry off writes the user's copy of it
//   with Hidden=true, as the specification says; turning it on again takes that copy away when nothing else changed in
//   it.
// - The user's systemd services that the session's targets (default.target, graphical-session.target) want: those whose
//   unit file says so in [Install] (on when enabled), and those the targets want otherwise (static). They are turned on
//   and off with EnableUnitFiles and DisableUnitFiles on the user's manager (the session bus).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import dbus "gt:dbus"
import "gt:platform"
import i18n "gt:i18n"

// The targets of a session: a service they want starts with it.
SESSION_TARGETS :: [2]string{"default.target", "graphical-session.target"}

Startup_Bus :: struct {
	conn: ^dbus.Conn,   // the session bus (the user's service manager)
}

startup_bus_close :: proc(b: ^Startup_Bus) {
	if b.conn != nil { dbus.conn_close(b.conn) }
	b.conn = nil
}

@(private = "file")
startup_conn :: proc(b: ^Startup_Bus) -> ^dbus.Conn {
	if b.conn != nil && !dbus.conn_alive(b.conn) {
		dbus.conn_close(b.conn)
		b.conn = nil
	}
	if b.conn == nil { b.conn = dbus.connect_bus(.Session, runtime.heap_allocator()) }
	return b.conn
}

// The user's autostart folder ($XDG_CONFIG_HOME/autostart).
@(private = "file")
autostart_user_dir :: proc() -> string {
	return strings.concatenate({platform.user_dir(.Config, "", context.temp_allocator), "/autostart"}, context.temp_allocator)
}

// The system's autostart folders, the first one first.
@(private = "file")
autostart_system_dirs :: proc() -> []string {
	dirs := os.get_env("XDG_CONFIG_DIRS", context.temp_allocator)
	if dirs == "" { dirs = "/etc/xdg" }
	out := make([dynamic]string, context.temp_allocator)
	for d in strings.split(dirs, ":", context.temp_allocator) {
		if d != "" { append(&out, strings.concatenate({d, "/autostart"}, context.temp_allocator)) }
	}
	return out[:]
}

// Everything that starts with the session into `out`, its texts in `a`. Returns what could not be read (temporary).
startup_read :: proc(b: ^Startup_Bus, out: ^[dynamic]Startup_Item, a: runtime.Allocator) -> (problem: string) {
	autostart_read(out, a)
	return user_services_read(b, out, a)
}

@(private = "file")
autostart_read :: proc(out: ^[dynamic]Startup_Item, a: runtime.Allocator) {
	seen := make(map[string]bool, 64, context.temp_allocator)
	desktops := strings.split(os.get_env("XDG_CURRENT_DESKTOP", context.temp_allocator), ":", context.temp_allocator)
	dirs := make([dynamic]string, context.temp_allocator)
	append(&dirs, autostart_user_dir())
	append(&dirs, ..autostart_system_dirs())
	for dir in dirs {
		fis, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil { continue }
		for fi in fis {
			if !strings.has_suffix(fi.name, ".desktop") || fi.name in seen { continue }
			seen[fi.name] = true
			path := strings.concatenate({dir, "/", fi.name}, context.temp_allocator)
			data, rerr := os.read_entire_file(path, context.temp_allocator)
			if rerr != nil { continue }
			e := autostart_entry(string(data), desktops)
			if !e.application { continue }
			status := i18n.tr("Enabled")
			if !e.enabled { status = i18n.tr("Disabled") } else if !e.in_desktop { status = i18n.tr("Not in this desktop") }
			append(out, Startup_Item{
				kind = .Autostart, id = strings.clone(fi.name, a), name = strings.clone(e.name != "" ? e.name : fi.name, a),
				command = strings.clone(e.exec, a), icon = strings.clone(e.icon, a), path = strings.clone(path, a),
				enabled = e.enabled, status = strings.clone(status, a), can_toggle = true,
			})
		}
	}
}

// What an autostart entry says.
Autostart_Entry :: struct {
	name, exec, icon: string,
	application:      bool,   // Type=Application (or no Type)
	enabled:          bool,   // not Hidden, not X-GNOME-Autostart-enabled=false
	in_desktop:       bool,   // OnlyShowIn and NotShowIn let it start in one of `desktops`
}

autostart_entry :: proc(text: string, desktops: []string) -> (e: Autostart_Entry) {
	g :: "Desktop Entry"
	e.name = unit_file_value(text, g, "Name")
	e.exec = unit_file_value(text, g, "Exec")
	e.icon = unit_file_value(text, g, "Icon")
	kind := unit_file_value(text, g, "Type")
	e.application = kind == "" || kind == "Application"
	e.enabled = unit_file_value(text, g, "Hidden") != "true" && unit_file_value(text, g, "X-GNOME-Autostart-enabled") != "false"
	listed :: proc(list: string, desktops: []string) -> bool {
		for d in strings.split(list, ";", context.temp_allocator) {
			if d == "" { continue }
			for cur in desktops { if strings.equal_fold(d, cur) { return true } }
		}
		return false
	}
	e.in_desktop = true
	if only := unit_file_value(text, g, "OnlyShowIn"); only != "" { e.in_desktop = listed(only, desktops) }
	if not := unit_file_value(text, g, "NotShowIn"); not != "" && listed(not, desktops) { e.in_desktop = false }
	return
}

@(private = "file")
user_services_read :: proc(b: ^Startup_Bus, out: ^[dynamic]Startup_Item, a: runtime.Allocator) -> (problem: string) {
	c := startup_conn(b)
	if c == nil { return i18n.tr("The user's service manager cannot be reached (no session bus): its services are not listed.") }
	states := make(map[string]string, 256, context.temp_allocator)   // name -> unit file state
	paths := make(map[string]string, 256, context.temp_allocator)
	msg, ok := dbus.call(c, SYSTEMD_DEST, SYSTEMD_PATH, SYSTEMD_IFACE, "ListUnitFiles", "", nil)
	if !ok { return i18n.tr("The user's service manager does not list its services.") }
	r := dbus.msg_reader(&msg)
	end := dbus.r_array_begin(&r, "(ss)")
	for r.pos < end && !r.err {
		dbus.r_align_entry(&r)
		path, state := dbus.r_string(&r), dbus.r_string(&r)
		name := filepath.base(path)
		if !strings.has_suffix(name, ".service") || strings.has_suffix(name, "@.service") { continue }
		key := strings.clone(name, context.temp_allocator)
		states[key] = strings.clone(state, context.temp_allocator)
		paths[key] = strings.clone(path, context.temp_allocator)
	}
	// what the session's targets want now (static services, links made by other tools)
	wanted := make(map[string]bool, 64, context.temp_allocator)
	for target in SESSION_TARGETS {
		w := dbus.body_writer()
		dbus.w_string(&w, target)
		umsg, uok := dbus.call(c, SYSTEMD_DEST, SYSTEMD_PATH, SYSTEMD_IFACE, "GetUnit", "s", w.buf[:])
		if !uok { continue }
		ur := dbus.msg_reader(&umsg)
		unit_path := strings.clone(dbus.r_string(&ur), context.temp_allocator)
		pw := dbus.body_writer()
		dbus.w_string(&pw, "org.freedesktop.systemd1.Unit")
		dbus.w_string(&pw, "Wants")
		pmsg, pok := dbus.call(c, SYSTEMD_DEST, unit_path, "org.freedesktop.DBus.Properties", "Get", "ss", pw.buf[:])
		if !pok { continue }
		pr := dbus.msg_reader(&pmsg)
		if dbus.r_variant_sig(&pr) != "as" { continue }
		wend := dbus.r_array_begin(&pr, "s")
		for pr.pos < wend && !pr.err {
			name := dbus.r_string(&pr)
			if strings.has_suffix(name, ".service") { wanted[strings.clone(name, context.temp_allocator)] = true }
		}
	}
	for name, path in paths {
		state := states[name]
		data, rerr := os.read_entire_file(path, context.temp_allocator)
		if rerr != nil { continue }
		text := string(data)
		install := strings.join({unit_file_value(text, "Install", "WantedBy"), unit_file_value(text, "Install", "RequiredBy")}, " ", context.temp_allocator)
		by_install := false
		for target in SESSION_TARGETS { if strings.contains(install, target) { by_install = true } }
		if !by_install && name not_in wanted { continue }
		// (on: a session's target wants it now, or its file is enabled; a masked service never starts)
		on := (name in wanted || state == "enabled" || state == "enabled-runtime") && state != "masked" && state != "masked-runtime"
		// (what its [Install] section lets EnableUnitFiles and DisableUnitFiles do)
		toggles := by_install && (state == "enabled" || state == "enabled-runtime" || state == "disabled" || state == "linked" || state == "linked-runtime")
		description := unit_file_value(text, "Unit", "Description")
		append(out, Startup_Item{
			kind = .User_Service, id = strings.clone(name, a), name = strings.clone(description != "" ? description : name, a),
			command = strings.clone(exec_command(unit_file_value(text, "Service", "ExecStart")), a), path = strings.clone(path, a),
			enabled = on, status = strings.clone(unit_status(state, on), a), can_toggle = toggles,
		})
	}
	return ""
}

// An ExecStart= without its prefixes ("-", "@", ":", "+", "!": how systemd runs it, not what it runs).
exec_command :: proc(exec: string) -> string {
	s := exec
	for len(s) > 0 && strings.index_byte("-@:+!", s[0]) >= 0 { s = s[1:] }
	return s
}

// What the Status column says of a user service: whether it starts with the session; a masked one never can.
@(private = "file")
unit_status :: proc(state: string, on: bool) -> string {
	if state == "masked" || state == "masked-runtime" { return i18n.tr("Masked") }
	return on ? i18n.tr("Enabled") : i18n.tr("Disabled")
}

// Turns an entry or a service on or off. Returns "" when it is done, else why not (temporary).
startup_set_enabled :: proc(b: ^Startup_Bus, kind: Startup_Kind, id: string, on: bool) -> (failure: string) {
	switch kind {
	case .Autostart:    return autostart_set_enabled(id, on)
	case .User_Service:
		c := startup_conn(b)
		if c == nil { return i18n.tr("the user's service manager cannot be reached") }
		return unit_act(c, on ? .Enable : .Disable, id)
	}
	return ""
}

// The user's copy of the entry `id`: Hidden=true to turn it off; on, Hidden and X-GNOME-Autostart-enabled=false go,
// and a copy that says the same as the system's entry goes with them.
@(private = "file")
autostart_set_enabled :: proc(id: string, on: bool) -> (failure: string) {
	if strings.contains(id, "/") || !strings.has_suffix(id, ".desktop") { return i18n.tr("not an autostart entry") }
	user_dir := autostart_user_dir()
	user_path := strings.concatenate({user_dir, "/", id}, context.temp_allocator)
	system_text := ""
	has_system := false
	for d in autostart_system_dirs() {
		if data, err := os.read_entire_file(strings.concatenate({d, "/", id}, context.temp_allocator), context.temp_allocator); err == nil {
			system_text, has_system = string(data), true
			break
		}
	}
	text := system_text
	has_user := false
	if data, err := os.read_entire_file(user_path, context.temp_allocator); err == nil { text, has_user = string(data), true }
	if !has_user && !has_system { return i18n.tr("its file is gone") }
	if on {
		text = desktop_entry_set(text, "Hidden", "")
		if unit_file_value(text, "Desktop Entry", "X-GNOME-Autostart-enabled") == "false" { text = desktop_entry_set(text, "X-GNOME-Autostart-enabled", "") }
		if has_system && text == system_text {
			if has_user && os.remove(user_path) != nil { return fmt.tprintf(i18n.tr("cannot remove %s"), user_path) }
			return ""
		}
		if has_system && unit_file_value(text, "Desktop Entry", "Hidden") == "" && unit_file_value(system_text, "Desktop Entry", "Hidden") == "true" {
			text = desktop_entry_set(text, "Hidden", "false")   // (the system's entry is off: the user's copy says on)
		}
	} else {
		text = desktop_entry_set(text, "Hidden", "true")
	}
	_ = os.make_directory_all(user_dir)   // (an error when it is there already: the write says what matters)
	// (a file beside it, then renamed over it: the session never reads a half-written entry)
	temp := strings.concatenate({user_path, ".inspecteur-new"}, context.temp_allocator)
	if os.write_entire_file(temp, text) != nil { return fmt.tprintf(i18n.tr("cannot write %s"), temp) }
	if os.rename(temp, user_path) != nil {
		_ = os.remove(temp)
		return fmt.tprintf(i18n.tr("cannot write %s"), user_path)
	}
	return ""
}

// The text of a desktop entry with `key` set to `value` in its [Desktop Entry] group ("" takes the key away): the line
// replaced where it is, else added at the end of the group. The rest is kept as it is.
desktop_entry_set :: proc(text, key, value: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	in_group, done := false, false
	put :: proc(b: ^strings.Builder, key, value: string) { if value != "" { strings.write_string(b, key); strings.write_byte(b, '='); strings.write_string(b, value); strings.write_byte(b, '\n') } }
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		t := strings.trim_space(line)
		if len(t) > 0 && t[0] == '[' {
			if in_group && !done { put(&b, key, value); done = true }
			in_group = t == "[Desktop Entry]"
			strings.write_string(&b, line)
			strings.write_byte(&b, '\n')
			continue
		}
		if in_group {
			if eq := strings.index_byte(t, '='); eq >= 0 && strings.trim_space(t[:eq]) == key {
				if !done { put(&b, key, value); done = true }
				continue
			}
		}
		strings.write_string(&b, line)
		strings.write_byte(&b, '\n')
	}
	if in_group && !done { put(&b, key, value) }
	return strings.to_string(b)
}
