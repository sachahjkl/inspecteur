package inspecteurtool

// live's checks of the guards (Inspecteur does not suspend itself), of a list another user's process refuses, of Kill
// on an app's group, of the commands' keys (the palette, the sheet of the keys, the sections, the columns) and of the
// desktop integration. As everywhere in live: a key that changes something is pressed only once the selected row is
// the test's own, and an app's group is killed only once the test has checked that it holds only its own processes.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:time"
import cdp "gt:cdp"
import toolbox "gt:toolbox"

// The app of this test: its desktop entry is in the session's data folder (written before inspecteur reads its apps),
// and its processes are those of a transient scope whose name holds the entry's id (the way a launcher names a scope).
// Its program is a name no process has: only that scope's processes are the app's.
live_app_id :: proc() -> string { return fmt.tprintf("inspecteurlive%d", os.get_pid()) }
live_app_name :: proc() -> string { return fmt.tprintf("Inspecteur live app %d", os.get_pid()) }

live_app_entry :: proc(dir: string) {
	apps := fmt.tprintf("%s/data/applications", dir)
	_ = os.make_directory_all(apps)
	entry := fmt.tprintf("[Desktop Entry]\nType=Application\nName=%s\nExec=inspecteur-live-app-%d\n", live_app_name(), os.get_pid())
	_ = os.write_entire_file(fmt.tprintf("%s/%s.desktop", apps, live_app_id()), entry)
	// Inspecteur's own window is an app's (its app id, inspecteur, the window class of this entry): its row has the
	// window's button (live_app_window), on a runner where Inspecteur is not installed too
	own := "[Desktop Entry]\nType=Application\nName=Inspecteur\nExec=inspecteur-live-none\nStartupWMClass=inspecteur\n"
	_ = os.write_entire_file(fmt.tprintf("%s/%swindow.desktop", apps, live_app_id()), own)
}

// Inspecteur's own row: Suspend is refused, and the process does not stop.
live_guards :: proc(l: ^Live) {
	c := &l.c
	pid := fmt.tprintf("%d", l.program.pid)
	check(l, cdp.key(c, "Escape") && cdp.type_text(c, pid), "filter by Inspecteur's own PID, %s", pid)
	// Its row is a background process's, or, on a machine whose menu has Inspecteur's own entry (installed by its
	// package), its app's group: Suspend is refused either way.
	time.sleep(DOUBLE_CLICK_GAP)
	at := pid_cell(c, pid)
	if !check(l, at >= 0, "its PID cell is in view") { return }
	_, clicked := cdp.call(c, "Toolkit.click", fmt.tprintf(`{{"name":"c1","index":%d}}`, at))
	cdp.wait_idle(c, SESSION_WAIT)
	got := selected_row_name(c)
	if clicked && got == "Inspecteur, 1 process" {
		// its app's group: opened, the process's own row under it (the same PID, the last such cell)
		check(l, cdp.key(c, "Right"), "Right opens Inspecteur's group")
		cdp.wait_idle(c, SESSION_WAIT)
		at = -1
		for b, i in cdp.find_name(c, "c1") { if b.text == pid { at = i } }
		if !check(l, at >= 0, "its process's PID cell is in view") { return }
		_, clicked = cdp.call(c, "Toolkit.click", fmt.tprintf(`{{"name":"c1","index":%d}}`, at))
		cdp.wait_idle(c, SESSION_WAIT)
		got = selected_row_name(c)
	}
	if !check(l, clicked && got == fmt.tprintf("inspecteur, PID %s", pid), "the row selected is Inspecteur's own process (%q)", got) { return }
	check(l, cdp.key(c, "ctrl+p"), "Ctrl+P: Suspend")
	check(l, cdp.wait_for(c, "Inspecteur does not suspend itself", SESSION_WAIT), "it is refused (%q)", footer(c))
	stopped := wait_state(l.program.pid, 'T', 500 * time.Millisecond)
	if stopped { _ = linux.kill(linux.Pid(l.program.pid), .SIGCONT) }   // (the test's own child: resumed whatever happened)
	check(l, !stopped, "Inspecteur still runs")
	check(l, cdp.key(c, "Escape"), "Escape clears the filter")
}

