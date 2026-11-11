package inspecteurtool

// live's checks of the Services, Startup, Connections and Information sections (live.odin runs them). Each acts only on
// what the test made itself: its own listening socket, its own autostart entry in the session's configuration, its own
// transient user service, checked by name before anything is pressed.

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"
import cdp "gt:cdp"
import toolbox "gt:toolbox"

// The sidebar's rows (view.odin: ###side_<tab>), in the order of the Tab enum.
SIDE_PROCESSES   :: "side_1"
SIDE_SERVICES    :: "side_3"
SIDE_STARTUP     :: "side_4"
SIDE_CONNECTIONS :: "side_5"
SIDE_INFORMATION :: "side_6"
// More than the toolkit's DOUBLE_CLICK_MS (450 ms) between two clicks on a row.
DOUBLE_CLICK_GAP :: 600 * time.Millisecond

// A TCP listener of this test on 127.0.0.1: its row says this tool's name and pid.
live_connections :: proc(l: ^Live) {
	c := &l.c
	sock, err := net.listen_tcp({net.IP4_Loopback, 0})
	if !check(l, err == nil, "a TCP listener of this test on 127.0.0.1") { return }
	defer net.close(sock)
	ep, berr := net.bound_endpoint(sock)
	if !check(l, berr == nil, "its port") { return }
	address := fmt.tprintf("127.0.0.1:%d", ep.port)
	check(l, cdp.click_name(c, SIDE_CONNECTIONS), "the Connections section")
	check(l, cdp.wait_name(c, "hd_3", SESSION_WAIT), "its table has its columns")
	check(l, cdp.type_text(c, address), "filter by %s", address)
	check(l, wait_named_text(c, "c3", address), "the listener's row is there")
	row := row_with(c, "c3", address)
	check(l, row.process == "inspecteurtool" && row.pid == fmt.tprintf("%d", os.get_pid()) && row.state == "Listening",
		"its process is this test (%s, PID %s), it listens (%s)", row.process, row.pid, row.state)
	check(l, cdp.key(c, "Escape"), "Escape clears the filter")
	cdp.wait_idle(c, SESSION_WAIT)
	check(l, cdp.shot(c, fmt.tprintf("%s/connections.png", l.dir)), "a picture of the section")
}

