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
		if need(cdp.wait_name(&c, "hist_cpu", SESSION_WAIT), "no History tab", &failed) { shot(&c, out, "properties_history", &failed) }
		cdp.click_name(&c, "props_tab_2")
		cdp.wait_name(&c, "threads", SESSION_WAIT)
		shot(&c, out, "properties_threads", &failed)
		cdp.key(&c, "Escape")
		cdp.wait_name(&c, "props_name", SESSION_WAIT, gone = true)
	}

	// the process tree (Ctrl+T), and back
	cdp.key(&c, "ctrl+t")
	if need(cdp.wait_for(&c, "as a tree", SESSION_WAIT), "no tree", &failed) { shot(&c, out, "processes_tree", &failed) }
	cdp.key(&c, "ctrl+t")
	need(cdp.wait_for(&c, "Background processes", SESSION_WAIT), "no apps after the tree", &failed)

	// three background processes marked (a click, a Shift click, a Ctrl click; the apps and the group open come first), and the kill's confirmation that lists them
	if rows := cdp.find_name(&c, "c1"); need(len(rows) > 20, "too few rows to mark", &failed) {
		click_at :: proc(c: ^cdp.Client, index: int, mods: int) {
			cdp.call(c, "Toolkit.click", fmt.tprintf(`{{"name":"c1","index":%d,"modifiers":%d}}`, index, mods))
			cdp.wait_idle(c, SESSION_WAIT)
		}
		click_at(&c, 15, 0)
		click_at(&c, 16, 8)
		click_at(&c, 18, 2)
		cdp.key(&c, "shift+Delete")
		if need(cdp.wait_for(&c, "Kill 3 processes?", SESSION_WAIT), "no confirmation of the kill of three", &failed) { shot(&c, out, "kill_confirm", &failed) }
		cdp.key(&c, "Escape")
		cdp.wait_name(&c, "confirm_act", SESSION_WAIT, gone = true)
		click_at(&c, 15, 0)
	}

	// the affinity of a process
	cdp.key(&c, "ctrl+shift+a")
	if need(cdp.wait_name(&c, "affinity_apply", SESSION_WAIT), "no affinity dialog", &failed) {
		shot(&c, out, "affinity", &failed)
		cdp.key(&c, "Escape")
		cdp.wait_name(&c, "affinity_apply", SESSION_WAIT, gone = true)
	}

	// the command palette, searching
	cdp.key(&c, "ctrl+k")
	if need(cdp.wait_name(&c, "palette_field", SESSION_WAIT), "no palette", &failed) {
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
	// Why is it slow?
	cdp.key(&c, "F2")
	if need(cdp.wait_for(&c, "Why is it slow?", SESSION_WAIT), "no diagnosis", &failed) {
		shot(&c, out, "diagnosis", &failed)
		cdp.key(&c, "Escape")
		cdp.wait_for(&c, "Why is it slow?", SESSION_WAIT, gone = true)
	}

	// the Performance section: the graphs need some history (a few samples)
	cdp.key(&c, "ctrl+3")
	cdp.wait_name(&c, "cpu_graph", SESSION_WAIT)
	time.sleep(PERF_SETTLE)
	shot(&c, out, "performance_cpu", &failed)
	cdp.key(&c, "ctrl+g")
	cdp.wait_name(&c, "core_0", SESSION_WAIT)
	shot(&c, out, "performance_cpu_grid", &failed)
	cdp.key(&c, "ctrl+g")
	pictures := [?]struct { device, picture: string }{
		{"dev_1_0", "performance_memory"}, {"dev_2_0", "performance_disk"}, {"dev_3_0", "performance_network"}, {"dev_4_0", "performance_gpu"}, {"dev_5_0", "performance_pressure"},
	}
	for p in pictures {
		if !need(cdp.click_name(&c, p.device), fmt.tprintf("no device %s", p.device), &failed) { continue }
		shot(&c, out, p.picture, &failed)
	}

	// Mission Control, once every section has read
	cdp.key(&c, "ctrl+1")
	if need(cdp.wait_name(&c, "mc_svc_0", SESSION_WAIT), "no Mission Control", &failed) {
		time.sleep(1500 * time.Millisecond)
		shot(&c, out, "mission_control", &failed)
	}

	// the sections that read on threads of their own: each once its reading is shown
	sections := []struct { key, ready, picture: string }{
		{"ctrl+4", "running", "services"},
		{"ctrl+5", " on", "startup"},
		{"ctrl+6", "listening or open", "connections"},
		{"ctrl+7", "Operating system", "information"},
	}
	for sec in sections {
		cdp.key(&c, sec.key)
		if !need(cdp.wait_for(&c, sec.ready, SESSION_WAIT), fmt.tprintf("%s is not read", sec.picture), &failed) { continue }
		time.sleep(500 * time.Millisecond)   // (the icons of the rows, loaded at their first frame)
		shot(&c, out, sec.picture, &failed)
	}

	// a failed service's journal: warnings and worse, an entry selected and shown whole
	cdp.key(&c, "ctrl+4")
	if need(cdp.wait_for(&c, "running", SESSION_WAIT), "no Services section", &failed) {
		cdp.type_text(&c, "nginx")
		cdp.wait_idle(&c, SESSION_WAIT)
		cdp.call(&c, "Toolkit.click", `{"name":"c0","index":0}`)
		if need(cdp.wait_for(&c, "Errors 3", SESSION_WAIT), "no journal of nginx", &failed) {
			cdp.key(&c, "alt+l")
			cdp.wait_idle(&c, SESSION_WAIT)
			cdp.call(&c, "Toolkit.click", `{"name":"jm","index":2}`)
			cdp.wait_name(&c, "je_message", SESSION_WAIT)
			shot(&c, out, "services_journal", &failed)
			cdp.key(&c, "alt+l")
			cdp.key(&c, "alt+l")
		}
		cdp.key(&c, "ctrl+f")
		cdp.key(&c, "Escape")
		cdp.wait_idle(&c, SESSION_WAIT)
	}

	// the settings (not the install's dialog: it shows the real folders of the machine it runs on), and the light version
	cdp.key(&c, "ctrl+,")
	if need(cdp.wait_for(&c, "Appearance", SESSION_WAIT), "no settings", &failed) {
		time.sleep(500 * time.Millisecond)   // (the themes' cards)
		shot(&c, out, "settings", &failed)
		cdp.key(&c, "Escape")
		cdp.key(&c, "Escape")
		cdp.wait_name(&c, "settings_button", SESSION_WAIT)
	}
	cdp.key(&c, "ctrl+2")
	need(cdp.wait_for(&c, "Background processes", SESSION_WAIT), "no Processes section", &failed)
	cdp.key(&c, "ctrl+shift+l")
	cdp.wait_for(&c, "Light colours", SESSION_WAIT)
	time.sleep(1500 * time.Millisecond)   // (the colours fade to the light version)
	shot(&c, out, "processes_light", &failed)
	// last: the footer says the text's size for a while after (it was in the next pictures)
	// larger text, as a narrow window: the name column keeps its width, the last columns go past the edge
	for _ in 0 ..< 4 { cdp.key(&c, "ctrl+=") }
	cdp.wait_idle(&c, SESSION_WAIT)
	shot(&c, out, "processes_large_text", &failed)
	if !failed && out == SHOTS_OUT && !site_pictures(out) { failed = true }
	return failed ? 1 : 0
}

// The site's pictures (site/img) and the documentation's they are copies of: shots writes them both, so neither falls
// behind the other.
SITE_PICTURES :: [?][2]string{
	{"main", "processes"}, {"properties", "properties"}, {"kill", "kill_confirm"}, {"performance", "performance_cpu"},
	{"services", "services"}, {"tree", "processes_tree"},
}

@(private = "file")
site_pictures :: proc(out: string) -> bool {
	for p in SITE_PICTURES {
		to := fmt.tprintf("site/img/%s.png", p[0])
		if err := os.copy_file(to, fmt.tprintf("%s/%s.png", out, p[1])); err != nil {
			fmt.eprintfln("inspecteurtool shots: %s cannot be written: %v", to, err)
			return false
		}
		fmt.printfln("wrote %s", to)
	}
	return true
}