// The Properties of PID 1, another user's (root's): its open files say "Access denied". Only read: nothing is pressed
// that acts.
live_access_denied :: proc(l: ^Live) {
	c := &l.c
	if linux.getuid() == 0 { check(l, true, "the test runs as root: PID 1's files are readable, skipped"); return }
	check(l, cdp.key(c, "Escape"), "Escape clears the filter")
	// (the PIDs from the lowest: PID 1 is the first background process)
	for _ in 0 ..< 2 {
		if turns(column_numbers(c, "c1"), true) <= 1 { break }
		cdp.click_name(c, "hd_1")
		cdp.wait_idle(c, SESSION_WAIT)
	}
	at := pid_cell(c, "1")
	if at < 0 { check(l, true, "PID 1 is not in view: skipped"); return }
	_, ok := cdp.call(c, "Toolkit.click", fmt.tprintf(`{{"name":"c1","index":%d}}`, at))
	cdp.wait_idle(c, SESSION_WAIT)
	if !check(l, ok && strings.has_suffix(selected_row_name(c), ", PID 1"), "PID 1 is selected (%q)", selected_row_name(c)) { return }
	check(l, cdp.key(c, "alt+Enter") && cdp.wait_name(c, "props_name", SESSION_WAIT), "its Properties open")
	check(l, cdp.click_name(c, "props_tab_3"), "the Open files tab")
	check(l, cdp.wait_for(c, "Access denied", SESSION_WAIT), "it says Access denied")
	check(l, cdp.key(c, "Escape") && cdp.wait_name(c, "props_name", SESSION_WAIT, gone = true), "Escape closes it")
}

// Kill on an app's group ends every process of it: two processes of this test, in a scope of the user's manager named
// for the test's app.
live_group_kill :: proc(l: ^Live) {
	c := &l.c
	if user_bus_address() == "" { check(l, true, "no session bus here: the group's kill is skipped"); return }
	unit := fmt.tprintf("app-%s-1.scope", live_app_id())
	mark_a, mark_b := fmt.tprintf("300.%d41", os.get_pid()), fmt.tprintf("300.%d42", os.get_pid())
	child, err := os.process_start({command = {"systemd-run", "--user", "--scope", "--quiet", fmt.tprintf("--unit=%s", unit), "--", "sh", "-c", fmt.tprintf("sleep %s & exec sleep %s", mark_a, mark_b)}})
	if !check(l, err == nil, "two sleeps of this test in a scope of their own, %s", unit) { return }
	reaped := false
	pid_a := 0
	defer {
		// (whatever failed: the test's own processes, found by their marks, and its scope)
		if !reaped { _ = os.process_kill(child); _, _ = os.process_wait(child, SESSION_WAIT) }
		if pid_a > 0 && has_mark(pid_a, mark_a) { _ = linux.kill(linux.Pid(pid_a), .SIGKILL) }
		_ = toolbox.run({"systemctl", "--user", "stop", unit})
	}
	pid_a = wait_mark(mark_a)
	if !check(l, pid_a > 0 && wait_mark(mark_b) == child.pid, "both run (PIDs %d and %d)", pid_a, child.pid) { return }
	// the scope holds these two and nothing else: the group can hold nothing else
	procs := scope_pids(child.pid, unit)
	if !check(l, len(procs) == 2 && contains_int(procs, pid_a) && contains_int(procs, child.pid), "the scope holds the two sleeps alone (%v)", procs) { return }

	name := live_app_name()
	check(l, cdp.key(c, "Escape") && cdp.type_text(c, name), "filter by the app's name")
	label := fmt.tprintf("%s, 2 processes", name)
	if !check(l, wait_named_text(c, "n", name), "its group is there") { return }
	at := -1
	for b, i in cdp.find_name(c, "n") { if b.text == name { at = i } }
	_, ok := cdp.call(c, "Toolkit.click", fmt.tprintf(`{{"name":"n","index":%d}}`, at))
	cdp.wait_idle(c, SESSION_WAIT)
	if !check(l, ok && selected_row_name(c) == label, "the row selected is the group (%q)", selected_row_name(c)) { return }
	if !check(l, cdp.key(c, "shift+Delete"), "Shift+Delete") { return }
	if !check(l, cdp.wait_for(c, fmt.tprintf("Kill %s (2 processes)?", name), SESSION_WAIT), "the kill of the 2 processes is asked") { return }
	if !check(l, cdp.click_name(c, "kill_confirm"), "click Kill") { return }
	ps, werr := os.process_wait(child, SESSION_WAIT)
	reaped = werr == nil && ps.exited
	check(l, reaped && ps.exit_code == 9, "the group's first process ends by SIGKILL (code %d)", ps.exit_code)
	check(l, wait_gone(pid_a, mark_a), "and the other one too")
	check(l, cdp.wait_for(c, label, SESSION_WAIT, gone = true), "the group goes")
	check(l, cdp.key(c, "Escape"), "Escape clears the filter")
}

