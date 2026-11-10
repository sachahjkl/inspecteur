package inspecteurtool

// live's checks of the Performance section, the table's columns, the theme's menu and the Properties dialog (live.odin
// runs them). A graph is checked by its pixels: drawn, it holds colours other than its background, its grid and its
// frame.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:time"
import cdp "gt:cdp"

// The share of a graph's pixels that are not one of its three commonest colours (its background, grid and frame), at
// least, for it to count as drawn; how far a colour may be from them and still be one of them.
GRAPH_DRAWN_SHARE :: 0.01
GRAPH_COLOR_SLACK :: 12
// The Performance section's graphs get some points first.
PERF_POINTS_WAIT :: 8 * time.Second
// How often a graph's pixels are read again while they are waited for (a picture of the window each time).
GRAPH_POLL :: 250 * time.Millisecond
// The busy children end by themselves after this many seconds, whatever becomes of this tool.
BUSY_SECONDS :: "30"

live_performance :: proc(l: ^Live) {
	c := &l.c
	// A machine at rest draws its CPU graphs as a line along the bottom, which a check by pixels cannot tell from an
	// empty graph. One busy child per logical processor, this test's own, gives every graph some area to draw.
	// Each runs under `timeout`, so that it ends even when this tool does not live to end it; SIGTERM to `timeout` ends
	// its loop too (SIGKILL would leave the loop running without it).
	busy := make([dynamic]os.Process, context.temp_allocator)
	for _ in 0 ..< logical_processors() {
		if child, err := os.process_start({command = {"timeout", BUSY_SECONDS, "sh", "-c", "while :; do :; done"}}); err == nil {
			append(&busy, child)
		}
	}
	defer for child in busy {
		_ = linux.kill(linux.Pid(child.pid), .SIGTERM)
		if _, err := os.process_wait(child, SESSION_WAIT); err != nil {
			_ = os.process_kill(child)
			_, _ = os.process_wait(child, SESSION_WAIT)
		}
	}
	check(l, len(busy) == logical_processors(), "%d busy children to draw against", len(busy))

	check(l, cdp.click_text(c, "Performance"), "click the Performance section")
	check(l, cdp.wait_name(c, "cpu_graph", SESSION_WAIT), "the CPU's graph is there")
	share := wait_drawn(c, "cpu_graph")
	check(l, share > GRAPH_DRAWN_SHARE, "the CPU's graph is drawn (%.1f%% of its pixels)", share * 100)
	check(l, cdp.wait_for(c, "Logical processors", SESSION_WAIT), "it counts the logical processors")

	// one graph per logical processor
	cores := logical_processors()
	check(l, cdp.click_text(c, "Logical processors"), "the per-processor view")
	check(l, cdp.wait_name(c, fmt.tprintf("core_%d", cores - 1), SESSION_WAIT), "a graph for each of the %d logical processors", cores)
	check(l, !cdp.wait_name(c, fmt.tprintf("core_%d", cores), 300 * time.Millisecond), "and no more")
	share = wait_drawn(c, "core_0")
	check(l, share > GRAPH_DRAWN_SHARE, "the first processor's graph is drawn (%.1f%%)", share * 100)
	check(l, cdp.click_text(c, "Overall"), "back to one graph")
	check(l, cdp.wait_name(c, "cpu_graph", SESSION_WAIT), "it is back")

	// the memory
	check(l, cdp.click_name(c, "dev_1_0"), "click Memory in the devices")
	check(l, cdp.wait_name(c, "memory_graph", SESSION_WAIT), "the memory's graph is there")
	check(l, cdp.wait_for(c, "Memory composition", SESSION_WAIT), "and its composition")
	share = wait_drawn(c, "memory_graph")
	check(l, share > GRAPH_DRAWN_SHARE, "the memory's graph is drawn (%.1f%%)", share * 100)

	// the other devices' pages, when the machine has them (Down goes from a device to the next)
	pages := [?]struct { device, graph, what: string }{
		{"dev_2_0", "disk_active", "a disk's active time"}, {"dev_3_0", "net_rate", "an interface's throughput"}, {"dev_4_0", "", "a GPU's page"},
	}
	for p in pages {
		if len(cdp.find_name(c, p.device)) == 0 { check(l, true, "no %s here: skipped", p.what); continue }
		check(l, cdp.click_name(c, p.device), "click %s", p.device)
		if p.graph != "" {
			check(l, cdp.wait_name(c, p.graph, SESSION_WAIT), "%s: its graph is there", p.what)
		} else {
			check(l, cdp.wait_for(c, "GPU 0", SESSION_WAIT), "%s: its title", p.what)
		}
	}
	check(l, cdp.click_name(c, "dev_0_0") && cdp.wait_name(c, "cpu_graph", SESSION_WAIT), "back to the CPU")
	check(l, cdp.key(c, "ArrowDown") && cdp.wait_name(c, "memory_graph", SESSION_WAIT), "Down: the next device, the memory")
	check(l, cdp.key(c, "ArrowUp") && cdp.wait_name(c, "cpu_graph", SESSION_WAIT), "Up: back to the CPU")
	check(l, cdp.key(c, "ctrl+g") && cdp.wait_name(c, "core_0", SESSION_WAIT), "Ctrl+G: a graph per logical processor")
	check(l, cdp.key(c, "ctrl+g") && cdp.wait_name(c, "cpu_graph", SESSION_WAIT), "Ctrl+G again: one graph")
}

