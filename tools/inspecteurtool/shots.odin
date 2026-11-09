package inspecteurtool

// shots: the pictures of the README, the program's own frames (over the DevTools protocol, session.odin). The processes
// are the machine's: what runs there when the pictures are made.
//
//   inspecteurtool shots [--out folder]      (default: docs/screenshots)

import "core:fmt"
import "core:os"
import "core:time"
import cdp "gt:cdp"

SHOTS_DIR  :: "build/shots"
SHOTS_PORT :: 9373
SHOTS_OUT  :: "docs/screenshots"

run_shots :: proc(args: []string) -> int {
	out := SHOTS_OUT
	if len(args) == 2 && args[0] == "--out" { out = args[1] }
	if run_build({"release"}) != 0 { return 1 }
	s: Session
	defer session_stop(&s)
	if why := session_start(&s, SHOTS_DIR, SHOTS_PORT, {"--pref", "view.mode=dark"}); why != "" { fmt.eprintfln("inspecteurtool shots: %s", why); return 1 }
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
	cdp.click_name(&c, "hd_3")   // the busiest first
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
	return failed ? 1 : 0
}