// The system's services are listed (and only read). Then a transient service of the user's manager that this test makes
// (inspecteur-live-<pid>): it fails first (a file it waits for is not there) and stays listed; the test makes the file,
// then Start, Restart and Stop from the window, each pressed only once the row selected is that service. It is stopped
// and its failure forgotten at the end, whatever happened.
live_services :: proc(l: ^Live) {
	c := &l.c
	check(l, cdp.click_name(c, SIDE_SERVICES), "the Services section")
	check(l, cdp.wait_for(c, "running", SESSION_WAIT), "the system's services are listed")
	check(l, len(cdp.find_name(c, "c0")) > 5, "with rows (%d in view)", len(cdp.find_name(c, "c0")))
	cdp.wait_idle(c, SESSION_WAIT)
	check(l, cdp.shot(c, fmt.tprintf("%s/services.png", l.dir)), "a picture of the section")

	if user_bus_address() == "" {
		check(l, true, "no session bus here (no DBUS_SESSION_BUS_ADDRESS, no $XDG_RUNTIME_DIR/bus): the user service's checks are skipped")
		return
	}
	unit := fmt.tprintf("inspecteur-live-%d", os.get_pid())
	service := fmt.tprintf("%s.service", unit)
	flag := fmt.tprintf("%s/start-allowed", l.dir)
	_ = os.remove(flag)
	script := fmt.tprintf("test -e '%s' && exec sleep 300; exit 1", flag)
	if !check(l, toolbox.run({"systemd-run", "--user", "--quiet", fmt.tprintf("--unit=%s", unit), "--", "sh", "-c", script}), "a transient user service of this test: %s", service) { return }
	defer {
		_ = toolbox.run({"systemctl", "--user", "stop", service})
		_ = toolbox.run({"systemctl", "--user", "reset-failed", service})
		_ = os.remove(flag)
	}
	check(l, wait_unit(service, "failed"), "it fails first (no %s)", flag)

	check(l, cdp.key(c, "ctrl+u"), "Ctrl+U: the user's services")
	check(l, cdp.type_text(c, unit), "filter by its name")
	if !check(l, wait_named_text(c, "c0", service), "its row is there") { return }
	check(l, wait_row_cell(c, service, "c2", "failed"), "it says failed")
	if !select_unit(l, service) { return }

	_ = os.write_entire_file(flag, "")
	if !check(l, cdp.key(c, "ctrl+s"), "Ctrl+S: Start") { return }
	check(l, wait_unit(service, "active"), "the manager says it is active")
	check(l, wait_row_cell(c, service, "c2", "active (running)"), "its row says active (running)")
	check(l, cdp.wait_for(c, fmt.tprintf("Started %s", service), SESSION_WAIT), "the footer says it started")
	pid := cell_of(c, service, "c5")
	check(l, pid != "", "its main process is shown (PID %s)", pid)

	// the details' pane: the service's name and its unit's details
	check(l, wait_named_text(c, "svc_details_name", service), "the details' pane is the service's")
	// its journal: the manager's entries of it (Started), a search that keeps none, the level, the boot
	check(l, wait_named_prefix(c, "svc_journal_count", ""), "its journal's entries are read (%s)", named_text(c, "svc_journal_count"))
	check(l, cdp.key(c, "ctrl+j") && cdp.type_text(c, "zzqx-nothing") && wait_named_prefix(c, "svc_journal_count", "0 of "), "Ctrl+J: a search that keeps no entry (%s)", named_text(c, "svc_journal_count"))
	check(l, cdp.key(c, "Escape") && wait_named_prefix(c, "svc_journal_count", "") && cdp.wait_for(c, "zzqx-nothing", SESSION_WAIT, gone = true) && !strings.has_prefix(named_text(c, "svc_journal_count"), "0 of"), "Escape clears it (%s)", named_text(c, "svc_journal_count"))
	check(l, cdp.key(c, "Escape"), "Escape again leaves the search")
	check(l, cdp.key(c, "alt+l") && file_has(prefs_path(l), "services.journal_level\twarnings"), "Alt+L: warnings and worse, kept")
	check(l, cdp.key(c, "alt+l") && cdp.key(c, "alt+l") && file_has(prefs_path(l), "services.journal_level\tall"), "Alt+L twice: errors, then all")
	check(l, cdp.key(c, "alt+b") && file_has(prefs_path(l), "services.journal_boot\tfalse") && cdp.key(c, "alt+b"), "Alt+B: every boot, and back")
	// its journal in a window of its own: sway lists it; closed, it goes and the main window answers on
	title := fmt.tprintf("%s: journal", service)
	check(l, cdp.key(c, "ctrl+shift+j") && wait_sway_title(l, title, true), "Ctrl+Shift+J: the journal in a window of its own (%s)", title)
	check(l, sway_command(l, fmt.tprintf(`[title="%s"] kill`, title)) && wait_sway_title(l, title, false), "closed, the window goes")
	check(l, cdp.wait_name(c, "svc_journal_count", SESSION_WAIT), "the main window answers on")

	if !select_unit(l, service) { return }
	if !check(l, cdp.key(c, "ctrl+r"), "Ctrl+R: Restart") { return }
	if !check(l, cdp.wait_for(c, fmt.tprintf("Restart %s?", service), SESSION_WAIT), "the restart is asked first") { return }
	if !check(l, cdp.key(c, "Enter"), "Enter confirms it") { return }
	check(l, cdp.wait_for(c, fmt.tprintf("Restarted %s", service), SESSION_WAIT), "the footer says it restarted")
	check(l, wait_row_cell_not(c, service, "c5", pid) && wait_unit(service, "active"), "a new main process (was %s, now %s)", pid, cell_of(c, service, "c5"))
	check(l, wait_row_cell(c, service, "c2", "active (running)"), "its row says active (running) again")

	// Go to service: from its main process in Processes, back to its row here
	main_pid := cell_of(c, service, "c5")
	check(l, cdp.key(c, "Enter") && cdp.wait_for(c, fmt.tprintf("PID %s", main_pid), SESSION_WAIT), "Enter: its main process in Processes (PID %s)", main_pid)
	check(l, cdp.key(c, "ctrl+shift+s") && cdp.wait_name(c, "svc_start", SESSION_WAIT), "Ctrl+Shift+S: Go to service")
	check(l, wait_named_text(c, "svc_details_name", service), "the service is selected again")
	// (the table's list has the keyboard since its row was clicked: Ctrl+F gives it to the filter)
	check(l, cdp.key(c, "ctrl+f") && cdp.type_text(c, unit), "Ctrl+F, filter by its name again")

	if !select_unit(l, service) { return }
	if !check(l, cdp.key(c, "Delete"), "Delete: Stop") { return }
	if !check(l, cdp.wait_for(c, fmt.tprintf("Stop %s?", service), SESSION_WAIT), "the stop is asked first") { return }
	if !check(l, cdp.click_name(c, "kill_confirm"), "click Stop") { return }
	check(l, cdp.wait_for(c, fmt.tprintf("Stopped %s", service), SESSION_WAIT), "the footer says it stopped (%q)", footer(c))
	check(l, !wait_unit(service, "active", 2 * time.Second), "the manager says it is not active")
	check(l, cdp.key(c, "Escape"), "Escape clears the filter")
	check(l, cdp.key(c, "ctrl+u"), "Ctrl+U: the system's services again")
}