// The share of a graph's pixels that are drawn, once it is more than GRAPH_DRAWN_SHARE or after PERF_POINTS_WAIT.
@(private = "file")
wait_drawn :: proc(c: ^cdp.Client, name: string) -> f64 {
	deadline := time.tick_add(time.tick_now(), PERF_POINTS_WAIT)
	share := 0.0
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		share = drawn_share(c, name)
		if share > GRAPH_DRAWN_SHARE { break }
		time.sleep(GRAPH_POLL)
	}
	return share
}

// The share of the box's pixels that are not its three commonest colours.
drawn_share :: proc(c: ^cdp.Client, name: string) -> f64 {
	boxes := cdp.find_name(c, name)
	if len(boxes) == 0 { return 0 }
	b := boxes[0]
	png, ok := cdp.screenshot(c, cdp.Clip{b.x, b.y, b.w, b.h}, context.temp_allocator)
	if !ok { return 0 }
	pic, dok := cdp.png_decode(png, context.temp_allocator)
	if !dok { return 0 }
	counts := make(map[u32]int, 256, context.temp_allocator)
	n := pic.width * pic.height
	for i in 0 ..< n {
		p := pic.pixels[i * 4:][:3]
		counts[u32(p[0]) << 16 | u32(p[1]) << 8 | u32(p[2])] += 1
	}
	Count :: struct { color: u32, n: int }
	list := make([dynamic]Count, 0, len(counts), context.temp_allocator)
	for k, v in counts { append(&list, Count{k, v}) }
	slice.sort_by(list[:], proc(a, b: Count) -> bool { return a.n > b.n })
	common := list[:min(3, len(list))]
	other := 0
	for i in 0 ..< n {
		p := pic.pixels[i * 4:][:3]
		near := false
		for k in common {
			r, g, bl := int(k.color >> 16), int(k.color >> 8 & 0xff), int(k.color & 0xff)
			if abs(int(p[0]) - r) <= GRAPH_COLOR_SLACK && abs(int(p[1]) - g) <= GRAPH_COLOR_SLACK && abs(int(p[2]) - bl) <= GRAPH_COLOR_SLACK { near = true; break }
		}
		if !near { other += 1 }
	}
	return n > 0 ? f64(other) / f64(n) : 0
}

