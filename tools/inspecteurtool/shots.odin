package inspecteurtool

// shots: the pictures of the README and the documentation, the program's own frames (over the DevTools protocol,
// session.odin). The program runs with --demo: its processes, devices, services, sockets and system are made up
// (src/demo.odin), so that no picture shows anything of the machine it is made on (its host and user names, its home
// folder, its addresses, its services and apps). Nothing of the person's session is used: no session bus.
//
//   inspecteurtool shots [--out folder]      (default: docs/screenshots)

import "core:fmt"
import "core:os"
import "core:time"
import cdp "gt:cdp"

SHOTS_DIR  :: "build/shots"
SHOTS_PORT :: 9373
SHOTS_OUT  :: "docs/screenshots"
// The Performance section's graphs, a few samples old before their pictures.
PERF_SETTLE :: 8 * time.Second

run_shots :: proc(args: []string) -> int {
	out := SHOTS_OUT
	if len(args) == 2 && args[0] == "--out" { out = args[1] }
	if run_build({"release"}) != 0 { return 1 }
	s: Session
	defer session_stop(&s)
	if why := session_start(&s, SHOTS_DIR, SHOTS_PORT, {"--demo", "--pref", "view.mode=dark"}); why != "" { fmt.eprintfln("inspecteurtool shots: %s", why); return 1 }
	c, ok := window_connect(&s)
	if !ok { fmt.eprintln("inspecteurtool shots: the window does not answer"); return 1 }
	defer cdp.close(&c)
	_ = os.make_directory_all(out)
	failed := false
	shot :: proc(c: ^cdp.Client, out, name: string, failed: ^bool) {
		cdp.wait_idle(c, SESSION_WAIT)
		path := fmt.tprintf("%s/%s.png", out, name)
		if cdp.shot(c, path) { fmt.printfln("wrote %s", path) } else { failed^ = true }
	}
	need :: proc(ok: bool, what: string, failed: ^bool) -> bool {
		if !ok { fmt.eprintfln("inspecteurtool shots: %s", what); failed^ = true }
		return ok
	}
	need(cdp.wait_for(&c, "Background processes", SESSION_WAIT), "no table", &failed)
	click_header(&c, "CPU")   // the busiest first
	time.sleep(2500 * time.Millisecond)   // (some samples: every row has its CPU %)
	shot(&c, out, "processes", &failed)

	// the first app's group, open, and its menu
	cdp.click_name(&c, "lrow_1")   // (row 0 is the section's title)
	cdp.key(&c, "ArrowRight")
	cdp.wait_idle(&c, SESSION_WAIT)
	cdp.key(&c, "ContextMenu")
	if need(cdp.wait_for(&c, "Copy command line", SESSION_WAIT), "no row menu", &failed) { shot(&c, out, "menu", &failed) }
	cdp.key(&c, "Escape")

	// the Properties of a process of the group, on its Threads tab
	cdp.key(&c, "ArrowDown")
	cdp.key(&c, "alt+Enter")
	if need(cdp.wait_name(&c, "props_name", SESSION_WAIT), "no Properties", &failed) {
		shot(&c, out, "properties", &failed)
		cdp.click_name(&c, "props_tab_1")
		cdp.wait_name(&c, "threads", SESSION_WAIT)
		shot(&c, out, "properties_threads", &failed)
		cdp.key(&c, "Escape")
		cdp.wait_name(&c, "props_name", SESSION_WAIT, gone = true)
	}

	// the command palette, searching
	cdp.key(&c, "ctrl+k")
	if need(cdp.wait_for(&c, "Type to search", SESSION_WAIT), "no palette", &failed) {
		cdp.type_text(&c, "prio")
		cdp.wait_for(&c, "Raise the priority", SESSION_WAIT)
		shot(&c, out, "palette", &failed)
		cdp.key(&c, "Escape")
	}
	// the sheet of the keys
	cdp.key(&c, "F1")
	if need(cdp.wait_for(&c, "Keyboard shortcuts", SESSION_WAIT), "no sheet of the keys", &failed) {
		shot(&c, out, "shortcuts", &failed)
		cdp.key(&c, "Escape")
		cdp.wait_for(&c, "Keyboard shortcuts", SESSION_WAIT, gone = true)
	}

	// the Performance section: the graphs need some history (a few samples)
	cdp.key(&c, "ctrl+2")
	cdp.wait_name(&c, "cpu_graph", SESSION_WAIT)
	time.sleep(PERF_SETTLE)
	shot(&c, out, "performance_cpu", &failed)
	cdp.key(&c, "ctrl+g")
	cdp.wait_name(&c, "core_0", SESSION_WAIT)
	shot(&c, out, "performance_cpu_grid", &failed)
	cdp.key(&c, "ctrl+g")
	pictures := [?]struct { device, picture: string }{
		{"dev_1_0", "performance_memory"}, {"dev_2_0", "performance_disk"}, {"dev_3_0", "performance_network"}, {"dev_4_0", "performance_gpu"},
	}
	for p in pictures {
		if !need(cdp.click_name(&c, p.device), fmt.tprintf("no device %s", p.device), &failed) { continue }
		shot(&c, out, p.picture, &failed)
	}

	// the sections that read on threads of their own: each once its reading is shown
	sections := []struct { key, ready, picture: string }{
		{"ctrl+3", "running", "services"},
		{"ctrl+4", " on", "startup"},
		{"ctrl+5", "listening or open", "connections"},
		{"ctrl+6", "Operating system", "information"},
	}
	for sec in sections {
		cdp.key(&c, sec.key)
		if !need(cdp.wait_for(&c, sec.ready, SESSION_WAIT), fmt.tprintf("%s is not read", sec.picture), &failed) { continue }
		time.sleep(500 * time.Millisecond)   // (the icons of the rows, loaded at their first frame)
		shot(&c, out, sec.picture, &failed)
	}

	// the welcome page, and the light version
	cdp.key(&c, "ctrl+shift+i")
	if need(cdp.wait_for(&c, "Welcome to Inspecteur", SESSION_WAIT), "no welcome page", &failed) {
		shot(&c, out, "welcome", &failed)
		cdp.click_name(&c, "setup_done")
		cdp.wait_for(&c, "Welcome to Inspecteur", SESSION_WAIT, gone = true)
	}
	cdp.key(&c, "ctrl+1")
	need(cdp.wait_for(&c, "Background processes", SESSION_WAIT), "no Processes section", &failed)
	cdp.key(&c, "ctrl+shift+l")
	cdp.wait_for(&c, "Light colours", SESSION_WAIT)
	time.sleep(1500 * time.Millisecond)   // (the colours fade to the light version)
	shot(&c, out, "processes_light", &failed)
	return failed ? 1 : 0
}