// The commands' keys: the palette runs a command, F1 shows the keys, Ctrl+Tab goes from a section to the next,
// Ctrl+Shift+C opens the columns' menu, Ctrl+Shift+L switches light and dark.
live_commands :: proc(l: ^Live) {
	c := &l.c
	prefs := fmt.tprintf("%s/config/inspecteur/prefs", l.dir)
	check(l, cdp.key(c, "Escape") && cdp.key(c, "ctrl+2"), "the Processes section")
	check(l, cdp.key(c, "ctrl+k") && cdp.wait_name(c, "palette_field", SESSION_WAIT), "Ctrl+K opens the palette")
	check(l, cdp.type_text(c, "performance") && cdp.wait_for(c, "Performance  ·  Sections", SESSION_WAIT), "typing finds the Performance section")
	check(l, cdp.key(c, "Enter") && cdp.wait_name(c, "cpu_graph", SESSION_WAIT), "Enter shows it")
	check(l, cdp.key(c, "ctrl+shift+p") && cdp.wait_name(c, "palette_field", SESSION_WAIT), "Ctrl+Shift+P opens it too")
	check(l, cdp.type_text(c, "zzqx") && cdp.wait_for(c, "Nothing matches", SESSION_WAIT), "a search that keeps nothing says so (no crash)")
	check(l, cdp.key(c, "Escape") && cdp.wait_name(c, "palette_field", SESSION_WAIT, gone = true), "Escape closes it")
	check(l, cdp.key(c, "F1") && cdp.wait_for(c, "Keyboard shortcuts", SESSION_WAIT), "F1 shows the keys")
	check(l, cdp.wait_for(c, "Suspend or resume", SESSION_WAIT) && cdp.wait_for(c, "Ctrl+K, Ctrl+Shift+P", SESSION_WAIT), "with every command's keys")
	check(l, cdp.key(c, "Escape") && cdp.wait_for(c, "Keyboard shortcuts", SESSION_WAIT, gone = true), "Escape closes them")
	check(l, cdp.key(c, "ctrl+Tab") && cdp.wait_name(c, "svc_start", SESSION_WAIT), "Ctrl+Tab: the next section, Services")
	check(l, cdp.key(c, "ctrl+shift+Tab") && cdp.wait_name(c, "cpu_graph", SESSION_WAIT), "Ctrl+Shift+Tab: back to Performance")
	check(l, cdp.key(c, "ctrl+2") && cdp.key(c, "ctrl+shift+c") && cdp.wait_for(c, "Default columns", SESSION_WAIT), "Ctrl+Shift+C in Processes: the columns' menu")
	check(l, cdp.key(c, "Escape") && cdp.wait_for(c, "Default columns", SESSION_WAIT, gone = true), "Escape closes the menu")
	// From the system's version, the key goes to the other one than the system shows: dark on a desktop in dark, light on
	// a runner that has no dark setting. Either is right; the second press must give the other.
	first := "light"
	pressed := cdp.key(c, "ctrl+shift+l")
	if pressed && !file_has(prefs, "view.mode\tlight") { first = "dark" }
	other := first == "light" ? "dark" : "light"
	check(l, pressed && file_has(prefs, fmt.tprintf("view.mode\t%s", first)), "Ctrl+Shift+L: the %s version, kept", first)
	check(l, cdp.key(c, "ctrl+shift+l") && file_has(prefs, fmt.tprintf("view.mode\t%s", other)), "again: the %s version", other)
	check(l, cdp.click_name(c, "theme") && cdp.wait_for(c, "As the system", SESSION_WAIT) && cdp.click_text(c, "As the system"), "back to the system's version")
	check(l, file_has(prefs, "view.mode\tsystem"), "kept")
}

