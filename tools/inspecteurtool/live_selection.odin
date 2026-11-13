package inspecteurtool

// live's checks of the selection of many rows (Ctrl clicks, the kill of the rows marked), of End process tree, of the
// window's keys that change no process (the refresh paused, the text size, the tree), and of a process's affinity and
// dump. As everywhere in live: a key that acts on processes is pressed only once the test has checked that what it acts
// on is its own (its rows, the confirmation's list of the processes).

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"
import cdp "gt:cdp"

// Two sleeps of this test: a click on the first, a Ctrl click on the second, Shift+Delete. The confirmation lists the
// two of them and nothing else; Kill ends both.
live_marks :: proc(l: ^Live) {
	c := &l.c
	a, mark_a, ok_a := start_child("51")
	b, mark_b, ok_b := start_child("52")
	if !check(l, ok_a && ok_b, "two sleeps of this test, %s and %s", mark_a, mark_b) { return }
	reaped_a, reaped_b := false, false
	defer {
		if !reaped_a { _ = os.process_kill(a); _, _ = os.process_wait(a, SESSION_WAIT) }
		if !reaped_b { _ = os.process_kill(b); _, _ = os.process_wait(b, SESSION_WAIT) }
	}
	pa, pb := fmt.tprintf("%d", a.pid), fmt.tprintf("%d", b.pid)
	common := mark_a[:len(mark_a) - 1]   // (both marks begin with it)
	check(l, cdp.key(c, "Escape") && cdp.type_text(c, common), "filter by their marks' start")
	check(l, cdp.wait_for(c, fmt.tprintf("sleep, PID %s", pa), SESSION_WAIT) || pid_cell(c, pa) >= 0, "the first is listed")
	if !select_child(l, pa) { return }
	at := pid_cell(c, pb)
	if !check(l, at >= 0, "the second is in view") { return }
	time.sleep(DOUBLE_CLICK_GAP)
	_, ok := cdp.call(c, "Toolkit.click", fmt.tprintf(`{{"name":"c1","index":%d,"modifiers":2}}`, at))
	check(l, ok && cdp.wait_for(c, "Selected: 2 rows", SESSION_WAIT), "a Ctrl click marks it too: 2 rows (%q)", footer(c))
	if !check(l, cdp.key(c, "shift+Delete") && cdp.wait_for(c, "Kill 2 processes?", SESSION_WAIT), "Shift+Delete asks to kill 2 processes") { return }
	lines := [2]string{line_text(c, 0), line_text(c, 1)}
	want := [2]string{fmt.tprintf("sleep, PID %s", pa), fmt.tprintf("sleep, PID %s", pb)}
	mine := (lines == want || lines == [2]string{want[1], want[0]}) && len(cdp.find_name(c, "confirm_line_2")) == 0
	if !check(l, mine, "it lists the two of them and nothing else (%v)", lines) { cdp.key(c, "Escape"); return }
	if !check(l, cdp.click_name(c, "confirm_act"), "click Kill") { return }
	sa, ea := os.process_wait(a, SESSION_WAIT)
	sb, eb := os.process_wait(b, SESSION_WAIT)
	reaped_a, reaped_b = ea == nil && sa.exited, eb == nil && sb.exited
	check(l, reaped_a && reaped_b && sa.exit_code == 9 && sb.exit_code == 9, "both end by SIGKILL (%d, %d)", sa.exit_code, sb.exit_code)
	check(l, cdp.key(c, "Escape"), "Escape clears the filter")
}