// Selects the row of `service` (its name's cell, clicked: the list gets the keyboard) and checks that the row selected,
// as the accessibility tree says, is that service. (It waits first: two clicks on a row closer than the toolkit's
// DOUBLE_CLICK_MS are a double click, which opens the service's process in Processes.)
@(private = "file")
select_unit :: proc(l: ^Live, service: string) -> bool {
	c := &l.c
	time.sleep(DOUBLE_CLICK_GAP)
	at := -1
	deadline := time.tick_add(time.tick_now(), READER_WAIT)
	for at < 0 && time.tick_diff(time.tick_now(), deadline) > 0 {
		for b, i in cdp.find_name(c, "c0") { if b.text == service { at = i } }
		if at < 0 { time.sleep(SESSION_POLL) }
	}
	if !check(l, at >= 0, "the row of %s is in view", service) {
		cdp.shot(c, fmt.tprintf("%s/select_failed.png", l.dir))   // (what the window showed instead)
		return false
	}
	_, ok := cdp.call(c, "Toolkit.click", fmt.tprintf(`{{"name":"c0","index":%d}}`, at))
	cdp.wait_idle(c, SESSION_WAIT)
	got := selected_row_name(c)
	if check(l, ok && strings.has_prefix(got, fmt.tprintf("%s, ", service)), "the row selected is %s (%q)", service, got) { return true }
	cdp.shot(c, fmt.tprintf("%s/select_failed.png", l.dir))   // (what the window showed instead)
	return false
}

// The footer's message.
footer :: proc(c: ^cdp.Client) -> string {
	boxes := cdp.find_name(c, "msg")
	return len(boxes) > 0 ? boxes[0].text : ""
}

// `systemctl --user is-active` says `want` within the time.
@(private = "file")
wait_unit :: proc(service, want: string, within := SESSION_WAIT) -> bool {
	deadline := time.tick_add(time.tick_now(), within)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		out, _ := toolbox.capture({"systemctl", "--user", "is-active", service})
		if strings.trim_space(out) == want { return true }
		time.sleep(SESSION_POLL)
	}
	return false
}

// The cell `name` of the row whose first cell says `first` ("" when it is not in view).
@(private = "file")
cell_of :: proc(c: ^cdp.Client, first, name: string) -> string {
	for b in cdp.find_name(c, "c0") {
		if b.text != first { continue }
		mid := b.y + b.h / 2
		for x in cdp.find_name(c, name) { if x.y <= mid && mid <= x.y + x.h { return x.text } }
	}
	return ""
}

@(private = "file")
wait_row_cell :: proc(c: ^cdp.Client, first, name, want: string) -> bool {
	deadline := time.tick_add(time.tick_now(), SESSION_WAIT)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		if cell_of(c, first, name) == want { return true }
		time.sleep(SESSION_POLL)
	}
	return false
}