// The install's dialog, at the first start of a copy that is not installed: Keep standalone closes it for good.
live_setup_offer :: proc(l: ^Live) {
	c := &l.c
	prefs := fmt.tprintf("%s/config/inspecteur/prefs", l.dir)
	check(l, cdp.wait_for(c, "Install Inspecteur", SESSION_WAIT), "the install's dialog shows at the first start")
	check(l, cdp.click_name(c, "setup_standalone") && cdp.wait_for(c, "Install Inspecteur", SESSION_WAIT, gone = true), "Keep standalone closes it")
	check(l, file_has(prefs, "setup.choice\tstandalone"), "it is not offered again")
}

// The install's dialog (Ctrl+Shift+I) installs Inspecteur in the session's own data folder: the program, its menu entry
// and its icons; Uninstall takes it all away. So do `inspecteur install` and `uninstall` in a folder of this test.
live_setup :: proc(l: ^Live) {
	c := &l.c
	data := fmt.tprintf("%s/data", l.dir)
	program := fmt.tprintf("%s/inspecteur/inspecteur", data)
	entry := fmt.tprintf("%s/applications/inspecteur.desktop", data)
	icon := fmt.tprintf("%s/icons/hicolor/64x64/apps/inspecteur.png", data)
	check(l, cdp.key(c, "ctrl+shift+i") && cdp.wait_for(c, "Install Inspecteur", SESSION_WAIT), "Ctrl+Shift+I: the install's dialog")
	check(l, cdp.click_name(c, "setup_install"), "Install")
	check(l, wait_present(program, SETUP_WAIT), "the program is copied: %s", program)
	check(l, wait_present(entry, SESSION_WAIT) && file_has(entry, "Categories=System;Monitor;") && file_has(entry, "[Desktop Action services]") && file_has(entry, "--section services"), "the menu entry, its category and its actions: %s", entry)
	check(l, os.exists(icon), "its icon: %s", icon)
	check(l, cdp.wait_for(c, "Uninstall", SESSION_WAIT), "the dialog offers Uninstall")
	check(l, cdp.click_name(c, "setup_uninstall") && cdp.wait_for(c, "Click again to uninstall", SESSION_WAIT), "Uninstall asks for a second click")
	check(l, cdp.click_name(c, "setup_uninstall"), "the second click")
	check(l, wait_missing(entry) && wait_missing(program) && !os.exists(icon), "the program, the entry and the icon are gone")
	check(l, cdp.key(c, "Escape") && cdp.wait_for(c, "Install Inspecteur", SESSION_WAIT, gone = true), "Escape closes the dialog")

	// the command line, in a data folder of this test
	cli := fmt.tprintf("%s/data-cli", l.dir)
	env := toolbox.env_with({"XDG_DATA_HOME"}, fmt.tprintf("XDG_DATA_HOME=%s", cli))
	run :: proc(args: []string, env: []string) -> int {
		cmd := make([dynamic]string, context.temp_allocator)
		append(&cmd, PROGRAM)
		append(&cmd, ..args)
		p, err := os.process_start({command = cmd[:], env = env})
		if err != nil { return -1 }
		st, werr := os.process_wait(p, SETUP_WAIT)
		return werr == nil && st.exited ? st.exit_code : -1
	}
	cli_entry := fmt.tprintf("%s/applications/inspecteur.desktop", cli)
	check(l, run({"status"}, env) == 1, "inspecteur status: not installed (1)")
	check(l, run({"install"}, env) == 0 && os.exists(cli_entry) && os.exists(fmt.tprintf("%s/inspecteur/inspecteur", cli)), "inspecteur install copies it and writes %s", cli_entry)
	check(l, run({"status"}, env) == 0, "status: installed (0)")
	check(l, run({"uninstall"}, env) == 0 && !os.exists(cli_entry), "inspecteur uninstall takes it away")
}