// A shell of this test with two sleeps under it: End process tree on the shell lists the three, and ends them.
live_end_tree :: proc(l: ^Live) {
	c := &l.c
	mark := fmt.tprintf("300.%d6", os.get_pid())
	mark_a, mark_b := fmt.tprintf("%s1", mark), fmt.tprintf("%s2", mark)
	sh, err := os.process_start({command = {"sh", "-c", fmt.tprintf("sleep %s & sleep %s & wait", mark_a, mark_b)}})
	if !check(l, err == nil, "a shell of this test and two sleeps under it") { return }
	reaped := false
	pid_a, pid_b := 0, 0
	defer {
		if !reaped { _ = os.process_kill(sh); _, _ = os.process_wait(sh, SESSION_WAIT) }
		for p in ([2][2]int{{pid_a, 0}, {pid_b, 1}}) {
			m := p[1] == 0 ? mark_a : mark_b
			if p[0] > 0 && has_mark(p[0], m) { _ = linux.kill(linux.Pid(p[0]), .SIGKILL) }
		}
	}
	pid_a, pid_b = wait_mark(mark_a), wait_mark(mark_b)
	if !check(l, pid_a > 0 && pid_b > 0, "both sleeps run (%d, %d)", pid_a, pid_b) { return }
	ps := fmt.tprintf("%d", sh.pid)
	check(l, cdp.key(c, "Escape") && cdp.type_text(c, ps), "filter by the shell's PID, %s", ps)
	if !select_named(l, ps, fmt.tprintf("sh, PID %s", ps)) { return }
	if !check(l, cdp.key(c, "ctrl+Delete") && cdp.wait_for(c, fmt.tprintf("End sh (PID %s) and 2 processes under it?", ps), SESSION_WAIT), "Ctrl+Delete asks to end the shell and the 2 under it") { return }
	got := [3]string{line_text(c, 0), line_text(c, 1), line_text(c, 2)}
	want := []string{fmt.tprintf("sleep, PID %d", pid_a), fmt.tprintf("sleep, PID %d", pid_b), fmt.tprintf("sh, PID %s", ps)}
	mine := len(cdp.find_name(c, "confirm_line_3")) == 0
	for w in want { if !(got[0] == w || got[1] == w || got[2] == w) { mine = false } }
	if !check(l, mine, "it lists those three and nothing else (%v)", got) { cdp.key(c, "Escape"); return }
	if !check(l, cdp.click_name(c, "confirm_act"), "click End tree") { return }
	state, werr := os.process_wait(sh, SESSION_WAIT)
	reaped = werr == nil && state.exited
	check(l, reaped, "the shell ends (code %d)", state.exit_code)
	check(l, wait_gone(pid_a, mark_a) && wait_gone(pid_b, mark_b), "and both sleeps")
	check(l, cdp.key(c, "Escape"), "Escape clears the filter")
}

// The keys that change no process: the refresh paused and resumed, the text size, the tree; each kept or said.
live_view_keys :: proc(l: ^Live) {
	c := &l.c
	prefs := fmt.tprintf("%s/config/inspecteur/prefs", l.dir)
	check(l, cdp.key(c, "Escape") && cdp.key(c, "ctrl+2"), "the Processes section")
	check(l, cdp.key(c, "ctrl+space") && cdp.wait_for(c, "Refresh paused", SESSION_WAIT), "Ctrl+Space pauses the refresh")
	check(l, cdp.wait_for(c, "Paused", SESSION_WAIT), "the footer says Paused")
	check(l, cdp.key(c, "ctrl+space") && cdp.wait_for(c, "Refresh every 1 s", SESSION_WAIT), "Ctrl+Space again resumes it")
	check(l, cdp.key(c, "ctrl+shift+r") && cdp.wait_for(c, "Refresh every", SESSION_WAIT) && cdp.click_text(c, "Low: 2 s"), "the refresh menu: every 2 s")
	check(l, file_has(prefs, "processes.refresh_ms\t2000"), "kept")
	check(l, cdp.key(c, "ctrl+shift+r") && cdp.wait_for(c, "Normal: 1 s", SESSION_WAIT) && cdp.click_text(c, "Normal: 1 s"), "back to every second")
	check(l, file_has(prefs, "processes.refresh_ms\t1000"), "kept")
	check(l, cdp.key(c, "ctrl+=") && file_has(prefs, "view.zoom\t1.1"), "Ctrl+=: zoomed in, kept")
	check(l, cdp.key(c, "ctrl+0") && file_has(prefs, "view.zoom\t1\n"), "Ctrl+0: 100 %% again")
	check(l, cdp.key(c, "ctrl+t") && cdp.wait_for(c, "as a tree", SESSION_WAIT) && file_has(prefs, "processes.view\ttree"), "Ctrl+T: every process under its parent, kept")
	check(l, cdp.key(c, "ctrl+t") && cdp.wait_for(c, "Background processes", SESSION_WAIT) && file_has(prefs, "processes.view\tapps"), "Ctrl+T again: the apps")
}