// The logical processors (the cpuN lines of /proc/stat).
@(private = "file")
logical_processors :: proc() -> int {
	data, _ := os.read_entire_file("/proc/stat", context.temp_allocator)
	n := 0
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(line, "cpu") && !strings.has_prefix(line, "cpu ") { n += 1 }
	}
	return n
}

// The columns: one shown and hidden again from the header's menu, one resized; both are in the preferences.
live_columns :: proc(l: ^Live) {
	c := &l.c
	prefs := fmt.tprintf("%s/config/inspecteur/prefs", l.dir)
	_, ok := cdp.call(c, "Toolkit.click", `{"name":"hd_0","button":"right"}`)
	check(l, ok && cdp.wait_for(c, "Default columns", SESSION_WAIT), "a right click on the header opens the columns' menu")
	check(l, click_last(c, "Parent PID"), "show Parent PID")
	check(l, cdp.wait_name(c, "hd_2", SESSION_WAIT), "its column is there")
	check(l, file_has(prefs, "ppid"), "and in the preferences")
	check(l, click_last(c, "Parent PID"), "hide it")
	check(l, cdp.wait_name(c, "hd_2", SESSION_WAIT, gone = true), "its column is gone")
	check(l, cdp.key(c, "Escape") && cdp.wait_for(c, "Default columns", SESSION_WAIT, gone = true), "Escape closes the menu")

	// the PID column's rule, dragged 40 px to the left: the column is wider
	before := cdp.find_name(c, "hd_1")
	rules := cdp.find_name(c, "rule")
	if !check(l, len(before) == 1 && len(rules) > 0, "the PID column has its rule") { return }
	r := rules[0]
	x, y := r.x + r.w / 2, r.y + r.h / 2
	mouse :: proc(c: ^cdp.Client, kind: string, x, y: f64) -> bool {
		_, ok := cdp.call(c, "Input.dispatchMouseEvent", fmt.tprintf(`{{"type":%q,"x":%v,"y":%v,"button":"left","buttons":1,"clickCount":1}}`, kind, x, y))
		return ok
	}
	moved := mouse(c, "mouseMoved", x, y) && mouse(c, "mousePressed", x, y)
	for k in 1 ..= 4 { moved = moved && mouse(c, "mouseMoved", x - f64(k) * 10, y) }
	moved = moved && mouse(c, "mouseReleased", x - 40, y)
	cdp.wait_idle(c, SESSION_WAIT)
	after := cdp.find_name(c, "hd_1")
	check(l, moved && len(after) == 1 && after[0].w > before[0].w + 30, "dragging its rule widens the PID column (%.0f px to %.0f)", before[0].w, len(after) == 1 ? after[0].w : 0)
	check(l, file_has(prefs, "processes.widths\tpid="), "its width is in the preferences")
}

// The theme's menu: light chosen, written; back to the system's.
live_theme :: proc(l: ^Live) {
	c := &l.c
	prefs := fmt.tprintf("%s/config/inspecteur/prefs", l.dir)
	check(l, cdp.click_name(c, "theme") && cdp.wait_for(c, "As the system", SESSION_WAIT), "the theme's menu opens")
	check(l, cdp.click_text(c, "Light"), "choose Light")
	check(l, file_has(prefs, "view.mode\tlight"), "it is in the preferences")
	// (the colours fade to the light version: the window is idle once the fade is over)
	cdp.wait_idle(c, SESSION_WAIT)
	check(l, cdp.shot(c, fmt.tprintf("%s/light.png", l.dir)), "a picture of the light version")
	check(l, cdp.click_name(c, "theme") && cdp.wait_for(c, "As the system", SESSION_WAIT), "the menu again")
	check(l, cdp.click_text(c, "As the system"), "back to the system's version")
	check(l, file_has(prefs, "view.mode\tsystem"), "written")
}