// The settings (Ctrl+,): the preferences' page in place of the sections; a switch there changes a preference, kept;
// Escape goes back.
live_settings :: proc(l: ^Live) {
	c := &l.c
	prefs := fmt.tprintf("%s/config/inspecteur/prefs", l.dir)
	check(l, cdp.key(c, "ctrl+,") && cdp.wait_for(c, "Appearance", SESSION_WAIT) && cdp.wait_for(c, "Updates", SESSION_WAIT), "Ctrl+,: the settings, their pages")
	// a theme's card: the window takes its colours at once
	before := page_pixel(c)
	check(l, cdp.click_name(c, "th0") && file_has(prefs, "view.theme\tMidnight"), "the first theme's card: Midnight, kept")
	check(l, wait_page_pixel_not(c, before), "the window takes its colours at once")
	check(l, cdp.click_name(c, "th1") && file_has(prefs, "view.theme\tGraphite"), "back to Graphite")
	check(l, cdp.key(c, "ctrl+f") && cdp.type_text(c, "rules") && cdp.wait_for(c, "Draw a thin line under each row of the tables.", SESSION_WAIT), "a search finds a preference")
	check(l, cdp.click_name(c, "sw") && file_has(prefs, "view.rules\tfalse"), "its switch changes it, kept")
	check(l, cdp.click_name(c, "sw") && file_has(prefs, "view.rules\ttrue"), "and back")
	check(l, cdp.key(c, "Escape") && cdp.wait_name(c, "settings_button", SESSION_WAIT) && cdp.wait_for(c, "Draw a thin line", SESSION_WAIT, gone = true), "Escape goes back to the sections")
}