@(private = "file")
wait_row_cell_not :: proc(c: ^cdp.Client, first, name, was: string) -> bool {
	deadline := time.tick_add(time.tick_now(), SESSION_WAIT)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		if v := cell_of(c, first, name); v != "" && v != was { return true }
		time.sleep(SESSION_POLL)
	}
	return false
}

// An autostart entry this test writes in the session's own configuration ($XDG_CONFIG_HOME/autostart of build/live):
// listed and on; Ctrl+D writes Hidden=true in it, Ctrl+E takes it away, each pressed only once the row selected is it.
live_startup :: proc(l: ^Live) {
	c := &l.c
	name := fmt.tprintf("Inspecteur live %d", os.get_pid())
	dir := fmt.tprintf("%s/config/autostart", l.dir)
	path := fmt.tprintf("%s/inspecteur-live-%d.desktop", dir, os.get_pid())
	_ = os.make_directory_all(dir)
	entry := fmt.tprintf("[Desktop Entry]\nType=Application\nName=%s\nExec=true --inspecteur-live\n", name)
	if !check(l, os.write_entire_file(path, entry) == nil, "an autostart entry of this test: %s", path) { return }
	check(l, cdp.click_name(c, SIDE_STARTUP), "the Startup section")
	check(l, cdp.type_text(c, name), "filter by its name")
	if !check(l, wait_named_text(c, "c0", name), "its row is there") { return }
	check(l, wait_row_cell(c, name, "c3", "Enabled") && wait_row_cell(c, name, "c2", "Autostart entry"), "an autostart entry, enabled")
	check(l, cell_of(c, name, "c1") == "true --inspecteur-live", "its command")

	if !select_row_named(l, name) { return }
	if !check(l, cdp.key(c, "ctrl+d"), "Ctrl+D: Disable") { return }
	check(l, file_has_text(path, "Hidden=true"), "its file says Hidden=true")
	check(l, wait_row_cell(c, name, "c3", "Disabled"), "its row says Disabled")
	check(l, cdp.wait_for(c, fmt.tprintf("Disabled %s", name), SESSION_WAIT), "the footer says so (%q)", footer(c))

	if !select_row_named(l, name) { return }
	if !check(l, cdp.key(c, "ctrl+e"), "Ctrl+E: Enable") { return }
	check(l, file_lacks_text(path, "Hidden="), "its file no longer hides it")
	check(l, wait_row_cell(c, name, "c3", "Enabled"), "its row says Enabled")
	cdp.wait_idle(c, SESSION_WAIT)
	check(l, cdp.key(c, "Escape"), "Escape clears the filter")
	cdp.wait_idle(c, SESSION_WAIT)
	check(l, cdp.shot(c, fmt.tprintf("%s/startup.png", l.dir)), "a picture of the section")
}

// Selects the row whose first cell says `first` (clicked, after a pause: not a double click) and checks that the row
// selected, as the accessibility tree says, is it.
@(private = "file")
select_row_named :: proc(l: ^Live, first: string) -> bool {
	c := &l.c
	time.sleep(DOUBLE_CLICK_GAP)
	at := -1
	for b, i in cdp.find_name(c, "c0") { if b.text == first { at = i } }
	if !check(l, at >= 0, "the row of %s is in view", first) { return false }
	_, ok := cdp.call(c, "Toolkit.click", fmt.tprintf(`{{"name":"c0","index":%d}}`, at))
	cdp.wait_idle(c, SESSION_WAIT)
	got := selected_row_name(c)
	return check(l, ok && strings.has_prefix(got, fmt.tprintf("%s, ", first)), "the row selected is %s (%q)", first, got)
}

@(private = "file")
file_has_text :: proc(path, text: string) -> bool {
	deadline := time.tick_add(time.tick_now(), SESSION_WAIT)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err == nil && strings.contains(string(data), text) { return true }
		time.sleep(SESSION_POLL)
	}
	return false
}

@(private = "file")
file_lacks_text :: proc(path, text: string) -> bool {
	deadline := time.tick_add(time.tick_now(), SESSION_WAIT)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err == nil && !strings.contains(string(data), text) { return true }
		time.sleep(SESSION_POLL)
	}
	return false
}