// The Properties of a process of this test: its threads, its files (its output, a file of this test), suspend and
// resume, End task.
live_properties :: proc(l: ^Live) {
	c := &l.c
	check(l, cdp.key(c, "Escape"), "Escape clears the search")
	out_path := fmt.tprintf("%s/child-output.txt", l.dir)
	out, oerr := os.open(out_path, {.Write, .Create, .Trunc})
	if !check(l, oerr == nil, "a file for the child's output") { return }
	mark := fmt.tprintf("300.%d3", os.get_pid())
	child, err := os.process_start({command = {"sleep", mark}, stdout = out})
	os.close(out)
	if !check(l, err == nil, "start sleep %s, its output in %s", mark, out_path) { return }
	reaped := false
	// (whatever failed, it does not stay; once reaped, its pid may be another process's: no signal then)
	defer if !reaped { _ = os.process_kill(child); _, _ = os.process_wait(child, SESSION_WAIT) }
	pid := fmt.tprintf("%d", child.pid)
	check(l, cdp.type_text(c, mark), "search it")
	check(l, cdp.wait_for(c, fmt.tprintf("Selected: sleep, PID %s", pid), SESSION_WAIT), "it is selected")
	if !select_child(l, pid) { return }
	check(l, cdp.key(c, "alt+Enter"), "Alt+Enter")
	// (the dialog's buttons act on the process its title names: they are clicked only when it names the child)
	cdp.wait_name(c, "props_name", SESSION_WAIT)
	if !check(l, props_is(c, pid), "its Properties open, on sleep PID %s", pid) { return }
	check(l, cdp.click_name(c, "props_tab_1"), "the History tab")
	check(l, cdp.wait_name(c, "hist_cpu", SESSION_WAIT) && cdp.wait_name(c, "hist_memory", SESSION_WAIT), "it graphs the process's CPU and memory since it started")
	check(l, cdp.click_name(c, "props_tab_2"), "the Threads tab")
	check(l, wait_cell(c, pid), "it lists the process's thread (TID %s)", pid)
	check(l, cdp.click_name(c, "props_tab_3"), "the Open files tab")
	check(l, cdp.wait_for(c, "child-output.txt", SESSION_WAIT), "it lists the file of its output")
	check(l, cdp.click_name(c, "props_tab_4"), "the Modules tab")
	check(l, cdp.wait_for(c, "libc", SESSION_WAIT), "it lists the C library")
	if !check(l, props_is(c, pid), "the dialog is still the child's") { return }
	if !check(l, cdp.click_name(c, "props_suspend"), "Suspend") { return }
	check(l, wait_state(child.pid, 'T'), "the process is stopped (T)")
	check(l, cdp.wait_for(c, "Resume", SESSION_WAIT), "the button says Resume")
	if !check(l, props_is(c, pid), "the dialog is still the child's") { return }
	if !check(l, cdp.click_name(c, "props_suspend"), "Resume") { return }
	check(l, wait_state(child.pid, 'S'), "the process sleeps again (S)")
	// its priority, lowered from the keyboard (a user may lower a priority: nice 0 to the next line, 5)
	if !check(l, props_is(c, pid), "the dialog is still the child's") { return }
	check(l, cdp.key(c, "ctrl+ArrowDown"), "Ctrl+Down: a lower priority")
	check(l, wait_nice(child.pid, 5), "the process runs at nice 5")
	check(l, cdp.key(c, "ctrl+p") && wait_state(child.pid, 'T'), "Ctrl+P suspends it")
	check(l, props_is(c, pid) && cdp.key(c, "ctrl+p") && wait_state(child.pid, 'S'), "Ctrl+P again resumes it")
	// the filter of the lists: Ctrl+F, a text no thread has
	check(l, cdp.click_name(c, "props_tab_2") && cdp.key(c, "ctrl+f") && cdp.type_text(c, "zzqx"), "Ctrl+F in the Threads tab, a text")
	check(l, cdp.wait_for(c, "Nothing matches “zzqx”.", SESSION_WAIT), "it filters the threads out")
	cdp.click_name(c, "props_tab_0")
	cdp.wait_idle(c, SESSION_WAIT)
	check(l, cdp.shot(c, fmt.tprintf("%s/properties.png", l.dir)), "a picture of the Properties")
	if !check(l, props_is(c, pid), "the dialog is still the child's") { return }
	if !check(l, cdp.click_name(c, "props_end"), "End task") { return }
	state, werr := os.process_wait(child, SESSION_WAIT)
	reaped = werr == nil && state.exited
	check(l, werr == nil && state.exited && state.exit_code == 15, "it ends by SIGTERM (code %d)", state.exit_code)
	check(l, cdp.wait_for(c, "The process has ended", SESSION_WAIT), "the dialog says it ended")
	check(l, cdp.key(c, "Escape") && cdp.wait_name(c, "props_name", SESSION_WAIT, gone = true), "Escape closes it")
	check(l, cdp.key(c, "Escape"), "Escape clears the search")
}

