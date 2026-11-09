package inspecteurtool

// live: the real program against a real compositor that nobody sees (session.odin), driven over the DevTools protocol
// as a person would: the rows are there, a search finds one process, a header sorts and sorts back, the row's menu, the
// tabs, then End task and Kill on processes this test started itself (`sleep` with a mark of its own in its command
// line, searched for, and checked by its pid before any key is pressed). Each wait is for a condition, with a bound.
//
//   inspecteurtool live [--keep]     (--keep: build/live stays, with the logs and the window's pictures)

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import cdp "gt:cdp"

LIVE_DIR  :: "build/live"
LIVE_PORT :: 9371
SCREENSHOT :: "docs/screenshots/processes.png"

@(private = "file")
Live :: struct {
	using session: Session,
	c:             cdp.Client,
	failures:      int,
	checks:        int,
}

@(private = "file")
check :: proc(l: ^Live, ok: bool, what: string, args: ..any) -> bool {
	l.checks += 1
	msg := fmt.tprintf(what, ..args)
	if ok { fmt.printfln("  ok    %s", msg) } else { l.failures += 1; fmt.printfln("  FAIL  %s", msg) }
	return ok
}

run_live :: proc(args: []string) -> int {
	keep := len(args) > 0 && args[0] == "--keep"
	if run_build(nil) != 0 { return 1 }
	l: Live
	if why := session_start(&l.session, LIVE_DIR, LIVE_PORT); why != "" {
		fmt.eprintfln("inspecteurtool live: %s", why)
		session_stop(&l.session)
		return 1
	}
	dir := strings.clone(l.dir, context.temp_allocator)
	output := strings.clone(l.output, context.temp_allocator)
	fmt.printfln("live: inspecteur runs in a headless sway (%s)", dir)
	ok: bool
	l.c, ok = window_connect(&l.session)
	if check(&l, ok, "the window serves the DevTools protocol") {
		live_window(&l)
		cdp.close(&l.c)
	}
	code := session_stop(&l.session)
	check(&l, code == 0, "inspecteur closed: it ends, with 0 (%d)", code)
	log, _ := os.read_entire_file(output, context.temp_allocator)
	check(&l, !strings.contains(string(log), "error"), "inspecteur wrote no error (%s)", output)
	fmt.printfln("live: %d checks, %d failed", l.checks, l.failures)
	if !keep && l.failures == 0 { _ = os.remove_all(dir) }
	return l.failures == 0 ? 0 : 1
}