// Mission Control (Ctrl+1): its panels; one closed from its menu, brought back; the layout as at first, kept.
live_mission :: proc(l: ^Live) {
	c := &l.c
	prefs := fmt.tprintf("%s/config/inspecteur/prefs", l.dir)
	check(l, cdp.key(c, "ctrl+1") && cdp.wait_name(c, "mc_machine", SESSION_WAIT) && cdp.wait_name(c, "mc_health", SESSION_WAIT) && cdp.wait_name(c, "mc_cpu", SESSION_WAIT), "Ctrl+1: Mission Control, its panels")
	check(l, cdp.wait_name(c, "mc_cpu_0", SESSION_WAIT), "the busiest processes are listed")
	check(l, cdp.click_name(c, "mission_panels") && cdp.wait_for(c, "Busiest: memory", SESSION_WAIT), "the panels' menu")
	// (the menu's line, not the tab of the same name: the menu is built after the panels)
	_, menu_ok := cdp.call(c, "Toolkit.click", `{"text":"Busiest: memory","index":1}`)
	check(l, menu_ok && cdp.wait_name(c, "mc_memory", SESSION_WAIT, gone = true) && file_has(prefs, "mission.layout"), "a panel closed, the layout kept")
	check(l, cdp.click_name(c, "mission_reset") && cdp.wait_name(c, "mc_memory", SESSION_WAIT), "the layout as at first brings it back")
	// a panel in a window of its own (its tab's menu): out of the dock, kept; the window closed, it comes back
	_, tab_menu := cdp.call(c, "Toolkit.click", fmt.tprintf(`{{"name":"dock_tab_%d","index":0,"count":1,"button":"right"}}`, 2))
	check(l, tab_menu && cdp.wait_for(c, "Open in a window", SESSION_WAIT) && cdp.click_text(c, "Open in a window"), "a panel's menu: Open in a window")
	check(l, wait_sway_title(l, "Health", true) && cdp.wait_name(c, "mc_health", SESSION_WAIT, gone = true), "Health in a window of its own, out of the dock")
	check(l, file_has(prefs, "mission.windows\thealth"), "the window is kept")
	check(l, sway_command(l, `[title="Health"] kill`) && wait_sway_title(l, "Health", false) && cdp.wait_name(c, "mc_health", SESSION_WAIT), "its window closed, Health is back in Mission Control")
	// a line's menu (a right click), its first item: the process in Processes; then a click on the line's middle (its name)
	_, right_ok := cdp.call(c, "Toolkit.click", `{"name":"mc_cpu_0","index":0,"count":1,"button":"right"}`)
	check(l, right_ok && cdp.wait_for(c, "Show in Processes", SESSION_WAIT) && cdp.wait_for(c, "Show its connections", SESSION_WAIT), "a line's right click: its menu")
	check(l, cdp.click_text(c, "Show in Processes") && cdp.wait_for(c, "Background processes", SESSION_WAIT), "the menu shows the process in Processes")
	check(l, cdp.key(c, "ctrl+1") && cdp.wait_name(c, "mc_cpu_0", SESSION_WAIT) && cdp.click_name(c, "mc_cpu_0") && cdp.wait_for(c, "Background processes", SESSION_WAIT), "a click on a line's name goes to its section")
	check(l, cdp.key(c, "ctrl+2") && cdp.wait_for(c, "Background processes", SESSION_WAIT), "Ctrl+2: Processes")
}

// One Inspecteur at a time: a second start with --section hands it to this one, which shows it, and ends.
live_one_copy :: proc(l: ^Live) {
	c := &l.c
	p, err := os.process_start({command = {PROGRAM, "--section", "startup"}, env = l.session.env})
	if !check(l, err == nil, "a second start, --section startup") { return }
	st, werr := os.process_wait(p, SESSION_WAIT)
	check(l, werr == nil && st.exited && st.exit_code == 0, "it ends at once, handed over (%v)", st.exit_code)
	check(l, cdp.wait_for(c, "File", SESSION_WAIT) && cdp.wait_for(c, "Status", SESSION_WAIT), "this one shows Startup (its columns File and Status)")
	check(l, cdp.key(c, "ctrl+2") && cdp.wait_for(c, "Background processes", SESSION_WAIT), "Ctrl+2: back to Processes")
}

// The colour of the page's background (a pixel of the window's corner, under the title bar).
@(private = "file")
page_pixel :: proc(c: ^cdp.Client) -> u32 {
	png, ok := cdp.screenshot(c, cdp.Clip{4, 120, 1, 1}, context.temp_allocator)
	if !ok { return 0 }
	pic, dok := cdp.png_decode(png, context.temp_allocator)
	if !dok || len(pic.pixels) < 3 { return 0 }
	return u32(pic.pixels[0]) << 16 | u32(pic.pixels[1]) << 8 | u32(pic.pixels[2])
}