// The nice value of /proc/<pid>/stat (its 19th field) becomes `want`.
wait_nice :: proc(pid: int, want: int) -> bool {
	deadline := time.tick_add(time.tick_now(), SESSION_WAIT)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		data, err := os.read_entire_file(fmt.tprintf("/proc/%d/stat", pid), context.temp_allocator)
		if err == nil {
			text := string(data)
			rest := text[strings.last_index_byte(text, ')') + 1:]
			field := 3
			for word in strings.fields_iterator(&rest) {
				if field == 19 {
					v := strconv.parse_int(word, 10) or_else -99
					if v == want { return true }
					break
				}
				field += 1
			}
		}
		time.sleep(SESSION_POLL)
	}
	return false
}

// Whether the Properties dialog's title names sleep, PID `pid` (its boxes props_name and props_pid).
props_is :: proc(c: ^cdp.Client, pid: string) -> bool {
	names := cdp.find_name(c, "props_name")
	pids := cdp.find_name(c, "props_pid")
	if len(names) != 1 || len(pids) != 1 || names[0].text != "sleep" { return false }
	t := pids[0].text
	want := fmt.tprintf("PID %s", pid)
	return t == want || strings.has_prefix(t, fmt.tprintf("%s ", want))
}

// Clicks the last box whose text holds `text` (a menu's item comes after the header that has the same words).
@(private = "file")
click_last :: proc(c: ^cdp.Client, text: string) -> bool {
	boxes := cdp.find(c, text)
	if len(boxes) == 0 { return false }
	_, ok := cdp.call(c, "Toolkit.click", fmt.tprintf(`{{"text":%s,"index":%d}}`, cdp.quote(text), len(boxes) - 1))
	return ok
}

// The file comes to hold `text`.
file_has :: proc(path, text: string) -> bool {
	deadline := time.tick_add(time.tick_now(), SESSION_WAIT)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err == nil && strings.contains(string(data), text) { return true }
		time.sleep(SESSION_POLL)
	}
	return false
}

// A list's first cell (named c0) that says `text`.
@(private = "file")
wait_cell :: proc(c: ^cdp.Client, text: string) -> bool {
	deadline := time.tick_add(time.tick_now(), SESSION_WAIT)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		for b in cdp.find_name(c, "c0") { if b.text == text { return true } }
		time.sleep(SESSION_POLL)
	}
	return false
}

// The state letter of /proc/<pid>/stat becomes `want` within the time.
wait_state :: proc(pid: int, want: u8, within := SESSION_WAIT) -> bool {
	deadline := time.tick_add(time.tick_now(), within)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		data, err := os.read_entire_file(fmt.tprintf("/proc/%d/stat", pid), context.temp_allocator)
		if err == nil {
			text := string(data)
			if i := strings.last_index_byte(text, ')'); i >= 0 && i + 2 < len(text) && text[i + 2] == want { return true }
		}
		time.sleep(SESSION_POLL)
	}
	return false
}