// The system's details: the kernel's version, as this test reads it; Copy all says what it copied.
live_information :: proc(l: ^Live) {
	c := &l.c
	release, _ := os.read_entire_file("/proc/sys/kernel/osrelease", context.temp_allocator)
	kernel := strings.trim_space(string(release))
	check(l, cdp.click_name(c, SIDE_INFORMATION), "the Information section")
	check(l, cdp.wait_for(c, fmt.tprintf("Linux %s", kernel), SESSION_WAIT), "it shows the kernel, Linux %s", kernel)
	check(l, cdp.wait_for(c, "Operating system", SESSION_WAIT) && cdp.wait_for(c, "Installed", SESSION_WAIT), "the system and its memory")
	check(l, cdp.key(c, "ctrl+c") && cdp.wait_for(c, "Copied the system's information", SESSION_WAIT), "Ctrl+C copies it all")
	cdp.wait_idle(c, SESSION_WAIT)
	check(l, cdp.shot(c, fmt.tprintf("%s/information.png", l.dir)), "a picture of the section")
}

// The cells of the row whose cell `name` says `text`: the process (c0), the PID (c1), the state (c5).
Row_Cells :: struct { process, pid, state: string }

row_with :: proc(c: ^cdp.Client, name, text: string) -> (r: Row_Cells) {
	for b in cdp.find_name(c, name) {
		if b.text != text { continue }
		mid := b.y + b.h / 2
		cell :: proc(c: ^cdp.Client, name: string, mid: f64) -> string {
			for x in cdp.find_name(c, name) { if x.y <= mid && mid <= x.y + x.h { return x.text } }
			return ""
		}
		return {cell(c, "c0", mid), cell(c, "c1", mid), cell(c, "c5", mid)}
	}
	return
}

// A box named `name` comes to say `text`.
wait_named_text :: proc(c: ^cdp.Client, name, text: string) -> bool {
	deadline := time.tick_add(time.tick_now(), READER_WAIT)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		for b in cdp.find_name(c, name) { if b.text == text { return true } }
		time.sleep(SESSION_POLL)
	}
	return false
}

// The text of the first box named `name` ("" none).
named_text :: proc(c: ^cdp.Client, name: string) -> string {
	for b in cdp.find_name(c, name) { return b.text }
	return ""
}

// Waits for a box named `name` whose text starts with `prefix` (any text when "").
wait_named_prefix :: proc(c: ^cdp.Client, name, prefix: string) -> bool {
	deadline := time.tick_add(time.tick_now(), READER_WAIT)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		for b in cdp.find_name(c, name) { if strings.has_prefix(b.text, prefix) && b.text != "" { return true } }
		time.sleep(SESSION_POLL)
	}
	return false
}

prefs_path :: proc(l: ^Live) -> string { return fmt.tprintf("%s/config/inspecteur/prefs", l.dir) }

// swaymsg on the session's sway (its socket in the runtime folder).
@(private = "file")
swaymsg :: proc(l: ^Live, args: ..string) -> (out: string, ok: bool) {
	code: int
	run := fmt.tprintf("%s/run", l.dir)
	sock := ""
	if fis, err := os.read_all_directory_by_path(run, context.temp_allocator); err == nil {
		for fi in fis { if strings.has_prefix(fi.name, "sway-ipc.") { sock = fmt.tprintf("%s/%s", run, fi.name) } }
	}
	if sock == "" { return }
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "swaymsg", "-s", sock)
	append(&cmd, ..args)
	out, code = toolbox.capture(cmd[:])
	return out, code == 0
}

@(private = "file")
sway_command :: proc(l: ^Live, command: string) -> bool { _, ok := swaymsg(l, command); return ok }

// Waits until sway's tree has a window titled `title` (`present`), or has none.
@(private = "file")
wait_sway_title :: proc(l: ^Live, title: string, present: bool) -> bool {
	deadline := time.tick_add(time.tick_now(), SESSION_WAIT)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		tree, _ := swaymsg(l, "-t", "get_tree")
		if strings.contains(tree, fmt.tprintf(`"name": "%s"`, title)) == present { return true }
		time.sleep(SESSION_POLL)
	}
	return false
}