@(private = "file")
wait_page_pixel_not :: proc(c: ^cdp.Client, before: u32) -> bool {
	deadline := time.tick_add(time.tick_now(), SESSION_WAIT)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		if page_pixel(c) != before { return true }
		time.sleep(SESSION_POLL)
	}
	return false
}

// Selects the row whose PID cell says `pid` (clicked: the list gets the keyboard) and checks that the row selected, as
// the accessibility tree says, is `name`.
select_named :: proc(l: ^Live, pid, name: string) -> bool {
	c := &l.c
	time.sleep(DOUBLE_CLICK_GAP)
	at := wait_pid_cell(c, pid)
	if !check(l, at >= 0, "its PID cell is in view") { return false }
	_, ok := cdp.call(c, "Toolkit.click", fmt.tprintf(`{{"name":"c1","index":%d}}`, at))
	cdp.wait_idle(c, SESSION_WAIT)
	got := selected_row_name(c)
	return check(l, ok && got == name, "the row selected is %s (%q)", name, got)
}

// The pid of the process whose command line holds `mark`, once there is one (0: none came).
wait_mark :: proc(mark: string) -> int {
	deadline := time.tick_add(time.tick_now(), SESSION_WAIT)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		fis, _ := os.read_all_directory_by_path("/proc", context.temp_allocator)
		for fi in fis {
			pid, ok := strconv.parse_int(fi.name, 10)
			if ok && has_mark(pid, mark) { return pid }
		}
		time.sleep(SESSION_POLL)
	}
	return 0
}

// Whether the process `pid` is `sleep <mark>` (its arguments exactly: a shell that starts it has the mark in its own).
has_mark :: proc(pid: int, mark: string) -> bool {
	data, err := os.read_entire_file(fmt.tprintf("/proc/%d/cmdline", pid), context.temp_allocator)
	if err != nil { return false }
	args := strings.split(strings.trim_right(string(data), "\x00"), "\x00", context.temp_allocator)
	return len(args) == 2 && strings.has_suffix(args[0], "sleep") && args[1] == mark
}

// The process `pid` with `mark` is gone (its pid ended, or names another process now).
wait_gone :: proc(pid: int, mark: string) -> bool {
	deadline := time.tick_add(time.tick_now(), SESSION_WAIT)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		if !has_mark(pid, mark) { return true }
		time.sleep(SESSION_POLL)
	}
	return false
}

// A setup's install copies the program and, on NixOS, builds the profile of its libraries (nix-build).
SETUP_WAIT :: 120 * time.Second

@(private = "file")
wait_present :: proc(path: string, limit: time.Duration) -> bool {
	deadline := time.tick_add(time.tick_now(), limit)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		if os.exists(path) { return true }
		time.sleep(SESSION_POLL)
	}
	return false
}

@(private = "file")
wait_missing :: proc(path: string) -> bool {
	deadline := time.tick_add(time.tick_now(), SESSION_WAIT)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		if !os.exists(path) { return true }
		time.sleep(SESSION_POLL)
	}
	return false
}

// The processes of the cgroup of `pid` (cgroup v2), when that cgroup is the scope `unit`; none otherwise.
@(private = "file")
scope_pids :: proc(pid: int, unit: string) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	data, err := os.read_entire_file(fmt.tprintf("/proc/%d/cgroup", pid), context.temp_allocator)
	if err != nil { return out[:] }
	line := strings.trim_space(string(data))
	if !strings.has_prefix(line, "0::") || !strings.has_suffix(line, fmt.tprintf("/%s", unit)) { return out[:] }
	procs, perr := os.read_entire_file(fmt.tprintf("/sys/fs/cgroup%s/cgroup.procs", line[3:]), context.temp_allocator)
	if perr != nil { return out[:] }
	rest := string(procs)
	for word in strings.fields_iterator(&rest) {
		if v, ok := strconv.parse_int(word, 10); ok { append(&out, v) }
	}
	return out[:]
}