@(private = "file")
live_window :: proc(l: ^Live) {
	c := &l.c
	check(l, cdp.wait_for(c, "Background processes", SESSION_WAIT), "the table has its sections")
	pids := column_numbers(c, "c1")
	check(l, len(pids) >= 10, "the table has rows (%d in view)", len(pids))
	check(l, cdp.wait_for(c, "processes", SESSION_WAIT), "the header counts the processes")

	// sorting: PID from the lowest, then from the highest (in each section: at most one turn between the two)
	check(l, cdp.click_name(c, "hd_1"), "click the PID header")
	cdp.wait_idle(c, SESSION_WAIT)
	up := column_numbers(c, "c1")
	check(l, turns(up, ascending = true) <= 1, "the rows go by PID, lowest first (%d turns)", turns(up, true))
	check(l, cdp.click_name(c, "hd_1"), "click it again")
	cdp.wait_idle(c, SESSION_WAIT)
	down := column_numbers(c, "c1")
	check(l, turns(down, ascending = false) <= 1, "the rows go by PID, highest first (%d turns)", turns(down, false))

	// the tabs
	check(l, cdp.click_text(c, "Performance"), "click the Performance tab")
	check(l, cdp.wait_for(c, "comes in a later version", SESSION_WAIT), "it says what it will be")
	check(l, cdp.click_text(c, "Processes"), "back to Processes")
	check(l, cdp.wait_for(c, "Background processes", SESSION_WAIT), "the table is back")

	// a process of this test: found by the search, its menu, End task
	child, mark, started := start_child("1")
	if !check(l, started, "start sleep %s, a child of this test", mark) { return }
	pid := fmt.tprintf("%d", child.pid)
	check(l, cdp.type_text(c, mark), "type its mark")
	check(l, cdp.wait_for(c, fmt.tprintf("Selected: sleep, PID %s", pid), SESSION_WAIT), "the search selects it (PID %s)", pid)
	shown := column_numbers(c, "c1")
	check(l, len(shown) >= 1 && len(shown) <= 2 && contains_int(shown, child.pid), "the search leaves the other processes out (%v)", shown)
	// (the PID cell of its row, by the cells' name and its place among them: its text could be inside the mark)
	at := -1
	for b, i in cdp.find_name(c, "c1") { if b.text == pid { at = i } }
	_, mok := cdp.call(c, "Toolkit.click", fmt.tprintf(`{{"name":"c1","index":%d,"button":"right"}}`, max(at, 0)))
	check(l, at >= 0 && mok && cdp.wait_for(c, "Copy command line", SESSION_WAIT), "a right click on its row opens the row's menu")
	check(l, cdp.key(c, "Escape") && cdp.wait_for(c, "Copy command line", SESSION_WAIT, gone = true), "Escape closes it")
	check(l, cdp.wait_for(c, fmt.tprintf("Selected: sleep, PID %s", pid), SESSION_WAIT), "it is still the one selected")
	check(l, cdp.key(c, "Delete"), "Delete")
	state, err := os.process_wait(child, SESSION_WAIT)
	check(l, err == nil && state.exited && state.exit_code == 15, "it ends by SIGTERM (exited %v, code %d)", state.exited, state.exit_code)
	if err != nil || !state.exited { _ = os.process_kill(child); _, _ = os.process_wait(child, SESSION_WAIT) }
	check(l, cdp.wait_for(c, fmt.tprintf("PID %s", pid), SESSION_WAIT, gone = true), "its row goes")

	// another one: Shift+Delete asks, Kill kills
	check(l, cdp.key(c, "Escape"), "Escape clears the search")
	child2, mark2, started2 := start_child("2")
	if !check(l, started2, "start sleep %s", mark2) { return }
	pid2 := fmt.tprintf("%d", child2.pid)
	check(l, cdp.type_text(c, mark2), "type its mark")
	check(l, cdp.wait_for(c, fmt.tprintf("Selected: sleep, PID %s", pid2), SESSION_WAIT), "the search selects it (PID %s)", pid2)
	check(l, cdp.key(c, "shift+Delete"), "Shift+Delete")
	check(l, cdp.wait_for(c, fmt.tprintf("Kill sleep (PID %s)?", pid2), SESSION_WAIT), "the kill is asked first")
	check(l, cdp.click_name(c, "kill_confirm"), "click Kill")
	state2, err2 := os.process_wait(child2, SESSION_WAIT)
	check(l, err2 == nil && state2.exited && state2.exit_code == 9, "it ends by SIGKILL (exited %v, code %d)", state2.exited, state2.exit_code)
	if err2 != nil || !state2.exited { _ = os.process_kill(child2); _, _ = os.process_wait(child2, SESSION_WAIT) }

	// the picture: every process, the busiest first
	check(l, cdp.key(c, "Escape"), "Escape clears the search")
	check(l, cdp.click_name(c, "hd_3"), "sort by CPU")
	cdp.wait_for(c, "Background processes", SESSION_WAIT)
	time.sleep(1500 * time.Millisecond)   // (two samples: every row has its CPU %)
	cdp.wait_idle(c, SESSION_WAIT)
	_ = os.make_directory_all("docs/screenshots")
	check(l, cdp.shot(c, SCREENSHOT), "a picture of the window: %s", SCREENSHOT)
	cdp.wait_idle(c, SESSION_WAIT)
	check(l, cdp.shot(c, fmt.tprintf("%s/window.png", l.dir)), "and one in %s", l.dir)
}

// `sleep` with a mark in its command line that no other process has: this test's pid and `n`.
@(private = "file")
start_child :: proc(n: string) -> (p: os.Process, mark: string, ok: bool) {
	mark = fmt.tprintf("300.%d%s", os.get_pid(), n)
	child, err := os.process_start({command = {"sleep", mark}})
	return child, mark, err == nil
}

// The numbers of a column's cells in view, top to bottom (the boxes named `name`).
@(private = "file")
column_numbers :: proc(c: ^cdp.Client, name: string) -> []int {
	boxes := cdp.find_name(c, name)
	out := make([dynamic]int, context.temp_allocator)
	for b in boxes {
		if n, ok := strconv.parse_int(b.text, 10); ok { append(&out, n) }
	}
	return out[:]
}

// How many times a list turns against the order.
@(private = "file")
turns :: proc(xs: []int, ascending: bool) -> int {
	n := 0
	for i in 1 ..< len(xs) {
		if ascending && xs[i] < xs[i - 1] { n += 1 }
		if !ascending && xs[i] > xs[i - 1] { n += 1 }
	}
	return n
}

@(private = "file")
contains_int :: proc(xs: []int, x: int) -> bool {
	for v in xs { if v == x { return true } }
	return false
}