// A sleep of this test: its affinity narrowed to processor 0 (the kernel says so), and a dump of it asked (written in
// the session's cache, or the footer says why not: gdb's gcore, the kernel's ptrace rules).
live_affinity_dump :: proc(l: ^Live) {
	c := &l.c
	child, mark, started := start_child("7")
	if !check(l, started, "start sleep %s", mark) { return }
	defer { _ = os.process_kill(child); _, _ = os.process_wait(child, SESSION_WAIT) }
	pid := fmt.tprintf("%d", child.pid)
	check(l, cdp.key(c, "Escape") && cdp.type_text(c, mark), "type its mark")
	check(l, cdp.wait_for(c, fmt.tprintf("Selected: sleep, PID %s", pid), SESSION_WAIT), "it is selected")
	if !select_child(l, pid) { return }
	if !check(l, cdp.key(c, "ctrl+shift+a") && cdp.wait_name(c, "affinity_apply", SESSION_WAIT), "Ctrl+Shift+A: its affinity") { return }
	check(l, cdp.wait_for(c, fmt.tprintf("Affinity of sleep (PID %s)", pid), SESSION_WAIT), "of the test's child")
	check(l, cdp.click_name(c, "affinity_none") && cdp.click_name(c, "cpu_0"), "processor 0 alone")
	if !check(l, cdp.click_name(c, "affinity_apply"), "Apply") { return }
	check(l, wait_allowed(child.pid, "0"), "the kernel lets it run on processor 0 alone")

	if !select_child(l, pid) { return }
	if !check(l, cdp.key(c, "ctrl+shift+d") && cdp.wait_for(c, fmt.tprintf("Create a dump file of sleep (PID %s)?", pid), SESSION_WAIT), "Ctrl+Shift+D asks first") { return }
	if !check(l, cdp.click_name(c, "confirm_act"), "Create") { return }
	deadline := time.tick_add(time.tick_now(), 4 * SESSION_WAIT)
	said := ""
	for time.tick_diff(time.tick_now(), deadline) > 0 && said == "" {
		f := footer(c)
		if strings.has_prefix(f, "Wrote the dump") || strings.has_prefix(f, "No dump:") { said = f }
		time.sleep(SESSION_POLL)
	}
	dumps := fmt.tprintf("%s/cache/inspecteur/dumps", l.dir)
	if strings.has_prefix(said, "Wrote the dump") {
		check(l, strings.contains(said, dumps), "the dump is in the session's cache (%q)", said)
	} else {
		check(l, said != "", "the footer says why there is no dump (%q)", said)
	}
	check(l, cdp.key(c, "Escape"), "Escape clears the filter")
}

// The text of the confirmation's line `i` ("" when there is none).
@(private = "file")
line_text :: proc(c: ^cdp.Client, i: int) -> string {
	boxes := cdp.find_name(c, fmt.tprintf("confirm_line_%d", i))
	return len(boxes) > 0 ? boxes[0].text : ""
}

// /proc/<pid>/status's Cpus_allowed_list becomes `want`.
@(private = "file")
wait_allowed :: proc(pid: int, want: string) -> bool {
	deadline := time.tick_add(time.tick_now(), SESSION_WAIT)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		data, _ := os.read_entire_file(fmt.tprintf("/proc/%d/status", pid), context.temp_allocator)
		rest := string(data)
		for line in strings.split_lines_iterator(&rest) {
			if strings.has_prefix(line, "Cpus_allowed_list:") && strings.trim_space(line[len("Cpus_allowed_list:"):]) == want { return true }
		}
		time.sleep(SESSION_POLL)
	}
	return false
}

// Alt+P pins the test's own child: a Pinned section above the others shows it, the preference keeps its name; Alt+P
// again unpins it. Nothing is signalled. The child is a background process, or a process of the app whose scope the
// test runs in (a terminal's, on a desktop): then its app is pinned. The name is read from the preference, and the
// window must say that one.
live_pin :: proc(l: ^Live) {
	c := &l.c
	prefs := fmt.tprintf("%s/config/inspecteur/prefs", l.dir)
	child, mark, started := start_child("8")
	if !check(l, started, "a child to pin (%s)", mark) { return }
	defer {
		_ = os.process_kill(child)
		_, _ = os.process_wait(child, SESSION_WAIT)
	}
	pid := fmt.tprintf("%d", child.pid)
	check(l, cdp.key(c, "Escape") && cdp.type_text(c, mark), "filter by its mark")
	listed := false
	deadline := time.tick_add(time.tick_now(), READER_WAIT)
	for !listed && time.tick_diff(time.tick_now(), deadline) > 0 {
		listed = pid_cell(c, pid) >= 0
		if !listed { time.sleep(SESSION_POLL) }
	}
	if !check(l, listed, "it is listed") { _ = cdp.key(c, "Escape"); return }
	if !select_child(l, pid) { _ = cdp.key(c, "Escape"); return }
	check(l, cdp.key(c, "alt+p") && cdp.wait_for(c, "Pinned (1)", SESSION_WAIT), "Alt+P pins it: a Pinned section")
	name := pref_line(prefs, "processes.pinned")
	check(l, name != "" && cdp.wait_for(c, fmt.tprintf("%s is pinned over the others", name), SESSION_WAIT), "the preference keeps its name, the one the window says (%q)", name)
	check(l, cdp.key(c, "alt+p") && cdp.wait_for(c, "Pinned (1)", SESSION_WAIT, gone = true), "Alt+P again unpins it")
	check(l, cdp.key(c, "Escape"), "Escape clears the filter")
}

// F2: "Why is it slow?", at least one finding; Escape closes it.
live_diagnosis :: proc(l: ^Live) {
	c := &l.c
	check(l, cdp.key(c, "F2") && cdp.wait_for(c, "Why is it slow?", SESSION_WAIT), "F2: Why is it slow?")
	check(l, cdp.wait_name(c, "diag_text0", SESSION_WAIT), "it says at least one thing")
	check(l, cdp.key(c, "Escape") && cdp.wait_for(c, "Why is it slow?", SESSION_WAIT, gone = true), "Escape closes it")
}
