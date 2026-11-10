package inspecteurtool

// shots: the pictures of the README, the program's own frames (over the DevTools protocol, session.odin). The processes,
// services, sockets and details are the machine's: what is there when the pictures are made.
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
PERF_SETTLE :: 6 * time.Second

run_shots :: proc(args: []string) -> int {
	out := SHOTS_OUT
	if len(args) == 2 && args[0] == "--out" { out = args[1] }
	if run_build({"release"}) != 0 { return 1 }
	s: Session
	defer session_stop(&s)
	// (the person's session bus: the Services and Startup sections read the user's service manager, nothing more)
	if why := session_start(&s, SHOTS_DIR, SHOTS_PORT, {"--pref", "view.mode=dark"}, user_bus = true); why != "" { fmt.eprintfln("inspecteurtool shots: %s", why); return 1 }
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
	cdp.wait_for(&c, "Background processes", SESSION_WAIT)
	click_header(&c, "CPU")   // the busiest first
	time.sleep(1500 * time.Millisecond)   // (two samples: every row has its CPU %)
	shot(&c, out, "processes", &failed)
	// the first app's group, open, and its menu
	cdp.click_name(&c, "lrow_1")   // (row 0 is the section's title)
	cdp.key(&c, "ArrowRight")
	cdp.wait_idle(&c, SESSION_WAIT)
	cdp.key(&c, "ContextMenu")
	cdp.wait_for(&c, "Copy command line", SESSION_WAIT)
	shot(&c, out, "menu", &failed)
	cdp.key(&c, "Escape")

	// the Performance section: the graphs need some history (a few samples)
	cdp.click_text(&c, "Performance")
	cdp.wait_name(&c, "cpu_graph", SESSION_WAIT)
	time.sleep(PERF_SETTLE)
	shot(&c, out, "performance_cpu", &failed)
	cdp.click_text(&c, "Logical processors")
	cdp.wait_name(&c, "core_0", SESSION_WAIT)
	shot(&c, out, "performance_cpu_grid", &failed)
	cdp.click_name(&c, "dev_1_0")
	cdp.wait_name(&c, "memory_graph", SESSION_WAIT)
	shot(&c, out, "performance_memory", &failed)
	pictures := [3]string{"performance_disk", "performance_network", "performance_gpu"}
	for name, kind in ([]string{"dev_2_0", "dev_3_0", "dev_4_0"}) {
		if !cdp.click_name(&c, name) { continue }
		cdp.wait_idle(&c, SESSION_WAIT)
		shot(&c, out, pictures[kind], &failed)
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
		if !cdp.wait_for(&c, sec.ready, SESSION_WAIT) { failed = true; continue }
		time.sleep(500 * time.Millisecond)   // (the icons of the rows, loaded at their first frame)
		shot(&c, out, sec.picture, &failed)
	}
	return failed ? 1 : 0
}
